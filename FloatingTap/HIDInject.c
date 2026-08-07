//
//  HIDInject.c — FloatingTap HID 注入引擎（纯 C 版）
//
//  v1.0.24/25：经典单事件写法（zxtouch/autotouch 验证 iOS 13-16 有效）——
//  构造 kIOHIDEventTypeDigitizer 触摸事件（type=Hand 转换器，坐标直传，归一化 0~1），
//  标记 kIOHIDEventFieldDigitizerIsDisplayIntegrated=1（关键，否则系统丢弃），
//  IOHIDEventSystemClientDispatchEvent 派发到系统 HID 服务，实现全局触摸注入。
//  SpringBoard 进程自身具备 HID entitlement，越狱环境可直接调用。
//
//  ⚠️ 纯 C 约束（arm64e PAC 环境铁律）：
//     - 无 @implementation / @"..." / block / @selector
//     - 不 import Foundation.h（ObjC 头），只用 CoreFoundation/GCD（纯 C）
//     - dispatch_once 用 C 静态 flag 代替
//

#include "HIDInject.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <stdio.h>
#include <syslog.h>
#include <stdint.h>
#include <stdbool.h>
#include <dispatch/dispatch.h>
// v1.0.63：纯 C 文件内读 UIEvent 的 _hidEvent 需要 objc runtime（Tweak.xm 是 ARC，
// object_getInstanceVariable 被禁；移到本 .c 文件绕开）。
#include <objc/runtime.h>

// MARK: - 私有类型与常量（本地前缀，避免与 SDK IOKit 头冲突）

typedef struct __IOHIDEvent * FT_IOHIDEventRef;
typedef struct __IOHIDEventSystemClient * FT_IOHIDEventSystemClientRef;
typedef struct __IOHIDService * FT_IOHIDServiceRef;
typedef int32_t FT_IOReturn;
typedef uint32_t FT_IOOptionBits;
static const FT_IOReturn FT_kIOReturnSuccess = 0;

enum {
    FT_kIOHIDDigitizerEventRange    = 0x00000001,
    FT_kIOHIDDigitizerEventTouch    = 0x00000002,
    FT_kIOHIDDigitizerEventPosition = 0x00000004,
    FT_kIOHIDDigitizerEventTip      = 0x00000008,
    FT_kIOHIDDigitizerEventIdentity = 0x00000010,
};

// MARK: - 私有函数指针（dlopen 动态解析）

// ⚠️ v1.0.37: IOHIDEventCreateDigitizerEvent 是 15 参数（无第 4 位 options）！
// 参考 zxtouch 源码：allocator, ts, type, index, identity, eventMask, buttonMask,
// x, y, z, tipPressure, barrelPressure, range, touch, options。
// v1.0.24~36 误用 16 参数导致 index 起全部参数错位 → 事件畸形被 iOS 忽略。
static FT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef,
                                                            uint64_t timeStamp,
                                                            uint32_t type,
                                                            uint32_t index,
                                                            uint32_t identity,
                                                            uint32_t eventMask,
                                                            uint32_t buttonMask,
                                                            double x, double y, double z,
                                                            double tipPressure,
                                                            double barrelPressure,
                                                            Boolean range,
                                                            Boolean touch,
                                                            FT_IOOptionBits options);

static FT_IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static FT_IOReturn (*p_IOHIDEventSystemClientDispatchEvent)(FT_IOHIDEventSystemClientRef, FT_IOHIDEventRef);
static void (*p_IOHIDEventSystemClientScheduleWithRunLoop)(FT_IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
static void (*p_IOHIDEventSetSenderID)(FT_IOHIDEventRef, uint64_t);
static void (*p_IOHIDEventSetIntegerValue)(FT_IOHIDEventRef, uint32_t, int64_t);
// v1.0.64：float 字段设置（坐标/半径），以及读事件类型（用于筛选 digitizer 事件抓 senderID）
static void (*p_IOHIDEventSetFloatValue)(FT_IOHIDEventRef, uint32_t, double);
static uint32_t (*p_IOHIDEventGetType)(FT_IOHIDEventRef);
static uint64_t (*p_IOHIDEventGetSenderID)(FT_IOHIDEventRef);
// 注：client 级 senderID 设置符号 (IOHIDEventSystemClientSetSenderID) 已弃用（v1.0.64）——设错会致 DispatchEvent 0x1。
// ⚠️ 子事件签名铁律（v1.0.67，来自 SimulateTouch 对系统函数的 hook 反编译，权威）：
//   IOHIDEventCreateDigitizerFingerEvent(allocator, ts, index, identity, eventMask,
//       IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
//       IOHIDFloat tipPressure, IOHIDFloat twist,
//       Boolean range, Boolean touch, IOOptionBits options)
//   —— 共 13 参数，【eventMask 之后直接是 x,y,z,tipPressure,twist,range,touch,options，
//      没有 buttonMask、也没有 minorRadius/majorRadius】。
//   v1.0.66 给 plain 变体误加了 minorRadius/majorRadius（15 参）→ 后续参数整体偏移一格 →
//   事件畸形 → DispatchEvent 0x1。现彻底修正为 13 参（与 ZXTouch 验证可用实现一致）。
//   （WithQuality 变体在 iOS 15.5 大概率不存在，已弃用，统一走 plain 13 参。）
static FT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t timeStamp, uint32_t index, uint32_t identity,
    uint32_t eventMask, double x, double y, double z, double tipPressure,
    double twist, Boolean range, Boolean touch, FT_IOOptionBits options);
static void (*p_IOHIDEventAppendEvent)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits);

// MARK: - 状态

static FT_IOHIDEventSystemClientRef g_hidClient = NULL;
static bool g_hidLoaded = false;
// v1.0.63：动态捕获的真实设备 senderID（0 表示未捕获，用兜底硬编码）
static uint64_t g_OverrideSenderID = 0;
// v1.0.74：sendEvent 里会出现【多个】digitizer senderID（主屏 digitizer / 手势翻译服务等），
// 最后一个捕获值不一定是系统认领的那个（ctor-45 实测 0x1000007af 被拒、ctor-39 的 0x1000007ad 可用）。
// 改为收集候选集，派发时逐个尝试，首个成功即锁定为 g_WorkingSID。
static uint64_t g_CapturedSIDs[4] = {0};
static int      g_CapturedSIDCount = 0;
static uint64_t g_WorkingSID = 0;   // 已验证可用的 senderID（锁定后优先使用）

// 前向声明（定义在文件后部「诊断日志」段，但 FT_HIDConnect 等前面函数要用）
static void FTHIDLog(const char *msg);

// MARK: - 符号解析（C 静态 flag 代替 dispatch_once）

static bool FT_HIDLoadSymbols(void) {
    if (g_hidLoaded) return true;

    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!handle) handle = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!handle) {
        syslog(LOG_ERR, "FloatingTap HID dlopen IOKit failed");
        return false;
    }

    p_IOHIDEventCreateDigitizerEvent =
        (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                              uint32_t, uint32_t, double, double, double, double, double,
                              Boolean, Boolean, FT_IOOptionBits))
        dlsym(handle, "IOHIDEventCreateDigitizerEvent");
    p_IOHIDEventSystemClientCreate =
        (FT_IOHIDEventSystemClientRef (*)(CFAllocatorRef))dlsym(handle, "IOHIDEventSystemClientCreate");
    p_IOHIDEventSystemClientDispatchEvent =
        (FT_IOReturn (*)(FT_IOHIDEventSystemClientRef, FT_IOHIDEventRef))dlsym(handle, "IOHIDEventSystemClientDispatchEvent");
    p_IOHIDEventSystemClientScheduleWithRunLoop =
        (void (*)(FT_IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef))dlsym(handle, "IOHIDEventSystemClientScheduleWithRunLoop");
    p_IOHIDEventSetSenderID =
        (void (*)(FT_IOHIDEventRef, uint64_t))dlsym(handle, "IOHIDEventSetSenderID");
    p_IOHIDEventSetIntegerValue =
        (void (*)(FT_IOHIDEventRef, uint32_t, int64_t))dlsym(handle, "IOHIDEventSetIntegerValue");
    // v1.0.64：float 字段设置 + 事件类型读取（筛选 digitizer 事件）
    p_IOHIDEventSetFloatValue =
        (void (*)(FT_IOHIDEventRef, uint32_t, double))dlsym(handle, "IOHIDEventSetFloatValue");
    p_IOHIDEventGetType =
        (uint32_t (*)(FT_IOHIDEventRef))dlsym(handle, "IOHIDEventGetType");
    p_IOHIDEventGetSenderID =
        (uint64_t (*)(FT_IOHIDEventRef))dlsym(handle, "IOHIDEventGetSenderID");
    p_IOHIDEventCreateDigitizerFingerEvent =
        (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                              double, double, double, double, double, Boolean, Boolean,
                              FT_IOOptionBits))
        dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    p_IOHIDEventAppendEvent =
        (void (*)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits))dlsym(handle, "IOHIDEventAppendEvent");

    g_hidLoaded = (p_IOHIDEventCreateDigitizerEvent &&
                   p_IOHIDEventSystemClientCreate &&
                   p_IOHIDEventSystemClientDispatchEvent &&
                   p_IOHIDEventSetSenderID &&
                   p_IOHIDEventSetFloatValue &&
                   p_IOHIDEventGetType &&
                   p_IOHIDEventGetSenderID);
    if (!g_hidLoaded) {
        syslog(LOG_ERR, "FloatingTap HID symbol load failed");
    }
    return g_hidLoaded;
}

// MARK: - 连接

bool FT_HIDConnect(void) {
    if (g_hidClient) return true;
    if (!FT_HIDLoadSymbols()) {
        FTHIDLog("HID connect failed: symbols");
        return false;
    }
    g_hidClient = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_hidClient) {
        FTHIDLog("HID connect failed: client create NULL");
        return false;
    }
    // v1.0.64：不再设置 client 级 senderID——zxtouch 经验是只设事件的 senderID，
    // client 设错误的 senderID 反而导致 DispatchEvent 返回 0x1（系统拒绝）。
    // 部分 iOS 版本需要 client 挂 runloop 才会真正派发事件（符号存在则挂，失败无害）
    if (p_IOHIDEventSystemClientScheduleWithRunLoop) {
        p_IOHIDEventSystemClientScheduleWithRunLoop(g_hidClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
    char dbg[128];
    snprintf(dbg, sizeof(dbg), "HID connected (senderID=0x%llx override=%d)",
             (unsigned long long)FT_HIDSenderID(), g_OverrideSenderID ? 1 : 0);
    FTHIDLog(dbg);
    return true;
}

bool FT_HIDIsConnected(void) {
    return g_hidClient != NULL;
}

// MARK: - 诊断日志（写文件，Filza 可见；与 Tweak.xm 的 FTLog 共用文件）

static void FTHIDLog(const char *msg) {
    FILE *f = fopen("/tmp/floatingtap_ctor.log", "a");
    if (f) {
        fprintf(f, "%s\n", msg);
        fclose(f);
    }
}

// MARK: - senderID（v1.0.53：移除 IOHID 事件回调捕获——arm64e SB 注册回调
// 是 Safe Mode 元凶，实测两次崩；直接用 zxtouch 社区通用硬编码兜底值）

uint64_t FT_HIDSenderID(void) {
    if (g_OverrideSenderID) return g_OverrideSenderID;
    return 0x8000000817371935ULL;
}

// v1.0.63：由 Tweak.xm 从真实触摸事件的 _hidEvent 读到的设备 senderID 写入，
// 覆盖硬编码值，使系统认领合成事件。
void FT_HIDSetSenderID(uint64_t sid) {
    if (sid) g_OverrideSenderID = sid;
}

// v1.0.63：从 IOHIDEvent 读 senderID（0 表示无效）
uint64_t FT_HIDGetSenderIDFromEvent(FT_IOHIDEventRef event) {
    if (!event) return 0;
    if (!FT_HIDLoadSymbols()) return 0;
    if (!p_IOHIDEventGetSenderID) return 0;
    return (uint64_t)p_IOHIDEventGetSenderID(event);
}

// v1.0.64：从真实触摸 UIEvent 读 _hidEvent 的 senderID 并缓存（放在 .c 文件，
// 绕开 Theos 对 Tweak.xm 的 ARC 限制——object_getInstanceVariable 在 ARC 下被禁用）。
// ⚠️ 关键修正：只接受【真正的 digitizer 触摸事件】(kIOHIDEventTypeDigitizer=11) 的 senderID。
// ctor-10 实测从 _UISystemGestureWindow 抓到 0x1000007b1（手势/翻译事件的非法 senderID），
// 设到事件上导致 DispatchEvent 返回 0x1（系统拒绝）。必须过滤掉非 digitizer 事件。
// Tweak.xm 的 sendEvent: hook 调本函数即可——用户首次真实触摸屏幕后便捕获到设备专属 senderID。
// v1.0.74：改为【候选集】收集——sendEvent 事件流里会出现多个 digitizer senderID
// （主屏 digitizer 与手势/翻译服务的），单独最后值不可靠（ctor-45：0x1000007af 被拒）。
// 每个不同的 digitizer senderID 都收进候选集，派发时逐个尝试。
void FT_HIDCaptureSenderIDFromUIEvent(void *event) {
    if (!event) return;
    if (!FT_HIDLoadSymbols()) return;
    if (!p_IOHIDEventGetSenderID || !p_IOHIDEventGetType) return;
    Ivar hidIvar = class_getInstanceVariable(object_getClass((id)event), "_hidEvent");
    if (!hidIvar) return;
    FT_IOHIDEventRef hid = NULL;
    object_getInstanceVariable((id)event, "_hidEvent", (void **)&hid);
    if (!hid) return;
    // kIOHIDEventTypeDigitizer = 11，只有 digitizer 触摸事件的 senderID 才是候选
    if (p_IOHIDEventGetType(hid) != 11) return;
    uint64_t sid = (uint64_t)p_IOHIDEventGetSenderID(hid);
    if (!sid) return;
    if (g_OverrideSenderID == 0) g_OverrideSenderID = sid; // 首个（连接日志用）
    for (int i = 0; i < g_CapturedSIDCount; i++) {
        if (g_CapturedSIDs[i] == sid) return; // 已有，不重复
    }
    if (g_CapturedSIDCount < 4) {
        g_CapturedSIDs[g_CapturedSIDCount++] = sid;
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "senderID candidate #%d: 0x%llx", g_CapturedSIDCount, (unsigned long long)sid);
        FTHIDLog(dbg);
    }
}

// MARK: - 事件构造

// v1.0.67：彻底修正子事件函数签名（权威来源 SimulateTouch 对系统函数的 hook）。
// 之前 v1.0.66 的 plain finger 事件声明多了一个 minorRadius/majorRadius（15 参，应为 13 参），
// 导致 range/touch 落到错误栈槽 → 事件在 ABI 层面畸形 → DispatchEvent 0x1（连硬编码 senderID 也失败）。
// 现严格按 13 参签名构造（ZXTouch 验证可用），并补齐父事件 Range/Touch 字段（对齐 ZXTouch）。
FT_IOHIDEventRef FT_HIDCreateDigitizerEvent(bool down, double x, double y, uint32_t index) {
    if (!FT_HIDLoadSymbols()) return NULL;
    if (!p_IOHIDEventCreateDigitizerEvent ||
        !p_IOHIDEventCreateDigitizerFingerEvent ||
        !p_IOHIDEventAppendEvent) {
        FTHIDLog("parent-child symbols missing");
        return NULL;
    }
    uint64_t ts = mach_absolute_time();
    uint32_t mask = down
        ? (FT_kIOHIDDigitizerEventRange | FT_kIOHIDDigitizerEventTouch | FT_kIOHIDDigitizerEventPosition)
        : (FT_kIOHIDDigitizerEventTouch | FT_kIOHIDDigitizerEventPosition); // up: range=0
    Boolean range = down ? 1 : 0;
    Boolean touch = down ? 1 : 0;

    // 子事件（finger）：13 参签名（无 buttonMask / minorRadius / majorRadius）。
    // 坐标 x,y 归一化 0~1 按位置参数传入（ZXTouch 验证：x/screenW, y/screenH）。
    FT_IOHIDEventRef child = p_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        index, 3,                      // index（finger id）, identity(3=finger transducer)
        mask,                         // eventMask
        x, y, 0.0,                     // x, y（归一化）, z
        0.0, 0.0,                      // tipPressure, twist
        range, touch, 0);              // range, touch, options
    if (!child) return NULL;
    if (p_IOHIDEventSetFloatValue) {
        // 字段常量再写一遍（iOS 15 SDK 布局，与 ZXTouch 验证实现一致）：
        // MajorRadius=0x0B0014 / MinorRadius=0x0B0015（模拟手指接触面积 0.04），X=0x0B000D, Y=0x0B000E
        p_IOHIDEventSetFloatValue(child, 0x0B0014, 0.04);
        p_IOHIDEventSetFloatValue(child, 0x0B0015, 0.04);
        p_IOHIDEventSetFloatValue(child, 0x0B000D, x);
        p_IOHIDEventSetFloatValue(child, 0x0B000E, y);
    }
    if (p_IOHIDEventSetIntegerValue) {
        // v1.0.76 关键：kIOHIDEventFieldDigitizerIsDisplayIntegrated(0x0B0005)=1——
        // 标记为「内置屏幕集成 digitizer」的真实触摸。缺失时系统可能把合成事件当
        // 外接设备/Apple Pencil 悬停触摸：App 收不到 touchesBegan（计数器 0 点击、
        // Notes 只显示笔点而不落墨）——ctor-47 实测。v1.0.24/25 曾设过，重构时丢失。
        p_IOHIDEventSetIntegerValue(child, 0x0B0005, 1);
    }

    // 父事件（digitizer hand）：15 参签名（含 buttonMask，位于 eventMask 之后、x 之前）。
    FT_IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts,
        3,                             // kIOHIDDigitizerTransducerTypeHand
        0, 1,                          // index（hand=0）, identity
        0, 0,                          // eventMask, buttonMask（由子事件体现）
        0.0, 0.0, 0.0,                 // x, y, z
        0.0, 0.0,                      // tipPressure, barrelPressure
        0, 0, 0);                      // range, touch, options
    if (!parent) {
        CFRelease(child);
        return NULL;
    }
    if (p_IOHIDEventSetIntegerValue) {
        // ZXTouch 验证生效的关键字段：
        //   IsDisplayIntegrated(0x0B0005)=1 → 内置屏幕集成触摸（v1.0.76 补回，防被当悬停/外接）
        //   Identity(0x0B0019)=1 + Type(0x4)=1 → 认作真实屏幕集成触摸
        //   EventMask(0x0B0007)=0x23 → 父事件 composite touch state
        //   Range(0x0B0006)=1 + Touch(0x0B0008)=1 → 接触状态（与子事件一致）
        p_IOHIDEventSetIntegerValue(parent, 0x0B0005, 1); // IsDisplayIntegrated
        p_IOHIDEventSetIntegerValue(parent, 0x0B0019, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x4, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0007, 0x23);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0006, 1); // Range
        p_IOHIDEventSetIntegerValue(parent, 0x0B0008, 1); // Touch
    }

    p_IOHIDEventAppendEvent(parent, child, 0);
    CFRelease(child);

    // senderID 由 FT_DispatchEvent 设置（优先捕获到的真实设备值，失败自动回退硬编码）
    return parent;
}

static void FT_DispatchEvent(FT_IOHIDEventRef event, double nx, double ny, uint32_t index, bool down) {
    if (!event || !g_hidClient) { if (event) CFRelease(event); return; }
    // v1.0.74：候选 senderID 逐个尝试——优先已验证可用的 g_WorkingSID，其次所有捕获候选，
    // 最后社区通用硬编码兜底。每个候选用【全新事件】派发（首次派发会消耗/失效原 event ref，
    // 同一 ref 二次派发必 0x1，ctor-40 隐藏坑）。首个成功即锁定 g_WorkingSID，后续直接用它。
    uint64_t cands[6];
    int nc = 0;
    if (g_WorkingSID) cands[nc++] = g_WorkingSID;
    for (int i = 0; i < g_CapturedSIDCount && nc < 5; i++) cands[nc++] = g_CapturedSIDs[i];
    cands[nc++] = 0x8000000817371935ULL; // 社区通用兜底（kIOHIDEventDigitizerSenderID）
    for (int i = 0; i < nc; i++) {
        FT_IOHIDEventRef ev = (i == 0) ? event : FT_HIDCreateDigitizerEvent(down, nx, ny, index);
        if (!ev) { if (i == 0 && event) CFRelease(event); continue; }
        p_IOHIDEventSetSenderID(ev, cands[i]);
        FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_hidClient, ev);
        if (ret == FT_kIOReturnSuccess) {
            g_WorkingSID = cands[i];
            // 成功只打一次（避免 10ms 连点每发一条把日志刷爆；失败照常全打）
            static bool sDidLogOk = false;
            if (!sDidLogOk) {
                sDidLogOk = true;
                char dbg[96];
                snprintf(dbg, sizeof(dbg), "DispatchEvent ok SID=0x%llx", (unsigned long long)cands[i]);
                FTHIDLog(dbg);
            }
            if (ev != event) CFRelease(ev); else CFRelease(event);
            return;
        }
        if (ev != event) CFRelease(ev); else CFRelease(event);
    }
    // 全部候选都失败：只打一次摘要（避免 10ms 连点刷爆日志）
    static bool sDidLogFail = false;
    if (!sDidLogFail) {
        sDidLogFail = true;
        char dbg[192];
        int off = snprintf(dbg, sizeof(dbg), "DispatchEvent all failed (%d candidates):", nc);
        for (int k = 0; k < nc && off < (int)sizeof(dbg) - 24; k++) {
            off += snprintf(dbg + off, sizeof(dbg) - (size_t)off, " 0x%llx", (unsigned long long)cands[k]);
        }
        FTHIDLog(dbg);
    }
}

// MARK: - 对外接口

void FT_HIDTapAt(double normalizedX, double normalizedY) {
    if (!g_hidClient) return;
    FT_HIDDispatchDown(normalizedX, normalizedY, 1);
    FT_HIDDispatchUp(normalizedX, normalizedY, 1);
}

// v1.0.62：down/up 单独派发到系统 HID 服务（供 Tweak.xm 的 down-now/up-延迟 模式复用）。
// 关键：走 IOHIDEventSystemClientDispatchEvent，事件由系统路由到前台 App，
// 而不是 SpringBoard 的 _handleHIDEvent:（那只能喂 SB 自身 UI，App 收不到）。
void FT_HIDDispatchDown(double normalizedX, double normalizedY, uint32_t index) {
    if (!FT_HIDConnect()) {
        syslog(LOG_ERR, "FloatingTap HID dispatch down: not connected");
        return;
    }
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(true, normalizedX, normalizedY, index),
                     normalizedX, normalizedY, index, true);
}

void FT_HIDDispatchUp(double normalizedX, double normalizedY, uint32_t index) {
    if (!FT_HIDConnect()) {
        syslog(LOG_ERR, "FloatingTap HID dispatch up: not connected");
        return;
    }
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(false, normalizedX, normalizedY, index),
                     normalizedX, normalizedY, index, false);
}

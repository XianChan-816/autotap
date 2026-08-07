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
// v1.0.79：IOHID 服务枚举——sendEvent 管线里的 senderID 是"翻译后"的（全被拒 0x1，
// ctor-49/52 实测 0x100000709/7af/251 全 0x1），系统真正接受的 digitizer 服务 senderID
// （ctor-39 的 0x1000007ad）只能直接从服务枚举拿。
static CFArrayRef (*p_IOHIDEventSystemClientCopyServices)(FT_IOHIDEventSystemClientRef);
static CFTypeRef  (*p_IOHIDServiceClientCopyProperty)(FT_IOHIDServiceRef, CFStringRef);
// v1.0.83：IOHIDServiceClientGetRegistryID——直接返回服务的 registryID（独立 API，非属性），
// 很可能是系统接受的 digitizer senderID（ctor-39 的 0x1000007ad 就是 registryID 形态）。
// v1.0.79 只用 CopyProperty 读 "SenderID"/"RegistryID"/"RegistryEntryID" 属性全 nil（ctor-53
// 实测 165 services 零条 service SID），必须改用 GetRegistryID。
static uint64_t (*p_IOHIDServiceClientGetRegistryID)(FT_IOHIDServiceRef);

// MARK: - 状态

static FT_IOHIDEventSystemClientRef g_hidClient = NULL;
static bool g_hidLoaded = false;
// v1.0.63：动态捕获的真实设备 senderID（0 表示未捕获，用兜底硬编码）
static uint64_t g_OverrideSenderID = 0;
// v1.0.74：sendEvent 里会出现【多个】digitizer senderID（主屏 digitizer / 手势翻译服务等），
// 最后一个捕获值不一定是系统认领的那个（ctor-45 实测 0x1000007af 被拒、ctor-39 的 0x1000007ad 可用）。
// 改为收集候选集，派发时逐个尝试，首个成功即锁定为 g_WorkingSID。
// v1.0.77：候选上限 4→8（不设 type==11 过滤，任何事件出现的 senderID 都收，扩大命中面）。
// v1.0.79：上限 8→12（服务枚举会加入多个 digitizer 服务的 SID）。
static uint64_t g_CapturedSIDs[12] = {0};
static int      g_CapturedSIDCount = 0;
static uint64_t g_WorkingSID = 0;   // 已验证可用（ret=0）的 senderID（锁定后优先使用）
// v1.0.84 教训（ctor-57）：服务枚举的 digitizer registryID（0x8de4/0x9114... 形态）不是
// 系统接受的 senderID——用它派发事件【完全不送达】（日志连点期间无合成触摸、计数器零点击）。
// sendEvent 捕获的 0x1000007xx（「翻译后」ID）虽然 ret=0x1（假阴性）但事件实际送达、点击有效。
// → 首选必须是 captured[0]（sendEvent 捕获值）；registryID 只入候选不做首选。

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
    // v1.0.79：服务枚举符号（可选，缺了不影响主流程）
    p_IOHIDEventSystemClientCopyServices =
        (CFArrayRef (*)(FT_IOHIDEventSystemClientRef))dlsym(handle, "IOHIDEventSystemClientCopyServices");
    p_IOHIDServiceClientCopyProperty =
        (CFTypeRef (*)(FT_IOHIDServiceRef, CFStringRef))dlsym(handle, "IOHIDServiceClientCopyProperty");
    // v1.0.83：GetRegistryID 独立 API（非属性）
    p_IOHIDServiceClientGetRegistryID =
        (uint64_t (*)(FT_IOHIDServiceRef))dlsym(handle, "IOHIDServiceClientGetRegistryID");

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

// v1.0.79：枚举 IOHID 系统服务，把服务的 senderID（SenderID / RegistryID 属性）收进候选集。
// sendEvent 事件流的 senderID 是翻译后的（全 0x1 被拒），系统真正接受的 digitizer 服务
// senderID 只能从这里拿。失败无害（无候选就仍用 sendEvent 捕获的）。
// v1.0.83：属性键（SenderID/RegistryID/RegistryEntryID）在 ctor-53 实测全 nil（165 服务零命中）
// → 改用独立 API IOHIDServiceClientGetRegistryID；并用 PrimaryUsagePage 过滤 digitizer 服务
// （HID Usage Page 0x0D = Digitizers），只有 digitizer 服务的 registryID 才收（避免 165 个
// 无关服务的 ID 污染候选集）。
static void FT_HIDEnumerateServices(void) {
    if (!g_hidClient) return;
    if (!p_IOHIDEventSystemClientCopyServices) {
        FTHIDLog("service enum: symbols missing");
        return;
    }
    CFArrayRef arr = p_IOHIDEventSystemClientCopyServices(g_hidClient);
    if (!arr) { FTHIDLog("service enum: none"); return; }
    CFIndex n = CFArrayGetCount(arr);
    char dbg[128];
    snprintf(dbg, sizeof(dbg), "service enum: %ld services", (long)n);
    FTHIDLog(dbg);
    // 先试属性键（旧路径，能读到最好）；PrimaryUsagePage 用于识别 digitizer 服务
    const char *propKeys[4] = { "SenderID", "RegistryID", "RegistryEntryID", "PrimaryUsagePage" };
    for (CFIndex i = 0; i < n; i++) {
        FT_IOHIDServiceRef svc = (FT_IOHIDServiceRef)CFArrayGetValueAtIndex(arr, i);
        if (!svc) continue;
        // 过滤 digitizer：PrimaryUsagePage == 0x0D。读不到属性时（旧键全 nil 场景）不拦。
        uint64_t usagePage = 0;
        bool gotUsage = false;
        if (p_IOHIDServiceClientCopyProperty) {
            CFStringRef kp = CFStringCreateWithCString(kCFAllocatorDefault, "PrimaryUsagePage", kCFStringEncodingUTF8);
            if (kp) {
                CFTypeRef vp = p_IOHIDServiceClientCopyProperty(svc, kp);
                CFRelease(kp);
                if (vp) {
                    if (CFGetTypeID(vp) == CFNumberGetTypeID()) {
                        CFNumberGetValue((CFNumberRef)vp, kCFNumberSInt64Type, &usagePage);
                        gotUsage = true;
                    }
                    CFRelease(vp);
                }
            }
        }
        if (gotUsage && usagePage != 0x0D) continue; // 非 digitizer 服务跳过
        // 属性路径（SenderID 等，若有）
        for (int k = 0; k < 3; k++) {
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, propKeys[k], kCFStringEncodingUTF8);
            if (!key) continue;
            CFTypeRef val = p_IOHIDServiceClientCopyProperty ? p_IOHIDServiceClientCopyProperty(svc, key) : NULL;
            CFRelease(key);
            if (!val) continue;
            uint64_t sid = 0;
            if (CFGetTypeID(val) == CFNumberGetTypeID()) {
                CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &sid);
            }
            CFRelease(val);
            if (!sid) continue;
            bool dup = false;
            for (int j = 0; j < g_CapturedSIDCount; j++) {
                if (g_CapturedSIDs[j] == sid) { dup = true; break; }
            }
            if (!dup && g_CapturedSIDCount < 12) {
                g_CapturedSIDs[g_CapturedSIDCount++] = sid;
                snprintf(dbg, sizeof(dbg), "service SID via '%s': 0x%llx", propKeys[k], (unsigned long long)sid);
                FTHIDLog(dbg);
            }
            break; // 该服务取到一个就下一个
        }
        // registryID 路径（v1.0.83）：独立 API。⚠️ v1.0.84 实测（ctor-57）registryID
        // 派发事件【不送达】——只入候选做诊断，不做首选（首选必须 sendEvent 捕获值）。
        if (p_IOHIDServiceClientGetRegistryID) {
            uint64_t rid = p_IOHIDServiceClientGetRegistryID(svc);
            if (rid) {
                bool dup = false;
                for (int j = 0; j < g_CapturedSIDCount; j++) {
                    if (g_CapturedSIDs[j] == rid) { dup = true; break; }
                }
                if (!dup && g_CapturedSIDCount < 12) {
                    g_CapturedSIDs[g_CapturedSIDCount++] = rid;
                    snprintf(dbg, sizeof(dbg), "service SID via RegistryID%s: 0x%llx",
                             gotUsage ? " (digitizer)" : "", (unsigned long long)rid);
                    FTHIDLog(dbg);
                }
            }
        }
    }
    CFRelease(arr);
}

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
    // v1.0.79：枚举服务收 senderID 候选（sendEvent 捕获不到系统接受的 SID）
    FT_HIDEnumerateServices();
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
// 每个不同的 senderID 都收进候选集，派发时逐个尝试。
// v1.0.77：放宽捕获——不过滤 type==11（SB 管线里真实触摸的 _hidEvent 类型未必是 11，
// 严格过滤会漏掉系统真正认领的那个 senderID）；上限 8 个。
void FT_HIDCaptureSenderIDFromUIEvent(void *event) {
    if (!event) return;
    if (!FT_HIDLoadSymbols()) return;
    if (!p_IOHIDEventGetSenderID) return;
    Ivar hidIvar = class_getInstanceVariable(object_getClass((id)event), "_hidEvent");
    if (!hidIvar) return;
    FT_IOHIDEventRef hid = NULL;
    object_getInstanceVariable((id)event, "_hidEvent", (void **)&hid);
    if (!hid) return;
    uint64_t sid = (uint64_t)p_IOHIDEventGetSenderID(hid);
    if (!sid) return;
    if (g_OverrideSenderID == 0) g_OverrideSenderID = sid; // 首个（连接日志用）
    for (int i = 0; i < g_CapturedSIDCount; i++) {
        if (g_CapturedSIDs[i] == sid) return; // 已有，不重复
    }
    if (g_CapturedSIDCount < 12) {
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
// v1.0.77：父事件 index 0→99（ZXTouch 用 99——index=0 会与用户真实手指的 hand(0) 冲突，
//  导致注入结束用户手指 touch ph=3 + 合成触摸被当同一 hand 的悬停）；IsDisplayIntegrated
//  改回 0x0B0017（v1.0.76 误写 0x0B0005；v1.0.64/SimulateTouch 权威值）；子事件显式设
//  EventMask/Range/Touch/Identity 字段（构造函数参数可能不落字段）。
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
        ? (FT_kIOHIDDigitizerEventRange | FT_kIOHIDDigitizerEventTouch | FT_kIOHIDDigitizerEventPosition) // down=0x07
        : FT_kIOHIDDigitizerEventTouch;                                                                  // up=0x02（仅 Touch 状态变更，v1.0.78）
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
        // v1.0.77：显式落子事件字段（构造函数参数未必持久化）：
        //   EventMask(0x0B0007)=mask、Range(0x0B0006)=range、Touch(0x0B0008)=touch、
        //   Identity(0x0B0019)=3(finger)、DisplayIntegrated(0x0B0017)=1（权威值，v1.0.76 误用 0x0B0005）
        p_IOHIDEventSetIntegerValue(child, 0x0B0007, (int64_t)mask);
        p_IOHIDEventSetIntegerValue(child, 0x0B0006, range ? 1 : 0);
        p_IOHIDEventSetIntegerValue(child, 0x0B0008, touch ? 1 : 0);
        p_IOHIDEventSetIntegerValue(child, 0x0B0019, 3);
        p_IOHIDEventSetIntegerValue(child, 0x0B0017, 1); // DisplayIntegrated
    }

    // 父事件（digitizer hand）：15 参签名（含 buttonMask，位于 eventMask 之后、x 之前）。
    // ⚠️ v1.0.77：index 用 99（ZXTouch 值）——合成 hand 与真实 hand(0) 分离，避免冲突。
    FT_IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts,
        3,                             // kIOHIDDigitizerTransducerTypeHand
        99, 1,                         // index（hand=99，勿用 0！）, identity
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
        //   DisplayIntegrated(0x0B0017)=1 → 内置屏幕集成触摸（v1.0.77 权威值修正）
        //   Identity(0x0B0019)=1 + Type(0x4)=1 → 认作真实屏幕集成触摸
        // ⚠️ v1.0.78 关键：Range/Touch/EventMask 必须按 down/up 区分！
        //   旧代码无条件 Range=1/Touch=1 → UP 事件父手仍显示"在触摸"→ 系统认为手指从未抬起
        //   → 长按选中/上下文菜单（ctor-50 实测），且松手后触摸仍挂着。
        p_IOHIDEventSetIntegerValue(parent, 0x0B0017, 1); // DisplayIntegrated（0x0B0017，非 0x0B0005）
        p_IOHIDEventSetIntegerValue(parent, 0x0B0019, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x4, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0007, down ? 0x23 : 0x02); // EventMask: down=composite 0x23, up=Touch 0x02
        p_IOHIDEventSetIntegerValue(parent, 0x0B0006, down ? 1 : 0);      // Range（up=0）
        p_IOHIDEventSetIntegerValue(parent, 0x0B0008, down ? 1 : 0);      // Touch（up=0）← 关键
    }

    p_IOHIDEventAppendEvent(parent, child, 0);
    CFRelease(child);

    // senderID 由 FT_DispatchEvent 设置（优先捕获到的真实设备值，失败自动回退硬编码）
    return parent;
}

// v1.0.83 关键重写：**单次派发**。
// 背景：v1.0.74-82 的「候选 senderID 全循环」（最多 10 个候选、每个重建全新事件再派发）
// 在 10ms 连点下 = 每秒 ~2000 次系统事件注入，严重污染系统触摸/手势状态机——
// 实测后果：连点之后 Home indicator（小白条）上滑手势失效（什么位置都触发、息屏才恢复）。
// 且 ret=0x1 是假阴性（ctor-54 证据：全候选 0x1 但 41 下真实点击照常），循环无收益。
// v1.0.85 首选修正（ctor-57 铁证）：首选必须是 sendEvent 捕获的 captured[0]（0x1000007xx，
// ret=0x1 假阴性但事件实际送达、点击有效）；服务枚举 registryID（0x8de4/0x9114...）派发
// 事件完全不送达（v1.0.84 实测零点击）→ 只留候选。单次派发、不再重建重试。
static void FT_DispatchEvent(FT_IOHIDEventRef event, double nx, double ny, uint32_t index, bool down) {
    (void)nx; (void)ny; (void)index; (void)down;
    if (!event || !g_hidClient) { if (event) CFRelease(event); return; }
    uint64_t sid = g_WorkingSID;
    if (!sid && g_CapturedSIDCount > 0) sid = g_CapturedSIDs[0];
    if (!sid) sid = 0x1000007adULL;
    p_IOHIDEventSetSenderID(event, sid);
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_hidClient, event);
    if (ret == FT_kIOReturnSuccess && !g_WorkingSID) {
        g_WorkingSID = sid; // 首次 ret=0 锁定（后续直用）
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "DispatchEvent ok SID=0x%llx", (unsigned long long)sid);
        FTHIDLog(dbg);
    } else if (ret != FT_kIOReturnSuccess) {
        // 失败也节流打一条（0x1 假阴性，仅诊断用；不打会丢失排查线索）
        static int sFailLog = 0;
        if ((sFailLog++ % 200) == 0) {
            char dbg[96];
            snprintf(dbg, sizeof(dbg), "dispatch SID=0x%llx ret=0x%x", (unsigned long long)sid, (unsigned)ret);
            FTHIDLog(dbg);
        }
    }
    CFRelease(event);
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

// v1.0.83：连点停止时「抬全手」——派发一个 hand-only up 事件
// （parent: hand index=99, Range=0/Touch=0, EventMask=0x02，无子事件），尝试抬起合成 hand。
// ⚠️ v1.0.87 回归（ctor-59 铁证）：v1.0.85 改为派发 8 个【正常 up 事件】（index 1~8、
// 屏幕中心 0.5,0.5）后，用户所有 App 全部收不到点击（备忘录无笔点、计数器不计数、
// 桌面无反应）——SEND 日志显示合成触摸只到 SB 手势窗口、不透传到前台 App；
// 而 v1.0.83 用 parent-only（ret=0x2cf4000 失败但无害）时点击有效（计数器 41+ 下）。
// 8-up 事件（中心坐标 + 无匹配 down）会破坏系统触摸路由。恢复 parent-only 单事件。
void FT_HIDRaiseAllSyntheticUp(void) {
    if (!g_hidClient) return;
    if (!FT_HIDLoadSymbols()) return;
    if (!p_IOHIDEventCreateDigitizerEvent) return;
    uint64_t ts = mach_absolute_time();
    // 15 参签名：alloc, ts, type=Hand(3), index=99, identity=1, eventMask=0, buttonMask=0,
    // x=0, y=0, z=0, tipPressure=0, barrelPressure=0, range=0, touch=0, options=0
    FT_IOHIDEventRef ev = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts,
        3, 99, 1,
        0, 0,
        0.0, 0.0, 0.0,
        0.0, 0.0,
        0, 0, 0);
    if (!ev) return;
    if (p_IOHIDEventSetIntegerValue) {
        p_IOHIDEventSetIntegerValue(ev, 0x0B0017, 1); // DisplayIntegrated
        p_IOHIDEventSetIntegerValue(ev, 0x0B0019, 1);
        p_IOHIDEventSetIntegerValue(ev, 0x4, 1);
        p_IOHIDEventSetIntegerValue(ev, 0x0B0007, 0x02); // EventMask = Touch-only（up 态）
        p_IOHIDEventSetIntegerValue(ev, 0x0B0006, 0);    // Range = 0
        p_IOHIDEventSetIntegerValue(ev, 0x0B0008, 0);    // Touch = 0
    }
    uint64_t sid = g_WorkingSID;
    if (!sid && g_CapturedSIDCount > 0) sid = g_CapturedSIDs[0];
    if (!sid) sid = 0x1000007adULL;
    p_IOHIDEventSetSenderID(ev, sid);
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_hidClient, ev);
    CFRelease(ev);
    char dbg[96];
    snprintf(dbg, sizeof(dbg), "hand-up raise all (SID=0x%llx) ret=0x%x", (unsigned long long)sid, (unsigned)ret);
    FTHIDLog(dbg);
}

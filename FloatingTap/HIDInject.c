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
// v1.0.63：client 级 senderID 设置 + 从事件读 senderID（动态捕获真实设备值）
static void (*p_IOHIDEventSystemClientSetSenderID)(FT_IOHIDEventSystemClientRef, uint64_t);
static uint64_t (*p_IOHIDEventGetSenderID)(FT_IOHIDEventRef);
static FT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef,
                                                                  uint64_t timeStamp,
                                                                  uint32_t index,
                                                                  uint32_t identity,
                                                                  uint32_t eventMask,
                                                                  uint32_t buttonMask,
                                                                  double x, double y, double z,
                                                                  double tipPressure,
                                                                  double twist,
                                                                  Boolean range,
                                                                  Boolean touch,
                                                                  FT_IOOptionBits options);
static void (*p_IOHIDEventAppendEvent)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits);

// MARK: - 状态

static FT_IOHIDEventSystemClientRef g_hidClient = NULL;
static bool g_hidLoaded = false;
// v1.0.63：动态捕获的真实设备 senderID（0 表示未捕获，用兜底硬编码）
static uint64_t g_OverrideSenderID = 0;

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
    // v1.0.63：client 级 senderID 设置 + 从事件读 senderID（动态捕获真实设备值）
    p_IOHIDEventSystemClientSetSenderID =
        (void (*)(FT_IOHIDEventSystemClientRef, uint64_t))dlsym(handle, "IOHIDEventSystemClientSetSenderID");
    p_IOHIDEventGetSenderID =
        (uint64_t (*)(FT_IOHIDEventRef))dlsym(handle, "IOHIDEventGetSenderID");
    p_IOHIDEventCreateDigitizerFingerEvent =
        (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                              double, double, double, double, double, Boolean, Boolean, FT_IOOptionBits))
        dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
    p_IOHIDEventAppendEvent =
        (void (*)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits))dlsym(handle, "IOHIDEventAppendEvent");

    g_hidLoaded = (p_IOHIDEventCreateDigitizerEvent &&
                   p_IOHIDEventSystemClientCreate &&
                   p_IOHIDEventSystemClientDispatchEvent &&
                   p_IOHIDEventSetSenderID);
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
    // v1.0.63：client 级 senderID 必须与真实设备一致，否则 iOS 会静默丢弃派发事件。
    // 优先用动态捕获的真实 senderID，兜底硬编码。
    if (p_IOHIDEventSystemClientSetSenderID) {
        p_IOHIDEventSystemClientSetSenderID(g_hidClient, FT_HIDSenderID());
    }
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

// v1.0.63：从真实触摸 UIEvent 读 _hidEvent 的 senderID 并缓存（放在 .c 文件，
// 绕开 Theos 对 Tweak.xm 的 ARC 限制——object_getInstanceVariable 在 ARC 下被禁用）。
// Tweak.xm 的 sendEvent: hook 调本函数即可。持续用真实设备值覆盖硬编码。
void FT_HIDCaptureSenderIDFromUIEvent(void *event) {
    if (!event) return;
    if (!FT_HIDLoadSymbols()) return;
    if (!p_IOHIDEventGetSenderID) return;
    Ivar hidIvar = class_getInstanceVariable(object_getClass((id)event), "_hidEvent");
    if (!hidIvar) return;
    FT_IOHIDEventRef hid = NULL;
    object_getInstanceVariable((id)event, "_hidEvent", (void **)&hid);
    if (hid) {
        uint64_t sid = (uint64_t)p_IOHIDEventGetSenderID(hid);
        if (sid) g_OverrideSenderID = sid;
    }
}

// MARK: - 事件构造

// v1.0.40: 父+子事件结构（zxtouch 原版）——digitizer(hand) 父事件 + finger 子事件 +
// IOHIDEventAppendEvent 组合。v1.0.24~39 用单事件结构（缺 finger 子事件），
// iOS 15 系统可能要求完整事件树。配合 v1.0.37 的 15 参数修正 + v1.0.38 的真实
// senderID，这是最后未验证的组合。
// - parent: IOHIDEventCreateDigitizerEvent(alloc, ts, Hand(3), index, identity, mask, 0, x,y,z, tip, 0, range, touch, 0)
// - child:  IOHIDEventCreateDigitizerFingerEvent(alloc, ts, index, identity, mask, 0, x,y,z, tip, 0, range, touch, 0)
// - IOHIDEventAppendEvent(parent, child, 0)
FT_IOHIDEventRef FT_HIDCreateDigitizerEvent(bool down, double x, double y, uint32_t index) {
    if (!FT_HIDLoadSymbols()) return NULL;
    if (!p_IOHIDEventCreateDigitizerEvent || !p_IOHIDEventCreateDigitizerFingerEvent ||
        !p_IOHIDEventAppendEvent) {
        FTHIDLog("parent-child symbols missing");
        return NULL;
    }
    uint64_t ts = mach_absolute_time();
    uint32_t mask = down
        ? (FT_kIOHIDDigitizerEventRange | FT_kIOHIDDigitizerEventTouch |
           FT_kIOHIDDigitizerEventPosition)
        : (FT_kIOHIDDigitizerEventRange);

    // 子事件（finger）
    FT_IOHIDEventRef child = p_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts,
        index, 1,                      // index（每次 tap 递增）, identity
        mask, 0,                       // eventMask, buttonMask
        x, y, 0.0,                     // x, y, z（归一化）
        down ? 1.0 : 0.0,              // tipPressure
        0.0,                           // twist
        true, down,                    // range, touch
        0);                            // options
    if (!child) return NULL;

    // 父事件（digitizer hand）
    FT_IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts,
        3,                             // kIOHIDDigitizerTransducerTypeHand
        index,                         // index（每次 tap 递增，避免被串流）
        1,                             // identity
        mask, 0,                       // eventMask, buttonMask
        x, y, 0.0,                     // x, y, z（归一化）
        down ? 1.0 : 0.0,              // tipPressure
        0.0,                           // barrelPressure
        true, down,                    // range, touch
        0);                            // options
    if (!parent) {
        CFRelease(child);
        return NULL;
    }

    p_IOHIDEventAppendEvent(parent, child, 0);
    CFRelease(child);

    if (p_IOHIDEventSetIntegerValue) {
        // kIOHIDEventFieldDigitizerIndex = 0x0B0002
        p_IOHIDEventSetIntegerValue(parent, 0x0B0002, (int64_t)index);
        // kIOHIDEventFieldDigitizerIdentity = 0x0B0003
        p_IOHIDEventSetIntegerValue(parent, 0x0B0003, 1);
        // kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0x0B0014 —— 屏幕集成触摸标记
        p_IOHIDEventSetIntegerValue(parent, 0x0B0014, 1);
    }
    // senderID：优先用捕获的设备专属值（zxtouch 机制），兜底硬编码
    if (p_IOHIDEventSetSenderID) {
        p_IOHIDEventSetSenderID(parent, FT_HIDSenderID());
    }
    return parent;
}

static void FT_DispatchEvent(FT_IOHIDEventRef event) {
    if (!event || !g_hidClient) return;
    p_IOHIDEventSetSenderID(event, FT_HIDSenderID());
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_hidClient, event);
    if (ret != FT_kIOReturnSuccess) {
        syslog(LOG_ERR, "FloatingTap DispatchEvent failed 0x%x", (unsigned)ret);
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "DispatchEvent failed 0x%x", (unsigned)ret);
        FTHIDLog(dbg);
    }
    CFRelease(event);
}

// MARK: - 对外接口

void FT_HIDTapAt(double normalizedX, double normalizedY) {
    if (!g_hidClient) return;
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(true, normalizedX, normalizedY, 1));
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(false, normalizedX, normalizedY, 1));
}

// v1.0.62：down/up 单独派发到系统 HID 服务（供 Tweak.xm 的 down-now/up-延迟 模式复用）。
// 关键：走 IOHIDEventSystemClientDispatchEvent，事件由系统路由到前台 App，
// 而不是 SpringBoard 的 _handleHIDEvent:（那只能喂 SB 自身 UI，App 收不到）。
void FT_HIDDispatchDown(double normalizedX, double normalizedY, uint32_t index) {
    if (!FT_HIDConnect()) {
        syslog(LOG_ERR, "FloatingTap HID dispatch down: not connected");
        return;
    }
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(true, normalizedX, normalizedY, index));
}

void FT_HIDDispatchUp(double normalizedX, double normalizedY, uint32_t index) {
    if (!FT_HIDConnect()) {
        syslog(LOG_ERR, "FloatingTap HID dispatch up: not connected");
        return;
    }
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(false, normalizedX, normalizedY, index));
}

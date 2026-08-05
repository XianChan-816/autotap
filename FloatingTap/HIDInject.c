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

// MARK: - 私有类型与常量（本地前缀，避免与 SDK IOKit 头冲突）

typedef struct __IOHIDEvent * FT_IOHIDEventRef;
typedef struct __IOHIDEventSystemClient * FT_IOHIDEventSystemClientRef;
typedef struct __IOHIDService * FT_IOHIDServiceRef;
typedef int32_t FT_IOReturn;
typedef uint32_t FT_IOOptionBits;
static const FT_IOReturn FT_kIOReturnSuccess = 0;

typedef void (*FT_IOHIDSystemCallback)(void *target, void *refcon,
                                       FT_IOHIDServiceRef service,
                                       FT_IOHIDEventRef event);

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
static void (*p_IOHIDEventSystemClientSetDispatchQueue)(FT_IOHIDEventSystemClientRef, dispatch_queue_t);
static void (*p_IOHIDEventSetSenderID)(FT_IOHIDEventRef, uint64_t);
static void (*p_IOHIDEventSetIntegerValue)(FT_IOHIDEventRef, uint32_t, int64_t);

// MARK: - 状态

static FT_IOHIDEventSystemClientRef g_hidClient = NULL;
static bool g_hidLoaded = false;

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
    p_IOHIDEventSystemClientSetDispatchQueue =
        (void (*)(FT_IOHIDEventSystemClientRef, dispatch_queue_t))dlsym(handle, "IOHIDEventSystemClientSetDispatchQueue");
    p_IOHIDEventSetSenderID =
        (void (*)(FT_IOHIDEventRef, uint64_t))dlsym(handle, "IOHIDEventSetSenderID");
    p_IOHIDEventSetIntegerValue =
        (void (*)(FT_IOHIDEventRef, uint32_t, int64_t))dlsym(handle, "IOHIDEventSetIntegerValue");

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
    if (!FT_HIDLoadSymbols()) return false;
    g_hidClient = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_hidClient) {
        syslog(LOG_ERR, "FloatingTap HID client create failed");
        return false;
    }
    // 部分 iOS 版本需要 client 挂 runloop/dispatch queue 才会真正派发事件（符号存在则挂，失败无害）
    if (p_IOHIDEventSystemClientScheduleWithRunLoop) {
        p_IOHIDEventSystemClientScheduleWithRunLoop(g_hidClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
    if (p_IOHIDEventSystemClientSetDispatchQueue) {
        p_IOHIDEventSystemClientSetDispatchQueue(g_hidClient, dispatch_get_main_queue());
    }
    syslog(LOG_ERR, "FloatingTap HID connected");
    return true;
}

bool FT_HIDIsConnected(void) {
    return g_hidClient != NULL;
}

// MARK: - 事件构造

static uint64_t FT_SenderID(void) {
    return 0x8000000817371935ULL;
}

// 经典单事件写法（zxtouch/autotouch 在 iOS 13-16 验证有效）：
// - type 参数必须是转换器类型 kIOHIDDigitizerTransducerTypeHand(3)，不是事件类型(11)；
// - index=1（zxtouch 用 1 不是 0），identity=1；
// - down eventMask 用 Range|Touch|Position（zxtouch 不加 Tip|Identity）；
// - 坐标直传事件本体（归一化 0~1）；时间戳 mach_absolute_time() 原始值；
// - 关键：IOHIDEventSetIntegerValue(isDisplayIntegrated=1, index=1, identity=1)，
//   否则系统可能丢弃合成触摸。
// 导出供 Tweak.xm 塞入 UIEvent._hidEvent（绕开 IOKit 分发层）。
FT_IOHIDEventRef FT_HIDCreateDigitizerEvent(bool down, double x, double y) {
    // v1.0.35: 必须先确保 dlsym 符号已加载（v1.0.30 起 FT_HIDConnect 不再被调用，
    // 符号加载被跳过导致函数指针全 NULL → 事件构造失败）
    if (!FT_HIDLoadSymbols()) return NULL;
    if (!p_IOHIDEventCreateDigitizerEvent) return NULL;
    uint32_t mask = down
        ? (FT_kIOHIDDigitizerEventRange | FT_kIOHIDDigitizerEventTouch |
           FT_kIOHIDDigitizerEventPosition)
        : (FT_kIOHIDDigitizerEventRange);

    FT_IOHIDEventRef event = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        mach_absolute_time(),          // 原始 tick，不做纳秒换算
        3,                             // kIOHIDDigitizerTransducerTypeHand
        1,                             // index
        1,                             // identity
        mask,                          // eventMask
        0,                             // buttonMask
        x, y, 0.0,                     // x, y, z（归一化 0~1）
        down ? 1.0 : 0.0,              // tipPressure
        0.0,                           // barrelPressure
        true,                          // range
        down,                          // touch
        0);                            // options

    if (event && p_IOHIDEventSetIntegerValue) {
        // kIOHIDEventFieldDigitizerIndex = 0x0B0002
        p_IOHIDEventSetIntegerValue(event, 0x0B0002, 1);
        // kIOHIDEventFieldDigitizerIdentity = 0x0B0003
        p_IOHIDEventSetIntegerValue(event, 0x0B0003, 1);
        // kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0x0B0014 —— 屏幕集成触摸标记
        p_IOHIDEventSetIntegerValue(event, 0x0B0014, 1);
    }
    return event;
}

static void FT_DispatchEvent(FT_IOHIDEventRef event) {
    if (!event || !g_hidClient) return;
    p_IOHIDEventSetSenderID(event, FT_SenderID());
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_hidClient, event);
    if (ret != FT_kIOReturnSuccess) {
        syslog(LOG_ERR, "FloatingTap DispatchEvent failed 0x%x", (unsigned)ret);
    }
    CFRelease(event);
}

// MARK: - 对外接口

void FT_HIDTapAt(double normalizedX, double normalizedY) {
    if (!g_hidClient) return;
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(true, normalizedX, normalizedY));
    FT_DispatchEvent(FT_HIDCreateDigitizerEvent(false, normalizedX, normalizedY));
}

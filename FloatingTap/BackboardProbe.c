//
//  BackboardProbe.c — 最小原型：在 backboardd 进程内注入 IOHID 触摸事件
//
//  目的（验证佳影技术路线）：backboardd 是系统触摸事件分发的源头进程。
//  在 backboardd 内部创建并派发 digitizer 事件，与真实触摸走同一条内部管线，
//  可能【不触发「未知设备上下文重置」】→ 不顶掉用户手指 → 不需要 SID 探测。
//  本文件只做一件事：每 3 秒注入一次 tap（down + 45ms up），验证两件事：
//    1. SB 的 sendEvent 能收到注入的合成触摸（送达）；
//    2. 用户按住屏幕期间注入【不顶掉】用户手指（核心验证目标）。
//
//  ⚠️ 纯 C 铁律（arm64e PAC）：无 @implementation / @"..." / block / @selector。
//  日志写 /tmp/backboard_probe.log（SB 侧 FloatingTap 日志在 /tmp/floatingtap_ctor.log，
//  两个日志都看：本文件显示注入执行，SB 日志显示是否送达/是否顶掉）。
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <syslog.h>
#include <time.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

// MARK: - 私有 IOHID 类型与函数指针

typedef struct __IOHIDEvent * FT_IOHIDEventRef;
typedef struct __IOHIDEventSystemClient * FT_IOHIDEventSystemClientRef;
typedef int32_t FT_IOReturn;
typedef uint32_t FT_IOOptionBits;
static const FT_IOReturn FT_kIOReturnSuccess = 0;

static FT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef,
                                                            uint64_t, uint32_t, uint32_t, uint32_t,
                                                            uint32_t, uint32_t, double, double, double,
                                                            double, double, Boolean, Boolean,
                                                            FT_IOOptionBits);
static FT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, Boolean, Boolean, FT_IOOptionBits);
static FT_IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static FT_IOReturn (*p_IOHIDEventSystemClientDispatchEvent)(FT_IOHIDEventSystemClientRef, FT_IOHIDEventRef);
static void (*p_IOHIDEventSetSenderID)(FT_IOHIDEventRef, uint64_t);
static void (*p_IOHIDEventSetIntegerValue)(FT_IOHIDEventRef, uint32_t, int64_t);
static void (*p_IOHIDEventSetFloatValue)(FT_IOHIDEventRef, uint32_t, double);
static void (*p_IOHIDEventAppendEvent)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits);

static FT_IOHIDEventSystemClientRef g_client = NULL;
static bool g_loaded = false;

// MARK: - 日志

static void BP_Log(const char *msg) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    char line[256];
    snprintf(line, sizeof(line), "[%.1f] %s", t, msg);
    FILE *f = fopen("/tmp/backboard_probe.log", "a");
    if (f) { fprintf(f, "%s\n", line); fclose(f); }
    syslog(LOG_ERR, "%s", line);
}

// MARK: - 符号加载

static bool BP_LoadSymbols(void) {
    if (g_loaded) return true;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) h = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!h) { BP_Log("dlopen IOKit failed"); return false; }
    p_IOHIDEventCreateDigitizerEvent =
        (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                              uint32_t, uint32_t, double, double, double, double, double,
                              Boolean, Boolean, FT_IOOptionBits))
        dlsym(h, "IOHIDEventCreateDigitizerEvent");
    p_IOHIDEventCreateDigitizerFingerEvent =
        (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                              double, double, double, double, double, Boolean, Boolean,
                              FT_IOOptionBits))
        dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    p_IOHIDEventSystemClientCreate = (FT_IOHIDEventSystemClientRef (*)(CFAllocatorRef))dlsym(h, "IOHIDEventSystemClientCreate");
    p_IOHIDEventSystemClientDispatchEvent = (FT_IOReturn (*)(FT_IOHIDEventSystemClientRef, FT_IOHIDEventRef))dlsym(h, "IOHIDEventSystemClientDispatchEvent");
    p_IOHIDEventSetSenderID = (void (*)(FT_IOHIDEventRef, uint64_t))dlsym(h, "IOHIDEventSetSenderID");
    p_IOHIDEventSetIntegerValue = (void (*)(FT_IOHIDEventRef, uint32_t, int64_t))dlsym(h, "IOHIDEventSetIntegerValue");
    p_IOHIDEventSetFloatValue = (void (*)(FT_IOHIDEventRef, uint32_t, double))dlsym(h, "IOHIDEventSetFloatValue");
    p_IOHIDEventAppendEvent = (void (*)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits))dlsym(h, "IOHIDEventAppendEvent");
    g_loaded = (p_IOHIDEventCreateDigitizerEvent && p_IOHIDEventCreateDigitizerFingerEvent &&
                p_IOHIDEventSystemClientCreate && p_IOHIDEventSystemClientDispatchEvent &&
                p_IOHIDEventSetSenderID && p_IOHIDEventAppendEvent);
    if (!g_loaded) BP_Log("symbol load failed");
    return g_loaded;
}

// MARK: - 事件构造（与 HIDInject.c 相同的权威结构：15 参 parent + 13 参 child）

static FT_IOHIDEventRef BP_CreateDigitizerEvent(bool down, double x, double y, uint32_t index) {
    if (!g_loaded) return NULL;
    uint64_t ts = mach_absolute_time();
    uint32_t mask = down ? 0x03 : 0x02; // Range|Touch (down) / Touch (up)
    Boolean range = down ? 1 : 0;
    Boolean touch = down ? 1 : 0;

    FT_IOHIDEventRef child = p_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts, index, 3, mask,
        x, y, 0.0, 0.0, 0.0, range, touch, 0);
    if (!child) return NULL;
    if (p_IOHIDEventSetFloatValue) {
        p_IOHIDEventSetFloatValue(child, 0x0B0014, 0.04);
        p_IOHIDEventSetFloatValue(child, 0x0B0015, 0.04);
        p_IOHIDEventSetFloatValue(child, 0x0B000D, x);
        p_IOHIDEventSetFloatValue(child, 0x0B000E, y);
    }
    if (p_IOHIDEventSetIntegerValue) {
        p_IOHIDEventSetIntegerValue(child, 0x0B0007, (int64_t)mask);
        p_IOHIDEventSetIntegerValue(child, 0x0B0006, range ? 1 : 0);
        p_IOHIDEventSetIntegerValue(child, 0x0B0008, touch ? 1 : 0);
        p_IOHIDEventSetIntegerValue(child, 0x0B0019, 3);
        p_IOHIDEventSetIntegerValue(child, 0x0B0017, 1);
    }

    FT_IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, 3, 99, 1, 0, 0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
    if (!parent) { CFRelease(child); return NULL; }
    if (p_IOHIDEventSetIntegerValue) {
        p_IOHIDEventSetIntegerValue(parent, 0x0B0017, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0019, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x4, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0007, down ? 0x23 : 0x02);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0006, down ? 1 : 0);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0008, down ? 1 : 0);
    }
    p_IOHIDEventAppendEvent(parent, child, 0);
    CFRelease(child);
    return parent;
}

static void BP_Dispatch(FT_IOHIDEventRef ev, uint64_t sid) {
    if (!ev || !g_client) { if (ev) CFRelease(ev); return; }
    p_IOHIDEventSetSenderID(ev, sid);
    if (p_IOHIDEventSetIntegerValue) p_IOHIDEventSetIntegerValue(ev, 0x0B0018, (int64_t)sid);
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_client, ev);
    if (ret != FT_kIOReturnSuccess) {
        static int sFail = 0;
        if ((sFail++ % 20) == 0) {
            char dbg[96];
            snprintf(dbg, sizeof(dbg), "dispatch ret=0x%x", (unsigned)ret);
            BP_Log(dbg);
        }
    }
    CFRelease(ev);
}

// MARK: - 注入一次 tap（down + 45ms up）

typedef struct { double x, y; uint32_t idx; uint64_t sid; } BP_TapCtx;
static void BP_UpCB(void *ctx) {
    BP_TapCtx *c = (BP_TapCtx *)ctx;
    if (!c) return;
    FT_IOHIDEventRef u = BP_CreateDigitizerEvent(false, c->x, c->y, c->idx);
    BP_Dispatch(u, c->sid);
    free(c);
}

static void BP_InjectTap(void) {
    if (!g_client) return;
    double nx = 0.5, ny = 0.66; // 屏幕中央偏下（与 FloatingTap 默认点击点一致，便于对照日志）
    uint64_t sid = 0x8000000817371935ULL; // 先试硬编码兜底值
    uint32_t idx = 2;
    FT_IOHIDEventRef d = BP_CreateDigitizerEvent(true, nx, ny, idx);
    BP_Dispatch(d, sid);
    BP_TapCtx *c = (BP_TapCtx *)malloc(sizeof(BP_TapCtx));
    if (c) {
        c->x = nx; c->y = ny; c->idx = idx; c->sid = sid;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.045 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, BP_UpCB);
    }
    static int sCount = 0;
    if ((sCount++ % 5) == 0) {
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "probe tap #%d @(%.2f,%.2f) idx=%u sid=0x%llx", sCount, nx, ny, (unsigned)idx, (unsigned long long)sid);
        BP_Log(dbg);
    }
}

// 周期注入回调（3s 一次）
static void BP_Tick(void *ctx) {
    (void)ctx;
    BP_InjectTap();
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, BP_Tick);
}

// MARK: - 构造入口（backboardd 进程加载时执行）

__attribute__((constructor))
static void BP_Ctor(void) {
    FILE *mk = fopen("/tmp/backboard_probe.log", "w");
    if (mk) { fprintf(mk, "BackboardProbe ctor run (backboardd, arm64e, pure C)\n"); fclose(mk); }
    BP_Log("backboardd probe: loading");
    if (!BP_LoadSymbols()) return;
    g_client = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_client) { BP_Log("client create failed"); return; }
    BP_Log("client created - starting 3s probe loop");
    BP_InjectTap(); // 立即注入一次
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, BP_Tick);
}

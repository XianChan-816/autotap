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
static void (*p_IOHIDEventSetSenderID)(FT_IOHIDEventRef, uint64_t);
static void (*p_IOHIDEventSetIntegerValue)(FT_IOHIDEventRef, uint32_t, int64_t);
// v1.0.64：float 字段设置（坐标/半径），以及读事件类型（用于筛选 digitizer 事件抓 senderID）
static void (*p_IOHIDEventSetFloatValue)(FT_IOHIDEventRef, uint32_t, double);
static uint32_t (*p_IOHIDEventGetType)(FT_IOHIDEventRef);
static uint64_t (*p_IOHIDEventGetSenderID)(FT_IOHIDEventRef);
// v1.0.89 实验：client 级 senderID（v1.0.64 弃用）——设成【真实捕获的设备 senderID】后，
// 系统可能认为本 client 就是真实 digitizer → 注入不被当「未知设备」→ 不触发触摸上下文
// 重置 → 用户按住的手指不再被注入顶掉（Ended）→ 连点可持续（ctor-62：每轮 400ms 就
// hold-release 停，因为注入第一个 down 就把用户手指 Ended 且系统不重发 Began）。
// ⚠️ v1.0.89 结论：该符号 iOS 15.5 不存在（dlsym NULL），无效。v1.0.96 移除符号声明。
// v1.0.92：IOHID 事件回调（纯 C）——从真实触摸的【原始 IOHIDEvent】提取 senderID。
// sendEvent 的 _hidEvent 是"翻译后"事件（0x1000007xx，送达但触发上下文重置 → 顶掉用户
// 手指）；zxtouch 用 IOHID 回调里的原始 senderID（系统真正认领，注入当真实 digitizer →
// 不顶掉）。v1.0.53 注册回调崩过（ObjC/block 实现）；v1.0.92 纯 C 回调在 Dopamine 上
// 只拿到翻译值（ctor-66），v1.0.96 已移除回调（对齐 zxtouch 纯注入 client）。
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
// ⚠️ v1.0.96 定案（ctor-68 重证）：finger index 2-9 避开 index=1 仍顶掉（clicks 13/轮）——
// 顶掉与 finger index 无关。且 v1.0.84 用 registryID 时事件结构还是旧的（child mask 0x07），
// v1.0.90 改 0x03 + v1.0.94 加 0x0B0018 之后【从没重试过 registryID】。registryID 是真实
// digitizer 服务 SID（zxtouch 用的就是真实 SID），可能「送达且不顶掉」。v1.0.96：
//   · g_PrimarySID = 第一个确认 digitizer 的 registryID（真实服务 SID）
//   · 派发 ret≠0 累计 5 次 → 自适应 fallback 到 captured[0]（送达保底，日志标记）
//   · 移除 ScheduleWithRunLoop + RegisterEventCallback（对齐 zxtouch 纯注入 client，
//     回调已验证拿不到原始 SID——Dopamine 上只有翻译值）
static uint64_t g_PrimarySID = 0;    // v1.0.96：首选（digitizer 服务 registryID）
static int      g_PrimarySIDFailCount = 0; // 首选连续失败计数（≥5 → fallback captured）
static bool     g_PrimarySIDFellBack = false;

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
    p_IOHIDEventSetSenderID =
        (void (*)(FT_IOHIDEventRef, uint64_t))dlsym(handle, "IOHIDEventSetSenderID");
    // v1.0.96：Register/UnregisterEventCallback dlsym 已移除（回调路径在 Dopamine 上
    // 拿不到原始 SID，且与纯注入 client 形态冲突）；client 级 SetSenderID 符号
    // iOS 15.5 不存在（v1.0.89 结论），一并移除。
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
        // registryID 路径（v1.0.83）：独立 API。⚠️ v1.0.96：registryID 是【真实 digitizer
        // 服务 SID】（zxtouch 用的就是真实 SID）——v1.0.84 首次试它时事件结构还是旧的
        // （child mask 0x07），v1.0.90 改 0x03 + v1.0.94 加 0x0B0018 后没重试过。
        // 现在重试：第一个确认 digitizer 的 registryID 设为首选（g_PrimarySID），
        // 派发连续失败 ≥5 次自动 fallback 到 captured[0]（送达保底）。
        if (p_IOHIDServiceClientGetRegistryID) {
            uint64_t rid = p_IOHIDServiceClientGetRegistryID(svc);
            if (rid) {
                if (!g_PrimarySID && gotUsage && usagePage == 0x0D) {
                    g_PrimarySID = rid;
                    snprintf(dbg, sizeof(dbg), "primary SID (digitizer service registryID): 0x%llx",
                             (unsigned long long)rid);
                    FTHIDLog(dbg);
                }
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

    // v1.0.96：移除 v1.0.92 的回调提取——ctor-66 实测回调在 Dopamine 上拿到的也是
    // 翻译值 0x100000709（与 sendEvent 捕获一致），无「原始硬件 SID」；且回调需要
    // client 挂 runloop，与 zxtouch 纯注入 client（不挂 runloop）形态冲突，已移除。

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
    // ⚠️ v1.0.89 实验结论：IOHIDEventSystemClientSetSenderID 符号在 iOS 15.5 不存在
    // （dlsym NULL，ctor-63 无 client senderID 日志），该路径无效，已回退。
    // ⚠️ v1.0.96：移除 ScheduleWithRunLoop + RegisterEventCallback——zxtouch 的【事件注入
    // client】是纯创建 + DispatchEvent（不挂 runloop、不注册回调；回调只用于【监控】client）。
    // 我们 v1.0.92 的回调已验证拿不到原始 SID（Dopamine 只有翻译值 0x1000007xx），
    // 挂 runloop 反而让 client 同时成为「监听者」，对齐 zxtouch 纯注入形态再验证。
    // v1.0.79：枚举服务收 senderID 候选（sendEvent 捕获不到系统接受的 SID）
    FT_HIDEnumerateServices();
    char dbg[128];
    snprintf(dbg, sizeof(dbg), "HID connected (senderID=0x%llx override=%d primary=0x%llx)",
             (unsigned long long)FT_HIDSenderID(), g_OverrideSenderID ? 1 : 0,
             (unsigned long long)g_PrimarySID);
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

// ⚠️ v1.0.100 定案（ctor-69/71/72 三会话数据）：**有效 SID = 「普通窗口触摸」的 SID**。
//   · ctor-69：candidate #1=0x100000709（有效，clicks 155 不顶掉）、#2=0x1000007af——同一会话
//     两个 SID，一个是主屏 digitizer（有效），一个是手势服务翻译值（无效）；
//   · ctor-72：user finger SID=0x1000007af（球上 Began 读到）= 手势服务翻译值 → 注入它顶掉；
//   · 结论：球在 _UISystemGestureWindow 里，**球上触摸被手势服务翻译成 0x1000007xx 无效值**；
//     注入必须用【非球上（主屏/App 窗口）触摸】的 SID（0x100000709 类，系统认领、不顶掉）。
//   · 因此 v1.0.98 的 g_UserSID（读球上触摸）方向错误，v1.0.99 的 captured[0] 若来自球上
//     触摸（用户先双击球）也无效。v1.0.100：捕获只认【非球上触摸】→ g_MainSID 首选。
static uint64_t g_MainSID = 0;   // v1.0.100：非球上（主屏/App 窗口）触摸的 SID（有效）
// 从 UIEvent 读 _hidEvent senderID → g_MainSID + 收入候选集（去重）。仅由 Tweak.xm 在
// 【确认该事件不含球上触摸】时调用（纯 C 绕 ARC，object_getInstanceVariable 放 .c）。
void FT_HIDCaptureMainSIDFromUIEvent(void *event) {
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
    if (g_MainSID == 0) {
        g_MainSID = sid;
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "main (non-ball) SID: 0x%llx", (unsigned long long)sid);
        FTHIDLog(dbg);
    }
    if (g_OverrideSenderID == 0) g_OverrideSenderID = sid;
    for (int i = 0; i < g_CapturedSIDCount; i++) {
        if (g_CapturedSIDs[i] == sid) return;
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
    // v1.0.90：child down eventMask 0x07 → 0x03（对齐 zxtouch：Range|Touch）。
    // 0x07 的 Position 位可能让系统把注入当「带移动的手势」→ 触发触摸上下文重置 →
    // 顶掉用户按住球的手指（每轮 400ms 就 hold-release 停的根因）。
    // 坐标位置已由 0x0B000D/E 字段单独设置，mask 无需 Position。
    uint32_t mask = down
        ? (FT_kIOHIDDigitizerEventRange | FT_kIOHIDDigitizerEventTouch) // down=0x03（zxtouch）
        : FT_kIOHIDDigitizerEventTouch;                                 // up=0x02（仅 Touch 状态变更，v1.0.78）
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
// ⚠️ v1.0.94/95 定案（ctor-65 + ctor(12) 双份实测）：
// ⚠️ v1.0.96 定案（ctor-68 重证 finger index 假设失败）：
//   · captured[0]（0x1000007xx 翻译 ID）——【送达】但【顶掉】用户手指（index 2-9 也顶掉，
//     clicks 13/轮 → 顶掉与 finger index 无关，与 SID 属性强相关）；
//   · 0x8000000817371935 + 0x0B0018 ——【不顶掉】但【不送达】→ Dopamine 无解，弃用；
//   · **registryID（真实 digitizer 服务 SID，zxtouch 用真实 SID 注入）从未用最新事件结构
//     重试过**（v1.0.84 首次试时 child mask 还是 0x07）。v1.0.96 首选 g_PrimarySID
//     （第一个确认 digitizer 的 registryID），ret≠0 连续 5 次 → 自适应 fallback captured[0]。
//   · 首选 + fallback 各自【单次派发】（不重建不重试同 ref），保持 v1.0.83 防污染铁律。
static void FT_DispatchEvent(FT_IOHIDEventRef event, double nx, double ny, uint32_t index, bool down) {
    (void)nx; (void)ny; (void)index; (void)down;
    if (!event || !g_hidClient) { if (event) CFRelease(event); return; }
    uint64_t sid;
    if (!g_PrimarySIDFellBack && g_PrimarySID) {
        sid = g_PrimarySID; // registryID（真实服务 SID）——若送达且同源则理想
    } else {
        // v1.0.100：首选【非球上（主屏/App 窗口）触摸 SID】g_MainSID——球上触摸被手势
        // 服务翻译成 0x1000007af 类无效值（注入顶掉用户手指，ctor-72 铁证）；主屏 digitizer
        // SID（0x100000709 类）系统认领、不顶掉（ctor-69 完美）。captured[0] 兜底。
        sid = g_WorkingSID;
        if (!sid && g_MainSID) sid = g_MainSID;
        if (!sid && g_CapturedSIDCount > 0) sid = g_CapturedSIDs[0];
        if (!sid) sid = 0x1000007adULL;
    }
    p_IOHIDEventSetSenderID(event, sid);
    // v1.0.94 保留：digitizer 事件字段里的 SenderID（0x0B0018 = kIOHIDEventFieldDigitizerSenderID）
    // 与顶层一致，让系统按事件字段归属 digitizer（对 registryID 首选尤其关键）。
    if (p_IOHIDEventSetIntegerValue) {
        p_IOHIDEventSetIntegerValue(event, 0x0B0018, (int64_t)sid);
    }
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_hidClient, event);
    if (ret == FT_kIOReturnSuccess && !g_WorkingSID) {
        g_WorkingSID = sid; // 首次 ret=0 锁定（后续直用）
        g_PrimarySIDFailCount = 0;
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "DispatchEvent ok SID=0x%llx", (unsigned long long)sid);
        FTHIDLog(dbg);
    } else if (ret != FT_kIOReturnSuccess) {
        // 首选（registryID）连续失败 → 自适应 fallback 到 captured[0]（送达保底）
        if (!g_PrimarySIDFellBack && g_PrimarySID && sid == g_PrimarySID) {
            if (++g_PrimarySIDFailCount >= 5) {
                g_PrimarySIDFellBack = true;
                char dbg[96];
                snprintf(dbg, sizeof(dbg), "SID fallback: registryID %d fails -> captured",
                         g_PrimarySIDFailCount);
                FTHIDLog(dbg);
            }
        }
        // 失败节流打一条（0x1 假阴性，仅诊断用；不打会丢失排查线索）
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

// ⚠️ v1.0.101：SID 运行时自动探测——Dopamine 上有效 SID（送达且不顶掉用户手指）是
// 会话随机的（ctor-69: 0x100000709 有效；ctor-71/72/73: 0x1000007b1/7af 顶掉；无规律）。
// Tweak.xm 按住球时逐个候选 SID 注入探测 tap，通过 sendEvent 回流（送达）+ 用户手指
// 存活（不顶掉）双重判定锁定 g_WorkingSID。以下为探测配套接口。
uint64_t FT_HIDGetMainSID(void) { return g_MainSID; }

int  FT_HIDGetCapturedCount(void) { return g_CapturedSIDCount; }
uint64_t FT_HIDGetCapturedAt(int i) {
    if (i < 0 || i >= g_CapturedSIDCount) return 0;
    return g_CapturedSIDs[i];
}

// 探测成功后锁定有效 SID（后续派发直接用它，绕过随机捕获）
void FT_HIDLockSenderID(uint64_t sid) {
    if (!sid) return;
    g_WorkingSID = sid;
    char dbg[96];
    snprintf(dbg, sizeof(dbg), "SID locked (probe OK): 0x%llx", (unsigned long long)sid);
    FTHIDLog(dbg);
}

// 用【指定 SID】注入一次探测 tap（down + up 立即）——探测阶段专用，
// 不走 g_WorkingSID 逻辑；0x0B0018 字段与正式派发一致。
void FT_HIDProbeTap(double nx, double ny, uint64_t sid) {
    if (!g_hidClient || !FT_HIDLoadSymbols() || !sid) return;
    FT_IOHIDEventRef d = FT_HIDCreateDigitizerEvent(true, nx, ny, 2);
    if (d) {
        p_IOHIDEventSetSenderID(d, sid);
        if (p_IOHIDEventSetIntegerValue) p_IOHIDEventSetIntegerValue(d, 0x0B0018, (int64_t)sid);
        p_IOHIDEventSystemClientDispatchEvent(g_hidClient, d);
        CFRelease(d);
    }
    FT_IOHIDEventRef u = FT_HIDCreateDigitizerEvent(false, nx, ny, 2);
    if (u) {
        p_IOHIDEventSetSenderID(u, sid);
        if (p_IOHIDEventSetIntegerValue) p_IOHIDEventSetIntegerValue(u, 0x0B0018, (int64_t)sid);
        p_IOHIDEventSystemClientDispatchEvent(g_hidClient, u);
        CFRelease(u);
    }
    char dbg[96];
    snprintf(dbg, sizeof(dbg), "probe tap SID=0x%llx", (unsigned long long)sid);
    FTHIDLog(dbg);
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

// v1.0.83：连点停止时「抬全手」——派发一个 hand-only up 事件（parent-only）。
// ⚠️ v1.0.90：改为【空实现】——parent-only 一直 ret≠0（0x2cf4000/0x2258000/d5c000 系统不认），
// v1.0.85 的 8-up 版本更是破坏路由（ctor-59：全部 App 收不到点击）。停止时不再派发任何
// 事件，彻底排除「清场事件干扰系统触摸」的可能。
void FT_HIDRaiseAllSyntheticUp(void) {
    FTHIDLog("hand-up: no-op (v1.0.90 removed stop-time dispatch)");
}

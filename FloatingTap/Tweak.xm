//
//  Tweak.xm — FloatingTap v1.0.53
//
//  架构（用户原设计）：AutoTap App = 启动器（选目标 App / 拖动十字线定位置 / 间隔），
//  FloatingTap tweak = 执行器。
//  v1.0.53：通信改为 CFPreferences（cfprefsd 守护进程，跨进程共享，纯系统 API 零第三方依赖）
//  + Darwin 通知（仅唤醒信号，不承载数据）。
//    - Dopamine rootless 官方无内置 rocketbootstrap（release note: "No rocketbootstrap / IPC"），
//      CFMessagePort + RocketBootstrap 方案实测既崩 SB 又不通（两次 Safe Mode），v1.0.53 彻底废弃。
//    - 数据全部走 cfprefsd 共享偏好（appID = com.floatingtap.shared）：
//      tweak 写 heartbeat(_loaded/_hbtimets) + apps(bundleID->displayName)；App 写 config(ClickX/ClickY/IntervalMs)
//    - App 前台轮询读偏好；tweak 常驻收 Darwin 通知（appStarted/configUpdated）后推数据/读配置。
//    - 同时移除 FT_HIDStartSenderIDCapture（arm64e SB 里注册 IOHID 事件回调 = Safe Mode 元凶），
//      senderID 直接用硬编码兜底值。
//
//  仍保持零静态 ObjC 元数据：无 @implementation / @"..." / block 字面量 / @selector / NSLog。
//  日志：syslog + /tmp/floatingtap_ctor.log（append，带时间戳）。
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>   // 仅类型声明（UIWindow/UIEvent），不产生运行时元数据；%hook 需要
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <syslog.h>
#import <time.h>
#import <stdint.h>
#import <stdbool.h>
#import <unistd.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>

#include "HIDInject.h"

// MARK: - objc_msgSend 类型化函数指针（ARM64 下结构体参数需与目标方法签名一致）

typedef id         (*Msg_Send)(id, SEL);
typedef id         (*Msg_Init)(id, SEL);
typedef id         (*Msg_InitWithTargetAction)(id, SEL, id, SEL);
typedef id         (*Msg_AllocInitWithFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetBackgroundColor)(id, SEL, id);
typedef void       (*Msg_SetCGFloat)(id, SEL, CGFloat);
typedef CGFloat    (*Msg_CGFloatReturn)(id, SEL);
typedef void       (*Msg_SetAlpha)(id, SEL, CGFloat);
typedef void       (*Msg_SetBorderColor)(id, SEL, CGColorRef);
typedef void       (*Msg_SetWindowLevel)(id, SEL, CGFloat);
typedef void       (*Msg_SetHidden)(id, SEL, BOOL);
typedef void       (*Msg_SetUserInteractionEnabled)(id, SEL, BOOL);
typedef void       (*Msg_AddGestureRecognizer)(id, SEL, id);
typedef void       (*Msg_SetEnabled)(id, SEL, BOOL);
typedef void       (*Msg_RequireToFail)(id, SEL, id);
typedef void       (*Msg_AddSubview)(id, SEL, id);
typedef void       (*Msg_SetTag)(id, SEL, NSInteger);
typedef id         (*Msg_ViewWithTag)(id, SEL, NSInteger);
typedef void       (*Msg_MakeKeyAndVisible)(id, SEL);
typedef void       (*Msg_SetNumberOfTapsRequired)(id, SEL, NSUInteger);
typedef void       (*Msg_SetWindowScene)(id, SEL, id);
typedef id         (*Msg_Layer)(id, SEL);
typedef id         (*Msg_ColorWithRGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
typedef CGColorRef (*Msg_CGColor)(id, SEL);
typedef CGRect     (*Msg_Bounds)(id, SEL);
typedef CGRect     (*Msg_Frame)(id, SEL);
typedef CGPoint    (*Msg_LocationInView)(id, SEL, id);
typedef NSUInteger (*Msg_State)(id, SEL);
typedef NSUInteger (*Msg_Count)(id, SEL);
typedef id         (*Msg_AnyObject)(id, SEL);
typedef id         (*Msg_ObjectAtIndex)(id, SEL, NSUInteger);
typedef BOOL       (*Msg_IsKindOf)(id, SEL, Class);
typedef NSInteger  (*Msg_Int)(id, SEL);
typedef id         (*Msg_SendID)(id, SEL, void *);
typedef const char * (*Msg_UTF8String)(id, SEL);
typedef CGPoint    (*Msg_LocationInView)(id, SEL, id);

// 判断当前进程 bundle id（v1.0.47：SB 进程控制端 / 抖音进程注入执行端）
static BOOL FTIsBundle(const char *bundleID) {
    Class ClsBundle = objc_getClass("NSBundle");
    if (!ClsBundle) return NO;
    id mb = ((Msg_Send)objc_msgSend)((id)ClsBundle, sel_registerName("mainBundle"));
    if (!mb) return NO;
    id bid = ((Msg_Send)objc_msgSend)(mb, sel_registerName("bundleIdentifier"));
    if (!bid) return NO;
    const char *s = ((Msg_UTF8String)objc_msgSend)(bid, sel_registerName("UTF8String"));
    return (s && strcmp(s, bundleID) == 0);
}

// MARK: - 全局状态（纯 C）

static id gBallContainer = nil;   // 球的父窗口（v1.0.58：优先 _UISystemGestureWindow，始终位于所有 App 之上；兜底 keyWindow）
static id gBallView      = nil;   // 球 UIView 本身
static id gGestureWin    = nil;   // v1.0.61：从 sendEvent 事件流直接捕获到的系统手势窗口实例（最可靠的定位方式）
static id gTapGR      = nil;
static id gTapGR2     = nil;   // 点击点标记上的双击手势（同样触发模式切换，避免标记盖住球时双击失效）
static id gLongGR     = nil;
static id gPanGR      = nil;   // 拖动手势（仅「红色拖动模式」生效，移动球本身）
static id gClickPointView = nil; // 点击点标记（独立视图，仅「红色拖动模式」可拖动；蓝色连击模式不可交互→点击穿透到下层 App）
static id gClickFlashView = nil; // v1.0.81：点击落点光圈——连点每次注入都在点击点显示红圈，直观看到"点击落在哪"
static id gClickPanGR = nil;   // 点击点拖动手势（仅红色模式生效，移动点击点，与球解耦）
static BOOL gDragMode = NO;    // NO=蓝色连击模式（长按触发连点）；YES=红色拖动模式（拖动定位）

// v1.0.71：按指针身份追踪按在球上的「用户手指」触摸，替代 UILongPressGR 触发连点。
// 免疫两大致命干扰：① 游戏内多点触摸（第 2 根手指）会让 UILongPress 被判 Cancelled；
// ② 合成注入触摸（当点击点==球心时落回球上）会让 UILongPress 收 2nd touch 取消。
// 只认「在球内 Began 的那一根触摸」，其余触摸/合成触摸一律忽略。
static void *gBallTouch = NULL;          // 用户手指对应的 UITouch 对象（ARC 下系统持有，指针有效期内稳定）
static double gBallTouchDownTime = 0;    // 该触摸 Began 的单调时间
static BOOL   gBallTouchClicking = NO;   // 是否已据此触摸开始连点（避免重复 start）
static BOOL   gBallTouchTimerPending = NO; // 120ms 长按计时器是否已排队（避免重复排）
// v1.0.80：松手宽限——注入合成触摸会让系统把按住球的手指 Ended（touch ph=3），但用户手指
// 仍物理按着，digitizer 会为同一手指重发 Began。故触摸结束时【不立即停止】，排 400ms 宽限
// 计时器：宽限内系统重发 Began → 重绑继续连点；宽限过无新 Began → 确认真松手 → 停止。
static BOOL   gStopGracePending = NO;
static void FTStopGraceTimer(void *ctx);

static CGPoint gClickPanStartLoc;   // 点击点拖动起点（窗口坐标）
static CGPoint gClickPanOrigin0;    // 点击点拖动起点 frame.origin

static CGPoint gPanStartLoc;   // 触摸起始点（窗口坐标）
static CGPoint gPanOrigin0;    // 触摸起始时窗口 frame.origin

static double  gScreenW = 0;   // 主屏尺寸（FTSetupBall 时保存）
static double  gScreenH = 0;

static BOOL    gIsClicking = NO;            // 连点进行中
static uint32_t gTapIndex = 0;              // 每次 tap 递增的 index（区分触摸，避免被串流）
static double  gClickLockX = 0.5;           // 连点锁定坐标 = 点击点标记位置（与球解耦，由标记拖动/App 配置设定）
static double  gClickLockY = 0.5;
static dispatch_source_t gClickTimer = NULL; // 连点定时器（SB 端直接注入用）

// v1.0.50：AutoTap App 配置（位置/间隔）——定义在 FTIntervalMs 之前（它要读）
static double gCfgX = 0.5, gCfgY = 0.5, gCfgMs = 10.0;
static int  gCfgLoaded = 0;

// MARK: - 诊断日志（append 到标记文件，Filza 可见；带单调时间戳）

static void FTLog(const char *msg) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    char line[256];
    snprintf(line, sizeof(line), "[%.1f] %s", t, msg);
    FILE *f = fopen("/tmp/floatingtap_ctor.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
    syslog(LOG_ERR, "%s", line);
}

// MARK: - 工具

static id FTAlloc(Class cls) {
    return ((Msg_Send)objc_msgSend)((id)cls, sel_registerName("alloc"));
}

static id FTAllocInitWithFrame(Class cls, CGRect frame) {
    id obj = FTAlloc(cls);
    return ((Msg_AllocInitWithFrame)objc_msgSend)(obj, sel_registerName("initWithFrame:"), frame);
}

// 取当前前台活跃的 UIWindowScene（iOS 13+ 必需，否则 UIWindow 不渲染）
static id FTGetActiveWindowScene(void) {
    Class ClsApp = objc_getClass("UIApplication");
    if (!ClsApp) return nil;
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
    if (!app) return nil;
    id scenes = ((Msg_Send)objc_msgSend)(app, sel_registerName("connectedScenes"));
    if (!scenes) return nil;
    id arr = ((Msg_Send)objc_msgSend)(scenes, sel_registerName("allObjects"));
    if (!arr) return nil;
    NSUInteger n = ((Msg_Count)objc_msgSend)(arr, sel_registerName("count"));
    Class ClsWScene = objc_getClass("UIWindowScene");
    id firstWS = nil;
    for (NSUInteger i = 0; i < n; i++) {
        id s = ((Msg_ObjectAtIndex)objc_msgSend)(arr, sel_registerName("objectAtIndex:"), i);
        if (!s) continue;
        if (ClsWScene && ((Msg_IsKindOf)objc_msgSend)(s, sel_registerName("isKindOfClass:"), ClsWScene)) {
            if (firstWS == nil) firstWS = s;
            NSInteger act = ((Msg_Int)objc_msgSend)(s, sel_registerName("activationState"));
            if (act == 1) return s; // UISceneActivationStateForegroundActive = 1
        }
    }
    return firstWS;
}

// SB UI 是否就绪：能拿到 windowScene，或 UIApplication 至少有一个 window
static BOOL FTUIReady(void) {
    if (FTGetActiveWindowScene()) return YES;
    Class ClsApp = objc_getClass("UIApplication");
    if (!ClsApp) return NO;
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
    if (!app) return NO;
    id wins = ((Msg_Send)objc_msgSend)(app, sel_registerName("windows"));
    if (!wins) return NO;
    NSUInteger n = ((Msg_Count)objc_msgSend)(wins, sel_registerName("count"));
    return n > 0;
}

// MARK: - 连点引擎

static unsigned long gClickCount = 0; // 本次连点周期内的点击次数（诊断）

// 读取连点间隔（毫秒）：优先 App 配置（v1.0.50），兜底 cfg 文件，默认 12ms。
// 12ms ≈ 83 次/秒；HID 事件每次递增 index 区分触摸，避免被系统串成同一触摸流。
static double FTIntervalMs(void) {
    if (gCfgLoaded && gCfgMs >= 1.0) return gCfgMs;
    FILE *f = fopen("/var/mobile/Library/Preferences/com.floatingtap.cfg", "r");
    if (f) {
        double v = 10.0;
        if (fscanf(f, "%lf", &v) == 1 && v >= 1.0 && v <= 60000.0) {
            fclose(f);
            return v;
        }
        fclose(f);
    }
    return 10.0;
}

// MARK: - App 通信（v1.0.53：CFPreferences 共享偏好，cfprefsd 守护进程跨进程共享）
// Dopamine rootless 官方无内置 rocketbootstrap（release note: "No rocketbootstrap / IPC"），
// 且第三方移植加载即崩 SB（实测两次 Safe Mode）→ CFMessagePort 方案废弃。
// 改用 cfprefsd（系统守护进程，所有进程共享，纯系统 API 零第三方依赖）：
//   tweak 写：appID=com.floatingtap.shared, key=_loaded=true, key=_hbtimets=epoch秒,
//             key=_apps=dict(bundleID->displayName)
//   App  写：appID=com.floatingtap.shared, key=_config=dict(ClickX/ClickY/IntervalMs)
// Darwin 通知（appStarted/configUpdated）仅作唤醒信号，不承载数据。
// 注意：App 前台轮询读偏好（无需 tweak 主动推送），tweak 常驻收通知后推数据/读配置。

typedef id         (*Msg_AllApps)(id, SEL);
typedef id         (*Msg_AppBid)(id, SEL);
typedef id         (*Msg_AppName)(id, SEL);

// 动态 CFString（避免字面量字符串元数据；CFStringCreateWithCString 在 SB 启动后安全）
static CFStringRef FTCreateCFStr(const char *s) {
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

// 共享偏好 appID（tweak 与 App 双方约定）
// v1.0.53.1：必须用 App 自己的 bundleID，否则 cfprefsd 在 iOS 沙盒下
// 拒绝 App 进程读第三方 appID 的偏好。Tweak 是越狱 root 进程，
// 写任何 appID 都通；App 只能读自己 bundleID（com.autotap.app）的偏好。
static CFStringRef FTSharedAppID(void) {
    return FTCreateCFStr("com.autotap.app");
}

// 写一条共享偏好（key:value → appID，current user / any host）
static void FTWritePref(const char *key, CFPropertyListRef value) {
    CFStringRef appID = FTSharedAppID();
    if (!appID || !key || !value) { if (appID) CFRelease(appID); return; }
    CFStringRef k = FTCreateCFStr(key);
    if (k) {
        CFPreferencesSetValue(k, value, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(k);
    }
    CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(appID);
}

// 前向声明（定义在文件后段）
static void FTMoveBallToConfig(void);
static void FTWriteAppsList(void);
static void FTAppsListDeferredCallback(void *ctx);

// 应用共享偏好里的 config（CoreFoundation CFDictionary，纯 C，无 ObjC）
static void FTApplyConfigFromPrefs(CFDictionaryRef dict) {
    if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return;
    double nx = 0.5, ny = 0.5, ms = 10.0;
    CFStringRef kX = FTCreateCFStr("ClickX");
    CFStringRef kY = FTCreateCFStr("ClickY");
    CFStringRef kMs = FTCreateCFStr("IntervalMs");
    CFNumberRef v = NULL;
    if (kX && (v = (CFNumberRef)CFDictionaryGetValue(dict, kX)) && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue(v, kCFNumberDoubleType, &nx);
    if (kY && (v = (CFNumberRef)CFDictionaryGetValue(dict, kY)) && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue(v, kCFNumberDoubleType, &ny);
    if (kMs && (v = (CFNumberRef)CFDictionaryGetValue(dict, kMs)) && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue(v, kCFNumberDoubleType, &ms);
    if (kX) CFRelease(kX); if (kY) CFRelease(kY); if (kMs) CFRelease(kMs);
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;
    if (ms < 1) ms = 10;
    gCfgX = nx; gCfgY = ny; gCfgMs = ms;
    gCfgLoaded = 1;
    FTMoveBallToConfig();
    char diag[128];
    snprintf(diag, sizeof(diag), "config via prefs x=%.2f y=%.2f ms=%.0f", nx, ny, ms);
    FTLog(diag);
}

// 读共享偏好里的 config（App 写；兼容 CFData(序列化) 或直接 CFDictionary 两种存储）
static void FTReadConfig(void) {
    CFStringRef appID = FTSharedAppID();
    if (!appID) return;
    CFStringRef k = FTCreateCFStr("_config");
    if (k) {
        CFPropertyListRef v = CFPreferencesCopyValue(k, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (v) {
            CFTypeID tid = CFGetTypeID(v);
            if (tid == CFDataGetTypeID()) {
                CFErrorRef err = NULL;
                CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, (CFDataRef)v,
                    kCFPropertyListImmutable, NULL, &err);
                if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
                    FTApplyConfigFromPrefs((CFDictionaryRef)plist);
                } else {
                    FTLog("config: parse failed");
                }
                if (plist) CFRelease(plist);
                if (err) CFRelease(err);
            } else if (tid == CFDictionaryGetTypeID()) {
                FTApplyConfigFromPrefs((CFDictionaryRef)v);
            }
            CFRelease(v);
        }
        CFRelease(k);
    }
    CFRelease(appID);
}

// tweak→App：写心跳（_loaded=true, _hbtimets=epoch 秒）
static void FTWriteHeartbeat(void) {
    double now = (double)time(NULL);
    CFNumberRef t = CFNumberCreate(NULL, kCFNumberDoubleType, &now);
    FTWritePref("_loaded", kCFBooleanTrue);
    FTWritePref("_hbtimets", t);
    if (t) CFRelease(t);
    FTLog("heartbeat written via CFPreferences");
    // v1.0.53.3 诊断：探测 cfprefsd 实际写入路径 + tweak 自身能否读回
    {
        const char *candidates[] = {
            "/var/mobile/Library/Preferences/com.autotap.app.plist",
            "/private/var/mobile/Library/Preferences/com.autotap.app.plist",
            NULL
        };
        for (int i = 0; candidates[i]; i++) {
            FILE *f = fopen(candidates[i], "r");
            char diag[200];
            if (f) {
                fseek(f, 0, SEEK_END);
                long sz = ftell(f);
                fclose(f);
                snprintf(diag, sizeof(diag), "probe tweak: %s EXISTS sz=%ld", candidates[i], sz);
            } else {
                snprintf(diag, sizeof(diag), "probe tweak: %s MISSING (errno=%d)", candidates[i], errno);
            }
            FTLog(diag);
        }
        // 同进程自读 cfprefsd：验证 tweak 写完自己能不能读回
        CFStringRef appID = FTSharedAppID();
        CFStringRef k = FTCreateCFStr("_hbtimets");
        if (appID && k) {
            CFPropertyListRef v = CFPreferencesCopyValue(k, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            char diag[160];
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                double back = 0;
                CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &back);
                snprintf(diag, sizeof(diag), "probe tweak: cfprefsd self-read OK back=%.0f", back);
                CFRelease(v);
            } else {
                snprintf(diag, sizeof(diag), "probe tweak: cfprefsd self-read NIL");
            }
            FTLog(diag);
            CFRelease(k);
        }
        if (appID) CFRelease(appID);
    }
}

// tweak→App：枚举已装 App 并写共享偏好（SB 进程 LSApplicationWorkspace 特权枚举）
static void FTWriteAppsList(void) {
    Class ClsWS = objc_getClass("LSApplicationWorkspace");
    if (!ClsWS) { FTLog("apps: LSApplicationWorkspace missing"); return; }
    id ws = ((Msg_Send)objc_msgSend)((id)ClsWS, sel_registerName("defaultWorkspace"));
    if (!ws) { FTLog("apps: workspace nil"); return; }
    id apps = ((Msg_AllApps)objc_msgSend)(ws, sel_registerName("allApplications"));
    if (!apps) { FTLog("apps: allApplications nil"); return; }
    NSUInteger n = ((Msg_Count)objc_msgSend)(apps, sel_registerName("count"));
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (NSUInteger i = 0; i < n; i++) {
        id a = ((Msg_ObjectAtIndex)objc_msgSend)(apps, sel_registerName("objectAtIndex:"), i);
        if (!a) continue;
        id bid = ((Msg_Send)objc_msgSend)(a, sel_registerName("bundleIdentifier"));
        id nm = ((Msg_Send)objc_msgSend)(a, sel_registerName("name"));
        const char *bidc = bid ? ((Msg_UTF8String)objc_msgSend)(bid, sel_registerName("UTF8String")) : NULL;
        if (!bidc) continue;
        const char *nmc = nm ? ((Msg_UTF8String)objc_msgSend)(nm, sel_registerName("UTF8String")) : NULL;
        CFStringRef kb = FTCreateCFStr(bidc);
        if (!kb) continue;
        CFStringRef kv = FTCreateCFStr(nmc ? nmc : bidc);
        CFDictionarySetValue(d, kb, kv ? kv : kb);
        if (kv) CFRelease(kv);
        CFRelease(kb);
    }
    FTWritePref("_apps", d);
    CFRelease(d);
    char diag[128];
    snprintf(diag, sizeof(diag), "apps saved %lu entries via CFPreferences", (unsigned long)n);
    FTLog(diag);
}

// Darwin 通知回调（纯 C；observer=静态占位，靠 name 区分）——只作唤醒信号，数据走 CFPreferences
static int sNotifyObserver = 0;
static void FTNotificationCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object; (void)userInfo;
    char buf[256];
    if (!name || !CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)) return;
    if (strcmp(buf, "com.floatingtap.autotap.appStarted") == 0) {
        FTLog("got appStarted -> write hb via CFPreferences");
        FTWriteHeartbeat();
        // v1.0.53.2：绝不在通知线程同步枚举 App（LSApplicationWorkspace 在通知回调里仍会崩 SB）。
        // 改派发 3s 延迟到主队列，复用已 @try 包裹的延迟回调；与 60s 那次枚举互不冲突。
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                         dispatch_get_main_queue(), NULL, FTAppsListDeferredCallback);
    } else if (strcmp(buf, "com.floatingtap.autotap.configUpdated") == 0) {
        FTLog("got configUpdated -> read config from CFPreferences");
        FTReadConfig();
        FTWriteHeartbeat();
    }
}

// 注册 Darwin 通知（App→tweak 唤醒信号；无 IPC server，数据走共享偏好）
static void FTRegisterNotifications(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (!center) return;
    static CFStringRef sNameAppStarted = NULL, sNameConfig = NULL;
    if (!sNameAppStarted) {
        sNameAppStarted = CFStringCreateWithCString(NULL, "com.floatingtap.autotap.appStarted", kCFStringEncodingUTF8);
        sNameConfig = CFStringCreateWithCString(NULL, "com.floatingtap.autotap.configUpdated", kCFStringEncodingUTF8);
    }
    if (sNameAppStarted)
        CFNotificationCenterAddObserver(center, &sNotifyObserver, FTNotificationCallback,
                                        sNameAppStarted, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    if (sNameConfig)
        CFNotificationCenterAddObserver(center, &sNotifyObserver, FTNotificationCallback,
                                        sNameConfig, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    FTLog("darwin notify registered (CFPreferences comm)");
    // 启动即尝试：读 App 可能已写的配置 + 推一次心跳（轻量操作，30s 阶段稳定）
    FTReadConfig();
    FTWriteHeartbeat();
    // FTWriteAppsList 用 objc_msgSend 调 LSApplicationWorkspace.allApplications——
    // 在 SB 启动 30s 阶段仍不稳，挪到独立的 60s 延迟回调，给 SB 更多时间稳定后再枚举。
    FTLog("defer apps list scan to +60s");
}

// 60s 后单独尝试枚举 App 列表（不再混入 30s init）；依然包 try/catch 兜底
static void FTAppsListDeferredCallback(void *ctx) {
    (void)ctx;
    FTLog("deferred apps list scan start");
    @try {
        FTWriteAppsList();
    } @catch (NSException *ex) {
        FTLog("apps list scan exception (swallowed)");
        (void)ex;
    }
}

// 恢复球窗口交互（注入后 60ms 回调）

// MARK: - 连点注入
// v1.0.62：改用「系统 HID 服务」派发（IOHIDEventSystemClientDispatchEvent，见 HIDInject.c
// 的 FT_HIDDispatchDown/Up），事件由系统路由到前台 App。
// ⚠️ 旧版（v1.0.41~61）走 SpringBoard 的 UIApplication._handleHIDEvent:——那只喂 SB 自己的
// 事件队列，前台 App（游戏）收不到 → 注入日志有、但无任何点击反馈。这是"无点击效果"的真凶。
// down 立即发，up 延迟 50ms 发（社区标准做法）——让系统把 down/up 关联为同一触摸。

// v1.0.75：up 回调上下文按次 malloc（消除全局覆盖——10ms 连点多个 pending up 会互相覆盖
// 坐标/index，导致 down/up 错配、部分触摸永远收不到 up）。回调里 free。
typedef struct {
    double   x, y;
    uint32_t index;
} FTHIDUpCtx;

// 发送一次 up（延迟回调）——经系统 HID 服务派发
static void FTSendHIDUpCallback(void *ctx) {
    FTHIDUpCtx *c = (FTHIDUpCtx *)ctx;
    if (c) {
        FT_HIDDispatchUp(c->x, c->y, c->index);
        free(c);
    }
}

// 在屏幕像素点 (px,py) 发一次合成点击（down 立即 + up 延迟 50ms；每次 tap index 递增）
// 取当前界面方向（UIInterfaceOrientation：1=竖屏 2=竖屏倒 3=横屏左(home左) 4=横屏右(home右)）
static NSInteger FTGetOrientation(void) {
    // 优先用活跃 windowScene 的 interfaceOrientation（iOS 13+ 现代 API，最可靠）
    id scene = FTGetActiveWindowScene();
    if (scene) {
        NSInteger o = ((Msg_Int)objc_msgSend)(scene, sel_registerName("interfaceOrientation"));
        if (o >= 1 && o <= 4) return o;
    }
    // 兜底：UIApplication.statusBarOrientation
    Class ClsApp = objc_getClass("UIApplication");
    if (ClsApp) {
        id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
        if (app) {
            NSInteger o = ((Msg_Int)objc_msgSend)(app, sel_registerName("statusBarOrientation"));
            if (o >= 1 && o <= 4) return o;
        }
    }
    return 1; // 默认竖屏
}

// v1.0.74：移除之前的横竖屏旋转转换（重要修正）。
// 结论：球/点击点标记是旋转窗口（UIWindow 用 transform 旋转显示）的 subview，其 frame 坐标与
// UITouch locationInView: 都在窗口的「未旋转基准坐标空间」= UIScreen.bounds 原生竖屏空间
// （gScreenW/H 也是 mainScreen.bounds，竖屏尺寸）。而 IOHIDEvent digitizer 坐标同样是
// 设备原生竖屏空间 → 二者一致，直接透传即可命中标记处。
// v1.0.70 加的旋转转换会把点击点旋转 90°（"真实点击点不在选定位置"的根因，ctor-39 已现偏移）。
// 若设备坐标系确实需要旋转，可在此按方向换算，但先按透传验证（最符合 UIKit 坐标语义）。
static void FTOrientForHID(double ox, double oy, double *nx, double *ny) {
    (void)ox; (void)oy;
    *nx = ox;
    *ny = oy;
}

static void FTSyntheticTap(double px, double py) {
    double ux = (gScreenW > 0) ? px / gScreenW : 0.5;
    double uy = (gScreenH > 0) ? py / gScreenH : 0.5;
    if (ux < 0.001) ux = 0.001; if (ux > 0.999) ux = 0.999;
    if (uy < 0.001) uy = 0.001; if (uy > 0.999) uy = 0.999;

    // 转换到 HID 原生竖屏坐标空间
    double nx = ux, ny = uy;
    FTOrientForHID(ux, uy, &nx, &ny);

    // 每次 tap 递增 index（v1.0.45：避免系统把连续注入事件串成同一触摸流）
    gTapIndex = (gTapIndex % 19) + 1;
    uint32_t idx = gTapIndex;

    // down 立即（系统级派发）
    FT_HIDDispatchDown(nx, ny, idx);
    // up 延迟 50ms（关联同一触摸，社区标准）。
    // ⚠️ v1.0.76 回归修复：v1.0.75 曾把 <50ms 间隔的 up 提前到 15ms，结果 15ms 的触摸被
    // 系统当噪声过滤，App 收不到 tapsBegan（计数器软件 0 点击、Notes 只出笔点不落墨，ctor-47）。
    // 50ms 是已验证能注册为真实点击的最短安全时长（ctor-46 有反馈）。10ms 连点会有 5 根
    // 同时按下的手指，属正常多指场景，App 仍逐个计数。
    // 上下文按次 malloc，避免全局覆盖导致 down/up 错配。
    FTHIDUpCtx *c = (FTHIDUpCtx *)malloc(sizeof(FTHIDUpCtx));
    if (c) {
        c->x = nx; c->y = ny; c->index = idx;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTSendHIDUpCallback);
    }
}

// MARK: - SB 端注入（v1.0.62 起走系统 HID 服务，可命中前台 App）
// v1.0.62：改为 IOHIDEventSystemClientDispatchEvent 系统级派发（HIDInject.c 的
// FT_HIDDispatchDown/Up），事件由系统路由到前台 App——游戏内点击也有效。
// 旧版（v1.0.41~61）用 SpringBoard 的 UIApplication._handleHIDEvent: 只喂 SB 自身 UI 队列，
// 前台 App 收不到 → 注入日志有、但无点击反馈。

// 连点回调：在点击点标记坐标发一次合成点击。
// v1.0.70：不再把球设为 alpha=0——实测 iOS 15.5 下改 alpha 会让长按手势被判 Cancelled，
// 导致连点定时器被立刻取消（只点 1 下就停、10s 仅数下）。点击点已独立成「标记视图」，
// 连击模式下 marker 的 userInteractionEnabled=NO → 合成点击直接穿透到下层 App，无需隐藏球。
static void FTClickCallback(void *ctx) {
    (void)ctx;
    if (!gBallView || !gIsClicking) return;

    FTSyntheticTap(gClickLockX * gScreenW, gClickLockY * gScreenH);
    gClickCount++;

    // v1.0.81：点击落点光圈——每次注入把光圈移到点击点并点亮（10ms 连点期间保持常亮）
    if (gClickFlashView) {
        ((Msg_SetFrame)objc_msgSend)(gClickFlashView, sel_registerName("setFrame:"),
            CGRectMake(gClickLockX * gScreenW - 13, gClickLockY * gScreenH - 13, 26, 26));
        ((Msg_SetAlpha)objc_msgSend)(gClickFlashView, sel_registerName("setAlpha:"), 1.0);
    }

    double hx = gClickLockX, hy = gClickLockY;
    FTOrientForHID(gClickLockX, gClickLockY, &hx, &hy);
    // 节流：每 ~25 次点击（约 250ms@10ms）打一条，避免日志被刷爆
    static int sTapLogCount = 0;
    if ((sTapLogCount++ % 25) == 0) {
        char diag[160];
        snprintf(diag, sizeof(diag), "inject tap uik=%.2f,%.2f hid=%.2f,%.2f orient=%ld",
                 gClickLockX, gClickLockY, hx, hy, (long)FTGetOrientation());
        FTLog(diag);
    }
}

// 诊断：dump UIEvent 的 ivar 名（已确认有 _hidEvent/_gsEvent）
static void FTDumpEventIvars(void) {
    Class ClsEvent = objc_getClass("UIEvent");
    if (!ClsEvent) return;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(ClsEvent, &count);
    if (!ivars) { FTLog("UIEvent ivar dump: none"); return; }
    char buf[768];
    size_t off = 0;
    int w = snprintf(buf, sizeof(buf), "UIEvent ivars:");
    if (w > 0) off = (size_t)w;
    for (unsigned int i = 0; i < count && off + 96 < sizeof(buf); i++) {
        const char *name = ivar_getName(ivars[i]);
        if (name) {
            int n = snprintf(buf + off, sizeof(buf) - off, " %s", name);
            if (n > 0) off += (size_t)n;
        }
    }
    free(ivars);
    FTLog(buf);
}

// v1.0.75：按「连点中 / 模式」统一启停全部手势识别器。
// ⚠️ 关键修复：连点期间【禁用全部 GR】——否则任何 GR（双击/长按/拖动，含合成点击落在
// 标记/球上的情况）都可能把按住球的手指判 Cancelled(phase=4) 或触发双击 → 连点刚启动就
// 被 FTStopClicking 掐断（"长按只算一次"，ctor-45/46 反复出现）。用户连点时按着球，本就不需要双击。
static void FTApplyGRModes(void) {
    if (!gTapGR || !gLongGR || !gPanGR) return;
    ((Msg_SetEnabled)objc_msgSend)(gTapGR,  sel_registerName("setEnabled:"), gIsClicking ? NO : YES);
    ((Msg_SetEnabled)objc_msgSend)(gTapGR2, sel_registerName("setEnabled:"), gIsClicking ? NO : (gClickPointView ? YES : NO));
    ((Msg_SetEnabled)objc_msgSend)(gLongGR, sel_registerName("setEnabled:"), gIsClicking ? NO : (!gDragMode ? YES : NO));
    ((Msg_SetEnabled)objc_msgSend)(gPanGR,  sel_registerName("setEnabled:"), gIsClicking ? NO : (gDragMode ? YES : NO));
    ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setEnabled:"), gIsClicking ? NO : (gDragMode ? YES : NO));
}

// v1.0.48：SB 端恢复直接注入（不再写任务文件）。坐标锁定 = App 配置点（v1.0.50）
// 或长按开始时球心（无配置时）。
static void FTStartClicking(void) {
    if (gIsClicking) return;
    if (!FT_HIDConnect()) {
        FTLog("clicking failed: HID connect failed");
        return;
    }
    gIsClicking = YES;
    gClickCount = 0;
    gTapIndex = 0;
    // 点击点 = gClickLockX/Y（由点击点标记拖动 / App 配置设定，与球位置解耦）。
    // 这里只做归一化钳制，不再把点击点锁回球心——否则「点击点独立于球」的设计失效。
    if (gClickLockX < 0.001) gClickLockX = 0.001; if (gClickLockX > 0.999) gClickLockX = 0.999;
    if (gClickLockY < 0.001) gClickLockY = 0.001; if (gClickLockY > 0.999) gClickLockY = 0.999;
    double ms = FTIntervalMs();
    // 一碰到球立即点一次（不等第一个 timer tick，短按也有一次点击）
    FTClickCallback(NULL);
    gClickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gClickTimer) {
        dispatch_source_set_timer(gClickTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                                  (uint64_t)(ms * NSEC_PER_MSEC), 0);
        dispatch_source_set_event_handler_f(gClickTimer, FTClickCallback);
        dispatch_resume(gClickTimer);
    }
    // v1.0.75：连点中禁用全部手势识别器（防 GR 取消手指/触发双击掐断连点）
    FTApplyGRModes();
    FTLog("clicking started");
}

// v1.0.75：FTStopClicking 带停止原因（诊断用），并在停止后按模式恢复手势
static void FTStopClicking(const char *reason) {
    if (!gIsClicking) return;
    gIsClicking = NO;
    gStopGracePending = NO; // 取消任何待决的松手宽限
    if (gClickTimer) {
        dispatch_source_cancel(gClickTimer);
        gClickTimer = NULL;
    }
    if (gClickFlashView) {
        ((Msg_SetAlpha)objc_msgSend)(gClickFlashView, sel_registerName("setAlpha:"), 0.0); // 灭光圈
    }
    FTApplyGRModes(); // 恢复手势（按当前模式启用对应 GR）
    char dbg[128];
    snprintf(dbg, sizeof(dbg), "clicking stopped (%s)", reason ? reason : "?");
    FTLog(dbg);
    char buf[96];
    snprintf(buf, sizeof(buf), "clicks this period: %lu", gClickCount);
    FTLog(buf);
}

// MARK: - 动态 GR target（运行时创建类，零静态 ObjC 元数据）

static Class gGRTargetClass = nil;
static id    gGRTarget      = nil;

// Long 回调：仅「蓝色连击模式」生效——一碰即连点（点击点锁在按下时球心，拖动不改变）。
// 「红色拖动模式」下长按无效（拖动由 Pan GR 负责），避免双击切换与连点冲突。
static void FTGRLongHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd; (void)gr;
    // v1.0.71：长按连点改由 sendEvent hook 按「触摸身份」追踪驱动（免疫游戏多点触摸 / 合成触摸取消），
    // 此处留空，仅保留 gLongGR 实例供 double-tap / pan 的 requireGestureRecognizerToFail 依赖。
}

// Pan 回调：仅「红色拖动模式」生效——拖动小球重新定位（点击点独立，不受影响）。
// 连击模式下忽略，保证长按只连点、拖动只定位，互不干扰。
static void FTGRPanHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr || !gBallView) return;
    if (!gDragMode) return; // 连击模式：不响应拖动
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 1) { // Began
        gPanStartLoc = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gBallView);
        gPanOrigin0  = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame")).origin;
    } else if (st == 2) { // Changed → 拖动球
        CGPoint cur = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gBallView);
        CGRect f = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
        ((Msg_SetFrame)objc_msgSend)(gBallView, sel_registerName("setFrame:"),
            CGRectMake(gPanOrigin0.x + (cur.x - gPanStartLoc.x),
                       gPanOrigin0.y + (cur.y - gPanStartLoc.y),
                       f.size.width, f.size.height));
    }
}

// 点击点拖动：仅「红色拖动模式」生效——拖动点击点标记，更新连点坐标（与球独立）。
// 连击模式下 gClickPointView 不可交互，此 GR 被禁用，标记只作位置指示。
static void FTGRClickPanHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr || !gClickPointView) return;
    if (!gDragMode) return; // 连击模式：不响应点击点拖动
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 1) { // Began
        gClickPanStartLoc = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gClickPointView);
        gClickPanOrigin0  = ((Msg_Frame)objc_msgSend)(gClickPointView, sel_registerName("frame")).origin;
    } else if (st == 2) { // Changed → 拖动点击点
        CGPoint cur = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gClickPointView);
        CGRect f = ((Msg_Frame)objc_msgSend)(gClickPointView, sel_registerName("frame"));
        ((Msg_SetFrame)objc_msgSend)(gClickPointView, sel_registerName("setFrame:"),
            CGRectMake(gClickPanOrigin0.x + (cur.x - gClickPanStartLoc.x),
                       gClickPanOrigin0.y + (cur.y - gClickPanStartLoc.y),
                       f.size.width, f.size.height));
        CGRect nf = ((Msg_Frame)objc_msgSend)(gClickPointView, sel_registerName("frame"));
        if (gScreenW > 0 && gScreenH > 0) {
            gClickLockX = (nf.origin.x + nf.size.width * 0.5) / gScreenW;
            gClickLockY = (nf.origin.y + nf.size.height * 0.5) / gScreenH;
            if (gClickLockX < 0.001) gClickLockX = 0.001; if (gClickLockX > 0.999) gClickLockX = 0.999;
            if (gClickLockY < 0.001) gClickLockY = 0.001; if (gClickLockY > 0.999) gClickLockY = 0.999;
        }
    }
}

// 根据模式刷新小球外观：蓝色=连击模式，红色=拖动模式
static void FTApplyBallAppearance(void) {
    if (!gBallView) return;
    Class ClsColor = objc_getClass("UIColor");
    if (!ClsColor) return;
    CGFloat r, g, b, a;
    if (gDragMode) { r = 1.0;  g = 0.231; b = 0.188; a = 0.9; }  // 红（拖动模式）
    else           { r = 0.0;  g = 0.478; b = 1.0;   a = 0.9; }  // 蓝（连击模式）
    id color = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor,
        sel_registerName("colorWithRed:green:blue:alpha:"), r, g, b, a);
    if (color) ((Msg_SetBackgroundColor)objc_msgSend)(gBallView, sel_registerName("setBackgroundColor:"), color);
}

// 点击点标记外观：拖动模式（红）高亮橙、可拖动；连击模式（蓝）暗显绿（仅指示点击位置、不挡触摸）
static void FTApplyClickPointAppearance(void) {
    if (!gClickPointView) return;
    Class ClsColor = objc_getClass("UIColor");
    if (!ClsColor) return;
    CGFloat r, g, b;
    if (gDragMode) { r = 1.0;  g = 0.84; b = 0.0; }   // 橙（可拖动）
    else           { r = 0.2;  g = 1.0;  b = 0.4; }   // 绿（暗显指示）
    id color = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor,
        sel_registerName("colorWithRed:green:blue:alpha:"), r, g, b, 1.0);
    id layer = ((Msg_Layer)objc_msgSend)(gClickPointView, sel_registerName("layer"));
    ((Msg_SetCGFloat)objc_msgSend)(layer, sel_registerName("setBorderWidth:"), (CGFloat)(gDragMode ? 3.5 : 2.5));
    ((Msg_SetBorderColor)objc_msgSend)(layer, sel_registerName("setBorderColor:"),
                                       ((Msg_CGColor)objc_msgSend)(color, sel_registerName("CGColor")));
    id dot = ((Msg_ViewWithTag)objc_msgSend)(gClickPointView, sel_registerName("viewWithTag:"), (NSInteger)101);
    if (dot) ((Msg_SetBackgroundColor)objc_msgSend)(dot, sel_registerName("setBackgroundColor:"), color);
}

// v1.0.73：按下球 120ms 后的延时计时器回调——静止按住时 iOS 不投递 Moved/Stationary 事件，
// 不能靠它们触发连点，改用此计时器。到时若手指仍按着（gBallTouch 未清空 = 同一根手指没抬起）
// 且非拖动模式，就开始连点。
static void FTBallHoldTimer(void *ctx) {
    (void)ctx;
    gBallTouchTimerPending = NO;
    if (gBallTouch != NULL && !gBallTouchClicking && !gDragMode) {
        gBallTouchClicking = YES;
        FTStartClicking();
    }
}

// v1.0.80：松手宽限计时器——400ms 内没有重发的 Began（重绑会清 gStopGracePending）才真停止。
static void FTStopGraceTimer(void *ctx) {
    (void)ctx;
    if (!gStopGracePending) return; // 已被重绑取消（用户手指仍在按着，系统重发了 Began）
    gStopGracePending = NO;
    FTStopClicking("hold-release");
}

// Tap 回调：双击 → 切换「拖动模式」与「连击模式」（不再隐藏球）。
//   蓝色（连击模式）：长按触发连点；红色（拖动模式）：拖动小球重新定位点击点。
static void FTGRTapHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr || !gBallView) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 3) { // Ended（双击完成）
        FTStopClicking("dbl-tap");
        // 切模式时清掉触摸追踪状态，避免残留的 120ms 计时器在切换后误开连点（竞态）
        gBallTouch = NULL;
        gBallTouchClicking = NO;
        gBallTouchTimerPending = NO;
        gDragMode = !gDragMode;
        // v1.0.75：统一由 FTApplyGRModes 按模式启用/禁用对应手势（含连点中全禁用）
        if (gClickPointView) {
            ((Msg_SetUserInteractionEnabled)objc_msgSend)(gClickPointView, sel_registerName("setUserInteractionEnabled:"), gDragMode ? YES : NO);
        }
        FTApplyGRModes();
        FTApplyBallAppearance();
        FTApplyClickPointAppearance();
        FTLog(gDragMode ? "double tap -> drag mode ON (red): drag ball / click-point to position" : "double tap -> combo mode ON (blue)");
    }
}

// 创建动态类 + target 实例（幂等）
static BOOL FTMakeGRTarget(void) {
    if (gGRTarget) return YES;
    Class superCls = objc_getClass("NSObject");
    if (!superCls) return NO;
    gGRTargetClass = objc_allocateClassPair(superCls, "FTGRTarget", 0);
    if (!gGRTargetClass) return NO;
    class_addMethod(gGRTargetClass, sel_registerName("handleLong:"), (IMP)FTGRLongHandler, "v@:@");
    class_addMethod(gGRTargetClass, sel_registerName("handleTap:"),  (IMP)FTGRTapHandler,  "v@:@");
    class_addMethod(gGRTargetClass, sel_registerName("handlePan:"),  (IMP)FTGRPanHandler,  "v@:@");
    class_addMethod(gGRTargetClass, sel_registerName("handleClickPan:"), (IMP)FTGRClickPanHandler, "v@:@");
    objc_registerClassPair(gGRTargetClass);
    gGRTarget = FTAlloc(gGRTargetClass);
    if (gGRTarget) {
        gGRTarget = ((Msg_Init)objc_msgSend)(gGRTarget, sel_registerName("init"));
    }
    return gGRTarget != nil;
}

// 创建带真实 target 的 GR（正确 initWithTarget:action:）
static id FTMakeGR(Class cls, const char *actionName) {
    id gr = FTAlloc(cls);
    if (!gr) return nil;
    return ((Msg_InitWithTargetAction)objc_msgSend)(gr,
        sel_registerName("initWithTarget:action:"), gGRTarget, sel_registerName(actionName));
}

// MARK: - 窗口定位（球挂到系统手势层）

static void FTSetupBall(void);
static void FTSetupBallRetry(void *ctx);

static int gBallSetupTries = 0;
static const int FT_BALL_MAX_TRIES = 12;

// 枚举含 internal 的全体窗口，返回数组或 nil。
// ⚠️ v1.0.61 修正：iOS 12 用 UIWindow 类方法 `_allWindowsIncludingInternalWindows:`；
// iOS 13+ 改用 UIWindowScene 实例方法（同一名字、无参数）。旧版只在 UIWindow 上探，
// 在 iOS 15 上 respondsToSelector 失败 → 返回 nil → 永远找不到手势窗口 → 球兜底挂到
// SBRecordingIndicatorWindow（非交互窗口，手势全失效）。
// 另外 sendEvent hook 会直接捕获手势窗口实例到 gGestureWin，作为最可靠来源。
static id FTInternalWindows(void) {
    // 1) iOS 12：UIWindow 类方法
    Class ClsWinCls = objc_getClass("UIWindow");
    if (ClsWinCls) {
        SEL sels[2];
        sels[0] = sel_registerName("_allWindowsIncludingInternalWindows:");
        sels[1] = sel_registerName("_windowsIncludingInternalWindows:");
        for (int k = 0; k < 2; k++) {
            if (sels[k] && class_respondsToSelector(ClsWinCls, sels[k])) {
                typedef id (*Msg_AllWin)(id, SEL, BOOL);
                id r = ((Msg_AllWin)objc_msgSend)((id)ClsWinCls, sels[k], YES);
                if (r) return r;
            }
        }
    }
    // 2) iOS 13+：UIWindowScene 实例方法（internal 窗口枚举在这里）
    id scene = FTGetActiveWindowScene();
    if (scene) {
        SEL selsS[2];
        selsS[0] = sel_registerName("_allWindowsIncludingInternalWindows");
        selsS[1] = sel_registerName("allWindowsIncludingInternalWindows");
        Class sceneCls = (Class)object_getClass(scene);
        for (int k = 0; k < 2; k++) {
            if (selsS[k] && class_respondsToSelector(sceneCls, selsS[k])) {
                typedef id (*Msg_SceneAllWin)(id, SEL);
                id r = ((Msg_SceneAllWin)objc_msgSend)(scene, selsS[k]);
                if (r) return r;
            }
        }
        // 兜底：scene 公开 windows（不全含 internal，但至少保证有窗口可枚举）
        id sw = ((Msg_Send)objc_msgSend)(scene, sel_registerName("windows"));
        if (sw) return sw;
    }
    return nil;
}

// 返回系统手势窗口（_UISystemGestureWindow / FBSystemGestureWindow 等）；没有返回 nil
static id FTFindSystemGestureWindow(void) {
    id ClsApp = objc_getClass("UIApplication");
    id app = ClsApp ? ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication")) : nil;
    id allWins = FTInternalWindows();
    id appWins = app ? ((Msg_Send)objc_msgSend)(app, sel_registerName("windows")) : nil;
    id sets[2]; sets[0] = allWins; sets[1] = appWins;
    for (int s = 0; s < 2; s++) {
        id ws = sets[s];
        if (!ws) continue;
        NSUInteger cnt = ((Msg_Count)objc_msgSend)(ws, sel_registerName("count"));
        for (NSUInteger i = 0; i < cnt; i++) {
            id w = ((Msg_ObjectAtIndex)objc_msgSend)(ws, sel_registerName("objectAtIndex:"), i);
            if (!w) continue;
            const char *cn = object_getClassName(w);
            if (cn && (strstr(cn, "SystemGesture") || strstr(cn, "GestureWindow") || strstr(cn, "FBSystemGesture"))) {
                return w;
            }
        }
    }
    return nil;
}

// 最佳挂载窗口：优先系统手势窗口；否则「最高 windowLevel 且非 Alert」窗口（避免选中瞬时弹窗）；最后 keyWindow
static id FTFindOverlayWindow(int *outIsGesture) {
    if (outIsGesture) *outIsGesture = 0;
    id g = FTFindSystemGestureWindow();
    if (g) {
        if (outIsGesture) *outIsGesture = 1;
        return g;
    }
    id ClsApp = objc_getClass("UIApplication");
    id app = ClsApp ? ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication")) : nil;
    id allWins = FTInternalWindows();
    id appWins = app ? ((Msg_Send)objc_msgSend)(app, sel_registerName("windows")) : nil;
    id best = nil; CGFloat bestLvl = -1e9;
    id sets[2]; sets[0] = allWins; sets[1] = appWins;
    for (int s = 0; s < 2; s++) {
        id ws = sets[s];
        if (!ws) continue;
        NSUInteger cnt = ((Msg_Count)objc_msgSend)(ws, sel_registerName("count"));
        for (NSUInteger i = 0; i < cnt; i++) {
            id w = ((Msg_ObjectAtIndex)objc_msgSend)(ws, sel_registerName("objectAtIndex:"), i);
            if (!w) continue;
            const char *cn = object_getClassName(w);
            // v1.0.68：跳过瞬时 / 非交互窗口。iOS 15 的 SBRecordingIndicatorWindow（隐私/录屏指示）
            // 尺寸极小却拥有最高 windowLevel，旧版兜底误选它 → 球挂上去 touch 命中范围错乱、手势收不到、
            // 在 App 内被完全盖住无反馈。一并排除 Alert / StatusBar / Keyboard / CoverSheet 等。
            if (cn && (strstr(cn, "Alert") || strstr(cn, "Recording") ||
                       strstr(cn, "Indicator") || strstr(cn, "StatusBar") ||
                       strstr(cn, "Keyboard") || strstr(cn, "CoverSheet"))) continue;
            CGFloat lvl = ((Msg_CGFloatReturn)objc_msgSend)(w, sel_registerName("windowLevel"));
            if (lvl > bestLvl) { bestLvl = lvl; best = w; }
        }
    }
    if (best) return best;
    return app ? ((Msg_Send)objc_msgSend)(app, sel_registerName("keyWindow")) : nil;
}

// 延迟重试挂载（dispatch_after_f 回调）
static void FTSetupBallRetry(void *ctx) {
    (void)ctx;
    FTSetupBall();
}

// v1.0.68：把球重新挂到系统手势窗口（当 sendEvent 捕获到真正手势窗口、而球此前挂在兜底窗口时）。
// 用主线程异步回调执行，避免在事件派发途中直接改视图层级导致异常。
static void FTReparentBallToGestureWin(void *ctx) {
    (void)ctx;
    if (!gBallView || !gGestureWin) return;
    id sup = ((Msg_Send)objc_msgSend)(gBallView, sel_registerName("superview"));
    if (sup == gGestureWin) return; // 已经在正确窗口
    if (sup) ((Msg_Send)objc_msgSend)(gBallView, sel_registerName("removeFromSuperview"));
    ((Msg_AddSubview)objc_msgSend)(gGestureWin, sel_registerName("addSubview:"), gBallView);
    gBallContainer = gGestureWin;
    // 点击点标记一并重挂到正确窗口
    if (gClickPointView) {
        id csup = ((Msg_Send)objc_msgSend)(gClickPointView, sel_registerName("superview"));
        if (csup != gGestureWin) {
            if (csup) ((Msg_Send)objc_msgSend)(gClickPointView, sel_registerName("removeFromSuperview"));
            ((Msg_AddSubview)objc_msgSend)(gGestureWin, sel_registerName("addSubview:"), gClickPointView);
        }
    }
    // 点击落点光圈一并重挂
    if (gClickFlashView) {
        id fsup = ((Msg_Send)objc_msgSend)(gClickFlashView, sel_registerName("superview"));
        if (fsup != gGestureWin) {
            if (fsup) ((Msg_Send)objc_msgSend)(gClickFlashView, sel_registerName("removeFromSuperview"));
            ((Msg_AddSubview)objc_msgSend)(gGestureWin, sel_registerName("addSubview:"), gClickFlashView);
        }
    }
    const char *oldCls = sup ? object_getClassName(sup) : "?";
    char diag[160];
    snprintf(diag, sizeof(diag), "ball reparented: %s -> %s", oldCls, object_getClassName(gGestureWin));
    FTLog(diag);
}

// MARK: - 创建小球

static void FTSetupBall(void) {
    // v1.0.58：球挂在 _UISystemGestureWindow（或兜底 keyWindow）的 subview，凭 superview 判断是否已挂载
    if (gBallView) {
        id sup = ((Msg_Send)objc_msgSend)(gBallView, sel_registerName("superview"));
        if (sup) return;
    }

    Class ClsApp   = objc_getClass("UIApplication");
    Class ClsView  = objc_getClass("UIView");
    Class ClsScreen = objc_getClass("UIScreen");
    Class ClsColor = objc_getClass("UIColor");
    Class ClsTapGR = objc_getClass("UITapGestureRecognizer");
    Class ClsLongGR = objc_getClass("UILongPressGestureRecognizer");
    Class ClsPanGR = objc_getClass("UIPanGestureRecognizer");
    if (!ClsApp || !ClsView || !ClsScreen || !ClsColor || !ClsTapGR || !ClsLongGR || !ClsPanGR) {
        FTLog("setup failed: system class missing");
        return;
    }
    if (!FTMakeGRTarget()) {
        FTLog("setup failed: make GR target");
        return;
    }

    // 主屏尺寸
    id mainScreen = ((Msg_Send)objc_msgSend)((id)ClsScreen, sel_registerName("mainScreen"));
    CGRect sb = ((Msg_Bounds)objc_msgSend)(mainScreen, sel_registerName("bounds"));
    gScreenW = sb.size.width;
    gScreenH = sb.size.height;
    CGFloat d = 56.0;
    CGRect ballFrame = CGRectMake(sb.size.width / 2 - d / 2, sb.size.height / 2 - d / 2, d, d);

    // v1.0.60：球必须挂到 _UISystemGestureWindow（系统手势层，始终在所有 App 之上），
    // 游戏/前台 App 内才可见可点。但它是 internal window，[UIApplication windows] 枚举不到，
    // 且 init 过早时可能尚未创建；旧版兜底取"windowLevel 最高"会选中瞬时弹窗 SBAlertItemWindow
    // （弹窗消失球也跟着没 → "没有悬浮窗"）。
    // 修复：先找系统手势窗口；找不到就延迟重试（最多 ~12s）等它就绪；
    //       重试耗尽才退化挂到「最高非 Alert 窗口 / keyWindow」（稳定、不会凭空消失）。
    int isGesture = 0;
    id targetWin = nil;
    // v1.0.61：优先用从 sendEvent 捕获到的真实系统手势窗口（最可靠），
    // 否则退化到枚举 + 兜底（最高非 Alert / keyWindow）。
    if (gGestureWin) {
        targetWin = gGestureWin;
        isGesture = 1;
        FTLog("ball: using gesture window captured from sendEvent");
    } else {
        targetWin = FTFindOverlayWindow(&isGesture);
    }
    {
        char diagSel[160];
        snprintf(diagSel, sizeof(diagSel), "ball select: gestureCaptured=%d target=%s isGesture=%d",
            gGestureWin ? 1 : 0,
            targetWin ? object_getClassName(targetWin) : "nil",
            isGesture);
        FTLog(diagSel);
    }
    if (!targetWin && gBallSetupTries < FT_BALL_MAX_TRIES) {
        gBallSetupTries++;
        FTLog("ball: no overlay window yet, retry later");
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTSetupBallRetry);
        return;
    }
    if (!targetWin) {
        FTLog("setup failed: no overlay window");
        return;
    }

    id ball = FTAllocInitWithFrame(ClsView, ballFrame);
    if (!ball) {
        FTLog("setup failed: alloc ball");
        return;
    }
    ((Msg_SetUserInteractionEnabled)objc_msgSend)(ball, sel_registerName("setUserInteractionEnabled:"), YES);
    ((Msg_SetBackgroundColor)objc_msgSend)(ball, sel_registerName("setBackgroundColor:"),
        ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"),
                                          0.0, 0.478, 1.0, 0.9));

    id layer = ((Msg_Layer)objc_msgSend)(ball, sel_registerName("layer"));
    ((Msg_SetCGFloat)objc_msgSend)(layer, sel_registerName("setCornerRadius:"), (CGFloat)(d / 2.0));
    ((Msg_SetCGFloat)objc_msgSend)(layer, sel_registerName("setBorderWidth:"), (CGFloat)2.5);
    id white = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"),
                                                 1.0, 1.0, 1.0, 1.0);
    ((Msg_SetBorderColor)objc_msgSend)(layer, sel_registerName("setBorderColor:"),
                                       ((Msg_CGColor)objc_msgSend)(white, sel_registerName("CGColor")));

    // GR：运行时创建的 target 实例 + initWithTarget:action:
    gTapGR  = FTMakeGR(ClsTapGR, "handleTap:");
    gLongGR = FTMakeGR(ClsLongGR, "handleLong:");
    gPanGR  = FTMakeGR(ClsPanGR, "handlePan:");
    if (!gTapGR || !gLongGR || !gPanGR) {
        FTLog("setup failed: make GR");
    }
    ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR, sel_registerName("setNumberOfTapsRequired:"), (NSUInteger)2);
    // 长按：minimumPressDuration=0.25 → 稍微按住即触发连点（更跟手）。仍保留 require 双击
    // 失败，确保双击切换优先级；0.25s 足够短于双击间隔，不会抢双击。
    // allowableMovement=200：宽松容差，iPad 上手指自然抖动/微小移动不会误判失败
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setMinimumPressDuration:"), 0.25);
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setAllowableMovement:"), 200.0);
    // 让「双击」手势优先：长按/拖动都 require 双击失败后才识别。
    // 这样双击必然触发模式切换，长按/拖动只在「不是双击」时才生效，二者不再抢触摸。
    ((Msg_RequireToFail)objc_msgSend)(gLongGR, sel_registerName("requireGestureRecognizerToFail:"), gTapGR);
    ((Msg_RequireToFail)objc_msgSend)(gPanGR,  sel_registerName("requireGestureRecognizerToFail:"), gTapGR);
    // v1.0.74：关键修复——UITapGestureRecognizer 默认 cancelsTouchesInView=YES，会在手势
    // 识别/失败时把触摸判为 Cancelled(phase=4)，导致 sendEvent 里追踪的「球上手指」被清空、
    // 连点定时器立刻被取消（"点一下只触发一次 / 长按只算一次"，ctor-45 根因）。
    // 设 NO：手势照常识别双击，但不再取消触摸，按住的手指持续被追踪 → 连点持续。
    ((Msg_SetEnabled)objc_msgSend)(gTapGR,  sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gTapGR2, sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gLongGR, sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gPanGR,  sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setCancelsTouchesInView:"), NO);
    // 模式初始化：蓝色连击模式 → 启用长按、禁用拖动
    ((Msg_SetEnabled)objc_msgSend)(gLongGR, sel_registerName("setEnabled:"), YES);
    ((Msg_SetEnabled)objc_msgSend)(gPanGR,  sel_registerName("setEnabled:"), NO);

    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gTapGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gLongGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gPanGR);

    // v1.0.58：把球作为 subview 挂到 targetWin（优先 _UISystemGestureWindow，始终位于所有 App 之上）。
    // 这样球在游戏 / 前台 App 内也可见、可触摸；点击注入本身是绝对坐标，跟前台 App 无关。
    ((Msg_AddSubview)objc_msgSend)(targetWin, sel_registerName("addSubview:"), ball);

    // 点击点标记（独立视图，与球解耦）：默认位置 = gClickLockX/Y（初始屏幕中心 / App 配置点）。
    // 仅「红色拖动模式」可拖动；蓝色连击模式 userInteractionEnabled=NO → 点击穿透到下层 App。
    {
        CGFloat m = 30.0;
        CGRect mf = CGRectMake(gClickLockX * gScreenW - m / 2, gClickLockY * gScreenH - m / 2, m, m);
        gClickPointView = FTAllocInitWithFrame(ClsView, mf);
        if (gClickPointView) {
            ((Msg_SetUserInteractionEnabled)objc_msgSend)(gClickPointView, sel_registerName("setUserInteractionEnabled:"), gDragMode ? YES : NO);
            id mlayer = ((Msg_Layer)objc_msgSend)(gClickPointView, sel_registerName("layer"));
            ((Msg_SetCGFloat)objc_msgSend)(mlayer, sel_registerName("setCornerRadius:"), (CGFloat)(m / 2));
            ((Msg_SetCGFloat)objc_msgSend)(mlayer, sel_registerName("setBorderWidth:"), (CGFloat)2.5);
            id mcol = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"), 0.2, 1.0, 0.4, 1.0);
            ((Msg_SetBorderColor)objc_msgSend)(mlayer, sel_registerName("setBorderColor:"),
                ((Msg_CGColor)objc_msgSend)(mcol, sel_registerName("CGColor")));
            // 中心圆点（指示精确点击位置），tag=101 便于外观刷新时定位
            id dot = FTAllocInitWithFrame(ClsView, CGRectMake(m / 2 - 4, m / 2 - 4, 8, 8));
            if (dot) {
                id dlayer = ((Msg_Layer)objc_msgSend)(dot, sel_registerName("layer"));
                ((Msg_SetCGFloat)objc_msgSend)(dlayer, sel_registerName("setCornerRadius:"), (CGFloat)4);
                ((Msg_SetBackgroundColor)objc_msgSend)(dot, sel_registerName("setBackgroundColor:"), mcol);
                ((Msg_SetTag)objc_msgSend)(dot, sel_registerName("setTag:"), (NSInteger)101);
                ((Msg_AddSubview)objc_msgSend)(gClickPointView, sel_registerName("addSubview:"), dot);
            }
            gClickPanGR = FTMakeGR(ClsPanGR, "handleClickPan:");
            if (gClickPanGR) {
                ((Msg_RequireToFail)objc_msgSend)(gClickPanGR, sel_registerName("requireGestureRecognizerToFail:"), gTapGR);
                ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setEnabled:"), gDragMode ? YES : NO);
                ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setCancelsTouchesInView:"), NO); // v1.0.74
                ((Msg_AddGestureRecognizer)objc_msgSend)(gClickPointView, sel_registerName("addGestureRecognizer:"), gClickPanGR);
            }
            // 点击点标记上也挂一个双击手势（同一 toggle handler）——避免编辑模式下标记盖住球时，
            // 双击球无法命中、导致切不回连击模式。双击始终局部命中单一视图，不会双触发。
            gTapGR2 = FTMakeGR(ClsTapGR, "handleTap:");
            if (gTapGR2) {
                ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR2, sel_registerName("setNumberOfTapsRequired:"), (NSUInteger)2);
                ((Msg_RequireToFail)objc_msgSend)(gTapGR2, sel_registerName("requireGestureRecognizerToFail:"), gLongGR);
                ((Msg_RequireToFail)objc_msgSend)(gTapGR2, sel_registerName("requireGestureRecognizerToFail:"), gClickPanGR);
                ((Msg_RequireToFail)objc_msgSend)(gClickPanGR, sel_registerName("requireGestureRecognizerToFail:"), gTapGR2);
                ((Msg_SetEnabled)objc_msgSend)(gTapGR2, sel_registerName("setCancelsTouchesInView:"), NO); // v1.0.74
                ((Msg_AddGestureRecognizer)objc_msgSend)(gClickPointView, sel_registerName("addGestureRecognizer:"), gTapGR2);
            }
            ((Msg_AddSubview)objc_msgSend)(targetWin, sel_registerName("addSubview:"), gClickPointView);
            FTApplyClickPointAppearance();
        }
    }

    // v1.0.81：点击落点光圈——每次注入在点击点显示红圈（连点时常亮），直观看到"点击落在哪"。
    // App 里点空白处/备忘录默认不显示反馈，用户看不到落点，故自绘光圈。
    {
        CGFloat f = 26.0;
        gClickFlashView = FTAllocInitWithFrame(ClsView, CGRectMake(0, 0, f, f));
        if (gClickFlashView) {
            ((Msg_SetUserInteractionEnabled)objc_msgSend)(gClickFlashView, sel_registerName("setUserInteractionEnabled:"), NO);
            id flayer = ((Msg_Layer)objc_msgSend)(gClickFlashView, sel_registerName("layer"));
            ((Msg_SetCGFloat)objc_msgSend)(flayer, sel_registerName("setCornerRadius:"), (CGFloat)(f / 2));
            ((Msg_SetCGFloat)objc_msgSend)(flayer, sel_registerName("setBorderWidth:"), (CGFloat)3.0);
            id fcol = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.3, 0.2, 0.95);
            ((Msg_SetBorderColor)objc_msgSend)(flayer, sel_registerName("setBorderColor:"),
                ((Msg_CGColor)objc_msgSend)(fcol, sel_registerName("CGColor")));
            ((Msg_SetBackgroundColor)objc_msgSend)(gClickFlashView, sel_registerName("setBackgroundColor:"),
                ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.55, 0.35, 0.30));
            ((Msg_SetAlpha)objc_msgSend)(gClickFlashView, sel_registerName("setAlpha:"), 0.0);
            ((Msg_AddSubview)objc_msgSend)(targetWin, sel_registerName("addSubview:"), gClickFlashView);
        }
    }

    gBallContainer = targetWin;
    gBallView      = ball;
    FTApplyBallAppearance(); // 初始蓝色=连击模式

    // v1.0.55 诊断：报告球窗口层级（之前 ball 在独立 UIWindow 上行为诡异）
    CGRect ballFrameDiag = ((Msg_Frame)objc_msgSend)(ball, sel_registerName("frame"));
    id ballSuper = ((Msg_Send)objc_msgSend)(ball, sel_registerName("superview"));
    const char *superCls = ballSuper ? object_getClassName(ballSuper) : "?";
    char diag[256];
    id kw = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
    kw = kw ? ((Msg_Send)objc_msgSend)(kw, sel_registerName("keyWindow")) : nil;
    snprintf(diag, sizeof(diag),
        "ball attached: super=%s frame=%.0f,%.0f,%.0fx%.0f keyWin=%s",
        superCls,
        ballFrameDiag.origin.x, ballFrameDiag.origin.y, ballFrameDiag.size.width, ballFrameDiag.size.height,
        kw ? object_getClassName(kw) : "?");
    FTLog(diag);

    FTLog("ball created, gesture handlers wired");

    // v1.0.50：球创建后立即按 App 配置定位（若已加载配置）
    FTMoveBallToConfig();
}

// v1.0.50：移动球到 App 配置位置（球心 = 配置点击点；未加载配置则居中不动）
static void FTMoveBallToConfig(void) {
    if (!gBallView || !gCfgLoaded) return;
    if (gScreenW <= 0 || gScreenH <= 0) return;
    double px = gCfgX * gScreenW;
    double py = gCfgY * gScreenH;
    CGRect f = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
    ((Msg_SetFrame)objc_msgSend)(gBallView, sel_registerName("setFrame:"),
        CGRectMake(px - f.size.width * 0.5, py - f.size.height * 0.5,
                   f.size.width, f.size.height));
    // 同步点击点标记位置（连点打在配置点；与球解耦，二者可分别拖动）
    gClickLockX = gCfgX;
    gClickLockY = gCfgY;
    if (gClickPointView) {
        CGFloat m = 30.0;
        ((Msg_SetFrame)objc_msgSend)(gClickPointView, sel_registerName("setFrame:"),
            CGRectMake(gCfgX * gScreenW - m / 2, gCfgY * gScreenH - m / 2, m, m));
    }
    char diag[96];
    snprintf(diag, sizeof(diag), "ball moved to config %.2f,%.2f", gCfgX, gCfgY);
    FTLog(diag);
}

// MARK: - GCD C 函数回调（代替 block）——前向声明

static void FTEnsureBallCallback(void *ctx);
static void FTTweakInitCallback(void *ctx);
static void FTEnsureBall(int attempt);

static void FTEnsureBall(int attempt) {
    if (FTUIReady()) {
        FTSetupBall();
        return;
    }
    if (attempt >= 10) {
        FTLog("SB UI not ready after 20s, giving up");
        return;
    }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTEnsureBallCallback);
}

static void FTEnsureBallCallback(void *ctx) {
    (void)ctx;
    FTEnsureBall(0);
}

static void FTTweakInitCallback(void *ctx) {
    (void)ctx;
    FTLog("init callback, calling FTEnsureBall");
    // v1.0.50：App 通信（注册通知 + 心跳 + 读配置）——必须在 SB 完全启动后
    // （ctor 阶段任何 ObjC 调用在 arm64e 下 PAC 崩，v1.0.50 实测 Safe Mode）
    FTRegisterNotifications();
    // v1.0.53：移除 FT_HIDStartSenderIDCapture——arm64e SB 里注册 IOHID 事件回调
    // 是 Safe Mode 元凶（实测两次崩）；senderID 用硬编码兜底值即可。
    FTDumpEventIvars();
    FTEnsureBall(0);

    // v1.0.53.1：延迟 60s 再枚举 App 列表（60s 期间 SB 完全稳定）。
    // 之前在 30s init 内合并调用，FTWriteAppsList 内 objc_msgSend 触发 Safe Mode。
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTAppsListDeferredCallback);
}

// MARK: - 诊断 hook（v1.0.29 临时）：观察注入触摸是否到达 UIKit 层
// 只读：%orig 先调，再节流打印 event 的触摸数与命中的 view 类。
// 判断：注入若到达，日志会高频出现 SEND touches=1 view=<下层view类>；
//       若完全没有注入相关记录 → HID 事件在 IOKit/BackBoard 层被丢弃。

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig;
    // v1.0.61：从事件流直接捕获系统手势窗口实例。
    // 已知真实触摸始终流经 _UISystemGestureWindow（日志 win= 字段印证），
    // 而 [UIApplication windows] 与部分 iOS 版本的枚举类方法都枚举不到它。
    // 捕获一次即可作为球的挂载容器，彻底绕开枚举盲区。
    if (!gGestureWin) {
        const char *cn = object_getClassName(self);
        if (cn && (strstr(cn, "SystemGesture") || strstr(cn, "GestureWindow") || strstr(cn, "FBSystemGesture"))) {
            gGestureWin = self;
            FTLog("captured system gesture window from sendEvent");
            // v1.0.68：若球此前挂在兜底窗口（如 SBRecordingIndicatorWindow），立即异步重挂到正确窗口。
            if (gBallView) {
                dispatch_async_f(dispatch_get_main_queue(), NULL, FTReparentBallToGestureWin);
            }
        }
    }
    // v1.0.64：从真实触摸事件的 _hidEvent 动态捕获设备 senderID（逻辑在 HIDInject.c，
    // 纯 C 绕开 Theos 对 Tweak.xm 的 ARC 限制——object_getInstanceVariable 在 ARC 下禁用）。
    // 仅接受 digitizer 触摸事件（type=11）的 senderID——ctor-10 实测抓到手势事件的
    // 非法 senderID(0x1000007b1) 会导致 DispatchEvent 返回 0x1。硬编码 senderID 在
    // Dopamine rootless + iOS 15.5 上会被系统静默丢弃，故必须捕获真实设备值。
    if (event) {
        FT_HIDCaptureSenderIDFromUIEvent((__bridge void *)event);
    }
    // v1.0.71：按「触摸身份」追踪按在球上的用户手指，驱动连点（替代 UILongPressGR）。
    // 免疫两大致命干扰：① 游戏内多点触摸（第 2 根手指）会让 UILongPress 被判 Cancelled；
    // ② 合成注入触摸（点击点==球心时落回球上）会让 UILongPress 收 2nd touch 取消。
    // 只认「在球内 Began 的那一根触摸」，合成触摸因指针身份不同被忽略；且只在按住 >120ms 后才连点，
    // 避免双击切模式时误触发连点。
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;

    if (gBallView && event && !gDragMode) {
        id tset = ((Msg_Send)objc_msgSend)(event, sel_registerName("allTouches"));
        // ⚠️ allTouches 返回 NSSet（非数组），必须用 allObjects 转成 NSArray 才能 objectAtIndex:
        // 直接对 NSSet 调 objectAtIndex: 会抛 unrecognized selector → SB 崩溃 → Safe Mode（ctor-42 真凶）。
        id tarr = tset ? ((Msg_Send)objc_msgSend)(tset, sel_registerName("allObjects")) : nil;
        NSUInteger tn = tarr ? ((Msg_Count)objc_msgSend)(tarr, sel_registerName("count")) : 0;
        CGRect bf = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
        for (NSUInteger i = 0; i < tn; i++) {
            id t = ((Msg_ObjectAtIndex)objc_msgSend)(tarr, sel_registerName("objectAtIndex:"), i);
            if (!t) continue;
            long ph = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("phase"));
            CGPoint loc = ((Msg_LocationInView)objc_msgSend)(t, sel_registerName("locationInView:"), nil);
            BOOL onBall = (loc.x >= bf.origin.x && loc.x <= bf.origin.x + bf.size.width &&
                          loc.y >= bf.origin.y && loc.y <= bf.origin.y + bf.size.height);
            void *tp = (__bridge void *)t;
            if (ph == 0) {                                   // Began
                if (onBall && gBallTouch == NULL) {
                    gBallTouch = tp;
                    gBallTouchDownTime = now;
                    // v1.0.80：若正在连点且系统因注入把上一根手指 Ended 后重发了 Began
                    // （用户仍物理按着），重绑并【取消松手宽限】，连点继续。
                    if (gIsClicking) {
                        gStopGracePending = NO;
                        gBallTouchClicking = YES;
                    } else {
                        // 排一个 120ms 延时计时器：到时若手指仍按着（gBallTouch 不变）且非拖动模式，
                        // 就开连点。⚠️ 不能等 Moved/Stationary 事件——静止按住时 iOS 不投递这些事件
                        // （ctor-44 实测：1.6s 按住零 phase=1/2，导致旧逻辑从未触发、零点击）。
                        if (!gBallTouchTimerPending) {
                            gBallTouchTimerPending = YES;
                            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                                             dispatch_get_main_queue(), NULL, FTBallHoldTimer);
                        }
                    }
                }
            } else if (ph == 1 || ph == 2) {                 // Moved / Stationary（仅作保险，主要靠计时器）
                if (gBallTouch == tp && !gBallTouchClicking && !gDragMode &&
                    (now - gBallTouchDownTime) > 0.12 && !gBallTouchTimerPending) {
                    gBallTouchClicking = YES;
                    FTStartClicking();
                }
            } else if (ph == 3 || ph == 4) {                 // Ended / Cancelled
                if (gBallTouch == tp) {
                    gBallTouch = NULL;
                    gBallTouchTimerPending = NO;
                    // v1.0.80：触摸结束【不立即停连点】——注入合成触摸会让系统把按住的手指
                    // Ended（ctor-53 铁证：clicking started 与 stopped 同戳、SEND 同时显示
                    // 用户手指仍在球上）。用户仍物理按着时系统会重发 Began（重绑已取消宽限）。
                    // 只有宽限 400ms 内没有新 Began（真松手）才停止。
                    gBallTouchClicking = NO;
                    if (gIsClicking && !gStopGracePending) {
                        gStopGracePending = YES;
                        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                         dispatch_get_main_queue(), NULL, FTStopGraceTimer);
                    }
                }
            }
        }
    }

    // 诊断节流（保留原 SEND 日志）
    static double sLastDiag = 0;
    if (now - sLastDiag < 0.5) return; // 节流 500ms
    sLastDiag = now;
    if (!event) return;
    id touches = ((Msg_Send)objc_msgSend)(event, sel_registerName("allTouches"));
    NSUInteger n = touches ? ((Msg_Count)objc_msgSend)(touches, sel_registerName("count")) : 0;
    if (n == 0) return;
    // v1.0.42 诊断：标记命中窗口是否为我们的球窗口（区分注入触摸被拦截 vs 到达下层）
    // v1.0.44 诊断：加 UITouch phase/tapCount（判断 down/up 是否关联成完整 tap）
    // v1.0.49 诊断：加 locationInWindow 像素坐标——判断坐标单位是否被 UIKit 误解
    //  （注入传归一化 0~1，若 UIKit 期望像素 → 触摸落在屏幕角落 → hitTest 命中不了图标）
    // v1.0.55+：球现在是 window 的 subview（非独立 window），self==gBallContainer 不可靠。
    // v1.0.58：gBallContainer 改为 _UISystemGestureWindow（接收所有触摸），self==gBallContainer 恒真。
    // 因此 isBall 只判触摸坐标是否落在球 frame 内——命中球时 ball=1，否则 0。
    const char *cls = "?";
    const char *winCls = object_getClassName(self);
    if (!winCls) winCls = "?";
    long ph = -1, tapc = -1;
    double lx = -1, ly = -1;
    id t = ((Msg_AnyObject)objc_msgSend)(touches, sel_registerName("anyObject"));
    if (t) {
        id v = ((Msg_Send)objc_msgSend)(t, sel_registerName("view"));
        if (v) cls = object_getClassName(v);
        ph = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("phase"));
        tapc = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("tapCount"));
        CGPoint loc = ((Msg_LocationInView)objc_msgSend)(t, sel_registerName("locationInView:"), nil);
        lx = loc.x; ly = loc.y;
    }
    BOOL isBall = NO;
    if (gBallView && lx >= 0 && ly >= 0) {
        CGRect bf = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
        if (lx >= bf.origin.x && lx <= bf.origin.x + bf.size.width &&
            ly >= bf.origin.y && ly <= bf.origin.y + bf.size.height) {
            isBall = YES;
        }
    }
    char buf[240];
    snprintf(buf, sizeof(buf), "SEND touches=%lu view=%s win=%s ball=%d phase=%ld tap=%ld loc=%.1f,%.1f",
             (unsigned long)n, cls, winCls, isBall ? 1 : 0, ph, tapc, lx, ly);
    FTLog(buf);
}
%end

// v1.0.41 诊断 hook：确认真实触摸是否经过 UIApplication _handleHIDEvent:（HID 入口）
%hook UIApplication
- (void)_handleHIDEvent:(void *)event {
    %orig;
    static double sLastHID = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    if (now - sLastHID < 1.0) return; // 节流 1s
    sLastHID = now;
    if (event) FTLog("UIApp handleHIDEvent called");
}
%end

// MARK: - 入口（纯 C constructor，等效 %ctor 但无 Logos 依赖、零 ObjC）

__attribute__((constructor))
static void FTTweakCtor(void) {
    syslog(LOG_ERR, "FloatingTap v1.0.81 loaded (click-point flash indicator; hold-to-combo; 400ms release grace)");

    // v1.0.50：对接 AutoTap App——App 是启动器（选目标 App/位置/间隔），tweak 执行。
    if (FTIsBundle("com.apple.springboard")) {
        // 【诊断标记】SB 进程覆盖写
        FILE *mk = fopen("/tmp/floatingtap_ctor.log", "w");
        if (mk) {
            fprintf(mk, "FloatingTap v1.0.81 ctor run (arm64e, pure C, ball on _UISystemGestureWindow; click-point flash; hold-to-combo; 400ms release grace)\n");
            fclose(mk);
        }
        syslog(LOG_ERR, "FloatingTap role: SpringBoard controller");

        // ⚠️ v1.0.50 教训：FTRegisterNotifications 不能放 ctor——它内部有 ObjC 动态调用
        // （FTStr/NSDictionary），%ctor 阶段 ObjC 调用在 arm64e 下 PAC 崩 → Safe Mode。
        // 已移到 FTTweakInitCallback（SB 完全启动 30s 后）。

        // 延迟 30s 等 SB 完全启动，再动态创建悬浮球
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTTweakInitCallback);
    }
}

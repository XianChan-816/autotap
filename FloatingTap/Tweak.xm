//
//  Tweak.xm — FloatingTap v1.0.50
//
//  架构（用户原设计）：AutoTap App = 启动器（选目标 App / 拖动十字线定位置 / 间隔），
//  FloatingTap tweak = 执行器。App 端协议（TargetAppManager.swift）早已定义，
//  tweak 端此前从未对接——v1.0.50 补齐通信：
//    - 监听 Darwin 通知（CFNotificationCenter，纯 C）：appStarted / configUpdated
//    - sysctl KERN_PROC_ALL 找 AutoTap PID + sandbox_container_path_for_pid 反查沙盒
//    - 写心跳 FloatingTap.tweak.plist（App 显示"已加载"）
//    - 读 AutoTapConfig.plist（ClickX/ClickY/IntervalMs）→ 球按配置定位 + 连点用配置坐标
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
typedef void       (*Msg_SetBorderColor)(id, SEL, CGColorRef);
typedef void       (*Msg_SetWindowLevel)(id, SEL, CGFloat);
typedef void       (*Msg_SetHidden)(id, SEL, BOOL);
typedef void       (*Msg_SetUserInteractionEnabled)(id, SEL, BOOL);
typedef void       (*Msg_AddGestureRecognizer)(id, SEL, id);
typedef void       (*Msg_AddSubview)(id, SEL, id);
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

static id gBallWindow = nil;
static id gBallView   = nil;
static id gTapGR      = nil;
static id gLongGR     = nil;

static CGPoint gPanStartLoc;   // 触摸起始点（窗口坐标）
static CGPoint gPanOrigin0;    // 触摸起始时窗口 frame.origin
static BOOL    gPanActive = NO;

static double  gScreenW = 0;   // 主屏尺寸（FTSetupBall 时保存）
static double  gScreenH = 0;

static BOOL    gIsClicking = NO;            // 连点进行中
static uint32_t gTapIndex = 0;              // 每次 tap 递增的 index（区分触摸，避免被串流）
static double  gClickLockX = 0;             // 连点锁定坐标（长按开始时球心，拖动不改变）
static double  gClickLockY = 0;
static dispatch_source_t gClickTimer = NULL; // 连点定时器（SB 端直接注入用）

// v1.0.50：AutoTap App 配置（位置/间隔）——定义在 FTIntervalMs 之前（它要读）
static double gCfgX = 0.5, gCfgY = 0.5, gCfgMs = 400.0;
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

// 读取连点间隔（毫秒）：优先 App 配置（v1.0.50），兜底 cfg 文件，默认 400ms。
// ⚠️ v1.0.46：默认 400ms——iOS 双击识别窗口约 350ms，间隔小于它会触发 tapCount 累积
// （v1.0.45 实测 tap=4），图标被当成多击不启动。400ms 以上每次点击独立 tapCount=1。
static double FTIntervalMs(void) {
    if (gCfgLoaded && gCfgMs >= 1.0) return gCfgMs;
    FILE *f = fopen("/var/mobile/Library/Preferences/com.floatingtap.cfg", "r");
    if (f) {
        double v = 400.0;
        if (fscanf(f, "%lf", &v) == 1 && v >= 1.0 && v <= 60000.0) {
            fclose(f);
            return v;
        }
        fclose(f);
    }
    return 400.0;
}

// MARK: - App 通信（v1.0.50 对接 AutoTap App）
// 协议（见 AutoTap/Sources/TargetAppManager.swift，App 端早已定义，tweak 端此前从未对接）：
//  - 配置：<AutoTap沙盒>/Library/Caches/AutoTapConfig.plist
//    keys：Targets([String]) / IntervalMs / ClickX / ClickY（归一化 0~1）
//  - tweak 写心跳：<AutoTap沙盒>/Library/Caches/FloatingTap.tweak.plist（_loaded / _time 毫秒）
//  - tweak 写枚举：FloatingTap.apps.plist + FloatingTap.apps.status.plist（下一步）
//  - Darwin 通知：com.floatingtap.autotap.appStarted / configUpdated / tweakDataUpdated
// 实现：CFNotificationCenter（纯 C API）+ sysctl 找 PID + sandbox_container_path_for_pid 反查沙盒。

typedef id         (*Msg_StringWithUTF8String)(id, SEL, const char *);
typedef id         (*Msg_DictWithFile)(id, SEL, id);
typedef id         (*Msg_ObjectForKey)(id, SEL, id);
typedef double     (*Msg_DoubleValue)(id, SEL);

static char gAutoTapSandbox[1024] = "";  // AutoTap App 沙盒路径（缓存）
static int  gAutoTapSandboxReady = 0;

// 运行时创建 NSString（禁止 @"..."：arm64e PAC 元数据雷区）
static id FTStr(const char *s) {
    Class ClsStr = objc_getClass("NSString");
    if (!ClsStr) return nil;
    return ((Msg_StringWithUTF8String)objc_msgSend)((id)ClsStr, sel_registerName("stringWithUTF8String:"), s);
}

// 通过进程名找 PID（sysctl KERN_PROC_ALL，纯 C）
static pid_t FTFindPIDByName(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return -1; }
    int n = (int)(len / sizeof(struct kinfo_proc));
    pid_t found = -1;
    for (int i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

// 反查 AutoTap 沙盒路径（sandbox_container_path_for_pid，dlsym 动态解析）
static void FTResolveAutoTapSandbox(void) {
    if (gAutoTapSandboxReady) return;
    gAutoTapSandboxReady = 1; // 只尝试一次（App 不在运行则等下次 appStarted 通知重试）
    pid_t pid = FTFindPIDByName("AutoTap");
    if (pid <= 0) { FTLog("autotap: process not running"); return; }
    static const char *(*p_sandbox_container_path_for_pid)(pid_t) = NULL;
    if (!p_sandbox_container_path_for_pid) {
        p_sandbox_container_path_for_pid =
            (const char *(*)(pid_t))dlsym(RTLD_DEFAULT, "sandbox_container_path_for_pid");
    }
    if (!p_sandbox_container_path_for_pid) { FTLog("autotap: no sandbox symbol"); return; }
    const char *sp = p_sandbox_container_path_for_pid(pid);
    if (!sp || !*sp) { FTLog("autotap: sandbox path empty"); return; }
    snprintf(gAutoTapSandbox, sizeof(gAutoTapSandbox), "%s", sp);
    gAutoTapSandboxReady = 2; // 成功
    char diag[300];
    snprintf(diag, sizeof(diag), "autotap sandbox: %s", gAutoTapSandbox);
    FTLog(diag);
}

// 写心跳（FloatingTap.tweak.plist，手动生成 XML plist，零 ObjC 元数据）
static void FTWriteHeartbeat(void) {
    FTResolveAutoTapSandbox();
    if (gAutoTapSandboxReady != 2) return;
    char path[1150];
    snprintf(path, sizeof(path), "%s/Library/Caches/FloatingTap.tweak.plist", gAutoTapSandbox);
    FILE *f = fopen(path, "w");
    if (!f) return;
    double now = (double)time(NULL) * 1000.0; // App 端 _time 为毫秒
    fprintf(f, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
               "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
               "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
               "<plist version=\"1.0\">\n<dict>\n"
               "\t<key>_loaded</key>\n\t<true/>\n"
               "\t<key>_time</key>\n\t<real>%.0f</real>\n"
               "</dict>\n</plist>\n", now);
    fclose(f);
    FTLog("heartbeat written");
}

// 读配置（dictionaryWithContentsOfFile: 动态调用）
static id FTReadConfigDict(void) {
    FTResolveAutoTapSandbox();
    if (gAutoTapSandboxReady != 2) return nil;
    char path[1150];
    snprintf(path, sizeof(path), "%s/Library/Caches/AutoTapConfig.plist", gAutoTapSandbox);
    id fstr = FTStr(path);
    if (!fstr) return nil;
    Class ClsDict = objc_getClass("NSDictionary");
    if (!ClsDict) return nil;
    return ((Msg_DictWithFile)objc_msgSend)((id)ClsDict, sel_registerName("dictionaryWithContentsOfFile:"), fstr);
}

static double FTConfigDouble(id dict, const char *key, double def) {
    if (!dict) return def;
    id k = FTStr(key);
    if (!k) return def;
    id v = ((Msg_ObjectForKey)objc_msgSend)(dict, sel_registerName("objectForKey:"), k);
    if (!v) return def;
    return ((Msg_DoubleValue)objc_msgSend)(v, sel_registerName("doubleValue"));
}

// 移动球到配置位置（球心 = 配置点击点）；同步锁定坐标
static void FTMoveBallToConfig(void);

// 应用配置：更新间隔 + 移动球
static void FTApplyConfig(void) {
    id dict = FTReadConfigDict();
    if (!dict) { FTLog("config: no dict"); return; }
    double nx = FTConfigDouble(dict, "ClickX", 0.5);
    double ny = FTConfigDouble(dict, "ClickY", 0.5);
    double ms = FTConfigDouble(dict, "IntervalMs", 400.0);
    if (ms < 1.0) ms = 400.0;
    if (nx < 0.0) nx = 0.0; if (nx > 1.0) nx = 1.0;
    if (ny < 0.0) ny = 0.0; if (ny > 1.0) ny = 1.0;
    gCfgX = nx; gCfgY = ny; gCfgMs = ms;
    gCfgLoaded = 1;
    FTMoveBallToConfig();
    char diag[128];
    snprintf(diag, sizeof(diag), "config loaded x=%.2f y=%.2f ms=%.0f", nx, ny, ms);
    FTLog(diag);
}

// Darwin 通知回调（纯 C；observer=静态占位，靠 name 区分）
static int sNotifyObserver = 0;
static void FTNotificationCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object; (void)userInfo;
    char buf[256];
    if (!name || !CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)) return;
    if (strcmp(buf, "com.floatingtap.autotap.appStarted") == 0) {
        FTLog("got appStarted");
        // App（重新）启动：强制重试反查沙盒（之前可能因 App 未运行失败）
        gAutoTapSandboxReady = 0;
        FTResolveAutoTapSandbox();
        FTWriteHeartbeat();
    } else if (strcmp(buf, "com.floatingtap.autotap.configUpdated") == 0) {
        FTLog("got configUpdated");
        FTApplyConfig();
    }
}

// 注册 Darwin 通知监听（name 需长期有效 → 存 static）
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
    FTLog("notifications registered");
    // 启动即尝试：App 可能已运行（心跳证明 tweak 活着）
    FTResolveAutoTapSandbox();
    FTWriteHeartbeat();
    FTApplyConfig();
}

// 恢复球窗口交互（注入后 60ms 回调）

// MARK: - 连点注入
// v1.0.41：走 [UIApplication _handleHIDEvent:]（UIKit 原生 HID 入口）——注入已确认
// 到达 UIKit（UIApp handleHIDEvent called 对齐 + SEND ball=0 到下层窗口）。
// v1.0.43：down 立即发，up 延迟 50ms 发（社区标准做法）——让 UIKit 把 down/up
// 关联为同一触摸（v1.0.42 实测 down+up 零间隔可能被当作两个独立触摸，tap 手势不触发）。

static double gPendingUpX = 0;
static double gPendingUpY = 0;
static uint32_t gPendingUpIndex = 0;
static void FTSendHIDUpCallback(void *ctx);

// 发送一次 up（延迟回调）
static void FTSendHIDUpCallback(void *ctx) {
    (void)ctx;
    @try {
        Class ClsApp = objc_getClass("UIApplication");
        if (!ClsApp) return;
        id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
        if (!app) return;
        FT_IOHIDEventRef up = FT_HIDCreateDigitizerEvent(false, gPendingUpX, gPendingUpY, gPendingUpIndex);
        if (up) {
            ((Msg_SendID)objc_msgSend)(app, sel_registerName("_handleHIDEvent:"), up);
            CFRelease(up);
        }
    } @catch (NSException *ex) {
        (void)ex;
    }
}

// 在屏幕像素点 (px,py) 发一次合成点击（down 立即 + up 延迟 50ms；每次 tap index 递增）
static void FTSyntheticTap(double px, double py) {
    @try {
        double nx = (gScreenW > 0) ? px / gScreenW : 0.5;
        double ny = (gScreenH > 0) ? py / gScreenH : 0.5;
        if (nx < 0.001) nx = 0.001; if (nx > 0.999) nx = 0.999;
        if (ny < 0.001) ny = 0.001; if (ny > 0.999) ny = 0.999;

        Class ClsApp = objc_getClass("UIApplication");
        if (!ClsApp) return;
        id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
        if (!app) return;

        // 每次 tap 递增 index（v1.0.45：避免 UIKit 把连续注入事件串成同一触摸流）
        gTapIndex = (gTapIndex % 19) + 1;
        uint32_t idx = gTapIndex;

        // down 立即
        FT_IOHIDEventRef down = FT_HIDCreateDigitizerEvent(true, nx, ny, idx);
        if (down) {
            ((Msg_SendID)objc_msgSend)(app, sel_registerName("_handleHIDEvent:"), down);
            CFRelease(down);
        }
        // up 延迟 50ms（关联同一触摸）
        gPendingUpX = nx;
        gPendingUpY = ny;
        gPendingUpIndex = idx;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTSendHIDUpCallback);
    } @catch (NSException *ex) {
        (void)ex;
        FTLog("inject exception");
    }
}

// MARK: - SB 端直接注入（v1.0.48 恢复：抖音双进程方案暂停，先把基本连点修好）
// v1.0.47 曾把 SB 端注入改为写任务文件交给抖音进程，但抖音沙盒 /tmp 隔离导致通信失败。
// 现恢复 SB 进程内直接注入（_handleHIDEvent: 路线，v1.0.41~46 已验证能到达 UIKit）。
// 注意：注入只对 SB 自己的窗口有效（主屏幕/系统 UI）；前台 App 需后续进程方案。

static void FTRestoreBallInteractionCallback(void *ctx);

// 连点回调：在锁定坐标发一次合成点击。
// ⚠️ 注入坐标=球心，球窗口(windowLevel 1001)正好在球心，注入触摸会先命中球窗口被吃掉。
// 注入瞬间关掉球窗口交互（userInteractionEnabled=NO → 不参与 hitTest → 穿透），60ms 后恢复。
static void FTClickCallback(void *ctx) {
    (void)ctx;
    if (!gBallWindow || !gIsClicking) return;

    // 注入前：球窗口不参与 hitTest → 注入触摸穿透到下层
    ((Msg_SetUserInteractionEnabled)objc_msgSend)(gBallWindow, sel_registerName("setUserInteractionEnabled:"), NO);

    FTSyntheticTap(gClickLockX * gScreenW, gClickLockY * gScreenH);
    gClickCount++;

    char diag[96];
    snprintf(diag, sizeof(diag), "inject tap nx=%.2f ny=%.2f", gClickLockX, gClickLockY);
    FTLog(diag);

    // 60ms 后恢复交互（连点 400ms 间隔，恢复后用户可松手停止）
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTRestoreBallInteractionCallback);
}

static void FTRestoreBallInteractionCallback(void *ctx) {
    (void)ctx;
    if (gBallWindow) {
        ((Msg_SetUserInteractionEnabled)objc_msgSend)(gBallWindow, sel_registerName("setUserInteractionEnabled:"), YES);
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
    if (gCfgLoaded) {
        // v1.0.50：App 配置优先——点击点 = 配置坐标（球已移动到该位置）
        gClickLockX = gCfgX;
        gClickLockY = gCfgY;
    } else if (gBallWindow) {
        // 无配置：锁定当前球心（v1.0.45：拖动球不改变注入点，避免 tap 因移动失败）
        CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame"));
        double cx = f.origin.x + f.size.width * 0.5;
        double cy = f.origin.y + f.size.height * 0.5;
        gClickLockX = (gScreenW > 0) ? cx / gScreenW : 0.5;
        gClickLockY = (gScreenH > 0) ? cy / gScreenH : 0.5;
        if (gClickLockX < 0.001) gClickLockX = 0.001; if (gClickLockX > 0.999) gClickLockX = 0.999;
        if (gClickLockY < 0.001) gClickLockY = 0.001; if (gClickLockY > 0.999) gClickLockY = 0.999;
    }
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
    FTLog("clicking started");
}

static void FTStopClicking(void) {
    if (!gIsClicking) return;
    gIsClicking = NO;
    if (gClickTimer) {
        dispatch_source_cancel(gClickTimer);
        gClickTimer = NULL;
    }
    FTLog("clicking stopped");
    char buf[96];
    snprintf(buf, sizeof(buf), "clicks this period: %lu", gClickCount);
    FTLog(buf);
}

// MARK: - 动态 GR target（运行时创建类，零静态 ObjC 元数据）

static Class gGRTargetClass = nil;
static id    gGRTarget      = nil;

// Long 回调：一碰即连点 + 拖动（Changed 状态拖动球，删除 Pan GR 避免手势冲突）
static void FTGRLongHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr || !gBallWindow) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 1) { // Began
        gPanStartLoc = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gBallWindow);
        gPanOrigin0  = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame")).origin;
        gPanActive   = YES;
        FTStartClicking();
    } else if (st == 2 && gPanActive) { // Changed → 拖动球
        CGPoint cur = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gBallWindow);
        CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame"));
        ((Msg_SetFrame)objc_msgSend)(gBallWindow, sel_registerName("setFrame:"),
            CGRectMake(gPanOrigin0.x + (cur.x - gPanStartLoc.x),
                       gPanOrigin0.y + (cur.y - gPanStartLoc.y),
                       f.size.width, f.size.height));
    } else if (st == 3 || st == 4 || st == 5) { // Ended / Cancelled / Failed
        gPanActive = NO;
        FTStopClicking();
    }
}

// Tap 回调：双击 → 停止连点并隐藏球
static void FTGRTapHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 3) { // Ended（双击完成）
        FTLog("double tap, hiding ball");
        FTStopClicking();
        if (gBallWindow) {
            ((Msg_SetHidden)objc_msgSend)(gBallWindow, sel_registerName("setHidden:"), YES);
        }
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

// MARK: - 创建小球

static void FTSetupBall(void) {
    if (gBallWindow) return;

    Class ClsWindow = objc_getClass("UIWindow");
    Class ClsView   = objc_getClass("UIView");
    Class ClsScreen = objc_getClass("UIScreen");
    Class ClsColor  = objc_getClass("UIColor");
    Class ClsTapGR  = objc_getClass("UITapGestureRecognizer");
    Class ClsLongGR = objc_getClass("UILongPressGestureRecognizer");
    if (!ClsWindow || !ClsView || !ClsScreen || !ClsColor || !ClsTapGR || !ClsLongGR) {
        FTLog("setup failed: system class missing");
        return;
    }
    if (!FTMakeGRTarget()) {
        FTLog("setup failed: make GR target");
        return;
    }

    id mainScreen = ((Msg_Send)objc_msgSend)((id)ClsScreen, sel_registerName("mainScreen"));
    CGRect sb = ((Msg_Bounds)objc_msgSend)(mainScreen, sel_registerName("bounds"));
    gScreenW = sb.size.width;
    gScreenH = sb.size.height;
    CGFloat d = 56.0;
    CGRect ballFrame = CGRectMake(sb.size.width / 2 - d / 2, sb.size.height / 2 - d / 2, d, d);

    // 独立小球窗口：只有小球大小 → 区域外触摸天然穿透
    id win = FTAllocInitWithFrame(ClsWindow, ballFrame);

    // iOS 13+：挂到当前活跃的 UIWindowScene，否则不渲染
    id scene = FTGetActiveWindowScene();
    if (scene) {
        ((Msg_SetWindowScene)objc_msgSend)(win, sel_registerName("setWindowScene:"), scene);
    }

    ((Msg_SetWindowLevel)objc_msgSend)(win, sel_registerName("setWindowLevel:"), (CGFloat)1001.0);

    id ball = FTAllocInitWithFrame(ClsView, CGRectMake(0, 0, d, d));
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
    if (!gTapGR || !gLongGR) {
        FTLog("setup failed: make GR");
    }
    ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR, sel_registerName("setNumberOfTapsRequired:"), (NSUInteger)2);
    // 长按：minimumPressDuration=0 → 手指一碰立即 Began（开始连点），
    // Changed 状态拖动球（删除 Pan GR 避免手势冲突）。
    // allowableMovement=200：宽松容差，iPad 上手指自然抖动/微小移动不会误判失败
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setMinimumPressDuration:"), 0.0);
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setAllowableMovement:"), 200.0);

    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gTapGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gLongGR);

    // 直接把 ball 加到 window（不走 VC），更可靠
    ((Msg_AddSubview)objc_msgSend)(win, sel_registerName("addSubview:"), ball);

    ((Msg_SetHidden)objc_msgSend)(win, sel_registerName("setHidden:"), NO);
    ((Msg_MakeKeyAndVisible)objc_msgSend)(win, sel_registerName("makeKeyAndVisible"));

    gBallWindow = win;
    gBallView   = ball;

    FTLog("ball created, gesture handlers wired");

    // v1.0.50：球创建后立即按 App 配置定位（若已加载配置）
    FTMoveBallToConfig();
}

// v1.0.50：移动球到 App 配置位置（球心 = 配置点击点；未加载配置则居中不动）
static void FTMoveBallToConfig(void) {
    if (!gBallWindow || !gCfgLoaded) return;
    if (gScreenW <= 0 || gScreenH <= 0) return;
    double px = gCfgX * gScreenW;
    double py = gCfgY * gScreenH;
    CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame"));
    ((Msg_SetFrame)objc_msgSend)(gBallWindow, sel_registerName("setFrame:"),
        CGRectMake(px - f.size.width * 0.5, py - f.size.height * 0.5,
                   f.size.width, f.size.height));
    // 同步锁定坐标（连点打在配置点）
    gClickLockX = gCfgX;
    gClickLockY = gCfgY;
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
    // v1.0.50：App 通信（注册通知 + 反查沙盒 + 心跳 + 读配置）——必须在 SB 完全启动后
    // （ctor 阶段任何 ObjC 调用在 arm64e 下 PAC 崩，v1.0.50 实测 Safe Mode）
    FTRegisterNotifications();
    // 启动 senderID 捕获（zxtouch 机制：用户下次真实触摸时提取设备专属 senderID）
    FT_HIDStartSenderIDCapture();
    FTDumpEventIvars();
    FTEnsureBall(0);
}

// MARK: - 诊断 hook（v1.0.29 临时）：观察注入触摸是否到达 UIKit 层
// 只读：%orig 先调，再节流打印 event 的触摸数与命中的 view 类。
// 判断：注入若到达，日志会高频出现 SEND touches=1 view=<下层view类>；
//       若完全没有注入相关记录 → HID 事件在 IOKit/BackBoard 层被丢弃。

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig;
    static double sLastDiag = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
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
    BOOL isBall = (self == gBallWindow);
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
    syslog(LOG_ERR, "FloatingTap v1.0.50 loaded (pure C ctor, zero static ObjC metadata)");

    // v1.0.50：对接 AutoTap App——App 是启动器（选目标 App/位置/间隔），tweak 执行。
    if (FTIsBundle("com.apple.springboard")) {
        // 【诊断标记】SB 进程覆盖写
        FILE *mk = fopen("/tmp/floatingtap_ctor.log", "w");
        if (mk) {
            fprintf(mk, "FloatingTap v1.0.50 ctor run (arm64e, pure C)\n");
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

//
//  Tweak.xm — FloatingTap v1.0.47
//
//  v1.0.47 双进程架构（解决进程隔离：SB 进程注入的触摸到不了前台 App）：
//    - Filter 增加抖音 com.ss.iphone.ugc.Aweme
//    - SB 进程（控制端）：球+手势；长按 → 写 /tmp/FloatingTap.task（start x y ms / stop）
//    - 抖音进程（执行端）：ctor 初始化屏幕尺寸 → 100ms 轮询任务文件 → 收到 start
//      后在本进程内 FTSyntheticTap（_handleHIDEvent: 注入，命中抖音自己的窗口）
//  v1.0.44 实测：注入触摸在 SB 进程 tapCount 累积（注入引擎有效）但直播间无反应
//  = 进程隔离。v1.0.45/46：坐标锁定 + index 递增 + 间隔 400ms（避开双击窗口）。
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
#import <syslog.h>
#import <time.h>
#import <stdint.h>
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

// 读取连点间隔（毫秒）：/var/mobile/Library/Preferences/com.floatingtap.cfg 第一行数字。
// ⚠️ v1.0.46：默认 400ms——iOS 双击识别窗口约 350ms，间隔小于它会触发 tapCount 累积
// （v1.0.45 实测 tap=4），图标被当成多击不启动。400ms 以上每次点击独立 tapCount=1。
static double FTIntervalMs(void) {
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

// MARK: - 抖音进程（v1.0.47 注入执行端）
// SB 端长按 → 写 /tmp/FloatingTap.task（start x y ms / stop）→ 抖音进程轮询执行注入。
// 进程隔离：SB 进程注入的触摸到不了前台 App（抖音），必须在抖音进程内注入。

static char gTaskLast[64] = "";
static BOOL gTaskRunning = NO;
static double gTaskX = 0.5, gTaskY = 0.5, gTaskMs = 400.0;
static dispatch_source_t gTaskTimer = NULL; // 注入 timer
static dispatch_source_t gPollTimer = NULL; // 任务文件轮询

static void FTAppClickCallback(void *ctx);
static void FTAppStartPollingCallback(void *ctx);

static void FTAppStartClicking(double x, double y, double ms) {
    gTaskRunning = YES;
    gTaskX = x; gTaskY = y; gTaskMs = ms;
    if (gTaskTimer) { dispatch_source_cancel(gTaskTimer); gTaskTimer = NULL; }
    gTaskTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gTaskTimer) {
        dispatch_source_set_timer(gTaskTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                                  (uint64_t)(ms * NSEC_PER_MSEC), 0);
        dispatch_source_set_event_handler_f(gTaskTimer, FTAppClickCallback);
        dispatch_resume(gTaskTimer);
    }
    FTAppClickCallback(NULL); // 立即点一次
    FTLog("app clicking start");
}

static void FTAppStopClicking(void) {
    if (!gTaskRunning) return;
    gTaskRunning = NO;
    if (gTaskTimer) { dispatch_source_cancel(gTaskTimer); gTaskTimer = NULL; }
    FTLog("app clicking stop");
}

static void FTAppClickCallback(void *ctx) {
    (void)ctx;
    if (!gTaskRunning) return;
    FTSyntheticTap(gTaskX * gScreenW, gTaskY * gScreenH);
}

static void FTAppPollCallback(void *ctx) {
    (void)ctx;
    FILE *f = fopen("/tmp/FloatingTap.task", "r");
    if (!f) return;
    char buf[64];
    if (fgets(buf, sizeof(buf), f)) {
        size_t len = strlen(buf);
        while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) buf[--len] = 0;
        if (strcmp(buf, gTaskLast) != 0) {
            strcpy(gTaskLast, buf);
            if (strncmp(buf, "start", 5) == 0) {
                double x = 0.5, y = 0.5, ms = 400.0;
                sscanf(buf + 5, "%lf %lf %lf", &x, &y, &ms);
                if (ms < 1.0) ms = 400.0;
                FTAppStartClicking(x, y, ms);
            } else if (strncmp(buf, "stop", 4) == 0) {
                FTAppStopClicking();
            }
        }
    }
    fclose(f);
}

static void FTAppStartPollingCallback(void *ctx) {
    (void)ctx;
    // 屏幕尺寸兜底（ctor 早期可能为 0）
    if (gScreenW <= 0 || gScreenH <= 0) {
        Class ClsScreen = objc_getClass("UIScreen");
        if (ClsScreen) {
            id ms = ((Msg_Send)objc_msgSend)((id)ClsScreen, sel_registerName("mainScreen"));
            CGRect sb = ((Msg_Bounds)objc_msgSend)(ms, sel_registerName("bounds"));
            gScreenW = sb.size.width;
            gScreenH = sb.size.height;
        }
    }
    gPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gPollTimer) {
        dispatch_source_set_timer(gPollTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                                  (uint64_t)(100 * NSEC_PER_MSEC), 0);
        dispatch_source_set_event_handler_f(gPollTimer, FTAppPollCallback);
        dispatch_resume(gPollTimer);
    }
    FTLog("app polling started");
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

// v1.0.47：SB 端不再直接注入（进程隔离，注入触摸到不了前台 App）。
// 改为写任务文件 /tmp/FloatingTap.task（start x y ms / stop），抖音进程轮询执行注入。
static void FTStartClicking(void) {
    if (gIsClicking) return;
    gIsClicking = YES;
    gClickCount = 0;
    // 锁定点击坐标 = 当前球心（拖动球不改变注入点）
    if (gBallWindow) {
        CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame"));
        double cx = f.origin.x + f.size.width * 0.5;
        double cy = f.origin.y + f.size.height * 0.5;
        gClickLockX = (gScreenW > 0) ? cx / gScreenW : 0.5;
        gClickLockY = (gScreenH > 0) ? cy / gScreenH : 0.5;
        if (gClickLockX < 0.001) gClickLockX = 0.001; if (gClickLockX > 0.999) gClickLockX = 0.999;
        if (gClickLockY < 0.001) gClickLockY = 0.001; if (gClickLockY > 0.999) gClickLockY = 0.999;
    }
    double ms = FTIntervalMs();
    FILE *f = fopen("/tmp/FloatingTap.task", "w");
    if (f) {
        fprintf(f, "start %.4f %.4f %.0f\n", gClickLockX, gClickLockY, ms);
        fclose(f);
    }
    FTLog("clicking started (task file written)");
}

static void FTStopClicking(void) {
    if (!gIsClicking) return;
    gIsClicking = NO;
    FILE *f = fopen("/tmp/FloatingTap.task", "w");
    if (f) {
        fprintf(f, "stop\n");
        fclose(f);
    }
    FTLog("clicking stopped");
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
    BOOL isBall = (self == gBallWindow);
    const char *cls = "?";
    long ph = -1, tapc = -1;
    id t = ((Msg_AnyObject)objc_msgSend)(touches, sel_registerName("anyObject"));
    if (t) {
        id v = ((Msg_Send)objc_msgSend)(t, sel_registerName("view"));
        if (v) cls = object_getClassName(v);
        ph = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("phase"));
        tapc = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("tapCount"));
    }
    char buf[200];
    snprintf(buf, sizeof(buf), "SEND touches=%lu view=%s ball=%d phase=%ld tap=%ld",
             (unsigned long)n, cls, isBall ? 1 : 0, ph, tapc);
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
    syslog(LOG_ERR, "FloatingTap v1.0.47 loaded (pure C ctor, zero static ObjC metadata)");

    // v1.0.47 进程分工：SB=控制端（球+手势+写任务文件）；抖音=执行端（轮询任务文件+注入）
    if (FTIsBundle("com.apple.springboard")) {
        // 【诊断标记】SB 进程覆盖写；抖音进程追加写（避免互相覆盖）
        FILE *mk = fopen("/tmp/floatingtap_ctor.log", "w");
        if (mk) {
            fprintf(mk, "FloatingTap v1.0.47 ctor run (arm64e, pure C)\n");
            fclose(mk);
        }
        syslog(LOG_ERR, "FloatingTap role: SpringBoard controller");
        // 延迟 30s 等 SB 完全启动，再动态创建悬浮球
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTTweakInitCallback);
    } else if (FTIsBundle("com.ss.iphone.ugc.Aweme")) {
        FILE *mk = fopen("/tmp/floatingtap_ctor.log", "a");
        if (mk) {
            fprintf(mk, "FloatingTap v1.0.47 Douyin injector ctor\n");
            fclose(mk);
        }
        syslog(LOG_ERR, "FloatingTap role: Douyin injector");
        // 初始化屏幕尺寸（注入坐标换算用）
        Class ClsScreen = objc_getClass("UIScreen");
        if (ClsScreen) {
            id ms = ((Msg_Send)objc_msgSend)((id)ClsScreen, sel_registerName("mainScreen"));
            CGRect sb = ((Msg_Bounds)objc_msgSend)(ms, sel_registerName("bounds"));
            gScreenW = sb.size.width;
            gScreenH = sb.size.height;
        }
        // 延迟 5s 等 App 起来后启动任务文件轮询
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTAppStartPollingCallback);
    }
}

//
//  Tweak.xm — FloatingTap v1.0.20
//
//  v1.0.19 实测：不弹 Safe Mode + /tmp/floatingtap_ctor.log 存在 + 蓝白球出现
//  → 「纯 C 驱动的 ObjC 动态调用」路线完全走通（arm64e 注入 + 零 ObjC 元数据安全）。
//
//  v1.0.20 恢复核心功能（仍保持零 @implementation / %hook / @"..." / block / @selector / NSLog）：
//    1. 长按（minimumPressDuration=0，手指一碰即开始）→ 每 interval 在球心发 HID 点击
//    2. 拖动球 → 调整点击位置（球心 = 点击点）
//    3. 双击 → 停止连点并隐藏球
//    4. 间隔从 /var/mobile/Library/Preferences/com.floatingtap.cfg 纯文本读取（默认 200ms）
//    HID 注入走 HIDInject.c（纯 C：dlopen IOHIDEvent + IOHIDEventSystemClientDispatchEvent）
//
//  铁律回顾：dylib 内任何 ObjC 元数据（类、@"..."、block）在 arm64e 注入下 PAC 崩。
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
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
typedef void       (*Msg_SetDelaysTouchesBegan)(id, SEL, BOOL);
typedef void       (*Msg_SetDelaysTouchesEnded)(id, SEL, BOOL);
typedef void       (*Msg_SetCancelsTouchesInView)(id, SEL, BOOL);
typedef void       (*Msg_SetWindowScene)(id, SEL, id);
typedef id         (*Msg_Layer)(id, SEL);
typedef id         (*Msg_ColorWithRGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
typedef CGColorRef (*Msg_CGColor)(id, SEL);
typedef CGRect     (*Msg_Bounds)(id, SEL);
typedef CGRect     (*Msg_Frame)(id, SEL);
typedef CGPoint    (*Msg_LocationInView)(id, SEL, id);
typedef NSUInteger (*Msg_State)(id, SEL);
typedef NSUInteger (*Msg_Count)(id, SEL);
typedef id         (*Msg_ObjectAtIndex)(id, SEL, NSUInteger);
typedef BOOL       (*Msg_IsKindOf)(id, SEL, Class);
typedef NSInteger  (*Msg_Int)(id, SEL);

// MARK: - 全局状态（纯 C）

static id gBallWindow = nil;
static id gBallView   = nil;
static id gPanGR      = nil;
static id gTapGR      = nil;
static id gLongGR     = nil;

static CGPoint gPanStartLoc;   // 触摸起始点（窗口坐标）
static CGPoint gPanOrigin0;    // 触摸起始时窗口 frame.origin
static BOOL    gPanActive = NO;
static double  gLastTapAt = 0; // mach monotonic 秒

static double  gScreenW = 0;   // 主屏尺寸（FTSetupBall 时保存）
static double  gScreenH = 0;

static BOOL    gIsClicking = NO;      // 连点进行中
static dispatch_source_t gClickTimer = NULL; // 连点定时器（ARC 管理）

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

// MARK: - GCD C 函数回调（代替 block）——前向声明

static void FTTickCallback(void *ctx);
static void FTEnsureBallCallback(void *ctx);
static void FTTweakInitCallback(void *ctx);
static void FTEnsureBall(int attempt);
static void FTStartClicking(void);
static void FTStopClicking(void);
static void FTClickCallback(void *ctx);

// MARK: - 触摸轮询（GR target=nil，只读 state）

static void FTOnPanTick(void) {
    if (!gPanGR || !gBallWindow) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gPanGR, sel_registerName("state"));
    if (st == 1) { // Began
        gPanStartLoc = ((Msg_LocationInView)objc_msgSend)(gPanGR, sel_registerName("locationInView:"), gBallWindow);
        gPanOrigin0  = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame")).origin;
        gPanActive   = YES;
        syslog(LOG_ERR, "FloatingTap Pan BEGIN");
    } else if (st == 2 && gPanActive) { // Changed
        CGPoint cur = ((Msg_LocationInView)objc_msgSend)(gPanGR, sel_registerName("locationInView:"), gBallWindow);
        CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame"));
        ((Msg_SetFrame)objc_msgSend)(gBallWindow, sel_registerName("setFrame:"),
            CGRectMake(gPanOrigin0.x + (cur.x - gPanStartLoc.x),
                       gPanOrigin0.y + (cur.y - gPanStartLoc.y),
                       f.size.width, f.size.height));
    } else if (st == 3 && gPanActive) { // Ended
        gPanActive = NO;
        syslog(LOG_ERR, "FloatingTap Pan END");
    } else if (st == 4) { // Cancelled
        gPanActive = NO;
    }
}

static void FTOnTapTick(void) {
    if (!gTapGR) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gTapGR, sel_registerName("state"));
    if (st != 3) return; // Ended
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    if (now - gLastTapAt < 0.4) {
        syslog(LOG_ERR, "FloatingTap DOUBLE TAP detected, hiding ball");
        FTStopClicking();
        if (gBallWindow) {
            ((Msg_SetHidden)objc_msgSend)(gBallWindow, sel_registerName("setHidden:"), YES);
        }
        gLastTapAt = 0;
    } else {
        gLastTapAt = now;
    }
}

// 长按轮询：Began → 开始连点；Ended/Cancelled/Failed → 停止连点
static void FTOnLongPressTick(void) {
    if (!gLongGR) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gLongGR, sel_registerName("state"));
    if (st == 1) { // Began
        FTStartClicking();
    } else if (st == 3 || st == 4 || st == 5) { // Ended / Cancelled / Failed
        FTStopClicking();
    }
}

// MARK: - 连点引擎

// 读取连点间隔（毫秒）：/var/mobile/Library/Preferences/com.floatingtap.cfg 第一行数字，默认 200
static double FTIntervalMs(void) {
    FILE *f = fopen("/var/mobile/Library/Preferences/com.floatingtap.cfg", "r");
    if (f) {
        double v = 200.0;
        if (fscanf(f, "%lf", &v) == 1 && v >= 1.0 && v <= 60000.0) {
            fclose(f);
            return v;
        }
        fclose(f);
    }
    return 200.0;
}

// 连点回调：在球心发一次 HID 点击
static void FTClickCallback(void *ctx) {
    (void)ctx;
    if (!gBallWindow || !gIsClicking) return;
    if (!FT_HIDIsConnected()) return;

    CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame"));
    double cx = f.origin.x + f.size.width * 0.5;
    double cy = f.origin.y + f.size.height * 0.5;
    double nx = (gScreenW > 0) ? cx / gScreenW : 0.5;
    double ny = (gScreenH > 0) ? cy / gScreenH : 0.5;
    if (nx < 0.001) nx = 0.001; if (nx > 0.999) nx = 0.999;
    if (ny < 0.001) ny = 0.001; if (ny > 0.999) ny = 0.999;

    FT_HIDTapAt(nx, ny);
}

static void FTStartClicking(void) {
    if (gIsClicking) return;
    if (!FT_HIDConnect()) {
        syslog(LOG_ERR, "FloatingTap HID connect failed, cannot start clicking");
        return;
    }
    gIsClicking = YES;
    double ms = FTIntervalMs();
    gClickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gClickTimer) {
        dispatch_source_set_timer(gClickTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                                  (uint64_t)(ms * NSEC_PER_MSEC), 0);
        dispatch_source_set_event_handler_f(gClickTimer, FTClickCallback);
        dispatch_resume(gClickTimer);
    }
    syslog(LOG_ERR, "FloatingTap clicking started, interval=%.0fms", ms);
}

static void FTStopClicking(void) {
    if (!gIsClicking) return;
    gIsClicking = NO;
    if (gClickTimer) {
        dispatch_source_cancel(gClickTimer);
        gClickTimer = NULL;
    }
    syslog(LOG_ERR, "FloatingTap clicking stopped");
}

// MARK: - 创建小球

static void FTSetupBall(void) {
    if (gBallWindow) return;

    Class ClsWindow = objc_getClass("UIWindow");
    Class ClsView   = objc_getClass("UIView");
    Class ClsScreen = objc_getClass("UIScreen");
    Class ClsColor  = objc_getClass("UIColor");
    Class ClsPanGR  = objc_getClass("UIPanGestureRecognizer");
    Class ClsTapGR  = objc_getClass("UITapGestureRecognizer");
    Class ClsLongGR = objc_getClass("UILongPressGestureRecognizer");
    if (!ClsWindow || !ClsView || !ClsScreen || !ClsColor || !ClsPanGR || !ClsTapGR || !ClsLongGR) {
        syslog(LOG_ERR, "FloatingTap system classes missing, skip");
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

    // GR：先 alloc 再 init（v1.0.14 教训：误把 alloc 当 initWithTarget: 用会崩）
    gPanGR = FTAlloc(ClsPanGR);
    ((Msg_Init)objc_msgSend)(gPanGR, sel_registerName("init"));
    gTapGR = FTAlloc(ClsTapGR);
    ((Msg_Init)objc_msgSend)(gTapGR, sel_registerName("init"));
    gLongGR = FTAlloc(ClsLongGR);
    ((Msg_Init)objc_msgSend)(gLongGR, sel_registerName("init"));
    ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR, sel_registerName("setNumberOfTapsRequired:"), (NSUInteger)2);
    ((Msg_SetDelaysTouchesBegan)objc_msgSend)(gPanGR, sel_registerName("setDelaysTouchesBegan:"), NO);
    ((Msg_SetDelaysTouchesEnded)objc_msgSend)(gPanGR, sel_registerName("setDelaysTouchesEnded:"), NO);
    ((Msg_SetCancelsTouchesInView)objc_msgSend)(gPanGR, sel_registerName("setCancelsTouchesInView:"), NO);
    // 长按：minimumPressDuration=0 → 手指一碰立即 Began（开始连点），allowableMovement=30 防抖动误取消
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setMinimumPressDuration:"), 0.0);
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setAllowableMovement:"), 30.0);

    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gPanGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gTapGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gLongGR);

    // 直接把 ball 加到 window（不走 VC），更可靠
    ((Msg_AddSubview)objc_msgSend)(win, sel_registerName("addSubview:"), ball);

    ((Msg_SetHidden)objc_msgSend)(win, sel_registerName("setHidden:"), NO);
    ((Msg_MakeKeyAndVisible)objc_msgSend)(win, sel_registerName("makeKeyAndVisible"));

    gBallWindow = win;
    gBallView   = ball;

    // 20Hz 轮询 GR 状态（C 函数回调，无 block）
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                              (uint64_t)(0.05 * NSEC_PER_SEC), (uint64_t)(0.01 * NSEC_PER_SEC));
    dispatch_source_set_event_handler_f(timer, FTTickCallback);
    dispatch_resume(timer);

    syslog(LOG_ERR, "FloatingTap ball created, scene=%d win=%lu",
           scene ? 1 : 0, (unsigned long)(uintptr_t)win);
}

// MARK: - GCD C 函数回调（代替 block）

static void FTTickCallback(void *ctx) {
    (void)ctx;
    FTOnLongPressTick();
    FTOnPanTick();
    FTOnTapTick();
}

static void FTEnsureBall(int attempt) {
    if (FTUIReady()) {
        FTSetupBall();
        return;
    }
    if (attempt >= 10) {
        syslog(LOG_ERR, "FloatingTap SB UI not ready after 20s, giving up");
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
    syslog(LOG_ERR, "FloatingTap init callback, UI ready? calling FTEnsureBall");
    FTEnsureBall(0);
}

// MARK: - 入口（纯 C constructor，等效 %ctor 但无 Logos 依赖、零 ObjC）

__attribute__((constructor))
static void FTTweakCtor(void) {
    // 【诊断标记】若重启后 /tmp/floatingtap_ctor.log 存在 → tweak 已注入 SpringBoard
    FILE *mk = fopen("/tmp/floatingtap_ctor.log", "w");
    if (mk) {
        fprintf(mk, "FloatingTap v1.0.20 ctor run (arm64e, pure C)\n");
        fclose(mk);
    }
    syslog(LOG_ERR, "FloatingTap v1.0.20 loaded (pure C ctor, zero ObjC metadata)");

    // 延迟 30s 等 SB 完全启动，再动态创建悬浮球
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTTweakInitCallback);
}

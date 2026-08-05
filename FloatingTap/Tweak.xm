//
//  Tweak.xm — FloatingTap v1.0.30
//
//  v1.0.29 诊断（决定性）：长按 6.3s 注入 30 次，UIWindow sendEvent 的 SEND 记录
//  只有零星几条（=用户手指），注入触摸从未到达 UIKit → IOHIDEventSystemClient
//  在 Dopamine+iOS15.5+M1 环境事件被 IOKit/BackBoard 层丢弃（DispatchEvent 返回成功但无效）。
//  v1.0.30 换注入路径：SB 进程内 KVC 合成 UITouch/UIEvent，调 [UIApplication sendEvent:]，
//  等价程序化手指，不经过 HID 系统。hitTest 找触摸点命中窗口（跳过球窗口）。
//
//  仍保持零静态 ObjC 元数据：无 @implementation / @"..." / block 字面量 / @selector / NSLog。
//  （KVC key 用 FTString 运行时创建 NSString）
//  日志：syslog + /tmp/floatingtap_ctor.log（append，带时间戳）。
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>   // 仅类型声明（UIWindow/UIEvent），不产生运行时元数据；%hook 需要
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
static dispatch_source_t gClickTimer = NULL; // 连点定时器（ARC 管理）

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

// 恢复球窗口交互（注入后 60ms 回调）
static void FTRestoreBallInteractionCallback(void *ctx);

// MARK: - 合成触摸（KVC 方案，v1.0.30 起替代 HID 注入）
// v1.0.29 诊断证实：IOHIDEventSystemClientDispatchEvent 在 Dopamine+iOS15.5+M1 环境
// 事件被 IOKit/BackBoard 层丢弃（从未到达 UIWindow sendEvent）。改在 SB 进程内
// 用 KVC 直接合成 UITouch/UIEvent，调 [UIApplication sendEvent:] —— 等价程序化手指。

typedef void (*Msg_SetValueForKey)(id, SEL, id, id);
typedef id   (*Msg_ValueWithCGPoint)(id, SEL, CGPoint);
typedef id   (*Msg_SetWithObject)(id, SEL, id);
typedef id   (*Msg_HitTest)(id, SEL, CGPoint, id);
typedef void (*Msg_SendEvent)(id, SEL, id);
typedef id   (*Msg_StringWithUTF8String)(id, SEL, const char *);
typedef id   (*Msg_NumberWithDouble)(id, SEL, double);
typedef id   (*Msg_NumberWithInt)(id, SEL, int);
typedef id   (*Msg_NumberWithUnsignedInt)(id, SEL, unsigned int);

// 运行时创建 NSString（禁止 @"" 字面量：arm64e PAC 元数据雷区）
static id FTString(const char *s) {
    Class ClsStr = objc_getClass("NSString");
    if (!ClsStr) return nil;
    return ((Msg_StringWithUTF8String)objc_msgSend)((id)ClsStr, sel_registerName("stringWithUTF8String:"), s);
}

// 在屏幕像素点 (px,py) 发一次合成点击（down + up，同一 touch 对象）
static void FTSyntheticTap(double px, double py) {
    Class ClsTouch = objc_getClass("UITouch");
    Class ClsEvent = objc_getClass("UIEvent");
    Class ClsApp   = objc_getClass("UIApplication");
    Class ClsSet   = objc_getClass("NSSet");
    Class ClsValue = objc_getClass("NSValue");
    Class ClsNumber= objc_getClass("NSNumber");
    if (!ClsTouch || !ClsEvent || !ClsApp || !ClsSet || !ClsValue || !ClsNumber) {
        FTLog("synthetic tap failed: class missing");
        return;
    }
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
    if (!app) return;
    id wins = ((Msg_Send)objc_msgSend)(app, sel_registerName("windows"));
    if (!wins) return;
    NSUInteger n = ((Msg_Count)objc_msgSend)(wins, sel_registerName("count"));

    // 1. 找触摸点命中的窗口（跳过球窗口，球窗口交互已由调用方关闭）
    CGPoint pt = CGPointMake(px, py);
    id targetWin = nil;
    for (NSUInteger i = 0; i < n; i++) {
        id w = ((Msg_ObjectAtIndex)objc_msgSend)(wins, sel_registerName("objectAtIndex:"), i);
        if (!w || w == gBallWindow) continue;
        id hit = ((Msg_HitTest)objc_msgSend)(w, sel_registerName("hitTest:withEvent:"), pt, nil);
        if (hit) { targetWin = w; break; }
    }
    if (!targetWin) {
        FTLog("synthetic tap: no target window at point");
        return;
    }

    // 2. 合成 UITouch（KVC 设置私有属性）
    id touch = FTAlloc(ClsTouch);
    if (!touch) return;
    touch = ((Msg_Init)objc_msgSend)(touch, sel_registerName("init"));
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    ((Msg_SetValueForKey)objc_msgSend)(touch, sel_registerName("setValue:forKey:"), targetWin, FTString("_window"));
    ((Msg_SetValueForKey)objc_msgSend)(touch, sel_registerName("setValue:forKey:"),
        ((Msg_NumberWithDouble)objc_msgSend)((id)ClsNumber, sel_registerName("numberWithDouble:"), now), FTString("_timestamp"));
    ((Msg_SetValueForKey)objc_msgSend)(touch, sel_registerName("setValue:forKey:"),
        ((Msg_NumberWithInt)objc_msgSend)((id)ClsNumber, sel_registerName("numberWithInt:"), 0), FTString("_phase")); // Began
    ((Msg_SetValueForKey)objc_msgSend)(touch, sel_registerName("setValue:forKey:"),
        ((Msg_NumberWithUnsignedInt)objc_msgSend)((id)ClsNumber, sel_registerName("numberWithUnsignedInt:"), 1), FTString("_tapCount"));
    ((Msg_SetValueForKey)objc_msgSend)(touch, sel_registerName("setValue:forKey:"),
        ((Msg_ValueWithCGPoint)objc_msgSend)((id)ClsValue, sel_registerName("valueWithCGPoint:"), pt), FTString("_locationInWindow"));

    // 3. 合成 UIEvent（_touches = NSSet{touch}）
    id set = ((Msg_SetWithObject)objc_msgSend)((id)ClsSet, sel_registerName("setWithObject:"), touch);
    if (!set) return;
    id event = FTAlloc(ClsEvent);
    if (!event) return;
    event = ((Msg_Init)objc_msgSend)(event, sel_registerName("init"));
    ((Msg_SetValueForKey)objc_msgSend)(event, sel_registerName("setValue:forKey:"), set, FTString("_touches"));

    // 4. down（Began）→ up（Ended）
    ((Msg_SendEvent)objc_msgSend)(app, sel_registerName("sendEvent:"), event);
    ((Msg_SetValueForKey)objc_msgSend)(touch, sel_registerName("setValue:forKey:"),
        ((Msg_NumberWithInt)objc_msgSend)((id)ClsNumber, sel_registerName("numberWithInt:"), 3), FTString("_phase")); // Ended
    ((Msg_SendEvent)objc_msgSend)(app, sel_registerName("sendEvent:"), event);
}

// 连点回调：在球心发一次合成点击。
// ⚠️ 注入坐标=球心，球窗口(windowLevel 1001)正好在球心，注入触摸会先命中
// 球窗口被吃掉 → 下层永远收不到。因此注入瞬间关掉球窗口交互
// （userInteractionEnabled=NO，窗口不参与 hitTest，注入触摸穿透），60ms 后恢复。
static void FTClickCallback(void *ctx) {
    (void)ctx;
    if (!gBallWindow || !gIsClicking) return;

    CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, sel_registerName("frame"));
    double cx = f.origin.x + f.size.width * 0.5;
    double cy = f.origin.y + f.size.height * 0.5;
    double nx = (gScreenW > 0) ? cx / gScreenW : 0.5;
    double ny = (gScreenH > 0) ? cy / gScreenH : 0.5;
    if (nx < 0.001) nx = 0.001; if (nx > 0.999) nx = 0.999;
    if (ny < 0.001) ny = 0.001; if (ny > 0.999) ny = 0.999;

    // 注入前：球窗口不参与 hitTest → 注入触摸穿透到下层
    ((Msg_SetUserInteractionEnabled)objc_msgSend)(gBallWindow, sel_registerName("setUserInteractionEnabled:"), NO);

    FTSyntheticTap(nx * gScreenW, ny * gScreenH);
    gClickCount++;

    char diag[96];
    snprintf(diag, sizeof(diag), "inject tap nx=%.2f ny=%.2f", nx, ny);
    FTLog(diag);

    // 60ms 后恢复交互（连点 200ms 间隔，恢复后用户可松手停止）
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTRestoreBallInteractionCallback);
}

static void FTRestoreBallInteractionCallback(void *ctx) {
    (void)ctx;
    if (gBallWindow) {
        ((Msg_SetUserInteractionEnabled)objc_msgSend)(gBallWindow, sel_registerName("setUserInteractionEnabled:"), YES);
    }
}

static void FTStartClicking(void) {
    if (gIsClicking) return;
    gIsClicking = YES;
    gClickCount = 0;
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
    const char *cls = "?";
    id t = ((Msg_AnyObject)objc_msgSend)(touches, sel_registerName("anyObject"));
    if (t) {
        id v = ((Msg_Send)objc_msgSend)(t, sel_registerName("view"));
        if (v) cls = object_getClassName(v);
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "SEND touches=%lu view=%s", (unsigned long)n, cls);
    FTLog(buf);
}
%end

// MARK: - 入口（纯 C constructor，等效 %ctor 但无 Logos 依赖、零 ObjC）

__attribute__((constructor))
static void FTTweakCtor(void) {
    // 【诊断标记】若重启后 /tmp/floatingtap_ctor.log 存在 → tweak 已注入 SpringBoard
    FILE *mk = fopen("/tmp/floatingtap_ctor.log", "w");
    if (mk) {
        fprintf(mk, "FloatingTap v1.0.30 ctor run (arm64e, pure C)\n");
        fclose(mk);
    }
    syslog(LOG_ERR, "FloatingTap v1.0.30 loaded (pure C ctor, zero static ObjC metadata)");

    // 延迟 30s 等 SB 完全启动，再动态创建悬浮球
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTTweakInitCallback);
}

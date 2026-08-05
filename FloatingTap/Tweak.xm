//
//  Tweak.xm — FloatingTap v1.0.18
//
//  v1.0.17 实测：绑了 UIWindowScene 仍不显示蓝球。两个问题待区分：
//    (A) tweak 没真正注入 SpringBoard（不弹 Safe Mode 也可能只是没加载）
//    (B) 窗口渲染方式在 SB 上不工作（VC + rootViewController 路径不可靠）
//
//  v1.0.18 变更：
//    1. 【决定性诊断】%ctor 最开头写 /tmp/floatingtap_ctor.log 标记文件。
//       装完重启后该文件存在 = tweak 确实加载；不存在 = 没注入（查 plist/安装）。
//    2. 窗口改更可靠路径：windowScene + 直接 addSubview（去掉 VC 中间层）
//       + makeKeyAndVisible（强制参与渲染并显示）。
//
//  仍保持：零 @implementation 零 %hook，纯 C + objc_msgSend，仅 arm64。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>

// MARK: - objc_msgSend 类型化函数指针

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

static CGPoint      gPanStartLoc;   // 触摸起始点（窗口坐标）
static CGPoint      gPanOrigin0;    // 触摸起始时窗口 frame.origin
static BOOL         gPanActive = NO;
static NSTimeInterval gLastTapAt = 0;

// MARK: - 工具

static id FTAlloc(Class cls) {
    return ((Msg_Send)objc_msgSend)((id)cls, @selector(alloc));
}

static id FTAllocInitWithFrame(Class cls, CGRect frame) {
    id obj = FTAlloc(cls);
    return ((Msg_AllocInitWithFrame)objc_msgSend)(obj, @selector(initWithFrame:), frame);
}

// 取当前前台活跃的 UIWindowScene（iOS 13+ 必需，否则 UIWindow 不渲染）
static id FTGetActiveWindowScene(void) {
    Class ClsApp = NSClassFromString(@"UIApplication");
    if (!ClsApp) return nil;
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, @selector(sharedApplication));
    if (!app) return nil;
    id scenes = ((Msg_Send)objc_msgSend)(app, @selector(connectedScenes));
    if (!scenes) return nil;
    id arr = ((Msg_Send)objc_msgSend)(scenes, @selector(allObjects));
    if (!arr) return nil;
    NSUInteger n = ((Msg_Count)objc_msgSend)(arr, @selector(count));
    Class ClsWScene = NSClassFromString(@"UIWindowScene");
    id firstWS = nil;
    for (NSUInteger i = 0; i < n; i++) {
        id s = ((Msg_ObjectAtIndex)objc_msgSend)(arr, @selector(objectAtIndex:), i);
        if (!s) continue;
        if (ClsWScene && ((Msg_IsKindOf)objc_msgSend)(s, @selector(isKindOfClass:), ClsWScene)) {
            if (firstWS == nil) firstWS = s;
            NSInteger act = ((Msg_Int)objc_msgSend)(s, @selector(activationState));
            if (act == 1) return s; // UISceneActivationStateForegroundActive = 1
        }
    }
    return firstWS;
}

// MARK: - 触摸轮询（GR target=nil，只能读 state）

static void FTOnPanTick(void) {
    if (!gPanGR || !gBallWindow) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gPanGR, @selector(state));
    if (st == 1) { // Began
        gPanStartLoc = ((Msg_LocationInView)objc_msgSend)(gPanGR, @selector(locationInView:), gBallWindow);
        gPanOrigin0  = ((Msg_Frame)objc_msgSend)(gBallWindow, @selector(frame)).origin;
        gPanActive   = YES;
        NSLog(@"[FloatingTap] Pan BEGIN");
    } else if (st == 2 && gPanActive) { // Changed
        CGPoint cur = ((Msg_LocationInView)objc_msgSend)(gPanGR, @selector(locationInView:), gBallWindow);
        CGRect f = ((Msg_Frame)objc_msgSend)(gBallWindow, @selector(frame));
        ((Msg_SetFrame)objc_msgSend)(gBallWindow, @selector(setFrame:),
            CGRectMake(gPanOrigin0.x + (cur.x - gPanStartLoc.x),
                       gPanOrigin0.y + (cur.y - gPanStartLoc.y),
                       f.size.width, f.size.height));
    } else if (st == 3 && gPanActive) { // Ended
        gPanActive = NO;
        NSLog(@"[FloatingTap] Pan END");
    } else if (st == 4) { // Cancelled
        gPanActive = NO;
    }
}

static void FTOnTapTick(void) {
    if (!gTapGR) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gTapGR, @selector(state));
    if (st != 3) return; // Ended
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastTapAt < 0.4) {
        NSLog(@"[FloatingTap] DOUBLE TAP detected");
        gLastTapAt = 0;
    } else {
        gLastTapAt = now;
    }
}

// SB UI 是否就绪：能拿到 windowScene，或 UIApplication 至少有一个 window
static BOOL FTUIReady(void) {
    if (FTGetActiveWindowScene()) return YES;
    Class ClsApp = NSClassFromString(@"UIApplication");
    if (!ClsApp) return NO;
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, @selector(sharedApplication));
    if (!app) return NO;
    id wins = ((Msg_Send)objc_msgSend)(app, @selector(windows));
    if (!wins) return NO;
    NSUInteger n = ((Msg_Count)objc_msgSend)(wins, @selector(count));
    return n > 0;
}

// MARK: - 创建小球

static void FTSetupBall(void) {
    if (gBallWindow) return;

    Class ClsWindow = NSClassFromString(@"UIWindow");
    Class ClsView   = NSClassFromString(@"UIView");
    Class ClsScreen = NSClassFromString(@"UIScreen");
    Class ClsColor  = NSClassFromString(@"UIColor");
    Class ClsPanGR  = NSClassFromString(@"UIPanGestureRecognizer");
    Class ClsTapGR  = NSClassFromString(@"UITapGestureRecognizer");
    if (!ClsWindow || !ClsView || !ClsScreen || !ClsColor || !ClsPanGR || !ClsTapGR) {
        NSLog(@"[FloatingTap] system classes missing, skip");
        return;
    }

    id mainScreen = ((Msg_Send)objc_msgSend)((id)ClsScreen, @selector(mainScreen));
    CGRect sb = ((Msg_Bounds)objc_msgSend)(mainScreen, @selector(bounds));
    CGFloat d = 56.0;
    CGRect ballFrame = CGRectMake(sb.size.width / 2 - d / 2, sb.size.height / 2 - d / 2, d, d);

    // 独立小球窗口：只有小球大小 → 区域外触摸天然穿透
    id win = FTAllocInitWithFrame(ClsWindow, ballFrame);

    // iOS 13+：挂到当前活跃的 UIWindowScene，否则不渲染
    id scene = FTGetActiveWindowScene();
    if (scene) {
        ((Msg_SetWindowScene)objc_msgSend)(win, @selector(setWindowScene:), scene);
    }

    ((Msg_SetWindowLevel)objc_msgSend)(win, @selector(setWindowLevel:), (CGFloat)1001.0);

    id ball = FTAllocInitWithFrame(ClsView, CGRectMake(0, 0, d, d));
    ((Msg_SetUserInteractionEnabled)objc_msgSend)(ball, @selector(setUserInteractionEnabled:), YES);
    ((Msg_SetBackgroundColor)objc_msgSend)(ball, @selector(setBackgroundColor:),
        ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, @selector(colorWithRed:green:blue:alpha:),
                                          0.0, 0.478, 1.0, 0.9));

    id layer = ((Msg_Layer)objc_msgSend)(ball, @selector(layer));
    ((Msg_SetCGFloat)objc_msgSend)(layer, @selector(setCornerRadius:), (CGFloat)(d / 2.0));
    ((Msg_SetCGFloat)objc_msgSend)(layer, @selector(setBorderWidth:), (CGFloat)2.5);
    id white = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, @selector(colorWithRed:green:blue:alpha:),
                                                 1.0, 1.0, 1.0, 1.0);
    ((Msg_SetBorderColor)objc_msgSend)(layer, @selector(setBorderColor:),
                                       ((Msg_CGColor)objc_msgSend)(white, @selector(CGColor)));

    // GR：先 alloc 再 init（target=nil, action=NULL，仅轮询 state）
    gPanGR = FTAlloc(ClsPanGR);
    ((Msg_Init)objc_msgSend)(gPanGR, @selector(init));
    gTapGR = FTAlloc(ClsTapGR);
    ((Msg_Init)objc_msgSend)(gTapGR, @selector(init));
    ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR, @selector(setNumberOfTapsRequired:), (NSUInteger)2);
    ((Msg_SetDelaysTouchesBegan)objc_msgSend)(gPanGR, @selector(setDelaysTouchesBegan:), NO);
    ((Msg_SetDelaysTouchesEnded)objc_msgSend)(gPanGR, @selector(setDelaysTouchesEnded:), NO);
    ((Msg_SetCancelsTouchesInView)objc_msgSend)(gPanGR, @selector(setCancelsTouchesInView:), NO);

    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, @selector(addGestureRecognizer:), gPanGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, @selector(addGestureRecognizer:), gTapGR);

    // 直接把 ball 加到 window（不走 VC），更可靠
    ((Msg_AddSubview)objc_msgSend)(win, @selector(addSubview:), ball);

    ((Msg_SetHidden)objc_msgSend)(win, @selector(setHidden:), NO);
    ((Msg_MakeKeyAndVisible)objc_msgSend)(win, @selector(makeKeyAndVisible));

    gBallWindow = win;
    gBallView   = ball;

    // 20Hz 轮询 GR 状态
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                              (uint64_t)(0.05 * NSEC_PER_SEC), (uint64_t)(0.01 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        FTOnPanTick();
        FTOnTapTick();
    });
    dispatch_resume(timer);

    NSLog(@"[FloatingTap] v1.0.18 ball created, scene=%@ win=%p",
          (scene ? @"yes" : @"no"), (__bridge void*)win);
}

// 确保 SB UI 就绪后再创建（每 2s 重试，最多 10 次）
static void FTEnsureBall(int attempt) {
    if (FTUIReady()) {
        FTSetupBall();
        return;
    }
    if (attempt >= 10) {
        NSLog(@"[FloatingTap] SB UI not ready after 20s, giving up");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FTEnsureBall(attempt + 1);
    });
}

%ctor {
    // 【诊断标记】若重启后 /tmp/floatingtap_ctor.log 存在 → tweak 已注入 SpringBoard
    FILE *mk = fopen("/tmp/floatingtap_ctor.log", "w");
    if (mk) {
        fprintf(mk, "FloatingTap v1.0.18 ctor run\n");
        fclose(mk);
    }
    NSLog(@"[FloatingTap] v1.0.18 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FTEnsureBall(0);
    });
}

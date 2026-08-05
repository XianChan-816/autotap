//
//  Tweak.xm — FloatingTap v1.0.15
//
//  v1.0.14 问题：GR 用错误的 objc_msgSend 一次调用（alloc 被当成
//  initWithTarget:action: 调），返回未初始化实例 → 后续 setter 全在垃圾内存上
//  → EXC_BAD_ACCESS → SpringBoard 崩 → Safe Mode。
//
//  v1.0.15 变更：
//    1. 修复 GR 初始化：先 alloc 再正确 init（target=nil, action=NULL，
//       仅轮询 state，不依赖回调）。
//    2. 创建窗口前检查 SB UI 就绪（UIApplication.windows count > 0），
//       未就绪则每 2s 重试（最多 10 次）——v1.0.13/14 在 5s 就建窗口可能太早。
//    3. 首次创建延迟 5s → 15s。
//    4. 拖动逻辑修正：locationInView:gBallWindow 用窗口坐标，拖动跟随不跳变。
//
//  仍保持：零 @implementation 零 %hook。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - objc_msgSend 类型化函数指针

typedef id         (*Msg_Send)(id, SEL);
typedef id         (*Msg_Init)(id, SEL);
typedef id         (*Msg_AllocInitWithFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetBackgroundColor)(id, SEL, id);
typedef void       (*Msg_SetWindowLevel)(id, SEL, CGFloat);
typedef void       (*Msg_SetHidden)(id, SEL, BOOL);
typedef void       (*Msg_SetRootVC)(id, SEL, id);
typedef void       (*Msg_SetView)(id, SEL, id);
typedef void       (*Msg_SetUserInteractionEnabled)(id, SEL, BOOL);
typedef void       (*Msg_AddGestureRecognizer)(id, SEL, id);
typedef void       (*Msg_SetCornerRadius)(id, SEL, CGFloat);
typedef void       (*Msg_SetBorderWidth)(id, SEL, CGFloat);
typedef void       (*Msg_SetBorderColor)(id, SEL, CGColorRef);
typedef void       (*Msg_SetNumberOfTapsRequired)(id, SEL, NSUInteger);
typedef void       (*Msg_SetDelaysTouchesBegan)(id, SEL, BOOL);
typedef void       (*Msg_SetDelaysTouchesEnded)(id, SEL, BOOL);
typedef void       (*Msg_SetCancelsTouchesInView)(id, SEL, BOOL);
typedef id         (*Msg_Layer)(id, SEL);
typedef id         (*Msg_ColorWithRGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
typedef CGColorRef (*Msg_CGColor)(id, SEL);
typedef CGRect     (*Msg_Bounds)(id, SEL);
typedef CGRect     (*Msg_Frame)(id, SEL);
typedef CGPoint    (*Msg_LocationInView)(id, SEL, id);
typedef NSUInteger (*Msg_State)(id, SEL);
typedef NSUInteger (*Msg_Count)(id, SEL);

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

// SB UI 是否就绪：UIApplication 存在且至少有一个 window
static BOOL FTUIReady(void) {
    Class ClsApp = NSClassFromString(@"UIApplication");
    if (!ClsApp) return NO;
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, @selector(sharedApplication));
    if (!app) return NO;
    id wins = ((Msg_Send)objc_msgSend)(app, @selector(windows));
    if (!wins) return NO;
    NSUInteger n = ((Msg_Count)objc_msgSend)(wins, @selector(count));
    return n > 0;
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

// MARK: - 创建小球

static void FTSetupBall(void) {
    if (gBallWindow) return;

    Class ClsWindow = NSClassFromString(@"UIWindow");
    Class ClsView   = NSClassFromString(@"UIView");
    Class ClsVC     = NSClassFromString(@"UIViewController");
    Class ClsScreen = NSClassFromString(@"UIScreen");
    Class ClsColor  = NSClassFromString(@"UIColor");
    Class ClsPanGR  = NSClassFromString(@"UIPanGestureRecognizer");
    Class ClsTapGR  = NSClassFromString(@"UITapGestureRecognizer");
    if (!ClsWindow || !ClsView || !ClsVC || !ClsScreen || !ClsColor || !ClsPanGR || !ClsTapGR) {
        NSLog(@"[FloatingTap] system classes missing, skip");
        return;
    }

    id mainScreen = ((Msg_Send)objc_msgSend)((id)ClsScreen, @selector(mainScreen));
    CGRect sb = ((Msg_Bounds)objc_msgSend)(mainScreen, @selector(bounds));
    CGFloat d = 56.0;
    CGRect ballFrame = CGRectMake(sb.size.width / 2 - d / 2, sb.size.height / 2 - d / 2, d, d);

    // 独立小球窗口：只有小球大小 → 区域外触摸天然穿透
    id win = FTAllocInitWithFrame(ClsWindow, ballFrame);
    ((Msg_SetWindowLevel)objc_msgSend)(win, @selector(setWindowLevel:), (CGFloat)1001.0);
    ((Msg_SetHidden)objc_msgSend)(win, @selector(setHidden:), NO);

    id vc = ((Msg_Send)objc_msgSend)((id)ClsVC, @selector(new));

    id ball = FTAllocInitWithFrame(ClsView, CGRectMake(0, 0, d, d));
    ((Msg_SetUserInteractionEnabled)objc_msgSend)(ball, @selector(setUserInteractionEnabled:), YES);
    ((Msg_SetBackgroundColor)objc_msgSend)(ball, @selector(setBackgroundColor:),
        ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, @selector(colorWithRed:green:blue:alpha:),
                                          0.0, 0.478, 1.0, 0.9));

    id layer = ((Msg_Layer)objc_msgSend)(ball, @selector(layer));
    ((Msg_SetCornerRadius)objc_msgSend)(layer, @selector(setCornerRadius:), (CGFloat)(d / 2.0));
    ((Msg_SetBorderWidth)objc_msgSend)(layer, @selector(setBorderWidth:), (CGFloat)2.5);
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

    ((Msg_SetView)objc_msgSend)(vc, @selector(setView:), ball);
    ((Msg_SetRootVC)objc_msgSend)(win, @selector(setRootViewController:), vc);

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

    NSLog(@"[FloatingTap] v1.0.15 ball shown at (%.0f,%.0f)", ballFrame.origin.x, ballFrame.origin.y);
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
    NSLog(@"[FloatingTap] v1.0.15 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FTEnsureBall(0);
    });
}

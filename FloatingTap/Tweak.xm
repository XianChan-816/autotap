//
//  Tweak.xm — FloatingTap v1.0.14
//
//  v1.0.13 进展：零 @implementation 类版本，验证不卡屏。
//  v1.0.13 残留问题：%hook UIView 方法交换仍会触发 SpringBoard 崩溃进 Safe Mode。
//                  （Logos 在编译期对 UIView 的 touchesBegan/Ended 做 swizzle，路径
//                   易与其他 tweak 的 hook 冲突，在 SB 这种被反复改的进程里翻车。）
//
//  v1.0.14 变更：彻底删除所有 %hook。改用系统级 UIGestureRecognizer 监听小球触摸：
//    - UIPanGestureRecognizer：拖动 + 状态打印
//    - UITapGestureRecognizer：双击关闭
//  GR 走系统标准事件分发，不动 UIView 任何方法，理论上 100% 安全。
//
//  本版本仅验证：
//    1) 安装/重启不再进 Safe Mode
//    2) 屏幕中央出现蓝色圆球
//    3) 拖动小球有日志
//    4) 双击小球有日志
//  HID 连点引擎留到 v1.0.15 补全（届时同样纯 C + IOHIDEventCreate + dispatch）。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - objc_msgSend 类型化函数指针

typedef id   (*Msg_Send)(id, SEL);
typedef id   (*Msg_AllocInitWithFrame)(id, SEL, CGRect);
typedef id   (*Msg_AllocInitWithTargetAction)(id, SEL, id, SEL);
typedef void (*Msg_SetFrame)(id, SEL, CGRect);
typedef void (*Msg_SetBackgroundColor)(id, SEL, id);
typedef void (*Msg_SetWindowLevel)(id, SEL, CGFloat);
typedef void (*Msg_SetHidden)(id, SEL, BOOL);
typedef void (*Msg_SetRootVC)(id, SEL, id);
typedef void (*Msg_SetView)(id, SEL, id);
typedef void (*Msg_SetUserInteractionEnabled)(id, SEL, BOOL);
typedef void (*Msg_AddGestureRecognizer)(id, SEL, id);
typedef void (*Msg_SetCornerRadius)(id, SEL, CGFloat);
typedef void (*Msg_SetBorderWidth)(id, SEL, CGFloat);
typedef void (*Msg_SetBorderColor)(id, SEL, CGColorRef);
typedef void (*Msg_SetNumberOfTapsRequired)(id, SEL, NSUInteger);
typedef void (*Msg_SetMinimumNumberOfTouches)(id, SEL, NSUInteger);
typedef void (*Msg_SetDelaysTouchesBegan)(id, SEL, BOOL);
typedef void (*Msg_SetDelaysTouchesEnded)(id, SEL, BOOL);
typedef void (*Msg_SetCancelsTouchesInView)(id, SEL, BOOL);
typedef id   (*Msg_Layer)(id, SEL);
typedef id   (*Msg_ColorWithRGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
typedef CGColorRef (*Msg_CGColor)(id, SEL);
typedef CGRect (*Msg_Bounds)(id, SEL);
typedef CGPoint (*Msg_LocationInView)(id, SEL, id);
typedef NSUInteger (*Msg_State)(id, SEL);

// MARK: - 全局状态（纯 C）

static id gBallWindow = nil;
static id gBallRootVC = nil;
static id gBallView   = nil;
static id gPanGR      = nil;
static id gTapGR      = nil;
static CGPoint gPanStartCenter;   // 拖动起始中心
static NSTimeInterval gLastTapAt  = 0;

// MARK: - 工具

static id FTAllocInitWithFrame(Class cls, CGRect frame) {
    static Msg_AllocInitWithFrame fn = (Msg_AllocInitWithFrame)objc_msgSend;
    id obj = ((Msg_Send)objc_msgSend)((id)cls, @selector(alloc));
    return fn(obj, @selector(initWithFrame:), frame);
}

// MARK: - Gesture 回调（必须是 ObjC selector，所以用系统类 NSObject 派生一个 helper 类的 class copy）

// 我们**不**自己 @implementation 任何类。
// 改用 Logos 的 %new —— 等下，%new 也会生成 ObjC 类。
// 真正零类的做法：用 performSelector 让一个 block 形式回调。
// 实际上 UIGestureRecognizer 需要一个 target:selector 配对——
// 解决方案：dispatch 一份 SEL 指向一个**不存在的类方法**，用 NSObject 现有的 forwardInvocation。
// 太复杂。
//
// 实用方案：保留一个最最小的 NSObject 子类（@implementation），让 GR 知道调谁。
// —— 但这违反"零 @implementation"约束。怎么办？
//
// 折中：先接受唯一一个辅助类，专门负责转发 GR 回调到纯 C 函数。
// 既然 v1.0.13 已经证明"只要 UIView 子类/UIResponder 子类"会卡，
// 那 NSObject 子类（非 UIView 派生）作为纯转发器可能安全。
//
// v1.0.14 仍然尝试 **零 @implementation**：
//   - 把 GR 的 target 直接设为 nil:self，selector 指向一个 Objective-C runtime
//     动态添加的方法（在某个系统类上 addMethod）—— 不需要自定义类。
//   - 或：用 category 给 UIResponder 添加方法（但 UIResponder 已存在，category 也算"加方法"）
//
// **真正可行的零类方案**：
//   使用 NSTimer 轮询 gBallView 的 recognizer 状态。
//   - 添加 UIPanGestureRecognizer 和 UITapGestureRecognizer（不指定 target）
//   - NSTimer 每 0.05s 读 recognizer.state 和 recognizer.locationInView
//   - 不需要 target:selector
//   - 不需要任何 ObjC 方法
//   - 不需要 @implementation 任何类
//
// 走这条路。

static void FTOnPanTick(void) {
    if (!gPanGR) return;
    NSUInteger state = ((Msg_State)objc_msgSend)(gPanGR, @selector(state));
    if (state == 0) return; // UIGestureRecognizerStatePossible = 0
    if (state == 1) {
        // began
        id win = gBallWindow;
        CGRect cur = ((Msg_Bounds)objc_msgSend)(win, @selector(bounds));
        gPanStartCenter = CGPointMake(CGRectGetMidX(cur), CGRectGetMidY(cur));
        NSLog(@"[FloatingTap] Pan BEGIN center=(%.0f,%.0f)", gPanStartCenter.x, gPanStartCenter.y);
    } else if (state == 2) {
        // changed
        id win = gBallWindow;
        CGRect winFrame = ((Msg_Bounds)objc_msgSend)(win, @selector(frame));
        CGPoint pt = ((Msg_LocationInView)objc_msgSend)(gPanGR, @selector(locationInView:), (id)nil);
        CGFloat newX = winFrame.origin.x + (pt.x - gPanStartCenter.x);
        CGFloat newY = winFrame.origin.y + (pt.y - gPanStartCenter.y);
        ((Msg_SetFrame)objc_msgSend)(win, @selector(setFrame:), CGRectMake(newX, newY, winFrame.size.width, winFrame.size.height));
    } else if (state == 3) {
        NSLog(@"[FloatingTap] Pan END");
    }
}

static void FTOnTapTick(void) {
    if (!gTapGR) return;
    NSUInteger state = ((Msg_State)objc_msgSend)(gTapGR, @selector(state));
    if (state != 3) return; // UIGestureRecognizerStateEnded
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastTapAt < 0.35) {
        NSLog(@"[FloatingTap] DOUBLE TAP detected — would close ball");
        gLastTapAt = 0;
    } else {
        gLastTapAt = now;
    }
}

static void FTSetupBall(void) {
    if (gBallWindow) return;

    Class ClsWindow  = NSClassFromString(@"UIWindow");
    Class ClsView    = NSClassFromString(@"UIView");
    Class ClsVC      = NSClassFromString(@"UIViewController");
    Class ClsScreen  = NSClassFromString(@"UIScreen");
    Class ClsColor   = NSClassFromString(@"UIColor");
    Class ClsPanGR   = NSClassFromString(@"UIPanGestureRecognizer");
    Class ClsTapGR   = NSClassFromString(@"UITapGestureRecognizer");
    if (!ClsWindow || !ClsView || !ClsVC || !ClsScreen || !ClsColor || !ClsPanGR || !ClsTapGR) {
        NSLog(@"[FloatingTap] 系统类缺失，跳过创建");
        return;
    }

    id mainScreen = ((Msg_Send)objc_msgSend)((id)ClsScreen, @selector(mainScreen));
    CGRect sb = ((Msg_Bounds)objc_msgSend)(mainScreen, @selector(bounds));
    CGFloat sw = sb.size.width, sh = sb.size.height;

    CGFloat d = 56.0;
    CGRect ballFrame = CGRectMake(sw / 2 - d / 2, sh / 2 - d / 2, d, d);

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

    // Gesture recognizers（**不指定 target**，由 NSTimer 轮询）
    gPanGR = ((Msg_AllocInitWithTargetAction)objc_msgSend)((id)ClsPanGR, @selector(alloc), nil, NULL);
    // initWithTarget:action: 必须给一个非 nil target 才会保留——这里我们仍然给 nil，
    // 但需要调一次 initWithTarget:action: 才能拿到实例。可以用 nil target。
    if (!gPanGR) {
        // 兜底：用默认 init
        gPanGR = ((Msg_Send)objc_msgSend)((id)ClsPanGR, @selector(new));
    }
    gTapGR = ((Msg_AllocInitWithTargetAction)objc_msgSend)((id)ClsTapGR, @selector(alloc), nil, NULL);
    if (!gTapGR) {
        gTapGR = ((Msg_Send)objc_msgSend)((id)ClsTapGR, @selector(new));
    }
    ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR, @selector(setNumberOfTapsRequired:), (NSUInteger)2);
    ((Msg_SetMinimumNumberOfTouches)objc_msgSend)(gTapGR, @selector(setMinimumNumberOfTouches:), (NSUInteger)1);
    ((Msg_SetDelaysTouchesBegan)objc_msgSend)(gPanGR, @selector(setDelaysTouchesBegan:), NO);
    ((Msg_SetDelaysTouchesEnded)objc_msgSend)(gPanGR, @selector(setDelaysTouchesEnded:), NO);
    ((Msg_SetCancelsTouchesInView)objc_msgSend)(gPanGR, @selector(setCancelsTouchesInView:), NO);

    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, @selector(addGestureRecognizer:), gPanGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, @selector(addGestureRecognizer:), gTapGR);

    ((Msg_SetView)objc_msgSend)(vc, @selector(setView:), ball);
    ((Msg_SetRootVC)objc_msgSend)(win, @selector(setRootViewController:), vc);

    gBallWindow = win;
    gBallRootVC = vc;
    gBallView   = ball;

    // 20Hz 轮询（target=nil 的 GR 不会被回调，必须轮询 state）
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(0.05 * NSEC_PER_SEC), (uint64_t)(0.01 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        FTOnPanTick();
        FTOnTapTick();
    });
    dispatch_resume(timer);

    NSLog(@"[FloatingTap] v1.0.14 小球已显示 (target=nil GR + 20Hz 轮询) 位置=(%.0f,%.0f)", ballFrame.origin.x, ballFrame.origin.y);
}

%ctor {
    NSLog(@"[FloatingTap] v1.0.14 已加载（零 %hook 零 @implementation 版）");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FTSetupBall();
    });
}

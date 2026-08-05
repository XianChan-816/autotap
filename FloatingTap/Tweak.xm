//
//  Tweak.xm — FloatingTap v1.0.13（零 ObjC 类验证版）
//
//  结论回顾：任何包含 @implementation 的 dylib 注入 SpringBoard 都会卡死
//  （升级 ElleKit 后依然如此，已实测 1.0.12 空 ObjC 类仍卡）。
//  本版本彻底移除自定义 ObjC 类：
//    - 纯 C 函数 + objc_msgSend 类型化调用，动态创建系统 UIView 小球（不定义新类）
//    - %hook 仅做方法交换（不注册新类），捕获小球触摸
//    - 小球使用独立小窗口（56x56），区域外触摸天然穿透，无需 FTPassthroughView 子类
//
//  目的：验证「零 @implementation 类」dylib 注入 SpringBoard 不再卡死，且小球可显示。
//  若本版不卡，v1.0.14 再补全 HID 连点引擎与配置读取。
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - objc_msgSend 类型化函数指针
// 直接 variadic 调用 objc_msgSend 传 CGRect/CGFloat 有 ABI 歧义，
// 必须 cast 成与目标方法签名一致的函数指针，编译器才会按正确规则传参。

typedef id         (*Msg_Send)(id, SEL);
typedef id         (*Msg_AllocInitWithFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetBackgroundColor)(id, SEL, id);
typedef void       (*Msg_SetUserInteractionEnabled)(id, SEL, BOOL);
typedef void       (*Msg_SetHidden)(id, SEL, BOOL);
typedef void       (*Msg_SetWindowLevel)(id, SEL, CGFloat);
typedef void       (*Msg_SetRootVC)(id, SEL, id);
typedef void       (*Msg_SetView)(id, SEL, id);
typedef id         (*Msg_Layer)(id, SEL);
typedef void       (*Msg_SetCornerRadius)(id, SEL, CGFloat);
typedef void       (*Msg_SetBorderWidth)(id, SEL, CGFloat);
typedef void       (*Msg_SetBorderColor)(id, SEL, CGColorRef);
typedef id         (*Msg_ColorWithRGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
typedef CGColorRef (*Msg_CGColor)(id, SEL);

// MARK: - 全局状态（纯 C，不定义任何 ObjC 类）

static id gBallWindow = nil;
static id gBallRootVC = nil;
static id gBallView   = nil;

static id FTAllocInitWithFrame(Class cls, CGRect frame) {
    static Msg_AllocInitWithFrame fn = (Msg_AllocInitWithFrame)objc_msgSend;
    id obj = ((Msg_Send)objc_msgSend)((id)cls, @selector(alloc));
    return fn(obj, @selector(initWithFrame:), frame);
}

static void FTSetupBall(void) {
    if (gBallWindow) return;

    Class ClsWindow  = NSClassFromString(@"UIWindow");
    Class ClsView    = NSClassFromString(@"UIView");
    Class ClsVC      = NSClassFromString(@"UIViewController");
    Class ClsScreen  = NSClassFromString(@"UIScreen");
    Class ClsUIColor = NSClassFromString(@"UIColor");
    if (!ClsWindow || !ClsView || !ClsVC || !ClsScreen || !ClsUIColor) {
        NSLog(@"[FloatingTap] 系统类缺失，跳过创建");
        return;
    }

    // 屏幕尺寸
    typedef CGRect (*Msg_Bounds)(id, SEL);
    id mainScreen = ((Msg_Send)objc_msgSend)((id)ClsScreen, @selector(mainScreen));
    CGRect sb = ((Msg_Bounds)objc_msgSend)(mainScreen, @selector(bounds));
    CGFloat sw = sb.size.width, sh = sb.size.height;

    // 小球尺寸与位置（先居中显示）
    CGFloat d = 56.0;
    CGRect ballFrame = CGRectMake(sw / 2 - d / 2, sh / 2 - d / 2, d, d);

    // 独立小球窗口：窗口只有小球大小 → 区域外触摸天然穿透给下层 App
    id win = FTAllocInitWithFrame(ClsWindow, ballFrame);
    ((Msg_SetWindowLevel)objc_msgSend)(win, @selector(setWindowLevel:), (CGFloat)1001.0);
    ((Msg_SetHidden)objc_msgSend)(win, @selector(setHidden:), NO);

    id vc = ((Msg_Send)objc_msgSend)((id)ClsVC, @selector(new));

    // 小球视图
    id ball = FTAllocInitWithFrame(ClsView, CGRectMake(0, 0, d, d));
    ((Msg_SetUserInteractionEnabled)objc_msgSend)(ball, @selector(setUserInteractionEnabled:), YES);
    ((Msg_SetBackgroundColor)objc_msgSend)(ball, @selector(setBackgroundColor:),
        ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsUIColor, @selector(colorWithRed:green:blue:alpha:),
                                          0.0, 0.478, 1.0, 0.9));

    // 圆角 + 白色描边（纯 layer 操作，不需要子类）
    id layer = ((Msg_Layer)objc_msgSend)(ball, @selector(layer));
    ((Msg_SetCornerRadius)objc_msgSend)(layer, @selector(setCornerRadius:), (CGFloat)(d / 2.0));
    ((Msg_SetBorderWidth)objc_msgSend)(layer, @selector(setBorderWidth:), (CGFloat)2.5);
    id white = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsUIColor, @selector(colorWithRed:green:blue:alpha:),
                                                 1.0, 1.0, 1.0, 1.0);
    ((Msg_SetBorderColor)objc_msgSend)(layer, @selector(setBorderColor:),
                                       ((Msg_CGColor)objc_msgSend)(white, @selector(CGColor)));

    ((Msg_SetView)objc_msgSend)(vc, @selector(setView:), ball);
    ((Msg_SetRootVC)objc_msgSend)(win, @selector(setRootViewController:), vc);

    gBallWindow = win;
    gBallRootVC = vc;
    gBallView   = ball;
    NSLog(@"[FloatingTap] v1.0.13 小球已显示 (%0.1f,%0.1f)", ballFrame.origin.x, ballFrame.origin.y);
}

// MARK: - 触摸捕获（方法交换，不注册新类；仅小球实例响应）

%hook UIView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self == gBallView) {
        NSLog(@"[FloatingTap] 小球按下");
    }
    %orig;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self == gBallView) {
        NSLog(@"[FloatingTap] 小球抬起");
    }
    %orig;
}
%end

// MARK: - 构造

%ctor {
    NSLog(@"[FloatingTap] v1.0.13 已加载（零 ObjC 类版）");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FTSetupBall();
    });
}

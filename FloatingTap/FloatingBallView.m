//
//  FloatingBallView.m
//  FloatingTap
//
//  实现：悬浮球 window、拖动/捏合/长按手势、点击注入引擎、配置持久化。
//
//  注入穿透说明：悬浮球占据点击点，若悬浮球 window 处于交互状态会拦截注入的
//  系统触摸。因此每次注入前临时关闭 window 交互（毫秒级），让新触摸穿透到
//  下层 App，注入完成立即恢复。用户按住的触摸序列不受影响。
//

#import "FloatingBallView.h"
#import "HIDInject.h"
#import <objc/runtime.h>

// 等价 systemRed / systemBlue 的显式 RGB（不依赖 SDK 缺失的 system 颜色属性）
static UIColor *FTTapColor(BOOL clicking) {
    return clicking
        ? [UIColor colorWithRed:1.0 green:0.231 blue:0.188 alpha:1.0]   // ~systemRed
        : [UIColor colorWithRed:0.0 green:0.478 blue:1.0   alpha:1.0];  // ~systemBlue
}

static NSString *const kPrefsBallX      = @"FloatingTap.ballX";
static NSString *const kPrefsBallY      = @"FloatingTap.ballY";
static NSString *const kPrefsBallSize   = @"FloatingTap.ballSize";
static NSString *const kPrefsIntervalMs = @"FloatingTap.intervalMs";

@interface FloatingBallView ()
@property (nonatomic, strong) UIWindow *ballWindow;
@property (nonatomic, strong) UIView *ring;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, assign) CGFloat diameter;
@property (nonatomic, assign) BOOL isClicking;
@property (nonatomic, strong) dispatch_source_t clickTimer;
@property (nonatomic, assign) CGPoint panAnchor;
@end

@implementation FloatingBallView

+ (instancetype)shared {
    static FloatingBallView *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[FloatingBallView alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(0, 0, 56, 56)];
    if (self) {
        _diameter = 56;
        self.userInteractionEnabled = YES;
        [self setupSubviews];
        [self setupGestures];
        [self updateAppearance];
    }
    return self;
}

// MARK: - 显示 / 移除

- (void)present {
    if (self.ballWindow) return;

    // SpringBoard 场景
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = 1001; // 高于普通 App 与状态栏，低于键盘
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = YES;

    UIViewController *rootVC = [UIViewController new];
    rootVC.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = rootVC;
    [window makeKeyAndVisible];

    // 悬浮球挂到 rootVC.view（避免被 SpringBoard 普通 window 遮挡）
    [rootVC.view addSubview:self];
    [rootVC.view bringSubviewToFront:self];

    self.ballWindow = window;

    // 恢复上次位置/大小
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    double x = [def doubleForKey:kPrefsBallX];
    double y = [def doubleForKey:kPrefsBallY];
    double size = [def doubleForKey:kPrefsBallSize];
    if (size >= 24 && size <= 160) self.diameter = size;
    [self updateAppearance];

    CGSize ss = [UIScreen mainScreen].bounds.size;
    CGFloat cx = (x > 0 && x < 1) ? x * ss.width : ss.width * 0.85;
    CGFloat cy = (y > 0 && y < 1) ? y * ss.height : ss.height * 0.25;
    self.center = CGPointMake(cx, cy);
}

- (void)dismiss {
    if (self.clickTimer) {
        dispatch_source_cancel(self.clickTimer);
        self.clickTimer = nil;
    }
    self.isClicking = NO;
    [self.ballWindow removeFromSuperview];
    self.ballWindow = nil;
    [self removeFromSuperview];
}

// MARK: - 子视图 / 外观

- (void)setupSubviews {
    _ring = [[UIView alloc] initWithFrame:self.bounds];
    _ring.userInteractionEnabled = NO;
    [self addSubview:_ring];

    _dot = [[UIView alloc] init];
    _dot.userInteractionEnabled = NO;
    [self addSubview:_dot];
}

- (void)setupGestures {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];

    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.35;
    [self addGestureRecognizer:longPress];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [self addGestureRecognizer:pinch];
}

- (void)updateAppearance {
    CGFloat d = self.diameter;
    self.bounds = CGRectMake(0, 0, d, d);
    self.layer.cornerRadius = d / 2;

    self.ring.frame = self.bounds;
    self.ring.layer.cornerRadius = d / 2;
    self.ring.layer.borderWidth = 2.5;
    self.ring.layer.borderColor = FTTapColor(self.isClicking).CGColor;
    self.ring.backgroundColor = [UIColor colorWithRed:(self.isClicking ? 0.85 : 0.15)
                                                green:(self.isClicking ? 0.10 : 0.35)
                                                 blue:(self.isClicking ? 0.10 : 0.85)
                                                alpha:(self.isClicking ? 0.45 : 0.20)];

    CGFloat dotSize = 10;
    self.dot.frame = CGRectMake((d - dotSize) / 2, (d - dotSize) / 2, dotSize, dotSize);
    self.dot.layer.cornerRadius = dotSize / 2;
    self.dot.backgroundColor = self.isClicking ? [UIColor whiteColor] : FTTapColor(NO);

    // 准星（圆心 = 点击点）
    [self.layer.sublayers enumerateObjectsUsingBlock:^(CALayer *layer, NSUInteger idx, BOOL *stop) {
        if ([layer.name isEqualToString:@"FloatingTap.cross"]) [layer removeFromSuperlayer];
    }];
    CAShapeLayer *cross = [CAShapeLayer layer];
    cross.name = @"FloatingTap.cross";
    cross.strokeColor = FTTapColor(self.isClicking).CGColor;
    cross.lineWidth = 1;
    cross.frame = self.bounds;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(0, d / 2)];
    [path addLineToPoint:CGPointMake(d, d / 2)];
    [path moveToPoint:CGPointMake(d / 2, 0)];
    [path addLineToPoint:CGPointMake(d / 2, d)];
    cross.path = path.CGPath;
    [self.layer addSublayer:cross];
}

// MARK: - 手势

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGSize ss = [UIScreen mainScreen].bounds.size;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.panAnchor = [g locationInView:self.superview];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [g locationInView:self.superview];
        CGPoint c = self.center;
        c.x += p.x - self.panAnchor.x;
        c.y += p.y - self.panAnchor.y;
        self.panAnchor = p;
        CGFloat r = self.diameter / 2;
        c.x = MIN(MAX(c.x, r), MAX(r, ss.width - r));
        c.y = MIN(MAX(c.y, r), MAX(r, ss.height - r));
        self.center = c;
        [self persistPosition];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        [self startClicking];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        [self stopClicking];
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat newD = MIN(MAX(self.diameter * g.scale, 24), 160);
        g.scale = 1;
        self.diameter = newD;
        [self updateAppearance];
        [self persistSize];
    }
}

// MARK: - 点击引擎

- (void)startClicking {
    if (self.isClicking) return;
    if (![[HIDInject shared] connect]) {
        NSLog(@"[FloatingTap] HID 连接失败，无法开始点击");
        return;
    }
    self.isClicking = YES;
    [self updateAppearance];

    double intervalMs = [self clickInterval];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, intervalMs * NSEC_PER_MSEC, 0);

    __weak typeof(self) wself = self;
    dispatch_source_set_event_handler(timer, ^{
        [wself injectClick];
    });
    dispatch_resume(timer);
    self.clickTimer = timer;
}

- (void)stopClicking {
    if (!self.isClicking) return;
    self.isClicking = NO;
    if (self.clickTimer) {
        dispatch_source_cancel(self.clickTimer);
        self.clickTimer = nil;
    }
    [self updateAppearance];
}

- (double)clickInterval {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    double ms = [def doubleForKey:kPrefsIntervalMs];
    return (ms >= 1 && ms <= 60000) ? ms : 200.0;
}

- (void)injectClick {
    CGFloat x = self.center.x / [UIScreen mainScreen].bounds.size.width;
    CGFloat y = self.center.y / [UIScreen mainScreen].bounds.size.height;
    x = MIN(MAX(x, 0.001), 0.999);
    y = MIN(MAX(y, 0.001), 0.999);

    HIDTap *tap = [[HIDTap alloc] init];
    tap.normalizedX = x;
    tap.normalizedY = y;

    // 主线程临时关闭 window 交互，让注入触摸穿透到下层 App
    dispatch_async(dispatch_get_main_queue(), ^{
        self.ballWindow.userInteractionEnabled = NO;
        [[HIDInject shared] tapAt:tap];
        self.ballWindow.userInteractionEnabled = YES;
    });
}

// MARK: - 持久化

- (void)persistPosition {
    CGSize ss = [UIScreen mainScreen].bounds.size;
    if (ss.width > 0 && ss.height > 0) {
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        [def setDouble:self.center.x / ss.width forKey:kPrefsBallX];
        [def setDouble:self.center.y / ss.height forKey:kPrefsBallY];
        [def synchronize];
    }
}

- (void)persistSize {
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def setDouble:self.diameter forKey:kPrefsBallSize];
    [def synchronize];
}

@end

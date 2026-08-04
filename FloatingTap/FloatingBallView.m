//
//  FloatingBallView.m
//  FloatingTap
//
//  实现：悬浮球 window、长按手势（立即触发连点）、点击注入引擎、位置由 AutoTap 配置下发。
//
//  穿透说明：悬浮球 window 全屏透明，用 FTPassthroughView 的 hitTest 实现
//  「空白区域穿透」——只有球本体接收手势，其余触摸原样交给下层 App/游戏。
//  注入的 HID 事件走系统事件管线，不经由 window 命中测试，无需开关交互。
//

#import "FloatingBallView.h"
#import "HIDInject.h"
#import <objc/runtime.h>

// 共享配置（AutoTap App 与 tweak 共同读写；rootless 下系统偏好目录不变）
NSString *const kFloatingTapConfigPath = @"/var/mobile/Library/Preferences/FloatingTap.plist";
NSString *const kFTKeyTargets   = @"Targets";
NSString *const kFTKeyIntervalMs= @"IntervalMs";
NSString *const kFTKeyClickX     = @"ClickX";
NSString *const kFTKeyClickY     = @"ClickY";

// tweak（SpringBoard 特权进程）枚举出的已装 App 清单，供 AutoTap App 读取
// 普通 App 受沙盒/文件权限限制无法枚举，故由 tweak 代劳并写入 mobile 可读路径
NSString *const kFloatingTapAppsDumpPath = @"/var/mobile/Library/Preferences/FloatingTap.apps.plist";

// 等价 systemRed / systemBlue 的显式 RGB（不依赖 SDK 缺失的 system 颜色属性）
static UIColor *FTTapColor(BOOL clicking) {
    return clicking
        ? [UIColor colorWithRed:1.0 green:0.231 blue:0.188 alpha:1.0]   // ~systemRed
        : [UIColor colorWithRed:0.0 green:0.478 blue:1.0   alpha:1.0];  // ~systemBlue
}

// 全屏透明容器：空白区域把触摸穿透给下层 App，只有悬浮球自身接收手势
@interface FTPassthroughView : UIView
@end
@implementation FTPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit; // 命中自己=空白区，放行给下层
}
@end

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
    FTPassthroughView *container = [[FTPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    container.backgroundColor = [UIColor clearColor];
    rootVC.view = container;
    window.rootViewController = rootVC;
    [window setHidden:NO]; // 不抢 keyWindow，避免干扰下层 App 的输入焦点

    // 悬浮球挂到 rootVC.view（避免被 SpringBoard 普通 window 遮挡）
    [container addSubview:self];
    [container bringSubviewToFront:self];

    self.ballWindow = window;

    // 目标 App 内悬浮球不可拖动/缩放，大小固定（updateAppearance 已按默认直径绘制）
    [self updateAppearance];

    // 位置由 AutoTap 配置下发（用户在 App 内调节点击位置，此处只读不调）
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kFloatingTapConfigPath];
    double cxN = 0.5, cyN = 0.5;
    id vx = cfg[kFTKeyClickX], vy = cfg[kFTKeyClickY];
    if ([vx respondsToSelector:@selector(doubleValue)]) cxN = [vx doubleValue];
    if ([vy respondsToSelector:@selector(doubleValue)]) cyN = [vy doubleValue];
    cxN = MIN(MAX(cxN, 0.0), 1.0);
    cyN = MIN(MAX(cyN, 0.0), 1.0);

    CGSize ss = [UIScreen mainScreen].bounds.size;
    self.center = CGPointMake(cxN * ss.width, cyN * ss.height);
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
    // 长按：立即触发连点（目标 App 内悬浮球不可拖动/缩放，只按住触发）
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.0;   // 手指一碰圆圈即开始连点
    longPress.allowableMovement = 30;       // 抖动不误判为取消
    [self addGestureRecognizer:longPress];

    // 双击：关闭悬浮球（想恢复时切走目标 App 再切回，或 sbreload）
    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [self addGestureRecognizer:doubleTap];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    [self dismiss];
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

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        [self startClicking];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        [self stopClicking];
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
    // 优先读共享配置（AutoTap App 设置），其次回退 NSUserDefaults
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kFloatingTapConfigPath];
    id v = cfg[kFTKeyIntervalMs];
    if ([v respondsToSelector:@selector(doubleValue)]) {
        double ms = [v doubleValue];
        if (ms >= 1 && ms <= 60000) return ms;
    }
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    double ms = [def doubleForKey:kPrefsIntervalMs];
    return (ms >= 1 && ms <= 60000) ? ms : 200.0;
}

// MARK: - 前台 App 检测 / 显隐控制

/// 读取共享配置中的目标 App 列表
- (NSArray<NSString *> *)loadTargets {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kFloatingTapConfigPath];
    NSArray *targets = cfg[kFTKeyTargets];
    return [targets isKindOfClass:[NSArray class]] ? targets : @[];
}

/// 获取当前前台 App 的 bundleIdentifier（SpringBoard 私有 API，KVC 动态访问）
- (NSString *)frontmostBundleID {
    // 仅使用 SBApplicationController.frontmostApplication（SpringBoard 进程内可用、稳定）
    // 不再回退到 UIApplication.sharedApplication（启动早期调用容易崩 SB）
    @try {
        Class sbClass = NSClassFromString(@"SBApplicationController");
        if (!sbClass) return nil;
        id controller = [sbClass valueForKey:@"sharedInstance"];
        if (!controller) return nil;
        id app = [controller valueForKey:@"frontmostApplication"];
        if (!app) return nil;
        NSString *bid = [app valueForKey:@"bundleIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) return bid;
    } @catch (NSException *ex) {
        NSLog(@"[FloatingTap] frontmostBundleID 异常: %@", ex);
    }
    return nil;
}

- (void)updateVisibilityForFrontmostApp {
    // 整个方法 try/catch 保护：SpringBoard 启动期/异常态 KVC 抛异常也不会拖死 SB
    @try {
        NSString *frontID = [self frontmostBundleID];
        NSArray *targets = [self loadTargets];
        BOOL shouldShow = (frontID.length > 0 && [targets containsObject:frontID]);

        if (shouldShow) {
            if (!self.ballWindow) {
                [self present];
                NSLog(@"[FloatingTap] 目标 App %@ 在前台，显示悬浮球", frontID);
            }
        } else {
            if (self.ballWindow) {
                [self dismiss];
            }
        }
    } @catch (NSException *ex) {
        NSLog(@"[FloatingTap] updateVisibility 异常: %@", ex);
    }
}

/// 枚举系统内所有已装 App，写入 kFloatingTapAppsDumpPath 供 AutoTap App 读取。
/// SpringBoard 是特权进程，LSApplicationWorkspace 枚举无限制；写到的路径对 mobile 用户可读。
/// 普通 App 受沙盒 + 文件权限（/var/containers 属 root 0700）双重限制无法枚举，故由 tweak 代劳。
- (void)dumpInstalledApps {
    @try {
        Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!lsClass) return;
        SEL selDef = NSSelectorFromString(@"defaultWorkspace");
        if (![lsClass respondsToSelector:selDef]) return;
        id ws = [lsClass performSelector:selDef];
        if (!ws) return;
        SEL selAll = NSSelectorFromString(@"allApplications");
        if (![ws respondsToSelector:selAll]) return;
        NSArray *apps = [ws performSelector:selAll];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (id proxy in apps) {
            NSString *bid = [proxy performSelector:NSSelectorFromString(@"bundleIdentifier")];
            if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
            NSString *name = [proxy performSelector:NSSelectorFromString(@"localizedName")];
            if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bid;
            dict[bid] = name;
        }
        [dict writeToFile:kFloatingTapAppsDumpPath atomically:YES];
        NSLog(@"[FloatingTap] 已导出 %lu 个已装 App 到 %@",
              (unsigned long)dict.count, kFloatingTapAppsDumpPath);
    } @catch (NSException *ex) {
        NSLog(@"[FloatingTap] dumpInstalledApps 异常: %@", ex);
    }
}

- (void)injectClick {
    CGFloat x = self.center.x / [UIScreen mainScreen].bounds.size.width;
    CGFloat y = self.center.y / [UIScreen mainScreen].bounds.size.height;
    x = MIN(MAX(x, 0.001), 0.999);
    y = MIN(MAX(y, 0.001), 0.999);

    HIDTap *tap = [[HIDTap alloc] init];
    tap.normalizedX = x;
    tap.normalizedY = y;

    // 直接注入 HID 事件（穿透已由 FTPassthroughView 保证，无需开关 window）
    [[HIDInject shared] tapAt:tap];
}

@end

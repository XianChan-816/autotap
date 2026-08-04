//
//  Tweak.xm
//  FloatingTap
//
//  Logos 入口：SpringBoard 启动后启动前台 App 监控。
//  注入目标：com.apple.springboard（见 FloatingTap.plist）
//
//  行为：每 0.5s 检测一次前台 App，若其 bundleID 在共享配置
//  （/var/mobile/Library/Preferences/FloatingTap.plist 的 Targets 列表）中，
//  则显示悬浮球；离开目标 App 立即隐藏。不再全局常驻。
//

#import "FloatingBallView.h"

%ctor {
    // SpringBoard 完全启动后再启动监控（8 秒延迟，避免启动期 KVC 私有 API 导致 SB 崩溃）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(NSTimer *t) {
            // 整个轮询用 @try/@catch 包裹，KVC 抛异常不会拖死 SpringBoard
            @try {
                [[FloatingBallView shared] updateVisibilityForFrontmostApp];
            } @catch (NSException *ex) {
                NSLog(@"[FloatingTap] 轮询异常: %@", ex);
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        @try {
            [[FloatingBallView shared] updateVisibilityForFrontmostApp];
        } @catch (NSException *ex) {
            NSLog(@"[FloatingTap] 启动首检异常: %@", ex);
        }
        NSLog(@"[FloatingTap] 前台 App 监控已启动（0.5s 轮询）");
    });
}

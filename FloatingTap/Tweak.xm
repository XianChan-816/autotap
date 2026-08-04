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
    // 立即写入心跳（证明 tweak 已加载），不等 8s 延迟
    @try { [[FloatingBallView shared] writeHeartbeat]; }
    @catch (NSException *ex) { NSLog(@"[FloatingTap] 心跳写入异常: %@", ex); }

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

        // 导出已装 App 清单给 AutoTap App 读取（SpringBoard 特权枚举，普通 App 做不到）
        @try {
            [[FloatingBallView shared] dumpInstalledApps];
        } @catch (NSException *ex) {
            NSLog(@"[FloatingTap] 导出 App 清单异常: %@", ex);
        }
        // 每 60s 刷新一次，覆盖新安装的 App
        NSTimer *dumpTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                              repeats:YES
                                                                block:^(NSTimer *t) {
            @try { [[FloatingBallView shared] dumpInstalledApps]; }
            @catch (NSException *ex) { NSLog(@"[FloatingTap] 刷新 App 清单异常: %@", ex); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:dumpTimer forMode:NSRunLoopCommonModes];

        // 每 30s 刷新心跳（让 App 端能判断 tweak 是否仍在运行）
        NSTimer *hbTimer = [NSTimer scheduledTimerWithTimeInterval:30
                                                           repeats:YES
                                                             block:^(NSTimer *t) {
            @try { [[FloatingBallView shared] writeHeartbeat]; }
            @catch (NSException *ex) { NSLog(@"[FloatingTap] 心跳刷新异常: %@", ex); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:hbTimer forMode:NSRunLoopCommonModes];

        NSLog(@"[FloatingTap] 前台 App 监控已启动（0.5s 轮询）");
    });
}

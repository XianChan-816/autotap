//
//  Tweak.xm
//  FloatingTap
//
//  Logos 入口：SpringBoard 启动完成后挂载全局悬浮球。
//  注入目标：com.apple.springboard（见 FloatingTap.plist）
//

#import "FloatingBallView.h"

%ctor {
    // SpringBoard 完全启动后再挂载悬浮球（3 秒延迟，避免启动期冲突）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[FloatingBallView shared] present];
        NSLog(@"[FloatingTap] 悬浮球已挂载");
    });
}

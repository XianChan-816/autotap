//
//  FloatingBallView.h
//  FloatingTap
//
//  全局悬浮球：显示在 SpringBoard 最高层 window，任意 App 上可见。
//  拖动调位置、捏合调大小、长按触发点击（松开停止）、点击位置 = 圆心。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FloatingBallView : UIView

+ (instancetype)shared;

/// 创建并显示悬浮球（window 挂到 SpringBoard 顶层）
- (void)present;

/// 移除悬浮球
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END

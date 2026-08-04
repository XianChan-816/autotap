//
//  FloatingBallView.h
//  FloatingTap
//
//  全局悬浮球：显示在 SpringBoard 最高层 window，任意 App 上可见。
//  拖动调位置、捏合调大小、长按触发点击（松开停止）、点击位置 = 圆心。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 共享配置文件路径（AutoTap App 与 tweak 共同读写）
extern NSString *const kFloatingTapConfigPath;

/// 共享配置键
extern NSString *const kFTKeyTargets;   // NSArray<NSString *>：目标 App bundleID 列表
extern NSString *const kFTKeyIntervalMs;// NSNumber：连点间隔（毫秒）

@interface FloatingBallView : UIView

+ (instancetype)shared;

/// 创建并显示悬浮球（window 挂到 SpringBoard 顶层）
- (void)present;

/// 移除悬浮球
- (void)dismiss;

/// 依据前台 App 是否在目标列表，自动显示/隐藏悬浮球（由 Tweak.xm 定时调用）
- (void)updateVisibilityForFrontmostApp;

/// 枚举系统内已装 App 并写入 kFloatingTapAppsDumpPath（仅 SpringBoard 特权进程调用）
- (void)dumpInstalledApps;

@end

NS_ASSUME_NONNULL_END

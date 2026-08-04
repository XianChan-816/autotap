//
//  FloatingBallView.h
//  FloatingTap
//
//  全局悬浮球：显示在 SpringBoard 最高层 window，任意 App 上可见。
//  拖动调位置、捏合调大小、长按触发点击（松开停止）、点击位置 = 圆心。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 共享配置文件路径（运行时由 FTSetAppCachesDir 设置为 App 沙盒 Caches 路径）
extern NSString *kFloatingTapConfigPath;

/// 共享配置键
extern NSString *const kFTKeyTargets;   // NSArray<NSString *>：目标 App bundleID 列表
extern NSString *const kFTKeyIntervalMs;// NSNumber：连点间隔（毫秒）

/// 拿到 AutoTap.app 沙盒 Caches 路径后由 Tweak.xm 调用（Darwin notification 回调里执行）
/// 之后所有跨进程 plist 读写都走此路径（App 100% 可读自己沙盒）
extern void FTSetAppCachesDir(NSString *dir);
extern NSString *FTGetAppCachesDir(void);

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

/// tweak 加载心跳：%ctor 立即写入，供 AutoTap App 判断 tweak 是否在线（类方法，不碰 UIKit）
+ (void)writeHeartbeat;

@end

NS_ASSUME_NONNULL_END

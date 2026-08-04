//
//  HIDInject.h
//  FloatingTap
//
//  IOHIDEvent 私有接口注入层（移植自 AutoTap App 版 HIDBridge）。
//  运行在 SpringBoard 进程（越狱环境），权限天然满足。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 一次完整的"按下-抬起"点击
@interface HIDTap : NSObject
/// 归一化坐标 (0~1)，以竖屏 home 在下为基准
@property (nonatomic, assign) CGFloat normalizedX;
@property (nonatomic, assign) CGFloat normalizedY;
@end

@interface HIDInject : NSObject

@property (nonatomic, readonly, getter=isConnected) BOOL connected;

+ (instancetype)shared;

- (BOOL)connect;

/// 在指定归一化坐标上执行一次点击（按下 + 抬起）
- (void)tapAt:(HIDTap *)tap;

/// 按下（长按场景）
- (void)tapDown:(HIDTap *)tap;

/// 抬起
- (void)tapUp:(HIDTap *)tap;

@end

NS_ASSUME_NONNULL_END

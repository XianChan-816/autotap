//
//  HIDBridge.h
//  AutoTap
//
//  通过苹果私有 IOHIDEvent 接口向系统全局注入触摸事件。
//  仅用于自动化测试 / 辅助功能场景；在越狱设备或 TrollStore 环境中使用。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一次完整的"按下-抬起"点击
@interface HIDTap : NSObject
/// 归一化坐标 (0~1)，以竖屏 home 键在下为基准
@property (nonatomic, assign) CGFloat normalizedX;
@property (nonatomic, assign) CGFloat normalizedY;
@end

@interface HIDBridge : NSObject

/// 是否已成功建立 HID 系统连接（代表权限生效）
@property (nonatomic, readonly, getter=isConnected) BOOL connected;

+ (instancetype)shared;

/// 初始化并连接 HID 系统服务。失败返回 NO（多为缺少 entitlement）
- (BOOL)connect;

/// 在指定归一化坐标上执行一次点击（按下 + 抬起）
- (void)tapAt:(HIDTap *)tap;

/// 按下（长按场景：配合 tapUp 使用）
- (void)tapDown:(HIDTap *)tap;

/// 抬起
- (void)tapUp:(HIDTap *)tap;

@end

NS_ASSUME_NONNULL_END

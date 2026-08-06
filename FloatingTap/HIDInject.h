//
//  HIDInject.h — FloatingTap HID 注入引擎（纯 C 版）
//
//  v1.0.20：由 ObjC 类 HIDInject/HIDTap 重写为纯 C 函数。
//  原因：arm64e 注入环境下 dylib 内任何 ObjC 元数据都会触发 PAC 失败崩 SB，
//  必须零 @implementation / @"..." / block。
//  对外只暴露三个函数；内部 dlopen IOHIDEvent 符号动态解析。
//

#ifndef HIDInject_h
#define HIDInject_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 不完整类型前置声明（仅作不透明指针使用）
struct __IOHIDEvent;
typedef struct __IOHIDEvent *FT_IOHIDEventRef;

// 连接 HID 系统（幂等；失败返回 false 并打 syslog）
bool FT_HIDConnect(void);

// 是否已连接
bool FT_HIDIsConnected(void);

// 在归一化坐标 (0~1, 0~1) 处发一次完整点击（down + up）
void FT_HIDTapAt(double normalizedX, double normalizedY);

// v1.0.62：分别派发 down / up 事件到「系统 HID 服务」（IOHIDEventSystemClientDispatchEvent），
// 由系统路由到前台 App——这是 zxtouch/autotouch 的标准全局注入入口。
// 注意：绝不能改走 SpringBoard 的 UIApplication._handleHIDEvent:（那只会喂 SB 自己的
// 事件队列，前台 App 收不到，游戏内点击无效）。保持 down 立即、up 延迟，让系统把
// 同一触摸关联为完整 tap（down/up 用相同 index）。
void FT_HIDDispatchDown(double normalizedX, double normalizedY, uint32_t index);
void FT_HIDDispatchUp(double normalizedX, double normalizedY, uint32_t index);

// 构造一个 digitizer 事件（down=true 按下 / down=false 抬起），坐标归一化，
// index 用于区分触摸（同一 tap 的 down/up 用相同 index，不同 tap 递增避免被串流）。
// 返回 +1 的 IOHIDEvent（调用方负责 CFRelease）。
FT_IOHIDEventRef FT_HIDCreateDigitizerEvent(bool down, double normalizedX, double normalizedY, uint32_t index);

// 返回 senderID（v1.0.53：直接用硬编码兜底值；原捕获机制在 arm64e SB 里
// 注册 IOHID 事件回调 = Safe Mode 元凶，已废弃）
uint64_t FT_HIDSenderID(void);

#ifdef __cplusplus
}
#endif

#endif /* HIDInject_h */

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

#ifdef __cplusplus
extern "C" {
#endif

// 连接 HID 系统（幂等；失败返回 false 并打 syslog）
bool FT_HIDConnect(void);

// 是否已连接
bool FT_HIDIsConnected(void);

// 在归一化坐标 (0~1, 0~1) 处发一次完整点击（down + up）
void FT_HIDTapAt(double normalizedX, double normalizedY);

#ifdef __cplusplus
}
#endif

#endif /* HIDInject_h */

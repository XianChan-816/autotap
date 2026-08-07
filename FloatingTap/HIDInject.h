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

// 返回 senderID。v1.0.63：优先返回动态捕获的真实设备 senderID（从真实触摸事件读，
// 系统必然认领），未捕获到才用硬编码兜底。硬编码值在 Dopamine rootless + iOS 15.5 上
// 可能被系统静默丢弃（事件派发 ret=success 但无触摸）。
uint64_t FT_HIDSenderID(void);

// v1.0.63：覆盖 senderID（由 Tweak.xm 从真实触摸事件的 _hidEvent 动态捕获后写入）。
// 这是让系统认领合成事件、产生真实点击的关键。
void FT_HIDSetSenderID(uint64_t sid);

// v1.0.63：从 IOHIDEvent 读取 senderID（返回 0 表示无效 / 无法读取）。
uint64_t FT_HIDGetSenderIDFromEvent(FT_IOHIDEventRef event);

// v1.0.63：从真实触摸 UIEvent 读 _hidEvent 的 senderID 并缓存（纯 C 实现，放在 .c 文件
// 以绕开 Theos 对 Tweak.xm 的 ARC 限制——object_getInstanceVariable 在 ARC 下被禁用）。
// 由 Tweak.xm 的 sendEvent: hook 调用，参数传 (__bridge void *)event。
void FT_HIDCaptureSenderIDFromUIEvent(void *event);

// v1.0.100：捕获【非球上（主屏/App 窗口）触摸】的 senderID 存为 g_MainSID（注入首选）——
// 球上触摸被手势服务翻译成 0x1000007af 类无效值（注入顶掉用户手指，ctor-72）；主屏
// digitizer SID（0x100000709 类）系统认领、不顶掉（ctor-69 完美）。由 Tweak.xm 在
// 【确认该事件不含球上触摸】时调用（如触摸 window != _UISystemGestureWindow）。
void FT_HIDCaptureMainSIDFromUIEvent(void *event);

// ⚠️ v1.0.101：SID 运行时自动探测接口——Dopamine 上「送达且不顶掉」的 SID 会话随机
// （ctor-69: 0x100000709 有效；ctor-71/72/73: 0x1000007b1/7af 顶掉），无规律可循。
// Tweak.xm 按住球时逐个候选 SID 注入探测 tap，双重判定（sendEvent 回流=送达、用户手指
// 存活=不顶掉）后锁定 g_WorkingSID，此后连点稳定。
uint64_t FT_HIDGetMainSID(void);
int     FT_HIDGetCapturedCount(void);
uint64_t FT_HIDGetCapturedAt(int i);
void    FT_HIDLockSenderID(uint64_t sid);
void    FT_HIDProbeTap(double nx, double ny, uint64_t sid);
// v1.0.102：探测 tap 带 25ms 延迟 up（同正式连点）——v1.0.101 的立即 up 让合成触摸
// 无可见窗口、送达检测永远失败（ctor-74）。探测统一走这个版本。
void    FT_HIDProbeTapDelayed(double nx, double ny, uint64_t sid);

// v1.0.83：连点停止时强制「抬全手」——派发一个 hand-only up 事件（hand index=99,
// Range=0/Touch=0），让系统把该合成 hand 的所有残留子手指一次抬起。
// 背景：高频连点（10ms）会残留未闭合的合成触摸，污染系统触摸状态机 →
// Home indicator（小白条）上滑手势失效（连点后息屏才恢复）。停止连点立即清场。
void FT_HIDRaiseAllSyntheticUp(void);

#ifdef __cplusplus
}
#endif

#endif /* HIDInject_h */

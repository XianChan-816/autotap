//
//  FTDaemonClient.h — FloatingTap SB 侧控制通道接口（纯 C）
//  v2.8 起：通过 Darwin 通知 + 共享命令文件驱动 backboardd 内注入（不再用 socket）。
//

#ifndef FTDAEMONCLIENT_H
#define FTDAEMONCLIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ping daemon：返回 1 = 存活（可连点走 daemon 注入），0 = daemon 不可用
int FTDaemonPing(void);

// 主动 spawn floatingtapd 独立 daemon（launchd 未拉起时的兜底）。
// 返回 1 = 已尝试 spawn（需再 ping 验证）；0 = spawn 失败/二进制不存在。
int FTDaemonSpawn(void);

// 开始连点：坐标点坐标（SB 已按竖屏基准尺寸换算），intervalMs 毫秒间隔（>5ms），
// sw/sh = 竖屏基准屏幕尺寸（供 backboardd 把点坐标归一化为 HID 0~1 坐标），
// sid = SB 侧捕获的真实硬件 digitizer senderID（backboardd 裸 HID 层事件无 senderID，必须由此推入）
void FTDaemonStartClicking(double nx, double ny, double intervalMs, double sw, double sh, uint64_t sid);

// 停止连点
void FTDaemonStopClicking(void);

// 单次 tap（诊断用）
void FTDaemonSingleTap(double nx, double ny);

// 设置注入 SID（SB 侧探测到的有效 SID 推给 daemon）
void FTDaemonSetSID(uint64_t sid);

#ifdef __cplusplus
}
#endif

#endif // FTDAEMONCLIENT_H

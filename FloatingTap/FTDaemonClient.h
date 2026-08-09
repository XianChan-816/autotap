//
//  FTDaemonClient.h — FloatingTapDaemon XPC 客户端接口（纯 C）
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

// 开始连点：坐标归一化 0~1，intervalMs 毫秒间隔（>5ms）
void FTDaemonStartClicking(double nx, double ny, double intervalMs);

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

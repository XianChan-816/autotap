//
//  FTDaemonClient.c — FloatingTap SB 侧控制通道客户端（纯 C，零 block）
//
//  v2.8 起：backboardd 注入改由【Darwin 通知 + 共享命令文件】驱动，
//  不再用 AF_UNIX socket——backboardd 是强沙盒进程，内部 bind socket 会被
//  沙盒 SIGKILL（v2.7.1 实测黑屏）。
//
//  协议：
//    SB 侧（本文件）              backboardd 侧（BackboardInject.c）
//    ------------------------------------  ------------------------------------
//    写 /tmp/floatingtap_cmd       轮询 notify_check("com.floatingtap.cmd")
//    notify_post(同)         ←——   读到文件后执行 start/stop/tap
//    读 /tmp/floatingtap_bbok      写 "1"（就绪标记，供 SB 探活）
//
//  命令文件一行一条：
//    "start x y ms W H\n"   开始连点（x/y = 屏幕【点坐标】；W/H = 竖屏基准尺寸，供 backboardd 归一化坐标）
//    "stop\n"           停止连点
//    "tap x y\n"        单次 tap（诊断，x/y 同为此前点坐标）
//
//  ⚠️ 纯 C：无 ObjC、无 block。失败静默返回，绝不阻塞 SB 主线程。
//  ⚠️ 路径铁律同 BackboardInject：SB 与 backboardd 都写 "/tmp/X"，
//     在 rootless 下都解析到 jbroot /tmp/X（= 真实 /var/jb/tmp/X），两侧一致。
//

#include "FTDaemonClient.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <notify.h>
#include <time.h>

static const char *g_cmdPath    = "/tmp/floatingtap_cmd";   // SB 写 / backboardd 读
static const char *g_readyPath  = "/tmp/floatingtap_bbok";  // backboardd 写 / SB 探活读
static const char *g_notifyName = "com.floatingtap.cmd";

// v2.1：注入改由 BackboardInject.dylib（注入 backboardd 进程）提供，
// 不再 spawn 独立 floatingtapd（独立进程无 HID entitlement，dispatch 全 ret=0x1，
// v2.0-daemon1/2/3 实测失败）。此函数保留接口但直接返回 0（不 spawn）。
int FTDaemonSpawn(void) {
    return 0;
}

// 探活：读 backboardd 写的就绪标记（stage>=5 命令线程起来后写 "1"）。
int FTDaemonPing(void) {
    FILE *f = fopen(g_readyPath, "r");
    if (!f) return 0;
    int v = 0;
    if (fscanf(f, "%d", &v) != 1) v = 0;
    fclose(f);
    return (v == 1) ? 1 : 0;
}

// 发命令：写共享文件 + 发 Darwin 通知（backboardd 收到通知后读文件执行）。
static void FTDSendCmd(const char *cmd) {
    FILE *f = fopen(g_cmdPath, "w");
    if (f) { fprintf(f, "%s", cmd); fclose(f); }   // 先写文件，再通知（backboardd 读时必已落盘）
    notify_post(g_notifyName);
}

void FTDaemonStartClicking(double nx, double ny, double intervalMs, double sw, double sh) {
    char line[160];
    snprintf(line, sizeof(line), "start %.4f %.4f %d %.1f %.1f\n", nx, ny, (int)intervalMs, sw, sh);
    FTDSendCmd(line);
}

void FTDaemonStopClicking(void) {
    FTDSendCmd("stop\n");
}

void FTDaemonSingleTap(double nx, double ny) {
    char line[128];
    snprintf(line, sizeof(line), "tap %.4f %.4f\n", nx, ny);
    FTDSendCmd(line);
}

// v2.3 起复用真实 digitizer service，不再需要 SID；空操作。
void FTDaemonSetSID(uint64_t sid) {
    (void)sid;
}

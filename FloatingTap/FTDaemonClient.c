//
//  FTDaemonClient.c — FloatingTap 独立注入 daemon 的 socket 客户端（纯 C，零 block）
//
//  SB 侧 tweak 通过本模块与 floatingtapd（独立进程）通信，协议为 Unix domain
//  socket 纯文本命令（一行一条）：
//    "ping\n"              → daemon 回 "pong\n"（探测存活）
//    "start x y ms\n"      → 开始连点（x/y 归一化 0~1，ms 间隔）
//    "stop\n"              → 停止连点
//    "tap x y\n"           → 单次 tap（诊断）
//    "set_sid 0x...\n"     → 设置注入 SID（SB 探测到的有效 SID 推给 daemon）
//
//  ⚠️ 选择 socket 而非 XPC 的原因：XPC 的 event handler 强制要求 block 字面量，
//     而 SB 侧注入 dylib 受「零 ObjC 元数据 / 无 block」铁律约束（arm64e PAC，
//     见构建安全报告 §四）。socket + write 纯 C 无 block，铁律全绿。
//
//  ⚠️ 纯 C：无 ObjC、无 block。失败静默返回，绝不阻塞 SB 主线程超过 300ms。
//

#include "FTDaemonClient.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>

// ⚠️ v2.6：注入 dylib 内绝不写 /var/jb 前缀——rootless 运行时会自动前缀 jbroot，
// 手写 "/var/jb/tmp/X" 会变成 <jbroot>/var/jb/tmp/X（死角）。
// 写 "/tmp/X" 才等价于 shell 侧的 /var/jb/tmp/X，与 BackboardInject 侧保持一致。
static const char *g_sockPath = "/tmp/floatingtapd.sock";
static const int g_timeoutMs = 300;

// ⚠️ v2.1：注入改由 BackboardInject.dylib（注入 backboardd 进程）提供 socket——
// 不再 spawn 独立 floatingtapd（独立进程无 HID entitlement，dispatch 全 ret=0x1，
// v2.0-daemon1/2/3 实测失败）。此函数保留接口但直接返回 0（不 spawn），
// 探测逻辑收到 0 后回退旧 SB 注入路径。
int FTDaemonSpawn(void) {
    return 0;
}

// 连接 daemon socket（每次调用新建，用完即关——保持无状态，避免陈旧连接）
static int FTDConnect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    // 非阻塞 connect + select 超时，防止 daemon 无响应时卡死 SB
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_sockPath, sizeof(addr.sun_path) - 1);
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc != 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = g_timeoutMs * 1000;
    rc = select(fd + 1, NULL, &wfds, NULL, &tv);
    if (rc <= 0) {
        close(fd);
        return -1;
    }
    int soerr = 0;
    socklen_t slen = sizeof(soerr);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen);
    if (soerr != 0) {
        close(fd);
        return -1;
    }
    // 恢复阻塞模式（后续 send 简单可靠）
    fcntl(fd, F_SETFL, fl);
    return fd;
}

// 发一条命令；wantReply=1 时等待 daemon 回一行（用于 ping）
static int FTDSendLine(const char *line, char *replyBuf, int replyCap) {
    int fd = FTDConnect();
    if (fd < 0) return 0;
    int ok = 0;
    if (write(fd, line, strlen(line)) == (ssize_t)strlen(line)) {
        if (replyBuf && replyCap > 0) {
            // select 等回复（剩余超时）
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(fd, &rfds);
            struct timeval tv;
            tv.tv_sec = 0;
            tv.tv_usec = g_timeoutMs * 1000;
            if (select(fd + 1, &rfds, NULL, NULL, &tv) > 0) {
                ssize_t n = read(fd, replyBuf, replyCap - 1);
                if (n > 0) { replyBuf[n] = 0; ok = 1; }
            }
        } else {
            ok = 1; // fire-and-forget
        }
    }
    close(fd);
    return ok;
}

int FTDaemonPing(void) {
    char buf[32];
    if (!FTDSendLine("ping\n", buf, sizeof(buf))) return 0;
    return (strstr(buf, "pong") != NULL) ? 1 : 0;
}

void FTDaemonStartClicking(double nx, double ny, double intervalMs) {
    char line[128];
    snprintf(line, sizeof(line), "start %.4f %.4f %d\n", nx, ny, (int)intervalMs);
    FTDSendLine(line, NULL, 0);
}

void FTDaemonStopClicking(void) {
    FTDSendLine("stop\n", NULL, 0);
}

void FTDaemonSingleTap(double nx, double ny) {
    char line[128];
    snprintf(line, sizeof(line), "tap %.4f %.4f\n", nx, ny);
    FTDSendLine(line, NULL, 0);
}

void FTDaemonSetSID(uint64_t sid) {
    char line[96];
    snprintf(line, sizeof(line), "set_sid 0x%llx\n", (unsigned long long)sid);
    FTDSendLine(line, NULL, 0);
}

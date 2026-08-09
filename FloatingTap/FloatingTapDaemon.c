//
//  FloatingTapDaemon.c — FloatingTap v2 独立注入 daemon（纯 C，Unix socket IPC）
//
//  目的（根治连点断连/顶掉问题，对应构建安全报告 §七.2 首选路线）：
//    · 独立 launchd daemon 进程持有 IOHIDEventSystemClient + DispatchEvent，
//      不在 SB 进程内注入 → 不参与 SB 手势窗口路由 → 崩了只崩 daemon 自己。
//    · daemon 进程内用【真实 digitizer 服务 SID（registryID）】注入，
//      系统把合成事件当真实触摸 → 不顶掉用户手指 → 不需要 SID 探测。
//    · SB 端 tweak 通过 Unix socket（/var/jb/run/floatingtapd.sock）通知 daemon：
//      开始连点(坐标+间隔)/停止连点/单次 tap/设置 SID。daemon 内部用 dispatch
//      timer 高频注入。
//
//  ⚠️ IPC 选型：Unix domain socket（而非 XPC）——XPC event handler 强制 block，
//     而 SB 侧注入 dylib 受「零 ObjC 元数据 / 无 block」铁律约束（arm64e PAC）。
//     daemon 是独立进程，本身无此限制，但保持同一纯 C 风格便于维护。
//
//  协议（一行一条）：
//    "ping\n"            → 回 "pong\n"
//    "start x y ms\n"    → 开始连点（x/y 归一化 0~1）
//    "stop\n"            → 停止连点
//    "tap x y\n"         → 单次 tap（诊断）
//    "set_sid 0x...\n"   → 设置注入 SID（可选）
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <syslog.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

// MARK: - 私有类型与常量

typedef struct __IOHIDEvent * FT_IOHIDEventRef;
typedef struct __IOHIDEventSystemClient * FT_IOHIDEventSystemClientRef;
typedef struct __IOHIDService * FT_IOHIDServiceRef;
typedef int32_t FT_IOReturn;
typedef uint32_t FT_IOOptionBits;
static const FT_IOReturn FT_kIOReturnSuccess = 0;

enum {
    FT_kIOHIDDigitizerEventRange    = 0x00000001,
    FT_kIOHIDDigitizerEventTouch    = 0x00000002,
    FT_kIOHIDDigitizerEventPosition = 0x00000004,
    FT_kIOHIDDigitizerEventTip      = 0x00000008,
    FT_kIOHIDDigitizerEventIdentity = 0x00000010,
};

static const char *g_sockPath = "/var/jb/tmp/floatingtapd.sock";
static const char *g_logPath = "/tmp/floatingtap_daemon.log";

// MARK: - 私有函数指针（dlopen 动态解析）

static FT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef,
                                                            uint64_t, uint32_t, uint32_t, uint32_t,
                                                            uint32_t, uint32_t, double, double, double,
                                                            double, double, Boolean, Boolean,
                                                            FT_IOOptionBits);
static FT_IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, Boolean, Boolean, FT_IOOptionBits);
static FT_IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static FT_IOReturn (*p_IOHIDEventSystemClientDispatchEvent)(FT_IOHIDEventSystemClientRef, FT_IOHIDEventRef);
static void (*p_IOHIDEventSetSenderID)(FT_IOHIDEventRef, uint64_t);
static void (*p_IOHIDEventSetIntegerValue)(FT_IOHIDEventRef, uint32_t, int64_t);
static void (*p_IOHIDEventSetFloatValue)(FT_IOHIDEventRef, uint32_t, double);
static void (*p_IOHIDEventAppendEvent)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits);
static CFArrayRef (*p_IOHIDEventSystemClientCopyServices)(FT_IOHIDEventSystemClientRef);
static CFTypeRef  (*p_IOHIDServiceClientCopyProperty)(FT_IOHIDServiceRef, CFStringRef);
static uint64_t   (*p_IOHIDServiceClientGetRegistryID)(FT_IOHIDServiceRef);

// MARK: - 状态

static FT_IOHIDEventSystemClientRef g_client = NULL;
static bool g_loaded = false;
static uint64_t g_sid = 0;              // 当前注入 SID（set_sid 优先，兜底 registryID）
static uint64_t g_registrySID = 0;      // 第一个确认 digitizer 服务的 registryID（真实 SID）
static dispatch_source_t g_timer = NULL; // 连点定时器
static double g_tx = 0.5, g_ty = 0.5;    // 连点目标坐标（归一化）
static int64_t g_ms = 40;                // 连点间隔（毫秒，默认 40ms=25Hz）
static uint32_t g_tapIndex = 2;          // 合成手指 index（2-9 循环，避开 1）
static bool g_clicking = false;
static int g_listenFd = -1;

// MARK: - 日志

static void FTDLog(const char *msg) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    char line[256];
    snprintf(line, sizeof(line), "[%.1f] %s", t, msg);
    FILE *f = fopen(g_logPath, "a");
    if (f) { fprintf(f, "%s\n", line); fclose(f); }
    syslog(LOG_ERR, "floatingtapd: %s", msg);
}

static void FTDLogFmt(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    FTDLog(buf);
}

// MARK: - 符号加载

static bool FTLoadSymbols(void) {
    if (g_loaded) return true;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) h = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!h) { FTDLog("dlopen IOKit failed"); return false; }
    p_IOHIDEventCreateDigitizerEvent =
        (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                              uint32_t, uint32_t, double, double, double, double, double,
                              Boolean, Boolean, FT_IOOptionBits))
        dlsym(h, "IOHIDEventCreateDigitizerEvent");
    p_IOHIDEventCreateDigitizerFingerEvent =
        (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                              double, double, double, double, double, Boolean, Boolean,
                              FT_IOOptionBits))
        dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    p_IOHIDEventSystemClientCreate = (FT_IOHIDEventSystemClientRef (*)(CFAllocatorRef))dlsym(h, "IOHIDEventSystemClientCreate");
    p_IOHIDEventSystemClientDispatchEvent = (FT_IOReturn (*)(FT_IOHIDEventSystemClientRef, FT_IOHIDEventRef))dlsym(h, "IOHIDEventSystemClientDispatchEvent");
    p_IOHIDEventSetSenderID = (void (*)(FT_IOHIDEventRef, uint64_t))dlsym(h, "IOHIDEventSetSenderID");
    p_IOHIDEventSetIntegerValue = (void (*)(FT_IOHIDEventRef, uint32_t, int64_t))dlsym(h, "IOHIDEventSetIntegerValue");
    p_IOHIDEventSetFloatValue = (void (*)(FT_IOHIDEventRef, uint32_t, double))dlsym(h, "IOHIDEventSetFloatValue");
    p_IOHIDEventAppendEvent = (void (*)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits))dlsym(h, "IOHIDEventAppendEvent");
    p_IOHIDEventSystemClientCopyServices = (CFArrayRef (*)(FT_IOHIDEventSystemClientRef))dlsym(h, "IOHIDEventSystemClientCopyServices");
    p_IOHIDServiceClientCopyProperty = (CFTypeRef (*)(FT_IOHIDServiceRef, CFStringRef))dlsym(h, "IOHIDServiceClientCopyProperty");
    p_IOHIDServiceClientGetRegistryID = (uint64_t (*)(FT_IOHIDServiceRef))dlsym(h, "IOHIDServiceClientGetRegistryID");
    g_loaded = (p_IOHIDEventCreateDigitizerEvent && p_IOHIDEventCreateDigitizerFingerEvent &&
                p_IOHIDEventSystemClientCreate && p_IOHIDEventSystemClientDispatchEvent &&
                p_IOHIDEventSetSenderID && p_IOHIDEventAppendEvent);
    if (!g_loaded) FTDLog("symbol load failed");
    return g_loaded;
}

// MARK: - SID 获取（真实 digitizer 服务 registryID，与 zxtouch 同源）

static void FTEnumerateServices(void) {
    if (!g_client || !p_IOHIDEventSystemClientCopyServices) return;
    CFArrayRef arr = p_IOHIDEventSystemClientCopyServices(g_client);
    if (!arr) { FTDLog("service enum: none"); return; }
    CFIndex n = CFArrayGetCount(arr);
    FTDLogFmt("service enum: %ld services", (long)n);
    for (CFIndex i = 0; i < n && !g_registrySID; i++) {
        FT_IOHIDServiceRef svc = (FT_IOHIDServiceRef)CFArrayGetValueAtIndex(arr, i);
        if (!svc) continue;
        uint64_t usagePage = 0;
        bool gotUsage = false;
        if (p_IOHIDServiceClientCopyProperty) {
            CFStringRef kp = CFStringCreateWithCString(kCFAllocatorDefault, "PrimaryUsagePage", kCFStringEncodingUTF8);
            if (kp) {
                CFTypeRef vp = p_IOHIDServiceClientCopyProperty(svc, kp);
                CFRelease(kp);
                if (vp) {
                    if (CFGetTypeID(vp) == CFNumberGetTypeID()) {
                        CFNumberGetValue((CFNumberRef)vp, kCFNumberSInt64Type, &usagePage);
                        gotUsage = true;
                    }
                    CFRelease(vp);
                }
            }
        }
        if (gotUsage && usagePage != 0x0D) continue;
        if (p_IOHIDServiceClientGetRegistryID) {
            uint64_t rid = p_IOHIDServiceClientGetRegistryID(svc);
            if (rid) {
                g_registrySID = rid;
                FTDLogFmt("registryID (digitizer): 0x%llx", (unsigned long long)rid);
            }
        }
    }
    CFRelease(arr);
}

// MARK: - 事件构造（15 参 parent + 13 参 child，权威结构，报告 §四）

static FT_IOHIDEventRef FTCreateDigitizerEvent(bool down, double x, double y, uint32_t index) {
    if (!g_loaded) return NULL;
    uint64_t ts = mach_absolute_time();
    uint32_t mask = down ? 0x03 : 0x02;
    Boolean range = down ? 1 : 0;
    Boolean touch = down ? 1 : 0;

    FT_IOHIDEventRef child = p_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts, index, 3, mask,
        x, y, 0.0, 0.0, 0.0, range, touch, 0);
    if (!child) return NULL;
    if (p_IOHIDEventSetFloatValue) {
        p_IOHIDEventSetFloatValue(child, 0x0B0014, 0.04);
        p_IOHIDEventSetFloatValue(child, 0x0B0015, 0.04);
        p_IOHIDEventSetFloatValue(child, 0x0B000D, x);
        p_IOHIDEventSetFloatValue(child, 0x0B000E, y);
    }
    if (p_IOHIDEventSetIntegerValue) {
        p_IOHIDEventSetIntegerValue(child, 0x0B0007, (int64_t)mask);
        p_IOHIDEventSetIntegerValue(child, 0x0B0006, range ? 1 : 0);
        p_IOHIDEventSetIntegerValue(child, 0x0B0008, touch ? 1 : 0);
        p_IOHIDEventSetIntegerValue(child, 0x0B0019, 3);
        p_IOHIDEventSetIntegerValue(child, 0x0B0017, 1);
    }

    FT_IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, 3, 99, 1, 0, 0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
    if (!parent) { CFRelease(child); return NULL; }
    if (p_IOHIDEventSetIntegerValue) {
        p_IOHIDEventSetIntegerValue(parent, 0x0B0017, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0019, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x4, 1);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0007, down ? 0x23 : 0x02);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0006, down ? 1 : 0);
        p_IOHIDEventSetIntegerValue(parent, 0x0B0008, down ? 1 : 0);
    }
    p_IOHIDEventAppendEvent(parent, child, 0);
    CFRelease(child);
    return parent;
}

// MARK: - 派发

static void FTDDispatch(FT_IOHIDEventRef ev) {
    if (!ev || !g_client) { if (ev) CFRelease(ev); return; }
    uint64_t sid = g_sid ? g_sid : (g_registrySID ? g_registrySID : 0x8000000817371935ULL);
    p_IOHIDEventSetSenderID(ev, sid);
    if (p_IOHIDEventSetIntegerValue) p_IOHIDEventSetIntegerValue(ev, 0x0B0018, (int64_t)sid);
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_client, ev);
    if (ret != FT_kIOReturnSuccess) {
        static int sFail = 0;
        if ((sFail++ % 20) == 0) FTDLogFmt("dispatch ret=0x%x", (unsigned)ret);
    }
    CFRelease(ev);
}

// MARK: - 连点引擎（daemon 内 dispatch timer，C 函数指针 handler）

typedef struct { double x, y; uint32_t idx; } FTDUpCtx;

static void FTDUpCB(void *ctx) {
    FTDUpCtx *c = (FTDUpCtx *)ctx;
    if (c) {
        FT_IOHIDEventRef u = FTCreateDigitizerEvent(false, c->x, c->y, c->idx);
        FTDDispatch(u);
        free(c);
    }
}

// 注入一次 down + 45ms 延迟 up（up-delay 必须 > 连点间隔，报告 §四铁律）
static void FTDInjectTap(void) {
    if (!g_client) return;
    uint32_t idx = g_tapIndex;
    g_tapIndex = (g_tapIndex % 8) + 2;
    FT_IOHIDEventRef d = FTCreateDigitizerEvent(true, g_tx, g_ty, idx);
    FTDDispatch(d);
    FTDUpCtx *c = (FTDUpCtx *)malloc(sizeof(FTDUpCtx));
    if (c) {
        c->x = g_tx; c->y = g_ty; c->idx = idx;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.045 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTDUpCB);
    }
}

static void FTDTick(void *ctx) {
    (void)ctx;
    FTDInjectTap();
}

// MARK: - 连点控制

static void FTDStartClicking(double x, double y, int64_t ms) {
    if (!g_client) { FTDLog("start: not connected"); return; }
    g_tx = x; g_ty = y;
    if (ms < 5) ms = 5;
    if (ms > 60000) ms = 60000;
    g_ms = ms;
    g_clicking = true;
    if (g_timer) dispatch_source_cancel(g_timer);
    g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (g_timer) {
        dispatch_source_set_timer(g_timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(g_ms * NSEC_PER_MSEC)),
                                  (uint64_t)(g_ms * NSEC_PER_MSEC), 0);
        dispatch_source_set_event_handler_f(g_timer, FTDTick);
        dispatch_resume(g_timer);
        FTDLogFmt("start clicking @(%.2f,%.2f) ms=%lld", x, y, (long long)ms);
    }
}

static void FTDStopClicking(void) {
    g_clicking = false;
    if (g_timer) {
        dispatch_source_cancel(g_timer);
        g_timer = NULL;
    }
    FTDLog("stop clicking");
}

// MARK: - Unix socket 服务（纯 C，无 block）

// 发送回复：客户端可能已断开（fire-and-forget），忽略 SIGPIPE + 检查写结果
static void FTDSendLine(int fd, const char *line) {
    if (fd < 0 || !line) return;
    size_t n = strlen(line);
    ssize_t w = write(fd, line, n);
    (void)w;
}

// 处理一行命令；回写 reply（最多一行）
static void FTDHandleLine(int fd, const char *line) {
    char reply[256];
    reply[0] = 0;
    if (strncmp(line, "ping", 4) == 0) {
        snprintf(reply, sizeof(reply), "pong\n");
    } else if (strncmp(line, "start", 5) == 0) {
        double x = 0.5, y = 0.5;
        long long msll = 40;
        sscanf(line + 5, "%lf %lf %lld", &x, &y, &msll);
        int64_t ms = (int64_t)msll;
        if (x < 0.001) x = 0.001; if (x > 0.999) x = 0.999;
        if (y < 0.001) y = 0.001; if (y > 0.999) y = 0.999;
        FTDStartClicking(x, y, ms);
        snprintf(reply, sizeof(reply), "ok\n");
    } else if (strncmp(line, "stop", 4) == 0) {
        FTDStopClicking();
        snprintf(reply, sizeof(reply), "ok\n");
    } else if (strncmp(line, "tap", 3) == 0) {
        double x = 0.5, y = 0.5;
        sscanf(line + 3, "%lf %lf", &x, &y);
        if (x < 0.001) x = 0.001; if (x > 0.999) x = 0.999;
        if (y < 0.001) y = 0.001; if (y > 0.999) y = 0.999;
        g_tx = x; g_ty = y;
        FTDInjectTap();
        FTDLogFmt("single tap @(%.2f,%.2f)", x, y);
        snprintf(reply, sizeof(reply), "ok\n");
    } else if (strncmp(line, "set_sid", 7) == 0) {
        uint64_t sid = 0;
        unsigned long long sll = 0;
        sscanf(line + 7, "0x%llx", &sll);
        sid = (uint64_t)sll;
        if (sid) { g_sid = sid; FTDLogFmt("set_sid = 0x%llx", (unsigned long long)sid); }
        snprintf(reply, sizeof(reply), "ok\n");
    } else {
        snprintf(reply, sizeof(reply), "unknown\n");
    }
    if (reply[0]) FTDSendLine(fd, reply);
}

// accept 循环：每客户端读一行处理一行（短连接，客户端即连即断）。
// ⚠️ 必须非阻塞 + select 超时：若客户端连接后不发数据，阻塞 read 会卡死
// 主队列 → 连点 timer 停止注入（daemon 主循环被拖垮）。
static void FTDHandleClient(void *ctx) {
    int fd = (int)(intptr_t)ctx;
    if (fd < 0) return;
    // 非阻塞 + select 800ms 读超时
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 800 * 1000;
    int rc = select(fd + 1, &rfds, NULL, NULL, &tv);
    char buf[512];
    ssize_t n = 0;
    if (rc > 0) {
        n = read(fd, buf, sizeof(buf) - 1);
    }
    if (n > 0) {
        buf[n] = 0;
        // 按行切分处理（客户端一次只发一行，但兼容多行）
        char *save = NULL;
        char *tok = strtok_r(buf, "\n", &save);
        while (tok) {
            FTDHandleLine(fd, tok);
            tok = strtok_r(NULL, "\n", &save);
        }
    }
    close(fd);
}

static void FTDAcceptCB(void *ctx) {
    (void)ctx;
    if (g_listenFd < 0) return;
    int cfd = accept(g_listenFd, NULL, NULL);
    if (cfd >= 0) {
        // 主队列串行处理（客户端超时短，不会阻塞）。fd 经 intptr_t 无损传递
        dispatch_async_f(dispatch_get_main_queue(), (void *)(intptr_t)cfd, FTDHandleClient);
    }
}

static int FTDSetupSocket(void) {
    // 确保 socket 目录存在（rootless 下 /var/jb/tmp 一般存在，防御性创建）
    mkdir("/var/jb/tmp", 0777);
    unlink(g_sockPath);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { FTDLog("socket create failed"); return -1; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_sockPath, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        FTDLogFmt("socket bind failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    chmod(g_sockPath, 0777); // SB（root）可连；越狱环境无沙盒
    if (listen(fd, 8) != 0) {
        FTDLogFmt("socket listen failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    g_listenFd = fd;
    // 监听 accept：dispatch source read handler（C 函数指针）
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
                                                   dispatch_get_main_queue());
    if (src) {
        dispatch_source_set_event_handler_f(src, FTDAcceptCB);
        dispatch_resume(src);
        FTDLog("socket listening");
    }
    return 0;
}

// MARK: - 入口

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    // 客户端 fire-and-forget 后可能立即断开：写 reply 触发 SIGPIPE 会杀死 daemon，
    // 必须忽略（write 返回 EPIPE 即可）。
    signal(SIGPIPE, SIG_IGN);
    FTDLogFmt("floatingtapd start pid=%d", getpid());
    if (!FTLoadSymbols()) return 0;
    g_client = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_client) { FTDLog("client create failed"); return 0; }
    FTEnumerateServices();
    FTDLogFmt("client ready, registrySID=0x%llx", (unsigned long long)g_registrySID);
    if (FTDSetupSocket() != 0) { FTDLog("socket setup failed"); return 0; }
    FTDLog("daemon ready");
    dispatch_main(); // never returns
    return 0;
}

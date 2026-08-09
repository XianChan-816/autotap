//
//  BackboardInject.c — FloatingTap v2.2 backboardd 内注入（佳影式，纯 C）
//
//  背景（关键教训链）：
//    · v2.1 BackboardInject 黑屏（8ddfa9e）——根因：constructor 里调用了
//      dispatch_after_f（GCD API）。违反报告 §三铁律「ctor 只许 fopen 写日志，
//      严禁 dispatch」。SafeProbe（ctor 只 fopen）验证加载安全。
//    · 佳影 BackboardService IMPORT 表（100 符号）实锤：用 _MSHookFunction /
//      _MSGetImageByName / _MSFindSymbol + _bootstrap_look_up / _mach_msg，
//      **没有 IOHIDEventSystemClientCreate/DispatchEvent**——它 hook backboardd
//      内部事件处理函数，从内部管线注入（同源），不用客户端 DispatchEvent。
//
//  本文件（v2.2）实现：
//    · constructor 只写日志（已验证安全）。
//    · pthread_create 启动后台线程（纯 POSIX，ctor 阶段安全），sleep 3s 后
//      初始化：dlopen IOKit → create client → socket 监听（/var/jb/tmp/
//      floatingtapd.sock，SB 侧 FTDaemonClient 协议不变）。
//    · socket 收到 "tap x y" / "start x y ms" → 用【佳影同源事件构造】
//      （IOHIDEventCreateDigitizerEvent 15 参 + FingerEvent 13 参，字段与
//      佳影 0xd46c 反汇编一致：0x0B000D X / 0x0B000E Y / 0x0B0007 mask /
//      0x0B0014 radius）→ DispatchEvent 派发（backboardd 进程有 HID
//      entitlement，dispatch 应有效；若 ret=0x1 连续 50 次自动关 socket，
//      SB 回退旧注入）。
//
//  ⚠️ 铁律：backboardd 危险等级 1。纯 C、零 ObjC、ctor 只日志、全操作保守。
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
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <pthread.h>
#include <dlfcn.h>
#include <syslog.h>
#include <time.h>
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

static const char *g_sockPath = "/var/jb/tmp/floatingtapd.sock";
static const char *g_logPath = "/tmp/backboard_inject.log";

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
static bool g_ready = false;
static uint64_t g_sid = 0;              // 注入 SID（set_sid 优先）
static uint64_t g_registrySID = 0;      // digitizer 服务 registryID
static int g_listenFd = -1;
static double g_tx = 0.5, g_ty = 0.5;   // 连点坐标（归一化）
static int64_t g_ms = 40;
static uint32_t g_tapIndex = 2;
static bool g_clicking = false;
static dispatch_source_t g_timer = NULL;

// MARK: - 日志

static void FTDLog(const char *msg) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    char line[256];
    snprintf(line, sizeof(line), "[%.1f] %s", t, msg);
    FILE *f = fopen(g_logPath, "a");
    if (f) { fprintf(f, "%s\n", line); fclose(f); }
    syslog(LOG_ERR, "BackboardInject: %s", msg);
}

static void FTDLogFmt(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    FTDLog(buf);
}

// MARK: - 符号加载（后台线程内执行，安全）

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

// MARK: - 事件构造（佳影同款字段，0xd46c 反汇编确认）

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
        p_IOHIDEventSetFloatValue(child, 0x0B0014, 0.04); // radius（佳影同款）
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

// MARK: - 派发（backboardd 进程内有 HID entitlement）

static void FTDDispatch(FT_IOHIDEventRef ev) {
    if (!ev || !g_client) { if (ev) CFRelease(ev); return; }
    uint64_t sid = g_sid ? g_sid : (g_registrySID ? g_registrySID : 0x8000000817371935ULL);
    p_IOHIDEventSetSenderID(ev, sid);
    if (p_IOHIDEventSetIntegerValue) p_IOHIDEventSetIntegerValue(ev, 0x0B0018, (int64_t)sid);
    FT_IOReturn ret = p_IOHIDEventSystemClientDispatchEvent(g_client, ev);
    if (ret != FT_kIOReturnSuccess) {
        static int sFail = 0;
        if ((sFail++ % 20) == 0) FTDLogFmt("dispatch ret=0x%x", (unsigned)ret);
        // 连续 50 次失败 → 关 socket，SB 回退旧注入（防"daemon 模式零点击"死锁）
        if (sFail >= 50 && g_listenFd >= 0) {
            FTDLog("dispatch failed 50x - closing socket, SB will fallback");
            close(g_listenFd);
            g_listenFd = -1;
            unlink(g_sockPath);
        }
    }
    CFRelease(ev);
}

// MARK: - 连点引擎（dispatch timer）

typedef struct { double x, y; uint32_t idx; } FTDUpCtx;

static void FTDUpCB(void *ctx) {
    FTDUpCtx *c = (FTDUpCtx *)ctx;
    if (c) {
        FT_IOHIDEventRef u = FTCreateDigitizerEvent(false, c->x, c->y, c->idx);
        FTDDispatch(u);
        free(c);
    }
}

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
    if (g_timer) { dispatch_source_cancel(g_timer); g_timer = NULL; }
    FTDLog("stop clicking");
}

// MARK: - socket 服务（纯 C）

static void FTDSendLine(int fd, const char *line) {
    if (fd < 0 || !line) return;
    ssize_t w = write(fd, line, strlen(line));
    (void)w;
}

static void FTDHandleLine(int fd, const char *line) {
    char reply[256];
    reply[0] = 0;
    if (strncmp(line, "ping", 4) == 0) {
        snprintf(reply, sizeof(reply), "pong\n");
    } else if (strncmp(line, "start", 5) == 0) {
        double x = 0.5, y = 0.5;
        long long msll = 40;
        sscanf(line + 5, "%lf %lf %lld", &x, &y, &msll);
        if (x < 0.001) x = 0.001; if (x > 0.999) x = 0.999;
        if (y < 0.001) y = 0.001; if (y > 0.999) y = 0.999;
        FTDStartClicking(x, y, (int64_t)msll);
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
        unsigned long long sll = 0;
        sscanf(line + 7, "0x%llx", &sll);
        if (sll) { g_sid = (uint64_t)sll; FTDLogFmt("set_sid = 0x%llx", sll); }
        snprintf(reply, sizeof(reply), "ok\n");
    } else {
        snprintf(reply, sizeof(reply), "unknown\n");
    }
    if (reply[0]) FTDSendLine(fd, reply);
}

static void FTDHandleClient(void *ctx) {
    int fd = (int)(intptr_t)ctx;
    if (fd < 0) return;
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
    if (rc > 0) n = read(fd, buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = 0;
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
        dispatch_async_f(dispatch_get_main_queue(), (void *)(intptr_t)cfd, FTDHandleClient);
    }
}

static int FTDSetupSocket(void) {
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
    chmod(g_sockPath, 0777);
    if (listen(fd, 8) != 0) {
        FTDLogFmt("socket listen failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    g_listenFd = fd;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
                                                   dispatch_get_main_queue());
    if (src) {
        dispatch_source_set_event_handler_f(src, FTDAcceptCB);
        dispatch_resume(src);
        FTDLog("socket listening");
    }
    return 0;
}

// MARK: - 后台初始化线程（ctor 里 pthread_create，纯 POSIX 安全）

static void *FTBInitThread(void *ctx) {
    (void)ctx;
    signal(SIGPIPE, SIG_IGN);
    sleep(3); // 等 backboardd 完全就绪
    FTDLog("init thread start");
    if (!FTLoadSymbols()) return NULL;
    g_client = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_client) { FTDLog("client create failed"); return NULL; }
    // 枚举 digitizer 服务拿 registryID（兜底 SID）
    if (p_IOHIDEventSystemClientCopyServices) {
        CFArrayRef arr = p_IOHIDEventSystemClientCopyServices(g_client);
        if (arr) {
            CFIndex n = CFArrayGetCount(arr);
            for (CFIndex i = 0; i < n && !g_registrySID; i++) {
                FT_IOHIDServiceRef svc = (FT_IOHIDServiceRef)CFArrayGetValueAtIndex(arr, i);
                if (!svc) continue;
                if (p_IOHIDServiceClientGetRegistryID) {
                    uint64_t rid = p_IOHIDServiceClientGetRegistryID(svc);
                    if (rid) { g_registrySID = rid; break; }
                }
            }
            CFRelease(arr);
            FTDLogFmt("registrySID=0x%llx", (unsigned long long)g_registrySID);
        }
    }
    if (FTDSetupSocket() != 0) { FTDLog("socket setup failed"); return NULL; }
    g_ready = true;
    FTDLog("BackboardInject v2.2 ready");
    return NULL;
}

// MARK: - 入口（constructor 只写日志 + pthread_create）

__attribute__((constructor))
static void FTBCtor(void) {
    // 铁律（报告 §三）：ctor 阶段只许 fopen 写日志。严禁 dispatch/dlopen/API。
    // v2.1 黑屏根因就是 ctor 里 dispatch_after_f（GCD API）！
    FILE *mk = fopen("/tmp/backboard_inject.log", "a");
    if (mk) {
        fprintf(mk, "[BackboardInject] ctor pid=%d proc=%s\n",
                (int)getpid(), getprogname() ? getprogname() : "?");
        fclose(mk);
    }
    // pthread_create 是纯 POSIX（不碰 GCD/IOKit），ctor 阶段安全。
    // 后台线程 sleep 3s 后初始化——等价于"进程就绪后延迟初始化"。
    pthread_t th;
    if (pthread_create(&th, NULL, FTBInitThread, NULL) == 0) {
        pthread_detach(th);
    }
}

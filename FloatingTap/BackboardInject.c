//
//  BackboardInject.c — FloatingTap v2.3 backboardd 内注入（佳影同源架构，纯 C）
//
//  ============================ 教训链（必读） ============================
//  · v2.1 黑屏：constructor 里调用 dispatch_after_f（GCD）→ 违反铁律。
//  · SafeProbe（ctor 只 fopen）→ 加载安全，实测不黑屏。
//  · v2.2 黑屏（本次）：真凶 = 在 backboardd 进程内调用
//      IOHIDEventSystemClientCreate() / IOHIDEventSystemClientCopyServices()。
//    backboardd 本身就是 HID event system 的【服务端】，在服务端进程里创建
//    客户端 = 自己连自己 → 死锁 / ___assert_rtn → 看门狗杀 backboardd →
//    「亮屏后自动黑屏 + 重复注销」。
//    实锤旁证：佳影 BackboardService.dylib 的导入表里【根本没有】
//    IOHIDEventSystemClientCreate / IOHIDEventSystemClientDispatchEvent。
//
//  ======================== 佳影真实架构（已逆向确认）========================
//  符号表实证（BackboardService.dylib）：
//      _MSGetImageByName / _MSFindSymbol / _MSHookFunction
//      ___IOHIDServiceEventCallback          ← MSFindSymbol 的目标（IOKit 私有）
//      _IOHIDServiceEventCallbackOld         ← MSHookFunction 保存的原函数
//      __Z28IOHIDServiceEventCallbackNewPvS_P14__IOHIDServiceP12__IOHIDEvent
//      _touchEventService                    ← 捕获到的真实 digitizer service
//      __Z21performDigitizerEventP12__IOHIDEvent  ← 注入入口
//  即：
//      1) hook IOKit 的 __IOHIDServiceEventCallback（backboardd 收触摸的入口）
//      2) 真实手指触摸时，把 (target, refcon, service) 三件套截获存起来
//      3) 注入 = 自己造 event，然后【直接调用原始回调】把它喂回 backboardd
//         的正常事件管线 —— 零客户端、零 DispatchEvent、零 mach 往返
//  副产品：SID 探测问题彻底消失（复用真实 digitizer 的 service，身份天然合法）。
//
//  ============================ 本版安全设计 ============================
//  1) constructor 只做：fopen 写日志 + 读控制文件 + pthread_create。零 API。
//  2) 【开机自愈保险】崩溃后自动禁用，无需安全模式：
//       ctor 读 guard 文件；若「本 stage 已尝试过且未确认存活」→ 直接禁用返回。
//       存活 25 秒后才把 guard 标记为「已确认安全」。
//       ⇒ 最多黑屏一次，下次开机自动跳过，设备正常进系统。
//  3) 【分级开关】改 /var/jb/tmp/ftb_stage 即可推进/回退，无需重新编译安装：
//       0 = 只写日志（等于关闭）
//       1 = dlopen IOKit + 解析事件构造符号（不碰任何 HID 对象）
//       2 = 1 + 定位 ___IOHIDServiceEventCallback 地址（只打印，不 hook）
//       3 = 2 + 装 hook，真实触摸时捕获 service/target/refcon 并记日志（不注入）
//       4 = 3 + 开 socket 服务 + 真正连点注入（完整功能）← 默认
//     改完 stage 会自动获得一次新的尝试机会（guard 按 stage 记账）。
//     默认直接 4：每一步都有日志打点，崩了看日志就知道死在哪，不必逐级试。
//  4) 全程零 GCD：socket 用独立 pthread 阻塞 accept，连点用独立 pthread 定时。
//     绝不占用 backboardd 主线程/主队列。
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
#include <CoreFoundation/CoreFoundation.h>

// MARK: - 类型

typedef struct __IOHIDEvent   *FT_IOHIDEventRef;
typedef struct __IOHIDService *FT_IOHIDServiceRef;
typedef uint32_t FT_IOOptionBits;

// IOKit 私有回调签名（佳影 IOHIDServiceEventCallbackNew 同款）
typedef void (*FT_ServiceEventCallback)(void *target, void *refcon,
                                        FT_IOHIDServiceRef service,
                                        FT_IOHIDEventRef event);

// substrate / ellekit
typedef void *(*FT_MSGetImageByName)(const char *file);
typedef void *(*FT_MSFindSymbol)(void *image, const char *name);
typedef void  (*FT_MSHookFunction)(void *symbol, void *replace, void **result);

// MARK: - 路径

static const char *g_sockPath  = "/var/jb/tmp/floatingtapd.sock";
static const char *g_logPath   = "/tmp/backboard_inject.log";
// 控制文件写两份（/var/jb/tmp 可能随 jbroot 挂载，/tmp 实测 backboardd 可写）
static const char *g_stageA    = "/var/jb/tmp/ftb_stage";
static const char *g_stageB    = "/tmp/ftb_stage";
static const char *g_guardA    = "/var/jb/tmp/ftb_guard";
static const char *g_guardB    = "/tmp/ftb_guard";

// MARK: - 事件构造符号（仅"创建/设值"类，纯内存操作，无跨进程通信 → 安全）

static FT_IOHIDEventRef (*p_CreateDigitizerEvent)(CFAllocatorRef, uint64_t,
                                                  uint32_t, uint32_t, uint32_t,
                                                  uint32_t, uint32_t,
                                                  double, double, double,
                                                  double, double,
                                                  Boolean, Boolean, FT_IOOptionBits);
static FT_IOHIDEventRef (*p_CreateFingerEvent)(CFAllocatorRef, uint64_t,
                                               uint32_t, uint32_t, uint32_t,
                                               double, double, double, double, double,
                                               Boolean, Boolean, FT_IOOptionBits);
static void (*p_SetIntegerValue)(FT_IOHIDEventRef, uint32_t, int64_t);
static void (*p_SetFloatValue)(FT_IOHIDEventRef, uint32_t, double);
static void (*p_AppendEvent)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits);
static uint32_t (*p_GetType)(FT_IOHIDEventRef);

// MARK: - 状态

static int   g_stage = 1;
static bool  g_symOK = false;
static void *g_cbAddr = NULL;                        // ___IOHIDServiceEventCallback
static FT_ServiceEventCallback g_origCB = NULL;      // MSHookFunction 保存的原函数
static bool  g_hooked = false;

// 真实触摸时捕获的三件套（佳影 _touchEventService 同款）
static void *g_target = NULL;
static void *g_refcon = NULL;
static FT_IOHIDServiceRef g_service = NULL;
static volatile bool g_captured = false;
static int   g_capLogCount = 0;

static pthread_mutex_t g_injectLock = PTHREAD_MUTEX_INITIALIZER;

static int    g_listenFd = -1;
static double g_tx = 0.5, g_ty = 0.5;
static int64_t g_ms = 12;
static volatile bool g_clickRun = false;
static pthread_t g_clickTh;

// MARK: - 日志

static void FTDLog(const char *msg) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    FILE *f = fopen(g_logPath, "a");
    if (f) { fprintf(f, "[%.1f][s%d] %s\n", t, g_stage, msg); fclose(f); }
    syslog(LOG_ERR, "BackboardInject: %s", msg);
}

static void FTDLogFmt(const char *fmt, ...) {
    char buf[320];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    FTDLog(buf);
}

// MARK: - 控制文件（stage / guard）

static int FTReadIntFile(const char *path, int def) {
    FILE *f = fopen(path, "r");
    if (!f) return def;
    int v = def;
    if (fscanf(f, "%d", &v) != 1) v = def;
    fclose(f);
    return v;
}

// guard 文件格式： "<stage> <attempts>"
static void FTReadGuard(int *gstage, int *gattempts) {
    int bs = -1, ba = 0, cs = -1, ca = 0;
    FILE *f = fopen(g_guardA, "r");
    if (f) { if (fscanf(f, "%d %d", &bs, &ba) != 2) { bs = -1; ba = 0; } fclose(f); }
    f = fopen(g_guardB, "r");
    if (f) { if (fscanf(f, "%d %d", &cs, &ca) != 2) { cs = -1; ca = 0; } fclose(f); }
    // 取"更悲观"的一份：只要任一份记录了本 stage 的未确认尝试，就算尝试过
    if (bs >= 0 && cs >= 0) {
        *gstage = (ba >= ca) ? bs : cs;
        *gattempts = (ba >= ca) ? ba : ca;
    } else if (bs >= 0) { *gstage = bs; *gattempts = ba; }
    else if (cs >= 0)   { *gstage = cs; *gattempts = ca; }
    else                { *gstage = -1; *gattempts = 0; }
}

static void FTWriteGuard(int stage, int attempts) {
    FILE *f = fopen(g_guardA, "w");
    if (f) { fprintf(f, "%d %d\n", stage, attempts); fclose(f); }
    f = fopen(g_guardB, "w");
    if (f) { fprintf(f, "%d %d\n", stage, attempts); fclose(f); }
}

// MARK: - 符号解析（stage >= 1，后台线程内执行）

static bool FTLoadSymbols(void) {
    if (g_symOK) return true;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY);
    if (!h) h = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    if (!h) { FTDLog("dlopen IOKit FAILED"); return false; }

    p_CreateDigitizerEvent = (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                                   uint32_t, uint32_t, uint32_t, double, double,
                                                   double, double, double, Boolean, Boolean,
                                                   FT_IOOptionBits))
                             dlsym(h, "IOHIDEventCreateDigitizerEvent");
    p_CreateFingerEvent = (FT_IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                                uint32_t, double, double, double, double, double,
                                                Boolean, Boolean, FT_IOOptionBits))
                          dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    p_SetIntegerValue = (void (*)(FT_IOHIDEventRef, uint32_t, int64_t))dlsym(h, "IOHIDEventSetIntegerValue");
    p_SetFloatValue   = (void (*)(FT_IOHIDEventRef, uint32_t, double))dlsym(h, "IOHIDEventSetFloatValue");
    p_AppendEvent     = (void (*)(FT_IOHIDEventRef, FT_IOHIDEventRef, FT_IOOptionBits))dlsym(h, "IOHIDEventAppendEvent");
    p_GetType         = (uint32_t (*)(FT_IOHIDEventRef))dlsym(h, "IOHIDEventGetType");

    g_symOK = (p_CreateDigitizerEvent && p_CreateFingerEvent && p_AppendEvent && p_GetType);
    FTDLogFmt("symbols: digi=%p finger=%p append=%p setInt=%p setFlt=%p getType=%p => %s",
              (void *)p_CreateDigitizerEvent, (void *)p_CreateFingerEvent, (void *)p_AppendEvent,
              (void *)p_SetIntegerValue, (void *)p_SetFloatValue, (void *)p_GetType,
              g_symOK ? "OK" : "FAILED");
    return g_symOK;
}

// MARK: - 定位 ___IOHIDServiceEventCallback（stage >= 2）

static bool FTLocateCallback(void) {
    if (g_cbAddr) return true;

    FT_MSGetImageByName fGetImage = (FT_MSGetImageByName)dlsym(RTLD_DEFAULT, "MSGetImageByName");
    FT_MSFindSymbol     fFindSym  = (FT_MSFindSymbol)dlsym(RTLD_DEFAULT, "MSFindSymbol");
    if (!fGetImage || !fFindSym) {
        const char *libs[] = { "/var/jb/usr/lib/libellekit.dylib",
                               "/var/jb/usr/lib/libsubstrate.dylib",
                               "/usr/lib/libsubstrate.dylib", NULL };
        for (int i = 0; libs[i] && (!fGetImage || !fFindSym); i++) {
            void *lh = dlopen(libs[i], RTLD_LAZY);
            if (!lh) continue;
            if (!fGetImage) fGetImage = (FT_MSGetImageByName)dlsym(lh, "MSGetImageByName");
            if (!fFindSym)  fFindSym  = (FT_MSFindSymbol)dlsym(lh, "MSFindSymbol");
        }
    }
    if (!fGetImage || !fFindSym) { FTDLog("MSGetImageByName/MSFindSymbol NOT FOUND"); return false; }

    const char *images[] = { "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
                             "/System/Library/Frameworks/IOKit.framework/IOKit",
                             "/usr/lib/libIOKit.dylib", NULL };
    const char *names[]  = { "___IOHIDServiceEventCallback",
                             "__IOHIDServiceEventCallback",
                             "_IOHIDServiceEventCallback", NULL };
    for (int i = 0; images[i] && !g_cbAddr; i++) {
        void *img = fGetImage(images[i]);
        if (!img) continue;
        for (int j = 0; names[j] && !g_cbAddr; j++) {
            void *sym = fFindSym(img, names[j]);
            if (sym) {
                g_cbAddr = sym;
                FTDLogFmt("found %s @ %p (image=%s)", names[j], sym, images[i]);
            }
        }
    }
    if (!g_cbAddr) FTDLog("___IOHIDServiceEventCallback NOT FOUND");
    return g_cbAddr != NULL;
}

// MARK: - Hook 回调（stage >= 3）——捕获真实 digitizer 三件套

static void FTServiceEventCallbackNew(void *target, void *refcon,
                                      FT_IOHIDServiceRef service,
                                      FT_IOHIDEventRef event) {
    // kIOHIDEventTypeDigitizer == 11
    if (event && p_GetType && p_GetType(event) == 11) {
        if (!g_captured) {
            g_target = target;
            g_refcon = refcon;
            g_service = service;
            g_captured = true;
            FTDLogFmt("CAPTURED target=%p refcon=%p service=%p", target, refcon, (void *)service);
        } else if (g_capLogCount < 3) {
            g_capLogCount++;
            FTDLogFmt("real touch #%d (service=%p)", g_capLogCount, (void *)service);
        }
    }
    if (g_origCB) g_origCB(target, refcon, service, event);
}

static bool FTInstallHook(void) {
    if (g_hooked) return true;
    if (!g_cbAddr) return false;
    FT_MSHookFunction fHook = (FT_MSHookFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!fHook) {
        const char *libs[] = { "/var/jb/usr/lib/libellekit.dylib",
                               "/var/jb/usr/lib/libsubstrate.dylib",
                               "/usr/lib/libsubstrate.dylib", NULL };
        for (int i = 0; libs[i] && !fHook; i++) {
            void *lh = dlopen(libs[i], RTLD_LAZY);
            if (lh) fHook = (FT_MSHookFunction)dlsym(lh, "MSHookFunction");
        }
    }
    if (!fHook) { FTDLog("MSHookFunction NOT FOUND"); return false; }
    fHook(g_cbAddr, (void *)FTServiceEventCallbackNew, (void **)&g_origCB);
    g_hooked = (g_origCB != NULL);
    FTDLogFmt("hook installed=%d orig=%p", g_hooked ? 1 : 0, (void *)g_origCB);
    return g_hooked;
}

// MARK: - 事件构造（佳影 0xd46c 同款字段）

static FT_IOHIDEventRef FTCreateEvent(bool down, double x, double y, uint32_t index) {
    if (!g_symOK) return NULL;
    uint64_t ts = mach_absolute_time();
    uint32_t mask = down ? 0x03 : 0x02;
    Boolean range = down ? 1 : 0;
    Boolean touch = down ? 1 : 0;

    FT_IOHIDEventRef child = p_CreateFingerEvent(kCFAllocatorDefault, ts, index, 3, mask,
                                                 x, y, 0.0, 0.0, 0.0, range, touch, 0);
    if (!child) return NULL;
    if (p_SetFloatValue) {
        p_SetFloatValue(child, 0x0B0014, 0.04);   // radius
        p_SetFloatValue(child, 0x0B0015, 0.04);
        p_SetFloatValue(child, 0x0B000D, x);      // X
        p_SetFloatValue(child, 0x0B000E, y);      // Y
    }
    if (p_SetIntegerValue) {
        p_SetIntegerValue(child, 0x0B0007, (int64_t)mask);
        p_SetIntegerValue(child, 0x0B0006, range ? 1 : 0);
        p_SetIntegerValue(child, 0x0B0008, touch ? 1 : 0);
        p_SetIntegerValue(child, 0x0B0019, 3);
        p_SetIntegerValue(child, 0x0B0017, 1);
    }

    FT_IOHIDEventRef parent = p_CreateDigitizerEvent(kCFAllocatorDefault, ts, 3, 99, 1, 0, 0,
                                                     0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
    if (!parent) { CFRelease(child); return NULL; }
    if (p_SetIntegerValue) {
        p_SetIntegerValue(parent, 0x0B0017, 1);
        p_SetIntegerValue(parent, 0x0B0019, 1);
        p_SetIntegerValue(parent, 0x4, 1);
        p_SetIntegerValue(parent, 0x0B0007, down ? 0x23 : 0x02);
        p_SetIntegerValue(parent, 0x0B0006, down ? 1 : 0);
        p_SetIntegerValue(parent, 0x0B0008, down ? 1 : 0);
    }
    p_AppendEvent(parent, child, 0);
    CFRelease(child);
    return parent;
}

// MARK: - 注入（佳影 performDigitizerEvent 同款：直接喂回原始回调）

static void FTInject(bool down, double x, double y, uint32_t index) {
    if (!g_captured || !g_origCB) return;
    FT_IOHIDEventRef ev = FTCreateEvent(down, x, y, index);
    if (!ev) return;
    pthread_mutex_lock(&g_injectLock);
    g_origCB(g_target, g_refcon, g_service, ev);   // ← 零客户端、零 DispatchEvent
    pthread_mutex_unlock(&g_injectLock);
    CFRelease(ev);
}

// MARK: - 连点线程（独立 pthread，绝不碰 backboardd 主线程）

static void *FTClickThread(void *arg) {
    (void)arg;
    uint32_t idx = 2;
    FTDLogFmt("click thread start @(%.3f,%.3f) ms=%lld", g_tx, g_ty, (long long)g_ms);
    while (g_clickRun) {
        double x = g_tx, y = g_ty;
        int64_t ms = g_ms;
        int64_t downMs = ms / 2;
        if (downMs > 12) downMs = 12;
        if (downMs < 2)  downMs = 2;
        FTInject(true, x, y, idx);
        usleep((useconds_t)(downMs * 1000));
        FTInject(false, x, y, idx);
        idx = (idx % 8) + 2;
        int64_t rest = ms - downMs;
        if (rest < 1) rest = 1;
        usleep((useconds_t)(rest * 1000));
    }
    FTInject(false, g_tx, g_ty, idx);   // 收尾抬起，防卡住
    FTDLog("click thread exit");
    return NULL;
}

static void FTStart(double x, double y, int64_t ms) {
    if (!g_captured) { FTDLog("start: no captured service yet (先在屏幕上真实触摸一次)"); return; }
    if (ms < 5) ms = 5;
    if (ms > 60000) ms = 60000;
    g_tx = x; g_ty = y; g_ms = ms;
    if (g_clickRun) return;             // 已在连点，只更新坐标
    g_clickRun = true;
    if (pthread_create(&g_clickTh, NULL, FTClickThread, NULL) == 0) pthread_detach(g_clickTh);
    else g_clickRun = false;
}

static void FTStop(void) {
    g_clickRun = false;
}

// MARK: - socket 服务（stage 4，独立 pthread 阻塞 accept，零 GCD）

static void FTHandleLine(int fd, const char *line) {
    char reply[128]; reply[0] = 0;
    if (strncmp(line, "ping", 4) == 0) {
        snprintf(reply, sizeof(reply), g_captured ? "pong\n" : "pong-nocap\n");
    } else if (strncmp(line, "start", 5) == 0) {
        double x = 0.5, y = 0.5; long long ms = 12;
        sscanf(line + 5, "%lf %lf %lld", &x, &y, &ms);
        if (x < 0.001) x = 0.001; if (x > 0.999) x = 0.999;
        if (y < 0.001) y = 0.001; if (y > 0.999) y = 0.999;
        FTStart(x, y, (int64_t)ms);
        snprintf(reply, sizeof(reply), "ok\n");
    } else if (strncmp(line, "stop", 4) == 0) {
        FTStop();
        snprintf(reply, sizeof(reply), "ok\n");
    } else if (strncmp(line, "tap", 3) == 0) {
        double x = 0.5, y = 0.5;
        sscanf(line + 3, "%lf %lf", &x, &y);
        if (x < 0.001) x = 0.001; if (x > 0.999) x = 0.999;
        if (y < 0.001) y = 0.001; if (y > 0.999) y = 0.999;
        FTInject(true, x, y, 2);
        usleep(10 * 1000);
        FTInject(false, x, y, 2);
        snprintf(reply, sizeof(reply), "ok\n");
    } else if (strncmp(line, "set_sid", 7) == 0) {
        snprintf(reply, sizeof(reply), "ok\n");   // v2.3 复用真实 service，无需 SID
    } else {
        snprintf(reply, sizeof(reply), "unknown\n");
    }
    if (reply[0]) { ssize_t w = write(fd, reply, strlen(reply)); (void)w; }
}

static void *FTSocketThread(void *arg) {
    (void)arg;
    while (g_listenFd >= 0) {
        int cfd = accept(g_listenFd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; break; }
        fd_set rfds; FD_ZERO(&rfds); FD_SET(cfd, &rfds);
        struct timeval tv; tv.tv_sec = 0; tv.tv_usec = 500 * 1000;
        char buf[512];
        if (select(cfd + 1, &rfds, NULL, NULL, &tv) > 0) {
            ssize_t n = read(cfd, buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = 0;
                char *save = NULL;
                for (char *tok = strtok_r(buf, "\n", &save); tok; tok = strtok_r(NULL, "\n", &save))
                    FTHandleLine(cfd, tok);
            }
        }
        close(cfd);
    }
    FTDLog("socket thread exit");
    return NULL;
}

static bool FTSetupSocket(void) {
    mkdir("/var/jb/tmp", 0777);
    unlink(g_sockPath);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { FTDLogFmt("socket() failed: %s", strerror(errno)); return false; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_sockPath, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        FTDLogFmt("bind failed: %s (backboardd 沙盒可能禁止)", strerror(errno));
        close(fd); return false;
    }
    chmod(g_sockPath, 0777);
    if (listen(fd, 8) != 0) {
        FTDLogFmt("listen failed: %s", strerror(errno));
        close(fd); return false;
    }
    g_listenFd = fd;
    pthread_t th;
    if (pthread_create(&th, NULL, FTSocketThread, NULL) == 0) pthread_detach(th);
    FTDLog("socket listening");
    return true;
}

// MARK: - 后台初始化线程

static void *FTInitThread(void *ctx) {
    (void)ctx;
    signal(SIGPIPE, SIG_IGN);
    sleep(6);                                  // 等 backboardd 完全就绪（比 v2.2 更保守）
    FTDLogFmt("init thread start, stage=%d", g_stage);

    if (g_stage >= 1) { if (!FTLoadSymbols()) goto done; }
    if (g_stage >= 2) { if (!FTLocateCallback()) goto done; }
    if (g_stage >= 3) { if (!FTInstallHook())   goto done; }
    if (g_stage >= 4) { FTSetupSocket(); }

    FTDLogFmt("stage %d init complete", g_stage);

done:
    // 存活确认：再撑 25 秒不崩 → 把 guard 标记为「本 stage 已验证安全」
    sleep(25);
    FTWriteGuard(g_stage, 0);
    FTDLogFmt("SURVIVED 30s -> stage %d marked SAFE", g_stage);
    return NULL;
}

// MARK: - 入口（constructor：只写日志 + 读控制文件 + pthread_create）

__attribute__((constructor))
static void FTBCtor(void) {
    const char *proc = getprogname();
    FILE *mk = fopen(g_logPath, "a");
    if (mk) {
        fprintf(mk, "\n===== [BackboardInject v2.3] ctor pid=%d proc=%s =====\n",
                (int)getpid(), proc ? proc : "?");
        fclose(mk);
    }

    // 读 stage（默认 4 = 完整功能；有自愈保险兜底，且日志逐步打点可定位失败点。
    // 需要二分排查时手动降到 1/2/3）
    int st = FTReadIntFile(g_stageA, -1);
    if (st < 0) st = FTReadIntFile(g_stageB, -1);
    if (st < 0) st = 4;
    if (st > 4) st = 4;
    g_stage = st;

    // 【开机自愈保险】本 stage 上次尝试过但没撑过 30 秒 → 判定为会崩，直接禁用
    int gs = -1, ga = 0;
    FTReadGuard(&gs, &ga);
    if (gs == g_stage && ga >= 1) {
        FILE *f = fopen(g_logPath, "a");
        if (f) {
            fprintf(f, "[GUARD] stage %d 上次未存活 -> 本次自动禁用（设备可正常启动）。\n"
                       "        降级：echo 0 > %s 然后注销；或改 stage 重试。\n",
                    g_stage, g_stageA);
            fclose(f);
        }
        return;                                 // 不启动任何线程 → 等价于未注入
    }
    if (g_stage <= 0) {
        FILE *f = fopen(g_logPath, "a");
        if (f) { fprintf(f, "[stage 0] 已关闭，不做任何事。\n"); fclose(f); }
        return;
    }
    FTWriteGuard(g_stage, 1);                   // 先记账，再干活

    pthread_t th;
    if (pthread_create(&th, NULL, FTInitThread, NULL) == 0) pthread_detach(th);
}

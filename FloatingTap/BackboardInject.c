//
//  BackboardInject.c — FloatingTap v2.4 backboardd 内注入（佳影同源架构，纯 C）
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
//       2 = 1 + 定位 ___IOHIDServiceEventCallback + 地址校验 + 指令 dump（不 hook）
//       3 = 2 + 装 hook，回调【纯透传】，只用裸 write 打探针  ← v2.4 默认
//       4 = 3 + 回调内调 IOHIDEventGetType 并捕获 service/target/refcon
//       5 = 4 + 开 socket 服务 + 真正连点注入（完整功能）
//     改完 stage 会自动获得一次新的尝试机会（guard 按 stage 记账）。
//
//  ============================ v2.4 崩溃防线 ============================
//  v2.3 崩溃点：日志停在 "hook installed=1 orig=0xd051f08113efc000"，
//  socket listening / bind failed 两行都没有 → 死在 hook 装上后的几微秒内，
//  即【第一个 HID 事件进回调就崩】。且两个地址高位异常：
//      cbAddr = 0x8a514a818d8268a4   orig = 0xd051f08113efc000
//  低 47 位也不像合法 image 地址 → 强烈怀疑 MSFindSymbol 返回值不可用 / 带 PAC。
//  本版四道防线：
//    ① dladdr 校验：地址不在任何已加载 image 内 → 直接拒绝 hook（不再盲装）
//    ② PAC 剥离：ptrauth_strip（arm64e）或手工清高位，剥离后再校验一次
//    ③ mach_vm_read_overwrite 安全读：dump 入口 16 字节，看是否 pacibsp(d503237f)
//    ④ g_origOK 门禁：orig 未通过校验就绝不调用，回调直接 return
//       （代价：触摸暂时失效；收益：不崩，日志完整留存）
//  回调内严禁 fopen/malloc/syslog/CF —— 只用预开 fd 的裸 write()。
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
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

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
static void *g_cbRaw  = NULL;                        // MSFindSymbol 原始返回（可能带 PAC）
static void *g_cbAddr = NULL;                        // strip + 校验后的可用地址
static FT_ServiceEventCallback g_origCB = NULL;      // MSHookFunction 保存的原函数
static bool  g_hooked = false;

// 回调内零 I/O 探针：init 阶段预开 fd，回调里只用裸 write()
static int   g_probeFd = -1;
static volatile int g_probeLeft = 16;                // 只打前 16 行，避免刷爆
static volatile unsigned long g_hits = 0;            // hook 命中计数
static volatile bool g_origOK = false;               // orig 指针校验通过才允许调用

// 真实触摸时捕获的三件套（佳影 _touchEventService 同款）
static void *g_target = NULL;
static void *g_refcon = NULL;
static FT_IOHIDServiceRef g_service = NULL;
static volatile bool g_captured = false;

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

// MARK: - 回调内零 I/O 探针（HID 热路径专用：不 fopen / 不 malloc / 不 syslog）

static void FTProbe(const char *tag) {
    if (g_probeFd < 0) return;
    if (g_probeLeft <= 0) return;
    // 注意：不做原子递减也无妨，多打几行不影响判断
    g_probeLeft--;
    ssize_t w = write(g_probeFd, tag, strlen(tag));
    (void)w;
}

// MARK: - PAC 处理与地址安全校验

static void *FTStripPtr(void *p) {
#if defined(__arm64e__) && __has_feature(ptrauth_calls)
    return ptrauth_strip(p, ptrauth_key_function_pointer);
#else
    uintptr_t v = (uintptr_t)p;
    if (v >> 47) v &= 0x00007FFFFFFFFFFFULL;   // 手工清 PAC 位
    return (void *)v;
#endif
}

// 安全读取目标地址内存：地址非法时返回 false 而不是崩溃
// vm_read_overwrite 在 iOS SDK 里必定可用（mach/mach.h → vm_map.h）
static bool FTSafeRead(void *addr, void *out, size_t len) {
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)(uintptr_t)addr,
                                         (vm_size_t)len,
                                         (vm_address_t)(uintptr_t)out,
                                         &got);
    return (kr == KERN_SUCCESS && got == (vm_size_t)len);
}

// 地址是否落在某个已加载 image 内（dladdr 只查 image 区间，不解引用 → 安全）
static bool FTAddrInImage(void *addr, char *outDesc, size_t descLen) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr(addr, &info) == 0) {
        if (outDesc) snprintf(outDesc, descLen, "NOT-IN-ANY-IMAGE");
        return false;
    }
    if (outDesc) {
        const char *fn = info.dli_fname ? info.dli_fname : "?";
        const char *sn = info.dli_sname ? info.dli_sname : "?";
        const char *base = strrchr(fn, '/');
        snprintf(outDesc, descLen, "image=%s sym=%s symaddr=%p",
                 base ? base + 1 : fn, sn, info.dli_saddr);
    }
    return true;
}

// dump 目标函数入口前 16 字节（arm64e 函数头通常是 pacibsp = 0xd503237f）
static void FTDumpInsns(void *addr) {
    uint32_t w[4] = {0, 0, 0, 0};
    if (!FTSafeRead(addr, w, sizeof(w))) {
        FTDLogFmt("insn dump @%p: UNREADABLE（地址无效，绝不可 hook）", addr);
        return;
    }
    FTDLogFmt("insn dump @%p: %08x %08x %08x %08x%s",
              addr, w[0], w[1], w[2], w[3],
              (w[0] == 0xd503237f) ? "  (pacibsp ✓ 函数入口)" : "");
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
    FTDLogFmt("MS api: getImage=%p findSym=%p", (void *)fGetImage, (void *)fFindSym);
    for (int i = 0; images[i] && !g_cbRaw; i++) {
        void *img = fGetImage(images[i]);
        FTDLogFmt("image[%d] %s => %p", i, images[i], img);
        if (!img) continue;
        for (int j = 0; names[j] && !g_cbRaw; j++) {
            void *sym = fFindSym(img, names[j]);
            if (sym) {
                g_cbRaw = sym;
                FTDLogFmt("MSFindSymbol %s => raw %p (image=%s)", names[j], sym, images[i]);
            }
        }
    }
    if (!g_cbRaw) { FTDLog("___IOHIDServiceEventCallback NOT FOUND"); return false; }

    // ---- v2.4 新增：PAC 剥离 + 三重校验，地址不合法就绝不 hook ----
    char desc[256];
    void *cand = g_cbRaw;
    bool ok = FTAddrInImage(cand, desc, sizeof(desc));
    FTDLogFmt("verify raw  %p -> %s", cand, desc);

    if (!ok) {
        void *st = FTStripPtr(g_cbRaw);
        if (st != g_cbRaw) {
            ok = FTAddrInImage(st, desc, sizeof(desc));
            FTDLogFmt("verify strip %p -> %s", st, desc);
            if (ok) cand = st;
        }
    }

    if (!ok) {
        FTDLogFmt("REJECT: 地址 %p 不在任何已加载 image 内（MSFindSymbol 返回值不可用）。"
                  " 不安装 hook，进程保持健康。", g_cbRaw);
        FTDumpInsns(g_cbRaw);
        return false;
    }

    FTDumpInsns(cand);
    uint32_t first = 0;
    if (!FTSafeRead(cand, &first, sizeof(first))) {
        FTDLogFmt("REJECT: %p 不可读，不安装 hook。", cand);
        return false;
    }

    g_cbAddr = cand;
    FTDLogFmt("callback target LOCKED @ %p", g_cbAddr);
    return true;
}

// MARK: - Hook 回调（stage >= 3）——捕获真实 digitizer 三件套

static void FTServiceEventCallbackNew(void *target, void *refcon,
                                      FT_IOHIDServiceRef service,
                                      FT_IOHIDEventRef event) {
    // ⚠️ HID 热路径：只允许裸 write()，禁止 fopen / malloc / syslog / CF 调用
    g_hits++;
    FTProbe("[cb] enter\n");

    // stage 3 = 纯透传，连 event 都不碰（验证 hook 本身与 orig 调用是否安全）
    if (g_stage >= 4) {
        FTProbe("[cb] gettype\n");
        uint32_t ty = (event && p_GetType) ? p_GetType(event) : 0;
        FTProbe("[cb] gettype ok\n");
        if (ty == 11 && !g_captured) {
            g_target  = target;
            g_refcon  = refcon;
            g_service = service;
            g_captured = true;
            FTProbe("[cb] CAPTURED\n");
        }
    }

    // g_origOK 只有在 orig 指针通过校验后才置位。
    // 未通过 → 直接 return（丢几个事件，屏幕短暂无响应），绝不盲调导致崩溃。
    if (!g_origOK) { FTProbe("[cb] orig-SKIP\n"); return; }

    FTProbe("[cb] pre-orig\n");
    g_origCB(target, refcon, service, event);
    FTProbe("[cb] post-orig\n");
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

    // 探针 fd 必须在 hook 之前就绪：hook 生效的瞬间事件就可能进来
    if (g_probeFd < 0) {
        g_probeFd = open(g_logPath, O_WRONLY | O_APPEND | O_CREAT, 0666);
        FTDLogFmt("probe fd=%d", g_probeFd);
    }

    FTDLogFmt("about to MSHookFunction(%p, %p)", g_cbAddr, (void *)FTServiceEventCallbackNew);
    fHook(g_cbAddr, (void *)FTServiceEventCallbackNew, (void **)&g_origCB);
    g_hooked = (g_origCB != NULL);
    FTDLogFmt("hook installed=%d origRaw=%p", g_hooked ? 1 : 0, (void *)g_origCB);
    if (!g_hooked) return false;

    // ---- v2.4：校验 orig 指针，通过才允许回调调用它 ----
    void *op = (void *)g_origCB;
    char desc[256];
    bool ok = FTAddrInImage(op, desc, sizeof(desc));
    FTDLogFmt("verify orig %p -> %s", op, desc);

    if (!ok) {
        void *st = FTStripPtr(op);
        if (st != op) {
            ok = FTAddrInImage(st, desc, sizeof(desc));
            FTDLogFmt("verify orig strip %p -> %s", st, desc);
            if (ok) { g_origCB = (FT_ServiceEventCallback)st; op = st; }
        }
    }
    // trampoline 通常不属于任何 image，可读即认为可用
    if (!ok) {
        uint32_t probe = 0;
        if (FTSafeRead(op, &probe, sizeof(probe))) {
            FTDLogFmt("orig 不在 image 内但可读（应为 trampoline），首指令=%08x", probe);
            ok = true;
        }
    }

    g_origOK = ok;
    FTDLogFmt("orig usable=%d  %s", ok ? 1 : 0,
              ok ? "(回调将正常透传)" : "(⚠️ 回调将丢弃事件，触摸会失效但不会崩)");
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

    if (g_stage >= 1) { if (!FTLoadSymbols())   goto done; }
    if (g_stage >= 2) { if (!FTLocateCallback()) goto done; }
    if (g_stage >= 3) { if (!FTInstallHook())    goto done; }
    if (g_stage >= 5) { FTSetupSocket(); }

    FTDLogFmt("stage %d init complete", g_stage);

    // hook 命中体检：5 秒后若一次都没进回调，说明这个符号根本不在触摸路径上
    if (g_stage >= 3) {
        sleep(5);
        FTDLogFmt("hook hits after 5s = %lu  (captured=%d, origOK=%d)",
                  g_hits, g_captured ? 1 : 0, g_origOK ? 1 : 0);
        if (g_hits == 0)
            FTDLog("⚠️ 命中 0 次：hook 目标不在触摸事件路径上（不崩但无效），需换符号。"
                   " 提示：屏幕上真实点几下再看这行。");
    }

done:
    // 存活确认：再撑 25 秒不崩 → 把 guard 标记为「本 stage 已验证安全」
    sleep(25);
    FTWriteGuard(g_stage, 0);
    FTDLogFmt("SURVIVED -> stage %d marked SAFE (hits=%lu captured=%d)",
              g_stage, g_hits, g_captured ? 1 : 0);
    return NULL;
}

// MARK: - 入口（constructor：只写日志 + 读控制文件 + pthread_create）

__attribute__((constructor))
static void FTBCtor(void) {
    const char *proc = getprogname();
    FILE *mk = fopen(g_logPath, "a");
    if (mk) {
        fprintf(mk, "\n===== [BackboardInject v2.4] ctor pid=%d proc=%s =====\n",
                (int)getpid(), proc ? proc : "?");
        fclose(mk);
    }

    // 读 stage（默认 4 = 完整功能；有自愈保险兜底，且日志逐步打点可定位失败点。
    // 需要二分排查时手动降到 1/2/3）
    int st = FTReadIntFile(g_stageA, -1);
    if (st < 0) st = FTReadIntFile(g_stageB, -1);
    if (st < 0) st = 3;                 // v2.4 默认 3：装 hook 但纯透传，先证明 hook 本身安全
    if (st > 5) st = 5;
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

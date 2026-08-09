//
//  BackboardInject.c — FloatingTap v2.6 backboardd 内注入（佳影同源架构，纯 C）
//
//  ==================== v2.6 头号教训：rootless 路径双前缀 ====================
//  注入 dylib 内的绝对路径，会被 rootless 运行时自动前缀 jbroot：
//      dylib "/tmp/X"        -> <jbroot>/tmp/X        == shell 的 /var/jb/tmp/X  ✓
//      dylib "/var/jb/tmp/X" -> <jbroot>/var/jb/tmp/X                           ✗ 死角
//  实证（v2.5 日志原文）：源码写 "/var/jb/tmp/ftb_stage"，printf 出来是
//      /var/containers/Bundle/Application/.jbroot-91718B01B8229D6D/var/jb/tmp/ftb_stage
//  后果：guard 落在死角 → postinst 的 rm 永远清不掉 → 早期一次被打断的记账
//        （安装后立刻 killall/重启，没撑过 36 秒存活窗）永久生效
//        → 之后每次开机都是 "[GUARD] 上次未存活 -> 自动禁用"，注入再没跑起来过。
//  铁律：dylib 侧一律 "/tmp/..."，shell 侧一律 "/var/jb/tmp/..."，两者指同一文件。
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
//  2) 【开机自愈保险 v2.6】崩溃后自动禁用，无需安全模式：
//       guard 内容 = "<build id> <stage> <attempts>"，单一路径 /tmp/ftb_guard。
//       · build id = 编译时间戳 hash：新构建自动作废旧记录，
//         不再依赖 postinst 能否够到文件（v2.5 正是栽在这）。
//       · 阈值 2：同 build 同 stage 连续 2 次没撑过存活窗才禁用。
//         阈值 1 会把"安装后立刻重启"误判成崩溃。
//       · 存活窗约 15 秒（v2.3 实测崩溃在 hook 装上后几微秒，长窗口只增加误判）。
//       ⇒ 最多黑屏两次，之后自动跳过，设备正常进系统。
//  3) 【分级开关】改 /var/jb/Library/FloatingTap/ftb_stage（Filza 里即 /Library/FloatingTap/ftb_stage）即可推进/回退，无需重新编译安装：
//       0 = 只写日志（等于关闭）
//       1 = dlopen IOKit + 解析事件构造符号（不碰任何 HID 对象）
//       2 = 1 + 定位 ___IOHIDServiceEventCallback + 地址校验 + 指令 dump（不 hook）
//       3 = 2 + 装 hook，回调【纯透传】，只用裸 write 打探针  ← v2.5 默认
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
//  ======================= v2.5：PAC 真相 + 修法（关键）=======================
//  v2.4 实测日志（设备存活，未黑屏）：
//      MSFindSymbol ___IOHIDServiceEventCallback => raw 0x8a514a818d8268a4
//      verify raw 0x8a514a818d8268a4 -> image=IOKit sym=<redacted> symaddr=0x18d8268a4
//      insn dump @0x8a514a818d8268a4: UNREADABLE → REJECT
//      SURVIVED -> stage 3 marked SAFE (hits=0)
//  结论：
//   A) 指针确实带 PAC。iOS 用户态 VA = 36 位（T0SZ=28），所以 PAC 占 bit36..62，
//      真实地址 = 低 36 位 = 0x18d8268a4 = IOKit 基址 0x18d820000 + 0x68a4。
//      v2.4 的手工掩码用了 47 位（0x00007FFF_FFFFFFFF）——对 macOS 对，对 iOS 错。
//   B) dladdr 内部会自行剥离 PAC，所以它成功了，并把真地址放在 dli_saddr 里；
//      v2.4 只用了它的返回值（bool），把 dli_saddr 这个正确答案扔了。
//   C) "sym=<redacted>" 是 dyld 共享缓存无本地符号表时的正常返回，不是错误。
//  v2.5 修法：
//   1) FTResolvePlain()：候选阶梯 dli_saddr → XPACI → &36位 → &47位 → 原值，
//      逐个 vm_read_overwrite 试读，第一个读得通的才采用，全过程打日志。
//   2) 【调用面 / patch 面分离】——v2.3 崩溃的真正原因很可能在这：
//        · 交给 MSHookFunction 打补丁的必须是【裸地址】
//        · 而 arm64e 上通过 C 函数指针调用会走 blraaz（key IA / disc 0 认证），
//          裸地址直接调 = 认证失败 = 硬崩；arm64 slice 上则相反，签名值直接
//          blr 跳过去 = 跳到垃圾地址 = 硬崩。
//        · 故统一：先求裸地址，再 FTSignPtr() 转成可调用形式（arm64e 重新签名，
//          arm64 原样返回），两种 slice 都安全。
//   3) 死人开关：hook 装上但 orig 不可用（回调只能丢事件 → 触摸失效）时，
//      guard 故意【不标记 SAFE】，重启即自动禁用，避免"不崩但触摸全废"的死局。
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

// ⚠️ v2.6 铁律：注入 dylib 内【绝不写 /var/jb 前缀】。
//    rootless 运行时会自动给绝对路径前缀 jbroot：
//      dylib  "/tmp/X"        -> <jbroot>/tmp/X      ← 与 shell 的 /var/jb/tmp/X 同一文件 ✓
//      dylib  "/var/jb/tmp/X" -> <jbroot>/var/jb/tmp/X  ← 死角，shell 侧永远够不到 ✗
//    v2.5 的 guard 就是栽在这：postinst 清的是前者，dylib 读的是后者，
//    残留的 "3 1" 永久生效 -> 每次开机都被自愈保险禁用。
static const char *g_ctrlDir   = "/Library/FloatingTap";               // 持久目录：jbroot /Library 重启不清
static const char *g_sockPath  = "/tmp/floatingtapd.sock";
static const char *g_logPath   = "/tmp/backboard_inject.log";
// v2.7 关键修复：stage 文件从 /tmp 移到持久目录。/var/jb/tmp 重启会被清空，
// 而 ftb_stage 是唯一不被 dylib 重新生成的文件 -> 重启即丢 -> 永远回退默认 stage 3。
// 改放 /Library/FloatingTap（== shell 的 /var/jb/Library/FloatingTap），重启不清，且 dylib 每次开机写回。
static const char *g_stagePath = "/Library/FloatingTap/ftb_stage";
static const char *g_guardPath = "/tmp/ftb_guard";
static const char *g_piPath    = "/tmp/ftb_pi";        // postinst 落的握手标记
// v2.5 遗留死角，ctor 里主动清掉（此处必须保留双前缀写法才能命中）
static const char *g_deadGuard = "/var/jb/tmp/ftb_guard";
static const char *g_deadStage = "/var/jb/tmp/ftb_stage";

// 编译时间戳 -> 32 位 hash，作为 build id 写进 guard。
// 新构建 = 新 build id = guard 自动作废 = 无条件获得一次干净机会，
// 不再依赖 postinst 能否够到文件。
static const char g_buildStr[] = __DATE__ " " __TIME__;
static unsigned FTBuildID(void) {
    unsigned h = 2166136261u;
    for (const char *p = g_buildStr; *p; p++) { h ^= (unsigned char)*p; h *= 16777619u; }
    return h;
}

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
static FT_ServiceEventCallback g_origCB = NULL;      // MSHookFunction 写回的原始值（可能带 PAC / 是 trampoline）
static FT_ServiceEventCallback g_origCall = NULL;    // 校验+重新签名后的【可调用】指针 ← 只用这个调
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

// iOS 用户态 VA = 36 位（T0SZ=28）→ PAC 占 bit36..62。实测 raw=0x8a514a8_18d8268a4，
// 低 36 位 0x18d8268a4 才是真地址。47 位掩码是 macOS 的规格，用在 iOS 上必错。
#define FT_VA36_MASK 0x0000000FFFFFFFFFULL
#define FT_VA47_MASK 0x00007FFFFFFFFFFFULL

// XPACI：硬件按实际 TCR 配置剥离，arm64 slice 上是 no-op
static void *FTXpac(void *p) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(p, ptrauth_key_function_pointer);
#else
    return p;
#endif
}

// 裸地址 → 【可调用】的函数指针
//   arm64e slice：编译器用 blraaz 认证（key IA / discriminator 0），必须重新签名
//   arm64  slice：blr 不认证，原样返回即可
static void *FTSignPtr(void *plain) {
#if __has_feature(ptrauth_calls)
    if (!plain) return NULL;
    return ptrauth_sign_unauthenticated(plain, ptrauth_key_function_pointer, 0);
#else
    return plain;
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
// 注意：dladdr 内部自带 PAC 剥离，所以带签名的指针也能查成功，
// 且 dli_saddr 就是【已剥离的真实符号地址】—— v2.4 的致命疏漏是没取这个字段。
static bool FTAddrInImage(void *addr, char *outDesc, size_t descLen, void **outSaddr) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (outSaddr) *outSaddr = NULL;
    if (dladdr(addr, &info) == 0) {
        if (outDesc) snprintf(outDesc, descLen, "NOT-IN-ANY-IMAGE");
        return false;
    }
    if (outSaddr) *outSaddr = info.dli_saddr;
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
__attribute__((unused))
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

// v2.5 核心：从可能带 PAC 的原始指针求出【真实可读的裸地址】
// 候选阶梯：dladdr 的 dli_saddr → XPACI → &36位 → &47位 → 原值
// 每个候选都用 vm_read_overwrite 试读，第一个读得通的才采用（读不通不会崩）
static void *FTResolvePlain(void *raw, const char *what) {
    if (!raw) return NULL;

    char desc[256];
    void *cands[8]; const char *tags[8]; int n = 0;

    void *saddr = NULL;
    bool inimg = FTAddrInImage(raw, desc, sizeof(desc), &saddr);
    FTDLogFmt("%s: dladdr(raw %p) -> %s", what, raw, desc);
    if (inimg && saddr) { cands[n] = saddr; tags[n] = "dli_saddr"; n++; }

    void *x = FTXpac(raw);
    if (x != raw) { cands[n] = x; tags[n] = "xpaci"; n++; }

    void *m36 = (void *)((uintptr_t)raw & FT_VA36_MASK);
    void *m47 = (void *)((uintptr_t)raw & FT_VA47_MASK);
    if (m36 != raw && m36 != x) { cands[n] = m36; tags[n] = "mask36"; n++; }
    if (m47 != raw && m47 != x && m47 != m36) { cands[n] = m47; tags[n] = "mask47"; n++; }

    cands[n] = raw; tags[n] = "raw"; n++;

    for (int i = 0; i < n; i++) {
        // 跳过与已试候选重复的项
        bool dup = false;
        for (int k = 0; k < i; k++) if (cands[k] == cands[i]) { dup = true; break; }
        if (dup) continue;

        uint32_t w[4] = {0, 0, 0, 0};
        if (!FTSafeRead(cands[i], w, sizeof(w))) {
            FTDLogFmt("%s cand[%s] %p -> UNREADABLE", what, tags[i], cands[i]);
            continue;
        }
        void *sa2 = NULL;
        bool in2 = FTAddrInImage(cands[i], desc, sizeof(desc), &sa2);
        (void)sa2;
        FTDLogFmt("%s cand[%s] %p -> READABLE %08x %08x %08x %08x | %s%s",
                  what, tags[i], cands[i], w[0], w[1], w[2], w[3],
                  in2 ? desc : "(not-in-image, 可能是 trampoline)",
                  (w[0] == 0xd503237f) ? "  [pacibsp ✓]" : "");
        return cands[i];
    }

    FTDLogFmt("%s: 全部候选均不可读 -> 放弃（不 hook，进程保持健康）", what);
    return NULL;
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

static void FTWriteIntFile(const char *path, int v) {
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "%d", v); fclose(f); }
}

// guard 文件格式： "<buildid> <stage> <attempts>"
// buildid 不匹配 = 别的构建留下的记录 = 直接作废（新版本必得一次干净机会）。
// 单一路径，不再做 A/B "取更悲观" —— v2.5 正是被够不到的那一份永久锁死。
static void FTReadGuard(int *gstage, int *gattempts, char *rawOut, size_t rawLen) {
    *gstage = -1; *gattempts = 0;
    if (rawOut && rawLen) snprintf(rawOut, rawLen, "MISSING");

    FILE *f = fopen(g_guardPath, "r");
    if (!f) return;
    char line[128] = {0};
    if (!fgets(line, sizeof(line), f)) { fclose(f); return; }
    fclose(f);

    for (char *p = line; *p; p++) if (*p == '\n' || *p == '\r') *p = 0;
    if (rawOut && rawLen) snprintf(rawOut, rawLen, "\"%s\"", line);

    unsigned bid = 0; int st = -1, at = 0;
    if (sscanf(line, "%u %d %d", &bid, &st, &at) != 3) return;
    if (bid != FTBuildID()) {
        if (rawOut && rawLen)
            snprintf(rawOut, rawLen, "\"%s\" (build 0x%08x != 本版 0x%08x -> 作废)",
                     line, bid, FTBuildID());
        return;                                  // 旧构建的记录，不认
    }
    *gstage = st; *gattempts = at;
}

static void FTWriteGuard(int stage, int attempts) {
    FILE *f = fopen(g_guardPath, "w");
    if (f) { fprintf(f, "%u %d %d\n", FTBuildID(), stage, attempts); fclose(f); }
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
        // 路径不带 /var/jb：运行时自动前缀 jbroot（写了反而变 <jbroot>/var/jb/... 死角）
        const char *libs[] = { "/usr/lib/libellekit.dylib",
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

    // ---- v2.5：候选阶梯求裸地址（dli_saddr 优先），读不通就不 hook ----
    void *plain = FTResolvePlain(g_cbRaw, "cbAddr");
    if (!plain) {
        FTDLogFmt("REJECT: 无法从 %p 求出可读的回调地址，不安装 hook。", g_cbRaw);
        return false;
    }
    g_cbAddr = plain;
    FTDLogFmt("callback target LOCKED @ %p  (raw was %p)", g_cbAddr, g_cbRaw);
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

    // g_origOK 只有在 orig 指针通过「可读校验 + 重新签名」后才置位。
    // 未通过 → 直接 return（丢事件，触摸暂时失效），绝不盲调导致崩溃。
    if (!g_origOK || !g_origCall) { FTProbe("[cb] orig-SKIP\n"); return; }

    FTProbe("[cb] pre-orig\n");
    g_origCall(target, refcon, service, event);
    FTProbe("[cb] post-orig\n");
}

static bool FTInstallHook(void) {
    if (g_hooked) return true;
    if (!g_cbAddr) return false;
    FT_MSHookFunction fHook = (FT_MSHookFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!fHook) {
        const char *libs[] = { "/usr/lib/libellekit.dylib",
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

    // MSHookFunction 要的是【裸地址】（它自己去 mprotect + 写指令）
    FTDLogFmt("about to MSHookFunction(%p, %p)", g_cbAddr, (void *)FTServiceEventCallbackNew);
    fHook(g_cbAddr, (void *)FTServiceEventCallbackNew, (void **)&g_origCB);
    g_hooked = (g_origCB != NULL);
    FTDLogFmt("hook installed=%d origRaw=%p", g_hooked ? 1 : 0, (void *)g_origCB);
    if (!g_hooked) return false;

    // ---- v2.5：orig 也走候选阶梯求裸地址，再重新签名成可调用指针 ----
    // 关键：调用面和 patch 面必须分开。arm64e 上 C 函数指针调用走 blraaz，
    // 直接调裸地址会认证失败硬崩；arm64 slice 上直接调签名值则跳到垃圾地址。
    void *origPlain = FTResolvePlain((void *)g_origCB, "orig");
    if (origPlain) {
        g_origCall = (FT_ServiceEventCallback)FTSignPtr(origPlain);
        g_origOK = true;
        FTDLogFmt("orig usable: plain=%p callable=%p (回调将正常透传)",
                  origPlain, (void *)g_origCall);
    } else {
        g_origCall = NULL;
        g_origOK = false;
        FTDLog("⚠️ orig 不可用 → 回调将丢弃全部事件：不崩，但触摸会失效。"
               " guard 将保持未确认，重启后自动禁用。");
    }
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
    if (!g_captured || !g_origOK || !g_origCall) return;
    FT_IOHIDEventRef ev = FTCreateEvent(down, x, y, index);
    if (!ev) return;
    pthread_mutex_lock(&g_injectLock);
    g_origCall(g_target, g_refcon, g_service, ev); // ← 零客户端、零 DispatchEvent
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
    sleep(4);                                  // 等 backboardd 完全就绪
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
    // 存活确认：再撑 6 秒不崩 → 把 guard 标记为「本 stage 已验证安全」。
    // 窗口从 v2.5 的 36 秒压到约 15 秒：v2.3 实测崩溃发生在 hook 装上后的几微秒内，
    // 长窗口只会让"安装后立刻重启"被误判成崩溃。
    sleep(6);

    // 【死人开关】hook 装上了但 orig 不可用 = 触摸事件被全部丢弃 = 设备变砖（虽不崩）。
    // 这种情况故意【不标记 SAFE】，让 guard 保持"未确认"，用户重启即自动禁用。
    if (g_hooked && !g_origOK) {
        FTWriteGuard(g_stage, 1);
        FTDLogFmt("⚠️ DEADMAN: stage %d hook 已装但 orig 不可用（触摸失效）。"
                  " guard 保持未确认 → 请重启设备，下次开机将自动禁用。", g_stage);
        return NULL;
    }

    FTWriteGuard(g_stage, 0);
    FTDLogFmt("SURVIVED -> stage %d marked SAFE (hits=%lu captured=%d origOK=%d)",
              g_stage, g_hits, g_captured ? 1 : 0, g_origOK ? 1 : 0);
    return NULL;
}

// MARK: - 入口（constructor：只写日志 + 读控制文件 + pthread_create）

__attribute__((constructor))
static void FTBCtor(void) {
    const char *proc = getprogname();
    FILE *mk = fopen(g_logPath, "a");
    if (mk) {
        fprintf(mk, "\n===== [BackboardInject v2.6] ctor pid=%d proc=%s slice=%s ptrauth=%s "
                    "build=%s(0x%08x) =====\n",
                (int)getpid(), proc ? proc : "?",
#if defined(__arm64e__)
                "arm64e",
#else
                "arm64",
#endif
#if __has_feature(ptrauth_calls)
                "yes",
#else
                "no",
#endif
                g_buildStr, FTBuildID());
        fclose(mk);
    }

    // v2.5 死角清理：那两个被双前缀的文件（<jbroot>/var/jb/tmp/...）shell 侧永远够不到，
    // 只能由 dylib 自己用同样的双前缀写法删掉，否则残留记录会永久锁死自愈保险。
    unlink(g_deadGuard);
    unlink(g_deadStage);

    // v2.7：确保持久控制目录存在（jbroot /Library 重启不清）
    mkdir(g_ctrlDir, 0755);

    // 读 stage（持久目录 /Library/FloatingTap/ftb_stage，等价于 shell 侧 /var/jb/Library/FloatingTap/ftb_stage）
    int st = FTReadIntFile(g_stagePath, -1);
    if (st < 0) st = 5;                 // v2.7.1 起默认 5：装完即高频（用户无法可靠用 Filza 改文件，直接默认到目标态）
    if (st > 5) st = 5;
    g_stage = st;
    FTWriteIntFile(g_stagePath, g_stage);   // 自愈：把当前 stage 写回持久目录，下次开机一定读得到

    // 【开机自愈保险】同一 build + 同一 stage 连续 2 次没撑过存活窗 → 判定为会崩，禁用。
    // 阈值取 2 而不是 1：安装后立刻 killall/重启会在存活窗内打断记账，
    // 那属于误判，不该因此永久封死（v2.5 就是被这种误判 + 死角文件双杀）。
    int gs = -1, ga = 0;
    char rawGuard[160];
    FTReadGuard(&gs, &ga, rawGuard, sizeof(rawGuard));

    // 握手探针：确认 dylib 与 postinst 是否在同一个文件视图里
    char piBuf[64] = "MISSING";
    { FILE *pf = fopen(g_piPath, "r");
      if (pf) { if (!fgets(piBuf, sizeof(piBuf), pf)) strcpy(piBuf, "EMPTY");
                for (char *p = piBuf; *p; p++) if (*p=='\n'||*p=='\r') *p = 0;
                fclose(pf); } }

    { FILE *f = fopen(g_logPath, "a");
      if (f) {
          fprintf(f, "[paths] stage=%d(from %s) guard=%s -> %s | postinst marker %s = %s\n",
                  g_stage, g_stagePath, g_guardPath, rawGuard, g_piPath, piBuf);
          fclose(f);
      } }

    if (gs == g_stage && ga >= 2) {
        FILE *f = fopen(g_logPath, "a");
        if (f) {
            fprintf(f, "[GUARD] stage %d 连续 %d 次未存活 -> 本次自动禁用（设备可正常启动）。\n"
                       "        重试：echo %d > /Library/FloatingTap/ftb_stage 并删除 /tmp/ftb_guard\n"
                       "        关闭：echo 0 > /Library/FloatingTap/ftb_stage\n",
                    g_stage, ga, g_stage);
            fclose(f);
        }
        return;                                 // 不启动任何线程 → 等价于未注入
    }
    if (g_stage <= 0) {
        FILE *f = fopen(g_logPath, "a");
        if (f) { fprintf(f, "[stage 0] 已关闭，不做任何事。\n"); fclose(f); }
        return;
    }
    FTWriteGuard(g_stage, (gs == g_stage ? ga : 0) + 1);   // 先记账，再干活

    pthread_t th;
    if (pthread_create(&th, NULL, FTInitThread, NULL) == 0) pthread_detach(th);
}

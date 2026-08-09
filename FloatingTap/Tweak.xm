//
//  Tweak.xm — FloatingTap v1.0.53
//
//  架构（用户原设计）：AutoTap App = 启动器（选目标 App / 拖动十字线定位置 / 间隔），
//  FloatingTap tweak = 执行器。
//  v1.0.53：通信改为 CFPreferences（cfprefsd 守护进程，跨进程共享，纯系统 API 零第三方依赖）
//  + Darwin 通知（仅唤醒信号，不承载数据）。
//    - Dopamine rootless 官方无内置 rocketbootstrap（release note: "No rocketbootstrap / IPC"），
//      CFMessagePort + RocketBootstrap 方案实测既崩 SB 又不通（两次 Safe Mode），v1.0.53 彻底废弃。
//    - 数据全部走 cfprefsd 共享偏好（appID = com.floatingtap.shared）：
//      tweak 写 heartbeat(_loaded/_hbtimets) + apps(bundleID->displayName)；App 写 config(ClickX/ClickY/IntervalMs)
//    - App 前台轮询读偏好；tweak 常驻收 Darwin 通知（appStarted/configUpdated）后推数据/读配置。
//    - 同时移除 FT_HIDStartSenderIDCapture（arm64e SB 里注册 IOHID 事件回调 = Safe Mode 元凶），
//      senderID 直接用硬编码兜底值。
//
//  仍保持零静态 ObjC 元数据：无 @implementation / @"..." / block 字面量 / @selector / NSLog。
//  日志：syslog + /tmp/floatingtap_ctor.log（append，带时间戳）。
//

#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>   // 仅类型声明（UIWindow/UIEvent），不产生运行时元数据；%hook 需要
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <syslog.h>
#import <time.h>
#import <math.h>
#import <stdint.h>
#import <stdbool.h>
#import <unistd.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <dispatch/dispatch.h>
#import <CoreGraphics/CoreGraphics.h>

#include "HIDInject.h"
#include "FTDaemonClient.h"

// FTLog 定义于文件后部（诊断日志），此处前向声明供 daemon 探测函数使用
static void FTLog(const char *msg);

// MARK: - v2.0 daemon 注入开关
// 根治方案：连点注入优先走独立 daemon（floatingtapd，Unix socket IPC）。
// daemon 在独立进程内用真实 digitizer SID 注入 → 不顶掉用户手指 → 不需要
// SID 探测/verify/stab/残留清理（那些都是 SB 端注入的权宜之计）。
// 运行策略：
//   0 = 未探测（首次连点前 ping 一次）；
//   1 = daemon 可用（连点走 daemon 注入，跳过 SB 端整套探测/残留逻辑）；
//   -1 = daemon 不可用（回退旧 SB 端注入路径）。
static int g_DaemonMode = 0;
static int g_DaemonProbed = 0;

// 探测 daemon 是否可用（只测一次，结果缓存）。失败先尝试 spawn daemon 再测，
// 还不行才回退 SB 注入（不影响使用）。daemon 崩了下次探测会重新 spawn。
static int FTDaemonProbe(void) {
    if (g_DaemonProbed) return g_DaemonMode;
    if (FTDaemonPing()) {
        g_DaemonProbed = 1;
        g_DaemonMode = 1;
        FTLog("daemon available - clicking via daemon");
    } else if (FTDaemonSpawn()) {
        // spawn 成功 → 等 daemon 就绪后二次 ping（spawn 内部已等 300ms）
        if (FTDaemonPing()) {
            g_DaemonProbed = 1;
            g_DaemonMode = 1;
            FTLog("daemon spawned + available - clicking via daemon");
        } else {
            g_DaemonProbed = 1;
            g_DaemonMode = -1;
            FTLog("daemon spawned but ping failed - fallback to SB inject");
        }
    } else {
        g_DaemonProbed = 1;
        g_DaemonMode = -1;
        FTLog("daemon unavailable (no binary) - fallback to SB inject");
    }
    return g_DaemonMode;
}

// MARK: - objc_msgSend 类型化函数指针（ARM64 下结构体参数需与目标方法签名一致）

typedef id         (*Msg_Send)(id, SEL);
typedef id         (*Msg_Init)(id, SEL);
typedef id         (*Msg_InitWithTargetAction)(id, SEL, id, SEL);
typedef id         (*Msg_AllocInitWithFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetFrame)(id, SEL, CGRect);
typedef void       (*Msg_SetBackgroundColor)(id, SEL, id);
typedef void       (*Msg_SetCGFloat)(id, SEL, CGFloat);
typedef CGFloat    (*Msg_CGFloatReturn)(id, SEL);
typedef void       (*Msg_SetAlpha)(id, SEL, CGFloat);
typedef void       (*Msg_SetBorderColor)(id, SEL, CGColorRef);
typedef void       (*Msg_SetWindowLevel)(id, SEL, CGFloat);
typedef void       (*Msg_SetHidden)(id, SEL, BOOL);
typedef void       (*Msg_SetUserInteractionEnabled)(id, SEL, BOOL);
typedef void       (*Msg_AddGestureRecognizer)(id, SEL, id);
typedef void       (*Msg_SetEnabled)(id, SEL, BOOL);
typedef void       (*Msg_RequireToFail)(id, SEL, id);
typedef void       (*Msg_AddSubview)(id, SEL, id);
typedef void       (*Msg_SetTag)(id, SEL, NSInteger);
typedef id         (*Msg_ViewWithTag)(id, SEL, NSInteger);
typedef void       (*Msg_MakeKeyAndVisible)(id, SEL);
typedef void       (*Msg_SetNumberOfTapsRequired)(id, SEL, NSUInteger);
typedef void       (*Msg_SetWindowScene)(id, SEL, id);
typedef id         (*Msg_Layer)(id, SEL);
typedef id         (*Msg_ColorWithRGBA)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat);
typedef CGColorRef (*Msg_CGColor)(id, SEL);
typedef CGRect     (*Msg_Bounds)(id, SEL);
typedef CGRect     (*Msg_Frame)(id, SEL);
typedef CGPoint    (*Msg_LocationInView)(id, SEL, id);
typedef NSUInteger (*Msg_State)(id, SEL);
typedef NSUInteger (*Msg_Count)(id, SEL);
typedef id         (*Msg_AnyObject)(id, SEL);
typedef id         (*Msg_ObjectAtIndex)(id, SEL, NSUInteger);
typedef BOOL       (*Msg_IsKindOf)(id, SEL, Class);
typedef NSInteger  (*Msg_Int)(id, SEL);
typedef id         (*Msg_SendID)(id, SEL, void *);
typedef const char * (*Msg_UTF8String)(id, SEL);
typedef CGPoint    (*Msg_LocationInView)(id, SEL, id);

// 判断当前进程 bundle id（v1.0.47：SB 进程控制端 / 抖音进程注入执行端）
static BOOL FTIsBundle(const char *bundleID) {
    Class ClsBundle = objc_getClass("NSBundle");
    if (!ClsBundle) return NO;
    id mb = ((Msg_Send)objc_msgSend)((id)ClsBundle, sel_registerName("mainBundle"));
    if (!mb) return NO;
    id bid = ((Msg_Send)objc_msgSend)(mb, sel_registerName("bundleIdentifier"));
    if (!bid) return NO;
    const char *s = ((Msg_UTF8String)objc_msgSend)(bid, sel_registerName("UTF8String"));
    return (s && strcmp(s, bundleID) == 0);
}

// MARK: - 全局状态（纯 C）

static id gBallContainer = nil;   // 球的父窗口（v1.0.58：优先 _UISystemGestureWindow，始终位于所有 App 之上；兜底 keyWindow）
static id gBallView      = nil;   // 球 UIView 本身
static id gGestureWin    = nil;   // v1.0.61：从 sendEvent 事件流直接捕获到的系统手势窗口实例（最可靠的定位方式）
static id gTapGR      = nil;
static id gTapGR2     = nil;   // 点击点标记上的双击手势（同样触发模式切换，避免标记盖住球时双击失效）
static id gLongGR     = nil;
static id gPanGR      = nil;   // 拖动手势（仅「红色拖动模式」生效，移动球本身）
static id gClickPointView = nil; // 点击点标记（独立视图，仅「红色拖动模式」可拖动；蓝色连击模式不可交互→点击穿透到下层 App）
static id gClickFlashView = nil; // v1.0.81：点击落点光圈——连点每次注入都在点击点显示红圈，直观看到"点击落在哪"
static id gClickPanGR = nil;   // 点击点拖动手势（仅红色模式生效，移动点击点，与球解耦）
static BOOL gDragMode = NO;    // NO=蓝色连击模式（长按触发连点）；YES=红色拖动模式（拖动定位）

// v1.0.71：按指针身份追踪按在球上的「用户手指」触摸，替代 UILongPressGR 触发连点。
// 免疫两大致命干扰：① 游戏内多点触摸（第 2 根手指）会让 UILongPress 被判 Cancelled；
// ② 合成注入触摸（当点击点==球心时落回球上）会让 UILongPress 收 2nd touch 取消。
// 只认「在球内 Began 的那一根触摸」，其余触摸/合成触摸一律忽略。
static void *gBallTouch = NULL;          // 用户手指对应的 UITouch 对象（ARC 下系统持有，指针有效期内稳定）
static double gBallTouchDownTime = 0;    // 该触摸 Began 的单调时间
static BOOL   gBallTouchClicking = NO;   // 是否已据此触摸开始连点（避免重复 start）
static BOOL   gBallTouchTimerPending = NO; // 120ms 长按计时器是否已排队（避免重复排）
// v1.0.94：松手宽限（豆包方案）——v1.0.94 起注入用 zxtouch 官方 SID 0x8000... + digitizer
// SenderID 字段（0x0B0018），目标是不再「顶掉」用户按住的手指 → 用户手指全程 alive →
// touchesEnded/Cancelled 是真实松手信号。宽限从 400ms 缩到 120ms：touchesEnded（抬起）/
// touchesCancelled（滑出/系统打断）后 120ms 内无新 Began 即停止连点（接近「立刻终止」）。
static BOOL   gStopGracePending = NO;
static void FTStopGraceTimer(void *ctx);

// ⚠️ v1.0.101：SID 运行时自动探测状态——Dopamine 上「送达且不顶掉」的 SID 会话随机
// （无规律可循），按住球时逐个候选 SID 注入探测 tap，双重判定（sendEvent 回流=送达、
// 用户手指存活=不顶掉）后锁定 g_LockedSID；失败则等用户重按再试下一个候选。
static BOOL   g_Probing = NO;        // 探测进行中（球变橙色提示）
static BOOL   g_ProbeNeedMain = NO;  // v1.0.103：候选全失败 → 球变紫，提示先点屏幕别处
static BOOL   g_ProbeFullScan = NO;  // v1.0.105：全扫模式（候选耗尽后扫 0x100000700-0x7ff）
static int    g_ProbeIdx = 0;        // 当前候选序号（全扫时 = 扫描偏移，跨轮保留）
static uint64_t g_ProbeEndingSIDs[64]; // v1.0.105：已验证「顶掉用户手指」的 SID（全扫跳过）
static int    g_ProbeEndingCount = 0;
static BOOL   g_ProbeTouchEnded = NO; // 探测期间用户手指被顶掉（SID 无效）
static BOOL   g_ProbeDelivered = NO;  // 探测期间合成触摸回流 sendEvent（SID 送达）
// v1.0.107：最近探测 tap 注入的单调时刻——送达判定用「时间窗」（注入后 60ms 内出现的
// 点击点附近 Began = 探测 tap 送达），排除用户手指干扰（滑出球边是 Moved 非 Began、
// 已存在触摸 Began 早于注入窗口）。
static double g_ProbeTapT0 = 0;
// v1.0.108：探测中用户手指被顶掉且未重绑（无法验证「不顶掉」）→ 送达型只记保底；
// 手指重新 Began（重绑复活）时复位，恢复完整验证。
static BOOL   g_ProbeFingerDead = NO;
// v1.0.108：手指死后第一个「送达型」SID（全扫耗尽时保底锁定开始连点，保证有点击）
static uint64_t g_ProbeDeliveredSID = 0;
// v1.0.115：锁定成功时的全扫位置——自愈验证失败（verify-fail）后从该位置继续扫，
// 不再从头全扫 49 秒（ctor-12：「至少三次按很久才变蓝」的根因之一）
static int g_ProbeLockIdx = 0;
static uint64_t g_ProbeSID = 0;      // 当前探测的 SID
static uint64_t g_LockedSID = 0;     // 探测成功锁定的有效 SID（会话内稳定）
static uint64_t g_ProbeSIDs[10];     // 候选集（构建后去重）
static int    g_ProbeSIDCount = 0;
static void FTStartProbing(void);
static void FTProbeNext(void);
static void FTCheckProbe(void *ctx);

static CGPoint gClickPanStartLoc;   // 点击点拖动起点（窗口坐标）
static CGPoint gClickPanOrigin0;    // 点击点拖动起点 frame.origin

static CGPoint gPanStartLoc;   // 触摸起始点（窗口坐标）
static CGPoint gPanOrigin0;    // 触摸起始时窗口 frame.origin

static double  gScreenW = 0;   // 主屏尺寸（FTSetupBall 时保存）
static double  gScreenH = 0;

static BOOL    gIsClicking = NO;            // 连点进行中
static uint32_t gTapIndex = 0;              // 每次 tap 递增的 index（区分触摸，避免被串流）
static double  gClickLockX = 0.5;           // 连点锁定坐标 = 点击点标记位置（与球解耦，由标记拖动/App 配置设定）
static double  gClickLockY = 0.5;
static dispatch_source_t gClickTimer = NULL; // 连点定时器（SB 端直接注入用）
// v1.0.97：残留合成手指追踪——10ms 连点 + 15ms up-delay 下，部分 up 会被系统吞掉，
// 导致合成手指永远"按着"屏幕（SEND phase=2 Stationary 残留，ctor-69 铁证：连点停止后
// 合成触摸持续 5s tap=151 不消失）→ Home indicator（小白条）上滑失效、息屏才恢复。
// 每个 down 记录 index，up 回调清除；连点停止时对【仍残留的 index】在点击点补发 up。
static bool g_PendingUpIdx[16] = {false}; // index 2-9 用（1 留给用户手指，勿动）
// v1.0.113：每个待 up index 的 down 时刻——连点期间定期清「down 超 150ms 未 up」的残留
// 手指（up 被吞的），防残留累积（ctor-9：SBHomeScreenWindow 残留 tap 累积 40→481 →
// 小白条失效 + 游戏长按效果 + tapCount 无限累积）
static double g_PendingUpT[16] = {0};
static void FTCheckResidualDuringCombo(void);
static void FTStopClicking(const char *reason); // v1.0.127：幽灵看门狗在 FTClickCallback 提前调用，需前向声明

// v1.0.112：连点「送达自愈验证」——锁定 SID 后若连点期间 SEND 无合成触摸回流
//（点击点附近 !onBall 触摸）→ 锁定的 SID 假送达（顶掉型 C 类）→ 停止连点、记录跳过、
// 自动重新探测。防止「锁定假送达型 → 连点空跑」（ctor-8：0x100000661 连点 540 次空跑）。
static BOOL   g_VerifyDelivering = NO;
static BOOL   g_VerifySawSynthetic = NO;
// ⚠️ v1.0.135（ctor-32 实锤）：verify 窗口内【送达回流计数】——顶掉型 SID 每轮也有
// 部分 down 送达（回流存在但 <50%），「有无回流」判不出（首轮 tap=15 全送达 → 不
// 淘汰 → 顶掉循环永驻 → 连点断续 + 游戏跳屏）。用【回流比例】：顶掉轮回流 <50%、
// 稳定轮回流 >50%。每轮 started 清零，sendEvent 判定处 +1。
static int     g_VerifySawCount = 0;
// ⚠️ v1.0.129（ctor-26 实锤）：verify 定时器必须绑定【具体轮次】。旧实现每轮
// FTStartClicking 都排 0.8s 定时器且共用 g_VerifyDelivering——用户快速反复短按时
//（游戏试枪），上一轮的定时器到期时新一轮 started 已把 g_VerifyDelivering 重置为
// YES → 旧轮定时器误把「刚 started 的新轮」（注入还没回流）判为 not delivering →
// 好 SID 被误淘汰 → 回退探测 → 探测时用户已松手 → 「一直变不了蓝」。g_VerifyEpoch
// 每轮递增，定时器 ctx 携带快照，到期时 epoch 不匹配 = 旧轮 → 直接丢弃。
static int     g_VerifyEpoch = 0;
// ⚠️ v1.0.130（ctor-27 实锤）：verify-fail 连续计数——单轮窗口内无回流不淘汰（游戏
// 高频场景注入繁忙/残留占槽时单轮无回流很常见，0x730 稳定连点 97 次仍被单轮误杀）。
// 连续 2 次 fail 才确认假送达 → 淘汰 + 续扫；通过即清零。
static int     g_VerifyFailCount = 0;
static void FTVerifyDeliveryTimer(void *ctx);
// ⚠️ v1.0.119（ctor-16 实锤）：「高频稳定性验证」——低频探测 tap（60ms 单发）不顶掉
// 用户手指的 SID，在 10ms 高频连点下可能顶掉（0x100000716：探测 dist=0 锁定，连点后
// 每轮仅 8 次就 touches-ended → 停止 → 0.6s 重绑 → 循环，用户感知「不连续」；且频繁
// 停止让 up 丢失 50% → 残留堆积 → 小白条失效）。锁定后进入 400ms 稳定性窗口：窗口内
// touches-ended（顶掉）且随后手指重绑（gBallTouch!=NULL）→ 该 SID 高频顶掉 → 记跳过
// + 断点续扫；窗口内稳定 → 验证通过，正式连点。
static BOOL   g_StabTesting = NO;
static BOOL   g_StabFail = NO;
// v1.0.127：连续 stab-fail 计数——≥3 次判定本会话「无稳定 SID」→ g_StabForceLock=YES，
// 下次锁定跳过验证直接连点（快速变蓝，防 ctor-22「一直变不了蓝」）；stab 通过即清零。
static int    g_StabFailCount = 0;
static BOOL   g_StabForceLock = NO;
// v1.0.121：探测续扫时用户手指不在球上（顶掉未重绑/真松手）的起始时刻——等手指
// 重绑或再按（≤5s），超时才停止探测回蓝（防真松手后空扫 46s 到紫）
static double g_ProbeNoFingerT0 = 0;

// v1.0.50：AutoTap App 配置（位置/间隔）——定义在 FTIntervalMs 之前（它要读）
// ⚠️ v1.0.123：默认间隔 10ms → 15ms——10ms（100Hz）+ up-delay 25ms = 同时 2.5 根
// 合成手指重叠，up 丢失率高 → 残留手指堆积 → 小白条失效 + 游戏长按残留（ctor-19/20
// 实锤，补发 up 也清不掉）。15ms（67Hz）→ 重叠 1.67 根，up 丢失率大幅下降。
// ⚠️ v1.0.128：15ms → 20ms（50Hz）——15ms + 25ms up-delay 重叠仍有 1.67 根，残留
// 依旧（ctor-25：绿圈出现还在开枪 = 残留手指按着开火键）。20ms → 重叠 1.25 根。
// ⚠️ v1.0.132：20ms → 30ms（33Hz）+ up-delay 25ms → 35ms——20ms+25ms 下 down(N+1)
// 仍在 up(N) 前 5ms（重叠 1.25 根），up 丢失依旧（ctor-29：combo cleanup 11 + 每轮
// raise 14 = 残留指数恶化 → 小白条 8s）。30ms+35ms：down(N+1) 在 up(N) 后 5ms → 活跃
// <1 根 → up 丢失率大降。33Hz 远超全自动枪射速，App 仍可配更快（gCfgMs）。
// ⚠️ v1.0.134：30ms → 40ms（25Hz）+ up-delay 45ms——ctor-31 每轮仍残留 6-8 个（up
// 丢失 3%），累积几十根 → 系统触摸崩溃 → 后半段每轮 4 次顶掉（「前面好后面失效」）。
// 40ms+45ms 频率低 → 每轮 up 数量少 → 丢失总数更少；25Hz 仍远超游戏射速。
static double gCfgX = 0.5, gCfgY = 0.5, gCfgMs = 40.0;
static int  gCfgLoaded = 0;

// MARK: - 诊断日志（append 到标记文件，Filza 可见；带单调时间戳）

static void FTLog(const char *msg) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double t = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    char line[256];
    snprintf(line, sizeof(line), "[%.1f] %s", t, msg);
    FILE *f = fopen("/tmp/floatingtap_ctor.log", "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
    syslog(LOG_ERR, "%s", line);
}

// MARK: - 工具

static id FTAlloc(Class cls) {
    return ((Msg_Send)objc_msgSend)((id)cls, sel_registerName("alloc"));
}

static id FTAllocInitWithFrame(Class cls, CGRect frame) {
    id obj = FTAlloc(cls);
    return ((Msg_AllocInitWithFrame)objc_msgSend)(obj, sel_registerName("initWithFrame:"), frame);
}

// 取当前前台活跃的 UIWindowScene（iOS 13+ 必需，否则 UIWindow 不渲染）
static id FTGetActiveWindowScene(void) {
    Class ClsApp = objc_getClass("UIApplication");
    if (!ClsApp) return nil;
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
    if (!app) return nil;
    id scenes = ((Msg_Send)objc_msgSend)(app, sel_registerName("connectedScenes"));
    if (!scenes) return nil;
    id arr = ((Msg_Send)objc_msgSend)(scenes, sel_registerName("allObjects"));
    if (!arr) return nil;
    NSUInteger n = ((Msg_Count)objc_msgSend)(arr, sel_registerName("count"));
    Class ClsWScene = objc_getClass("UIWindowScene");
    id firstWS = nil;
    for (NSUInteger i = 0; i < n; i++) {
        id s = ((Msg_ObjectAtIndex)objc_msgSend)(arr, sel_registerName("objectAtIndex:"), i);
        if (!s) continue;
        if (ClsWScene && ((Msg_IsKindOf)objc_msgSend)(s, sel_registerName("isKindOfClass:"), ClsWScene)) {
            if (firstWS == nil) firstWS = s;
            NSInteger act = ((Msg_Int)objc_msgSend)(s, sel_registerName("activationState"));
            if (act == 1) return s; // UISceneActivationStateForegroundActive = 1
        }
    }
    return firstWS;
}

// SB UI 是否就绪：能拿到 windowScene，或 UIApplication 至少有一个 window
static BOOL FTUIReady(void) {
    if (FTGetActiveWindowScene()) return YES;
    Class ClsApp = objc_getClass("UIApplication");
    if (!ClsApp) return NO;
    id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
    if (!app) return NO;
    id wins = ((Msg_Send)objc_msgSend)(app, sel_registerName("windows"));
    if (!wins) return NO;
    NSUInteger n = ((Msg_Count)objc_msgSend)(wins, sel_registerName("count"));
    return n > 0;
}

// MARK: - 连点引擎

static unsigned long gClickCount = 0; // 本次连点周期内的点击次数（诊断）

// 读取连点间隔（毫秒）：优先 App 配置（v1.0.50），兜底 cfg 文件，默认 20ms。
// ⚠️ v1.0.128：20ms ≈ 50 次/秒（15ms=67Hz 时 up 重叠 1.67 根残留仍多，ctor-25 实锤）；
// 50Hz 游戏连点足够，up 丢失率最低。
static double FTIntervalMs(void) {
    if (gCfgLoaded && gCfgMs >= 1.0) return gCfgMs;
    FILE *f = fopen("/var/mobile/Library/Preferences/com.floatingtap.cfg", "r");
    if (f) {
        double v = 40.0; // v1.0.134：默认 40ms（25Hz，up 丢失最少）
        if (fscanf(f, "%lf", &v) == 1 && v >= 1.0 && v <= 60000.0) {
            fclose(f);
            return v;
        }
        fclose(f);
    }
    return 30.0;
}

// MARK: - App 通信（v1.0.53：CFPreferences 共享偏好，cfprefsd 守护进程跨进程共享）
// Dopamine rootless 官方无内置 rocketbootstrap（release note: "No rocketbootstrap / IPC"），
// 且第三方移植加载即崩 SB（实测两次 Safe Mode）→ CFMessagePort 方案废弃。
// 改用 cfprefsd（系统守护进程，所有进程共享，纯系统 API 零第三方依赖）：
//   tweak 写：appID=com.floatingtap.shared, key=_loaded=true, key=_hbtimets=epoch秒,
//             key=_apps=dict(bundleID->displayName)
//   App  写：appID=com.floatingtap.shared, key=_config=dict(ClickX/ClickY/IntervalMs)
// Darwin 通知（appStarted/configUpdated）仅作唤醒信号，不承载数据。
// 注意：App 前台轮询读偏好（无需 tweak 主动推送），tweak 常驻收通知后推数据/读配置。

typedef id         (*Msg_AllApps)(id, SEL);
typedef id         (*Msg_AppBid)(id, SEL);
typedef id         (*Msg_AppName)(id, SEL);

// 动态 CFString（避免字面量字符串元数据；CFStringCreateWithCString 在 SB 启动后安全）
static CFStringRef FTCreateCFStr(const char *s) {
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

// 共享偏好 appID（tweak 与 App 双方约定）
// v1.0.53.1：必须用 App 自己的 bundleID，否则 cfprefsd 在 iOS 沙盒下
// 拒绝 App 进程读第三方 appID 的偏好。Tweak 是越狱 root 进程，
// 写任何 appID 都通；App 只能读自己 bundleID（com.autotap.app）的偏好。
static CFStringRef FTSharedAppID(void) {
    return FTCreateCFStr("com.autotap.app");
}

// 写一条共享偏好（key:value → appID，current user / any host）
static void FTWritePref(const char *key, CFPropertyListRef value) {
    CFStringRef appID = FTSharedAppID();
    if (!appID || !key || !value) { if (appID) CFRelease(appID); return; }
    CFStringRef k = FTCreateCFStr(key);
    if (k) {
        CFPreferencesSetValue(k, value, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(k);
    }
    CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(appID);
}

// 前向声明（定义在文件后段）
static void FTMoveBallToConfig(void);
static void FTWriteAppsList(void);
static void FTAppsListDeferredCallback(void *ctx);

// 应用共享偏好里的 config（CoreFoundation CFDictionary，纯 C，无 ObjC）
static void FTApplyConfigFromPrefs(CFDictionaryRef dict) {
    if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return;
    double nx = 0.5, ny = 0.5, ms = 40.0; // v1.0.134：默认 40ms（25Hz，up 丢失最少）
    CFStringRef kX = FTCreateCFStr("ClickX");
    CFStringRef kY = FTCreateCFStr("ClickY");
    CFStringRef kMs = FTCreateCFStr("IntervalMs");
    CFNumberRef v = NULL;
    if (kX && (v = (CFNumberRef)CFDictionaryGetValue(dict, kX)) && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue(v, kCFNumberDoubleType, &nx);
    if (kY && (v = (CFNumberRef)CFDictionaryGetValue(dict, kY)) && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue(v, kCFNumberDoubleType, &ny);
    if (kMs && (v = (CFNumberRef)CFDictionaryGetValue(dict, kMs)) && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue(v, kCFNumberDoubleType, &ms);
    if (kX) CFRelease(kX); if (kY) CFRelease(kY); if (kMs) CFRelease(kMs);
    if (nx < 0) nx = 0; if (nx > 1) nx = 1;
    if (ny < 0) ny = 0; if (ny > 1) ny = 1;
    if (ms < 1) ms = 40;
    gCfgX = nx; gCfgY = ny; gCfgMs = ms;
    gCfgLoaded = 1;
    FTMoveBallToConfig();
    char diag[128];
    snprintf(diag, sizeof(diag), "config via prefs x=%.2f y=%.2f ms=%.0f", nx, ny, ms);
    FTLog(diag);
}

// 读共享偏好里的 config（App 写；兼容 CFData(序列化) 或直接 CFDictionary 两种存储）
static void FTReadConfig(void) {
    CFStringRef appID = FTSharedAppID();
    if (!appID) return;
    CFStringRef k = FTCreateCFStr("_config");
    if (k) {
        CFPropertyListRef v = CFPreferencesCopyValue(k, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (v) {
            CFTypeID tid = CFGetTypeID(v);
            if (tid == CFDataGetTypeID()) {
                CFErrorRef err = NULL;
                CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, (CFDataRef)v,
                    kCFPropertyListImmutable, NULL, &err);
                if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
                    FTApplyConfigFromPrefs((CFDictionaryRef)plist);
                } else {
                    FTLog("config: parse failed");
                }
                if (plist) CFRelease(plist);
                if (err) CFRelease(err);
            } else if (tid == CFDictionaryGetTypeID()) {
                FTApplyConfigFromPrefs((CFDictionaryRef)v);
            }
            CFRelease(v);
        }
        CFRelease(k);
    }
    CFRelease(appID);
}

// tweak→App：写心跳（_loaded=true, _hbtimets=epoch 秒）
static void FTWriteHeartbeat(void) {
    double now = (double)time(NULL);
    CFNumberRef t = CFNumberCreate(NULL, kCFNumberDoubleType, &now);
    FTWritePref("_loaded", kCFBooleanTrue);
    FTWritePref("_hbtimets", t);
    if (t) CFRelease(t);
    FTLog("heartbeat written via CFPreferences");
    // v1.0.53.3 诊断：探测 cfprefsd 实际写入路径 + tweak 自身能否读回
    {
        const char *candidates[] = {
            "/var/mobile/Library/Preferences/com.autotap.app.plist",
            "/private/var/mobile/Library/Preferences/com.autotap.app.plist",
            NULL
        };
        for (int i = 0; candidates[i]; i++) {
            FILE *f = fopen(candidates[i], "r");
            char diag[200];
            if (f) {
                fseek(f, 0, SEEK_END);
                long sz = ftell(f);
                fclose(f);
                snprintf(diag, sizeof(diag), "probe tweak: %s EXISTS sz=%ld", candidates[i], sz);
            } else {
                snprintf(diag, sizeof(diag), "probe tweak: %s MISSING (errno=%d)", candidates[i], errno);
            }
            FTLog(diag);
        }
        // 同进程自读 cfprefsd：验证 tweak 写完自己能不能读回
        CFStringRef appID = FTSharedAppID();
        CFStringRef k = FTCreateCFStr("_hbtimets");
        if (appID && k) {
            CFPropertyListRef v = CFPreferencesCopyValue(k, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            char diag[160];
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                double back = 0;
                CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &back);
                snprintf(diag, sizeof(diag), "probe tweak: cfprefsd self-read OK back=%.0f", back);
                CFRelease(v);
            } else {
                snprintf(diag, sizeof(diag), "probe tweak: cfprefsd self-read NIL");
            }
            FTLog(diag);
            CFRelease(k);
        }
        if (appID) CFRelease(appID);
    }
}

// tweak→App：枚举已装 App 并写共享偏好（SB 进程 LSApplicationWorkspace 特权枚举）
static void FTWriteAppsList(void) {
    Class ClsWS = objc_getClass("LSApplicationWorkspace");
    if (!ClsWS) { FTLog("apps: LSApplicationWorkspace missing"); return; }
    id ws = ((Msg_Send)objc_msgSend)((id)ClsWS, sel_registerName("defaultWorkspace"));
    if (!ws) { FTLog("apps: workspace nil"); return; }
    id apps = ((Msg_AllApps)objc_msgSend)(ws, sel_registerName("allApplications"));
    if (!apps) { FTLog("apps: allApplications nil"); return; }
    NSUInteger n = ((Msg_Count)objc_msgSend)(apps, sel_registerName("count"));
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (NSUInteger i = 0; i < n; i++) {
        id a = ((Msg_ObjectAtIndex)objc_msgSend)(apps, sel_registerName("objectAtIndex:"), i);
        if (!a) continue;
        id bid = ((Msg_Send)objc_msgSend)(a, sel_registerName("bundleIdentifier"));
        id nm = ((Msg_Send)objc_msgSend)(a, sel_registerName("name"));
        const char *bidc = bid ? ((Msg_UTF8String)objc_msgSend)(bid, sel_registerName("UTF8String")) : NULL;
        if (!bidc) continue;
        const char *nmc = nm ? ((Msg_UTF8String)objc_msgSend)(nm, sel_registerName("UTF8String")) : NULL;
        CFStringRef kb = FTCreateCFStr(bidc);
        if (!kb) continue;
        CFStringRef kv = FTCreateCFStr(nmc ? nmc : bidc);
        CFDictionarySetValue(d, kb, kv ? kv : kb);
        if (kv) CFRelease(kv);
        CFRelease(kb);
    }
    FTWritePref("_apps", d);
    CFRelease(d);
    char diag[128];
    snprintf(diag, sizeof(diag), "apps saved %lu entries via CFPreferences", (unsigned long)n);
    FTLog(diag);
}

// Darwin 通知回调（纯 C；observer=静态占位，靠 name 区分）——只作唤醒信号，数据走 CFPreferences
static int sNotifyObserver = 0;
static void FTNotificationCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object; (void)userInfo;
    char buf[256];
    if (!name || !CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)) return;
    if (strcmp(buf, "com.floatingtap.autotap.appStarted") == 0) {
        FTLog("got appStarted -> write hb via CFPreferences");
        FTWriteHeartbeat();
        // v1.0.53.2：绝不在通知线程同步枚举 App（LSApplicationWorkspace 在通知回调里仍会崩 SB）。
        // 改派发 3s 延迟到主队列，复用已 @try 包裹的延迟回调；与 60s 那次枚举互不冲突。
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                         dispatch_get_main_queue(), NULL, FTAppsListDeferredCallback);
    } else if (strcmp(buf, "com.floatingtap.autotap.configUpdated") == 0) {
        FTLog("got configUpdated -> read config from CFPreferences");
        FTReadConfig();
        FTWriteHeartbeat();
    }
}

// 注册 Darwin 通知（App→tweak 唤醒信号；无 IPC server，数据走共享偏好）
static void FTRegisterNotifications(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (!center) return;
    static CFStringRef sNameAppStarted = NULL, sNameConfig = NULL;
    if (!sNameAppStarted) {
        sNameAppStarted = CFStringCreateWithCString(NULL, "com.floatingtap.autotap.appStarted", kCFStringEncodingUTF8);
        sNameConfig = CFStringCreateWithCString(NULL, "com.floatingtap.autotap.configUpdated", kCFStringEncodingUTF8);
    }
    if (sNameAppStarted)
        CFNotificationCenterAddObserver(center, &sNotifyObserver, FTNotificationCallback,
                                        sNameAppStarted, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    if (sNameConfig)
        CFNotificationCenterAddObserver(center, &sNotifyObserver, FTNotificationCallback,
                                        sNameConfig, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    FTLog("darwin notify registered (CFPreferences comm)");
    // 启动即尝试：读 App 可能已写的配置 + 推一次心跳（轻量操作，30s 阶段稳定）
    FTReadConfig();
    FTWriteHeartbeat();
    // FTWriteAppsList 用 objc_msgSend 调 LSApplicationWorkspace.allApplications——
    // 在 SB 启动 30s 阶段仍不稳，挪到独立的 60s 延迟回调，给 SB 更多时间稳定后再枚举。
    FTLog("defer apps list scan to +60s");
}

// 60s 后单独尝试枚举 App 列表（不再混入 30s init）；依然包 try/catch 兜底
static void FTAppsListDeferredCallback(void *ctx) {
    (void)ctx;
    FTLog("deferred apps list scan start");
    @try {
        FTWriteAppsList();
    } @catch (NSException *ex) {
        FTLog("apps list scan exception (swallowed)");
        (void)ex;
    }
}

// 恢复球窗口交互（注入后 60ms 回调）

// MARK: - 连点注入
// v1.0.62：改用「系统 HID 服务」派发（IOHIDEventSystemClientDispatchEvent，见 HIDInject.c
// 的 FT_HIDDispatchDown/Up），事件由系统路由到前台 App。
// ⚠️ 旧版（v1.0.41~61）走 SpringBoard 的 UIApplication._handleHIDEvent:——那只喂 SB 自己的
// 事件队列，前台 App（游戏）收不到 → 注入日志有、但无任何点击反馈。这是"无点击效果"的真凶。
// down 立即发，up 延迟 50ms 发（社区标准做法）——让系统把 down/up 关联为同一触摸。

// v1.0.75：up 回调上下文按次 malloc（消除全局覆盖——10ms 连点多个 pending up 会互相覆盖
// 坐标/index，导致 down/up 错配、部分触摸永远收不到 up）。回调里 free。
typedef struct {
    double   x, y;
    uint32_t index;
} FTHIDUpCtx;

// 发送一次 up（延迟回调）——经系统 HID 服务派发
static void FTSendHIDUpCallback(void *ctx) {
    FTHIDUpCtx *c = (FTHIDUpCtx *)ctx;
    if (c) {
        // ⚠️ v1.0.131 修正（ctor(3) 实锤）：v1.0.129 的 gIsClicking 拦截在【顶掉循环】中
        // 把所有补发全拦了（自动重启连点让 gIsClicking 几乎一直 YES）→ 残留永远清不掉
        //（tap=66 → 小白条 8s）。v1.0.130 起 index 分配已跳过残留（位图 false → 不再
        // 占用）→ 补发安全。改为【index 占用检查】：位图又变 true = 新连点占用了该
        // index → 放弃；false = 残留 index 空闲 → 补发执行。
        if (c->index < 16 && g_PendingUpIdx[c->index]) { free(c); return; }
        FT_HIDDispatchUp(c->x, c->y, c->index);
        if (c->index < 16) {
            g_PendingUpIdx[c->index] = false; // v1.0.97：up 已派发，清除残留标记
            g_PendingUpT[c->index] = 0;       // v1.0.113：清 down 时刻
        }
        free(c);
    }
}

// ⚠️ v1.0.124：残留处理「移走」回调——对已存在的合成手指 index 注入同 index 的 down
//（zxtouch 移动语义：系统按 index 匹配已有手指并更新位置）→ 把残留手指从点击点移到
// 屏幕角落。即使后续 up 仍被系统吞掉，手指也已离开游戏按钮 → 停止持续触发/长按。
static void FTSendHIDMoveCallback(void *ctx) {
    FTHIDUpCtx *c = (FTHIDUpCtx *)ctx;
    if (c) {
        // v1.0.131：同 FTSendHIDUpCallback——gIsClicking 改「index 被占用」检查
        if (c->index < 16 && g_PendingUpIdx[c->index]) { free(c); return; }
        FT_HIDDispatchDown(c->x, c->y, c->index);
        free(c);
    }
}

// v1.0.108：探测 tap 的 up 已派发完成（HIDInject.c 回调）→ 清除残留位图 index=2
//（探测 tap 固定 index 2）。防残留合成手指堆积污染触摸状态 → 连点 down 不送达（空跑）。
// ⚠️ 必须 extern "C"——Tweak.xm 是 ObjC++（.mm），普通函数定义会被 C++ name-mangle
// 成 _Z18FT_ProbeUpDoneHookv，HIDInject.c（纯 C）引用的 _FT_ProbeUpDoneHook 找不到
//（CI 链接 Undefined symbols 实锤）。
extern "C" void FT_ProbeUpDoneHook(void) {
    g_PendingUpIdx[2] = false;
}

// 在屏幕像素点 (px,py) 发一次合成点击（down 立即 + up 延迟 50ms；每次 tap index 递增）
// 取当前界面方向（UIInterfaceOrientation：1=竖屏 2=竖屏倒 3=横屏左(home左) 4=横屏右(home右)）
static NSInteger FTGetOrientation(void) {
    // 优先用活跃 windowScene 的 interfaceOrientation（iOS 13+ 现代 API，最可靠）
    id scene = FTGetActiveWindowScene();
    if (scene) {
        NSInteger o = ((Msg_Int)objc_msgSend)(scene, sel_registerName("interfaceOrientation"));
        if (o >= 1 && o <= 4) return o;
    }
    // 兜底：UIApplication.statusBarOrientation
    Class ClsApp = objc_getClass("UIApplication");
    if (ClsApp) {
        id app = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
        if (app) {
            NSInteger o = ((Msg_Int)objc_msgSend)(app, sel_registerName("statusBarOrientation"));
            if (o >= 1 && o <= 4) return o;
        }
    }
    return 1; // 默认竖屏
}

// v1.0.86 定案：**恒透传**（恢复 v1.0.74 设计）。
// 证据链（ctor-56/58）：_UISystemGestureWindow bounds 恒=竖屏基准 834×1194（SB 用
// transform 旋转显示）；IOHID digitizer 归一化坐标按竖屏基准换算（注入 0.43,0.66 →
// 窗口 358.5,790.5 = 0.43×834, 0.66×1194，SEND 实测）；标记/球 frame 同在此空间
// （gScreenW/H 已锁竖屏基准）。注入透传 → SB 层命中标记 → 系统把触摸路由到 App 时与
// 标记显示共用同一旋转 → App 层同样命中。横竖屏都不需要额外换算。
// ⚠️ v1.0.84 的横屏缩放（nx=ox×W/H）是错的——它基于「gScreenW/H=方向尺寸」的错误前提，
// 与竖屏基准窗口冲突；v1.0.70 的旋转公式同样基于错误前提。
static void FTOrientForHID(double ox, double oy, double *nx, double *ny) {
    *nx = ox;
    *ny = oy;
}

static void FTSyntheticTap(double px, double py) {
    double ux = (gScreenW > 0) ? px / gScreenW : 0.5;
    double uy = (gScreenH > 0) ? py / gScreenH : 0.5;
    if (ux < 0.001) ux = 0.001; if (ux > 0.999) ux = 0.999;
    if (uy < 0.001) uy = 0.001; if (uy > 0.999) uy = 0.999;

    // 转换到 HID 原生竖屏坐标空间
    double nx = ux, ny = uy;
    FTOrientForHID(ux, uy, &nx, &ny);

    // 每次 tap 递增 index（v1.0.45：避免系统把连续注入事件串成同一触摸流）。
    // ⚠️ v1.0.95 关键修正：index 从 2 开始（2-9 循环）——旧代码 (gTapIndex%19)+1 首发 index=1，
    // 与用户按住球的手指 index(=1) 冲突 → 系统把注入 down 当「index 1 手指重复按下」→
    // 结束用户手指（touch ph=3 顶掉）→ 松手检测死 + 连点每 ~40 次断。避开 index=1 后
    // 注入成为「同源第二根手指」，系统不重置触摸上下文 → 用户手指全程 alive →
    // touchesEnded/Cancelled 真实 → 松手即停（豆包方案）与连点持续同时成立。
    // ⚠️ v1.0.130（ctor-27 实锤）：**分配 index 时跳过「仍待 up」的残留 index**——up 被吞
    // 的残留手指在系统里仍活跃，复用其 index 会让新 down 被系统当作「已有手指的移动」
    // → 无 Began 回流 → 游戏收不到新点击 + verify 窗口内无回流 → 好 SID 被误淘汰。
    // ⚠️ v1.0.132（ctor-29 实锤）：index 池 2-15（14 个）改回 **2-9 循环（8 个）**——
    // 14 根不同 index 手指同时活跃让系统触摸状态机超载（combo cleanup 11 + raise 14），
    // up 丢失加剧；8 指池是 v1.0.95-110 时代的稳定形态（配合 30ms 间隔残留已大幅减少）。
    // 从 gTapIndex 起循环找空位（最多 8 次），全满（8 根残留，极端）才兜底复用。
    uint32_t idx = 0;
    for (int r = 0; r < 8; r++) {
        uint32_t cand = (uint32_t)(((gTapIndex + (uint32_t)r) % 8) + 2);
        if (!g_PendingUpIdx[cand]) { idx = cand; gTapIndex = cand; break; }
    }
    if (idx == 0) {
        gTapIndex = (gTapIndex % 8) + 2;
        idx = gTapIndex;
    }
    if (idx < 16) {
        g_PendingUpIdx[idx] = true; // v1.0.97：记录待 up 的合成手指（停止时清场用）
        struct timespec tts;
        clock_gettime(CLOCK_MONOTONIC, &tts); // v1.0.113：记录 down 时刻（定期清残留判断）
        g_PendingUpT[idx] = (double)tts.tv_sec + (double)tts.tv_nsec * 1e-9;
    }

    // down 立即（系统级派发）
    FT_HIDDispatchDown(nx, ny, idx);
    // up 延迟（关联同一触摸）。v1.0.82：50ms → 15ms——10ms 连点 + 50ms 抬指 = 同时 5 根手指
    // 按着，图标/按钮被持续"按压高亮"（看起来像长按，ctor-55 用户反馈"桌面只触发长按效果"）。
    // ⚠️ v1.0.99：15ms → 25ms——ctor-71 实测每轮残留 4 根合成手指（up 被系统吞掉），
    // 25ms 抬指降低 up 丢失率（重叠 ~2.5 根仍可接受），配合 FTRaiseResidualUps 清场。
    // ⚠️ v1.0.109：25ms → 15ms——ctor(2) 实测每轮停止仍清 4 根残留（重叠 2.5 根 up 仍丢），
    // 游戏内残留 Stationary 手指导致视角跳屏 + 停止延迟感知。15ms 重叠 ~1.5 根，
    // up 丢失率大幅下降（v1.0.82 已验证 15ms 触摸可注册为 tap；v1.0.76 的"15ms 噪声"
    // 结论当时被悬停/senderID bug 混淆，现代结构已修正）。
    // ⚠️ v1.0.110：15ms → 25ms（回退）——ctor-6 实测 15ms 每轮只 11-13 次（100ms 宽限停）：
    // down(N+1) 紧贴 up(N)（10ms < 15ms）触发系统触摸上下文重置 → 顶掉用户手指 → 连点
    // 不连续。25ms 下 up 在 down 后从容发出（v1.0.108 实测 clicks 131 持续）。跳屏改由
    // FTRaiseResidualUps 串行补发（v1.0.110）解决，不再牺牲 up-delay。
    // ⚠️ v1.0.132：25ms → 35ms——配合间隔 30ms（铁律 up-delay > 间隔）：down(N+1) 在
    // up(N) 后 5ms 发出（无重叠）→ up 丢失率大降。35ms 下活跃手指 <1 根。
    // ⚠️ v1.0.134：35ms → 45ms——配合间隔 40ms（25Hz）：down(N+1) 仍在 up(N) 后 5ms，
    // 但频率低 → 每轮 up 数量少 → 丢失总数更少（ctor-31 每轮仍残留 6-8 个）。
    // 上下文按次 malloc，避免全局覆盖导致 down/up 错配。
    FTHIDUpCtx *c = (FTHIDUpCtx *)malloc(sizeof(FTHIDUpCtx));
    if (c) {
        c->x = nx; c->y = ny; c->index = idx;
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.045 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTSendHIDUpCallback);
    }
}

// v1.0.94：移除 v1.0.93 的「模拟手指」——它每 60ms 注入球心触摸让追踪持续重绑，
// 连点虽不断但【松手停不了】（只能双击停，用户拒绝）。v1.0.94 改注入 zxtouch 官方
// senderID 0x8000... + digitizer SenderID 字段（0x0B0018），目标是不顶掉用户手指 →
// 用户手指全程 alive → 松手 touchesEnded 真实到达 → Ended/Cancelled 即停（豆包方案）。

// MARK: - SB 端注入（v1.0.62 起走系统 HID 服务，可命中前台 App）
// v1.0.62：改为 IOHIDEventSystemClientDispatchEvent 系统级派发（HIDInject.c 的
// FT_HIDDispatchDown/Up），事件由系统路由到前台 App——游戏内点击也有效。
// 旧版（v1.0.41~61）用 SpringBoard 的 UIApplication._handleHIDEvent: 只喂 SB 自身 UI 队列，
// 前台 App 收不到 → 注入日志有、但无点击反馈。

// 连点回调：在点击点标记坐标发一次合成点击。
// v1.0.70：不再把球设为 alpha=0——实测 iOS 15.5 下改 alpha 会让长按手势被判 Cancelled，
// 导致连点定时器被立刻取消（只点 1 下就停、10s 仅数下）。
// ⚠️ v1.0.88 验证实验（ctor-60）：合成触摸只到 _UISystemGestureWindow、不透传前台 App
// （SEND 全 win=手势窗口，备忘录无笔点、计数器 0）。v1.0.86/87 注入坐标精确命中标记后
// 反而不透传（v1.0.85 注入偏离标记、落在空白时反而有效）→ 怀疑手势窗口把落在自身
// subview（标记/红圈）上的触摸「收口」不路由。连点期间把标记+红圈 alpha=0（不参与
// hitTest），验证注入是否恢复透传。
static void FTClickCallback(void *ctx) {
    (void)ctx;
    if (!gBallView || !gIsClicking) return;
    // ⚠️ v1.0.128 定案（ctor-25 实锤）：幽灵看门狗必须配合松手宽限，不能抢跑！
    // v1.0.127 的 `if (gBallTouch == NULL) FTStopClicking("ghost-guard")` 把「高频顶掉」
    //（touches-ended 到达 → gBallTouch 清空 + 50ms 宽限已排，用户手指物理还在等重绑）
    // 误判为「用户松手」→ 10ms 内抢跑停止 → 连点每轮 46 次恶化到 2 次 → 频繁停止又
    // 加剧残留 → 恶性循环（ctor-25 日志 ghost-guard 刷屏 + clicks: 2）。
    // 修复：宽限已排（gStopGracePending）说明 touches-ended 走正常停止/重绑路径 →
    // 看门狗不干预；只有「gBallTouch==NULL 且无宽限」的异常（几乎不发生）才兜底停止。
    // 幽灵连点（Ended 丢失、gBallTouch 残留非空）本就不触发此分支，由 v1.0.127 的
    // Ended 双条件（指针匹配 OR 100px）兜底。
    if (gBallTouch == NULL && !gStopGracePending) {
        FTStopClicking("ghost-guard");
        return;
    }

    FTSyntheticTap(gClickLockX * gScreenW, gClickLockY * gScreenH);
    gClickCount++;

    // v1.0.88：红圈保持隐藏（验证 subview 遮挡假说）——点击恢复后再恢复光圈显示
    // if (gClickFlashView) {
    //     ((Msg_SetFrame)objc_msgSend)(gClickFlashView, sel_registerName("setFrame:"),
    //         CGRectMake(gClickLockX * gScreenW - 13, gClickLockY * gScreenH - 13, 26, 26));
    //     ((Msg_SetAlpha)objc_msgSend)(gClickFlashView, sel_registerName("setAlpha:"), 1.0);
    // }

    double hx = gClickLockX, hy = gClickLockY;
    FTOrientForHID(gClickLockX, gClickLockY, &hx, &hy);
    // 节流：每 ~25 次点击（约 250ms@10ms）打一条，避免日志被刷爆
    static int sTapLogCount = 0;
    if ((sTapLogCount++ % 25) == 0) {
        char diag[160];
        snprintf(diag, sizeof(diag), "inject tap uik=%.2f,%.2f hid=%.2f,%.2f orient=%ld",
                 gClickLockX, gClickLockY, hx, hy, (long)FTGetOrientation());
        FTLog(diag);
    }
    // v1.0.113：连点期间定期清残留——防残留合成手指累积
    // （ctor-9：SBHomeScreenWindow 残留 tap 40→481 → 小白条失效 + 游戏长按 + tapCount 累积）
    // ⚠️ v1.0.122：每 50 次 → 每 25 次（≈250ms）——ctor-19 残留 tap=799/91 持续 3-8s，
    // 50 次的窗口太长，残留先累积到影响小白条才清。加密后残留峰值更低、小白条更稳。
    static int sResidualCheck = 0;
    if ((sResidualCheck++ % 25) == 0) {
        FTCheckResidualDuringCombo();
    }
}

// 诊断：dump UIEvent 的 ivar 名（已确认有 _hidEvent/_gsEvent）
static void FTDumpEventIvars(void) {
    Class ClsEvent = objc_getClass("UIEvent");
    if (!ClsEvent) return;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(ClsEvent, &count);
    if (!ivars) { FTLog("UIEvent ivar dump: none"); return; }
    char buf[768];
    size_t off = 0;
    int w = snprintf(buf, sizeof(buf), "UIEvent ivars:");
    if (w > 0) off = (size_t)w;
    for (unsigned int i = 0; i < count && off + 96 < sizeof(buf); i++) {
        const char *name = ivar_getName(ivars[i]);
        if (name) {
            int n = snprintf(buf + off, sizeof(buf) - off, " %s", name);
            if (n > 0) off += (size_t)n;
        }
    }
    free(ivars);
    FTLog(buf);
}

// v1.0.75：按「连点中 / 模式」统一启停全部手势识别器。
// ⚠️ 关键修复：连点期间【禁用全部 GR】——否则任何 GR（双击/长按/拖动，含合成点击落在
// 标记/球上的情况）都可能把按住球的手指判 Cancelled(phase=4) 或触发双击 → 连点刚启动就
// 被 FTStopClicking 掐断（"长按只算一次"，ctor-45/46 反复出现）。用户连点时按着球，本就不需要双击。
static void FTApplyGRModes(void) {
    if (!gTapGR || !gLongGR || !gPanGR) return;
    ((Msg_SetEnabled)objc_msgSend)(gTapGR,  sel_registerName("setEnabled:"), gIsClicking ? NO : YES);
    ((Msg_SetEnabled)objc_msgSend)(gTapGR2, sel_registerName("setEnabled:"), gIsClicking ? NO : (gClickPointView ? YES : NO));
    ((Msg_SetEnabled)objc_msgSend)(gLongGR, sel_registerName("setEnabled:"), gIsClicking ? NO : (!gDragMode ? YES : NO));
    ((Msg_SetEnabled)objc_msgSend)(gPanGR,  sel_registerName("setEnabled:"), gIsClicking ? NO : (gDragMode ? YES : NO));
    ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setEnabled:"), gIsClicking ? NO : (gDragMode ? YES : NO));
}

// v1.0.99：清残留合成手指（定义在 FTStopClicking 之前；FTStartClicking 先调用需前向声明）
static void FTRaiseResidualUps(void);

// v1.0.48：SB 端恢复直接注入（不再写任务文件）。坐标锁定 = App 配置点（v1.0.50）
// 或长按开始时球心（无配置时）。
// v2.0：连点注入优先走独立 daemon（floatingtapd）——daemon 在独立进程内注入，
// 不参与 SB 手势窗口路由、用真实 digitizer SID → 不顶掉用户手指 → 无需探测。
static void FTStartClicking(void) {
    if (gIsClicking) return;
    // v2.0：daemon 可用时走 daemon 注入（一碰即点，无 SB 端探测/残留开销）
    if (FTDaemonProbe() == 1) {
        gIsClicking = YES;
        gClickCount = 0;
        if (gClickLockX < 0.001) gClickLockX = 0.001; if (gClickLockX > 0.999) gClickLockX = 0.999;
        if (gClickLockY < 0.001) gClickLockY = 0.001; if (gClickLockY > 0.999) gClickLockY = 0.999;
        double ms = FTIntervalMs();
        FTDaemonStartClicking(gClickLockX, gClickLockY, ms);
        FTApplyGRModes();
        FTLog("clicking started via daemon");
        return;
    }
    if (!FT_HIDConnect()) {
        FTLog("clicking failed: HID connect failed");
        return;
    }
    gIsClicking = YES;
    gClickCount = 0;
    gTapIndex = 0;
    // v1.0.99：开始前清上一轮残留合成手指（防跨轮积累干扰本轮注入）
    FTRaiseResidualUps();
    // 点击点 = gClickLockX/Y（由点击点标记拖动 / App 配置设定，与球位置解耦）。
    // 这里只做归一化钳制，不再把点击点锁回球心——否则「点击点独立于球」的设计失效。
    if (gClickLockX < 0.001) gClickLockX = 0.001; if (gClickLockX > 0.999) gClickLockX = 0.999;
    if (gClickLockY < 0.001) gClickLockY = 0.001; if (gClickLockY > 0.999) gClickLockY = 0.999;
    double ms = FTIntervalMs();
    // 一碰到球立即点一次（不等第一个 timer tick，短按也有一次点击）
    FTClickCallback(NULL);
    gClickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gClickTimer) {
        dispatch_source_set_timer(gClickTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                                  (uint64_t)(ms * NSEC_PER_MSEC), 0);
        dispatch_source_set_event_handler_f(gClickTimer, FTClickCallback);
        dispatch_resume(gClickTimer);
    }
    // v1.0.75：连点中禁用全部手势识别器（防 GR 取消手指/触发双击掐断连点）
    FTApplyGRModes();
    // v1.0.112：连点送达自愈验证——窗口内 SEND 无合成触摸回流 → 锁定 SID 假送达
    // → FTVerifyDeliveryTimer 停止连点 + 记录跳过 + 自动重新探测（防空跑）
    // ⚠️ v1.0.119：窗口 300→800ms——承载「高频稳定性验证」（g_StabTesting）。
    // ⚠️ v1.0.125：800→300ms（ctor-22 会话无稳定 SID，800ms 全淘汰 → 一直变不了蓝）。
    // ⚠️ v1.0.127 定案（ctor-23/24 + 用户「123 最好」）：800→300→**800ms**——严格验证
    // 淘汰「高频顶掉」SID 后锁定的连点最稳定（ctor-21 0x7b2 119 次 / ctor-24 0x716
    // 729 次）；「一直变不了蓝」由「连续 stab-fail ≥3 次 → 强制锁定跳过验证」
    //（g_StabForceLock）兜底——正常会话 800ms 找稳定 SID，差会话快速锁保底。
    // ⚠️ v1.0.129：epoch 绑定——每轮 started 递增，定时器 ctx 携带快照；到期时
    // epoch 不匹配（已有新一轮 started）→ 旧轮定时器丢弃，不再误判「新轮 not delivering」
    //（ctor-26 实锤：快速短按时旧轮定时器把刚 started 的新轮判 fail → 好 SID 误淘汰）。
    g_VerifyEpoch++;
    g_VerifyDelivering = YES;
    g_VerifySawSynthetic = NO;
    g_VerifySawCount = 0; // v1.0.135：每轮重置送达回流计数（顶掉检测用）
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), (void *)(intptr_t)g_VerifyEpoch,
                     FTVerifyDeliveryTimer);
    // v1.0.88 验证：连点期间隐藏点击点标记（alpha=0 不参与 hitTest）——
    // 怀疑手势窗口把落在自身 subview（标记/红圈）上的注入触摸「收口」不透传 App
    if (gClickPointView) {
        ((Msg_SetAlpha)objc_msgSend)(gClickPointView, sel_registerName("setAlpha:"), 0.0);
    }
    FTLog("clicking started");
}

// v1.0.97/99：清残留合成手指——对【仍残留】的 index（down 已发但 up 被系统吞掉）在点击点
// 补发 up。ctor-69 铁证：10ms 连点 + 短 up-delay 下部分 up 丢失 → 合成手指永久按着屏幕
// （SEND phase=2 Stationary 持续 5s）→ Home indicator（小白条）上滑失效、息屏才恢复；
// 且残留跨轮积累会干扰下一次连点（ctor-71：每轮残留 4 根）。只抬【有匹配 down 的残留
// index 2-9】（永不碰用户手指 index=1），坐标用点击点（残留手指实际位置）——最安全清场。
// v1.0.99：FTStartClicking + FTStopClicking 都调用（开始清上一轮残留、停止清本轮残留）。
// v1.0.110：串行补发——一次性 dispatch 多个 up 会被系统合并/丢弃，残留手指清不掉
// → 停止后游戏仍看到点击点有手指按着（视角跳屏，ctor(2) 用户反馈）；逐个间隔 25ms
// 延迟发出，确保每个 up 都被系统独立处理、全部送达。
static void FTRaiseResidualUps(void) {
    double rx = gClickLockX, ry = gClickLockY;
    if (rx < 0.001) rx = 0.001; if (rx > 0.999) rx = 0.999;
    if (ry < 0.001) ry = 0.001; if (ry > 0.999) ry = 0.999;
    uint32_t pend[14];
    int np = 0;
    for (uint32_t i = 2; i < 16; i++) {
        if (g_PendingUpIdx[i]) {
            g_PendingUpIdx[i] = false;
            if (np < 14) pend[np++] = i;
        }
    }
    if (np > 0) {
        // ⚠️ v1.0.124 定案（ctor-19/20/21 实锤）：停止后补发 up 一直无效（立即/串行/
        // 延迟 150ms/x2 全被系统吞）——残留合成手指 Stationary 持续数秒 → 全自动枪
        // 持续开火 + 小白条失效（用户：绿圈出现=已停止，枪还在开）。根因：up 事件
        // 可能被系统当作「同一手指的重复抬起」忽略。
        // ⚠️ v1.0.130（ctor-27/29/30/31 实锤）：move 角落 + up 角落 + up 点击点 500ms/1s
        // 全部无效——残留 Stationary 持续 tap 累积（61→224）→ 小白条 + 残留堆积到
        // 几十根 → 系统触摸崩溃 → 后半段每轮 4 次顶掉（「前面测得好好的后面失效」）。
        // 残留是系统 UIEvent 层幻影（up 补发时系统已无该手指上下文 → 忽略）。
        // **v1.0.134 换思路：先「重建上下文」再「抬起」**——对每个残留 index 先注入
        // 同 index 的 down 到【点击点】（系统重新建立该 index 手指上下文 = 位置更新），
        // 30ms 后再同位置 up（有 down 上下文支撑的 up 系统才接受）。500ms/1s 各补一次
        // up（残留若未抬，系统稳定后再试）。不再发角落（角落 down 被当新手指，无效）。
        for (int k = 0; k < np; k++) {
            FTHIDUpCtx *d = (FTHIDUpCtx *)malloc(sizeof(FTHIDUpCtx));
            if (d) {
                d->x = rx; d->y = ry; d->index = pend[k];
                dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.03 + (double)k * 0.02) * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), NULL, FTSendHIDMoveCallback);
            }
            FTHIDUpCtx *u = (FTHIDUpCtx *)malloc(sizeof(FTHIDUpCtx));
            if (u) {
                u->x = rx; u->y = ry; u->index = pend[k];
                dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.06 + (double)k * 0.02) * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), NULL, FTSendHIDUpCallback);
            }
            // 残留真实位置 up——500ms 与 1000ms 各一次（系统稳定后补抬，成功率更高）
            FTHIDUpCtx *c1 = (FTHIDUpCtx *)malloc(sizeof(FTHIDUpCtx));
            if (c1) {
                c1->x = rx; c1->y = ry; c1->index = pend[k];
                dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + (double)k * 0.02) * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), NULL, FTSendHIDUpCallback);
            }
            FTHIDUpCtx *c2 = (FTHIDUpCtx *)malloc(sizeof(FTHIDUpCtx));
            if (c2) {
                c2->x = rx; c2->y = ry; c2->index = pend[k];
                dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.0 + (double)k * 0.02) * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), NULL, FTSendHIDUpCallback);
            }
        }
        char dbg2[96];
        snprintf(dbg2, sizeof(dbg2), "raise residual synthetic ups: %d (rebuild-ctx: down+up @click-pt, 30/60/500/1k ms)", np);
        FTLog(dbg2);
    }
}

// ⚠️ v1.0.130：连点期清残留专用 up 回调——**不检查 gIsClicking**（v1.0.129 的
// FTSendHIDUpCallback 加了 gIsClicking 拦截 → FTCheckResidualDuringCombo 在连点中
// 调用时补发全被拦 → 连点期残留清理失效，ctor-27 残留越积越多）。连点期补发的
// up 抬的是残留 index（已清出 g_PendingUpIdx，v1.0.130 分配不再复用）→ 不冲突。
static void FTSendHIDUpNoGuardCallback(void *ctx) {
    FTHIDUpCtx *c = (FTHIDUpCtx *)ctx;
    if (c) {
        FT_HIDDispatchUp(c->x, c->y, c->index);
        free(c);
    }
}

// v1.0.113：连点期间定期清残留——只补发「down 超阈值仍未 up」的 index（正常 25ms up
// 不受影响）。防残留合成手指累积（ctor-9 铁证：SBHomeScreenWindow 残留 tap 累积 40→481
// → 小白条失效 + 游戏长按效果持续 + tapCount 无限累积）。串行补发（逐个 25ms 间隔）。
// 由 FTClickCallback 每 ~25 次点击（约 375ms）调用一次。
// ⚠️ v1.0.126（ctor-23 实锤）：阈值 150ms → 50ms——探测 tap 的 up（25ms 延迟）丢失后
// 残留 Stationary 会污染后续探测（0x716 送达但 phase=1 被 miss → 全扫 50s 白扫）。
// 50ms 未 up = 已丢失（正常 up 25ms 内必到），立即补发防累积。
static void FTCheckResidualDuringCombo(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    uint32_t pend[14];
    int n = 0;
    for (uint32_t i = 2; i < 16; i++) {
        if (g_PendingUpIdx[i] && g_PendingUpT[i] > 0 && (now - g_PendingUpT[i]) > 0.05) {
            g_PendingUpIdx[i] = false;
            g_PendingUpT[i] = 0;
            if (n < 14) pend[n++] = i;
        }
    }
    if (n > 0) {
        double rx = gClickLockX, ry = gClickLockY;
        if (rx < 0.001) rx = 0.001; if (rx > 0.999) rx = 0.999;
        if (ry < 0.001) ry = 0.001; if (ry > 0.999) ry = 0.999;
        for (int k = 0; k < n; k++) {
            FTHIDUpCtx *c = (FTHIDUpCtx *)malloc(sizeof(FTHIDUpCtx));
            if (c) {
                c->x = rx; c->y = ry; c->index = pend[k];
                dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((double)k * 0.025 * NSEC_PER_SEC)),
                                 dispatch_get_main_queue(), NULL, FTSendHIDUpNoGuardCallback);
            }
        }
        char dbg2[96];
        snprintf(dbg2, sizeof(dbg2), "combo residual cleanup: %d", n);
        FTLog(dbg2);
    }
}

// v1.0.75：FTStopClicking 带停止原因（诊断用），并在停止后按模式恢复手势
static void FTStopClicking(const char *reason) {
    if (!gIsClicking) return;
    gIsClicking = NO;
    gStopGracePending = NO; // 取消任何待决的松手宽限
    // v2.0：daemon 路径 → 通知 daemon 停止，恢复手势，无需 SB 端残留清理
    if (g_DaemonProbed && g_DaemonMode == 1) {
        FTDaemonStopClicking();
        FTApplyGRModes();
        char dbgD[96];
        snprintf(dbgD, sizeof(dbgD), "clicking stopped via daemon (%s)", reason ? reason : "?");
        FTLog(dbgD);
        return;
    }
    // ⚠️ v1.0.132（ctor-29 实锤）：touches-ended 停止【保留 verify】——让定时器到期裁决
    // 「该轮是否有送达回流」（g_VerifySawSynthetic）：顶掉循环（无回流）→ 淘汰 SID；
    // 快速短按（有回流）→ 保持锁定。v1.0.129 epoch 保护：用户松手后 0.8s 内重按 →
    // 新一轮 started 递增 epoch → 旧定时器丢弃，不误判。非松手停止（dbl-tap 等）才取消。
    if (reason && strcmp(reason, "touches-ended") == 0) {
        if (g_StabTesting) g_StabFail = YES; // stab 验证期顶掉标记（计数兜底）
        // ⚠️ v1.0.133（ctor-30 实锤）：**touches-ended 立即裁决**——本轮 started 后
        // 送达异常且点击 ≥3 次 = 顶掉循环/空跑（注入被系统吞）→ 淘汰 SID。不能依赖
        // 0.8s verify 定时器：顶掉循环中自动重启连点（重绑 <0.8s + 120ms 计时器）
        // 不断递增 epoch → 定时器永远被丢弃 → 永不裁决（ctor-30 每轮 7 次顶掉）。
        // ⚠️ v1.0.135（ctor-32 实锤）：「有无回流」判不出顶掉型（每轮也有部分 down
        // 送达 → 有回流但 <50%）。改【回流比例】：g_VerifySawCount*2 < gClickCount
        // = 回流 <50% → 顶掉/空跑 → 淘汰。稳定轮（244 次）回流 >90% 保持；快速短按
        //（注入正常）回流 ~100% 保持；clicks<3 极短轻点豁免。
        if (g_LockedSID != 0 && !g_Probing && gClickCount >= 3 &&
            g_VerifySawCount * 2 < gClickCount) {
            char dbg3[96];
            snprintf(dbg3, sizeof(dbg3), "evict: low return ratio %d/%lu (high-freq ender)", g_VerifySawCount, (unsigned long)gClickCount);
            FTLog(dbg3);
            bool dup = false;
            for (int k = 0; k < g_ProbeEndingCount; k++) {
                if (g_ProbeEndingSIDs[k] == g_LockedSID) { dup = true; break; }
            }
            if (!dup && g_ProbeEndingCount < 64) {
                g_ProbeEndingSIDs[g_ProbeEndingCount++] = g_LockedSID;
            }
            g_VerifyFailCount = 0;
            g_LockedSID = 0;
            FT_HIDLockSenderID(0);
            if (g_ProbeLockIdx > 0) {
                g_ProbeIdx = g_ProbeLockIdx;
                g_ProbeFullScan = YES;
                char dbg2[96];
                snprintf(dbg2, sizeof(dbg2), "evict: resume full scan from %d/768", g_ProbeIdx);
                FTLog(dbg2);
            }
            FTStartProbing(); // 手指物理还在（顶掉场景）→ 续扫下一个；已松手 → 等手指回蓝
        }
    } else {
        g_VerifyDelivering = NO; // v1.0.112：非松手停止取消送达验证
    }
    if (gClickTimer) {
        dispatch_source_cancel(gClickTimer);
        gClickTimer = NULL;
    }
    if (gClickFlashView) {
        ((Msg_SetAlpha)objc_msgSend)(gClickFlashView, sel_registerName("setAlpha:"), 0.0); // 灭光圈
    }
    // v1.0.88：恢复标记可见（连点期间被隐藏以验证 subview 遮挡假说）
    if (gClickPointView) {
        ((Msg_SetAlpha)objc_msgSend)(gClickPointView, sel_registerName("setAlpha:"), 1.0);
    }
    // v1.0.97/99：停止时清本轮残留合成手指（防小白条失效 + 残留跨轮积累干扰下次连点）
    FTRaiseResidualUps();
    FTApplyGRModes(); // 恢复手势（按当前模式启用对应 GR）
    char dbg[128];
    snprintf(dbg, sizeof(dbg), "clicking stopped (%s)", reason ? reason : "?");
    FTLog(dbg);
    char buf[96];
    snprintf(buf, sizeof(buf), "clicks this period: %lu", gClickCount);
    FTLog(buf);
}

// MARK: - 动态 GR target（运行时创建类，零静态 ObjC 元数据）

static Class gGRTargetClass = nil;
static id    gGRTarget      = nil;

// Long 回调：仅「蓝色连击模式」生效——一碰即连点（点击点锁在按下时球心，拖动不改变）。
// 「红色拖动模式」下长按无效（拖动由 Pan GR 负责），避免双击切换与连点冲突。
static void FTGRLongHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd; (void)gr;
    // v1.0.71：长按连点改由 sendEvent hook 按「触摸身份」追踪驱动（免疫游戏多点触摸 / 合成触摸取消），
    // 此处留空，仅保留 gLongGR 实例供 double-tap / pan 的 requireGestureRecognizerToFail 依赖。
}

// Pan 回调：仅「红色拖动模式」生效——拖动小球重新定位（点击点独立，不受影响）。
// 连击模式下忽略，保证长按只连点、拖动只定位，互不干扰。
static void FTGRPanHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr || !gBallView) return;
    if (!gDragMode) return; // 连击模式：不响应拖动
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 1) { // Began
        gPanStartLoc = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gBallView);
        gPanOrigin0  = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame")).origin;
    } else if (st == 2) { // Changed → 拖动球
        CGPoint cur = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gBallView);
        CGRect f = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
        ((Msg_SetFrame)objc_msgSend)(gBallView, sel_registerName("setFrame:"),
            CGRectMake(gPanOrigin0.x + (cur.x - gPanStartLoc.x),
                       gPanOrigin0.y + (cur.y - gPanStartLoc.y),
                       f.size.width, f.size.height));
    }
}

// 点击点拖动：仅「红色拖动模式」生效——拖动点击点标记，更新连点坐标（与球独立）。
// 连击模式下 gClickPointView 不可交互，此 GR 被禁用，标记只作位置指示。
static void FTGRClickPanHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr || !gClickPointView) return;
    if (!gDragMode) return; // 连击模式：不响应点击点拖动
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 1) { // Began
        gClickPanStartLoc = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gClickPointView);
        gClickPanOrigin0  = ((Msg_Frame)objc_msgSend)(gClickPointView, sel_registerName("frame")).origin;
    } else if (st == 2) { // Changed → 拖动点击点
        CGPoint cur = ((Msg_LocationInView)objc_msgSend)(gr, sel_registerName("locationInView:"), gClickPointView);
        CGRect f = ((Msg_Frame)objc_msgSend)(gClickPointView, sel_registerName("frame"));
        ((Msg_SetFrame)objc_msgSend)(gClickPointView, sel_registerName("setFrame:"),
            CGRectMake(gClickPanOrigin0.x + (cur.x - gClickPanStartLoc.x),
                       gClickPanOrigin0.y + (cur.y - gClickPanStartLoc.y),
                       f.size.width, f.size.height));
        CGRect nf = ((Msg_Frame)objc_msgSend)(gClickPointView, sel_registerName("frame"));
        if (gScreenW > 0 && gScreenH > 0) {
            gClickLockX = (nf.origin.x + nf.size.width * 0.5) / gScreenW;
            gClickLockY = (nf.origin.y + nf.size.height * 0.5) / gScreenH;
            if (gClickLockX < 0.001) gClickLockX = 0.001; if (gClickLockX > 0.999) gClickLockX = 0.999;
            if (gClickLockY < 0.001) gClickLockY = 0.001; if (gClickLockY > 0.999) gClickLockY = 0.999;
        }
    }
}

// 根据模式刷新小球外观：蓝色=连击模式，红色=拖动模式，橙色=探测校准中，紫色=需要主屏 SID
static void FTApplyBallAppearance(void) {
    if (!gBallView) return;
    Class ClsColor = objc_getClass("UIColor");
    if (!ClsColor) return;
    CGFloat r, g, b, a;
    if (g_ProbeNeedMain) { r = 0.6; g = 0.0; b = 1.0; a = 0.9; } // 紫（需点屏幕别处）
    else if (g_Probing) { r = 1.0; g = 0.6; b = 0.0; a = 0.9; }     // 橙（SID 校准中）
    else if (gDragMode) { r = 1.0;  g = 0.231; b = 0.188; a = 0.9; }  // 红（拖动模式）
    else           { r = 0.0;  g = 0.478; b = 1.0;   a = 0.9; }  // 蓝（连击模式）
    id color = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor,
        sel_registerName("colorWithRed:green:blue:alpha:"), r, g, b, a);
    if (color) ((Msg_SetBackgroundColor)objc_msgSend)(gBallView, sel_registerName("setBackgroundColor:"), color);
}

// 点击点标记外观：拖动模式（红）高亮橙、可拖动；连击模式（蓝）暗显绿（仅指示点击位置、不挡触摸）
static void FTApplyClickPointAppearance(void) {
    if (!gClickPointView) return;
    Class ClsColor = objc_getClass("UIColor");
    if (!ClsColor) return;
    CGFloat r, g, b;
    if (gDragMode) { r = 1.0;  g = 0.84; b = 0.0; }   // 橙（可拖动）
    else           { r = 0.2;  g = 1.0;  b = 0.4; }   // 绿（暗显指示）
    id color = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor,
        sel_registerName("colorWithRed:green:blue:alpha:"), r, g, b, 1.0);
    id layer = ((Msg_Layer)objc_msgSend)(gClickPointView, sel_registerName("layer"));
    ((Msg_SetCGFloat)objc_msgSend)(layer, sel_registerName("setBorderWidth:"), (CGFloat)(gDragMode ? 3.5 : 2.5));
    ((Msg_SetBorderColor)objc_msgSend)(layer, sel_registerName("setBorderColor:"),
                                       ((Msg_CGColor)objc_msgSend)(color, sel_registerName("CGColor")));
    id dot = ((Msg_ViewWithTag)objc_msgSend)(gClickPointView, sel_registerName("viewWithTag:"), (NSInteger)101);
    if (dot) ((Msg_SetBackgroundColor)objc_msgSend)(dot, sel_registerName("setBackgroundColor:"), color);
}

// v1.0.73：按下球 120ms 后的延时计时器回调——静止按住时 iOS 不投递 Moved/Stationary 事件，
// 不能靠它们触发连点，改用此计时器。到时若手指仍按着（gBallTouch 未清空 = 同一根手指没抬起）
// 且非拖动模式：已锁定有效 SID → 直接连点；未锁定（v1.0.101）→ 进入 SID 自动探测校准。
static void FTBallHoldTimer(void *ctx) {
    (void)ctx;
    gBallTouchTimerPending = NO;
    if (gBallTouch != NULL && !gBallTouchClicking && !gDragMode) {
        // ⚠️ v1.0.119：stab 裁决前不重启连点——顶掉后重绑会再次触发本计时器，若 SID
        // 高频顶掉会反复「连点→顶掉→重启」（ctor-16 每轮 8 次循环）。等 0.8s 裁决
        // （stab-fail 续扫 or 稳定通过）后再动作。
        if (g_StabTesting && g_StabFail) return;
        if (g_LockedSID != 0) {
            gBallTouchClicking = YES;
            FTStartClicking();
        } else {
            FTStartProbing(); // 第一次按住：探测校准有效 SID（球变橙色）
        }
    }
}

// v1.0.101：构建 SID 候选集（去重）——g_MainSID（当前会话主屏触摸 SID）+ 全部 captured
// 候选 + 历史有效值（0x100000709/7ad，曾出真实点击）。有效 SID 大概率是会话内某次触摸
// 出现过的值，故候选集覆盖即可探测到。
static void FTBuildProbeCandidates(void) {
    g_ProbeSIDCount = 0;
    uint64_t v = FT_HIDGetMainSID();
    if (v) g_ProbeSIDs[g_ProbeSIDCount++] = v;
    int nc = FT_HIDGetCapturedCount();
    for (int i = 0; i < nc && g_ProbeSIDCount < 10; i++) {
        v = FT_HIDGetCapturedAt(i);
        if (!v) continue;
        bool dup = false;
        for (int j = 0; j < g_ProbeSIDCount; j++) {
            if (g_ProbeSIDs[j] == v) { dup = true; break; }
        }
        if (!dup) g_ProbeSIDs[g_ProbeSIDCount++] = v;
    }
    uint64_t hist[] = { 0x100000709ULL, 0x1000007adULL, 0x1000007afULL, 0x1000006f0ULL };
    for (int k = 0; k < 4 && g_ProbeSIDCount < 10; k++) {
        v = hist[k];
        bool dup = false;
        for (int j = 0; j < g_ProbeSIDCount; j++) {
            if (g_ProbeSIDs[j] == v) { dup = true; break; }
        }
        if (!dup) g_ProbeSIDs[g_ProbeSIDCount++] = v;
    }
    char dbg[96];
    snprintf(dbg, sizeof(dbg), "probe candidates: %d", g_ProbeSIDCount);
    FTLog(dbg);
}

// 开始探测（v1.0.103：每次重建候选集——用户点过屏幕别处后 g_MainSID 更新，必须重新纳入。
// v1.0.105：全扫模式下保留 g_ProbeIdx 进度（顶掉后重按继续扫描，不从头来）。
// v1.0.106：按住一次自动连续扫描——顶掉/不送达都自动试下一个，不再要求每次重按）
static void FTStartProbing(void) {
    if (g_Probing) return;
    // ⚠️ v1.0.118：确保 HID client 已建立——探测 tap 注入前必须 connect，否则
    // FT_HIDProbeTapDelayed 因 g_hidClient==NULL 静默丢弃全部 tap（ctor-15 实锤：
    // 首轮全扫 768 零送达零顶掉 = 注入从未发生；第二轮因有残留触发 connect 立见
    // 注入生效）。旧代码只在 FTRaiseResidualUps 有残留、或连点时才会 connect。
    if (!FT_HIDConnect()) {
        FTLog("probing aborted: HID connect failed");
        return;
    }
    // ⚠️ v1.0.116：点击点与球重叠保护（ctor-13 全扫 768 零送达的根因）——距离 <120px
    // （球直径 56 + 边距）时，注入到点击点的合成触摸会被球（可交互手势窗口 subview）
    // 拦截，任何 SID 都不会送达。紫球提示先拖动点击点/球分离，不再浪费 ~49s 全扫。
    if (gBallView) {
        CGRect bf = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
        double bcx = bf.origin.x + bf.size.width * 0.5;
        double bcy = bf.origin.y + bf.size.height * 0.5;
        double ddx = gClickLockX * gScreenW - bcx;
        double ddy = gClickLockY * gScreenH - bcy;
        if (ddx * ddx + ddy * ddy < 120.0 * 120.0) {
            g_ProbeNeedMain = YES;
            FTApplyBallAppearance();
            FTLog("click-point overlaps ball; drag click-point away from ball, then retry");
            return;
        }
    }
    FTBuildProbeCandidates();
    g_Probing = YES;
    if (!g_ProbeFullScan) g_ProbeIdx = 0; // 全扫中保留进度
    g_ProbeNoFingerT0 = 0;   // v1.0.121：新探测会话重置「等手指」计时
    g_ProbeTouchEnded = NO;
    g_ProbeDelivered = NO;
    g_ProbeTapT0 = 0;            // v1.0.107：清注入时刻
    g_ProbeFingerDead = NO;      // v1.0.108：新探测会话，手指按着 = 活着
    g_ProbeDeliveredSID = 0;     // v1.0.108：清保底
    // v1.0.108：探测开始前清上一轮残留合成手指（探测 tap up 丢失会堆积 → 污染系统触摸
    // 状态 → 连点 down 不送达 → 空跑，ctor(1)(1) 实锤 tap=3/28/43/71 残留）
    FTRaiseResidualUps();
    g_ProbeNeedMain = NO; // 重新探测时清除紫色提示
    FTApplyBallAppearance(); // 橙色 = 校准中
    FTLog("probing: looking for a working senderID (auto-continue on fail)");
    FTProbeNext();
}

// 注入下一个候选 SID 的探测 tap，稍后检查结果。
// v1.0.105：候选（≤10）耗尽后自动进入【全扫】模式——遍历 0x100000700-0x1000007ff，
// 跳过已验证「顶掉用户手指」的 SID；每 SID 200ms（送达/顶掉信号均在内），找到即停。
// v1.0.111：全扫范围扩到 0x100000600-0x1000008ff（768 个）——有效 SID 会话随机，
// 可能落在 6xx/8xx 段（ctor-7 实测 7xx 全扫 256 个仅 2 个送达型、无 A 类 → 变不了蓝）；
// 检查窗口 80ms→60ms（Began 回流 10-30ms，顶掉信号 <60ms 内）；分段进度日志。
// v1.0.121：FTProbeNext 的「等手指」延时重查回调（dispatch_after_f 需要 void(*)(void*) 签名）
static void FTProbeNextWaitCB(void *ctx) {
    (void)ctx;
    FTProbeNext();
}

static void FTProbeNext(void) {
    if (!g_Probing) return;
    // ⚠️ v1.0.121：用户手指不在球上（顶掉未重绑 / 真松手）→ 等手指重绑或再按再注入。
    // 顶掉续扫后手指未重绑时盲目注入探测 tap 没有意义（v1.0.120 的「等重绑裁决」
    // 被 0.7~1.7s 重绑延迟击穿 → 0x7b1 死循环，ctor-18 实锤）。等 250ms 重查；
    // 超过 5s 无手指 → 停止探测回蓝（防真松手后空扫 46s 到紫）。
    if (gBallTouch == NULL) {
        struct timespec tts;
        clock_gettime(CLOCK_MONOTONIC, &tts);
        double now = (double)tts.tv_sec + (double)tts.tv_nsec * 1e-9;
        if (g_ProbeNoFingerT0 == 0) g_ProbeNoFingerT0 = now;
        if (now - g_ProbeNoFingerT0 > 5.0) {
            g_Probing = NO;
            g_ProbeFullScan = NO;
            g_ProbeIdx = 0;
            g_ProbeNoFingerT0 = 0;
            FTApplyBallAppearance(); // 回蓝
            FTLog("probe: no finger on ball for 5s - stopped");
            return;
        }
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTProbeNextWaitCB);
        return;
    }
    g_ProbeNoFingerT0 = 0; // 手指在，清零等待计时
    uint64_t sid = 0;
    if (g_ProbeFullScan) {
        while (g_ProbeIdx < 768) {
            // v1.0.115：段顺序 7xx → 8xx → 6xx——历史有效 SID 在 7xx（709/716/741/7f3）
            // 和 8xx（8fe/8a9/8b5/854）都出现过（ctor-12 有效值 8fe 在 8xx），6xx 最后。
            // 7xx+8xx 共 512 个 ≈ 30s 内大概率命中。
            uint64_t cand;
            if (g_ProbeIdx < 256) {
                cand = 0x100000700ULL + (uint64_t)g_ProbeIdx;        // 7xx（256 个）
            } else if (g_ProbeIdx < 512) {
                cand = 0x100000800ULL + (uint64_t)(g_ProbeIdx - 256); // 8xx（256 个）
            } else {
                cand = 0x100000600ULL + (uint64_t)(g_ProbeIdx - 512); // 6xx（256 个）
            }
            g_ProbeIdx++;
            bool skip = false;
            for (int k = 0; k < g_ProbeEndingCount; k++) {
                if (g_ProbeEndingSIDs[k] == cand) { skip = true; break; }
            }
            if (skip) continue;
            sid = cand;
            break;
        }
        if (sid == 0) {
            // v1.0.108：全扫耗尽——若手指死后记录过「送达型」保底 → 锁定开始连点
            //（保证有点击）；完全没有送达型才紫色提示。
            if (g_ProbeDeliveredSID != 0) {
                g_LockedSID = g_ProbeDeliveredSID;
                FT_HIDLockSenderID(g_ProbeDeliveredSID);
                g_Probing = NO;
                g_ProbeFullScan = NO;
                g_ProbeIdx = 0;
                // ⚠️ v1.0.123：不再清空 g_ProbeEndingCount（跳过列表）——锁定成功时清空
                // 会丢掉 stab-fail 已验证的坏 SID（ctor-20 实锤：0x716 每次探测都被重新
                // 锁定 → 41 次顶掉 → stab-fail → 重复「变蓝变黄」）。坏 SID 会话内不变，
                // 跳过列表应跨锁定累积（respring 才重置）。
                FTRaiseResidualUps(); // 清探测期残留合成手指（防连点不送达）
                FTApplyBallAppearance(); // 回蓝色
                char dbg2[128];
                snprintf(dbg2, sizeof(dbg2), "scan done - locked fallback SID 0x%llx (delivered); if combo is choppy, release and hold again to skip bad SIDs",
                         (unsigned long long)g_ProbeDeliveredSID);
                FTLog(dbg2);
                gBallTouchClicking = YES;
                FTStartClicking();
            } else {
                g_Probing = NO;
                g_ProbeFullScan = NO;
                g_ProbeIdx = 0;
                g_ProbeNeedMain = YES;
                FTApplyBallAppearance(); // 紫
                FTLog("full scan complete - no working SID; touch non-ball area and retry");
            }
            return;
        }
        // v1.0.111：段切换提示（7xx/8xx/6xx）+ 每 64 个进度（768 总数）
        if (g_ProbeIdx == 1 || g_ProbeIdx == 257 || g_ProbeIdx == 513) {
            uint64_t segbase = (g_ProbeIdx <= 256) ? 0x100000700ULL
                             : (g_ProbeIdx <= 512) ? 0x100000800ULL
                                                   : 0x100000600ULL;
            char dbg2[96];
            snprintf(dbg2, sizeof(dbg2), "full scan: entering 0x%llx range (%d/768)",
                     (unsigned long long)segbase, g_ProbeIdx);
            FTLog(dbg2);
        } else if ((g_ProbeIdx % 64) == 0) {
            char dbg2[96];
            snprintf(dbg2, sizeof(dbg2), "full scan: 0x%llx (%d/768)", (unsigned long long)sid, g_ProbeIdx);
            FTLog(dbg2);
        }
    } else {
        // v1.0.107：候选阶段也跳过已验证「顶掉」的 SID（否则重按后重复测同一个坏 SID）
        while (g_ProbeIdx < g_ProbeSIDCount) {
            uint64_t cand = g_ProbeSIDs[g_ProbeIdx++];
            bool skip = false;
            for (int k = 0; k < g_ProbeEndingCount; k++) {
                if (g_ProbeEndingSIDs[k] == cand) { skip = true; break; }
            }
            if (skip) continue;
            sid = cand;
            break;
        }
        if (sid == 0) {
            // 候选耗尽 → 进入全扫（v1.0.111：范围扩到 0x100000600-0x1000008ff）
            g_ProbeFullScan = YES;
            g_ProbeIdx = 0;
            FTLog("candidates exhausted - full scanning 0x100000600..0x1000008ff (hold)");
            FTProbeNext();
            return;
        }
    }
    g_ProbeSID = sid;
    g_ProbeTouchEnded = NO;
    g_ProbeDelivered = NO;
    // v1.0.107：探测 tap 注入回【点击点】（有效注入区——v1.0.106 角落注入实测零送达，
    // ctor-5 全扫 256 个全空；ctor-3 点击点注入能送达）。送达判定靠「时间窗+Began」
    // 防误判（见 sendEvent），无需改注入位置。
    double nx = gClickLockX, ny = gClickLockY;
    if (nx < 0.001) nx = 0.001; if (nx > 0.999) nx = 0.999;
    if (ny < 0.001) ny = 0.001; if (ny > 0.999) ny = 0.999;
    struct timespec tts;
    clock_gettime(CLOCK_MONOTONIC, &tts);
    g_ProbeTapT0 = (double)tts.tv_sec + (double)tts.tv_nsec * 1e-9;
    // v1.0.108：探测 tap 固定 index=2 → 置位残留位图（up 回调经 FT_ProbeUpDoneHook 清除）；
    // 探测停止/锁定/耗尽时 FTRaiseResidualUps 补发残留 up，防合成手指堆积污染触摸状态
    g_PendingUpIdx[2] = true;
    // v1.0.102：探测 tap 用「down + 25ms 延迟 up」（同正式连点）——立即 up 无可见窗口
    FT_HIDProbeTapDelayed(nx, ny, sid);
    // v1.0.114：探测期间也定期清残留（每 ~16 个 ≈ 1s）——探测 tap up 丢失同样会堆积
    // 残留合成手指 → 污染系统触摸状态 → 后续探测 tap 全部不送达（ctor-11 多轮全扫
    // 768 个零送达的疑似根因；v1.0.113 的清残留只在连点期间生效，探测期间漏了）
    static int sProbeResidual = 0;
    if ((sProbeResidual++ % 16) == 0) {
        FTCheckResidualDuringCombo();
    }
    // v1.0.111：全扫检查窗口 80ms→60ms（Began 回流 10-30ms、顶掉信号 <60ms 内；
    // 768 全扫 46s→35s 最坏）
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTCheckProbe);
}

// 探测结果检查：送达（sendEvent 回流点击点触摸）且用户手指存活（未被顶掉）→ 锁定成功。
// v1.0.108：顶掉（g_ProbeTouchEnded）→ 记录 SID + 标记手指死 +【自动继续扫】（找送达型
// 保底，不让用户干等 2-3 分钟）；送达且手指活 → 锁定完美；送达但手指死 → 记保底继续；
// 全扫耗尽 → 锁保底（有点击）或紫色。不送达也不顶掉 → 自动继续。
static void FTCheckProbe(void *ctx) {
    (void)ctx;
    if (!g_Probing) return;
    if (g_ProbeTouchEnded) {
        // 顶掉（手指被系统 Ended，用户可能仍按着）→ 记录跳过 + 手指死 + 自动继续扫
        if (g_ProbeEndingCount < 64 && g_ProbeSID) {
            bool dup = false;
            for (int k = 0; k < g_ProbeEndingCount; k++) {
                if (g_ProbeEndingSIDs[k] == g_ProbeSID) { dup = true; break; }
            }
            if (!dup) g_ProbeEndingSIDs[g_ProbeEndingCount++] = g_ProbeSID;
        }
        // v1.0.112 修正：顶掉 ≠ 送达！系统对任何注入都会重置触摸上下文顶掉手指
        //（ctor-8 实锤：0x100000661 顶掉型锁定后连点 540 次空跑——顶掉但无 SEND 回流）。
        // 只有「本 tap 有真送达回流（g_ProbeDelivered）」的顶掉型（B 类）才记保底；
        // 纯顶掉（C 类，无回流）只记跳过列表，绝不保底（否则锁定假送达型 → 空跑）。
        if (g_ProbeDelivered && g_ProbeDeliveredSID == 0) g_ProbeDeliveredSID = g_ProbeSID;
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "probe SID=0x%llx ended finger (delivered=%d) - recorded, auto next",
                 (unsigned long long)g_ProbeSID, g_ProbeDelivered ? 1 : 0);
        FTLog(dbg);
        g_ProbeTouchEnded = NO;
        if (gBallTouch == NULL) {
            g_ProbeFingerDead = YES;
            FTLog("probe: finger ended & not re-bound -> can't verify non-ending SIDs this hold");
        } else {
            g_ProbeFingerDead = NO; // 已重绑 → 手指还活着，可继续完整验证
        }
        FTProbeNext(); // 自动继续（球保持橙色）
        return;
    }
    if (g_ProbeDelivered) {
        if (!g_ProbeFingerDead) {
            // 送达且没顶掉（手指活着）→ 锁定完美
            g_LockedSID = g_ProbeSID;
            FT_HIDLockSenderID(g_ProbeSID);
            g_ProbeLockIdx = g_ProbeIdx; // v1.0.115：记锁定位置（verify-fail 后从断点继续）
            g_Probing = NO;
            g_ProbeFullScan = NO;
            g_ProbeIdx = 0;
            // ⚠️ v1.0.123：保留跳过列表（同保底分支，见上）——坏 SID 会话内跨锁定累积
            FTRaiseResidualUps(); // 清探测期残留合成手指（防连点不送达，ctor(1)(1) 空跑根因）
            FTApplyBallAppearance(); // 回蓝色
            FTLog("probe OK - SID locked, starting combo");
            gBallTouchClicking = YES;
            // ⚠️ v1.0.119：进入【高频稳定性验证】——低频探测不顶掉的 SID 在 10ms 高频
            // 连点下可能顶掉用户手指（ctor-16：0x100000716 每轮 8 次就 touches-ended）。
            // FTVerifyDeliveryTimer 窗口内顶掉+重绑 → stab-fail → 记跳过 + 续扫。
            // ⚠️ v1.0.127：连续 stab-fail ≥3 次（g_StabForceLock）→ 跳过验证直接连点
            //（快速变蓝，防「一直变不了蓝」；连点断续由幽灵看门狗+自动重绑恢复兜底）。
            g_StabTesting = !g_StabForceLock;
            g_StabFail = NO;
            FTStartClicking();
            return;
        }
        // 送达但手指已死：记录第一个送达型为保底，继续扫（耗尽时锁定保底开始连点）
        if (g_ProbeDeliveredSID == 0) g_ProbeDeliveredSID = g_ProbeSID;
        char dbg[96];
        snprintf(dbg, sizeof(dbg), "probe SID=0x%llx delivered but finger dead - fallback kept, auto next",
                 (unsigned long long)g_ProbeSID);
        FTLog(dbg);
        g_ProbeDelivered = NO;
        FTProbeNext();
        return;
    }
    // 没送达也没顶掉（不送达型，如 0x8000... 类被丢弃）→ 自动试下一个（手指活着，无需重按）
    FTProbeNext();
}

// v1.0.94：松手宽限计时器（豆包方案）——touchesEnded/Cancelled 后 120ms 内没有重发的
// Began（重绑会清 gStopGracePending）才真停止（手指抬起/滑出/打断 → 停止连点）。
static void FTStopGraceTimer(void *ctx) {
    (void)ctx;
    if (!gStopGracePending) return; // 已被重绑取消（用户手指仍在按着，系统重发了 Began）
    gStopGracePending = NO;
    FTStopClicking("touches-ended");
}

// v1.0.112：连点送达自愈验证——锁定 SID 后窗口内 SEND 无合成触摸回流（点击点附近
// !onBall 触摸）→ 锁定的 SID 假送达（顶掉型 C 类，ctor-8 实锤：0x100000661 连点 540 次
// 空跑）→ 停止连点、记录跳过列表、清锁定、自动重新探测。
// ⚠️ v1.0.119（ctor-16 实锤）：扩展为【高频稳定性裁决】——低频探测不顶掉的 SID，
// 10ms 高频连点会顶掉用户手指 → 记跳过 + 断点续扫，直到找到「高频也不顶掉」的 SID。
// ⚠️ v1.0.125 定案（ctor-22 实锤）：**高频顶掉是概率性的**（同 SID 一会 119 次稳定一会
// 30 次顶掉），会话内几乎没有完全不顶掉的 A 类。800ms 窗口把所有 SID 都淘汰 → 一直
// 续扫 → 「变蓝后变黄，接着一直变不了蓝」。① 验证窗口缩到 300ms——只淘汰「<0.3s
// 立即顶掉」的极端坏 SID，其余快速锁定；顶掉后由「重绑 → 120ms 计时器自动恢复连点」
// 兜底（用户无需重按）。② 300ms 窗口内系统重绑（0.6s+）不可能发生，gBallTouch==NULL
// 即手指已松（轻点真松手 or 顶掉未重绑）→ 记跳过 + 清锁 + 停止（不续扫，等下次按住
// 重新探测自动跳过坏 SID）；手指在（快速重按 or 假送达）→ 记跳过 + 断点续扫。
static void FTVerifyDeliveryTimer(void *ctx) {
    int epoch = (int)(intptr_t)ctx;
    // ⚠️ v1.0.129（ctor-26 实锤）：epoch 不匹配 = 这是【上一轮连点】排的定时器，
    // 新一轮已 started（g_VerifyDelivering 被新一轮重置为 YES）——旧轮定时器不能
    // 裁决新一轮的送达（注入可能还没回流）→ 直接丢弃，防「快速短按 → 好 SID 被
    // 误判 not delivering → 误淘汰 → 一直变不了蓝」。
    if (!g_VerifyDelivering || epoch != g_VerifyEpoch) return;
    g_VerifyDelivering = NO;
    bool wasStab = g_StabTesting;
    g_StabTesting = NO;
    // ⚠️ v1.0.130（ctor-27 实锤）：g_StabFail 只属于【本轮窗口】——首轮短按 touches-ended
    // 设它（FTStopClicking stab 分支），若窗口内松手被 deferred（v1.0.129 不清锁 return）
    // 而没清，残留到下一轮 → 下一轮即使送达也因 g_StabFail==YES 不走通过分支 → 误判
    // stab-fail → 好 SID（0x716/0x717 连遭误杀）被淘汰。触发时无条件保存并清理。
    bool stabFail = g_StabFail;
    g_StabFail = NO;
    // 送达 + 无顶掉 → 验证通过（稳定 SID 或正常连点）
    if (g_VerifySawSynthetic && !stabFail) {
        if (wasStab) {
            FTLog("stab: SID stable - combo continues");
            // v1.0.127：验证通过 → 重置连续失败计数、解除强制锁定
            g_StabFailCount = 0;
            g_StabForceLock = NO;
        }
        g_VerifyFailCount = 0; // v1.0.130：通过即清零连续失败计数
        return;
    }
    // ⚠️ v1.0.132 定案（ctor-29 实锤）：**「窗口内送达回流」是顶掉 vs 快速短按的
    // 可靠区分**——顶掉循环里注入被系统吞（回流少），快速短按注入正常（回流多）。
    // · 松手 + 回流 <50%（g_VerifySawCount*2 < gClickCount）= 顶掉/空跑 → 淘汰；
    // · 松手 + 回流 ≥50% = 用户真松手（连点正常工作过）→ 保持锁定。
    // ⚠️ v1.0.135（ctor-32 实锤）：「有无回流」判不出顶掉型（每轮也有部分 down 送达）
    // → 改回流比例（顶掉轮 <50%，稳定轮 >90%，快速短按 ~100%）。
    if (gBallTouch == NULL) {
        if (gClickCount >= 3 && g_VerifySawCount * 2 < gClickCount) {
            char dbg0[96];
            snprintf(dbg0, sizeof(dbg0), "verify: low return ratio %d/%lu - evicting SID", g_VerifySawCount, (unsigned long)gClickCount);
            FTLog(dbg0);
            if (g_LockedSID) {
                bool dup = false;
                for (int k = 0; k < g_ProbeEndingCount; k++) {
                    if (g_ProbeEndingSIDs[k] == g_LockedSID) { dup = true; break; }
                }
                if (!dup && g_ProbeEndingCount < 64) {
                    g_ProbeEndingSIDs[g_ProbeEndingCount++] = g_LockedSID;
                }
            }
            g_VerifyFailCount = 0;
            FTStopClicking("verify-no-delivery");
            g_LockedSID = 0;
            FT_HIDLockSenderID(0);
            if (g_ProbeLockIdx > 0) {
                g_ProbeIdx = g_ProbeLockIdx;
                g_ProbeFullScan = YES;
                char dbg2[96];
                snprintf(dbg2, sizeof(dbg2), "verify-fail: resume full scan from %d/768", g_ProbeIdx);
                FTLog(dbg2);
            }
            FTStartProbing(); // 手指物理还在（顶掉场景）→ 续扫下一个；已松手 → 等手指回蓝
            return;
        }
        FTLog("verify: finger up during window - verdict deferred, lock kept");
        return;
    }
    // 走到这里 = 手指还在（顶掉后已重绑 / 快速重按）或假送达（用户按着但回流不足）。
    // ⚠️ v1.0.130（ctor-27 实锤）：**单轮异常不淘汰**——游戏高频场景注入繁忙/残留
    // 占槽时单轮窗口内异常很常见（0x100000730 稳定连点 97 次仍被单轮 verify 误杀）。
    // 首次 fail 记警告保持锁定（连点继续），连续 2 次才确认 → 淘汰。防空跑 ≤2×0.8s。
    // ⚠️ v1.0.135（ctor-32 实锤）：判定改【回流比例】——g_VerifySawCount*2 < gClickCount
    // = 回流 <50% → 顶掉/空跑（顶掉型每轮也有部分送达 → 「有无回流」判不出）。
    bool lowReturn = (g_VerifySawCount * 2 < gClickCount);
    g_VerifyFailCount++;
    const char *why = (lowReturn && !wasStab)
        ? "verify: low return ratio this round"
        : "stab-fail: high-freq combo ends user finger";
    if (g_VerifyFailCount < 2) {
        char dbg2[96];
        snprintf(dbg2, sizeof(dbg2), "%s (%d/2) - lock kept, next round re-checks", why, g_VerifyFailCount);
        FTLog(dbg2);
        return;
    }
    g_VerifyFailCount = 0;
    char dbg3[96];
    snprintf(dbg3, sizeof(dbg3), "%s (2/2) - reverting to probe", why);
    FTLog(dbg3);
    // ⚠️ v1.0.127：stab-fail（高频顶掉）连续计数——≥3 次判定本会话无稳定 SID →
    // 强制锁定跳过验证（快速变蓝）；假送达（verify）不算（那是 SID 根本不通，跳过正常）
    if (wasStab && stabFail) {
        g_StabFailCount++;
        if (g_StabFailCount >= 3) {
            g_StabForceLock = YES;
            char dbg4[96];
            snprintf(dbg4, sizeof(dbg4), "stab: %d consecutive fails - force-lock next delivery SID (skip verify)", g_StabFailCount);
            FTLog(dbg4);
        }
    }
    if (g_LockedSID) {
        bool dup = false;
        for (int k = 0; k < g_ProbeEndingCount; k++) {
            if (g_ProbeEndingSIDs[k] == g_LockedSID) { dup = true; break; }
        }
        if (!dup && g_ProbeEndingCount < 64) {
            g_ProbeEndingSIDs[g_ProbeEndingCount++] = g_LockedSID;
        }
    }
    FTStopClicking("stab/verify-fail");
    g_LockedSID = 0;
    FT_HIDLockSenderID(0);
    // v1.0.115：从【锁定位置】继续全扫（跳过已记录的坏 SID），不再从头 49 秒
    if (g_ProbeLockIdx > 0) {
        g_ProbeIdx = g_ProbeLockIdx;
        g_ProbeFullScan = YES;
        char dbg5[96];
        snprintf(dbg5, sizeof(dbg5), "verify-fail: resume full scan from %d/768", g_ProbeIdx);
        FTLog(dbg5);
    }
    FTStartProbing(); // 用户仍按着球 → 从跳过列表后继续探测
}

// Tap 回调：双击 → 切换「拖动模式」与「连击模式」（不再隐藏球）。
//   蓝色（连击模式）：长按触发连点；红色（拖动模式）：拖动小球重新定位点击点。
static void FTGRTapHandler(id self, SEL _cmd, id gr) {
    (void)self; (void)_cmd;
    if (!gr || !gBallView) return;
    NSUInteger st = ((Msg_State)objc_msgSend)(gr, sel_registerName("state"));
    if (st == 3) { // Ended（双击完成）
        FTStopClicking("dbl-tap");
        // 切模式时清掉触摸追踪状态，避免残留的 120ms 计时器在切换后误开连点（竞态）
        gBallTouch = NULL;
        gBallTouchClicking = NO;
        gBallTouchTimerPending = NO;
        gDragMode = !gDragMode;
        // v1.0.75：统一由 FTApplyGRModes 按模式启用/禁用对应手势（含连点中全禁用）
        if (gClickPointView) {
            ((Msg_SetUserInteractionEnabled)objc_msgSend)(gClickPointView, sel_registerName("setUserInteractionEnabled:"), gDragMode ? YES : NO);
        }
        FTApplyGRModes();
        FTApplyBallAppearance();
        FTApplyClickPointAppearance();
        FTLog(gDragMode ? "double tap -> drag mode ON (red): drag ball / click-point to position" : "double tap -> combo mode ON (blue)");
    }
}

// 创建动态类 + target 实例（幂等）
static BOOL FTMakeGRTarget(void) {
    if (gGRTarget) return YES;
    Class superCls = objc_getClass("NSObject");
    if (!superCls) return NO;
    gGRTargetClass = objc_allocateClassPair(superCls, "FTGRTarget", 0);
    if (!gGRTargetClass) return NO;
    class_addMethod(gGRTargetClass, sel_registerName("handleLong:"), (IMP)FTGRLongHandler, "v@:@");
    class_addMethod(gGRTargetClass, sel_registerName("handleTap:"),  (IMP)FTGRTapHandler,  "v@:@");
    class_addMethod(gGRTargetClass, sel_registerName("handlePan:"),  (IMP)FTGRPanHandler,  "v@:@");
    class_addMethod(gGRTargetClass, sel_registerName("handleClickPan:"), (IMP)FTGRClickPanHandler, "v@:@");
    objc_registerClassPair(gGRTargetClass);
    gGRTarget = FTAlloc(gGRTargetClass);
    if (gGRTarget) {
        gGRTarget = ((Msg_Init)objc_msgSend)(gGRTarget, sel_registerName("init"));
    }
    return gGRTarget != nil;
}

// 创建带真实 target 的 GR（正确 initWithTarget:action:）
static id FTMakeGR(Class cls, const char *actionName) {
    id gr = FTAlloc(cls);
    if (!gr) return nil;
    return ((Msg_InitWithTargetAction)objc_msgSend)(gr,
        sel_registerName("initWithTarget:action:"), gGRTarget, sel_registerName(actionName));
}

// MARK: - 窗口定位（球挂到系统手势层）

static void FTSetupBall(void);
static void FTSetupBallRetry(void *ctx);

static int gBallSetupTries = 0;
static const int FT_BALL_MAX_TRIES = 12;

// 枚举含 internal 的全体窗口，返回数组或 nil。
// ⚠️ v1.0.61 修正：iOS 12 用 UIWindow 类方法 `_allWindowsIncludingInternalWindows:`；
// iOS 13+ 改用 UIWindowScene 实例方法（同一名字、无参数）。旧版只在 UIWindow 上探，
// 在 iOS 15 上 respondsToSelector 失败 → 返回 nil → 永远找不到手势窗口 → 球兜底挂到
// SBRecordingIndicatorWindow（非交互窗口，手势全失效）。
// 另外 sendEvent hook 会直接捕获手势窗口实例到 gGestureWin，作为最可靠来源。
static id FTInternalWindows(void) {
    // 1) iOS 12：UIWindow 类方法
    Class ClsWinCls = objc_getClass("UIWindow");
    if (ClsWinCls) {
        SEL sels[2];
        sels[0] = sel_registerName("_allWindowsIncludingInternalWindows:");
        sels[1] = sel_registerName("_windowsIncludingInternalWindows:");
        for (int k = 0; k < 2; k++) {
            if (sels[k] && class_respondsToSelector(ClsWinCls, sels[k])) {
                typedef id (*Msg_AllWin)(id, SEL, BOOL);
                id r = ((Msg_AllWin)objc_msgSend)((id)ClsWinCls, sels[k], YES);
                if (r) return r;
            }
        }
    }
    // 2) iOS 13+：UIWindowScene 实例方法（internal 窗口枚举在这里）
    id scene = FTGetActiveWindowScene();
    if (scene) {
        SEL selsS[2];
        selsS[0] = sel_registerName("_allWindowsIncludingInternalWindows");
        selsS[1] = sel_registerName("allWindowsIncludingInternalWindows");
        Class sceneCls = (Class)object_getClass(scene);
        for (int k = 0; k < 2; k++) {
            if (selsS[k] && class_respondsToSelector(sceneCls, selsS[k])) {
                typedef id (*Msg_SceneAllWin)(id, SEL);
                id r = ((Msg_SceneAllWin)objc_msgSend)(scene, selsS[k]);
                if (r) return r;
            }
        }
        // 兜底：scene 公开 windows（不全含 internal，但至少保证有窗口可枚举）
        id sw = ((Msg_Send)objc_msgSend)(scene, sel_registerName("windows"));
        if (sw) return sw;
    }
    return nil;
}

// 返回系统手势窗口（_UISystemGestureWindow / FBSystemGestureWindow 等）；没有返回 nil
static id FTFindSystemGestureWindow(void) {
    id ClsApp = objc_getClass("UIApplication");
    id app = ClsApp ? ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication")) : nil;
    id allWins = FTInternalWindows();
    id appWins = app ? ((Msg_Send)objc_msgSend)(app, sel_registerName("windows")) : nil;
    id sets[2]; sets[0] = allWins; sets[1] = appWins;
    for (int s = 0; s < 2; s++) {
        id ws = sets[s];
        if (!ws) continue;
        NSUInteger cnt = ((Msg_Count)objc_msgSend)(ws, sel_registerName("count"));
        for (NSUInteger i = 0; i < cnt; i++) {
            id w = ((Msg_ObjectAtIndex)objc_msgSend)(ws, sel_registerName("objectAtIndex:"), i);
            if (!w) continue;
            const char *cn = object_getClassName(w);
            if (cn && (strstr(cn, "SystemGesture") || strstr(cn, "GestureWindow") || strstr(cn, "FBSystemGesture"))) {
                return w;
            }
        }
    }
    return nil;
}

// 最佳挂载窗口：优先系统手势窗口；否则「最高 windowLevel 且非 Alert」窗口（避免选中瞬时弹窗）；最后 keyWindow
static id FTFindOverlayWindow(int *outIsGesture) {
    if (outIsGesture) *outIsGesture = 0;
    id g = FTFindSystemGestureWindow();
    if (g) {
        if (outIsGesture) *outIsGesture = 1;
        return g;
    }
    id ClsApp = objc_getClass("UIApplication");
    id app = ClsApp ? ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication")) : nil;
    id allWins = FTInternalWindows();
    id appWins = app ? ((Msg_Send)objc_msgSend)(app, sel_registerName("windows")) : nil;
    id best = nil; CGFloat bestLvl = -1e9;
    id sets[2]; sets[0] = allWins; sets[1] = appWins;
    for (int s = 0; s < 2; s++) {
        id ws = sets[s];
        if (!ws) continue;
        NSUInteger cnt = ((Msg_Count)objc_msgSend)(ws, sel_registerName("count"));
        for (NSUInteger i = 0; i < cnt; i++) {
            id w = ((Msg_ObjectAtIndex)objc_msgSend)(ws, sel_registerName("objectAtIndex:"), i);
            if (!w) continue;
            const char *cn = object_getClassName(w);
            // v1.0.68：跳过瞬时 / 非交互窗口。iOS 15 的 SBRecordingIndicatorWindow（隐私/录屏指示）
            // 尺寸极小却拥有最高 windowLevel，旧版兜底误选它 → 球挂上去 touch 命中范围错乱、手势收不到、
            // 在 App 内被完全盖住无反馈。一并排除 Alert / StatusBar / Keyboard / CoverSheet 等。
            if (cn && (strstr(cn, "Alert") || strstr(cn, "Recording") ||
                       strstr(cn, "Indicator") || strstr(cn, "StatusBar") ||
                       strstr(cn, "Keyboard") || strstr(cn, "CoverSheet"))) continue;
            CGFloat lvl = ((Msg_CGFloatReturn)objc_msgSend)(w, sel_registerName("windowLevel"));
            if (lvl > bestLvl) { bestLvl = lvl; best = w; }
        }
    }
    if (best) return best;
    return app ? ((Msg_Send)objc_msgSend)(app, sel_registerName("keyWindow")) : nil;
}

// 延迟重试挂载（dispatch_after_f 回调）
static void FTSetupBallRetry(void *ctx) {
    (void)ctx;
    FTSetupBall();
}

// v1.0.68：把球重新挂到系统手势窗口（当 sendEvent 捕获到真正手势窗口、而球此前挂在兜底窗口时）。
// 用主线程异步回调执行，避免在事件派发途中直接改视图层级导致异常。
static void FTReparentBallToGestureWin(void *ctx) {
    (void)ctx;
    if (!gBallView || !gGestureWin) return;
    id sup = ((Msg_Send)objc_msgSend)(gBallView, sel_registerName("superview"));
    if (sup == gGestureWin) return; // 已经在正确窗口
    if (sup) ((Msg_Send)objc_msgSend)(gBallView, sel_registerName("removeFromSuperview"));
    ((Msg_AddSubview)objc_msgSend)(gGestureWin, sel_registerName("addSubview:"), gBallView);
    gBallContainer = gGestureWin;
    // 点击点标记一并重挂到正确窗口
    if (gClickPointView) {
        id csup = ((Msg_Send)objc_msgSend)(gClickPointView, sel_registerName("superview"));
        if (csup != gGestureWin) {
            if (csup) ((Msg_Send)objc_msgSend)(gClickPointView, sel_registerName("removeFromSuperview"));
            ((Msg_AddSubview)objc_msgSend)(gGestureWin, sel_registerName("addSubview:"), gClickPointView);
        }
    }
    // 点击落点光圈一并重挂
    if (gClickFlashView) {
        id fsup = ((Msg_Send)objc_msgSend)(gClickFlashView, sel_registerName("superview"));
        if (fsup != gGestureWin) {
            if (fsup) ((Msg_Send)objc_msgSend)(gClickFlashView, sel_registerName("removeFromSuperview"));
            ((Msg_AddSubview)objc_msgSend)(gGestureWin, sel_registerName("addSubview:"), gClickFlashView);
        }
    }
    const char *oldCls = sup ? object_getClassName(sup) : "?";
    char diag[160];
    snprintf(diag, sizeof(diag), "ball reparented: %s -> %s", oldCls, object_getClassName(gGestureWin));
    FTLog(diag);
}

// MARK: - 创建小球

static void FTSetupBall(void) {
    // v1.0.58：球挂在 _UISystemGestureWindow（或兜底 keyWindow）的 subview，凭 superview 判断是否已挂载
    if (gBallView) {
        id sup = ((Msg_Send)objc_msgSend)(gBallView, sel_registerName("superview"));
        if (sup) return;
    }

    Class ClsApp   = objc_getClass("UIApplication");
    Class ClsView  = objc_getClass("UIView");
    Class ClsScreen = objc_getClass("UIScreen");
    Class ClsColor = objc_getClass("UIColor");
    Class ClsTapGR = objc_getClass("UITapGestureRecognizer");
    Class ClsLongGR = objc_getClass("UILongPressGestureRecognizer");
    Class ClsPanGR = objc_getClass("UIPanGestureRecognizer");
    if (!ClsApp || !ClsView || !ClsScreen || !ClsColor || !ClsTapGR || !ClsLongGR || !ClsPanGR) {
        FTLog("setup failed: system class missing");
        return;
    }
    if (!FTMakeGRTarget()) {
        FTLog("setup failed: make GR target");
        return;
    }

    // 主屏尺寸
    id mainScreen = ((Msg_Send)objc_msgSend)((id)ClsScreen, sel_registerName("mainScreen"));
    CGRect sb = ((Msg_Bounds)objc_msgSend)(mainScreen, sel_registerName("bounds"));
    // v1.0.86 关键修正：gScreenW/H 必须恒为【竖屏基准】（短边×长边）！
    // 实测（ctor-56/58）：_UISystemGestureWindow 的 bounds 恒为竖屏 834×1194（SB 窗口用
    // transform 旋转显示），IOHID digitizer 归一化换算也是此基准。若用「当前方向尺寸」
    // （横屏启动时 1194×834）快照，标记 frame 与注入坐标基准错位 → 点击偏离标记
    // （竖屏偏左下 ~286pt、横屏偏右下 50°/4cm，ctor-58 实测）。统一竖屏基准后透传即命中。
    if (sb.size.width < sb.size.height) {
        gScreenW = sb.size.width;
        gScreenH = sb.size.height;
    } else {
        gScreenW = sb.size.height;
        gScreenH = sb.size.width;
    }
    CGFloat d = 56.0;
    CGRect ballFrame = CGRectMake(gScreenW / 2 - d / 2, gScreenH / 2 - d / 2, d, d);
    // ⚠️ v1.0.116 定案（ctor-13 实锤）：默认点击点必须与球分离！
    // 旧默认 gClickLock=(0.5,0.5)=屏幕中心=球位置：探测 tap 注入到点击点=注入到球上，
    // 球是 userInteractionEnabled=YES 的手势窗口 subview → 合成触摸被球拦截永不路由 →
    // 全扫 768 个 SID 零送达 → 变不了蓝。点击点标记 userInteractionEnabled=NO（穿透），
    // 只要点击点不在球上，注入即可送达。无配置时默认放到球下方 ~1/6 屏（竖屏基准）。
    if (!gCfgLoaded) {
        gClickLockX = 0.5;
        gClickLockY = 0.66; // 球下方 ~190px（1194×0.16）
    }

    // v1.0.60：球必须挂到 _UISystemGestureWindow（系统手势层，始终在所有 App 之上），
    // 游戏/前台 App 内才可见可点。但它是 internal window，[UIApplication windows] 枚举不到，
    // 且 init 过早时可能尚未创建；旧版兜底取"windowLevel 最高"会选中瞬时弹窗 SBAlertItemWindow
    // （弹窗消失球也跟着没 → "没有悬浮窗"）。
    // 修复：先找系统手势窗口；找不到就延迟重试（最多 ~12s）等它就绪；
    //       重试耗尽才退化挂到「最高非 Alert 窗口 / keyWindow」（稳定、不会凭空消失）。
    int isGesture = 0;
    id targetWin = nil;
    // v1.0.61：优先用从 sendEvent 捕获到的真实系统手势窗口（最可靠），
    // 否则退化到枚举 + 兜底（最高非 Alert / keyWindow）。
    if (gGestureWin) {
        targetWin = gGestureWin;
        isGesture = 1;
        FTLog("ball: using gesture window captured from sendEvent");
    } else {
        targetWin = FTFindOverlayWindow(&isGesture);
    }
    {
        char diagSel[160];
        snprintf(diagSel, sizeof(diagSel), "ball select: gestureCaptured=%d target=%s isGesture=%d",
            gGestureWin ? 1 : 0,
            targetWin ? object_getClassName(targetWin) : "nil",
            isGesture);
        FTLog(diagSel);
    }
    if (!targetWin && gBallSetupTries < FT_BALL_MAX_TRIES) {
        gBallSetupTries++;
        FTLog("ball: no overlay window yet, retry later");
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTSetupBallRetry);
        return;
    }
    if (!targetWin) {
        FTLog("setup failed: no overlay window");
        return;
    }

    id ball = FTAllocInitWithFrame(ClsView, ballFrame);
    if (!ball) {
        FTLog("setup failed: alloc ball");
        return;
    }
    ((Msg_SetUserInteractionEnabled)objc_msgSend)(ball, sel_registerName("setUserInteractionEnabled:"), YES);
    ((Msg_SetBackgroundColor)objc_msgSend)(ball, sel_registerName("setBackgroundColor:"),
        ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"),
                                          0.0, 0.478, 1.0, 0.9));

    id layer = ((Msg_Layer)objc_msgSend)(ball, sel_registerName("layer"));
    ((Msg_SetCGFloat)objc_msgSend)(layer, sel_registerName("setCornerRadius:"), (CGFloat)(d / 2.0));
    ((Msg_SetCGFloat)objc_msgSend)(layer, sel_registerName("setBorderWidth:"), (CGFloat)2.5);
    id white = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"),
                                                 1.0, 1.0, 1.0, 1.0);
    ((Msg_SetBorderColor)objc_msgSend)(layer, sel_registerName("setBorderColor:"),
                                       ((Msg_CGColor)objc_msgSend)(white, sel_registerName("CGColor")));

    // GR：运行时创建的 target 实例 + initWithTarget:action:
    gTapGR  = FTMakeGR(ClsTapGR, "handleTap:");
    gLongGR = FTMakeGR(ClsLongGR, "handleLong:");
    gPanGR  = FTMakeGR(ClsPanGR, "handlePan:");
    if (!gTapGR || !gLongGR || !gPanGR) {
        FTLog("setup failed: make GR");
    }
    ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR, sel_registerName("setNumberOfTapsRequired:"), (NSUInteger)2);
    // 长按：minimumPressDuration=0.25 → 稍微按住即触发连点（更跟手）。仍保留 require 双击
    // 失败，确保双击切换优先级；0.25s 足够短于双击间隔，不会抢双击。
    // allowableMovement=200：宽松容差，iPad 上手指自然抖动/微小移动不会误判失败
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setMinimumPressDuration:"), 0.25);
    ((Msg_SetCGFloat)objc_msgSend)(gLongGR, sel_registerName("setAllowableMovement:"), 200.0);
    // 让「双击」手势优先：长按/拖动都 require 双击失败后才识别。
    // 这样双击必然触发模式切换，长按/拖动只在「不是双击」时才生效，二者不再抢触摸。
    ((Msg_RequireToFail)objc_msgSend)(gLongGR, sel_registerName("requireGestureRecognizerToFail:"), gTapGR);
    ((Msg_RequireToFail)objc_msgSend)(gPanGR,  sel_registerName("requireGestureRecognizerToFail:"), gTapGR);
    // v1.0.74：关键修复——UITapGestureRecognizer 默认 cancelsTouchesInView=YES，会在手势
    // 识别/失败时把触摸判为 Cancelled(phase=4)，导致 sendEvent 里追踪的「球上手指」被清空、
    // 连点定时器立刻被取消（"点一下只触发一次 / 长按只算一次"，ctor-45 根因）。
    // 设 NO：手势照常识别双击，但不再取消触摸，按住的手指持续被追踪 → 连点持续。
    ((Msg_SetEnabled)objc_msgSend)(gTapGR,  sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gTapGR2, sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gLongGR, sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gPanGR,  sel_registerName("setCancelsTouchesInView:"), NO);
    ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setCancelsTouchesInView:"), NO);
    // 模式初始化：蓝色连击模式 → 启用长按、禁用拖动
    ((Msg_SetEnabled)objc_msgSend)(gLongGR, sel_registerName("setEnabled:"), YES);
    ((Msg_SetEnabled)objc_msgSend)(gPanGR,  sel_registerName("setEnabled:"), NO);

    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gTapGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gLongGR);
    ((Msg_AddGestureRecognizer)objc_msgSend)(ball, sel_registerName("addGestureRecognizer:"), gPanGR);

    // v1.0.58：把球作为 subview 挂到 targetWin（优先 _UISystemGestureWindow，始终位于所有 App 之上）。
    // 这样球在游戏 / 前台 App 内也可见、可触摸；点击注入本身是绝对坐标，跟前台 App 无关。
    ((Msg_AddSubview)objc_msgSend)(targetWin, sel_registerName("addSubview:"), ball);

    // 点击点标记（独立视图，与球解耦）：默认位置 = gClickLockX/Y（初始屏幕中心 / App 配置点）。
    // 仅「红色拖动模式」可拖动；蓝色连击模式 userInteractionEnabled=NO → 点击穿透到下层 App。
    {
        CGFloat m = 30.0;
        CGRect mf = CGRectMake(gClickLockX * gScreenW - m / 2, gClickLockY * gScreenH - m / 2, m, m);
        gClickPointView = FTAllocInitWithFrame(ClsView, mf);
        if (gClickPointView) {
            ((Msg_SetUserInteractionEnabled)objc_msgSend)(gClickPointView, sel_registerName("setUserInteractionEnabled:"), gDragMode ? YES : NO);
            id mlayer = ((Msg_Layer)objc_msgSend)(gClickPointView, sel_registerName("layer"));
            ((Msg_SetCGFloat)objc_msgSend)(mlayer, sel_registerName("setCornerRadius:"), (CGFloat)(m / 2));
            ((Msg_SetCGFloat)objc_msgSend)(mlayer, sel_registerName("setBorderWidth:"), (CGFloat)2.5);
            id mcol = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"), 0.2, 1.0, 0.4, 1.0);
            ((Msg_SetBorderColor)objc_msgSend)(mlayer, sel_registerName("setBorderColor:"),
                ((Msg_CGColor)objc_msgSend)(mcol, sel_registerName("CGColor")));
            // 中心圆点（指示精确点击位置），tag=101 便于外观刷新时定位
            id dot = FTAllocInitWithFrame(ClsView, CGRectMake(m / 2 - 4, m / 2 - 4, 8, 8));
            if (dot) {
                id dlayer = ((Msg_Layer)objc_msgSend)(dot, sel_registerName("layer"));
                ((Msg_SetCGFloat)objc_msgSend)(dlayer, sel_registerName("setCornerRadius:"), (CGFloat)4);
                ((Msg_SetBackgroundColor)objc_msgSend)(dot, sel_registerName("setBackgroundColor:"), mcol);
                ((Msg_SetTag)objc_msgSend)(dot, sel_registerName("setTag:"), (NSInteger)101);
                ((Msg_AddSubview)objc_msgSend)(gClickPointView, sel_registerName("addSubview:"), dot);
            }
            gClickPanGR = FTMakeGR(ClsPanGR, "handleClickPan:");
            if (gClickPanGR) {
                ((Msg_RequireToFail)objc_msgSend)(gClickPanGR, sel_registerName("requireGestureRecognizerToFail:"), gTapGR);
                ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setEnabled:"), gDragMode ? YES : NO);
                ((Msg_SetEnabled)objc_msgSend)(gClickPanGR, sel_registerName("setCancelsTouchesInView:"), NO); // v1.0.74
                ((Msg_AddGestureRecognizer)objc_msgSend)(gClickPointView, sel_registerName("addGestureRecognizer:"), gClickPanGR);
            }
            // 点击点标记上也挂一个双击手势（同一 toggle handler）——避免编辑模式下标记盖住球时，
            // 双击球无法命中、导致切不回连击模式。双击始终局部命中单一视图，不会双触发。
            gTapGR2 = FTMakeGR(ClsTapGR, "handleTap:");
            if (gTapGR2) {
                ((Msg_SetNumberOfTapsRequired)objc_msgSend)(gTapGR2, sel_registerName("setNumberOfTapsRequired:"), (NSUInteger)2);
                ((Msg_RequireToFail)objc_msgSend)(gTapGR2, sel_registerName("requireGestureRecognizerToFail:"), gLongGR);
                ((Msg_RequireToFail)objc_msgSend)(gTapGR2, sel_registerName("requireGestureRecognizerToFail:"), gClickPanGR);
                ((Msg_RequireToFail)objc_msgSend)(gClickPanGR, sel_registerName("requireGestureRecognizerToFail:"), gTapGR2);
                ((Msg_SetEnabled)objc_msgSend)(gTapGR2, sel_registerName("setCancelsTouchesInView:"), NO); // v1.0.74
                ((Msg_AddGestureRecognizer)objc_msgSend)(gClickPointView, sel_registerName("addGestureRecognizer:"), gTapGR2);
            }
            ((Msg_AddSubview)objc_msgSend)(targetWin, sel_registerName("addSubview:"), gClickPointView);
            FTApplyClickPointAppearance();
        }
    }

    // v1.0.81：点击落点光圈——每次注入在点击点显示红圈（连点时常亮），直观看到"点击落在哪"。
    // App 里点空白处/备忘录默认不显示反馈，用户看不到落点，故自绘光圈。
    {
        CGFloat f = 26.0;
        gClickFlashView = FTAllocInitWithFrame(ClsView, CGRectMake(0, 0, f, f));
        if (gClickFlashView) {
            ((Msg_SetUserInteractionEnabled)objc_msgSend)(gClickFlashView, sel_registerName("setUserInteractionEnabled:"), NO);
            id flayer = ((Msg_Layer)objc_msgSend)(gClickFlashView, sel_registerName("layer"));
            ((Msg_SetCGFloat)objc_msgSend)(flayer, sel_registerName("setCornerRadius:"), (CGFloat)(f / 2));
            ((Msg_SetCGFloat)objc_msgSend)(flayer, sel_registerName("setBorderWidth:"), (CGFloat)3.0);
            id fcol = ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.3, 0.2, 0.95);
            ((Msg_SetBorderColor)objc_msgSend)(flayer, sel_registerName("setBorderColor:"),
                ((Msg_CGColor)objc_msgSend)(fcol, sel_registerName("CGColor")));
            ((Msg_SetBackgroundColor)objc_msgSend)(gClickFlashView, sel_registerName("setBackgroundColor:"),
                ((Msg_ColorWithRGBA)objc_msgSend)((id)ClsColor, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.55, 0.35, 0.30));
            ((Msg_SetAlpha)objc_msgSend)(gClickFlashView, sel_registerName("setAlpha:"), 0.0);
            ((Msg_AddSubview)objc_msgSend)(targetWin, sel_registerName("addSubview:"), gClickFlashView);
        }
    }

    gBallContainer = targetWin;
    gBallView      = ball;
    FTApplyBallAppearance(); // 初始蓝色=连击模式

    // v1.0.55 诊断：报告球窗口层级（之前 ball 在独立 UIWindow 上行为诡异）
    CGRect ballFrameDiag = ((Msg_Frame)objc_msgSend)(ball, sel_registerName("frame"));
    id ballSuper = ((Msg_Send)objc_msgSend)(ball, sel_registerName("superview"));
    const char *superCls = ballSuper ? object_getClassName(ballSuper) : "?";
    char diag[256];
    id kw = ((Msg_Send)objc_msgSend)((id)ClsApp, sel_registerName("sharedApplication"));
    kw = kw ? ((Msg_Send)objc_msgSend)(kw, sel_registerName("keyWindow")) : nil;
    snprintf(diag, sizeof(diag),
        "ball attached: super=%s frame=%.0f,%.0f,%.0fx%.0f keyWin=%s",
        superCls,
        ballFrameDiag.origin.x, ballFrameDiag.origin.y, ballFrameDiag.size.width, ballFrameDiag.size.height,
        kw ? object_getClassName(kw) : "?");
    FTLog(diag);

    FTLog("ball created, gesture handlers wired");

    // v1.0.50：球创建后立即按 App 配置定位（若已加载配置）
    FTMoveBallToConfig();
}

// v1.0.50：移动球到 App 配置位置（球心 = 配置点击点；未加载配置则居中不动）
// ⚠️ v1.0.116：球与点击点必须分离——球（可交互手势窗口 subview）盖住点击点会拦截
// 注入到点击点的合成触摸 → 探测零送达（ctor-13 实锤）。配置点=点击点，球移到配置点
// 必然重叠 → 把球放到点击点正上方 150px（用户可再拖球微调）。
static void FTMoveBallToConfig(void) {
    if (!gBallView || !gCfgLoaded) return;
    if (gScreenW <= 0 || gScreenH <= 0) return;
    double px = gCfgX * gScreenW;
    double py = gCfgY * gScreenH;
    CGRect f = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
    double bw = f.size.width, bh = f.size.height;
    // 偏移：默认点击点上方 150px；上方越界（<60px）则改下方
    double ox = 0.0, oy = -150.0;
    if (py + oy < 60.0) oy = 150.0;
    ((Msg_SetFrame)objc_msgSend)(gBallView, sel_registerName("setFrame:"),
        CGRectMake(px - bw * 0.5, py - bh * 0.5 + oy, bw, bh));
    // 同步点击点标记位置（连点打在配置点；与球解耦，二者可分别拖动）
    gClickLockX = gCfgX;
    gClickLockY = gCfgY;
    if (gClickPointView) {
        CGFloat m = 30.0;
        ((Msg_SetFrame)objc_msgSend)(gClickPointView, sel_registerName("setFrame:"),
            CGRectMake(gCfgX * gScreenW - m / 2, gCfgY * gScreenH - m / 2, m, m));
    }
    char diag[96];
    snprintf(diag, sizeof(diag), "ball moved to config %.2f,%.2f (offset %.0f,%.0f)", gCfgX, gCfgY, ox, oy);
    FTLog(diag);
}

// MARK: - GCD C 函数回调（代替 block）——前向声明

static void FTEnsureBallCallback(void *ctx);
static void FTTweakInitCallback(void *ctx);
static void FTEnsureBall(int attempt);

static void FTEnsureBall(int attempt) {
    if (FTUIReady()) {
        FTSetupBall();
        return;
    }
    if (attempt >= 10) {
        FTLog("SB UI not ready after 20s, giving up");
        return;
    }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTEnsureBallCallback);
}

static void FTEnsureBallCallback(void *ctx) {
    (void)ctx;
    FTEnsureBall(0);
}

static void FTTweakInitCallback(void *ctx) {
    (void)ctx;
    FTLog("init callback, calling FTEnsureBall");
    // v1.0.50：App 通信（注册通知 + 心跳 + 读配置）——必须在 SB 完全启动后
    // （ctor 阶段任何 ObjC 调用在 arm64e 下 PAC 崩，v1.0.50 实测 Safe Mode）
    FTRegisterNotifications();
    // v1.0.53：移除 FT_HIDStartSenderIDCapture——arm64e SB 里注册 IOHID 事件回调
    // 是 Safe Mode 元凶（实测两次崩）；senderID 用硬编码兜底值即可。
    FTDumpEventIvars();
    FTEnsureBall(0);

    // v1.0.53.1：延迟 60s 再枚举 App 列表（60s 期间 SB 完全稳定）。
    // 之前在 30s init 内合并调用，FTWriteAppsList 内 objc_msgSend 触发 Safe Mode。
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), NULL, FTAppsListDeferredCallback);
}

// MARK: - 诊断 hook（v1.0.29 临时）：观察注入触摸是否到达 UIKit 层
// 只读：%orig 先调，再节流打印 event 的触摸数与命中的 view 类。
// 判断：注入若到达，日志会高频出现 SEND touches=1 view=<下层view类>；
//       若完全没有注入相关记录 → HID 事件在 IOKit/BackBoard 层被丢弃。

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig;
    // v1.0.61：从事件流直接捕获系统手势窗口实例。
    // 已知真实触摸始终流经 _UISystemGestureWindow（日志 win= 字段印证），
    // 而 [UIApplication windows] 与部分 iOS 版本的枚举类方法都枚举不到它。
    // 捕获一次即可作为球的挂载容器，彻底绕开枚举盲区。
    if (!gGestureWin) {
        const char *cn = object_getClassName(self);
        if (cn && (strstr(cn, "SystemGesture") || strstr(cn, "GestureWindow") || strstr(cn, "FBSystemGesture"))) {
            gGestureWin = self;
            FTLog("captured system gesture window from sendEvent");
            // v1.0.68：若球此前挂在兜底窗口（如 SBRecordingIndicatorWindow），立即异步重挂到正确窗口。
            if (gBallView) {
                dispatch_async_f(dispatch_get_main_queue(), NULL, FTReparentBallToGestureWin);
            }
        }
    }
    // ⚠️ v1.0.100：SID 捕获移入下方遍历循环——只对【非球上触摸】（主屏/App 窗口）捕获
    // g_MainSID。球上触摸被手势服务翻译成 0x1000007af 类无效值（注入顶掉用户手指，
    // ctor-72 铁证）；主屏 digitizer SID（0x100000709 类）系统认领、不顶掉（ctor-69 完美）。
    // 注意：不在此处无条件捕获（否则球上触摸的翻译值污染候选集）。
    // v1.0.71：按「触摸身份」追踪按在球上的用户手指，驱动连点（替代 UILongPressGR）。
    // 免疫两大致命干扰：① 游戏内多点触摸（第 2 根手指）会让 UILongPress 被判 Cancelled；
    // ② 合成注入触摸（点击点==球心时落回球上）会让 UILongPress 收 2nd touch 取消。
    // 只认「在球内 Began 的那一根触摸」，合成触摸因指针身份不同被忽略；且只在按住 >120ms 后才连点，
    // 避免双击切模式时误触发连点。
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;

    if (gBallView && event && !gDragMode) {
        id tset = ((Msg_Send)objc_msgSend)(event, sel_registerName("allTouches"));
        // ⚠️ allTouches 返回 NSSet（非数组），必须用 allObjects 转成 NSArray 才能 objectAtIndex:
        // 直接对 NSSet 调 objectAtIndex: 会抛 unrecognized selector → SB 崩溃 → Safe Mode（ctor-42 真凶）。
        id tarr = tset ? ((Msg_Send)objc_msgSend)(tset, sel_registerName("allObjects")) : nil;
        NSUInteger tn = tarr ? ((Msg_Count)objc_msgSend)(tarr, sel_registerName("count")) : 0;
        CGRect bf = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
        for (NSUInteger i = 0; i < tn; i++) {
            id t = ((Msg_ObjectAtIndex)objc_msgSend)(tarr, sel_registerName("objectAtIndex:"), i);
            if (!t) continue;
            long ph = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("phase"));
            CGPoint loc = ((Msg_LocationInView)objc_msgSend)(t, sel_registerName("locationInView:"), nil);
            BOOL onBall = (loc.x >= bf.origin.x && loc.x <= bf.origin.x + bf.size.width &&
                          loc.y >= bf.origin.y && loc.y <= bf.origin.y + bf.size.height);
            void *tp = (__bridge void *)t;
            // ⚠️ v1.0.103：捕获【真正的主屏/App 窗口】触摸——判断触摸所在 window 是否
            // 手势窗口（_UISystemGestureWindow）。球/点击点标记/红圈都是手势窗口 subview，
            // 触摸全部被手势服务翻译成 0x1000007xx 无效值（注入顶掉用户手指，ctor-72 铁证）。
            // v1.0.100 用「!onBall」判断不够——点击点标记附近的触摸（loc≈331,591，离球仅
            // ~90px）也在手势窗口内、同样是翻译值（ctor.log：main SID=0x1000007b1 无效）。
            // 只有 window != 手势窗口 的触摸才是主屏 digitizer 直通 SID（0x100000709 类）。
            id tw = ((Msg_Send)objc_msgSend)(t, sel_registerName("window"));
            BOOL inGestureWin = (tw && gGestureWin && tw == gGestureWin);
            if (!inGestureWin) {
                FT_HIDCaptureMainSIDFromUIEvent((__bridge void *)event);
            }
            // v1.0.101：探测期间检测「送达」——合成触摸回流 sendEvent 且落在点击点附近
            // （非球上）→ 当前探测 SID 送达成功。
            // v1.0.107：加「ph==0(Began) + 注入后 60ms 时间窗」双重条件——旧方案只看位置
            // 90px，用户手指滑出球边（Moved，距点击点 <90px）或第二根手指经过点击点附近
            // 会被误判送达（ctor-3 锁定不送达 SID → 空跑）；Began+时间窗只认探测 tap 自己的
            // 合成触摸（注入后立即回流的 Began），用户手指的 Moved/已存在触摸不匹配。
            // ⚠️ v1.0.117 定案（ctor-14 实锤）：判定半径 45px → 200px——合成触摸回流位置
            // 与注入点存在 ~100px 垂直偏移（注入 (417,788)，回流实测 (410,888) dist=101），
            // 45px 全部 miss → 全扫 768 零送达 → 变不了蓝；0x652 类「送达+顶掉」B 类 SID
            // 被误归 C 类。200px 覆盖偏移+余量；用户手指在球上（onBall 排除）+ Began 在
            // 注入后 60ms 时间窗内，误判概率极低，自愈验证兜底。v1.0.115 的 45px 防误判
            // 目标改由「!onBall + 时间窗」达成，不再靠窄半径。
            // ⚠️ v1.0.126（ctor-23 实锤）：ph==0 → ph==0||ph==1——探测 tap 的 up 丢失会让
            // 合成触摸残留成 Stationary（phase=1）回流：0x716 探测时送达了但 phase=1 →
            // 只认 Began 判定 miss → 残留污染后续 700+ 个 SID 探测 → 首次全扫 50s 白扫。
            // 残留合成手指 = 该 SID down 成功注入（送达证据）→ Stationary 同样算送达。
            if (g_Probing && !g_ProbeDelivered && (ph == 0 || ph == 1 || ph == 2) && !onBall && g_ProbeTapT0 > 0) {
                double cx = gClickLockX * gScreenW;
                double cy = gClickLockY * gScreenH;
                if ((now - g_ProbeTapT0) < 0.06) {
                    double dist = sqrt((loc.x - cx) * (loc.x - cx) + (loc.y - cy) * (loc.y - cy));
                    // v1.0.116 诊断：记录回流落点+距离（节流每 32）——若仍有 miss 可定位偏移
                    if (dist < 200.0) {
                        static int sProbeSaw = 0;
                        if ((sProbeSaw++ % 32) == 0) {
                            char dbg[128];
                            snprintf(dbg, sizeof(dbg), "probe saw Began at %.0f,%.0f (clickPt %.0f,%.0f dist=%.0f)",
                                     loc.x, loc.y, cx, cy, dist);
                            FTLog(dbg);
                        }
                        g_ProbeDelivered = YES; // v1.0.117：200px 内即送达（v1.0.126 含 Stationary）
                    }
                }
            }
            // v1.0.112：连点送达自愈验证——锁定后连点期间，点击点附近出现 !onBall 合成
            // 触摸回流 → 真送达（300ms 内任一即通过；用户手指在球上 onBall 排除）
            // ⚠️ v1.0.117：半径 45px → 200px（同探测，回流偏移 ~100px，45px 会让真送达
            // 被误判 verify-fail → 回退循环）；加 ph==0——用户手指滑出球边的 Moved
            // （phase=1）不算合成回流，防用户手指干扰误判验证通过。
            // ⚠️ v1.0.126：ph==0 → ph==0||ph==1（同探测，残留 Stationary 也算合成回流）。
            // ⚠️ v1.0.133（ctor-30 实锤）：**去掉 ph==2**——残留 Stationary 是【上一轮】
            // 的，不证明本轮送达。v1.0.129 加 ph==2 后，顶掉循环里残留常驻点击点 →
            // verify 永远「看到送达」→ 顶掉 SID 永不淘汰（ctor-30：每轮 7 次顶掉 +
            // verdict deferred, lock kept 永驻 → 无连续连点 + 残留堆积小白条）。
            // 本轮送达只看新 down 的 Began（ph==0）/Moved（ph==1）；v1.0.132 的
            // 30ms+35ms 无重叠注入下新 down 必有 Began。探测判定仍保留 ph==2（ctor-23）。
            if (g_VerifyDelivering && !onBall && (ph == 0 || ph == 1)) {
                double vcx = gClickLockX * gScreenW;
                double vcy = gClickLockY * gScreenH;
                double vdist = sqrt((loc.x - vcx) * (loc.x - vcx) + (loc.y - vcy) * (loc.y - vcy));
                if (vdist < 200.0) {
                    g_VerifySawSynthetic = YES;
                    g_VerifySawCount++; // v1.0.135：回流计数（顶掉检测：比例 <50% 淘汰）
                }
            }
            if (ph == 0) {                                   // Began
                if (onBall && gBallTouch == NULL) {
                    gBallTouch = tp;
                    gBallTouchDownTime = now;
                    // ⚠️ v1.0.132：v1.0.131 的「顶掉重绑时间窗检测」已删除——ctor-29 实锤
                    // 顶掉后系统重绑可 <0.2s（并非 0.5-2.5s），时间窗不可靠。顶掉 vs 快速
                    // 短按的可靠区分改由 verify 裁决：「窗口内无送达回流（g_VerifySawSynthetic
                    // ==NO）且松手」= 顶掉/空跑 → 淘汰 SID（FTVerifyDeliveryTimer 已实现）。
                    // v1.0.108：探测期间系统重发 Began（手指被顶掉后重绑复活）
                    // → 恢复「不顶掉」验证能力，后续送达型 SID 可直接锁定
                    if (g_Probing) g_ProbeFingerDead = NO;
                    // v1.0.80：若正在连点且系统因注入把上一根手指 Ended 后重发了 Began
                    // （用户仍物理按着），重绑并【取消松手宽限】，连点继续。
                    if (gIsClicking) {
                        gStopGracePending = NO;
                        gBallTouchClicking = YES;
                    } else {
                        // 排一个 120ms 延时计时器：到时若手指仍按着（gBallTouch 不变）且非拖动模式，
                        // 就开连点。⚠️ 不能等 Moved/Stationary 事件——静止按住时 iOS 不投递这些事件
                        // （ctor-44 实测：1.6s 按住零 phase=1/2，导致旧逻辑从未触发、零点击）。
                        if (!gBallTouchTimerPending) {
                            gBallTouchTimerPending = YES;
                            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                                             dispatch_get_main_queue(), NULL, FTBallHoldTimer);
                        }
                    }
                }
            } else if (ph == 1 || ph == 2) {                 // Moved / Stationary（仅作保险，主要靠计时器）
                // v1.0.101：探测期间或未锁定 SID 时禁止直接连点（必须走探测校准）
                // ⚠️ v1.0.119：stab 裁决前不重启（顶掉后重绑的 Moved 会走这里，防顶掉循环）
                if (gBallTouch == tp && !gBallTouchClicking && !gDragMode && !g_Probing && g_LockedSID != 0 &&
                    !(g_StabTesting && g_StabFail) &&
                    (now - gBallTouchDownTime) > 0.12 && !gBallTouchTimerPending) {
                    gBallTouchClicking = YES;
                    FTStartClicking();
                }
            } else if (ph == 3 || ph == 4) {                 // Ended / Cancelled
                // ⚠️ v1.0.122：不再只依赖 gBallTouch==tp 指针匹配——iOS 可能在 Began 与
                // Ended 之间重建 touch 对象（指针不同 → 匹配失败 → gBallTouch 残留幽灵 →
                // 120ms 计时器照样触发连点且无人能停 → 「点一下立马松手还是长按状态」）。
                // ⚠️ v1.0.127 定案（ctor-24「轻按触发长时间连击，手指早已离开」）：v1.0.122
                // 的纯位置判断（球上/40px）太严——轻按松手时系统报告的 Ended 位置可能滑出
                // 球外 >40px（手指抬起偏移/系统坐标抖动）→ 判 nearBall 失败 → gBallTouch
                // 残留 → 幽灵连点。改【指针匹配 OR 位置 100px】双条件：指针匹配抓大多数
                // Ended；位置放宽兜底对象重建。合成触摸的 Ended（点击点位置距球通常 >100px
                // 且指针不同）不会被误清 → 连点不被合成手指中断。
                BOOL endedMatches = (gBallTouch == tp);
                BOOL nearBall = onBall;
                if (!nearBall) {
                    double bdx = loc.x - (bf.origin.x + bf.size.width * 0.5);
                    double bdy = loc.y - (bf.origin.y + bf.size.height * 0.5);
                    nearBall = (bdx * bdx + bdy * bdy < 100.0 * 100.0);
                }
                if (gBallTouch != NULL && (endedMatches || nearBall)) {
                    // v1.0.108：探测中手指 Ended 分两种情况：
                    //  · 探测 tap 注入后 300ms 内（顶掉）→ 记录 SID 进跳过列表 + 置
                    //    g_ProbeTouchEnded（FTCheckProbe 自动继续扫，找送达型保底，用户
                    //    不用干等 2-3 分钟）；若系统重发 Began（重绑复活）→ 清 dead 标志。
                    //  · 距注入 >300ms（真松手）→ 立即停止探测回蓝（不再空转）。
                    if (g_Probing) {
                        if ((now - g_ProbeTapT0) < 0.3 && g_ProbeSID) {
                            bool dup = false;
                            for (int k = 0; k < g_ProbeEndingCount; k++) {
                                if (g_ProbeEndingSIDs[k] == g_ProbeSID) { dup = true; break; }
                            }
                            if (!dup && g_ProbeEndingCount < 64) {
                                g_ProbeEndingSIDs[g_ProbeEndingCount++] = g_ProbeSID;
                            }
                            g_ProbeTouchEnded = YES; // 顶掉 → FTCheckProbe 自动继续
                        } else {
                            g_ProbeTouchEnded = NO;
                            g_Probing = NO;
                            FTApplyBallAppearance(); // 回蓝（真松手）
                            FTLog("probe stopped: finger released");
                        }
                    }
                    gBallTouch = NULL;
                    gBallTouchTimerPending = NO;
                    // v1.0.94+（豆包方案）：touchesEnded（手指抬起）/ touchesCancelled（滑出球/
                    // 系统手势打断）→ 排短宽限，无新 Began 即停止连点（接近立刻终止）。
                    // v1.0.96：宽限 120ms→200ms——registryID 首选若送达且不顶掉，这里的
                    // Ended/Cancelled 是真实松手信号（200ms 停感知即时）；若顶掉仍在
                    // （fallback captured），200ms 宽限 = 每轮 ~20 次（比 120ms 的 13 次好）。
                    // ⚠️ v1.0.109：200ms → 100ms——ctor(2) 用户反馈「停止按压后还是有延迟」；
                    // 现在连点机制稳定（touches-ended 即停），100ms 宽限仍可吸收注入导致的
                    // 边界重发 Began，同时停止感知更即时。
                    // ⚠️ v1.0.113：100ms → 50ms——ctor-9 用户反馈「手离不能立马停」；
                    // 真送达 SID 下 touches-ended 即真实松手，50ms 仅吸收极端边界重发。
                    gBallTouchClicking = NO;
                    if (gIsClicking && !gStopGracePending) {
                        gStopGracePending = YES;
                        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                                         dispatch_get_main_queue(), NULL, FTStopGraceTimer);
                    }
                }
            }
        }
    }

    // 诊断节流（保留原 SEND 日志）
    static double sLastDiag = 0;
    if (now - sLastDiag < 0.5) return; // 节流 500ms
    sLastDiag = now;
    if (!event) return;
    id touches = ((Msg_Send)objc_msgSend)(event, sel_registerName("allTouches"));
    NSUInteger n = touches ? ((Msg_Count)objc_msgSend)(touches, sel_registerName("count")) : 0;
    if (n == 0) return;
    // v1.0.42 诊断：标记命中窗口是否为我们的球窗口（区分注入触摸被拦截 vs 到达下层）
    // v1.0.44 诊断：加 UITouch phase/tapCount（判断 down/up 是否关联成完整 tap）
    // v1.0.49 诊断：加 locationInWindow 像素坐标——判断坐标单位是否被 UIKit 误解
    //  （注入传归一化 0~1，若 UIKit 期望像素 → 触摸落在屏幕角落 → hitTest 命中不了图标）
    // v1.0.55+：球现在是 window 的 subview（非独立 window），self==gBallContainer 不可靠。
    // v1.0.58：gBallContainer 改为 _UISystemGestureWindow（接收所有触摸），self==gBallContainer 恒真。
    // 因此 isBall 只判触摸坐标是否落在球 frame 内——命中球时 ball=1，否则 0。
    const char *cls = "?";
    const char *winCls = object_getClassName(self);
    if (!winCls) winCls = "?";
    long ph = -1, tapc = -1;
    double lx = -1, ly = -1;
    id t = ((Msg_AnyObject)objc_msgSend)(touches, sel_registerName("anyObject"));
    if (t) {
        id v = ((Msg_Send)objc_msgSend)(t, sel_registerName("view"));
        if (v) cls = object_getClassName(v);
        ph = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("phase"));
        tapc = (long)((Msg_Int)objc_msgSend)(t, sel_registerName("tapCount"));
        CGPoint loc = ((Msg_LocationInView)objc_msgSend)(t, sel_registerName("locationInView:"), nil);
        lx = loc.x; ly = loc.y;
    }
    BOOL isBall = NO;
    if (gBallView && lx >= 0 && ly >= 0) {
        CGRect bf = ((Msg_Frame)objc_msgSend)(gBallView, sel_registerName("frame"));
        if (lx >= bf.origin.x && lx <= bf.origin.x + bf.size.width &&
            ly >= bf.origin.y && ly <= bf.origin.y + bf.size.height) {
            isBall = YES;
        }
    }
    char buf[240];
    snprintf(buf, sizeof(buf), "SEND touches=%lu view=%s win=%s ball=%d phase=%ld tap=%ld loc=%.1f,%.1f",
             (unsigned long)n, cls, winCls, isBall ? 1 : 0, ph, tapc, lx, ly);
    FTLog(buf);
}
%end

// v1.0.41 诊断 hook：确认真实触摸是否经过 UIApplication _handleHIDEvent:（HID 入口）
%hook UIApplication
- (void)_handleHIDEvent:(void *)event {
    %orig;
    static double sLastHID = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
    if (now - sLastHID < 1.0) return; // 节流 1s
    sLastHID = now;
    if (event) FTLog("UIApp handleHIDEvent called");
}
%end

// MARK: - 入口（纯 C constructor，等效 %ctor 但无 Logos 依赖、零 ObjC）

__attribute__((constructor))
static void FTTweakCtor(void) {
    syslog(LOG_ERR, "FloatingTap v1.0.135 loaded (return-ratio eviction - enders <50%% return, stable >90%%; residual rebuild-ctx)");

    // v1.0.50：对接 AutoTap App——App 是启动器（选目标 App/位置/间隔），tweak 执行。
    if (FTIsBundle("com.apple.springboard")) {
        // 【诊断标记】SB 进程覆盖写
        FILE *mk = fopen("/tmp/floatingtap_ctor.log", "w");
        if (mk) {
            fprintf(mk, "FloatingTap v1.0.135 ctor run (arm64e, pure C, ball on _UISystemGestureWindow; return-ratio eviction)\n");
            fclose(mk);
        }
        syslog(LOG_ERR, "FloatingTap role: SpringBoard controller");

        // ⚠️ v1.0.50 教训：FTRegisterNotifications 不能放 ctor——它内部有 ObjC 动态调用
        // （FTStr/NSDictionary），%ctor 阶段 ObjC 调用在 arm64e 下 PAC 崩 → Safe Mode。
        // 已移到 FTTweakInitCallback（SB 完全启动 30s 后）。

        // 延迟 30s 等 SB 完全启动，再动态创建悬浮球
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), NULL, FTTweakInitCallback);
    }
}

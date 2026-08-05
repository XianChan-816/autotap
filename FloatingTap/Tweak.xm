//
//  Tweak.xm
//  FloatingTap
//
//  Logos 入口：SpringBoard 启动后启动前台 App 监控 + 注册 Darwin notification 监听。
//  注入目标：com.apple.springboard（见 FloatingTap.plist）
//
//  行为：每 2s 检测一次前台 App，若其 bundleID 在共享配置
//  （App 沙盒 ~/Library/Caches/AutoTapConfig.plist 的 Targets 列表）中，
//  则显示悬浮球；离开目标 App 立即隐藏。不再全局常驻。
//
//  跨进程通信：
//  - 监听 AutoTap.app 启动的 Darwin notification（CFNotificationCenter GetDarwinNotifyCenter）
//  - 收到后用 proc_listpids + sandbox_get_container_for_pid 找 App 沙盒 Caches 路径
//  - 之后所有 plist 读写都通过该路径（App 100% 可读自己沙盒）
//

#import "FloatingBallView.h"
#import <notify.h>
#import <dlfcn.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/param.h>

// Darwin notification 名（与 AutoTap/Sources/TargetAppManager.swift 严格一致）
static NSString *const kFTNotifyAppStarted = @"com.floatingtap.autotap.appStarted";
static NSString *const kFTNotifyConfigUpdated = @"com.floatingtap.autotap.configUpdated";
static NSString *const kFTNotifyTweakDataUpdated = @"com.floatingtap.autotap.tweakDataUpdated";

// 私有 API sandbox_container_path_for_pid 通过 dlsym 动态解析（SDK 无声明，避免编译报错）
// 签名：int sandbox_container_path_for_pid(pid_t pid, char *buf, size_t bufsize);
typedef int (*FTSandboxContainerPathForPID)(pid_t, char *, size_t);
static FTSandboxContainerPathForPID gSandboxPathForPid = NULL;
static void FTSandboxLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSandboxPathForPid = (FTSandboxContainerPathForPID)dlsym(RTLD_DEFAULT, "sandbox_container_path_for_pid");
        NSLog(@"[FloatingTap] sandbox_container_path_for_pid 解析: %p", gSandboxPathForPid);
    });
}

// 找到 App 沙盒 Caches 路径后通知 tweak 写入端
static pid_t gAppPID = 0;  // 0 = 未发现

// 通过进程名查找 PID（找所有同名进程的最新一个）
// 用 sysctl KERN_PROC_ALL 枚举（公开 POSIX API，iOS SDK 头文件齐全；
// proc_listpids/proc_name 是 macOS 专用头文件 libproc.h，iOS SDK 没有）
static pid_t FTFindAppPID(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return 0;
    pid_t found = 0;
    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        int count = (int)(size / sizeof(struct kinfo_proc));
        for (int i = 0; i < count; i++) {
            const char *comm = procs[i].kp_proc.p_comm;
            if (comm[0] == '\0') continue;
            if (strncmp(comm, "AutoTap", strlen("AutoTap")) == 0) {
                found = procs[i].kp_proc.p_pid;  // 取最后一个（一般是前台）
            }
        }
    }
    free(procs);
    return found;
}

// 用 sandbox_container_path_for_pid 拿 App 沙盒根路径，然后拼 Caches/ 子目录
// 私有 API（libsystem_sandbox.dylib），dlsym 解析；返回 0 成功，
// buf 写入 /var/mobile/Containers/Data/Application/<UUID>/
static NSString *FTResolveAppCaches(pid_t pid) {
    if (pid <= 0) return nil;
    FTSandboxLoad();
    if (!gSandboxPathForPid) {
        NSLog(@"[FloatingTap] sandbox_container_path_for_pid 未解析到，无法定位 App 沙盒");
        return nil;
    }
    char buf[PATH_MAX] = {0};
    int ret = gSandboxPathForPid(pid, buf, sizeof(buf));
    if (ret != 0 || buf[0] == '\0') {
        NSLog(@"[FloatingTap] sandbox_container_path_for_pid 失败: pid=%d ret=%d", pid, ret);
        return nil;
    }
    NSString *root = [NSString stringWithUTF8String:buf];
    NSString *caches = [root stringByAppendingPathComponent:@"Library/Caches/"];
    NSLog(@"[FloatingTap] App 沙盒 Caches 路径: %@", caches);
    return caches;
}

// 收到 App 启动通知后：找 App PID → 拿沙盒路径 → 立即写心跳 + 导出
// 注意：C 函数里不能使用 @synchronized（ObjC 语法仅限方法），Darwin notification
// 回调运行在主 run loop，天然串行，无需加锁。
static void FTOnAppStarted(void) {
    if (gAppPID <= 0) {
        gAppPID = FTFindAppPID();
    }
    if (gAppPID <= 0) {
        NSLog(@"[FloatingTap] 找不到 AutoTap 进程");
        return;
    }
    NSString *caches = FTResolveAppCaches(gAppPID);
    if (!caches) {
        NSLog(@"[FloatingTap] 拿不到 App 沙盒 Caches 路径");
        return;
    }
    FTSetAppCachesDir(caches);
    // 立即写心跳 + 导出 App 列表（此时 App 还没装载 UI，时间充裕）
    @try { [FloatingBallView writeHeartbeat]; }
    @catch (NSException *ex) { NSLog(@"[FloatingTap] 启动心跳异常: %@", ex); }
    @try { [[FloatingBallView shared] dumpInstalledApps]; }
    @catch (NSException *ex) { NSLog(@"[FloatingTap] 启动枚举异常: %@", ex); }
    // 通知 App 数据已就绪
    notify_post([kFTNotifyTweakDataUpdated UTF8String]);
}

// 收到 App configUpdated 通知后：重新读 config（目标 App / 间隔 / 位置）
static void FTOnConfigUpdated(void) {
    @try {
        // 影响 FloatingBallView 内部缓存，调用 updateVisibilityForFrontmostApp 重新读取
        // 同时悬浮球重定位（loadClick 在 present/dismiss 时读取）
        // 简单做法：让 UIMonitor 下一个 tick 重新读
        // 这里只打一行日志，真正的 reload 由轮询线程触发
        NSLog(@"[FloatingTap] 收到 App configUpdated 通知，下个轮询 tick 会重新读取配置");
    } @catch (NSException *ex) {
        NSLog(@"[FloatingTap] configUpdated 回调异常: %@", ex);
    }
}

// Darwin notification 回调
static void FTNotificationCallback(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    if ([n isEqualToString:kFTNotifyAppStarted]) {
        FTOnAppStarted();
    } else if ([n isEqualToString:kFTNotifyConfigUpdated]) {
        FTOnConfigUpdated();
    }
}

// 注册 Darwin notification 监听
static void FTRegisterNotifications(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL,
                                    FTNotificationCallback,
                                    (__bridge CFStringRef)kFTNotifyAppStarted,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL,
                                    FTNotificationCallback,
                                    (__bridge CFStringRef)kFTNotifyConfigUpdated,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    NSLog(@"[FloatingTap] Darwin notification 监听已注册");
}

%ctor {
    // 1. 立即注册 Darwin notification 监听（安全，不碰 UIKit）
    @try { FTRegisterNotifications(); }
    @catch (NSException *ex) { NSLog(@"[FloatingTap] 注册通知异常: %@", ex); }

    // 2. 尝试主动找 App 沙盒（如果 App 已经在运行，比如 SB 重启）
    @try {
        pid_t pid = FTFindAppPID();
        if (pid > 0) {
            gAppPID = pid;
            NSString *caches = FTResolveAppCaches(pid);
            if (caches) {
                FTSetAppCachesDir(caches);
                @try { [FloatingBallView writeHeartbeat]; }
                @catch (NSException *ex) { NSLog(@"[FloatingTap] 启动心跳异常: %@", ex); }
            }
        }
    } @catch (NSException *ex) {
        NSLog(@"[FloatingTap] 主动解析 App 沙盒异常: %@", ex);
    }

    // 3. SpringBoard 完全启动后再启动监控（8 秒延迟，避免启动期 KVC 私有 API 导致 SB 崩溃）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                          repeats:YES
                                                            block:^(NSTimer *t) {
            // 整个轮询用 @try/@catch 包裹，KVC 抛异常不会拖死 SpringBoard
            @try {
                [[FloatingBallView shared] updateVisibilityForFrontmostApp];
            } @catch (NSException *ex) {
                NSLog(@"[FloatingTap] 轮询异常: %@", ex);
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        @try {
            [[FloatingBallView shared] updateVisibilityForFrontmostApp];
        } @catch (NSException *ex) {
            NSLog(@"[FloatingTap] 启动首检异常: %@", ex);
        }

        // 首次枚举（如果主动解析 App 沙盒失败，等待 App 启动通知）
        if (FTGetAppCachesDir()) {
            @try {
                [[FloatingBallView shared] dumpInstalledApps];
            } @catch (NSException *ex) {
                NSLog(@"[FloatingTap] 导出 App 清单异常: %@", ex);
            }
        }

        // 每 300s（5 分钟）刷新一次 App 清单（高频全量枚举耗 CPU 发热）
        NSTimer *dumpTimer = [NSTimer scheduledTimerWithTimeInterval:300
                                                              repeats:YES
                                                                block:^(NSTimer *t) {
            @try { [[FloatingBallView shared] dumpInstalledApps]; }
            @catch (NSException *ex) { NSLog(@"[FloatingTap] 刷新 App 清单异常: %@", ex); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:dumpTimer forMode:NSRunLoopCommonModes];

        // 每 30s 刷新心跳（让 App 端能判断 tweak 是否仍在运行）
        NSTimer *hbTimer = [NSTimer scheduledTimerWithTimeInterval:30
                                                           repeats:YES
                                                             block:^(NSTimer *t) {
            @try { [FloatingBallView writeHeartbeat]; }
            @catch (NSException *ex) { NSLog(@"[FloatingTap] 心跳刷新异常: %@", ex); }
        }];
        [[NSRunLoop mainRunLoop] addTimer:hbTimer forMode:NSRunLoopCommonModes];

        NSLog(@"[FloatingTap] 前台 App 监控已启动（2s 轮询）");
    });
}

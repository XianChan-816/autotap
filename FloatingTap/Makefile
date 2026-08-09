# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.20「纯 C 驱动的 ObjC 动态调用」：Tweak.xm（UI/交互）+ HIDInject.c（HID 连点引擎）。
# 铁律：dylib 内零 ObjC 元数据（无 @implementation、无 @"..."、无 block、无 @selector/__cfstring），
# 才能避开 ellekit 在 arm64e（M1）注入路径的 PAC 指针认证问题（已实测：有元数据→SB 崩/SafeMode）。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
# 必须 arm64 arm64e 双架构：M1 的 SpringBoard/backboardd 是 arm64e 进程，纯 arm64 无法注入。
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap BackboardInject

# FloatingTap：SB 侧悬浮球 + 连点（UI/交互 + 连点引擎 + backboardd socket 客户端）
FloatingTap_FILES = Tweak.xm HIDInject.c FTDaemonClient.c
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

# BackboardInject v2.6：backboardd 内注入（佳影同源架构 + PAC 解析 + rootless 路径修正）
#   6) v2.6 头号教训：注入 dylib 内的绝对路径会被运行时自动前缀 jbroot。
#        dylib "/tmp/X"        -> <jbroot>/tmp/X   == shell 的 /var/jb/tmp/X  ✓
#        dylib "/var/jb/tmp/X" -> <jbroot>/var/jb/tmp/X                       ✗ 死角
#      v2.5 的 guard 落在死角，postinst 清不掉，一次被打断的记账永久生效，
#      之后每次开机都是 "[GUARD] 上次未存活 -> 自动禁用"，注入根本没跑起来。
#      对策：dylib 侧全改 /tmp/；guard 加 build id（新构建自动作废）；
#            阈值 1 -> 2（防"装完立刻重启"误判）；存活窗 36s -> 15s。

#   4) v2.3 黑屏根因 = 盲信 MSFindSymbol 返回值（带 PAC 的指针当裸地址用）。
#   5) v2.4 实测（未黑屏，四道防线拦住了）：
#        raw 0x8a514a818d8268a4 -> dladdr 成功 symaddr=0x18d8268a4，但 raw 不可读 -> REJECT
#      真相：iOS 用户态 VA 是 36 位（T0SZ=28），PAC 占 bit36..62；
#            真地址 = 低 36 位 = 0x18d8268a4 = IOKit 基址 0x18d820000 + 0x68a4。
#            v2.4 手工掩码用了 47 位（macOS 规格）→ 剥不干净；
#            而 dladdr 自带剥离，正确答案本来就在 dli_saddr 里，被 v2.4 丢了。
#   v2.5 对策：
#      · FTResolvePlain 候选阶梯 dli_saddr → XPACI → &36位 → &47位 → 原值，
#        逐个 vm_read_overwrite 试读，第一个读得通的才用。
#      · 调用面 / patch 面分离：MSHookFunction 收裸地址；orig 求出裸地址后
#        用 ptrauth_sign_unauthenticated 重新签名再调（arm64e 走 blraaz 认证，
#        arm64 slice 则原样 blr）——两种 slice 都不会跳飞。
#      · 死人开关：hook 装上但 orig 不可用（触摸会失效）时故意不标 SAFE，重启即禁用。
#      · 回调内严禁 fopen/malloc/syslog，只用预开 fd 的裸 write() 打探针。
# 黑屏教训链：
#   1) SafeProbe（ctor 只 fopen）→ 加载安全，实测不黑屏
#   2) v2.1 黑屏根因 = ctor 里 dispatch_after_f（GCD API）
#   3) v2.2 黑屏根因 = 在 backboardd 内调用 IOHIDEventSystemClientCreate
#      （backboardd 本身是 HID 服务端，自己连自己 → 死锁 → 看门狗杀进程）
#      实锤：佳影导入表【没有】ClientCreate/DispatchEvent
# 本版改为佳影真实路线：
#   · MSHookFunction hook IOKit 私有函数 ___IOHIDServiceEventCallback
#   · 真实触摸时捕获 (target, refcon, IOHIDServiceRef) 三件套
#   · 注入 = 直接调用原始回调把事件喂回 backboardd 管线（零客户端、零 SID 探测）
#   · 全程零 GCD：socket 用阻塞 accept 线程，连点用独立 pthread
#   · 开机自愈保险：崩一次→下次开机自动禁用（不用进安全模式）
#   · 分级开关 /var/jb/tmp/ftb_stage
#     0关闭 1符号 2定位+校验 3挂钩纯透传(默认) 4加GetType捕获 5socket+注入
# SB 侧 FTDaemonClient 协议不变（socket /var/jb/tmp/floatingtapd.sock）
BackboardInject_FILES = BackboardInject.c
BackboardInject_CFLAGS = -Wno-deprecated-declarations
BackboardInject_FRAMEWORKS = CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

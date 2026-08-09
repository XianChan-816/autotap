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

# BackboardInject v2.3：backboardd 内注入（佳影同源架构）
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
#   · 分级开关 /var/jb/tmp/ftb_stage（0关闭 1符号 2定位 3挂钩 4完整）
# SB 侧 FTDaemonClient 协议不变（socket /var/jb/tmp/floatingtapd.sock）
BackboardInject_FILES = BackboardInject.c
BackboardInject_CFLAGS = -Wno-deprecated-declarations
BackboardInject_FRAMEWORKS = CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

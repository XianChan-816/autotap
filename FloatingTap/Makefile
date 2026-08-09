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

# FloatingTap：SB 侧悬浮球 + 连点（UI/交互 + socket 客户端）
# v2.0: 增加 FTDaemonClient（socket 客户端，连点注入走 backboardd 内 BackboardInject）
FloatingTap_FILES = Tweak.xm HIDInject.c FTDaemonClient.c
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

# BackboardInject：注入 backboardd 的触摸注入 dylib（v2.1 根治方案）
# 参考佳影 BackboardService.dylib：在 backboardd 进程内部创建/派发 digitizer 事件，
# 继承 backboardd 的系统 HID entitlement → dispatch 有效（独立 daemon 无 entitlement，
# ret=0x1 被拒，floatingtapd v2.0-daemon1/2/3 全失败实锤）。
# ⚠️ backboardd = 危险等级 1（报告 §三）：constructor 只写日志，IOHID 初始化延迟到
# 主队列就绪后（BackboardInject.c 内 dispatch_after 重试），绝不能在 ctor 早期
# dlopen/dispatch（BackboardProbe 黑屏事故）。
BackboardInject_FILES = BackboardInject.c
BackboardInject_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BackboardInject_FRAMEWORKS = CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

# ⚠️ 已移除：floatingtapd 独立 daemon（TOOL）——独立进程无 HID entitlement，
# IOHIDEventSystemClientDispatchEvent 全 ret=0x1 被拒（v2.0-daemon1/2/3 实测）。
# 触摸注入只能在 backboardd 进程内部做（继承其 entitlement），即 BackboardInject。
# 同时移除：BackboardProbe（backboardd 内 constructor 早期初始化 → 黑屏，报告 §一）。

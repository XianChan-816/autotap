# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.20「纯 C 驱动的 ObjC 动态调用」：Tweak.xm（UI/交互）+ HIDInject.c（HID 连点引擎）。
# 铁律：dylib 内零 ObjC 元数据（无 @implementation、无 @"..."、无 block、无 @selector/__cfstring），
# 才能避开 ellekit 在 arm64e（M1）注入路径的 PAC 指针认证问题（已实测：有元数据→SB 崩/SafeMode）。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
# 必须 arm64 arm64e 双架构：M1 的 SpringBoard 是 arm64e 进程，纯 arm64 无法注入。
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap BackboardProbe

# FloatingTap：SB 侧悬浮球 + 连点（现有逻辑）
FloatingTap_FILES = Tweak.xm HIDInject.c
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

# BackboardProbe：backboardd 进程内 IOHID 注入最小原型（v2.0 方向验证）
# 目的：验证「在触摸分发源头(backboardd)注入 → 系统当真实触摸 → 不顶掉用户手指」
BackboardProbe_FILES = BackboardProbe.c
BackboardProbe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BackboardProbe_FRAMEWORKS = CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

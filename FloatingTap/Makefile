# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.20「纯 C 驱动的 ObjC 动态调用」：Tweak.xm（UI/交互）+ HIDInject.c（HID 连点引擎）。
# 铁律：dylib 内零 ObjC 元数据（无 @implementation、无 @"..."、无 block、无 @selector/__cfstring），
# 才能避开 ellekit 在 arm64e（M1）注入路径的 PAC 指针认证问题（已实测：有元数据→SB 崩/SafeMode）。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
# 必须 arm64 arm64e 双架构：M1 的 SpringBoard 是 arm64e 进程，纯 arm64 无法注入。
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap

# FloatingTap：SB 侧悬浮球 + 连点（现有逻辑）
# v2.0: 增加 FTDaemonClient（XPC 客户端，连点注入走独立 daemon floatingtapd）
FloatingTap_FILES = Tweak.xm HIDInject.c FTDaemonClient.c
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz
# XPC 是系统库（libxpc），Tweak 链接不需要额外框架；libSystem 自带

include $(THEOS_MAKE_PATH)/tweak.mk

# ---- floatingtapd：独立注入 daemon（v2.0 根治方案） ----
# 独立 launchd daemon 进程持有 IOHIDEventSystemClient + DispatchEvent，
# 不在 SB 进程内注入 → 不参与 SB 手势窗口路由 → 崩了只崩 daemon 自己。
# 对应构建安全报告 §七.2 首选路线（独立 daemon 验证"不顶掉"）。
TOOL_NAME = floatingtapd

floatingtapd_FILES = FloatingTapDaemon.c
floatingtapd_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
floatingtapd_FRAMEWORKS = CoreFoundation
floatingtapd_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

# ⚠️ BackboardProbe（backboardd 内注入原型）已从构建中移除——
# 它在 constructor 早期 dlopen+dispatch 导致 backboardd 启动失败 → 整机黑屏
#（见 FloatingTap构建安全报告 §一）。注入验证一律走 floatingtapd 独立 daemon。

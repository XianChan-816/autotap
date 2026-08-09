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

# BackboardInject v2.2：backboardd 内注入（佳影式，第二阶段）
# 安全链已验证：
#   1) SafeProbe（ctor 只 fopen）→ 加载安全，不黑屏（bb_safe_probe.log 实测）
#   2) v2.1 黑屏根因 = ctor 里 dispatch_after_f（GCD API），违反报告 §三铁律
# 本版：
#   · constructor 只写日志（验证安全）
#   · pthread_create 后台线程（纯 POSIX，ctor 阶段安全）sleep 3s 后初始化
#   · 佳影同源事件构造（IOHIDEventCreateDigitizerEvent 字段与佳影 0xd46c 一致）
#   · backboardd 进程内有 HID entitlement → DispatchEvent 应有效
#   · 连续 50 次失败自动关 socket → SB 回退旧注入（防死锁）
# SB 侧 FTDaemonClient 协议不变（socket /var/jb/tmp/floatingtapd.sock）
BackboardInject_FILES = BackboardInject.c
BackboardInject_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
BackboardInject_FRAMEWORKS = CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.20「纯 C 驱动的 ObjC 动态调用」：Tweak.xm（UI/交互）+ HIDInject.c（HID 连点引擎）。
# 铁律：dylib 内零 ObjC 元数据（无 @implementation、无 @"..."、无 block、无 @selector/__cfstring），
# 才能避开 ellekit 在 arm64e（M1）注入路径的 PAC 指针认证问题（已实测：有元数据→SB 崩/SafeMode）。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
# 必须 arm64 arm64e 双架构：M1 的 SpringBoard/backboardd 是 arm64e 进程，纯 arm64 无法注入。
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap BackboardSafeProbe

# FloatingTap：SB 侧悬浮球 + 连点（UI/交互 + 连点引擎，纯 SB 注入）
# ⚠️ v2.1 回退：BackboardInject（注入 backboardd）已移除——实测黑屏
#（backboardd 注入即使延迟初始化仍有 ellekit/PAC 崩溃风险）。触摸注入
# 回到绝对安全的 SB 进程内（崩 = 安全模式，永不黑屏）。
# v2.0 的 FTDaemonClient（socket 客户端）一并移除——独立 daemon 无 HID
# entitlement（dispatch 全 0x1），backboardd 注入黑屏，两条路都走不通。
FloatingTap_FILES = Tweak.xm HIDInject.c
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

# BackboardSafeProbe：backboardd 注入【加载安全】最小验证 dylib
# ⚠️ 只测「ellekit 加载 backboardd dylib 本身是否黑屏」——constructor 只写日志，
# 零 API 调用。装上重启后看 /tmp/bb_safe_probe.log：
#   有 ctor 行 = 加载安全 → 下一步做佳影式服务回调注入；
#   黑屏 = 加载环节就崩 → backboardd 注入路线彻底放弃。
# 本文件必须与 FloatingTap 同 deb 打包（当前无功能冲突），黑屏时 Sileo 整体卸载。
BackboardSafeProbe_FILES = BackboardSafeProbe.c
BackboardSafeProbe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

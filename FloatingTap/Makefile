# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.13 零 ObjC 类验证版：只编译 Tweak.xm（纯 C + objc_msgSend 动态调用）。
# 背景：任何含 @implementation 的 dylib 注入 SpringBoard 都卡死（与 ElleKit 版本无关）。
# 本版彻底不定义自定义 ObjC 类，验证注入不再卡死且小球可显示。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
# v1.0.16: 去掉 arm64e，只编 arm64。
# 根因：崩溃日志显示 FloatingTap.dylib 以 arm64e 注入 M1 时，%ctor 内 NSLog 的
# objc_msgSend 触发 ARM64E PAC（指针认证）失败 → SB 崩 → Safe Mode。
# 只编 arm64（无 PAC）在 M1 上可正常运行，ElleKit 注入不走指针认证，绕开此坑。
export ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap

# 零 ObjC 类：只编译 Tweak.xm（不编译 FloatingBallView.m / HIDInject.m / MinimalClass.m）
FloatingTap_FILES = Tweak.xm
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk

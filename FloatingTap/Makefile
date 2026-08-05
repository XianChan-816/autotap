# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.19 「纯 C 驱动的 ObjC 动态调用」版：只编译 Tweak.xm。
# 背景链：
#   - v1.0.9（双架构 + 空 %ctor）不卡；v1.0.11/12（双架构 + 含 ObjC 类）卡；
#   - v1.0.13/14（双架构 + %ctor 里 NSLog(@"...")）PAC 崩 → SafeMode；
#   - v1.0.16~18（纯 arm64）→ 不注入（M1 的 SpringBoard 是 arm64e 进程，只收 arm64e slice）。
# 结论：必须编回 arm64e 才能注入；且 dylib 内零 ObjC 元数据（无类、无 @"..."、无 block、
# 无 @selector/__cfstring）才能避开 ellekit 注入路径的 PAC 指针认证问题。
# 本版恢复双架构，代码全部纯 C + objc_msgSend 动态调系统类。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
# v1.0.19: 恢复 arm64 arm64e（纯 arm64 无法注入 arm64e 的 SpringBoard）。
# 代码已做到零 ObjC 元数据，arm64e slice 在 ellekit 注入路径下不再触发 PAC 失败。
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap

# 零 ObjC 类：只编译 Tweak.xm（不编译 FloatingBallView.m / HIDInject.m / MinimalClass.m）
FloatingTap_FILES = Tweak.xm
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk

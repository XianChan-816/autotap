# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.11 二分诊断版：空 Tweak.xm + 只加回 HIDInject.m（不含 FloatingBallView.m）。
# 定位卡屏元凶文件：卡 = HIDInject.m；不卡 = FloatingBallView.m。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap

# 只编译空 Tweak.xm + HIDInject.m（排除 FloatingBallView.m）
FloatingTap_FILES = Tweak.xm HIDInject.m
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk

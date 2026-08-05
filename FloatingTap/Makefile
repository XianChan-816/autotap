# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.12 二分诊断版：空 Tweak.xm + MinimalClass.m（一个空的 ObjC 类）。
# 目的：区分「任何 ObjC 类注入都卡」vs「HIDInject.m 具体内容导致卡」。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap

# 空 Tweak.xm + MinimalClass.m（空 ObjC 类）
FloatingTap_FILES = Tweak.xm MinimalClass.m
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk

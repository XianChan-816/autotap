# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# Theos / Logos 工程，注入 SpringBoard，悬浮球在任意 App 上显示。
# 构建：make clean package（rootless + arm64e，Dopamine 越狱环境）

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap

FloatingTap_FILES = Tweak.xm FloatingBallView.m HIDInject.m
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk

# FloatingTap — 全局悬浮球自动点击器（越狱 tweak）
# ⚠️ v1.0.9 超级空壳诊断版：只编译空的 Tweak.xm，不包含任何业务代码。
# 二分定位「装 deb 重启卡屏」：若此版仍卡 = deb 打包/注入/环境问题。

export THEOS_PACKAGE_SCHEME = rootless
export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FloatingTap

# 只编译空壳 Tweak.xm（排除 FloatingBallView.m / HIDInject.m 的加载时初始化）
FloatingTap_FILES = Tweak.xm
FloatingTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FloatingTap_FRAMEWORKS = UIKit CoreGraphics
FloatingTap_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk

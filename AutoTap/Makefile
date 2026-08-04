# AutoTap 构建脚本
#
# 用法：
#   make setup        # 安装 xcodegen（brew）
#   make project      # 生成 AutoTap.xcodeproj
#   make build        # 本地编译（Debug，不签名）
#   make ipa          # 打包无签名 .ipa（配合 TrollStore 注入）
#
# 注意：没有 Mac 也能打包 —— 使用 .github/workflows/build.yml 在 GitHub 云端构建。

XCODEGEN ?= xcodegen
PROJECT  := AutoTap
BUILD_DIR := build

.PHONY: setup project build ipa clean

setup:
	@command -v xcodegen >/dev/null 2>&1 || brew install xcodegen

project:
	$(XCODEGEN) generate --spec $(PROJECT)/project.yml

build: project
	xcodebuild \
		-project $(PROJECT).xcodeproj \
		-scheme AutoTap \
		-configuration Debug \
		-sdk iphoneos \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		build

ipa: build
	mkdir -p $(BUILD_DIR)/Payload
	cp -R $(BUILD_DIR)/DerivedData/Build/Products/Debug-iphoneos/AutoTap.app $(BUILD_DIR)/Payload/
	cd $(BUILD_DIR) && zip -qry AutoTap.ipa Payload/
	@echo "=============================================="
	@echo "  IPA 已生成: $(BUILD_DIR)/AutoTap.ipa"
	@echo "  将 ipa 发给 iPhone 后用 TrollStore 安装即可"
	@echo "=============================================="

clean:
	rm -rf $(BUILD_DIR) $(PROJECT).xcodeproj

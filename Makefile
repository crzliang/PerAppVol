# mac-sound-control —— 构建入口
#
#   make            构建 App + 全部工具
#   make app        只构建菜单栏 App（build/PerAppVol.app）
#   make tools      只构建命令行工具（build/{perappvol,apptap,volctl}）
#   make dmg        打包成 build/PerAppVol.dmg（可分发）
#   make install    安装到 /Applications 并启动
#   make run        构建并启动（不安装）
#   make clean      清理产物

BUILD  := build
CC     := clang
SWIFTC := swiftc

# 目前只出 arm64（Apple Silicon）。x86_64 未经测试，暂不产出。
ARCH   ?= arm64
export MACOSX_DEPLOYMENT_TARGET ?= 14.2
CLANG_FLAGS := -arch $(ARCH)
SWIFT_FLAGS := -target $(ARCH)-apple-macos$(MACOSX_DEPLOYMENT_TARGET)

OBJC_FLAGS  := -fobjc-arc -O2 -Wall $(CLANG_FLAGS)
FRAMEWORKS  := -framework CoreAudio -framework Foundation -framework CoreGraphics -framework AppKit

.PHONY: all app tools icon dmg install run autostart autostart-off clean

all: app tools

app:
	./build-app.sh

tools: $(BUILD)/perappvol $(BUILD)/apptap $(BUILD)/volctl

# 只生成图标（预览图在 build/AppIcon-preview.png）
icon: | $(BUILD)
	swiftc -O scripts/make-icon.swift -o $(BUILD)/make-icon -framework AppKit
	$(BUILD)/make-icon
	iconutil -c icns $(BUILD)/AppIcon.iconset -o $(BUILD)/AppIcon.icns
	@echo "✅ $(BUILD)/AppIcon.icns"

$(BUILD):
	mkdir -p $(BUILD)

# 混音引擎（也是 App bundle 里的那个二进制）
$(BUILD)/perappvol: src/engine/perappvol.m | $(BUILD)
	$(CC) $(OBJC_FLAGS) $< -o $@ $(FRAMEWORKS)

# 链路 PoC / 调试：进程枚举 + tap 抓取 + 聚合设备 dump
$(BUILD)/apptap: src/tools/apptap.m | $(BUILD)
	$(CC) $(OBJC_FLAGS) $< -o $@ -framework CoreAudio -framework Foundation -framework CoreGraphics

# 系统总音量 / 静音 / 切换默认输出设备（零权限）
$(BUILD)/volctl: src/tools/volctl.swift | $(BUILD)
	$(SWIFTC) -O $(SWIFT_FLAGS) $< -o $@

# 打包 DMG（App + Applications 快捷方式，可分发）
dmg:
	./make-dmg.sh

# 安装到 /Applications 并启动
install: app
	pkill -f "PerAppVol.app/Contents/MacOS/PerAppVol" 2>/dev/null || true
	pkill -f "PerAppVol.app/Contents/Resources/perappvol" 2>/dev/null || true
	rm -rf "/Applications/PerAppVol.app"
	cp -R "$(BUILD)/PerAppVol.app" /Applications/
	@echo "✅ 已安装到 /Applications/PerAppVol.app (arch=$(ARCH))"
	@echo "   首次运行需在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 里打开 PerAppVol"
	open "/Applications/PerAppVol.app"

# 开机自启（用户级 LaunchAgent，无需管理员权限）
# 说明：PerAppVol 不启动 = 没有 tap = 完全没有音量控制，所以这个很重要
autostart: install
	./scripts/autostart.sh on

autostart-off:
	./scripts/autostart.sh off

run: app
	open $(BUILD)/PerAppVol.app

clean:
	rm -rf $(BUILD)

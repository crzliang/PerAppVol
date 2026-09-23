# mac-sound-control —— 构建入口
#
#   make            构建 App + 全部工具
#   make app        只构建菜单栏 App（build/PerAppVol.app）
#   make tools      只构建命令行工具（build/{perappvol,apptap,volctl}）
#   make run        构建并启动
#   make clean      清理产物

BUILD  := build
CC     := clang
SWIFTC := swiftc

OBJC_FLAGS  := -fobjc-arc -O2 -Wall
FRAMEWORKS  := -framework CoreAudio -framework Foundation -framework CoreGraphics -framework AppKit

.PHONY: all app tools run clean

all: app tools

app:
	./build-app.sh

tools: $(BUILD)/perappvol $(BUILD)/apptap $(BUILD)/volctl

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
	$(SWIFTC) -O $< -o $@

run: app
	open $(BUILD)/PerAppVol.app

clean:
	rm -rf $(BUILD)

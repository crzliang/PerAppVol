#!/bin/bash
# build-app.sh —— 把引擎(perappvol)和菜单栏 UI 打包成 PerAppVol.app
#
# 为什么必须是 .app：TCC 权限（屏幕与系统音频录制）只授予有 bundle ID + 代码签名的
# bundle 身份。裸 CLI 只能算在"责任进程"（你的终端）头上。见 README 坑 6。
#
# 用法: ./build-app.sh      产出 build/PerAppVol.app
#       open build/PerAppVol.app

set -euo pipefail
cd "$(dirname "$0")"

APP=build/PerAppVol.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 编译混音引擎 (src/engine/perappvol.m)…"
clang -fobjc-arc -O2 src/engine/perappvol.m \
    -o "$APP/Contents/Resources/perappvol" \
    -framework CoreAudio -framework Foundation -framework CoreGraphics -framework AppKit

echo "▸ 编译菜单栏 UI (src/ui/PerAppVolApp.swift)…"
swiftc -O -parse-as-library src/ui/PerAppVolApp.swift \
    -o "$APP/Contents/MacOS/PerAppVol" \
    -framework SwiftUI -framework AppKit -framework CoreAudio

echo "▸ 写 Info.plist…"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>      <string>com.mac-sound-control.perappvol</string>
  <key>CFBundleName</key>            <string>PerAppVol</string>
  <key>CFBundleDisplayName</key>     <string>PerAppVol</string>
  <key>CFBundleExecutable</key>      <string>PerAppVol</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>14.2</string>
  <key>LSUIElement</key>             <true/>          <!-- 只有菜单栏图标，不占 Dock -->
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSAudioCaptureUsageDescription</key>
      <string>需要读取各 App 的音频，才能给每个 App 单独调节音量。</string>
  <key>NSSystemAudioCaptureUsageDescription</key>
      <string>需要读取各 App 的音频，才能给每个 App 单独调节音量。</string>
</dict>
</plist>
PLIST

echo "▸ 签名…"
# 关键：必须用【有稳定身份的签名】。ad-hoc 签名拿不到 TCC 授权 ——
#   实测 app 根本不会出现在 系统设置→隐私与安全性→屏幕与系统音频录制 的列表里。
# 可用 identity：security find-identity -v -p codesigning
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "SoundControl Local Signing"; then
        SIGN_IDENTITY="SoundControl Local Signing"
    fi
fi
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
    echo "  已用身份: $SIGN_IDENTITY"
else
    # 兼容回退：ad-hoc（只能自测引擎，拿不到 TCC）
    codesign --force --deep -s - "$APP"
    echo "  ⚠ 未找到签名身份，用了 ad-hoc —— 将无法取得 TCC 权限。"
    echo "    用 security find-identity -v -p codesigning 查看可用身份，再跑："
    echo "    SIGN_IDENTITY='你的身份' ./build-app.sh"
fi

echo
echo "✅ 完成: $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
echo
echo "运行:  open $APP"
echo "首次运行需在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 里打开 PerAppVol"

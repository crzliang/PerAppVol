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
ARCH="${ARCH:-arm64}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ 生成 App 图标 (scripts/make-icon.swift)…"
swiftc -O scripts/make-icon.swift -o build/make-icon -framework AppKit
build/make-icon >/dev/null
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo "  ✅ AppIcon.icns"

echo "▸ 编译混音引擎 (src/engine/perappvol.m)…"
# 架构显式钉死：目前只出 arm64（Apple Silicon）。
# 要出通用二进制改成 -arch arm64 -arch x86_64，但 x86 需要真机/CI 验证。
# 14.2 是 AudioHardwareCreateProcessTap 的最低版本。
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.2}"
# clang 认 -arch；swiftc 认 -target（不能混用）
CLANG_FLAGS="-arch $ARCH"
SWIFT_FLAGS="-target $ARCH-apple-macos${MACOSX_DEPLOYMENT_TARGET}"
clang -fobjc-arc -O2 $CLANG_FLAGS src/engine/perappvol.m \
    -o "$APP/Contents/Resources/perappvol" \
    -framework CoreAudio -framework Foundation -framework CoreGraphics -framework AppKit

echo "▸ 编译菜单栏 UI (src/ui/PerAppVolApp.swift)…"
swiftc -O -parse-as-library $SWIFT_FLAGS src/ui/PerAppVolApp.swift \
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
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundleIconName</key>        <string>AppIcon</string>
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
echo "✅ 完成: $APP  (arch=$ARCH, macOS >= ${MACOSX_DEPLOYMENT_TARGET:-14.2})"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
echo
echo "运行:  open $APP"
echo "首次运行需在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 里打开 PerAppVol"

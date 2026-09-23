#!/bin/bash
# make-dmg.sh —— 打包成可分发的 DMG
#
#   ./make-dmg.sh           产出 build/PerAppVol.dmg
#
# DMG 内容：PerAppVol.app + Applications 快捷方式（拖进去即安装）
#
# 关于签名/公证：
#   · 本机使用 —— 用本机签名身份即可（build-app.sh 会自动挑）。
#   · 分发给别的 Mac —— 必须用 Developer ID Application 签名 + 公证，
#     否则 Gatekeeper 会拦。见脚本末尾的说明。

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PerAppVol"
APP="build/$APP_NAME.app"
DMG="build/$APP_NAME.dmg"
STAGE="build/dmg-stage"
VOLNAME="$APP_NAME"

echo "▸ 构建 App…"
./build-app.sh

[ -d "$APP" ] || { echo "❌ 没找到 $APP"; exit 1; }

echo "▸ 组装 DMG 内容（App + Applications 快捷方式）…"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"

echo "▸ 生成压缩 DMG…"
rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"

echo "▸ 签名 DMG…"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "SoundControl Local Signing"; then
    SIGN_IDENTITY="SoundControl Local Signing"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
    echo "  已用身份: $SIGN_IDENTITY"
else
    echo "  ⚠ 未找到签名身份，DMG 未签名（仅本机可用）"
fi

echo
echo "✅ 完成: $DMG"
ls -lh "$DMG" | awk '{print "   大小:", $5}'
echo
echo "安装方式："
echo "  1. 双击 $DMG"
echo "  2. 把 PerAppVol 拖到 Applications"
echo "  3. 首次运行：系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 打开 PerAppVol"
echo
echo "本机直接安装可用:  make install"
echo
echo "—— 分发给别的 Mac 还需要 ——"
echo "  codesign --force --deep --options runtime --sign \"Developer ID Application: 你的名字 (TEAMID)\" build/$APP_NAME.app"
echo "  codesign --sign \"Developer ID Application: 你的名字 (TEAMID)\" $DMG"
echo "  xcrun notarytool submit $DMG --keychain-profile <profile> --wait"
echo "  xcrun stapler staple $DMG"

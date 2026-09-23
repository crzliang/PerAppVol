#!/bin/bash
# make-dmg.sh —— 打包 DMG
#
#   ./make-dmg.sh              本机用：用本机签名身份，产出 build/PerAppVol.dmg
#   ./make-dmg.sh --release    分发用：Developer ID 签名 + 公证 + 装订
#   ./make-dmg.sh --check      只检查分发前置条件
#
# 为什么要公证（notarization）：
#   macOS 的 Gatekeeper 会拦【未公证】的 app。给别人安装必须走：
#   Developer ID 签名 → hardened runtime → 公证 → 装订（staple）。
#
# 前置条件（分发用）：
#   1. Apple Developer Program 会员（99 USD/年）https://developer.apple.com/programs/
#   2. 「Developer ID Application」证书：
#        Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#      或 developer.apple.com → Certificates, Identifiers & Profiles → Developer ID Application
#   3. App 专用密码（用于公证）：appleid.apple.com → 登录与安全 → App 专用密码
#      然后存一次凭据（以后不用再输）：
#        xcrun notarytool store-credentials "notary-profile" \
#                --apple-id "you@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PerAppVol"
APP="build/$APP_NAME.app"
ARCH="${ARCH:-arm64}"
DMG="build/$APP_NAME-$ARCH.dmg"
STAGE="build/dmg-stage"
VOLNAME="$APP_NAME"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-profile}"

MODE="local"
for a in "$@"; do
    case "$a" in
        --release) MODE="release" ;;
        --check)   MODE="check" ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

# ─────────────────────────────────────────────────────────── 前置检查

find_dev_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)".*/\1/'
}
find_local_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "SoundControl Local Signing" | head -1 \
        | sed -E 's/.*"(.*)".*/\1/'
}

check_dist() {
    local ok=1
    echo "—— 分发前置条件检查 ——"

    if xcode-select -p >/dev/null 2>&1; then
        echo "  ✅ 命令行工具 / Xcode: $(xcode-select -p)"
    else
        echo "  ❌ 未安装命令行工具: xcode-select --install"; ok=0
    fi

    local dev
    dev=$(find_dev_id)
    if [ -n "$dev" ]; then
        echo "  ✅ Developer ID Application 证书: $dev"
    else
        echo "  ❌ 没有「Developer ID Application」证书"
        echo "     需要 Apple Developer Program 会员（99 USD/年）"
        echo "     Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
        ok=0
    fi

    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "  ✅ 公证凭据已就绪 (keychain-profile: $NOTARY_PROFILE)"
    else
        echo "  ❌ 公证凭据未配置"
        echo "     先去 appleid.apple.com 生成「App 专用密码」，然后："
        echo "     xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        echo "             --apple-id \"you@example.com\" --team-id \"TEAMID\" --password \"xxxx-xxxx\""
        ok=0
    fi

    if [ "$ok" = 1 ]; then
        echo
        echo "✅ 具备分发条件，可以跑:  ./make-dmg.sh --release"
    else
        echo
        echo "⚠  尚不具备分发条件。上面 ❌ 的项目需要你去 Apple Developer 后台操作。"
        echo "   在此之前可以 ./make-dmg.sh 打本机版自用，或把源码给别人自己 make。"
    fi
    return $((1 - ok))
}

if [ "$MODE" = "check" ]; then
    check_dist
    exit $?
fi

# ─────────────────────────────────────────────────────────── 构建

echo "▸ 构建 App…"
./build-app.sh
[ -d "$APP" ] || { echo "❌ 没找到 $APP"; exit 1; }

if [ "$MODE" = "release" ]; then
    echo "▸ 检查分发前置条件…"
    check_dist || { echo; echo "❌ 前置条件不足，已中止。"; exit 1; }
    DEV_ID=$(find_dev_id)
fi

# ─────────────────────────────────────────────────────────── 签名 App

echo "▸ 签名 App…"
if [ "$MODE" = "release" ]; then
    # 分发：Developer ID + hardened runtime + 时间戳。
    # 必须先签内层再签外层（不要用 --deep，Apple 不推荐）。
    codesign --force --options runtime --timestamp \
             --sign "$DEV_ID" "$APP/Contents/Resources/perappvol"
    codesign --force --options runtime --timestamp \
             --sign "$DEV_ID" "$APP/Contents/MacOS/PerAppVol"
    codesign --force --options runtime --timestamp \
             --sign "$DEV_ID" "$APP"
    echo "  Developer ID: $DEV_ID  (hardened runtime, 已带时间戳)"
else
    LOCAL_ID="${SIGN_IDENTITY:-$(find_local_id)}"
    if [ -n "$LOCAL_ID" ]; then
        codesign --force --deep --sign "$LOCAL_ID" "$APP"
        echo "  本机身份: $LOCAL_ID"
    else
        codesign --force --deep -s - "$APP"
        echo "  ⚠ ad-hoc（拿不到 TCC，仅本机自测用）"
    fi
fi

# ─────────────────────────────────────────────────────────── 组装 DMG

echo "▸ 组装 DMG（App + Applications 快捷方式）…"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"

echo "▸ 生成压缩 DMG…"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "▸ 签名 DMG…"
if [ "$MODE" = "release" ]; then
    codesign --force --timestamp --sign "$DEV_ID" "$DMG"
else
    LOCAL_ID="${SIGN_IDENTITY:-$(find_local_id)}"
    if [ -n "$LOCAL_ID" ]; then codesign --force --sign "$LOCAL_ID" "$DMG"; fi
fi

# ─────────────────────────────────────────────────────────── 公证 + 装订（仅 release）

if [ "$MODE" = "release" ]; then
    echo "▸ 提交公证（notarytool，通常 1–5 分钟）…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "▸ 装订票据（staple，离线也能过 Gatekeeper）…"
    xcrun stapler staple "$DMG"

    echo "▸ 最终校验…"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo
echo "✅ 完成: $DMG  (arch=$ARCH)"
ls -lh "$DMG" | awk '{print "   大小:", $5}'
codesign -dv "$DMG" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" | sed 's/^/   /'
echo
if [ "$MODE" = "release" ]; then
    echo "🎉 这个 DMG 可以直接发给别人安装（已公证 + 已装订，Gatekeeper 放行）。"
else
    echo "⚠  这是【本机版】，不能直接发给别人。"
    echo "   收件人会看到「无法验证开发者」，需要右键 → 打开，或："
    echo "       xattr -d com.apple.quarantine /Applications/PerAppVol.app"
    echo "   要正式分发请跑：  ./make-dmg.sh --release"
fi

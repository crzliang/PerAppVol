#!/bin/bash
# PerAppVol 安装脚本 —— 双击即可运行
#
# 解决的是「没有 Apple 开发者账号」时的分发问题：
#   未签名/自签名的 app 拿不到 TCC 授权（系统设置里根本不出现），
#   而 App 没有授权就抓不到其它 App 的音频 —— 等于废的。
#
# 本脚本做的事：
#   1. 在你机器上生成一张【自签名代码签名证书】（只做一次，以后复用）
#   2. 用它重签 PerAppVol.app —— 从此 TCC 能正常授权
#   3. 移除 quarantine（绕开 Gatekeeper 的"无法验证开发者"）
#   4. 安装到 /Applications 并启动
#
# 全程无需 Apple 开发者账号、无需管理员密码。

set -uo pipefail

APP_NAME="PerAppVol"
CERT_NAME="PerAppVol Local Signing"
LEGACY_CERT_NAME="SoundControl Local Signing"   # 项目原名时期的证书（可复用，避免再弹一次钥匙串）
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "──────────────────────────────────────────────"
echo " PerAppVol 安装"
echo "──────────────────────────────────────────────"
echo

[ -d "$SRC" ] || { echo "❌ 没找到 ${SRC}（请从 DMG 里运行本脚本）"; exit 1; }

# DMG 是【只读】挂载，必须先拷到可写位置才能重签名
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "▸ 解包到临时目录（DMG 只读，不能原地重签）…"
cp -R "$SRC" "$WORK/$APP_NAME.app"
SRC="$WORK/$APP_NAME.app"

# ───────────────────────── 1) 确保有可用的本地签名证书
echo "▸ 检查签名证书…"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "  ✅ 已有可用证书: ${CERT_NAME}（复用）"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$LEGACY_CERT_NAME\""; then
    CERT_NAME="$LEGACY_CERT_NAME"
    echo "  ✅ 复用旧证书: ${CERT_NAME}（项目改名前的，仍然有效）"
else
    echo "  生成自签名代码签名证书（仅此一次）…"
    TMP=$(mktemp -d)
    P12PW="$(openssl rand -hex 16)"
    # 关键扩展：
    #   keyUsage        缺了会报 "Invalid Key Usage for policy"
    #   extendedKeyUsage=codeSigning
    #   basicConstraints=CA:false
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes \
        -subj "/CN=$CERT_NAME/O=PerAppVol" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature,nonRepudiation" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "subjectKeyIdentifier=hash" 2>/dev/null
    # p12 必须用旧算法：macOS 的 security 认不了 OpenSSL 3.x 的默认算法
    # （会报 MAC verification failed）。密码也不能留空。
    openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/cert.p12" -passout "pass:$P12PW" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

    security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PW" -T /usr/bin/codesign || true
    # 设为受信：自签名证书默认被标 CSSMERR_TP_NOT_TRUSTED，codesign 会拒绝
    security add-trusted-cert -r trustRoot -p codeSign "$TMP/cert.pem" || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l >/dev/null 2>&1 || true
    rm -rf "$TMP"

    if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
        echo "  ✅ 证书已创建并信任: $CERT_NAME"
    else
        echo "  ❌ 证书创建失败。请手动创建："
        echo "     钥匙串访问 → 证书助理 → 创建证书 → 名称填 \"$CERT_NAME\""
        echo "     类型选「代码签名」→ 勾选「让我覆盖默认值」→ 确认"
        exit 1
    fi
fi

# ───────────────────────── 2) 必要时重签名
echo "▸ 检查 App 签名…"
# 规则：只有【Developer ID】签的才保留（那是已公证、到处可用的）。
# ad-hoc 或"某台机器上的自签名证书"在别的机器上都拿不到 TCC 授权 —— 必须用本机证书重签。
if codesign -dv "$SRC" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "  ✅ Developer ID 签名 + 已公证，保持不动"
else
    echo "  当前签名无法在本机取得 TCC 授权，用本地证书重签…"
    if codesign --force --deep --sign "$CERT_NAME" "$SRC" 2>&1 | tail -1; then
        codesign --verify --deep "$SRC" >/dev/null 2>&1 \
            && echo "  ✅ 已用 $CERT_NAME 重签并通过校验" \
            || { echo "  ❌ 签名校验失败"; exit 1; }
    else
        echo "  ❌ 重签失败"; exit 1
    fi
fi

# ────────────────────── 旧版迁移（项目原名 mac-sound-control → PerAppVol）
# bundle ID 变了：TCC / LaunchAgent / socket / 用户设置全都得迁，否则旧 agent 会拉起第二个 App、
# 旧引擎会占着旧 socket 继续抓音频。脚本幂等，没有旧版残留时什么都不做。
MIGRATE="$HERE/scripts/migrate-legacy.sh"
if [ -x "$MIGRATE" ]; then
    echo
    "$MIGRATE" || true
    echo
fi

# ───────────────────────── 4) 安装
echo "▸ 安装到 /Applications…"
[ -d "$DEST" ] && { pkill -f "$DEST/Contents/MacOS/$APP_NAME" 2>/dev/null; sleep 1; rm -rf "$DEST"; }
cp -R "$SRC" "$DEST"
echo "  ✅ $DEST"

# ───────────────────────── 3) 清隔离属性（必须在拷到 /Applications 之后）
echo "▸ 清除隔离标记…"
# macOS 会打两种隔离属性，任一存在都会报「已损坏 / 无法验证开发者」：
#   com.apple.quarantine   下载隔离（老系统）
#   com.apple.provenance   来源标记（macOS 15+ 新增）
if xattr -dr com.apple.quarantine "$DEST" 2>/dev/null \
   | xattr -dr com.apple.provenance "$DEST" 2>/dev/null; then
    :
fi
echo "  残留属性: $(xattr "$DEST" 2>/dev/null | tr '\n' ' ' || echo '（无）')"
echo "  ✅ 已清除隔离标记"

# ───────────────────────── 5) 启动 + 授权指引
echo
open "$DEST"
sleep 2
echo "──────────────────────────────────────────────"
echo " ⚠  最后一步：授权（不授权则抓不到其它 App 的音频）"
echo "──────────────────────────────────────────────"
echo "  系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 打开 PerAppVol"
echo
echo "  或者直接打开那个设置页："
echo "    open \"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture\""
echo
read -r -p "  现在打开系统设置？[Y/n] " yn
case "${yn:-Y}" in
    [Nn]*) ;;
    *) open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" ;;
esac
echo
echo "✅ 安装完成"
echo
echo "──────────────────────────────────────────────"
echo " 如果打开时提示「已损坏，无法打开」/「无法验证开发者」"
echo "──────────────────────────────────────────────"
echo "  这是 Gatekeeper 对未公证应用的正常拦截。终端里执行："
echo
echo "      xattr -cr /Applications/PerAppVol.app"
echo
echo "  然后重新打开。也可以：右键 → 打开 → 再点「打开」。"
echo "  （xattr 只是清除下载隔离标记，不影响签名）"

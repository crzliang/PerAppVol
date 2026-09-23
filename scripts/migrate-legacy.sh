#!/bin/bash
# migrate-legacy.sh —— 从项目原名 mac-sound-control 迁到 PerAppVol
#
# 改名不是"改个字符串"：下面每一样都是【系统侧的持久状态】，漏一个就出问题。
#   bundled ID  com.mac-sound-control.perappvol → com.perappvol.PerAppVol
#     · TCC 授权按 bundle ID 记账 —— 新 ID 要重新授权（旧条目留着也不会再匹配）
#     · UserDefaults 也按 bundle ID 分域 —— 用户的每 App 音量设置在这里
#   LaunchAgent com.mac-sound-control.perappvol → com.perappvol.autostart
#     · 旧 agent 的 KeepAlive 会拉起第二个 App 实例（两个菜单栏图标、抢引擎）
#   /tmp/mac-sound-control.{sock,pid} → /tmp/perappvol.{sock,pid}
#     · 旧引擎占着旧 socket 照样在跑 —— 必须按 socket 找到它并杀掉，
#       否则新旧两个引擎同时抓音频（自激反馈 + 双份声音）。
#
# 幂等：全部有存在性判断，重复跑无副作用。
# 调用方：Makefile 的 install / migrate，install.command（DMG 安装）

set -uo pipefail

OLD_BUNDLE="com.mac-sound-control.perappvol"
NEW_BUNDLE="com.perappvol.PerAppVol"
OLD_LABEL="$OLD_BUNDLE"
NEW_LABEL="com.perappvol.autostart"
OLD_SOCK="/tmp/mac-sound-control.sock"
OLD_PID="/tmp/mac-sound-control.pid"
UID_NUM=$(id -u)
LA="$HOME/Library/LaunchAgents"
PREF="$HOME/Library/Preferences"
ACTED=0

say() { echo "▸ $*"; }

# ───────────────────────── 1) 旧 LaunchAgent
# 旧 agent 的 KeepAlive=true → 必须 bootout，否则它会把旧 App 再拉起来
# （两个菜单栏图标、两个 UI 抢同一个引擎）。
# 迁移方式：【改 label 换名】而不是重新 bootstrap ——
# 现在 bootstrap 会立刻拉起 /Applications 里那个旧二进制，白白闪一下；
# 写成新 plist 后下次登录自然生效，本次会话由安装器 open 新 App 负责。
PLB=/usr/libexec/PlistBuddy
APP_BIN=/Applications/PerAppVol.app/Contents/MacOS/PerAppVol
if [ -f "$LA/$OLD_LABEL.plist" ]; then
    say "迁移旧开机自启 ($OLD_LABEL → $NEW_LABEL)…"
    launchctl bootout "gui/$UID_NUM/$OLD_LABEL" 2>/dev/null || true
    launchctl unload "$LA/$OLD_LABEL.plist" 2>/dev/null || true
    if [ -f "$LA/$NEW_LABEL.plist" ]; then
        rm -f "$LA/$OLD_LABEL.plist"          # 新 label 已经在了，只删旧的
    elif [ -x "$PLB" ] \
         && "$PLB" -c "Set :Label $NEW_LABEL" \
                   -c "Set :ProgramArguments:0 $APP_BIN" \
                   "$LA/$OLD_LABEL.plist" >/dev/null 2>&1; then
        mv "$LA/$OLD_LABEL.plist" "$LA/$NEW_LABEL.plist"
        echo "  ✅ 已改名（下次登录生效；现在想立刻生效：make autostart）"
    else
        rm -f "$LA/$OLD_LABEL.plist"
    fi
    ACTED=1
fi

# ───────────────────────── 2) 还占着旧 socket 的旧引擎（按文件反查 pid，别乱 pkill）
if [ -S "$OLD_SOCK" ]; then
    say "停掉占用 $OLD_SOCK 的旧引擎…"
    for p in $(lsof -U 2>/dev/null | awk -v s="$OLD_SOCK" '$0 ~ s { print $2 }' | sort -u); do
        kill "$p" 2>/dev/null || true
    done
    sleep 1
    for p in $(lsof -U 2>/dev/null | awk -v s="$OLD_SOCK" '$0 ~ s { print $2 }' | sort -u); do
        kill -9 "$p" 2>/dev/null || true
    done
fi
if [ -f "$OLD_PID" ]; then
    old_pid=$(head -1 "$OLD_PID" 2>/dev/null | tr -dc '0-9')
    [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null || true
fi
if [ -e "$OLD_SOCK" ] || [ -e "$OLD_PID" ]; then
    rm -f "$OLD_SOCK" "$OLD_PID"
    ACTED=1
fi
# 旧容器的日志（新名字已经是 perappvol-*，直接用新名，只清旧的）
rm -f /tmp/mac-sound-control*.log /tmp/mac-sound-control-engine.* 2>/dev/null || true

# ───────────────────────── 3) 用户设置（UserDefaults 按 bundle ID 分域，不迁就丢）
# 必须先 export/import 而不是 mv：cfprefsd 有缓存，直接换文件会被它写回覆盖。
OLD_PREF="$PREF/$OLD_BUNDLE.plist"
NEW_PREF="$PREF/$NEW_BUNDLE.plist"
if [ -f "$OLD_PREF" ] && [ ! -f "$NEW_PREF" ]; then
    say "迁移用户设置 ($OLD_BUNDLE → $NEW_BUNDLE)…"
    TMPP=$(mktemp /tmp/ppv-prefs.XXXXXX.plist)
    if defaults export "$OLD_BUNDLE" "$TMPP" 2>/dev/null && [ -s "$TMPP" ]; then
        defaults import "$NEW_BUNDLE" "$TMPP" 2>/dev/null || true
        n=$(defaults read "$NEW_BUNDLE" ppv.gains 2>/dev/null | grep -c '=' || true)
        echo "  ✅ 已迁移${n:+（ppv.gains 里 $n 条）}"
        ACTED=1
    else
        # 极少数情况（域没被 cfprefsd 接管）直接拷贝文件也能work
        cp "$OLD_PREF" "$NEW_PREF" && echo "  ✅ 已按文件迁移" && ACTED=1
    fi
    rm -f "$TMPP"
fi

# ───────────────────────── 4) TCC 旧条目（bundle ID 变了，旧条目是死记录）
# tccutil 对不存在的 bundle ID 返回 64、对存在的返回 0 —— 用退出码判断，不解析文案
for svc in ScreenCapture AudioCapture; do
    if tccutil reset "$svc" "$OLD_BUNDLE" >/dev/null 2>&1; then
        say "清理旧 bundle ID 的 TCC 记录（${svc}）…"   # 必须 ${svc}：macOS 自带的 bash 3.2 会把全角『）』的字节吃进变量名
        ACTED=1
    fi
done

# ───────────────────────── 5) LaunchServices 里旧 bundle ID 的注册
# 只在【已安装的 App 仍是旧 bundle ID】时注销 —— 避免把刚装好的新版一起注销掉
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INSTALLED=/Applications/PerAppVol.app
if [ -x "$LSREG" ] && [ -d "$INSTALLED" ]; then
    cur=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo "")
    if [ "$cur" = "$OLD_BUNDLE" ]; then
        say "注销旧 bundle ID 的 LaunchServices 注册…"
        "$LSREG" -u "$INSTALLED" 2>/dev/null || true
        ACTED=1
    fi
fi

if [ "$ACTED" = 0 ]; then
    echo "▸ 无需迁移（没有发现 mac-sound-control 时期的残留）"
else
    echo
    echo "⚠  最后一步要人工点：新 bundle ID 是【新的 TCC 身份】——"
    echo "   系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 打开 PerAppVol"
fi
exit 0

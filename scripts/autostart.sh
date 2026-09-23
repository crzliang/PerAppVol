#!/bin/bash
# autostart.sh —— 开机自启（用户级 LaunchAgent，无需管理员权限）
#
#   ./scripts/autostart.sh on       开启开机自启
#   ./scripts/autostart.sh off      关闭
#   ./scripts/autostart.sh status   查看状态
#
# 为什么重要：PerAppVol 不启动 = 没有 tap = 完全没有音量控制。
# plist 里的 KeepAlive=true，挂了会自动拉起。

set -uo pipefail

LABEL="com.perappvol.autostart"
LEGACY_LABEL="com.mac-sound-control.perappvol"   # 项目原名，升级时清掉
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

# 优先用已安装的版本；开发构建则用当前 bundle
APP="/Applications/PerAppVol.app/Contents/MacOS/PerAppVol"
[ -x "$APP" ] || APP="$(cd "$(dirname "$0")/.." && pwd)/build/PerAppVol.app/Contents/MacOS/PerAppVol"

case "${1:-status}" in
on)
    [ -x "$APP" ] || { echo "❌ 找不到 PerAppVol，先跑 make install"; exit 1; }
    # 先清掉项目原名时期的 agent：它的 KeepAlive 会再拉起一个 App
    if [ -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist" ]; then
        launchctl bootout "gui/$UID_NUM/$LEGACY_LABEL" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
        echo "▸ 已清理旧 label: $LEGACY_LABEL"
    fi
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>$LABEL</string>
    <key>ProgramArguments</key>  <array><string>$APP</string></array>
    <key>RunAtLoad</key>         <true/>
    <key>KeepAlive</key>         <true/>
    <key>ProcessType</key>       <string>Interactive</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
        echo "✅ 已开启开机自启"
    else
        # 老系统用 load
        launchctl load "$PLIST" 2>/dev/null && echo "✅ 已开启开机自启" \
            || { echo "❌ 装载失败"; exit 1; }
    fi
    echo "   $PLIST"
    echo "   指向: $APP"
    ;;
off)
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✅ 已关闭开机自启"
    ;;
status)
    if [ -f "$PLIST" ]; then
        echo "开机自启: ✅ 已开启"
        echo "  $PLIST"
        launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | grep -E "state|pid" | sed 's/^/  /' || true
    else
        echo "开机自启: ⬜ 未开启   （开启: make autostart）"
    fi
    ;;
*)
    echo "用法: $0 on|off|status"; exit 2
    ;;
esac

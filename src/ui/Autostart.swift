// Autostart.swift —— 开机自启（LaunchAgent）
//
// 为什么必须有：PerAppVol 不启动 = 没有 tap = 没有任何音量控制。
// 不是"锦上添花的常驻工具"，而是音量链路本身的一部分。
//
// 实现：往 ~/Library/LaunchAgents/ 写一个 LaunchAgent plist，用 launchctl 装载。
//      不需要管理员权限（用户级 LaunchAgent）。

import Foundation

enum Autostart {
    static let label = "com.perappvol.autostart"

    /// 旧版（项目原名 mac-sound-control）的 label —— 升级时必须清理，
    /// 否则旧 agent 的 KeepAlive 会再拉起一个 App（两个菜单栏图标 + 抢引擎）。
    private static let legacyLabel = "com.mac-sound-control.perappvol"

    private static var plistURL: URL { plistURL(label) }

    private static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 把旧 label 的 LaunchAgent 迁到新 label（保留"原本是开着的"这个意图）。
    /// 幂等：没有旧 plist 时什么都不做。App 启动时调一次。
    static func migrateLegacy() {
        let old = plistURL(legacyLabel)
        let wasEnabled = FileManager.default.fileExists(atPath: old.path)
        guard wasEnabled else { return }
        _ = run("launchctl", ["bootout", "gui/\(getuid())/\(legacyLabel)"])
        _ = run("launchctl", ["unload", old.path])
        try? FileManager.default.removeItem(at: old)
        ulog("Autostart: 已清理旧 LaunchAgent \(legacyLabel)")
        if !isEnabled { install() }   // 原来开着 → 用新 label 重新装上
    }

    /// 是否已启用（看 plist 在不在即可 —— launchctl 状态查询在新版 macOS 上不稳定）
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 指向【当前这个】可执行文件，开发构建和 /Applications 安装都能用
    private static var executablePath: String {
        Bundle.main.executableURL?.path
            ?? "/Applications/PerAppVol.app/Contents/MacOS/PerAppVol"
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        on ? install() : uninstall()
    }

    @discardableResult
    static func install() -> Bool {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,          // 挂了自动拉起 —— 引擎没了就等于没音量控制
            "ProcessType": "Interactive",
        ]
        let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        guard let data else { return false }

        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? data.write(to: plistURL)) != nil else { return false }

        // 先卸再装，避免重复装载
        _ = run("launchctl", ["bootout", "gui/\\(getuid())/\\(label)"])
        return run("launchctl", ["bootstrap", "gui/\\(getuid())", plistURL.path])
    }

    @discardableResult
    static func uninstall() -> Bool {
        _ = run("launchctl", ["bootout", "gui/\\(getuid())/\\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        return !isEnabled
    }

    @discardableResult
    private static func run(_ cmd: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [cmd] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

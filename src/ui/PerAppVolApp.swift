// PerAppVolApp.swift —— macOS 按 App 调音量 · 菜单栏 UI
//
// 架构：UI 只是控制器，真正的混音引擎是常驻的 `perappvol serve`（独立进程）。
//      UI 崩了/退了都不能断音 —— 所以拆成两个进程，用 Unix socket 通信。
//
// App 识别由引擎负责（`list` 命令）：它用 proc_pidpath + 最外层 .app 归组，
// 所以 QQ/微信/Chrome/飞书的 helper 进程都会归进主 App。UI 不重复造轮子。
//
// 编译:
//   swiftc -O -parse-as-library PerAppVolApp.swift -o build/PerAppVol.app/Contents/MacOS/PerAppVol \
//       -framework SwiftUI -framework AppKit -framework CoreAudio
//
// 注意（纯 swiftc 编 SwiftUI 的限制）：
//   · 必须 -parse-as-library，否则 @main 报 "contains top-level code"
//   · 不要用 @State/@StateObject —— 它们是宏，需要 SwiftUIMacros 插件（只有 Xcode 构建系统提供）。
//     状态全放 ObservableObject，Binding 手工构造。

import SwiftUI
import AppKit
import CoreAudio
import CoreGraphics
import Darwin

let kSockPath = "/tmp/perappvol.sock"
let kPidPath = "/tmp/perappvol.pid"
let kLogPath = "/tmp/perappvol-ui.log"
let kEngineErrPath = "/tmp/perappvol-engine.err"

/// UI 是 GUI 进程，stdout 看不到 —— 写文件才能调试
func ulog(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] " + s + "\n"
    if let fh = FileHandle(forWritingAtPath: kLogPath) {
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: line.data(using: .utf8) ?? Data())
    } else {
        try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: kLogPath))
    }
}

// MARK: - 引擎控制客户端（Unix socket）

final class CtlClient {
    static let shared = CtlClient()
    private init() {}

    private func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let bytes = Array(kSockPath.utf8.prefix(maxLen))
        withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 { close(fd); return -1 }
        // 必须有超时：引擎忙于重建时不会立刻应答，
        // 没超时的话 UI 主线程会永久阻塞在 read() 上 —— 就是"卡死"。
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// 引擎进程是否【真的】在跑 —— 看 PID 文件 + kill(pid,0)。
    /// 不能用 socket 探测：引擎重建时会短暂不应答，误判就会重复拉起一个新引擎。
    static func engineProcessAlive() -> Bool {
        guard let txt = try? String(contentsOfFile: kPidPath, encoding: .utf8),
              let pid = Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
        else { return false }
        return kill(pid, 0) == 0
    }

    private let sendLock = NSLock()

    /// 发一条命令，读回应答（`get`/`list`/`stat` 以 "END" 结尾，其余一行）
    /// 必须串行化：电平轮询(10Hz)、命令合并(40Hz)、状态刷新(1Hz) 会并发调用它。
    func send(_ cmd: String) -> String? {
        sendLock.lock(); defer { sendLock.unlock() }
        return sendLocked(cmd)
    }

    private func sendLocked(_ cmd: String) -> String? {
        let fd = connect()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var payload = Array((cmd + "\n").utf8)
        if Darwin.write(fd, &payload, payload.count) < 0 { return nil }

        let isMulti = cmd == "get" || cmd == "list" || cmd == "stat"
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if let s = String(data: out, encoding: .utf8) {
                if isMulti { if s.hasSuffix("END\n") { break } }
                else if s.contains("\n") { break }
            }
            if out.count > 256 * 1024 { break }
        }
        return String(data: out, encoding: .utf8)
    }

    func isAlive() -> Bool { send("get") != nil }
}

// MARK: - 字体规格

/// 中日韩字形笔画密度天然高于拉丁 —— 同字重视觉上明显更黑。
/// 要视觉平衡必须【显式】指定苹方字重，而且要比拉丁细两档：
///   SF Mono Light  的笔画比 苹方-细体 / 苹方-纤细体 都细。
///
/// 为什么不能用 systemFont 的自动回落：
///   自动回落按【拉丁字重】选苹方，且被 SF Mono 的最细档（Light）钳住，做不到更细。
/// 为什么不用 font cascade list：
///   AppKit 里有效，但 SwiftUI 不保证保留它 —— 不赌。
/// 可靠做法：按字符集切 run，各自显式指定字体（AttributedString）。
enum Typo {
    /// 中文字重开关（苹方-简 六档：Ultralight/Thin/Light/Regular/Medium/Semibold）
    static let cjkBody  = "PingFangSC-Thin"           // 苹方-简 纤细体（Ultralight 在 12pt 过细会糊）
    static let cjkTitle = "PingFangSC-Medium"        // 苹方-简 中黑体（与拉丁 Medium 同字重）

    /// 标题。
    /// 关键：必须走 per-run【显式指定苹方】。用 Font.system 自然回落时，
    /// 中文的字宽处理会出错 —— 实测「音量控制」四个字会互相叠在一起（看起来就是"失真"）。
    /// 另外中英同字重：之前 "App"=SF Mono Medium + "音量控制"=苹方细体，半重半轻也不对。
    static let title   = Spec(size: 13, latinWeight: .medium, cjk: cjkTitle, design: .monospaced)
    static let name    = Spec(size: 12,   latinWeight: .light,  cjk: cjkBody)   // App 名称
    static let ui      = Spec(size: 11,   latinWeight: .light,  cjk: cjkBody)   // 控件文字
    static let caption = Spec(size: 10,   latinWeight: .light,  cjk: cjkBody)   // 辅助信息
    static let tiny    = Spec(size: 9,    latinWeight: .light,  cjk: cjkBody)   // 副标题
    static let badge   = Spec(size: 9,    latinWeight: .light,  cjk: cjkBody)   // 小图标
    /// 数字恒等宽（拖滑块时位数变化不抖）
    static let num     = Spec(size: 10.5, latinWeight: .light,  cjk: cjkBody)

    struct Spec {
        let size: CGFloat
        let latinWeight: Font.Weight
        let cjk: String?
        /// .monospaced = 等宽；.default = SF Pro（更接近 macOS 原生观感、更锐）
        var design: Font.Design = .monospaced

        /// Font.Weight -> NSFont.Weight（只有中文回落需要 NSFont）
        var nsWeight: NSFont.Weight {
            switch latinWeight {
            case .ultraLight: return .ultraLight
            case .thin:       return .thin
            case .light:      return .light
            case .medium:     return .medium
            case .semibold:   return .semibold
            case .bold:       return .bold
            default:          return .regular
            }
        }

        /// 拉丁 = 等宽 SF Mono。故意用 SwiftUI 的 Font.system 而不是 Font(NSFont)：
        /// Font(NSFont) 走的是 SwiftUI 的非原生渲染路径，小字号下会有"失真/发糊"。
        var latinFont: Font { Font.system(size: size, weight: latinWeight, design: design) }
        var latin: NSFont {
            design == .monospaced
                ? NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight)
                : NSFont.systemFont(ofSize: size, weight: nsWeight)
        }
        /// 给 SF Symbol 之类【纯拉丁】场景用
        var font: Font { latinFont }

        /// cjk == nil 时不切 run —— 整条用 SwiftUI 原生字体，
        /// 由系统自然回落到苹方（字重自动匹配，渲染路径最短、最锐）。
        /// 切 run 只用于"中文要比拉丁细一档"的正文。
        func text(_ s: String) -> Text {
            guard let cjkName = cjk, let cjkFont = NSFont(name: cjkName, size: size) else {
                return Text(s).font(latinFont)
            }
            return Text(Typo.attributed(s, latin: latinFont, cjk: cjkFont))
        }
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x3000...0x303F:
            return true
        default:
            return false
        }
    }

    static func attributed(_ s: String, latin lat: Font, cjk: NSFont) -> AttributedString {
        var out = AttributedString()
        var buf = ""
        var bufCJK = false
        for (i, ch) in s.enumerated() {
            let c = isCJK(ch)
            if i == 0 { bufCJK = c }
            if c == bufCJK {
                buf.append(ch)
            } else {
                var piece = AttributedString(buf)
                piece.font = bufCJK ? Font(cjk) : lat
                out.append(piece)
                buf = String(ch)
                bufCJK = c
            }
        }
        if !buf.isEmpty {
            var piece = AttributedString(buf)
            piece.font = bufCJK ? Font(cjk) : lat
            out.append(piece)
        }
        return out
    }
}

/// AppKit 侧（滑块百分比）：纯数字，直接用等宽
enum TypoNS {
    static let num = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .light)
}

// MARK: - 图标缓存

/// 图标必须只解析一次。渲染路径里调 NSWorkspace.icon(forFile:) 会打到磁盘，
/// 拖滑块时 60fps × 17 行 ≈ 每秒 1000 次查询 —— 直接卡成狗。
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// path = .app 包路径（取图标的依据）；key = 稳定身份（bundle ID），只做缓存键
    static func get(key: String, path: String, pid: Int32) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let img: NSImage?
        if key == "systemsoundserverd" {
            img = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "系统提示音")
        } else if path.hasSuffix(".app") {
            img = NSWorkspace.shared.icon(forFile: path)
        } else if pid > 0 {
            img = NSRunningApplication(processIdentifier: pid)?.icon
        } else {
            img = nil
        }
        if let img { cache[key] = img }
        return img
    }
}

// MARK: - 电平表数据源

/// 共享电平源：后台 10Hz 轮询引擎 `stat`，各行的 AppKit 视图直接读。
/// 【不经过 SwiftUI diff】—— 所以拖滑块、看电平互不干扰。
final class MeterFeed {
    static let shared = MeterFeed()
    private var pk: [String: Double] = [:]
    private let lock = NSLock()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .userInteractive).async {
                guard let resp = CtlClient.shared.send("stat") else { return }
                var next: [String: Double] = [:]
                for line in resp.split(separator: "\n") {
                    // 行格式: in <label（可含空格）> rms=... pk=... gain=...
                    guard line.hasPrefix("in ") else { continue }
                    let t = line.split(separator: " ").map(String.init)
                    guard let pkIdx = t.firstIndex(where: { $0.hasPrefix("pk=") }) else { continue }
                    let label = t[1..<pkIdx].joined(separator: " ")
                    if let v = Double(t[pkIdx].dropFirst(3)) { next[label] = v }
                }
                self?.lock.lock(); self?.pk = next; self?.lock.unlock()
            }
        }
    }

    /// 该路的峰值电平（0...1），带缓降
    func level(_ label: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        return pk[label] ?? 0
    }
}

// MARK: - 命令合并发送（latest-wins）★ 跟手感的关键

/// 滑块拖动每秒产生 ~60 个事件。逐个开 socket 发命令必然积压、丢包、乱序 —— 表现为"不跟手"。
/// 这里做两件事：① 同一个目标的多次 set 合并成最后一次（latest-wins）② 每 60ms 批量发一次。
final class CmdQueue {
    static let shared = CmdQueue()
    private var pending: [String: String] = [:]     // 去重 key -> 命令
    private let lock = NSLock()
    private var started = false

    /// dedupeKey 用 "set/<label>" 这类形式，同一个目标只保留最新一条
    func submit(_ dedupeKey: String, _ cmd: String) {
        lock.lock()
        pending[dedupeKey] = cmd
        lock.unlock()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        lock.unlock()
        guard !batch.isEmpty else { return }
        for cmd in batch.values {
            DispatchQueue.global(qos: .userInteractive).async {
                _ = CtlClient.shared.send(cmd)
            }
        }
    }
}

// MARK: - App 行（引擎的 `list` 输出）

struct AppRow: Identifiable, Equatable {
    let realApp: Bool     // 是不是真正的 .app（false = com.apple.* 之类的系统守护进程）
    let playing: Bool     // 当前有没有在出声
    let pid: Int32
    let name: String
    /// 稳定身份 = bundle ID（设置按它持久化 —— App 路径会变，bundle ID 不变）
    let key: String
    /// .app 包路径，只用来取图标
    let path: String
    let icon: NSImage?    // 存储属性：解析时算好，渲染时零成本
    var id: String { key }
    var isSystemService: Bool { key == "systemsoundserverd" }
}

/// 解析 `list` 的 TAB 行：app \t real \t playing \t pid \t name \t key
func parseAppRows(_ resp: String) -> [AppRow] {
    ulog("parseAppRows: 响应 \(resp.count) 字符, \(resp.split(separator: "\n").count) 行")
    ulog("parseAppRows: 首行=\({ let l = resp.split(separator: "\n"); return l.isEmpty ? "(空)" : String(l[0]) }())")
    let rows: [AppRow] = resp.split(separator: "\n").compactMap { (line: Substring) -> AppRow? in
        guard line.hasPrefix("app\t") else { return nil }
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6 else { return nil }
        let key = f[5]
        let path = f.count >= 7 ? f[5 + 1] : ""
        let pid = Int32(f[3]) ?? 0
        return AppRow(realApp: f[1] == "1", playing: f[2] == "1",
                      pid: pid, name: f[4], key: key, path: path,
                      icon: IconCache.get(key: key, path: path, pid: pid))
    }
    ulog("parseAppRows: 解析出 \(rows.count) 行")
    return rows
}

// MARK: - 状态

final class AppModel: ObservableObject {
    static let shared = AppModel()
    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "ppv.gains") as? [String: Double] {
            // 迁移：老版本用 .app 路径当 key，App 一移动设置就丢。
            // 现在 key = bundle ID，这里把路径形式的老 key 映射过去。
            var migrated: [String: Double] = [:]
            for (k, v) in saved {
                var key = k
                if k.hasSuffix(".app"), let bid = (Bundle(path: k)?.bundleIdentifier) {
                    key = bid
                }
                migrated[key] = v
            }
            if migrated != saved {
                desired = migrated
                // 注意：init() 里的赋值【不触发 didSet】，必须显式写回，否则迁移只活在内存里
                UserDefaults.standard.set(migrated, forKey: "ppv.gains")
                ulog("迁移设置: \(saved.count) 条，路径 key -> bundle ID（已写回）")
            } else {
                desired = saved
            }
        }
        if UserDefaults.standard.bool(forKey: "ppv.bypass") { bypass = true }
    }

    @Published var apps: [AppRow] = []
    @Published var gains: [String: Double] = [:]   // 引擎实际状态（用于显示）
    /// 期望增益 —— 这才是【用户的设置】，持久化到 UserDefaults。
    /// 引擎只是执行器：它重启/槽位丢失时，refresh() 的 reconcile() 会按这里重新施加。
    /// （之前直接把引擎的 get 结果当真相，引擎一重启就"设置回到 100%"。）
    /// 期望增益。【故意不是 @Published】：
    /// 拖滑块时每步都写它，如果触发 objectWillChange 就会整列表 diff 一遍 —— 那就是"不跟手"。
    /// 需要重绘时由 refresh() 提升 revision（1Hz）。
    var desired: [String: Double] = [:] {
        didSet { UserDefaults.standard.set(desired, forKey: "ppv.gains") }
    }
    @Published private(set) var revision = 0
    private var lastEdit = Date.distantPast

    /// 需要重绘时调用。但【拖动中绝不打断】——
    /// refresh() 每秒 bump 一次会让 List 重建行、重设滑块拇指位置，手感就是被这个打断的。
    func touch() {
        guard Date().timeIntervalSince(lastEdit) > 0.5 else { return }
        revision += 1
    }
    private var preBypass: [String: Double]? = nil
    @Published var engineUp = false
    @Published var allGain: Double = 1.0
    @Published var bypass = false
    @Published var showAll = false
    @Published var showSystem = false
    @Published var autostart = false
    private var timer: Timer?
    private var lastLaunch = Date.distantPast
    private var launching = false
    private var refreshing = false

    /// 要展示的 App：真实 App + 正在出声的；系统守护进程收进"显示系统进程"
    var visible: [AppRow] {
        let selfPath = Bundle.main.bundlePath
        return apps.filter { a in
            if a.key == selfPath { return false }         // 不控制自己（混音器自己的输出）
            return showSystem ? true : (a.realApp || a.playing)
        }
    }

    func start() {
        // 独立 .app 身份需要自己的 TCC 授权（屏幕与系统音频录制）。
        // 不授权的话 tap 不报错、只给静音 —— 见 README 坑 1/2。
        if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CGRequestScreenCaptureAccess()
            }
        }
        autostart = Autostart.isEnabled
        ensureEngine()
        MeterFeed.shared.start()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// 引擎 stderr 落盘用。
    /// 坑：`FileHandle(forWritingTo:)` 是 O_WRONLY，**偏移是 0** —— 不 seek 到末尾的话，
    /// 新引擎的输出会从文件开头覆盖，把上一次“确实起来了”的日志盖掉，
    /// 看起来就像引擎从未启动（实测花了很久才反应过来）。
    private func openEngineLog() -> FileHandle {
        if !FileManager.default.fileExists(atPath: kEngineErrPath) {
            FileManager.default.createFile(atPath: kEngineErrPath, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: kEngineErrPath)) else {
            return FileHandle.nullDevice
        }
        _ = try? fh.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        _ = try? fh.write(contentsOf: Data("\n===== 引擎启动 \(stamp) =====\n".utf8))
        return fh
    }

    /// 引擎没起就拉起它（引擎二进制塞在 app bundle 的 Resources 里）
    private func ensureEngine() {
        // 关键：判"要不要拉起"必须看进程，不能看 socket 应答。
        // 否则引擎忙的时候会再拉一个 —— 两个引擎抢 socket 且互相抓对方的输出。
        guard !CtlClient.engineProcessAlive(), !launching else { return }
        launching = true
        defer { launching = false }
        lastLaunch = Date()
        // 注意：@State/@StateObject 在纯 swiftc 下不可用，所以这里全是普通代码
        let candidates: [String] = [
            Bundle.main.resourceURL?.appendingPathComponent("perappvol").path ?? "",
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/perappvol").path,
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("perappvol").path,
            FileManager.default.currentDirectoryPath + "/perappvol",
        ]
        guard let exe = candidates.first(where: {
            !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["serve", "ALL=1.0", "--socket", kSockPath]
        p.standardOutput = FileHandle.nullDevice
        // 引擎的诊断信息必须留下来 —— 之前丢给 /dev/null，它为什么挂掉根本查不到。
        p.standardError = openEngineLog()
        try? p.run()
        for _ in 0..<30 {
            usleep(100_000)
            if CtlClient.shared.isAlive() { break }
        }
    }

    func refresh() {
        // 整段放后台：主线程上做阻塞 socket I/O + NSWorkspace 取图标，是卡顿/卡死的根源。
        guard !refreshing else { return }
        refreshing = true
        let showSystem = self.showSystem
        DispatchQueue.global(qos: .userInitiated).async {
            if !CtlClient.engineProcessAlive(),
               Date().timeIntervalSince(self.lastLaunch) > 5 {
                self.ensureEngine()
            }
            let up = CtlClient.shared.isAlive()
            var newApps: [AppRow]? = nil
            var newGains: [String: Double]? = nil
            var newAll: Double? = nil
            if up, let resp = CtlClient.shared.send("list") { newApps = parseAppRows(resp) }
            if up, let resp = CtlClient.shared.send("get") {
                var g: [String: Double] = [:]
                var all: Double = 1.0
                for line in resp.split(separator: "\n") {
                    let t = line.split(separator: " ")
                    guard t.count >= 2, let v = Double(t[t.count - 1]) else { continue }
                    let label = t[..<(t.count - 1)].joined(separator: " ")
                    if label == "ALL" { all = v } else { g[label] = v }
                }
                newGains = g
                newAll = all
            }
            DispatchQueue.main.async {
                self.engineUp = up
                if let a = newApps { self.apps = a }
                if let g = newGains { self.gains = g }
                if let a = newAll { self.allGain = a }
                self.reconcile(engineGains: newGains ?? [:], all: newAll ?? 1.0)
                self.touch()          // 1Hz 的唯一重绘来源
                self.refreshing = false
                ulog("refresh: apps=\(self.apps.count) visible=\(self.visible.count) engineUp=\(up) showSystem=\(showSystem)")
            }
        }
    }

    // —— 调音量：先写期望（持久化），再让 reconcile() 保证引擎落实 ——

    /// 设置某个 label 的期望增益。label 可能含空格（.app 路径），协议已支持。
    func control(label: String, _ v: Double) {
        lastEdit = Date()          // 拖动期间冻结 SwiftUI 重绘
        let nv = min(max(v, 0), 1)
        let old = desired[label]
        // 编辑日志：只在用户真的改值时记（不在渲染路径上）。
        // 设置"自己变回去"时，这里能看出是谁改的、从多少改到多少。
        if old == nil || abs(old! - nv) > 0.001 {
            ulog("EDIT \(label): \(old.map { String(format: "%.4f", $0) } ?? "(无)") -> \(String(format: "%.4f", nv))")
        }
        desired[label] = nv
        if !bypass { fireGain(label, nv) }
    }

    func control(_ a: AppRow, gain: Double) { control(label: a.key, gain) }

    func release(_ a: AppRow) {
        desired[a.key] = nil
        touch()
        fire("remove \(a.key)", dedupe: "remove/\(a.key)")
    }

    func toggleAutostart() {
        autostart.toggle()
        let ok = Autostart.setEnabled(autostart)
        ulog("开机自启 -> \(autostart ? "开" : "关")  \(ok ? "成功" : "失败")")
        if !ok { autostart = Autostart.isEnabled }
    }

    func toggleBypass() {
        bypass.toggle()
        UserDefaults.standard.set(bypass, forKey: "ppv.bypass")
        if bypass {
            preBypass = desired
            for k in desired.keys { fireGain(k, 0) }
            fire("set ALL 0")
        } else {
            if let p = preBypass { desired = p; preBypass = nil }
            for (k, v) in desired { fireGain(k, v) }
        }
    }

    /// 自愈：把期望状态施加到引擎。
    /// 覆盖三种丢设置的场景：引擎重启、App 退出后重新出声、槽位被移除。
    private func reconcile(engineGains: [String: Double], all: Double) {
        guard !bypass else { return }
        for (label, v) in desired {
            let cur = (label == "ALL") ? all : engineGains[label]
            if cur == nil {
                ulog("reconcile: 引擎缺 \(label)，重新 add = \(v)")
                fire("add \(label) \(v)", dedupe: "add/\(label)")
            } else if abs(cur! - v) > 0.02 {
                ulog("reconcile: \(label) 引擎=\(cur!) 期望=\(v)，纠正")
                fireGain(label, v)
            }
        }
    }

    private func fire(_ cmd: String, dedupe: String? = nil) {
        CmdQueue.shared.submit(dedupe ?? "cmd/\(UUID().uuidString)", cmd)
    }

    /// 增益类命令：必须去重，否则拖动时会发出几百条只留最后一条才有意义的命令
    private func fireGain(_ label: String, _ v: Double) {
        CmdQueue.shared.submit("set/\(label)", "set \(label) \(v)")
    }
}

// MARK: - 电平条（AppKit 自绘，30Hz 自刷新，不碰 SwiftUI）

final class LevelBarView: NSView {
    var meterKey: String = ""
    private var shown = 0.0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let target = min(max(MeterFeed.shared.level(meterKey), 0), 1)
        shown += (target - shown) * 0.35                  // 视觉缓动
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
        if shown > 0.002 {
            (shown > 0.85 ? NSColor.systemOrange : NSColor.systemBlue).setFill()
            NSRect(x: 0, y: 0, width: bounds.width * shown, height: bounds.height).fill()
        }
    }

    /// 30Hz 自刷新 —— 完全不触发 SwiftUI 重绘
    func startTicking() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
}

// MARK: - AppKit 原生滑块（跟手感的物理上限）

/// 关键：拖动过程【完全不经过 SwiftUI】。
/// 之前用 SwiftUI Slider + @Binding，每拖一步都写一次 @Published → 整个列表 diff 一遍，
/// 声音要排过这条渲染+命令队列，就是"滑块跟手、声音不跟手"的根源。
/// 现在：NSSlider 的 target/action 直通命令队列，百分比由 NSTextField 原生刷新。
final class SliderRowView: NSView {
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "")
    private let level = LevelBarView()
    var onEdit: ((Double) -> Void)?

    /// 该行对应引擎里的哪一路（用于取电平）
    var meterKey: String = "" {
        didSet { level.meterKey = meterKey; level.needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true          // 拖动过程中连续回调
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed(_:))

        label.font = TypoNS.num
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        level.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        addSubview(label)
        addSubview(level)

        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            slider.topAnchor.constraint(equalTo: topAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.widthAnchor.constraint(equalToConstant: 38),
            label.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            level.leadingAnchor.constraint(equalTo: leadingAnchor),
            level.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            level.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 3),
            level.heightAnchor.constraint(equalToConstant: 2),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        level.startTicking()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed(_ sender: NSSlider) {
        let v = sender.doubleValue
        paint(v)                 // 数字即时更新，不等 SwiftUI
        onEdit?(v)               // 直通命令队列
    }

    private func paint(_ v: Double) {
        let pct = Int((v * 100).rounded())
        label.stringValue = "\(pct)%"
        label.textColor = (pct == 0) ? .systemRed : .secondaryLabelColor
    }

    /// 只有外部真的改了值才回写 —— 拖动中绝不反向覆盖拇指位置
    func apply(_ v: Double) {
        if abs(slider.doubleValue - v) > 0.02 { slider.doubleValue = v }
        paint(v)
    }
}

struct LabeledSlider: NSViewRepresentable {
    let value: Double
    let onEdit: (Double) -> Void
    var meterKey: String = ""

    func makeNSView(context: Context) -> SliderRowView {
        let v = SliderRowView()
        v.onEdit = onEdit
        v.meterKey = meterKey
        v.apply(value)
        return v
    }

    func updateNSView(_ v: SliderRowView, context: Context) {
        v.onEdit = onEdit
        v.meterKey = meterKey
        v.apply(value)           // 内部有 0.02 死区，拖动时不会被打断
    }
}

// MARK: - UI

struct RowView: View {
    let title: String
    let subtitle: String?
    let icon: NSImage?
    let playing: Bool
    let value: Double
    let onEdit: (Double) -> Void
    var meterKey: String = ""
    var onRelease: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed").frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Typo.name.text(title).lineLimit(1)
                        if playing {
                            Image(systemName: "waveform").font(Typo.badge.font)
                                .foregroundStyle(.green)
                        }
                    }
                    if let subtitle {
                        Typo.tiny.text(subtitle).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                if let onRelease {
                    Button(action: onRelease) {
                        Image(systemName: "minus.circle").font(Typo.ui.font)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("取消单独控制，回到「其他」")
                }
            }
            LabeledSlider(value: value, onEdit: onEdit, meterKey: meterKey)
                .padding(.leading, 22)   // = 图标16 + 间距6，与 App 名称左边缘对齐
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 注意：这里【绝不能】打日志 / 取图标 / 做任何 I/O。
        // body 在拖滑块时每秒求值 ~60 次，渲染热路径必须是纯计算。
        return panelBody
    }

    var panelBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Typo.title.text("App 音量控制").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Typo.caption.text("共 \(model.visible.count) 个 App")
                    .foregroundStyle(.secondary)
                Spacer()
                Circle().fill(model.engineUp ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Typo.caption.text(model.engineUp ? "引擎运行中" : "引擎未连接").foregroundStyle(.secondary)
            }

            Divider()

            // 用 ScrollView + LazyVStack，而不是 List：
            // macOS 的 List 会自带一层内容缩进（实测约 6-10pt），行的左边缘永远和标题对不齐。
            // 这里每一处 inset 都自己控制 —— 行的【图标左边缘 = 标题左边缘】。
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.visible.isEmpty {
                        Typo.name.text("没有识别到 App（共收到 \(model.apps.count) 条）")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                    ForEach(model.visible) { a in
                        RowView(title: a.name,
                                subtitle: a.isSystemService ? "通知/警告提示音都走这里"
                                         : (a.realApp ? nil : a.key),
                                icon: a.icon,
                                playing: a.playing,
                                value: model.desired[a.key] ?? 1.0,
                                onEdit: { model.control(a, gain: $0) },
                                meterKey: a.key,
                                onRelease: model.desired[a.key] != nil ? { model.release(a) } : nil)
                            .padding(.vertical, 7)     // 行内上下留白
                        Divider()                      // 行间分隔线（与 List 视觉一致）
                    }
                }
            }
            .scrollIndicators(.hidden)
            // 必须是【确定高度】：maxHeight 会让 ScrollView 在自适应窗口里被压成 0 高
            .frame(height: 300)

            DisclosureGroup(isExpanded: Binding(
                                get: { model.showAll },
                                set: { model.showAll = $0 })) {
                RowView(title: "其他所有 App", subtitle: nil, icon: nil, playing: false,
                        value: model.desired["ALL"] ?? model.allGain,
                        onEdit: { model.control(label: "ALL", $0) },
                        meterKey: "ALL")
            } label: {
                Typo.ui.text("其他所有 App  \(Int(model.allGain * 100))%")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { model.showSystem },
                                         set: { model.showSystem = $0 })) {
                        Typo.caption.text("显示系统进程")
                    }
                    .toggleStyle(.checkbox).controlSize(.mini)
                    // 开机自启很关键：App 不启动 = 没有 tap = 完全没有音量控制
                    Toggle(isOn: Binding(get: { model.autostart },
                                         set: { _ in model.toggleAutostart() })) {
                        Typo.caption.text("开机自启")
                    }
                    .toggleStyle(.checkbox).controlSize(.mini)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button(action: { model.toggleBypass() }) {
                        Typo.caption.text(model.bypass ? "取消全部静音" : "全部静音")
                    }
                    .controlSize(.small)
                    Button(action: { NSApp.terminate(nil) }) { Typo.caption.text("退出") }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }
}

@main
struct PerAppVolApp: App {
    init() {
        // 注意：不能依赖 PanelView.onAppear —— MenuBarExtra(.window) 的内容
        // 只有用户点开菜单时才创建，那时才启动引擎就太晚了。
        Autostart.migrateLegacy()   // 旧 label 的 LaunchAgent 会拉起第二个 App，必须先清
        DispatchQueue.main.async { AppModel.shared.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(AppModel.shared)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)

        // 另给一个普通窗口：既是"打开主窗口"的产品功能，
        // 也方便调试（MenuBarExtra 的面板无法用 screencapture -l 精确截取）。
        Window("PerAppVol", id: "main") {
            PanelView().environmentObject(AppModel.shared)
        }
        .windowResizability(.contentSize)
    }
}

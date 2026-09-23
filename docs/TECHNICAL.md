# 技术笔记

PerAppVol 的实现细节、实测数据与踩过的坑。面向要改代码或做同类工具的人。

---

## 一、结论

macOS **没有**"按 App 调音量"的现成公开 API。
但 **CoreAudio Process Taps（macOS 14.2+）** 提供了全部所需原语，而且
**不需要写虚拟音频驱动**（不用 AudioServerPlugIn、不用装驱动、不用 `killall coreaudiod`）。

| 需要的能力 | API |
|---|---|
| 枚举"哪个 App 在出声" | `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningOutput` |
| 按进程抓它的音频 | `CATapDescription.initStereoMixdownOfProcesses:` + `AudioHardwareCreateProcessTap` |
| 把该 App 的音频从硬件劫走 | `CATapDescription.muteBehavior = CATapMuted` |
| 把 N 路 tap 装进聚合设备当输入 | `AudioHardwareCreateAggregateDevice` + `kAudioAggregateDeviceTapListKey` |

> 另有 `AudioToolbox` 私有符号 `ATSubmixTap*`（`ATSubmixTapNew` / `GetSourceAudio` / `ATAssignToSubmixTap`），
> 无公开头文件，属 SPI。功能等价的另一条路，仅供研究。

## 二、架构

```
┌─ App A ─┐   ┌─ App B ─┐   ┌─ 其余所有 App ─┐
└────┬────┘   └────┬────┘   └───────┬────────┘
     │ tap A       │ tap B          │ "exclude" 全局 tap
     │ CATapMuted  │ CATapMuted     │ CATapMuted   ← 音频不再直通硬件
     ▼             ▼                ▼
┌──────────────────────────────────────────────────────┐
│ 私有聚合设备（taps=[A,B,ALL]，subdevices=[真实输出设备]）│
│   master = 真实输出设备 → 同一时钟，零漂移、低延迟       │
│   输入流 1..N = 每个 tap 一路；输出流 = 真实设备         │
└────────────────────────┬─────────────────────────────┘
                         │ AudioDeviceCreateIOProcIDWithBlock
                         ▼
           render():  out = Σ in[i] × gain[i]（增益带线性斜坡）
                      ↓
                    链接式峰值限幅器（立体声联动，快攻慢放）
                         ▼
                  真实输出设备（扬声器 / 蓝牙耳机）
```

**进程模型**：

```
PerAppVol.app（菜单栏 UI，SwiftUI）          ← 只是控制器，崩了不能断音
        │  Unix socket  /tmp/perappvol.sock
        ▼
perappvol serve（常驻混音引擎，ObjC）        ← 真正的音频通路
```

**关键点**
- **每个 App 一个 tap = 聚合设备里一路独立输入流** —— 这就是 per-app 音量的全部秘密。
- 真实输出设备作为 **sub-device** 塞进同一个聚合设备，输入输出共用一个 IOProc、一个时钟
  —— 不需要额外 AudioUnit，也没有时钟漂移。
- 流的顺序由 `kAudioAggregateDevicePropertyFullSubDeviceList` 决定；实测该列表**只含 sub-device 的 UID，
  不含 tap UID**，所以用 tap 创建顺序映射。
- **身份键**用 `.app` 的 `Info.plist` bundle ID（路径会变），**归组**用 `.app` 包路径（保证 helper 归并）。

## 三、控制协议（Unix socket）

```
set <label> <0.0-1.0>     设置增益        -> OK | ERR <msg>
gain <label> <0-100>      同上，百分比
mute <label> <on|off>
get                       -> "<label> <gain>" 多行，最后 "END"
stat                      -> cb / out / opk / lim + 每路 in（rms/pk/gain）
add <label> [gain]        运行时新增一路 per-app 控制
remove <label>            运行时移除
list                      -> app \t real \t playing \t pid \t 名字 \t key \t path
quit
```

label 可含空格（`.app` 路径）；解析规则是「数字参数在最后，中间整体是 label」。

## 四、实测数据

### 1. 每 App 一路独立音频流
```
[diag] inInputData->mNumberBuffers=2  outCh=2 outFrames=512
[cb=23] [62498 100% rms=0.07149] [ALL 100% rms=0.89572]  OUT rms=0.94201
[cb=71] [62498 100% rms=0.00141] [ALL 100% rms=1.07639]  OUT rms=1.07669
```
48kHz / 32bit float / 交错立体声，512 帧一次回调。

### 2. 增益精确、隔离完美

稳态正弦波（amplitude 0.5，理论 `rms = 0.5/√2 = 0.35355`）：

| 目标增益 | 实测 in_rms | 实测 OUT_rms | 期望 in×gain |
|---|---|---|---|
| 0%   | 0.34809 | **0.00000** | 0（完全静音） |
| 4%   | 0.34976 | 0.01512 | 0.0140 |
| 30%  | 0.34793 | 0.10321 | 0.1044 |
| 77%  | 0.35498 | 0.27416 | 0.2733 |
| 100% | 0.35874 | **0.35874** | 0.3587 |

其余 App 那一路恒为 `0.00000` —— **互不串扰**。

### 3. 限幅器
3 路各 `rms=0.636` 全开（线性和 ≈1.10、峰值可达 2.7）→ `OUT rms=0.457, lim=-8.0dB`，峰值压到 0.98 以内。

### 4. 音频到底走哪个进程

| 触发方式 | systemsoundserverd | QQ | 微信 | 飞书 | App 自己 |
|---|---|---|---|---|---|
| `osascript -e 'beep'`（系统提示音） | **0.192** | 0 | 0 | 0 | — |
| `display notification … sound name`（**消息提示音**） | **0.108** | 0 | 0 | 0 | — |
| `afplay` / `say`（App 自己放音） | 0 | — | — | — | ✅ |

**结论：消息提示音走 `systemsoundserverd`，不走 App 自己。**
所以"给 QQ 调音量"管不到它的新消息提示音 —— 那要调「系统提示音」这一路。
细分：App 前台自己播的提示音（自研音效）走 App 自己 ✅；后台收消息走系统通知 → `systemsoundserverd`。

### 5. 短命进程（systemsoundserverd）
```
in systemsoundserverd pk=0.15338 gain=0.300
                opk 0.04601
```
`0.15338 × 30% = 0.046014` —— 与 `opk` 精确吻合。

## 五、踩过的坑（18 条，全部实测）

1. **静默鉴权失败**：没权限时 tap 不报错、只给静音。必须看
   `log stream --predicate 'process == "coreaudiod"'` 找
   `Client is not granted access to the tap.`，否则会以为 API 用错。
2. **`CATapMuted` + 无权限 = 全机静音**：声音被劫走但拿不到数据 → 什么都没了。
   引擎必须加启动前权限守卫（`CGPreflightScreenCaptureAccess()`）。
3. **ad-hoc 签名拿不到 TCC 身份**：app 压根不出现在系统设置的授权列表里。
   必须用有稳定身份的签名（Developer ID 或本地自签名证书）。
4. **自激反馈**：兜底的 `ALL` tap 会把混音器**自己的输出**抓回来形成正反馈
   —— 表现为"没动那一路，它的 RMS 却跟着总输出走"。
   **必须把自己的进程对象加进 `initStereoGlobalTapButExcludeProcesses:` 的排除列表。**
5. **多 App 叠加会过载**：线性和可达 `rms>1`、峰值 2.7，会削顶。已加链接式峰值限幅器。
6. **`MenuBarExtra(.window)` 的内容只在用户点开菜单时才创建** —— 启动逻辑（拉引擎、申请权限）
   绝对不能放 `onAppear`，要放 `App.init()`。
7. **权限弹窗与引擎启动有竞争**：首次启动时用户还没点完弹窗，引擎的权限守卫就会拒绝启动。
   UI 必须持续重试（限流）。
8. **纯 `swiftc` 编 SwiftUI 有限制**：需要 `-parse-as-library`（否则 `@main` 报 "contains top-level code"）；
   且 `@State`/`@StateObject` 是宏，需要 `SwiftUIMacros` 插件（只有 Xcode 构建系统提供）。
   **不要用它们，状态放 `ObservableObject`，`Binding` 手工构造。**
9. **进程对象是短命的**：`while :; do afplay x.aiff; done` 每次都是新进程，
   tap 绑死在旧进程对象上 → 永远静音。验证务必用**单个长生命周期**音频源。
10. **`CATapDescription` 的头文件不在 `CoreAudio.h` 里**，要单独
    `#import <CoreAudio/AudioHardwareTapping.h>` 和 `#import <CoreAudio/CATapDescription.h>`。
11. **TCC 责任进程**：从终端跑的工具，权限算在终端 App 头上。
    而且 **`CGRequestScreenCaptureAccess` 对已拒绝过的进程不会重新弹窗**，只能去系统设置手动打开。
12. **`kAudioAggregateDevicePropertyFullSubDeviceList` 不含 tap 的 UID**（实测只返回 sub-device），
    "输入流 → 哪个 App"的映射要用 tap 创建顺序来推。
13. **HDMI/DP 设备没有硬件音量属性**，但走本方案时音量是自己乘增益，不受此限制。
14. **短命音频进程必须用 `bundleIDs` + `processRestoreEnabled`**（macOS 26+）。
    `systemsoundserverd` 只在播提示音的那一瞬连上 coreaudiod：
    按 object ID 建 tap 会 `ERR cannot create tap`；就算建成，它重连后拿到新的 object ID 也接不上。
    ```objc
    d = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[]];
    d.bundleIDs = @[@"systemsoundserverd"];   // 按 bundle ID 圈定，而非 object ID
    d.processRestoreEnabled = YES;            // 进程重启后系统自动恢复到 tap
    ```
15. **`gInRMS` 只反映最后一个 ~10ms 缓冲**，提示音只有 0.1s 级，低频采样会整段漏掉。
    已加**峰值保持**（`pk`，约 2.6s 衰减）—— 做电平表和短促声音检测都必须用它。
16. **`catchAllExcludeList` 曾把逻辑写反**（把"未单独控制的"App 排除出 `ALL`），
    导致它们直通硬件、「其他所有 App」滑块等于失效。
17. **中文文本必须 per-run**：`Font.system` 自然回落会让中文字形**重叠**（字宽算错）。见第六节。
18. **App 重启**：进程对象失效，需监听 `kAudioHardwarePropertyProcessObjectList` 变化并重建 tap。

### 工程层面踩过的坑

- **ad-hoc 签名的自签名证书**三件事缺一不可：
  `keyUsage=critical,digitalSignature,nonRepudiation`（缺了报 `Invalid Key Usage for policy`）；
  p12 用 `PBE-SHA1-3DES`（OpenSSL 3.x 默认算法 macOS 的 `security` 认不了，报 `MAC verification failed`）；
  `security add-trusted-cert -r trustRoot -p codeSign`（否则标 `CSSMERR_TP_NOT_TRUSTED`）。
- **DMG 是只读挂载**，不能原地重签 —— 必须先拷到临时目录。
- **隔离标记是拷进 /Applications 时才打上的** —— `xattr` 清理要在安装**之后**。
  macOS 15+ 还会加 `com.apple.provenance`，与 `com.apple.quarantine` 一样会触发"已损坏"。
- **`NSRunningApplication.bundleIdentifier` 拿到的是 helper 自己的** bundleID
  （AweSun 会拿到 `com.oray.sunlogin.macclient.agent` 而非主 App）。
  稳定身份要用 `.app` 的 `Info.plist` bundle ID。
- **Swift：`init()` 里的赋值不触发 `didSet`** —— 数据迁移的结果必须显式写回。
- **`swiftc` 不认 `-arch`**（那是 clang 的），要用 `-target arm64-apple-macos14.2`。
- **`swiftc` 单文件默认当脚本编译**，`@main` 会报 "contains top-level code"，需要 `-parse-as-library`。
- **项目改名（mac-sound-control → PerAppVol）不是改字符串**，系统侧有一整套持久状态跟着 bundle ID / label 走，
  漏一个就出事。完整清单和迁移脚本见 `scripts/migrate-legacy.sh`：
  | 改了 | 不加迁移会怎样 |
  |---|---|
  | bundle ID | TCC 授权按 bundle ID 记账 → 旧授权不再匹配（旧条目成死记录，用 `tccutil reset` 清）；`UserDefaults` 也按 bundle ID 分域 → 用户的每 App 音量设置丢失（要 `defaults export/import`，不能 `mv` 文件，cfprefsd 有缓存会写回） |
  | LaunchAgent label | 旧 agent 的 `KeepAlive=true` 会再拉起一个 App：两个菜单栏图标，两个 UI 抢引擎 |
  | `/tmp/*.sock` | 旧引擎照跑、占着旧 socket，新引擎绑新 socket → 两个引擎同时抓音频，自激反馈 + 双份声音。要按 socket 反查 pid（`lsof -U`）杀，不要无差别 `pkill` |
  | LaunchServices 注册 | 同一路径同时挂两个 bundle ID，`open` 打开哪个看注册顺序（注销前要确认已安装的 App 确实是旧 ID，否则会把新版一起注销） |
- **macOS 自带的 bash 是 3.2，`"$var）…"` 会把全角字符的字节吃进变量名**（变量名变成 `var\uff09` 这种）——
  `set -u` 下直接报 `unbound variable` 把脚本打死（实测迁移脚本就死在这）。
  **变量紧跟中文时必须写 `${var}`**，一个都不能饶。
- **`FileHandle(forWritingTo:)` 是 O_WRONLY 且偏移为 0**：用它当子进程的 stderr 时，
  新进程的输出会从文件**开头覆盖**，上一次“确实起来了”的日志被盖掉 ——
  现场表现为“引擎日志里没有启动记录，看起来根本没跑过”（实测花了很久才反应过来）。
  必须先 `seekToEnd()`（或在子进程里用 `fopen(..., "a")`）。

## 六、中英混排的字体排版

### 1. 中文必须比拉丁【细两档】才视觉平衡

中日韩字形笔画密度天然高于拉丁。同样叫 "Light"，苹方细体看着也比 SF Mono Light 黑得多。

| 拉丁 | 配套中文 | 苹方字重 |
|---|---|---|
| SF Mono Light | 比拉丁细两档 | `PingFangSC-Thin` 纤细体 |
| SF Mono Medium | 与拉丁同字重 | `PingFangSC-Medium` 中黑体 |

苹方六档可直接指定：`PingFangSC-{Ultralight,Thin,Light,Regular,Medium,Semibold}`

### 2. `Font.system` 自然回落会让中文字形【重叠】

**实测 bug**：`Text(s).font(Font.system(size: 13, weight: .medium, design: .monospaced))`
渲染「音量控制」时，四个中文字**互相叠在一起** —— 看起来像"失真"，实际是字宽（advance width）算错。

同一张图里的对照：
- 「共 17 个 App」用 **per-run 显式指定苹方** → 字距正常 ✓
- 「App 音量控制」用 **`Font.system` 自然回落** → 中文字形重叠 ✗

**结论：所有含中文的文本都必须走 per-run（`AttributedString` 按字符集切 run、各自指定字体）。**

### 3. `NSFont` 的自动回落做不到"比拉丁更细"

`NSFont.monospacedSystemFont(ofSize:, weight: .light)` 回落到汉字时被 **SF Mono 的最细档（Light）钳住**
—— 请求 `.ultraLight` 也只会给苹方细体。要更细只能**显式指定苹方 PostScript 名**。

### 4. font cascade list 在 AppKit 有效、SwiftUI 不保证

`NSFontDescriptor` 的 `NSFontCascadeListAttribute` 在 `NSString.draw` 下确实生效（72pt 验证四档差别明显），
但 SwiftUI 的 `Text` 不保证保留它。**不赌** —— 统一用 per-run。

### 5. 一处开关

```swift
enum Typo {
    static let cjkBody  = "PingFangSC-Thin"      // 正文中文字重
    static let cjkTitle = "PingFangSC-Medium"    // 标题中文字重（与拉丁同字重）
    static let title / name / ui / caption / tiny / num
}
```

## 七、UI 性能（拖滑块必须零延迟）

拖动每秒约 60 个事件。热路径上任何 I/O 或 diff 都会表现为"不跟手"。

| 热路径上的操作 | 反模式 | 做法 |
|---|---|---|
| 滑块控件 | SwiftUI `Slider` + `@Binding`（每步写 `@Published` → 整列表 diff） | **`NSViewRepresentable` 包装 `NSSlider`**，拖动零 SwiftUI diff |
| 百分比数字 | 等 SwiftUI 重绘 | **`NSTextField` 原生刷新** |
| 期望状态 | `@Published`（每次写都触发重绘） | **普通字典**，需要时才 `touch()` |
| 图标 | 计算属性 `NSWorkspace.icon(forFile:)`（每秒上千次磁盘查询） | **`IconCache` 存储属性**，每个 App 只解析一次 |
| 命令发送 | 每个事件一条 socket 连接（60/s） | **latest-wins 合并 + 25ms 批量** |
| 日志 | 渲染热路径写文件 | 渲染路径**零 I/O** |
| 电平表 | 经过 SwiftUI diff | **AppKit 自绘 30Hz**，共享 `MeterFeed` 10Hz 轮询 |

端到端延迟预算：滑块 0ms + 合并 ≤25ms + socket ~3ms + 下一回调 ~10ms ≈ **≤40ms**（架构理论下限）。

## 八、图标体积

`NSBitmapImageRep` 的 PNG 输出几乎不压缩（1024² 高达 3.6MB）。两个改动让 `icns` 从 1.6M 降到 **179K**：

1. 换 **ImageIO**（`CGImageDestination`）写 PNG：3.6MB → 1.4MB
2. 渐变方向 **斜向 → 垂直**：PNG 的 Sub/Up 滤波器对垂直渐变近乎无损预测，1.4MB → **242KB**

> 这条对任何"渐变背景 + 扁平图形"的图标都适用 —— 是 PNG 编码特性。

## 九、发布

- **GitHub Actions**：`.github/workflows/ci.yml`（每次 push 构建验证）、
  `.github/workflows/release.yml`（推 `v*` 标签 → 构建 + 签名 + 公证 + 发布 Release）
- **只出 arm64**：无 x86 测试环境，不做未经验证的构建。
  架构在构建脚本里显式钉死（`clang -arch arm64` / `swiftc -target arm64-apple-macos14.2`）。
- **没有 Apple 开发者账号也能分发**：DMG 里的「安装.command」会在用户机器上生成本地自签名证书并重签，
  从而取得 TCC 授权。见 `install.command` 的注释。
- **分发给其他 Mac 正式签名**：
  ```bash
  codesign --force --deep --options runtime --sign "Developer ID Application: …" build/PerAppVol.app
  xcrun notarytool submit build/PerAppVol-arm64.dmg --keychain-profile <profile> --wait
  xcrun stapler staple build/PerAppVol-arm64.dmg
  ```


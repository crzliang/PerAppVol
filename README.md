# mac-sound-control —— macOS 按 App 单独控制音量

像 Windows 音量合成器那样，给每个 App 单独调音量/静音。

**状态：核心链路 + 菜单栏 App 全部跑通**（含 TCC 授权、端到端验证）。

```
build/PerAppVol.app     ← 菜单栏 App（图标：扬声器）
./build-app.sh          ← 重新编译打包
```

---

## 一、结论

macOS **没有**"按 App 调音量"的现成公开 API。
但它有一套**公开的原语**（CoreAudio Process Taps，macOS 14.2+），足够你自己实现，而且
**不需要写虚拟音频驱动**（不用 AudioServerPlugIn、不用装驱动、不用 `killall coreaudiod`）。

所需原语只有 4 个：

| 需要的能力 | API | 状态 |
|---|---|---|
| 枚举"哪个 App 在出声" | `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningOutput` | ✅ 零权限 |
| 按进程抓它的音频 | `CATapDescription.initStereoMixdownOfProcesses:` + `AudioHardwareCreateProcessTap` | ✅ |
| 把该 App 的音频从硬件劫走 | `CATapDescription.muteBehavior = CATapMuted` | ✅ |
| 把 N 路 tap 装进聚合设备当输入 | `AudioHardwareCreateAggregateDevice` + `kAudioAggregateDeviceTapListKey` | ✅ |

> 另有 `AudioToolbox` 私有符号 `ATSubmixTap*`（`ATSubmixTapNew` / `GetSourceAudio` / `ATAssignToSubmixTap`），
> 无公开头文件，属 SPI，上架不可用。功能上是同一套东西的另一条路，仅供研究。

---

## 二、已验证的实测结果

### 1. 每个 App 一路独立音频流
```
[diag] inInputData->mNumberBuffers=2 期望=2  outCh=2 outFrames=512
[diag]   in buf0 ch=2 bytes=4096        ← 48kHz / 32bit float / 交错立体声
[cb=23] [62498 100% rms=0.07149] [ALL 100% rms=0.89572]  OUT rms=0.94201
[cb=71] [62498 100% rms=0.00141] [ALL 100% rms=1.07639]  OUT rms=1.07669
```
两路 RMS 特征完全不同（一路是语音有停顿，一路恒定）—— **确实是按 App 分开的**。

### 2. 增益精确、隔离完美

稳态正弦波（amplitude 0.5，理论 `rms = 0.5/√2 = 0.35355`），扫动目标 App 增益、其余静音：

| 目标增益 | 实测 in_rms | 实测 OUT_rms | 期望 in×gain |
|---|---|---|---|
| 0%   | 0.34809 | **0.00000** | 0（完全静音） |
| 1%   | 0.35371 | 0.00218 | 0.0035 |
| 4%   | 0.34976 | 0.01512 | 0.0140 |
| 30%  | 0.34793 | 0.10321 | 0.1044 |
| 53%  | 0.35861 | 0.18869 | 0.1901 |
| 77%  | 0.35498 | 0.27416 | 0.2733 |
| 100% | 0.35874 | **0.35874** | 0.3587 |

其余 App 那一路恒为 `rms=0.00000` —— **互不串扰**。

### 3. 限幅器
3 路各 `rms=0.636` 全开（线性和 `rms≈1.10`、峰值可达 2.7）：
```
[cb=23] [63345 100% rms=0.62978] [63346 100% rms=0.63463] [63347 100% rms=0.63695]
        OUT rms=0.45656  lim=-8.0dB        ← 峰值被压到 0.98 以内，不再削顶
```

### 4. 输出设备热切换
切到 S2716Q 再切回，tap 全程保留，回调计数连续（24 → 862 无中断）：
```
[engine] 重建完成（output device change）：1 路 per-app 输入 -> 142 S2716Q
[engine] 重建完成（output device change）：1 路 per-app 输入 -> 130 MacBook Air扬声器
```

### 5. 运行时动态增删 App
```
启动: ALL 1.000                       ← 1 路
add 63772 1.0  →  ALL 1.000 / 63772 1.000   ← 2 路，各自独立
set 63772 0.2  →  日志 [ALL 100% rms=0.63] [63772 20% rms=0.63]   ← 确实分离
remove 63772   →  ALL 1.000          ← 回 1 路，ALL rms 升到 0.85（两路合并）
```

### 6. 通过菜单栏 App 端到端（引擎用 app 自己的 TCC 身份跑）
```
ALL=1.0  in 0.645  out 0.64535      ← 有声
ALL=0.0  in 0.627  out 0.00000      ← 完全静音（输入仍在捕获）
ALL=1.0  in 0.643  out 0.64280      ← 恢复
```

---

## 三、架构

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

**进程模型（重要）**：

```
PerAppVol.app（菜单栏 UI，SwiftUI）          ← 只是控制器，崩了不能断音
        │  Unix socket  /tmp/mac-sound-control.sock
        ▼
perappvol serve（常驻混音引擎，ObjC）        ← 真正的音频通路
```
引擎必须常驻（UI 退出/崩溃都不能断音），所以拆成两个进程。

**关键点**：
- **每个 App 一个 tap = 聚合设备里一路独立输入流**，所以能单独增益。这就是 per-app 音量的全部秘密。
- 把真实输出设备作为 **sub-device** 塞进同一个聚合设备，输入输出共用一个 IOProc、一个时钟 ——
  不需要额外 AudioUnit，也没有时钟漂移。
- 流的顺序由 `kAudioAggregateDevicePropertyFullSubDeviceList` 决定；实测该列表**只含 sub-device 的 UID，
  不含 tap UID**，所以用 tap 创建顺序映射（实测正确）。

---

## 四、需要准备什么

### 1. 系统要求
- **macOS 14.2+**（`AudioHardwareCreateProcessTap` 的最低版本）
- `CATapDescription.bundleIDs` / `processRestoreEnabled`（App 重启后自动重新纳入 tap）需要 **macOS 26+**

### 2. ⚠️ 代码签名是硬门槛（实测结论）

| 签名方式 | TCC 能否授权 | 实测现象 |
|---|---|---|
| 裸 CLI 二进制 | ❌ | 权限算在**责任进程（终端）**头上 |
| `.app` + **ad-hoc**（`-s -`） | ❌ | **app 根本不出现在系统设置的授权列表里**，`CGRequestScreenCaptureAccess` 无效 |
| `.app` + **真实签名身份** | ✅ | `com.mac-sound-control.perappvol` 出现在列表，授权后 tap 拿到真数据 |

查可用身份：
```bash
security find-identity -v -p codesigning
```
本仓库 `build-app.sh` 会自动挑 `SoundControl Local Signing`；也可以
`SIGN_IDENTITY='你的身份' ./build-app.sh`。
正式发行用 **Developer ID Application** + 公证。

### 3. TCC 权限
「屏幕与系统音频录制」(`kTCCServiceScreenCapture`)。首次运行 `CGRequestScreenCaptureAccess()` 会弹窗。
> 没权限时 tap **不报错、只给静音**。而 `CATapMuted` 又会把 App 的声音劫走 —— 合起来就是
> **全机静音**。所以 `perappvol` 有启动前权限守卫，没权限直接拒绝启动（见坑 1、2）。

### 4. 其它
- **Info.plist**：`CFBundleIdentifier` 必填；建议加 `NSAudioCaptureUsageDescription` / `NSSystemAudioCaptureUsageDescription`；`LSUIElement=true` 只留菜单栏图标
- **不能上 Mac App Store**：tap 与沙盒不兼容，需 Developer ID 直发 + 公证

### 5. 控制协议（`perappvol serve`，Unix socket）
```
set <label> <0.0-1.0>     设置增益        -> OK | ERR <msg>
gain <label> <0-100>      同上，百分比
mute <label> <on|off>
get                       -> "<label> <gain>" 多行，最后 "END"
stat                      -> cb/out/lim + 每路 in 电平，最后 "END"
add <label> [gain]        运行时新增一路 per-app 控制
remove <label>            运行时移除
list                      -> 所有 HAL 进程（objID pid runningOut bundleID），最后 "END"
quit
```

---

## 五、路线图

**阶段 0 —— PoC** ✅ 进程枚举、tap、聚合设备、IOProc、定位 TCC
**阶段 1 —— 打通音频** ✅ 拿到真数据、`CATapMuted` 劫持生效、多 tap 独立
**阶段 2 —— 混音引擎** ✅ per-app 增益 + 斜坡、共用时钟输出、运行时调音量、限幅器、设备热切换、动态增删
**阶段 3 —— 产品化** 🚧
- [x] 菜单栏 UI（滑块列表 + App 图标/名字 + 静音 + 全部静音）
- [x] 引擎自动拉起 + TCC 申请 + 失败重试
- [x] UI/引擎双进程分离
- [ ] UI 里显示电平表（引擎 `stat` 已支持）
- [ ] 按 bundle ID 持久化音量设置；App 启动时自动应用
- [ ] 用 `kAudioProcessPropertyIsRunningOutput` 做"正在播放"高亮 + 自动收纳
- [ ] 限幅器参数可调 / 加 soft-clip 后级（当前持续过载时压得较狠，-8dB）
- [ ] 延迟测量与优化
- [ ] 全局快捷键、按 App 独立输出设备、语音/提示音单独控制
- [ ] LaunchAgent 开机自启

---

## 五之二、音频到底走哪个进程（实测，决定产品语义）

用「每 App 一路 + 峰值保持」实测各路 `pk`（峰值）：

| 触发方式 | systemsoundserverd | QQ | 微信 | 飞书 | App 自己 |
|---|---|---|---|---|---|
| `osascript -e 'beep'`（系统提示音） | **0.192** | 0 | 0 | 0 | — |
| `display notification … sound name "Glass"`（**消息提示音**） | **0.108** | 0 | 0 | 0 | — |
| `afplay 音效`（App 自己放音） | 0 | — | — | — | ✅ 落在该 App |
| `say 语音`（App 长时间放音） | 0 | — | — | — | ✅ 落在该 App |

### 结论（产品必须知道）

**「新消息提示音」走 `systemsoundserverd`，不走 App 自己。**

`systemsoundserverd` 是系统提示音服务 —— `NSSound`、`AudioServicesPlayAlertSound`、
系统通知的 `soundName` 最终都由它混音输出。

所以：
- 给 QQ / 微信 / 飞书 调音量 → 管得住 **它们自己的音频**（语音消息、视频通话、App 内音效）
- 但管不住 **「新消息提示音」** → 那要调「**系统提示音**」这一路

细分：
- App **在前台**自己播放的提示音（自研音效）→ 走 App 自己的进程 ✅ 可单独控
- App **在后台**收消息走系统通知（`UNUserNotificationCenter` + `soundName`）→ `systemsoundserverd`

因此 UI 把 `systemsoundserverd` 提升为一等公民，显示为「**系统提示音**」（铃铛图标），
可以单独调、单独静音 —— 这正是"夜里静音提示音但保留通话音量"这类需求的开关。

---

## 五之三、中英混排的字体排版（实测踩坑）

### 1. 中文必须比拉丁【细两档】才视觉平衡

中日韩字形笔画密度天然高于拉丁。同样叫 "Light"，苹方细体看着也比 SF Mono Light 黑得多。

| 拉丁 | 配套中文 | 苹方字重 |
|---|---|---|
| SF Mono Light | 比拉丁细两档 | `PingFangSC-Thin` 苹方-简 纤细体 |
| SF Mono Medium | 与拉丁同字重 | `PingFangSC-Medium` 苹方-简 中黑体 |

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
    static let title / name / ui / caption / tiny / num  // 各档字号与拉丁字重
}
```
改一处即可全局生效。

---

## 六、坑与已知限制（全部实测踩过）

1. **静默鉴权失败**：没权限时 tap 不报错只给静音。必须看
   `log stream --predicate 'process == "coreaudiod"'` 找
   `Client is not granted access to the tap.`，否则会以为 API 用错。
2. **`CATapMuted` + 无权限 = 全机静音**：声音被劫走但拿不到数据 → 什么都没了。
   引擎必须加启动前权限守卫（`CGPreflightScreenCaptureAccess()`），否则会把用户的电脑弄没声。
3. **ad-hoc 签名拿不到 TCC 身份**：app 压根不出现在系统设置的授权列表里。必须用真实签名身份（见第四节）。
4. **自激反馈（真 bug，已修）**：兜底的 `ALL` tap 会把**混音器自己的输出**抓回来形成正反馈 ——
   表现为"没动那一路，它的 RMS 却跟着总输出走"。
   **必须把自己的进程对象加进 `initStereoGlobalTapButExcludeProcesses:` 的排除列表。**
5. **多 App 叠加会过载**：线性和可达 `rms>1`、峰值 2.7，会削顶。已加链接式峰值限幅器。
6. **`MenuBarExtra(.window)` 的内容只在用户点开菜单时才创建** —— 启动逻辑（拉引擎、申请权限）
   绝对不能放 `onAppear`，要放 `App.init()` 或 `NSApplicationDelegate`。
7. **权限弹窗与引擎启动有竞争**：首次启动时用户还没点完弹窗，引擎的权限守卫就会拒绝启动。
   UI 必须持续重试（限流），不能一次失败就放弃。
8. **纯 `swiftc` 编 SwiftUI 有限制**：需要 `-parse-as-library`（否则 `@main` 报"contains top-level code"）；
   且 `@State` 这类宏展开需要 `SwiftUIMacros` 插件（只有 Xcode 构建系统提供）——
   **不要用 `@State`/`@StateObject`，状态放 `ObservableObject`，`Binding` 手工构造。**
9. **进程对象是短命的**：`while :; do afplay x.aiff; done` 每次都是新进程，tap 绑死在旧进程对象上 → 永远静音。
   验证务必用**单个长生命周期**音频源（`afplay` 一个长 wav，或 `say` 一段长文本）。
10. **`CATapDescription` 的头文件不在 `CoreAudio.h` 里**，要单独
    `#import <CoreAudio/AudioHardwareTapping.h>` 和 `#import <CoreAudio/CATapDescription.h>`。
11. **TCC 责任进程**：从终端跑的工具，权限算在终端 App 头上（本项目算在 Ghostty 头上）。
    而且 **`CGRequestScreenCaptureAccess` 对已拒绝过的进程不会重新弹窗**（见 `CGWindow.h` 注释），
    只能去系统设置里手动打开。
12. **`kAudioAggregateDevicePropertyFullSubDeviceList` 不含 tap 的 UID**（实测只返回 sub-device），
    "输入流 → 哪个 App"的映射要用 tap 创建顺序来推。
13. **HDMI/DP 设备没有硬件音量属性**（见 `volctl.swift devices`），但走本方案时音量是自己乘增益，
    **不受此限制**。
14. **提示音不归 App 管**：见「五之二」。给 App 调音量管不到它的新消息提示音（那走 `systemsoundserverd`）。
15. **`gInRMS` 只反映最后一个 ~10ms 缓冲**，提示音只有 0.1s 级，低频采样会整段漏掉。
    已加**峰值保持**（`pk`，约 2.6s 衰减）——做电平表和短促声音检测都必须用它，不能用瞬时 RMS。
16. **`catchAllExcludeList` 曾把逻辑写反**（把"未单独控制的"App 排除出 `ALL`），
    导致它们直通硬件、「其他所有 App」滑块等于失效。已修正为只排除"已单独控制的 + 自己"。
17. **短命音频进程必须用 `bundleIDs` + `processRestoreEnabled`**（macOS 26+）。
    `systemsoundserverd` 只在播提示音的那一瞬连上 coreaudiod，安静时就断开：
    按 object ID 建 tap 会 `ERR cannot create tap`（建 tap 时它不在列表里）；
    就算建成，它重连后拿到新的 object ID 也接不上。
    正解：
    ```objc
    d = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[]];
    d.bundleIDs = @[@"systemsoundserverd"];   // 按 bundle ID 圈定，而非 object ID
    d.processRestoreEnabled = YES;            // 进程重启后系统自动恢复到 tap
    ```
    实测：输入 0.15338 × 30% = 输出 0.046014（与 `opk 0.04601` 精确吻合）。
18. **中文文本必须 per-run**：`Font.system` 自然回落会让中文字形重叠。见「五之三」。
19. **App 重启**：进程对象失效，需监听 `kAudioHardwarePropertyProcessObjectList` 变化并重建 tap；
    macOS 26+ 可用 `processRestoreEnabled` + `bundleIDs` 让系统自动恢复。

---

## 七、目录结构与构建

```
mac-sound-control/
├── README.md                  本文
├── Makefile                   统一构建入口
├── build-app.sh               打包成 build/PerAppVol.app（含签名）
├── src/
│   ├── engine/
│   │   └── perappvol.m        ★ 混音引擎（ObjC/C）
│   │                          tap / 聚合设备 / 渲染 / 限幅 / 设备热切换 /
│   │                          动态增删 / Unix socket 控制协议
│   ├── ui/
│   │   └── PerAppVolApp.swift ★ 菜单栏 UI（SwiftUI）
│   │                          只是控制器；AppKit NSSlider、命令合并、设置自愈
│   └── tools/
│       ├── apptap.m           链路 PoC / 调试：进程枚举 + tap 抓取 + 聚合设备 dump
│       └── volctl.swift       系统总音量 / 静音 / 切换默认输出设备（零权限）
├── docs/                      调研佐证（截图、对照图、日志）
└── build/                     构建产物（gitignore）
```

### 构建

```bash
make              # App + 全部工具
make app          # 只要菜单栏 App  ->  build/PerAppVol.app
make tools        # 只要命令行工具   ->  build/{perappvol,apptap,volctl}
make run          # 构建并启动
make clean
```

### 运行 App

```bash
open build/PerAppVol.app
# 首次运行：系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 打开 PerAppVol
```

### 引擎单独跑（不走 UI）

```bash
build/perappvol --list                                   # 可识别的 App（helper 已归并）
build/perappvol demo com.netease.163music 12             # 目标 App 音量 0→100→0 扫动（听觉验证）
build/perappvol run com.netease.163music=0.2 ALL=1.0 10  # 静态增益
build/perappvol serve com.netease.163music=0.2 ALL=1.0 --socket /tmp/ppv.sock
printf "set ALL 0.5\nstat\n" | nc -U /tmp/ppv.sock
```

### 调试工具

```bash
build/apptap procs                   # 谁在出声（OBJID / PID / OUT / IN / BUNDLE ID）
build/apptap tap ALL 5               # 全局 tap
APPTAP_MUTE=1  build/apptap tap ...  # 同时把它的声音从硬件劫走
APPTAP_DUMP=1  build/apptap tap ...  # 打印聚合设备构成

build/volctl get                     # 30%  [muted]
build/volctl set 50
build/volctl mute on|off|toggle
build/volctl devices                 # 列出输出设备 + 是否支持硬件音量
build/volctl setout 142              # 切换默认输出设备
build/volctl watch                   # 实时监听音量变化
```

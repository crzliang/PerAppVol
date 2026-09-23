# PerAppVol —— 源码

给 Mac 上的每个 App 单独调音量。用 CoreAudio Process Taps（macOS 14.2+）实现，无需虚拟音频驱动。

> 📖 **产品介绍、安装方式、FAQ** → [`crzliang/mac-sound-control`](https://github.com/crzliang/mac-sound-control)
> 🔧 **实现原理、实测数据、踩过的 25 个坑** → 该仓库的 `TECHNICAL.md`

## 构建

```bash
make              # App + 命令行工具
make app          # 只要菜单栏 App  → build/PerAppVol.app
make tools        # 只要命令行工具  → build/{perappvol,apptap,volctl}
make icon         # 重新生成图标
make dmg          # 打包 build/PerAppVol-arm64.dmg
make install      # 装到 /Applications 并启动
make autostart    # 开机自启（LaunchAgent）
make clean
```

架构显式钉死 **arm64**（无 x86 测试环境，不做未经验证的构建），最低系统 **macOS 14.2**。

## 目录结构

```
src/
  engine/perappvol.m          ★ 混音引擎（ObjC/C）
                              CoreAudio tap / 私有聚合设备 / 渲染 / 限幅 /
                              设备热切换 / 动态增删 / Unix socket 控制协议
  ui/PerAppVolApp.swift       ★ 菜单栏 UI（SwiftUI）
                              AppKit NSSlider、命令合并、设置持久化 + 自愈
  ui/Autostart.swift             开机自启（LaunchAgent）
  tools/apptap.m                 链路调试：进程枚举 + tap 抓取 + 聚合设备 dump
  tools/volctl.swift             系统总音量 / 静音 / 切换默认输出设备（零权限）
scripts/
  make-icon.swift                图标生成（含 README 页头用的 hero-icon）
  autostart.sh                   开机自启 on|off|status
.github/workflows/
  ci.yml                         每次 push/PR：构建验证 + DMG 结构校验
  release.yml                    推 v* 标签：签名 + 公证 + 发布 GitHub Release
build-app.sh                     打包 .app（含签名）
make-dmg.sh                      打包 DMG（含免开发者账号的安装脚本）
install.command                  DMG 里的安装脚本（本地自签证书 + 重签 + 清隔离标记）
Makefile                         统一构建入口
```

## 运行与调试

```bash
build/perappvol --list                       # 可识别的 App（helper 已归并）
build/perappvol serve "ALL=1.0" --socket /tmp/ppv.sock   # 单独跑引擎
printf "get\nstat\n" | nc -U /tmp/ppv.sock   # 查状态/电平

build/apptap procs                           # 谁在出声
build/volctl devices                         # 输出设备与硬件音量支持情况
```

控制协议（Unix socket）见文档仓库的 `TECHNICAL.md` 第三节。

## 发版

推 `v*` 标签即自动构建 + 签名 + 公证 + 发布到 GitHub Releases：

```bash
git tag v0.1.0
git push origin v0.1.0
```

只出 **arm64**。未配置签名 Secrets 时会产出未公证 DMG（仅供自测），配置方法见文档仓库 `TECHNICAL.md` 第九节。

## 许可

待定。

<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac，原生 macOS Xray-core 客户端，支持 VLESS、VMess、Trojan、Shadowsocks 和 Hysteria2" width="720"></p>

<h1 align="center">V2Mac</h1>

<p align="center"><b>原生 macOS Xray-core / V2Ray 客户端。</b><br>
VLESS、REALITY、VMess、Trojan、Shadowsocks、Hysteria2 和 WireGuard，集成在一个为 Apple Silicon 打造的快速 SwiftUI 菜单栏应用中。</p>

<p align="center">
  <a href="https://github.com/LordVersA/v2mac/releases/latest"><img src="https://img.shields.io/github/v/release/LordVersA/v2mac?label=release&color=0A84FF" alt="最新版本"></a>
  <a href="https://github.com/LordVersA/v2mac/releases"><img src="https://img.shields.io/github/downloads/LordVersA/v2mac/total?color=34C759" alt="下载量"></a>
  <a href="https://github.com/LordVersA/v2mac/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LordVersA/v2mac/ci.yml?branch=main&label=CI" alt="CI 状态"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26 或更高">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/LordVersA/v2mac?color=blue" alt="GPL-3.0 许可证"></a>
  <a href="https://github.com/LordVersA/v2mac/stargazers"><img src="https://img.shields.io/github/stars/LordVersA/v2mac?style=flat&color=FFCC00" alt="GitHub 星标"></a>
</p>

<p align="center"><a href="README.md">English</a> | <a href="README.fa.md">فارسی</a> | 简体中文 | <a href="README.ru.md">Русский</a></p>

<p align="center">
  <a href="#安装">安装</a> ·
  <a href="#功能">功能</a> ·
  <a href="https://github.com/LordVersA/v2mac/wiki/zh-Home"><b>文档</b></a> ·
  <a href="#从源码构建">构建</a>
</p>

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="V2Mac 主窗口：按延迟排序服务器、打开收藏并搜索" width="760"></p>

粘贴订阅链接、选择服务器，即可获得本地 SOCKS5 + HTTP 代理；或打开 TUN 模式让整台 Mac 走代理。V2Mac 是免费开源的 **macOS 版 v2rayN / V2RayX 替代品**，使用 SwiftUI 和 Liquid Glass 原生编写。无 Electron、无统计分析、无遥测。

## 安装

需要 **Apple Silicon** 上的 **macOS 26 或更高版本**。

```sh
brew install --cask lordversa/tap/v2mac
```

也可从[最新版本](https://github.com/LordVersA/v2mac/releases/latest)下载 DMG。应用未经公证：首次启动时在 系统设置 → 隐私与安全性 中点击 **仍要打开**。详见[安装指南](https://github.com/LordVersA/v2mac/wiki/zh-Installation)。

**快速开始：** 点击 **Add Subscription** 粘贴链接，双击服务器，然后使用 `127.0.0.1:10808`（SOCKS5 / HTTP），或打开 **System Proxy** 或 **TUN**。

## 功能

- **协议：** VLESS（REALITY、XTLS Vision）、VMess、Trojan、Shadowsocks、Hysteria2、WireGuard、SOCKS、HTTP 以及完整 Xray JSON 配置。
- **订阅：** 自动更新、流量与到期日、收藏、二维码和一键导入、完整的服务器编辑器。
- **连接：** 真实延迟和速度测试、自动选择服务器、无需重启的实时切换、菜单栏显示出口国家。
- **全局模式：** TUN、系统代理和基于 pf 的 Kill Switch。
- **路由：** Global、Bypass regions（伊朗、中国、俄罗斯）、Rules Only 和 Direct，以及按网站和应用的 Proxy / Direct / Block 规则。
- **Proxifier 替代品：** 按应用分流、导入 `.ppx` 配置、可视化 Rule Builder 和实时连接视图。
- **Cloudflare WARP：** 作为独立服务器或串接在你的服务器之后。
- **macOS 集成：** 菜单栏面板、快捷指令、Siri、Spotlight、控制中心、桌面小组件、Apple Intelligence 域名建议、Touch ID、通知、备份与恢复。支持英语、波斯语、中文和俄语。

## 截图

<p align="center"><img src="docs/images/screenshots/main.png" alt="V2Mac 主窗口：订阅分组、服务器延迟和速度、检查器和连接栏" width="760"></p>

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-editor-simple.png" alt="规则编辑器简单视图" width="380"><br><sub>按应用和网站分流</sub></td>
    <td align="center"><img src="docs/images/screenshots/connections.png" alt="连接窗口" width="380"><br><sub>每个连接及其规则</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Rule Builder 世界地图" width="380"><br><sub>Rule Builder</sub></td>
    <td align="center"><img src="docs/images/screenshots/proxifier-import.png" alt="导入 Proxifier 配置" width="380"><br><sub>导入 Proxifier</sub></td>
  </tr>
</table>

## 文档

**[V2Mac Wiki](https://github.com/LordVersA/v2mac/wiki/zh-Home)** 详细介绍了所有内容：

| | |
|---|---|
| [安装](https://github.com/LordVersA/v2mac/wiki/zh-Installation) | Homebrew、DMG、首次启动、更新 |
| [服务器与订阅](https://github.com/LordVersA/v2mac/wiki/zh-Servers-and-Subscriptions) | 添加、更新、编辑、延迟测试 |
| [连接](https://github.com/LordVersA/v2mac/wiki/zh-Connecting) | TUN、系统代理、Kill Switch、出口检测、WARP |
| [路由](https://github.com/LordVersA/v2mac/wiki/zh-Routing) | 模式、自定义规则、导入 Proxifier、Rule Builder |
| [连接列表](https://github.com/LordVersA/v2mac/wiki/zh-Connections) | 实时连接列表和地图 |
| [菜单栏与快捷方式](https://github.com/LordVersA/v2mac/wiki/zh-Menu-Bar-and-Shortcuts) | 面板、键盘、快捷指令、通知 |
| [设置参考](https://github.com/LordVersA/v2mac/wiki/zh-Settings-Reference) | 所有设置、备份、隐私 |
| [故障排除与常见问题](https://github.com/LordVersA/v2mac/wiki/zh-Troubleshooting-and-FAQ) | 常见问题与解答 |

如需在 Chrome 中防止泄漏，可搭配同一作者的免费扩展 [**noleaker**](https://github.com/LordVersA/noleaker)。

## 从源码构建

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

需要 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。设计文档：[docs/SPEC.md](docs/SPEC.md)。测试：`cd Packages/V2MacCore && swift test`。欢迎在 [Issues](https://github.com/LordVersA/v2mac/issues) 提交问题和 PR。

## 许可证

[GPL-3.0](LICENSE)。内置 [Xray-core](https://github.com/XTLS/Xray-core)（MPL-2.0）；见 [THIRD_PARTY.md](THIRD_PARTY.md)。

<p align="center"><sub>如果 V2Mac 对你有帮助，点个 ⭐ 能让更多人发现它。</sub></p>

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
  <a href="#截图">截图</a> ·
  <a href="docs/routing-rules.zh.md">路由规则</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="#从源码构建">构建</a>
</p>

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="V2Mac 主窗口：按延迟排序服务器、打开收藏并搜索" width="760"></p>

粘贴订阅链接，选择服务器，即可获得本地 SOCKS5 + HTTP 代理；也可以开启 TUN 模式，让整台 Mac 走代理。V2Mac 是免费开源的 **macOS 版 v2rayN / V2RayX 替代品**，使用 SwiftUI 和 Liquid Glass 原生开发。没有 Electron，没有统计，没有遥测。

## 安装

需要 **macOS 26 或更高版本**，**Apple Silicon**（M1 及更新）。

**Homebrew**（推荐，跳过 Gatekeeper 提示）：

```sh
brew install --cask lordversa/tap/v2mac
```

之后用 `brew upgrade --cask v2mac` 更新。

**手动下载：**

1. 从[最新版本](https://github.com/LordVersA/v2mac/releases/latest)下载 `V2Mac-<version>.dmg`，把 **V2Mac** 拖到 **应用程序**。
2. 应用未经公证，macOS 会阻止首次启动。先打开一次，然后在 **系统设置 → 隐私与安全性** 中点击 **仍要打开**，或运行：
   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```

**首次连接：**

1. 点击 **添加订阅**，粘贴你的链接（或 `vless://`、`vmess://`、`trojan://`、`ss://`、`hy2://` 链接）。
2. 双击服务器进行连接。
3. 将应用指向 `socks5://127.0.0.1:10808` 或 `http://127.0.0.1:10808`，或打开 **系统代理** 或 **TUN**。

关闭窗口代理仍会运行。按 ⌘Q 退出才会停止。

## 功能

### 协议与导入

| | |
|---|---|
| **协议** | VLESS（含 REALITY、XTLS Vision）、VMess、Trojan、Shadowsocks、Hysteria2、WireGuard、SOCKS、HTTP，以及完整的 Xray JSON 配置 |
| **订阅** | 自动更新；服务商提供时显示流量用量和到期日期 |
| **快速导入** | 在任意位置点击分享链接、服务商的 `v2mac://install-config?url=…` 按钮、粘贴二维码截图，或将配置文件和二维码图片拖到窗口 |
| **服务器编辑器** | 手动设置所有选项：传输方式、TLS 或 REALITY、Mux。编辑导入的服务器而不改动原始条目 |
| **收藏** | 给服务器加星；订阅更新不会未经询问就删除它们 |

### 连接

- **延迟测试：** 对整组同时进行真实延迟和 TCP ping，按速度排序，并可测下载速度。
- **自动选择服务器**（可选）：按真实 HTTP 延迟选择可用服务器，持续监测，卡住或变慢时按组内顺序切换。
- **TUN 模式：** 一个开关让所有应用和所有 DNS 查询走代理。无需付费开发者账号或系统扩展；`Scripts/check-tun.sh` 可检查有无泄漏。
- **系统代理：** 一个开关将 macOS 系统代理指向 V2Mac，状态圆点显示当前代理归属。
- **Kill switch**（可选）：连接期间除服务器和本地网络外全部阻断，连接断开时也一样，基于 macOS 防火墙（pf）。
- **Cloudflare WARP：** 注册免费 WARP 设备（MASQUE），使用 WARP+ 密钥，把 WARP 添加为服务器或串联在你自己的服务器之后。
- **稳定：** 崩溃、睡眠或网络变化后自动重启核心，启动时自动重连。
- **实时切换：** 选择其他服务器时在运行中的核心里直接替换，无需重启。

### 路由

- **模式：** 全局、仅规则（Rules Only）、直连，或 **绕过** 地区（伊朗、中国、俄罗斯），让本地网站直连。
- **自定义规则，类似 Proxifier：** 按网站和应用设置有序的代理 / 直连 / 阻止规则。可导入 Proxifier `.ppx` 配置、Clash 规则、hosts 文件、Adblock 列表以及 geosite 和 geoip 标签。
- **Rule Builder：** 在世界地图上选择国家，从列表中选择服务（Google、Telegram、OpenAI、Netflix、广告……）。
- **连接视图：** 所有连接按主机或应用分组，并显示决定其路由的规则。

→ 完整指南：**[自定义路由规则](docs/routing-rules.zh.md)**

### macOS 集成

- **菜单栏控制：** 连接、切换服务器、实时上下行速度、出口 IP 和国家。
- **控制中心、快捷指令、聚焦搜索和 Siri：** 连接、断开，切换 TUN、路由模式、系统代理或 kill switch。
- **特权助手：** Apple 签名版本使用只需批准一次的 `SMAppService` 助手；V2Mac 从不读取或保存你的管理员密码。
- **备份：** 将订阅、服务器、收藏和设置导出为 `.v2m` 文件，在另一台 Mac 上恢复。
- **其他：** 带密码的局域网共享、二维码、日志查看器、通知、登录时启动，以及一键更新应用和 Xray 核心。
- **语言：** 英语、波斯语（从右到左）、简体中文和俄语。
- **隐私：** 无统计、无遥测。密钥保存在加密的本地文件中，也可选择保存在钥匙串。

## 按应用分流：macOS 上的 Proxifier 替代品

V2Mac 逐个连接决定哪个应用、哪个网站**走代理**、**直连**或**被阻止**，就像 Proxifier 一样，但内置了 Xray 的协议，因此不再需要两个应用。

- **按应用和主机设置规则。** 应用可以写成 `Telegram.app`、Bundle ID（`com.example.chat`）、通配模式（`*code*`）、进程名（`curl`）或完整路径。主机支持域名、通配符（`*google*`）、IP 范围、geosite/geoip 标签、Clash 规则、hosts 文件和 Adblock 列表。同时包含两者的规则需要两者都匹配。
- **首个匹配生效。** 规则从上往下检查，拖动即可调整顺序。本地名称（`localhost`、`*.local`）和局域网始终直连。
- **简单编辑器。** 每个应用或主机一行，带 Proxy / Direct / Block 菜单，支持保存的分组、批量修改，以及 **Discovered** 收件箱：列出流量中新出现的应用和主机，一键即可设置路由。
- **导入 Proxifier 配置。** **Import…** 读取 `.ppx` 文件，添加前展示每条规则。使用 V2Mac 端口的规则变为 Proxy 规则，Direct 和 Block 规则保持不变，指向其他代理或代理链的规则会被跳过并列出。**Block QUIC (UDP 443)** 与 Proxifier 的同名选项相同，让浏览器回退到 TCP，使主机名能被规则匹配。
- **规则配置集。** 保存多套命名规则（家、公司、旅行），在工具栏中切换。

<p align="center"><img src="docs/images/screenshots/rule-editor-simple.png" alt="规则编辑器简单视图：Telegram、Discord、Xcode、Safari 等应用，各自走 Proxy 或 Direct" width="720"></p>

<p align="center"><img src="docs/images/screenshots/rule-editor-advanced.png" alt="规则编辑器高级视图：有序规则，带 Add Rule、Rule Builder 和 Import Proxifier Profile 按钮及 Block QUIC 开关" width="720"></p>

应用规则适用于使用系统代理或连接 V2Mac 端口的应用。在 TUN 模式下无法得知应用名称，因此改用主机和 IP 规则。详见 **[路由规则指南](docs/routing-rules.zh.md)**。

## 连接：查看每个请求的去向

**Connections** 窗口实时列出每个请求：发起的应用、目标主机和端口、已打开时长、发送和接收的字节数，以及路由它的**规则**（Proxy、Direct 或 Block，以及规则名称）。

- 按应用或按主机**分组**，查看哪些应用通信最多、连向哪里，或逐条显示每个连接。
- 按 All / Open 和路由**筛选**，并搜索应用和目标。
- **颜色标示原因：** 橙色表示应用自行设置使用代理端口，紫色表示流量回退到导入配置自身的路由。
- 底部的**事件日志**显示每个连接的打开和关闭。
- **Map** 视图在地球上显示请求和最活跃的应用。
- 右键单击连接可直接跳转到其背后的规则（或服务器配置），或为该应用或主机添加新规则。

<p align="center"><img src="docs/images/screenshots/connections.png" alt="Connections 窗口：Mail、Safari、curl 和 Music 的请求，含目标、时长、Proxy/Direct/Block 路由、规则名称和流量" width="720"></p>

## 截图

所有截图均使用虚构的演示服务器。

<p align="center"><img src="docs/images/screenshots/main.png" alt="V2Mac 主窗口：订阅分组、服务器延迟和速度、检查器和连接栏" width="760"></p>

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/add-subscription.png" alt="添加订阅对话框" width="380"><br><sub>添加订阅</sub></td>
    <td align="center"><img src="docs/images/screenshots/server-editor.png" alt="VLESS 服务器编辑器" width="380"><br><sub>编辑任意服务器</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Rule Builder 世界地图上已选择的国家" width="380"><br><sub>Rule Builder：在地图上选国家</sub></td>
    <td align="center"><img src="docs/images/screenshots/custom-rules.png" alt="设置中的自定义路由规则" width="380"><br><sub>自定义路由规则</sub></td>
  </tr>
</table>

<details>
<summary><b>更多截图</b></summary>

<p align="center"><img src="docs/images/screenshots/settings-tour.gif" alt="V2Mac 所有设置标签页的动画演示" width="560"></p>
<p align="center"><img src="docs/images/screenshots/connection-settings.png" alt="连接设置：自动选择服务器和 TUN 失败策略" width="560"></p>
<p align="center"><img src="docs/images/screenshots/routing-settings.png" alt="路由设置：绕过伊朗" width="560"></p>
<p align="center"><img src="docs/images/screenshots/sharing.png" alt="用于分享的服务器二维码" width="328"></p>

</details>

## Chrome 防泄漏：noleaker

仅靠代理无法阻止浏览器泄漏：WebRTC 可能暴露真实 IP，DNS 和 QUIC 可能绕过代理，时区和语言也会暴露你的位置。[**noleaker**](https://github.com/LordVersA/noleaker) 是同一作者的免费扩展，可与 V2Mac 配合用于 Chrome 和 Chromium 浏览器：强制流量和 DNS 走 V2Mac 的 SOCKS5 代理，阻止 WebRTC 和 QUIC 泄漏，使时区、语言和地理位置与服务器国家一致，代理断开时阻止请求。

设置：安装[最新版本](https://github.com/LordVersA/noleaker/releases/latest)，添加代理 `127.0.0.1:10808`，打开 **Protection**。V2Mac 的代理用户名和密码请留空。

## 常见问题

<details>
<summary><b>V2Mac 是 Mac 上的 V2Ray 客户端吗？</b></summary>

是的。V2Mac 运行 [Xray-core](https://github.com/XTLS/Xray-core)（V2Ray 核心持续开发的继任者），因此可以读取 V2Ray 和 Xray 的分享链接与订阅（VLESS、VMess、Trojan、Shadowsocks），以及 Hysteria2 和 WireGuard。
</details>

<details>
<summary><b>支持 VLESS REALITY 和 XTLS Vision 吗？</b></summary>

支持，分享链接和服务器编辑器都支持，传输方式包括 TCP、WebSocket、gRPC、HTTPUpgrade、XHTTP（SplitHTTP）和 mKCP。
</details>

<details>
<summary><b>如何让所有应用（包括没有代理设置的应用）走代理？</b></summary>

打开路由菜单旁的 **TUN** 开关，所有应用和 DNS 查询都会经过服务器。批准一次助手（Apple 签名版本），或每次会话输入一次管理员密码（ad-hoc 版本）。
</details>

<details>
<summary><b>支持 Intel Mac 或更旧的 macOS 吗？</b></summary>

不支持。V2Mac 需要 Apple Silicon 上的 macOS 26 或更高版本。
</details>

<details>
<summary><b>为什么 macOS 提示无法打开应用？</b></summary>

DMG 未经公证。请在隐私与安全性中使用 **仍要打开**、运行上面的 `xattr` 命令，或用 Homebrew 安装。
</details>

<details>
<summary><b>V2Mac 会收集数据吗？</b></summary>

不会。没有统计或遥测。除了你自己的流量，V2Mac 只会访问你的订阅地址、GitHub（用于更新和规则文件），以及连接后用于检查出口的公共 IP 服务。
</details>

## 从源码构建

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

需要 Xcode 26+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。设计文档见 [docs/SPEC.md](docs/SPEC.md)。包测试：`cd Packages/V2MacCore && swift test`。

欢迎在 [Issues](https://github.com/LordVersA/v2mac/issues) 提交问题和 pull request。

## 许可证

[GPL-3.0](LICENSE)。内置 [Xray-core](https://github.com/XTLS/Xray-core)（MPL-2.0）；见 [THIRD_PARTY.md](THIRD_PARTY.md)。

<p align="center"><sub>如果 V2Mac 对你有帮助，点个 ⭐ 能让更多人找到它。</sub></p>

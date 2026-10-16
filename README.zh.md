<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac：原生 macOS Xray-core 客户端，支持 VLESS、VMess、Trojan、Shadowsocks 和 Hysteria2" width="720"></p>

<p align="center"><a href="README.md">English</a> | <a href="README.fa.md">فارسی</a> | 简体中文 | <a href="README.ru.md">Русский</a></p>

# V2Mac

**[Xray-core](https://github.com/XTLS/Xray-core) 的原生 macOS 客户端。** 粘贴订阅链接，选择服务器，即可使用本地 SOCKS5 和 HTTP 代理。采用 SwiftUI 和 Liquid Glass 构建，专为 Apple Silicon Mac 设计。

## 功能

- **订阅：** 支持导入 VLESS、VMess、Trojan、Shadowsocks、Hysteria2、WireGuard、普通 SOCKS/HTTP 链接，以及完整的 Xray JSON 配置。支持自动更新；服务商提供相关信息时，可显示流量用量和到期时间。
- **手动添加和编辑服务器：** 手动填写 VLESS、VMess、Trojan、Shadowsocks、Hysteria2、WireGuard、SOCKS 或 HTTP 服务器的各项参数，包括传输方式、TLS 或 REALITY、Mux，也可以修改已导入的服务器。
- **收藏：** 将喜欢的服务器标记为收藏，并在同一个列表中查看。订阅更新时，删除收藏的服务器前会先征求确认。
- **延迟测试：** 批量测试整个分组的真实延迟（Real Delay）和 TCP Ping，并按速度排序。
- **可选的自动选择：** 默认关闭。根据真实 HTTP 响应延迟选择可用服务器，检查正在运行的代理，并在故障时按分组顺序切换到其他服务器。手动选择的服务器只要仍能响应，就会保持选中。还可选择在延迟持续过高或下载持续过慢（时长可设置）时自动切换。
- **路由：** 支持全局（Global）、直连（Direct）和绕过地区（Bypass regions，包含伊朗）模式，让指定地区的流量直连。
- **自定义路由规则：** 在任何路由模式之上添加你自己的有序 Proxy、Direct 和 Block 规则，可按网站和按应用匹配，与 Proxifier 一样（也能导入其配置文件）。可以粘贴域名、IP 段、geosite/geoip 标签、Clash 规则、hosts 文件或 Adblock 列表，也可以用 **Rule Builder** 在地图上选国家、从列表里选服务来生成规则。[详见下文](#自定义路由规则)。
- **TUN 模式：** 通过一个开关，将 Mac 上的所有流量转发到代理，包括没有代理设置的应用和所有 DNS 查询。无需付费开发者账号或系统扩展。`Scripts/check-tun.sh` 可检查是否有泄漏。
- **系统代理：** 在菜单栏或窗口中用一个开关，让 macOS 系统代理在连接期间指向 V2Mac。圆点显示系统代理是 V2Mac（绿色）、其他代理（红色）还是未设置（灰色）。
- **断网保护（Kill Switch）：** 可选，默认关闭。V2Mac 连接或重新连接期间，只能访问服务器、局域网和域名服务器，其他流量都会被拦截；即使连接断开或 V2Mac 意外退出也是如此，直到你断开连接。使用 macOS 防火墙（pf）。
- **Cloudflare WARP：** 在设置中通过 MASQUE 注册免费的 WARP 设备，输入 WARP+ 许可证密钥即可使用其套餐；可以把 WARP 添加为服务器，也可以让流量经过你自己的服务器后再从 WARP 出站，网站看到的是 Cloudflare 地址。
- **明确的 TUN 故障处理：** TUN 出现故障时，可选择继续运行本地代理或停止连接。状态显示会区分本地代理和已启用的系统隧道。
- **只需一次管理员授权：** TUN 模式、系统代理和断网保护每次启动共用一次管理员授权；把密码保存在钥匙串中后则不再询问。
- **菜单栏控制：** 连接、切换服务器、查看实时速度，以及复制本地代理地址。
- **可靠连接：** 核心崩溃、系统睡眠或网络变化后会重新启动核心，并在应用启动时重新连接。
- **快速导入：** 在任意位置点击 `vless://`、`vmess://`、`trojan://`、`ss://` 或 `hy2://` 链接，或服务商的“添加到应用”按钮（`v2mac://install-config?url=…`）；粘贴二维码截图，或将配置文件和二维码图片拖到窗口中。
- **控制中心、快捷指令和 Siri：** 提供用于控制中心和菜单栏的 V2Mac 开关；可在“快捷指令”、聚焦搜索和 Siri 中连接、断开，设置 TUN 模式、路由模式、系统代理或断网保护，也可以在那里为它们设置键盘快捷键。
- **备份：** 将订阅、服务器、收藏和设置导出为 `.v2m` 文件，并在另一台 Mac 上恢复。
- **语言：** 英语、波斯语（从右到左）、简体中文和俄语。
- **其他功能：** 菜单栏显示上传和下载速度、带密码（保存在钥匙串中）的局域网共享、二维码、日志查看器、登录时启动，以及一键更新应用和 Xray 核心。
- **隐私：** 不收集使用统计或遥测数据。

## 截图

截图来自当前 V2MacDev 构建，使用虚构的演示服务器。开发版代理使用端口 `10818`；安装版应用的默认端口为 `10808`。

**浏览服务器：** 按延迟排序、打开收藏夹，并搜索服务器。

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="按延迟排序服务器、打开收藏夹并搜索法兰克福的动画演示" width="720"></p>

<details>
<summary>更多截图：导入、编辑、二维码分享和设置</summary>

<p align="center"><img src="docs/images/screenshots/main.png" alt="V2Mac 主窗口：订阅分组、服务器延迟和速度、详情面板及连接栏" width="720"></p>

主窗口会显示每个订阅的流量用量和剩余天数，以及每台服务器的延迟和最高下载速度。选择服务器即可查看详情，并复制分享链接或二维码。底部栏显示连接状态、TUN 开关、路由模式和本地代理地址。

**设置导览：** 通用、代理、路由、连接、服务器、通知、核心和关于。

<p align="center"><img src="docs/images/screenshots/settings-tour.gif" alt="V2Mac 全部八个设置标签页的动画导览" width="560"></p>

自动选择服务器默认关闭。连接设置说明了真实 HTTP 响应检查，并可选择 TUN 失败时的处理方式。

<p align="center"><img src="docs/images/screenshots/connection-settings.png" alt="连接设置：自动选择服务器关闭，TUN 失败时保持本地代理运行" width="560"></p>

**添加订阅：** 输入订阅地址和可选名称。

<p align="center"><img src="docs/images/screenshots/add-subscription.png" alt="添加订阅对话框，包含地址、可选名称和通过代理获取的选项" width="460"></p>

**编辑服务器副本：** 保存到自定义配置，不更改订阅中的原始条目。

<p align="center"><img src="docs/images/screenshots/server-editor.png" alt="演示 VLESS 服务器编辑器，包含地址、端口、用户 ID、流控和传输方式" width="520"></p>

**分享服务器：** 使用详情面板中的二维码。

<p align="center"><img src="docs/images/screenshots/sharing.png" alt="演示服务器详情面板，完整显示二维码分享弹出窗口" width="328"></p>

**通用设置：** 启动、重新连接、睡眠或网络变化后的恢复、更新和诊断。

<p align="center"><img src="docs/images/screenshots/settings.png" alt="通用设置，包含启动、连接恢复、更新和诊断" width="560"></p>

**代理设置：** 配置本地端口，以及带身份验证的可选局域网访问。

<p align="center"><img src="docs/images/screenshots/proxy-settings.png" alt="代理设置，显示开发版端口且局域网访问关闭" width="560"></p>

**路由设置：** 选择路由模式，管理绕过代理的地区，并编辑[自定义规则](#自定义路由规则)。

<p align="center"><img src="docs/images/screenshots/routing-settings.png" alt="路由设置，显示全局模式和伊朗绕过代理地区" width="560"></p>

</details>

## 安装

需要搭载 Apple Silicon 的 Mac，运行 macOS 26 或更高版本。

1. 从 [Releases](../../releases) 下载 `V2Mac-<version>.dmg`，将 **V2Mac** 拖入 **Applications（应用程序）** 文件夹。
2. 应用尚未通过 Apple 公证，因此 macOS 会阻止首次启动。先尝试打开一次，然后前往 **系统设置 → 隐私与安全性**，点击 **仍要打开**。也可以运行：

   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```

3. 点击 **Add Subscription**，粘贴订阅链接，双击服务器即可连接。
4. 将应用的代理地址设置为 `socks5://127.0.0.1:10808` 或 `http://127.0.0.1:10808`。

如果希望整个 Mac 使用代理，请打开路由菜单旁的 **TUN** 开关。每次打开 V2Mac 后，macOS 会在首次启用 TUN 时要求输入一次管理员密码；不会安装任何组件。

关闭窗口后，代理仍会继续运行。使用 ⌘Q 退出应用即可停止代理。

## 自定义路由规则

路由模式决定大部分流量怎么走，自定义规则决定例外：哪些网站、国家或地址始终**走代理**、始终**直连**，或被**拦截**。它们在所有模式下都生效，也能和绕过地区一起使用。例如：绕过伊朗，但仍让某个伊朗网站走代理；或者无论用哪种模式都拦截广告。

打开 **Settings → Routing → Custom rules**。这里是一个规则列表，每条规则有名称、开关、动作（Proxy、Direct 或 Block）、适用的应用和匹配的主机。点击 **Add Rule** 或 **Edit…**，拖动规则调整顺序，然后点击 **Apply**；如果已连接，连接会重启以使用新规则。同时写了应用和主机的规则需两者都匹配；留空表示全部。

从 Proxifier 迁移？**Import Proxifier Profile…** 可读取 `.ppx` 文件。指向 V2Mac 端口的规则变为 Proxy 规则，Direct 和 Block 规则保持不变，指向其他代理或代理链的规则会被跳过并列出。**Block QUIC (UDP 443)** 与 Proxifier 的同名选项作用相同：浏览器改用 TCP，主机名就能交给规则处理。

应用可以写成 `Spotify.app`、`com.spotify.client`、`*discord*`、进程名（`curl`）或完整路径。应用规则适用于使用系统代理的应用；在 TUN 模式下，所有应用都经隧道到达 V2Mac，应用规则暂时无法区分它们。

**关闭系统代理时**，手动设置为使用 V2Mac 代理端口的应用会跳过自定义规则和地区规则，直接使用服务器。连接窗口以橙色的**应用的代理设置**标签标记这些连接，并且不会将它们添加到规则编辑器的新发现条目中。本地流量仍然直连，启用的 QUIC 阻断仍然生效；Direct 模式仍然只检查 Block 规则，其余流量直连。**开启系统代理时**，该端口的所有流量都遵循规则，因为手动代理和系统代理使用同一个端口。完整 JSON 配置也遵循这一策略。

在**连接**窗口中，选择**按主机分组**或**按应用分组**，即可像规则编辑器一样展开和折叠分组。分组显示连接数、活动连接数和总流量；展开后可查看每条连接及其路由标签。搜索和 All/Open 筛选在分组前生效。所有模式都保留相同的可排序表格和单行布局，分组默认折叠。选择**不分组**可单独查看每条连接。

<p align="center"><img src="docs/images/screenshots/custom-rules.png" alt="路由设置中的自定义规则部分，Proxy 列表包含 Telegram、AI 服务、一条 Clash 规则和一个通配符域名" width="560"></p>

**规则的检查顺序**

1. 首先检查已启用的 QUIC 阻断，然后本地名称（`localhost`、`*.local`、`*.test` 等）和局域网地址直连。
2. 上述应用代理例外，然后从上到下检查你的规则。
3. 然后才是路由模式本身：绕过地区的规则包，其余走代理（Direct 模式下则直连）。

先匹配到的规则生效，所以即使某个网站所在的国家被绕过，只要它在 Proxy 规则里，就仍然走代理；放在宽泛 Proxy 规则上方的 Direct 规则会优先生效。在 **Direct** 模式下只使用 Block 规则，因为此时不应有任何流量进入代理。完整的 Xray JSON 配置先使用 V2Mac 的规则和路由模式，再将导入的路由作为回退；也可以为这些配置选择路由模式。连接窗口以紫色的**配置回退路由**标记回退流量，手动代理流量保持橙色。IP 规则在检查时解析域名，防止后面的全匹配规则抢先生效。

**可以写什么**

规则的主机支持大多数教程、规则集和 Proxifier 使用的格式。逗号、空格和 `;` 也能分隔条目，以 `#`、`//` 或 `!` 开头的行是注释。

| 写法 | 匹配 |
|---|---|
| `example.com`、`*.example.com`、`+.example.com`、`.ir` | 该域名及其所有子域名（`.ir` 表示所有 `.ir` 网站） |
| `full:www.example.com` | 仅这个完整域名 |
| `keyword:shop`、`*shop*` | 包含该关键词的任何域名 |
| `regexp:^ads\d+\.` | 匹配正则表达式的域名 |
| `1.2.3.4`、`10.0.0.0/8`、`2001:db8::/32`、`10.0.0.1-10.0.0.9` | 单个地址或地址段，IPv4 或 IPv6 |
| `geosite:google`、`geosite:category-ads-all` | 核心 `geosite.dat` 中的站点列表（1500 多个） |
| `geoip:de`、`geoip:telegram` | `geoip.dat` 中某个国家或服务的地址 |
| `ext:region-ir-geosite.dat:ir` | 已下载地区规则包中的列表 |
| `DOMAIN-SUFFIX,example.com,DIRECT` | Clash 规则：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`DOMAIN-REGEX`、`IP-CIDR`、`IP-CIDR6`、`GEOIP`、`GEOSITE`（动作由规则决定，而不是 policy 列） |
| `0.0.0.0 ads.example.com` | hosts 文件中的行 |
| `\|\|ads.example.com^` | Adblock 域名规则 |

不是规则的内容会被跳过，并在编辑框下方列出，所以输错也不会导致无法连接。

### Rule Builder

不想手写规则？点击规则下方的 **Rule Builder…**，它会分三步帮你生成规则。

**1. 动作（Action）。** 选择要怎么处理：Proxy、Direct 或 Block。也可以从常用方案开始，例如让本国流量直连、拦截广告和跟踪器，或让 AI 服务、Telegram、流媒体走代理。

<p align="center"><img src="docs/images/screenshots/rule-builder-action.png" alt="Rule Builder 第一步：Proxy、Direct、Block 三张卡片和常用方案列表" width="720"></p>

**2. 选择（Choose）。** 在三个标签页中选择要匹配的内容。标签页和底部的数字显示目前已选数量。

- **国家（Countries）：** 按名称或代码搜索全部 250 个国家和地区，或直接在地图上点击某个国家来添加或移除。选中的国家会在地图上显示国旗。每个国家可以选择添加：IP 段（`geoip:ir`）、国家顶级域名（`domain:ir`，即所有 `.ir` 网站），以及规则文件中该国在其他域名上的已知网站列表（`geosite:category-ir`）。

<p align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Rule Builder 国家步骤：左侧是可搜索的国家列表，右侧是标有德国、伊朗和日本国旗的世界地图" width="720"></p>

- **服务（Services）：** 一键选择 Google、YouTube、Telegram、Instagram、WhatsApp、X、Netflix、Spotify、OpenAI、Anthropic、Apple、Microsoft、广告和跟踪器等。右侧可以搜索核心规则文件中的所有列表。这些列表直接从文件读取，因此 Rule Builder 不会为核心中不存在的列表生成规则。

<p align="center"><img src="docs/images/screenshots/rule-builder-services.png" alt="Rule Builder 服务步骤：常用服务卡片和可搜索的全部 geosite、geoip 列表" width="720"></p>

- **域名和 IP（Domains & IPs）：** 输入或粘贴上述任意格式，输入时即时检查，旁边附有格式说明。

<p align="center"><img src="docs/images/screenshots/rule-builder-domains.png" alt="Rule Builder 域名步骤：文本编辑框、实时计数和格式说明" width="720"></p>

**3. 确认（Review）。** 查看将要写入的每个条目及其类型。相同动作的规则中已有的条目会被标出，不会重复添加。点击 **Add Rules**，它们会保存为一条以日期命名的新规则：Block 规则放在列表顶部，其他放在底部。之后可以在设置中重命名、修改或移动它。

<p align="center"><img src="docs/images/screenshots/rule-builder-review.png" alt="Rule Builder 确认步骤，列出 Direct 列表的十三条规则" width="720"></p>

**示例**

| 目标 | 列表 | 规则 |
|---|---|---|
| 在所有模式下拦截广告 | Block | `geosite:category-ads-all` |
| 即使绕过伊朗，AI 服务也走代理 | Proxy | `geosite:openai`、`geosite:anthropic`、`geosite:category-ai-!cn` |
| Apple 和 Microsoft 更新不走代理 | Direct | `geosite:apple`、`geosite:microsoft` |
| 直连公司内网 | Direct | `10.0.0.0/8`、`full:intranet.example.com` |
| 使用下载的 Clash 规则列表 | 任意 | 直接粘贴 `payload:` 中的行 |

如果规则引用了文件中不存在的列表（例如 `geosite:nonexistent`），核心将无法启动，日志会指出是哪一条。Rule Builder 只提供实际存在的列表。

## Chrome 防泄漏：noleaker

仅使用代理无法阻止浏览器泄露信息：WebRTC 可能暴露真实 IP，DNS 和 QUIC 可能绕过代理，时区和语言也可能透露所在地区。对于 Chrome 和其他基于 Chromium 的浏览器，可以使用 [**noleaker**](https://github.com/LordVersA/noleaker)。这是同一作者开发的免费开源扩展，可与 V2Mac 配合使用：

- 将所有浏览器流量和 DNS 查询通过 V2Mac 的 SOCKS5 代理发送，并阻止 WebRTC 和 QUIC 泄漏。
- 根据服务器所在国家或地区调整时区、语言和地理位置。
- 断网保护（Kill Switch）：代理断开时阻止请求，避免请求改为直连。
- 内置泄漏测试，逐项检查并说明需要调整哪些设置。
- 兼容模式允许托管在伊朗的网站绕过代理。

配置方法：从 [最新版本](https://github.com/LordVersA/noleaker/releases/latest) 安装 noleaker，添加主机为 `127.0.0.1`、端口为 `10808` 的代理，并开启 **Protection**。noleaker 无法发送代理用户名或密码，因此请在 V2Mac 设置中将这两项留空。已在 Chrome 120 及更新版本上测试。

## 从源码构建

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

需要 Xcode 26 或更高版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。设计规范见 [docs/SPEC.md](docs/SPEC.md)（英文）。

## 许可证

GPL-3.0。详见 [LICENSE](LICENSE) 和 [THIRD_PARTY.md](THIRD_PARTY.md)。

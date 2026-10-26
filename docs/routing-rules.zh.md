# V2Mac: 路由规则

路由模式决定大部分流量如何处理。规则决定例外情况：哪些应用、网站、国家或地址**走代理**、**经由**另一台服务器、**直连**或被**阻止**。规则在所有模式下都有效，并与 Bypass regions 并存。例如，你可以绕过伊朗，但仍让某个伊朗网站走代理；或者在任何模式下都拦截广告。

### 规则窗口

可以从侧边栏底部的玻璃按钮、**Settings → Routing** 中的 **Open Rules…**、**Connections** 中的连接或菜单栏打开 **Rules**。左侧列表从上往下检查，第一条匹配的规则决定流量去向：

1. **Before your rules：** 本地网络（本机、局域网和 `printer.local` 等名称始终直连）、**Block QUIC**（开关），以及使用代理端口的应用（在 Settings → Proxy 中设置）。
2. **My rules**，按你的顺序。拖动可重新排序；每条都有开关。
3. **After your rules：** 路由模式自己的规则，然后是 **Everything else**（跟随模式、Proxy、Direct 或 Block）。

所有修改都是草稿：修改过的规则带有圆点，⌘Z 可撤销，**Apply**（⌘S）保存并让正在运行的连接重启一次。窗口有未应用的修改时，关闭前会先询问。

### 一条规则

- **Send to：** **Proxy**（当前连接的服务器）、**Via** 某台服务器或某个分组（分组中响应最快的服务器）、**Direct** 或 **Block**。
- **Matches any of：** 应用、域名、精确名称、关键字、地址和范围、国家及服务列表。在同一个输入框中输入并从建议中选择（已安装的应用、带条目数的服务、国家），一次粘贴多行，或点击 **Browse…** 使用应用清单、服务卡片和世界地图。右键点击网站可将其改为精确名称、关键字或正则表达式。点击应用可查看它在此 Mac 上匹配什么。
- **Only when**（可选）：端口（`443`、`8000-8100`）、TCP 或 UDP、协议（TLS、HTTP、QUIC、BitTorrent）和应用。每一项还必须满足这些条件。例如，含 `*.example.com` 且“Only when: Safari”的规则只匹配 Safari 访问该网站的流量。

只有“Only when”而没有条目的规则会匹配所有此类流量：“UDP、BitTorrent → Direct”会让种子流量直连。

**New Rule ▾** 可从模板开始：AI 服务、开发者工具、Apple 服务、社交和聊天、流媒体、地区网站直连、种子直连、广告和跟踪器。

### 经由另一台服务器（Via）

**Via** 让规则的流量经由与当前连接不同的服务器，例如让 AI 网站走另一个国家的服务器。选择一台服务器，或选择一个分组以使用其中响应最快的服务器（每 30 秒检查一次，失败时由下一台接替）。

当它的服务器都没有响应时，规则的流量默认会**失败**，绝不会走其他路径。开启 **If its servers fail, use the current server** 则改用当前服务器。规则会显示有多少台服务器响应，全部无响应时菜单栏会发出警告。

### 流量去哪儿？

在搜索框中输入网站、链接、地址或应用名称。列表上方会显示它的去向和原因，例如“api.github.com → Proxy，由 Developer（#8），匹配 geosite:github”，依据的是你当前的规则，无论是否已应用。

**Discovered** 列出在 Rules 或 Connections 窗口打开期间看到、且没有任何规则覆盖的应用和网站。用 **Add to** 添加到规则、拖到规则上，或选择 **Ignore**。网站会以整个域名的形式建议（`api.github.com` 建议为 `github.com`）。

**Tidy Up…**（⋯ 菜单中）会建议合并作用相同的规则、删除已被前面规则覆盖的规则，以及删除重复条目。勾选你需要的项；在 Apply 之前不会有任何改变。

在 **Connections** 中右键点击某行，可使用 **Add App to Rule**、**Add Host to Rule** 和 **Show Rule**。菜单栏面板会显示前台应用、它的去向以及 **Add to Rule**。快捷指令中有 **Add to Rule** 操作。

### 导入和配置

**Import…**（⋯ 菜单）可读取 Proxifier `.ppx` 配置、Clash / Mihomo、Shadowrocket / Surge、sing-box 和 Xray / v2rayN 规则，以及 V2Mac 导出的文件。在确认之前不会添加任何内容。

- 指向 V2Mac 端口的 Proxifier 规则变为 **Proxy** 规则；**Direct** 和 **Block** 保持不变；使用其他代理或代理链的规则会被跳过并列出。
- Proxifier 的端口，以及 Clash 和 sing-box 的端口、网络和协议条件，会变为 **Only when**。
- Proxifier 的 **Block UDP 443** 会开启 **Block QUIC**。
- 导入的规则排在你的规则之后，你的规则保持优先。

**Export** 导出全部或所选规则。**配置菜单**可保存多套命名规则，例如家里和公司。

V2Mac 1.1 的规则会在首次启动时迁移，效果与之前相同：1.1 中同时包含应用和主机的规则，会变为这些主机并加上“Only when”这些应用。

### 应用

应用可以写成 `Spotify.app`、`com.spotify.client`、`*discord*`、进程名（`curl`）或完整路径。应用规则适用于使用系统代理或连接 V2Mac 代理端口的应用。在 TUN 模式下，内核无法看出连接来自哪个应用，因此应用条目只匹配使用代理端口的应用；网站和地址条目仍然有效。

**关闭系统代理时**，设置为使用 V2Mac 代理端口的应用会跳过规则，直接使用服务器（Settings → Proxy）。Connections 以橙色的 **App's proxy setting** 标记这些连接。**开启系统代理时**，经该端口的所有流量都遵循规则。

第一条匹配的规则生效，因此即使某网站所在国家被绕过，Proxy 规则中的该网站仍走代理。**Direct** 模式只使用 Block 规则。完整的 Xray JSON 配置会先使用 V2Mac 的规则和模式，再以其自身路由作为兜底；Connections 以紫色的 **Config fallback** 标记这类流量。

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

无法识别的内容会显示为红色标记并被忽略，所以输错也不会导致无法连接。

**示例**

| 目标 | 发送到 | 条目 |
|---|---|---|
| 在所有模式下拦截广告 | Block | `geosite:category-ads-all` |
| 即使绕过伊朗，AI 服务也走代理 | Proxy | `geosite:openai`、`geosite:anthropic`、`geosite:category-ai-!cn` |
| Apple 和 Microsoft 更新不走代理 | Direct | `geosite:apple`、`geosite:microsoft` |
| 直连公司内网 | Direct | `10.0.0.0/8`、`full:intranet.example.com` |
| 使用下载的 Clash 规则列表 | 任意 | 直接粘贴 `payload:` 中的行 |

如果规则引用了文件中不存在的列表（例如 `geosite:nonexistent`），核心将无法启动，日志会指出是哪一条。规则窗口只提供实际存在的列表。


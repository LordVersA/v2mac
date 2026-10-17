# V2Mac: 自定义路由规则

路由模式决定大部分流量怎么走，自定义规则决定例外：哪些网站、国家或地址始终**走代理**、始终**直连**，或被**拦截**。它们在所有模式下都生效，也能和绕过地区一起使用。例如：绕过伊朗，但仍让某个伊朗网站走代理；或者无论用哪种模式都拦截广告。

打开 **Settings → Routing → Custom rules**。这里是一个规则列表，每条规则有名称、开关、动作（Proxy、Direct 或 Block）、适用的应用和匹配的主机。点击 **Add Rule** 或 **Edit…**，拖动规则调整顺序，然后点击 **Apply**；如果已连接，连接会重启以使用新规则。同时写了应用和主机的规则需两者都匹配；留空表示全部。

从 Proxifier 迁移？**Import Proxifier Profile…** 可读取 `.ppx` 文件。指向 V2Mac 端口的规则变为 Proxy 规则，Direct 和 Block 规则保持不变，指向其他代理或代理链的规则会被跳过并列出。**Block QUIC (UDP 443)** 与 Proxifier 的同名选项作用相同：浏览器改用 TCP，主机名就能交给规则处理。

应用可以写成 `Spotify.app`、`com.spotify.client`、`*discord*`、进程名（`curl`）或完整路径。应用规则适用于使用系统代理的应用；在 TUN 模式下，所有应用都经隧道到达 V2Mac，应用规则暂时无法区分它们。

**关闭系统代理时**，手动设置为使用 V2Mac 代理端口的应用会跳过自定义规则和地区规则，直接使用服务器。连接窗口以橙色的**应用的代理设置**标签标记这些连接，并且不会将它们添加到规则编辑器的新发现条目中。本地流量仍然直连，启用的 QUIC 阻断仍然生效；Direct 模式仍然只检查 Block 规则，其余流量直连。**开启系统代理时**，该端口的所有流量都遵循规则，因为手动代理和系统代理使用同一个端口。完整 JSON 配置也遵循这一策略。

在**连接**窗口中，选择**按主机分组**或**按应用分组**，即可像规则编辑器一样展开和折叠分组。分组显示连接数、活动连接数和总流量；展开后可查看每条连接及其路由标签。搜索、All/Open 和 All/Proxy/Direct/Block 路由筛选在分组前生效。所有模式都保留相同的可排序表格和单行布局，分组默认折叠。选择**不分组**可单独查看每条连接。

<p align="center"><img src="images/screenshots/custom-rules.png" alt="路由设置中的自定义规则部分，Proxy 列表包含 Telegram、AI 服务、一条 Clash 规则和一个通配符域名" width="560"></p>

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

<p align="center"><img src="images/screenshots/rule-builder-action.png" alt="Rule Builder 第一步：Proxy、Direct、Block 三张卡片和常用方案列表" width="720"></p>

**2. 选择（Choose）。** 在三个标签页中选择要匹配的内容。标签页和底部的数字显示目前已选数量。

- **国家（Countries）：** 按名称或代码搜索全部 250 个国家和地区，或直接在地图上点击某个国家来添加或移除。选中的国家会在地图上显示国旗。每个国家可以选择添加：IP 段（`geoip:ir`）、国家顶级域名（`domain:ir`，即所有 `.ir` 网站），以及规则文件中该国在其他域名上的已知网站列表（`geosite:category-ir`）。

<p align="center"><img src="images/screenshots/rule-builder-countries.png" alt="Rule Builder 国家步骤：左侧是可搜索的国家列表，右侧是标有德国、伊朗和日本国旗的世界地图" width="720"></p>

- **服务（Services）：** 一键选择 Google、YouTube、Telegram、Instagram、WhatsApp、X、Netflix、Spotify、OpenAI、Anthropic、Apple、Microsoft、广告和跟踪器等。右侧可以搜索核心规则文件中的所有列表。这些列表直接从文件读取，因此 Rule Builder 不会为核心中不存在的列表生成规则。

<p align="center"><img src="images/screenshots/rule-builder-services.png" alt="Rule Builder 服务步骤：常用服务卡片和可搜索的全部 geosite、geoip 列表" width="720"></p>

- **域名和 IP（Domains & IPs）：** 输入或粘贴上述任意格式，输入时即时检查，旁边附有格式说明。

<p align="center"><img src="images/screenshots/rule-builder-domains.png" alt="Rule Builder 域名步骤：文本编辑框、实时计数和格式说明" width="720"></p>

**3. 确认（Review）。** 查看将要写入的每个条目及其类型。相同动作的规则中已有的条目会被标出，不会重复添加。点击 **Add Rules**，它们会保存为一条以日期命名的新规则：Block 规则放在列表顶部，其他放在底部。之后可以在设置中重命名、修改或移动它。

<p align="center"><img src="images/screenshots/rule-builder-review.png" alt="Rule Builder 确认步骤，列出 Direct 列表的十三条规则" width="720"></p>

**示例**

| 目标 | 列表 | 规则 |
|---|---|---|
| 在所有模式下拦截广告 | Block | `geosite:category-ads-all` |
| 即使绕过伊朗，AI 服务也走代理 | Proxy | `geosite:openai`、`geosite:anthropic`、`geosite:category-ai-!cn` |
| Apple 和 Microsoft 更新不走代理 | Direct | `geosite:apple`、`geosite:microsoft` |
| 直连公司内网 | Direct | `10.0.0.0/8`、`full:intranet.example.com` |
| 使用下载的 Clash 规则列表 | 任意 | 直接粘贴 `payload:` 中的行 |

如果规则引用了文件中不存在的列表（例如 `geosite:nonexistent`），核心将无法启动，日志会指出是哪一条。Rule Builder 只提供实际存在的列表。


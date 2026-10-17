# V2Mac: 自定义路由规则

路由模式决定大部分流量怎么走，自定义规则决定例外：哪些网站、国家或地址始终**走代理**、始终**直连**，或被**拦截**。它们在所有模式下都生效，也能和绕过地区一起使用。例如：绕过伊朗，但仍让某个伊朗网站走代理；或者无论用哪种模式都拦截广告。

### 规则编辑器

点击侧边栏底部的玻璃按钮，或在 **Settings → Routing** 中点击 **Open Rule Editor…**，即可打开 **Rule Editor**。顶部可在两个视图间切换，右侧是规则配置集菜单（可保存多套命名规则，如家和公司，并随时切换）。

**Simple** 适合日常使用。**Apps** 和 **Hosts** 列出规则所路由的每个应用或网站，每行一个，带 Proxy / Direct / Block 菜单，标签显示它属于哪条规则。相关应用（多个 Xcode 或 VS Code 辅助进程）会合并为可展开的一组。**Discovered** 收集流量中出现但尚无规则覆盖的应用和主机，一键即可设置路由。可多选批量修改、按路由筛选，并用 **Add…** 选择已安装应用或输入域名。修改会自动保存并生效。

<p align="center"><img src="images/screenshots/rule-editor-simple.png" alt="规则编辑器简单视图：Telegram、Discord、Spotify、curl 等应用，各带规则标签和 Proxy 菜单" width="720"></p>

**Advanced** 显示完整的有序列表。每条规则有开关、动作、应用和主机。**Add Rule** 或 **Edit…** 打开规则，拖动调整顺序，**Apply** 保存（运行中的连接会重启）。这里还可以打开 **Rule Builder** 和 **Import Proxifier Profile…**，以及开启 **Block QUIC (UDP 443)**。地址范围和同时包含应用与主机的规则在这里编辑。

<p align="center"><img src="images/screenshots/rule-editor-advanced.png" alt="规则编辑器高级视图：八条有序规则，带 Add Rule、Rule Builder、Import Proxifier Profile 按钮和 Block QUIC 开关" width="720"></p>

同时包含应用和主机的规则需两者都匹配；空字段匹配一切。规则在所有模式下都生效：在 **Rules Only** 模式下只有 Proxy 规则会走服务器，**Settings → Routing → Traffic that matches no rule** 决定其余流量去向（跟随模式、Proxy、Direct 或 Block）。

### 从 Proxifier 导入

从 Proxifier 迁移？在 Simple 视图点击 **Import…**（或 Advanced 中的 **Import Proxifier Profile…**），选择 `.ppx` 文件。确认前不会添加任何内容：预览会列出每条规则的应用、主机和动作。

<p align="center"><img src="images/screenshots/proxifier-import.png" alt="导入 Proxifier 配置预览：五条待添加规则、一条因使用其他代理而跳过的规则，以及将开启 Block QUIC" width="720"></p>

- 发往本机代理（V2Mac 端口）的规则变为 **Proxy** 规则。
- **Direct** 和 **Block** 规则保持不变；已禁用的规则导入后仍为禁用。
- 使用其他代理或代理链的规则会被跳过，并以橙色列出名称。
- Proxifier 的 **Block UDP 443** 选项会开启 **Block QUIC**。
- 导入的规则排在现有规则之后，你自己的规则保持优先。

### 应用

应用可以写成 `Spotify.app`、`com.spotify.client`、`*discord*`、进程名（`curl`）或完整路径。应用规则适用于使用系统代理或直接连接 V2Mac 代理端口的应用。TUN 连接会跳过应用规则，因为转发进程无法得知应用身份；主机/IP 规则和默认路由仍然生效。导入的 JSON 配置中的进程规则同样如此。

**关闭系统代理时**，手动设置为使用 V2Mac 代理端口的应用会跳过自定义规则和地区规则，直接使用服务器。连接窗口以橙色的 **App's proxy setting** 标记这些连接，且不会将其加入 Discovered。本地流量仍然直连，Block QUIC 仍然生效，Direct 模式仍只使用 Block 规则后将其余流量直连。**开启系统代理时**，经该端口的所有流量都遵循规则，因为手动代理和系统代理共用同一端口。完整 JSON 配置也遵循此策略。

在 **Connections** 中，每行显示路由它的规则，右键可跳转到该规则。**By Host** 和 **By Application** 可像规则编辑器一样把流量折叠为可展开的分组。

<p align="center"><img src="images/screenshots/routing-settings.png" alt="路由设置：Rules Only 模式、未匹配规则的流量直连、Bypass regions 和 Open Rule Editor" width="560"></p>

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

不想手写规则？点击规则编辑器 Advanced 视图中的 **Rule Builder…**，它会分三步帮你生成规则。

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

<p align="center"><img src="images/screenshots/rule-builder-review.png" alt="Rule Builder 确认步骤，列出新 Direct 规则的九个条目，三个已存在的条目显示为灰色" width="720"></p>

**示例**

| 目标 | 列表 | 规则 |
|---|---|---|
| 在所有模式下拦截广告 | Block | `geosite:category-ads-all` |
| 即使绕过伊朗，AI 服务也走代理 | Proxy | `geosite:openai`、`geosite:anthropic`、`geosite:category-ai-!cn` |
| Apple 和 Microsoft 更新不走代理 | Direct | `geosite:apple`、`geosite:microsoft` |
| 直连公司内网 | Direct | `10.0.0.0/8`、`full:intranet.example.com` |
| 使用下载的 Clash 规则列表 | 任意 | 直接粘贴 `payload:` 中的行 |

如果规则引用了文件中不存在的列表（例如 `geosite:nonexistent`），核心将无法启动，日志会指出是哪一条。Rule Builder 只提供实际存在的列表。


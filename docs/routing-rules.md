# V2Mac: Custom routing rules

The routing mode decides what happens to most traffic. Custom rules decide the exceptions: which sites, countries or addresses always go **through the proxy**, always go **direct**, or are **blocked**. They work in every mode and next to Bypass regions, so you can, for example, bypass Iran but still send one Iranian site through the proxy, or block ads whichever mode you use.

### The Rule Editor

Open the **Rule Editor** from the glass button at the foot of the sidebar, or with **Open Rule Editor…** in **Settings → Routing**. It has two views, switched at the top, and a rule profile menu on the right (keep several named rule sets, such as home and work, and switch between them).

**Simple** is for everyday use. **Apps** and **Hosts** list everything your rules route, one row per app or site, each with a Proxy / Direct / Block menu; a tag shows which rule it belongs to. Related apps (several Xcode or VS Code helpers) are folded into one group that you can expand. **Discovered** collects apps and hosts seen in your traffic that no rule covers yet, so you can route them with one click. Select several rows to change them together, filter by route, and use **Add…** to pick installed apps or type domains. Changes save and apply on their own.

<p align="center"><img src="images/screenshots/rule-editor-simple.png" alt="Rule Editor, Simple view: apps such as Telegram, Discord, Spotify and curl, each with its rule tag and a Proxy menu" width="720"></p>

**Advanced** shows the whole ordered list. Each rule has a switch, an action, its apps and its hosts. **Add Rule** or **Edit…** opens a rule, drag to reorder, and **Apply** saves (a running connection restarts). From here you also open the **Rule Builder** and **Import Proxifier Profile…**, and turn on **Block QUIC (UDP 443)**. Address ranges and rules that combine apps and hosts are edited here.

<p align="center"><img src="images/screenshots/rule-editor-advanced.png" alt="Rule Editor, Advanced view: eight ordered rules with Add Rule, Rule Builder and Import Proxifier Profile buttons and the Block QUIC switch" width="720"></p>

A rule with both apps and hosts needs both to match; an empty field matches everything. Rules work in every mode: in **Rules Only** mode only Proxy rules reach the server, and **Settings → Routing → Traffic that matches no rule** decides where everything else goes (follow the mode, Proxy, Direct or Block).

### Import from Proxifier

Coming from Proxifier? Click **Import…** in the Simple view (or **Import Proxifier Profile…** in Advanced) and pick your `.ppx` file. Nothing is added until you confirm: the review lists every rule with its apps, hosts and action.

<p align="center"><img src="images/screenshots/proxifier-import.png" alt="Import Proxifier profile review: five rules to add, one skipped rule that uses another proxy, and Block QUIC to be enabled" width="720"></p>

- Rules that send to a proxy on this Mac (V2Mac's port) become **Proxy** rules.
- **Direct** and **Block** rules stay as they are; disabled rules come in disabled.
- Rules that use another proxy or a chain are skipped and named in orange.
- Proxifier's **Block UDP 443** option turns on **Block QUIC**.
- Imported rules go after your existing ones, so your own rules keep priority.

### Apps

Apps can be written as `Spotify.app`, `com.spotify.client`, `*discord*`, a process name (`curl`) or a full path. App rules work for apps that use the system proxy or connect directly to V2Mac's proxy port. TUN connections skip app rules because the forwarder loses app identity; host/IP rules and the default route still apply. This also applies to process rules in imported JSON configs.

With **System Proxy off**, apps pointed at V2Mac's proxy port skip custom and region rules and use the server. Connections marks these in orange as **App's proxy setting** and leaves them out of newly discovered rule-editor entries. Local traffic stays direct, Block QUIC still applies, and Direct mode still uses only Block rules before sending everything else direct. With **System Proxy on**, all traffic through that port follows the rules, since manual and system proxy connections share the same port. Full JSON configs follow this policy too.

In **Connections**, every row shows the rule that routed it, and a right-click jumps to that rule. **By Host** and **By Application** fold traffic into expandable groups like the rule editor.

<p align="center"><img src="images/screenshots/routing-settings.png" alt="Routing settings: mode Rules Only, traffic that matches no rule goes Direct, Bypass regions and Open Rule Editor" width="560"></p>

**How rules are checked**

1. Block QUIC, when enabled; then local names (`localhost`, `*.local`, `*.test`, …) and local network addresses go direct.
2. The app proxy exception described above, then your rules from the top down.
3. Then the routing mode itself: the Bypass region packs, then everything else to the proxy (or direct in Direct mode).

The first match wins, so a site in a Proxy rule goes through the proxy even when its country is bypassed, and a Direct rule above a broad Proxy rule wins over it. In **Direct** mode only Block rules are used, since nothing there should reach the proxy. Full Xray JSON configs use V2Mac's rules and mode first, then their imported routing as fallback. The mode picker works for them too. Connections marks imported fallback traffic in purple as **Config fallback**; manually proxied traffic stays orange. IP rules resolve names when reached, so a later catch-all cannot preempt them.

**What you can write**

A rule's hosts take the formats most guides, rule sets and Proxifier use. Commas, spaces and `;` also separate entries, and lines starting with `#`, `//` or `!` are comments.

| Write | Matches |
|---|---|
| `example.com`, `*.example.com`, `+.example.com`, `.ir` | the domain and all its subdomains (`.ir` covers every `.ir` site) |
| `full:www.example.com` | only that exact name |
| `keyword:shop`, `*shop*` | any name containing the word |
| `regexp:^ads\d+\.` | names matching a regular expression |
| `1.2.3.4`, `10.0.0.0/8`, `2001:db8::/32`, `10.0.0.1-10.0.0.9` | an address or a range, IPv4 or IPv6 |
| `geosite:google`, `geosite:category-ads-all` | a site list from the core's `geosite.dat` (1,500+ lists) |
| `geoip:de`, `geoip:telegram` | a country's or service's addresses from `geoip.dat` |
| `ext:region-ir-geosite.dat:ir` | a list from a downloaded region pack |
| `DOMAIN-SUFFIX,example.com,DIRECT` | Clash rules: `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-REGEX`, `IP-CIDR`, `IP-CIDR6`, `GEOIP`, `GEOSITE` (the rule's action decides, not the policy column) |
| `0.0.0.0 ads.example.com` | lines from a hosts file |
| `\|\|ads.example.com^` | Adblock domain lines |

Anything that is not a rule is skipped and named under the editor, so a typo never stops the connection.

### Rule Builder

Rather not type rules? Click **Rule Builder…** in the Advanced view of the Rule Editor. It writes them for you in three steps.

**1. Action.** Choose what should happen: Proxy, Direct or Block. Or start from a common setup, such as keeping your own country direct, blocking ads and trackers, or sending AI services, Telegram or streaming through the proxy.

<p align="center"><img src="images/screenshots/rule-builder-action.png" alt="Rule Builder first step with Proxy, Direct and Block cards and a list of common setups" width="720"></p>

**2. Choose.** Pick what to match from three tabs. The counts in the tabs and the footer show how much you have picked so far.

- **Countries:** search all 250 countries by name or code, or click a country on the map to add or remove it. Each picked country gets a flag on the map. For each country you choose what to add: its IP ranges (`geoip:ir`), its domain ending (`domain:ir`, every `.ir` site), and its list of known sites on other domains (`geosite:category-ir`) where the rule files have one.

<p align="center"><img src="images/screenshots/rule-builder-countries.png" alt="Rule Builder country step: searchable country list on the left, a world map with flags on Germany, Iran and Japan on the right" width="720"></p>

- **Services:** one click for Google, YouTube, Telegram, Instagram, WhatsApp, X, Netflix, Spotify, OpenAI, Anthropic, Apple, Microsoft, ads and trackers, and more. On the right you can search every list in the core's rule files. The lists come from the files themselves, so the builder never writes a rule for a list the core does not have.

<p align="center"><img src="images/screenshots/rule-builder-services.png" alt="Rule Builder services step with popular service tiles and a searchable list of every geosite and geoip list" width="720"></p>

- **Domains & IPs:** type or paste anything in the formats above. It is checked as you type, and a guide to the formats sits beside it.

<p align="center"><img src="images/screenshots/rule-builder-domains.png" alt="Rule Builder domains step with a text editor, a live count and a guide to accepted formats" width="720"></p>

**3. Review.** See every entry that will be written and what kind it is. Entries your rules with the same action already have are marked and not added twice. Click **Add Rules** to save them as one new rule named after the date: a Block rule goes to the top of the list, the others to the bottom. You can rename, edit or move it later in Settings.

<p align="center"><img src="images/screenshots/rule-builder-review.png" alt="Rule Builder review step listing nine entries for a new Direct rule, with three already in the list greyed out" width="720"></p>

**Examples**

| Goal | List | Rules |
|---|---|---|
| Block ads everywhere | Block | `geosite:category-ads-all` |
| Use AI services through the proxy, even with Iran bypassed | Proxy | `geosite:openai`, `geosite:anthropic`, `geosite:category-ai-!cn` |
| Keep Apple and Microsoft updates off the proxy | Direct | `geosite:apple`, `geosite:microsoft` |
| Reach your office network directly | Direct | `10.0.0.0/8`, `full:intranet.example.com` |
| Use a downloaded Clash rule list | any | paste the `payload:` lines as they are |

A rule naming a list the files do not contain, say `geosite:nonexistent`, stops the core from starting; the log says which one. The Rule Builder only offers lists that exist.


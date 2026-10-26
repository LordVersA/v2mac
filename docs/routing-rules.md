# V2Mac: Routing rules

The routing mode decides what happens to most traffic. Rules decide the exceptions: which apps, sites, countries or addresses go **through the proxy**, **via** another server, **direct**, or are **blocked**. They work in every mode and next to Bypass regions, so you can, for example, bypass Iran but still send one Iranian site through the proxy, or block ads whichever mode you use.

### The Rules window

Open **Rules** from the glass button at the foot of the sidebar, with **Open Rules…** in **Settings → Routing**, from a connection in **Connections**, or from the menu bar. The list on the left is checked from the top, and the first rule that matches decides where the traffic goes:

1. **Before your rules:** Local network (this Mac, the LAN and names such as `printer.local` always go direct), **Block QUIC** (a switch), and Apps using the proxy port (set in Settings → Proxy).
2. **My rules**, in your order. Drag to reorder; each has a switch.
3. **After your rules:** the routing mode's own rules, then **Everything else** (follow the mode, Proxy, Direct or Block).

Every change is a draft: the changed rules get a dot, ⌘Z undoes, and **Apply** (⌘S) saves and restarts a running connection once. Closing the window with changes asks first.

### A rule

- **Send to:** **Proxy** (the server you are connected to), **Via** a server or a group (the group's fastest server that answers), **Direct** or **Block**.
- **Matches any of:** apps, domains, exact names, keywords, addresses and ranges, countries and service lists. Type in the one field and pick from the suggestions (installed apps, services with their sizes, countries), paste many lines at once, or click **Browse…** for an app checklist, service tiles and the world map. Right-click a site to read it as an exact name, a keyword or a regular expression. Click an app to see what it matches on this Mac.
- **Only when** (optional): ports (`443`, `8000-8100`), TCP or UDP, the protocol (TLS, HTTP, QUIC, BitTorrent) and apps. Every item must also meet these. For example, a rule with `*.example.com` and "Only when: Safari" matches only Safari's traffic to that site.

A rule with only "Only when" and no items matches all such traffic: "UDP, BitTorrent → Direct" sends torrents direct.

**New Rule ▾** starts from a template: AI services, developer tools, Apple services, social and chat, streaming, region sites direct, torrents direct, ads and trackers.

### Via another server

**Via** sends a rule's traffic through a different server than the one you are connected to, for example AI sites through a server in another country. Pick a server, or a group to use its fastest server that answers (checked every 30 seconds, and the next one takes over when it fails).

When none of its servers answers, the rule's traffic **fails** by default, so it never leaves another way. Turn on **If its servers fail, use the current server** to fall back instead. The rule shows how many servers answer, and the menu bar warns when none does.

### Where does it go?

Type a site, a link, an address or an app name in the search field. Above the list V2Mac answers where it goes and why, such as "api.github.com → Proxy, by Developer (#8), matched geosite:github", working from your rules as they are now, applied or not.

**Discovered** lists apps and sites seen while the Rules or Connections window is open that no rule covers. Add one to a rule with **Add to**, drag it onto a rule, or **Ignore** it. A site is offered as its whole domain (`github.com` for `api.github.com`).

**Tidy Up…** (in the ⋯ menu) suggests merging rules that do the same thing, dropping rules an earlier one already covers, and removing repeated entries. Pick the ones you want; nothing changes until you Apply.

In **Connections**, right-click a row for **Add App to Rule**, **Add Host to Rule** and **Show Rule**. The menu bar panel shows the app in front, where it goes and **Add to Rule**. Shortcuts has an **Add to Rule** action.

### Import and profiles

**Import…** (⋯ menu) reads Proxifier `.ppx` profiles, Clash / Mihomo, Shadowrocket / Surge, sing-box and Xray / v2rayN rules, and files exported by V2Mac. Nothing is added until you confirm in the review.

- Proxifier rules to V2Mac's port become **Proxy** rules; **Direct** and **Block** stay; rules to other proxies or chains are skipped and named.
- Proxifier's ports, and Clash and sing-box port, network and protocol conditions, become **Only when**.
- Proxifier's **Block UDP 443** turns on **Block QUIC**.
- Imported rules go after yours, so your rules keep priority.

**Export** writes all or the selected rules. The **profile menu** keeps several named rule sets, such as home and work.

Rules from V2Mac 1.1 are moved over on first launch and do the same as before: a 1.1 rule with apps and hosts becomes the hosts with "Only when" those apps.

### Apps

Apps can be written as `Spotify.app`, `com.spotify.client`, `*discord*`, a process name (`curl`) or a full path. App rules work for apps that use the system proxy or connect to V2Mac's proxy port. In TUN mode the core cannot see which app a connection comes from, so app items match only apps that use the proxy port; site and address items still apply.

With **System Proxy off**, apps pointed at V2Mac's proxy port skip the rules and use the server (Settings → Proxy). Connections marks these in orange as **App's proxy setting**. With **System Proxy on**, all traffic through that port follows the rules.

The first match wins, so a site in a Proxy rule goes through the proxy even when its country is bypassed. In **Direct** mode only Block rules are used. Full Xray JSON configs use V2Mac's rules and mode first, then their own routing as fallback; Connections marks that traffic in purple as **Config fallback**.

**What you can write**

A rule's items take the formats most guides, rule sets and Proxifier use. Commas, spaces and `;` also separate entries, and lines starting with `#`, `//` or `!` are comments.

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

Anything that is not understood shows as a red token and is left out, so a typo never stops the connection.

**Examples**

| Goal | Send to | Items |
|---|---|---|
| Block ads everywhere | Block | `geosite:category-ads-all` |
| Use AI services through the proxy, even with Iran bypassed | Proxy | `geosite:openai`, `geosite:anthropic`, `geosite:category-ai-!cn` |
| Keep Apple and Microsoft updates off the proxy | Direct | `geosite:apple`, `geosite:microsoft` |
| Reach your office network directly | Direct | `10.0.0.0/8`, `full:intranet.example.com` |
| Use a downloaded Clash rule list | any | paste the `payload:` lines as they are |

A rule naming a list the files do not contain, say `geosite:nonexistent`, stops the core from starting; the log says which one. The Rules window only offers lists that exist.


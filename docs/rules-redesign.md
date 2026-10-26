# Rules redesign (workspace Phase 12)

**Goal:** one Rules window that is easy for a first-time user and complete for a Proxifier or Clash user.
It replaces the Rule Builder, the Rule Editor (Simple and Advanced) and the custom rules list in
Settings → Routing. It ships in one release.

## Today
- Three places edit the same `CustomRule` list (about 2,600 lines of UI): Settings → Routing (the raw
  list), the Rule Editor window (`rule-editor`: Simple library with six hidden fixed rules that
  `SimpleRules.move` rewrites, Advanced list, profiles), and the Rule Builder window (`rule-builder`:
  action → countries / services / domains → review, one "Rule Builder, <date>" rule). Spec 8.6.
- A rule has two text fields, `apps` and `hosts`, and needs both to match when both are filled (AND).
  Ports, network and sniffed protocol cannot be expressed; import skips such rules; Block QUIC is a
  one-off switch.
- Only one proxy outbound exists (`ConfigBuilder.proxyTag`), so every Proxy rule exits through the
  connected server.
- A real list (the developer's, 28 rules) shows the cost: every service is split into an "App - X" and a
  "Host - X" rule to get OR; each app is listed 4–6 ways (`"ChatGPT.app"`, `ChatGPT`, bundle id,
  `*chatgpt*`, …) because nothing shows what matches; local network appears in three rules although
  local names already go direct; nothing uses AND.

## Decisions
| Topic | Decision |
|---|---|
| Scope | One Rules window. Settings → Routing keeps only mode-level switches (apps using the proxy port, region packs) and an "Open Rules…" button. The Rule Builder and Rule Editor windows and their code go. |
| Rule | Name, on/off, action, items, optional "Only when". Ordered, first match wins, as today. |
| Items (OR) | App, domain (`domain:`/`full:`/wildcards), keyword, regex, IP/CIDR/range, country, service (geosite/geoip list). Any item matching fires the rule. Entry forms are the ones `RuleMatchers` and `AppMatchers` read today. |
| Only when (AND) | Port or range, network TCP/UDP, sniffed protocol (BitTorrent, QUIC, TLS, HTTP), apps. Applied to every item of the rule. |
| Compiling | One rule becomes adjacent Xray rules with the same outbound (one for apps, one for domains, one for IPs), each carrying the Only-when fields, so first-match order holds. IP handling and `domainStrategy` as in 8.6 today. |
| Actions | Proxy (connected server), **Via** a server or a group, Direct, Block. |
| Via server | Its own outbound tag per target. Any server: a JSON config contributes its first proxy outbound plus the outbounds its `dialerProxy` chain needs, its routing is ignored. |
| Via group | An Xray balancer over the group's servers with observatory, so the core picks the fastest working one and fails over by itself. |
| Via failure | Fail closed: the rule's traffic fails, never leaks to Direct or another exit. The rule shows a warning badge in the window and the menu bar shows a warning. Per rule opt-in: "Fall back to current server" (balancer `fallbackTag`). |
| Modes | Via rules work in Global, Bypass and Rules only (like Proxy rules). Direct mode stays Block rules only. |
| App token | Stores the bundle id (or a path for CLI tools picked from running processes or Discovered). Matches the app's folder, so helpers inside match, plus its executable name. Its popover lists the processes it matched on this Mac and connections seen; widening to a keyword is an explicit checkbox. TUN warning badge on app tokens while app rules cannot see apps in TUN (Track A). |
| Built-ins | Shown in the list in evaluation order: Local network (locked), Block QUIC (switch), Apps using the proxy port (locked), my rules, the mode's rules (locked), and last "Everything else → [Follow mode ▾]" (today's `unmatchedRoute`). |
| Storage | New key `rules` (and `ruleProfilesV2`/`activeRuleProfile` alike), versioned JSON. `customRuleList` and `ruleProfiles` are left untouched, so a downgrade to 1.1.x gets the pre-upgrade rules back. Backups write v2 and read old backups through the same migration. |
| Migration | Exact: one old rule → one new rule, routing unchanged. An old rule with apps and hosts keeps its hosts as items and its apps under Only when. Old `blockQUIC` maps to the built-in switch. |
| Tidy Up | A review sheet of suggestions, each with a checkbox: merge "App - X" with "Host - X" (same action, neighbours or no rule between them that could match), drop entries the built-ins cover, collapse one app's many spellings into one token, drop exact duplicates. Nothing changes without approval. |
| Saving | Edits form a draft with ⌘Z undo; a bar "N changes · Revert · Apply (⌘S)" applies with one core restart. Closing with pending changes asks. Changed rules get a dot. |
| Templates | "New rule ▾": Empty, or AI services, Developer tools, Apple services, Social & chat, Streaming, region sites direct (from the chosen region pack), Torrents direct, Ads & trackers block. A template fills an ordinary rule from the geo files (`GeoTags`, so only lists the core has) and installed apps; it is not linked afterwards. |
| Profiles, files | Toolbar: profile menu (switch, New, Duplicate, Rename, Delete) and a ⋯ menu with Import (all of today's formats, now also port, network and logic-free AND rules) and Export (V2Mac JSON, selected rules or all). Via targets export by server name; a missing one shows as unresolved after import. |

## The window (`rules`)
- **Sidebar:** search field, All/Proxy/Via/Direct/Block filter, then the list in evaluation order
  (built-ins, My rules with drag to reorder, mode rules, Everything else), then Discovered (N).
  Each rule row: drag handle, action colour, name, Via target, item count, switch, change dot,
  warning badge.
- **Detail:** name, action menu (Proxy · Via ▸ groups, servers · Direct · Block), switch; the smart
  field; items as tokens grouped by kind (Apps, Domains, IPs, Countries, Services); "Only when"
  collapsed.
- **Smart field:** typing shows grouped suggestions: installed apps with icons, services (geosite and
  geoip lists with entry counts), countries (local and English name, code), and the text itself as
  domain, keyword, regex or IP with its detected kind (changeable on the token). ↑↓ Return. Pasting
  many lines parses all of them with `RuleMatchers`/`RuleImport` and names the skipped ones. Apple
  Intelligence "Suggest domains for …" stays as a row when available. **Browse** opens the visual
  pickers: app checklist, service tiles, country map (today's Rule Builder panes, reused).
- **Search:** filters rules by name and by item, highlighting matching tokens. When the text is a host,
  URL, IP or app, a top row answers where it goes: "api.github.com → Proxy, by Developer services
  (#8), matched `*github*`", evaluated with real order, built-ins, geo list contents and the mode's
  default; a click selects the rule.
- **Discovered:** apps and hosts no rule covers, with traffic and last seen. Each row: "Add to ▾"
  (rules, most recently used first; New rule…; Ignore); multi-select and drag onto a rule. A host
  offers its registered domain (`EntryGroups`). Recording stays tied to the window being open
  (`ConnectionWatcher`).

## Other entry points
- Main sidebar glass button and Settings → Routing open the window; `focusedRule` keeps working.
- Connections window: right-click a connection → Add to rule ▸ / New rule… / Show rule.
- Menu bar: "Frontmost app: <name> → <where it goes> ▸" with the same Add to rule menu.
- App Intent "Add to rule" (app or domain, rule name), beside the connect intents.

## R0 results (2026-10-27, Xray 26.10.21)
- **(a) Balancer.** `leastPing` with `observatory` (probe `https://www.gstatic.com/generate_204`, 5 s in the
  spike) moved traffic from a stopped server to the working one within one probe. An outbound with its own
  `sockopt.dialerProxy` chain is probed end to end (dead when its hop is down). A Hysteria 2 outbound is
  accepted as a balancer and observatory subject. **When every member is dead, the core logs "balancing
  strategy returns empty tag" and sends the traffic to the config's *default (first) outbound*, which is a
  leak.** So the compiler always sets `fallbackTag`: `block` (fail closed) or the proxy tag (the opt-in).
  With it the core logs "fallback to [block], due to empty tag returned". `subjectSelector` and `selector`
  match by tag *prefix*: each group's tags get a prefix no other outbound starts with (`via-g<n>-`).
  Status: the metrics endpoint the app already polls (`/debug/vars`) carries `observatory`, keyed by tag,
  with `alive`, `delay` and `last_error_reason`. R6 reads that; single Via servers join the observatory too.
- **(b) Geo search.** `geosite.dat` (2.3 MB): 1,549 lists, 112,644 entries, 13 ms to parse in full,
  15 MB resident, and 47 ms for a naive substring scan over every entry. Contents are searched (the tester
  needs them anyway), indexed once off the main actor, and searched with a short debounce.
- **(c) Order.** With `IPIfNonMatch`, an earlier IP rule is skipped in the first pass and a later domain
  rule wins (`ip 0.0.0.0/0, port 80 → r1` above `domain:example.com → r2`: http://example.com went to r2).
  With `IPOnDemand` it went to r1. So whenever a user rule has IP items, `domainStrategy` must be
  `IPOnDemand` (today's rule, kept), and a rule compiled into adjacent app/domain/IP Xray rules keeps
  first-match order.

## Tasks
| # | Task |
|---|---|
| R0 | **Spike.** (a) Balancer + observatory over outbounds that carry their own `dialerProxy` chain (WARP, imported JSON) and over Hysteria 2; `fallbackTag`; what the core reports when all fail. (b) Smart-field search over every geosite list's names and contents: time and memory to index on this Mac; decide whether contents are searched or only names. (c) That adjacent compiled rules keep first-match order with `IPOnDemand`/`IPIfNonMatch`. Write results here. |
| R1 | Package: `Rule` v2 model (items, only-when, action with Via), migration from `CustomRule` (exact), compile to Xray rules, `RuleTester` (where does X go) as a pure function. Package tests: migration of the developer-shaped list (anonymised), OR/AND compile, tester against built-ins and modes. |
| R2 | Package: Via outbounds and balancers in `ConfigBuilder` (one outbound per target, JSON first-outbound with its dialer chain, fail-closed, fallback opt-in), across Global, Bypass, Rules only, TUN and full configs; kill switch gets every Via server's IPs. Tests. |
| R3 | Package: Tidy Up suggestions (pure function), import of port/network rules, v2 export/import, backup read/write. Tests. |
| R4 | App: Rules window: sidebar, detail, tokens, draft/undo/Apply, built-ins, profiles, templates. |
| R5 | App: smart field, Browse pickers (move the Rule Builder panes), app token popover, search with tester row, Discovered with Add to and drag. |
| R6 | App: Via status (balancer/observatory state → badges, menu bar warning). |
| R7 | App: entry points: Connections menu, menu bar frontmost app, App Intent; Settings → Routing trimmed; delete Rule Builder, Rule Editor and the Settings list code. |
| R8 | Docs: spec 8.6 rewritten (and 12.x for the window and menu bar), `docs/routing-rules*.md` ×4, wiki `Routing.md` ×4, README ×4 if it names the old windows; String Catalogs ×3 (Localizable, AppShortcuts). |
| R9 | Check with the dev build (never the installed app): migrate a copy of the real list and compare generated configs before/after (identical routing); Tidy Up on it; a Via group with one server stopped fails over, all stopped fails closed; tester answers match the access log for 10 hosts and 3 apps; downgrade to 1.1.0 build reads the old list. |

**Done when:** R9 passes, the old windows are gone, and a released V2Mac has the Rules window.

# Replacing Proxifier

V2Mac can fully replace Proxifier for the user's profile (`updated v7.1.ppx`) in five
phases. Phases 1–3 are enough in system proxy mode; Phase 4 removes the need for Proxifier.

## Goal

Proxifier sends traffic to V2Mac's SOCKS port (127.0.0.1:10808) using 25 rules, applied top
to bottom with the first match winning:

- **9 app rules:** Claude, CapCut, AI apps, developer tools, Notion/Figma,
  Discord/Telegram/Zoom, Spotify, Ledger, X, Apple system services.
- **15 host rules:** keyword wildcards (`*google*`, `*openai*`), plain domains, single IPs and
  IP ranges (`17.0.0.0-17.255.255.255`).
- **Direct rules:** loopback, LAN, docker hosts, Sourena Games.
- **Options:** block UDP 443 (QUIC), resolve DNS through the proxy, and a list of local names
  that skip the proxy.
- **Default:** proxy.

Proxifier catches every app's connections, including apps that ignore the system proxy, and
knows which app opened each one. V2Mac must do both.

## Status (2026-10-17)

Phases 1, 2, 3 and 5 are done (spec 8.6). Phase 4 is not started: it needs TUN mode
tested while the installed V2Mac is not in use.

## What works today

These parts need no code changes:

- **Default to proxy:** Global routing mode.
- **Loopback and LAN go direct:** built in through `geoip:private`.
- **Plain domains and single IPs:** Custom rules, Proxy and Direct lists (spec 8.6).
- **Keyword rules:** possible if written as `keyword:google` instead of `*google*`.
- **Chrome by host:** with the system proxy on, Chrome sends each connection's host name to
  V2Mac, and the rules decide connection by connection. YouTube (`keyword:googlevideo`,
  `keyword:ytimg`) goes through the proxy and other sites go direct, without pushing all of
  Chrome through the proxy. Rules see host names only, not URL paths, the same as Proxifier.
- **"Direct - Proxy Engines" rule:** not needed, because Xray doesn't loop its own traffic
  back through itself.

Checked on 2026-10-16: the bundled Xray v26.10.10 accepts `process` rules on macOS. A rule
sending `curl` to Block stopped curl through the SOCKS port, and a rule naming another app let
it through.

## Phase 1: rule format (small)

Make the v7.1 host rules work as written (`CustomRules.swift`).

- [x] Turn `*word*` into `keyword:word`. Keep `*.domain` as `domain:` like today.
- [x] Turn IP ranges `a-b` (v4 and v6) into the smallest set of CIDR blocks.
- [x] Add a "Block QUIC (UDP 443)" setting: one Xray rule, `network: udp, port: 443` → block.
      It needs a `Prefs` key, a default, a settings row and the fa/zh-Hans/ru strings.
- [x] Always send local names (`*.local`, `*.test`, `localhost`, docker hosts) direct.
- [x] Package tests for every new form.

**Done when:** the v7.1 host rules can be pasted into the lists with nothing skipped.

## Phase 2: app rules in system proxy mode (medium)

- [x] Add an app list to the Proxy, Direct and Block lists. Each entry becomes an Xray
      `process` rule.
- [x] Accept Proxifier's forms: `"Spotify.app"`, `Spotify`, `com.spotify.client`, `*discord*`
      and full paths.
- [x] Turn a bundle id into the app's binary name through Launch Services, because Xray
      matches process names or paths, not bundle ids.
- [x] Decide how `*word*` app patterns map onto Xray's process matching. It takes no
      wildcards (exact name, exact path, or a folder prefix ending in `/`), so they are
      expanded against the installed and running apps at connect time.
- [x] Tests for the conversion.
- [ ] Run a manual check with the dev build (system proxy off, apps pointed at the dev port).

**Done when:** in system proxy mode, every app that respects the system proxy follows its
app rule.

## Phase 3: one ordered rule list (medium)

Today V2Mac applies Block, then Proxy, then Direct. Proxifier goes top to bottom and the first
match wins, and v7.1 depends on it (for example, "Direct - Local Network" comes before the
broad Proxy rules).

- [x] One ordered list of rules. Each rule has a name, apps and/or hosts, an action and an
      on/off switch.
- [x] Turn the list into Xray rules in the same order.
- [x] Move the existing three lists into the new list once (Block, Proxy, Direct order), so
      nothing changes for current users.
- [x] Update the Rule Builder to add rules to the ordered list (since replaced by the Rules window, Phase 12).

**Done when:** the order of v7.1 can be reproduced exactly.

## Phase 4: TUN mode that knows the app (large)

In TUN mode every app's traffic is captured, but it reaches the core through the root
forwarder, so the core sees the forwarder (`xray`) as the app. App rules stop working.

- [ ] First, find out whether the forwarder's own Xray sees the real app for traffic that
      arrives from the TUN interface. Phase 4 depends on the answer.
- [ ] If it does: the forwarder checks only the app rules and sends each connection to one of
      three core ports (proxy, direct, block). The core handles each port with its own rules.
      Only app names reach the root process, never server configs (spec 9.5).
- [ ] If it doesn't: look up the app by the connection's source port in the root helper,
      or accept that app rules work only in system proxy mode.
- [ ] Turn on the QUIC block from Phase 1 in TUN mode by default, so Chrome's UDP traffic
      follows the host rules.
- [ ] Update spec 9.5 and 8.6.

**Done when:** with TUN on and Proxifier quit, every v7.1 rule behaves as before, including
apps that ignore the system proxy (command-line tools, Docker, Apple background services).

## Phase 5: import a `.ppx` file (small, optional)

- [x] Read Proxifier's XML: `RuleList`, `Targets`, `Applications`, `Action`, `enabled`,
      `BlockUDP443`, `ExclusionList`.
- [x] Rules that point at other proxies or chains are skipped and listed.
- [x] Test with a made-up profile in `Fixtures.swift` (no real hosts or IPs).

## Risks and open questions

- **Phase 4 is unproven.** Process matching was tested only on connections made through the
  proxy, not on traffic from the TUN interface.
- **Apps that ignore the system proxy** stay outside V2Mac until Phase 4 is done.
- **DNS through the proxy:** V2Mac uses its own resolver (spec 8.4) instead of Proxifier's
  per-host choice. Check that no name leaks to the local resolver in TUN mode.
- **System settings:** TUN mode and the system proxy change settings for the whole Mac. Test
  in the dev build only when the installed V2Mac isn't in use.

# Optional system fail-closed protection

This is a design for a future, separately enabled system kill switch. The current
"If TUN fails → Stop connection" setting stops V2Mac's local core; it cannot keep
other applications from using direct routes after a TUN disappears.

## Protection boundary

An opt-in privileged service would own a narrowly scoped firewall anchor that
blocks IPv4 and IPv6 egress on physical interfaces while protection is armed.
Arm the block before installing tunnel routes. Permit traffic inside the tunnel
and only the proxy core's required outer connections on physical interfaces.
Keep the block through app/core/forwarder crashes, sleep, network changes,
authentication failure and exhausted recovery. Automatic server selection may
change the allowed proxy endpoints only while the block remains armed.

Do not modify unrelated firewall rules or infer protection from an active utun.
Report protection as unarmed, arming, protected, blocked, or failed, independently
of proxy and TUN status. Never display protected until the privileged service has
acknowledged both IPv4 and IPv6 enforcement. Unsupported/enforcement failure must
leave connection attempts blocked, with an explicit recovery action.

## Bootstrap and DNS

Application DNS already goes through the tunnel (spec 9.5): the forwarder hands
port 53 to the core, and only the core's lookups of its own server names leave
directly, for exactly those names. Resolve proxy hostnames before arming, or allow only a dedicated
core bootstrap resolver with pinned destinations and a scoped authorization.
Permit only the outer endpoints needed by the selected protocol (including
documented UDP/port-hopping endpoints), and explicitly chosen LAN/DHCP/NDP
exceptions. Subscription refresh, updates and health probes must use the proxy
or tightly scoped service-owned exceptions; no silent direct fallback.

Rule updates need endpoint/identity validation and atomic replacement. The
service must not accept arbitrary shell commands, firewall text or untrusted
full Xray configs from the unprivileged app. It must bind authorization to the
intended app and separately validate every requested exception.

## Lifetime and recovery

Disabling protection is an explicit user action. Show that direct traffic will
resume. Provide a privileged, authenticated recovery path if the GUI cannot run.
The helper must reconcile stale state after launch and avoid removing an armed
block merely because its app heartbeat vanished. Define reboot behavior before
shipping; protection must not silently disappear while the UI claims it persists.

## Release validation

Use an isolated development host with packet capture on every physical interface.
Exercise core, forwarder, GUI and privileged-service crashes; cancel authorization;
exhaust recovery; change Wi-Fi/Ethernet; sleep/wake; and test IPv4/IPv6, TCP/UDP,
DNS/DoH/DoT, endpoint rotation, port hopping and full custom configs. Verify that
only documented bootstrap exceptions escape while armed and that disabling
protection restores the original firewall state. Test recovery with the GUI and
core unavailable. This requires privileged integration tests beyond the current
unprivileged helper/DNS configuration regressions.

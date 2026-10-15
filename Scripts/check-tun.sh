#!/bin/sh
# Checks that TUN mode carries all of this Mac's traffic (spec 9.5). Run it while V2Mac is
# connected with TUN mode on. It watches the physical interface with tcpdump (hence sudo) while
# it makes DNS lookups and connections, and reports anything that left outside the tunnel.
#
#   Scripts/check-tun.sh
#
# Exit status 0 when nothing leaked.
set -u

phys=$(printf 'show State:/Network/Global/IPv4\n' | scutil | sed -n 's/^ *PrimaryInterface : //p')
[ -n "$phys" ] || { echo "No network connection."; exit 2; }
leaks=0
ok() { echo "  ok    $1"; }
leak() { echo "  LEAK  $1"; leaks=$((leaks + 1)); }
via() { route -n get "$@" 2>/dev/null | awk '/interface:/ {print $2}'; }

echo "Routes (physical interface: $phys)"
tun=$(via 1.0.0.1)
case "$tun" in
  utun*) ok "IPv4 goes into $tun" ;;
  *) leak "IPv4 leaves through ${tun:-nothing}: is TUN mode on?" ;;
esac
v6=$(via -inet6 2606:4700:4700::1001)
case "$v6" in
  utun*) ok "IPv6 goes into $v6" ;;
  "") ok "no IPv6 route on this network" ;;
  *) leak "IPv6 leaves through $v6" ;;
esac

echo "DNS"
servers=$(scutil --dns | awk '/for scoped/ {exit} /^resolver #1/ {on=1; next} /^resolver/ {on=0} on && /nameserver/ {print $3}')
for s in $servers; do
  case "$(via "$s")" in
    utun*) ok "resolver $s is reached through the tunnel" ;;
    *) leak "resolver $s is reached directly, through $(via "$s")" ;;
  esac
done

echo "Watching $phys while lookups and connections run (sudo asks for your password)…"
capture=$(mktemp)
token="v2mac-check-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)"
sudo -v || exit 2
sudo tcpdump -i "$phys" -n -l -s 512 "port 53 or host 1.0.0.1 or host 9.9.9.9 or host 2606:4700:4700::1001" > "$capture" 2>/dev/null &
dump=$!
sleep 2
# The system resolver, the resolver /etc/resolv.conf names, and one an app picks itself.
dscacheutil -q host -a name "$token-sys.example.com" > /dev/null
dig +time=3 +tries=1 "$token-dig.example.com" > /dev/null 2>&1
dig +time=3 +tries=1 @9.9.9.9 "$token-q9.example.com" > /dev/null 2>&1
exit4=$(curl -s -m 10 https://1.0.0.1/cdn-cgi/trace | sed -n 's/^ip=//p')
exit6=""
[ -n "$v6" ] && exit6=$(curl -6 -s -m 10 'https://[2606:4700:4700::1001]/cdn-cgi/trace' | sed -n 's/^ip=//p')
sleep 2
sudo kill "$dump" 2> /dev/null
wait "$dump" 2> /dev/null

if grep -q "$token" "$capture"; then
  leak "DNS lookups went out directly:"
  grep "$token" "$capture" | sed 's/^/          /'
else
  ok "no lookup went out directly"
fi
if grep -Eq '1\.0\.0\.1|9\.9\.9\.9|2606:4700:4700::1001' "$capture"; then
  leak "connections went out directly:"
  grep -E '1\.0\.0\.1|9\.9\.9\.9|2606:4700:4700::1001' "$capture" | head -5 | sed 's/^/          /'
else
  ok "no connection went out directly"
fi
rm -f "$capture"

echo "Exit address: ${exit4:-no answer}${exit6:+ / $exit6} (should be the server's, not yours)"
if [ "$leaks" -eq 0 ]; then echo "All traffic went through the tunnel."; else echo "$leaks leak(s) found."; fi
[ "$leaks" -eq 0 ]

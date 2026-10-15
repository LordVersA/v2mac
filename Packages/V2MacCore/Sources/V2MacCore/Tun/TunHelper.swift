import Darwin
import Foundation

/// The privileged side of TUN mode: a shell script that runs as root for one app session and
/// keeps the TUN forwarder up while the app asks for it.
///
/// The app talks to it only through two flag files in its own run directory. The script and the
/// forwarder config travel inside the root command itself, and the helper copies the core into a
/// root-owned directory and checks its SHA-256 against the one in the command, so no file a
/// process without root can change between the prompt and the copy is ever run as root.
///
/// While the forwarder runs, the helper also points the primary network service's DNS at
/// `dnsServers` (spec 9.5): a resolver on the local network is reached without the TUN, so its
/// lookups would never reach the core.
public enum TunHelper {
    /// Present while the app wants the helper alive.
    public static let sessionFlag = "tun.session"
    /// Present while the TUN should be up.
    public static let onFlag = "tun.on"

    public static func rootDirectory(uid: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/var/run/v2mac-tun-\(uid)", isDirectory: true)
    }

    /// Arguments: app pid, state directory, core binary, its SHA-256, forwarder config (the JSON
    /// itself), root directory. The body is one `{ }` group, so the shell has read all of it
    /// before running any of it.
    public static let script = #"""
    # V2Mac TUN helper. Runs as root for one app session.
    {
    APP_PID="$1"; STATE_DIR="$2"; XRAY_SRC="$3"; XRAY_SHA="$4"; CONFIG="$5"; ROOT_DIR="$6"
    [ -n "$ROOT_DIR" ] || exit 64
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    umask 022

    rm -rf "$ROOT_DIR"
    mkdir -m 755 "$ROOT_DIR" || exit 1
    if ! cp "$XRAY_SRC" "$ROOT_DIR/xray" \
      || [ "$(shasum -a 256 "$ROOT_DIR/xray" | cut -d ' ' -f 1)" != "$XRAY_SHA" ] \
      || ! printf '%s\n' "$CONFIG" > "$ROOT_DIR/config.json"; then
      rm -rf "$ROOT_DIR"
      exit 1
    fi
    chmod 755 "$ROOT_DIR/xray"
    chmod 644 "$ROOT_DIR/config.json"

    \#(dnsFunctions)
    child=""
    stop_tun() {
      dns_restore
      [ -n "$child" ] || return 0
      kill "$child" 2>/dev/null
      n=0
      while kill -0 "$child" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
      kill -9 "$child" 2>/dev/null
      wait "$child" 2>/dev/null
      child=""
    }
    finish() { stop_tun; rm -rf "$ROOT_DIR"; exit 0; }
    trap finish TERM INT
    trap '' HUP

    echo $$ > "$ROOT_DIR/pid"
    tick=0
    while kill -0 "$APP_PID" 2>/dev/null && [ -e "$STATE_DIR/tun.session" ]; do
      if [ ! -e "$STATE_DIR/tun.on" ]; then
        stop_tun
      elif [ -z "$child" ]; then
        "$ROOT_DIR/xray" run -c "$ROOT_DIR/config.json" > "$ROOT_DIR/xray.log" 2>&1 &
        child=$!
        tick=0
      elif ! kill -0 "$child" 2>/dev/null; then
        # It died on its own. Wait before the next try so a broken start does not spin.
        wait "$child" 2>/dev/null
        child=""
        dns_restore
        sleep 2
      else
        # Soon after the start, then every few seconds: a network change or a settings
        # change can replace the DNS servers, or the service they belong to.
        [ $((tick % 10)) -eq 1 ] && dns_apply
        tick=$((tick + 1))
      fi
      sleep 0.3
    done
    finish
    }

    """#

    /// Public resolvers: lookups sent to them enter the TUN, and if the helper is killed before it
    /// can undo the change they still answer.
    public static let dnsServers = "1.1.1.1 8.8.8.8"

    /// The DNS part of the helper. The change is made in the dynamic store only (`Setup:` keys,
    /// which win over what DHCP sets), never in the saved network settings, so a reboot or a
    /// change in System Settings drops it, and putting it back means copying the saved
    /// settings over it again. That also undoes a change a killed helper left behind.
    static let dnsFunctions = #"""
    DNS_SERVERS='\#(dnsServers)'
    dns_svc=""
    dns_list() { awk '/ServerAddresses/ {on=1; next} on && /}/ {exit} on {print $3}' | tr '\n' ' ' | sed 's/ $//'; }
    dns_set() {
      if [ -n "$2" ]; then
        printf 'd.init\nget %s\nd.add ServerAddresses * %s\nset %s\n' "$1" "$2" "$1" | scutil > /dev/null
      else
        printf 'd.init\nget %s\nd.remove ServerAddresses\nset %s\n' "$1" "$1" | scutil > /dev/null
      fi
    }
    dns_flush() { dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null; }
    dns_apply() {
      svc=$(printf 'show State:/Network/Global/IPv4\n' | scutil | sed -n 's/^ *PrimaryService : //p')
      [ -n "$svc" ] || return 0
      [ "$svc" = "$dns_svc" ] || dns_restore
      current=$(printf 'show Setup:/Network/Service/%s/DNS\n' "$svc" | scutil | dns_list)
      [ "$svc" = "$dns_svc" ] && [ "$current" = "$DNS_SERVERS" ] && return 0
      dns_set "Setup:/Network/Service/$svc/DNS" "$DNS_SERVERS"
      dns_svc=$svc
      dns_flush
    }
    dns_restore() {
      [ -n "$dns_svc" ] || return 0
      saved=$(printf 'get /NetworkServices/%s/DNS\nd.show\n' "$dns_svc" | scutil --prefs)
      case "$saved" in
        *"No such key"*) printf 'remove Setup:/Network/Service/%s/DNS\n' "$dns_svc" | scutil > /dev/null ;;
        *) dns_set "Setup:/Network/Service/$dns_svc/DNS" "$(printf '%s\n' "$saved" | dns_list)" ;;
      esac
      dns_svc=""
      dns_flush
    }
    """#

    /// The shell command that starts the helper in the background and returns at once.
    /// `coreSHA256` must be taken before the prompt; `config` is the forwarder config's JSON.
    public static func launchCommand(
        appPID: Int32, stateDirectory: URL, core: URL, coreSHA256: String, config: String, rootDirectory: URL
    ) -> String {
        let arguments = [script, "v2mac-tun-helper", "\(appPID)", stateDirectory.path, core.path, coreSHA256, config, rootDirectory.path]
        return "/bin/sh -c " + arguments.map(shellQuoted).joined(separator: " ") + " > /dev/null 2>&1 &"
    }

    /// SHA-256 of a file, hex, as `shasum -a 256` prints it.
    public static func sha256(of file: URL) async throws -> String {
        try await Task.detached { RegionPackInstaller.sha256(try Data(contentsOf: file)) }.value
    }

    /// AppleScript that runs `command` as root after the system's administrator prompt.
    public static func appleScript(command: String, prompt: String) -> String {
        "do shell script \(appleScriptQuoted(command)) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// True while the helper that wrote `rootDirectory/pid` is running.
    public static func isAlive(rootDirectory: URL) -> Bool {
        let file = rootDirectory.appendingPathComponent("pid")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        // A root process answers EPERM to an unprivileged signal 0: it exists.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The most useful line of the forwarder's output, for an error message.
    public static func failureDetail(rootDirectory: URL) -> String? {
        let file = rootDirectory.appendingPathComponent("xray.log")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return CoreOutputParser.failureDetail(from: text.split(separator: "\n").suffix(100).map(String.init))
    }
}

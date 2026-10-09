import Darwin
import Foundation

/// The privileged side of TUN mode: a shell script that runs as root for one app session and
/// keeps the TUN forwarder up while the app asks for it.
///
/// The app talks to it only through two flag files in its own run directory. The helper copies
/// the core and its config into a root-owned directory first, so nothing it runs later can be
/// changed by a process without root.
public enum TunHelper {
    /// Present while the app wants the helper alive.
    public static let sessionFlag = "tun.session"
    /// Present while the TUN should be up.
    public static let onFlag = "tun.on"

    public static func rootDirectory(uid: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/var/run/v2mac-tun-\(uid)", isDirectory: true)
    }

    /// Arguments: app pid, state directory, core binary, forwarder config, root directory.
    /// The body is one `{ }` group, so the shell has read all of it before running any of it.
    public static let script = #"""
    #!/bin/sh
    # V2Mac TUN helper. Runs as root for one app session.
    {
    APP_PID="$1"; STATE_DIR="$2"; XRAY_SRC="$3"; CONFIG_SRC="$4"; ROOT_DIR="$5"
    [ -n "$ROOT_DIR" ] || exit 64
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    umask 022

    rm -rf "$ROOT_DIR"
    mkdir -m 755 "$ROOT_DIR" || exit 1
    if ! cp "$XRAY_SRC" "$ROOT_DIR/xray" || ! cp "$CONFIG_SRC" "$ROOT_DIR/config.json"; then
      rm -rf "$ROOT_DIR"
      exit 1
    fi
    chmod 755 "$ROOT_DIR/xray"
    chmod 644 "$ROOT_DIR/config.json"

    child=""
    stop_tun() {
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
    while kill -0 "$APP_PID" 2>/dev/null && [ -e "$STATE_DIR/tun.session" ]; do
      if [ ! -e "$STATE_DIR/tun.on" ]; then
        stop_tun
      elif [ -z "$child" ]; then
        "$ROOT_DIR/xray" run -c "$ROOT_DIR/config.json" > "$ROOT_DIR/xray.log" 2>&1 &
        child=$!
      elif ! kill -0 "$child" 2>/dev/null; then
        # It died on its own. Wait before the next try so a broken start does not spin.
        wait "$child" 2>/dev/null
        child=""
        sleep 2
      fi
      sleep 0.3
    done
    finish
    }

    """#

    /// The shell command that starts the helper in the background and returns at once.
    public static func launchCommand(
        script: URL, appPID: Int32, stateDirectory: URL, core: URL, config: URL, rootDirectory: URL
    ) -> String {
        let arguments = [script.path, "\(appPID)", stateDirectory.path, core.path, config.path, rootDirectory.path]
        return "/bin/sh " + arguments.map(shellQuoted).joined(separator: " ") + " > /dev/null 2>&1 &"
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

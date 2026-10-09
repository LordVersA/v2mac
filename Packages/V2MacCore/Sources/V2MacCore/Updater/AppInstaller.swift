import Foundation

public enum AppInstallError: Error, Sendable, Equatable, LocalizedError {
    case mountFailed
    case appMissing
    case copyFailed
    case signatureInvalid
    case wrongApp
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .mountFailed: "The downloaded disk image could not be opened."
        case .appMissing: "The disk image does not contain V2Mac."
        case .copyFailed: "The new version could not be copied."
        case .signatureInvalid: "The new version failed its signature check."
        case .wrongApp: "The download is not the expected version of V2Mac."
        case .notWritable(let path): "V2Mac cannot replace itself in \(path). Move it to Applications, or install the update by hand."
        }
    }
}

/// Downloads a release of the app, checks it, and swaps it for the running copy (spec 11.3).
public enum AppInstaller {
    public static let appName = "V2Mac.app"

    /// A checked copy of the new app, ready to be swapped in.
    public struct Staged: Sendable, Equatable {
        public var app: URL
        /// Holds `app`; removed after the swap.
        public var workDirectory: URL
        public var version: String
    }

    // MARK: Release files

    /// The DMG the release workflow publishes for `tag`, and its checksum file.
    public static func assetURLs(repository: String, tag: String) -> (dmg: URL, checksum: URL)? {
        let name = "V2Mac-\(VersionCompare.normalized(tag)).dmg"
        guard let tagPart = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let dmg = URL(string: "https://github.com/\(repository)/releases/download/\(tagPart)/\(name)"),
              let checksum = URL(string: dmg.absoluteString + ".sha256") else { return nil }
        return (dmg, checksum)
    }

    /// The hash in a `shasum -a 256` line ("<hex>  <file>").
    public static func parseChecksum(_ data: Data) throws -> String {
        let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
        guard let first, first.count == 64, first.allSatisfy(\.isHexDigit) else { throw DownloadError.checksumMalformed }
        return first
    }

    // MARK: Prepare

    /// Downloads the DMG, checks it against the published SHA-256, copies the app out of it and
    /// verifies its signature, bundle identifier and version. The installed app is not touched.
    public static func prepare(
        dmg: URL,
        checksum: URL,
        expectedVersion: String,
        bundleIdentifier: String,
        downloader: FileDownloader,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> Staged {
        let expected = try parseChecksum(try await downloader.download(checksum))
        let image = try await downloader.download(dmg, onProgress: onProgress)
        guard RegionPackInstaller.sha256(image) == expected else {
            throw DownloadError.checksumMismatch(file: dmg.lastPathComponent)
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("v2mac-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let app = try await unpack(image, in: work)
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            let version = info?["CFBundleShortVersionString"] as? String ?? ""
            guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
                  VersionCompare.normalized(version) == VersionCompare.normalized(expectedVersion) else {
                throw AppInstallError.wrongApp
            }
            return Staged(app: app, workDirectory: work, version: version)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private static func unpack(_ image: Data, in work: URL) async throws -> URL {
        let fm = FileManager.default
        let imageURL = work.appendingPathComponent("update.dmg")
        try image.write(to: imageURL)
        defer { try? fm.removeItem(at: imageURL) }
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)

        let attach = try await CoreUpdater.run("/usr/bin/hdiutil", [
            "attach", imageURL.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path,
        ])
        guard attach.status == 0 else { throw AppInstallError.mountFailed }

        let source = mount.appendingPathComponent(appName)
        let app = work.appendingPathComponent(appName)
        let copy: Int32? = fm.fileExists(atPath: source.path)
            ? try? await CoreUpdater.run("/usr/bin/ditto", [source.path, app.path]).status
            : nil
        _ = try? await CoreUpdater.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard let copy else { throw AppInstallError.appMissing }
        guard copy == 0 else { throw AppInstallError.copyFailed }

        _ = try? await CoreUpdater.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard try await CoreUpdater.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            throw AppInstallError.signatureInvalid
        }
        return app
    }

    // MARK: Swap

    /// Whether the app at `target` can be replaced in place.
    public static func checkReplaceable(_ target: URL) throws {
        let parent = target.deletingLastPathComponent().path
        let fm = FileManager.default
        guard !target.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: target.path) else {
            throw AppInstallError.notWritable(parent)
        }
    }

    /// Waits for the running app (`$1`) to exit, replaces it (`$3`) with the staged copy (`$2`),
    /// starts it again with the command in `$5` and removes the work directory (`$4`).
    /// The old app is put back when the new one cannot be moved into place.
    public static let swapScript = """
    #!/bin/sh
    APP_PID="$1"; NEW="$2"; APP="$3"; WORK="$4"; OPEN="$5"
    OLD="$(dirname "$APP")/.v2mac-previous-$$"

    n=0
    while kill -0 "$APP_PID" 2>/dev/null; do
      n=$((n + 1))
      # Never replace an app that is still running.
      [ "$n" -gt 300 ] && exit 1
      sleep 0.2
    done

    if mv "$APP" "$OLD" 2>/dev/null; then
      if mv "$NEW" "$APP" 2>/dev/null; then
        rm -rf "$OLD"
      else
        rm -rf "$APP"
        mv "$OLD" "$APP"
      fi
    fi
    rm -rf "$WORK"
    "$OPEN" "$APP"

    """

    /// Starts the swap script detached. The caller then quits the app, which lets it proceed.
    public static func scheduleSwap(
        _ staged: Staged,
        replacing target: URL,
        processID: Int32,
        openCommand: String = "/usr/bin/open"
    ) throws {
        try checkReplaceable(target)
        // Outside the work directory, which the script deletes.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-swap-\(UUID().uuidString).sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "\(processID)", staged.app.path, target.path, staged.workDirectory.path, openCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

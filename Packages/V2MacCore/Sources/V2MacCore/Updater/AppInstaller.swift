import CryptoKit
import Foundation

public enum AppInstallError: Error, Sendable, Equatable, LocalizedError {
    case mountFailed
    case appMissing
    case copyFailed
    case signatureInvalid
    case notSignedByProject
    case wrongApp
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .mountFailed: String(localized: "The downloaded disk image could not be opened.")
        case .appMissing: String(localized: "The disk image does not contain V2Mac.")
        case .copyFailed: String(localized: "The new version could not be copied.")
        case .signatureInvalid: String(localized: "The new version failed its signature check.")
        case .notSignedByProject: String(localized: "The download is not signed by the V2Mac project.")
        case .wrongApp: String(localized: "The download is not the expected version of V2Mac.")
        case .notWritable(let path): String(localized: "V2Mac cannot replace itself in \(path). Move it to Applications, or install the update by hand.")
        }
    }
}

/// Downloads a release of the app, checks it, and swaps it for the running copy (spec 11.3).
public enum AppInstaller {
    public static let appName = "V2Mac.app"

    /// Public half of the Ed25519 key the release workflow signs each DMG with
    /// (`Scripts/sign-update.swift`, secret `UPDATE_SIGNING_KEY`). The DMG's own code signature
    /// is ad-hoc and its `.sha256` comes from the same release, so this is what proves origin.
    public static let updateKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "gD28LTL7mjOQOXZnPkm/FuIH8bRKZh8JuMlDXODXmpE=")!
    )

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

    /// The release's file-by-file manifest (`BundleManifest`); its signature is `<url>.sig`.
    public static func manifestURL(repository: String, tag: String) -> URL? {
        guard let tagPart = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/download/\(tagPart)/files.json")
    }

    /// The hash in a `shasum -a 256` line ("<hex>  <file>").
    public static func parseChecksum(_ data: Data) throws -> String {
        let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
        guard let first, first.count == 64, first.allSatisfy(\.isHexDigit) else { throw DownloadError.checksumMalformed }
        return first
    }

    // MARK: Prepare

    /// Whether `signature` (the base64 `.sig` file) is `key`'s signature of `data`.
    public static func isSigned(_ data: Data, signature: Data, by key: Curve25519.Signing.PublicKey = updateKey) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(raw, for: data)
    }

    /// Downloads the DMG, checks it against the published SHA-256 and the project's signature
    /// (`<dmg>.sig`), copies the app out of it and verifies its code signature, bundle identifier
    /// and version. The installed app is not touched.
    public static func prepare(
        dmg: URL,
        checksum: URL,
        expectedVersion: String,
        bundleIdentifier: String,
        downloader: FileDownloader,
        signedBy key: Curve25519.Signing.PublicKey = updateKey,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> Staged {
        let expected = try parseChecksum(try await downloader.download(checksum))
        let signature = try await downloader.download(URL(string: dmg.absoluteString + ".sig")!)
        let image = try await downloader.download(dmg, onProgress: onProgress)
        guard RegionPackInstaller.sha256(image) == expected else {
            throw DownloadError.checksumMismatch(file: dmg.lastPathComponent)
        }
        guard isSigned(image, signature: signature, by: key) else { throw AppInstallError.notSignedByProject }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("v2mac-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let app = try await unpack(image, in: work)
            let version = try await check(app, expectedVersion: expectedVersion, bundleIdentifier: bundleIdentifier)
            return Staged(app: app, workDirectory: work, version: version)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Builds the release beside the installed app in `work` (docs/app-auto-update.md): the manifest must carry
    /// the project's signature, then unchanged files are copied from `installed`, patched where a patch applies,
    /// the rest downloaded (`BundleManifest.build`), and the result gets the same checks as a DMG's app.
    /// Downloads stay in `work/download` for a later attempt.
    public static func prepareDelta(
        manifest url: URL,
        expectedVersion: String,
        bundleIdentifier: String,
        installed: URL,
        alternates: [String: URL] = [:],
        work: URL,
        downloader: FileDownloader,
        download: ResumableDownload,
        signedBy key: Curve25519.Signing.PublicKey = updateKey,
        onProgress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> Staged {
        let data = try await downloader.download(url)
        let signature = try await downloader.download(URL(string: url.absoluteString + ".sig")!)
        guard isSigned(data, signature: signature, by: key) else { throw AppInstallError.notSignedByProject }
        let manifest = try BundleManifest(data: data)
        guard VersionCompare.normalized(manifest.version) == VersionCompare.normalized(expectedVersion) else {
            throw AppInstallError.wrongApp
        }
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let app = work.appendingPathComponent(appName)
        do {
            try await manifest.build(at: app, from: installed, alternates: alternates, release: url,
                                     downloads: work.appendingPathComponent("download"), download: download, onProgress: onProgress)
            let version = try await check(app, expectedVersion: expectedVersion, bundleIdentifier: bundleIdentifier)
            return Staged(app: app, workDirectory: work, version: version)
        } catch {
            try? fm.removeItem(at: app)
            throw error
        }
    }

    /// Code signature, bundle identifier and version of a downloaded app; returns its version.
    private static func check(_ app: URL, expectedVersion: String, bundleIdentifier: String) async throws -> String {
        _ = try? await CoreUpdater.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard try await CoreUpdater.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            throw AppInstallError.signatureInvalid
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              VersionCompare.normalized(version) == VersionCompare.normalized(expectedVersion) else {
            throw AppInstallError.wrongApp
        }
        return version
    }

    // MARK: Staged update

    /// Moves a checked app to `updates/V2Mac.app`, where it waits for the next quit (or launch). Only a
    /// checked app is ever moved there, so its presence means it is ready.
    public static func stage(_ prepared: Staged, in updates: URL) throws -> Staged {
        let fm = FileManager.default
        let app = updates.appendingPathComponent(appName)
        try fm.createDirectory(at: updates, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: app)
        try fm.moveItem(at: prepared.app, to: app)
        if prepared.workDirectory != updates { try? fm.removeItem(at: prepared.workDirectory) }
        return Staged(app: app, workDirectory: updates, version: prepared.version)
    }

    /// The app staged in `updates/` when it is a newer version of this one. Anything else there is removed.
    public static func staged(in updates: URL, newerThan version: String, bundleIdentifier: String) -> Staged? {
        let app = updates.appendingPathComponent(appName)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let newVersion = info?["CFBundleShortVersionString"] as? String,
              info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              VersionCompare.isNewer(newVersion, than: version) else {
            if FileManager.default.fileExists(atPath: app.path) { try? FileManager.default.removeItem(at: updates) }
            return nil
        }
        return Staged(app: app, workDirectory: updates, version: newVersion)
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
    /// starts it again with the command in `$5` (none: it stays closed) and removes the work directory (`$4`).
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
    rm -f "$0"
    [ -n "$OPEN" ] && "$OPEN" "$APP"
    exit 0

    """

    /// Starts the swap script detached. The caller then quits the app, which lets it proceed.
    public static func scheduleSwap(
        _ staged: Staged,
        replacing target: URL,
        processID: Int32,
        openCommand: String? = "/usr/bin/open"
    ) throws {
        try checkReplaceable(target)
        // Outside the work directory, which the script deletes.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("v2mac-swap-\(UUID().uuidString).sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "\(processID)", staged.app.path, target.path, staged.workDirectory.path, openCommand ?? ""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

import Foundation
import Observation
import V2MacCore

/// The Cloudflare WARP device (spec 9.10): registering it, WARP+ license keys, and the server
/// and exit made from it. Cloudflare is asked through the proxy when it runs, since its API is
/// often blocked where the app is needed.
@MainActor @Observable
final class WarpService {
    private(set) var account: WarpAccount? = Prefs.warpAccount
    private(set) var isBusy = false
    var errorMessage: String?

    @ObservationIgnored var route: () -> FetchRoute = { .direct }
    /// The device changed, so a running WARP exit needs the core restarted.
    @ObservationIgnored var onAccountChanged: () -> Void = {}
    @ObservationIgnored var addServer: ([ParsedProfile]) async throws -> UUID = { _ in throw WarpError.badResponse }

    private var client: WarpClient { WarpClient(route: route()) }

    func register() async {
        await run { try await self.client.register() }
    }

    func refresh() async {
        guard let account else { return }
        await run { try await self.client.refresh(account) }
    }

    func setLicense(_ license: String) async {
        let license = license.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !license.isEmpty else { return }
        await run { try await self.client.setLicense(license, on: account) }
    }

    /// Removes the device from Cloudflare, and from this Mac even when Cloudflare cannot be reached.
    func remove() async {
        guard let account else { return }
        isBusy = true
        try? await client.delete(account)
        isBusy = false
        save(nil)
    }

    /// Adds WARP to Custom Configs as a server of its own; returns its group.
    func addToServers() async -> UUID? {
        guard let account else { return nil }
        do {
            errorMessage = nil
            return try await addServer([account.profile])
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func run(_ work: @escaping () async throws -> WarpAccount) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            save(try await work())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ new: WarpAccount?) {
        let keysChanged = new?.privateKey != account?.privateKey
        account = new
        Prefs.warpAccount = new
        if keysChanged { onAccountChanged() }
    }
}

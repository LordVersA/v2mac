import Foundation
import Testing
import V2MacCore

@Suite @MainActor
struct ConnectionGroupTests {
    private func connection(_ id: Int, host: String = "example.com", app: String? = nil, process: String? = nil) -> ConnectionWatcher.Connection {
        var row = ConnectionWatcher.Connection(id: id, sourcePort: nil, host: host, port: 443,
                                               inbound: ConfigBuilder.inboundTag, outbound: ConfigBuilder.proxyTag, start: .now)
        row.app = app
        row.process = process
        return row
    }

    @Test func hostGroupsReuseRuleEditorBrandsAndKeepAddressesSeparate() throws {
        let rows = [connection(1, host: "mail.google.com"), connection(2, host: "googleapis.com"),
                    connection(3, host: "google.co.uk"), connection(4, host: "1.2.3.4"), connection(5, host: "1.2.3.5")]
        let groups = ConnectionGroup.make(rows, by: .host)
        #expect(groups.count == 3)
        let google = try #require(groups.first { $0.title == "google" })
        #expect(google.connections.map(\.id) == [1, 2, 3])
        #expect(Set(groups.flatMap(\.connections).map(\.id)) == Set(rows.map(\.id)))
        #expect(groups.contains { $0.title == "1.2.3.4" })
        #expect(groups.contains { $0.title == "1.2.3.5" })
    }

    @Test func groupTotalsFollowOnlyTheSuppliedConnections() throws {
        var open = connection(1), closed = connection(2), unknown = connection(3)
        open.sent = 10; open.received = 20
        closed.sent = 30; closed.received = 40; closed.end = .now
        unknown.untracked = true
        let all = try #require(ConnectionGroup.make([open, closed, unknown], by: .host).first)
        #expect(all.connections.count == 3 && all.openCount == 1)
        #expect(all.sent == 40 && all.received == 60 && all.hasTrackedTraffic)
        let filtered = try #require(ConnectionGroup.make([open], by: .host).first)
        #expect(filtered.id == all.id)
        #expect(filtered.sent == 10 && filtered.received == 20)
        #expect(ConnectionGroup.make([unknown], by: .host).first?.hasTrackedTraffic == false)
        #expect(ConnectionGroup.make([], by: .host).isEmpty)
    }

    @Test func applicationsProcessesAndUnknownRowsStayDistinct() {
        let rows = [connection(1, app: "/Fixtures/Chat.app"), connection(2, app: "/Fixtures/Chat.app"),
                    connection(3, process: "Chat"), connection(4), connection(5)]
        let groups = ConnectionGroup.make(rows, by: .app)
        #expect(groups.count == 3)
        #expect(groups.first { $0.connections.contains { $0.id == 1 } }?.connections.map(\.id) == [1, 2])
        #expect(groups.first { $0.connections.contains { $0.id == 3 } }?.connections.count == 1)
        #expect(groups.first { $0.connections.contains { $0.id == 4 } }?.connections.map(\.id) == [4, 5])
    }

    @Test func tableGroupRowsKeepChildrenAndSortByAggregatedTraffic() throws {
        var first = connection(1), second = connection(2)
        first.sent = 10; first.received = 20
        second.sent = 30; second.received = 40
        let group = try #require(ConnectionGroup.make([first, second], by: .host).first)
        let header = ConnectionGroup.Row.group(group)
        let child = ConnectionGroup.Row.connection(first)
        #expect(header.id != child.id)
        #expect(header.children.map(\.connection?.id) == [1, 2])
        #expect(header.sent == 40 && header.received == 60)
        #expect(child.target == first.target && child.appName == first.appName)
        #expect(child.children.isEmpty)
        #expect([child, header].sorted(using: KeyPathComparator(\.sent, order: .reverse)).first?.id == header.id)
    }

    @Test func aThousandConnectionsUseOneHostGroupWithoutLosingRows() throws {
        let rows = (0..<1000).map { connection($0, host: "api\($0 % 25).example.com") }
        let groups = ConnectionGroup.make(rows, by: .host)
        #expect(groups.count == 1)
        let header = ConnectionGroup.Row.group(try #require(groups.first))
        #expect(header.children.count == 1000)
        #expect(Set(([header] + header.children).map(\.id)).count == 1001)
    }

    @Test func routeFilterCombinesWithSearchAndOpenStateBeforeGrouping() throws {
        var proxy = connection(1, host: "api.example.com", process: "curl")
        proxy.action = .proxy; proxy.sent = 10; proxy.usesProxySetting = true
        var direct = connection(2, host: "www.example.com")
        direct.action = .direct; direct.sent = 20; direct.end = .now
        var block = connection(3, host: "ads.example.com")
        block.action = .block; block.sent = 30
        let unknown = connection(4)
        let rows = [proxy, direct, block, unknown]
        #expect(rows.filter { $0.matches(search: "", onlyOpen: false, action: nil) }.count == 4)
        for action in CustomRule.Action.allCases {
            #expect(rows.filter { $0.matches(search: "", onlyOpen: false, action: action) }.count == 1)
        }
        #expect(rows.filter { $0.matches(search: "", onlyOpen: true, action: .direct) }.isEmpty)
        #expect(rows.filter { $0.matches(search: "CURL", onlyOpen: true, action: .proxy) }.map(\.id) == [1])
        #expect(rows.filter { $0.matches(search: "ads", onlyOpen: false, action: .proxy) }.isEmpty)
        let filtered = rows.filter { $0.matches(search: "EXAMPLE.COM", onlyOpen: true, action: .proxy) }
        let group = try #require(ConnectionGroup.make(filtered, by: .host).first)
        #expect(group.connections.map(\.id) == [1])
        #expect(group.sent == 10 && group.openCount == 1)
    }

    @Test func applicationsFromTheSameVendorGroupTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rows: [ConnectionWatcher.Connection] = []
        for (id, name) in ["Chat", "Mail"].enumerated() {
            let app = directory.appendingPathComponent("\(name).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "com.fixture.\(name.lowercased())", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            rows.append(connection(id, app: app.path))
        }
        let group = try #require(ConnectionGroup.make(rows, by: .app).first)
        #expect(group.title == "fixture")
        #expect(group.connections.count == 2)
    }
}

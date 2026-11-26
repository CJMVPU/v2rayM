import XCTest
@testable import V2rayMKit

final class RuntimeQueryTests: XCTestCase {
    func testLogTailRetainsOnlyRequestedNewRowsAcrossEvictionAndClear() {
        let log = NativeRuntimeLog()
        log.append(source: "core", lines: (1...10_005).map(String.init))
        XCTAssertEqual(log.tail(after: 0, limit: .max).items.first?.sequence, 6)
        XCTAssertEqual(log.tail(after: 10_003, limit: 10_000).items.map(\.sequence), [10_004, 10_005])
        XCTAssertEqual(log.tail(after: 10_005, limit: 100).items.count, 0)
        XCTAssertEqual(log.tail(after: .max, limit: 1).items.first?.sequence, 10_005)
        log.clear()
        XCTAssertTrue(log.tail(after: 0, limit: 100).items.isEmpty)
        log.append(source: "core", lines: ["next"])
        let tail = log.tail(after: 2, limit: 100)
        XCTAssertEqual(tail.items.map(\.sequence), [10_006])
        XCTAssertEqual(tail.generation, 1)
    }

    func testFilteredLogPagesCountFromNewestAndPreserveInsertionOrder() {
        let log = NativeRuntimeLog()
        log.append(source: "core", lines: ["one", "two", "three", "four", "five"])
        log.append(source: "host", lines: ["exclude"])
        let latest = log.page(1, size: 2, filter: "^core ")
        XCTAssertEqual(latest.items.map(\.message), ["four", "five"])
        XCTAssertEqual(latest.total, 5)
        XCTAssertEqual(latest.totalPages, 3)
        XCTAssertEqual(log.page(Int.max, size: 2, filter: "^core ").items.map(\.message), ["one"])
        XCTAssertEqual(log.recent(limit: 2, filter: "[").map(\.message), ["five", "exclude"])
        log.clear()
        log.append(source: "host", lines: ["new generation"])
        let fresh = log.page(0, size: 999, filter: nil)
        XCTAssertEqual(fresh.pageSize, 200)
        XCTAssertEqual(fresh.items.first?.sequence, 7)
        XCTAssertEqual(fresh.items.first?.generation, 1)
    }

    func testExpensiveLogPatternReturnsSnapshotWithinOneBudget() {
        let log = NativeRuntimeLog()
        log.append(source: "core", lines: Array(repeating: String(repeating: "a", count: 100) + "!", count: 4))
        let start = ContinuousClock.now
        XCTAssertEqual(log.page(1, size: 100, filter: "(a+)+$").total, 4)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testNativeProfileObservationsMatchCompatibilityReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = NativeRuntimeHost(dataDirectory: directory, mayContactHelper: false, automaticMaintenance: false)
        let api = try await host.startClient()
        let store = NativeConfigurationStore(dataDirectory: directory)
        let db = try RuntimeDatabase(url: directory.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileExItem(IndexId,Delay) VALUES ('fixture',26)")
        _ = try db.query("INSERT INTO ServerStatItem(IndexId,TotalUp,TotalDown) VALUES ('fixture',15,50)")
        var settings = try await store.readSettings()
        for enabled in [true, false] {
            settings["GuiItem"]["EnableStatistics"] = .bool(enabled)
            try await store.writeSettings(settings)
            let typed = try await api.profileObservations()
            let compatibility: [ProfileObservation] = try await api.value("/api/profiles/observations")
            XCTAssertEqual(typed, compatibility)
            XCTAssertEqual(typed.first?.delay, 26)
            XCTAssertEqual(typed.first?.totalDown, enabled ? 50 : 0)
        }
        try await host.stop()
    }

    func testTodayCountersAndSortingExpireForIdleNodesButRetainLifetimeTotals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        var settings = try await store.readSettings()
        settings["GuiItem"]["EnableStatistics"] = .bool(true)
        try await store.writeSettings(settings)
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem(IndexId, Subid) VALUES ('yesterday','g'),('today','g'),('undated','g')")
        _ = try db.query("INSERT INTO ServerStatItem(IndexId,TotalDown,TodayDown) VALUES ('undated',100,100)")
        let now = Date()
        try await store.addTraffic(nodeID: "yesterday", up: 55, down: 99, date: now.addingTimeInterval(-86400 * 2))
        try await store.addTraffic(nodeID: "today", up: 1, down: 2, date: now)
        for key in ["todayup", "todaydown"] {
            try await store.sortProfiles(group: "g", column: key, ascending: false)
            let rows = try await store.profileCatalog(group: "g", includeStatistics: true)
            XCTAssertEqual(rows.map(\.id), ["today", "yesterday", "undated"])
            XCTAssertEqual(rows.map(\.todayDown), [2, 0, 0])
            XCTAssertEqual(rows.map(\.todayUp), [1, 0, 0])
            XCTAssertEqual(rows.map(\.totalDown), [2, 99, 100])
        }
        try await store.sortProfiles(group: "", column: "totaldown", ascending: false)
        let byTotal = try await store.profileCatalog(includeStatistics: true)
        XCTAssertEqual(byTotal.map(\.id), ["undated", "yesterday", "today"])
    }

    func testProfileListingPreservesStoredResultsAndDistinguishesOmittedGroupFromAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        var settings = try await store.readSettings()
        settings["SubIndexId"] = .string("g")
        settings["GuiItem"]["EnableStatistics"] = .bool(true)
        try await store.writeSettings(settings)
        let db = try RuntimeDatabase(url: root.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ProfileItem(IndexId,Subid,Remarks,Address) VALUES ('jp','g','Tokyo','jp.example'),('us','s','Seattle','us.example')")
        _ = try db.query("INSERT INTO ProfileExItem(IndexId,Sort,Speed,IpInfo) VALUES ('jp',3,12.5,'JP')")
        try await store.addTraffic(nodeID: "jp", up: 99, down: 101, date: Date())
        let selected = try await store.profileCatalog(group: nil, includeStatistics: true, search: "  ^jp[.] ")
        XCTAssertEqual(selected.map(\.id), ["jp"])
        XCTAssertEqual(selected.first?.speed, 12.5)
        XCTAssertEqual(selected.first?.ipInfo, "JP")
        XCTAssertEqual(selected.first?.todayDown, 101)
        XCTAssertEqual(selected.first?.todayUp, 99)
        let all = try await store.profileCatalog(group: "", search: "[")
        XCTAssertEqual(all.map(\.id), ["us", "jp"])
        XCTAssertEqual(all.last?.todayDown, 0)
    }
}

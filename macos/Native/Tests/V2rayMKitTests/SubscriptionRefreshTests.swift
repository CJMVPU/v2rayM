import Foundation
import XCTest
@testable import V2rayMKit

final class SubscriptionRefreshTests: XCTestCase {
    func testManualCopiesAndCrossGroupMovesSurviveBothSubscriptionUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let source = try await store.saveSubscription(.object(["remarks": .string("Source")]), id: nil)
        let destination = try await store.saveSubscription(.object(["remarks": .string("Destination")]), id: nil)
        let feed = try ShareLinkImport.decode("socks://127.0.0.1:11001#A1\nsocks://127.0.0.2:11002#A2")
        try await store.replaceSubscription(source, rows: feed, serving: nil)
        let entries = try await store.profileCatalog(group: source.id)
        let a = try XCTUnwrap(entries.first { $0.remarks == "A1" })
        let b = try XCTUnwrap(entries.first { $0.remarks == "A2" })
        try await store.copyProfiles([a.id])
        try await store.moveProfiles([a.id], group: source.id)
        try await store.moveProfiles([b.id], group: destination.id)
        let listing = try await store.profileCatalog(group: source.id)
        let clone = try XCTUnwrap(listing.first { $0.remarks == "A1-clone" })
        let current = try await store.subscriptions()
        try await store.replaceSubscription(try XCTUnwrap(current.first { $0.id == source.id }),
            rows: try ShareLinkImport.decode("socks://127.0.0.1:11111#A1"), serving: nil)
        try await store.replaceSubscription(destination,
            rows: try ShareLinkImport.decode("socks://127.0.0.3:11003#B1"), serving: nil)
        let original = try await store.profileDocument(id: a.id)
        let copied = try await store.profileDocument(id: clone.id)
        let moved = try await store.profileDocument(id: b.id)
        XCTAssertEqual(original["port"].text, "11111")
        XCTAssertTrue(original["isSub"].flag)
        XCTAssertEqual(copied["port"].text, "11001")
        XCTAssertFalse(copied["isSub"].flag)
        XCTAssertEqual(moved["subid"].text, destination.id)
        XCTAssertFalse(moved["isSub"].flag)
    }

    func testMatchIndexRespectsPrecedenceAndConsumesDuplicateRowsInOriginalOrder() {
        func row(_ id: String, _ name: String, _ address: String, _ password: String, _ port: Int64 = 80) -> RuntimeDatabase.Row {
            ["IndexId": .text(id), "ConfigType": .integer(4), "Remarks": .text(name), "Address": .text(address),
             "Password": .text(password), "Port": .integer(port)]
        }
        let previous = [row("a", "same", "one", "x"), row("b", "same", "two", "y"),
                        row("c", "old-c", "node", "a"), row("d", "old-d", "NODE", "Secret"),
                        row("e", "old-e", "node", "", 90)]
        let incoming = [row("", "same", "changed", ""), row("", "same", "two", "y"),
                        row("", "new", " node ", "Secret"), row("", "new", "node", "other"),
                        row("", "new", "node", "", 800)]
        let index = SubscriptionMatchIndex(previous: previous, incoming: incoming)
        XCTAssertEqual(index.matches.map { $0?["IndexId"] }, ["a","b","d","c","e"].map { .text($0) })
        XCTAssertTrue(index.unmatched.isEmpty)

        let ambiguous = SubscriptionMatchIndex(previous: [row("a", "old-a", "node", "PASS"), row("b", "old-b", "node", "pass")],
                                              incoming: [row("", "new", "node", "pAss")])
        XCTAssertNil(ambiguous.matches[0])
        XCTAssertEqual(ambiguous.unmatched.count, 2)
        let oneOld = SubscriptionMatchIndex(previous: [row("a", "old", "node", "a")],
                                           incoming: [row("", "one", "node", "b"), row("", "two", "node", "c")])
        XCTAssertTrue(oneOld.matches.allSatisfy { $0 == nil })

        let duplicates = SubscriptionMatchIndex(previous: [row("a", "same", "node", "x"), row("b", "same", "node", "x")],
                                               incoming: [row("", "same", "node", "x"), row("", "same", "node", "x")])
        XCTAssertEqual(duplicates.matches.map { $0?["IndexId"] }, [.text("a"), .text("b")])
    }

    func testNewEntryBeforeUnchangedPeersCannotTakeCurrentSelectionOrObservations() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NativeConfigurationStore(dataDirectory: dir)
        try await store.initializeRuntimeStore()
        let group = try await store.saveSubscription(.object(["remarks": .string("Fixture")]), id: nil)
        let feed = "socks://u:a@proxy.example:1080#A\nsocks://u:b@proxy.example:1080#B"
        try await store.replaceSubscription(group, rows: ShareLinkImport.decode(feed), serving: nil)
        let previous = try await store.profileCatalog(group: group.id)
        let a = try XCTUnwrap(previous.first { $0.remarks == "A" })
        try await store.recordLatency(37, for: a)
        let db = try RuntimeDatabase(url: dir.appendingPathComponent("guiConfigs/guiNDB.db"), writable: true)
        _ = try db.query("INSERT INTO ServerStatItem(IndexId,TotalDown) VALUES (?,12345)", [.text(a.id)])
        var settings = try await store.readSettings()
        settings["IndexId"] = .string(a.id)
        try await store.writeSettings(settings)
        let current = try await store.subscriptions()
        try await store.replaceSubscription(XCTUnwrap(current.first), rows: ShareLinkImport.decode("socks://u:c@proxy.example:1080#C\n" + feed), serving: a.id)
        let refreshed = try await store.profileCatalog(group: group.id)
        XCTAssertEqual(refreshed.count, 3)
        for old in previous { XCTAssertEqual(refreshed.first { $0.remarks == old.remarks }?.id, old.id) }
        let selected = try XCTUnwrap(refreshed.first { $0.isCurrent })
        XCTAssertEqual(selected.remarks, "A")
        XCTAssertEqual(selected.delay, 37)
        let c = try XCTUnwrap(refreshed.first { $0.remarks == "C" })
        XCTAssertTrue(previous.allSatisfy { $0.id != c.id })
        XCTAssertEqual(c.delay, 0)
        let counts = try db.query("SELECT p.Remarks, s.TotalDown FROM ServerStatItem s JOIN ProfileItem p ON p.IndexId=s.IndexId")
        XCTAssertEqual(counts, [["Remarks": .text("A"), "TotalDown": .integer(12345)]])
    }

    func testRefreshCarriesIdentityAndStatsAndRejectsStaleOrInvalidBatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NativeConfigurationStore(dataDirectory: dir)
        try await store.initializeRuntimeStore()
        let input: SettingsValue = .object(["remarks": .string("Group"), "url": .string("http://127.0.0.1/feed")])
        let group = try await store.saveSubscription(input, id: nil)
        let source = "socks://u:secret%3Aone@127.0.0.1:40201#First\nsocks://127.0.0.1:40202#Second"
        let rows = try ShareLinkImport.decode(Data(source.utf8).base64EncodedString())
        try await store.replaceSubscription(group, rows: rows, serving: nil)
        let saved = try await store.profileCatalog(group: group.id)
        let first = try XCTUnwrap(saved.first)
        let second = try XCTUnwrap(saved.last)
        XCTAssertEqual(saved.count, 2)
        try await store.recordLatency(37, for: first)
        var settings = try await store.readSettings()
        settings["IndexId"] = .string(second.id)
        try await store.writeSettings(settings)

        let list = try await store.subscriptions()
        let current = try XCTUnwrap(list.first)
        XCTAssertGreaterThan(current.updateTime, 0)
        let updated = try ShareLinkImport.decode("socks://u:changed@127.0.0.1:40201#First")
        try await store.replaceSubscription(current, rows: updated, serving: nil)
        let refreshed = try await store.profileCatalog(group: group.id)
        XCTAssertEqual(refreshed.map(\.id), saved.map(\.id))
        XCTAssertEqual(refreshed.first?.delay, 37)
        XCTAssertTrue(refreshed.last?.isCurrent == true)
        let changed = try await store.profileDocument(id: first.id)
        XCTAssertEqual(changed["password"].text, "changed")

        var bad = try XCTUnwrap(updated.first)
        bad["Port"] = .integer(-1)
        let latest = try await store.subscriptions()
        do {
            try await store.replaceSubscription(try XCTUnwrap(latest.first), rows: rows + [bad], serving: nil)
            XCTFail("Invalid node must roll back earlier writes in the same refresh")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "profile_validation_failed") }
        let retained = try await store.profileDocument(id: first.id)
        XCTAssertEqual(retained, changed)
        do {
            try await store.replaceSubscription(group, rows: rows, serving: nil)
            XCTFail("Stale download must not overwrite newer subscription state")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "subscription_edit_conflict") }
    }
}

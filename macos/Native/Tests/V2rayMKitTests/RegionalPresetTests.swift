import XCTest
@testable import V2rayMKit

final class RegionalPresetTests: XCTestCase {
    func testDefaultRegionKeepsLockedRouteAndTemplateVersionEndsAtDelimiter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let added = try await store.saveRoute(.object(["remarks": .string("V10-personal"),
            "locked": .bool(true), "ruleSet": .string("[]")]))
        _ = try await store.selectRoute(added["routingId"].text, delete: false)
        let before = try await store.regionSnapshot()
        let source = try RegionalSources.standard("default")
        let stager = try await store.presetStager(proxyEndpoints: nil)
        let dns = try await stager.dns(region: "default", sources: source, existing: before.dns)
        let reset = try await stager.routes(source: source.routingTemplate, base: before, explicitImport: false)
        try await store.applyRegion(sources: source, dns: dns, routes: reset)
        let after = try await store.regionSnapshot()
        XCTAssertEqual(after.routes, before.routes)
        for (version, expected) in [("V1", ["V1-fixture"]), ("V10", [])] {
            let template = NativeRegionalPreset(fetch: { _ in
                #"{ "Version": "\#(version)", "RoutingItems": [{"Remarks":"fixture", "RuleSet":"[]"}] }"#
            }, builtins: [], defaultDNS: .null)
            let plan = try await template.routes(source: "template", base: after, explicitImport: false)
            XCTAssertEqual(plan.additions.map { $0["remarks"].text }, expected)
        }
    }

    func testTemplateFallbackAndExplicitImportSemantics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        let before = try await store.regionSnapshot()
        let builtin = try await store.presetStager(proxyEndpoints: nil)
        let stager = NativeRegionalPreset(fetch: { _ in throw ClientFailure("fixture_http_failure") },
                                          builtins: builtin.builtins, defaultDNS: builtin.defaultDNS)
        let source = try RegionalSources.standard("iran")
        let fallback = try await stager.dns(region: "iran", sources: source, existing: before.dns)
        XCTAssertTrue(fallback.profile["enabled"].flag)
        XCTAssertEqual(fallback.simple, builtin.defaultDNS)
        let unchanged = try await stager.routes(source: source.routingTemplate, base: before, explicitImport: false)
        XCTAssertTrue(unchanged.additions.isEmpty)
        let appended = try await stager.routes(source: source.routingTemplate, base: before, explicitImport: true)
        try await store.importRoutes(appended)
        let current = try await store.regionSnapshot()
        XCTAssertEqual(current.routes.count, before.routes.count + 3)
        XCTAssertEqual(current.routes.first { $0["isActive"].flag }, before.routes.first { $0["isActive"].flag })
        let duplicate = NativeRegionalPreset(fetch: { _ in #"{"Version":"V4","RoutingItems":[{"Remark":"fixture","RuleSet":"[]"}]}"# },
                                            builtins: [], defaultDNS: builtin.defaultDNS)
        let noChange = try await duplicate.routes(source: source.routingTemplate, base: current, explicitImport: false)
        XCTAssertTrue(noChange.additions.isEmpty)
        let reset = try await stager.dns(region: "default", sources: try RegionalSources.standard("default"), existing: current.dns)
        XCTAssertEqual(reset.profile["enabled"], .bool(false))
    }

    func testInterruptedRegionRestoresBothTablesAndPreviousGeoGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let geo = NativeGeoAssets(dataDirectory: root, bundled: root)
        let store = NativeConfigurationStore(dataDirectory: root)
        try await store.initializeRuntimeStore()
        func candidate() throws -> URL {
            let dir = try geo.newGeneration()
            for name in NativeGeoAssets.names { try Data([10,3,10,1,65]).write(to: dir.appendingPathComponent(name + ".dat")) }
            return dir
        }
        let old = try candidate()
        try geo.commit(old)
        let before = try await store.regionSnapshot()
        try await store.beginEdit(table: .routes, regional: RegionalRecovery(generation: old.lastPathComponent, runningNode: "archived-node"))
        try await store.applyRegion(sources: RegionalSources.standard("iran"), dns: (.object([:]), .object(["enabled": .bool(true)])),
                                    routes: RegionalRoutingPlan(additions: [.object(["remarks": .string("new")])], useFirst: true))
        try geo.commit(candidate())
        let reopened = NativeConfigurationStore(dataDirectory: root)
        let resume = try await reopened.interruptedRegionalNode()
        XCTAssertEqual(resume, "archived-node")
        try await reopened.initializeRuntimeStore(keepRecoveryJournal: true)
        let after = try await reopened.regionSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try geo.currentGeneration(), old.lastPathComponent)
        try await reopened.finishEdit()
        let cleared = try await reopened.interruptedRegionalNode()
        XCTAssertNil(cleared)
    }
}

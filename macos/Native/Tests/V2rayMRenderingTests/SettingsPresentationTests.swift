import XCTest
import SwiftUI
import AppKit
import V2rayMKit
@testable import V2rayM

@MainActor final class SettingsPresentationTests: XCTestCase {
    func testSubmittedLineArraysExcludeBlankRowsWithoutChangingDraft() throws {
        let values: SettingsValue = .array([.string("one"), .string(""), .string("two"), .string("")])
        let clean: SettingsValue = .array([.string("one"), .string("two")])
        var parameters = ParameterSettingsDraft()
        parameters.settings["core"]["fragmentLengths"] = values
        parameters.tunSettings["routeExcludeAddress"] = values
        XCTAssertEqual(parameters.submission["core"]["fragmentLengths"], clean)
        XCTAssertEqual(parameters.submission["nativeTun"]["routeExcludeAddress"], clean)
        XCTAssertEqual(parameters.tunSettings["routeExcludeAddress"], values)
        var route = RoutingSettingsDraft()
        route.rules = [.object(["domain":values, "unknown":values])]
        let submitted = route.submission()["ruleSet"].items.first
        XCTAssertEqual(submitted?["domain"], clean)
        XCTAssertEqual(submitted?["unknown"], values)
    }

    func testPresetRefreshCommitsSelectedIdentityOnlyAfterAllReadsSucceed() async throws {
        let old: SettingsValue = .object(["id": .string("old")])
        let new: SettingsValue = .object(["id": .string("new"), "isActive": .bool(true)])
        var draft = RoutingSettingsDraft(routes: [old], route: old, routeID: "old")
        do {
            draft = try await draft.refreshing(routes: [old, new], preferActive: true) { _ in throw ClientFailure("read_failed") }
            XCTFail("Expected read failure")
        } catch { }
        XCTAssertEqual(draft.routes, [old])
        XCTAssertEqual(draft.routeID, "old")
        XCTAssertEqual(draft.savedID, draft.routeID)
        draft = try await draft.refreshing(routes: [old, new], preferActive: true) { id in
            XCTAssertEqual(id, "new"); return [.string("new rule")]
        }
        XCTAssertEqual(draft.routeID, "new")
        XCTAssertEqual(draft.rules, [.string("new rule")])
    }

    func testImportRetainsInputOnFailureAndAllowsRetry() async {
        let draft = ImportDraft()
        XCTAssertTrue(draft.requestClose(home: true))
        XCTAssertTrue(draft.returningHome)
        draft.content = "original input"
        XCTAssertFalse(draft.requestClose(home: true))
        XCTAssertTrue(draft.discard)
        draft.discard = false
        XCTAssertFalse(draft.requestClose(home: false))
        XCTAssertFalse(draft.returningHome)
        draft.discard = false
        let failed = await draft.submit { _ in throw ClientFailure("invalid_profile") }
        XCTAssertFalse(failed)
        XCTAssertEqual(draft.content, "original input")
        XCTAssertNotNil(draft.error)
        XCTAssertFalse(draft.saving)
        let succeeded = await draft.submit { content in XCTAssertEqual(content, "original input") }
        XCTAssertTrue(succeeded)
        XCTAssertNil(draft.error)
    }

    func testNodeRowDescribesLatencyAndCurrentStatusIndependentlyOfSelection() throws {
        let data = Data(#"{"indexId":"one","remarks":"Fixture","protocol":"socks","address":"127.0.0.1","port":1080,"network":"raw","coreType":"xray","delay":0,"isCurrent":false,"canTest":true}"#.utf8)
        var profile = try JSONDecoder().decode(Profile.self, from: data)
        for address in ["2001:db8::1", "[2001:db8::1]"] {
            profile.address = address
            let row = RealityProfileRow(profile: profile, selected: false, action: {})
            XCTAssertTrue(row.accessibilitySummary.contains("服务器 [2001:db8::1]:1080"))
        }
        profile.address = "127.0.0.1"
        for (value, label) in [(-1, "失败"), (0, "未测"), (71, "71 ms")] {
            profile.delay = value
            for current in [true, false] {
                profile.isCurrent = current
                let row = RealityProfileRow(profile: profile, selected: !current, action: {})
                XCTAssertEqual(RealityProfileRow.delayLabel(value), label)
                XCTAssertTrue(row.accessibilitySummary.contains("延迟 " + label))
                XCTAssertEqual(row.accessibilitySummary.contains("当前节点"), current)
            }
        }
    }

    func testImportCannotSubmitTwiceWhilePending() async {
        let draft = ImportDraft()
        draft.content = "test"
        var continuation: CheckedContinuation<Void, Never>?
        let first = Task { await draft.submit { _ in await withCheckedContinuation { continuation = $0 } } }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(draft.saving)
        XCTAssertFalse(draft.requestClose(home: true))
        XCTAssertFalse(draft.discard)
        let second = await draft.submit { _ in XCTFail("Duplicate submit") }
        XCTAssertFalse(second)
        continuation?.resume()
        let done = await first.value
        XCTAssertTrue(done)
    }

    func testCreateAcknowledgementSurvivesFailedReadAndNextSaveUpdatesSameIdentity() async throws {
        var draft = RoutingSettingsDraft()
        draft.route = .object(["remarks": .string("New route")])
        draft.rules = [.object(["id": .string("rule")])]
        XCTAssertNil(draft.savedID)
        draft.acceptSaved("created-id")
        do {
            draft = try await draft.selecting(draft.route) { _ in throw ClientFailure("read_failed") }
            XCTFail("Expected refresh failure")
        } catch { }
        XCTAssertEqual(draft.savedID, "created-id")
        XCTAssertEqual(draft.rules.first?["id"].text, "rule")
    }

    func testFailedRouteReadPreservesPreviouslyEditableDocument() async throws {
        var draft = RoutingSettingsDraft()
        draft.routeID = "previous"
        draft.route = .object(["id": .string("previous"), "remarks": .string("Original")])
        draft.rules = [.object(["remarks": .string("Keep this rule")])]
        let original = draft
        let selected = SettingsValue.object(["id": .string("next"), "remarks": .string("Next")])
        do {
            draft = try await draft.selecting(selected) { _ in throw ClientFailure("read_failed") }
            XCTFail("Expected read failure")
        } catch { }
        XCTAssertEqual(draft.routeID, original.routeID)
        XCTAssertEqual(draft.route, original.route)
        XCTAssertEqual(draft.rules, original.rules)
        draft = try await draft.selecting(selected) { id in
            XCTAssertEqual(id, "next")
            return [.object(["remarks": .string("New rule")])]
        }
        XCTAssertEqual(draft.routeID, "next")
        XCTAssertEqual(draft.rules.first?["remarks"].text, "New rule")
    }

    func testSettingsLayoutSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["V2RAYM_SETTINGS_RENDER_DIRECTORY"] else {
            throw XCTSkip("Set V2RAYM_SETTINGS_RENDER_DIRECTORY to inspect settings layouts")
        }
        AppFont.register()
        let model = AppModel(dataDirectory: URL(fileURLWithPath: "/tmp/v2raym-ui-fixture"))
        model.ready = true
        try await render(ImportPane(homeRequest: 0, goHome: {}, close: {}, save: { _ in }).environmentObject(model),
            name: "import", height: 568, directory: directory)
        model.routes = try JSONDecoder().decode([RoutingProfile].self, from: Data("""
            [{"id":"one","remarks":"绕过大陆","isActive":true},{"id":"two","remarks":"全局代理","isActive":false}]
            """.utf8))
        model.status = try JSONDecoder().decode(RuntimeStatus.self, from: Data("""
            {"coreRunning":false,"xrayAvailable":true,"runtimeState":"stopped","configuredProxyPort":10808}
            """.utf8))
        let settings = try SettingsValue.parse("""
            {"inbound":{"localPort":10808,"udpEnabled":true,"sniffingEnabled":true,"destOverride":["http","tls"]},
             "core":{"logEnabled":true,"loglevel":"warning","defFingerprint":"chrome","mux4RayConcurrency":8},
             "application":{"enableStatistics":true,"displayRealTimeSpeed":true,"geoAutoUpdateInterval":24},
             "speedTest":{"speedTestTimeout":10,"mixedConcurrencyCount":4},"domainStrategy":"AsIs"}
            """)
        let tun = try SettingsValue.parse("""
            {"mtu":1500,"enableIPv6Address":true,"routeExcludeAddress":["192.168.0.0/16"]}
            """)
        try await render(SettingsPage(navigationLocked: .constant(false)).environmentObject(model),
            name: "settings", height: 568, directory: directory)
        try await render(SettingsPage(navigationLocked: .constant(false)).environmentObject(model),
            name: "settings-full", height: 900, directory: directory)
        for group in ["监听与嗅探", "Xray 参数", "应用与测速", "原生 TUN"] {
            try await render(ParameterSettingsFields(settings: .constant(settings), tunSettings: .constant(tun),
                dirty: .constant(false), parameterGroup: group).environmentObject(model).padding(16),
                name: "parameters-\(group)", height: group == "Xray 参数" ? 900 : 568, directory: directory)
        }
        try await render(DNSSettingsFields(simpleDNS: .constant(try SettingsValue.parse("""
            {"directDNS":"https://dns.example/dns-query","remoteDNS":"1.1.1.1","bootstrapDNS":"223.5.5.5","useSystemHosts":true}
            """)), dns: .constant(.object(["enabled": .bool(false)])), dirty: .constant(false), saveSimple: {}, saveCustom: {}).padding(16),
            name: "dns", height: 1500, directory: directory)
        let route = try SettingsValue.parse("""
            {"id":"one","remarks":"绕过大陆","isActive":true,"domainStrategy":"AsIs"}
            """)
        let rule = try SettingsValue.parse("""
            {"remarks":"直连局域网","enabled":true,"outboundTag":"direct","ip":["geoip:private"]}
            """)
        try await render(RoutingSettingsFields(routes: [route], profiles: [], route: .constant(route), rules: .constant([rule]),
            routeID: .constant("one"), ruleIndex: .constant(0), dirty: .constant(false), select: { _ in }, create: {}, delete: {}, activate: {}, importRoutes: {}, applyPreset: { _ in }).padding(16),
            name: "routing", height: 1100, directory: directory)
    }

    private func render<V: View>(_ view: V, name: String, height: CGFloat, directory: String) async throws {
        let host = NSHostingView(rootView: RealityWindow {
            view.font(AppFont.body).buttonStyle(HoverButtonStyle())
                .frame(width: 860, height: height, alignment: .top)
        }.environment(\.colorScheme, .dark).environment(\.dashboardVisibilityOverride, true))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 860, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber),
            URL(fileURLWithPath: directory).appendingPathComponent(name + ".png").path]
        try capture.run(); capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }
}

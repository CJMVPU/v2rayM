import XCTest
@testable import V2rayMKit

private final class MemoryPreferences: ProxyPreferencesStore {
    var values: [ProxyService] = [ProxyService(id: "wifi", configuration: [
        "HTTPEnable": 1, "HTTPProxy": "previous.proxy", "HTTPPort": 8080,
        "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.invalid/proxy.pac",
        "UnmanagedField": "keep-me"])]
    var failApply = false
    var applyCount = 0
    var disabled = Set<String>()
    func services() throws -> [ProxyService] { values.filter { !disabled.contains($0.id) } }
    func recoveryServices() throws -> [ProxyService] { values }
    func apply(_ services: [ProxyService]) throws {
        applyCount += 1
        if failApply { throw ClientFailure("proxy_configuration") }
        for service in services {
            if let index = values.firstIndex(where: { $0.id == service.id }) { values[index] = service }
        }
    }
}
final class ProxyRecoveryTests: XCTestCase {
    func testActiveJournalIsNotAnOrphanButARecreatedControllerRequiresRecovery() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences()
        let active = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await active.enable(port: 10808)
        let enabled = await active.isEnabled, needsRecovery = await active.needsRecovery
        XCTAssertTrue(enabled); XCTAssertFalse(needsRecovery)
        do { try await active.enable(port: 10809); XCTFail("Must not overwrite the original journal") }
        catch { XCTAssertEqual((error as? ClientFailure)?.code, "proxy_recovery") }
        let recreated = SystemProxyController(dataDirectory: directory, makeStore: { store })
        let pending = await recreated.needsRecovery, recreatedEnabled = await recreated.isEnabled
        XCTAssertTrue(pending); XCTAssertFalse(recreatedEnabled)
        _ = try await recreated.restore()
        XCTAssertEqual(store.values[0].configuration["HTTPProxy"] as? String, "previous.proxy")
    }
    func testPortRebindKeepsTheOriginalBaselineAndDoesNotWriteForUnchangedPorts() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences(), original = store.values[0].configuration
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        try await controller.rebind(port: 10808)
        XCTAssertEqual(store.applyCount, 1)
        try await controller.rebind(port: 10809)
        for prefix in ["HTTP", "HTTPS", "SOCKS"] {
            XCTAssertEqual(store.values[0].configuration[prefix + "Port"] as? Int, 10809)
        }
        let pending = await controller.needsRecovery
        XCTAssertFalse(pending)
        _ = try await controller.restore()
        XCTAssertTrue(NSDictionary(dictionary: store.values[0].configuration).isEqual(to: original))
    }
    func testRebindDoesNotOverwriteAnotherAppsProxy() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences()
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        store.values[0].configuration["HTTPProxy"] = "another-app.proxy"
        do { try await controller.rebind(port: 10809); XCTFail("External ownership must stop rebinding") }
        catch { XCTAssertEqual((error as? ClientFailure)?.code, "proxy_changed") }
        XCTAssertEqual(store.values[0].configuration["HTTPProxy"] as? String, "another-app.proxy")
        XCTAssertNil(store.values[0].configuration["SOCKSEnable"])
        let enabled = await controller.isEnabled
        XCTAssertFalse(enabled)
    }
    func testFailedRebindRetainsJournalAndExposesRecovery() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences()
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        store.failApply = true
        do { try await controller.rebind(port: 10809); XCTFail("Expected failed restore") } catch {}
        let pending = await controller.needsRecovery, enabled = await controller.isEnabled
        XCTAssertTrue(pending); XCTAssertFalse(enabled)
        store.failApply = false
        _ = try await controller.restore()
        XCTAssertEqual(store.values[0].configuration["HTTPProxy"] as? String, "previous.proxy")
    }
    func testEnableThenRestorePreservesPreviousProxyPACAndUnmanagedFields() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences(); let original = store.values[0].configuration
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        XCTAssertEqual(store.values[0].configuration["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(store.values[0].configuration["SOCKSPort"] as? Int, 10808)
        XCTAssertEqual(store.values[0].configuration["ProxyAutoConfigEnable"] as? Int, 0)
        XCTAssertEqual(store.values[0].configuration["UnmanagedField"] as? String, "keep-me")
        let journal = directory.appendingPathComponent("native-proxy-recovery.plist")
        let permissions = try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let changed = try await controller.restore()
        XCTAssertFalse(changed)
        XCTAssertTrue(NSDictionary(dictionary: store.values[0].configuration).isEqual(to: original))
        let pending = await controller.needsRecovery; XCTAssertFalse(pending)
    }
    func testRecoverySurvivesControllerRecreationAndDoesNotEraseAnotherApp() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences()
        let first = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await first.enable(port: 10808)
        store.values[0].configuration["HTTPProxy"] = "another-app.proxy"
        let second = SystemProxyController(dataDirectory: directory, makeStore: { store })
        let changed = try await second.restore()
        XCTAssertTrue(changed)
        XCTAssertEqual(store.values[0].configuration["HTTPProxy"] as? String, "another-app.proxy")
        XCTAssertNil(store.values[0].configuration["SOCKSEnable"], "Restore our SOCKS settings even when another app changes HTTP")
    }
    func testFailedApplyRetainsRecoveryAndRejectsSecondEnable() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences(); store.failApply = true
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        do { try await controller.enable(port: 10808); XCTFail("Expected a failure") } catch {}
        let pending = await controller.needsRecovery; XCTAssertTrue(pending)
        do { try await controller.enable(port: 10809); XCTFail("Expected recovery gate") }
        catch { XCTAssertEqual((error as? ClientFailure)?.code, "proxy_recovery") }
        store.failApply = false
        _ = try await controller.restore()
        let remaining = await controller.needsRecovery; XCTAssertFalse(remaining)
    }
    func testFailedRestoreKeepsJournalForRetry() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences(); let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        store.failApply = true
        do { _ = try await controller.restore(); XCTFail("Expected failure") } catch {}
        let pending = await controller.needsRecovery; XCTAssertTrue(pending)
        store.failApply = false; _ = try await controller.restore()
        XCTAssertEqual(store.values[0].configuration["HTTPProxy"] as? String, "previous.proxy")
    }
    func testRestoringOneServicePreservesAnotherServicesLaterSettings() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences()
        store.values.append(ProxyService(id: "ethernet", configuration: ["HTTPEnable": 0]))
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        store.values[1].configuration["HTTPPort"] = 9999
        let changed = try await controller.restore()
        XCTAssertTrue(changed)
        XCTAssertEqual(store.values[0].configuration["HTTPProxy"] as? String, "previous.proxy")
        XCTAssertEqual(store.values[1].configuration["HTTPPort"] as? Int, 9999)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testDisabledServiceIsRestoredWithoutBlockingOtherServices() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences()
        store.values.append(ProxyService(id: "ethernet", configuration: ["HTTPEnable": 0]))
        let original = store.values
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        store.disabled.insert("wifi")
        _ = try await controller.restore()
        for (actual, expected) in zip(store.values, original) {
            XCTAssertTrue(NSDictionary(dictionary: actual.configuration).isEqual(to: expected.configuration))
        }
        let pending = await controller.needsRecovery; XCTAssertFalse(pending)
    }

    func testDeletedServiceDoesNotTrapRecoveryJournal() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryPreferences()
        store.values.append(ProxyService(id: "ethernet", configuration: ["HTTPEnable": 0]))
        let controller = SystemProxyController(dataDirectory: directory, makeStore: { store })
        try await controller.enable(port: 10808)
        store.values.removeAll { $0.id == "wifi" }
        _ = try await controller.restore()
        XCTAssertEqual(store.values[0].configuration["HTTPEnable"] as? Int, 0)
        let pending = await controller.needsRecovery; XCTAssertFalse(pending)
    }
}

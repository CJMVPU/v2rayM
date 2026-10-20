import XCTest
@testable import TunShared

final class LaunchPolicyTests: XCTestCase {
    var temporary: URL!
    var bundle: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        bundle = temporary.appendingPathComponent("V2rayM.app")
        let core = bundle.appendingPathComponent("Contents/Resources/Backend/bin/sing_box")
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try Data("test-fixture-never-executed".utf8).write(to: core.appendingPathComponent("sing-box"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }
    func policy(validate: @escaping (URL, String) throws -> Void = { _, _ in }) -> LaunchPolicy {
        LaunchPolicy(bundle: bundle, stateRoot: temporary.appendingPathComponent("state"), validate: validate)
    }
    func request(extra: [String: Any] = [:]) throws -> HelperRequest {
        var object: [String: Any] = ["inbounds": [["type": "tun"]], "outbounds": [["type": "direct"]]]
        for (key, value) in extra { object[key] = value }
        var request = HelperRequest(action: "start"); request.core = "sing_box"
        request.config = try JSONSerialization.data(withJSONObject: object)
        return request
    }
    func testPrivateCopyIsVerifiedAndArbitraryLogFileIsRemoved() throws {
        var validated: URL?
        let result = try policy { validated = $0; XCTAssertEqual($1, "sing_box") }
            .prepare(request(extra: ["log": ["output": "/etc/privileged-file"]]))
        XCTAssertEqual(validated, result.executable)
        XCTAssertTrue(result.executable.path.hasPrefix(temporary.appendingPathComponent("state").path + "/"))
        let output = try JSONSerialization.jsonObject(with: Data(contentsOf: result.directory.appendingPathComponent("config.json"))) as! [String: Any]
        XCTAssertNil((output["log"] as? [String: Any])?["output"])
        XCTAssertFalse(result.environment.keys.contains(where: { $0.hasPrefix("DYLD_") }))
    }
    func testUnknownCoreCannotSupplyAnExecutablePath() throws {
        var input = try request(); input.core = "/bin/sh"
        XCTAssertThrowsError(try policy().prepare(input))
    }
    func testRegularProxyConfigurationCannotAcquireRoot() throws {
        var input = try request(); input.config = Data("{\"inbounds\":[{\"type\":\"mixed\"}]}".utf8)
        XCTAssertThrowsError(try policy().prepare(input))
    }
    func testUnsignedCoreIsRejectedAndStagingIsRemoved() throws {
        XCTAssertThrowsError(try policy { _, _ in throw HelperFailure("core_signature_invalid") }.prepare(request()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.appendingPathComponent("state").path), [])
    }
    func testResourcesCannotEscapePrivateStaging() throws {
        var input = try request(); input.resources = ["../escape.srs": Data([0])]
        XCTAssertThrowsError(try policy().prepare(input))
    }
    func testLocalFilesMustBeProvidedAsSnapshots() throws {
        let input = try request(extra: ["tls": ["key_path": "/etc/ssh/ssh_host_ed25519_key"]])
        XCTAssertThrowsError(try policy().prepare(input))
    }
    func testLocalRuleSnapshotIsRewrittenButWebsocketPathIsPreserved() throws {
        var input = try request(extra: [
            "route": ["rule_set": [["type": "local", "path": "/user/rules.srs"]]],
            "transport": ["type": "ws", "path": "/websocket"]])
        input.resources = ["rules.srs": Data([1, 2, 3])]; input.paths = ["/user/rules.srs": "rules.srs"]
        let result = try policy().prepare(input)
        let output = try JSONSerialization.jsonObject(with: Data(contentsOf: result.directory.appendingPathComponent("config.json"))) as! [String: Any]
        let route = output["route"] as! [String: Any]
        let rules = route["rule_set"] as! [[String: Any]]
        XCTAssertEqual(rules[0]["path"] as? String, result.directory.appendingPathComponent("rules.srs").path)
        XCTAssertEqual((output["transport"] as! [String: Any])["path"] as? String, "/websocket")
    }
    func testSymlinkedStateDirectoryIsRejected() throws {
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("state"), withDestinationURL: temporary)
        XCTAssertThrowsError(try policy().prepare(request()))
    }

    func testXrayWebsocketPathsRemainTransportSettings() throws {
        let directory = bundle.appendingPathComponent("Contents/Resources/Backend/bin/xray")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: directory.appendingPathComponent("xray"))
        var input = HelperRequest(action: "start"); input.core = "xray"
        input.config = try JSONSerialization.data(withJSONObject: [
            "inbounds": [["protocol": "tun"]],
            "streamSettings": ["wsSettings": ["path": "/proxy"], "xhttpSettings": ["path": "/xhttp"]]])
        let prepared = try policy().prepare(input)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: prepared.directory.appendingPathComponent("config.json"))) as! [String: Any]
        let stream = object["streamSettings"] as! [String: Any]
        XCTAssertEqual((stream["wsSettings"] as! [String: Any])["path"] as? String, "/proxy")
        XCTAssertEqual((stream["xhttpSettings"] as! [String: Any])["path"] as? String, "/xhttp")
    }
}

import Foundation
import V2rayMKit

extension NativeCheck {
    static func serveHostFixture(data: URL, node: String, bundle: URL) async throws {
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw ClientFailure("check_failed", label) }
        }
        let host = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false)
        try await host.start()
        do {
            let other = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false)
            do {
                _ = try await other.startClient()
                throw ClientFailure("fixture_data_lock_missing")
            } catch let error as ClientFailure where error.code == "runtime_data_in_use" {}

            let tunnel = try await host.tunStatus(.normal)
            try expect(!tunnel.enabled, "Loopback fixture requires TUN disabled")
            try await host.selectProfile(node, connect: false)
            try await host.startCore()
            let original = try await host.profileDocument(id: node)
            var edited = original
            edited["remarks"] = .string(original["remarks"].text + " fixture edit")
            try await host.saveProfile(id: node, original: original, edited: edited)
            var invalid = edited
            invalid["streamSecurity"] = .string("invalid-fixture-value")
            do {
                try await host.saveProfile(id: node, original: edited, edited: invalid)
                throw ClientFailure("fixture_invalid_edit_accepted")
            } catch let error as ClientFailure where error.code == "stream_security_unsupported" {}
            let restored = try await host.profileDocument(id: node)
            try expect(restored == edited, "Failed active edit restores the stored node")
            let state: RuntimeStatus = try await host.runtimeStatus()
            try expect(state.runningProfileId == node && state.runningProfileName == edited["remarks"].text,
                        "Restored process is serving the edited node")
            guard state.coreProcessIds?.count == 1, let pid = state.coreProcessIds?.first else { throw ClientFailure("fixture_core_pid_missing") }
            FileHandle.standardOutput.write(Data("\(pid)\n".utf8))
            guard var session = state.coreSessionID else { throw ClientFailure("fixture_core_session_missing") }
            while let command = readLine() {
                switch command {
                case "start": try await host.startCore()
                case "restart": try await host.restartCore()
                default: throw ClientFailure("fixture_unknown_command")
                }
                let current = try await host.runtimeStatus()
                try expect(current.coreRunning && current.runningProfileId == node, "Same node serves after core command")
                guard let next = current.coreSessionID else { throw ClientFailure("fixture_core_session_missing") }
                try expect((next == session) == (command == "start"),
                           "Repeated start preserves the session and restart replaces it")
                session = next
                FileHandle.standardOutput.write(Data("\(command) ok\n".utf8))
            }
            try await host.stop()
            let reopened = try await other.startClient()
            do {
                let persisted = try await reopened.profileDocument(id: node)
                let status: RuntimeStatus = try await reopened.runtimeStatus()
                try expect(persisted == edited && status.currentProfileId == node && !status.coreRunning,
                            "Reopen retains selection and edit after graceful shutdown")
                try await other.stop()
            } catch { try await other.stop(); throw error }
        } catch { try await host.stop(); throw error }
    }
}

extension NativeCheck {
    static func checkCustomFixture(bundle: URL, data: URL, target: Int, inbound: Int) async throws {
        let host = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false)
        try await host.start()
        func testSelected(_ action: NativeSpeedAction, _ ids: [String]) async throws {
            try await host.testProfiles(ids, action: action)
            for _ in 0..<100 {
                let pending = try await host.activeOperations()
                if !pending.contains("speedtest") { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ClientFailure("fixture_diagnostic_timeout")
        }
        do {
            try await testSelected(.realping, ["probe-good"])
            let idle: RuntimeStatus = try await host.runtimeStatus()
            let measured: [ProfileObservation] = try await host.profileObservations()
            try require(!idle.coreRunning && measured.contains { $0.indexId == "probe-good" && $0.delay > 0 },
                        "Offline probe forwards through its selected node without starting a serving session")
            try await host.selectProfile("custom", connect: false)
            try await host.startCore()
            let state: RuntimeStatus = try await host.runtimeStatus()
            guard state.coreProcessIds == [getpid()],
                  state.runningProxyPort == inbound else { throw ClientFailure("custom_embedded_session_missing") }
            try await testSelected(.mixedtest, ["probe-good", "probe-bad"])
            let policies = ["leastping", "fallback", "random", "rr", "leastload"].map { "group-" + $0 }
            try await testSelected(.fastrealping, policies)
            let profiles: [Profile] = try await host.profiles(group: "", search: "least|random|rr|fallback")
            try require(Set(profiles.map(\.id)) == Set(policies) && profiles.allSatisfy { $0.delay > 0 && $0.ipInfo == "🇯🇵(JP) 192.0.2.7" },
                        "Five group policies probe through their own members and record exit IP via the selected group")
            let during: RuntimeStatus = try await host.runtimeStatus()
            try require(during.coreProcessIds == [getpid()] && during.coreSessionID == state.coreSessionID,
                        "Mixed diagnostics keep the serving node and embedded session alive")
            for domain in ["native-check.invalid", "legacy-custom.invalid"] {
                let request = Process(), response = Pipe()
                request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                request.arguments = ["--fail", "--silent", "--max-time", "8", "--noproxy", "", "--proxy",
                                     "http://127.0.0.1:\(inbound)", "http://\(domain):\(target)/traffic"]
                request.standardOutput = response
                try request.run()
                let bytes = response.fileHandleForReading.readDataToEndOfFile()
                request.waitUntilExit()
                try require(request.terminationStatus == 0 && String(decoding: bytes, as: UTF8.self) == "v2rayM-local-traffic-ok",
                            "Legacy pre-SOCKS forwards \(domain) using the custom graph's routes and DNS")
            }
            let tail: LogTail = try await host.logTail(after: 0, limit: 10000)
            for domain in ["native-check.invalid", "legacy-custom.invalid"] {
                try require(tail.items.contains { $0.message.contains(" accepted ") && $0.message.contains(domain) },
                            "The native log console receives the access record for \(domain)")
            }
            try await host.stopCore()
            let after: RuntimeStatus = try await host.runtimeStatus()
            try require(!after.coreRunning && after.coreProcessIds?.isEmpty == true, "Stopping releases both listener sets")
            try await host.startCore()
            let again: RuntimeStatus = try await host.runtimeStatus()
            try require(again.coreProcessIds == [getpid()] && again.coreSessionID != state.coreSessionID,
                        "Both re-opened listeners share the host PID")
            try await host.stop()
        } catch { try await host.stop(); throw error }
    }
}

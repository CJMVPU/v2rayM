import XCTest
import SwiftUI
import AppKit
import V2rayMKit
@testable import V2rayM

@MainActor final class UpdateLayoutTests: XCTestCase {
    func testUpdateStatesKeepPanelAndFollowingCardInPlace() throws {
        AppFont.register()
        let states: [(String, String?, Bool, String?)] = [
            ("idle", nil, false, nil),
            ("queued", nil, true, nil),
            ("checking", "\"phase\":\"checking\"", true, nil),
            ("downloading", "\"phase\":\"downloading\",\"downloadedBytes\":50,\"totalBytes\":100,\"version\":\"v26.11.9\"", true, nil),
            ("unknown-length", "\"phase\":\"downloading\",\"downloadedBytes\":50", true, nil),
            ("completed", "\"phase\":\"completed\",\"isComplete\":true,\"success\":true,\"version\":\"v26.11.9\",\"detail\":\"已安装同版本修复版，无需更新\"", false, nil),
            ("failed", "\"phase\":\"failed\",\"isComplete\":true,\"detail\":\"下载失败：请检查连接。详细说明包含多行内容。\\n旧版本仍可继续使用。\"", false, nil),
            ("validation", "\"phase\":\"awaiting-validation\",\"isComplete\":true,\"version\":\"v26.11.10-preview-long-version\"", false, nil),
            ("service-error", nil, false, String(repeating: "后台恢复失败，请检查连接。", count: 15))
        ]
        var reference: CGFloat?
        for (name, fields, active, error) in states {
            let model = AppModel(dataDirectory: URL(fileURLWithPath: "/tmp/v2raym-layout-fixture"))
            model.ready = true
            model.moduleUpdateActive = active
            model.moduleScope = active ? .all : nil
            model.moduleUpdateError = error
            if let fields {
                var object: [String: Any] = ["coreType": "Xray", "phase": "checking", "isComplete": false, "success": false, "batch": false]
                let overrides = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\(fields)}".utf8)) as? [String: Any])
                object.merge(overrides) { _, new in new }
                model.moduleObservation.progress = [try JSONDecoder().decode(ModuleUpdateProgress.self,
                    from: JSONSerialization.data(withJSONObject: object))]
            }
            let host = NSHostingView(rootView: VStack(spacing: 12) {
                ModuleUpdatePanel().environmentObject(model)
                SettingsCard(title: "下一张卡片") { Text("位置保持不变") }
            }.font(AppFont.body).buttonStyle(HoverButtonStyle()).padding(16).frame(width: 860)
                .background(DashboardTheme.background).environment(\.colorScheme, .dark))
            let height = host.fittingSize.height
            XCTAssertGreaterThan(height, 200)
            if let reference { XCTAssertEqual(height, reference, accuracy: 0.5, name) }
            else { reference = height }
            host.frame = CGRect(x: 0, y: 0, width: 860, height: height)
            host.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["V2RAYM_UPDATE_RENDER_DIRECTORY"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
        }
    }

    func testLoginItemApprovalDoesNotAddRows() {
        var reference: CGSize?
        for (approval, bundled, updating) in [(false, true, false), (true, true, false), (false, true, true), (false, false, false)] {
            let host = NSHostingView(rootView: LoginItemStatusRow(registered: .constant(false),
                requiresApproval: approval, bundled: bundled, updating: updating, openSettings: {})
                .font(AppFont.body).buttonStyle(HoverButtonStyle()).frame(width: 780))
            if let reference { XCTAssertEqual(host.fittingSize, reference) }
            else { reference = host.fittingSize }
        }
    }

    func testDNSModeWarningDoesNotMoveFields() {
        var reference: CGSize?
        for enabled in [false, true] {
            let host = NSHostingView(rootView: DNSSettingsFields(simpleDNS: .constant(.object([:])),
                dns: .constant(.object(["enabled": .bool(enabled)])), dirty: .constant(false),
                saveSimple: {}, saveCustom: {}).font(AppFont.body).frame(width: 800))
            if let reference { XCTAssertEqual(host.fittingSize, reference) }
            else { reference = host.fittingSize }
        }
    }

    func testRuntimePortWarningDoesNotMoveFields() throws {
        var reference: CGSize?
        for running in [false, true] {
            let model = AppModel(dataDirectory: URL(fileURLWithPath: "/tmp/v2raym-layout-fixture"))
            model.ready = true
            model.systemProxyEnabled = running
            model.status = try JSONDecoder().decode(RuntimeStatus.self, from: Data("{\"coreRunning\":\(running),\"xrayAvailable\":true,\"runtimeState\":\"running\"}".utf8))
            XCTAssertEqual(model.proxyRunning, running)
            let host = NSHostingView(rootView: ParameterSettingsFields(settings: .constant(.object([:])),
                tunSettings: .constant(.object([:])), dirty: .constant(false)).environmentObject(model)
                .font(AppFont.body).frame(width: 800))
            if let reference { XCTAssertEqual(host.fittingSize, reference) }
            else { reference = host.fittingSize }
        }
    }

    func testBusyIndicatorKeepsFooterWidthAndHeight() {
        var reference: CGSize?
        for active in [false, true] {
            let host = NSHostingView(rootView: HStack {
                Text("保存状态")
                InlineActivityIndicator(active: active)
                Button("保存") {}
            }.font(AppFont.body).buttonStyle(HoverButtonStyle()))
            if let reference { XCTAssertEqual(host.fittingSize, reference) }
            else { reference = host.fittingSize }
        }
    }
}

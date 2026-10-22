import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var mainWindow: NSWindow?
    private var statusBar: StatusBarController?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(model: { [weak self] in self?.model }, show: { [weak self] in
            self?.mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            let success = await model.shutdown()
            terminating = false
            if !success {
                let alert = NSAlert()
                alert.messageText = "暂时无法安全退出"
                alert.informativeText = model.error ?? "请先关闭系统代理，再重试退出。"
                alert.addButton(withTitle: "返回应用")
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }
}
@main struct V2rayMApp: App {
    init() { AppFont.register() }
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("v2rayM", id: "main") {
            ContentView().environmentObject(model)
                .font(AppFont.body)
                .buttonStyle(HoverButtonStyle())
                .background(WindowTracker { delegate.mainWindow = $0 })
                .task { delegate.model = model; await model.connect() }
        }
        .defaultSize(width: 860, height: 600)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("刷新") { model.run { _ in } }.keyboardShortcut("r")
                    .disabled(!model.ready || model.busy)
            }
        }
    }
}

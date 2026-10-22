import AppKit
import V2rayMKit

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let model: () -> AppModel?
    private let show: () -> Void
    private var appearanceTask: Task<Void, Never>?
    private var lastMode: MenuBarMode?

    init(model: @escaping () -> AppModel?, show: @escaping () -> Void) {
        self.model = model; self.show = show
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "v2rayM.MenuBar"
        item.isVisible = true
        if let button = item.button {
            button.image = MenuBarIcon.image(for: .inactive)
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "v2rayM"
            button.setAccessibilityLabel("v2rayM")
            button.setAccessibilityIdentifier("v2rayM.statusItem")
        }
        let menu = NSMenu(title: "v2rayM"); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        refreshAppearance()
        appearanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshAppearance()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    deinit { appearanceTask?.cancel() }
    private func refreshAppearance() {
        guard let current = model() else { return }
        let state = DashboardStatus.resolve(ready: current.ready, updating: current.moduleUpdateActive,
            busy: current.busy, recovery: current.proxyNeedsRecovery, state: current.status,
            tunRunning: current.tun?.isRunning == true, systemProxy: current.systemProxyEnabled,
            lastRefresh: current.lastStatusRefresh, now: Date())
        let mode = MenuBarMode(state)
        if mode != lastMode {
            item.button?.image = MenuBarIcon.image(for: mode)
            lastMode = mode
        }
        let label = "v2rayM · " + (mode == .attention ? state.title : mode.label)
        item.button?.toolTip = label
        item.button?.setAccessibilityLabel(label)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAppearance()
        menu.removeAllItems()
        let open = NSMenuItem(title: "显示 v2rayM", action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let current = model()
        let state = NSMenuItem(title: current?.proxyDescription ?? "代理已关闭", action: nil, keyEquivalent: "")
        state.isEnabled = false; menu.addItem(state)
        menu.addItem(.separator())
        let system = NSMenuItem(title: "系统代理", action: #selector(toggleSystemProxy), keyEquivalent: "")
        system.target = self
        system.state = systemIsRunning(current) ? .on : .off
        system.isEnabled = canSwitch(current)
        menu.addItem(system)
        let tun = NSMenuItem(title: "TUN 模式", action: #selector(toggleTunMode), keyEquivalent: "")
        tun.target = self
        tun.state = current?.tun?.isRunning == true ? .on : .off
        tun.isEnabled = canSwitch(current) && current?.tun != nil
        menu.addItem(tun)
        if let error = current?.error {
            let failure = NSMenuItem(title: "操作未完成：" + String(error.prefix(70)), action: nil, keyEquivalent: "")
            failure.isEnabled = false; failure.toolTip = error; menu.addItem(failure)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 v2rayM", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }
    private func canSwitch(_ current: AppModel?) -> Bool {
        guard let current else { return false }
        return current.ready && !current.busy && !current.moduleUpdateActive
    }
    private func systemIsRunning(_ current: AppModel?) -> Bool {
        current?.systemProxyEnabled == true && current?.status?.coreRunning == true && current?.tun?.isRunning != true
    }
    @objc private func toggleSystemProxy() {
        guard let current = model(), canSwitch(current) else { return }
        current.toggleProxy(!systemIsRunning(current))
        refreshAppearance()
    }
    @objc private func toggleTunMode() {
        guard let current = model(), canSwitch(current), current.tun != nil else { return }
        current.toggleTun(!current.tun!.isRunning)
        refreshAppearance()
    }
    @objc private func showWindow() { show() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

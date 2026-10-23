import AppKit
import Network

/// Observe physical paths separately so our own utun restart does not trigger
/// another recovery. No SSIDs or network credentials are read.
@MainActor final class NetworkLifecycle {
    private var monitors: [NWPathMonitor] = []
    private var observers: [NSObjectProtocol] = []
    private var paths: [Int: String] = [:]
    private var signature: String?
    init(sleep: @escaping @MainActor (Bool) -> Void,
         change: @escaping @MainActor (Bool) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in sleep(asleep) }
            })
        }
        for (index, type) in [NWInterface.InterfaceType.wifi, .wiredEthernet].enumerated() {
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            monitor.pathUpdateHandler = { [weak self] path in
                let value = path.status == .satisfied
                    ? path.availableInterfaces.map(\.name).sorted().joined(separator: ",") + "|" + path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
                    : ""
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.paths[index] = value
                    guard self.paths.count == 2 else { return }
                    let signature = (0..<2).map { self.paths[$0] ?? "" }.joined(separator: ";")
                    guard signature != self.signature else { return }
                    self.signature = signature
                    change(self.paths.values.contains { !$0.isEmpty })
                }
            }
            monitor.start(queue: DispatchQueue(label: "v2rayM.physical-path.\(index)"))
            monitors.append(monitor)
        }
    }
    deinit {
        monitors.forEach { $0.cancel() }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

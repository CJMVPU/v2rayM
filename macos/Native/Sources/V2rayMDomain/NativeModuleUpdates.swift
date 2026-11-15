public enum RuntimeUpdateActivity {
    public static func isActive(_ operations: [String]) -> Bool {
        operations.contains { $0.hasPrefix("core-update") || $0 == "geo-update" }
    }
}

public enum ModuleUpdateScope: String, CaseIterable, Identifiable {
    case xray, geo, all
    public var id: String { rawValue }
    public var coreType: String? { self == .xray ? "Xray" : nil }
    public var targets: [String] { coreType.map { [$0] } ?? (self == .all ? ["Xray", "GeoFiles"] : ["GeoFiles"]) }
}

public struct NativeModuleUpdatePlan {
    public let targets: [String]
    public var useProxy: Bool
    public let preRelease = true
    public var preReleaseTargets: [String] { targets.filter { $0 != "GeoFiles" } }
    public init(installableTargets: [String], useProxy: Bool) {
        targets = (installableTargets.contains("Xray") ? ["Xray"] : []) + ["GeoFiles"]
        self.useProxy = useProxy
    }
    public func usingAvailableProxy(coreRunning: Bool) -> Self {
        var plan = self; plan.useProxy = useProxy && coreRunning; return plan
    }
}

public enum NativeModuleUpdateCompletion {
    public static func finished(starting: Bool, operations: [String], targets: [String], terminalTargets: Set<String>) -> Bool {
        !starting && !RuntimeUpdateActivity.isActive(operations) && targets.allSatisfy(terminalTargets.contains)
    }
}

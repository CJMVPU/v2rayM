public enum RuntimeUpdateActivity {
    public static func isActive(_ operations: [String]) -> Bool {
        operations.contains { $0.hasPrefix("core-update") || $0 == "geo-update" }
    }
}

public enum ModuleUpdateScope: String, CaseIterable, Identifiable {
    case geo
    public var id: String { rawValue }
    public var targets: [String] { ["GeoFiles"] }
}

public enum NativeModuleUpdateCompletion {
    public static func finished(starting: Bool, operations: [String], targets: [String], terminalTargets: Set<String>) -> Bool {
        !starting && !RuntimeUpdateActivity.isActive(operations) && targets.allSatisfy(terminalTargets.contains)
    }
}

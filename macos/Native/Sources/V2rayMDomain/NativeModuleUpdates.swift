public enum RuntimeUpdateActivity {
    public static func isActive(_ operations: [String]) -> Bool {
        operations.contains { $0.hasPrefix("core-update") || $0 == "geo-update" }
    }
}

public enum NativeModuleUpdateCompletion {
    public static func finished(starting: Bool, operations: [String], geoUpdateComplete: Bool) -> Bool {
        !starting && !RuntimeUpdateActivity.isActive(operations) && geoUpdateComplete
    }
}

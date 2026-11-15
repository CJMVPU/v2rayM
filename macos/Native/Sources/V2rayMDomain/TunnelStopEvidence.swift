public struct TunnelStopEvidence {
    public let ownedProcessIDs: [Int]
    public let runtimeState: String
    public init(ownedProcessIDs: [Int], runtimeState: String) {
        self.ownedProcessIDs = ownedProcessIDs; self.runtimeState = runtimeState
    }
    public var confirmed: Bool { ownedProcessIDs.isEmpty && runtimeState == "stopped" }
}

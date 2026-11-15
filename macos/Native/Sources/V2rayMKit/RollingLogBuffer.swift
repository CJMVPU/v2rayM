import V2rayMDomain

extension LogEntry: RetainedLogEntry {}
public typealias RollingLogBuffer = BoundedLogHistory<LogEntry>

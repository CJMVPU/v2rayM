import XCTest
@testable import V2rayMKit

final class TrafficTrendTests: XCTestCase {
    private func state(at time: TimeInterval, profile: String = "a", started: TimeInterval = 900,
                       running: Bool = true, enabled: Bool = true, upload: Double = 300, download: Double = 600) throws -> RuntimeStatus {
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = ["coreRunning": running, "xrayAvailable": true, "runtimeState": running ? "running" : "stopped",
            "runningProfileId": profile, "coreStartedAt": formatter.string(from: Date(timeIntervalSince1970: started)),
            "trafficEnabled": enabled, "traffic": ["proxyUp": upload, "proxyDown": download,
                "directUp": 100, "directDown": 200, "sampleSeconds": 60,
                "sampledAt": formatter.string(from: Date(timeIntervalSince1970: time))]]
        return try JSONDecoder().decode(RuntimeStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testPollingDoesNotDuplicateOrReorderSamples() throws {
        var trend = TrafficTrend()
        let now = Date(timeIntervalSince1970: 1000)
        trend.record(try state(at: 1000), now: now)
        trend.record(try state(at: 1000), now: now.addingTimeInterval(2))
        trend.record(try state(at: 995), now: now)
        XCTAssertEqual(trend.samples.count, 1)
        XCTAssertEqual(trend.samples[0].upload, 5)
        XCTAssertEqual(trend.samples[0].download, 10)
    }
    func testStaleDisabledAndStoppedDoNotInventZeroSamples() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1013))
        trend.record(try state(at: 1015, enabled: false), now: Date(timeIntervalSince1970: 1015))
        trend.record(try state(at: 1020, running: false), now: Date(timeIntervalSince1970: 1020))
        XCTAssertEqual(trend.samples.count, 1)
        trend.record(try state(at: 1025), now: Date(timeIntervalSince1970: 1025))
        XCTAssertNotEqual(trend.samples[0].segment, trend.samples[1].segment)
        XCTAssertEqual(trend.samples[1].upload, 5)
    }
    func testMissingPollsBreakLineAndShortIntervalsRemainContinuous() throws {
        var trend = TrafficTrend()
        for time in [1000.0, 1005, 1020] { trend.record(try state(at: time), now: Date(timeIntervalSince1970: time)) }
        XCTAssertEqual(trend.samples[0].segment, trend.samples[1].segment)
        XCTAssertNotEqual(trend.samples[1].segment, trend.samples[2].segment)
    }
    func testNodeAndCoreRestartResetHistoryAndRejectEarlierSamples() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, profile: "b"), now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.samples.count, 1)
        XCTAssertEqual(trend.samples[0].date, Date(timeIntervalSince1970: 1005))
        trend.record(try state(at: 1005, profile: "b", started: 1008), now: Date(timeIntervalSince1970: 1010))
        XCTAssertTrue(trend.samples.isEmpty)
    }
    func testCapacityAndTimeWindowRemainBoundedEvenWithoutNewSamples() throws {
        var trend = TrafficTrend()
        for time in 1000...1500 { trend.record(try state(at: Double(time)), now: Date(timeIntervalSince1970: Double(time))) }
        XCTAssertEqual(trend.samples.count, 61)
        XCTAssertTrue(trend.visible(at: Date(timeIntervalSince1970: 1801)).isEmpty)
        trend.record(try state(at: 1801, running: false), now: Date(timeIntervalSince1970: 1801))
        XCTAssertTrue(trend.samples.isEmpty)
    }
    func testDirectionalMinutePeaksExpireWithoutNewSamples() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000, upload: 6000, download: 60), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, upload: 60, download: 3000), now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1059)), [100, 50])
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1060)), [1, 50])
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1065)), [0, 0])
        XCTAssertEqual(trend.visible(at: Date(timeIntervalSince1970: 1065)).count, 2)
    }
    func testPeaksExcludeFutureAndPreviousSessions() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 999)), [0, 0])
        trend.record(try state(at: 1005, profile: "b", upload: 0, download: 0), now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1005)), [0, 0])
    }

}

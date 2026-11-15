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
    func testNodeAndCoreRestartPreserveHistoryAndRejectEarlierSamples() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, profile: "b"), now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.samples.count, 2)
        XCTAssertNotEqual(trend.samples[0].segment, trend.samples[1].segment)
        let history = trend.samples
        trend.record(try state(at: 1005, profile: "b", started: 1008), now: Date(timeIntervalSince1970: 1010))
        XCTAssertEqual(trend.samples, history)
        trend.record(try state(at: 1010, profile: "b", started: 1008), now: Date(timeIntervalSince1970: 1010))
        XCTAssertEqual(trend.samples.count, 3)
        XCTAssertNotEqual(trend.samples[1].segment, trend.samples[2].segment)
        trend.record(try state(at: 1015, profile: "b", started: 1008), now: Date(timeIntervalSince1970: 1015))
        XCTAssertEqual(trend.samples[2].segment, trend.samples[3].segment)
    }
    func testStopThenRestartPreservesRecentSamplesAndPeaks() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        let original = trend.samples[0]
        trend.record(try state(at: 1002, running: false), now: Date(timeIntervalSince1970: 1002))
        trend.record(try state(at: 1005, started: 1003, upload: 60, download: 120), now: Date(timeIntervalSince1970: 1005))
        XCTAssertNil(trend.pausedAt)
        XCTAssertEqual(trend.samples.count, 2)
        XCTAssertEqual(trend.samples[0], original)
        XCTAssertNotEqual(trend.samples[0].segment, trend.samples[1].segment)
        XCTAssertEqual(trend.visible(at: Date(timeIntervalSince1970: 1005)).count, 2)
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1005)), [5, 10])
    }
    func testCapacityAndTimeWindowRemainBoundedEvenWithoutNewSamples() throws {
        var trend = TrafficTrend()
        for time in 1000...1500 { trend.record(try state(at: Double(time)), now: Date(timeIntervalSince1970: Double(time))) }
        XCTAssertEqual(trend.samples.count, 61)
        XCTAssertTrue(trend.visible(at: Date(timeIntervalSince1970: 1801)).isEmpty)
        trend.record(try state(at: 1801, running: false), now: Date(timeIntervalSince1970: 1801))
        XCTAssertEqual(trend.samples.count, 61) // Stopping preserves bounded history.
        trend.record(try state(at: 1802), now: Date(timeIntervalSince1970: 1802))
        XCTAssertEqual(trend.samples.count, 1)
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
    func testPeaksExcludeFutureButRetainPreviousSessions() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 999)), [0, 0])
        trend.record(try state(at: 1005, profile: "b", upload: 0, download: 0), now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1005)), [5, 10])
    }

    func testStoppedClockFreezesHistoryAndResumesWhenEnabled() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, running: false), now: Date(timeIntervalSince1970: 1005))
        let frozen = trend.visible(at: Date(timeIntervalSince1970: 1005))
        for time in [1100.0, 1600, 2000] {
            trend.record(try state(at: time, running: false), now: Date(timeIntervalSince1970: time))
            XCTAssertEqual(trend.displayDate(at: Date(timeIntervalSince1970: time)), Date(timeIntervalSince1970: 1005))
            XCTAssertEqual(trend.visible(at: Date(timeIntervalSince1970: time)), frozen)
            XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: time)), [5, 10])
        }
        trend.record(try state(at: 2005), now: Date(timeIntervalSince1970: 2005))
        XCTAssertNil(trend.pausedAt)
        XCTAssertEqual(trend.samples.count, 1)
    }

    func testResumeRetirementKeepsFrozenGeometryButNotLiveStatistics() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, running: false), now: Date(timeIntervalSince1970: 1005))
        let resume = Date(timeIntervalSince1970: 2000)
        let retirement = try XCTUnwrap(TrafficTrendRetirement(previous: trend, resumedAt: resume))
        trend.record(try state(at: 2000, started: 1999, upload: 0, download: 0), now: resume)
        XCTAssertEqual(retirement.samples.count, 1)
        XCTAssertEqual(retirement.displayDate, Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(retirement.progress(at: resume.addingTimeInterval(-1)), 0)
        XCTAssertEqual(retirement.progress(at: resume.addingTimeInterval(0.6)), 0.5, accuracy: 0.00001)
        XCTAssertEqual(retirement.progress(at: resume.addingTimeInterval(2)), 1)
        XCTAssertEqual(trend.samples.count, 1)
        XCTAssertEqual(trend.peaks(at: resume), [0, 0])
        XCTAssertNil(TrafficTrendRetirement(previous: trend, resumedAt: resume))
    }

    func testShortPauseDoesNotFadeUnexpiredHistory() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, running: false), now: Date(timeIntervalSince1970: 1005))
        XCTAssertNil(TrafficTrendRetirement(previous: trend, resumedAt: Date(timeIntervalSince1970: 1010)))
    }

}

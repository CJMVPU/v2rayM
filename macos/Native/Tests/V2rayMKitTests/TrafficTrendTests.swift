import XCTest
@testable import V2rayMKit

final class TrafficTrendTests: XCTestCase {
    private func state(at time: TimeInterval, profile: String = "a", started: TimeInterval = 900,
                       running: Bool = true, enabled: Bool = true, upload: Double = 300, download: Double = 600,
                       directUpload: Double = 0, directDownload: Double = 0) throws -> RuntimeStatus {
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = ["coreRunning": running, "xrayAvailable": true, "runtimeState": running ? "running" : "stopped",
            "runningProfileId": profile, "coreStartedAt": formatter.string(from: Date(timeIntervalSince1970: started)),
            "trafficEnabled": enabled, "traffic": ["proxyUp": upload, "proxyDown": download,
                "directUp": directUpload, "directDown": directDownload, "sampleSeconds": 60,
                "sampledAt": formatter.string(from: Date(timeIntervalSince1970: time))]]
        return try JSONDecoder().decode(RuntimeStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testResumeKeepsOnlyTheFrozenViewportAndUsesAFixedBlendDuration() throws {
        var trend = TrafficTrend()
        for time in stride(from: 1000.0, through: 1600, by: 5) {
            trend.record(try state(at: time), now: Date(timeIntervalSince1970: time))
        }
        let frozen = Date(timeIntervalSince1970: 1600)
        for gap: TimeInterval in [1, 300, 604800] {
            let resumed = frozen.addingTimeInterval(gap)
            let transition = TrafficTrendCatchUp(previous: trend, displayedAt: frozen, resumedAt: resumed)
            XCTAssertEqual(transition.samples, trend.plotSamples(at: frozen))
            XCTAssertEqual(transition.displayDate, frozen)
            XCTAssertEqual(transition.startedAt, resumed)
            let repeated = TrafficTrendCatchUp(holding: transition, resumedAt: resumed.addingTimeInterval(10))
            XCTAssertEqual(transition.samples, repeated.samples)
            XCTAssertEqual(transition.displayDate, repeated.displayDate)
        }
        XCTAssertEqual(TrafficTrendCatchUp.progress(after: 0), 0)
        XCTAssertEqual(TrafficTrendCatchUp.progress(after: TrafficTrendCatchUp.duration / 2), 0.5)
        XCTAssertEqual(TrafficTrendCatchUp.progress(after: TrafficTrendCatchUp.duration), 1)
    }

    func testSameSecondCoreRestartStartsANewSegment() throws {
        var trend = TrafficTrend()
        var a = try state(at: 1000, upload: 60, download: 120)
        var b = try state(at: 1005, upload: 120, download: 60)
        a.coreSessionID = UUID()
        b.coreSessionID = UUID()
        b.coreStartedAt = a.coreStartedAt
        trend.record(a, now: Date(timeIntervalSince1970: 1000))
        trend.record(b, now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.samples.count, 2)
        XCTAssertNotEqual(trend.samples.first?.segment, trend.samples.last?.segment)
    }

    func testDirectTrafficHasIndependentRatesPeaksAndChartScale() throws {
        var trend = TrafficTrend()
        let now = Date(timeIntervalSince1970: 1000)
        trend.record(try state(at: 1000, upload: 60, download: 120,
                               directUpload: 1800, directDownload: 3600), now: now)
        let sample = try XCTUnwrap(trend.samples.first)
        XCTAssertEqual(sample.upload, 1)
        XCTAssertEqual(sample.download, 2)
        XCTAssertEqual(sample.directUpload, 30)
        XCTAssertEqual(sample.directDownload, 60)
        XCTAssertEqual(sample.maximum, 60)
        XCTAssertEqual(trend.peaks(at: now), [1, 2, 30, 60])
        XCTAssertEqual(trend.peaks(at: now.addingTimeInterval(60)), [0, 0, 0, 0])
        trend.record(try state(at: 1005, running: false), now: now.addingTimeInterval(5))
        let retired = try XCTUnwrap(TrafficTrendRetirement(previous: trend, resumedAt: now.addingTimeInterval(400)))
        XCTAssertEqual(retired.ceiling, 60 * 1.12, accuracy: 0.001)
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
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1005)), [5, 10, 0, 0])
    }
    func testCapacityAndTimeWindowRemainBoundedEvenWithoutNewSamples() throws {
        var trend = TrafficTrend()
        for time in 1000...1500 { trend.record(try state(at: Double(time)), now: Date(timeIntervalSince1970: Double(time))) }
        XCTAssertEqual(trend.samples.count, 302) // Five minutes at 1 Hz, plus the clip-edge predecessor.
        XCTAssertEqual(trend.visible(at: Date(timeIntervalSince1970: 1500)).count, 301)
        XCTAssertTrue(trend.visible(at: Date(timeIntervalSince1970: 1801)).isEmpty)
        trend.record(try state(at: 1801, running: false), now: Date(timeIntervalSince1970: 1801))
        XCTAssertEqual(trend.samples.count, 302) // Stopping preserves bounded history.
        trend.record(try state(at: 1802), now: Date(timeIntervalSince1970: 1802))
        XCTAssertEqual(trend.samples.count, 1)
    }
    func testDirectionalMinutePeaksExpireWithoutNewSamples() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000, upload: 6000, download: 60), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, upload: 60, download: 3000), now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1059)), [100, 50, 0, 0])
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1060)), [1, 50, 0, 0])
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1065)), [0, 0, 0, 0])
        XCTAssertEqual(trend.visible(at: Date(timeIntervalSince1970: 1065)).count, 2)
    }

    func testLeftEdgeRetainsCurvePredecessorWithoutKeepingExpiredStatistics() throws {
        var trend = TrafficTrend()
        for time in [1000.0, 1005, 1010] {
            trend.record(try state(at: time), now: Date(timeIntervalSince1970: time))
        }
        let before = Date(timeIntervalSince1970: 1299.9)
        let after = Date(timeIntervalSince1970: 1300.1)
        XCTAssertEqual(trend.plotSamples(at: before), trend.plotSamples(at: after))
        XCTAssertEqual(trend.visible(at: after).map(\.date), [1005.0, 1010].map(Date.init(timeIntervalSince1970:)))
        XCTAssertEqual(trend.peaks(at: after), [0, 0, 0, 0])

        // The periodic status update must not delete that rendering predecessor.
        trend.record(try state(at: 1300), now: after)
        XCTAssertEqual(trend.plotSamples(at: after).first?.date, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(trend.plotSamples(at: Date(timeIntervalSince1970: 1305.1)).first?.date, Date(timeIntervalSince1970: 1005))
    }

    func testLeftEdgeNeverConnectsAcrossSessionOrMissingSamples() throws {
        for differentSession in [false, true] {
            var trend = TrafficTrend()
            trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
            let second = differentSession ? 1005.0 : 1020.0
            trend.record(try state(at: second, profile: differentSession ? "b" : "a"), now: Date(timeIntervalSince1970: second))
            let now = Date(timeIntervalSince1970: 1300.1)
            XCTAssertEqual(trend.plotSamples(at: now), trend.visible(at: now))
        }
    }

    func testStoppedHistoryRetainsLeftEdgeGeometry() throws {
        var trend = TrafficTrend()
        for time in stride(from: 1000.0, through: 1300.0, by: 5) {
            trend.record(try state(at: time), now: Date(timeIntervalSince1970: time))
        }
        trend.record(try state(at: 1301, running: false), now: Date(timeIntervalSince1970: 1301))
        let frozen = trend.plotSamples(at: Date(timeIntervalSince1970: 1301))
        XCTAssertEqual(frozen.first?.date, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(trend.plotSamples(at: Date(timeIntervalSince1970: 2000)), frozen)
    }
    func testPeaksExcludeFutureButRetainPreviousSessions() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 999)), [0, 0, 0, 0])
        trend.record(try state(at: 1005, profile: "b", upload: 0, download: 0), now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: 1005)), [5, 10, 0, 0])
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
            XCTAssertEqual(trend.peaks(at: Date(timeIntervalSince1970: time)), [5, 10, 0, 0])
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
        XCTAssertEqual(trend.peaks(at: resume), [0, 0, 0, 0])
        XCTAssertNil(TrafficTrendRetirement(previous: trend, resumedAt: resume))
    }

    func testShortPauseDoesNotFadeUnexpiredHistory() throws {
        var trend = TrafficTrend()
        trend.record(try state(at: 1000), now: Date(timeIntervalSince1970: 1000))
        trend.record(try state(at: 1005, running: false), now: Date(timeIntervalSince1970: 1005))
        XCTAssertNil(TrafficTrendRetirement(previous: trend, resumedAt: Date(timeIntervalSince1970: 1010)))
    }

}

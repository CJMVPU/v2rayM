import XCTest
import Combine
@testable import V2rayM

@MainActor final class DashboardCardPresentationTests: XCTestCase {
    private let timing = DashboardCardTiming(outward: 0.06, inward: 0.06, settle: 0.03, stagger: 0.10)

    func testFreezingRestingCardDoesNotPublishIdenticalContent() {
        let card = DashboardCardPresentation(value: 42, idle: 0, active: true, ready: true, slot: 0)
        var publications = 0
        let observation = card.objectWillChange.sink { publications += 1 }
        defer { observation.cancel(); card.disappear() }
        for _ in 0..<20 { card.update(value: 42, idle: 0, active: true, ready: true, reduced: true) }
        XCTAssertEqual(publications, 0, "Freezing must not cause extra passes for unchanged front content")
        card.update(value: 43, idle: 0, active: true, ready: true, reduced: true)
        XCTAssertEqual(card.displayed, 43)
        XCTAssertEqual(publications, 1, "The latest value must still publish on catch-up")
    }

    func testWaitsForDataAndRetainsLastSnapshotUntilClosingFinishes() async throws {
        let card = DashboardCardPresentation(value: [Double](), idle: [], active: false, ready: false, slot: 0, timing: timing)
        card.update(value: [], idle: [], active: true, ready: false, reduced: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(card.targetActive)
        XCTAssertEqual(card.angle, 0)
        XCTAssertTrue(card.displayed.isEmpty)

        card.update(value: [12.3], idle: [], active: true, ready: true, reduced: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(card.presentedActive)
        XCTAssertEqual(card.displayed, [12.3])
        card.update(value: [45.6], idle: [], active: true, ready: true, reduced: false)
        XCTAssertEqual(card.displayed, [45.6])

        card.update(value: [], idle: [], active: false, ready: false, reduced: false)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(card.presentedActive)
        XCTAssertEqual(card.displayed, [45.6], "Stopping must freeze the last live face through the return turn")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(card.presentedActive)
        XCTAssertTrue(card.displayed.isEmpty)
        XCTAssertEqual(card.angle, 0)
    }

    func testRecentCardChangesContentOnlyWhileBackFacesViewer() async throws {
        let card = DashboardCardPresentation(value: [Int](), idle: [], active: false, ready: false,
            slot: 2, timing: timing, contentWhileHidden: true)
        defer { card.disappear() }
        card.update(value: [42], idle: [], active: true, ready: true, reduced: false)
        XCTAssertTrue(card.displayed.isEmpty); XCTAssertFalse(card.presentedActive)
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertTrue(card.displayed.isEmpty, "Keep the old front during the outward turn")
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertEqual(card.displayed, [42])
        try await Task.sleep(for: .milliseconds(130))
        card.update(value: [], idle: [], active: false, ready: false, reduced: false)
        XCTAssertEqual(card.displayed, [42])
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertEqual(card.displayed, [42])
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertTrue(card.displayed.isEmpty, "Clear while the branded back hides the content area")
    }

    func testCardsStaggerInBothDirections() async throws {
        let cards = (0...2).map { DashboardCardPresentation(value: 0, idle: 0, active: false, ready: false, slot: $0, timing: timing) }
        for card in cards { card.update(value: 42, idle: 0, active: true, ready: true, reduced: false) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotEqual(cards[0].angle, 0)
        XCTAssertEqual(cards[1].angle, 0)
        XCTAssertEqual(cards[2].angle, 0)
        try await Task.sleep(for: .milliseconds(390))
        XCTAssertTrue(cards.allSatisfy { $0.displayed == 42 && $0.presentedActive })
        for card in cards { card.update(value: 0, idle: 0, active: false, ready: false, reduced: false) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotEqual(cards[0].angle, 0)
        XCTAssertEqual(cards[1].angle, 0)
        XCTAssertEqual(cards[2].angle, 0)
        XCTAssertTrue(cards.allSatisfy { $0.displayed == 42 })
        try await Task.sleep(for: .milliseconds(390))
        XCTAssertTrue(cards.allSatisfy { $0.displayed == 0 && !$0.presentedActive && $0.angle == 0 })
    }

    func testRapidStopRestartCannotRestoreOldData() async throws {
        let card = DashboardCardPresentation(value: "", idle: "", active: false, ready: false, slot: 1, timing: timing)
        card.update(value: "old", idle: "", active: true, ready: true, reduced: false)
        card.update(value: "", idle: "", active: false, ready: false, reduced: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(card.displayed, "")
        XCTAssertFalse(card.presentedActive)
        card.update(value: "first", idle: "", active: true, ready: true, reduced: false)
        try await Task.sleep(for: .milliseconds(300))
        card.update(value: "", idle: "", active: false, ready: false, reduced: false)
        try await Task.sleep(for: .milliseconds(140))
        card.update(value: "latest", idle: "", active: true, ready: true, reduced: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(card.displayed, "latest")
        XCTAssertTrue(card.presentedActive)
        XCTAssertEqual(card.angle, 0)
    }

    func testMissingSamplesDoNotRetriggerAndReduceMotionCancelsQueuedWork() async throws {
        let card = DashboardCardPresentation(value: 7, idle: 0, active: true, ready: true, slot: 2, timing: timing)
        card.update(value: 0, idle: 0, active: true, ready: false, reduced: false)
        XCTAssertTrue(card.targetActive, "Readiness gates startup, not normal sample expiration")
        XCTAssertEqual(card.angle, 0)
        card.update(value: 0, idle: 0, active: false, ready: false, reduced: false)
        card.update(value: 0, idle: 0, active: false, ready: false, reduced: true)
        XCTAssertFalse(card.presentedActive)
        XCTAssertEqual(card.displayed, 0)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(card.angle, 0)
        XCTAssertFalse(card.presentedActive)
        card.update(value: 9, idle: 0, active: true, ready: false, reduced: true)
        XCTAssertFalse(card.presentedActive)
        card.update(value: 9, idle: 0, active: true, ready: true, reduced: true)
        XCTAssertEqual(card.displayed, 9)
        XCTAssertTrue(card.presentedActive)
    }
}

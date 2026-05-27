@testable import AppBundle
import XCTest

final class WorkspaceTimeTrackerTest: XCTestCase {
    private let day = "2026-05-27"

    func testNormalCreditAddsElapsedToFocused() {
        let now = Date()
        let last = now.addingTimeInterval(-5)
        let (map, key) = accrueWorkspaceTime(
            map: ["Personal": 10],
            dayKey: day,
            nowDayKey: day,
            lastSample: last,
            now: now,
            focused: "Personal",
            isEnabled: true,
            idleSeconds: 0,
            tickIntervalMax: 30,
            idleThreshold: 300,
        )
        XCTAssertEqual(key, day)
        XCTAssertEqual(map["Personal"] ?? 0, 15, accuracy: 0.001)
    }

    func testIdleGateBlocksCredit() {
        let now = Date()
        let (map, _) = accrueWorkspaceTime(
            map: [:],
            dayKey: day,
            nowDayKey: day,
            lastSample: now.addingTimeInterval(-5),
            now: now,
            focused: "Hotrema",
            isEnabled: true,
            idleSeconds: 301,
            tickIntervalMax: 30,
            idleThreshold: 300,
        )
        XCTAssertNil(map["Hotrema"])
    }

    func testWakeClampDiscardsLargeDelta() {
        let now = Date()
        let (map, _) = accrueWorkspaceTime(
            map: [:],
            dayKey: day,
            nowDayKey: day,
            lastSample: now.addingTimeInterval(-120),
            now: now,
            focused: "Corp-Opus",
            isEnabled: true,
            idleSeconds: 0,
            tickIntervalMax: 30,
            idleThreshold: 300,
        )
        XCTAssertNil(map["Corp-Opus"])
    }

    func testDisabledBlocksCredit() {
        let now = Date()
        let (map, _) = accrueWorkspaceTime(
            map: [:],
            dayKey: day,
            nowDayKey: day,
            lastSample: now.addingTimeInterval(-5),
            now: now,
            focused: "KD-Jupiter",
            isEnabled: false,
            idleSeconds: 0,
            tickIntervalMax: 30,
            idleThreshold: 300,
        )
        XCTAssertNil(map["KD-Jupiter"])
    }

    func testDayRolloverZeroesMapAndUpdatesKey() {
        let now = Date()
        let (map, key) = accrueWorkspaceTime(
            map: ["Personal": 999, "Other-work": 12],
            dayKey: "2026-05-26",
            nowDayKey: day,
            lastSample: now.addingTimeInterval(-5),
            now: now,
            focused: "Personal",
            isEnabled: true,
            idleSeconds: 0,
            tickIntervalMax: 30,
            idleThreshold: 300,
        )
        XCTAssertEqual(key, day)
        XCTAssertTrue(map.isEmpty)
    }
}

import AppKit
import Combine
import Foundation
import IOKit

/// Per-workspace daily active-time tracker.
///
/// A 5s repeating timer credits real elapsed time to the focused workspace, but
/// only while AeroSpace is enabled, the user is not idle (>5 min), and there was
/// no large gap since the last tick (sleep/throttle). Totals are kept per local
/// day and zeroed on date rollover. The accrual decision lives in the pure,
/// unit-tested `accrueWorkspaceTime(...)` free function below.
@MainActor
final class WorkspaceTimeTracker: ObservableObject {
    static let shared = WorkspaceTimeTracker()

    private init() {}

    @Published private(set) var secondsByWorkspace: [String: Double] = [:]

    private var dayKey: String = ""
    private var lastSample: Date = Date()
    private var timer: Timer?
    private var ticksSincePersist = 0

    private static let tickInterval: TimeInterval = 5.0
    private static let idleThresholdSeconds: Double = 300.0
    private static let maxGapSeconds: Double = 30.0
    /// Persist roughly once a minute (every ~12 ticks of 5s).
    private static let persistEveryNTicks = 12

    func start() {
        guard timer == nil else { return }
        let today = Self.dayKey(for: Date())
        if let persisted = loadPersisted(), persisted.day == today {
            secondsByWorkspace = persisted.seconds
        } else {
            secondsByWorkspace = [:]
        }
        dayKey = today
        lastSample = Date()
        ticksSincePersist = 0
        // The Timer callback is NOT MainActor-isolated; hop explicitly, mirroring
        // VolumeView.swift's pattern.
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        // The day key is computed here (caller-side) so the pure function stays
        // deterministic and Calendar-free.
        let nowDayKey = Self.dayKey(for: now)
        let result = accrueWorkspaceTime(
            map: secondsByWorkspace,
            dayKey: dayKey,
            nowDayKey: nowDayKey,
            lastSample: lastSample,
            now: now,
            focused: focus.workspace.name,
            isEnabled: TrayMenuModel.shared.isEnabled,
            idleSeconds: Self.idleSeconds(),
            tickIntervalMax: Self.maxGapSeconds,
            idleThreshold: Self.idleThresholdSeconds,
        )
        secondsByWorkspace = result.map
        dayKey = result.dayKey
        lastSample = now

        ticksSincePersist += 1
        if ticksSincePersist >= Self.persistEveryNTicks {
            ticksSincePersist = 0
            persist()
        }
    }

    // MARK: Accessors

    func seconds(for name: String) -> Double {
        secondsByWorkspace[name] ?? 0
    }

    /// Human-readable today's duration for the menu row. Empty for zero-time
    /// workspaces (so they show no duration).
    func formatted(_ name: String) -> String {
        let secs = seconds(for: name)
        guard secs >= 1 else { return "" }
        let totalMinutes = Int(secs) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if totalMinutes > 0 { return "\(totalMinutes)m" }
        return "\(Int(secs))s"
    }

    // MARK: Idle detection (IOKit)

    /// Seconds since the last HID input event, via IOHIDSystem's `HIDIdleTime`
    /// (nanoseconds). Returns 0 on any failure (treated as "not idle").
    static func idleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, unsafe IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let property = unsafe IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0,
        )?.takeRetainedValue(), let nanos = property as? NSNumber else {
            return 0
        }
        return nanos.doubleValue / 1_000_000_000.0
    }

    // MARK: Day key

    /// Local-timezone `yyyy-MM-dd`. Used only on the caller side; the pure
    /// accrual function never touches `Calendar`.
    private static func dayKey(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(comps.year ?? 0)-\(pad2(comps.month ?? 0))-\(pad2(comps.day ?? 0))"
    }

    // MARK: Persistence (crash-safe, never crashes the app)

    private struct PersistedWorktime: Codable {
        let day: String
        let seconds: [String: Double]
    }

    private static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/aerospace/worktime.json")
    }

    private func persist() {
        let snapshot = PersistedWorktime(day: dayKey, seconds: secondsByWorkspace)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = Self.storeURL
        // Keep disk I/O off the main runloop.
        Task.detached {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadPersisted() -> PersistedWorktime? {
        let url = Self.storeURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistedWorktime.self, from: data) else {
            return nil
        }
        return decoded
    }
}

/// Pure accrual decision: no globals, no I/O, no `Calendar`. Returns the updated
/// per-workspace seconds map and day key. Unit-tested in WorkspaceTimeTrackerTest.
func accrueWorkspaceTime(
    map: [String: Double],
    dayKey: String,
    nowDayKey: String,
    lastSample: Date,
    now: Date,
    focused: String,
    isEnabled: Bool,
    idleSeconds: Double,
    tickIntervalMax: Double,
    idleThreshold: Double,
) -> (map: [String: Double], dayKey: String) {
    // Date rollover (pure string compare): start fresh. An in-progress interval
    // crossing midnight is dropped (≤ one tick ≈ 5s/day) — accepted error budget.
    if nowDayKey != dayKey {
        return (map: [:], dayKey: nowDayKey)
    }
    let delta = now.timeIntervalSince(lastSample)
    // Credit only when enabled, not idle, and the gap is small (clamps sleep/throttle).
    guard isEnabled, delta > 0, delta <= tickIntervalMax, idleSeconds < idleThreshold else {
        return (map: map, dayKey: dayKey)
    }
    var newMap = map
    newMap[focused, default: 0] += delta
    return (map: newMap, dayKey: dayKey)
}

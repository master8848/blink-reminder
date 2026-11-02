// Tests.swift — pure-logic tests for BlinkReminder (no AppKit, no Xcode project).
// Each helper mirrors the corresponding logic in BlinkReminder.swift; keep them in sync.
// Run: swift Tests.swift  (exits nonzero on any failure — do NOT use bare assert(),
// which is stripped in optimized builds).
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    check(actual == expected, "\(message) (expected \(expected), got \(actual))")
}

// MARK: - Mirrors of BlinkReminder.swift logic

/// Mirrors AppDelegate.countdownTitle() MM:SS formatting.
func formatCountdownTitle(remaining: Int) -> String {
    let r = max(0, remaining)
    let minutes = r / 60
    let seconds = r % 60
    return String(format: "Next break in %02d:%02d", minutes, seconds)
}

/// Mirrors AppDelegate.deferBreak(by:) delay computation: snooze means the
/// next break comes `extra` seconds from now (startTimer clamps to >= 1s).
func deferNewDelay(extra: TimeInterval) -> TimeInterval {
    max(1, extra)
}

/// Mirrors AppDelegate.remainingManualPauseText() ("Xm left" rounding).
func remainingPauseText(remaining: TimeInterval) -> String? {
    guard remaining > 0 else { return nil }
    return "\(Int(ceil(remaining / 60.0)))m left"
}

/// Mirrors AppDelegate.refreshManualPauseIfExpired() expiry decision.
func isPauseExpired(now: Date, until: Date?) -> Bool {
    guard let until else { return false }
    return now >= until
}

/// Mirrors the 1-hour skip-window filter in showOverlay().
func filterRecentSkips(_ stamps: [Date], now: Date) -> [Date] {
    stamps.filter { now.timeIntervalSince($0) < 3600 }
}

/// Mirrors the canSkip computation in showOverlay().
func canSkip(maxSkips: Int, recentCount: Int) -> Bool {
    (maxSkips == -1) || (recentCount < maxSkips)
}

/// Mirrors shouldSkipBreakForIdle() in BlinkReminder.swift.
func shouldSkipBreakForIdle(manual: Bool, resetOnIdle: Bool, idleSeconds: TimeInterval, threshold: TimeInterval) -> Bool {
    !manual && resetOnIdle && idleSeconds >= threshold
}

/// Mirrors AppDelegate.idleThreshold default resolution.
func resolveIdleThreshold(stored: Double) -> Double {
    stored > 0 ? stored : 60
}

/// Mirrors AppDelegate.breakDurationSeconds default resolution.
func resolveBreakDuration(stored: Double) -> Int {
    stored > 0 ? Int(stored) : 20
}

// MARK: - Tests

// 1. Countdown formatting MM:SS from remaining seconds.
checkEqual(formatCountdownTitle(remaining: 125), "Next break in 02:05", "countdown 125s")
checkEqual(formatCountdownTitle(remaining: 0), "Next break in 00:00", "countdown 0s")
checkEqual(formatCountdownTitle(remaining: 65), "Next break in 01:05", "countdown 65s")
checkEqual(formatCountdownTitle(remaining: 3600), "Next break in 60:00", "countdown 3600s")
checkEqual(formatCountdownTitle(remaining: -5), "Next break in 00:00", "countdown clamps negative")

// 2. deferBreak: next break comes `extra` seconds from now.
checkEqual(deferNewDelay(extra: 60), 60, "defer +1m means 60s from now")
checkEqual(deferNewDelay(extra: 300), 300, "defer +5m means 300s from now")
checkEqual(deferNewDelay(extra: 0), 1, "defer clamps to >= 1s")

// 2b. Pause For: "Xm left" rounding + expiry decision.
checkEqual(remainingPauseText(remaining: 900), "15m left", "pause 15m")
checkEqual(remainingPauseText(remaining: 1800), "30m left", "pause 30m")
checkEqual(remainingPauseText(remaining: 3600), "60m left", "pause 1h")
checkEqual(remainingPauseText(remaining: 59), "1m left", "pause rounds up partial minute")
checkEqual(remainingPauseText(remaining: 61), "2m left", "pause rounds up 61s")
checkEqual(remainingPauseText(remaining: 0), nil, "pause ended shows nothing")
checkEqual(remainingPauseText(remaining: -5), nil, "pause overdue shows nothing")
let ref = Date()
checkEqual(isPauseExpired(now: ref, until: ref), true, "pause expires exactly at deadline")
checkEqual(isPauseExpired(now: ref.addingTimeInterval(1), until: ref), true, "pause expires past deadline")
checkEqual(isPauseExpired(now: ref.addingTimeInterval(-1), until: ref), false, "pause active before deadline")
checkEqual(isPauseExpired(now: ref, until: nil), false, "no schedule never expires")

// 3. Skip-window filter (<3600s) + canSkip vs maxSkips (-1/0/1/3/5).
let now = Date()
let recent = now.addingTimeInterval(-100)
let old = now.addingTimeInterval(-4000)
let boundary = now.addingTimeInterval(-3600)
checkEqual(filterRecentSkips([recent, old], now: now).count, 1, "skip filter drops >1h old")
checkEqual(filterRecentSkips([boundary], now: now).count, 0, "skip filter drops exactly-3600s")
checkEqual(filterRecentSkips([], now: now).count, 0, "skip filter empty")

checkEqual(canSkip(maxSkips: -1, recentCount: 99), true, "unlimited allows skip")
checkEqual(canSkip(maxSkips: 0, recentCount: 0), false, "strict(0) denies with zero skips")
checkEqual(canSkip(maxSkips: 1, recentCount: 0), true, "1 skip allows first")
checkEqual(canSkip(maxSkips: 1, recentCount: 1), false, "1 skip denies second")
checkEqual(canSkip(maxSkips: 3, recentCount: 2), true, "3 skips allows third")
checkEqual(canSkip(maxSkips: 3, recentCount: 3), false, "3 skips denies fourth")
checkEqual(canSkip(maxSkips: 5, recentCount: 5), false, "5 skips denies sixth")
checkEqual(canSkip(maxSkips: 5, recentCount: 4), true, "5 skips allows fifth")

// 4. Defaults.
checkEqual(resolveIdleThreshold(stored: 0), 60, "idleThreshold default 60s")
checkEqual(resolveIdleThreshold(stored: 120), 120, "idleThreshold stored respected")
checkEqual(resolveBreakDuration(stored: 0), 20, "breakDuration default 20s")
checkEqual(resolveBreakDuration(stored: 30), 30, "breakDuration stored respected")

// 5. Idle-skip applies to scheduled fires only; manual triggers always present.
checkEqual(shouldSkipBreakForIdle(manual: false, resetOnIdle: true, idleSeconds: 3600, threshold: 60), true, "scheduled idle skips")
checkEqual(shouldSkipBreakForIdle(manual: false, resetOnIdle: true, idleSeconds: 10, threshold: 60), false, "scheduled active does not skip")
checkEqual(shouldSkipBreakForIdle(manual: false, resetOnIdle: false, idleSeconds: 3600, threshold: 60), false, "idle reset off does not skip")
checkEqual(shouldSkipBreakForIdle(manual: true, resetOnIdle: true, idleSeconds: 3600, threshold: 60), false, "manual never skips")

// MARK: - Result

if failures > 0 {
    print("\(failures) test(s) FAILED")
    exit(1)
}
print("All logic tests passed.")

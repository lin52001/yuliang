import Foundation

/// Transient visual reactions never alter quota, timestamps or the stored satiety level.
public enum BuddyAction: String, Codable, Sendable, CaseIterable {
    case idle, eating, pat, wave, nap, celebrate
}

/// Compares already validated, selected Codex observations. The caller must invoke this
/// only when ingesting a real collector snapshot, never for a preview or a preference change.
public enum BuddyQuotaChange {
    /// Returns the observed decrease in percentage points, not an inferred token count.
    /// Missing cycle evidence is deliberately quiet rather than mistaking a reset for a meal.
    public static func consumption(from previous: QuotaPresentation, to next: QuotaPresentation) -> Double? {
        guard previous.provider == .codex, next.provider == .codex,
              previous.freshness == .fresh, next.freshness == .fresh,
              let oldWindow = previous.window, let newWindow = next.window,
              ["primary", "secondary"].contains(oldWindow.id), oldWindow.id == newWindow.id,
              oldWindow.label == newWindow.label,
              let before = previous.remainingPercent, let after = next.remainingPercent,
              before.isFinite, after.isFinite, (0...100).contains(before), (0...100).contains(after),
              before > after,
              let oldObserved = previous.observedAt, let newObserved = next.observedAt,
              oldObserved.timeIntervalSince1970.isFinite, newObserved.timeIntervalSince1970.isFinite,
              newObserved > oldObserved,
              let oldReset = previous.resetAt, let newReset = next.resetAt,
              oldReset.timeIntervalSince1970.isFinite, newReset.timeIntervalSince1970.isFinite,
              oldReset == newReset, newReset > newObserved else { return nil }
        return before - after
    }
}

import Foundation

/// Transient visual reactions never alter quota, timestamps or the stored satiety level.
public enum BuddyAction: String, Codable, Sendable, CaseIterable {
    case idle, eating, pat, wave, nap, celebrate, jump, dance, spin

    public static let interactiveActions: [Self] = [.pat, .wave, .jump, .dance, .spin, .nap, .celebrate, .eating]
    /// A random greeting cannot be confused with an automatically consumed meal.
    public static let playfulActions = interactiveActions.filter { $0 != .eating }

    public var label: String {
        switch self {
        case .idle: "休息"
        case .eating: "喂一口饼干"
        case .pat: "摸摸头"
        case .wave: "招招手"
        case .nap: "小睡一下"
        case .celebrate: "给点鼓励"
        case .jump: "跳一跳"
        case .dance: "摇摇摆"
        case .spin: "转个圈"
        }
    }
    public var symbol: String {
        switch self {
        case .idle: "leaf"
        case .eating: "fork.knife"
        case .pat: "hand.raised.fill"
        case .wave: "hand.wave.fill"
        case .nap: "moon.zzz.fill"
        case .celebrate: "sparkles"
        case .jump: "arrow.up"
        case .dance: "music.note"
        case .spin: "arrow.triangle.2.circlepath"
        }
    }
    public var duration: TimeInterval {
        switch self {
        case .idle: 0
        case .eating: 3
        case .jump: 2.2
        case .dance: 2.8
        case .pat, .wave, .nap, .celebrate, .spin: 2.4
        }
    }

    /// Finite, deterministic visual sampling. Offsets are fractions of the
    /// sprite size, so motion never changes a quota-derived rail position.
    public func motionSample(progress: Double, reduceMotion: Bool = false) -> BuddyMotionSample {
        guard progress.isFinite, progress > 0, progress < 1, !reduceMotion else { return .rest }
        let t = progress
        let envelope = pow(sin(t * .pi), 2)
        let wave = sin(t * .pi * 6)
        switch self {
        case .idle: return .rest
        case .eating:
            return .init(verticalOffset: -0.014 * abs(wave) * envelope)
        case .pat:
            return .init(scaleX: 1 + 0.045 * envelope, scaleY: 1 + 0.045 * envelope)
        case .wave:
            return .init(rotationDegrees: wave * 8 * envelope)
        case .nap:
            return .init(rotationDegrees: -5 * sin(t * .pi), verticalOffset: 0.016 * envelope)
        case .celebrate:
            return .init(rotationDegrees: sin(t * .pi * 4) * 2 * envelope,
                         verticalOffset: -0.08 * abs(sin(t * .pi * 3)) * envelope,
                         scaleX: 1 + 0.025 * envelope, scaleY: 1 + 0.025 * envelope)
        case .jump:
            let hop = abs(sin(t * .pi * 2))
            let landing = max(0, 1 - hop * 5) * envelope
            return .init(verticalOffset: -0.18 * hop, scaleX: 1 + 0.10 * landing, scaleY: 1 - 0.10 * landing)
        case .dance:
            return .init(rotationDegrees: wave * 10 * envelope,
                         horizontalOffset: wave * 0.055 * envelope,
                         verticalOffset: -0.02 * abs(wave) * envelope)
        case .spin:
            let turn = t * t * (3 - 2 * t)
            return .init(rotationDegrees: 360 * turn, verticalOffset: -0.045 * sin(t * .pi),
                         scaleX: 1 - 0.06 * envelope, scaleY: 1 - 0.06 * envelope)
        }
    }
}

public struct BuddyMotionSample: Equatable, Sendable {
    public let rotationDegrees: Double
    public let horizontalOffset: Double
    public let verticalOffset: Double
    public let scaleX: Double
    public let scaleY: Double
    public static let rest = Self()

    public init(rotationDegrees: Double = 0, horizontalOffset: Double = 0,
                verticalOffset: Double = 0, scaleX: Double = 1, scaleY: Double = 1) {
        self.rotationDegrees = rotationDegrees
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
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

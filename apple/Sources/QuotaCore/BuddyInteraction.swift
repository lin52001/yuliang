import Foundation

/// Transient visual reactions never alter quota, timestamps or the stored satiety level.
public enum BuddyAction: String, Codable, Sendable, CaseIterable {
    case idle, eating, pat, wave, nap, celebrate, jump, dance, spin, stretch, nuzzle, peek, sip

    public static let interactiveActions: [Self] = [.pat, .wave, .jump, .dance, .spin, .nap, .celebrate, .eating,
                                                  .stretch, .nuzzle, .peek, .sip]
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
        case .stretch: "伸伸懒腰"
        case .nuzzle: "蹭蹭你"
        case .peek: "探个头"
        case .sip: "一起喝水"
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
        case .stretch: "figure.flexibility"
        case .nuzzle: "heart.fill"
        case .peek: "eyes"
        case .sip: "cup.and.saucer.fill"
        }
    }
    public var duration: TimeInterval {
        switch self {
        case .idle: 0
        case .eating: 3
        case .jump: 2.2
        case .dance: 2.8
        case .stretch, .sip: 3
        case .nuzzle: 2.8
        case .pat, .wave, .nap, .celebrate, .spin, .peek: 2.4
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
        case .stretch:
            return .init(rotationDegrees: sin(t * .pi * 2) * 2 * envelope,
                         verticalOffset: -0.026 * envelope,
                         scaleX: 1 - 0.035 * envelope, scaleY: 1 + 0.075 * envelope)
        case .nuzzle:
            return .init(rotationDegrees: sin(t * .pi * 4) * 5 * envelope,
                         horizontalOffset: sin(t * .pi * 2) * 0.04 * envelope,
                         scaleX: 1 + 0.025 * envelope, scaleY: 1 + 0.025 * envelope)
        case .peek:
            return .init(rotationDegrees: -5 * sin(t * .pi * 2) * envelope,
                         horizontalOffset: 0.05 * sin(t * .pi), verticalOffset: -0.024 * envelope)
        case .sip:
            return .init(rotationDegrees: -6 * envelope,
                         verticalOffset: -0.008 * sin(t * .pi * 4) * envelope,
                         scaleX: 1 + 0.012 * envelope, scaleY: 1 + 0.012 * envelope)
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

/// A character's visual vocabulary. Rendering stays in the shared SwiftUI view;
/// the core only describes a bounded gesture and its small local effect.
public enum BuddySignatureEffect: String, CaseIterable, Sendable {
    case dragonSpark, amberOrbit, tideBubble, starlight, cloudDrift, puddingBounce, swordArc, softGlow
}

public extension QuotaCharacter {
    var signatureEffect: BuddySignatureEffect {
        switch self {
        case .dragonGirl: .dragonSpark
        case .claudeGirl: .amberOrbit
        case .deepseekGirl: .tideBubble
        case .geminiGirl: .starlight
        case .cloudSprite: .cloudDrift
        case .nailong: .puddingBounce
        case .swordCat: .swordArc
        default: .softGlow
        }
    }

    var signatureAction: BuddyAction {
        switch self {
        case .dragonGirl: .spin
        case .claudeGirl: .wave
        case .deepseekGirl: .jump
        case .geminiGirl: .peek
        case .cloudSprite: .stretch
        case .nailong: .dance
        case .swordCat: .celebrate
        default: .nuzzle
        }
    }

    var signatureLabel: String {
        switch self {
        case .dragonGirl: "龙息星糖"
        case .claudeGirl: "暖光应援"
        case .deepseekGirl: "泡泡跃浪"
        case .geminiGirl: "星轨巡游"
        case .cloudSprite: "云朵轻飘"
        case .nailong: "弹弹肚皮"
        case .swordCat: "护你一剑"
        default: "暖心贴贴"
        }
    }

    var signatureSymbol: String {
        switch self {
        case .dragonGirl: "flame.fill"
        case .claudeGirl: "sun.max.fill"
        case .deepseekGirl: "drop.fill"
        case .geminiGirl: "star.fill"
        case .cloudSprite: "cloud.fill"
        case .nailong: "circle.inset.filled"
        case .swordCat: "shield.lefthalf.filled"
        default: "heart.fill"
        }
    }

    /// The signature appears in the quiet-time vocabulary without making every
    /// action identical. No autonomous vocabulary contains a synthetic meal.
    var companionActions: [BuddyAction] {
        var result: [BuddyAction] = []
        for action in [signatureAction, .stretch, .nuzzle, .peek, .sip, .wave, .nap, .celebrate] {
            if !result.contains(action) { result.append(action) }
        }
        return result
    }

    func signatureCaption(variant: Int = 0) -> String {
        let phrases: [String]
        switch self {
        case .dragonGirl: phrases = ["龙尾画个圈，送你一点勇气", "小小龙息，暖暖陪着你", "星糖闪一下，今天也加油"]
        case .claudeGirl: phrases = ["暖光绕一圈，为你轻轻鼓掌", "把这束暖光，留给认真开工的你", "挥挥手，今天也有我应援"]
        case .deepseekGirl: phrases = ["跃过小浪花，我们慢慢前进", "吹个泡泡，把紧张放轻一点", "蓝鲸陪着你，深呼吸一下"]
        case .geminiGirl: phrases = ["星轨转一圈，灵感来敲门", "耳朵动一下，听见你的努力啦", "送你一颗星，照亮眼前一小步"]
        case .cloudSprite: phrases = ["轻轻飘一下，肩膀也放松吧", "把烦恼放进云朵里歇一会儿", "云朵软软的，借你靠一下"]
        case .nailong: phrases = ["肚皮弹一弹，烦恼抖掉一点点", "奶龙陪你，慢慢来也很棒", "吨吨一下，给今天补点元气"]
        case .swordCat: phrases = ["小剑出鞘，替你挡住一点烦恼", "收剑站好，陪你稳稳往前走", "这一剑，斩掉一点点坏心情"]
        default: phrases = ["轻轻靠近，陪你慢慢来", "你忙你的，我会乖乖陪着", "送你一点小小的元气"]
        }
        let index = ((variant % phrases.count) + phrases.count) % phrases.count
        return phrases[index]
    }

    /// Character-specific gestures are sampled locally, then applied around the
    /// quota-derived anchor. They must never move the actual progress boundary.
    func motionSample(action: BuddyAction, progress: Double, reduceMotion: Bool = false) -> BuddyMotionSample {
        let base = action.motionSample(progress: progress, reduceMotion: reduceMotion)
        guard progress.isFinite, progress > 0, progress < 1, !reduceMotion else { return .rest }
        let envelope = pow(sin(progress * .pi), 2)
        let sway = sin(progress * .pi * 4)
        if action == .eating {
            switch self {
            case .nailong:
                return .init(verticalOffset: base.verticalOffset,
                             scaleX: 1 + 0.065 * abs(sway) * envelope,
                             scaleY: 1 - 0.035 * abs(sway) * envelope)
            case .swordCat:
                return .init(rotationDegrees: -3 * envelope, verticalOffset: base.verticalOffset)
            case .deepseekGirl:
                return .init(rotationDegrees: sway * 2 * envelope, verticalOffset: base.verticalOffset)
            default: return base
            }
        }
        guard action == signatureAction || action == .celebrate else { return base }
        switch signatureEffect {
        case .dragonSpark:
            return .init(rotationDegrees: sway * 13 * envelope,
                         horizontalOffset: sin(progress * .pi * 2) * 0.065 * envelope,
                         verticalOffset: -0.055 * envelope)
        case .amberOrbit:
            return .init(rotationDegrees: sin(progress * .pi * 6) * 5 * envelope,
                         verticalOffset: -0.015 * envelope,
                         scaleX: 1 + 0.028 * envelope, scaleY: 1 + 0.028 * envelope)
        case .tideBubble:
            return .init(rotationDegrees: sin(progress * .pi * 2) * 8 * envelope,
                         horizontalOffset: sin(progress * .pi * 2) * 0.055 * envelope,
                         verticalOffset: -0.17 * pow(sin(progress * .pi), 2))
        case .starlight:
            return .init(rotationDegrees: sway * 6 * envelope,
                         horizontalOffset: sin(progress * .pi * 2) * 0.075 * envelope,
                         verticalOffset: -0.026 * envelope,
                         scaleX: 1 + 0.045 * envelope, scaleY: 1 + 0.045 * envelope)
        case .cloudDrift:
            return .init(rotationDegrees: sin(progress * .pi * 2) * 3 * envelope,
                         horizontalOffset: sin(progress * .pi * 2) * 0.035 * envelope,
                         verticalOffset: -0.105 * envelope,
                         scaleX: 1 - 0.02 * envelope, scaleY: 1 + 0.035 * envelope)
        case .puddingBounce:
            let bounce = abs(sin(progress * .pi * 3)) * envelope
            return .init(rotationDegrees: sway * 4 * envelope,
                         verticalOffset: -0.085 * bounce,
                         scaleX: 1 + 0.115 * bounce, scaleY: 1 - 0.085 * bounce)
        case .swordArc:
            let slash = sin(progress * .pi * 2) * envelope
            return .init(rotationDegrees: slash * 19,
                         horizontalOffset: slash * 0.095,
                         verticalOffset: -0.055 * envelope,
                         scaleX: 1 + 0.025 * envelope, scaleY: 1 - 0.015 * envelope)
        case .softGlow: return base
        }
    }
}

/// Compares already validated, selected provider observations. The caller must invoke this
/// only when ingesting a real collector snapshot, never for a preview or a preference change.
public enum BuddyQuotaChange {
    /// Returns the observed decrease in percentage points, not an inferred token count.
    /// Missing cycle evidence is deliberately quiet rather than mistaking a reset for a meal.
    public static func consumption(from previous: QuotaPresentation, to next: QuotaPresentation) -> Double? {
        let allowedWindowIDs: [String]
        switch previous.provider {
        case .codex: allowedWindowIDs = ["primary", "secondary"]
        // These are the only windows emitted by the visible Claude usage parser.
        case .claude: allowedWindowIDs = ["session", "weekly", "sonnet-weekly"]
        default: return nil
        }
        guard previous.provider == next.provider,
              previous.freshness == .fresh, next.freshness == .fresh,
              let oldWindow = previous.window, let newWindow = next.window,
              allowedWindowIDs.contains(oldWindow.id), oldWindow.id == newWindow.id,
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

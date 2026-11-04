import Foundation

/// Local visibility and preference signals only. No chat or account content is used.
public struct BuddyCompanionContext: Equatable, Sendable {
    public var isVisible: Bool
    public var isBusy: Bool
    public var isSleeping: Bool
    public var reduceMotion: Bool
    public var isEnabled: Bool

    public init(isVisible: Bool = true, isBusy: Bool = false, isSleeping: Bool = false,
                reduceMotion: Bool = false, isEnabled: Bool = true) {
        self.isVisible = isVisible; self.isBusy = isBusy; self.isSleeping = isSleeping
        self.reduceMotion = reduceMotion; self.isEnabled = isEnabled
    }
}

public struct BuddyCompanionMoment: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case company, care }

    public let action: BuddyAction
    public let caption: String
    public let kind: Kind

    public init(action: BuddyAction, caption: String, kind: Kind = .company) {
        self.action = action; self.caption = caption; self.kind = kind
    }
}

/// One shared scheduler belongs to the model, never to an individual widget view.
/// Calling `tick` once a second does not continuously animate or poll any provider.
/// A seeded generator and injected dates make the complete behavior deterministic.
public struct BuddyCompanionSchedule: Equatable, Sendable {
    public static let careInterval: TimeInterval = 45 * 60
    public static let maximumTickGap: TimeInterval = 10

    public private(set) var nextDueAt: Date
    public private(set) var activeDuration: TimeInterval = 0
    private var lastTickAt: Date
    private var lastCareDuration: TimeInterval = 0
    private var lastAction: BuddyAction?
    private var sequence: Int = 0
    private var isPaused = false
    private var randomState: UInt64

    public init(now: Date = Date(), seed: UInt64 = UInt64.random(in: .min ... .max)) {
        let initialDate = Self.isFinite(now) ? now : Date(timeIntervalSince1970: 0)
        lastTickAt = initialDate
        nextDueAt = initialDate
        randomState = seed
        nextDueAt = initialDate.addingTimeInterval(delay(first: true))
    }

    /// Manual play and explicit selection changes restart the quiet period.
    /// Genuine consumption uses the busy context instead: repeatedly resetting
    /// this full interval would starve autonomous company during active usage.
    public mutating func postpone(after now: Date) {
        guard Self.isFinite(now) else { return }
        nextDueAt = now.addingTimeInterval(delay(first: false))
    }

    public mutating func tick(now: Date, context: BuddyCompanionContext = .init()) -> BuddyCompanionMoment? {
        guard Self.isFinite(now) else { return nil }
        let elapsed = now.timeIntervalSince(lastTickAt)
        lastTickAt = now
        let paused = !context.isVisible || context.isSleeping || context.reduceMotion || !context.isEnabled
        if paused {
            isPaused = true
            return nil
        }
        // Resume and clock jumps both start a fresh quiet interval. A suspended
        // process cannot accumulate missed care reminders or bursts of animations.
        if isPaused || elapsed < 0 || elapsed > Self.maximumTickGap {
            isPaused = false
            nextDueAt = now.addingTimeInterval(delay(first: true))
            return nil
        }
        activeDuration += elapsed
        if context.isBusy {
            nextDueAt = max(nextDueAt, now.addingTimeInterval(12))
            return nil
        }
        guard now >= nextDueAt else { return nil }
        nextDueAt = now.addingTimeInterval(delay(first: false))
        sequence &+= 1
        let moment: BuddyCompanionMoment
        if activeDuration - lastCareDuration >= Self.careInterval {
            lastCareDuration = activeDuration
            let action: BuddyAction = lastAction == .sip ? .stretch : .sip
            moment = .init(action: action,
                           caption: action == .sip ? "陪你一阵子啦，喝口水吧" : "伸伸懒腰，也看看远处吧",
                           kind: .care)
        } else {
            let choices: [BuddyAction] = [.stretch, .nuzzle, .peek, .sip, .wave, .nap, .celebrate]
                .filter { $0 != lastAction }
            let index = min(choices.count - 1, Int(unitRandom() * Double(choices.count)))
            let action = choices[index]
            let phrases = Self.phrases(for: action)
            let phraseIndex = sequence % phrases.count
            moment = .init(action: action, caption: phrases[phraseIndex])
        }
        lastAction = moment.action
        return moment
    }

    private mutating func delay(first: Bool) -> TimeInterval {
        first ? 35 + unitRandom() * 25 : 70 + unitRandom() * 60
    }

    private mutating func unitRandom() -> Double {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(randomState >> 11) / 9_007_199_254_740_992
    }

    private static func isFinite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }

    private static func phrases(for action: BuddyAction) -> [String] {
        switch action {
        case .stretch: ["伸个懒腰，再陪你一会儿", "肩膀放松一点点吧", "一起舒展一下，好不好"]
        case .nuzzle: ["蹭蹭你，给我一点关注嘛", "借一点点你的好心情", "忙完这小步，摸摸我好不好"]
        case .peek: ["探个头，你还好吗", "我有乖乖陪着你哦", "偷偷看看你，继续加油"]
        case .sip: ["我先喝一口，你也来一点", "喝口水，慢慢继续吧", "杯子碰一下，照顾好自己"]
        case .wave: ["挥挥手，我一直在这里", "抬头看我一眼就好", "今天也一起慢慢前进"]
        case .nap: ["靠在这里，陪你眯一会儿", "我打个小盹，醒来还陪你", "不着急，歇一下也可以"]
        default: ["认真投入的你，很闪亮", "送你一颗小小的星星", "已经走了一点点，很棒哦"]
        }
    }
}

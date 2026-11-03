import Foundation

/// A compact, readable footer response. It never implies points, affection levels,
/// token rewards or a change in the account's real quota.
public struct BuddyFeedbackMessage: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case encouragement, interaction, refresh, error
    }

    public let kind: Kind
    public let text: String
    public let symbol: String

    public init(kind: Kind, text: String, symbol: String) {
        self.kind = kind; self.text = text; self.symbol = symbol
    }
}

/// Transient feedback is driven by actual events, not the SwiftUI render clock.
/// Loading a stored snapshot or changing a preference must not call `didRefresh`.
/// The owner formats the observed time and supplies any persistent collection error.
public struct BuddyFeedbackState: Equatable, Sendable {
    public static let refreshDuration: TimeInterval = 2.4
    public static let interactionDuration: TimeInterval = 5.5

    public private(set) var lastObservedAt: Date?
    private var refreshVisibleUntil: Date?
    private var interactionVisibleUntil: Date?
    private var action: BuddyAction = .idle
    private var interactionSequence: Int = 0
    private var encouragementSequence: Int

    /// A persisted observation seeds replay protection without showing a refresh.
    public init(variant: Int = 0, observedAt: Date? = nil) {
        encouragementSequence = variant
        lastObservedAt = observedAt.flatMap { Self.isFinite($0) ? $0 : nil }
    }

    /// Invoke only after accepting a validated live collector observation.
    /// Duplicate/older observations never flash again, even after an intervening tap.
    @discardableResult
    public mutating func didRefresh(observedAt: Date, now: Date) -> Bool {
        guard Self.isFinite(observedAt), Self.isFinite(now),
              observedAt <= now.addingTimeInterval(60),
              lastObservedAt.map({ observedAt > $0 }) ?? true else { return false }
        lastObservedAt = observedAt
        refreshVisibleUntil = now.addingTimeInterval(Self.refreshDuration)
        encouragementSequence &+= 1
        return true
    }

    /// Every completed choice receives enough reading time, including reduced-motion
    /// interactions. The visual animation may finish earlier without removing its words.
    public mutating func interact(_ newAction: BuddyAction, now: Date) {
        guard newAction != .idle, Self.isFinite(now) else { return }
        action = newAction
        interactionVisibleUntil = now.addingTimeInterval(Self.interactionDuration)
        interactionSequence &+= 1
        encouragementSequence &+= 1
    }

    /// Error visibility is retained; otherwise a tap takes priority over the refresh flash.
    /// Identical calls return identical text, so ticking a clock cannot shuffle the footer.
    public func message(at now: Date, refreshTimeLabel: String, error: String? = nil) -> BuddyFeedbackMessage {
        if let error = error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return .init(kind: .error, text: error, symbol: "exclamationmark.circle")
        }
        if let until = interactionVisibleUntil, now < until {
            let phrases = Self.phrases(for: action)
            return .init(kind: .interaction, text: phrases[Self.index(interactionSequence, count: phrases.count)],
                         symbol: action.symbol)
        }
        if let until = refreshVisibleUntil, now < until {
            let time = refreshTimeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(kind: .refresh, text: time.isEmpty ? "额度已更新" : "刚刚更新 · \(time)", symbol: "arrow.clockwise")
        }
        let phrases = Self.phrases(for: .idle)
        return .init(kind: .encouragement,
                     text: phrases[Self.index(encouragementSequence, count: phrases.count)], symbol: "heart")
    }

    /// Schedule just the next visible phase boundary; no per-second timer is required.
    /// A refresh that expires beneath a longer interaction will not be replayed later.
    public func nextTransition(after now: Date) -> Date? {
        if let until = interactionVisibleUntil, until > now { return until }
        if let until = refreshVisibleUntil, until > now { return until }
        return nil
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    private static func index(_ value: Int, count: Int) -> Int {
        let remainder = value % count
        return remainder < 0 ? remainder + count : remainder
    }

    private static func phrases(for action: BuddyAction) -> [String] {
        switch action {
        case .idle:
            ["慢慢来，每一步都算数", "先做好眼前这一小步", "认真投入的你，很棒",
             "不用着急，按自己的节奏", "累了就歇一会儿", "今天也有一点点进步",
             "小小的坚持，也值得肯定", "照顾好自己，再继续"]
        case .eating:
            ["这一口，奖励认真开工", "饼干收到，你也要照顾自己", "补点能量，再慢慢向前"]
        case .pat:
            ["摸摸头，你已经很努力了", "今天的你，也值得被肯定", "别着急，我陪你慢慢来"]
        case .wave:
            ["我在这里，陪你一起开工", "挥挥手，把压力放轻一点", "新的一步，我们一起"]
        case .nap:
            ["闭闭眼，休息也是向前", "给自己一点喘息的时间", "不用一直绷紧，歇一下吧"]
        case .celebrate:
            ["你已经做得很棒了", "这一点点进步，也值得庆祝", "认真坚持的你，值得掌声"]
        case .jump:
            ["跳一下，给自己打打气", "向前一小步，也很了不起", "轻轻起跳，再稳稳落地"]
        case .dance:
            ["摇一摇，把紧绷放松一点", "跟着自己的节奏慢慢来", "让心情也松一口气"]
        case .spin:
            ["转个圈，换个轻松的思路", "暂时卡住，也没关系", "换个角度，再试一次"]
        }
    }
}

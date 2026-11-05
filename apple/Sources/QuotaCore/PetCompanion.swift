import Foundation

/// Care belongs to the pet. It never writes a quota or a provider's Token count.
public enum PetCareAction: String, Codable, Sendable, CaseIterable {
    case fruit, milk, playBall, groom, highFive, rest, explore
    public var buddyAction: BuddyAction {
        switch self {
        case .fruit: .eating
        case .milk: .sip
        case .playBall: .jump
        case .groom: .nuzzle
        case .highFive: .wave
        case .rest: .nap
        case .explore: .peek
        }
    }
    public var symbol: String {
        switch self {
        case .fruit: "carrot.fill"
        case .milk: "mug.fill"
        case .playBall: "basketball.fill"
        case .groom: "comb.fill"
        case .highFive: "hand.raised.fill"
        case .rest: "moon.zzz.fill"
        case .explore: "sparkle.magnifyingglass"
        }
    }
    public func title(language: YuliangLanguage = .system) -> String {
        switch self {
        case .fruit: petText("喂水果", "Fruit snack", "フルーツ", language)
        case .milk: petText("喝牛奶", "Warm milk", "ミルク", language)
        case .playBall: petText("玩小球", "Play ball", "ボール遊び", language)
        case .groom: petText("梳梳毛", "Groom", "ブラッシング", language)
        case .highFive: petText("击个掌", "High five", "ハイタッチ", language)
        case .rest: petText("一起休息", "Rest together", "ひと休み", language)
        case .explore: petText("寻小宝", "Treasure hunt", "宝探し", language)
        }
    }
    public func caption(language: YuliangLanguage = .system) -> String {
        switch self {
        case .fruit: petText("水果甜甜，陪伴也甜甜", "A sweet little snack together", "甘いフルーツ、やさしい時間", language)
        case .milk: petText("慢慢喝，你也补充点水吧", "A warm sip. Take one too?", "ゆっくり一口。あなたもどうぞ", language)
        case .playBall: petText("接住啦！换我传给你", "Got it! Your turn", "キャッチ！今度はあなたの番", language)
        case .groom: petText("毛茸茸的心情，整理好啦", "All cozy and cared for", "ふわふわ、すっきりしたよ", language)
        case .highFive: petText("啪！这一步做得很棒", "High five for your next small step", "パチン！小さな一歩もえらい", language)
        case .rest: petText("歇一会儿，我守着你", "Rest a while. I'll stay with you", "ひと休み。ここで待ってるね", language)
        case .explore: petText("找到一颗小星星，送给你", "Found a tiny star for you", "小さな星を見つけたよ", language)
        }
    }
}

public enum PetEvolutionSkin: String, Codable, Sendable, CaseIterable {
    case natural, starlight, aurora
    public var requiredLevel: Int { switch self { case .natural: 1; case .starlight: 3; case .aurora: 6 } }
    public func title(language: YuliangLanguage = .system) -> String {
        switch self {
        case .natural: petText("初遇", "Original", "はじまり", language)
        case .starlight: petText("星光伙伴", "Starlight", "星の友だち", language)
        case .aurora: petText("极光守护", "Aurora", "オーロラの守り", language)
        }
    }
}

public enum PetAchievement: String, Codable, Sendable, CaseIterable {
    case firstCare, variety, threeDays, tokenGrowth, firstEvolution, restful
    public var symbol: String {
        switch self {
        case .firstCare: "heart.fill"
        case .variety: "sparkles"
        case .threeDays: "calendar.badge.checkmark"
        case .tokenGrowth: "leaf.fill"
        case .firstEvolution: "star.fill"
        case .restful: "moon.stars.fill"
        }
    }
    public func title(language: YuliangLanguage = .system) -> String {
        switch self {
        case .firstCare: petText("初次照顾", "First care", "はじめてのお世話", language)
        case .variety: petText("花样陪伴", "Many ways to care", "いろんなふれあい", language)
        case .threeDays: petText("三日相伴", "Three days together", "三日間の友だち", language)
        case .tokenGrowth: petText("一起成长", "Growing together", "一緒に成長", language)
        case .firstEvolution: petText("星光初现", "First starlight", "はじめての星光", language)
        case .restful: petText("懂得休息", "Room to rest", "休むのも大切", language)
        }
    }
    public func detail(language: YuliangLanguage = .system) -> String {
        switch self {
        case .firstCare: petText("完成第一次照顾", "Care for a buddy once", "初めてのお世話をする", language)
        case .variety: petText("体验 5 种不同照顾", "Try five different care actions", "5種類のお世話を試す", language)
        case .threeDays: petText("在 3 个不同日期照顾伙伴", "Care on three different days", "別々の3日間にお世話をする", language)
        case .tokenGrowth: petText("记录到新的真实 Token 使用", "Observe new verified Token usage", "新しい実際のToken使用を記録", language)
        case .firstEvolution: petText("伙伴达到 3 级", "Reach buddy level 3", "レベル3になる", language)
        case .restful: petText("陪伙伴休息一次", "Rest together once", "一緒にひと休みする", language)
        }
    }
}

private func petText(_ zh: String, _ en: String, _ ja: String, _ language: YuliangLanguage) -> String {
    let resolved = language == .system ? YuliangL10n.language.resolved : language.resolved
    return resolved == .zhHans ? zh : resolved == .ja ? ja : en
}

public struct PetTokenObservation: Codable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let serverDayTokens: Int64?
    public let serverDay: String?
    public let observedAt: Date
    public init(lifetimeTokens: Int64?, serverDayTokens: Int64?, serverDay: String?, observedAt: Date) {
        self.lifetimeTokens = lifetimeTokens; self.serverDayTokens = serverDayTokens
        self.serverDay = serverDay; self.observedAt = observedAt
    }
}

public enum PetGrowthReason: String, Codable, Sendable {
    case care, cooldown, tokenGrowth, baseline, unchanged, rebased, invalid
}
public struct PetGrowthEvent: Equatable, Sendable {
    public let accepted: Bool
    public let experienceGained: Int
    public let newBadges: [PetAchievement]
    public let evolved: Bool
    public let reason: PetGrowthReason
    fileprivate init(_ reason: PetGrowthReason, accepted: Bool = false, experience: Int = 0,
                     badges: [PetAchievement] = [], evolved: Bool = false) {
        self.reason = reason; self.accepted = accepted; experienceGained = experience
        newBadges = badges; self.evolved = evolved
    }
}

public struct PetProfileSnapshot: Equatable, Sendable {
    public let level: Int
    public let experience: Int
    public let nextLevelExperience: Int
    public let levelProgress: Double
    public let satiety: Int
    public let energy: Int
    public let mood: Int
    public let bond: Int
    public let skin: PetEvolutionSkin
    public let unlockedSkins: [PetEvolutionSkin]
    public let badges: [PetAchievement]
    public let careCount: Int
    public let confirmedTokens: Int64
}

private struct PetProfileRecord: Codable, Equatable, Sendable {
    var experience = 0
    var satiety = 65
    var energy = 75
    var mood = 70
    var bond = 0
    var skin: PetEvolutionSkin = .natural
    var careCount = 0
    var confirmedTokens: Int64 = 0
    var tokenRemainder: Int64 = 0
    var lastCareAt: Date?
    var actionDates: [String: Date] = [:]
    var careDays: [String] = []
    var careTypes: [PetCareAction] = []
    var badges: [PetAchievement] = []
    var needUpdatedAt: Date
    var rewardDay = ""
    var careExperienceToday = 0
    var tokenExperienceToday = 0
    init(now: Date) { needUpdatedAt = now }
}

/// A small local journal, independent of quota.json. No historical account totals
/// are awarded on first use. Without an account identity, growth is deliberately
/// conservative: cumulative and same-day deltas must agree within ten minutes.
public struct PetCompanionState: Codable, Equatable, Sendable {
    public static let careExperienceDailyLimit = 24
    public static let tokenExperienceDailyLimit = 60
    public static let tokensPerExperience: Int64 = 5_000
    public static let maximumObservationGap: TimeInterval = 10 * 60
    public static let maximumExperience = 10_000
    public let version: Int
    private var profiles: [String: PetProfileRecord]
    private var tokenBaseline: PetTokenObservation?
    private static let thresholds = [0, 30, 80, 160, 280, 440, 650, 920, 1_250, 1_650]

    public init(now: Date = Date()) { version = 1; profiles = [:]; tokenBaseline = nil }

    public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 100_000, finite(now) else { throw QuotaError.oversized }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(Self.self, from: data)
        let latestAllowed = now.addingTimeInterval(300)
        guard value.tokenBaseline.map({ $0.observedAt <= latestAllowed }) ?? true,
              value.profiles.values.allSatisfy({ record in
                  record.needUpdatedAt <= latestAllowed
                      && (record.lastCareAt.map({ $0 <= latestAllowed }) ?? true)
                      && record.actionDates.values.allSatisfy({ $0 <= latestAllowed })
              }) else { throw QuotaError.invalid("宠物成长记录包含未来时间，已保留原文件。") }
        return value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 100_000 else { throw QuotaError.oversized }
        return data
    }

    public func profile(for character: QuotaCharacter, now: Date = Date()) -> PetProfileSnapshot {
        let record = profiles[character.rawValue] ?? PetProfileRecord(now: now)
        let level = Self.level(record.experience)
        let floor = Self.thresholds[level - 1]
        let ceiling = level < Self.thresholds.count ? Self.thresholds[level] : Self.maximumExperience
        let needs = Self.needs(record, now: now)
        return .init(level: level, experience: record.experience, nextLevelExperience: ceiling,
                     levelProgress: level == Self.thresholds.count ? 1 : Double(record.experience - floor) / Double(ceiling - floor),
                     satiety: needs.0, energy: needs.1, mood: needs.2, bond: record.bond,
                     skin: record.skin, unlockedSkins: PetEvolutionSkin.allCases.filter { $0.requiredLevel <= level },
                     badges: record.badges, careCount: record.careCount, confirmedTokens: record.confirmedTokens)
    }

    public func cooldownRemaining(for action: PetCareAction, character: QuotaCharacter, now: Date = Date()) -> TimeInterval {
        guard Self.finite(now), let record = profiles[character.rawValue] else { return 0 }
        let any = record.lastCareAt.map { max(0, 10 - now.timeIntervalSince($0)) } ?? 0
        let same = record.actionDates[action.rawValue].map { max(0, 90 - now.timeIntervalSince($0)) } ?? 0
        return max(any, same)
    }

    @discardableResult public mutating func care(_ action: PetCareAction, character: QuotaCharacter, now: Date = Date()) -> PetGrowthEvent {
        guard Self.finite(now) else { return .init(.invalid) }
        guard cooldownRemaining(for: action, character: character, now: now) <= 0 else { return .init(.cooldown) }
        var record = profiles[character.rawValue] ?? PetProfileRecord(now: now)
        guard now >= record.needUpdatedAt else { return .init(.invalid) }
        Self.updateDay(&record, now: now)
        let needs = Self.needs(record, now: now)
        record.satiety = needs.0; record.energy = needs.1; record.mood = needs.2
        record.needUpdatedAt = now
        switch action {
        case .fruit: record.satiety += 16; record.mood += 5
        case .milk: record.satiety += 8; record.energy += 8
        case .playBall: record.mood += 15; record.energy -= 5
        case .groom: record.mood += 10
        case .highFive: record.mood += 8
        case .rest: record.energy += 22; record.mood += 5
        case .explore: record.mood += 10; record.energy -= 3
        }
        record.satiety = min(100, max(0, record.satiety))
        record.energy = min(100, max(0, record.energy))
        record.mood = min(100, max(0, record.mood))
        record.lastCareAt = now; record.actionDates[action.rawValue] = now
        record.careCount = min(1_000_000, record.careCount + 1)
        let day = Self.day(now)
        if !record.careDays.contains(day) { record.careDays.append(day) }
        // Only three days are needed; retaining a lifetime daily log is unnecessary.
        record.careDays = Array(record.careDays.suffix(3))
        if !record.careTypes.contains(action) { record.careTypes.append(action) }
        let experience = min(3, Self.careExperienceDailyLimit - record.careExperienceToday)
        record.careExperienceToday += experience
        if experience > 0 { record.bond = min(100, record.bond + 2) }
        var earned: [PetAchievement] = [.firstCare]
        if record.careTypes.count >= 5 { earned.append(.variety) }
        if record.careDays.count >= 3 { earned.append(.threeDays) }
        if action == .rest { earned.append(.restful) }
        let event = Self.award(experience, to: &record, badges: earned, reason: .care)
        profiles[character.rawValue] = record
        return event
    }

    @discardableResult public mutating func observe(_ observation: PetTokenObservation, character: QuotaCharacter) -> PetGrowthEvent {
        guard Self.valid(observation) else { return .init(.invalid) }
        guard let before = tokenBaseline else { tokenBaseline = observation; return .init(.baseline) }
        guard observation.observedAt > before.observedAt else { return .init(.unchanged) }
        tokenBaseline = observation
        guard let lifetime = observation.lifetimeTokens, let previousLifetime = before.lifetimeTokens,
              let daily = observation.serverDayTokens, let previousDaily = before.serverDayTokens,
              observation.serverDay == before.serverDay,
              observation.observedAt.timeIntervalSince(before.observedAt) <= Self.maximumObservationGap,
              lifetime >= previousLifetime, daily >= previousDaily else { return .init(.rebased) }
        let delta = lifetime - previousLifetime
        guard delta == daily - previousDaily else { return .init(.rebased) }
        guard delta > 0 else { return .init(.unchanged) }
        var record = profiles[character.rawValue] ?? PetProfileRecord(now: observation.observedAt)
        guard observation.observedAt >= record.needUpdatedAt else { return .init(.rebased) }
        Self.updateDay(&record, now: observation.observedAt)
        record.confirmedTokens = Self.saturatingAdd(record.confirmedTokens, delta)
        let whole = delta / Self.tokensPerExperience
        let remainder = delta % Self.tokensPerExperience + record.tokenRemainder
        let points = whole + remainder / Self.tokensPerExperience
        record.tokenRemainder = remainder % Self.tokensPerExperience
        let experience = Int(min(Int64(Self.tokenExperienceDailyLimit - record.tokenExperienceToday), points))
        record.tokenExperienceToday += experience
        // Fullness is a pet state, not a statement about subscription quota.
        record.satiety = min(100, record.satiety + min(4, experience))
        record.mood = min(100, record.mood + min(2, experience))
        let event = Self.award(experience, to: &record, badges: [.tokenGrowth], reason: .tokenGrowth)
        profiles[character.rawValue] = record
        return event
    }

    @discardableResult public mutating func chooseSkin(_ skin: PetEvolutionSkin, character: QuotaCharacter, now: Date = Date()) -> Bool {
        guard Self.finite(now) else { return false }
        var record = profiles[character.rawValue] ?? PetProfileRecord(now: now)
        guard skin.requiredLevel <= Self.level(record.experience) else { return false }
        record.skin = skin
        profiles[character.rawValue] = record
        return true
    }

    private static func award(_ experience: Int, to record: inout PetProfileRecord,
                              badges requested: [PetAchievement], reason: PetGrowthReason) -> PetGrowthEvent {
        let previous = record.experience
        let previousLevel = level(previous)
        record.experience = min(maximumExperience, previous + max(0, experience))
        let newLevel = level(record.experience)
        var candidates = requested
        if newLevel >= 3 { candidates.append(.firstEvolution) }
        let badges = candidates.filter { !record.badges.contains($0) }
        record.badges.append(contentsOf: badges)
        let evolution = PetEvolutionSkin.allCases.last { $0.requiredLevel <= newLevel && $0.requiredLevel > previousLevel }
        if let evolution { record.skin = evolution }
        return .init(reason, accepted: true, experience: record.experience - previous, badges: badges, evolved: evolution != nil)
    }
    private static func level(_ experience: Int) -> Int { (thresholds.lastIndex { experience >= $0 } ?? 0) + 1 }
    private static func finite(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) < 253_402_300_800 }
    private static func day(_ date: Date) -> String { String(Int64(floor(date.timeIntervalSince1970 / 86_400))) }
    private static func updateDay(_ record: inout PetProfileRecord, now: Date) {
        let current = day(now)
        if record.rewardDay != current {
            record.rewardDay = current; record.careExperienceToday = 0; record.tokenExperienceToday = 0
        }
    }
    private static func needs(_ record: PetProfileRecord, now: Date) -> (Int, Int, Int) {
        let elapsed = finite(now) ? max(0, min(12 * 3_600, now.timeIntervalSince(record.needUpdatedAt))) : 0
        let hours = Int(elapsed / 3_600)
        // Offline time has a small, bounded effect. A pet never becomes distressed
        // because its owner did not open the app, and no pushy penalty is awarded.
        return (max(25, record.satiety - hours * 2), max(30, record.energy - hours), max(35, record.mood - hours))
    }
    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }
    private static func valid(_ value: PetTokenObservation) -> Bool {
        guard finite(value.observedAt), let total = value.lifetimeTokens, let daily = value.serverDayTokens,
              total >= 0, daily >= 0, daily <= total, let day = value.serverDay,
              day.count == 10, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let parsed = try? QuotaDate.parse(day + "T00:00:00Z") else { return false }
        return finite(parsed)
    }

    private enum CodingKeys: String, CodingKey { case version, profiles, tokenBaseline }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        profiles = try values.decode([String: PetProfileRecord].self, forKey: .profiles)
        tokenBaseline = try values.decodeIfPresent(PetTokenObservation.self, forKey: .tokenBaseline)
        guard version == 1, profiles.count <= QuotaCharacter.allCases.count,
              tokenBaseline.map(Self.valid) ?? true else { throw QuotaError.invalid("宠物成长记录版本或用量基线无法验证。") }
        for (key, value) in profiles {
            guard QuotaCharacter(rawValue: key) != nil, (0...Self.maximumExperience).contains(value.experience),
                  (0...100).contains(value.satiety), (0...100).contains(value.energy), (0...100).contains(value.mood),
                  (0...100).contains(value.bond), (0...1_000_000).contains(value.careCount), value.confirmedTokens >= 0,
                  (0..<Self.tokensPerExperience).contains(value.tokenRemainder), Self.finite(value.needUpdatedAt),
                  value.lastCareAt.map(Self.finite) ?? true,
                  value.actionDates.count <= PetCareAction.allCases.count,
                  value.actionDates.allSatisfy({ PetCareAction(rawValue: $0.key) != nil && Self.finite($0.value) }),
                  value.careDays.count <= 3, Set(value.careDays).count == value.careDays.count,
                  value.careDays.allSatisfy({ Int64($0) != nil }),
                  value.rewardDay.isEmpty || Int64(value.rewardDay) != nil,
                  value.careTypes.count <= PetCareAction.allCases.count, Set(value.careTypes).count == value.careTypes.count,
                  value.badges.count <= PetAchievement.allCases.count, Set(value.badges).count == value.badges.count,
                  (0...Self.careExperienceDailyLimit).contains(value.careExperienceToday),
                  (0...Self.tokenExperienceDailyLimit).contains(value.tokenExperienceToday),
                  value.skin.requiredLevel <= Self.level(value.experience)
            else { throw QuotaError.invalid("宠物成长记录无法验证，已保留原文件。") }
        }
    }
}

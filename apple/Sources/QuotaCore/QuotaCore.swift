import Foundation

/// Subscription snapshots preserve observed percentages rather than inferred token counts.
/// Sources are bound to their provider: browser-visible fields or Codex app-server rate limits.
public enum QuotaProvider: String, Codable, Sendable, CaseIterable {
    case chatgpt, claude, codex
    public var name: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Original buddies ship with the open-source edition. Legacy identifiers remain
/// decodable so a local theme choice never invalidates an existing quota store.
public enum QuotaCharacter: String, Codable, Sendable, CaseIterable {
    case mochiCat, butterBunny, mintFox, sesameBear, dragonGirl, cloudSprite
    case claudeGirl, deepseekGirl, geminiGirl
    case kuromi, myMelody

    public static let builtInCharacters: [Self] = [.dragonGirl, .claudeGirl, .deepseekGirl, .geminiGirl,
        .mochiCat, .butterBunny, .mintFox, .sesameBear, .cloudSprite]
    /// Newly drawn themes, not a statement of endorsement by model providers.
    public static let originalCharacters: [Self] = builtInCharacters
    public var isOriginal: Bool { Self.originalCharacters.contains(self) }
    public var name: String {
        switch self {
        case .mochiCat: "团子猫"
        case .butterBunny: "奶油兔"
        case .mintFox: "薄荷狐"
        case .sesameBear: "芝麻熊"
        case .dragonGirl: "星糖龙娘"
        case .cloudSprite: "云朵精灵"
        case .claudeGirl: "橘光学姐"
        case .deepseekGirl: "蓝鲸少女"
        case .geminiGirl: "星喵少女"
        case .kuromi: "库洛米"
        case .myMelody: "美乐蒂"
        }
    }
    public var accentHex: String {
        switch self {
        case .mochiCat, .kuromi: "#6B4F8F"
        case .butterBunny, .myMelody: "#BD4F75"
        case .mintFox: "#3C8073"
        case .sesameBear: "#8B6650"
        case .dragonGirl: "#8462B1"
        case .cloudSprite: "#4C88A8"
        case .claudeGirl: "#C66D4F"
        case .deepseekGirl: "#477DBC"
        case .geminiGirl: "#7369B5"
        }
    }
    /// Cycling returns to the built-in catalog, including from a legacy local theme.
    public var next: Self {
        guard let index = Self.builtInCharacters.firstIndex(of: self) else { return .dragonGirl }
        return Self.builtInCharacters[(index + 1) % Self.builtInCharacters.count]
    }
}

public enum QuotaError: Error, Equatable, LocalizedError, Sendable {
    case oversized, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .oversized: "采集记录不能超过 100 KB。"
        case .invalid(let message): message
        }
    }
}

/// Dates are encoded as UTC ISO 8601 strings, matching the existing browser schema.
public enum QuotaDate {
    public static func parse(_ value: String) throws -> Date {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range), match.range == range else {
            throw QuotaError.invalid("时间必须包含完整日期、秒和时区。")
        }
        func field(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        guard let year = field(1), let month = field(2), let day = field(3),
              let hour = field(4), let minute = field(5), let second = field(6),
              year >= 1, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { throw QuotaError.invalid("时间包含无效的日期或时刻。") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let calendarDate = calendar.date(from: components),
              calendar.component(.year, from: calendarDate) == year,
              calendar.component(.month, from: calendarDate) == month,
              calendar.component(.day, from: calendarDate) == day else {
            throw QuotaError.invalid("时间包含不存在的日期。")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let result = formatter.date(from: value), result.timeIntervalSince1970.isFinite else {
            throw QuotaError.invalid("时间或时区无效。")
        }
        return result
    }

    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private func text(_ value: String, name: String, max: Int, empty: Bool = false) throws -> String {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count <= max, empty || !clean.isEmpty else { throw QuotaError.invalid("\(name)格式无效。") }
    return clean
}

private func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 100 && value.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil
}

public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double?
    public var resetAt: Date?
    public var resetLabel: String?
    public var note: String?
    /// Native storage retains each window's own sample time when a batch omits it.
    /// A new observation for a different window must not freshen this one.
    public var observedAt: Date?

    public init(id: String, label: String, usedPercent: Double?, resetAt: Date? = nil,
                resetLabel: String? = nil, note: String? = nil, observedAt: Date? = nil) {
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.resetAt = resetAt
        self.resetLabel = resetLabel; self.note = note; self.observedAt = observedAt
    }

    public var remainingPercent: Double? { usedPercent.map { 100 - $0 } }

    enum CodingKeys: String, CodingKey { case id, label, usedPercent, resetAt, resetLabel, note, observedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        usedPercent = try values.decodeIfPresent(Double.self, forKey: .usedPercent)
        resetAt = try values.decodeIfPresent(String.self, forKey: .resetAt).map(QuotaDate.parse)
        observedAt = try values.decodeIfPresent(String.self, forKey: .observedAt).map(QuotaDate.parse)
        resetLabel = try values.decodeIfPresent(String.self, forKey: .resetLabel)
        note = try values.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(label, forKey: .label)
        if let usedPercent { try values.encode(usedPercent, forKey: .usedPercent) } else { try values.encodeNil(forKey: .usedPercent) }
        if let resetAt { try values.encode(QuotaDate.string(resetAt), forKey: .resetAt) } else { try values.encodeNil(forKey: .resetAt) }
        try values.encodeIfPresent(resetLabel, forKey: .resetLabel); try values.encodeIfPresent(note, forKey: .note)
        if let observedAt { try values.encode(QuotaDate.string(observedAt), forKey: .observedAt) }
    }

    fileprivate func validated(provider: QuotaProvider, envelopeDate: Date, now: Date) throws -> Self {
        let allowed: [String]
        switch provider {
        case .claude: allowed = ["session", "weekly", "sonnet-weekly"]
        case .chatgpt: allowed = ["notice"]
        case .codex: allowed = ["primary", "secondary"]
        }
        guard allowed.contains(id) else { throw QuotaError.invalid("此服务不支持该额度窗口。") }
        if let usedPercent, !usedPercent.isFinite || !(0...100).contains(usedPercent) {
            throw QuotaError.invalid("已用百分比必须在 0 至 100 之间。")
        }
        guard provider != .chatgpt || usedPercent == nil else {
            throw QuotaError.invalid("ChatGPT 限制提示不能推算统一百分比。")
        }
        let date = observedAt ?? envelopeDate
        guard date.timeIntervalSince1970.isFinite, date <= now.addingTimeInterval(60), date <= envelopeDate else {
            throw QuotaError.invalid("额度窗口的采样时间无效。")
        }
        if let resetAt, !resetAt.timeIntervalSince1970.isFinite { throw QuotaError.invalid("重置时间无效。") }
        return .init(id: id, label: try text(label, name: "额度窗口", max: 80), usedPercent: usedPercent,
                     resetAt: resetAt,
                     resetLabel: try resetLabel.map { try text($0, name: "重置说明", max: 120, empty: true) },
                     note: try note.map { try text($0, name: "备注", max: 500, empty: true) }, observedAt: date)
    }
}

public struct SnapshotEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var providerId: QuotaProvider
    public var pageKind: String
    public var observedAt: Date
    public var source: String
    public var windows: [QuotaWindow]
    public var parserVersion: Int
    public var id: String?

    public init(schemaVersion: Int = 1, providerId: QuotaProvider, pageKind: String, observedAt: Date,
                source: String = "browser", windows: [QuotaWindow], parserVersion: Int = 1, id: String? = nil) {
        self.schemaVersion = schemaVersion; self.providerId = providerId; self.pageKind = pageKind
        self.observedAt = observedAt; self.source = source; self.windows = windows; self.parserVersion = parserVersion; self.id = id
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, providerId, pageKind, observedAt, source, windows, parserVersion, id }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Existing extension records predate an explicit envelope schemaVersion.
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        providerId = try values.decode(QuotaProvider.self, forKey: .providerId)
        pageKind = try values.decode(String.self, forKey: .pageKind)
        observedAt = try QuotaDate.parse(values.decode(String.self, forKey: .observedAt))
        source = try values.decode(String.self, forKey: .source)
        windows = try values.decode([QuotaWindow].self, forKey: .windows)
        parserVersion = try values.decode(Int.self, forKey: .parserVersion)
        id = try values.decodeIfPresent(String.self, forKey: .id)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(providerId, forKey: .providerId)
        try values.encode(pageKind, forKey: .pageKind); try values.encode(QuotaDate.string(observedAt), forKey: .observedAt)
        try values.encode(source, forKey: .source); try values.encode(windows, forKey: .windows)
        try values.encode(parserVersion, forKey: .parserVersion); try values.encodeIfPresent(id, forKey: .id)
    }

    /// Decode only known fields, validate provider/source evidence, and drop extra input fields.
    public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 100_000 else { throw QuotaError.oversized }
        return try JSONDecoder().decode(Self.self, from: data).validated(now: now)
    }

    public func validated(now: Date = Date()) throws -> Self {
        let expectedSource: String
        let expectedPageKind: String
        switch providerId {
        case .claude: expectedSource = "browser"; expectedPageKind = "usage"
        case .chatgpt: expectedSource = "browser"; expectedPageKind = "limit-notice"
        case .codex: expectedSource = "codex-app-server"; expectedPageKind = "rate-limits"
        }
        guard schemaVersion == 1, parserVersion == 1, source == expectedSource,
              pageKind == expectedPageKind else {
            throw QuotaError.invalid("记录版本、来源或页面类型不受支持。")
        }
        guard observedAt.timeIntervalSince1970.isFinite, observedAt <= now.addingTimeInterval(60) else {
            throw QuotaError.invalid("采样时间不能来自未来。")
        }
        guard !windows.isEmpty, windows.count <= 16, Set(windows.map(\.id)).count == windows.count else {
            throw QuotaError.invalid("额度窗口为空、过多或重复。")
        }
        if let id, !identifier(id) { throw QuotaError.invalid("记录 ID 无效。") }
        var result = self
        result.windows = try windows.map { try $0.validated(provider: providerId, envelopeDate: observedAt, now: now) }
        return result
    }
}

public struct QuotaPreferences: Codable, Equatable, Sendable {
    public var providerId: QuotaProvider
    public var character: QuotaCharacter
    public var reactionAt: Date?
    /// An explicit selection belongs to providerId. Switching services clears it.
    public var windowId: String?
    public init(providerId: QuotaProvider = .claude, character: QuotaCharacter = .dragonGirl, reactionAt: Date? = nil,
                windowId: String? = nil) {
        self.providerId = providerId; self.character = character; self.reactionAt = reactionAt; self.windowId = windowId
    }
    enum CodingKeys: String, CodingKey { case providerId, character, reactionAt, windowId }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try values.decodeIfPresent(QuotaProvider.self, forKey: .providerId) ?? .claude
        character = try values.decodeIfPresent(QuotaCharacter.self, forKey: .character) ?? .dragonGirl
        reactionAt = try values.decodeIfPresent(String.self, forKey: .reactionAt).map(QuotaDate.parse)
        windowId = try values.decodeIfPresent(String.self, forKey: .windowId)
        if let windowId, !["session", "weekly", "sonnet-weekly", "notice", "primary", "secondary"].contains(windowId) {
            throw QuotaError.invalid("所选额度窗口不受支持。")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerId, forKey: .providerId); try values.encode(character, forKey: .character)
        if let reactionAt { try values.encode(QuotaDate.string(reactionAt), forKey: .reactionAt) }
        try values.encodeIfPresent(windowId, forKey: .windowId)
    }
}

public struct QuotaStoreDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var records: [SnapshotEnvelope]
    public var preferences: QuotaPreferences
    public init(records: [SnapshotEnvelope] = [], preferences: QuotaPreferences = .init()) {
        schemaVersion = 1; self.records = records; self.preferences = preferences
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 100_000 else { throw QuotaError.oversized }
        var document = try JSONDecoder().decode(Self.self, from: data)
        guard document.schemaVersion == 1, document.records.count <= 3,
              Set(document.records.map(\.providerId)).count == document.records.count else {
            throw QuotaError.invalid("本机快照版本或服务列表无效。")
        }
        document.records = try document.records.map { try $0.validated(now: now) }
        return document
    }

    public func encoded(now: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let validated = try Self.decode(encoder.encode(self), now: now)
        return try encoder.encode(validated)
    }

    /// Only a genuinely later sample freshens its corresponding windows. A replay does not.
    /// An unchanged percentage is still a new confirmed observation when observedAt advances;
    /// it must not age into a false stale state while collection is working. A repeated
    /// relative browser reset label never moves that window's original reset anchor forward.
    /// Codex app-server supplies absolute resets, so a newer official reset replaces the old one.
    @discardableResult public mutating func merge(_ snapshot: SnapshotEnvelope, now: Date = Date()) throws -> Bool {
        let incoming = try snapshot.validated(now: now)
        guard let index = records.firstIndex(where: { $0.providerId == incoming.providerId }) else {
            records.append(incoming); records.sort { $0.providerId.rawValue < $1.providerId.rawValue }; return true
        }
        var stored = try records[index].validated(now: now)
        var changed = false
        for var window in incoming.windows {
            guard let windowIndex = stored.windows.firstIndex(where: { $0.id == window.id }) else {
                stored.windows.append(window); changed = true; continue
            }
            let previous = stored.windows[windowIndex]
            guard let incomingDate = window.observedAt, let previousDate = previous.observedAt, incomingDate > previousDate else { continue }
            if incoming.source == "browser", let label = window.resetLabel, !label.isEmpty, label == previous.resetLabel {
                window.resetAt = previous.resetAt
            }
            stored.windows[windowIndex] = window; changed = true
        }
        guard changed else { return false }
        stored.observedAt = stored.windows.compactMap(\.observedAt).max() ?? stored.observedAt
        stored.id = incoming.id
        records[index] = stored
        return true
    }
}

public enum QuotaFreshness: String, Codable, Sendable { case missing, fresh, stale, resetDue }
public enum QuotaSatiety: String, Codable, Sendable {
    case unknown, hungry, snacking, satisfied, full
    public var label: String {
        switch self {
        case .unknown: "等待开饭"
        case .hungry: "饿肚子"
        case .snacking: "吃几口"
        case .satisfied: "很满足"
        case .full: "吃饱啦"
        }
    }
    public var frame: Int {
        switch self { case .unknown, .hungry: 0; case .snacking: 1; case .satisfied: 2; case .full: 3 }
    }
}

/// Presentation never increments usage, resets a balance, or changes an observation timestamp.
/// Both the host App and WidgetKit timeline should use this same value at their own `now`.
public struct QuotaPresentation: Equatable, Sendable {
    public var provider: QuotaProvider
    public var window: QuotaWindow?
    public var remainingPercent: Double? { window?.remainingPercent }
    public var usedPercent: Double? { window?.usedPercent }
    public var observedAt: Date?
    public var resetAt: Date? { window?.resetAt }
    public var freshness: QuotaFreshness
    public var satiety: QuotaSatiety

    public init(document: QuotaStoreDocument, provider: QuotaProvider? = nil, windowId: String? = nil, now: Date = Date(), staleAfter: TimeInterval = 6 * 3_600) {
        let selectedProvider = provider ?? document.preferences.providerId
        self.provider = selectedProvider
        let record = document.records.first { $0.providerId == selectedProvider }
        let requestedWindow = windowId ?? (selectedProvider == document.preferences.providerId ? document.preferences.windowId : nil)
        let defaultWindow: String
        switch selectedProvider {
        case .claude: defaultWindow = "session"
        case .chatgpt: defaultWindow = "notice"
        case .codex: defaultWindow = "primary"
        }
        let preferred = requestedWindow ?? defaultWindow
        // Preserve the legacy browser fallback. Codex windows are official identifiers,
        // not aliases for fixed durations; a missing primary cannot borrow secondary.
        window = record?.windows.first { $0.id == preferred }
            ?? (requestedWindow == nil && selectedProvider != .codex ? record?.windows.first : nil)
        observedAt = window?.observedAt ?? (window == nil ? nil : record?.observedAt)
        if let observedAt {
            if let resetAt = window?.resetAt, resetAt <= now { freshness = .resetDue }
            else if now.timeIntervalSince(observedAt) >= staleAfter { freshness = .stale }
            else { freshness = .fresh }
        } else { freshness = .missing }
        if let used = window?.usedPercent {
            satiety = used >= 90 ? .full : used >= 60 ? .satisfied : used >= 25 ? .snacking : .hungry
        } else { satiety = .unknown }
    }
}

import Foundation
import CoreFoundation

/// Account token activity returned by `account/usage/read`; unrelated to quota percentages.
/// Daily dates have no documented timezone, so `todayTokens` deliberately remains unknown.
struct TokenUsageSnapshot: Equatable, Sendable {
    let todayTokens: Int64?
    let serverDayTokens: Int64?
    let serverDay: String?
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let longestRunningTurnSec: Int64?
    let observedAt: Date
    let sourceLabel: String

    static func decode(_ data: Data, observedAt: Date) throws -> TokenUsageSnapshot {
        guard data.count <= 100_000,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = result["summary"] as? [String: Any] else {
            throw TokenUsageValidationError.invalidResponse
        }
        let lifetime = try nonnegativeInteger(summary["lifetimeTokens"])
        let peak = try nonnegativeInteger(summary["peakDailyTokens"])
        let streak = try nonnegativeInteger(summary["currentStreakDays"])
        let longestStreak = try nonnegativeInteger(summary["longestStreakDays"])
        let longestTurn = try nonnegativeInteger(summary["longestRunningTurnSec"])
        var daily: [String: Int64] = [:]
        if let raw = result["dailyUsageBuckets"], !(raw is NSNull) {
            guard let buckets = raw as? [[String: Any]], buckets.count <= 3_660 else {
                throw TokenUsageValidationError.invalidResponse
            }
            for bucket in buckets {
                guard let date = bucket["startDate"] as? String, validDate(date), daily[date] == nil,
                      let count = try nonnegativeInteger(bucket["tokens"]) else {
                    throw TokenUsageValidationError.invalidResponse
                }
                daily[date] = count
            }
        }
        let latestDay = daily.keys.max()
        return TokenUsageSnapshot(todayTokens: nil,
                                  serverDayTokens: latestDay.flatMap { daily[$0] }, serverDay: latestDay,
                                  lifetimeTokens: lifetime, peakDailyTokens: peak,
                                  currentStreakDays: streak, longestStreakDays: longestStreak,
                                  longestRunningTurnSec: longestTurn, observedAt: observedAt,
                                  sourceLabel: "Codex 账号用量 · 服务端日统计")
    }

    /// Keep int64 exact, including values above Double's 53-bit integer precision.
    private static func nonnegativeInteger(_ raw: Any?) throws -> Int64? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw TokenUsageValidationError.invalidResponse }
        let decimal = number.decimalValue
        guard decimal >= 0, decimal <= Decimal(Int64.max) else { throw TokenUsageValidationError.invalidResponse }
        let integer = NSDecimalNumber(decimal: decimal).int64Value
        guard Decimal(integer) == decimal else { throw TokenUsageValidationError.invalidResponse }
        return integer
    }

    private static func validDate(_ raw: String) -> Bool {
        guard raw.utf8.count == 10, raw.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9_999).contains(parts[0]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let values = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: values) else { return false }
        let decoded = calendar.dateComponents([.year, .month, .day], from: date)
        return decoded.year == parts[0] && decoded.month == parts[1] && decoded.day == parts[2]
    }
}

enum TokenUsageReadingState: Equatable, Sendable {
    case unknown, available, unsupported, unavailable, loginRequired, rateLimited, invalid
}

enum TokenUsageValidationError: Error {
    case invalidResponse
}

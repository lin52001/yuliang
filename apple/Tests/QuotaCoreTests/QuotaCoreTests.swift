import Foundation
import Testing
@testable import QuotaCore

struct QuotaCoreTests {
    let now = Date(timeIntervalSince1970: 1_793_649_600) // 2026-11-02T16:00:00Z

    func snapshot(provider: QuotaProvider = .claude, used: Double? = 38,
                  at: Date? = nil, reset: Date? = nil, label: String? = nil,
                  windows: [QuotaWindow]? = nil) -> SnapshotEnvelope {
        .init(providerId: provider, pageKind: provider == .claude ? "usage" : "limit-notice",
              observedAt: at ?? now, windows: windows ?? [
                .init(id: provider == .claude ? "session" : "notice", label: "当前时段",
                      usedPercent: used, resetAt: reset, resetLabel: label)
              ], id: "auto-test")
    }

    func codexSnapshot(at: Date? = nil, windows: [QuotaWindow]? = nil) -> SnapshotEnvelope {
        .init(providerId: .codex, pageKind: "rate-limits", observedAt: at ?? now,
              source: "codex-app-server", windows: windows ?? [
                .init(id: "primary", label: "主窗口 · 7天", usedPercent: 42,
                      resetAt: now.addingTimeInterval(86_400))
              ], id: "codex-test")
    }

    func data(_ value: SnapshotEnvelope) throws -> Data { try JSONEncoder().encode(value) }
    func replacing(_ key: String, with value: Any, in snapshot: SnapshotEnvelope? = nil) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data(snapshot ?? self.snapshot())) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func testExtensionCompatibleDecodeAndWhitelistOutput() throws {
        var object = try #require(JSONSerialization.jsonObject(with: data(snapshot())) as? [String: Any])
        object.removeValue(forKey: "schemaVersion") // Existing extension record.
        object["cookie"] = "SHOULD-NOT-SURVIVE"
        object["url"] = "https://example.invalid/private"
        let decoded = try SnapshotEnvelope.decode(JSONSerialization.data(withJSONObject: object), now: now)
        expectEqual(decoded.schemaVersion, 1)
        expectEqual(decoded.windows[0].remainingPercent, 62)
        expectEqual(decoded.windows[0].observedAt, now)
        let encoded = String(decoding: try data(decoded), as: UTF8.self)
        expectFalse(encoded.contains("SHOULD-NOT-SURVIVE"))
        expectFalse(encoded.contains("example.invalid"))
    }

    @Test func testUnknownRemainsUnknownAndChatGPTCannotHavePercentage() throws {
        let unknown = try SnapshotEnvelope.decode(data(snapshot(provider: .chatgpt, used: nil)), now: now)
        let presentation = QuotaPresentation(document: .init(records: [unknown]), provider: .chatgpt, now: now)
        expectNil(presentation.remainingPercent)
        expectNil(presentation.usedPercent)
        expectEqual(presentation.satiety, .unknown)
        expectEqual(presentation.freshness, .fresh)
        expectThrows(try SnapshotEnvelope.decode(data(snapshot(provider: .chatgpt, used: 0)), now: now))
    }

    @Test func testBoundaryPercentagesAndInvalidValues() throws {
        for value: Double in [0, 100, 22.5] {
            let decoded = try SnapshotEnvelope.decode(data(snapshot(used: value)), now: now)
            expectEqual(decoded.windows[0].remainingPercent, 100 - value)
        }
        for value: Double in [-0.1, 100.1, .infinity, .nan] {
            expectThrows(try snapshot(used: value).validated(now: now))
        }
    }

    @Test func testBadProvidersSourcesVersionsWindowsAndFutureDatesRejected() throws {
        for (key, value) in [("providerId", "other"), ("source", "manual"), ("pageKind", "chat")] {
            expectThrows(try SnapshotEnvelope.decode(replacing(key, with: value), now: now))
        }
        for key in ["schemaVersion", "parserVersion"] {
            expectThrows(try SnapshotEnvelope.decode(replacing(key, with: 2), now: now))
        }
        expectThrows(try SnapshotEnvelope.decode(data(snapshot(windows: [])), now: now))
        expectThrows(try SnapshotEnvelope.decode(data(snapshot(windows: [.init(id: "bad", label: "坏窗口", usedPercent: nil)])), now: now))
        let sameWindow = QuotaWindow(id: "session", label: "时段", usedPercent: 10)
        expectThrows(try SnapshotEnvelope.decode(data(snapshot(windows: [sameWindow, sameWindow])), now: now))
        expectThrows(try SnapshotEnvelope.decode(data(snapshot(at: now.addingTimeInterval(61))), now: now))
        expectNoThrow(try SnapshotEnvelope.decode(data(snapshot(at: now.addingTimeInterval(60))), now: now))
        expectThrows(try SnapshotEnvelope.decode(Data(repeating: 32, count: 100_001), now: now))
    }

    @Test func testDateParserRejectsImpossibleCalendarAndMissingTimezone() throws {
        for invalid in ["2026-02-30T12:00:00Z", "2025-02-29T12:00:00Z", "2026-11-02T25:00:00Z", "2026-11-02T12:00:00", "2026-13-01T12:00:00Z", "2026-11-02T12:00:61Z"] {
            expectThrows(try QuotaDate.parse(invalid), invalid)
        }
        expectEqual(try QuotaDate.parse("2024-02-29T21:00:00+09:00"), try QuotaDate.parse("2024-02-29T12:00:00Z"))
        expectEqual(try QuotaDate.parse("2024-02-29T12:00:00.123Z").timeIntervalSince1970,
                       try QuotaDate.parse("2024-02-29T12:00:00Z").timeIntervalSince1970 + 0.123, accuracy: 0.000_001)
    }

    @Test func testMergeDuplicateAndOlderObservationsDoesNotFreshenOrMoveReset() throws {
        let reset = now.addingTimeInterval(3_600)
        var document = QuotaStoreDocument()
        expectTrue(try document.merge(snapshot(reset: reset, label: "1小时后"), now: now))
        let original = document
        expectFalse(try document.merge(snapshot(reset: reset, label: "1小时后"), now: now))
        expectEqual(document, original)
        expectFalse(try document.merge(snapshot(used: 80, at: now.addingTimeInterval(-1)), now: now))
        expectEqual(document, original)
        expectFalse(try document.merge(snapshot(used: 80), now: now), "同时间冲突不能覆盖")
        expectEqual(document, original)
    }

    @Test func testNewConfirmedSampleFreshensUnchangedPercentageWithoutMovingResetAnchor() throws {
        let reset = now.addingTimeInterval(3_600)
        var document = QuotaStoreDocument()
        try document.merge(snapshot(reset: reset, label: "1小时后"), now: now)
        let later = now.addingTimeInterval(30)
        expectTrue(try document.merge(snapshot(at: later, reset: reset.addingTimeInterval(30), label: "1小时后"), now: now))
        let presentation = QuotaPresentation(document: document, now: now)
        expectEqual(presentation.usedPercent, 38)
        expectEqual(presentation.observedAt, later)
        expectEqual(presentation.resetAt, reset)
        expectEqual(document.records[0].observedAt, later)
        let confirmed = document
        expectFalse(try document.merge(snapshot(reset: reset, label: "1小时后"), now: now), "旧采样重放不能覆盖新确认")
        expectEqual(document, confirmed)
    }

    @Test func testChangedConsumptionKeepsRelativeResetAnchorAndUpdatesOnlyObservedWindow() throws {
        let reset = now.addingTimeInterval(3_600)
        let weekly = QuotaWindow(id: "weekly", label: "本周", usedPercent: 15, resetAt: now.addingTimeInterval(86_400))
        let session = QuotaWindow(id: "session", label: "当前时段", usedPercent: 20, resetAt: reset, resetLabel: "1小时后")
        var document = QuotaStoreDocument()
        try document.merge(snapshot(windows: [session, weekly]), now: now)
        let nextTime = now.addingTimeInterval(30)
        expectTrue(try document.merge(snapshot(used: 40, at: nextTime, reset: reset.addingTimeInterval(30), label: "1小时后"), now: now))
        let updated = QuotaPresentation(document: document, now: now)
        let oldWindow = QuotaPresentation(document: document, windowId: "weekly", now: now)
        expectEqual(updated.usedPercent, 40)
        expectEqual(updated.observedAt, nextTime)
        expectEqual(updated.resetAt, reset)
        expectEqual(oldWindow.usedPercent, 15)
        expectEqual(oldWindow.observedAt, now)
        expectEqual(document.records.count, 1)
    }

    @Test func testMissingWindowInNewBatchCanReceiveItsOwnLaterObservation() throws {
        var document = QuotaStoreDocument()
        try document.merge(snapshot(windows: [.init(id: "weekly", label: "本周", usedPercent: 15)]), now: now)
        try document.merge(snapshot(at: now.addingTimeInterval(30)), now: now)
        expectTrue(try document.merge(snapshot(at: now.addingTimeInterval(20), windows: [.init(id: "weekly", label: "本周", usedPercent: 20)]), now: now))
        expectEqual(QuotaPresentation(document: document, windowId: "weekly", now: now).observedAt, now.addingTimeInterval(20))
        expectEqual(document.records[0].observedAt, now.addingTimeInterval(30), "顶层保持窗口最新时间")
    }

    @Test func testFreshnessDoesNotRefillAtResetAndOldSatietyIsRetained() throws {
        var document = QuotaStoreDocument()
        try document.merge(snapshot(used: 95, reset: now.addingTimeInterval(100)), now: now)
        expectEqual(QuotaPresentation(document: document, now: now).freshness, .fresh)
        let expired = QuotaPresentation(document: document, now: now.addingTimeInterval(101))
        expectEqual(expired.freshness, .resetDue)
        expectEqual(expired.remainingPercent, 5)
        expectEqual(expired.satiety, .full)
        expectEqual(expired.observedAt, now)
        expectEqual(QuotaPresentation(document: document, now: now.addingTimeInterval(7 * 3_600)).freshness, .resetDue)
        try document.merge(snapshot(used: 96, at: now.addingTimeInterval(10), reset: nil), now: now)
        expectEqual(QuotaPresentation(document: document, now: now.addingTimeInterval(6 * 3_600 + 10)).freshness, .stale)
    }

    @Test func testSatietyThresholdsAreDrivenByUsedPercentage() throws {
        for (used, expected): (Double, QuotaSatiety) in [(0, .hungry), (24.9, .hungry), (25, .snacking), (59.9, .snacking), (60, .satisfied), (89.9, .satisfied), (90, .full), (100, .full)] {
            let document = QuotaStoreDocument(records: [try snapshot(used: used).validated(now: now)])
            let presentation = QuotaPresentation(document: document, now: now)
            expectEqual(presentation.satiety, expected)
            expectEqual(presentation.remainingPercent, 100 - used)
        }
    }

    @Test func testTwoServiceRoundTripPreferencesAndNoSyntheticDefaults() throws {
        var document = QuotaStoreDocument()
        expectTrue(document.records.isEmpty)
        expectEqual(QuotaPresentation(document: document, now: now).freshness, .missing)
        expectNil(QuotaPresentation(document: document, now: now).remainingPercent)
        try document.merge(snapshot(), now: now)
        try document.merge(snapshot(provider: .chatgpt, used: nil), now: now)
        document.preferences = .init(providerId: .chatgpt, character: .myMelody, reactionAt: now)
        let encoded = try document.encoded(now: now)
        let decoded = try QuotaStoreDocument.decode(encoded, now: now)
        expectEqual(decoded, document)
        expectEqual(decoded.records.count, 2)
        expectEqual(decoded.preferences.character, .myMelody)
        expectEqual(decoded.preferences.reactionAt, now)
        expectNil(QuotaPresentation(document: decoded, now: now).remainingPercent)
    }

    @Test func testPersistedDocumentRejectsDuplicateServicesAndFutureWindowTimes() throws {
        let duplicate = QuotaStoreDocument(records: [snapshot(), snapshot()])
        expectThrows(try QuotaStoreDocument.decode(JSONEncoder().encode(duplicate), now: now))
        let futureWindow = QuotaWindow(id: "session", label: "当前时段", usedPercent: 10, observedAt: now.addingTimeInterval(1))
        expectThrows(try snapshot(windows: [futureWindow]).validated(now: now))
        let tooLongLabel = QuotaWindow(id: "session", label: String(repeating: "字", count: 81), usedPercent: 10)
        expectThrows(try snapshot(windows: [tooLongLabel]).validated(now: now))
    }

    @Test func testSelectedWeeklyWindowUsesItsOwnQuotaAndObservationWithoutEditingRecords() throws {
        let weeklyTime = now.addingTimeInterval(-3_600)
        let windows: [QuotaWindow] = [
            .init(id: "session", label: "短时", usedPercent: 80, observedAt: now),
            .init(id: "weekly", label: "每周", usedPercent: 25, observedAt: weeklyTime)
        ]
        var document = QuotaStoreDocument(records: [try snapshot(windows: windows).validated(now: now)])
        let originalRecords = document.records
        document.preferences.windowId = "weekly"
        let weekly = QuotaPresentation(document: document, now: now)
        expectEqual(weekly.window?.id, "weekly")
        expectEqual(weekly.remainingPercent, 75)
        expectEqual(weekly.observedAt, weeklyTime)
        expectEqual(weekly.satiety, .snacking)
        let explicitSession = QuotaPresentation(document: document, windowId: "session", now: now)
        expectEqual(explicitSession.remainingPercent, 20)
        expectEqual(explicitSession.observedAt, now)
        expectEqual(document.records, originalRecords)
        let decoded = try QuotaStoreDocument.decode(document.encoded(now: now), now: now)
        expectEqual(decoded.preferences.windowId, "weekly")
        expectEqual(decoded.records, originalRecords)
    }

    @Test func testExplicitMissingOrUnknownWindowNeverBorrowsAnotherQuota() throws {
        var document = QuotaStoreDocument(records: [try snapshot().validated(now: now)],
                                          preferences: .init(windowId: "weekly"))
        let missing = QuotaPresentation(document: document, now: now)
        expectNil(missing.window)
        expectNil(missing.remainingPercent)
        expectNil(missing.observedAt)
        expectEqual(missing.freshness, .missing)
        expectEqual(missing.satiety, .unknown)
        try document.merge(snapshot(windows: [.init(id: "weekly", label: "每周", usedPercent: nil)]), now: now)
        let unknown = QuotaPresentation(document: document, now: now)
        expectEqual(unknown.window?.id, "weekly")
        expectNil(unknown.remainingPercent)
        expectEqual(unknown.observedAt, now)
        expectEqual(unknown.freshness, .fresh)
        expectEqual(QuotaPresentation(document: document, windowId: "session", now: now).remainingPercent, 62)
    }

    @Test func testWindowPreferenceIsScopedToItsSelectedProviderAndLegacyDataStillLoads() throws {
        var document = QuotaStoreDocument(preferences: .init(windowId: "weekly"))
        try document.merge(snapshot(windows: [.init(id: "weekly", label: "每周", usedPercent: 30)]), now: now)
        try document.merge(snapshot(provider: .chatgpt, used: nil), now: now)
        let otherProvider = QuotaPresentation(document: document, provider: .chatgpt, now: now)
        expectEqual(otherProvider.window?.id, "notice")
        expectEqual(otherProvider.freshness, .fresh)
        var object = try #require(JSONSerialization.jsonObject(with: document.encoded(now: now)) as? [String: Any])
        var preferences = try #require(object["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "windowId")
        object["preferences"] = preferences
        let legacy = try QuotaStoreDocument.decode(JSONSerialization.data(withJSONObject: object), now: now)
        expectNil(legacy.preferences.windowId)
        expectEqual(legacy.records, document.records)
        expectEqual(QuotaPresentation(document: legacy, now: now).remainingPercent, 70, "未选窗口仍可使用服务已有窗口")
    }

    @Test func testInvalidPersistedWindowPreferenceIsRejectedAndKnownSelectionsRoundTrip() throws {
        for window in ["session", "weekly", "sonnet-weekly", "notice", "primary", "secondary"] {
            let preferences = QuotaPreferences(windowId: window)
            let decoded = try JSONDecoder().decode(QuotaPreferences.self, from: JSONEncoder().encode(preferences))
            expectEqual(decoded.windowId, window)
        }
        for invalid: Any in ["", "other", "../session", "weekly ", 42, true] {
            let value: [String: Any] = ["providerId": "claude", "character": "kuromi", "windowId": invalid]
            expectThrows(try JSONDecoder().decode(QuotaPreferences.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        expectThrows(try QuotaStoreDocument(preferences: .init(windowId: "other")).encoded(now: now))
    }

    @Test func testCodexRequiresOfficialSourceAndOwnWindowIdentifiers() throws {
        let codex = try SnapshotEnvelope.decode(data(codexSnapshot()), now: now)
        expectEqual(codex.providerId.name, "Codex")
        expectEqual(codex.source, "codex-app-server")
        expectEqual(codex.pageKind, "rate-limits")
        expectEqual(codex.windows[0].label, "主窗口 · 7天")
        expectEqual(codex.windows[0].usedPercent, 42)
        for (key, value) in [("source", "browser"), ("source", "manual"), ("pageKind", "usage"), ("pageKind", "limit-notice")] {
            expectThrows(try SnapshotEnvelope.decode(replacing(key, with: value, in: codexSnapshot()), now: now))
        }
        for provider: QuotaProvider in [.claude, .chatgpt] {
            expectThrows(try SnapshotEnvelope.decode(replacing("source", with: "codex-app-server", in: snapshot(provider: provider, used: nil)), now: now))
        }
        for id in ["session", "weekly", "notice"] {
            expectThrows(try codexSnapshot(windows: [.init(id: id, label: "错误窗口", usedPercent: 10)]).validated(now: now))
        }
        expectThrows(try snapshot(windows: [.init(id: "primary", label: "错误窗口", usedPercent: 10)]).validated(now: now))
    }

    @Test func testCodexWindowsRetainIndependentObservationResetAndUnknownValues() throws {
        let secondaryTime = now.addingTimeInterval(-300)
        let primaryReset = now.addingTimeInterval(86_400)
        let secondaryReset = now.addingTimeInterval(7 * 86_400)
        var document = QuotaStoreDocument(preferences: .init(providerId: .codex))
        try document.merge(codexSnapshot(windows: [
            .init(id: "primary", label: "主窗口 · 7天", usedPercent: nil, resetAt: primaryReset, observedAt: now),
            .init(id: "secondary", label: "次窗口 · 30天", usedPercent: 12.5, resetAt: secondaryReset, observedAt: secondaryTime)
        ]), now: now)
        let unknown = QuotaPresentation(document: document, now: now)
        expectEqual(unknown.window?.id, "primary")
        expectEqual(unknown.window?.label, "主窗口 · 7天")
        expectNil(unknown.usedPercent)
        expectNil(unknown.remainingPercent)
        expectEqual(unknown.satiety, .unknown)
        expectEqual(unknown.observedAt, now)
        expectEqual(unknown.resetAt, primaryReset)
        let nextTime = now.addingTimeInterval(5)
        try document.merge(codexSnapshot(at: nextTime, windows: [
            .init(id: "primary", label: "主窗口 · 7天", usedPercent: 1.25, resetAt: primaryReset)
        ]), now: now)
        let secondary = QuotaPresentation(document: document, windowId: "secondary", now: nextTime)
        expectEqual(secondary.usedPercent, 12.5)
        expectEqual(secondary.remainingPercent, 87.5)
        expectEqual(secondary.observedAt, secondaryTime)
        expectEqual(secondary.resetAt, secondaryReset)
        expectEqual(QuotaPresentation(document: document, now: nextTime).observedAt, nextTime)
    }

    @Test func testMissingCodexPrimaryNeverBorrowsSecondaryOrAssumesFiveHours() throws {
        let record = try codexSnapshot(windows: [
            .init(id: "secondary", label: "次窗口 · 7天", usedPercent: 30)
        ]).validated(now: now)
        let document = QuotaStoreDocument(records: [record], preferences: .init(providerId: .codex))
        let missing = QuotaPresentation(document: document, now: now)
        expectNil(missing.window)
        expectNil(missing.remainingPercent)
        expectNil(missing.observedAt)
        expectEqual(missing.freshness, .missing)
        expectEqual(missing.satiety, .unknown)
        let selected = QuotaPresentation(document: document, windowId: "secondary", now: now)
        expectEqual(selected.window?.label, "次窗口 · 7天")
        expectEqual(selected.remainingPercent, 70)
        expectEqual(selected.observedAt, now)
    }

    @Test func testNewCodexAbsoluteResetCanChangeWithSameDisplayLabelAndReplaysCannotChangeIt() throws {
        let originalReset = now.addingTimeInterval(3_600)
        let revisedReset = now.addingTimeInterval(7_200)
        var document = QuotaStoreDocument(preferences: .init(providerId: .codex))
        try document.merge(codexSnapshot(windows: [
            .init(id: "primary", label: "主窗口 · 7天", usedPercent: 45, resetAt: originalReset, resetLabel: "稍后重置")
        ]), now: now)
        let nextTime = now.addingTimeInterval(5)
        expectTrue(try document.merge(codexSnapshot(at: nextTime, windows: [
            .init(id: "primary", label: "主窗口 · 7天", usedPercent: 45, resetAt: revisedReset, resetLabel: "稍后重置")
        ]), now: now))
        expectEqual(QuotaPresentation(document: document, now: nextTime).resetAt, revisedReset)
        let confirmed = document
        for at in [now, nextTime] {
            expectFalse(try document.merge(codexSnapshot(at: at, windows: [
                .init(id: "primary", label: "主窗口 · 7天", usedPercent: 99, resetAt: originalReset, resetLabel: "稍后重置")
            ]), now: now))
            expectEqual(document, confirmed)
        }
        expectTrue(try document.merge(codexSnapshot(at: now.addingTimeInterval(10), windows: [
            .init(id: "primary", label: "主窗口 · 7天", usedPercent: nil, resetAt: nil)
        ]), now: now))
        let unavailable = QuotaPresentation(document: document, now: now.addingTimeInterval(10))
        expectNil(unavailable.usedPercent)
        expectNil(unavailable.resetAt)
        expectEqual(unavailable.observedAt, now.addingTimeInterval(10))
    }

    @Test func testThreeProvidersRoundTripAndLegacyTwoProviderDocumentRemainsValid() throws {
        var legacy = QuotaStoreDocument(preferences: .init(character: .kuromi))
        try legacy.merge(snapshot(), now: now)
        try legacy.merge(snapshot(provider: .chatgpt, used: nil), now: now)
        var object = try #require(JSONSerialization.jsonObject(with: legacy.encoded(now: now)) as? [String: Any])
        object["preferences"] = ["providerId": "claude", "character": "kuromi"]
        let decodedLegacy = try QuotaStoreDocument.decode(JSONSerialization.data(withJSONObject: object), now: now)
        expectEqual(decodedLegacy, legacy)
        expectEqual(decodedLegacy.records.count, 2)
        expectNil(decodedLegacy.preferences.windowId)

        var current = decodedLegacy
        try current.merge(codexSnapshot(windows: [
            .init(id: "primary", label: "主窗口 · 7天", usedPercent: 42),
            .init(id: "secondary", label: "次窗口 · 30天", usedPercent: 9)
        ]), now: now)
        current.preferences = .init(providerId: .codex, character: .myMelody, windowId: "secondary")
        let decodedCurrent = try QuotaStoreDocument.decode(current.encoded(now: now), now: now)
        expectEqual(decodedCurrent, current)
        expectEqual(decodedCurrent.records.count, 3)
        expectEqual(decodedCurrent.schemaVersion, 1)
        expectEqual(QuotaPresentation(document: decodedCurrent, now: now).remainingPercent, 91)
        var duplicate = current
        duplicate.records.append(try codexSnapshot().validated(now: now))
        expectThrows(try duplicate.encoded(now: now))
    }

    @Test func testCodexResetDueRetainsOfficialUsageAndObservationWithoutRefilling() throws {
        let reset = now.addingTimeInterval(1)
        let record = try codexSnapshot(windows: [
            .init(id: "primary", label: "主窗口 · 7天", usedPercent: 92.5, resetAt: reset)
        ]).validated(now: now)
        let document = QuotaStoreDocument(records: [record], preferences: .init(providerId: .codex))
        let due = QuotaPresentation(document: document, now: now.addingTimeInterval(5))
        expectEqual(due.freshness, .resetDue)
        expectEqual(due.usedPercent, 92.5)
        expectEqual(due.remainingPercent, 7.5)
        expectEqual(due.observedAt, now)
        expectEqual(due.resetAt, reset)
        expectEqual(due.satiety, .full)
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs == rhs, "\(message)", sourceLocation: sourceLocation)
}
private func expectEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(lhs - rhs) <= accuracy, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, "\(message)", sourceLocation: sourceLocation)
}
private func expectFalse(_ value: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, "\(message)", sourceLocation: sourceLocation)
}
private func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func expectThrows<T>(_ value: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try value()
        Issue.record("应拒绝该输入。\(message)", sourceLocation: sourceLocation)
    } catch { }
}
private func expectNoThrow<T>(_ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try value() } catch { Issue.record("不应抛错：\(error)", sourceLocation: sourceLocation) }
}

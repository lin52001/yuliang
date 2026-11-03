import Foundation
import Testing
@testable import QuotaCore

struct BuddyInteractionTests {
    private let now = Date(timeIntervalSince1970: 1_793_649_600)

    private func value(used: Double? = 20, at offset: TimeInterval = 0,
                       resetOffset: TimeInterval? = 3_600, window: String = "primary",
                       label: String = "7天额度", provider: QuotaProvider = .codex,
                       displayOffset: TimeInterval = 60) -> QuotaPresentation {
        let observation = now.addingTimeInterval(offset)
        let snapshot = SnapshotEnvelope(providerId: provider,
            pageKind: provider == .codex ? "rate-limits" : "usage", observedAt: observation,
            source: provider == .codex ? "codex-app-server" : "browser", windows: [
                QuotaWindow(id: window, label: label, usedPercent: used,
                    resetAt: resetOffset.map { now.addingTimeInterval($0) }, observedAt: observation)
            ])
        let document = QuotaStoreDocument(records: [snapshot], preferences: .init(providerId: provider, windowId: window))
        return QuotaPresentation(document: document, now: now.addingTimeInterval(displayOffset))
    }

    @Test func genuineConsumptionReportsPercentagePointsWithoutMutatingInput() {
        let previous = value(used: 20)
        let next = value(used: 22.5, at: 60)
        #expect(BuddyQuotaChange.consumption(from: previous, to: next) == 2.5)
        #expect(previous.remainingPercent == 80)
        #expect(next.remainingPercent == 77.5)
        #expect(previous.observedAt == now)
        #expect(next.observedAt == now.addingTimeInterval(60))
    }

    @Test func identicalAndOlderObservationsCannotReplayAMeal() {
        let previous = value(used: 20)
        for next in [value(used: 22, at: 0), value(used: 22, at: -1), value(used: 20, at: 60)] {
            #expect(BuddyQuotaChange.consumption(from: previous, to: next) == nil)
        }
    }

    @Test func unknownAndFirstLoadDoNotFeed() {
        let missing = QuotaPresentation(document: .init(preferences: .init(providerId: .codex)), now: now)
        #expect(BuddyQuotaChange.consumption(from: missing, to: value(used: 22, at: 60)) == nil)
        #expect(BuddyQuotaChange.consumption(from: value(used: nil), to: value(used: 22, at: 60)) == nil)
        #expect(BuddyQuotaChange.consumption(from: value(), to: value(used: nil, at: 60)) == nil)
    }

    @Test func recoveryAndResetNeverFeed() {
        let previous = value(used: 20)
        #expect(BuddyQuotaChange.consumption(from: previous, to: value(used: 10, at: 60)) == nil)
        #expect(BuddyQuotaChange.consumption(from: previous, to: value(used: 22, at: 60, resetOffset: 7_200)) == nil)
        #expect(BuddyQuotaChange.consumption(from: previous, to: value(used: 22, at: 60, resetOffset: nil)) == nil)
        #expect(BuddyQuotaChange.consumption(from: value(resetOffset: nil), to: value(used: 22, at: 60, resetOffset: nil)) == nil)
        #expect(BuddyQuotaChange.consumption(from: value(resetOffset: nil), to: value(used: 22, at: 60)) == nil)
    }

    @Test func changedWindowProviderOrDurationDoesNotFeed() {
        let previous = value(used: 20)
        #expect(BuddyQuotaChange.consumption(from: previous, to: value(used: 22, at: 60, window: "secondary")) == nil)
        #expect(BuddyQuotaChange.consumption(from: previous, to: value(used: 22, at: 60, label: "5小时额度")) == nil)
        #expect(BuddyQuotaChange.consumption(from: previous, to: value(used: 22, at: 60, provider: .claude)) == nil)
        #expect(BuddyQuotaChange.consumption(from: value(provider: .claude), to: value(used: 22, at: 60, provider: .claude)) == nil)
    }

    @Test func staleOrResetDueEvidenceCannotFeed() {
        let stale = value(used: 20, resetOffset: 100_000, displayOffset: 21_600)
        #expect(stale.freshness == .stale)
        #expect(BuddyQuotaChange.consumption(from: stale, to: value(used: 22, at: 21_600, resetOffset: 100_000, displayOffset: 21_600)) == nil)
        let resetDue = value(used: 22, at: 60, resetOffset: 60)
        #expect(resetDue.freshness == .resetDue)
        #expect(BuddyQuotaChange.consumption(from: value(resetOffset: 60), to: resetDue) == nil)
    }

    @Test func invalidPercentagesAndCyclesCannotFeed() {
        for invalid in [Double.nan, .infinity, -1, 101] {
            #expect(BuddyQuotaChange.consumption(from: value(used: invalid), to: value(used: 22, at: 60)) == nil)
            #expect(BuddyQuotaChange.consumption(from: value(used: 20), to: value(used: invalid, at: 60)) == nil)
        }
        // A future sample can still pass presentation freshness. It must not cross the cycle boundary.
        let earlier = value(used: 20, resetOffset: 30, displayOffset: 0)
        let crossing = value(used: 22, at: 60, resetOffset: 30, displayOffset: 0)
        #expect(crossing.freshness == .fresh)
        #expect(BuddyQuotaChange.consumption(from: earlier, to: crossing) == nil)
    }
}

import Foundation
import Testing
@testable import QuotaCore

struct BuddyInteractionTests {
    private let now = Date(timeIntervalSince1970: 1_793_649_600)

    @Test func actionChoicesKeepRandomPlaySeparateFromMealsAndRemainCodable() throws {
        #expect(!BuddyAction.interactiveActions.contains(.idle))
        #expect(BuddyAction.interactiveActions.contains(.eating))
        #expect(!BuddyAction.playfulActions.contains(.eating))
        #expect(!BuddyAction.playfulActions.contains(.idle))
        for action in [BuddyAction.jump, .dance, .spin] {
            #expect(BuddyAction.playfulActions.contains(action))
            #expect(try JSONDecoder().decode(BuddyAction.self, from: JSONEncoder().encode(action)) == action)
        }
        for action in BuddyAction.interactiveActions {
            // Every interaction can finish on its own and has a discoverable control.
            #expect(action.duration > 0 && action.duration <= 3)
            #expect(!action.label.isEmpty && !action.symbol.isEmpty)
            #expect(BuddyAction.playfulActions.filter { $0 != action }.count > 1)
        }
        #expect(try JSONDecoder().decode(BuddyAction.self, from: Data("\"pat\"".utf8)) == .pat)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BuddyAction.self, from: Data("\"unknown\"".utf8))
        }
    }

    @Test func jumpLandsDanceSwaysAndSpinCompletesADifferentMotion() {
        let airborne = BuddyAction.jump.motionSample(progress: 0.25)
        let landed = BuddyAction.jump.motionSample(progress: 0.5)
        #expect(airborne.verticalOffset < -0.15)
        #expect(airborne.horizontalOffset == 0 && airborne.rotationDegrees == 0)
        #expect(abs(landed.verticalOffset) < 0.000_001)
        #expect(landed.scaleX > 1 && landed.scaleY < 1)
        let left = BuddyAction.dance.motionSample(progress: 0.25)
        let right = BuddyAction.dance.motionSample(progress: 0.75)
        #expect(left.horizontalOffset < 0 && right.horizontalOffset > 0)
        #expect(left.rotationDegrees < 0 && right.rotationDegrees > 0)
        let halfTurn = BuddyAction.spin.motionSample(progress: 0.5)
        #expect(halfTurn.rotationDegrees == 180)
        #expect(halfTurn.horizontalOffset == 0)
        #expect(BuddyAction.spin.motionSample(progress: 1) == .rest)
    }

    @Test func finiteMotionCannotDriftOrContinueAfterAnInteraction() {
        for action in BuddyAction.allCases {
            for invalidOrFinished in [-Double.infinity, -1, 0, 1, 2, Double.infinity, Double.nan] {
                #expect(action.motionSample(progress: invalidOrFinished) == .rest)
            }
            for step in 0...120 {
                let t = Double(step) / 120
                let sample = action.motionSample(progress: t)
                let allFinite = [sample.rotationDegrees, sample.horizontalOffset, sample.verticalOffset, sample.scaleX, sample.scaleY].allSatisfy { $0.isFinite }
                #expect(allFinite)
                #expect(abs(sample.horizontalOffset) <= 0.055_001)
                #expect((-0.180_001...0.016_001).contains(sample.verticalOffset))
                #expect((0.899_999...1.100_001).contains(sample.scaleX))
                #expect((0.899_999...1.100_001).contains(sample.scaleY))
                #expect(action.motionSample(progress: t, reduceMotion: true) == .rest)
            }
            let finish = action.motionSample(progress: 1 - 0.000_001)
            #expect(abs(finish.horizontalOffset) < 0.000_1 && abs(finish.verticalOffset) < 0.000_1)
            #expect(abs(finish.scaleX - 1) < 0.000_1 && abs(finish.scaleY - 1) < 0.000_1)
            // A full turn and the resting orientation are visually equivalent.
            #expect(abs(sin(finish.rotationDegrees * .pi / 180)) < 0.000_1)
        }
    }

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

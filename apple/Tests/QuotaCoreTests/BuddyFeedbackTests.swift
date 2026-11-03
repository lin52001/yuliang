import Foundation
import Testing
@testable import QuotaCore

struct BuddyFeedbackTests {
    private let now = Date(timeIntervalSince1970: 1_793_736_000)

    @Test func storedSnapshotDoesNotFlashAndReadingCannotShuffleEncouragement() {
        let state = BuddyFeedbackState()
        let initial = state.message(at: now, refreshTimeLabel: "09:00")
        #expect(initial.kind == .encouragement)
        #expect(initial.text.count <= 20)
        #expect(state.nextTransition(after: now) == nil)
        for offset in [1.0, 2.4, 5.5, 60, 3_600] {
            #expect(state.message(at: now.addingTimeInterval(offset), refreshTimeLabel: "09:00") == initial)
        }
    }

    @Test func acceptedRefreshFlashesOnceThenRestoresEncouragement() {
        var state = BuddyFeedbackState()
        let accepted = state.didRefresh(observedAt: now, now: now)
        #expect(accepted)
        let message = state.message(at: now, refreshTimeLabel: "09:16")
        #expect(message.kind == .refresh)
        #expect(message.text.contains("09:16"))
        #expect(state.nextTransition(after: now) == now.addingTimeInterval(2.4))
        #expect(state.message(at: now.addingTimeInterval(2.399), refreshTimeLabel: "09:16").kind == .refresh)
        #expect(state.message(at: now.addingTimeInterval(2.4), refreshTimeLabel: "09:16").kind == .encouragement)
        #expect(state.nextTransition(after: now.addingTimeInterval(2.4)) == nil)
        let duplicate = state.didRefresh(observedAt: now, now: now.addingTimeInterval(60))
        let older = state.didRefresh(observedAt: now.addingTimeInterval(-1), now: now.addingTimeInterval(60))
        #expect(!duplicate && !older)
        #expect(state.message(at: now.addingTimeInterval(60), refreshTimeLabel: "09:16").kind == .encouragement)
    }

    @Test func persistedObservationSeedsDeduplicationWithoutARefreshFlash() {
        var state = BuddyFeedbackState(variant: 2, observedAt: now)
        let initial = state.message(at: now, refreshTimeLabel: "09:00")
        #expect(initial.kind == .encouragement)
        #expect(state.lastObservedAt == now)
        #expect(state.nextTransition(after: now) == nil)
        let duplicate = state.didRefresh(observedAt: now, now: now.addingTimeInterval(60))
        let older = state.didRefresh(observedAt: now.addingTimeInterval(-60), now: now.addingTimeInterval(60))
        #expect(!duplicate && !older)
        #expect(state.message(at: now.addingTimeInterval(60), refreshTimeLabel: "09:00") == initial)
        let next = now.addingTimeInterval(60)
        let accepted = state.didRefresh(observedAt: next, now: next)
        #expect(accepted)
        #expect(state.message(at: next, refreshTimeLabel: "09:01").kind == .refresh)
        #expect(state.nextTransition(after: next) == next.addingTimeInterval(2.4))
        #expect(state.message(at: next.addingTimeInterval(2.4), refreshTimeLabel: "09:01").kind == .encouragement)
    }

    @Test func everyInteractionHasBriefVariedEncouragementWithoutAnUnimplementedReward() {
        for action in BuddyAction.interactiveActions {
            var state = BuddyFeedbackState()
            var responses = Set<String>()
            for step in 0..<3 {
                let date = now.addingTimeInterval(Double(step) * 10)
                state.interact(action, now: date)
                let message = state.message(at: date, refreshTimeLabel: "")
                #expect(message.kind == .interaction)
                #expect(!message.text.isEmpty && message.text.count <= 20)
                #expect(message.symbol == action.symbol)
                #expect(!message.text.contains("积分") && !message.text.contains("好感度") && !message.text.contains("Token"))
                responses.insert(message.text)
                #expect(state.message(at: date.addingTimeInterval(5.499), refreshTimeLabel: "").kind == .interaction)
                #expect(state.message(at: date.addingTimeInterval(5.5), refreshTimeLabel: "").kind == .encouragement)
            }
            #expect(responses.count == 3)
        }
    }

    @Test func interactionReadingTimeSurvivesAShortRefreshAndDoesNotReplayIt() {
        var state = BuddyFeedbackState()
        state.interact(.pat, now: now)
        let response = state.message(at: now, refreshTimeLabel: "")
        let accepted = state.didRefresh(observedAt: now.addingTimeInterval(1), now: now.addingTimeInterval(1))
        #expect(accepted)
        #expect(state.message(at: now.addingTimeInterval(1), refreshTimeLabel: "09:17") == response)
        #expect(state.nextTransition(after: now.addingTimeInterval(1)) == now.addingTimeInterval(5.5))
        #expect(state.message(at: now.addingTimeInterval(5.5), refreshTimeLabel: "09:17").kind == .encouragement)
    }

    @Test func laterRefreshUsesOnlyItsRemainingFlashTimeAfterInteraction() {
        var state = BuddyFeedbackState()
        state.interact(.jump, now: now)
        let accepted = state.didRefresh(observedAt: now.addingTimeInterval(5), now: now.addingTimeInterval(5))
        #expect(accepted)
        #expect(state.message(at: now.addingTimeInterval(5.5), refreshTimeLabel: "09:18").kind == .refresh)
        #expect(state.nextTransition(after: now.addingTimeInterval(5.5)) == now.addingTimeInterval(7.4))
        #expect(state.message(at: now.addingTimeInterval(7.4), refreshTimeLabel: "09:18").kind == .encouragement)
    }

    @Test func nextTapReplacesTheWordsAndRestartsReadingTime() {
        var state = BuddyFeedbackState()
        state.interact(.pat, now: now)
        let first = state.message(at: now, refreshTimeLabel: "")
        state.interact(.eating, now: now.addingTimeInterval(5))
        let second = state.message(at: now.addingTimeInterval(5), refreshTimeLabel: "")
        #expect(first.text != second.text)
        #expect(second.kind == .interaction)
        #expect(state.message(at: now.addingTimeInterval(10.499), refreshTimeLabel: "") == second)
        #expect(state.nextTransition(after: now.addingTimeInterval(5)) == now.addingTimeInterval(10.5))
    }

    @Test func collectionErrorsRemainVisibleInsteadOfBeingHiddenByEncouragement() {
        var state = BuddyFeedbackState()
        state.interact(.celebrate, now: now)
        let accepted = state.didRefresh(observedAt: now, now: now)
        #expect(accepted)
        let failed = state.message(at: now, refreshTimeLabel: "09:20", error: "  无法读取额度  ")
        #expect(failed.kind == .error)
        #expect(failed.text == "无法读取额度")
        #expect(state.message(at: now, refreshTimeLabel: "09:20", error: " \n ").kind == .interaction)
        #expect(state.message(at: now.addingTimeInterval(60), refreshTimeLabel: "09:20", error: "无法读取额度") == failed)
    }

    @Test func invalidRefreshesOrIdleEventsCannotAdvanceOrRestartFeedback() {
        var state = BuddyFeedbackState(variant: Int.min)
        let before = state
        state.interact(.idle, now: now)
        state.interact(.pat, now: Date(timeIntervalSinceReferenceDate: .nan))
        let invalidObservation = state.didRefresh(observedAt: Date(timeIntervalSinceReferenceDate: .infinity), now: now)
        let invalidClock = state.didRefresh(observedAt: now, now: Date(timeIntervalSinceReferenceDate: .nan))
        let futureObservation = state.didRefresh(observedAt: now.addingTimeInterval(61), now: now)
        #expect(!invalidObservation && !invalidClock && !futureObservation)
        #expect(state == before)
        #expect(state.message(at: now, refreshTimeLabel: "").kind == .encouragement)
    }

    @Test func refreshWithoutFormattedTimeStillHasReadableText() {
        var state = BuddyFeedbackState()
        let accepted = state.didRefresh(observedAt: now, now: now)
        #expect(accepted)
        #expect(state.message(at: now, refreshTimeLabel: " \n ").text == "额度已更新")
    }
}

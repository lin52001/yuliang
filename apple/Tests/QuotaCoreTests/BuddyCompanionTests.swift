import Foundation
import Testing
@testable import QuotaCore

struct BuddyCompanionTests {
    private let now = Date(timeIntervalSince1970: 1_793_736_000)

    @Test func seededScheduleIsQuietVariedAndCannotFabricateAMeal() throws {
        var schedule = BuddyCompanionSchedule(now: now, seed: 42)
        var replay = BuddyCompanionSchedule(now: now, seed: 42)
        #expect((35...60).contains(schedule.nextDueAt.timeIntervalSince(now)))
        var emitted: [(Int, BuddyCompanionMoment)] = []
        for second in 1...1_200 {
            let time = now.addingTimeInterval(Double(second))
            let result = schedule.tick(now: time)
            let replayed = replay.tick(now: time)
            #expect(result == replayed)
            if let result { emitted.append((second, result)) }
        }
        try #require(emitted.count >= 8 && emitted.count <= 18)
        #expect((35...60).contains(emitted[0].0))
        for pair in zip(emitted, emitted.dropFirst()) {
            #expect((70...130).contains(pair.1.0 - pair.0.0))
            #expect(pair.1.1.action != pair.0.1.action)
        }
        for (_, result) in emitted {
            #expect(result.kind == .company)
            #expect(result.action != .eating && result.action != .idle)
            #expect(!result.caption.isEmpty && result.caption.count <= 20)
        }
    }

    @Test func hiddenSleepingQuietAndReducedMotionDoNotAccumulatePlayback() {
        let blocked: [BuddyCompanionContext] = [
            .init(isVisible: false), .init(isSleeping: true), .init(reduceMotion: true), .init(isEnabled: false)
        ]
        for context in blocked {
            var schedule = BuddyCompanionSchedule(now: now, seed: 13)
            for second in 1...200 {
                let result = schedule.tick(now: now.addingTimeInterval(Double(second)), context: context)
                #expect(result == nil)
            }
            #expect(schedule.activeDuration == 0)
            let resume = now.addingTimeInterval(201)
            let resumed = schedule.tick(now: resume)
            #expect(resumed == nil)
            #expect((35...60).contains(schedule.nextDueAt.timeIntervalSince(resume)))
            for second in 1...34 {
                let result = schedule.tick(now: resume.addingTimeInterval(Double(second)))
                #expect(result == nil)
            }
        }
    }

    @Test func busyInteractionsDelayAndManualPlayRestartsTheLongQuietInterval() {
        var schedule = BuddyCompanionSchedule(now: now, seed: 3)
        for second in 1...200 {
            let result = schedule.tick(now: now.addingTimeInterval(Double(second)), context: .init(isBusy: true))
            #expect(result == nil)
        }
        #expect(schedule.nextDueAt >= now.addingTimeInterval(212))
        let tapped = now.addingTimeInterval(201)
        schedule.postpone(after: tapped)
        #expect((70...130).contains(schedule.nextDueAt.timeIntervalSince(tapped)))
        for second in 201...270 {
            let result = schedule.tick(now: now.addingTimeInterval(Double(second)))
            #expect(result == nil)
        }
        var emitted = 0
        for second in 271...331 {
            if schedule.tick(now: now.addingTimeInterval(Double(second))) != nil { emitted += 1 }
        }
        #expect(emitted == 1)
    }

    @Test func sleepGapsAndClockChangesCannotPretendToBeActiveTime() {
        var schedule = BuddyCompanionSchedule(now: now, seed: 0)
        for second in 1...10 {
            let result = schedule.tick(now: now.addingTimeInterval(Double(second)))
            #expect(result == nil)
        }
        #expect(schedule.activeDuration == 10)
        let wake = now.addingTimeInterval(3_600)
        let waking = schedule.tick(now: wake)
        #expect(waking == nil)
        #expect(schedule.activeDuration == 10)
        #expect((35...60).contains(schedule.nextDueAt.timeIntervalSince(wake)))
        let backwards = schedule.tick(now: now)
        #expect(backwards == nil)
        #expect(schedule.activeDuration == 10)
        let saved = schedule
        let invalid = schedule.tick(now: Date(timeIntervalSinceReferenceDate: .nan))
        #expect(invalid == nil)
        schedule.postpone(after: Date(timeIntervalSinceReferenceDate: .infinity))
        #expect(schedule == saved)
    }

    @Test func careUsesVisibleActiveTimeAndDoesNotRepeatMoreOftenThanFortyFiveMinutes() throws {
        var schedule = BuddyCompanionSchedule(now: now, seed: 99)
        var careTimes: [Int] = []
        for second in 1...5_700 {
            if let moment = schedule.tick(now: now.addingTimeInterval(Double(second))), moment.kind == .care {
                careTimes.append(second)
                #expect([BuddyAction.sip, .stretch].contains(moment.action))
                #expect(moment.caption.count <= 20)
            }
        }
        try #require(careTimes.count == 2)
        #expect((2_700...2_830).contains(careTimes[0]))
        #expect((2_700...2_830).contains(careTimes[1] - careTimes[0]))
    }

    @Test func aLongHiddenBreakDoesNotImmediatelyTriggerACareMessage() {
        var schedule = BuddyCompanionSchedule(now: now, seed: 8)
        for second in 1...1_349 { _ = schedule.tick(now: now.addingTimeInterval(Double(second))) }
        for second in 1_350...6_749 {
            let result = schedule.tick(now: now.addingTimeInterval(Double(second)), context: .init(isVisible: false))
            #expect(result == nil)
        }
        #expect(schedule.activeDuration == 1_349)
        let resumed = schedule.tick(now: now.addingTimeInterval(6_750))
        #expect(resumed == nil)
        for second in 6_751...8_000 {
            let moment = schedule.tick(now: now.addingTimeInterval(Double(second)))
            #expect(moment?.kind != .care)
        }
    }
}

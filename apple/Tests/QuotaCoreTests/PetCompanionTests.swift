import Foundation
import Testing
@testable import QuotaCore

struct PetCompanionTests {
    private let now = Date(timeIntervalSince1970: 1_793_836_800)
    private func sample(_ lifetime: Int64?, _ daily: Int64?, _ offset: TimeInterval = 0,
                        day: String? = "2026-11-05") -> PetTokenObservation {
        .init(lifetimeTokens: lifetime, serverDayTokens: daily, serverDay: day,
              observedAt: now.addingTimeInterval(offset))
    }

    @Test func firstSampleDoesNotAwardHistoricalUsageAndReplayDoesNotGrow() {
        var state = PetCompanionState(now: now)
        let first = state.observe(sample(8_000_000, 1_000_000), character: .swordCat)
        #expect(first.reason == .baseline)
        #expect(state.profile(for: .swordCat, now: now).experience == 0)
        let next = state.observe(sample(8_010_000, 1_010_000, 60), character: .swordCat)
        #expect(next.experienceGained == 2)
        #expect(next.newBadges == [.tokenGrowth])
        let replay = state.observe(sample(8_010_000, 1_010_000, 60), character: .swordCat)
        let old = state.observe(sample(99_000_000, 92_000_000, 30), character: .swordCat)
        #expect(replay.reason == .unchanged && old.reason == .unchanged)
        let unchanged = state.observe(sample(8_010_000, 1_010_000, 120), character: .swordCat)
        #expect(unchanged.reason == .unchanged)
        #expect(state.profile(for: .swordCat, now: now).confirmedTokens == 10_000)
        #expect(state.profile(for: .swordCat, now: now).experience == 2)
    }

    @Test func unknownInvalidAndMismatchedSamplesCannotPretendToBeTokenGrowth() {
        var state = PetCompanionState(now: now)
        for invalid in [sample(nil, 0), sample(2, nil), sample(-1, 0), sample(2, 3),
                        sample(2, 0, day: "2026-02-30"), sample(2, 0, day: "not-a-day")] {
            #expect(state.observe(invalid, character: .dragonGirl).reason == .invalid)
        }
        #expect(state.observe(sample(1_000, 100), character: .dragonGirl).reason == .baseline)
        #expect(state.observe(sample(11_000, 100, 60), character: .dragonGirl).reason == .rebased)
        #expect(state.observe(sample(21_000, 101, 120), character: .dragonGirl).reason == .rebased)
        #expect(state.profile(for: .dragonGirl, now: now).confirmedTokens == 0)
    }

    @Test func resetsAccountChangesDayChangesAndLongGapsRebaseWithoutRewards() {
        var state = PetCompanionState(now: now)
        _ = state.observe(sample(50_000, 10_000), character: .cloudSprite)
        #expect(state.observe(sample(5_000, 1_000, 60), character: .cloudSprite).reason == .rebased)
        #expect(state.observe(sample(500_000, 2_000, 120), character: .cloudSprite).reason == .rebased)
        #expect(state.observe(sample(510_000, 12_000, 180, day: "2026-11-06"), character: .cloudSprite).reason == .rebased)
        #expect(state.observe(sample(520_000, 22_000, 3_600, day: "2026-11-06"), character: .cloudSprite).reason == .rebased)
        #expect(state.profile(for: .cloudSprite, now: now).experience == 0)
        #expect(state.observe(sample(525_000, 27_000, 3_660, day: "2026-11-06"), character: .cloudSprite).experienceGained == 1)
    }

    @Test func partialTokensCarryExactlyAndRewardsAreCapped() {
        var state = PetCompanionState(now: now)
        _ = state.observe(sample(0, 0), character: .dragonGirl)
        #expect(state.observe(sample(4_000, 4_000, 60), character: .dragonGirl).experienceGained == 0)
        #expect(state.observe(sample(5_000, 5_000, 120), character: .dragonGirl).experienceGained == 1)
        let capped = state.observe(sample(5_000_000, 5_000_000, 180), character: .dragonGirl)
        #expect(capped.experienceGained == 59)
        #expect(state.observe(sample(6_000_000, 6_000_000, 240), character: .dragonGirl).experienceGained == 0)
        #expect(state.profile(for: .dragonGirl, now: now).experience == PetCompanionState.tokenExperienceDailyLimit)
        let tomorrow = now.addingTimeInterval(86_400)
        _ = state.observe(.init(lifetimeTokens: 6_000_000, serverDayTokens: 0, serverDay: "2026-11-06", observedAt: tomorrow), character: .dragonGirl)
        let result = state.observe(.init(lifetimeTokens: 6_010_000, serverDayTokens: 10_000, serverDay: "2026-11-06", observedAt: tomorrow.addingTimeInterval(60)), character: .dragonGirl)
        #expect(result.experienceGained == 2)
    }

    @Test func hugeExactCountersAndSaturationNeverOverflow() throws {
        var state = PetCompanionState(now: now)
        _ = state.observe(sample(0, 0), character: .nailong)
        let huge = state.observe(sample(.max, .max, 60), character: .nailong)
        #expect(huge.experienceGained == PetCompanionState.tokenExperienceDailyLimit)
        #expect(state.profile(for: .nailong, now: now).confirmedTokens == Int64.max)
        _ = state.observe(sample(0, 0, 120), character: .nailong)
        _ = state.observe(sample(.max, .max, 180), character: .nailong)
        #expect(state.profile(for: .nailong, now: now).confirmedTokens == Int64.max)
        let roundtrip = try PetCompanionState.decode(state.encoded(), now: now.addingTimeInterval(180))
        #expect(roundtrip == state)
    }

    @Test func careCooldownNeedsAndDailyRewardsAreIndependentOfQuota() {
        var state = PetCompanionState(now: now)
        let first = state.care(.fruit, character: .swordCat, now: now)
        #expect(first.accepted && first.experienceGained == 3)
        #expect(first.newBadges == [.firstCare])
        #expect(state.profile(for: .swordCat, now: now).satiety == 81)
        #expect(state.cooldownRemaining(for: .fruit, character: .swordCat, now: now) == 90)
        #expect(state.care(.fruit, character: .swordCat, now: now.addingTimeInterval(89)).reason == .cooldown)
        #expect(state.care(.milk, character: .swordCat, now: now.addingTimeInterval(9)).reason == .cooldown)
        #expect(state.care(.milk, character: .swordCat, now: now.addingTimeInterval(10)).accepted)
        for index in 1...20 {
            _ = state.care(.highFive, character: .swordCat, now: now.addingTimeInterval(Double(index * 100)))
        }
        let pet = state.profile(for: .swordCat, now: now.addingTimeInterval(2_000))
        #expect(pet.experience == PetCompanionState.careExperienceDailyLimit)
        #expect(pet.bond == 16)
        #expect(pet.confirmedTokens == 0)
        #expect(pet.careCount == 22)
        #expect(state.care(.rest, character: .swordCat, now: now.addingTimeInterval(1_999)).reason == .cooldown)
    }

    @Test func achievementsUnlockOnceAndThreeDaysNeedDistinctDays() {
        var state = PetCompanionState(now: now)
        let actions: [PetCareAction] = [.fruit, .milk, .playBall, .groom, .rest]
        for (index, action) in actions.enumerated() {
            _ = state.care(action, character: .geminiGirl, now: now.addingTimeInterval(Double(index * 10)))
        }
        let first = state.profile(for: .geminiGirl, now: now.addingTimeInterval(40))
        #expect(first.badges.contains(.firstCare) && first.badges.contains(.variety) && first.badges.contains(.restful))
        #expect(!first.badges.contains(.threeDays))
        let repeatCare = state.care(.rest, character: .geminiGirl, now: now.addingTimeInterval(200))
        #expect(repeatCare.newBadges.isEmpty)
        _ = state.care(.groom, character: .geminiGirl, now: now.addingTimeInterval(86_400))
        let third = state.care(.rest, character: .geminiGirl, now: now.addingTimeInterval(172_800))
        #expect(third.newBadges == [.threeDays])
        #expect(Set(state.profile(for: .geminiGirl, now: now).badges).count == 4)
    }

    @Test func charactersKeepTheirOwnNeedsBadgesAndGrowth() {
        var state = PetCompanionState(now: now)
        _ = state.care(.fruit, character: .nailong, now: now)
        #expect(state.profile(for: .nailong, now: now).experience == 3)
        #expect(state.profile(for: .swordCat, now: now).experience == 0)
        _ = state.observe(sample(0, 0), character: .nailong)
        _ = state.observe(sample(5_000, 5_000, 60), character: .swordCat)
        #expect(state.profile(for: .swordCat, now: now).experience == 1)
        #expect(state.profile(for: .nailong, now: now).confirmedTokens == 0)
        _ = state.observe(sample(5_000, 5_000, 60), character: .nailong)
        #expect(state.profile(for: .nailong, now: now).experience == 3)
    }

    @Test func evolutionSkinsUnlockAndRemainSelectable() {
        var state = PetCompanionState(now: now)
        let locked = state.chooseSkin(.starlight, character: .dragonGirl, now: now)
        #expect(!locked)
        var evolved = 0
        for dayIndex in 0..<8 {
            let dayDate = now.addingTimeInterval(Double(dayIndex * 86_400))
            let dayKey = String(format: "2026-11-%02d", 5 + dayIndex)
            _ = state.observe(.init(lifetimeTokens: Int64(dayIndex * 500_000), serverDayTokens: 0, serverDay: dayKey, observedAt: dayDate), character: .dragonGirl)
            let result = state.observe(.init(lifetimeTokens: Int64((dayIndex + 1) * 500_000), serverDayTokens: 500_000, serverDay: dayKey, observedAt: dayDate.addingTimeInterval(60)), character: .dragonGirl)
            if result.evolved { evolved += 1 }
        }
        let pet = state.profile(for: .dragonGirl, now: now)
        #expect(pet.level >= 6)
        #expect(pet.unlockedSkins == [.natural, .starlight, .aurora])
        #expect(pet.skin == .aurora && evolved == 2)
        #expect(pet.badges.filter { $0 == .firstEvolution }.count == 1)
        let original = state.chooseSkin(.natural, character: .dragonGirl, now: now)
        #expect(original)
        #expect(state.profile(for: .dragonGirl, now: now).skin == .natural)
    }

    @Test func persistenceRejectsMalformedOversizedFutureAndTamperedRecords() throws {
        var state = PetCompanionState(now: now)
        _ = state.care(.rest, character: .cloudSprite, now: now)
        let data = try state.encoded()
        #expect(try PetCompanionState.decode(data, now: now) == state)
        #expect(throws: (any Error).self) { try PetCompanionState.decode(Data(repeating: 32, count: 100_001), now: now) }
        #expect(throws: (any Error).self) { try PetCompanionState.decode(data, now: now.addingTimeInterval(-301)) }
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 999
        let wrongVersion = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try PetCompanionState.decode(wrongVersion, now: now) }
        object["version"] = 1
        var records = try #require(object["profiles"] as? [String: [String: Any]])
        records["cloudSprite"]?["experience"] = -1
        object["profiles"] = records
        let negative = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try PetCompanionState.decode(negative, now: now) }
    }

    @Test func noOfflineDistressAndAllNewLabelsAreLocalized() {
        var state = PetCompanionState(now: now)
        _ = state.care(.rest, character: .claudeGirl, now: now)
        let away = state.profile(for: .claudeGirl, now: now.addingTimeInterval(86_400 * 365))
        #expect(away.satiety >= 25 && away.energy >= 30 && away.mood >= 35)
        #expect(away.experience == 3 && away.careCount == 1)
        for action in PetCareAction.allCases {
            #expect(action.title(language: .en) != action.title(language: .zhHans))
            #expect(action.title(language: .ja) != action.title(language: .en))
            #expect(!action.caption(language: .en).isEmpty)
            #expect(!action.symbol.isEmpty && action.buddyAction != .idle)
        }
    }
}

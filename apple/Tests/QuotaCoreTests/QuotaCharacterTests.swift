import Foundation
import Testing
@testable import QuotaCore

struct QuotaCharacterTests {
    @Test func builtInCatalogDefaultsToDragonAndCyclesWithoutLegacyArtwork() throws {
        #expect(QuotaCharacter.originalCharacters.allSatisfy { QuotaCharacter.builtInCharacters.contains($0) })
        #expect(QuotaPreferences().character == .dragonGirl)
        #expect(try JSONDecoder().decode(QuotaPreferences.self, from: Data("{}".utf8)).character == .dragonGirl)
        #expect(QuotaCharacter.builtInCharacters == [.dragonGirl, .claudeGirl, .deepseekGirl, .geminiGirl, .cloudSprite, .nailong, .swordCat])
        for removed in [QuotaCharacter.mochiCat, .butterBunny, .mintFox, .sesameBear] {
            #expect(!QuotaCharacter.builtInCharacters.contains(removed))
            #expect(removed.next == .dragonGirl)
        }
        for character in QuotaCharacter.originalCharacters { #expect(character.isOriginal) }
        for (index, character) in QuotaCharacter.builtInCharacters.enumerated() {
            #expect(character.next == QuotaCharacter.builtInCharacters[(index + 1) % QuotaCharacter.builtInCharacters.count])
            #expect(character.accentHex.count == 7)
            #expect(!character.name.isEmpty)
        }
        #expect(!QuotaCharacter.kuromi.isOriginal)
        #expect(!QuotaCharacter.myMelody.isOriginal)
        #expect(!QuotaCharacter.nailong.isOriginal && !QuotaCharacter.swordCat.isOriginal)
        #expect(QuotaCharacter.kuromi.next == .dragonGirl)
        #expect(QuotaCharacter.myMelody.next == .dragonGirl)
    }

    @Test func everyCharacterRoundTripsAndLegacyPreferencesRemainReadable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for character in QuotaCharacter.allCases {
            let preferences = QuotaPreferences(providerId: .codex, character: character, windowId: "primary")
            #expect(try decoder.decode(QuotaPreferences.self, from: encoder.encode(preferences)) == preferences)
        }
        let old = Data(#"{"providerId":"claude","character":"myMelody","windowId":"weekly"}"#.utf8)
        let decoded = try decoder.decode(QuotaPreferences.self, from: old)
        #expect(decoded.character == .myMelody)
        #expect(decoded.providerId == .claude)
        #expect(decoded.windowId == "weekly")
        for removed in ["mochiCat", "butterBunny", "mintFox", "sesameBear"] {
            let saved = Data("{\"providerId\":\"codex\",\"character\":\"\(removed)\",\"windowId\":\"primary\"}".utf8)
            let preferences = try decoder.decode(QuotaPreferences.self, from: saved)
            #expect(preferences.character.rawValue == removed)
            #expect(preferences.providerId == .codex && preferences.windowId == "primary")
        }
    }

    @Test func everyAvailableCharacterHasDistinctSignatureAndSafeMotion() {
        let catalog = QuotaCharacter.builtInCharacters
        #expect(Set(catalog.map(\.signatureEffect)).count == catalog.count)
        #expect(Set(catalog.map { $0.signatureCaption() }).count == catalog.count)
        for character in catalog {
            #expect(character.companionActions.contains(character.signatureAction))
            #expect(!character.companionActions.contains(.eating))
            #expect(Set(character.companionActions).count == character.companionActions.count)
            #expect(!character.signatureLabel.isEmpty && !character.signatureSymbol.isEmpty)
            for action in BuddyAction.allCases {
                for invalid in [-Double.infinity, -1, 0, 1, 2, Double.infinity, Double.nan] {
                    #expect(character.motionSample(action: action, progress: invalid) == .rest)
                }
                for step in 0...60 {
                    let progress = Double(step) / 60
                    let sample = character.motionSample(action: action, progress: progress)
                    let allFinite = [sample.rotationDegrees, sample.horizontalOffset, sample.verticalOffset,
                                     sample.scaleX, sample.scaleY].allSatisfy { $0.isFinite }
                    #expect(allFinite)
                    #expect(abs(sample.horizontalOffset) <= 0.1)
                    #expect((-0.181...0.017).contains(sample.verticalOffset))
                    #expect((0.88...1.12).contains(sample.scaleX))
                    #expect((0.88...1.12).contains(sample.scaleY))
                    #expect(character.motionSample(action: action, progress: progress, reduceMotion: true) == .rest)
                }
            }
        }
        let motions = catalog.map { $0.motionSample(action: $0.signatureAction, progress: 0.31) }
        for i in motions.indices {
            for j in motions.indices where i != j { #expect(motions[i] != motions[j]) }
        }
    }

    @Test func unknownCharactersStillRejectCorruptPreferences() {
        let unknown = Data(#"{"character":"unregistered-buddy"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(QuotaPreferences.self, from: unknown) }
    }
}

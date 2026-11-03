import Foundation
import Testing
@testable import QuotaCore

struct QuotaCharacterTests {
    @Test func builtInCatalogDefaultsToDragonAndCyclesWithoutLegacyArtwork() throws {
        #expect(QuotaCharacter.originalCharacters == QuotaCharacter.builtInCharacters)
        #expect(QuotaPreferences().character == .dragonGirl)
        #expect(try JSONDecoder().decode(QuotaPreferences.self, from: Data("{}".utf8)).character == .dragonGirl)
        #expect(QuotaCharacter.builtInCharacters == [.dragonGirl, .claudeGirl, .deepseekGirl, .geminiGirl, .mochiCat, .butterBunny, .mintFox, .sesameBear, .cloudSprite])
        for character in QuotaCharacter.originalCharacters { #expect(character.isOriginal) }
        for (index, character) in QuotaCharacter.builtInCharacters.enumerated() {
            #expect(character.next == QuotaCharacter.builtInCharacters[(index + 1) % QuotaCharacter.builtInCharacters.count])
            #expect(character.accentHex.count == 7)
            #expect(!character.name.isEmpty)
        }
        #expect(!QuotaCharacter.kuromi.isOriginal)
        #expect(!QuotaCharacter.myMelody.isOriginal)
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
    }

    @Test func unknownCharactersStillRejectCorruptPreferences() {
        let unknown = Data(#"{"character":"unregistered-buddy"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(QuotaPreferences.self, from: unknown) }
    }
}

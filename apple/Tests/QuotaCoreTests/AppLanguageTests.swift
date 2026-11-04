import Foundation
import Testing
@testable import QuotaCore

@Suite(.serialized)
struct AppLanguageTests {
    @Test func systemPreferenceUsesFirstSupportedLanguageAndSafeFallback() {
        #expect(YuliangLanguage.resolve(preferredLanguages: ["fr-FR", "ja-JP", "en-US"]) == .ja)
        #expect(YuliangLanguage.resolve(preferredLanguages: ["zh-Hant-TW"]) == .zhHans)
        #expect(YuliangLanguage.resolve(preferredLanguages: ["en_GB"]) == .en)
        #expect(YuliangLanguage.resolve(preferredLanguages: ["de-DE"]) == .en)
        #expect(YuliangLanguage.resolve(preferredLanguages: []) == .en)
    }

    @Test func catalogHasCompletePairedTranslations() {
        #expect(YuliangL10n.catalog.count > 390)
        for (source, entry) in YuliangL10n.catalog {
            #expect(!entry.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!entry.ja.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(YuliangL10n.text(source, language: .zhHans) == source)
            #expect(YuliangL10n.text(source, language: .en) == entry.en)
            #expect(YuliangL10n.text(source, language: .ja) == entry.ja)
        }
    }

    @Test func unknownDataDoesNotBecomeZeroOrKnownOnLanguageChange() {
        for language in [YuliangLanguage.zhHans, .en, .ja] {
            #expect(YuliangL10n.text("—", language: language) == "—")
            #expect(YuliangL10n.text("private-unrecognized-service-error", language: language) == "private-unrecognized-service-error")
            #expect(!YuliangL10n.text("剩余额度未知", language: language).contains("0%"))
            #expect(!YuliangL10n.text("未提供", language: language).isEmpty)
        }
    }

    @Test func dynamicValuesAndReportingWindowsKeepTheirValues() {
        #expect(YuliangL10n.text("5小时额度", language: .en) == "5h quota")
        #expect(YuliangL10n.text("7天额度", language: .ja) == "7日枠")
        #expect(YuliangL10n.text("剩余 63%", language: .en) == "Remaining 63%")
        #expect(YuliangL10n.text("剩余百分之63", language: .ja) == "残り63パーセント")
        #expect(YuliangL10n.text("刚刚更新 · 14:03:07", language: .en) == "Just updated · 14:03:07")
        #expect(YuliangL10n.text("已读取 Codex · 目标每 60 秒刷新", language: .en) == "Codex updated · Every ~60s")
        #expect(YuliangL10n.text("官网限流，请等待退避结束 · 120 秒后重试", language: .en) == "Official site rate-limited · Waiting to retry · Retry in 120s")
    }

    @Test func placeholderFormattingAllowsTranslatedWordOrderWithoutChangingValues() {
        #expect(YuliangL10n.format("剩余 {0}%", arguments: ["63"], language: .en) == "63% remaining")
        #expect(YuliangL10n.format("上次成功读取 {0}", arguments: ["14:03"], language: .ja) == "前回の取得成功 14:03")
        #expect(YuliangL10n.format("未知 {0}", arguments: ["12.3K"], language: .en) == "未知 12.3K")
        #expect(YuliangL10n.format("{0} {1}", arguments: ["{1}", "63"], language: .en) == "{1} 63")
    }

    @Test func sharedWidgetTitlesDatesAndAccessibilityAreLocalizedWithoutChangingValues() {
        #expect(YuliangL10n.format("最后读取 {0}", arguments: ["14:03:07"], language: .en) == "Last read 14:03:07")
        #expect(YuliangL10n.format("读于 {0}", arguments: ["14:03:07"], language: .ja) == "取得時刻 14:03:07")
        #expect(YuliangL10n.format("重置 {0}", arguments: ["23:00"], language: .en) == "Resets 23:00")
        #expect(YuliangL10n.format("摸摸{0}", arguments: ["Kitten Knight"], language: .en) == "Pet Kitten Knight")
        #expect(YuliangL10n.format("和{0}互动", arguments: ["子ねこ剣士"], language: .ja) == "子ねこ剣士と遊ぶ")
        #expect(YuliangL10n.format("{0} · {1}", arguments: ["5h quota", "Updated"], language: .en) == "5h quota · Updated")
        #expect(YuliangL10n.format("剩余百分之{0}", arguments: ["63"], language: .ja) == "残り63パーセント")
        #expect(YuliangL10n.format("已用 {0}%", arguments: ["37"], language: .en) == "37% used")
        #expect(YuliangL10n.text("上次记录，已陈旧", language: .en) == "Previous record is out of date")
        #expect(YuliangL10n.text("上次记录，重置待核对", language: .ja) == "前回の記録 · リセット要確認")
        #expect(YuliangL10n.text("星光额度轨道", language: .en) == "Starlight quota rail")
        #expect(YuliangL10n.text("点按与小伙伴互动，额度不会改变", language: .ja) == "クリックして遊べます。利用枠は変わりません")
        #expect(YuliangL10n.text("服务端日统计 · ", language: .en) == "Service daily total · ")
        #expect(YuliangL10n.text("账号累计统计", language: .ja) == "アカウント累計")
        #expect(YuliangL10n.format("更新 {0}", arguments: ["14:03"], language: .en) == "Updated 14:03")
    }

    @Test func languagePreferenceIsIndependentOfExistingQuotaDocument() throws {
        let before = QuotaStoreDocument()
        let data = try JSONEncoder().encode(before)
        let saved = YuliangL10n.language
        defer { YuliangL10n.language = saved }
        YuliangL10n.language = .ja
        #expect(YuliangL10n.text("设置") == "設定")
        YuliangL10n.language = .en
        #expect(YuliangL10n.text("设置") == "Settings")
        #expect(try JSONDecoder().decode(QuotaStoreDocument.self, from: data) == before)
    }
}

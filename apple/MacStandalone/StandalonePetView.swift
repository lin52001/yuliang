import SwiftUI
import QuotaCore

/// A companion drawer, rather than another permanent desktop window. The quota
/// widget keeps its existing dimensions; caring and collecting live here.
struct StandalonePetView: View {
    @ObservedObject var model: StandaloneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias SectionState = SwiftUI.State<PetSection>
    @SectionState private var section: PetSection = .care

    private enum PetSection: String, CaseIterable {
        case care, wardrobe, achievements
    }

    private var profile: PetProfileSnapshot { model.petProfile }
    private var character: QuotaCharacter { model.document.preferences.character }
    private var accent: Color { QuotaPalette.accent(for: character) }
    private var language: YuliangLanguage { model.language }

    var body: some View {
        VStack(spacing: 12) {
            companionHeader
            needsStrip
            Picker(copy("一起成长", "Grow together", "いっしょに成長"), selection: $section) {
                Text(copy("照顾", "Care", "お世話")).tag(PetSection.care)
                Text(copy("衣橱", "Looks", "着せ替え")).tag(PetSection.wardrobe)
                Text(copy("成就", "Badges", "実績")).tag(PetSection.achievements)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("yuliang.pet.sections")
            ScrollView {
                Group {
                    switch section {
                    case .care: careContent
                    case .wardrobe: wardrobeContent
                    case .achievements: achievementContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)
            .id(section)
            .transition(.opacity)
            footer
        }
        .padding(18)
        .frame(width: 400, height: 540)
        .background(StandalonePalette.surface)
        .foregroundStyle(.primary)
        .tint(accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: section)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: profile.level)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: profile.skin)
        .environment(\.locale, language.locale)
    }

    private var companionHeader: some View {
        HStack(spacing: 12) {
            PetBuddyPreview(character: character, skin: profile.skin,
                            activity: model.buddyActivity, size: 92)
                .frame(width: 98, height: 98)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(YuliangL10n.text(character.name, language: language))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("Lv.\(profile.level)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .fixedSize()
                }
                Text(profile.skin.title(language: language))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ProgressView(value: profile.levelProgress)
                    .progressViewStyle(.linear).tint(accent)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: profile.levelProgress)
                    .accessibilityLabel(copy("成长进度", "Growth progress", "成長の進み具合"))
                HStack(spacing: 4) {
                    Text(copy("成长", "Growth", "成長"))
                    Text("\(profile.experience) / \(profile.nextLevelExperience)")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Image(systemName: "heart.fill").foregroundStyle(accent)
                    Text("\(profile.bond)").monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy("成长 \(profile.experience) / \(profile.nextLevelExperience)，亲密度 \(profile.bond)",
                                         "Growth \(profile.experience) of \(profile.nextLevelExperience). Bond \(profile.bond).",
                                         "成長 \(profile.experience) / \(profile.nextLevelExperience)、親密度 \(profile.bond)"))
            }
        }
        .frame(height: 98)
    }

    private var needsStrip: some View {
        HStack(spacing: 14) {
            need(copy("饱食", "Fullness", "満腹"), symbol: "leaf", value: profile.satiety)
            need(copy("精力", "Energy", "元気"), symbol: "bolt", value: profile.energy)
            need(copy("心情", "Mood", "気分"), symbol: "face.smiling", value: profile.mood)
        }
        .frame(height: 34)
    }

    private func need(_ title: String, symbol: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(accent)
                Text(title)
                Spacer(minLength: 0)
                Text("\(value)").monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            ProgressView(value: Double(value), total: 100).tint(accent.opacity(0.72))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value) / 100")
    }

    private var careContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(PetCareAction.allCases, id: \.self) { action in
                    careButton(action)
                }
            }
            Text(copy("不用赶进度，偶尔陪它玩一会儿就很好。",
                      "No rush. A little time together goes a long way.",
                      "急がなくて大丈夫。少し遊ぶだけでもうれしい。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func careButton(_ action: PetCareAction) -> some View {
        let cooldown = max(0, model.petCooldown(for: action))
        let ready = cooldown <= 0
        return Button { model.care(action) } label: {
            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 34)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                Text(action.title(language: language))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 27, alignment: .top)
                Text(ready ? copy("一起玩", "Ready", "遊ぼう")
                           : copy("成长 \(Int(ceil(cooldown)))s", "Bonus \(Int(ceil(cooldown)))s", "成長まで\(Int(ceil(cooldown)))s"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: 85)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!model.petCareAvailable)
        .help(action.caption(language: language))
        .accessibilityIdentifier("yuliang.pet.care." + action.rawValue)
        .accessibilityLabel(action.title(language: language))
        .accessibilityValue(ready ? copy("可以互动", "Ready to play", "お世話できます")
                                : copy("可以互动，\(Int(ceil(cooldown))) 秒后再次获得成长", "Ready to play. Growth bonus returns in \(Int(ceil(cooldown))) seconds.", "遊べます。成長ボーナスまであと \(Int(ceil(cooldown))) 秒"))
    }

    private var wardrobeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PetEvolutionSkin.allCases, id: \.self) { skin in
                skinRow(skin)
                if skin != PetEvolutionSkin.allCases.last { Divider().padding(.leading, 51) }
            }
            Text(copy("成长解锁配饰，每个伙伴都会保留自己的模样。",
                      "Growth unlocks accessories. Every buddy keeps their own look.",
                      "成長でアクセサリーが解放。みんなの個性はそのまま。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func skinRow(_ skin: PetEvolutionSkin) -> some View {
        let unlocked = profile.unlockedSkins.contains(skin)
        let selected = profile.skin == skin
        return Button { model.choosePetSkin(skin) } label: {
            HStack(spacing: 11) {
                Image(systemName: skin == .natural ? "leaf" : skin == .starlight ? "sparkles" : "crown")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(unlocked ? accent : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background(accent.opacity(unlocked ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(skin.title(language: language)).font(.system(size: 12, weight: .medium))
                    Text(unlocked ? copy("已解锁", "Unlocked", "解放済み")
                                  : copy("Lv.\(skin.requiredLevel) 解锁", "Unlocks at Lv.\(skin.requiredLevel)", "Lv.\(skin.requiredLevel) で解放"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : unlocked ? "circle" : "lock.fill")
                    .font(.system(size: 15)).foregroundStyle(selected ? accent : Color.secondary)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
        .accessibilityIdentifier("yuliang.pet.skin." + skin.rawValue)
        .accessibilityLabel(skin.title(language: language))
        .accessibilityValue(selected ? copy("正在穿戴", "Equipped", "着用中")
                                : unlocked ? copy("已解锁", "Unlocked", "解放済み")
                                : copy("Lv.\(skin.requiredLevel) 解锁", "Unlocks at Lv.\(skin.requiredLevel)", "Lv.\(skin.requiredLevel) で解放"))
    }

    private var achievementContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(copy("一起留下的小纪念", "Little milestones together", "いっしょの小さな記念"))
                Spacer()
                Text("\(profile.badges.count) / \(PetAchievement.allCases.count)").monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(PetAchievement.allCases, id: \.self) { badge in
                let unlocked = profile.badges.contains(badge)
                HStack(spacing: 11) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(unlocked ? accent : Color.secondary.opacity(0.65))
                        .frame(width: 36, height: 36)
                        .background(unlocked ? accent.opacity(0.1) : Color.primary.opacity(0.035), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(badge.title(language: language)).font(.system(size: 12, weight: .medium))
                        Text(badge.detail(language: language)).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: unlocked ? "checkmark.seal.fill" : "lock")
                        .font(.system(size: 12)).foregroundStyle(unlocked ? accent : Color.secondary)
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(badge.title(language: language) + ". " + badge.detail(language: language))
                .accessibilityValue(unlocked ? copy("已获得", "Earned", "獲得済み") : copy("尚未获得", "Not yet earned", "未獲得"))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.petStorageError ?? model.petNotice ?? copy("今天也有好好陪着你。", "Right here with you, today too.", "今日もそばにいるよ。"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.petStorageError == nil ? accent : Color.red)
                .lineLimit(3)
                .accessibilityAddTraits(.updatesFrequently)
            Text(copy("照顾与真实新增 Token 均可成长；无需额外消耗。",
                      "Care and new verified Token use help growth. No extra use needed.",
                      "お世話と確認済みの新規 Token で成長。余分な消費は不要です。"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 40, alignment: .topLeading)
    }

    private func copy(_ zh: String, _ en: String, _ ja: String) -> String {
        switch language.resolved {
        case .zhHans: return zh
        case .ja: return ja
        default: return en
        }
    }
}

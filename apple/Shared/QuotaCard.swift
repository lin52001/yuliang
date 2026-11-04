import SwiftUI
import QuotaCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum QuotaPalette {
    static let ink = Color.primary
    #if os(macOS)
    static let surface = Color(nsColor: .windowBackgroundColor)
    #else
    static let surface = Color(uiColor: .secondarySystemBackground)
    #endif
    static let purple = Color(red: 0.42, green: 0.31, blue: 0.56)
    static let pink = Color(red: 0.74, green: 0.31, blue: 0.46)
    static let track = Color.primary.opacity(0.09)
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }))
        #else
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
        #endif
    }
    static func accent(for character: QuotaCharacter) -> Color {
        guard let value = UInt64(String(character.accentHex.dropFirst()), radix: 16) else { return purple }
        let red = Double((value >> 16) & 255) / 255
        let green = Double((value >> 8) & 255) / 255
        let blue = Double(value & 255) / 255
        return adaptive(light: (red, green, blue), dark: (red * 0.65 + 0.35, green * 0.65 + 0.35, blue * 0.65 + 0.35))
    }
}

/// Provider identity is independent from the selected companion theme.
struct ProviderBrandMark: View {
    let provider: QuotaProvider
    var size: CGFloat = 12
    var body: some View {
        Group {
            if provider == .codex {
                codexMark
            } else if provider == .claude {
                Image(systemName: "sun.max.fill").resizable().scaledToFit()
                    .foregroundStyle(Color(red: 0.78, green: 0.45, blue: 0.32))
            } else {
                Image(systemName: "terminal.fill").resizable().scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
    @ViewBuilder private var codexMark: some View {
        #if os(macOS)
        if let image = BuddyArtworkCache.installedCodexIcon {
            image.resizable().interpolation(.high).scaledToFit()
        } else { bundledCodexMark }
        #else
        bundledCodexMark
        #endif
    }
    @ViewBuilder private var bundledCodexMark: some View {
        if let image = BuddyArtworkCache.load("provider-codex", from: .main) {
            image.resizable().interpolation(.high).scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else { Image(systemName: "terminal.fill").resizable().scaledToFit() }
    }
}

enum BuddyActivitySource: Equatable { case usage, play, companion }

/// Shared by both surfaces. Opening a second view does not restart the event.
struct BuddyActivity: Equatable {
    let id = UUID()
    let action: BuddyAction
    let startedAt: Date
    let source: BuddyActivitySource
    var consumedPercent: Double? = nil
    var duration: TimeInterval { action.duration }
    var caption: String {
        switch action {
        case .idle: return "等你一起开工"
        case .eating:
            if source == .usage, let consumedPercent {
                return "额度用了 \(String(format: "%g", consumedPercent))% · 吃一块小饼干"
            }
            return "零食时间 · 这口不改变额度"
        case .pat: return "摸摸头，心情变好了"
        case .wave: return "在这里，陪你一起开工"
        case .nap: return "眯一小会儿，马上回来"
        case .celebrate: return "给你一点小小的鼓励"
        case .jump: return "蹦一下，继续加油"
        case .dance: return "跟着节拍摇摇摆"
        case .spin: return "转一圈，元气回来啦"
        case .stretch: return "伸个懒腰，肩膀放松一点"
        case .nuzzle: return "靠近一点，陪着你就很好"
        case .peek: return "探个头，看看你有没有想我"
        case .sip: return "碰个杯，你也喝口水吧"
        }
    }
}

/// Vector biscuit keeps the same crisp edges at both widget sizes.
struct CookieBiscuit: View {
    var bitten = false
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Path { path in
                    path.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
                    if bitten {
                        path.addEllipse(in: CGRect(x: side * 0.63, y: -side * 0.1, width: side * 0.56, height: side * 0.56))
                    }
                }.fill(Color(red: 0.87, green: 0.66, blue: 0.43), style: FillStyle(eoFill: true))
                ForEach(0..<5) { index in
                    let points: [(CGFloat, CGFloat)] = [(0.27,0.28),(0.55,0.22),(0.38,0.56),(0.7,0.62),(0.27,0.77)]
                    Circle().fill(Color(red: 0.43, green: 0.27, blue: 0.18).opacity(0.86))
                        .frame(width: side * 0.105, height: side * 0.105)
                        .position(x: points[index].0 * side, y: points[index].1 * side)
                }
            }
        }.accessibilityHidden(true)
    }
}

/// Atlas rows are explicit: a theme can never accidentally borrow another character.
private extension QuotaCharacter {
    var illustrationRow: Int? {
        switch self {
        case .dragonGirl: 0
        case .claudeGirl: 1
        case .deepseekGirl: 2
        case .geminiGirl: 3
        default: nil
        }
    }
}

@MainActor
private enum BuddyArtworkCache {
    private static var images: [String: Image] = [:]
    #if os(macOS)
    static let installedCodexIcon: Image? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return nil }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }()
    #endif
    static func load(_ name: String, from bundle: Bundle) -> Image? {
        guard let url = bundle.url(forResource: name, withExtension: "png") else { return nil }
        if let image = images[url.path] { return image }
        #if os(macOS)
        guard let bitmap = NSImage(contentsOf: url) else { return nil }
        let image = Image(nsImage: bitmap)
        #else
        guard let bitmap = UIImage(contentsOfFile: url.path) else { return nil }
        let image = Image(uiImage: bitmap)
        #endif
        images[url.path] = image
        return image
    }
}

struct BuddySprite: View {
    let character: QuotaCharacter
    let frame: Int
    var size: CGFloat = 56
    var resourceBundle: Bundle = .main
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var atlas: (image: Image, row: Int, rowCount: Int)? {
        if let row = character.illustrationRow,
           let image = BuddyArtworkCache.load("original-buddies-v1", from: resourceBundle) {
            return (image, row, 4)
        }
        if character == .kuromi || character == .myMelody,
           let image = BuddyArtworkCache.load("anime-satiety-atlas-v1", from: resourceBundle) {
            return (image, character == .kuromi ? 0 : 1, 2)
        }
        if character == .nailong || character == .swordCat,
           let image = BuddyArtworkCache.load("new-buddies-v017", from: resourceBundle) {
            return (image, character == .nailong ? 0 : 1, 2)
        }
        return nil
    }
    var body: some View {
        Group {
            if let atlas {
                atlas.image.resizable().interpolation(.high)
                    .frame(width: size * 6, height: size * CGFloat(atlas.rowCount))
                    .offset(x: -CGFloat(max(0, min(5, frame))) * size, y: -CGFloat(atlas.row) * size)
                    .frame(width: size, height: size, alignment: .topLeading).clipped()
                    .allowsHitTesting(false)
            } else if character == .nailong || character == .swordCat {
                // A damaged/missing atlas must not impersonate another buddy.
                Image(systemName: character.signatureSymbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(QuotaPalette.accent(for: character))
                    .frame(width: size, height: size)
                    .background(QuotaPalette.accent(for: character).opacity(0.08), in: Circle())
            } else {
                OriginalBuddy(character: character, frame: frame, size: size)
            }
        }
        // Clipping only trims pixels; constrain the atlas's interaction region
        // separately so invisible rows cannot cover adjacent character buttons.
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .transaction { $0.animation = nil }
        // Swap silhouettes with an outer dissolve, while atlas frame/crop
        // changes remain instantaneous inside the sprite's own transaction.
        .id(character)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: character)
    }
}

/// Motion follows each silhouette. Mouth positions are relative to the sprite's
/// center and never affect the rail's quota-derived position.
private struct BuddyMotionProfile {
    var mouthX: Double = 0
    var mouthY: Double = 0.07
    var waveAngle: Double = 8
    var napAngle: Double = 5
    var patScale: Double = 0.045
    var cheerLift: Double = 4
    var chewLift: Double = 0.8
    var jumpLift: Double = 8
    var danceAngle: Double = 9
    var danceSway: Double = 2.4
    var spinDirection: Double = 1

    init(character: QuotaCharacter, illustrated: Bool) {
        switch character {
        case .dragonGirl:
            waveAngle = 7; napAngle = 4; cheerLift = 4.5; mouthY = illustrated ? -0.08 : 0.05
            jumpLift = 9; danceAngle = 8; danceSway = 2.2
        case .claudeGirl:
            waveAngle = 4; napAngle = 3; patScale = 0.035; cheerLift = 2.5; mouthY = illustrated ? -0.08 : 0.05
            jumpLift = 6; danceAngle = 5; danceSway = 1.8; spinDirection = -1
        case .deepseekGirl:
            waveAngle = 6; napAngle = 4; cheerLift = 3.5; mouthY = illustrated ? -0.07 : 0.05
            jumpLift = 7.5; danceAngle = 8; danceSway = 2.5
        case .geminiGirl:
            waveAngle = 10; napAngle = 5; patScale = 0.055; cheerLift = 5; mouthY = illustrated ? -0.08 : 0.05
            jumpLift = 10; danceAngle = 12; danceSway = 3; spinDirection = -1
        case .cloudSprite:
            waveAngle = 6; napAngle = 4; cheerLift = 3; mouthY = 0.05
            jumpLift = 8.5; danceAngle = 9; danceSway = 2.8
        case .nailong:
            mouthY = -0.20; waveAngle = 5; napAngle = 3; chewLift = 1.3
            jumpLift = 6; danceAngle = 7; danceSway = 2
        case .swordCat:
            mouthY = -0.015; waveAngle = 4; napAngle = 3; jumpLift = 9
            danceAngle = 5; danceSway = 1.6; spinDirection = -1
        case .mochiCat:
            waveAngle = 9; napAngle = 7; patScale = 0.06; cheerLift = 4
            jumpLift = 7; danceAngle = 11; danceSway = 2.4; spinDirection = -1
        case .butterBunny:
            waveAngle = 7; napAngle = 5; patScale = 0.055; cheerLift = 5
            jumpLift = 10; danceAngle = 8; danceSway = 2
        case .mintFox:
            waveAngle = 11; napAngle = 6; cheerLift = 4.5
            jumpLift = 9; danceAngle = 12; danceSway = 3.2; spinDirection = -1
        case .sesameBear:
            waveAngle = 5; napAngle = 4; patScale = 0.035; cheerLift = 2.5; chewLift = 0.5
            jumpLift = 5; danceAngle = 5; danceSway = 1.4
        case .kuromi, .myMelody: break
        }
    }
}

struct QuotaCard: View {
    let document: QuotaStoreDocument
    let now: Date
    var compact = false
    var reaction = false
    var resourceBundle: Bundle = .main
    var onPat: (() -> Void)? = nil
    var widgetInteraction = false
    var animateChanges = false
    var activity: BuddyActivity? = nil
    var activityPreviewElapsed: TimeInterval? = nil
    var onAction: ((BuddyAction) -> Void)? = nil
    var minimal = false
    var slim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let value = QuotaPresentation(document: document, now: now)
        QuotaCardContent(document: document, now: now, compact: compact, minimal: minimal, slim: slim, reaction: reaction,
                         resourceBundle: resourceBundle, onPat: onPat, widgetInteraction: widgetInteraction,
                         progress: value.remainingPercent ?? 0, isKnown: value.remainingPercent != nil,
                         activity: activity, activityPreviewElapsed: activityPreviewElapsed, onAction: onAction)
            .animation(animateChanges && !reduceMotion && value.freshness == .fresh ? .easeInOut(duration: 0.8) : nil,
                       value: value.remainingPercent)
            .id("\(value.provider.rawValue)/\(value.window?.id ?? "missing")/\(value.remainingPercent != nil)/\(value.freshness)")
    }
}

/// All visible quota elements read the same interpolated percentage.
private struct QuotaCardContent: View, Animatable {
    let document: QuotaStoreDocument
    let now: Date
    let compact: Bool
    let minimal: Bool
    let slim: Bool
    let reaction: Bool
    let resourceBundle: Bundle
    let onPat: (() -> Void)?
    let widgetInteraction: Bool
    var progress: Double
    let isKnown: Bool
    let activity: BuddyActivity?
    let activityPreviewElapsed: TimeInterval?
    let onAction: ((BuddyAction) -> Void)?
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var presentation: QuotaPresentation {
        QuotaPresentation(document: document, provider: document.preferences.providerId, now: now)
    }
    var accent: Color { QuotaPalette.accent(for: document.preferences.character) }
    var remaining: Double? { isKnown ? progress : nil }
    var used: Double? { remaining.map { 100 - $0 } }
    var frame: Int {
        if reaction { return 4 }
        guard let used else { return 0 }
        return used >= 90 ? 3 : used >= 60 ? 2 : used >= 25 ? 1 : 0
    }
    var title: String {
        if reaction { return "摸摸头，今天也一起加油呀。" }
        guard let used else { return "等一口新消息" }
        return used >= 90 ? "吃饱啦，歇一会儿" : used >= 60 ? "很满足" : used >= 25 ? "再吃一小口" : "肚子还空空的"
    }
    var providerName: String { document.preferences.providerId.name }
    var status: String {
        switch presentation.freshness {
        case .missing: return document.preferences.providerId == .codex ? "等待 Codex 读取" : "等待官网读取"
        case .stale: return "上次记录 · 已陈旧"
        case .resetDue: return "上次记录 · 重置待核对"
        case .fresh:
            if remaining != nil { return "已读取" }
            return document.preferences.providerId == .codex ? "Codex 未提供百分比" : "官网未提供百分比"
        }
    }
    var readingLabel: String {
        switch presentation.freshness {
        case .stale, .resetDue: return "上次剩余"
        case .fresh: return "剩余"
        case .missing: return "待连接"
        }
    }
    var subtitle: String {
        if compact {
            if presentation.freshness == .resetDue { return "重置待核对" }
            if presentation.freshness == .stale { return "记录已陈旧" }
        }
        if document.preferences.providerId == .codex {
            return presentation.window.map { "订阅额度 · \($0.label)" } ?? "订阅额度"
        }
        return presentation.window?.label ?? "网页订阅"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: slim ? (compact ? 2 : 4) : compact ? 6 : 10) {
            if slim {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(YuliangL10n.text(presentation.window?.label ?? "订阅额度"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Circle().fill(presentation.freshness == .fresh && remaining != nil ? Color.green : Color.secondary)
                        .frame(width: 4, height: 4).help(YuliangL10n.text(status)).accessibilityLabel(YuliangL10n.text(status))
                    Spacer(minLength: 4)
                    Text(YuliangL10n.text(remaining == nil ? "待确认" : readingLabel))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    readout.font(.system(size: slim && compact ? 18 : 22, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
            HStack(spacing: compact ? 4 : 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(YuliangL10n.text(minimal ? "订阅额度" : providerName)).font(.system(size: compact ? 12 : 13, weight: .semibold))
                    Text(YuliangL10n.text(minimal ? (presentation.window?.label ?? "等待读取") : subtitle))
                        .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Circle().fill(presentation.freshness == .fresh ? Color.green : Color.secondary).frame(width: 4, height: 4)
                    .help(YuliangL10n.text(status)).accessibilityLabel(YuliangL10n.text(status))
                Spacer(minLength: 0)
                if compact {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(YuliangL10n.text(remaining == nil ? "待确认" : readingLabel))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        readout.font(.system(size: slim && compact ? 18 : 22, weight: .semibold, design: .rounded))
                    }.fixedSize(horizontal: true, vertical: false)
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(YuliangL10n.text(readingLabel)).font(.system(size: 9)).foregroundStyle(.secondary)
                        readout.font(.system(size: 30, weight: .semibold, design: .rounded))
                    }
                }
            }
            }
            QuotaRail(remainingPercent: remaining, character: document.preferences.character, frame: frame,
                      accent: accent, size: slim ? (compact ? 28 : 36) : compact ? 48 : 56, resourceBundle: resourceBundle,
                      onPat: onPat, widgetInteraction: widgetInteraction, activity: activity, activityPreviewElapsed: activityPreviewElapsed,
                      onAction: onAction, trackHeight: slim ? (compact ? 8 : 12) : nil)
                .frame(height: slim ? (compact ? 28 : 36) : compact ? 48 : 56)
            if !minimal && !compact { Text(YuliangL10n.text(title)).font(.system(size: 12, weight: .medium)).lineLimit(1) }
            if !minimal { HStack(alignment: .firstTextBaseline) {
                Text(used.map { YuliangL10n.format("已用 {0}%", String(format: "%.0f", $0)) } ?? YuliangL10n.text("已用量未知"))
                Spacer(minLength: 3)
                if let date = presentation.observedAt {
                    Group {
                        if compact && presentation.provider == .codex {
                            Text(YuliangL10n.format("读于 {0}", date.formatted(.dateTime.hour().minute().second().locale(YuliangL10n.language.locale))))
                        }
                        else if compact { Text(YuliangL10n.format("读于 {0}", date.formatted(.dateTime.hour().minute().locale(YuliangL10n.language.locale)))) }
                        else { Text(YuliangL10n.format("读于 {0}", date.formatted(.dateTime.hour().minute().locale(YuliangL10n.language.locale)))) }
                    }.monospacedDigit().accessibilityLabel(YuliangL10n.format("最后读取 {0}", date.formatted(.dateTime.locale(YuliangL10n.language.locale))))
                } else { Text(YuliangL10n.text("未读取")) }
            }.font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary).lineLimit(1)
            if !compact {
                HStack {
                    Text(YuliangL10n.text(status))
                    Spacer(minLength: 3)
                    if let reset = presentation.resetAt, reset > now {
                        Text(YuliangL10n.format("重置 {0}", reset.formatted(.dateTime.hour().minute().locale(YuliangL10n.language.locale))))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            }
        }.foregroundStyle(QuotaPalette.ink)
    }
    var readout: some View {
        Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
            .monospacedDigit()
            .accessibilityLabel(remaining.map { YuliangL10n.format("剩余百分之{0}", String(Int($0.rounded()))) } ?? YuliangL10n.text("剩余额度未知"))
    }
}

/// Fill, clipping and marker derive from the card's one visible percentage.
struct QuotaRail: View {
    let progress: Double
    let isKnown: Bool
    let character: QuotaCharacter
    let frame: Int
    let accent: Color
    let size: CGFloat
    let resourceBundle: Bundle
    var onPat: (() -> Void)?
    var widgetInteraction: Bool
    var activity: BuddyActivity?
    var activityPreviewElapsed: TimeInterval?
    var onAction: ((BuddyAction) -> Void)?
    var trackHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    // The explicit wrapper alias also works with Command Line Tools whose SDK
    // exposes the newer State macro without bundling its compiler plugin.
    private typealias HoverState = SwiftUI.State<CGFloat?>
    @HoverState private var hoverX: CGFloat? = nil

    init(remainingPercent: Double?, character: QuotaCharacter, frame: Int, accent: Color,
         size: CGFloat, resourceBundle: Bundle = .main, onPat: (() -> Void)? = nil,
         widgetInteraction: Bool = false, activity: BuddyActivity? = nil, activityPreviewElapsed: TimeInterval? = nil,
         onAction: ((BuddyAction) -> Void)? = nil, trackHeight: CGFloat? = nil) {
        let valid = remainingPercent.map { $0.isFinite && (0...100).contains($0) } ?? false
        self.progress = valid ? remainingPercent! : 0
        self.isKnown = valid
        self.character = character; self.frame = frame; self.accent = accent
        self.size = size; self.resourceBundle = resourceBundle
        self.onPat = onPat; self.widgetInteraction = widgetInteraction
        self.activity = activity; self.activityPreviewElapsed = activityPreviewElapsed; self.onAction = onAction
        self.trackHeight = trackHeight
    }
    private var motion: BuddyMotionProfile {
        BuddyMotionProfile(character: character, illustrated: character.illustrationRow != nil
            && resourceBundle.url(forResource: "original-buddies-v1", withExtension: "png") != nil)
    }
    var body: some View {
        GeometryReader { geometry in
            let layout = QuotaRailGeometry(width: geometry.size.width, avatarSize: size, remainingPercent: isKnown ? progress : nil)
            ZStack(alignment: .leading) {
                refinedTrack(layout, height: trackHeight ?? (size < 50 ? 10 : 12))
                if let activity {
                    if let elapsed = activityPreviewElapsed {
                        activeBuddy(activity, elapsed: elapsed, size: layout.avatarSize)
                            .offset(x: layout.markerLeadingX)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                            activeBuddy(activity, elapsed: max(0, context.date.timeIntervalSince(activity.startedAt)), size: layout.avatarSize)
                        }.frame(width: layout.avatarSize, height: layout.avatarSize)
                            .offset(x: layout.markerLeadingX)
                    }
                } else {
                    buddy(size: layout.avatarSize).offset(x: layout.markerLeadingX)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    /// One continuous, measured ribbon. Stars are touch targets and scale marks,
    /// never editable quota. Its moving character still uses the same geometry.
    private func refinedTrack(_ layout: QuotaRailGeometry, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(accent.opacity(colorScheme == .dark ? 0.11 : 0.065))
                .overlay { Capsule().strokeBorder(accent.opacity(colorScheme == .dark ? 0.24 : 0.13), lineWidth: 0.5) }
            if layout.isKnown {
                Capsule().fill(LinearGradient(stops: [
                    .init(color: accent.opacity(colorScheme == .dark ? 0.36 : 0.28), location: 0),
                    .init(color: accent.opacity(colorScheme == .dark ? 0.75 : 0.68), location: 0.72),
                    .init(color: accent.opacity(colorScheme == .dark ? 0.92 : 0.86), location: 1),
                ], startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .top) {
                        Capsule().fill(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55))
                            .frame(height: 1).padding(.horizontal, 5).padding(.top, 2)
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: layout.fillWidth) }
                ForEach(1..<10) { tick in
                    let reached = Double(tick) * 10 <= progress
                    if tick % 2 == 0 {
                        Image(systemName: character.signatureEffect == .starlight ? "sparkle" : "circle.fill")
                            .font(.system(size: character.signatureEffect == .starlight ? 5.5 : 2.2, weight: .semibold))
                            .foregroundStyle(reached ? Color.white.opacity(0.82) : accent.opacity(0.28))
                            .frame(width: 7, height: 7)
                            .offset(x: layout.width * Double(tick) / 10 - 3.5)
                    } else {
                        Capsule().fill(reached ? Color.white.opacity(0.42) : accent.opacity(0.16))
                            .frame(width: 0.7, height: 2.5)
                            .offset(x: layout.width * Double(tick) / 10 - 0.35)
                    }
                }
                if progress > 0 {
                    Circle().fill(Color.white.opacity(0.92))
                        .overlay { Circle().stroke(accent.opacity(0.7), lineWidth: 0.75) }
                        .shadow(color: accent.opacity(0.45), radius: 3)
                        .frame(width: 5, height: 5)
                        .offset(x: min(max(0, layout.width - 5), max(0, layout.fillWidth - 2.5)))
                }
            }
            if let hoverX, onAction != nil {
                Circle().fill(accent.opacity(0.15)).frame(width: 18, height: 18)
                    .overlay { Image(systemName: character.signatureSymbol).font(.system(size: 7)).foregroundStyle(accent) }
                    .offset(x: min(max(0, layout.width - 18), max(0, hoverX - 9)))
            }
        }
        .frame(height: height)
        .overlay {
            if let activity, !reduceMotion {
                if let elapsed = activityPreviewElapsed {
                    trackResponse(layout, activity: activity, elapsed: elapsed)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        trackResponse(layout, activity: activity, elapsed: context.date.timeIntervalSince(activity.startedAt))
                    }
                }
            }
        }
        .frame(height: max(22, height))
        .contentShape(Capsule())
        .onContinuousHover { phase in
            switch phase { case .active(let point): hoverX = point.x; case .ended: hoverX = nil }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            guard let onAction else { onPat?(); return }
            let ratio = value.location.x / max(1, layout.width)
            let choices: [BuddyAction] = [.peek, .nuzzle, character.signatureAction, .stretch]
            onAction(choices[min(3, max(0, Int(ratio * 4)))])
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(YuliangL10n.text("星光额度轨道"))
        .accessibilityValue(isKnown ? YuliangL10n.format("剩余百分之{0}", String(Int(progress.rounded()))) : YuliangL10n.text("额度未知"))
        .accessibilityHint(onAction == nil ? "" : YuliangL10n.text("点按与小伙伴互动，额度不会改变"))
        .accessibilityAddTraits(onAction == nil ? [] : .isButton)
        .accessibilityAction { onAction?(.peek) }
        .accessibilityIdentifier("yuliang.quota.rail")
    }

    private func trackResponse(_ layout: QuotaRailGeometry, activity: BuddyActivity, elapsed: TimeInterval) -> some View {
        let t = min(1, max(0, elapsed / max(0.001, activity.duration)))
        let visible = elapsed >= 0 && elapsed < activity.duration
        let envelope = pow(sin(t * .pi), 2)
        let x = min(max(16, layout.fillWidth), max(16, layout.width - 16))
        let responseWidth = min(layout.width, 46 + 24 * envelope)
        let responseX = min(max(0, x - responseWidth / 2), max(0, layout.width - responseWidth))
        return ZStack(alignment: .leading) {
            // A local response follows the measured endpoint, never changes its value.
            Capsule().fill(accent.opacity(0.18 * envelope))
                .frame(width: responseWidth, height: 3)
                .offset(x: responseX)
            ForEach(0..<3) { index in
                let phase = t * .pi * 2 + Double(index) * 0.8
                Group {
                    if character.signatureEffect == .tideBubble || character.signatureEffect == .puddingBounce {
                        Circle().stroke(accent.opacity(0.75), lineWidth: 0.85)
                            .frame(width: Double(3 + index * 2), height: Double(3 + index * 2))
                    } else {
                        Image(systemName: character.signatureSymbol)
                            .font(.system(size: index == 1 ? 6 : 4, weight: .medium))
                            .foregroundStyle(accent)
                    }
                }
                .offset(x: min(max(3, x - Double(index + 1) * 12 + sin(phase) * 3), max(3, layout.width - 10)),
                        y: -Double(4 + index * 3) * envelope)
                .opacity(visible ? envelope : 0)
            }
        }.frame(width: layout.width, height: 14, alignment: .leading)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    @ViewBuilder func activeBuddy(_ activity: BuddyActivity, elapsed: TimeInterval, size: Double) -> some View {
        let active = elapsed.isFinite && elapsed >= 0 && elapsed < activity.duration
        let t = elapsed.isFinite ? min(1, max(0, elapsed / max(0.001, activity.duration))) : 1
        let eating = active && activity.action == .eating
        let animatedFrame: Int = !active ? frame : eating ? 5 : activity.action == .nap ? 3 : 4
        let sample = active ? character.motionSample(action: activity.action, progress: t, reduceMotion: reduceMotion) : .rest
        let transform = adaptedMotion(sample, action: activity.action, size: size)
        ZStack {
            buddy(size: size, spriteFrame: animatedFrame)
                .rotationEffect(.degrees(transform.angle))
                .scaleEffect(x: transform.scaleX, y: transform.scaleY, anchor: activity.action == .jump ? .bottom : .center)
                .offset(x: transform.x, y: transform.y)
            if active {
                if eating {
                    feedingBiscuit(elapsed: elapsed, duration: activity.duration, size: size)
                } else {
                    actionFeedback(activity.action, progress: t, size: size)
                }
            }
        }.frame(width: size, height: size)
    }
    private func adaptedMotion(_ sample: BuddyMotionSample, action: BuddyAction, size: Double)
        -> (angle: Double, x: Double, y: Double, scaleX: Double, scaleY: Double) {
        let spriteScale = min(1, size / 48)
        var angle = sample.rotationDegrees
        var x = sample.horizontalOffset * size
        var y = sample.verticalOffset * size
        var scaleX = sample.scaleX
        var scaleY = sample.scaleY
        switch action {
        case .wave: angle *= motion.waveAngle / 8
        case .nap: angle *= motion.napAngle / 5
        case .eating: y = sample.verticalOffset / 0.014 * motion.chewLift * spriteScale
        case .celebrate: y = sample.verticalOffset / 0.08 * motion.cheerLift * spriteScale
        case .pat:
            scaleX = 1 + (sample.scaleX - 1) / 0.045 * motion.patScale
            scaleY = 1 + (sample.scaleY - 1) / 0.045 * motion.patScale
        case .jump:
            y = sample.verticalOffset / 0.18 * motion.jumpLift * spriteScale
        case .dance:
            angle *= motion.danceAngle / 10
            x = sample.horizontalOffset / 0.055 * motion.danceSway * spriteScale
        case .spin: angle *= motion.spinDirection
        case .stretch: angle *= motion.napAngle / 5
        case .nuzzle: angle *= motion.waveAngle / 8; x *= motion.danceSway / 2.4
        case .peek: angle *= motion.waveAngle / 8
        case .sip: y *= motion.chewLift
        case .idle: break
        }
        return (angle, x, y, scaleX, scaleY)
    }
    @ViewBuilder private func actionFeedback(_ action: BuddyAction, progress t: Double, size: Double) -> some View {
        let fade = reduceMotion ? 1 : sin(min(1, t * 3) * .pi / 2) * min(1, (1 - t) * 5)
        let flourish = reduceMotion ? 0 : sin(t * .pi)
        Group {
            if action == character.signatureAction || action == .celebrate {
                BuddySignatureFlourish(effect: character.signatureEffect, accent: accent,
                                       progress: t, size: size, reduceMotion: reduceMotion)
            } else if action == .idle {
                EmptyView()
            } else if action == .dance {
                ForEach(0..<2) { index in
                    Image(systemName: index == 0 ? "music.note" : "music.quarternote.3")
                        .font(.system(size: size * 0.19, weight: .semibold))
                        .rotationEffect(.degrees(index == 0 ? -12 : 12))
                        .offset(x: (index == 0 ? -1 : 1) * size * 0.36,
                                y: -size * 0.22 - (reduceMotion ? 0 : 3 * sin(t * .pi * 4 + Double(index) * .pi)))
                }
            } else if action == .nuzzle {
                ForEach(0..<2) { index in
                    Image(systemName: "heart.fill")
                        .font(.system(size: size * (index == 0 ? 0.17 : 0.12)))
                        .offset(x: (index == 0 ? -1 : 1) * size * 0.32,
                                y: -size * 0.18 - Double(index + 1) * 4 * flourish)
                }
            } else if action == .sip {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: size * 0.25))
                    .rotationEffect(.degrees(reduceMotion ? 0 : -12 * flourish))
                    .offset(x: size * 0.08, y: size * 0.12 - size * 0.14 * flourish)
            } else {
                let symbol = action == .pat ? "heart.fill" : action == .wave ? "sparkle" : action == .nap ? "zzz" : action.symbol
                Image(systemName: symbol)
                    .font(.system(size: size * 0.21, weight: .semibold))
                    .offset(x: action == .spin && !reduceMotion ? cos(t * .pi * 2) * size * 0.34 : size * 0.32,
                            y: action == .spin && !reduceMotion ? -size * 0.15 + sin(t * .pi * 2) * size * 0.34 : -size * 0.34 - 3 * flourish)
            }
        }
        .foregroundStyle(accent).opacity(fade).allowsHitTesting(false).accessibilityHidden(true)
    }
    func feedingBiscuit(elapsed: TimeInterval, duration: TimeInterval, size: Double) -> some View {
        let t = min(1, max(0, elapsed / duration))
        let approach = min(1, t / 0.3)
        let chewing = max(0, min(1, (t - 0.48) / 0.42))
        // The bite notch, rather than the cookie's center, meets the mouth.
        let targetX = (motion.mouthX - 0.10) * size
        let targetY = (motion.mouthY + 0.09) * size
        let approachDistance = size * 0.60 * min(1, size / 32)
        return ZStack {
            CookieBiscuit(bitten: reduceMotion || t > 0.32)
                .frame(width: size * 0.30, height: size * 0.30)
                .scaleEffect(reduceMotion ? 1 : 1 - chewing * 0.65)
                .offset(x: reduceMotion ? targetX : targetX - approachDistance * (1 - approach),
                        y: reduceMotion ? targetY : targetY - sin(approach * .pi) * size * 0.08)
                .opacity(reduceMotion ? 1 : 1 - chewing)
            if !reduceMotion && t > 0.36 && t < 0.92 {
                ForEach(0..<4) { index in
                    let burst = min(1, (t - 0.36) / 0.56)
                    Circle().fill(Color(red: 0.82, green: 0.57, blue: 0.32))
                        .frame(width: index % 2 == 0 ? 2.6 : 1.7, height: index % 2 == 0 ? 2.6 : 1.7)
                        .offset(x: motion.mouthX * size + Double(index - 2) * burst * 6,
                                y: (motion.mouthY + 0.10) * size + burst * Double(7 + index * 2))
                        .opacity(1 - burst)
                }
            }
        }.allowsHitTesting(false)
    }
    @ViewBuilder func buddy(size: Double, spriteFrame: Int? = nil) -> some View {
        #if YULIANG_STANDALONE
        interactiveBuddy(size: size, spriteFrame: spriteFrame)
            .overlay {
                if let onAction {
                    StandaloneBuddyContextMenu(action: onAction,
                        enabled: activity.map { !($0.action == .eating && $0.source == .usage
                            && Date().timeIntervalSince($0.startedAt) < $0.duration) } ?? true,
                        character: character)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHint(YuliangL10n.text(onAction == nil ? "点按回应" : "点按随机回应，右键选择互动动作"))
        #else
        interactiveBuddy(size: size, spriteFrame: spriteFrame)
            .contextMenu {
                if let onAction {
                    ForEach(BuddyAction.interactiveActions, id: \.self) { action in
                        if action == .eating { Divider() }
                        Button(YuliangL10n.text(action.label), systemImage: action.symbol) { onAction(action) }
                    }
                }
            }
            .accessibilityHint(YuliangL10n.text(onAction == nil ? "点按回应" : "点按随机回应，右键选择互动动作"))
        #endif
    }
    @ViewBuilder private func interactiveBuddy(size: Double, spriteFrame: Int?) -> some View {
        if widgetInteraction {
            #if YULIANG_STANDALONE
            BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            #else
            Button(intent: PatQuotaBuddyIntent()) {
                BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            }.buttonStyle(.plain).accessibilityLabel(YuliangL10n.format("摸摸{0}", YuliangL10n.text(character.name)))
            #endif
        } else if let onPat {
            Button(action: onPat) {
                BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            }.buttonStyle(.plain).accessibilityLabel(YuliangL10n.format("和{0}互动", YuliangL10n.text(character.name)))
        } else if let onAction {
            Button { onAction(.pat) } label: {
                BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            }.buttonStyle(.plain).accessibilityLabel(YuliangL10n.format("摸摸{0}", YuliangL10n.text(character.name)))
        } else {
            BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
        }
    }
}

/// A small secondary motion gives each silhouette its own visual vocabulary.
/// All drawing stays around the avatar; the quota anchor is never modified.
private struct BuddySignatureFlourish: View {
    let effect: BuddySignatureEffect
    let accent: Color
    let progress: Double
    let size: Double
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, _ in
            let t = reduceMotion ? 0.5 : progress
            let pulse = sin(t * .pi)
            let mid = size / 2
            func stroke(_ path: Path, opacity: Double = 0.8, width: Double = 1) {
                context.stroke(path, with: .color(accent.opacity(opacity)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func dot(_ x: Double, _ y: Double, radius: Double, hollow: Bool = false) {
                let path = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                if hollow { stroke(path, width: 0.85) }
                else { context.fill(path, with: .color(accent.opacity(0.85))) }
            }
            switch effect {
            case .dragonSpark:
                for index in 0..<3 {
                    let x = mid + Double(index - 1) * size * 0.30
                    let y = size * (index == 1 ? 0.04 : 0.22) - pulse * size * 0.07
                    let r = size * (index == 1 ? 0.095 : 0.06)
                    var flame = Path()
                    flame.move(to: CGPoint(x: x, y: y - r))
                    flame.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x + r * 1.8, y: y + r * 0.3))
                    flame.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x - r, y: y + r * 0.1))
                    context.fill(flame, with: .color(accent.opacity(0.72)))
                }
            case .amberOrbit:
                var orbit = Path()
                orbit.addEllipse(in: CGRect(x: size * 0.08, y: size * 0.15, width: size * 0.84, height: size * 0.56))
                stroke(orbit, opacity: 0.34, width: 0.75)
                for index in 0..<3 {
                    let angle = t * .pi * 2 + Double(index) * .pi * 2 / 3
                    dot(mid + cos(angle) * size * 0.42, size * 0.43 + sin(angle) * size * 0.28, radius: size * 0.035)
                }
            case .tideBubble:
                for index in 0..<3 {
                    let x = mid + Double(index - 1) * size * 0.32 + sin(t * .pi * 2 + Double(index)) * size * 0.035
                    let y = size * (index == 1 ? 0.12 : 0.31) - pulse * size * 0.14
                    dot(x, y, radius: size * Double(3 + index) / 55, hollow: true)
                }
                var wave = Path()
                wave.move(to: CGPoint(x: size * 0.12, y: size * 0.88))
                wave.addQuadCurve(to: CGPoint(x: size * 0.88, y: size * 0.88),
                                  control: CGPoint(x: mid, y: size * (0.88 - pulse * 0.12)))
                stroke(wave, opacity: 0.45, width: 0.8)
            case .starlight:
                var line = Path()
                for index in 0..<3 {
                    let x = mid + Double(index - 1) * size * 0.34
                    let y = size * (index == 1 ? 0.06 : 0.26) - pulse * size * 0.025
                    let r = size * (index == 1 ? 0.1 : 0.065)
                    var star = Path()
                    star.move(to: CGPoint(x: x, y: y - r))
                    star.addLines([CGPoint(x: x + r * 0.3, y: y - r * 0.25), CGPoint(x: x + r, y: y),
                                   CGPoint(x: x + r * 0.3, y: y + r * 0.25), CGPoint(x: x, y: y + r),
                                   CGPoint(x: x - r * 0.3, y: y + r * 0.25), CGPoint(x: x - r, y: y),
                                   CGPoint(x: x - r * 0.3, y: y - r * 0.25)])
                    star.closeSubpath()
                    context.fill(star, with: .color(accent.opacity(0.85)))
                    if index == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                stroke(line, opacity: 0.28, width: 0.65)
            case .cloudDrift:
                for index in 0..<2 {
                    let x = size * (index == 0 ? 0.15 : 0.83) + sin(t * .pi * 2) * size * 0.04
                    let y = size * (index == 0 ? 0.23 : 0.12) - pulse * size * 0.04
                    var cloud = Path()
                    cloud.addRoundedRect(in: CGRect(x: x - size * 0.12, y: y, width: size * 0.24, height: size * 0.08), cornerSize: CGSize(width: size * 0.04, height: size * 0.04))
                    cloud.addEllipse(in: CGRect(x: x - size * 0.065, y: y - size * 0.06, width: size * 0.12, height: size * 0.12))
                    context.fill(cloud, with: .color(accent.opacity(0.38)))
                }
            case .puddingBounce:
                for index in 0..<2 {
                    let expansion = pulse * size * 0.08 + Double(index) * size * 0.07
                    let rect = CGRect(x: size * 0.23 - expansion, y: size * 0.79 - expansion * 0.12,
                                      width: size * 0.54 + expansion * 2, height: size * 0.12 + expansion * 0.3)
                    stroke(Path(ellipseIn: rect), opacity: index == 0 ? 0.55 : 0.24, width: 0.9)
                }
            case .swordArc:
                let sweep = min(1, max(0, (t - 0.12) / 0.55))
                var arc = Path()
                arc.move(to: CGPoint(x: size * 0.08, y: size * 0.62))
                arc.addQuadCurve(to: CGPoint(x: size * 0.91, y: size * 0.12), control: CGPoint(x: size * 0.16, y: -size * 0.22))
                stroke(arc.trimmedPath(from: max(0, sweep - 0.5), to: max(0.01, sweep)), opacity: 0.9, width: size * 0.035)
                dot(size * 0.82, size * 0.10, radius: size * 0.035)
            case .softGlow:
                dot(size * 0.18, size * 0.22, radius: size * 0.035)
                dot(size * 0.82, size * 0.16, radius: size * 0.05, hollow: true)
            }
        }.frame(width: size, height: size).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A compact gauge uses one measured percentage for its ring, text and orbit.
/// Its reserved outer margin contains the sprite's motion and feeding biscuit.
struct QuotaDuoGeometry: Equatable {
    let side: CGFloat
    let ringDiameter: CGFloat
    let avatarSize: CGFloat
    let progress: Double
    let isKnown: Bool
    let markerX: CGFloat
    let markerY: CGFloat

    init(size: CGFloat, remainingPercent: Double?) {
        side = size.isFinite ? max(64, size) : 80
        ringDiameter = side * 0.60
        avatarSize = side * 0.275
        isKnown = remainingPercent.map { $0.isFinite && (0...100).contains($0) } ?? false
        progress = isKnown ? remainingPercent! : 0
        let angle = progress / 100 * .pi * 2 - .pi / 2
        markerX = side / 2 + (isKnown ? ringDiameter / 2 * cos(angle) : 0)
        markerY = side / 2 + (isKnown ? ringDiameter / 2 * sin(angle) : 0)
    }
}

struct QuotaDuoGauge: View {
    let document: QuotaStoreDocument
    let now: Date
    var reaction = false
    var resourceBundle: Bundle = .main
    var onPat: (() -> Void)? = nil
    var animateChanges = false
    var activity: BuddyActivity? = nil
    var activityPreviewElapsed: TimeInterval? = nil
    var onAction: ((BuddyAction) -> Void)? = nil
    var size: CGFloat = 80
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let value = QuotaPresentation(document: document, now: now)
        QuotaDuoGaugeContent(document: document, now: now, reaction: reaction,
                             resourceBundle: resourceBundle, onPat: onPat,
                             progress: value.remainingPercent ?? 0, isKnown: value.remainingPercent != nil,
                             activity: activity, activityPreviewElapsed: activityPreviewElapsed,
                             onAction: onAction, size: size)
            .animation(animateChanges && !reduceMotion && value.freshness == .fresh ? .easeInOut(duration: 0.8) : nil,
                       value: value.remainingPercent)
            .id("duo/\(value.provider.rawValue)/\(value.window?.id ?? "missing")/\(value.remainingPercent != nil)/\(value.freshness)")
    }
}

private struct QuotaDuoGaugeContent: View, Animatable {
    let document: QuotaStoreDocument
    let now: Date
    let reaction: Bool
    let resourceBundle: Bundle
    let onPat: (() -> Void)?
    var progress: Double
    let isKnown: Bool
    let activity: BuddyActivity?
    let activityPreviewElapsed: TimeInterval?
    let onAction: ((BuddyAction) -> Void)?
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    private var presentation: QuotaPresentation { QuotaPresentation(document: document, now: now) }
    private var layout: QuotaDuoGeometry {
        QuotaDuoGeometry(size: size, remainingPercent: isKnown ? min(100, max(0, progress)) : nil)
    }
    private var accent: Color { QuotaPalette.accent(for: document.preferences.character) }
    private var frame: Int {
        if reaction { return 4 }
        guard layout.isKnown else { return 0 }
        let used = 100 - layout.progress
        return used >= 90 ? 3 : used >= 60 ? 2 : used >= 25 ? 1 : 0
    }
    private var readingLabel: String {
        guard layout.isKnown else { return "待确认" }
        switch presentation.freshness {
        case .stale, .resetDue: return "上次"
        case .fresh: return "剩余"
        case .missing: return "待确认"
        }
    }
    private var status: String {
        switch presentation.freshness {
        case .stale: return "上次记录，已陈旧"
        case .resetDue: return "上次记录，重置待核对"
        case .missing: return "等待读取额度"
        case .fresh:
            if layout.isKnown { return "已读取" }
            return presentation.provider == .codex ? "Codex 未提供百分比" : "官网未提供百分比"
        }
    }
    private var renderer: QuotaRail {
        QuotaRail(remainingPercent: layout.isKnown ? layout.progress : nil,
                  character: document.preferences.character, frame: frame, accent: accent,
                  size: layout.avatarSize, resourceBundle: resourceBundle, onPat: onPat,
                  activity: activity, activityPreviewElapsed: activityPreviewElapsed, onAction: onAction)
    }

    var body: some View {
        ZStack {
            Path { path in
                let radius = layout.ringDiameter / 2
                for tick in 0..<12 {
                    let angle = Double(tick) / 12 * .pi * 2 - .pi / 2
                    let inner = radius + 4.5
                    let outer = inner + (tick % 3 == 0 ? 3 : 1.5)
                    path.move(to: CGPoint(x: layout.side / 2 + inner * cos(angle),
                                          y: layout.side / 2 + inner * sin(angle)))
                    path.addLine(to: CGPoint(x: layout.side / 2 + outer * cos(angle),
                                             y: layout.side / 2 + outer * sin(angle)))
                }
            }.stroke(accent.opacity(layout.isKnown ? 0.30 : 0.16),
                     style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .accessibilityHidden(true).allowsHitTesting(false)
            Circle().stroke(QuotaPalette.track, lineWidth: 5)
                .frame(width: layout.ringDiameter, height: layout.ringDiameter)
                .accessibilityHidden(true)
            if layout.isKnown {
                Circle().trim(from: 0, to: layout.progress / 100)
                    .stroke(accent.opacity(presentation.freshness == .fresh ? 0.90 : 0.48),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: layout.ringDiameter, height: layout.ringDiameter)
                    .accessibilityHidden(true)
                Circle().trim(from: 0, to: layout.progress / 100)
                    .stroke(QuotaPalette.surface.opacity(colorScheme == .dark ? 0.18 : 0.46),
                            style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: layout.ringDiameter - 2, height: layout.ringDiameter - 2)
                    .accessibilityHidden(true).allowsHitTesting(false)
                VStack(spacing: 0) {
                    Text(String(format: "%.0f%%", layout.progress))
                        .font(.system(size: layout.side * 0.20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel(YuliangL10n.format("剩余百分之{0}", String(Int(layout.progress.rounded()))))
                    Text(YuliangL10n.text(readingLabel)).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }.foregroundStyle(QuotaPalette.ink)
                animatedBuddy.position(x: layout.markerX, y: layout.markerY)
            } else {
                VStack(spacing: 0) {
                    animatedBuddy
                    Text("—").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .accessibilityLabel(YuliangL10n.text("剩余额度未知"))
                }
            }
        }
        .frame(width: layout.side, height: layout.side)
        .help("\(YuliangL10n.text(presentation.window?.label ?? "订阅额度")) · \(YuliangL10n.text(status))")
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var animatedBuddy: some View {
        if let activity {
            if let elapsed = activityPreviewElapsed {
                renderer.activeBuddy(activity, elapsed: elapsed, size: layout.avatarSize)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    renderer.activeBuddy(activity,
                                         elapsed: max(0, context.date.timeIntervalSince(activity.startedAt)),
                                         size: layout.avatarSize)
                }.frame(width: layout.avatarSize, height: layout.avatarSize)
            }
        } else {
            renderer.buddy(size: layout.avatarSize)
        }
    }
}

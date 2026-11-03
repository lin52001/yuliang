import SwiftUI
import QuotaCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum QuotaPalette {
    static let ink = Color(red: 0.18, green: 0.16, blue: 0.22)
    static let purple = Color(red: 0.42, green: 0.31, blue: 0.56)
    static let pink = Color(red: 0.74, green: 0.31, blue: 0.46)
    static let track = Color(red: 0.95, green: 0.94, blue: 0.97)
    static func accent(for character: QuotaCharacter) -> Color {
        guard let value = UInt64(String(character.accentHex.dropFirst()), radix: 16) else { return purple }
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

enum BuddyActivitySource: Equatable { case usage, play }

/// Shared by both surfaces. Opening a second view does not restart the event.
struct BuddyActivity: Equatable {
    let id = UUID()
    let action: BuddyAction
    let startedAt: Date
    let source: BuddyActivitySource
    var consumedPercent: Double? = nil
    var duration: TimeInterval { action == .eating ? 3.0 : 2.4 }
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
    private var atlas: (image: Image, row: Int, rowCount: Int)? {
        if let row = character.illustrationRow,
           let image = BuddyArtworkCache.load("original-buddies-v1", from: resourceBundle) {
            return (image, row, 4)
        }
        if character == .kuromi || character == .myMelody,
           let image = BuddyArtworkCache.load("anime-satiety-atlas-v1", from: resourceBundle) {
            return (image, character == .kuromi ? 0 : 1, 2)
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
            } else {
                OriginalBuddy(character: character, frame: frame, size: size)
            }
        }
        .accessibilityHidden(true)
        .transaction { $0.animation = nil }
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

    init(character: QuotaCharacter, illustrated: Bool) {
        switch character {
        case .dragonGirl:
            waveAngle = 7; napAngle = 4; cheerLift = 4.5; mouthY = illustrated ? -0.08 : 0.05
        case .claudeGirl:
            waveAngle = 4; napAngle = 3; patScale = 0.035; cheerLift = 2.5; mouthY = illustrated ? -0.08 : 0.05
        case .deepseekGirl:
            waveAngle = 6; napAngle = 4; cheerLift = 3.5; mouthY = illustrated ? -0.07 : 0.05
        case .geminiGirl:
            waveAngle = 10; napAngle = 5; patScale = 0.055; cheerLift = 5; mouthY = illustrated ? -0.08 : 0.05
        case .cloudSprite:
            waveAngle = 6; napAngle = 4; cheerLift = 3; mouthY = 0.05
        case .mochiCat:
            waveAngle = 9; napAngle = 7; patScale = 0.06; cheerLift = 4
        case .butterBunny:
            waveAngle = 7; napAngle = 5; patScale = 0.055; cheerLift = 5
        case .mintFox:
            waveAngle = 11; napAngle = 6; cheerLift = 4.5
        case .sesameBear:
            waveAngle = 5; napAngle = 4; patScale = 0.035; cheerLift = 2.5; chewLift = 0.5
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let value = QuotaPresentation(document: document, now: now)
        QuotaCardContent(document: document, now: now, compact: compact, reaction: reaction,
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
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: compact ? 4 : 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerName).font(.system(size: compact ? 12 : 13, weight: .semibold))
                    Text(subtitle).font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Circle().fill(presentation.freshness == .fresh ? Color.green : Color.secondary).frame(width: 4, height: 4)
                Spacer(minLength: 0)
                if compact {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(remaining == nil ? "待确认" : "余")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        readout.font(.system(size: 22, weight: .semibold, design: .rounded))
                    }.fixedSize(horizontal: true, vertical: false)
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(readingLabel).font(.system(size: 9)).foregroundStyle(.secondary)
                        readout.font(.system(size: 30, weight: .semibold, design: .rounded))
                    }
                }
            }
            QuotaRail(remainingPercent: remaining, character: document.preferences.character, frame: frame,
                      accent: accent, size: compact ? 48 : 56, resourceBundle: resourceBundle,
                      onPat: onPat, widgetInteraction: widgetInteraction, activity: activity, activityPreviewElapsed: activityPreviewElapsed,
                      onAction: onAction)
                .frame(height: compact ? 48 : 56)
            if !compact { Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1) }
            HStack(alignment: .firstTextBaseline) {
                Text(used.map { "已用 \(String(format: "%.0f", $0))%" } ?? "已用量未知")
                Spacer(minLength: 3)
                if let date = presentation.observedAt {
                    Group {
                        if compact && presentation.provider == .codex {
                            Text("读于 \(date.formatted(date: .omitted, time: .standard))")
                        }
                        else if compact { Text("读于 \(date, style: .time)") }
                        else { Text("读取 \(date, style: .relative)前") }
                    }.monospacedDigit().accessibilityLabel("最后读取 \(date.formatted())")
                } else { Text("未读取") }
            }.font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary).lineLimit(1)
            if !compact {
                HStack {
                    Text(status)
                    Spacer(minLength: 3)
                    if let reset = presentation.resetAt, reset > now {
                        Text("重置 \(reset, style: .time)")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.foregroundStyle(QuotaPalette.ink)
    }
    var readout: some View {
        Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
            .monospacedDigit()
            .accessibilityLabel(remaining.map { "剩余百分之\(Int($0.rounded()))" } ?? "剩余额度未知")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(remainingPercent: Double?, character: QuotaCharacter, frame: Int, accent: Color,
         size: CGFloat, resourceBundle: Bundle = .main, onPat: (() -> Void)? = nil,
         widgetInteraction: Bool = false, activity: BuddyActivity? = nil, activityPreviewElapsed: TimeInterval? = nil,
         onAction: ((BuddyAction) -> Void)? = nil) {
        let valid = remainingPercent.map { $0.isFinite && (0...100).contains($0) } ?? false
        self.progress = valid ? remainingPercent! : 0
        self.isKnown = valid
        self.character = character; self.frame = frame; self.accent = accent
        self.size = size; self.resourceBundle = resourceBundle
        self.onPat = onPat; self.widgetInteraction = widgetInteraction
        self.activity = activity; self.activityPreviewElapsed = activityPreviewElapsed; self.onAction = onAction
    }
    private var motion: BuddyMotionProfile {
        BuddyMotionProfile(character: character, illustrated: character.illustrationRow != nil
            && resourceBundle.url(forResource: "original-buddies-v1", withExtension: "png") != nil)
    }
    var body: some View {
        GeometryReader { geometry in
            let layout = QuotaRailGeometry(width: geometry.size.width, avatarSize: size, remainingPercent: isKnown ? progress : nil)
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.065))
                // Crop a full-size capsule. A narrow capsule becomes a
                // vertical pill at low percentages, which misrepresents the track.
                Capsule().fill(accent.opacity(0.13))
                    .mask(alignment: .leading) { Rectangle().frame(width: layout.fillWidth) }
                if layout.isKnown {
                    HStack(spacing: 0) {
                        ForEach(0..<8) { index in
                            Image(systemName: index % 2 == 0 ? "sparkle" : "heart.fill")
                                .font(.system(size: 9)).frame(maxWidth: .infinity)
                        }
                    }
                    .foregroundStyle(accent.opacity(0.55))
                    .mask(alignment: .leading) { Rectangle().frame(width: layout.foodClipWidth) }
                }
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
            }
        }
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder func activeBuddy(_ activity: BuddyActivity, elapsed: TimeInterval, size: Double) -> some View {
        let active = elapsed < activity.duration
        let t = min(1, max(0, elapsed / activity.duration))
        let wave = sin(t * .pi * 6)
        let eating = active && activity.action == .eating
        let animatedFrame: Int = !active ? frame : eating ? 5 : activity.action == .nap ? 3 : 4
        let angle: Double = !active || reduceMotion ? 0 : activity.action == .wave ? wave * motion.waveAngle : activity.action == .nap ? -motion.napAngle * sin(t * .pi) : 0
        let lift: Double = !active || reduceMotion ? 0 : activity.action == .celebrate ? -abs(wave) * motion.cheerLift : eating ? -abs(wave) * motion.chewLift : 0
        let scale: Double = !active || reduceMotion ? 1 : activity.action == .pat ? 1 + motion.patScale * sin(t * .pi) : 1
        ZStack {
            buddy(size: size, spriteFrame: animatedFrame)
                .rotationEffect(.degrees(angle)).scaleEffect(scale).offset(y: lift)
            if active {
                if eating {
                    feedingBiscuit(elapsed: elapsed, duration: activity.duration, size: size)
                } else {
                    Image(systemName: activity.action == .nap ? "zzz" : activity.action == .pat ? "heart.fill" : activity.action == .wave ? "sparkle" : "star.fill")
                        .font(.system(size: size * 0.21, weight: .semibold)).foregroundStyle(accent)
                        .offset(x: size * 0.32, y: -size * 0.34 + (reduceMotion ? 0 : -3 * sin(t * .pi)))
                        .opacity(reduceMotion ? 1 : sin(min(1, t * 3) * .pi / 2) * min(1, (1 - t) * 5))
                        .allowsHitTesting(false)
                }
            }
        }.frame(width: size, height: size)
    }
    func feedingBiscuit(elapsed: TimeInterval, duration: TimeInterval, size: Double) -> some View {
        let t = min(1, max(0, elapsed / duration))
        let approach = min(1, t / 0.3)
        let chewing = max(0, min(1, (t - 0.48) / 0.42))
        // The bite notch, rather than the cookie's center, meets the mouth.
        let targetX = (motion.mouthX - 0.10) * size
        let targetY = (motion.mouthY + 0.09) * size
        return ZStack {
            CookieBiscuit(bitten: reduceMotion || t > 0.32)
                .frame(width: size * 0.30, height: size * 0.30)
                .scaleEffect(reduceMotion ? 1 : 1 - chewing * 0.65)
                .offset(x: reduceMotion ? targetX : targetX - size * 0.60 * (1 - approach),
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
    func buddy(size: Double, spriteFrame: Int? = nil) -> some View {
        interactiveBuddy(size: size, spriteFrame: spriteFrame)
            .contextMenu {
                if let onAction {
                    Button("摸摸头", systemImage: "hand.raised.fill") { onAction(.pat) }
                    Button("招招手", systemImage: "hand.wave.fill") { onAction(.wave) }
                    Button("小睡一下", systemImage: "moon.zzz.fill") { onAction(.nap) }
                    Button("给点鼓励", systemImage: "sparkles") { onAction(.celebrate) }
                    Divider()
                    Button("喂一口饼干", systemImage: "fork.knife") { onAction(.eating) }
                }
            }
            .accessibilityHint(onAction == nil ? "点按回应" : "点按随机回应，菜单可选择摸头、招手、小睡、鼓励或喂食")
    }
    @ViewBuilder private func interactiveBuddy(size: Double, spriteFrame: Int?) -> some View {
        if widgetInteraction {
            #if YULIANG_STANDALONE
            BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            #else
            Button(intent: PatQuotaBuddyIntent()) {
                BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            }.buttonStyle(.plain).accessibilityLabel("摸摸\(character.name)")
            #endif
        } else if let onPat {
            Button(action: onPat) {
                BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            }.buttonStyle(.plain).accessibilityLabel("和\(character.name)互动")
        } else if let onAction {
            Button { onAction(.pat) } label: {
                BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
            }.buttonStyle(.plain).accessibilityLabel("摸摸\(character.name)")
        } else {
            BuddySprite(character: character, frame: spriteFrame ?? frame, size: size, resourceBundle: resourceBundle)
        }
    }
}

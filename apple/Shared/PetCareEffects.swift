import SwiftUI
import QuotaCore

/// The collection and the widget use the same sprite, props and evolution accessories.
struct PetBuddyPreview: View {
    let character: QuotaCharacter
    let skin: PetEvolutionSkin
    var activity: BuddyActivity? = nil
    var size: CGFloat = 100
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var renderer: QuotaRail {
        QuotaRail(remainingPercent: nil, character: character, frame: 0,
                  accent: QuotaPalette.accent(for: character), size: size, petSkin: skin)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: activity == nil || reduceMotion)) { timeline in
            if let activity {
                renderer.activeBuddy(activity, elapsed: reduceMotion ? activity.duration * 0.5 : timeline.date.timeIntervalSince(activity.startedAt), size: size)
            } else {
                renderer.buddy(size: size)
            }
        }.frame(width: size, height: size)
    }
}

/// Props share the activity clock with the avatar. They never move the quota marker.
struct PetCarePropEffect: View {
    let action: PetCareAction
    let progress: Double
    let size: Double
    let accent: Color
    let reduceMotion: Bool

    private var t: Double { reduceMotion ? 0.52 : min(1, max(0, progress)) }
    private var envelope: Double { reduceMotion ? 1 : min(1, t * 7) * min(1, (1 - t) * 6) }
    private var lift: Double { sin(t * .pi) }

    var body: some View {
        ZStack { prop }
            .frame(width: size, height: size)
            .opacity(envelope)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // Keep each effect in a separate view expression so the supported Swift
    // toolchains do not infer all seven animated prop trees at once.
    @ViewBuilder private var prop: some View {
        switch action {
        case .fruit: fruitEffect
        case .milk: milkEffect
        case .playBall: playBallEffect
        case .groom: groomEffect
        case .highFive: highFiveEffect
        case .rest: restEffect
        case .explore: exploreEffect
        }
    }

    @ViewBuilder private var fruitEffect: some View {
        PetFruit(bitten: t > 0.47)
            .frame(width: size * 0.29, height: size * 0.31)
            .rotationEffect(.degrees(-18 + 20 * lift))
            .scaleEffect(reduceMotion ? 1 : 1 - max(0, t - 0.65) * 1.5)
            .offset(x: -size * (0.37 - min(1, t / 0.35) * 0.31), y: size * 0.05 - lift * size * 0.06)
        sparkleTrail(symbol: "leaf.fill", tint: .green, count: 2)
    }

    @ViewBuilder private var milkEffect: some View {
        milkBottle
            .rotationEffect(.degrees(reduceMotion ? -15 : -30 * lift))
            .offset(x: size * (0.32 - 0.2 * lift), y: size * (0.18 - 0.23 * lift))
        if t > 0.35 {
            Image(systemName: "drop.fill")
                .font(.system(size: size * 0.08))
                .foregroundStyle(Color.white)
                .offset(x: size * 0.02, y: -size * 0.02)
        }
    }

    @ViewBuilder private var playBallEffect: some View {
        ZStack {
            Circle().fill(accent.opacity(0.9))
            Circle().trim(from: 0.15, to: 0.65).stroke(Color.white.opacity(0.9), lineWidth: max(1, size * 0.025))
                .padding(size * 0.04)
            Circle().fill(Color.white.opacity(0.85)).frame(width: size * 0.05, height: size * 0.05)
                .offset(x: size * 0.055, y: -size * 0.035)
        }
        .frame(width: size * 0.25, height: size * 0.25)
        .rotationEffect(.degrees(reduceMotion ? 0 : t * 540))
        .offset(x: reduceMotion ? size * 0.3 : cos(t * .pi * 2) * size * 0.4,
                y: size * 0.31 - (reduceMotion ? 0 : abs(sin(t * .pi * 3)) * size * 0.22))
    }

    @ViewBuilder private var groomEffect: some View {
        Image(systemName: "comb.fill")
            .font(.system(size: size * 0.32, weight: .medium))
            .rotationEffect(.degrees(-35 + (reduceMotion ? 0 : sin(t * .pi * 6) * 12)))
            .foregroundStyle(accent)
            .offset(x: size * 0.2, y: -size * 0.22 + (reduceMotion ? 0 : sin(t * .pi * 6) * size * 0.06))
        sparkleTrail(symbol: "sparkle", tint: accent, count: 3)
    }

    @ViewBuilder private var highFiveEffect: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: size * 0.32, weight: .medium))
            .foregroundStyle(Color(red: 0.98, green: 0.77, blue: 0.57))
            .rotationEffect(.degrees(-22 + 22 * lift))
            .offset(x: size * (0.4 - 0.12 * lift), y: -size * 0.17)
        Canvas { context, _ in
            guard t > 0.30, t < 0.85 else { return }
            let burst = reduceMotion ? 0.5 : (t - 0.30) / 0.55
            for index in 0..<3 {
                let angle = Double(index) * 0.65 - 1.2
                let radius: Double = size * (0.08 + burst * 0.12)
                let start = CGPoint(x: size * 0.78 + cos(angle) * radius,
                                    y: size * 0.27 + sin(angle) * radius)
                var ray = Path()
                ray.move(to: start)
                let end = CGPoint(x: start.x + CGFloat(cos(angle) * size * 0.09),
                                  y: start.y + CGFloat(sin(angle) * size * 0.09))
                ray.addLine(to: end)
                context.stroke(ray, with: .color(accent.opacity(1 - burst)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }.frame(width: size, height: size)
    }

    @ViewBuilder private var restEffect: some View {
        Image(systemName: "moon.zzz.fill")
            .font(.system(size: size * 0.26, weight: .medium))
            .foregroundStyle(accent.opacity(0.8))
            .offset(x: size * 0.3, y: -size * 0.3 - (reduceMotion ? 0 : lift * size * 0.08))
        RoundedRectangle(cornerRadius: size * 0.05)
            .fill(accent.opacity(0.20))
            .frame(width: size * 0.63, height: size * 0.12)
            .offset(y: size * 0.41)
    }

    @ViewBuilder private var exploreEffect: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: size * 0.32, weight: .semibold))
            .foregroundStyle(accent)
            .rotationEffect(.degrees(-25 + (reduceMotion ? 0 : sin(t * .pi * 2) * 18)))
            .offset(x: size * 0.3, y: -size * 0.01)
        sparkleTrail(symbol: "sparkle", tint: accent, count: 2)
    }

    private var milkBottle: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: size * 0.025).fill(accent).frame(width: size * 0.16, height: size * 0.055)
            RoundedRectangle(cornerRadius: size * 0.055)
                .fill(Color.white)
                .overlay { RoundedRectangle(cornerRadius: size * 0.055).stroke(accent.opacity(0.8), lineWidth: 1) }
                .overlay { Image(systemName: "heart.fill").font(.system(size: size * 0.085)).foregroundStyle(accent) }
                .frame(width: size * 0.20, height: size * 0.26)
        }
    }

    private func sparkleTrail(symbol: String, tint: Color, count: Int) -> some View {
        ForEach(0..<count, id: \.self) { index in
            let fraction = Double(index) / Double(max(1, count - 1))
            Image(systemName: symbol)
                .font(.system(size: size * (index == 1 ? 0.11 : 0.075), weight: .medium))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(Double(index - 1) * 25))
                .offset(x: (fraction - 0.5) * size * 0.65,
                        y: -size * 0.33 - (reduceMotion ? 0 : lift * size * (0.04 + fraction * 0.08)))
        }
    }
}

private struct PetFruit: View {
    let bitten: Bool
    var body: some View {
        GeometryReader { geometry in
            let s = geometry.size.width
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: s * 0.5, y: s * 0.2))
                    path.addCurve(to: CGPoint(x: s * 0.5, y: s * 0.96), control1: CGPoint(x: -s * 0.08, y: -s * 0.01), control2: CGPoint(x: -s * 0.06, y: s * 0.84))
                    path.addCurve(to: CGPoint(x: s * 0.5, y: s * 0.2), control1: CGPoint(x: s * 1.04, y: s * 0.86), control2: CGPoint(x: s * 1.06, y: -s * 0.02))
                }.fill(Color(red: 0.93, green: 0.38, blue: 0.37))
                Ellipse().fill(Color(red: 0.32, green: 0.60, blue: 0.37)).frame(width: s * 0.3, height: s * 0.14)
                    .rotationEffect(.degrees(-30)).offset(x: s * 0.11, y: -s * 0.43)
                if bitten {
                    Circle().blendMode(.destinationOut).frame(width: s * 0.42, height: s * 0.42).offset(x: s * 0.38, y: -s * 0.1)
                }
            }.compositingGroup()
        }
    }
}

/// Quiet, static accessories make evolution visible without another perpetual animation.
struct PetEvolutionAdornment: View {
    let skin: PetEvolutionSkin
    let accent: Color
    let size: Double

    var body: some View {
        ZStack {
            if skin != .natural {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.12, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
                    .offset(x: -size * 0.36, y: -size * 0.22)
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.11))
                    .foregroundStyle(Color(red: 0.99, green: 0.78, blue: 0.34))
                    .background(Circle().fill(accent.opacity(0.85)).frame(width: size * 0.16, height: size * 0.16))
                    .offset(x: size * 0.07, y: size * 0.23)
            }
            if skin == .aurora {
                Image(systemName: "crown.fill")
                    .font(.system(size: size * 0.24, weight: .medium))
                    .foregroundStyle(Color(red: 0.99, green: 0.77, blue: 0.37))
                    .rotationEffect(.degrees(-10))
                    .offset(x: size * 0.03, y: -size * 0.41)
                ForEach(0..<2) { index in
                    Image(systemName: "sparkle")
                        .font(.system(size: size * (index == 0 ? 0.09 : 0.13)))
                        .foregroundStyle(accent.opacity(0.75))
                        .offset(x: size * (index == 0 ? 0.35 : 0.39), y: size * (index == 0 ? 0.11 : -0.19))
                }
            }
        }.frame(width: size, height: size)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

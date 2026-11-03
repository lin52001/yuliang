// Copyright (c) 2026 Yuliang contributors. MIT licensed.
// Vector fallback drawings for the app's newly drawn character themes.
// No third-party artwork files are copied into this source.
import SwiftUI
import QuotaCore

/// A compact, transparent 2D companion drawn on one shared 100 × 100 grid.
/// Frames 0...3 show satiety, 4 is a happy pat, and 5 is a chewing reaction.
struct OriginalBuddy: View {
    let character: QuotaCharacter
    let frame: Int
    var size: CGFloat = 56

    var body: some View {
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 100, y: canvasSize.height / 100)
            draw(in: &context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var kind: QuotaCharacter { character.isOriginal ? character : .dragonGirl }
    private var ink: Color { Color(red: 0.26, green: 0.22, blue: 0.29) }
    private var coat: Color {
        switch kind {
        case .mochiCat: Color(red: 0.91, green: 0.89, blue: 0.96)
        case .butterBunny: Color(red: 1.0, green: 0.95, blue: 0.81)
        case .mintFox: Color(red: 0.66, green: 0.86, blue: 0.79)
        case .sesameBear: Color(red: 0.80, green: 0.66, blue: 0.55)
        default: .white
        }
    }
    private var inset: Color {
        kind == .mintFox ? Color(red: 0.90, green: 0.98, blue: 0.93) : Color(red: 1, green: 0.97, blue: 0.94)
    }
    private var earPink: Color { Color(red: 0.92, green: 0.69, blue: 0.73) }
    private var full: CGFloat { frame <= 3 ? CGFloat(max(0, frame)) / 3 : 0.45 }

    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h))
    }
    private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }
    private func filled(_ path: Path, _ color: Color, in context: inout GraphicsContext, outlined: Bool = true, width: CGFloat = 2.4) {
        context.fill(path, with: .color(color))
        if outlined { context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)) }
    }
    private func line(_ path: Path, in context: inout GraphicsContext, color: Color? = nil, width: CGFloat = 2.5) {
        context.stroke(path, with: .color(color ?? ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    private func draw(in context: inout GraphicsContext) {
        if [.dragonGirl, .claudeGirl, .deepseekGirl, .geminiGirl, .cloudSprite].contains(kind) {
            drawGirl(in: &context)
            return
        }
        let bellyWidth: CGFloat = 35 + full * 15
        let bodyY: CGFloat = 59 - full * 2
        // Distinct tails sit behind the body rather than floating outside the sprite.
        if kind == .mintFox {
            var tail = Path()
            tail.move(to: CGPoint(x: 64, y: 82))
            tail.addCurve(to: CGPoint(x: 86, y: 48), control1: CGPoint(x: 91, y: 87), control2: CGPoint(x: 94, y: 66))
            tail.addCurve(to: CGPoint(x: 63, y: 71), control1: CGPoint(x: 74, y: 49), control2: CGPoint(x: 67, y: 57))
            tail.closeSubpath()
            filled(tail, coat, in: &context)
            var tip = Path()
            tip.move(to: CGPoint(x: 86, y: 48))
            tip.addQuadCurve(to: CGPoint(x: 90, y: 64), control: CGPoint(x: 91, y: 54))
            tip.addLine(to: CGPoint(x: 80, y: 61))
            tip.addLine(to: CGPoint(x: 77, y: 54))
            tip.closeSubpath()
            filled(tip, inset, in: &context, outlined: false)
        } else if kind == .mochiCat {
            var tail = Path()
            tail.move(to: CGPoint(x: 65, y: 80))
            tail.addCurve(to: CGPoint(x: 82, y: 65), control1: CGPoint(x: 86, y: 88), control2: CGPoint(x: 88, y: 64))
            line(tail, in: &context, width: 7)
            line(tail, in: &context, color: coat, width: 3.8)
        } else if kind == .butterBunny {
            filled(ellipse(70, 71, 13, 14), inset, in: &context, width: 2)
        }
        filled(ellipse(50 - bellyWidth / 2, bodyY, bellyWidth, 31 + full * 4), coat, in: &context)
        filled(ellipse(39 - full * 4, 68, 22 + full * 8, 19 + full * 3), inset, in: &context, outlined: false)
        // Two little feet keep every companion grounded on the quota rail.
        filled(ellipse(31 - full * 2, 85, 17, 9), coat, in: &context, width: 2)
        filled(ellipse(52 + full * 2, 85, 17, 9), coat, in: &context, width: 2)

        switch kind {
        case .mochiCat:
            var left = Path()
            left.move(to: CGPoint(x: 24, y: 32)); left.addLine(to: CGPoint(x: 24, y: 12)); left.addQuadCurve(to: CGPoint(x: 41, y: 26), control: CGPoint(x: 34, y: 12)); left.closeSubpath()
            filled(left, coat, in: &context)
            var right = Path()
            right.move(to: CGPoint(x: 60, y: 25)); right.addQuadCurve(to: CGPoint(x: 77, y: 12), control: CGPoint(x: 66, y: 12)); right.addLine(to: CGPoint(x: 76, y: 33)); right.closeSubpath()
            filled(right, coat, in: &context)
            filled(ellipse(28, 20, 7, 10), Color(red: 0.70, green: 0.64, blue: 0.82), in: &context, outlined: false)
            filled(ellipse(65, 20, 7, 10), earPink.opacity(0.8), in: &context, outlined: false)
        case .butterBunny:
            filled(rounded(29, 7, 14, 29, 7), coat, in: &context)
            filled(rounded(56, 9, 14, 27, 7), coat, in: &context)
            filled(rounded(33, 12, 6, 18, 3), earPink.opacity(0.85), in: &context, outlined: false)
            filled(rounded(60, 14, 6, 16, 3), earPink.opacity(0.85), in: &context, outlined: false)
        case .mintFox:
            for right in [false, true] {
                let x: CGFloat = right ? 61 : 23
                var ear = Path()
                ear.move(to: CGPoint(x: x, y: 32)); ear.addLine(to: CGPoint(x: x + (right ? 14 : 1), y: 8)); ear.addLine(to: CGPoint(x: x + 17, y: 31)); ear.closeSubpath()
                filled(ear, coat, in: &context)
                var center = Path()
                center.move(to: CGPoint(x: x + 5, y: 27)); center.addLine(to: CGPoint(x: x + (right ? 12 : 4), y: 16)); center.addLine(to: CGPoint(x: x + 13, y: 28)); center.closeSubpath()
                filled(center, inset, in: &context, outlined: false)
            }
        case .sesameBear:
            filled(ellipse(18, 19, 21, 22), coat, in: &context)
            filled(ellipse(61, 19, 21, 22), coat, in: &context)
            filled(ellipse(23, 24, 11, 12), Color(red: 0.64, green: 0.49, blue: 0.40), in: &context, outlined: false)
            filled(ellipse(66, 24, 11, 12), Color(red: 0.64, green: 0.49, blue: 0.40), in: &context, outlined: false)
        default: break
        }
        filled(ellipse(21, 25, 58, 48), coat, in: &context)
        if kind == .mintFox {
            var mask = Path()
            mask.move(to: CGPoint(x: 24, y: 43)); mask.addQuadCurve(to: CGPoint(x: 50, y: 51), control: CGPoint(x: 35, y: 40)); mask.addQuadCurve(to: CGPoint(x: 76, y: 43), control: CGPoint(x: 65, y: 40)); mask.addQuadCurve(to: CGPoint(x: 50, y: 70), control: CGPoint(x: 73, y: 65)); mask.addQuadCurve(to: CGPoint(x: 24, y: 43), control: CGPoint(x: 26, y: 65)); mask.closeSubpath()
            filled(mask, inset, in: &context, outlined: false)
        } else if kind == .sesameBear {
            filled(ellipse(35, 48, 30, 21), inset, in: &context, outlined: false)
        } else if kind == .mochiCat {
            filled(ellipse(27, 29, 18, 19), .white.opacity(0.65), in: &context, outlined: false)
        }
        // Cheeks and brow spacing stay readable at the compact 40 pt size.
        filled(ellipse(27, 51, 11, frame == 5 ? 7 : 5), earPink.opacity(0.7), in: &context, outlined: false)
        filled(ellipse(62, 51, 11, frame == 5 ? 7 : 5), earPink.opacity(0.7), in: &context, outlined: false)
        let sleepy = frame == 3 || frame == 4
        if sleepy {
            for x in [CGFloat(37), CGFloat(59)] {
                var eye = Path(); eye.move(to: CGPoint(x: x, y: 47)); eye.addQuadCurve(to: CGPoint(x: x + 6, y: 47), control: CGPoint(x: x + 3, y: frame == 4 ? 43 : 50)); line(eye, in: &context)
            }
        } else {
            filled(ellipse(38, 44, 4, frame == 5 ? 5 : 6), ink, in: &context, outlined: false)
            filled(ellipse(59, 44, 4, frame == 5 ? 5 : 6), ink, in: &context, outlined: false)
        }
        if kind == .mintFox || kind == .sesameBear {
            filled(ellipse(47, 52, 6, 4), ink, in: &context, outlined: false)
        }
        if frame == 5 {
            filled(ellipse(46, 56, 8, 6), Color(red: 0.80, green: 0.43, blue: 0.47), in: &context, width: 1.6)
        } else {
            var mouth = Path()
            mouth.move(to: CGPoint(x: 45, y: 56)); mouth.addQuadCurve(to: CGPoint(x: 50, y: 59), control: CGPoint(x: 47, y: 60)); mouth.addQuadCurve(to: CGPoint(x: 55, y: 56), control: CGPoint(x: 53, y: 60)); line(mouth, in: &context, width: 1.8)
        }
        // Tiny whisker freckles distinguish the cat without crowded linework.
        if kind == .mochiCat {
            for x in [CGFloat(29), CGFloat(69)] {
                filled(ellipse(x, 49, 1.5, 1.5), ink.opacity(0.6), in: &context, outlined: false)
            }
        }
        // Paws hug the tummy when full, lift for a pat, and meet the cookie while chewing.
        let pawY: CGFloat = frame == 4 ? 61 : frame == 5 ? 66 : 72 + full * 2
        let pawX: CGFloat = frame == 5 ? 36 : 29 - full * 2
        filled(ellipse(pawX, pawY, 13, 10), coat, in: &context, width: 1.8)
        filled(ellipse(100 - pawX - 13, pawY, 13, 10), coat, in: &context, width: 1.8)
        if kind == .butterBunny {
            // One butter-yellow spot is part of this original rabbit's identity.
            filled(ellipse(46, 32, 7, 5), Color(red: 0.91, green: 0.73, blue: 0.32).opacity(0.55), in: &context, outlined: false)
        }
    }

    private func drawGirl(in context: inout GraphicsContext) {
        let dragon = kind == .dragonGirl
        let hair: Color
        let hairShade: Color
        let cloth: Color
        switch kind {
        case .dragonGirl:
            hair = Color(red: 0.70, green: 0.58, blue: 0.86)
            hairShade = Color(red: 0.53, green: 0.40, blue: 0.69)
            cloth = Color(red: 0.92, green: 0.86, blue: 0.98)
        case .claudeGirl:
            hair = Color(red: 0.94, green: 0.63, blue: 0.37)
            hairShade = Color(red: 0.70, green: 0.36, blue: 0.23)
            cloth = Color(red: 0.40, green: 0.31, blue: 0.29)
        case .deepseekGirl:
            hair = Color(red: 0.39, green: 0.66, blue: 0.91)
            hairShade = Color(red: 0.22, green: 0.42, blue: 0.68)
            cloth = Color(red: 0.88, green: 0.95, blue: 1.0)
        case .geminiGirl:
            hair = Color(red: 0.64, green: 0.64, blue: 0.91)
            hairShade = Color(red: 0.39, green: 0.39, blue: 0.69)
            cloth = Color(red: 0.92, green: 0.91, blue: 1.0)
        default:
            hair = Color(red: 0.62, green: 0.82, blue: 0.94)
            hairShade = Color(red: 0.36, green: 0.64, blue: 0.79)
            cloth = Color(red: 0.94, green: 0.98, blue: 1.0)
        }
        let skin = Color(red: 1.0, green: 0.91, blue: 0.85)
        let gold = Color(red: 0.94, green: 0.78, blue: 0.44)
        // Rear hair, dragon tail, and cape form one bounded silhouette.
        var rearHair = Path()
        rearHair.move(to: CGPoint(x: 21, y: 42))
        rearHair.addCurve(to: CGPoint(x: 24, y: 80), control1: CGPoint(x: 12, y: 61), control2: CGPoint(x: 17, y: 79))
        rearHair.addQuadCurve(to: CGPoint(x: 77, y: 80), control: CGPoint(x: 50, y: 69))
        rearHair.addCurve(to: CGPoint(x: 80, y: 39), control1: CGPoint(x: 85, y: 79), control2: CGPoint(x: 87, y: 57))
        rearHair.closeSubpath()
        filled(rearHair, hairShade, in: &context)
        if dragon {
            var tail = Path()
            tail.move(to: CGPoint(x: 68, y: 80)); tail.addCurve(to: CGPoint(x: 86, y: 72), control1: CGPoint(x: 82, y: 93), control2: CGPoint(x: 90, y: 84)); tail.addLine(to: CGPoint(x: 83, y: 65))
            line(tail, in: &context, width: 6)
            line(tail, in: &context, color: hair, width: 3)
            for right in [false, true] {
                let x: CGFloat = right ? 69 : 14
                var wing = Path()
                wing.move(to: CGPoint(x: x + (right ? 0 : 15), y: 65))
                wing.addLine(to: CGPoint(x: x + (right ? 16 : 0), y: 53))
                wing.addLine(to: CGPoint(x: x + (right ? 13 : 3), y: 69))
                wing.addQuadCurve(to: CGPoint(x: x + (right ? 2 : 13), y: 72), control: CGPoint(x: x + 8, y: 67))
                wing.closeSubpath()
                filled(wing, hair, in: &context, width: 2)
            }
        } else {
            var cape = Path()
            cape.move(to: CGPoint(x: 30, y: 60)); cape.addLine(to: CGPoint(x: 18, y: 77)); cape.addQuadCurve(to: CGPoint(x: 40, y: 80), control: CGPoint(x: 31, y: 85)); cape.addLine(to: CGPoint(x: 61, y: 80)); cape.addQuadCurve(to: CGPoint(x: 82, y: 77), control: CGPoint(x: 72, y: 85)); cape.addLine(to: CGPoint(x: 69, y: 60)); cape.closeSubpath()
            filled(cape, cloth, in: &context, width: 2)
        }
        let bodyWidth: CGFloat = 29 + full * 11
        filled(rounded(50 - bodyWidth / 2, 62, bodyWidth, 27 + full * 3, 11), cloth, in: &context, width: 2)
        if kind == .claudeGirl {
            filled(rounded(39, 62, 22, 13, 4), .white, in: &context, outlined: false)
            var collar = Path()
            collar.move(to: CGPoint(x: 41, y: 63)); collar.addLine(to: CGPoint(x: 47, y: 70)); collar.addLine(to: CGPoint(x: 50, y: 65)); collar.addLine(to: CGPoint(x: 53, y: 70)); collar.addLine(to: CGPoint(x: 59, y: 63))
            line(collar, in: &context, color: hairShade.opacity(0.55), width: 1.1)
        }
        filled(ellipse(34, 86, 13, 9), hairShade, in: &context, width: 2)
        filled(ellipse(53, 86, 13, 9), hairShade, in: &context, width: 2)
        filled(ellipse(22, 16, 56, 52), hair, in: &context)
        filled(ellipse(27, 25, 46, 39), skin, in: &context, width: 1.6)
        // A broad sweeping fringe with three clear locks gives the tiny face an anime shape.
        var fringe = Path()
        fringe.move(to: CGPoint(x: 24, y: 40))
        fringe.addCurve(to: CGPoint(x: 29, y: 22), control1: CGPoint(x: 22, y: 30), control2: CGPoint(x: 23, y: 23))
        fringe.addQuadCurve(to: CGPoint(x: 70, y: 23), control: CGPoint(x: 50, y: 6))
        fringe.addQuadCurve(to: CGPoint(x: 76, y: 42), control: CGPoint(x: 78, y: 28))
        fringe.addQuadCurve(to: CGPoint(x: 61, y: 30), control: CGPoint(x: 68, y: 40))
        fringe.addLine(to: CGPoint(x: 59, y: 37))
        fringe.addQuadCurve(to: CGPoint(x: 48, y: 29), control: CGPoint(x: 53, y: 36))
        fringe.addLine(to: CGPoint(x: 44, y: 37))
        fringe.addLine(to: CGPoint(x: 41, y: 29))
        fringe.addQuadCurve(to: CGPoint(x: 24, y: 40), control: CGPoint(x: 34, y: 36))
        fringe.closeSubpath()
        filled(fringe, hair, in: &context, width: 1.7)
        if dragon {
            for right in [false, true] {
                let x: CGFloat = right ? 64 : 25
                var horn = Path()
                horn.move(to: CGPoint(x: x, y: 21)); horn.addQuadCurve(to: CGPoint(x: x + 3, y: 6), control: CGPoint(x: x - 2, y: 13)); horn.addQuadCurve(to: CGPoint(x: x + 11, y: 23), control: CGPoint(x: x + 6, y: 16)); horn.closeSubpath()
                filled(horn, gold, in: &context, width: 1.8)
            }
        } else if kind == .claudeGirl {
            // A small generic five-petal flower, drawn from elementary circles.
            for index in 0..<5 {
                let angle = CGFloat(index) * .pi * 2 / 5
                filled(ellipse(70 + cos(angle) * 5 - 3, 23 + sin(angle) * 5 - 3, 6, 6), .white, in: &context, outlined: false)
            }
            filled(ellipse(68, 21, 4, 4), gold, in: &context, outlined: false)
        } else if kind == .deepseekGirl {
            var whaleTail = Path()
            whaleTail.move(to: CGPoint(x: 69, y: 22))
            whaleTail.addQuadCurve(to: CGPoint(x: 57, y: 10), control: CGPoint(x: 57, y: 19))
            whaleTail.addQuadCurve(to: CGPoint(x: 69, y: 14), control: CGPoint(x: 65, y: 8))
            whaleTail.addQuadCurve(to: CGPoint(x: 82, y: 10), control: CGPoint(x: 75, y: 7))
            whaleTail.addQuadCurve(to: CGPoint(x: 72, y: 23), control: CGPoint(x: 81, y: 18))
            whaleTail.closeSubpath()
            filled(whaleTail, hairShade, in: &context, width: 1.5)
            var seam = Path(); seam.move(to: CGPoint(x: 70, y: 15)); seam.addLine(to: CGPoint(x: 70, y: 21)); line(seam, in: &context, color: .white.opacity(0.75), width: 1)
        } else if kind == .geminiGirl {
            for right in [false, true] {
                let x: CGFloat = right ? 62 : 24
                var ear = Path()
                ear.move(to: CGPoint(x: x, y: 26)); ear.addLine(to: CGPoint(x: x + (right ? 14 : 0), y: 9)); ear.addLine(to: CGPoint(x: x + 15, y: 26)); ear.closeSubpath()
                filled(ear, hairShade, in: &context, width: 1.8)
                var inner = Path(); inner.move(to: CGPoint(x: x + 4, y: 23)); inner.addLine(to: CGPoint(x: x + (right ? 11 : 3), y: 16)); inner.addLine(to: CGPoint(x: x + 11, y: 23)); inner.closeSubpath(); filled(inner, earPink, in: &context, outlined: false)
            }
            var starClip = Path()
            for index in 0..<10 {
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let radius: CGFloat = index % 2 == 0 ? 5 : 2.2
                let point = CGPoint(x: 73 + cos(angle) * radius, y: 34 + sin(angle) * radius)
                if index == 0 { starClip.move(to: point) } else { starClip.addLine(to: point) }
            }
            starClip.closeSubpath()
            filled(starClip, gold, in: &context, width: 1)
        } else {
            // One original cloud ornament is readable against a white widget.
            var cloud = Path()
            cloud.move(to: CGPoint(x: 55, y: 22))
            cloud.addQuadCurve(to: CGPoint(x: 55, y: 14), control: CGPoint(x: 49, y: 18))
            cloud.addQuadCurve(to: CGPoint(x: 62, y: 12), control: CGPoint(x: 56, y: 9))
            cloud.addQuadCurve(to: CGPoint(x: 73, y: 12), control: CGPoint(x: 66, y: 3))
            cloud.addQuadCurve(to: CGPoint(x: 81, y: 15), control: CGPoint(x: 79, y: 10))
            cloud.addQuadCurve(to: CGPoint(x: 81, y: 22), control: CGPoint(x: 87, y: 19))
            cloud.closeSubpath()
            filled(cloud, .white, in: &context, width: 1.4)
        }
        // Big irises with a single white catchlight remain legible at 40 points.
        if frame == 3 || frame == 4 {
            for x in [CGFloat(35), CGFloat(57)] {
                var eye = Path(); eye.move(to: CGPoint(x: x, y: 44)); eye.addQuadCurve(to: CGPoint(x: x + 8, y: 44), control: CGPoint(x: x + 4, y: frame == 4 ? 39 : 48)); line(eye, in: &context, width: 2)
            }
        } else {
            for x in [CGFloat(35), CGFloat(57)] {
                filled(ellipse(x, 39, 8, 12), .white, in: &context, width: 1.3)
                filled(ellipse(x + 1, 42, 6, 8), hairShade, in: &context, outlined: false)
                filled(ellipse(x + 2, 43, 2, 3), .white, in: &context, outlined: false)
                var lash = Path(); lash.move(to: CGPoint(x: x - 1, y: 39)); lash.addLine(to: CGPoint(x: x + 8, y: 40)); line(lash, in: &context, width: 1.5)
            }
        }
        filled(ellipse(28, 49, 10, frame == 4 ? 6 : 4), earPink.opacity(0.85), in: &context, outlined: false)
        filled(ellipse(62, 49, 10, frame == 4 ? 6 : 4), earPink.opacity(0.85), in: &context, outlined: false)
        if frame == 5 {
            filled(ellipse(46, 52, 8, 6), Color(red: 0.85, green: 0.46, blue: 0.51), in: &context, width: 1.4)
        } else {
            var mouth = Path(); mouth.move(to: CGPoint(x: 46, y: 53)); mouth.addQuadCurve(to: CGPoint(x: 54, y: 53), control: CGPoint(x: 50, y: 58)); line(mouth, in: &context, width: 1.5)
        }
        // Arms move toward the snack for chewing, toward the face for a happy pat.
        let handY: CGFloat = frame == 4 ? 57 : frame == 5 ? 64 : 71
        let handX: CGFloat = frame == 5 ? 38 : 28
        filled(ellipse(handX, handY, 11, 10), skin, in: &context, width: 1.7)
        filled(ellipse(89 - handX, handY, 11, 10), skin, in: &context, width: 1.7)
        var star = Path()
        for index in 0..<10 {
            let angle = CGFloat(index) * .pi / 5 - .pi / 2
            let radius: CGFloat = index % 2 == 0 ? 4 : 1.8
            let point = CGPoint(x: 50 + cos(angle) * radius, y: 71 + sin(angle) * radius)
            if index == 0 { star.move(to: point) } else { star.addLine(to: point) }
        }
        star.closeSubpath()
        filled(star, gold, in: &context, outlined: false)
    }

}

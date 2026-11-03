import Testing
@testable import QuotaCore

struct QuotaRailGeometryTests {
    @Test func compactLowQuotaKeepsTheCharacterAtTheLowEndOfTheFill() {
        let rail = QuotaRailGeometry(width: 133, avatarSize: 45, remainingPercent: 8)
        #expect(rail.isKnown)
        #expect(rail.remainingFraction == 0.08)
        #expect(abs(rail.fillWidth - 10.64) < 0.000_001)
        #expect(rail.markerLeadingX == 0)
        #expect(rail.markerCenterX == 22.5)
        #expect(rail.markerCenterX < rail.width / 2, "低余量的人物不能反向跑到轨道右端")
        #expect(rail.foodClipWidth == rail.fillWidth)
    }

    @Test func interiorCharacterCenterMeetsTheVisibleQuotaBoundary() {
        let examples: [(Double, Double, Double, Double)] = [
            (133, 45, 35, 46.55),
            (133, 45, 65, 86.45),
            (274, 56, 35, 95.9),
            (274, 56, 65, 178.1),
        ]
        for (width, size, percentage, boundary) in examples {
            let rail = QuotaRailGeometry(width: width, avatarSize: size, remainingPercent: percentage)
            #expect(abs(rail.markerCenterX - boundary) < 0.000_001)
            #expect(abs(rail.fillWidth - boundary) < 0.000_001)
            #expect(abs(rail.markerLeadingX + rail.avatarSize / 2 - rail.fillWidth) < 0.000_001)
        }
    }

    @Test func exactEmptyAndFullFillRemainExactWhileCharacterStaysInside() {
        for (width, size): (Double, Double) in [(133, 45), (274, 56)] {
            let empty = QuotaRailGeometry(width: width, avatarSize: size, remainingPercent: 0)
            let full = QuotaRailGeometry(width: width, avatarSize: size, remainingPercent: 100)
            #expect(empty.isKnown && full.isKnown)
            #expect(empty.fillWidth == 0)
            #expect(empty.markerLeadingX == 0)
            #expect(full.fillWidth == width)
            #expect(full.markerLeadingX + full.avatarSize == width)
        }
    }

    @Test func quotaConsumptionMovesFillFoodAndCharacterInTheSameDirection() {
        for (width, size): (Double, Double) in [(133, 45), (274, 56)] {
            var previous = QuotaRailGeometry(width: width, avatarSize: size, remainingPercent: 100)
            for remaining in stride(from: 99.0, through: 0.0, by: -0.5) {
                let current = QuotaRailGeometry(width: width, avatarSize: size, remainingPercent: remaining)
                #expect(current.fillWidth < previous.fillWidth)
                #expect(current.foodClipWidth == current.fillWidth)
                #expect(current.markerCenterX <= previous.markerCenterX)
                #expect(current.markerLeadingX >= 0)
                #expect(current.markerLeadingX + current.avatarSize <= width + 0.000_001)
                previous = current
            }
        }
    }

    @Test func unknownAndInvalidPercentagesCannotCreateAFiftyPercentFill() {
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -1, 101]
        for percentage in invalid {
            let rail = QuotaRailGeometry(width: 133, avatarSize: 45, remainingPercent: percentage)
            #expect(!rail.isKnown)
            #expect(rail.remainingFraction == nil)
            #expect(rail.fillWidth == 0)
            #expect(rail.foodClipWidth == 0)
            #expect(rail.markerCenterX == 66.5, "居中仅为未知状态布局，不代表50%额度")
        }
    }

    @Test func tinyOrInvalidLayoutsNeverPlaceCharacterOutsideTheTrack() {
        for width: Double in [0, 1, 12, 44, -12, .nan, .infinity, -.infinity] {
            for remaining: Double? in [0, 8, 35, 65, 100, nil] {
                let rail = QuotaRailGeometry(width: width, avatarSize: 45, remainingPercent: remaining)
                #expect(rail.width.isFinite && rail.width >= 0)
                #expect(rail.avatarSize.isFinite && rail.avatarSize <= rail.width)
                #expect(rail.fillWidth.isFinite && rail.fillWidth >= 0 && rail.fillWidth <= rail.width)
                #expect(rail.markerLeadingX.isFinite && rail.markerLeadingX >= 0)
                #expect(rail.markerLeadingX + rail.avatarSize <= rail.width)
            }
        }
        for size: Double in [-1, .nan, .infinity, -.infinity] {
            let rail = QuotaRailGeometry(width: 133, avatarSize: size, remainingPercent: 35)
            #expect(rail.avatarSize == 0)
            #expect(rail.markerCenterX == rail.fillWidth)
        }
    }
}

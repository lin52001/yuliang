/// Shared rail geometry for every native card size.
/// The fill boundary and character use the same remaining-quota coordinate.
/// Only the character's center is clamped near the ends to keep its full body visible.
/// A missing or invalid percentage is not rendered as an invented midpoint quota.
public struct QuotaRailGeometry: Equatable, Sendable {
    public let width: Double
    public let avatarSize: Double
    public let remainingFraction: Double?
    public let fillWidth: Double
    public let markerCenterX: Double
    public let markerLeadingX: Double
    public let foodClipWidth: Double

    public var isKnown: Bool { remainingFraction != nil }

    public init(width: Double, avatarSize: Double, remainingPercent: Double?) {
        let safeWidth = width.isFinite ? max(0, width) : 0
        let safeAvatar = avatarSize.isFinite ? min(safeWidth, max(0, avatarSize)) : 0
        self.width = safeWidth
        self.avatarSize = safeAvatar

        if let remainingPercent, remainingPercent.isFinite, (0...100).contains(remainingPercent) {
            remainingFraction = remainingPercent / 100
        } else {
            remainingFraction = nil
        }

        fillWidth = safeWidth * (remainingFraction ?? 0)
        foodClipWidth = fillWidth
        let halfAvatar = safeAvatar / 2
        if remainingFraction != nil {
            markerCenterX = min(safeWidth - halfAvatar, max(halfAvatar, fillWidth))
        } else {
            markerCenterX = safeWidth / 2
        }
        markerLeadingX = markerCenterX - halfAvatar
    }
}

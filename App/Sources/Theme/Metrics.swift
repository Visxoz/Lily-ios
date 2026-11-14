import CoreGraphics

/// ytm-native's `Layout` global (`ui/page/layout.slint`) and the row sizes of
/// `page/*.slint`, for a 6.3" portrait screen. Values the phone forced to
/// change keep the desktop's in their comment.
nonisolated enum Metrics {
    /// Desktop 24: a 393 pt screen can't spare it on both sides.
    static let pagePadding: CGFloat = 16
    /// Space under a page's last row, clear of the tab bar's edge.
    static let pageBottom: CGFloat = 24

    // Track rows
    static let rowHeight: CGFloat = 56
    /// Desktop 16, inside a page padding that is smaller here.
    static let rowPadding: CGFloat = 8
    /// Desktop 16.
    static let rowSpacing: CGFloat = 12
    static let rowArt: CGFloat = 40
    static let rowNumber: CGFloat = 24
    /// Desktop 32, shown there only on hover.
    static let rowMore: CGFloat = 28
    static let rowDuration: CGFloat = 44

    // Section titles and the column labels over a track list
    static let titleHeight: CGFloat = 68
    static let greetingHeight: CGFloat = 48
    static let columnsHeight: CGFloat = 44

    // Cards. On a phone there is no hover background, so the artwork takes
    // the card's whole width and the gap between cards does the spacing.
    /// Desktop 188, which fits a single grid column on a phone.
    static let cardWidth: CGFloat = 156
    /// Desktop 4 between cards padded by 12 either side.
    static let cardGap: CGFloat = 12
    static let cardArtRadius: CGFloat = 6

    // Genre tiles
    /// Desktop 190.
    static let chipMinWidth: CGFloat = 150
    static let chipHeight: CGFloat = 96
    /// Desktop 16.
    static let chipGap: CGFloat = 12

    // Page headers
    static let headerArt: CGFloat = 232
    /// Desktop 340, beside the desktop's wider window.
    static let bannerHeight: CGFloat = 300
    /// Desktop 96.
    static let actionsHeight: CGFloat = 88
    static let topResultArt: CGFloat = 96
    /// Desktop 200 (`top-height` less its margin), as the phone's card stacks.
    static let topResultHeight: CGFloat = 200

    // Behind the page
    static let tintHeight: CGFloat = 420
    /// How far the header scrolls away before its title shows in the bar.
    static let stickyTitleAfter: CGFloat = 280

    /// How many cards a grid `width` wide fits in a row, and how wide each is
    /// then, as `Layout.card-columns` and `card-cell`.
    static func cardColumns(width: CGFloat) -> (count: Int, cell: CGFloat) {
        columns(width: width, minimum: cardWidth, gap: cardGap)
    }

    static func chipColumns(width: CGFloat) -> (count: Int, cell: CGFloat) {
        columns(width: width, minimum: chipMinWidth, gap: chipGap)
    }

    private static func columns(width: CGFloat, minimum: CGFloat, gap: CGFloat) -> (count: Int, cell: CGFloat) {
        let count = max(1, Int(((width + gap) / (minimum + gap)).rounded(.down)))
        return (count, max(0, (width - CGFloat(count - 1) * gap) / CGFloat(count)))
    }
}

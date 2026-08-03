import CalendarDomain
import CoreGraphics
import Testing
@testable import CalendarApp

@Suite("AnchoredEditorLayoutTests")
struct AnchoredEditorLayoutTests {
    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let card = CGSize(width: 280, height: 220)

    @Test func cardPrefersRightThenFlipsLeftAtWindowEdge() {
        let centered = AnchoredEditorLayout.place(
            cardSize: card,
            anchorFrame: CGRect(x: 220, y: 220, width: 60, height: 40),
            windowBounds: window
        )
        let rightEdge = AnchoredEditorLayout.place(
            cardSize: card,
            anchorFrame: CGRect(x: 720, y: 220, width: 60, height: 40),
            windowBounds: window
        )

        #expect(centered.edge == .right)
        #expect(rightEdge.edge == .left)
        #expect(rightEdge.frame.minX >= 12)
    }

    @Test func cardFallsBelowThenAboveWhenHorizontalEdgesCannotFit() {
        let below = AnchoredEditorLayout.place(
            cardSize: CGSize(width: 760, height: 180),
            anchorFrame: CGRect(x: 370, y: 120, width: 60, height: 40),
            windowBounds: window
        )
        let above = AnchoredEditorLayout.place(
            cardSize: CGSize(width: 760, height: 180),
            anchorFrame: CGRect(x: 370, y: 500, width: 60, height: 40),
            windowBounds: window
        )

        #expect(below.edge == .below)
        #expect(above.edge == .above)
        #expect(below.frame.minY >= 12)
        #expect(above.frame.maxY <= 588)
    }

    @Test func offscreenAnchorPinsToNearestSafeWindowEdge() {
        let placement = AnchoredEditorLayout.place(
            cardSize: card,
            anchorFrame: CGRect(x: 300, y: 720, width: 60, height: 40),
            windowBounds: window
        )

        #expect(placement.pinnedToWindowEdge)
        #expect(placement.frame.maxY <= window.maxY - 12)
        #expect(placement.frame.minX >= 12)
    }

    @Test func oversizedMeasuredCardIsContainedAndRequestsInternalScrolling() {
        let placement = AnchoredEditorLayout.place(
            cardSize: CGSize(width: 760, height: 720),
            anchorFrame: CGRect(x: 370, y: 140, width: 60, height: 40),
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 300)
        )

        #expect(placement.frame.minX >= 12)
        #expect(placement.frame.maxX <= 788)
        #expect(placement.frame.minY >= 12)
        #expect(placement.frame.maxY <= 288)
        #expect(placement.requiresInternalScroll)
    }

    @Test func quickCreateOverlayUsesMeasuredDynamicSizeWithoutChangingItsRangeDraft() {
        let draft = QuickCreatePresentation(
            range: .init(
                start: CalendarDate(year: 2026, month: 8, day: 6)!,
                end: CalendarDate(year: 2026, month: 8, day: 8)!
            ),
            anchorDate: CalendarDate(year: 2026, month: 8, day: 8)!
        )
        let layout = QuickCreateOverlayPresentation(
            presentation: draft,
            measuredContentSize: CGSize(width: 370, height: 740),
            anchorFrame: CGRect(x: 720, y: 220, width: 60, height: 40),
            windowBounds: window
        )

        #expect(layout.presentation == draft)
        #expect(layout.placement.edge == .left)
        #expect(layout.maximumContentHeight == 576)
        #expect(layout.placement.requiresInternalScroll)
    }

    @Test func measuredWeeklyEndAndErrorContentSwitchesTheProductionOverlayToScrollableLayout() {
        let draft = QuickCreatePresentation(
            range: .init(
                start: CalendarDate(year: 2026, month: 8, day: 6)!,
                end: CalendarDate(year: 2026, month: 8, day: 8)!
            ),
            anchorDate: CalendarDate(year: 2026, month: 8, day: 8)!
        )
        let weeklyOnly = QuickCreateOverlayPresentation(
            presentation: draft,
            measuredContentSize: CGSize(width: 370, height: 520),
            anchorFrame: CGRect(x: 370, y: 220, width: 60, height: 40),
            windowBounds: window
        )
        let weeklyEndAndError = QuickCreateOverlayPresentation(
            presentation: draft,
            measuredContentSize: CGSize(width: 370, height: 740),
            anchorFrame: CGRect(x: 370, y: 220, width: 60, height: 40),
            windowBounds: window
        )

        #expect(weeklyOnly.contentLayout == .natural)
        #expect(weeklyEndAndError.contentLayout == .scrollable(maximumHeight: 576))
    }

    @Test func minimumWindowClampsBothCardDimensionsInsideItsSafeBounds() {
        let placement = AnchoredEditorLayout.place(
            cardSize: CGSize(width: 370, height: 740),
            anchorFrame: CGRect(x: 140, y: 60, width: 40, height: 30),
            windowBounds: CGRect(x: 0, y: 0, width: 320, height: 180)
        )

        #expect(placement.frame == CGRect(x: 12, y: 12, width: 296, height: 156))
        #expect(placement.requiresInternalScroll)
    }
}

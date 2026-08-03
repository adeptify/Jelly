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

    @Test func zeroAndTinyWindowsProduceFiniteFramesInsideTheAvailableWindow() {
        let zero = AnchoredEditorLayout.place(
            cardSize: CGSize(width: 370, height: 740),
            anchorFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
            windowBounds: .zero
        )
        let tinyWindow = CGRect(x: 20, y: 30, width: 10, height: 10)
        let tiny = AnchoredEditorLayout.place(
            cardSize: CGSize(width: 370, height: 740),
            anchorFrame: CGRect(x: 22, y: 32, width: 2, height: 2),
            windowBounds: tinyWindow
        )

        #expect(zero.frame == .zero)
        #expect(tiny.frame == tinyWindow)
        #expect(isFinite(tiny.frame))
    }

    @Test func nonFiniteInputsCannotEscapeAFiniteWindow() {
        let finiteWindow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let invalidAnchors = [
            CGRect(x: CGFloat.nan, y: 10, width: 20, height: 20),
            CGRect(x: CGFloat.infinity, y: 10, width: 20, height: 20),
            CGRect(x: 10, y: -CGFloat.infinity, width: 20, height: 20)
        ]
        let invalidCards = [
            CGSize(width: CGFloat.nan, height: 240),
            CGSize(width: CGFloat.infinity, height: 240),
            CGSize(width: 240, height: -CGFloat.infinity)
        ]

        for anchor in invalidAnchors {
            let placement = AnchoredEditorLayout.place(
                cardSize: CGSize(width: CGFloat.infinity, height: CGFloat.nan),
                anchorFrame: anchor,
                windowBounds: finiteWindow
            )
            #expect(isFinite(placement.frame))
            #expect(finiteWindow.contains(placement.frame))
        }
        for card in invalidCards {
            let placement = AnchoredEditorLayout.place(
                cardSize: card,
                anchorFrame: CGRect(x: 200, y: 220, width: 30, height: 30),
                windowBounds: finiteWindow
            )
            #expect(isFinite(placement.frame))
            #expect(finiteWindow.contains(placement.frame))
        }
    }

    @Test func nullInfiniteAndNonFiniteWindowsCollapseToAFiniteZeroFrame() {
        let invalidWindows = [
            CGRect.null,
            CGRect.infinite,
            CGRect(x: CGFloat.nan, y: 0, width: 300, height: 200),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200)
        ]

        for window in invalidWindows {
            let placement = AnchoredEditorLayout.place(
                cardSize: CGSize(width: CGFloat.infinity, height: CGFloat.nan),
                anchorFrame: CGRect(x: CGFloat.infinity, y: CGFloat.nan, width: 20, height: 20),
                windowBounds: window
            )

            #expect(placement.frame == .zero)
            #expect(isFinite(placement.frame))
        }
    }

    private func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
    }
}

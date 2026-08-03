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
}

import CoreGraphics

enum AnchoredEditorEdge: Equatable {
    case right
    case left
    case below
    case above
}

struct AnchoredEditorPlacement: Equatable {
    let frame: CGRect
    let edge: AnchoredEditorEdge
    let pinnedToWindowEdge: Bool
    let requiresInternalScroll: Bool
}

enum AnchoredEditorLayout {
    static let safeInset: CGFloat = 12
    static let anchorSpacing: CGFloat = 8

    static func place(
        cardSize: CGSize,
        anchorFrame: CGRect,
        windowBounds: CGRect
    ) -> AnchoredEditorPlacement {
        let safeBounds = boundedSafeArea(in: windowBounds)
        let constrainedCardSize = CGSize(
            width: min(max(0, cardSize.width), safeBounds.width),
            height: min(max(0, cardSize.height), safeBounds.height)
        )
        let requiresInternalScroll = cardSize.height > constrainedCardSize.height
        guard anchorFrame.intersects(windowBounds) else {
            return offscreenPlacement(
                cardSize: constrainedCardSize,
                anchorFrame: anchorFrame,
                safeBounds: safeBounds,
                requiresInternalScroll: requiresInternalScroll
            )
        }

        let candidates = candidateFrames(cardSize: constrainedCardSize, anchorFrame: anchorFrame)
        if let candidate = candidates.first(where: { safeBounds.contains($0.frame) }) {
            return .init(
                frame: candidate.frame,
                edge: candidate.edge,
                pinnedToWindowEdge: false,
                requiresInternalScroll: requiresInternalScroll
            )
        }

        let candidate = candidates.min { left, right in
            overflow(of: left.frame, beyond: safeBounds) < overflow(of: right.frame, beyond: safeBounds)
        }!
        return .init(
            frame: clamped(candidate.frame, to: safeBounds),
            edge: candidate.edge,
            pinnedToWindowEdge: false,
            requiresInternalScroll: requiresInternalScroll
        )
    }

    private static func candidateFrames(
        cardSize: CGSize,
        anchorFrame: CGRect
    ) -> [(edge: AnchoredEditorEdge, frame: CGRect)] {
        [
            (
                .right,
                .init(
                    x: anchorFrame.maxX + anchorSpacing,
                    y: anchorFrame.midY - cardSize.height / 2,
                    width: cardSize.width,
                    height: cardSize.height
                )
            ),
            (
                .left,
                .init(
                    x: anchorFrame.minX - anchorSpacing - cardSize.width,
                    y: anchorFrame.midY - cardSize.height / 2,
                    width: cardSize.width,
                    height: cardSize.height
                )
            ),
            (
                .below,
                .init(
                    x: anchorFrame.midX - cardSize.width / 2,
                    y: anchorFrame.maxY + anchorSpacing,
                    width: cardSize.width,
                    height: cardSize.height
                )
            ),
            (
                .above,
                .init(
                    x: anchorFrame.midX - cardSize.width / 2,
                    y: anchorFrame.minY - anchorSpacing - cardSize.height,
                    width: cardSize.width,
                    height: cardSize.height
                )
            )
        ]
    }

    private static func offscreenPlacement(
        cardSize: CGSize,
        anchorFrame: CGRect,
        safeBounds: CGRect,
        requiresInternalScroll: Bool
    ) -> AnchoredEditorPlacement {
        let edge: AnchoredEditorEdge
        let origin: CGPoint
        if anchorFrame.maxY < safeBounds.minY {
            edge = .below
            origin = .init(x: anchorFrame.midX - cardSize.width / 2, y: safeBounds.minY)
        } else if anchorFrame.minY > safeBounds.maxY {
            edge = .above
            origin = .init(
                x: anchorFrame.midX - cardSize.width / 2,
                y: safeBounds.maxY - cardSize.height
            )
        } else if anchorFrame.maxX < safeBounds.minX {
            edge = .right
            origin = .init(x: safeBounds.minX, y: anchorFrame.midY - cardSize.height / 2)
        } else {
            edge = .left
            origin = .init(
                x: safeBounds.maxX - cardSize.width,
                y: anchorFrame.midY - cardSize.height / 2
            )
        }
        let frame = CGRect(origin: origin, size: cardSize)
        return .init(
            frame: clamped(frame, to: safeBounds),
            edge: edge,
            pinnedToWindowEdge: true,
            requiresInternalScroll: requiresInternalScroll
        )
    }

    private static func boundedSafeArea(in windowBounds: CGRect) -> CGRect {
        let inset = windowBounds.insetBy(dx: safeInset, dy: safeInset)
        return CGRect(
            x: inset.minX,
            y: inset.minY,
            width: max(0, inset.width),
            height: max(0, inset.height)
        )
    }

    private static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
            y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private static func overflow(of frame: CGRect, beyond bounds: CGRect) -> CGFloat {
        max(0, bounds.minX - frame.minX)
            + max(0, frame.maxX - bounds.maxX)
            + max(0, bounds.minY - frame.minY)
            + max(0, frame.maxY - bounds.maxY)
    }
}

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
        let safeBounds = boundedSafeArea(in: sanitizedWindow(windowBounds))
        guard safeBounds.width > 0, safeBounds.height > 0 else {
            return .init(
                frame: .zero,
                edge: .right,
                pinnedToWindowEdge: true,
                requiresInternalScroll: cardSize.height.isFinite && cardSize.height > 0
            )
        }

        let constrainedCardSize = CGSize(
            width: constrainedDimension(cardSize.width, maximum: safeBounds.width),
            height: constrainedDimension(cardSize.height, maximum: safeBounds.height)
        )
        let requiresInternalScroll = requiresInternalScroll(
            requestedHeight: cardSize.height,
            constrainedHeight: constrainedCardSize.height
        )
        let sanitizedAnchor = sanitizedAnchor(anchorFrame, fallbackIn: safeBounds)
        guard sanitizedAnchor.intersects(safeBounds) else {
            return offscreenPlacement(
                cardSize: constrainedCardSize,
                anchorFrame: sanitizedAnchor,
                safeBounds: safeBounds,
                requiresInternalScroll: requiresInternalScroll
            )
        }

        let candidates = candidateFrames(
            cardSize: constrainedCardSize,
            anchorFrame: sanitizedAnchor,
            fallbackBounds: safeBounds
        )
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
        anchorFrame: CGRect,
        fallbackBounds: CGRect
    ) -> [(edge: AnchoredEditorEdge, frame: CGRect)] {
        [
            (
                .right,
                .init(
                    x: finiteCoordinate(
                        anchorFrame.maxX + anchorSpacing,
                        fallback: fallbackBounds.minX
                    ),
                    y: finiteCoordinate(
                        anchorFrame.midY - cardSize.height / 2,
                        fallback: fallbackBounds.minY
                    ),
                    width: cardSize.width,
                    height: cardSize.height
                )
            ),
            (
                .left,
                .init(
                    x: finiteCoordinate(
                        anchorFrame.minX - anchorSpacing - cardSize.width,
                        fallback: fallbackBounds.minX
                    ),
                    y: finiteCoordinate(
                        anchorFrame.midY - cardSize.height / 2,
                        fallback: fallbackBounds.minY
                    ),
                    width: cardSize.width,
                    height: cardSize.height
                )
            ),
            (
                .below,
                .init(
                    x: finiteCoordinate(
                        anchorFrame.midX - cardSize.width / 2,
                        fallback: fallbackBounds.minX
                    ),
                    y: finiteCoordinate(
                        anchorFrame.maxY + anchorSpacing,
                        fallback: fallbackBounds.minY
                    ),
                    width: cardSize.width,
                    height: cardSize.height
                )
            ),
            (
                .above,
                .init(
                    x: finiteCoordinate(
                        anchorFrame.midX - cardSize.width / 2,
                        fallback: fallbackBounds.minX
                    ),
                    y: finiteCoordinate(
                        anchorFrame.minY - anchorSpacing - cardSize.height,
                        fallback: fallbackBounds.minY
                    ),
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
            origin = .init(
                x: finiteCoordinate(anchorFrame.midX - cardSize.width / 2, fallback: safeBounds.minX),
                y: safeBounds.minY
            )
        } else if anchorFrame.minY > safeBounds.maxY {
            edge = .above
            origin = .init(
                x: finiteCoordinate(anchorFrame.midX - cardSize.width / 2, fallback: safeBounds.minX),
                y: safeBounds.maxY - cardSize.height
            )
        } else if anchorFrame.maxX < safeBounds.minX {
            edge = .right
            origin = .init(
                x: safeBounds.minX,
                y: finiteCoordinate(anchorFrame.midY - cardSize.height / 2, fallback: safeBounds.minY)
            )
        } else {
            edge = .left
            origin = .init(
                x: safeBounds.maxX - cardSize.width,
                y: finiteCoordinate(anchorFrame.midY - cardSize.height / 2, fallback: safeBounds.minY)
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
        guard windowBounds.width > 0, windowBounds.height > 0 else { return .zero }
        guard windowBounds.width > safeInset * 2,
              windowBounds.height > safeInset * 2
        else {
            return windowBounds
        }
        return CGRect(
            x: windowBounds.minX + safeInset,
            y: windowBounds.minY + safeInset,
            width: windowBounds.width - safeInset * 2,
            height: windowBounds.height - safeInset * 2
        )
    }

    private static func sanitizedWindow(_ bounds: CGRect) -> CGRect {
        sanitizedFiniteRect(bounds) ?? .zero
    }

    private static func sanitizedAnchor(_ anchor: CGRect, fallbackIn bounds: CGRect) -> CGRect {
        sanitizedFiniteRect(anchor) ?? CGRect(
            x: bounds.midX,
            y: bounds.midY,
            width: 0,
            height: 0
        )
    }

    private static func sanitizedFiniteRect(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull,
              !rect.isInfinite,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite
        else {
            return nil
        }
        let standardized = rect.standardized
        guard standardized.origin.x.isFinite,
              standardized.origin.y.isFinite,
              standardized.size.width.isFinite,
              standardized.size.height.isFinite,
              standardized.maxX.isFinite,
              standardized.maxY.isFinite,
              standardized.width >= 0,
              standardized.height >= 0
        else {
            return nil
        }
        return standardized
    }

    private static func constrainedDimension(_ requested: CGFloat, maximum: CGFloat) -> CGFloat {
        guard maximum.isFinite, maximum > 0 else { return 0 }
        if requested == .infinity { return maximum }
        guard requested.isFinite else { return 0 }
        return min(max(0, requested), maximum)
    }

    private static func requiresInternalScroll(
        requestedHeight: CGFloat,
        constrainedHeight: CGFloat
    ) -> Bool {
        requestedHeight == .infinity
            || (requestedHeight.isFinite && requestedHeight > constrainedHeight)
    }

    private static func finiteCoordinate(_ candidate: CGFloat, fallback: CGFloat) -> CGFloat {
        candidate.isFinite ? candidate : fallback
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

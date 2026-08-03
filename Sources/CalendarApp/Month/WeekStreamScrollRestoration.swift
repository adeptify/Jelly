import AppKit
import CalendarDomain
import SwiftUI

struct WeekStreamWindowRevision: Equatable, Hashable, Sendable {
    let first: CalendarDate
    let last: CalendarDate
    let count: Int

    init(first: CalendarDate, last: CalendarDate, count: Int) {
        self.first = first
        self.last = last
        self.count = count
    }

    init(weekStarts: [CalendarDate]) {
        precondition(!weekStarts.isEmpty, "A week-stream revision requires a non-empty window.")
        first = weekStarts[0]
        last = weekStarts[weekStarts.count - 1]
        count = weekStarts.count
    }
}

enum WeekStreamRestorationAction: Equatable {
    case wait
    case adjustContentOffset(viewportDeltaY: CGFloat)
    case confirmed
}

struct WeekStreamRestorationState: Equatable {
    private struct Pending: Equatable {
        var anchor: WeekStreamAnchor
        let desiredMinY: CGFloat
        var expectedRevision: WeekStreamWindowRevision?
        var proposedAnchorMinY: CGFloat?
        var awaitingFrameFromAnchorMinY: CGFloat?
    }

    private static let confirmationTolerance: CGFloat = 0.5
    private var pending: Pending?

    var isLocked: Bool { pending != nil }

    mutating func begin(request: WeekStreamExtensionRequest) -> Bool {
        guard pending == nil else { return false }
        pending = Pending(
            anchor: request.anchor,
            desiredMinY: request.desiredMinY,
            expectedRevision: nil
        )
        return true
    }

    mutating func expect(anchor: WeekStreamAnchor, windowRevision: WeekStreamWindowRevision) {
        guard var pending else { return }
        pending.anchor = anchor
        pending.expectedRevision = windowRevision
        self.pending = pending
    }

    mutating func receive(frames: [WeekRowViewportFrame]) -> WeekStreamRestorationAction {
        guard var pending, let expectedRevision = pending.expectedRevision else {
            return .wait
        }
        guard let anchorFrame = frames.first(where: {
            $0.weekStart == pending.anchor.weekStart && $0.windowRevision == expectedRevision
        }) else {
            return .wait
        }

        let viewportDeltaY = anchorFrame.minY - pending.desiredMinY
        if abs(viewportDeltaY) <= Self.confirmationTolerance {
            self.pending = nil
            return .confirmed
        }

        if let awaitingFrameFromAnchorMinY = pending.awaitingFrameFromAnchorMinY {
            guard abs(anchorFrame.minY - awaitingFrameFromAnchorMinY) > Self.confirmationTolerance else {
                return .wait
            }
            pending.awaitingFrameFromAnchorMinY = nil
        }

        pending.proposedAnchorMinY = anchorFrame.minY
        self.pending = pending
        return .adjustContentOffset(viewportDeltaY: viewportDeltaY)
    }

    mutating func recordAppliedAdjustment(
        requestedViewportDeltaY: CGFloat,
        appliedViewportDeltaY: CGFloat
    ) {
        guard var pending, let proposedAnchorMinY = pending.proposedAnchorMinY else { return }
        let proposedViewportDeltaY = proposedAnchorMinY - pending.desiredMinY
        guard abs(proposedViewportDeltaY - requestedViewportDeltaY) <= Self.confirmationTolerance else {
            return
        }

        if abs(appliedViewportDeltaY) <= Self.confirmationTolerance {
            // The document boundary made the requested restoration unreachable. Release the
            // extension lock explicitly instead of waiting for a frame change that cannot occur.
            self.pending = nil
            return
        }
        pending.proposedAnchorMinY = nil
        pending.awaitingFrameFromAnchorMinY = proposedAnchorMinY
        self.pending = pending
    }
}

enum WeekStreamScrollOffset {
    static func adjustedOriginY(
        currentOriginY: CGFloat,
        viewportDeltaY: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        documentIsFlipped: Bool
    ) -> CGFloat {
        let maximumOriginY = max(0, documentHeight - viewportHeight)
        let orientedDelta = documentIsFlipped ? viewportDeltaY : -viewportDeltaY
        return min(max(currentOriginY + orientedDelta, 0), maximumOriginY)
    }

    static func appliedViewportDeltaY(
        fromOriginY: CGFloat,
        toOriginY: CGFloat,
        documentIsFlipped: Bool
    ) -> CGFloat {
        documentIsFlipped ? toOriginY - fromOriginY : fromOriginY - toOriginY
    }
}

struct WeekStreamScrollAdjustment: Equatable {
    let requestedViewportDeltaY: CGFloat
    let appliedViewportDeltaY: CGFloat
}

@MainActor
final class WeekStreamScrollCoordinator: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var queuedViewportDeltaY: CGFloat?

    func resolve(from markerView: NSView) {
        if let scrollView = Self.findScrollView(from: markerView) {
            attach(scrollView)
            return
        }
        DispatchQueue.main.async { [weak self, weak markerView] in
            guard let self, let markerView,
                  let scrollView = Self.findScrollView(from: markerView)
            else {
                return
            }
            self.attach(scrollView)
        }
    }

    func adjustViewport(by viewportDeltaY: CGFloat) -> WeekStreamScrollAdjustment? {
        guard let scrollView, let documentView = scrollView.documentView else {
            queuedViewportDeltaY = viewportDeltaY
            return nil
        }
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin
        let documentHeight = max(documentView.bounds.height, documentView.frame.height)
        let newOriginY = WeekStreamScrollOffset.adjustedOriginY(
            currentOriginY: currentOrigin.y,
            viewportDeltaY: viewportDeltaY,
            documentHeight: documentHeight,
            viewportHeight: clipView.bounds.height,
            documentIsFlipped: documentView.isFlipped
        )
        let appliedViewportDeltaY = WeekStreamScrollOffset.appliedViewportDeltaY(
            fromOriginY: currentOrigin.y,
            toOriginY: newOriginY,
            documentIsFlipped: documentView.isFlipped
        )

        if abs(appliedViewportDeltaY) > 0.01 {
            clipView.scroll(to: NSPoint(x: currentOrigin.x, y: newOriginY))
            scrollView.reflectScrolledClipView(clipView)
        }
        queuedViewportDeltaY = nil
        return WeekStreamScrollAdjustment(
            requestedViewportDeltaY: viewportDeltaY,
            appliedViewportDeltaY: appliedViewportDeltaY
        )
    }

    private func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        if let queuedViewportDeltaY {
            _ = adjustViewport(by: queuedViewportDeltaY)
        }
    }

    private static func findScrollView(from markerView: NSView) -> NSScrollView? {
        var candidate: NSView? = markerView
        while let view = candidate {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            if let enclosingScrollView = view.enclosingScrollView {
                return enclosingScrollView
            }
            candidate = view.superview
        }
        return nil
    }
}

struct WeekStreamScrollResolver: NSViewRepresentable {
    let coordinator: WeekStreamScrollCoordinator

    func makeNSView(context: Context) -> NSView {
        let markerView = NSView(frame: .zero)
        coordinator.resolve(from: markerView)
        return markerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        coordinator.resolve(from: nsView)
    }
}

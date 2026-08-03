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

struct WeekStreamScrollCorrectionToken: Equatable, Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

struct WeekStreamScrollCorrection: Equatable, Sendable {
    let token: WeekStreamScrollCorrectionToken
    let windowRevision: WeekStreamWindowRevision
    let viewportDeltaY: CGFloat

    init(
        token: WeekStreamScrollCorrectionToken = .init(),
        windowRevision: WeekStreamWindowRevision,
        viewportDeltaY: CGFloat
    ) {
        self.token = token
        self.windowRevision = windowRevision
        self.viewportDeltaY = viewportDeltaY
    }
}

struct WeekStreamCenteringRequest: Equatable, Sendable {
    let id: UUID
    let weekStart: CalendarDate
    let windowRevision: WeekStreamWindowRevision

    init(
        id: UUID = UUID(),
        weekStart: CalendarDate,
        windowRevision: WeekStreamWindowRevision
    ) {
        self.id = id
        self.weekStart = weekStart
        self.windowRevision = windowRevision
    }
}

enum WeekStreamCenteringAction: Equatable {
    case wait
    case retry(WeekStreamCenteringRequest)
    case ready
}

struct WeekStreamCenteringState: Equatable {
    private enum Phase: Equatable {
        case pending
        case animating
        case centering
    }

    private static let confirmationTolerance: CGFloat = 0.5
    private var request: WeekStreamCenteringRequest?
    private var phase: Phase?
    private var retryScheduled = false
    private var retriesRemaining = 1

    var blocksViewportUpdates: Bool { request != nil }
    var pendingRequest: WeekStreamCenteringRequest? { request }

    @discardableResult
    mutating func begin(
        weekStart: CalendarDate,
        windowRevision: WeekStreamWindowRevision
    ) -> WeekStreamCenteringRequest {
        let request = WeekStreamCenteringRequest(
            weekStart: weekStart,
            windowRevision: windowRevision
        )
        self.request = request
        phase = .pending
        retryScheduled = false
        retriesRemaining = 1
        return request
    }

    @discardableResult
    mutating func markScrollIssued(
        for request: WeekStreamCenteringRequest,
        animated: Bool = false
    ) -> Bool {
        guard self.request == request else { return false }
        phase = animated ? .animating : .centering
        retryScheduled = false
        return true
    }

    @discardableResult
    mutating func markAnimationSettled(for request: WeekStreamCenteringRequest) -> Bool {
        guard self.request == request, phase == .animating else { return false }
        phase = .centering
        return true
    }

    mutating func receive(
        frames: [WeekRowViewportFrame],
        viewportHeight: CGFloat
    ) -> WeekStreamCenteringAction {
        guard let request else { return .ready }
        guard phase == .centering else { return .wait }

        let currentFrames = frames.filter { $0.windowRevision == request.windowRevision }
        guard !currentFrames.isEmpty else { return .wait }
        guard let targetFrame = currentFrames.first(where: { $0.weekStart == request.weekStart }) else {
            return scheduleRetry(for: request)
        }
        let viewportCenter = viewportHeight / 2
        guard abs(targetFrame.centerY - viewportCenter) <= Self.confirmationTolerance else {
            return scheduleRetry(for: request)
        }

        self.request = nil
        phase = nil
        retryScheduled = false
        return .ready
    }

    private mutating func scheduleRetry(for request: WeekStreamCenteringRequest) -> WeekStreamCenteringAction {
        guard !retryScheduled, retriesRemaining > 0 else { return .wait }
        retryScheduled = true
        retriesRemaining -= 1
        return .retry(request)
    }
}

struct WeekStreamCenteringCoordinator: Equatable {
    private var state = WeekStreamCenteringState()
    private var latestFrames: [WeekRowViewportFrame] = []
    private var latestViewportHeight: CGFloat?

    var blocksViewportUpdates: Bool { state.blocksViewportUpdates }
    var pendingRequest: WeekStreamCenteringRequest? { state.pendingRequest }

    @discardableResult
    mutating func begin(
        weekStart: CalendarDate,
        windowRevision: WeekStreamWindowRevision
    ) -> WeekStreamCenteringRequest {
        state.begin(weekStart: weekStart, windowRevision: windowRevision)
    }

    @discardableResult
    mutating func markScrollIssued(
        for request: WeekStreamCenteringRequest,
        animated: Bool = false
    ) -> Bool {
        state.markScrollIssued(for: request, animated: animated)
    }

    @discardableResult
    mutating func markAnimationSettled(for request: WeekStreamCenteringRequest) -> Bool {
        state.markAnimationSettled(for: request)
    }

    mutating func receiveViewport(
        frames: [WeekRowViewportFrame],
        viewportHeight: CGFloat
    ) -> WeekStreamCenteringAction {
        latestFrames = frames
        latestViewportHeight = viewportHeight
        return state.receive(frames: frames, viewportHeight: viewportHeight)
    }

    mutating func confirmDeferredCentering(
        for request: WeekStreamCenteringRequest
    ) -> WeekStreamCenteringAction {
        guard state.pendingRequest == request,
              let latestViewportHeight
        else {
            return .wait
        }
        return state.receive(
            frames: latestFrames,
            viewportHeight: latestViewportHeight
        )
    }
}

enum WeekStreamRestorationAction: Equatable {
    case wait
    case adjustContentOffset(WeekStreamScrollCorrection)
    case confirmed
}

struct WeekStreamRestorationState: Equatable {
    private struct Pending: Equatable {
        var anchor: WeekStreamAnchor
        let desiredMinY: CGFloat
        var expectedRevision: WeekStreamWindowRevision?
        var outstandingCorrection: WeekStreamScrollCorrection?
        var outstandingAnchorMinY: CGFloat?
        var awaitingFrameFromAnchorMinY: CGFloat?
    }

    private static let confirmationTolerance: CGFloat = 0.5
    private var pending: Pending?

    var isLocked: Bool { pending != nil }

    mutating func cancel() {
        pending = nil
    }

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

        guard pending.outstandingCorrection == nil else {
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

        let correction = WeekStreamScrollCorrection(
            windowRevision: expectedRevision,
            viewportDeltaY: viewportDeltaY
        )
        pending.outstandingCorrection = correction
        pending.outstandingAnchorMinY = anchorFrame.minY
        self.pending = pending
        return .adjustContentOffset(correction)
    }

    mutating func recordAppliedAdjustment(_ adjustment: WeekStreamScrollAdjustment) {
        guard var pending,
              let expectedRevision = pending.expectedRevision,
              let outstandingCorrection = pending.outstandingCorrection,
              let outstandingAnchorMinY = pending.outstandingAnchorMinY,
              adjustment.correction == outstandingCorrection,
              adjustment.correction.windowRevision == expectedRevision
        else {
            return
        }

        if abs(adjustment.appliedViewportDeltaY) <= Self.confirmationTolerance {
            // The document boundary made the requested restoration unreachable. Release the
            // extension lock explicitly instead of waiting for a frame change that cannot occur.
            self.pending = nil
            return
        }
        pending.outstandingCorrection = nil
        pending.outstandingAnchorMinY = nil
        pending.awaitingFrameFromAnchorMinY = outstandingAnchorMinY
        self.pending = pending
    }
}

@MainActor
final class WeekStreamRestorationController: ObservableObject {
    @Published private var state = WeekStreamRestorationState()

    var isLocked: Bool { state.isLocked }

    func begin(request: WeekStreamExtensionRequest) -> Bool {
        state.begin(request: request)
    }

    func expect(anchor: WeekStreamAnchor, windowRevision: WeekStreamWindowRevision) {
        state.expect(anchor: anchor, windowRevision: windowRevision)
    }

    func cancel() {
        state.cancel()
    }

    func receive(frames: [WeekRowViewportFrame]) -> WeekStreamRestorationAction {
        state.receive(frames: frames)
    }

    func recordAppliedAdjustment(_ adjustment: WeekStreamScrollAdjustment) {
        state.recordAppliedAdjustment(adjustment)
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
    let correction: WeekStreamScrollCorrection
    let appliedViewportDeltaY: CGFloat
}

@MainActor
final class WeekStreamScrollCoordinator: ObservableObject {
    private let onAdjustment: @MainActor (WeekStreamScrollAdjustment) -> Void
    private weak var scrollView: NSScrollView?
    private var queuedCorrection: WeekStreamScrollCorrection?

    init(
        onAdjustment: @escaping @MainActor (WeekStreamScrollAdjustment) -> Void = { _ in }
    ) {
        self.onAdjustment = onAdjustment
    }

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

    func adjustViewport(_ correction: WeekStreamScrollCorrection) {
        guard let scrollView, let documentView = scrollView.documentView else {
            if queuedCorrection == nil {
                queuedCorrection = correction
            }
            return
        }
        apply(correction, to: scrollView, documentView: documentView)
    }

    func invalidateQueuedCorrection() {
        queuedCorrection = nil
    }

    private func apply(
        _ correction: WeekStreamScrollCorrection,
        to scrollView: NSScrollView,
        documentView: NSView
    ) {
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin
        let documentHeight = max(documentView.bounds.height, documentView.frame.height)
        let newOriginY = WeekStreamScrollOffset.adjustedOriginY(
            currentOriginY: currentOrigin.y,
            viewportDeltaY: correction.viewportDeltaY,
            documentHeight: documentHeight,
            viewportHeight: clipView.bounds.height,
            documentIsFlipped: documentView.isFlipped
        )

        if abs(newOriginY - currentOrigin.y) > 0.01 {
            clipView.scroll(to: NSPoint(x: currentOrigin.x, y: newOriginY))
            scrollView.reflectScrolledClipView(clipView)
        }
        let actualOriginY = clipView.bounds.origin.y
        let adjustment = WeekStreamScrollAdjustment(
            correction: correction,
            appliedViewportDeltaY: WeekStreamScrollOffset.appliedViewportDeltaY(
                fromOriginY: currentOrigin.y,
                toOriginY: actualOriginY,
                documentIsFlipped: documentView.isFlipped
            )
        )
        onAdjustment(adjustment)
    }

    private func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        guard let queuedCorrection, let documentView = scrollView.documentView else { return }
        self.queuedCorrection = nil
        apply(queuedCorrection, to: scrollView, documentView: documentView)
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

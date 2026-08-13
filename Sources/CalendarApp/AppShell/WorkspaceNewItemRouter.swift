import Combine
import Foundation
import AppKit

struct WorkspaceNewItemRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let route: WorkspaceRoute

    init(id: UUID = UUID(), route: WorkspaceRoute) {
        self.id = id
        self.route = route
    }
}

@MainActor
final class WorkspaceNewItemRouter: ObservableObject {
    @Published private(set) var pendingRequest: WorkspaceNewItemRequest?
    private var capturedRequestID: UUID?
    private var capturedWindowNumber: Int?
    private var bufferedKeyEvents: [NSEvent] = []
    private var keyEventMonitor: Any?

    @discardableResult
    func requestNewItem(
        route: WorkspaceRoute,
        features: WorkspaceFeatures,
        capturesTypingUntilReady: Bool = false,
        sourceWindowNumber: Int? = nil
    ) -> WorkspaceNewItemRequest? {
        guard features.isEnabled(route) else { return nil }
        let request = WorkspaceNewItemRequest(route: route)
        if route == .notes, capturesTypingUntilReady {
            beginCapturingTyping(
                for: request.id,
                sourceWindowNumber: sourceWindowNumber
            )
        }
        pendingRequest = request
        return request
    }

    func consume(_ id: UUID, route: WorkspaceRoute) -> WorkspaceNewItemRequest? {
        guard let request = pendingRequest,
              request.id == id,
              request.route == route
        else {
            return nil
        }
        pendingRequest = nil
        return request
    }

    func deliverCapturedTyping(for requestID: UUID) {
        guard capturedRequestID == requestID else { return }
        let events = endCapturingTyping()
        Task { @MainActor in
            await Task.yield()
            events.forEach(NSApplication.shared.sendEvent)
        }
    }

    func cancelCapturedTyping(for requestID: UUID) {
        guard capturedRequestID == requestID else { return }
        let events = endCapturingTyping()
        Task { @MainActor in
            await Task.yield()
            events.forEach(NSApplication.shared.sendEvent)
        }
    }

    private func beginCapturingTyping(
        for requestID: UUID,
        sourceWindowNumber: Int?
    ) {
        if keyEventMonitor != nil {
            _ = endCapturingTyping()
        }
        capturedRequestID = requestID
        capturedWindowNumber = sourceWindowNumber
            ?? NSApplication.shared.keyWindow?.windowNumber
        bufferedKeyEvents = []
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.capturedRequestID == requestID else { return event }
            guard let capturedWindowNumber = self.capturedWindowNumber,
                  event.windowNumber == capturedWindowNumber else { return event }
            if event.modifierFlags.intersection([.command, .control]).isEmpty == false {
                return event
            }
            self.bufferedKeyEvents.append(event)
            return nil
        }
    }

    private func endCapturingTyping() -> [NSEvent] {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        capturedRequestID = nil
        capturedWindowNumber = nil
        let events = bufferedKeyEvents
        bufferedKeyEvents = []
        return events
    }
}

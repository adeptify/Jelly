import SwiftUI

struct ContinuousBlockEditorRepresentable: NSViewRepresentable {
    let session: BlockEditorSession
    let appearance: CalendarSemanticAppearance

    func makeCoordinator() -> Coordinator { .init(session: session) }

    func makeNSView(context: Context) -> ContinuousBlockEditorHostView {
        let host = ContinuousBlockEditorHostView(appearance: appearance)
        context.coordinator.session.attach(host: host, hostToken: context.coordinator.hostToken)
        return host
    }

    func updateNSView(_ host: ContinuousBlockEditorHostView, context: Context) {
        host.semanticAppearance = appearance
        context.coordinator.session.attach(host: host, hostToken: context.coordinator.hostToken)
        context.coordinator.session.projectAuthoritativeState()
    }

    static func dismantleNSView(_ host: ContinuousBlockEditorHostView, coordinator: Coordinator) {
        coordinator.session.detachContinuousHost(hostToken: coordinator.hostToken)
    }

    @MainActor
    final class Coordinator {
        let session: BlockEditorSession
        let hostToken = UUID()

        init(session: BlockEditorSession) {
            self.session = session
        }
    }
}

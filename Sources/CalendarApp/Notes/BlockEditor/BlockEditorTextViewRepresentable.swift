import AppKit
import SwiftUI
import WorkspaceDomain

struct BlockEditorTextViewRepresentable: NSViewRepresentable {
    let blockID: BlockID
    let session: BlockEditorSession

    func makeCoordinator() -> Coordinator { .init(session: session, blockID: blockID) }

    func makeNSView(context: Context) -> BlockEditorTextView {
        let textView = BlockEditorTextView(frame: .zero)
        context.coordinator.session.attach(
            blockID: context.coordinator.blockID,
            hostToken: context.coordinator.hostToken,
            textView: textView
        )
        return textView
    }

    func updateNSView(_ nsView: BlockEditorTextView, context: Context) {
        context.coordinator.session.attach(
            blockID: context.coordinator.blockID,
            hostToken: context.coordinator.hostToken,
            textView: nsView
        )
        context.coordinator.session.projectAuthoritativeState()
    }

    static func dismantleNSView(_ nsView: BlockEditorTextView, coordinator: Coordinator) {
        coordinator.session.detach(hostToken: coordinator.hostToken)
    }

    @MainActor
    final class Coordinator {
        let session: BlockEditorSession
        let blockID: BlockID
        let hostToken = UUID()

        init(session: BlockEditorSession, blockID: BlockID) {
            self.session = session
            self.blockID = blockID
        }
    }
}

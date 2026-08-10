import AppKit
import SwiftUI

/// Borderless title field that registers its field-editor UndoManager with the
/// shared `EditorFocusRegistry` while focused, so Command-Z never falls through
/// to Workspace undo.
struct NoteTitleTextField: NSViewRepresentable {
    @Binding var title: String
    let focusRegistry: EditorFocusRegistry
    let ownerID: UUID
    var onCommit: (String) -> Void
    var onEditingChanged: (String) -> Void
    var coordinatorSink: ((Coordinator) -> Void)?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            focusRegistry: focusRegistry,
            ownerID: ownerID,
            onCommit: onCommit,
            onEditingChanged: onEditingChanged
        )
        coordinatorSink?(coordinator)
        return coordinator
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: title)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .semibold)
        field.placeholderString = "标题"
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = true
        context.coordinator.field = field
        coordinatorSink?(context.coordinator)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onEditingChanged = onEditingChanged
        coordinatorSink?(context.coordinator)
        if nsView.stringValue != title, context.coordinator.isEditing == false {
            nsView.stringValue = title
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let focusRegistry: EditorFocusRegistry
        let ownerID: UUID
        var onCommit: (String) -> Void
        var onEditingChanged: (String) -> Void
        weak var field: NSTextField?
        private(set) var isEditing = false

        init(
            focusRegistry: EditorFocusRegistry,
            ownerID: UUID,
            onCommit: @escaping (String) -> Void,
            onEditingChanged: @escaping (String) -> Void
        ) {
            self.focusRegistry = focusRegistry
            self.ownerID = ownerID
            self.onCommit = onCommit
            self.onEditingChanged = onEditingChanged
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
            registerFieldEditor()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            registerFieldEditor()
            onEditingChanged(field.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            focusRegistry.clear(ownerID: ownerID)
            guard let field else { return }
            onCommit(field.stringValue)
        }

        /// Commit marked IME text in the title field-editor if present.
        @discardableResult
        func terminallyFinalizeNativeComposition() -> Bool {
            guard let field,
                  let editor = field.currentEditor() as? NSTextView else { return true }
            if editor.hasMarkedText() {
                editor.unmarkText()
            }
            return editor.hasMarkedText() == false
        }

        private func registerFieldEditor() {
            guard let field,
                  let editor = field.currentEditor() as? NSTextView,
                  let manager = editor.undoManager else { return }
            focusRegistry.register(manager, ownerID: ownerID)
        }
    }
}

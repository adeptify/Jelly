import AppKit
import Foundation
import WorkspaceDomain

@MainActor
final class TaskBlockCheckboxOverlay: NSView {
    private weak var session: BlockEditorSession?
    private weak var textView: ContinuousBlockEditorTextView?
    private var buttons: [BlockID: TaskBlockCheckboxButton] = [:]

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for button in buttons.values where button.frame.contains(point) { return button }
        return nil
    }

    func apply(
        document: BlockDocument,
        textView: ContinuousBlockEditorTextView,
        updateFramesImmediately: Bool = true
    ) {
        session = textView.attachedSession
        self.textView = textView
        let tasks = document.blocks.filter { $0.kind == .task }
        let taskIDs = Set(tasks.map(\.id))
        for (blockID, button) in buttons where !taskIDs.contains(blockID) {
            button.removeFromSuperview()
            buttons[blockID] = nil
        }
        for task in tasks {
            let button = buttons[task.id] ?? makeButton(blockID: task.id)
            configure(button, completed: task.taskState?.completedAt != nil)
        }
        if updateFramesImmediately { updateFrames() }
    }

    func updateFrames() {
        guard let textView else { return }
        for (blockID, button) in buttons {
            button.frame = textView.taskCheckboxFrame(for: blockID) ?? .zero
            button.isHidden = button.frame.isEmpty
        }
    }

    private func makeButton(blockID: BlockID) -> TaskBlockCheckboxButton {
        let button = TaskBlockCheckboxButton(blockID: blockID)
        button.setButtonType(.switch)
        button.title = ""
        button.target = self
        button.action = #selector(toggleTask(_:))
        button.controlSize = .small
        addSubview(button)
        buttons[blockID] = button
        return button
    }

    private func configure(_ button: TaskBlockCheckboxButton, completed: Bool) {
        button.state = completed ? .on : .off
        button.setAccessibilityRole(.checkBox)
        button.setAccessibilityLabel(completed ? "重开待办" : "完成待办")
        button.setAccessibilityValue(completed ? "已完成" : "未完成")
        button.setAccessibilityIdentifier("task-block-checkbox-\(button.blockID.rawValue.uuidString)")
    }

    @objc private func toggleTask(_ sender: TaskBlockCheckboxButton) {
        guard let session else { return }
        session.performAuxiliaryControlAction {
            _ = session.toggleTaskCompletion(blockID: sender.blockID, at: Date())
        }
    }
}

@MainActor
private final class TaskBlockCheckboxButton: NSButton {
    let blockID: BlockID

    init(blockID: BlockID) {
        self.blockID = blockID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
}

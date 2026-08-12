import AppKit
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("TaskBlockCompletionPresentationTests")
struct TaskBlockCompletionPresentationTests {
    @Test @MainActor func continuousEditorExposesOneSemanticCheckboxPerTaskAndNoneForParagraphs() throws {
        _ = NSApplication.shared
        let firstID = BlockID()
        let paragraphID = BlockID()
        let completedID = BlockID()
        let completedAt = Date(timeIntervalSince1970: 1_755_000_200)
        let blocks: [DocumentBlock] = [
            try .task(id: firstID, text: "未完成"),
            .init(
                id: paragraphID,
                kind: .paragraph,
                inlineContent: .plain("普通正文"),
                taskState: nil,
                indentLevel: 0
            ),
            try .task(id: completedID, text: "已完成", completedAt: completedAt)
        ]
        var publications: [BlockDocument] = []
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: blocks),
            initialSelection: taskPresentationCaret(firstID, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { publications.append($0) }
        )
        let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
        host.frame = .init(x: 0, y: 0, width: 520, height: 180)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        session.attach(host: host, hostToken: UUID())
        host.layoutSubtreeIfNeeded()

        let buttons = taskPresentationDescendants(of: host, as: NSButton.self).filter {
            $0.accessibilityIdentifier().hasPrefix("task-block-checkbox-")
        }
        #expect(buttons.count == 2)
        let first = try #require(buttons.first {
            $0.accessibilityIdentifier() == "task-block-checkbox-\(firstID.rawValue.uuidString)"
        })
        let completed = try #require(buttons.first {
            $0.accessibilityIdentifier() == "task-block-checkbox-\(completedID.rawValue.uuidString)"
        })
        #expect(first.accessibilityLabel() == "完成待办")
        #expect(first.accessibilityValue() as? String == "未完成")
        #expect(completed.accessibilityLabel() == "重开待办")
        #expect(completed.accessibilityValue() as? String == "已完成")
        #expect(buttons.allSatisfy {
            !$0.accessibilityIdentifier().contains(paragraphID.rawValue.uuidString)
        })
        let completedLocation = try #require(
            BlockDocumentTextProjection(document: session.document, appearance: CalendarTheme.light)
                .segments.first { $0.blockID == completedID }?.contentRange.location
        )
        #expect(host.textView.textStorage?.attribute(
            .strikethroughStyle,
            at: completedLocation,
            effectiveRange: nil
        ) != nil)

        #expect(window.makeFirstResponder(first))
        first.performClick(first)
        #expect(session.document.blocks.first { $0.id == firstID }?.taskState?.completedAt != nil)
        #expect(publications.count == 1)
        #expect(window.firstResponder === host.textView)
        window.orderOut(nil)
    }

    @Test func removingALinkedTaskRequiresAChoiceButOrdinaryBlocksDoNot() throws {
        let noteID = NoteID()
        let linkedID = BlockID()
        let ordinaryID = BlockID()
        let before = BlockDocument(blocks: [
            try .task(id: linkedID, text: "已关联"),
            .init(
                id: ordinaryID,
                kind: .paragraph,
                inlineContent: .plain("普通正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let after = BlockDocument(blocks: [])
        let links: Set<TaskBlockCalendarLink> = [
            .init(noteID: noteID, blockID: linkedID, calendarItemID: UUID())
        ]

        #expect(TaskBlockDeletionConfirmation.requiredLinkedBlocks(
            noteID: noteID,
            before: before,
            after: after,
            links: links
        ) == [linkedID])
    }
}

private func taskPresentationCaret(_ blockID: BlockID, _ offset: Int) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: blockID, graphemeOffset: offset),
        focus: .init(blockID: blockID, graphemeOffset: offset),
        preferredColumn: nil,
        typingAttributes: .init(marks: [], linkURL: nil)
    )
}

@MainActor
private func taskPresentationDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { taskPresentationDescendants(of: $0, as: type) }
}

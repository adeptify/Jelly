import AppKit
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorVisualContractTests", .serialized)
@MainActor
struct BlockEditorVisualContractTests {
    @Test func emptyAndOrdinaryDocumentsUseOneUnframedContinuousSurface() {
        let empty = block(kind: .paragraph, text: "")
        let emptyFixture = fixture(blocks: [empty])
        #expect(emptyFixture.host.textView.isPresentingEmptyDocumentPlaceholder)
        #expect(descendants(of: emptyFixture.host, as: ContinuousBlockEditorTextView.self).count == 1)
        #expect(descendants(of: emptyFixture.host, as: BlockSelectionHandleView.self).isEmpty)
        #expect(descendants(of: emptyFixture.host.taskCheckboxOverlay, as: NSButton.self).isEmpty)
        #expect(emptyFixture.host.textView.drawsBackground == false)
        #expect(emptyFixture.host.textView.textContainerInset.width == 0)

        let ordinary = block(kind: .paragraph, text: "第一段")
        let second = block(kind: .paragraph, text: "第二段")
        let ordinaryFixture = fixture(blocks: [ordinary, second])
        #expect(ordinaryFixture.host.textView.isPresentingEmptyDocumentPlaceholder == false)
        #expect(descendants(of: ordinaryFixture.host, as: ContinuousBlockEditorTextView.self).count == 1)
        #expect(descendants(of: ordinaryFixture.host, as: BlockSelectionHandleView.self).isEmpty)
        #expect(descendants(of: ordinaryFixture.host.taskCheckboxOverlay, as: NSButton.self).isEmpty)
    }

    @Test func checkboxGutterExistsOnlyForTasksAndCarriesReadableState() throws {
        let paragraph = block(kind: .paragraph, text: "普通正文")
        let openTask = block(kind: .task, text: "未完成")
        let doneTask = DocumentBlock(
            id: BlockID(),
            kind: .task,
            inlineContent: .plain("已完成"),
            taskState: .init(completedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            indentLevel: 0
        )
        let editor = fixture(blocks: [paragraph, openTask, doneTask])
        let buttons = descendants(of: editor.host.taskCheckboxOverlay, as: NSButton.self)

        #expect(buttons.count == 2)
        #expect(Set(buttons.compactMap { $0.accessibilityRole() }) == [.checkBox])
        #expect(Set(buttons.compactMap { $0.accessibilityLabel() }) == ["完成待办", "重开待办"])
        #expect(Set(buttons.compactMap { $0.accessibilityValue() as? String }) == ["未完成", "已完成"])
        #expect(buttons.allSatisfy { $0.accessibilityIdentifier().hasPrefix("task-block-checkbox-") })
    }

    @Test func documentMeasureTypographyAndSemanticColorsMatchTheCalendarLanguage() {
        #expect(NoteEditorLayout.maximumContentWidth == 720)
        #expect(NoteEditorLayout.horizontalSafetyMargin == 28)
        #expect(NoteEditorLayout.bodyPointSize == 16)
        #expect(BlockTextStyle.baseFont(for: .paragraph).pointSize == 16)
        #expect(BlockTextStyle.paragraphStyle(for: .paragraph).lineHeightMultiple == 1.45)
        #expect(CalendarTheme.light.primaryTextContrast >= 4.5)
        #expect(CalendarTheme.light.secondaryTextContrast >= 4.5)
        #expect(CalendarTheme.dark.primaryTextContrast >= 4.5)
        #expect(CalendarTheme.dark.secondaryTextContrast >= 4.5)
    }

    private func fixture(
        blocks: [DocumentBlock]
    ) -> (session: BlockEditorSession, host: ContinuousBlockEditorHostView) {
        let first = blocks[0]
        let document = BlockDocument(blocks: blocks)
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: document,
            initialSelection: .text(
                anchor: .init(blockID: first.id, graphemeOffset: 0),
                focus: .init(blockID: first.id, graphemeOffset: 0),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            ),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
        host.frame = .init(x: 0, y: 0, width: 720, height: 240)
        session.attach(host: host, hostToken: UUID())
        host.layoutSubtreeIfNeeded()
        return (session, host)
    }

    private func block(kind: BlockKind, text: String) -> DocumentBlock {
        .init(
            id: BlockID(),
            kind: kind,
            inlineContent: .plain(text),
            taskState: kind == .task ? .init(completedAt: nil) : nil,
            indentLevel: 0
        )
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        let own = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(of: $0, as: type) }
    }
}

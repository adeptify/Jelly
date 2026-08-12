import AppKit
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorPerformanceTests", .serialized)
@MainActor
struct BlockEditorPerformanceTests {
    @Test(arguments: EditorPerformanceDataset.allCases)
    func reducerProjectionHostedAndOpenStayInsideTheRecordedGates(
        _ dataset: EditorPerformanceDataset
    ) throws {
        let fixture = try EditorPerformanceFixture(dataset: dataset)
        let reducer = try BlockEditorPerformanceProbe.measure {
            _ = try BlockInputReducer.reduce(
                fixture.document,
                selection: fixture.selection,
                command: .insertText("字"),
                environment: .init(isComposingText: false, idSource: .random)
            )
        }
        let projection = BlockEditorPerformanceProbe.measure {
            _ = BlockDocumentTextProjection(
                document: fixture.document,
                appearance: CalendarTheme.light
            )
        }
        let hosted = hostedDistribution(fixture: fixture)
        let settledLayout = settledLayoutDistribution(fixture: fixture)
        let open = BlockEditorPerformanceProbe.measure(warmups: 3, iterations: 20) {
            autoreleasepool {
                let session = BlockEditorSession(
                    noteID: NoteID(),
                    editSessionID: UUID(),
                    initialDocument: fixture.document,
                    initialSelection: fixture.selection,
                    focusRegistry: EditorFocusRegistry(),
                    onDocumentChange: { _ in }
                )
                let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
                host.frame = .init(x: 0, y: 0, width: 720, height: 80)
                session.attach(host: host, hostToken: UUID())
                host.layoutSubtreeIfNeeded()
                _ = host.textView.measuredContentHeight(for: 720)
            }
        }

        report(dataset, "reducer", reducer)
        report(dataset, "projection", projection)
        report(dataset, "key-visible", hosted)
        report(dataset, "settled-layout", settledLayout)
        report(dataset, "open", open)
        #expect(reducer.p95Milliseconds <= dataset.reducerP95, Comment(rawValue: failure("reducer", reducer, dataset.reducerP95)))
        #expect(projection.p95Milliseconds <= dataset.projectionP95, Comment(rawValue: failure("projection", projection, dataset.projectionP95)))
        #expect(hosted.p95Milliseconds <= dataset.keyVisibleP95, Comment(rawValue: failure("key-visible p95", hosted, dataset.keyVisibleP95)))
        #expect(hosted.maxMilliseconds <= dataset.keyVisibleMax, Comment(rawValue: failure("key-visible max", hosted, dataset.keyVisibleMax)))
        #expect(settledLayout.p95Milliseconds <= dataset.settledLayoutP95, Comment(rawValue: failure("settled-layout", settledLayout, dataset.settledLayoutP95)))
        #expect(open.p95Milliseconds <= dataset.openP95, Comment(rawValue: failure("open", open, dataset.openP95)))
    }

    @Test func twoHundredOrdinaryCharactersUseOnlyBoundedDiffs() throws {
        let fixture = try EditorPerformanceFixture(dataset: .long)
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
        session.attach(host: host, hostToken: UUID())
        let initialFull = host.textView.fullProjectionApplyCount

        for _ in 0..<200 {
            host.textView.insertText("x", replacementRange: .init(location: NSNotFound, length: 0))
        }

        #expect(host.textView.fullProjectionApplyCount == initialFull)
        #expect(host.textView.diffProjectionApplyCount == 200)
    }

    private func hostedDistribution(
        fixture: EditorPerformanceFixture
    ) -> BlockEditorPerformanceDistribution {
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
        host.frame = .init(x: 0, y: 0, width: 720, height: 80)
        session.attach(host: host, hostToken: UUID())
        return BlockEditorPerformanceProbe.measure {
            host.textView.insertText("x", replacementRange: .init(location: NSNotFound, length: 0))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func settledLayoutDistribution(
        fixture: EditorPerformanceFixture
    ) -> BlockEditorPerformanceDistribution {
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in }
        )
        let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
        host.frame = .init(x: 0, y: 0, width: 720, height: 80)
        session.attach(host: host, hostToken: UUID())
        return BlockEditorPerformanceProbe.measure {
            host.textView.insertText("x", replacementRange: .init(location: NSNotFound, length: 0))
            _ = host.textView.measuredContentHeight(for: 720)
        }
    }

    private func report(
        _ dataset: EditorPerformanceDataset,
        _ stage: String,
        _ distribution: BlockEditorPerformanceDistribution
    ) {
        print(String(
            format: "EDITOR_PERF|%@|%@|%.3f|%.3f",
            dataset.rawValue,
            stage,
            distribution.p95Milliseconds,
            distribution.maxMilliseconds
        ))
    }

    private func failure(
        _ stage: String,
        _ distribution: BlockEditorPerformanceDistribution,
        _ gate: Double
    ) -> String {
        let sorted = distribution.samplesMilliseconds.sorted()
        return "\(stage) 超标：p95=\(distribution.p95Milliseconds)ms max=\(distribution.maxMilliseconds)ms gate=\(gate)ms samples=\(sorted)"
    }
}

enum EditorPerformanceDataset: String, CaseIterable, Sendable {
    case daily
    case long
    case stress

    var blockCount: Int { self == .daily ? 20 : self == .long ? 200 : 500 }
    var characterCount: Int { self == .daily ? 2_000 : self == .long ? 20_000 : 50_000 }
    var reducerP95: Double { self == .daily ? 2 : self == .long ? 4 : 8 }
    var projectionP95: Double { self == .daily ? 8 : self == .long ? 12 : 16 }
    var keyVisibleP95: Double { self == .daily ? 33 : self == .long ? 50 : 75 }
    var keyVisibleMax: Double { self == .stress ? 150 : 100 }
    var settledLayoutP95: Double { self == .daily ? 33 : self == .long ? 75 : 150 }
    var openP95: Double { self == .daily ? 150 : self == .long ? 300 : 600 }
}

private struct EditorPerformanceFixture {
    let document: BlockDocument
    let selection: BlockEditorSelection

    init(dataset: EditorPerformanceDataset) throws {
        var blocks: [DocumentBlock] = []
        let unit = "中文 English 🙂 Jelly 流畅记录 "
        let perBlock = max(1, dataset.characterCount / dataset.blockCount)
        for index in 0..<dataset.blockCount {
            let id = BlockID(UUID(uuidString: String(
                format: "00000000-0000-0000-0004-%012d",
                index + 1
            ))!)
            let kind: BlockKind = switch index % 10 {
            case 1: .heading2
            case 2: .bullet
            case 3: .ordered
            case 4: .task
            case 5: .quote
            case 6: .code
            case 7: .heading3
            case 8: .divider
            default: .paragraph
            }
            let text = kind == .divider ? "" : String(
                String(repeating: unit, count: (perBlock / unit.count) + 1).prefix(perBlock)
            )
            blocks.append(.init(
                id: id,
                kind: kind,
                inlineContent: .plain(text),
                taskState: kind == .task ? .init(completedAt: index.isMultiple(of: 20) ? .distantPast : nil) : nil,
                indentLevel: 0,
                codeInfoString: kind == .code ? "swift" : nil
            ))
        }
        let document = BlockDocument(blocks: blocks)
        try BlockDocumentValidator.validate(document)
        self.document = document
        let first = blocks[0]
        selection = .text(
            anchor: .init(blockID: first.id, graphemeOffset: first.inlineContent.spans.map(\.text).joined().count),
            focus: .init(blockID: first.id, graphemeOffset: first.inlineContent.spans.map(\.text).joined().count),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
    }
}

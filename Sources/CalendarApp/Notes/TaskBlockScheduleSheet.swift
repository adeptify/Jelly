import CalendarDomain
import SwiftUI
import WorkspaceDomain

enum TaskBlockScheduleDefaults {
    static func day(now: Date, timeZone: TimeZone) -> CalendarDate {
        CalendarDate.localDay(containing: now, in: timeZone)
    }

    static func makeItem(
        id: UUID,
        note: Note,
        blockID: BlockID,
        selectedDate: Date,
        timeZone: TimeZone,
        createdAt: Date
    ) throws -> CalendarItem {
        guard let block = note.document.blocks.first(where: {
            $0.id == blockID && $0.kind == .task
        }) else {
            throw TaskBlockScheduleError.missingTaskBlock
        }
        return try CalendarItem(
            id: id,
            kind: .task,
            title: block.inlineContent.spans.map(\.text).joined(),
            categoryID: note.categoryID,
            schedule: try CalendarSchedule(
                startDate: day(now: selectedDate, timeZone: timeZone),
                endDate: day(now: selectedDate, timeZone: timeZone),
                startTime: nil,
                endTime: nil
            ),
            completedAt: block.taskState?.completedAt,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

enum TaskBlockScheduleError: Error, Equatable {
    case missingTaskBlock
}

struct TaskBlockScheduleSheet: View {
    let store: WorkspaceStore
    let noteID: NoteID
    let blockID: BlockID
    let prepareForMutation: () async -> Bool
    let onCancel: () -> Void
    let onScheduled: () -> Void
    private let timeZone: TimeZone

    @State private var selectedDate: Date
    @State private var error: String?

    init(
        store: WorkspaceStore,
        noteID: NoteID,
        blockID: BlockID,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent,
        prepareForMutation: @escaping () async -> Bool = { true },
        onCancel: @escaping () -> Void,
        onScheduled: @escaping () -> Void
    ) {
        self.store = store
        self.noteID = noteID
        self.blockID = blockID
        self.timeZone = timeZone
        self.prepareForMutation = prepareForMutation
        self.onCancel = onCancel
        self.onScheduled = onScheduled
        _selectedDate = State(initialValue: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安排这个待办")
                .font(.headline)
            if let title = taskTitle {
                Text(title.isEmpty ? "无标题待办" : title)
                    .font(.body)
                    .accessibilityLabel("待办标题，\(title.isEmpty ? "无标题" : title)")
            }
            EditorDateChip(date: $selectedDate)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("创建") { Task { await schedule() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.phase != .ready)
            }
        }
        .padding(16)
        .frame(minWidth: 320)
    }

    private var taskTitle: String? {
        store.state.notes[noteID]?.document.blocks.first(where: {
            $0.id == blockID && $0.kind == .task
        })?.inlineContent.spans.map(\.text).joined()
    }

    private func schedule() async {
        do {
            guard await prepareForMutation() else {
                error = "请先完成当前笔记的保存。"
                return
            }
            guard let note = store.state.notes[noteID] else {
                error = "笔记不存在。"
                return
            }
            let createdAt = Date.now
            let item = try TaskBlockScheduleDefaults.makeItem(
                id: UUID(),
                note: note,
                blockID: blockID,
                selectedDate: selectedDate,
                timeZone: timeZone,
                createdAt: createdAt
            )
            let outcome = try await store.sendWorkspace(
                .scheduleTaskBlock(.init(noteID: noteID, blockID: blockID, item: item)),
                undoLabel: "安排这个待办"
            )
            if case .committed = outcome {
                onScheduled()
            } else {
                error = "安排未完成。"
            }
        } catch {
            self.error = "安排失败。"
        }
    }
}

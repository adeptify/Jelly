import CalendarDomain
import SwiftUI
import WorkspaceDomain

enum TaskBlockScheduleDefaults {
    static func day(now: Date, timeZone: TimeZone) -> CalendarDate {
        CalendarDate.localDay(containing: now, in: timeZone)
    }
}

struct TaskBlockScheduleSheet: View {
    let store: WorkspaceStore
    let noteID: NoteID
    let blockID: BlockID
    let onCancel: () -> Void
    let onScheduled: () -> Void
    private let timeZone: TimeZone

    @State private var title = ""
    @State private var selectedDate: Date
    @State private var error: String?

    init(
        store: WorkspaceStore,
        noteID: NoteID,
        blockID: BlockID,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent,
        onCancel: @escaping () -> Void,
        onScheduled: @escaping () -> Void
    ) {
        self.store = store
        self.noteID = noteID
        self.blockID = blockID
        self.timeZone = timeZone
        self.onCancel = onCancel
        self.onScheduled = onScheduled
        _selectedDate = State(initialValue: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安排待办到日历")
                .font(.headline)
            TextField("事项标题", text: $title)
                .textFieldStyle(.roundedBorder)
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
        .onAppear {
            if let note = store.state.notes[noteID],
               let block = note.document.blocks.first(where: { $0.id == blockID }) {
                title = block.inlineContent.spans.map(\.text).joined()
            }
        }
    }

    private func schedule() async {
        do {
            guard let note = store.state.notes[noteID] else {
                error = "笔记不存在。"
                return
            }
            let item = try CalendarItem(
                id: UUID(),
                kind: .task,
                title: title.isEmpty ? "待办" : title,
                categoryID: note.categoryID,
                schedule: try CalendarSchedule(
                    startDate: TaskBlockScheduleDefaults.day(now: selectedDate, timeZone: timeZone),
                    endDate: TaskBlockScheduleDefaults.day(now: selectedDate, timeZone: timeZone),
                    startTime: nil,
                    endTime: nil
                ),
                completedAt: nil,
                createdAt: .now,
                updatedAt: .now
            )
            let outcome = try await store.sendWorkspace(
                .scheduleTaskBlock(.init(noteID: noteID, blockID: blockID, item: item)),
                undoLabel: "安排待办到日历"
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

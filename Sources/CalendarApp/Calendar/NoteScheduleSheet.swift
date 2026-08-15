import CalendarDomain
import SwiftUI
import WorkspaceDomain

enum NoteScheduleDefaults {
    static func day(now: Date, timeZone: TimeZone) -> CalendarDate {
        CalendarDate.localDay(containing: now, in: timeZone)
    }
}

struct NoteScheduleSheet: View {
    let store: WorkspaceStore
    let noteID: NoteID
    let onCancel: () -> Void
    let onScheduled: (UUID) -> Void
    private let timeZone: TimeZone
    private let clock: @Sendable () -> Date

    @State private var title: String = ""
    @State private var selectedDate: Date
    @State private var error: String?

    init(
        store: WorkspaceStore,
        noteID: NoteID,
        now: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone = .autoupdatingCurrent,
        onCancel: @escaping () -> Void,
        onScheduled: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.noteID = noteID
        self.onCancel = onCancel
        self.onScheduled = onScheduled
        self.timeZone = timeZone
        clock = now
        _selectedDate = State(initialValue: now())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安排这篇笔记")
                .font(.headline)
            Text("将创建一个全天事项，并把这篇笔记作为事项详情。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("事项标题", text: $title)
                .textFieldStyle(.roundedBorder)
            EditorDateChip(date: $selectedDate)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("创建") {
                    Task { await schedule() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.phase != .ready)
            }
        }
        .padding(16)
        .frame(minWidth: 320)
        .onAppear {
            title = store.state.notes[noteID]?.title ?? ""
        }
    }

    private func schedule() async {
        do {
            guard let note = store.state.notes[noteID] else {
                error = "笔记不存在。"
                return
            }
            let timestamp = clock()
            let item = try CalendarItem(
                id: UUID(),
                kind: .task,
                title: title.isEmpty ? (note.title.isEmpty ? "未命名" : note.title) : title,
                categoryID: note.categoryID,
                schedule: try CalendarSchedule(
                    startDate: NoteScheduleDefaults.day(now: selectedDate, timeZone: timeZone),
                    endDate: NoteScheduleDefaults.day(now: selectedDate, timeZone: timeZone),
                    startTime: nil,
                    endTime: nil
                ),
                completedAt: nil,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            let outcome = try await store.sendWorkspace(
                .scheduleNoteOnCalendar(.init(noteID: noteID, item: item)),
                undoLabel: "安排这篇笔记"
            )
            if case .committed = outcome {
                onScheduled(item.id)
            } else {
                error = "安排未完成。"
            }
        } catch {
            self.error = "安排失败。"
        }
    }
}

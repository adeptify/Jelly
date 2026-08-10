import CalendarDomain
import SwiftUI
import WorkspaceDomain

struct NoteScheduleSheet: View {
    let store: WorkspaceStore
    let noteID: NoteID
    let onCancel: () -> Void
    let onScheduled: () -> Void

    @State private var title: String = ""
    @State private var day = CalendarDate(year: 2026, month: 8, day: 11)!
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从笔记安排到日历")
                .font(.headline)
            TextField("事项标题", text: $title)
                .textFieldStyle(.roundedBorder)
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
            let item = try CalendarItem(
                id: UUID(),
                kind: .task,
                title: title.isEmpty ? (note.title.isEmpty ? "未命名" : note.title) : title,
                categoryID: note.categoryID,
                schedule: try CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: nil,
                    endTime: nil
                ),
                completedAt: nil,
                createdAt: .now,
                updatedAt: .now
            )
            let outcome = try await store.sendWorkspace(
                .scheduleNoteOnCalendar(.init(noteID: noteID, item: item)),
                undoLabel: "从笔记安排到日历"
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

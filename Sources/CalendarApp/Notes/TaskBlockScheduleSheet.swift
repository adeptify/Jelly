import CalendarDomain
import SwiftUI
import WorkspaceDomain

struct TaskBlockScheduleSheet: View {
    let store: WorkspaceStore
    let noteID: NoteID
    let blockID: BlockID
    let onCancel: () -> Void
    let onScheduled: () -> Void

    @State private var title = ""
    @State private var day = CalendarDate(year: 2026, month: 8, day: 11)!
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("安排待办到日历")
                .font(.headline)
            TextField("事项标题", text: $title)
                .textFieldStyle(.roundedBorder)
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
                schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
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

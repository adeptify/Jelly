import CalendarDomain
import SwiftUI
import WorkspaceDomain

/// Inline, unobtrusive calendar badge for a linked Task Block.
struct TaskBlockCalendarBadge: View {
    let store: WorkspaceStore
    let noteID: NoteID
    let blockID: BlockID
    var onSchedule: () -> Void
    var onUnlink: () -> Void
    var onOpenItem: (UUID) -> Void
    var onToggleCompletion: () -> Void

    private var link: TaskBlockCalendarLink? {
        store.state.taskBlockLinks.first { $0.noteID == noteID && $0.blockID == blockID }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let link, let item = store.calendarState.items[link.calendarItemID] {
                Button {
                    onOpenItem(link.calendarItemID)
                } label: {
                    Label(dateLabel(item), systemImage: "calendar")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("已关联日历事项")

                Button(item.completedAt == nil ? "完成" : "重开") {
                    onToggleCompletion()
                }
                .controlSize(.mini)

                Button("取消关联", role: .destructive, action: onUnlink)
                    .controlSize(.mini)
            } else {
                Button("安排到日历", action: onSchedule)
                    .controlSize(.mini)
                    .accessibilityLabel("安排待办到日历")
            }
        }
    }

    private func dateLabel(_ item: CalendarItem) -> String {
        let d = item.schedule.startDate
        return String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
    }
}

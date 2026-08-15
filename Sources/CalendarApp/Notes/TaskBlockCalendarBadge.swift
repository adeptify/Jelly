import AppKit
import CalendarDomain
import SwiftUI
import WorkspaceDomain

@MainActor
struct TaskBlockCalendarContext {
    let store: WorkspaceStore
    let now: @Sendable () -> Date
    let prepareForMutation: () async -> Bool
    let didCommitMutation: () -> Void
    let onOpenItem: (UUID) -> Void

    init(
        store: WorkspaceStore,
        now: @escaping @Sendable () -> Date = Date.init,
        prepareForMutation: @escaping () async -> Bool = { true },
        didCommitMutation: @escaping () -> Void = {},
        onOpenItem: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.now = now
        self.prepareForMutation = prepareForMutation
        self.didCommitMutation = didCommitMutation
        self.onOpenItem = onOpenItem
    }
}

/// Inline, unobtrusive calendar badge for a linked Task Block.
struct TaskBlockCalendarBadge: View {
    let store: WorkspaceStore
    let noteID: NoteID
    let blockID: BlockID
    var onSchedule: () -> Void
    var onUnlink: () -> Void
    var onOpenItem: (UUID) -> Void

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

                TaskBlockUnlinkButton(action: onUnlink)
                    .frame(width: 118, height: 22)
            } else {
                TaskBlockScheduleButton(action: onSchedule)
                    .frame(width: 112, height: 22)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func dateLabel(_ item: CalendarItem) -> String {
        let d = item.schedule.startDate
        return String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
    }
}

private struct TaskBlockUnlinkButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "解除任务联动",
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .roundRect
        button.controlSize = .mini
        button.contentTintColor = .systemRed
        button.setAccessibilityLabel("解除任务联动")
        button.setAccessibilityIdentifier("task-block-unlink-calendar")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = "解除任务联动"
        button.setAccessibilityLabel("解除任务联动")
        button.setAccessibilityIdentifier("task-block-unlink-calendar")
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() { action() }
    }
}

private struct TaskBlockScheduleButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "安排这个待办",
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .roundRect
        button.controlSize = .mini
        button.setAccessibilityLabel("安排待办到日历")
        button.setAccessibilityIdentifier("task-block-schedule-calendar")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityLabel("安排待办到日历")
        button.setAccessibilityIdentifier("task-block-schedule-calendar")
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() { action() }
    }
}

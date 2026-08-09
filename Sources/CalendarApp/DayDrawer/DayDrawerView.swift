import CalendarDomain
import SwiftUI

struct DayDrawerView: View {
    let date: CalendarDate
    let store: WorkspaceStore
    let categories: [UUID: CalendarCategory]
    let hiddenCategoryIDs: Set<UUID>
    let onClose: () -> Void
    let onQuickCreate: (CalendarDate) -> Void
    let onOpenDetail: (ProjectedItem) -> Void
    var onDelete: ((ProjectedItem) -> Void)?
    @StateObject private var model: DayDrawerViewModel

    init(
        date: CalendarDate,
        store: WorkspaceStore,
        categories: [UUID: CalendarCategory],
        hiddenCategoryIDs: Set<UUID>,
        onClose: @escaping () -> Void,
        onQuickCreate: @escaping (CalendarDate) -> Void,
        onOpenDetail: @escaping (ProjectedItem) -> Void,
        onDelete: ((ProjectedItem) -> Void)? = nil
    ) {
        self.date = date
        self.store = store
        self.categories = categories
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.onClose = onClose
        self.onQuickCreate = onQuickCreate
        self.onOpenDetail = onOpenDetail
        self.onDelete = onDelete
        _model = StateObject(wrappedValue: DayDrawerViewModel(
            date: date,
            state: store.calendarState,
            hiddenCategoryIDs: hiddenCategoryIDs
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.date.month)月\(model.date.day)日")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            if model.items.isEmpty {
                ContentUnavailableView("当天没有事项", systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.items) { item in
                            CalendarItemRow(
                                item: item,
                                category: categories[item.categoryID],
                                onCompletion: sendCompletion,
                                onOpenDetail: onOpenDetail,
                                onDelete: { onDelete?(item) },
                                allowsSwipeToDelete: CalendarItemRowPlacement.dayDrawer.allowsSwipeToDelete
                            )
                        }
                    }
                }
            }

            Button("新建事项") {
                onQuickCreate(model.quickCreateDate)
            }
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(16)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1)
        }
        .onChange(of: store.calendarState) { _, state in
            model.refresh(state: state, hiddenCategoryIDs: hiddenCategoryIDs)
        }
        .onChange(of: date) { _, date in
            model.retarget(date: date, state: store.calendarState, hiddenCategoryIDs: hiddenCategoryIDs)
        }
        .onChange(of: hiddenCategoryIDs) { _, hidden in
            model.refresh(state: store.calendarState, hiddenCategoryIDs: hidden)
        }
    }

    private func sendCompletion(_ command: CalendarCommand) {
        guard store.phase == .ready else { return }
        Task {
            try? await store.sendCalendar(command, undoLabel: "已更新完成状态")
        }
    }
}

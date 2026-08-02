import CalendarDomain
import SwiftUI

struct DayDrawerView: View {
    let store: CalendarStore
    let categories: [UUID: CalendarCategory]
    let hiddenCategoryIDs: Set<UUID>
    let onClose: () -> Void
    let onQuickCreate: (CalendarDate) -> Void
    let onOpenDetail: (ProjectedItem) -> Void
    @StateObject private var model: DayDrawerViewModel

    init(
        date: CalendarDate,
        store: CalendarStore,
        categories: [UUID: CalendarCategory],
        hiddenCategoryIDs: Set<UUID>,
        onClose: @escaping () -> Void,
        onQuickCreate: @escaping (CalendarDate) -> Void,
        onOpenDetail: @escaping (ProjectedItem) -> Void
    ) {
        self.store = store
        self.categories = categories
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.onClose = onClose
        self.onQuickCreate = onQuickCreate
        self.onOpenDetail = onOpenDetail
        _model = StateObject(wrappedValue: DayDrawerViewModel(
            date: date,
            state: store.state,
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
                                onOpenDetail: onOpenDetail
                            )
                        }
                    }
                }
            }

            Button("新建事项") {
                onQuickCreate(model.date)
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
        .onChange(of: store.state) { _, state in
            model.refresh(state: state, hiddenCategoryIDs: hiddenCategoryIDs)
        }
        .onChange(of: hiddenCategoryIDs) { _, hidden in
            model.refresh(state: store.state, hiddenCategoryIDs: hidden)
        }
    }

    private func sendCompletion(_ command: CalendarCommand) {
        guard store.phase == .ready else { return }
        Task {
            try? await store.send(command, undoLabel: "已更新完成状态")
        }
    }
}

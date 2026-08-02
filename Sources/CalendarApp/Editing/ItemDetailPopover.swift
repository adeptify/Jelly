import CalendarDomain
import SwiftUI

struct ItemDetailPopover: View {
    let item: ProjectedItem
    let store: CalendarStore
    let categories: [CalendarCategory]
    let onClose: () -> Void
    @State private var pendingAction: DetailAction?
    @State private var editorConfiguration: EditorConfiguration?
    @State private var deleteConfirmationShown = false
    @State private var localError: String?

    var body: some View {
        Group {
            if let editorConfiguration {
                ItemEditForm(
                    configuration: editorConfiguration,
                    store: store,
                    categories: categories,
                    onCancel: { self.editorConfiguration = nil },
                    onSaved: onClose
                )
            } else {
                detailContent
            }
        }
        .frame(width: 370)
        .confirmationDialog("选择应用范围", isPresented: scopeConfirmationBinding, titleVisibility: .visible) {
            Button("仅本次") { apply(scope: .onlyThis) }
            Button("本次及以后") { apply(scope: .thisAndFuture) }
            Button("取消", role: .cancel) { pendingAction = nil }
        }
        .confirmationDialog("删除此事项？", isPresented: $deleteConfirmationShown, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteOneOff() }
            Button("取消", role: .cancel) {}
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.title)
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            Text(item.kind == .task ? "待办" : "日程")
                .foregroundStyle(.secondary)
            Text(item.timeRange.map { "\(Self.timeString($0.start))–\(Self.timeString($0.end))" } ?? "全天")
                .foregroundStyle(.secondary)
            if let message = localError {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("编辑") { begin(.edit) }
                    .disabled(store.phase != .ready)
                Button("删除", role: .destructive) { begin(.delete) }
                    .disabled(store.phase != .ready)
                Spacer()
            }
        }
        .padding(18)
    }

    private var scopeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingAction != nil && isRecurring },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private var isRecurring: Bool {
        if case .occurrence = item { true } else { false }
    }

    private func begin(_ action: DetailAction) {
        localError = nil
        guard isRecurring else {
            if action == .edit {
                editorConfiguration = .oneOff(item: oneOffItem)
            } else {
                deleteConfirmationShown = true
            }
            return
        }
        pendingAction = action
    }

    private func apply(scope: SeriesScope) {
        guard let action = pendingAction,
              case let .occurrence(occurrence) = item,
              let series = store.state.recurrence.series[occurrence.key.seriesID]
        else {
            localError = "找不到重复事项"
            pendingAction = nil
            return
        }
        pendingAction = nil
        switch action {
        case .edit:
            editorConfiguration = .occurrence(
                series: series,
                occurrence: occurrence,
                scope: scope
            )
        case .delete:
            let mode = ItemEditorMode.editOccurrence(series: series, key: occurrence.key, scope: scope)
            let draft = ItemDraft(occurrence: occurrence, series: series)
            let vm = ItemEditorViewModel(mode: mode, draft: draft)
            do {
                let command = try vm.makeDeleteCommand(newSeriesID: UUID())
                sendDelete(command)
            } catch {
                localError = vm.validationMessage ?? "无法删除事项"
            }
        }
    }

    private func deleteOneOff() {
        let vm = ItemEditorViewModel(mode: .editItem(oneOffItem), draft: ItemDraft(item: oneOffItem))
        do {
            sendDelete(try vm.makeDeleteCommand(newSeriesID: UUID()))
        } catch {
            localError = vm.validationMessage ?? "无法删除事项"
        }
    }

    private func sendDelete(_ command: CalendarCommand) {
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        Task {
            do {
                try await store.send(command, undoLabel: "已删除事项")
                onClose()
            } catch {
                localError = store.mutationError ?? "删除失败，请重试"
            }
        }
    }

    private var oneOffItem: CalendarItem {
        guard case let .item(item) = item else {
            preconditionFailure("A recurring item cannot use a one-off action.")
        }
        return item
    }

    private static func timeString(_ minute: MinuteOfDay) -> String {
        String(format: "%02d:%02d", minute.value / 60, minute.value % 60)
    }
}

private enum DetailAction {
    case edit
    case delete
}

private enum EditorConfiguration: Identifiable {
    case oneOff(item: CalendarItem)
    case occurrence(series: WeeklySeries, occurrence: CalendarOccurrence, scope: SeriesScope)

    var id: String {
        switch self {
        case let .oneOff(item): "item-\(item.id.uuidString)"
        case let .occurrence(_, occurrence, scope): "occurrence-\(occurrence.id.seriesID.uuidString)-\(scope)"
        }
    }

    var mode: ItemEditorMode {
        switch self {
        case let .oneOff(item): .editItem(item)
        case let .occurrence(series, occurrence, scope):
            .editOccurrence(series: series, key: occurrence.key, scope: scope)
        }
    }

    var draft: ItemDraft {
        switch self {
        case let .oneOff(item): ItemDraft(item: item)
        case let .occurrence(series, occurrence, _): ItemDraft(occurrence: occurrence, series: series)
        }
    }

    var canEditRule: Bool {
        if case let .occurrence(_, _, scope) = self {
            return scope == .thisAndFuture
        }
        return false
    }
}

private struct ItemEditForm: View {
    let configuration: EditorConfiguration
    let store: CalendarStore
    let categories: [CalendarCategory]
    let onCancel: () -> Void
    let onSaved: () -> Void
    @FocusState private var titleFocused: Bool
    @StateObject private var model: ItemEditorViewModel
    @State private var localError: String?

    init(
        configuration: EditorConfiguration,
        store: CalendarStore,
        categories: [CalendarCategory],
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.store = store
        self.categories = categories
        self.onCancel = onCancel
        self.onSaved = onSaved
        _model = StateObject(wrappedValue: ItemEditorViewModel(
            mode: configuration.mode,
            draft: configuration.draft
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑事项").font(.headline)
            TextField("标题", text: $model.draft.title).focused($titleFocused)
            Picker("类型", selection: $model.draft.kind) {
                Text("待办").tag(ItemKind.task)
                Text("日程").tag(ItemKind.event)
            }
            .pickerStyle(.segmented)
            Picker("分类", selection: $model.draft.categoryID) {
                ForEach(categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
            DatePicker("日期", selection: dateBinding, displayedComponents: .date)
            Toggle("具体时间", isOn: $model.draft.usesTime)
            if model.draft.usesTime {
                HStack {
                    DatePicker("开始", selection: startBinding, displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: endBinding, displayedComponents: .hourAndMinute)
                }
            }
            if configuration.canEditRule {
                weekdayPicker
                Toggle("设置结束日期", isOn: recurrenceEndEnabledBinding)
                if model.draft.recurrenceEndDate != nil {
                    DatePicker("结束日期", selection: recurrenceEndBinding, displayedComponents: .date)
                }
            }
            if let message = localError ?? model.validationMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.escape, modifiers: [])
                Button("保存", action: save)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(store.phase != .ready)
            }
        }
        .padding(18)
        .onAppear { titleFocused = true }
        .onKeyPress(.return) { save(); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            ForEach(Weekday.allCases, id: \.self) { weekday in
                Button(["一", "二", "三", "四", "五", "六", "日"][weekday.rawValue - 1]) {
                    if model.draft.weekdays.contains(weekday) {
                        model.draft.weekdays.remove(weekday)
                    } else {
                        model.draft.weekdays.insert(weekday)
                    }
                }
                .buttonStyle(.bordered)
                .tint(model.draft.weekdays.contains(weekday) ? .accentColor : .gray)
            }
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { model.draft.date.editorDate }, set: { model.draft.date = .editorDate(containing: $0) })
    }

    private var startBinding: Binding<Date> {
        Binding(get: { model.draft.start.editorDate }, set: { model.draft.start = .editorMinute(containing: $0) })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { model.draft.end.editorDate }, set: { model.draft.end = .editorMinute(containing: $0) })
    }

    private var recurrenceEndEnabledBinding: Binding<Bool> {
        Binding(get: { model.draft.recurrenceEndDate != nil }, set: {
            model.draft.recurrenceEndDate = $0 ? model.draft.date : nil
        })
    }

    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { (model.draft.recurrenceEndDate ?? model.draft.date).editorDate },
            set: { model.draft.recurrenceEndDate = .editorDate(containing: $0) }
        )
    }

    private func save() {
        localError = nil
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        let command: CalendarCommand
        do {
            command = try model.makeCommand(
                now: Date(),
                newItemID: UUID(),
                newSeriesID: UUID(),
                timeZoneIdentifier: TimeZone.current.identifier
            )
        } catch {
            localError = model.validationMessage ?? "无法保存事项"
            return
        }
        Task {
            do {
                try await store.send(command, undoLabel: "已更新事项")
                onSaved()
            } catch {
                localError = store.mutationError ?? "保存失败，请重试"
            }
        }
    }
}

import CalendarDomain
import SwiftUI

struct ItemDetailPopover: View {
    let item: ProjectedItem
    let store: WorkspaceStore
    let categories: [CalendarCategory]
    let onClose: () -> Void
    @State private var pendingAction: DetailAction?
    @State private var editorConfiguration: ItemEditorConfiguration?
    @State private var deleteConfirmationShown = false
    @State private var localError: String?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

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
        .frame(width: ItemEditForm.preferredWidth)
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
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
            Text(item.schedule.startTime == nil ? "全天事项" : "定时事项")
                .foregroundStyle(theme.secondaryText)
            Text("\(Self.dateString(item.schedule.startDate)) 至 \(Self.dateString(item.schedule.endDate))")
                .foregroundStyle(theme.secondaryText)
            if let startTime = item.schedule.startTime,
               let endTime = item.schedule.endTime {
                Text("\(Self.timeString(startTime))–\(Self.timeString(endTime))")
                    .foregroundStyle(theme.secondaryText)
            } else {
                Text("全天")
                    .foregroundStyle(theme.secondaryText)
            }
            if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("随记")
                        .font(EditorFormStyle.label)
                        .foregroundStyle(theme.secondaryText)
                    MarkdownNotesPreview(markdown: item.notes)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.subtleBorder.opacity(0.16))
                )
            }
            if let message = localError {
                Text(message).font(.footnote).foregroundStyle(theme.error)
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
              let series = store.calendarState.recurrence.series[occurrence.key.seriesID]
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
                _ = try await store.sendCalendar(command, undoLabel: "已删除事项")
                onClose()
            } catch {
                localError = "删除失败，请重试"
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

    private static func dateString(_ date: CalendarDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
}

private enum DetailAction {
    case edit
    case delete
}

enum ItemEditorConfiguration: Identifiable {
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

struct ItemEditForm: View {
    /// Compact editor card — calendar-tool density, not form-wizard spacing.
    nonisolated static let preferredWidth: CGFloat = 360

    let configuration: ItemEditorConfiguration
    let store: WorkspaceStore
    let categories: [CalendarCategory]
    let onCancel: () -> Void
    let onSaved: () -> Void
    @FocusState private var titleFocused: Bool
    @StateObject private var model: ItemEditorViewModel
    @State private var categoryOption: String
    @State private var localError: String?
    @State private var deleteConfirmationShown = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openCategoryManager) private var openCategoryManager

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    init(
        configuration: ItemEditorConfiguration,
        store: WorkspaceStore,
        categories: [CalendarCategory],
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.store = store
        self.categories = categories
        self.onCancel = onCancel
        self.onSaved = onSaved
        let draft = configuration.draft
        _model = StateObject(wrappedValue: ItemEditorViewModel(
            mode: configuration.mode,
            draft: draft
        ))
        _categoryOption = State(initialValue: draft.categoryID.uuidString)
    }

    var body: some View {
        // No ScrollView: it was expanding to maxHeight and leaving huge empty bands.
        VStack(spacing: 0) {
            header
            thinRule
            VStack(alignment: .leading, spacing: EditorFormStyle.contentSpacing) {
                titleField
                metaBlock
                scheduleBlock
                if configuration.canEditRule {
                    recurrenceBlock
                }
                MarkdownNotesEditor(text: $model.draft.notes)
                if let message = localError ?? model.validationMessage {
                    Text(message)
                        .font(EditorFormStyle.caption)
                        .foregroundStyle(theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            thinRule
            footer
        }
        .frame(width: Self.preferredWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .onAppear { titleFocused = true }
        .onChange(of: model.draft.categoryID) { _, id in
            categoryOption = id.uuidString
        }
        // Return inserts a newline in 随记; save via ⌘↩ or the button.
        .onKeyPress(.return) {
            guard titleFocused else { return .ignored }
            save()
            return .handled
        }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .confirmationDialog("删除此事项？", isPresented: $deleteConfirmationShown, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteItem)
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Text("编辑事项")
                .font(EditorFormStyle.title)
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .background(theme.subtleBorder.opacity(0.35), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("删除", role: .destructive) {
                deleteConfirmationShown = true
            }
            .controlSize(.small)
            .disabled(store.phase != .ready)
            Spacer(minLength: 0)
            Button("取消", action: onCancel)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
            Button("保存", action: save)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(store.phase != .ready)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var thinRule: some View {
        Rectangle()
            .fill(theme.separator.opacity(0.55))
            .frame(height: 1)
    }

    // MARK: - Content

    private var titleField: some View {
        TextField("标题", text: $model.draft.title)
            .textFieldStyle(.roundedBorder)
            .font(EditorFormStyle.body)
            .focused($titleFocused)
    }

    /// Category + priority as one distinct block.
    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: EditorFormStyle.blockSpacing) {
            fieldRow("分类") {
                categoryMenu
            }

            fieldRow("优先级") {
                EditorPriorityPicker(priority: priorityBinding)
                Spacer(minLength: 0)
            }
        }
        .padding(EditorFormStyle.blockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    /// macOS menus strip SwiftUI colors from SF Symbols; bake category color into NSImage.
    private var categoryMenu: some View {
        let selectedHex = selectedCategory?.colorHex ?? "#8C8F96"
        return Menu {
            ForEach(categories) { category in
                Button {
                    selectCategory(category.id)
                } label: {
                    // Name left, category-colored tag on the right.
                    Text(category.name)
                    CalendarTheme.categoryTagDotImage(category.colorHex, appearance: appearance)
                    if category.id == model.draft.categoryID {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            Button("新建分类…") {
                openCategoryManager.callAsFunction()
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedCategory?.name ?? "未分类")
                    .font(EditorFormStyle.control)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Circle()
                    .fill(CalendarTheme.categoryTagColor(selectedHex, appearance: appearance))
                    .frame(width: 8, height: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(EditorFormStyle.chevron)
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                theme.subtleBorder.opacity(0.28),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.subtleBorder.opacity(0.55), lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var selectedCategory: CalendarCategory? {
        categories.first { $0.id == model.draft.categoryID }
            ?? categories.first { $0.id.uuidString == categoryOption }
    }

    private func selectCategory(_ id: UUID) {
        categoryOption = id.uuidString
        model.draft.categoryID = id
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: EditorFormStyle.blockSpacing) {
            // 全天 / 定时 — short chips, no long checkbox copy
            HStack(spacing: 0) {
                timeModeChip(title: "全天", selected: !model.draft.usesTime) {
                    if model.draft.usesTime {
                        model.draft.usesTime = false
                    }
                }
                timeModeChip(title: "定时", selected: model.draft.usesTime) {
                    if !model.draft.usesTime {
                        model.draft.usesTime = true
                        model.usesTimeDidChange()
                    }
                }
            }
            .padding(2)
            .background(
                theme.subtleBorder.opacity(0.22),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )

            fieldRow("开始") {
                EditorDateChip(date: startDateBinding)
                if model.draft.usesTime {
                    EditorTimeChip(date: startTimeBinding)
                        .help("开始时间")
                }
                Spacer(minLength: 0)
            }

            fieldRow("结束") {
                EditorDateChip(date: endDateBinding)
                if model.draft.usesTime {
                    EditorTimeChip(date: endTimeBinding)
                        .help("结束时间；跨日可到次日 00:00")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(EditorFormStyle.blockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private func timeModeChip(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(EditorFormStyle.segment(selected: selected))
                .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.elevatedSurface)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recurrenceBlock: some View {
        VStack(alignment: .leading, spacing: EditorFormStyle.blockSpacing) {
            Text("重复")
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)
            weekdayPicker
            Toggle(isOn: recurrenceEndEnabledBinding) {
                Text("设置结束日期")
                    .font(EditorFormStyle.control)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            if model.draft.recurrenceEndDate != nil {
                fieldRow("直到") {
                    EditorDateChip(date: recurrenceEndBinding)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(EditorFormStyle.blockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private var fieldBlockBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.subtleBorder.opacity(0.16))
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)
                .frame(width: EditorFormStyle.labelWidth, alignment: .leading)
            content()
        }
        .frame(minHeight: EditorFormStyle.fieldMinHeight)
    }

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            ForEach(Weekday.allCases, id: \.self) { weekday in
                let selected = model.draft.weekdays.contains(weekday)
                Button(["一", "二", "三", "四", "五", "六", "日"][weekday.rawValue - 1]) {
                    if selected {
                        model.draft.weekdays.remove(weekday)
                    } else {
                        model.draft.weekdays.insert(weekday)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(selected ? theme.controlAccent : theme.secondaryText)
            }
        }
    }

    // MARK: - Bindings & actions

    private var priorityBinding: Binding<ItemPriority> {
        Binding(
            get: { model.draft.priority },
            set: { model.draft.priority = $0 }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.startDate.editorDate },
            set: { model.draft.startDate = .editorDate(containing: $0) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.endDate.editorDate },
            set: { model.draft.endDate = .editorDate(containing: $0) }
        )
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: { model.draft.startTime.editorDate },
            set: { model.draft.startTime = .editorMinute(containing: $0) }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding(
            get: { model.draft.endTime.editorDate },
            set: { model.draft.endTime = .editorMinute(containing: $0) }
        )
    }

    private var recurrenceEndEnabledBinding: Binding<Bool> {
        Binding(get: { model.draft.recurrenceEndDate != nil }, set: {
            model.draft.recurrenceEndDate = $0 ? model.draft.startDate : nil
        })
    }

    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { (model.draft.recurrenceEndDate ?? model.draft.startDate).editorDate },
            set: { model.draft.recurrenceEndDate = .editorDate(containing: $0) }
        )
    }

    private func deleteItem() {
        localError = nil
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        let command: CalendarCommand
        do {
            command = try model.makeDeleteCommand(newSeriesID: UUID())
        } catch {
            localError = model.validationMessage ?? "无法删除事项"
            return
        }
        Task {
            do {
                _ = try await store.sendCalendar(command, undoLabel: "已删除事项")
                onSaved()
            } catch {
                localError = "删除失败，请重试"
            }
        }
    }

    private func save() {
        localError = nil
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        // Pin is retired as a product feature; always clear on save.
        model.draft.isPinned = false
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
                _ = try await store.sendCalendar(command, undoLabel: "已更新事项")
                onSaved()
            } catch {
                localError = "保存失败，请重试"
            }
        }
    }
}

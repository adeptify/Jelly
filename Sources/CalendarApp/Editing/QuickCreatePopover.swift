import CalendarDomain
import SwiftUI

struct QuickCreatePresentation: Equatable {
    let range: CalendarDateRange
    let anchorDate: CalendarDate

    init(range: CalendarDateRange, anchorDate: CalendarDate) {
        self.range = range
        self.anchorDate = anchorDate
    }

    init?(action: CalendarInteractionAction) {
        guard case let .openCreate(range, anchor) = action else { return nil }
        self.init(range: range, anchorDate: anchor)
    }

    func initialDraft(categoryID: UUID) -> ItemDraft {
        .newItem(from: range.start, through: range.end, categoryID: categoryID)
    }
}

struct QuickCreatePopover: View {
    static let cardSize = CGSize(width: 370, height: 460)

    let store: CalendarStore
    let categories: [CalendarCategory]
    let onClose: () -> Void
    @Environment(\.openWindow) private var openWindow
    @FocusState private var titleFocused: Bool
    @StateObject private var model: ItemEditorViewModel
    @State private var categoryOption: String
    @State private var localError: String?

    private static let categoryManagerOption = "__category_manager__"

    init(
        presentation: QuickCreatePresentation,
        categories: [CalendarCategory],
        store: CalendarStore,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.categories = categories
        self.onClose = onClose
        let categoryID = categories.first?.id ?? store.state.uncategorizedID
        let draft = presentation.initialDraft(categoryID: categoryID)
        _model = StateObject(wrappedValue: ItemEditorViewModel(mode: .create, draft: draft))
        _categoryOption = State(initialValue: categoryID.uuidString)
        _localError = State(initialValue: nil)
    }

    var body: some View {
        editorContent
            .padding(18)
            .frame(width: 370)
            .onAppear { titleFocused = true }
            .onKeyPress(.return) {
                save()
                return .handled
            }
            .onKeyPress(.escape) {
                onClose()
                return .handled
            }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建事项")
                .font(.headline)
            TextField("标题", text: $model.draft.title)
                .focused($titleFocused)
            Picker("类型", selection: $model.draft.kind) {
                Text("待办").tag(ItemKind.task)
                Text("日程").tag(ItemKind.event)
            }
            .pickerStyle(.segmented)

            Picker("分类", selection: $categoryOption) {
                ForEach(categories) { category in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(CalendarTheme.categoryColor(category.colorHex))
                            .frame(width: 8, height: 8)
                        Text(category.name)
                    }
                    .tag(category.id.uuidString)
                }
                Divider()
                Text("管理分类…").tag(Self.categoryManagerOption)
            }
            .onChange(of: categoryOption) { _, option in
                guard option == Self.categoryManagerOption else {
                    if let id = UUID(uuidString: option) {
                        model.draft.categoryID = id
                    }
                    return
                }
                openWindow(id: "category-manager")
                categoryOption = model.draft.categoryID.uuidString
            }

            Toggle("具体时间", isOn: $model.draft.usesTime)
            HStack {
                DatePicker("开始日期", selection: startDateBinding, displayedComponents: .date)
                if model.draft.usesTime {
                    DatePicker("开始时间", selection: startTimeBinding, displayedComponents: .hourAndMinute)
                }
            }
            HStack {
                DatePicker("结束日期", selection: endDateBinding, displayedComponents: .date)
                if model.draft.usesTime {
                    DatePicker("结束时间", selection: endTimeBinding, displayedComponents: .hourAndMinute)
                }
            }

            Toggle("每周重复", isOn: $model.draft.repeatsWeekly)
            if model.draft.repeatsWeekly {
                weekdayPicker
                Toggle("设置重复结束日期", isOn: recurrenceEndEnabledBinding)
                if model.draft.recurrenceEndDate != nil {
                    DatePicker("重复结束日期", selection: recurrenceEndBinding, displayedComponents: .date)
                }
            }

            if let message = localError ?? model.validationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: onClose)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存", action: save)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(store.phase != .ready)
            }
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 4) {
            ForEach(Weekday.allCases, id: \.self) { weekday in
                Button(Self.weekdayName(weekday)) {
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

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.startDate.editorDate },
            set: { model.draft.startDate = CalendarDate.editorDate(containing: $0) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.endDate.editorDate },
            set: { model.draft.endDate = CalendarDate.editorDate(containing: $0) }
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
        Binding(
            get: { model.draft.recurrenceEndDate != nil },
            set: { enabled in
                model.draft.recurrenceEndDate = enabled ? model.draft.startDate : nil
            }
        )
    }

    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { (model.draft.recurrenceEndDate ?? model.draft.startDate).editorDate },
            set: { model.draft.recurrenceEndDate = CalendarDate.editorDate(containing: $0) }
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
                try await store.send(command, undoLabel: "已创建事项")
                onClose()
            } catch {
                localError = store.mutationError ?? "保存失败，请重试"
            }
        }
    }

    private static func weekdayName(_ weekday: Weekday) -> String {
        ["一", "二", "三", "四", "五", "六", "日"][weekday.rawValue - 1]
    }
}

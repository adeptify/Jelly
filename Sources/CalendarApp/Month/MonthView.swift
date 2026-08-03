import CalendarDomain
import SwiftUI

enum MonthEmptyStateHintPolicy {
    static func shouldShow(phase: StorePhase, state: CalendarState) -> Bool {
        phase == .ready && state.items.isEmpty && state.recurrence.series.isEmpty
    }
}

struct MonthViewTodayRefreshPolicy {
    let now: () -> Date
    let calendar: Calendar

    static let calendarDayChangedNotification = Notification.Name.NSCalendarDayChanged

    var today: CalendarDate {
        CalendarDate.localDay(containing: now(), in: calendar.timeZone)
    }

    static func shouldRefresh(for scenePhase: ScenePhase) -> Bool {
        scenePhase == .active
    }

    static var live: MonthViewTodayRefreshPolicy {
        MonthViewTodayRefreshPolicy(now: Date.init, calendar: .autoupdatingCurrent)
    }
}

enum MonthViewTodayRefreshEvent {
    case calendarDayChanged
    case scenePhaseChanged(ScenePhase)
}

struct MonthViewTodayRefreshController {
    let policy: MonthViewTodayRefreshPolicy

    func handle(
        _ event: MonthViewTodayRefreshEvent,
        updateToday: (CalendarDate) -> Void
    ) {
        guard shouldRefresh(for: event) else { return }
        updateToday(policy.today)
    }

    private func shouldRefresh(for event: MonthViewTodayRefreshEvent) -> Bool {
        switch event {
        case .calendarDayChanged:
            true
        case let .scenePhaseChanged(scenePhase):
            MonthViewTodayRefreshPolicy.shouldRefresh(for: scenePhase)
        }
    }
}

struct MonthView: View {
    let store: CalendarStore
    private let todayRefreshPolicy: MonthViewTodayRefreshPolicy
    private let todayRefreshController: MonthViewTodayRefreshController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: MonthViewModel
    @StateObject private var dropCoordinator: CalendarDropCoordinator
    @AppStorage("calendar.hiddenCategoryIDs") private var storedHiddenCategoryIDs = ""
    @State private var hiddenCategoryIDs: Set<UUID> = []
    @State private var quickCreateDate: CalendarDate?
    @State private var selectedDayDrawerDate: CalendarDate?
    @State private var selectedItem: ProjectedItem?
    @State private var recurringDropPresentation = RecurringDropPresentationController()

    init(
        store: CalendarStore,
        todayRefreshPolicy: MonthViewTodayRefreshPolicy = .live
    ) {
        self.store = store
        self.todayRefreshPolicy = todayRefreshPolicy
        todayRefreshController = MonthViewTodayRefreshController(policy: todayRefreshPolicy)
        let today = todayRefreshPolicy.today
        _model = StateObject(wrappedValue: MonthViewModel(
            displayedMonth: today,
            state: store.state,
            hiddenCategoryIDs: [],
            today: today
        ))
        _dropCoordinator = StateObject(wrappedValue: CalendarDropCoordinator(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            weekdayHeader
            GeometryReader { proxy in
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                    spacing: 0
                ) {
                    ForEach(MonthGridBuilder.cells(containing: model.displayedMonth), id: \.self) { date in
                        dayCell(for: date, cellHeight: proxy.size.height / 6)
                        .frame(height: proxy.size.height / 6)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            hiddenCategoryIDs = CategoryFilterView.decode(storedHiddenCategoryIDs)
            refreshProjection()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: MonthViewTodayRefreshPolicy.calendarDayChangedNotification
        )) { _ in
            refreshToday(for: .calendarDayChanged)
        }
        .onChange(of: scenePhase) { _, newPhase in
            refreshToday(for: .scenePhaseChanged(newPhase))
        }
        .onChange(of: store.state) { _, _ in refreshProjection() }
        .onChange(of: hiddenCategoryIDs) { _, _ in refreshProjection() }
        .onChange(of: storedHiddenCategoryIDs) { _, encoded in
            hiddenCategoryIDs = CategoryFilterView.decode(encoded)
        }
        .onChange(of: dropCoordinator.pendingRecurringDrop) { _, pendingDrop in
            recurringDropPresentation.pendingDropDidChange(hasPendingDrop: pendingDrop != nil)
        }
        .popover(isPresented: quickCreatePresented) {
            if let date = quickCreateDate {
                QuickCreatePopover(
                    date: date,
                    categories: orderedCategories,
                    store: store,
                    onClose: { quickCreateDate = nil }
                )
            }
        }
        .popover(item: $selectedItem) { item in
            ItemDetailPopover(
                item: item,
                store: store,
                categories: orderedCategories,
                onClose: { selectedItem = nil }
            )
        }
        .confirmationDialog(
            "移动重复事项",
            isPresented: recurringDropConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("仅本次") { resolveRecurringDrop(scope: .onlyThis) }
            Button("本次及以后") { resolveRecurringDrop(scope: .thisAndFuture) }
            Button("取消", role: .cancel) {
                cancelRecurringDropConfirmation()
            }
        } message: {
            Text("请选择移动范围")
        }
        .overlay(alignment: .trailing) {
            if let date = selectedDayDrawerDate {
                DayDrawerView(
                    date: date,
                    store: store,
                    categories: store.state.categories,
                    hiddenCategoryIDs: hiddenCategoryIDs,
                    onClose: { selectedDayDrawerDate = nil },
                    onQuickCreate: { quickCreateDate = $0 },
                    onOpenDetail: { selectedItem = $0 }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .overlay(alignment: .bottom) {
            if let undoNotice = store.undoNotice {
                HStack(spacing: 10) {
                    Text(undoNotice)
                    Button("撤销") { undo() }
                        .disabled(!store.canUndo || store.isMutating)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .alert("日历提示", isPresented: alertPresented) {
            Button("知道了", role: .cancel) { store.dismissErrors() }
        } message: {
            Text(store.loadError ?? store.mutationError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monthTitle)
                    .font(CalendarTheme.monthTitleFont)
                if MonthEmptyStateHintPolicy.shouldShow(phase: store.phase, state: store.state) {
                    Text("点击日期开始创建")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.goToPreviousMonth() } label: {
                Image(systemName: "chevron.left")
            }
            .help("上个月")
            Button("今天") { model.goToToday(todayRefreshPolicy.today) }
            Button { model.goToNextMonth() } label: {
                Image(systemName: "chevron.right")
            }
            .help("下个月")
            Menu("分类") {
                CategoryFilterView(
                    categories: orderedCategories,
                    hiddenCategoryIDs: $hiddenCategoryIDs
                )
            }
            Button("管理分类") {
                openWindow(id: "category-manager")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: CalendarTheme.toolbarHeight)
        .disabled(store.phase != .ready)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                Text(weekday)
                    .font(CalendarTheme.dateFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: CalendarTheme.weekdayHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CalendarTheme.gridStroke).frame(height: 0.5)
        }
    }

    private var monthTitle: String {
        "\(model.displayedMonth.year)年\(model.displayedMonth.month)月"
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: {
                recurringDropPresentation.isErrorPresented
                    || store.loadError != nil
                    || (
                        store.mutationError != nil
                            && recurringDropPresentation.state != .resolving
                    )
            },
            set: { isPresented in
                guard !isPresented else { return }
                store.dismissErrors()
                _ = recurringDropPresentation.acknowledgeError(
                    hasPendingDrop: dropCoordinator.pendingRecurringDrop != nil
                )
            }
        )
    }

    private var recurringDropConfirmationPresented: Binding<Bool> {
        Binding(
            get: { recurringDropPresentation.isConfirmationPresented },
            set: { isPresented in
                guard !isPresented else { return }
                requestRecurringDropConfirmationDismissal()
            }
        )
    }

    private var quickCreatePresented: Binding<Bool> {
        Binding(
            get: { quickCreateDate != nil },
            set: { if !$0 { quickCreateDate = nil } }
        )
    }

    private var orderedCategories: [CalendarCategory] {
        store.state.categories.values.sorted {
            $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
        }
    }

    @ViewBuilder
    private func dayCell(for date: CalendarDate, cellHeight: CGFloat) -> some View {
        let cell = model.cell(for: date)
        let capacity = MonthLayout.itemCapacity(cellHeight: cellHeight)
        DayCellView(
            cell: cell,
            capacity: capacity,
            model: model,
            categories: store.state.categories,
            dropCoordinator: dropCoordinator,
            onAction: handle,
            onCompletion: sendCompletion
        )
    }

    private func handle(_ action: DayCellAction) {
        switch action {
        case let .openDay(date):
            model.selectedDate = date
            selectedDayDrawerDate = date
        case let .quickCreate(date):
            quickCreateDate = date
        case let .openItem(id):
            selectedItem = model.item(withID: id)
        }
    }

    private func sendCompletion(_ command: CalendarCommand) {
        guard store.phase == .ready else { return }
        Task {
            try? await store.send(command, undoLabel: "已更新完成状态")
        }
    }

    private func resolveRecurringDrop(scope: SeriesScope) {
        guard recurringDropPresentation.beginScopeSelection() else { return }
        guard let resolution = dropCoordinator.beginResolution(scope: scope) else {
            recurringDropPresentation.pendingDropDidChange(
                hasPendingDrop: dropCoordinator.pendingRecurringDrop != nil
            )
            return
        }
        Task {
            do {
                try await dropCoordinator.submit(resolution)
                recurringDropPresentation.resolutionSucceeded()
            } catch {
                recurringDropPresentation.resolutionFailed()
            }
        }
    }

    private func requestRecurringDropConfirmationDismissal() {
        guard recurringDropPresentation.requestConfirmationDismissal() else { return }
        Task { @MainActor in
            await Task.yield()
            guard recurringDropPresentation.settleConfirmationDismissal() else { return }
            dropCoordinator.cancel()
        }
    }

    private func cancelRecurringDropConfirmation() {
        guard recurringDropPresentation.cancelConfirmation() else { return }
        dropCoordinator.cancel()
    }

    private func undo() {
        Task {
            try? await store.undo()
        }
    }

    private func refreshProjection() {
        refreshProjection(today: todayRefreshPolicy.today)
    }

    private func refreshToday(for event: MonthViewTodayRefreshEvent) {
        todayRefreshController.handle(event) { today in
            refreshProjection(today: today)
        }
    }

    private func refreshProjection(today: CalendarDate) {
        model.update(
            state: store.state,
            hiddenCategoryIDs: hiddenCategoryIDs,
            today: today
        )
    }
}

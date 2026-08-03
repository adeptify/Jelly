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

private struct WeekStreamScrollRequest: Equatable {
    let id = UUID()
    let weekStart: CalendarDate
    let windowRevision: WeekStreamWindowRevision
    let animated: Bool
}

enum MonthQuickCreateRouting {
    static func presentation(for action: CalendarInteractionAction?) -> QuickCreatePresentation? {
        guard let action else { return nil }
        return QuickCreatePresentation(action: action)
    }
}

enum WeekStreamAutoScrollPlan: Equatable {
    case scroll(CalendarDate)
    case extendEarlier(thenScrollTo: CalendarDate)
    case extendLater(thenScrollTo: CalendarDate)
}

enum WeekStreamAutoScrollRouting {
    static func plan(
        cursorDate: CalendarDate,
        direction: CalendarInteractionAutoScrollDirection,
        loadedWeekStarts: [CalendarDate]
    ) -> WeekStreamAutoScrollPlan {
        let targetWeek = WeekStreamModel.weekStart(containing: cursorDate.addingDays(direction.dayDelta))
        guard !loadedWeekStarts.contains(targetWeek) else {
            return .scroll(targetWeek)
        }
        switch direction {
        case .earlier: return .extendEarlier(thenScrollTo: targetWeek)
        case .later: return .extendLater(thenScrollTo: targetWeek)
        }
    }
}

@MainActor
protocol WeekStreamAutoScrollDeferredCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol WeekStreamAutoScrollDeferrer: AnyObject {
    func deferToNextLayout(
        _ action: @escaping () -> Void
    ) -> any WeekStreamAutoScrollDeferredCancellation
}

@MainActor
final class WeekStreamAutoScrollExecutionDriver: ObservableObject {
    private let deferrer: any WeekStreamAutoScrollDeferrer
    private var pendingScroll: (any WeekStreamAutoScrollDeferredCancellation)?

    init(deferrer: any WeekStreamAutoScrollDeferrer = MainActorNextLayoutDeferrer()) {
        self.deferrer = deferrer
    }

    func execute(
        plan: WeekStreamAutoScrollPlan,
        visibleWeek: CalendarDate,
        direction: CalendarInteractionAutoScrollDirection,
        loadedWeekStarts: @escaping () -> [CalendarDate],
        extend: @escaping (CalendarInteractionAutoScrollDirection, CalendarDate) -> Void,
        scroll: @escaping (CalendarDate, CalendarInteractionAutoScrollDirection) -> Void
    ) {
        cancel()

        let targetWeek: CalendarDate
        switch plan {
        case let .scroll(week):
            targetWeek = week
        case let .extendEarlier(thenScrollTo: week):
            targetWeek = week
            extend(.earlier, visibleWeek)
        case let .extendLater(thenScrollTo: week):
            targetWeek = week
            extend(.later, visibleWeek)
        }

        guard plan.requiresWindowExtension else {
            scrollIfLoaded(
                targetWeek,
                direction: direction,
                loadedWeekStarts: loadedWeekStarts,
                scroll: scroll
            )
            return
        }

        pendingScroll = deferrer.deferToNextLayout { [weak self] in
            guard let self else { return }
            self.pendingScroll = nil
            self.scrollIfLoaded(
                targetWeek,
                direction: direction,
                loadedWeekStarts: loadedWeekStarts,
                scroll: scroll
            )
        }
    }

    func cancel() {
        pendingScroll?.cancel()
        pendingScroll = nil
    }

    private func scrollIfLoaded(
        _ targetWeek: CalendarDate,
        direction: CalendarInteractionAutoScrollDirection,
        loadedWeekStarts: () -> [CalendarDate],
        scroll: (CalendarDate, CalendarInteractionAutoScrollDirection) -> Void
    ) {
        guard loadedWeekStarts().contains(targetWeek) else { return }
        scroll(targetWeek, direction)
    }
}

private extension WeekStreamAutoScrollPlan {
    var requiresWindowExtension: Bool {
        switch self {
        case .scroll: false
        case .extendEarlier, .extendLater: true
        }
    }
}

@MainActor
private final class MainActorNextLayoutDeferrer: WeekStreamAutoScrollDeferrer {
    private final class Cancellation: WeekStreamAutoScrollDeferredCancellation {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    func deferToNextLayout(
        _ action: @escaping () -> Void
    ) -> any WeekStreamAutoScrollDeferredCancellation {
        let cancellation = Cancellation()
        Task { @MainActor in
            await Task.yield()
            guard !cancellation.isCancelled else { return }
            action()
        }
        return cancellation
    }
}

struct MonthView: View {
    let store: CalendarStore
    private let todayRefreshPolicy: MonthViewTodayRefreshPolicy
    private let todayRefreshController: MonthViewTodayRefreshController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @StateObject private var model: MonthViewModel
    @StateObject private var dropCoordinator: CalendarDropCoordinator
    @StateObject private var interactionCoordinator: CalendarInteractionCoordinator
    @StateObject private var autoScrollDriver: CalendarInteractionAutoScrollDriver
    @StateObject private var autoScrollExecutionDriver: WeekStreamAutoScrollExecutionDriver
    @StateObject private var weekStreamScrollCoordinator: WeekStreamScrollCoordinator
    @StateObject private var weekStreamRestoration: WeekStreamRestorationController
    @AppStorage("calendar.hiddenCategoryIDs") private var storedHiddenCategoryIDs = ""
    @State private var hiddenCategoryIDs: Set<UUID> = []
    @State private var quickCreatePresentation: QuickCreatePresentation?
    @State private var dateFrameMap = CalendarDateFrameMap(frames: [])
    @State private var lastEditorAnchorFrame: CGRect?
    @State private var quickCreateMeasuredContentSize = CGSize.zero
    @State private var selectedDayDrawerDate: CalendarDate?
    @State private var selectedItem: ProjectedItem?
    @State private var recurringDropPresentation = RecurringDropPresentationController()
    @State private var requestedCenterRequest: WeekStreamScrollRequest?
    @State private var weekStreamCentering: WeekStreamCenteringState

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var motionPolicy: CalendarMotionPolicy {
        CalendarMotionPolicy(reduceMotion: accessibilityReduceMotion)
    }

    init(
        store: CalendarStore,
        todayRefreshPolicy: MonthViewTodayRefreshPolicy = .live
    ) {
        self.store = store
        self.todayRefreshPolicy = todayRefreshPolicy
        todayRefreshController = MonthViewTodayRefreshController(policy: todayRefreshPolicy)
        let today = todayRefreshPolicy.today
        _model = StateObject(wrappedValue: MonthViewModel(
            centeredOn: today,
            state: store.state,
            hiddenCategoryIDs: [],
            today: today
        ))
        _dropCoordinator = StateObject(wrappedValue: CalendarDropCoordinator(store: store))
        _interactionCoordinator = StateObject(wrappedValue: CalendarInteractionCoordinator())
        _autoScrollDriver = StateObject(wrappedValue: CalendarInteractionAutoScrollDriver())
        _autoScrollExecutionDriver = StateObject(wrappedValue: WeekStreamAutoScrollExecutionDriver())
        let restoration = WeekStreamRestorationController()
        _weekStreamRestoration = StateObject(wrappedValue: restoration)
        _weekStreamScrollCoordinator = StateObject(wrappedValue: WeekStreamScrollCoordinator {
            [weak restoration] adjustment in
            restoration?.recordAppliedAdjustment(adjustment)
        })
        let initialStream = WeekStreamModel(centeredOn: today)
        var initialCentering = WeekStreamCenteringState()
        _ = initialCentering.begin(
            weekStart: initialStream.focusWeek,
            windowRevision: WeekStreamWindowRevision(weekStarts: initialStream.weekStarts)
        )
        _weekStreamCentering = State(initialValue: initialCentering)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            weekdayHeader
            GeometryReader { proxy in
                weekStream(viewportBounds: proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root)))
            }
        }
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .transaction { transaction in
            if accessibilityReduceMotion {
                transaction.disablesAnimations = true
            }
        }
        .coordinateSpace(name: CalendarInteractionCoordinateSpace.root)
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
        .onPreferenceChange(QuickCreateCardSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            quickCreateMeasuredContentSize = size
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
            "修改重复事项",
            isPresented: recurringDropConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("仅本次") { resolveRecurringDrop(scope: .onlyThis) }
            Button("本次及以后") { resolveRecurringDrop(scope: .thisAndFuture) }
            Button("取消", role: .cancel) {
                cancelRecurringDropConfirmation()
            }
        } message: {
            Text("请选择这次修改影响的范围")
        }
        .overlay(alignment: .trailing) {
            if let date = selectedDayDrawerDate {
                DayDrawerView(
                    date: date,
                    store: store,
                    categories: store.state.categories,
                    hiddenCategoryIDs: hiddenCategoryIDs,
                    onClose: {
                        withAnimation(motionPolicy.overlayAnimation) {
                            selectedDayDrawerDate = nil
                        }
                    },
                    onQuickCreate: { openQuickCreate(on: $0) },
                    onOpenDetail: { selectedItem = $0 }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .overlay {
            GeometryReader { proxy in
                if let presentation = quickCreatePresentation {
                    let windowBounds = proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root))
                    let overlayPresentation = QuickCreateOverlayPresentation(
                        presentation: presentation,
                        measuredContentSize: quickCreateMeasuredContentSize,
                        anchorFrame: resolvedEditorAnchorFrame(
                            for: presentation.anchorDate,
                            windowBounds: windowBounds
                        ),
                        windowBounds: windowBounds
                    )
                    QuickCreatePopover(
                        presentation: presentation,
                        categories: orderedCategories,
                        store: store,
                        availableWidth: overlayPresentation.placement.frame.width,
                        maximumContentHeight: overlayPresentation.contentLayout.maximumHeight,
                        onClose: dismissQuickCreate
                    )
                    .frame(width: overlayPresentation.placement.frame.width)
                    .background(theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.subtleBorder, lineWidth: 1)
                    }
                    .shadow(color: theme.subtleShadow.opacity(0.20), radius: 14, y: 5)
                    .position(
                        x: overlayPresentation.placement.frame.midX,
                        y: overlayPresentation.placement.frame.midY
                    )
                    .accessibilityIdentifier("quick-create-overlay-card")
                }
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
                .foregroundStyle(theme.primaryText)
                .background(theme.elevatedSurface, in: Capsule())
                .overlay(Capsule().stroke(theme.subtleBorder, lineWidth: 0.5))
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
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            Button { navigateToPreviousMonth() } label: {
                Image(systemName: "chevron.left")
            }
            .help("上个月")
            Button("今天") { navigateToToday() }
            Button { navigateToNextMonth() } label: {
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
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: CalendarTheme.weekdayHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 0.5)
        }
    }

    private var monthTitle: String {
        "\(model.monthTitleDate.year)年\(model.monthTitleDate.month)月"
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

    private var orderedCategories: [CalendarCategory] {
        store.state.categories.values.sorted {
            $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
        }
    }

    private func handle(_ action: DayCellAction) {
        switch action {
        case let .openDay(date):
            model.selectedDate = date
            withAnimation(motionPolicy.overlayAnimation) {
                selectedDayDrawerDate = date
            }
        case let .quickCreate(date):
            openQuickCreate(on: date)
        case let .openItem(id):
            selectedItem = model.projectedItem(withID: id)
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
            recurringDropPresentation.scopeSelectionCaptureFailed(
                hasPendingDrop: dropCoordinator.pendingRecurringDrop != nil
            )
            if dropCoordinator.pendingRecurringDrop == nil {
                interactionCoordinator.completePendingMutation()
            }
            return
        }
        Task {
            do {
                try await dropCoordinator.submit(resolution)
                recurringDropPresentation.resolutionSucceeded()
                interactionCoordinator.completePendingMutation()
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
            interactionCoordinator.completePendingMutation()
        }
    }

    private func cancelRecurringDropConfirmation() {
        guard recurringDropPresentation.cancelConfirmation() else { return }
        dropCoordinator.cancel()
        interactionCoordinator.completePendingMutation()
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

    private func navigateToPreviousMonth() {
        model.moveWeekStreamFocus(to: .previousLogicalMonth)
        requestCentering(on: model.focusWeek)
    }

    private func navigateToNextMonth() {
        model.moveWeekStreamFocus(to: .nextLogicalMonth)
        requestCentering(on: model.focusWeek)
    }

    private func navigateToToday() {
        model.moveWeekStreamFocus(to: .today(todayRefreshPolicy.today))
        requestCentering(on: model.focusWeek)
    }

    private func requestCentering(on weekStart: CalendarDate) {
        requestedCenterRequest = .init(
            weekStart: weekStart,
            windowRevision: WeekStreamWindowRevision(weekStarts: model.weekStarts),
            animated: true
        )
    }

    private func weekStream(viewportBounds: CGRect) -> some View {
        let viewportHeight = viewportBounds.height
        let windowRevision = WeekStreamWindowRevision(weekStarts: model.weekStarts)
        let layouts = Dictionary(uniqueKeysWithValues: model.weekLayouts(
            laneCapacity: WeekRowMetrics.itemCapacity(height: WeekRowMetrics.defaultHeight)
        ).map { ($0.weekStart, $0) })

        return ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.weekStarts, id: \.self) { weekStart in
                        if let layout = layouts[weekStart] {
                            WeekRowView(
                                layout: layout,
                                today: model.today,
                                selectedDate: model.selectedDate,
                                categories: store.state.categories,
                                dropCoordinator: dropCoordinator,
                                onAction: handle,
                                onCompletion: sendCompletion,
                                selectionRange: interactionCoordinator.previewRange,
                                onRangeGesture: { gesture in
                                    handleRangeGesture(
                                        gesture,
                                        viewportBounds: viewportBounds,
                                        scrollProxy: scrollProxy
                                    )
                                },
                                onItemGesture: { gesture in
                                    handleItemGesture(
                                        gesture,
                                        viewportBounds: viewportBounds,
                                        scrollProxy: scrollProxy
                                    )
                                }
                            )
                            .id(weekStart)
                            .background {
                                GeometryReader { rowProxy in
                                    Color.clear.preference(
                                        key: WeekRowFramePreferenceKey.self,
                                        value: [.init(
                                            weekStart: weekStart,
                                            minY: rowProxy.frame(in: .named("week-stream-viewport")).minY,
                                            maxY: rowProxy.frame(in: .named("week-stream-viewport")).maxY,
                                            windowRevision: windowRevision
                                        )]
                                    )
                                }
                            }
                        }
                    }
                }
                .background {
                    WeekStreamScrollResolver(coordinator: weekStreamScrollCoordinator)
                        .frame(width: 0, height: 0)
                }
            }
            .coordinateSpace(name: "week-stream-viewport")
            .onAppear {
                if let request = weekStreamCentering.pendingRequest {
                    issueCenteringScroll(request, using: scrollProxy, animated: false)
                }
            }
            .onChange(of: requestedCenterRequest) { _, request in
                guard let request else { return }
                let centeringRequest = weekStreamCentering.begin(
                    weekStart: request.weekStart,
                    windowRevision: request.windowRevision
                )
                issueCenteringScroll(
                    centeringRequest,
                    using: scrollProxy,
                    animated: request.animated
                )
            }
            .onPreferenceChange(WeekRowFramePreferenceKey.self) { frames in
                handleWeekStreamViewport(
                    frames: frames,
                    viewportHeight: viewportHeight,
                    scrollProxy: scrollProxy
                )
            }
            .onPreferenceChange(CalendarDateFramePreferenceKey.self) { frames in
                dateFrameMap = CalendarDateFrameMap(frames: frames)
                if let anchor = quickCreatePresentation?.anchorDate,
                   let frame = dateFrameMap.frame(for: anchor) {
                    lastEditorAnchorFrame = frame
                }
            }
            .onChange(of: autoScrollDriver.latestTick) { _, tick in
                guard let tick else { return }
                advanceRangeAutoScroll(
                    tick,
                    viewportBounds: viewportBounds,
                    scrollProxy: scrollProxy
                )
            }
        }
    }

    private func handleRangeGesture(
        _ gesture: WeekRowRangeGesture,
        viewportBounds: CGRect,
        scrollProxy: ScrollViewProxy
    ) {
        switch gesture {
        case let .began(date, target, point):
            cancelRangeAutoScroll()
            interactionCoordinator.pointerDown(on: date, target: target, point: point)
        case let .changed(point):
            let date = dateFrameMap.date(at: point)
            _ = interactionCoordinator.updatePointer(
                point: point,
                over: date,
                viewportBounds: viewportBounds
            )
            autoScrollExecutionDriver.cancel()
            autoScrollDriver.update(direction: interactionCoordinator.autoScrollDirection)
        case let .ended(point):
            cancelRangeAutoScroll()
            let releaseDate = dateFrameMap.date(at: point) ?? dateFrameMap.nearestDate(to: point)
            let action = interactionCoordinator.pointerUp(at: point, over: releaseDate)
            presentQuickCreate(for: action)
        }
    }

    private func handleItemGesture(
        _ gesture: WeekRowItemGesture,
        viewportBounds: CGRect,
        scrollProxy: ScrollViewProxy
    ) {
        switch gesture {
        case let .began(date, target, source, point):
            cancelRangeAutoScroll()
            interactionCoordinator.pointerDown(
                on: date,
                target: target,
                source: source,
                point: point
            )
        case let .changed(point):
            let date = dateFrameMap.date(at: point) ?? dateFrameMap.nearestDate(to: point)
            _ = interactionCoordinator.updatePointer(
                point: point,
                over: date,
                viewportBounds: viewportBounds
            )
            autoScrollExecutionDriver.cancel()
            autoScrollDriver.update(direction: interactionCoordinator.autoScrollDirection)
        case let .ended(point):
            cancelRangeAutoScroll()
            let releaseDate = dateFrameMap.date(at: point) ?? dateFrameMap.nearestDate(to: point)
            guard case let .submitMutation(pending) = interactionCoordinator.pointerUp(
                at: point,
                over: releaseDate
            ) else {
                return
            }
            if case .occurrence = pending.source {
                interactionCoordinator.beginPendingRecurrenceScope()
            }
            Task {
                do {
                    try await dropCoordinator.accept(pending)
                } catch {
                    interactionCoordinator.completePendingMutation()
                }
            }
        }
    }

    private func advanceRangeAutoScroll(
        _ tick: CalendarInteractionAutoScrollTick,
        viewportBounds: CGRect,
        scrollProxy: ScrollViewProxy
    ) {
        guard interactionCoordinator.isDragging,
              interactionCoordinator.autoScrollDirection == tick.direction
        else {
            return
        }
        let pointer = interactionCoordinator.latestPointer ?? CGPoint(
            x: viewportBounds.midX,
            y: tick.direction == .earlier ? viewportBounds.minY : viewportBounds.maxY
        )
        guard let cursorDate = dateFrameMap.date(at: pointer)
            ?? dateFrameMap.nearestDate(to: pointer)
            ?? interactionCoordinator.selectionCursorDate
        else {
            return
        }

        let targetDate = cursorDate.addingDays(tick.direction.dayDelta)
        interactionCoordinator.refreshInteraction(over: targetDate)
        let plan = WeekStreamAutoScrollRouting.plan(
            cursorDate: cursorDate,
            direction: tick.direction,
            loadedWeekStarts: model.weekStarts
        )
        autoScrollExecutionDriver.execute(
            plan: plan,
            visibleWeek: WeekStreamModel.weekStart(containing: cursorDate),
            direction: tick.direction,
            loadedWeekStarts: { model.weekStarts },
            extend: { direction, visibleWeek in
                switch direction {
                case .earlier:
                    _ = model.extendEarlier(visibleWeek: visibleWeek, pixelOffset: 0)
                case .later:
                    _ = model.extendLater(visibleWeek: visibleWeek, pixelOffset: 0)
                }
            },
            scroll: { targetWeek, direction in
                scrollProxy.scrollTo(
                    targetWeek,
                    anchor: direction == .earlier ? .top : .bottom
                )
            }
        )
    }

    private func openQuickCreate(on date: CalendarDate) {
        presentQuickCreate(for: .openCreate(
            CalendarDateRange(start: date, end: date),
            anchor: date
        ))
    }

    private func presentQuickCreate(for action: CalendarInteractionAction?) {
        guard let presentation = MonthQuickCreateRouting.presentation(for: action)
        else {
            return
        }
        cancelRangeAutoScroll()
        withAnimation(motionPolicy.overlayAnimation) {
            quickCreatePresentation = presentation
        }
        lastEditorAnchorFrame = dateFrameMap.frame(for: presentation.anchorDate)
        quickCreateMeasuredContentSize = .zero
        interactionCoordinator.openEditor(for: presentation.range, anchor: presentation.anchorDate)
    }

    private func dismissQuickCreate() {
        cancelRangeAutoScroll()
        withAnimation(motionPolicy.overlayAnimation) {
            quickCreatePresentation = nil
        }
        lastEditorAnchorFrame = nil
        quickCreateMeasuredContentSize = .zero
        interactionCoordinator.cancel()
    }

    private func issueCenteringScroll(
        _ request: WeekStreamCenteringRequest,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        Task { @MainActor in
            await Task.yield()
            guard weekStreamCentering.markScrollIssued(for: request) else { return }
            align(proxy, to: request.weekStart, anchor: .center, animated: animated)
        }
    }

    private func align(
        _ proxy: ScrollViewProxy,
        to weekStart: CalendarDate,
        anchor: UnitPoint,
        animated: Bool = true
    ) {
        guard motionPolicy.shouldAlignToWeek else { return }
        guard animated, let animation = motionPolicy.snapAnimation else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(weekStart, anchor: anchor)
            }
            return
        }
        withAnimation(animation) {
            proxy.scrollTo(weekStart, anchor: anchor)
        }
    }

    private func cancelRangeAutoScroll() {
        autoScrollDriver.cancel()
        autoScrollExecutionDriver.cancel()
    }

    private func resolvedEditorAnchorFrame(for date: CalendarDate, windowBounds: CGRect) -> CGRect {
        if let frame = dateFrameMap.frame(for: date) {
            return frame
        }
        let visibleDates = dateFrameMap.visibleDates
        if let first = visibleDates.first, date < first {
            return CGRect(x: windowBounds.midX, y: windowBounds.minY - 1, width: 1, height: 1)
        }
        if let last = visibleDates.last, date > last {
            return CGRect(x: windowBounds.midX, y: windowBounds.maxY + 1, width: 1, height: 1)
        }
        return lastEditorAnchorFrame ?? CGRect(
            x: windowBounds.midX,
            y: windowBounds.midY,
            width: 1,
            height: 1
        )
    }

    private var isExtendingWeekStream: Bool {
        weekStreamRestoration.isLocked
    }

    private func handleWeekStreamViewport(
        frames: [WeekRowViewportFrame],
        viewportHeight: CGFloat,
        scrollProxy: ScrollViewProxy
    ) {
        switch weekStreamCentering.receive(
            frames: frames,
            viewportHeight: viewportHeight
        ) {
        case .wait:
            return
        case let .retry(request):
            issueCenteringScroll(request, using: scrollProxy, animated: false)
            return
        case .ready:
            break
        }

        if isExtendingWeekStream {
            switch weekStreamRestoration.receive(frames: frames) {
            case .wait, .confirmed:
                return
            case let .adjustContentOffset(correction):
                weekStreamScrollCoordinator.adjustViewport(correction)
                return
            }
        }

        let windowRevision = WeekStreamWindowRevision(weekStarts: model.weekStarts)
        let currentFrames = frames.filter { $0.windowRevision == windowRevision }
        if let focusWeek = WeekStreamViewport.focusWeek(
            in: currentFrames,
            viewportHeight: viewportHeight
        ),
           focusWeek != model.focusWeek {
            model.updateFocus(toWeekStarting: focusWeek)
        }

        guard let request = WeekStreamViewport.extensionRequest(
                in: currentFrames,
                loadedWeekStarts: model.weekStarts,
                viewportHeight: viewportHeight
              ),
              weekStreamRestoration.begin(request: request)
        else {
            return
        }

        let anchor: WeekStreamAnchor
        switch request.direction {
        case .earlier:
            anchor = model.extendEarlier(
                visibleWeek: request.anchor.weekStart,
                pixelOffset: request.anchor.pixelOffset
            )
        case .later:
            anchor = model.extendLater(
                visibleWeek: request.anchor.weekStart,
                pixelOffset: request.anchor.pixelOffset
            )
        }
        weekStreamRestoration.expect(
            anchor: anchor,
            windowRevision: WeekStreamWindowRevision(weekStarts: model.weekStarts)
        )
    }
}

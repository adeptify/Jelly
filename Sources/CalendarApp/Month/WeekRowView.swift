import AppKit
import CalendarDomain
import SwiftUI

enum WeekRowMetrics {
    /// Compact week row; lane count follows itemRowHeight (not locked to 10).
    static let defaultHeight: CGFloat = 212
    /// Date numeral band + a little air above the first item chip.
    static let dateHeaderHeight: CGFloat = 26
    static let laneHeight: CGFloat = CalendarTheme.itemRowHeight
    static let laneSpacing: CGFloat = 2

    static func itemCapacity(height: CGFloat) -> Int {
        let laneAreaHeight = max(0, height - dateHeaderHeight)
        return max(0, Int(floor((laneAreaHeight + laneSpacing) / (laneHeight + laneSpacing))))
    }

    static func laneOffset(_ lane: Int) -> CGFloat {
        dateHeaderHeight + CGFloat(lane) * (laneHeight + laneSpacing)
    }
}

enum WeekRowDropTarget {
    static func date(atX x: CGFloat, rowWidth: CGFloat, weekStart: CalendarDate) -> CalendarDate {
        guard rowWidth > 0 else { return weekStart }
        let columnWidth = rowWidth / 7
        let column = min(max(Int(floor(x / columnWidth)), 0), 6)
        return weekStart.addingDays(column)
    }
}

struct CalendarDateBadgePresentation: Equatable {
    let showsTodayDot: Bool
    let showsSelectionRing: Bool
    let accessibilityLabel: String
    let accessibilityValue: String

    init(date: CalendarDate, isToday: Bool, isSelected: Bool) {
        showsTodayDot = isToday
        showsSelectionRing = isSelected

        var labelComponents = ["\(date.month)月\(date.day)日"]
        var stateComponents: [String] = []
        if isToday {
            labelComponents.append("今天")
            stateComponents.append("今天")
        }
        if isSelected {
            labelComponents.append("已选中")
            stateComponents.append("已选中")
        }
        labelComponents.append("打开当天事项")
        accessibilityLabel = labelComponents.joined(separator: "，")
        accessibilityValue = stateComponents.isEmpty
            ? "普通日期"
            : stateComponents.joined(separator: "，")
    }
}

struct WeekRowSegmentPresentation: Identifiable, Equatable {
    let id: WeekSegmentID
    let source: ProjectedEntryID
    let entry: ProjectedEntry
    let startColumn: Int
    let endColumn: Int
    let lane: Int
    let continuesBefore: Bool
    let continuesAfter: Bool
    let showsLeadingHandle: Bool
    let showsTrailingHandle: Bool
    let accessibilityLabel: String
    let accessibilityValue: String
    let leadingHandleAccessibility: CalendarResizeHandleAccessibility?
    let trailingHandleAccessibility: CalendarResizeHandleAccessibility?

    var leadingContinuation: Bool { continuesBefore }
    var trailingContinuation: Bool { continuesAfter }

    init(segment: WeekSegment, categoryName: String) {
        id = segment.id
        source = segment.source
        entry = segment.entry
        startColumn = segment.startColumn
        endColumn = segment.endColumn
        lane = segment.lane
        continuesBefore = segment.entry.schedule.startDate < segment.id.weekStart
        continuesAfter = segment.entry.schedule.endDate > segment.id.weekStart.addingDays(6)
        showsLeadingHandle = segment.showsLeadingHandle
        showsTrailingHandle = segment.showsTrailingHandle
        accessibilityLabel = Self.makeAccessibilityLabel(
            entry: segment.entry,
            categoryName: categoryName,
            continuesBefore: continuesBefore,
            continuesAfter: continuesAfter
        )
        accessibilityValue = Self.makeAccessibilityValue(entry: segment.entry)
        leadingHandleAccessibility = segment.showsLeadingHandle
            ? .init(
                label: "调整开始日期",
                value: CalendarItemAccessibility.fullDateText(segment.entry.schedule.startDate)
            )
            : nil
        trailingHandleAccessibility = segment.showsTrailingHandle
            ? .init(
                label: "调整结束日期",
                value: CalendarItemAccessibility.fullDateText(segment.entry.schedule.endDate)
            )
            : nil
    }

    private static func makeAccessibilityValue(entry: ProjectedEntry) -> String {
        let item: ProjectedItem = switch entry {
        case let .item(item): .item(item)
        case let .occurrence(occurrence): .occurrence(occurrence)
        }
        return CalendarItemAccessibility.sourceValue(for: item)
    }

    private static func makeAccessibilityLabel(
        entry: ProjectedEntry,
        categoryName: String,
        continuesBefore: Bool,
        continuesAfter: Bool
    ) -> String {
        var components = [
            "事项",
            categoryName,
            entry.title,
            CalendarItemAccessibility.dateTimeRangeText(for: entry.schedule)
        ]
        if continuesBefore {
            components.append("从前一周继续")
        }
        if continuesAfter {
            components.append("延续到下一周")
        }
        components.append(entry.completedAt == nil ? "未完成" : "已完成")
        return components.joined(separator: "，")
    }

}

struct CalendarResizeHandleAccessibility: Equatable {
    let label: String
    let value: String
}

struct WeekRowPresentation: Equatable {
    let weekStart: CalendarDate
    let segments: [WeekRowSegmentPresentation]
    let overflowByDate: [CalendarDate: Int]

    init(layout: WeekLayout, categories: [UUID: CalendarCategory] = [:]) {
        weekStart = layout.weekStart
        overflowByDate = layout.overflowByDate
        segments = layout.visibleSegments.map { segment in
            WeekRowSegmentPresentation(
                segment: segment,
                categoryName: categories[segment.entry.categoryID]?.name ?? "未分类"
            )
        }
    }

    var accessibilityLabel: String {
        segments.map(\.accessibilityLabel).joined(separator: "；")
    }

    func segment(_ source: ProjectedEntryID) -> WeekRowSegmentPresentation? {
        segments.first(where: { $0.source == source })
    }

    func overflowCount(for date: CalendarDate) -> Int {
        overflowByDate[date, default: 0]
    }
}

struct WeekRowViewportFrame: Equatable, Identifiable {
    let weekStart: CalendarDate
    let minY: CGFloat
    let maxY: CGFloat
    let windowRevision: WeekStreamWindowRevision?

    init(
        weekStart: CalendarDate,
        minY: CGFloat,
        maxY: CGFloat,
        windowRevision: WeekStreamWindowRevision? = nil
    ) {
        self.weekStart = weekStart
        self.minY = minY
        self.maxY = maxY
        self.windowRevision = windowRevision
    }

    var id: CalendarDate { weekStart }
    var centerY: CGFloat { (minY + maxY) / 2 }
}

enum WeekStreamExtensionDirection: Equatable {
    case earlier
    case later
}

struct WeekStreamExtensionRequest: Equatable {
    let direction: WeekStreamExtensionDirection
    let anchor: WeekStreamAnchor
    let desiredMinY: CGFloat

    init(
        direction: WeekStreamExtensionDirection,
        anchor: WeekStreamAnchor,
        desiredMinY: CGFloat? = nil
    ) {
        self.direction = direction
        self.anchor = anchor
        self.desiredMinY = desiredMinY ?? -anchor.pixelOffset
    }
}

struct WeekStreamRestorationIntent: Equatable {
    let weekStart: CalendarDate
    let pixelOffset: CGFloat
}

enum WeekStreamViewport {
    static let edgeThreshold: CGFloat = WeekRowMetrics.defaultHeight

    static func focusWeek(
        in frames: [WeekRowViewportFrame],
        viewportHeight: CGFloat
    ) -> CalendarDate? {
        let viewportCenter = viewportHeight / 2
        return frames.min {
            let leftDistance = abs($0.centerY - viewportCenter)
            let rightDistance = abs($1.centerY - viewportCenter)
            if leftDistance == rightDistance {
                return $0.weekStart < $1.weekStart
            }
            return leftDistance < rightDistance
        }?.weekStart
    }

    static func extensionRequest(
        in frames: [WeekRowViewportFrame],
        loadedWeekStarts: [CalendarDate],
        viewportHeight: CGFloat
    ) -> WeekStreamExtensionRequest? {
        guard let firstLoadedWeek = loadedWeekStarts.first,
              let lastLoadedWeek = loadedWeekStarts.last
        else {
            return nil
        }

        let framesByWeek = Dictionary(uniqueKeysWithValues: frames.map { ($0.weekStart, $0) })
        let visibleFrames = frames
            .filter { $0.maxY >= 0 && $0.minY <= viewportHeight }
            .sorted {
                if $0.minY == $1.minY {
                    return $0.weekStart < $1.weekStart
                }
                return $0.minY < $1.minY
            }
        guard let stableAnchor = visibleFrames.first else {
            return nil
        }

        if let firstFrame = framesByWeek[firstLoadedWeek],
           firstFrame.maxY >= 0,
           firstFrame.minY <= edgeThreshold {
            return WeekStreamExtensionRequest(
                direction: .earlier,
                anchor: .init(
                    weekStart: stableAnchor.weekStart,
                    pixelOffset: max(0, -stableAnchor.minY)
                ),
                desiredMinY: stableAnchor.minY
            )
        }
        if let lastFrame = framesByWeek[lastLoadedWeek],
           lastFrame.minY <= viewportHeight,
           lastFrame.maxY >= viewportHeight - edgeThreshold {
            return WeekStreamExtensionRequest(
                direction: .later,
                anchor: .init(
                    weekStart: stableAnchor.weekStart,
                    pixelOffset: max(0, -stableAnchor.minY)
                ),
                desiredMinY: stableAnchor.minY
            )
        }
        return nil
    }

    static func restorationIntent(for anchor: WeekStreamAnchor) -> WeekStreamRestorationIntent {
        .init(weekStart: anchor.weekStart, pixelOffset: anchor.pixelOffset)
    }
}

struct WeekRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [WeekRowViewportFrame] = []

    static func reduce(value: inout [WeekRowViewportFrame], nextValue: () -> [WeekRowViewportFrame]) {
        var frames = Dictionary(uniqueKeysWithValues: value.map { ($0.weekStart, $0) })
        for frame in nextValue() {
            frames[frame.weekStart] = frame
        }
        value = frames.values.sorted { $0.weekStart < $1.weekStart }
    }
}

struct CalendarDateFramePreferenceKey: PreferenceKey {
    static let defaultValue: [CalendarDateFrame] = []

    static func reduce(value: inout [CalendarDateFrame], nextValue: () -> [CalendarDateFrame]) {
        var frames = Dictionary(uniqueKeysWithValues: value.map { ($0.date, $0) })
        for frame in nextValue() {
            frames[frame.date] = frame
        }
        value = frames.values.sorted { $0.date < $1.date }
    }
}

enum WeekRowHitSurface: Equatable {
    case emptySurface
    case dateNumber
    case overflow
    case item
    case completion
    case scroll
}

enum WeekRowHitRouting {
    static func selectionTarget(for surface: WeekRowHitSurface) -> CalendarInteractionHitTarget? {
        switch surface {
        case .emptySurface:
            .emptyCell
        case .dateNumber, .overflow, .item, .completion, .scroll:
            nil
        }
    }

    static func dayAction(for surface: WeekRowHitSurface, date: CalendarDate) -> DayCellAction? {
        switch surface {
        case .dateNumber:
            DayCellSurfaceInteraction.controlAction(for: .dateNumber, date: date)
        case .overflow:
            DayCellSurfaceInteraction.controlAction(for: .overflow, date: date)
        case .emptySurface, .item, .completion, .scroll:
            nil
        }
    }
}

enum WeekRowItemHitRouting {
    /// Wide enough to grab; checked before completion so edges aren't swallowed.
    static let handleHitWidth: CGFloat = 18
    /// Completion circle sits after the leading handle strip.
    static let completionHitRange: ClosedRange<CGFloat> = 18...40

    static func target(
        atX x: CGFloat,
        width: CGFloat,
        kind: ItemKind,
        showsLeadingHandle: Bool,
        showsTrailingHandle: Bool
    ) -> CalendarInteractionHitTarget {
        let clampedX = min(max(x, 0), max(0, width))
        // Handles first — otherwise completion (10…34) ate the leading edge.
        if showsLeadingHandle, clampedX <= handleHitWidth {
            return .leadingHandle
        }
        if showsTrailingHandle, clampedX >= max(0, width - handleHitWidth) {
            return .trailingHandle
        }
        if completionHitRange.contains(clampedX) {
            return .completionButton
        }
        return .barBody
    }
}

@MainActor
final class WeekRowRangeGestureSurfaceView: NSView {
    private var date: CalendarDate
    private var hitSurface: WeekRowHitSurface
    private var rootOrigin: CGPoint
    private var onRangeGesture: (WeekRowRangeGesture) -> Void
    private var isTrackingRange = false

    override var isFlipped: Bool { true }

    init(
        date: CalendarDate,
        hitSurface: WeekRowHitSurface,
        rootOrigin: CGPoint,
        onRangeGesture: @escaping (WeekRowRangeGesture) -> Void
    ) {
        self.date = date
        self.hitSurface = hitSurface
        self.rootOrigin = rootOrigin
        self.onRangeGesture = onRangeGesture
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        date: CalendarDate,
        hitSurface: WeekRowHitSurface,
        rootOrigin: CGPoint,
        onRangeGesture: @escaping (WeekRowRangeGesture) -> Void
    ) {
        self.date = date
        self.hitSurface = hitSurface
        self.rootOrigin = rootOrigin
        self.onRangeGesture = onRangeGesture
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Accept every point in the body. Occupied chips sit in a higher ZStack layer and
        // receive their own hits; masking whole lanes here left dead zones beside/under items
        // (e.g. day-cell bottom-left margins next to a chip).
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let target = WeekRowHitRouting.selectionTarget(for: hitSurface) else {
            isTrackingRange = false
            return
        }
        isTrackingRange = true
        onRangeGesture(.began(date, target, rootPoint(for: event)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingRange else { return }
        onRangeGesture(.changed(rootPoint(for: event)))
    }

    override func mouseUp(with event: NSEvent) {
        defer { isTrackingRange = false }
        guard isTrackingRange else { return }
        onRangeGesture(.ended(rootPoint(for: event)))
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    private func rootPoint(for event: NSEvent) -> CGPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: rootOrigin.x + localPoint.x,
            y: rootOrigin.y + localPoint.y
        )
    }
}

private struct WeekRowEmptyRangeGestureSurface: NSViewRepresentable {
    let date: CalendarDate
    let rootOrigin: CGPoint
    let onRangeGesture: (WeekRowRangeGesture) -> Void

    func makeNSView(context _: Context) -> WeekRowRangeGestureSurfaceView {
        WeekRowRangeGestureSurfaceView(
            date: date,
            hitSurface: .emptySurface,
            rootOrigin: rootOrigin,
            onRangeGesture: onRangeGesture
        )
    }

    func updateNSView(_ view: WeekRowRangeGestureSurfaceView, context _: Context) {
        view.update(
            date: date,
            hitSurface: .emptySurface,
            rootOrigin: rootOrigin,
            onRangeGesture: onRangeGesture
        )
    }
}

/// ObjC-safe target for AppKit menus (SwiftUI-hosted NSViews can drop MainActor selectors).
private final class ItemContextMenuTarget: NSObject {
    var onEdit: () -> Void = {}
    var onPriority: (ItemPriority) -> Void = { _ in }
    var onPin: () -> Void = {}
    var onDelete: () -> Void = {}

    @objc func edit() { onEdit() }
    @objc func priorityP0() { onPriority(.p0) }
    @objc func priorityP1() { onPriority(.p1) }
    @objc func priorityP2() { onPriority(.p2) }
    @objc func priorityNone() { onPriority(.none) }
    @objc func pin() { onPin() }
    @objc func deleteItem() { onDelete() }
}

/// Opaque AppKit hit layer over month chips: owns drag/resize + right-click menu.
///
/// Trackpad secondary click is often swallowed by SwiftUI before `rightMouseDown`
/// reaches a representable. A local event monitor catches it first.
final class WeekRowItemGestureSurfaceView: NSView {
    private var source: ProjectedEntry
    private var weekStart: CalendarDate
    private var startColumn: Int
    private var endColumn: Int
    private var columnWidth: CGFloat
    private var rootOrigin: CGPoint
    private var showsLeadingHandle: Bool
    private var showsTrailingHandle: Bool
    private var isPinned: Bool
    private var onItemGesture: (WeekRowItemGesture) -> Void
    private var onClick: (CalendarInteractionHitTarget) -> Void
    private let menuTarget = ItemContextMenuTarget()
    private var trackedTarget: CalendarInteractionHitTarget?
    private var trackedRootPoint: CGPoint?
    /// Stored as nonisolated(unsafe) so teardown is safe from deinit under Swift 6.
    nonisolated(unsafe) private var secondaryClickMonitor: Any?
    private var rightClickRecognizer: NSClickGestureRecognizer?
    private var isPresentingContextMenu = false

    override var isFlipped: Bool { true }

    init(
        source: ProjectedEntry,
        weekStart: CalendarDate,
        startColumn: Int,
        endColumn: Int,
        columnWidth: CGFloat,
        rootOrigin: CGPoint,
        showsLeadingHandle: Bool,
        showsTrailingHandle: Bool,
        isPinned: Bool,
        onItemGesture: @escaping (WeekRowItemGesture) -> Void,
        onClick: @escaping (CalendarInteractionHitTarget) -> Void,
        onEdit: @escaping () -> Void,
        onPriority: @escaping (ItemPriority) -> Void,
        onPin: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.source = source
        self.weekStart = weekStart
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.columnWidth = columnWidth
        self.rootOrigin = rootOrigin
        self.showsLeadingHandle = showsLeadingHandle
        self.showsTrailingHandle = showsTrailingHandle
        self.isPinned = isPinned
        self.onItemGesture = onItemGesture
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        menuTarget.onEdit = onEdit
        menuTarget.onPriority = onPriority
        menuTarget.onPin = onPin
        menuTarget.onDelete = onDelete
        installRightClickRecognizer()
        // Keep AppKit `menu` property in sync so system presentation also works.
        menu = makeContextMenu()
    }

    deinit {
        if let secondaryClickMonitor {
            NSEvent.removeMonitor(secondaryClickMonitor)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        source: ProjectedEntry,
        weekStart: CalendarDate,
        startColumn: Int,
        endColumn: Int,
        columnWidth: CGFloat,
        rootOrigin: CGPoint,
        showsLeadingHandle: Bool,
        showsTrailingHandle: Bool,
        isPinned: Bool,
        onItemGesture: @escaping (WeekRowItemGesture) -> Void,
        onClick: @escaping (CalendarInteractionHitTarget) -> Void,
        onEdit: @escaping () -> Void,
        onPriority: @escaping (ItemPriority) -> Void,
        onPin: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.source = source
        self.weekStart = weekStart
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.columnWidth = columnWidth
        self.rootOrigin = rootOrigin
        self.showsLeadingHandle = showsLeadingHandle
        self.showsTrailingHandle = showsTrailingHandle
        self.isPinned = isPinned
        self.onItemGesture = onItemGesture
        self.onClick = onClick
        menuTarget.onEdit = onEdit
        menuTarget.onPriority = onPriority
        menuTarget.onPin = onPin
        menuTarget.onDelete = onDelete
        menu = makeContextMenu()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tearDownSecondaryClickMonitor()
        } else {
            installSecondaryClickMonitor()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if Self.isSecondaryClick(event) {
            showContextMenu(with: event)
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        let rootPoint = rootPoint(for: localPoint)
        let target = WeekRowItemHitRouting.target(
            atX: localPoint.x,
            width: bounds.width,
            kind: source.kind,
            showsLeadingHandle: showsLeadingHandle,
            showsTrailingHandle: showsTrailingHandle
        )
        trackedTarget = target
        trackedRootPoint = rootPoint
        onItemGesture(.began(date(atLocalX: localPoint.x), target, source, rootPoint))
    }

    override func mouseDragged(with event: NSEvent) {
        guard trackedTarget != nil else { return }
        onItemGesture(.changed(rootPoint(for: convert(event.locationInWindow, from: nil))))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            trackedTarget = nil
            trackedRootPoint = nil
        }
        guard let trackedTarget, let trackedRootPoint else { return }
        let point = rootPoint(for: convert(event.locationInWindow, from: nil))
        onItemGesture(.ended(point))
        guard hypot(point.x - trackedRootPoint.x, point.y - trackedRootPoint.y)
            < CalendarInteractionCoordinator.dragThreshold
        else {
            return
        }
        onClick(trackedTarget)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu()
    }

    private func installRightClickRecognizer() {
        let recognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleRightClickRecognizer(_:))
        )
        recognizer.buttonMask = 0x2 // right / secondary
        recognizer.numberOfClicksRequired = 1
        addGestureRecognizer(recognizer)
        rightClickRecognizer = recognizer
    }

    @objc private func handleRightClickRecognizer(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, let event = NSApp.currentEvent else { return }
        showContextMenu(with: event)
    }

    /// Runs before SwiftUI can swallow trackpad secondary clicks.
    private func installSecondaryClickMonitor() {
        tearDownSecondaryClickMonitor()
        secondaryClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.window != nil, event.window === self.window else { return event }
            guard Self.isSecondaryClick(event) else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point), !self.isHidden, self.alphaValue > 0.01 else {
                return event
            }
            self.showContextMenu(with: event)
            return nil
        }
    }

    private func tearDownSecondaryClickMonitor() {
        if let secondaryClickMonitor {
            NSEvent.removeMonitor(secondaryClickMonitor)
            self.secondaryClickMonitor = nil
        }
    }

    private static func isSecondaryClick(_ event: NSEvent) -> Bool {
        if event.type == .rightMouseDown { return true }
        if event.buttonNumber == 1 { return true }
        if event.type == .leftMouseDown, event.modifierFlags.contains(.control) { return true }
        return false
    }

    private func showContextMenu(with event: NSEvent) {
        guard !isPresentingContextMenu else { return }
        isPresentingContextMenu = true
        defer { isPresentingContextMenu = false }

        if trackedTarget != nil {
            onItemGesture(.ended(rootPoint(for: convert(event.locationInWindow, from: nil))))
            trackedTarget = nil
            trackedRootPoint = nil
        }
        let menu = makeContextMenu()
        self.menu = menu
        let localPoint = convert(event.locationInWindow, from: nil)
        // `popUp(positioning:at:in:)` is more reliable than popUpContextMenu under SwiftUI.
        menu.popUp(positioning: nil, at: localPoint, in: self)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "事项")
        menu.autoenablesItems = false
        menu.addItem(menuItem(title: "编辑", action: #selector(ItemContextMenuTarget.edit)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "P0", action: #selector(ItemContextMenuTarget.priorityP0)))
        menu.addItem(menuItem(title: "P1", action: #selector(ItemContextMenuTarget.priorityP1)))
        menu.addItem(menuItem(title: "P2", action: #selector(ItemContextMenuTarget.priorityP2)))
        menu.addItem(menuItem(title: "清除优先级", action: #selector(ItemContextMenuTarget.priorityNone)))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: isPinned ? "取消置顶" : "置顶（P0）",
            action: #selector(ItemContextMenuTarget.pin)
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "删除", action: #selector(ItemContextMenuTarget.deleteItem)))
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = menuTarget
        item.isEnabled = true
        return item
    }

    private func date(atLocalX x: CGFloat) -> CalendarDate {
        guard columnWidth > 0 else { return weekStart.addingDays(startColumn) }
        let localColumn = min(
            max(Int(floor(x / columnWidth)), 0),
            endColumn - startColumn
        )
        return weekStart.addingDays(startColumn + localColumn)
    }

    private func rootPoint(for localPoint: CGPoint) -> CGPoint {
        CGPoint(x: rootOrigin.x + localPoint.x, y: rootOrigin.y + localPoint.y)
    }
}

private struct WeekRowItemGestureSurface: NSViewRepresentable {
    let source: ProjectedEntry
    let weekStart: CalendarDate
    let startColumn: Int
    let endColumn: Int
    let columnWidth: CGFloat
    let rootOrigin: CGPoint
    let showsLeadingHandle: Bool
    let showsTrailingHandle: Bool
    let isPinned: Bool
    let onItemGesture: (WeekRowItemGesture) -> Void
    let onClick: (CalendarInteractionHitTarget) -> Void
    let onEdit: () -> Void
    let onPriority: (ItemPriority) -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    func makeNSView(context _: Context) -> WeekRowItemGestureSurfaceView {
        WeekRowItemGestureSurfaceView(
            source: source,
            weekStart: weekStart,
            startColumn: startColumn,
            endColumn: endColumn,
            columnWidth: columnWidth,
            rootOrigin: rootOrigin,
            showsLeadingHandle: showsLeadingHandle,
            showsTrailingHandle: showsTrailingHandle,
            isPinned: isPinned,
            onItemGesture: onItemGesture,
            onClick: onClick,
            onEdit: onEdit,
            onPriority: onPriority,
            onPin: onPin,
            onDelete: onDelete
        )
    }

    func updateNSView(_ view: WeekRowItemGestureSurfaceView, context _: Context) {
        view.update(
            source: source,
            weekStart: weekStart,
            startColumn: startColumn,
            endColumn: endColumn,
            columnWidth: columnWidth,
            rootOrigin: rootOrigin,
            showsLeadingHandle: showsLeadingHandle,
            showsTrailingHandle: showsTrailingHandle,
            isPinned: isPinned,
            onItemGesture: onItemGesture,
            onClick: onClick,
            onEdit: onEdit,
            onPriority: onPriority,
            onPin: onPin,
            onDelete: onDelete
        )
    }
}

enum WeekRowRangeGesture {
    case began(CalendarDate, CalendarInteractionHitTarget, CGPoint)
    case changed(CGPoint)
    case ended(CGPoint)

    static func target(for target: DayCellHitTarget) -> CalendarInteractionHitTarget {
        switch target {
        case .emptyArea:
            WeekRowHitRouting.selectionTarget(for: .emptySurface) ?? .emptyCell
        case .dateNumber:
            .dateNumber
        case .overflow:
            .overflow
        case .item:
            .barBody
        }
    }
}

enum WeekRowItemGesture {
    case began(CalendarDate, CalendarInteractionHitTarget, ProjectedEntry, CGPoint)
    case changed(CGPoint)
    case ended(CGPoint)
}

struct WeekRowView: View {
    let layout: WeekLayout
    let today: CalendarDate
    let selectedDate: CalendarDate?
    let categories: [UUID: CalendarCategory]
    @ObservedObject var dropCoordinator: CalendarDropCoordinator
    let onAction: (DayCellAction) -> Void
    let onCompletion: (CalendarCommand) -> Void
    var onDelete: ((ProjectedItem) -> Void)?
    let selectionRange: CalendarDateRange?
    let onRangeGesture: (WeekRowRangeGesture) -> Void
    let onItemGesture: (WeekRowItemGesture) -> Void
    var height: CGFloat = WeekRowMetrics.defaultHeight

    private var presentation: WeekRowPresentation {
        WeekRowPresentation(layout: layout, categories: categories)
    }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let date = layout.weekStart.addingDays(column)
                        WeekRowDateCell(
                            date: date,
                            isToday: date == today,
                            isSelected: date == selectedDate,
                            isInSelection: selectionRange.map { $0.start <= date && date <= $0.end } ?? false,
                            overflow: presentation.overflowCount(for: date),
                            dropCoordinator: dropCoordinator,
                            onAction: onAction,
                            onRangeGesture: onRangeGesture
                        )
                        .frame(width: columnWidth, height: height)
                    }
                }

                ForEach(presentation.segments) { segment in
                    WeekRowSegmentBar(
                        segment: segment,
                        category: categories[segment.entry.categoryID],
                        weekStart: layout.weekStart,
                        columnWidth: columnWidth,
                        onItemGesture: onItemGesture,
                        onCompletion: onCompletion,
                        onOpenDetail: { item in
                            onAction(.openItem(item.id))
                        },
                        onDelete: onDelete
                    )
                    // Inset chip without expanding dead zones: apply padding inside the frame
                    // so neighboring empty body stays hittable for create.
                    .padding(.horizontal, 2)
                    .frame(
                        width: columnWidth * CGFloat(segment.endColumn - segment.startColumn + 1),
                        height: WeekRowMetrics.laneHeight
                    )
                    .offset(
                        x: columnWidth * CGFloat(segment.startColumn),
                        y: WeekRowMetrics.laneOffset(segment.lane)
                    )
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
            .dropDestination(for: CalendarTransferPayload.self) { payloads, location in
                guard let payload = payloads.first else { return false }
                let destination = WeekRowDropTarget.date(
                    atX: location.x,
                    rowWidth: proxy.size.width,
                    weekStart: layout.weekStart
                )
                Task {
                    try? await dropCoordinator.accept(payload, on: destination)
                }
                return true
            } isTargeted: { _ in
                // Date cells keep the targeted-date highlight; this parent also covers row overlays.
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }
}

private struct WeekRowDateCell: View {
    let date: CalendarDate
    let isToday: Bool
    let isSelected: Bool
    let isInSelection: Bool
    let overflow: Int
    @ObservedObject var dropCoordinator: CalendarDropCoordinator
    let onAction: (DayCellAction) -> Void
    let onRangeGesture: (WeekRowRangeGesture) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        let badge = CalendarDateBadgePresentation(
            date: date,
            isToday: isToday,
            isSelected: isSelected
        )
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    sendDayAction(for: .dateNumber)
                } label: {
                    let dayText = String(date.day)
                    Text(dayText)
                        .font(CalendarTheme.dateFont)
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(dateBadgeFill)
                        .clipShape(Capsule())
                        .overlay {
                            if badge.showsSelectionRing {
                                Capsule()
                                    .stroke(theme.selectionOutline, lineWidth: 1.5)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if badge.showsTodayDot {
                                Circle()
                                    .fill(theme.todayOutline)
                                    .frame(width: 4, height: 4)
                                    .overlay(Circle().stroke(theme.canvas, lineWidth: 0.5))
                                    .offset(y: 2)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(badge.accessibilityLabel)
                .accessibilityValue(badge.accessibilityValue)

                Spacer(minLength: 0)

                if overflow > 0 {
                    Button("还有 \(overflow) 项") {
                        sendDayAction(for: .overflow)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("\(date.month)月\(date.day)日，还有 \(overflow) 项，打开当天事项")
                }
            }
            .padding(.horizontal, CalendarTheme.cellPadding)
            .frame(height: WeekRowMetrics.dateHeaderHeight)
            GeometryReader { proxy in
                WeekRowEmptyRangeGestureSurface(
                    date: date,
                    rootOrigin: proxy.frame(
                        in: .named(CalendarInteractionCoordinateSpace.root)
                    ).origin,
                    onRangeGesture: onRangeGesture
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .background {
            Rectangle()
                .fill(isInSelection ? theme.rangePreviewFill : theme.canvas)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CalendarDateFramePreferenceKey.self,
                    value: [.init(
                        date: date,
                        frame: proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root))
                    )]
                )
            }
        }
        .overlay {
            Rectangle().stroke(theme.separator, lineWidth: 0.5)
            if isInSelection {
                Rectangle()
                    .inset(by: 2)
                    .stroke(
                        theme.rangePreviewOutline,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if dropCoordinator.dropTargetDate == date {
                Rectangle()
                    .fill(theme.dragPreviewFill)
                    .allowsHitTesting(false)
                    .overlay(Rectangle().inset(by: 1).stroke(theme.dragPreviewOutline, lineWidth: 1.5))
                    .overlay(alignment: .bottomLeading) {
                        Text("移到 \(date.month)月\(date.day)日")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .padding(4)
                    }
            }
        }
        .dropDestination(for: CalendarTransferPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            Task {
                try? await dropCoordinator.accept(payload, on: date)
            }
            return true
        } isTargeted: { isTargeted in
            dropCoordinator.setTargeted(isTargeted, date: date)
        }
    }

    private var dateBadgeFill: Color {
        if isSelected { return theme.selectionFill }
        if isToday { return theme.todayFill }
        return .clear
    }

    private func sendDayAction(for surface: WeekRowHitSurface) {
        guard let action = WeekRowHitRouting.dayAction(for: surface, date: date) else { return }
        onAction(action)
    }
}

private struct WeekRowSegmentBar: View {
    let segment: WeekRowSegmentPresentation
    let category: CalendarCategory?
    let weekStart: CalendarDate
    let columnWidth: CGFloat
    let onItemGesture: (WeekRowItemGesture) -> Void
    let onCompletion: (CalendarCommand) -> Void
    let onOpenDetail: (ProjectedItem) -> Void
    var onDelete: ((ProjectedItem) -> Void)?

    @State private var isItemDragging = false
    @State private var barFrameInRoot: CGRect = .zero

    var body: some View {
        CalendarItemRow(
            item: projectedItem,
            category: category,
            onCompletion: onCompletion,
            onOpenDetail: onOpenDetail,
            onDelete: { onDelete?(projectedItem) },
            accessibilityLabelOverride: segment.accessibilityLabel,
            accessibilityValueOverride: segment.accessibilityValue,
            continuesBefore: segment.continuesBefore,
            continuesAfter: segment.continuesAfter,
            showsLeadingHandle: segment.showsLeadingHandle,
            showsTrailingHandle: segment.showsTrailingHandle,
            leadingHandleAccessibility: segment.leadingHandleAccessibility,
            trailingHandleAccessibility: segment.trailingHandleAccessibility
        )
        .accessibilityIdentifier(stableAccessibilityIdentifier)
        .accessibilityValue(segment.accessibilityValue)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WeekRowSegmentFramePreferenceKey.self,
                    value: proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root))
                )
            }
        }
        .onPreferenceChange(WeekRowSegmentFramePreferenceKey.self) { frame in
            barFrameInRoot = frame
        }
        // highPriority so edge resize isn't stolen by system .draggable / tap.
        // minimumDistance keeps short clicks free for open-detail.
        .highPriorityGesture(itemDragGesture)
    }

    private var itemDragGesture: some Gesture {
        DragGesture(
            minimumDistance: CalendarInteractionCoordinator.dragThreshold,
            coordinateSpace: .named(CalendarInteractionCoordinateSpace.root)
        )
        .onChanged { value in
            if !isItemDragging {
                isItemDragging = true
                let localX = value.startLocation.x - barFrameInRoot.minX
                let target = WeekRowItemHitRouting.target(
                    atX: localX,
                    width: max(barFrameInRoot.width, 1),
                    kind: segment.entry.kind,
                    showsLeadingHandle: segment.showsLeadingHandle,
                    showsTrailingHandle: segment.showsTrailingHandle
                )
                // Completion is a button; don't start a drag from it.
                guard target != .completionButton else {
                    isItemDragging = false
                    return
                }
                onItemGesture(
                    .began(
                        dateAtLocalX(localX),
                        target,
                        segment.entry,
                        value.startLocation
                    )
                )
            }
            guard isItemDragging else { return }
            onItemGesture(.changed(value.location))
        }
        .onEnded { value in
            guard isItemDragging else { return }
            isItemDragging = false
            onItemGesture(.ended(value.location))
        }
    }

    private func dateAtLocalX(_ x: CGFloat) -> CalendarDate {
        guard columnWidth > 0 else {
            return weekStart.addingDays(segment.startColumn)
        }
        let localColumn = min(
            max(Int(floor(x / columnWidth)), 0),
            segment.endColumn - segment.startColumn
        )
        return weekStart.addingDays(segment.startColumn + localColumn)
    }

    private var projectedItem: ProjectedItem {
        switch segment.entry {
        case let .item(item):
            .item(item)
        case let .occurrence(occurrence):
            .occurrence(occurrence)
        }
    }

    private var stableAccessibilityIdentifier: String {
        switch segment.source {
        case let .item(id):
            "week-segment-item-\(id.uuidString)-\(segment.id.weekStart.year)-\(segment.id.weekStart.month)-\(segment.id.weekStart.day)"
        case let .occurrence(key):
            "week-segment-occurrence-\(key.seriesID.uuidString)-\(key.originalDate.year)-\(key.originalDate.month)-\(key.originalDate.day)-\(segment.id.weekStart.year)-\(segment.id.weekStart.month)-\(segment.id.weekStart.day)"
        }
    }
}

private struct WeekRowSegmentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

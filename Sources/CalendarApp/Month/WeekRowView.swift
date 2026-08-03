import AppKit
import CalendarDomain
import SwiftUI

enum WeekRowMetrics {
    static let defaultHeight: CGFloat = 252
    static let dateHeaderHeight: CGFloat = 24
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
    }

    private static func makeAccessibilityLabel(
        entry: ProjectedEntry,
        categoryName: String,
        continuesBefore: Bool,
        continuesAfter: Bool
    ) -> String {
        var components = [
            entry.kind == .task ? "待办" : "日程",
            categoryName,
            entry.title,
            dateTimeRangeText(for: entry.schedule)
        ]
        if continuesBefore {
            components.append("从前一周继续")
        }
        if continuesAfter {
            components.append("延续到下一周")
        }
        if entry.kind == .task {
            components.append(entry.completedAt == nil ? "未完成" : "已完成")
        }
        return components.joined(separator: "，")
    }

    private static func dateTimeRangeText(for schedule: CalendarSchedule) -> String {
        let includesYear = schedule.startDate.year != schedule.endDate.year
        let startDate = dateText(schedule.startDate, includesYear: includesYear)
        let endDate = dateText(schedule.endDate, includesYear: includesYear)

        guard let startTime = schedule.startTime, let endTime = schedule.endTime else {
            return schedule.startDate == schedule.endDate
                ? startDate
                : "\(startDate)至\(endDate)"
        }

        if schedule.startDate == schedule.endDate {
            return "\(startDate) \(timeText(startTime))至\(timeText(endTime))"
        }
        return "\(startDate) \(timeText(startTime))至\(endDate) \(timeText(endTime))"
    }

    private static func dateText(_ date: CalendarDate, includesYear: Bool) -> String {
        if includesYear {
            return "\(date.year)年\(date.month)月\(date.day)日"
        }
        return "\(date.month)月\(date.day)日"
    }

    private static func timeText(_ time: MinuteOfDay) -> String {
        String(format: "%02d:%02d", time.value / 60, time.value % 60)
    }
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
    static let handleHitWidth: CGFloat = 14
    static let completionHitRange: ClosedRange<CGFloat> = 10...34

    static func target(
        atX x: CGFloat,
        width: CGFloat,
        kind: ItemKind,
        showsLeadingHandle: Bool,
        showsTrailingHandle: Bool
    ) -> CalendarInteractionHitTarget {
        let clampedX = min(max(x, 0), max(0, width))
        if kind == .task, completionHitRange.contains(clampedX) {
            return .completionButton
        }
        if showsLeadingHandle, clampedX <= handleHitWidth {
            return .leadingHandle
        }
        if showsTrailingHandle, clampedX >= max(0, width - handleHitWidth) {
            return .trailingHandle
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

@MainActor
final class WeekRowItemGestureSurfaceView: NSView {
    private var source: ProjectedEntry
    private var weekStart: CalendarDate
    private var startColumn: Int
    private var endColumn: Int
    private var columnWidth: CGFloat
    private var rootOrigin: CGPoint
    private var showsLeadingHandle: Bool
    private var showsTrailingHandle: Bool
    private var onItemGesture: (WeekRowItemGesture) -> Void
    private var onClick: (CalendarInteractionHitTarget) -> Void
    private var trackedTarget: CalendarInteractionHitTarget?
    private var trackedRootPoint: CGPoint?

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
        onItemGesture: @escaping (WeekRowItemGesture) -> Void,
        onClick: @escaping (CalendarInteractionHitTarget) -> Void
    ) {
        self.source = source
        self.weekStart = weekStart
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.columnWidth = columnWidth
        self.rootOrigin = rootOrigin
        self.showsLeadingHandle = showsLeadingHandle
        self.showsTrailingHandle = showsTrailingHandle
        self.onItemGesture = onItemGesture
        self.onClick = onClick
        super.init(frame: .zero)
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
        onItemGesture: @escaping (WeekRowItemGesture) -> Void,
        onClick: @escaping (CalendarInteractionHitTarget) -> Void
    ) {
        self.source = source
        self.weekStart = weekStart
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.columnWidth = columnWidth
        self.rootOrigin = rootOrigin
        self.showsLeadingHandle = showsLeadingHandle
        self.showsTrailingHandle = showsTrailingHandle
        self.onItemGesture = onItemGesture
        self.onClick = onClick
    }

    override func mouseDown(with event: NSEvent) {
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

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
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
    let onItemGesture: (WeekRowItemGesture) -> Void
    let onClick: (CalendarInteractionHitTarget) -> Void

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
            onItemGesture: onItemGesture,
            onClick: onClick
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
            onItemGesture: onItemGesture,
            onClick: onClick
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
                        }
                    )
                    .frame(
                        width: columnWidth * CGFloat(segment.endColumn - segment.startColumn + 1),
                        height: WeekRowMetrics.laneHeight
                    )
                    .offset(
                        x: columnWidth * CGFloat(segment.startColumn),
                        y: WeekRowMetrics.laneOffset(segment.lane)
                    )
                    .padding(.horizontal, 2)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    sendDayAction(for: .dateNumber)
                } label: {
                    Text("\(date.day)")
                        .font(CalendarTheme.dateFont)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isToday || isSelected ? CalendarTheme.selectedDay : .clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(date.month)月\(date.day)日，打开当天事项")

                Spacer(minLength: 0)

                if overflow > 0 {
                    Button("还有 \(overflow) 项") {
                        sendDayAction(for: .overflow)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(date.month)月\(date.day)日，还有 \(overflow) 项，打开当天事项")
                }
            }
            .padding(.horizontal, CalendarTheme.cellPadding)
            .frame(height: WeekRowMetrics.dateHeaderHeight)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .background {
            Rectangle()
                .fill(isInSelection ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
                .overlay {
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
        .overlay(Rectangle().stroke(CalendarTheme.gridStroke, lineWidth: 0.5))
        .overlay {
            if dropCoordinator.dropTargetDate == date {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottomLeading) {
                        Text("移到 \(date.month)月\(date.day)日")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
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

    var body: some View {
        CalendarItemRow(
            item: projectedItem,
            category: category,
            onCompletion: onCompletion,
            onOpenDetail: onOpenDetail,
            accessibilityLabelOverride: segment.accessibilityLabel,
            continuesBefore: segment.continuesBefore,
            continuesAfter: segment.continuesAfter,
            showsLeadingHandle: segment.showsLeadingHandle,
            showsTrailingHandle: segment.showsTrailingHandle
        )
        .accessibilityIdentifier(stableAccessibilityIdentifier)
        .overlay {
            GeometryReader { proxy in
                WeekRowItemGestureSurface(
                    source: segment.entry,
                    weekStart: weekStart,
                    startColumn: segment.startColumn,
                    endColumn: segment.endColumn,
                    columnWidth: columnWidth,
                    rootOrigin: proxy.frame(
                        in: .named(CalendarInteractionCoordinateSpace.root)
                    ).origin,
                    showsLeadingHandle: segment.showsLeadingHandle,
                    showsTrailingHandle: segment.showsTrailingHandle,
                    onItemGesture: onItemGesture,
                    onClick: routeClick
                )
                .accessibilityHidden(true)
            }
        }
    }

    private func routeClick(_ target: CalendarInteractionHitTarget) {
        switch target {
        case .completionButton:
            if let command = ItemCompletionRouter.command(for: projectedItem, now: Date()) {
                onCompletion(command)
            }
        case .barBody:
            onOpenDetail(projectedItem)
        case .leadingHandle, .trailingHandle, .dateNumber, .overflow, .emptyCell:
            break
        }
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

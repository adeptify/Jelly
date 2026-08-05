import CalendarDomain
import SwiftUI

enum WeekTimeGridMetrics {
    static let hourHeight: CGFloat = 48
    static let hourCount = 24
    static let gutterWidth: CGFloat = 48
    static let allDayRowMinHeight: CGFloat = 28
    static let dayHeaderHeight: CGFloat = 40

    static var gridHeight: CGFloat {
        CGFloat(hourCount) * hourHeight
    }

    static func yOffset(minute: Int) -> CGFloat {
        CGFloat(minute) / 60 * hourHeight
    }

    static func blockHeight(startMinute: Int, endMinute: Int) -> CGFloat {
        max(hourHeight * 0.35, yOffset(minute: endMinute - startMinute))
    }
}

struct WeekView: View {
    let store: CalendarStore
    @ObservedObject var model: WeekViewModel
    let categories: [CalendarCategory]
    @Binding var hiddenCategoryIDs: Set<UUID>
    let onOpenDetail: (ProjectedItem) -> Void
    let onCreate: (CalendarDate) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var categoryByID: [UUID: CalendarCategory] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            allDaySection
            Divider().overlay(theme.separator)
            timedScrollGrid
        }
        .background(theme.canvas)
        .onChange(of: store.state) { _, _ in
            model.update(
                state: store.state,
                hiddenCategoryIDs: hiddenCategoryIDs,
                today: model.today
            )
        }
        .onChange(of: hiddenCategoryIDs) { _, ids in
            model.update(state: store.state, hiddenCategoryIDs: ids, today: model.today)
        }
    }

    private var allDaySection: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("全天")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: WeekTimeGridMetrics.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 6)
            ForEach(Array(model.dayStarts.enumerated()), id: \.offset) { dayIndex, day in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.allDayItems(on: dayIndex)) { item in
                        weekChip(entry: item.entry, compactTime: nil)
                    }
                    if model.allDayItems(on: dayIndex).isEmpty {
                        Color.clear.frame(height: 4)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: WeekTimeGridMetrics.allDayRowMinHeight, alignment: .topLeading)
                .padding(.horizontal, 3)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { onCreate(day) }
                if dayIndex < 6 {
                    Rectangle().fill(theme.separator).frame(width: 0.5)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var timedScrollGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourBackground
                    timedBlocksLayer
                }
                .frame(height: WeekTimeGridMetrics.gridHeight)
                .padding(.bottom, 12)
                .id("week-grid")
            }
            .onAppear {
                // Scroll toward a useful daytime band (08:00).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo("hour-8", anchor: .top)
                    }
                }
            }
        }
    }

    private var hourBackground: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<WeekTimeGridMetrics.hourCount, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                        .frame(
                            width: WeekTimeGridMetrics.gutterWidth,
                            height: WeekTimeGridMetrics.hourHeight,
                            alignment: .topTrailing
                        )
                        .padding(.trailing, 6)
                        .offset(y: -6)
                        .id("hour-\(hour)")
                }
            }
            ForEach(0..<7, id: \.self) { dayIndex in
                ZStack {
                    VStack(spacing: 0) {
                        ForEach(0..<WeekTimeGridMetrics.hourCount, id: \.self) { _ in
                            Rectangle()
                                .fill(theme.separator.opacity(0.55))
                                .frame(height: 0.5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .frame(height: WeekTimeGridMetrics.hourHeight)
                        }
                    }
                    if model.dayStarts[dayIndex] == model.today {
                        theme.todayFill.opacity(0.18)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onCreate(model.dayStarts[dayIndex]) }
                if dayIndex < 6 {
                    Rectangle().fill(theme.separator).frame(width: 0.5)
                }
            }
        }
    }

    private var timedBlocksLayer: some View {
        GeometryReader { proxy in
            let dayWidth = max(0, (proxy.size.width - WeekTimeGridMetrics.gutterWidth) / 7)
            ForEach(model.timedBlocks()) { block in
                let x = WeekTimeGridMetrics.gutterWidth + CGFloat(block.dayIndex) * dayWidth + 2
                let y = WeekTimeGridMetrics.yOffset(minute: block.startMinute)
                let height = WeekTimeGridMetrics.blockHeight(
                    startMinute: block.startMinute,
                    endMinute: block.endMinute
                )
                weekChip(
                    entry: block.entry,
                    compactTime: CalendarItemRowPresentation.displayTimeText(for: block.entry.schedule)
                )
                .frame(width: max(24, dayWidth - 4), height: height, alignment: .topLeading)
                .position(x: x + (dayWidth - 4) / 2, y: y + height / 2)
            }
        }
        .padding(.leading, 0)
    }

    @ViewBuilder
    private func weekChip(entry: ProjectedEntry, compactTime: String?) -> some View {
        let item = ProjectedItem(entry: entry)
        let category = categoryByID[entry.categoryID]
        let hex = category?.colorHex ?? "#8C8F96"
        let roles = CalendarTheme.categoryItemRoles(
            hex,
            isCompleted: item.completedAt != nil,
            appearance: appearance
        )
        let background = roles.map { CalendarTheme.categoryColor($0.background) }
            ?? CalendarTheme.itemBackground(CalendarTheme.categoryColor(hex), appearance: appearance)
        let text = roles.map { CalendarTheme.categoryColor($0.text) } ?? theme.primaryText
        let accent = roles.map { CalendarTheme.categoryColor($0.accent) } ?? CalendarTheme.categoryColor(hex)

        Button {
            onOpenDetail(item)
        } label: {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: item.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accent.opacity(0.8))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        ItemPriorityBadge(priority: item.priority, isPinned: item.isPinned)
                        if let compactTime {
                            Text(compactTime)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .opacity(0.8)
                        }
                    }
                    Text(entry.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(text)
            .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(item.completedAt == nil ? 1 : CalendarTheme.completedItemOpacity(for: appearance))
        }
        .buttonStyle(.plain)
        .help(entry.title)
        .contextMenu {
            Button("编辑") { onOpenDetail(item) }
            Divider()
            // Priority/pin/delete for week grid use the same edit entry; full actions live on month chips.
        }
    }
}


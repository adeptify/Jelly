import CalendarDomain
import SwiftUI

struct MonthView: View {
    let store: CalendarStore
    @StateObject private var model: MonthViewModel
    @State private var hiddenCategoryIDs: Set<UUID> = []

    init(store: CalendarStore) {
        self.store = store
        let today = CalendarDate.localDay(containing: Date(), in: .current)
        _model = StateObject(wrappedValue: MonthViewModel(
            displayedMonth: today,
            state: store.state,
            hiddenCategoryIDs: [],
            today: today
        ))
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
                        DayCellView(
                            cell: model.cell(for: date),
                            capacity: MonthLayout.itemCapacity(cellHeight: proxy.size.height / 6),
                            model: model,
                            categories: store.state.categories,
                            selectedDate: $model.selectedDate
                        )
                        .frame(height: proxy.size.height / 6)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refreshProjection() }
        .onChange(of: store.state) { _, _ in refreshProjection() }
        .onChange(of: hiddenCategoryIDs) { _, _ in refreshProjection() }
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
                if store.state.items.isEmpty && store.state.recurrence.series.isEmpty {
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
            Button("今天") { model.goToToday(CalendarDate.localDay(containing: Date(), in: .current)) }
            Button { model.goToNextMonth() } label: {
                Image(systemName: "chevron.right")
            }
            .help("下个月")
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
            get: { store.loadError != nil || store.mutationError != nil },
            set: { if !$0 { store.dismissErrors() } }
        )
    }

    private func refreshProjection() {
        model.update(
            state: store.state,
            hiddenCategoryIDs: hiddenCategoryIDs,
            today: CalendarDate.localDay(containing: Date(), in: .current)
        )
    }
}

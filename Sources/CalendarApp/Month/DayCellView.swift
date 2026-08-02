import CalendarDomain
import SwiftUI

struct DayCellView: View {
    let cell: MonthCellModel
    let capacity: Int
    let model: MonthViewModel
    let categories: [UUID: CalendarCategory]
    @Binding var selectedDate: CalendarDate?

    var body: some View {
        let visibleItems = model.visibleItems(in: cell, capacity: capacity)
        let overflow = model.overflowCount(in: cell, capacity: capacity)

        VStack(alignment: .leading, spacing: CalendarTheme.itemSpacing) {
            HStack {
                Text("\(cell.date.day)")
                    .font(CalendarTheme.dateFont)
                    .foregroundStyle(cell.isInDisplayedMonth ? .primary : .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(cell.isToday || selectedDate == cell.date ? CalendarTheme.selectedDay : .clear)
                    .clipShape(Capsule())
                Spacer(minLength: 0)
            }

            ForEach(visibleItems) { item in
                CalendarItemRow(item: item, category: categories[item.categoryID])
            }
            if overflow > 0 {
                Text("还有 \(overflow) 项")
                    .font(CalendarTheme.itemFont)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(CalendarTheme.cellPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().stroke(CalendarTheme.gridStroke, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { selectedDate = cell.date }
    }
}

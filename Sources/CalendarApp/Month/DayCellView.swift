import CalendarDomain
import SwiftUI

enum DayCellHitTarget: Equatable {
    case dateNumber
    case emptyArea
    case item(String)
    case overflow
}

enum DayCellAction: Equatable {
    case openDay(CalendarDate)
    case quickCreate(CalendarDate)
    case openItem(String)
}

enum DayCellInteractionRouter {
    static func action(for target: DayCellHitTarget, date: CalendarDate) -> DayCellAction {
        switch target {
        case .dateNumber, .overflow:
            .openDay(date)
        case .emptyArea:
            .quickCreate(date)
        case let .item(id):
            .openItem(id)
        }
    }
}

struct DayCellView: View {
    let cell: MonthCellModel
    let capacity: Int
    let model: MonthViewModel
    let categories: [UUID: CalendarCategory]
    let onAction: (DayCellAction) -> Void
    let onCompletion: (CalendarCommand) -> Void

    var body: some View {
        let visibleItems = model.visibleItems(in: cell, capacity: capacity)
        let overflow = model.overflowCount(in: cell, capacity: capacity)

        VStack(alignment: .leading, spacing: CalendarTheme.itemSpacing) {
            HStack {
                Button {
                    onAction(DayCellInteractionRouter.action(for: .dateNumber, date: cell.date))
                } label: {
                    Text("\(cell.date.day)")
                        .font(CalendarTheme.dateFont)
                        .foregroundStyle(cell.isInDisplayedMonth ? .primary : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(cell.isToday || model.selectedDate == cell.date ? CalendarTheme.selectedDay : .clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }

            ForEach(visibleItems) { item in
                CalendarItemRow(
                    item: item,
                    category: categories[item.categoryID],
                    onCompletion: onCompletion,
                    onOpenDetail: { opened in
                        onAction(DayCellInteractionRouter.action(for: .item(opened.id), date: cell.date))
                    }
                )
            }
            if overflow > 0 {
                Button("还有 \(overflow) 项") {
                    onAction(DayCellInteractionRouter.action(for: .overflow, date: cell.date))
                }
                .buttonStyle(.plain)
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
        .background {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    onAction(DayCellInteractionRouter.action(for: .emptyArea, date: cell.date))
                }
        }
    }
}

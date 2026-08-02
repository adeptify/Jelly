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

enum DayCellSurfaceInteraction {
    static func backgroundAction(for date: CalendarDate) -> DayCellAction {
        .quickCreate(date)
    }

    static func controlAction(for target: DayCellHitTarget, date: CalendarDate) -> DayCellAction {
        DayCellInteractionRouter.action(for: target, date: date)
    }
}

struct DayCellView: View {
    let cell: MonthCellModel
    let capacity: Int
    let model: MonthViewModel
    let categories: [UUID: CalendarCategory]
    @ObservedObject var dropCoordinator: CalendarDropCoordinator
    let onAction: (DayCellAction) -> Void
    let onCompletion: (CalendarCommand) -> Void

    var body: some View {
        let visibleItems = model.visibleItems(in: cell, capacity: capacity)
        let overflow = model.overflowCount(in: cell, capacity: capacity)

        VStack(alignment: .leading, spacing: CalendarTheme.itemSpacing) {
            HStack {
                Button {
                    onAction(DayCellSurfaceInteraction.controlAction(for: .dateNumber, date: cell.date))
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
                        onAction(DayCellSurfaceInteraction.controlAction(for: .item(opened.id), date: cell.date))
                    }
                )
            }
            if overflow > 0 {
                Button("还有 \(overflow) 项") {
                    onAction(DayCellSurfaceInteraction.controlAction(for: .overflow, date: cell.date))
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
        .background {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture {
                    onAction(DayCellSurfaceInteraction.backgroundAction(for: cell.date))
                }
        }
        .overlay(Rectangle().stroke(CalendarTheme.gridStroke, lineWidth: 0.5))
        .overlay {
            if dropCoordinator.dropTargetDate == cell.date {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottomLeading) {
                        Text("移到 \(cell.date.month)月\(cell.date.day)日")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(4)
                    }
            }
        }
        .dropDestination(for: CalendarTransferPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            Task {
                try? await dropCoordinator.accept(payload, on: cell.date)
            }
            return true
        } isTargeted: { isTargeted in
            dropCoordinator.setTargeted(isTargeted, date: cell.date)
        }
    }
}

import CalendarDomain

enum DayCellHitTarget: Equatable {
    case dateNumber
    case emptyArea
    case overflow
    case item(String)
}

enum DayCellAction: Equatable {
    case quickCreate(CalendarDate)
    case openDay(CalendarDate)
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

import CalendarDomain

enum CalendarNewItemRequestPolicy {
    static func resolve(
        dayDrawerDate: CalendarDate?,
        selectedDate: CalendarDate?,
        today: CalendarDate,
        isQuickCreatePresented: Bool,
        isItemEditorPresented: Bool
    ) -> CalendarDate? {
        guard !isQuickCreatePresented, !isItemEditorPresented else { return nil }
        return dayDrawerDate ?? selectedDate ?? today
    }
}

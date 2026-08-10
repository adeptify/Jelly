import Testing
@testable import CalendarApp

@Suite("WorkspaceWindowLayoutTests")
struct WorkspaceWindowLayoutTests {
    @Test func shellKeepsCalendarContentWidthBesideTheFixedRail() {
        #expect(WorkspaceWindowLayout.railWidth == 64)
        #expect(WorkspaceWindowLayout.calendarContentMinimumWidth == 980)
        #expect(WorkspaceWindowLayout.minimumWidth == 1_044)
        #expect(abs(
            WorkspaceWindowLayout.minimumWidth
                - (WorkspaceWindowLayout.railWidth + WorkspaceWindowLayout.calendarContentMinimumWidth)
        ) < 0.001)
        #expect(WorkspaceWindowLayout.minimumHeight == 680)
    }
}

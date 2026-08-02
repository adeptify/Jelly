import Testing
@testable import CalendarApp

@Suite("CalendarAppCommandPolicyTests")
@MainActor
struct CalendarAppCommandPolicyTests {
    @Test func backupCommandsRemainSingleGroupAcrossWindowFocus() {
        #expect(CalendarAppCommandPolicy.installsBackupCommands(in: .mainCalendar))
        #expect(CalendarAppCommandPolicy.installsBackupCommands(in: .categoryManager) == false)
    }
}

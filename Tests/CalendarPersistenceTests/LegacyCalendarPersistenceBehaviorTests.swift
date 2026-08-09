import CalendarDomain
import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

/// Behaviorally equivalent ports of the deleted repository assertions.  These
/// deliberately cross the current Workspace persistence boundary instead of
/// pointing a coverage map at similarly named tests.
@Suite("LegacyCalendarPersistenceBehaviorTests")
struct LegacyCalendarPersistenceBehaviorTests {
    @Test func legacySaveThenReopenRoundTripsState() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        var expected = WorkspaceState.empty(calendar: try legacyPopulatedCalendarState())
        expected.revision = 7
        let seed = expected
        let url = directory.file("workspace.json")
        let writer = JSONWorkspaceRepository(documentURL: url, seed: { seed })

        _ = try await writer.load()
        _ = try await writer.save(expected)

        let reader = JSONWorkspaceRepository(documentURL: url, seed: { seed })
        #expect(try await reader.load().state == expected)
    }

    @Test func legacySchemaOneMigratesCompleteGraphWithoutChangingIdentity() throws {
        let original = LegacyV1CompleteGraphFixture.data
        let result = try WorkspaceDocumentCodec.decode(original)
        let state = result.state.calendar

        #expect(result.provenance.sourceSchema == 1)
        #expect(state.uncategorizedID == LegacyV1CompleteGraphFixture.categoryID)
        #expect(state.categories[LegacyV1CompleteGraphFixture.categoryID]?.id == LegacyV1CompleteGraphFixture.categoryID)
        #expect(state.items[LegacyV1CompleteGraphFixture.itemID]?.id == LegacyV1CompleteGraphFixture.itemID)
        #expect(state.items[LegacyV1CompleteGraphFixture.itemID]?.completedAt == LegacyV1CompleteGraphFixture.itemCompletionDate)
        #expect(state.recurrence.series[LegacyV1CompleteGraphFixture.seriesID]?.id == LegacyV1CompleteGraphFixture.seriesID)
        #expect(state.recurrence.exceptions[LegacyV1CompleteGraphFixture.movedKey] != nil)
        #expect(state.recurrence.exceptions[LegacyV1CompleteGraphFixture.skippedKey] == .skipped)
        #expect(state.recurrence.completions[LegacyV1CompleteGraphFixture.completionKey]?.key == LegacyV1CompleteGraphFixture.completionKey)
        #expect(state.recurrence.completions[LegacyV1CompleteGraphFixture.completionKey]?.completedAt == LegacyV1CompleteGraphFixture.occurrenceCompletionDate)
        #expect(original == LegacyV1CompleteGraphFixture.data)
    }

    @Test func legacyLoadingSchemaOneDoesNotRewritePrimaryUntilNormalSave() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let primary = directory.file("calendar.json")
        try LegacyV1CompleteGraphFixture.data.write(to: primary)
        let repository = JSONWorkspaceRepository(
            documentURL: primary,
            seed: { .empty(calendar: CalendarState.empty(uncategorizedID: LegacyV1CompleteGraphFixture.categoryID, now: .distantPast)) }
        )

        let migrated = try await repository.load()

        #expect(try Data(contentsOf: primary) == LegacyV1CompleteGraphFixture.data)
        _ = try await repository.save(migrated.state)
        #expect(try legacySchemaVersion(at: primary) == WorkspaceDocument.currentSchemaVersion)
    }

    @Test func legacyUnknownSchemaDoesNotRewritePrimary() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let primary = directory.file("calendar.json")
        let bytes = Data(#"{"schemaVersion":999,"state":"not-a-workspace"}"#.utf8)
        try bytes.write(to: primary)
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { .empty(calendar: try! legacyPopulatedCalendarState()) })

        await #expect(throws: WorkspacePersistenceError.unsupportedSchema(999)) { _ = try await repository.load() }
        #expect(try Data(contentsOf: primary) == bytes)
    }

    @Test func legacyUnsupportedSchemaIsRejectedBeforePayloadDecoding() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let primary = directory.file("calendar.json")
        let bytes = Data(#"{"schemaVersion":999,"state":"not-a-calendar-state"}"#.utf8)
        try bytes.write(to: primary)
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { .empty(calendar: try! legacyPopulatedCalendarState()) })

        await #expect(throws: WorkspacePersistenceError.unsupportedSchema(999)) { _ = try await repository.load() }
        #expect(try Data(contentsOf: primary) == bytes)
    }

    @Test func legacyMissingFileSeedsExactlyOnce() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let counter = LegacyLockedCounter()
        let state = WorkspaceState.empty(calendar: try legacyPopulatedCalendarState())
        let repository = JSONWorkspaceRepository(documentURL: directory.file("calendar.json")) {
            counter.increment()
            return state
        }

        let first = try await repository.load()
        let second = try await repository.load()

        #expect(counter.value == 1)
        #expect(first.state == state)
        #expect(second.state == state)
    }

    @Test func legacyMalformedV1SpanDoesNotOverwritePrimaryOrRollback() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let current = WorkspaceState.empty(calendar: try legacyPopulatedCalendarState())
        let main = directory.file("main.json")
        let source = directory.file("malformed-v1.json")
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        _ = try await repository.save(current)
        let beforeMain = try Data(contentsOf: main)
        let malformed = Data(String(decoding: LegacyV1CompleteGraphFixture.data, as: UTF8.self)
            .replacingOccurrences(of: #""end":{"value":600}"#, with: #""end":{"value":480}"#).utf8)
        try malformed.write(to: source)

        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await BackupService().inspectRestoreSource(source)
        }
        #expect(try Data(contentsOf: main) == beforeMain)
        #expect(try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix("workspace-rollback-") } == false)
    }

    @Test func legacySemanticallyInvalidV1DanglingCategoryDoesNotOverwritePrimaryOrRollback() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let current = WorkspaceState.empty(calendar: try legacyPopulatedCalendarState())
        let main = directory.file("main.json")
        let source = directory.file("dangling-v1.json")
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        _ = try await repository.save(current)
        let beforeMain = try Data(contentsOf: main)
        let dangling = Data(String(decoding: LegacyV1CompleteGraphFixture.data, as: UTF8.self)
            .replacingOccurrences(of: "\"categoryID\":\"00000000-0000-0000-0000-000000000100\"", with: "\"categoryID\":\"00000000-0000-0000-0000-000000000199\"").utf8)
        try dangling.write(to: source)

        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await BackupService().inspectRestoreSource(source)
        }
        #expect(try Data(contentsOf: main) == beforeMain)
        #expect(try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix("workspace-rollback-") } == false)
    }

    @Test func legacyFirstRestoreCreatesMissingRollbackDirectory() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let current = WorkspaceState.empty(calendar: try legacyPopulatedCalendarState())
        var restored = current
        restored.revision = 1
        let source = directory.file("restore.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: directory.file("main.json"), seed: { current })
        _ = try await repository.load()
        let rollbackDirectory = directory.file("Rollbacks")
        #expect(FileManager.default.fileExists(atPath: rollbackDirectory.path) == false)

        let prepared = try await repository.prepareRestore(
            try await BackupService().inspectRestoreSource(source), rollbackDirectoryURL: rollbackDirectory
        )
        _ = try await repository.commitRestore(prepared, state: restored)

        #expect(FileManager.default.fileExists(atPath: rollbackDirectory.path))
        #expect(try await repository.load().state == restored)
    }

    @Test func legacyFractionalDatesRoundTripWithoutChangingSortOrder() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        var calendar = try legacyPopulatedCalendarState()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
        calendar.items[id] = try CalendarItem(
            id: id, kind: .task, title: "排序保持", categoryID: calendar.uncategorizedID,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 3)!, endDate: .init(year: 2026, month: 8, day: 3)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: Date(timeIntervalSince1970: 0.223456), updatedAt: Date(timeIntervalSince1970: 0.223456)
        )
        let expected = WorkspaceState.empty(calendar: calendar)
        let url = directory.file("calendar.json")
        let repository = JSONWorkspaceRepository(documentURL: url, seed: { expected })
        _ = try await repository.load()
        _ = try await repository.save(expected)
        let firstBytes = try Data(contentsOf: url)
        let reopened = JSONWorkspaceRepository(documentURL: url, seed: { expected })
        let decoded = try await reopened.load()
        _ = try await reopened.save(decoded.state)

        #expect(decoded.state.calendar.items[id]?.createdAt == Date(timeIntervalSince1970: 0.223456))
        #expect(decoded.state.calendar.recurrence.completions.values.first?.completedAt == .distantPast)
        #expect(decoded.state.calendar.items.values.sorted { $0.createdAt < $1.createdAt }.map(\.id)
            == expected.calendar.items.values.sorted { $0.createdAt < $1.createdAt }.map(\.id))
        #expect(try Data(contentsOf: url) == firstBytes)
    }

    @Test func legacyCompleteCalendarGraphRoundTripsExactly() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let expected = WorkspaceState.empty(calendar: try legacyPopulatedCalendarState())
        let repository = JSONWorkspaceRepository(documentURL: directory.file("calendar.json"), seed: { expected })
        _ = try await repository.load()
        _ = try await repository.save(expected)

        #expect(try await repository.load().state == expected)
    }
}

private final class LegacyLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private func legacySchemaVersion(at url: URL) throws -> Int {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return try #require(object?["schemaVersion"] as? Int)
}

private enum LegacyV1CompleteGraphFixture {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    static let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    static let movedKey = OccurrenceKey(seriesID: seriesID, originalDate: .init(year: 2026, month: 8, day: 10)!)
    static let skippedKey = OccurrenceKey(seriesID: seriesID, originalDate: .init(year: 2026, month: 8, day: 12)!)
    static let completionKey = OccurrenceKey(seriesID: seriesID, originalDate: .init(year: 2026, month: 8, day: 17)!)
    static let itemCompletionDate = Date(timeIntervalSince1970: 1_700_000_100.25)
    static let occurrenceCompletionDate = Date(timeIntervalSince1970: 1_700_000_300.5)
    static let data = Data(#"""
    {"schemaVersion":1,"state":{"categories":["00000000-0000-0000-0000-000000000100",{"id":"00000000-0000-0000-0000-000000000100","name":"未分类","colorHex":"#8E8E93","sortIndex":0,"createdAt":1700000000000,"updatedAt":1700000000100}],"items":["00000000-0000-0000-0000-000000000101",{"id":"00000000-0000-0000-0000-000000000101","kind":"task","title":"单日事项","categoryID":"00000000-0000-0000-0000-000000000100","date":{"year":2026,"month":8,"day":6},"timeRange":{"start":{"value":540},"end":{"value":600}},"creationTimeZoneIdentifier":"Asia/Shanghai","completedAt":1700000100250,"createdAt":1700000000200,"updatedAt":1700000000300}],"recurrence":{"series":["00000000-0000-0000-0000-000000000102",{"id":"00000000-0000-0000-0000-000000000102","kind":"task","title":"每周回顾","categoryID":"00000000-0000-0000-0000-000000000100","startDate":{"year":2026,"month":8,"day":3},"endDate":{"year":2026,"month":8,"day":31},"weekdays":[1,4],"timeRange":{"start":{"value":570},"end":{"value":615}},"creationTimeZoneIdentifier":"Asia/Shanghai","createdAt":1700000000400,"updatedAt":1700000000500}],"exceptions":[{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":10}},{"modified":{"_0":{"displayedDate":{"year":2026,"month":8,"day":13},"title":"已移动","kind":"task","categoryID":"00000000-0000-0000-0000-000000000100","timeRange":{"start":{"value":660},"end":{"value":720}}}}},{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":12}},{"skipped":{}}],"completions":[{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":17}},{"key":{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":17}},"completedAt":1700000300500}]},"uncategorizedID":"00000000-0000-0000-0000-000000000100"}}
    """#.utf8)
}

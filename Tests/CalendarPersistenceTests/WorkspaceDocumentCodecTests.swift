import CalendarDomain
import CryptoKit
import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceDocumentCodecTests")
struct WorkspaceDocumentCodecTests {
    @Test func v1AndV2LoadThroughTheSingleCalendarMigrationPath() throws {
        let v1 = WorkspacePersistenceFixtures.v1CalendarDocument()
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()

        let v1Result = try WorkspaceDocumentCodec.decode(v1)
        let v2Result = try WorkspaceDocumentCodec.decode(v2)

        #expect(v1Result.provenance.sourceSchema == 1)
        #expect(v1Result.state == .empty(calendar: WorkspacePersistenceFixtures.calendarState))
        #expect(v2Result.provenance.sourceSchema == 2)
        #expect(v2Result.state == .empty(calendar: WorkspacePersistenceFixtures.calendarState))
    }

    @Test func v2LoadReturnsExactRawByteProvenance() throws {
        let data = try WorkspacePersistenceFixtures.v2CalendarDocument()

        let result = try WorkspaceDocumentCodec.decode(data)

        #expect(result.provenance.sourceBytesSHA256 == WorkspacePersistenceFixtures.sha256(data))
        #expect(result.provenance.sourceByteCount == data.count)
        #expect(result.state.calendar == WorkspacePersistenceFixtures.calendarState)
    }

    @Test func v3RoundTripUsesDeterministicEncodingAndPreservesAllWorkspaceContent() throws {
        let expected = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 3)

        let first = try WorkspaceDocumentCodec.encode(expected)
        let second = try WorkspaceDocumentCodec.encode(expected)
        let result = try WorkspaceDocumentCodec.decode(first)

        #expect(first == second)
        #expect(result.provenance.sourceSchema == 3)
        #expect(result.state == expected)
        #expect(result.consistencyIssues.isEmpty)
    }

    @Test func unknownSchemaIsRejectedBeforePayloadDecode() {
        let raw = Data(#"{"schemaVersion":999,"state":"not-a-workspace"}"#.utf8)

        #expect(throws: WorkspacePersistenceError.unsupportedSchema(999)) {
            _ = try WorkspaceDocumentCodec.decode(raw)
        }
    }

    @Test func danglingRelationshipIsReportedWithoutMutatingDecodedContent() throws {
        var workspace = WorkspaceState.empty(calendar: WorkspacePersistenceFixtures.calendarState)
        workspace.calendarNoteRelations.baselines[.item(UUID())] = .init(
            primaryNoteID: nil,
            referenceNoteIDs: []
        )
        let raw = try JSONEncoder.workspaceDeterministic.encode(
            WorkspaceDocument(schemaVersion: 3, state: workspace)
        )

        let result = try WorkspaceDocumentCodec.decode(raw)

        #expect(result.state == workspace)
        #expect(result.consistencyIssues.count == 1)
        #expect(result.consistencyIssues.first?.defect == .missingCalendarOwner)
    }
}

enum WorkspacePersistenceFixtures {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    static let calendarState = CalendarState.empty(
        uncategorizedID: categoryID,
        now: Date(timeIntervalSince1970: 0)
    )

    static func v2CalendarDocument() throws -> Data {
        let encoder = JSONEncoder.workspaceDeterministic
        return try encoder.encode(CalendarDocument(state: calendarState))
    }

    static func v1CalendarDocument() -> Data {
        Data(#"""
        {"schemaVersion":1,"state":{"categories":["00000000-0000-0000-0000-000000000501",{"id":"00000000-0000-0000-0000-000000000501","name":"未分类","colorHex":"#8E8E93","sortIndex":0,"createdAt":0,"updatedAt":0}],"items":[],"recurrence":{"series":[],"exceptions":[],"completions":[]},"uncategorizedID":"00000000-0000-0000-0000-000000000501"}}
        """#.utf8)
    }

    static func workspaceWithOneNote(revision: Int64 = 1) throws -> WorkspaceState {
        let now = Date(timeIntervalSince1970: 0)
        let note = Note(
            id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000502")!),
            title: "迁移测试笔记",
            document: .empty(),
            categoryID: categoryID,
            archivedAt: nil,
            revision: revision,
            createdAt: now,
            updatedAt: now
        )
        return WorkspaceState(
            revision: revision,
            calendar: calendarState,
            notes: [note.id: note],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: []
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
@testable import CalendarApp

@Suite("CalendarStoreTests")
@MainActor
struct CalendarStoreTests {
    @Test func v1PrimaryToV2StoreProjectionAndUndoRoundTripKeepsOneCrossDayIdentity() async throws {
        let directory = try makeTemporaryCalendarAppDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("calendar-v1.json")
        try Data(V1CompleteGraphStoreFixture.json.utf8).write(to: documentURL)
        let seed = makeEmptyState()
        let repository = JSONCalendarRepository(documentURL: documentURL, seed: { seed })
        let store = CalendarStore(initialState: seed, repository: repository)

        await store.load()
        try #require(store.phase == .ready)
        let migrated = store.state
        try assertCompleteMigratedV1Graph(migrated)
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001201")!,
            kind: .task,
            title: "跨层跨日事项",
            categoryID: migrated.uncategorizedID,
            schedule: CalendarSchedule(
                startDate: .init(year: 2026, month: 8, day: 30)!,
                endDate: .init(year: 2026, month: 9, day: 2)!,
                startTime: nil,
                endTime: nil
            ),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        try await store.send(.createItem(item), undoLabel: "添加跨日事项")

        let visibleRange = CalendarDateRange(
            start: .init(year: 2026, month: 8, day: 3)!,
            end: .init(year: 2026, month: 9, day: 6)!
        )
        let projection = TimelineProjection.make(
            in: visibleRange,
            state: store.state,
            hiddenCategoryIDs: []
        )
        #expect(projection.entries.filter { $0.id == .item(item.id) }.count == 1)
        #expect(projection.entries.contains { $0.id == .item(V1CompleteGraphStoreFixture.itemID) })
        let moved = try #require(
            projection.entries.first { $0.id == .occurrence(V1CompleteGraphStoreFixture.movedKey) }
        )
        #expect(moved.title == "已移动")
        #expect(moved.schedule == V1CompleteGraphStoreFixture.movedSchedule)
        let completed = try #require(
            projection.entries.first { $0.id == .occurrence(V1CompleteGraphStoreFixture.completionKey) }
        )
        #expect(completed.completedAt == V1CompleteGraphStoreFixture.occurrenceCompletionDate)
        #expect(projection.entries.contains { $0.id == .occurrence(V1CompleteGraphStoreFixture.skippedKey) } == false)
        #expect(try await repository.load() == store.state)
        #expect(try schemaVersionInDocument(at: documentURL) == 2)

        try await store.undo()

        #expect(store.state == migrated)
        #expect(store.state.items[item.id] == nil)
        #expect(try await repository.load() == store.state)
        #expect(try schemaVersionInDocument(at: documentURL) == 2)
    }

    @Test func v1BackupRestoreMigratesThroughStoreAndCorruptBackupCannotOverwriteIt() async throws {
        let directory = try makeTemporaryCalendarAppDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("calendar-v1.json")
        let seed = try makeStateWithOneItem()
        let repository = JSONCalendarRepository(documentURL: documentURL, seed: { seed })
        let store = CalendarStore(initialState: seed, repository: repository)
        await store.load()
        try #require(store.phase == .ready)
        let preRestoreState = store.state
        let preRestorePrimaryBytes = try Data(contentsOf: documentURL)

        let v1Backup = directory.appendingPathComponent("schema-one-backup.json")
        try Data(V1CompleteGraphStoreFixture.json.utf8).write(to: v1Backup)
        let rollback = directory.appendingPathComponent("rollback.json")
        try await store.restore(from: v1Backup, using: BackupService(), rollbackURL: rollback)

        let restored = store.state
        let restoredBytes = try Data(contentsOf: documentURL)
        try assertCompleteMigratedV1Graph(restored)
        #expect(restored != preRestoreState)
        #expect(try await repository.load() == restored)
        #expect(try schemaVersionInDocument(at: documentURL) == 2)
        let acceptedRollbackBytes = try Data(contentsOf: rollback)
        #expect(acceptedRollbackBytes == preRestorePrimaryBytes)
        #expect(try decodedBackupState(from: rollback) == preRestoreState)

        let corruptBackup = directory.appendingPathComponent("corrupt-backup.json")
        try Data("{not-valid-json".utf8).write(to: corruptBackup)
        let rejectedRollback = directory.appendingPathComponent("rejected-rollback.json")

        await #expect(throws: StoreError.restoreFailed) {
            try await store.restore(
                from: corruptBackup,
                using: BackupService(),
                rollbackURL: rejectedRollback
            )
        }

        #expect(store.state == restored)
        #expect(try Data(contentsOf: documentURL) == restoredBytes)
        #expect(try await repository.load() == restored)
        #expect(try Data(contentsOf: rollback) == acceptedRollbackBytes)
        #expect(FileManager.default.fileExists(atPath: rejectedRollback.path) == false)
    }

    @Test func failedSaveDoesNotPublishOrRegisterUndo() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)
        await repository.failNextSave()

        do {
            try await store.send(.createCategory(makeCategory(name: "工作")), undoLabel: "添加分类")
            Issue.record("A failed save must throw.")
        } catch let error as StoreError {
            #expect(error == .persistenceFailed)
        }

        #expect(store.state == original)
        #expect(store.canUndo == false)
        #expect(store.mutationError != nil)
        #expect(store.phase == .ready)
    }

    @Test func failedReductionReturnsReadyWithoutSaveOrUndo() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)

        do {
            try await store.send(.deleteItem(UUID()), undoLabel: "删除")
            Issue.record("A missing item must be rejected by the reducer.")
        } catch is ReducerError {}

        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 0)
        #expect(store.state == original)
        #expect(store.canUndo == false)
    }

    @Test func successfulSendPersistsBeforePublishing() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)
        let item = try makeItem(categoryID: original.uncategorizedID)

        try await store.send(.createItem(item), undoLabel: "添加事项")

        let persisted = await repository.persistedState
        #expect(persisted == store.state)
        #expect(store.state.items[item.id] == item)
        #expect(store.canUndo)
        #expect(store.undoNotice == "添加事项")
    }

    @Test func undoRestoresWholeSnapshotAfterSuccessfulSave() async throws {
        let fixture = try makeCategoryReferenceFixture()
        let original = fixture.state
        let (store, repository) = try await makeReadyStore(initialState: original)

        try await store.send(
            .deleteCategory(fixture.deletedCategoryID, migrateTo: fixture.targetCategoryID),
            undoLabel: "删除分类"
        )
        #expect(store.state != original)

        try await store.undo()

        #expect(store.state == original)
        #expect(await repository.persistedState == original)
        #expect(store.canUndo == false)
    }

    @Test func concurrentMutationIsRejected() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)
        await repository.suspendNextSave()
        let firstItem = try makeItem(categoryID: original.uncategorizedID, title: "第一项")
        let secondItem = try makeItem(categoryID: original.uncategorizedID, title: "第二项")
        let first = Task { @MainActor in
            try await store.send(.createItem(firstItem), undoLabel: "添加第一项")
        }
        await repository.waitForSaveToStart()

        do {
            try await store.send(.createItem(secondItem), undoLabel: "添加第二项")
            Issue.record("A mutation while saving must be rejected.")
        } catch let error as StoreError {
            #expect(error == .mutationInProgress)
        }
        await repository.resumeSave()
        try await first.value

        #expect(store.state.items[firstItem.id] != nil)
        #expect(store.state.items[secondItem.id] == nil)
        #expect(await repository.persistedState == store.state)
    }

    @Test func sendDuringLoadIsRejected() async throws {
        let disk = try makeStateWithOneItem()
        let repository = InMemoryCalendarRepository(initialState: disk)
        await repository.suspendNextLoad()
        let store = CalendarStore(initialState: makeEmptyState(), repository: repository)
        let loading = Task { @MainActor in await store.load() }
        await repository.waitForLoadToStart()
        #expect(store.phase == .loading)

        do {
            try await store.send(.deleteItem(UUID()), undoLabel: "删除")
            Issue.record("Commands during load must not reduce from the seed state.")
        } catch let error as StoreError {
            #expect(error == .notReady)
        }
        #expect(await repository.saveCount == 0)
        await repository.resumeLoad()
        await loading.value

        #expect(store.phase == .ready)
        #expect(store.state == disk)
    }

    @Test func restoreBlocksSendAndUndo() async throws {
        let original = makeEmptyState()
        let restored = try makeStateWithOneItem()
        let (store, repository) = try await makeReadyStore(initialState: original)
        let source = try makeBackupFile(for: restored)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let rollback = source.deletingLastPathComponent().appendingPathComponent("rollback.json")
        await repository.suspendNextSnapshot()
        let restoreTask = Task { @MainActor in
            try await store.restore(from: source, using: BackupService(), rollbackURL: rollback)
        }
        await repository.waitForSnapshotToStart()
        #expect(store.phase == .restoring)

        do {
            try await store.send(.deleteItem(UUID()), undoLabel: "删除")
            Issue.record("Commands during restore must be rejected.")
        } catch let error as StoreError {
            #expect(error == .mutationInProgress)
        }
        do {
            try await store.undo()
            Issue.record("Undo during restore must be rejected.")
        } catch let error as StoreError {
            #expect(error == .mutationInProgress)
        }

        await repository.resumeSnapshot()
        try await restoreTask.value
        #expect(store.phase == .ready)
        #expect(store.state == restored)
        #expect(await repository.persistedState == restored)
    }

    @Test func corruptPrimaryCanRestoreValidBackup() async throws {
        let seed = makeEmptyState()
        let restored = try makeStateWithOneItem()
        let repository = InMemoryCalendarRepository(initialState: seed)
        let corrupt = Data("corrupt primary bytes".utf8)
        await repository.replaceRawDocument(with: corrupt)
        let store = CalendarStore(initialState: seed, repository: repository)
        await store.load()
        #expect(store.phase == .loadFailed)
        #expect(store.loadError != nil)
        let source = try makeBackupFile(for: restored)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let rollback = source.deletingLastPathComponent().appendingPathComponent("rollback.json")

        try await store.restore(from: source, using: BackupService(), rollbackURL: rollback)

        #expect(try Data(contentsOf: rollback) == corrupt)
        #expect(store.phase == .ready)
        #expect(store.loadError == nil)
        #expect(store.state == restored)
        #expect(await repository.persistedState == restored)
    }

    @Test func invalidSemanticRestoreKeepsMemoryDiskAndRollbackUntouched() async throws {
        let stored = try makeStateWithOneItem()
        let (store, repository) = try await makeReadyStore(initialState: stored)
        try await store.send(.createCategory(makeCategory(name: "保留撤销")), undoLabel: "添加分类")
        let publishedBeforeRestore = store.state
        let primaryBytesBeforeRestore = await repository.rawDocumentData()
        let canUndoBeforeRestore = store.canUndo
        let sourceDirectory = try makeTemporaryCalendarAppDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("invalid-semantic-backup.json")
        let rollback = sourceDirectory
            .appendingPathComponent("Rollbacks", isDirectory: true)
            .appendingPathComponent("proposed-rollback.json")
        var invalid = publishedBeforeRestore
        let itemID = try #require(invalid.items.keys.first)
        invalid.items[itemID]?.categoryID = UUID()
        try writeRawBackupDocument(state: invalid, to: source)

        do {
            try await store.restore(from: source, using: BackupService(), rollbackURL: rollback)
            Issue.record("A backup with a dangling category must be rejected.")
        } catch let error as StoreError {
            #expect(error == .restoreFailed)
        }

        #expect(store.state == publishedBeforeRestore)
        #expect(await repository.rawDocumentData() == primaryBytesBeforeRestore)
        #expect(await repository.saveCount == 1)
        #expect(store.canUndo == canUndoBeforeRestore)
        #expect(FileManager.default.fileExists(atPath: rollback.path) == false)
        #expect(FileManager.default.fileExists(atPath: rollback.deletingLastPathComponent().path) == false)
    }

    @Test func failedV1RestoreDoesNotPublishMigratedState() async throws {
        let stored = try makeStateWithOneItem()
        let (store, repository) = try await makeReadyStore(initialState: stored)
        let beforeState = store.state
        let beforePublicationGeneration = store.statePublicationGeneration
        let beforePrimary = await repository.rawDocumentData()
        let sourceDirectory = try makeTemporaryCalendarAppDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("schema-one-backup.json")
        let rollback = sourceDirectory.appendingPathComponent("rollback.json")
        try Data(schemaOneEmptyCalendarJSON.utf8).write(to: source)
        let rollbackWriter = StoreFailingRollbackWriter()
        rollbackWriter.failNextWrite = true

        await #expect(throws: StoreError.restoreFailed) {
            try await store.restore(
                from: source,
                using: BackupService(writer: rollbackWriter),
                rollbackURL: rollback
            )
        }

        #expect(store.state == beforeState)
        #expect(store.statePublicationGeneration == beforePublicationGeneration)
        #expect(store.phase == .ready)
        #expect(await repository.rawDocumentData() == beforePrimary)
        #expect(await repository.saveCount == 0)
    }

    @Test func failedV1RestorePrimarySaveDoesNotPublishState() async throws {
        let stored = try makeStateWithOneItem()
        let (store, repository) = try await makeReadyStore(initialState: stored)
        let beforeState = store.state
        let beforePublicationGeneration = store.statePublicationGeneration
        let beforePrimary = await repository.rawDocumentData()
        let sourceDirectory = try makeTemporaryCalendarAppDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("schema-one-primary-failure.json")
        let rollback = sourceDirectory.appendingPathComponent("rollback.json")
        try Data(schemaOneEmptyCalendarJSON.utf8).write(to: source)
        await repository.failNextSave()

        await #expect(throws: StoreError.restoreFailed) {
            try await store.restore(
                from: source,
                using: BackupService(),
                rollbackURL: rollback
            )
        }

        #expect(store.state == beforeState)
        #expect(store.statePublicationGeneration == beforePublicationGeneration)
        #expect(store.phase == .ready)
        #expect(await repository.rawDocumentData() == beforePrimary)
        #expect(await repository.saveCount == 0)
        #expect(try Data(contentsOf: rollback) == beforePrimary)
    }

    @Test func successfulRestorePublishesOnceAndClearsUndo() async throws {
        let original = makeEmptyState()
        let restored = try makeCompleteRecurrenceGraphState()
        let (store, repository) = try await makeReadyStore(initialState: original)
        try await store.send(.createCategory(makeCategory(name: "待撤销")), undoLabel: "添加分类")
        let preRestore = store.state
        let preRestoreBytes = await repository.rawDocumentData()
        let savesBeforeRestore = await repository.saveCount
        let source = try makeBackupFile(for: restored)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let rollbackDirectory = source.deletingLastPathComponent()
            .appendingPathComponent("Rollbacks", isDirectory: true)
        let rollback = rollbackDirectory.appendingPathComponent("restore-\(UUID().uuidString).json")
        #expect(FileManager.default.fileExists(atPath: rollbackDirectory.path) == false)

        let publicationGenerationBeforeRestore = store.statePublicationGeneration

        try await store.restore(from: source, using: BackupService(), rollbackURL: rollback)

        #expect(store.state == restored)
        #expect(await repository.persistedState == restored)
        #expect(await repository.saveCount == savesBeforeRestore + 1)
        #expect(store.statePublicationGeneration == publicationGenerationBeforeRestore + 1)
        #expect(FileManager.default.fileExists(atPath: rollbackDirectory.path))
        #expect(try Data(contentsOf: rollback) == preRestoreBytes)
        #expect(try decodedBackupState(from: rollback) == preRestore)
        #expect(store.canUndo == false)
        #expect(store.undoNotice == nil)
    }
}

private func makeTemporaryCalendarAppDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CalendarStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func writeRawBackupDocument(state: CalendarState, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(CalendarDocument(state: state)).write(to: url)
}

private func decodedBackupState(from url: URL) throws -> CalendarState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(CalendarDocument.self, from: Data(contentsOf: url)).state
}

private func schemaVersionInDocument(at url: URL) throws -> Int {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return try #require(object?["schemaVersion"] as? Int)
}

private let schemaOneEmptyCalendarJSON = #"""
{
  "schemaVersion": 1,
  "state": {
    "categories": [
      "00000000-0000-0000-0000-000000000601",
      {
        "id": "00000000-0000-0000-0000-000000000601",
        "name": "未分类",
        "colorHex": "#8E8E93",
        "sortIndex": 0,
        "createdAt": -63114076800000,
        "updatedAt": -63114076800000
      }
    ],
    "items": [],
    "recurrence": {
      "series": [],
      "exceptions": [],
      "completions": []
    },
    "uncategorizedID": "00000000-0000-0000-0000-000000000601"
  }
}
"""#

private enum V1CompleteGraphStoreFixture {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    static let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    static let movedKey = OccurrenceKey(
        seriesID: seriesID,
        originalDate: CalendarDate(year: 2026, month: 8, day: 10)!
    )
    static let skippedKey = OccurrenceKey(
        seriesID: seriesID,
        originalDate: CalendarDate(year: 2026, month: 8, day: 12)!
    )
    static let completionKey = OccurrenceKey(
        seriesID: seriesID,
        originalDate: CalendarDate(year: 2026, month: 8, day: 17)!
    )
    static let itemCompletionDate = Date(timeIntervalSince1970: 1_700_000_100.25)
    static let occurrenceCompletionDate = Date(timeIntervalSince1970: 1_700_000_300.5)
    static let categoryCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let categoryUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000.1)
    static let itemCreatedAt = Date(timeIntervalSince1970: 1_700_000_000.2)
    static let itemUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000.3)
    static let seriesCreatedAt = Date(timeIntervalSince1970: 1_700_000_000.4)
    static let seriesUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000.5)
    static let itemSchedule = try! CalendarSchedule(
        startDate: CalendarDate(year: 2026, month: 8, day: 6)!,
        endDate: CalendarDate(year: 2026, month: 8, day: 6)!,
        startTime: MinuteOfDay(hour: 9, minute: 0),
        endTime: MinuteOfDay(hour: 10, minute: 0)
    )
    static let movedSchedule = try! CalendarSchedule(
        startDate: CalendarDate(year: 2026, month: 8, day: 13)!,
        endDate: CalendarDate(year: 2026, month: 8, day: 13)!,
        startTime: MinuteOfDay(hour: 11, minute: 0),
        endTime: MinuteOfDay(hour: 12, minute: 0)
    )

    static let json = #"""
    {
      "schemaVersion": 1,
      "state": {
        "categories": [
          "00000000-0000-0000-0000-000000000100",
          {
            "id": "00000000-0000-0000-0000-000000000100",
            "name": "未分类",
            "colorHex": "#8E8E93",
            "sortIndex": 0,
            "createdAt": 1700000000000,
            "updatedAt": 1700000000100
          }
        ],
        "items": [
          "00000000-0000-0000-0000-000000000101",
          {
            "id": "00000000-0000-0000-0000-000000000101",
            "kind": "task",
            "title": "单日事项",
            "categoryID": "00000000-0000-0000-0000-000000000100",
            "date": { "year": 2026, "month": 8, "day": 6 },
            "timeRange": {
              "start": { "value": 540 },
              "end": { "value": 600 }
            },
            "creationTimeZoneIdentifier": "Asia/Shanghai",
            "completedAt": 1700000100250,
            "createdAt": 1700000000200,
            "updatedAt": 1700000000300
          }
        ],
        "recurrence": {
          "series": [
            "00000000-0000-0000-0000-000000000102",
            {
              "id": "00000000-0000-0000-0000-000000000102",
              "kind": "task",
              "title": "每周回顾",
              "categoryID": "00000000-0000-0000-0000-000000000100",
              "startDate": { "year": 2026, "month": 8, "day": 3 },
              "endDate": { "year": 2026, "month": 8, "day": 31 },
              "weekdays": [1, 4],
              "timeRange": {
                "start": { "value": 570 },
                "end": { "value": 615 }
              },
              "creationTimeZoneIdentifier": "Asia/Shanghai",
              "createdAt": 1700000000400,
              "updatedAt": 1700000000500
            }
          ],
          "exceptions": [
            {
              "seriesID": "00000000-0000-0000-0000-000000000102",
              "originalDate": { "year": 2026, "month": 8, "day": 10 }
            },
            {
              "modified": {
                "_0": {
                  "displayedDate": { "year": 2026, "month": 8, "day": 13 },
                  "title": "已移动",
                  "kind": "task",
                  "categoryID": "00000000-0000-0000-0000-000000000100",
                  "timeRange": {
                    "start": { "value": 660 },
                    "end": { "value": 720 }
                  }
                }
              }
            },
            {
              "seriesID": "00000000-0000-0000-0000-000000000102",
              "originalDate": { "year": 2026, "month": 8, "day": 12 }
            },
            { "skipped": {} }
          ],
          "completions": [
            {
              "seriesID": "00000000-0000-0000-0000-000000000102",
              "originalDate": { "year": 2026, "month": 8, "day": 17 }
            },
            {
              "key": {
                "seriesID": "00000000-0000-0000-0000-000000000102",
                "originalDate": { "year": 2026, "month": 8, "day": 17 }
              },
              "completedAt": 1700000300500
            }
          ]
        },
        "uncategorizedID": "00000000-0000-0000-0000-000000000100"
      }
    }
    """#
}

private func assertCompleteMigratedV1Graph(_ state: CalendarState) throws {
    #expect(state.uncategorizedID == V1CompleteGraphStoreFixture.categoryID)
    #expect(state.categories.count == 1)
    let category = try #require(state.categories[V1CompleteGraphStoreFixture.categoryID])
    #expect(category.id == V1CompleteGraphStoreFixture.categoryID)
    #expect(category.name == "未分类")
    #expect(category.createdAt == V1CompleteGraphStoreFixture.categoryCreatedAt)
    #expect(category.updatedAt == V1CompleteGraphStoreFixture.categoryUpdatedAt)

    #expect(state.items.count == 1)
    let item = try #require(state.items[V1CompleteGraphStoreFixture.itemID])
    #expect(item.id == V1CompleteGraphStoreFixture.itemID)
    #expect(item.title == "单日事项")
    #expect(item.schedule == V1CompleteGraphStoreFixture.itemSchedule)
    #expect(item.creationTimeZoneIdentifier == "Asia/Shanghai")
    #expect(item.completedAt == V1CompleteGraphStoreFixture.itemCompletionDate)
    #expect(item.createdAt == V1CompleteGraphStoreFixture.itemCreatedAt)
    #expect(item.updatedAt == V1CompleteGraphStoreFixture.itemUpdatedAt)

    #expect(state.recurrence.series.count == 1)
    let series = try #require(state.recurrence.series[V1CompleteGraphStoreFixture.seriesID])
    #expect(series.id == V1CompleteGraphStoreFixture.seriesID)
    #expect(series.title == "每周回顾")
    #expect(series.ruleStartDate == CalendarDate(year: 2026, month: 8, day: 3)!)
    #expect(series.recurrenceEndDate == CalendarDate(year: 2026, month: 8, day: 31)!)
    #expect(series.weekdays == [.monday, .thursday])
    #expect(series.durationDays == 1)
    #expect(series.startTime == MinuteOfDay(hour: 9, minute: 30))
    #expect(series.endTime == MinuteOfDay(hour: 10, minute: 15))
    #expect(series.creationTimeZoneIdentifier == "Asia/Shanghai")
    #expect(series.createdAt == V1CompleteGraphStoreFixture.seriesCreatedAt)
    #expect(series.updatedAt == V1CompleteGraphStoreFixture.seriesUpdatedAt)

    #expect(state.recurrence.exceptions.count == 2)
    let moved = try #require(state.recurrence.exceptions[V1CompleteGraphStoreFixture.movedKey])
    guard case let .modified(override) = moved else {
        Issue.record("完整 V1 图中的 modified 例外必须保持 modified。")
        return
    }
    #expect(override.displayedSchedule == V1CompleteGraphStoreFixture.movedSchedule)
    #expect(override.title == "已移动")
    #expect(override.kind == .task)
    #expect(override.categoryID == V1CompleteGraphStoreFixture.categoryID)
    #expect(state.recurrence.exceptions[V1CompleteGraphStoreFixture.skippedKey] == .skipped)

    #expect(state.recurrence.completions.count == 1)
    let completion = try #require(
        state.recurrence.completions[V1CompleteGraphStoreFixture.completionKey]
    )
    #expect(completion.key == V1CompleteGraphStoreFixture.completionKey)
    #expect(completion.completedAt == V1CompleteGraphStoreFixture.occurrenceCompletionDate)
}

private final class StoreFailingRollbackWriter: AtomicFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextWrite = false

    var failNextWrite: Bool {
        get { lock.withLock { shouldFailNextWrite } }
        set { lock.withLock { shouldFailNextWrite = newValue } }
    }

    func replaceAtomically(data: Data, at destination: URL) throws {
        let shouldFail = lock.withLock {
            defer { shouldFailNextWrite = false }
            return shouldFailNextWrite
        }
        if shouldFail {
            throw StoreRollbackWriteError.failed
        }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

private enum StoreRollbackWriteError: Error {
    case failed
}

private func makeCompleteRecurrenceGraphState() throws -> CalendarState {
    var state = try makeStateWithOneItem()
    let series = try WeeklySeries(
        id: UUID(),
        kind: .task,
        title: "恢复后的每周复盘",
        categoryID: state.uncategorizedID,
        ruleStartDate: .init(year: 2026, month: 8, day: 3)!,
        recurrenceEndDate: .init(year: 2026, month: 8, day: 31)!,
        weekdays: [.monday, .wednesday],
        durationDays: 1,
        startTime: nil,
        endTime: nil,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )
    let modifiedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 10)!
    )
    let completedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 12)!
    )
    state.recurrence = .init(
        series: [series.id: series],
        exceptions: [
            modifiedKey: .modified(.init(
                displayedSchedule: try CalendarSchedule(
                    startDate: .init(year: 2026, month: 8, day: 11)!,
                    endDate: .init(year: 2026, month: 8, day: 11)!,
                    startTime: nil,
                    endTime: nil
                ),
                title: "保留的单次例外",
                kind: .task,
                categoryID: state.uncategorizedID
            ))
        ],
        completions: [
            completedKey: .init(key: completedKey, completedAt: .distantPast)
        ]
    )
    return state
}

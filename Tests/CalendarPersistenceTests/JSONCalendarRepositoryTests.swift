import Foundation
import Testing
@testable import CalendarDomain
@testable import CalendarPersistence

@Suite("JSONCalendarRepositoryTests")
struct JSONCalendarRepositoryTests {
    @Test func saveThenReopenRoundTripsState() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("calendar.json")
        let expected = try makePopulatedState()
        let empty = CalendarState.empty(
            uncategorizedID: expected.uncategorizedID,
            now: Date(timeIntervalSince1970: 0)
        )
        let writer = JSONCalendarRepository(documentURL: url) { empty }
        try await writer.save(expected)
        let reader = JSONCalendarRepository(documentURL: url) { empty }
        #expect(try await reader.load() == expected)
    }

    @Test func schemaOneMigratesSingleDayItemsSeriesOverridesAndCompletionsWithoutChangingIdentity() throws {
        let originalBytes = Data(V1CompleteGraphFixture.json.utf8)

        let state = try CalendarDocumentCodec.decode(originalBytes)
        let expectedItemSchedule = try schedule("2026-08-06", "2026-08-06", 9, 0, 10, 0)
        let expectedMovedSchedule = try schedule("2026-08-13", "2026-08-13", 11, 0, 12, 0)

        let item = try #require(state.items[V1CompleteGraphFixture.itemID])
        #expect(item.id == V1CompleteGraphFixture.itemID)
        #expect(item.schedule == expectedItemSchedule)
        #expect(item.completedAt == V1CompleteGraphFixture.itemCompletionDate)
        #expect(item.createdAt == V1CompleteGraphFixture.itemCreatedAt)
        #expect(item.updatedAt == V1CompleteGraphFixture.itemUpdatedAt)
        let category = try #require(state.categories[V1CompleteGraphFixture.categoryID])
        #expect(category.id == V1CompleteGraphFixture.categoryID)
        #expect(category.createdAt == V1CompleteGraphFixture.categoryCreatedAt)
        #expect(category.updatedAt == V1CompleteGraphFixture.categoryUpdatedAt)
        let series = try #require(state.recurrence.series[V1CompleteGraphFixture.seriesID])
        #expect(series.id == V1CompleteGraphFixture.seriesID)
        #expect(series.ruleStartDate == CalendarDate(year: 2026, month: 8, day: 3)!)
        #expect(series.recurrenceEndDate == CalendarDate(year: 2026, month: 8, day: 31)!)
        #expect(series.durationDays == 1)
        #expect(series.startTime == MinuteOfDay(hour: 9, minute: 30))
        #expect(series.endTime == MinuteOfDay(hour: 10, minute: 15))
        #expect(series.createdAt == V1CompleteGraphFixture.seriesCreatedAt)
        #expect(series.updatedAt == V1CompleteGraphFixture.seriesUpdatedAt)
        let moved = try #require(state.recurrence.exceptions[V1CompleteGraphFixture.movedKey])
        guard case let .modified(override) = moved else {
            Issue.record("The V1 modified exception must remain modified.")
            return
        }
        #expect(override.displayedSchedule == expectedMovedSchedule)
        #expect(override.title == "已移动")
        #expect(override.kind == .task)
        #expect(override.categoryID == V1CompleteGraphFixture.categoryID)
        #expect(state.recurrence.exceptions[V1CompleteGraphFixture.skippedKey] == .skipped)
        #expect(
            state.recurrence.completions[V1CompleteGraphFixture.completionKey]?.completedAt
                == V1CompleteGraphFixture.occurrenceCompletionDate
        )
        #expect(originalBytes == Data(V1CompleteGraphFixture.json.utf8))
    }

    @Test func loadingSchemaOneDoesNotRewritePrimaryUntilNormalSave() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let primary = directory.file("calendar.json")
        let v1Bytes = Data(V1CompleteGraphFixture.json.utf8)
        try v1Bytes.write(to: primary)
        let repository = JSONCalendarRepository(documentURL: primary) {
            CalendarState.empty(
                uncategorizedID: V1CompleteGraphFixture.categoryID,
                now: .distantPast
            )
        }

        let migrated = try await repository.load()

        #expect(try Data(contentsOf: primary) == v1Bytes)
        try await repository.save(migrated)
        #expect(try schemaVersion(at: primary) == 2)
    }

    @Test func invalidBackupNeverOverwritesCurrentState() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let repository = JSONCalendarRepository(
            documentURL: directory.file("calendar.json")
        ) { current }
        try await repository.save(current)
        let badBackup = directory.file("bad-backup.json")
        let rollback = directory.file("rollback.json")
        try Data("not-json".utf8).write(to: badBackup)
        let backup = BackupService()
        await #expect(throws: BackupError.invalidDocument) {
            try await backup.restore(
                from: badBackup,
                repository: repository,
                rollbackURL: rollback
            )
        }
        #expect(try await repository.load() == current)
        #expect(FileManager.default.fileExists(atPath: rollback.path) == false)
    }

    @Test func unknownSchemaDoesNotRewriteFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let url = directory.file("calendar.json")
        let bytes = try encodedDocumentData(current, schemaVersion: 999)
        try bytes.write(to: url)

        let repository = JSONCalendarRepository(documentURL: url) { current }
        await #expect(throws: BackupError.unsupportedSchema(999)) {
            try await repository.load()
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func unsupportedSchemaIsRejectedBeforePayloadDecoding() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let url = directory.file("calendar.json")
        let bytes = Data(#"{"schemaVersion":999,"state":"not-a-calendar-state"}"#.utf8)
        try bytes.write(to: url)
        let repository = JSONCalendarRepository(documentURL: url) { current }

        await #expect(throws: BackupError.unsupportedSchema(999)) {
            try await repository.load()
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func missingFileSeedsExactlyOnce() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let state = try makePopulatedState()
        let counter = LockedCounter()
        let repository = JSONCalendarRepository(documentURL: directory.file("calendar.json")) {
            counter.increment()
            return state
        }

        let first = try await repository.load()
        let second = try await repository.load()

        #expect(counter.value == 1)
        #expect(first == state)
        #expect(second == state)
    }

    @Test func validRestoreWritesRollbackBeforeReplacement() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let restored = try makeAlternateState()
        let primary = directory.file("calendar.json")
        let source = directory.file("backup.json")
        let rollback = directory.file("rollback.json")
        let repository = JSONCalendarRepository(documentURL: primary) { current }
        try await repository.save(current)
        let previousPrimary = try Data(contentsOf: primary)
        let backup = BackupService()
        try await backup.export(state: restored, to: source)

        #expect(try await backup.restore(
            from: source,
            repository: repository,
            rollbackURL: rollback
        ) == restored)
        #expect(try Data(contentsOf: rollback) == previousPrimary)
        #expect(try decodedDocumentState(from: rollback) == current)
        #expect(try await repository.load() == restored)
    }

    @Test func malformedV1SpanMigrationDoesNotOverwritePrimaryOrRollback() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let primary = directory.file("calendar.json")
        let rollback = directory.file("rollback.json")
        let malformedV1 = Data(
            V1CompleteGraphFixture.json.replacingOccurrences(
                of: #""end": { "value": 600 }"#,
                with: #""end": { "value": 480 }"#
            ).utf8
        )
        let source = directory.file("malformed-v1.json")
        let repository = JSONCalendarRepository(documentURL: primary) { current }
        try await repository.save(current)
        try Data("previous rollback bytes".utf8).write(to: rollback)
        let beforePrimary = try Data(contentsOf: primary)
        let beforeRollback = try Data(contentsOf: rollback)

        try malformedV1.write(to: source)
        await #expect(throws: BackupError.invalidDocument) {
            try await BackupService().restore(
                from: source,
                repository: repository,
                rollbackURL: rollback
            )
        }

        #expect(try Data(contentsOf: primary) == beforePrimary)
        #expect(try Data(contentsOf: rollback) == beforeRollback)
    }

    @Test func rollbackFailureLeavesOriginalPrimaryAndRollbackBytesUnchanged() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let primary = directory.file("calendar.json")
        let rollback = directory.file("rollback.json")
        let source = directory.file("valid-v1.json")
        let repository = JSONCalendarRepository(documentURL: primary) { current }
        try await repository.save(current)
        try Data("previous rollback bytes".utf8).write(to: rollback)
        let beforePrimary = try Data(contentsOf: primary)
        let beforeRollback = try Data(contentsOf: rollback)
        let rollbackWriter = FailingRollbackWriter()
        rollbackWriter.failNextWrite = true

        try Data(V1CompleteGraphFixture.json.utf8).write(to: source)
        await #expect(throws: BackupError.rollbackWriteFailed) {
            try await BackupService(writer: rollbackWriter).restore(
                from: source,
                repository: repository,
                rollbackURL: rollback
            )
        }

        #expect(try Data(contentsOf: primary) == beforePrimary)
        #expect(try Data(contentsOf: rollback) == beforeRollback)
    }

    @Test func v1RestorePrimaryAtomicFailureKeepsPrimaryAfterRollbackWasWritten() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let primary = directory.file("calendar.json")
        let rollback = directory.file("rollback.json")
        let source = directory.file("valid-v1-primary-failure.json")
        let preparingRepository = JSONCalendarRepository(documentURL: primary) { current }
        try await preparingRepository.save(current)
        let beforePrimary = try Data(contentsOf: primary)
        try Data(V1CompleteGraphFixture.json.utf8).write(to: source)
        let failingRepository = JSONCalendarRepository(
            documentURL: primary,
            seed: { current },
            writer: InjectedReplaceFailureWriter()
        )

        await #expect(throws: BackupError.atomicWriteFailed) {
            try await BackupService().restore(
                from: source,
                repository: failingRepository,
                rollbackURL: rollback
            )
        }

        #expect(try Data(contentsOf: primary) == beforePrimary)
        #expect(try Data(contentsOf: rollback) == beforePrimary)
    }

    @Test func semanticallyInvalidV1MigrationDoesNotOverwritePrimaryOrRollback() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let primary = directory.file("calendar.json")
        let rollback = directory.file("rollback.json")
        let source = directory.file("dangling-category-v1.json")
        let repository = JSONCalendarRepository(documentURL: primary) { current }
        try await repository.save(current)
        try Data("previous rollback bytes".utf8).write(to: rollback)
        let beforePrimary = try Data(contentsOf: primary)
        let beforeRollback = try Data(contentsOf: rollback)
        let danglingCategoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000199")!
        let semanticallyInvalidV1 = try mutatedV1DocumentData { document in
            try mutateItem(&document, id: V1CompleteGraphFixture.itemID) { item in
                item["categoryID"] = danglingCategoryID.uuidString
            }
        }
        try semanticallyInvalidV1.write(to: source)

        await #expect(throws: BackupError.invalidDocument) {
            try await BackupService().restore(
                from: source,
                repository: repository,
                rollbackURL: rollback
            )
        }

        #expect(try Data(contentsOf: primary) == beforePrimary)
        #expect(try Data(contentsOf: rollback) == beforeRollback)
    }

    @Test func firstRestoreCreatesMissingRollbackDirectory() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let restored = try makeAlternateState()
        let repository = JSONCalendarRepository(documentURL: directory.file("calendar.json")) { current }
        try await repository.save(current)
        let source = directory.file("backup.json")
        let rollbackParent = directory.file("Rollbacks")
        let rollback = rollbackParent.appendingPathComponent("2026-08-02.json")
        let backup = BackupService()
        try await backup.export(state: restored, to: source)
        #expect(FileManager.default.fileExists(atPath: rollbackParent.path) == false)

        _ = try await backup.restore(
            from: source,
            repository: repository,
            rollbackURL: rollback
        )

        #expect(FileManager.default.fileExists(atPath: rollbackParent.path))
        #expect(FileManager.default.fileExists(atPath: rollback.path))
        #expect(FileManager.default.fileExists(atPath: directory.file("Unrelated").path) == false)
        #expect(try await repository.load() == restored)
    }

    @Test func corruptPrimarySnapshotPreservesRawBytes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let restored = try makeAlternateState()
        let primary = directory.file("calendar.json")
        let source = directory.file("backup.json")
        let rollback = directory.file("rollback.json")
        let corruptBytes = Data("not-valid-primary-json".utf8)
        try corruptBytes.write(to: primary)
        let repository = JSONCalendarRepository(documentURL: primary) { current }
        let backup = BackupService()
        try await backup.export(state: restored, to: source)

        _ = try await backup.restore(
            from: source,
            repository: repository,
            rollbackURL: rollback
        )

        #expect(try Data(contentsOf: rollback) == corruptBytes)
        #expect(try await repository.load() == restored)
    }

    @Test func failedAtomicReplaceKeepsPreviousDocument() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let updated = try makeAlternateState()
        let primary = directory.file("calendar.json")
        let realRepository = JSONCalendarRepository(documentURL: primary) { current }
        try await realRepository.save(current)
        let originalBytes = try Data(contentsOf: primary)
        let failingRepository = JSONCalendarRepository(
            documentURL: primary,
            seed: { current },
            writer: InjectedReplaceFailureWriter()
        )

        await #expect(throws: BackupError.atomicWriteFailed) {
            try await failingRepository.save(updated)
        }
        #expect(try Data(contentsOf: primary) == originalBytes)
        let reopened = JSONCalendarRepository(documentURL: primary) { updated }
        #expect(try await reopened.load() == current)
    }

    @Test func fractionalDatesRoundTripWithoutChangingSortOrder() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var expected = try makePopulatedState()
        let secondItem = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
            kind: .task,
            title: "排序保持",
            categoryID: expected.uncategorizedID,
            schedule: CalendarSchedule(
                startDate: .init(year: 2026, month: 8, day: 3)!,
                endDate: .init(year: 2026, month: 8, day: 3)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 0.223456),
            updatedAt: Date(timeIntervalSince1970: 0.223456)
        )
        expected.items[secondItem.id] = secondItem
        let persisted = expected
        let url = directory.file("calendar.json")
        let repository = JSONCalendarRepository(documentURL: url) { persisted }
        try await repository.save(expected)
        let firstBytes = try Data(contentsOf: url)
        let reopened = JSONCalendarRepository(documentURL: url) { persisted }
        let decoded = try await reopened.load()
        try await reopened.save(decoded)
        let decodedOrder = decoded.items.values
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)
        let expectedOrder = expected.items.values
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)

        #expect(decoded.items[secondItem.id]?.createdAt == secondItem.createdAt)
        #expect(decoded.recurrence.series.values.first?.createdAt == Date(timeIntervalSince1970: 0.123456))
        #expect(decoded.recurrence.completions.values.first?.completedAt == Date(timeIntervalSince1970: 0.456789))
        #expect(decodedOrder == expectedOrder)
        #expect(try Data(contentsOf: url) == firstBytes)
    }

    @Test func completeGraphRoundTripsExactly() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let expected = try makePopulatedState()
        let repository = JSONCalendarRepository(documentURL: directory.file("calendar.json")) { expected }
        try await repository.save(expected)

        #expect(try await repository.load() == expected)
    }

    @Test func decodableDanglingCategoryBackupIsRejected() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let data = try mutatedDocumentData(from: current) { document in
            var state = try dictionary(at: "state", in: document)
            state["categories"] = []
            document["state"] = state
        }
        try await assertInvalidRestore(
            data: data,
            current: current,
            directory: directory
        )
    }

    @Test func decodableInvalidRecurrenceBackupIsRejected() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let seriesID = try requiredSeriesID(in: current)
        let invalidDocuments = try [
            mutatedDocumentData(from: current) { document in
                try mutateSeries(&document, id: seriesID) { $0["weekdays"] = [] }
            },
            mutatedDocumentData(from: current) { document in
                try mutateSeries(&document, id: seriesID) {
                    $0["endDate"] = ["year": 2026, "month": 8, "day": 2]
                }
            },
            mutatedDocumentData(from: current) { document in
                try mutateSeries(&document, id: seriesID) {
                    $0["startDate"] = ["year": 2026, "month": 8, "day": 4]
                    $0["endDate"] = ["year": 2026, "month": 8, "day": 4]
                    $0["weekdays"] = [Weekday.monday.rawValue]
                }
            },
            mutatedDocumentData(from: current) { document in
                try mutateRecurrence(&document) { recurrence in
                    recurrence["series"] = []
                    recurrence["completions"] = []
                }
            },
            mutatedDocumentData(from: current) { document in
                try mutateRecurrence(&document) { recurrence in
                    recurrence["series"] = []
                    recurrence["exceptions"] = []
                }
            },
            mutatedDocumentData(from: current) { document in
                try mutateFirstOccurrenceKey(in: &document, collection: "exceptions") { key in
                    key["originalDate"] = ["year": 2026, "month": 9, "day": 1]
                }
            },
            mutatedDocumentData(from: current) { document in
                try mutateSeries(&document, id: seriesID) { $0["kind"] = ItemKind.event.rawValue }
            }
        ]

        for (index, data) in invalidDocuments.enumerated() {
            try await assertInvalidRestore(
                data: data,
                current: current,
                directory: directory,
                name: "invalid-recurrence-\(index).json"
            )
        }
    }

    @Test func weeklySeriesDecoderRejectsMissingV2CoreFields() throws {
        let state = try makePopulatedState()
        let series = try #require(state.recurrence.series.values.first)
        var payload = try encodedJSONDictionary(series)
        payload.removeValue(forKey: "durationDays")

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WeeklySeries.self, from: try jsonData(payload))
        }
    }

    @Test func weeklySeriesDecoderTreatsEveryV2ScheduleKeyAsV2Shape() throws {
        let state = try makePopulatedState()
        let series = try #require(state.recurrence.series.values.first)
        var legacyBase = try encodedJSONDictionary(series)
        legacyBase["startDate"] = legacyBase.removeValue(forKey: "ruleStartDate")
        legacyBase["endDate"] = legacyBase.removeValue(forKey: "recurrenceEndDate")
        legacyBase.removeValue(forKey: "durationDays")

        var isolatedRecurrenceEnd = legacyBase
        isolatedRecurrenceEnd["recurrenceEndDate"] = ["year": 2026, "month": 8, "day": 31]
        var isolatedStartTime = legacyBase
        isolatedStartTime["startTime"] = ["value": 540]
        var isolatedEndTime = legacyBase
        isolatedEndTime["endTime"] = ["value": 600]

        for payload in [isolatedRecurrenceEnd, isolatedStartTime, isolatedEndTime] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(WeeklySeries.self, from: try jsonData(payload))
            }
        }
    }

    @Test func v2DomainDecodersRejectLegacyAndMixedScheduleRepresentations() throws {
        let state = try makePopulatedState()
        let item = try #require(state.items.values.first)
        let series = try #require(state.recurrence.series.values.first)
        let override: OccurrenceOverride = try #require(state.recurrence.exceptions.values.compactMap { exception -> OccurrenceOverride? in
            guard case let .modified(override) = exception else { return nil }
            return override
        }.first)

        var legacyItem = try encodedJSONDictionary(item)
        legacyItem["date"] = ["year": 2026, "month": 8, "day": 3]
        var mixedSeries = try encodedJSONDictionary(series)
        mixedSeries["startDate"] = mixedSeries["ruleStartDate"]
        mixedSeries["endDate"] = mixedSeries["recurrenceEndDate"]
        var mixedOverride = try encodedJSONDictionary(override)
        mixedOverride["displayedDate"] = ["year": 2026, "month": 8, "day": 11]
        mixedOverride["timeRange"] = [
            "start": ["value": 540],
            "end": ["value": 600]
        ]

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CalendarItem.self, from: try jsonData(legacyItem))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WeeklySeries.self, from: try jsonData(mixedSeries))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OccurrenceOverride.self, from: try jsonData(mixedOverride))
        }
    }

    @Test func occurrenceOverrideDecoderRejectsLegacyScheduleFields() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000400")!
        let displayedDate = CalendarDate(year: 2026, month: 8, day: 11)!
        let v2TimeRange = try LocalTimeRange(
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 10, minute: 0)!
        )
        let override = OccurrenceOverride(
            displayedSchedule: try CalendarSchedule(
                startDate: displayedDate,
                endDate: displayedDate,
                startTime: v2TimeRange.start,
                endTime: v2TimeRange.end
            ),
            title: "改期复盘",
            kind: .task,
            categoryID: categoryID
        )
        let base = try encodedJSONDictionary(override)

        var dateConflict = base
        dateConflict["displayedDate"] = try encodedJSONValue(
            CalendarDate(year: 2026, month: 8, day: 12)!
        )
        dateConflict["timeRange"] = try encodedJSONValue(v2TimeRange)

        var timeConflict = base
        timeConflict["displayedDate"] = try encodedJSONValue(displayedDate)
        timeConflict["timeRange"] = try encodedJSONValue(
            LocalTimeRange(
                start: MinuteOfDay(hour: 11, minute: 0)!,
                end: MinuteOfDay(hour: 12, minute: 0)!
            )
        )

        for payload in [dateConflict, timeConflict] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(OccurrenceOverride.self, from: try jsonData(payload))
            }
        }
    }

    @Test func decodablePartialOrReversedTimeIsRejected() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let itemID = try requiredItemID(in: current)
        let invalidDocuments = try [
            mutatedDocumentData(from: current) { document in
                try mutateItem(&document, id: itemID) {
                    var schedule = try dictionary(at: "schedule", in: $0)
                    schedule["startTime"] = ["value": 600]
                    $0["schedule"] = schedule
                }
            },
            mutatedDocumentData(from: current) { document in
                try mutateItem(&document, id: itemID) {
                    var schedule = try dictionary(at: "schedule", in: $0)
                    schedule["startTime"] = ["value": 600]
                    schedule["endTime"] = ["value": 600]
                    $0["schedule"] = schedule
                }
            }
        ]

        for (index, data) in invalidDocuments.enumerated() {
            try await assertInvalidRestore(
                data: data,
                current: current,
                directory: directory,
                name: "invalid-time-\(index).json"
            )
        }
    }

    @Test func decodableConstructorAndIdentityViolationsAreRejected() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let current = try makePopulatedState()
        let itemID = try requiredItemID(in: current)
        let seriesID = try requiredSeriesID(in: current)
        let categoryID = current.uncategorizedID
        let invalidDocuments = try [
            mutatedDocumentData(from: current) { document in
                try mutateItem(&document, id: itemID) { $0["title"] = "" }
            },
            mutatedDocumentData(from: current) { document in
                try mutateItem(&document, id: itemID) {
                    $0["creationTimeZoneIdentifier"] = "Not/AReal_TimeZone"
                }
            },
            mutatedDocumentData(from: current) { document in
                try renameDictionaryKey(
                    &document,
                    stateCollection: "categories",
                    from: categoryID.uuidString,
                    to: UUID(uuidString: "00000000-0000-0000-0000-000000000499")!.uuidString
                )
            },
            mutatedDocumentData(from: current) { document in
                try renameDictionaryKey(
                    &document,
                    stateCollection: "items",
                    from: itemID.uuidString,
                    to: UUID(uuidString: "00000000-0000-0000-0000-000000000498")!.uuidString
                )
            },
            mutatedDocumentData(from: current) { document in
                try renameRecurrenceSeriesKey(
                    &document,
                    from: seriesID.uuidString,
                    to: UUID(uuidString: "00000000-0000-0000-0000-000000000497")!.uuidString
                )
            },
            mutatedDocumentData(from: current) { document in
                try mutateFirstOccurrenceValue(in: &document, collection: "completions") { completion in
                    var key = try dictionary(at: "key", in: completion)
                    key["originalDate"] = ["year": 2026, "month": 8, "day": 24]
                    completion["key"] = key
                }
            }
        ]

        for (index, data) in invalidDocuments.enumerated() {
            try await assertInvalidRestore(
                data: data,
                current: current,
                directory: directory,
                name: "invalid-constructor-identity-\(index).json"
            )
        }
    }

    private func assertInvalidRestore(
        data: Data,
        current: CalendarState,
        directory: TemporaryDirectory,
        name: String = "invalid-backup.json"
    ) async throws {
        let primary = directory.file("calendar.json")
        let source = directory.file(name)
        let rollback = directory.file("rollback-\(name)")
        let repository = JSONCalendarRepository(documentURL: primary) { current }
        try await repository.save(current)
        let previousBytes = try Data(contentsOf: primary)
        try data.write(to: source)
        let backup = BackupService()

        await #expect(throws: BackupError.invalidDocument) {
            try await backup.validatedState(from: source)
        }
        await #expect(throws: BackupError.invalidDocument) {
            try await backup.restore(
                from: source,
                repository: repository,
                rollbackURL: rollback
            )
        }
        #expect(try Data(contentsOf: primary) == previousBytes)
        #expect(try await repository.load() == current)
        #expect(FileManager.default.fileExists(atPath: rollback.path) == false)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalCalendarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private enum InjectedReplaceFailure: Error {
    case beforeReplacement
}

private struct InjectedReplaceFailureWriter: AtomicFileWriting {
    func replaceAtomically(data: Data, at destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".injected-\(UUID().uuidString)")
        try data.write(to: temporary)
        throw InjectedReplaceFailure.beforeReplacement
    }
}

private final class FailingRollbackWriter: AtomicFileWriting, @unchecked Sendable {
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
            throw InjectedReplaceFailure.beforeReplacement
        }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

private enum V1CompleteGraphFixture {
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

private func schedule(
    _ startDate: String,
    _ endDate: String,
    _ startHour: Int,
    _ startMinute: Int,
    _ endHour: Int,
    _ endMinute: Int
) throws -> CalendarSchedule {
    func date(_ value: String) -> CalendarDate {
        let parts = value.split(separator: "-").map { Int($0)! }
        return CalendarDate(year: parts[0], month: parts[1], day: parts[2])!
    }
    return try CalendarSchedule(
        startDate: date(startDate),
        endDate: date(endDate),
        startTime: MinuteOfDay(hour: startHour, minute: startMinute),
        endTime: MinuteOfDay(hour: endHour, minute: endMinute)
    )
}

private func schemaVersion(at url: URL) throws -> Int {
    let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return try #require(document?["schemaVersion"] as? Int)
}

private func makePopulatedState() throws -> CalendarState {
    let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000400")!
    var state = CalendarState.empty(
        uncategorizedID: uncategorizedID,
        now: Date(timeIntervalSince1970: 0)
    )
    let item = try CalendarItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
        kind: .task,
        title: "持久化测试",
        categoryID: uncategorizedID,
        schedule: CalendarSchedule(
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: .init(year: 2026, month: 8, day: 3)!,
            startTime: nil,
            endTime: nil
        ),
        completedAt: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    state.items[item.id] = item
    let series = try WeeklySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
        kind: .task,
        title: "周复盘",
        categoryID: uncategorizedID,
        ruleStartDate: .init(year: 2026, month: 8, day: 3)!,
        recurrenceEndDate: .init(year: 2026, month: 8, day: 31)!,
        weekdays: [.monday, .wednesday],
        durationDays: 1,
        startTime: nil,
        endTime: nil,
        creationTimeZoneIdentifier: "Asia/Shanghai",
        createdAt: Date(timeIntervalSince1970: 0.123456),
        updatedAt: Date(timeIntervalSince1970: 0.123456)
    )
    let modifiedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 10)!
    )
    let skippedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 12)!
    )
    let completedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 17)!
    )
    state.recurrence = RecurrenceGraph(
        series: [series.id: series],
        exceptions: [
            modifiedKey: .modified(.init(
                displayedSchedule: try CalendarSchedule(
                    startDate: .init(year: 2026, month: 8, day: 11)!,
                    endDate: .init(year: 2026, month: 8, day: 11)!,
                    startTime: nil,
                    endTime: nil
                ),
                title: "改期复盘",
                kind: .task,
                categoryID: uncategorizedID
            )),
            skippedKey: .skipped
        ],
        completions: [
            completedKey: .init(
                key: completedKey,
                completedAt: Date(timeIntervalSince1970: 0.456789)
            )
        ]
    )
    return state
}

private func makeAlternateState() throws -> CalendarState {
    var state = try makePopulatedState()
    state.items[try requiredItemID(in: state)]?.title = "已恢复的持久化测试"
    return state
}

private func encodedDocumentData(
    _ state: CalendarState,
    schemaVersion: Int = CalendarDocument.currentSchemaVersion
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(CalendarDocument(schemaVersion: schemaVersion, state: state))
}

private func decodedDocumentState(from url: URL) throws -> CalendarState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(CalendarDocument.self, from: Data(contentsOf: url)).state
}

private func mutatedDocumentData(
    from state: CalendarState,
    mutation: (inout [String: Any]) throws -> Void
) throws -> Data {
    let source = try encodedDocumentData(state)
    var document = try JSONSerialization.jsonObject(with: source) as! [String: Any]
    try mutation(&document)
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func mutatedV1DocumentData(
    mutation: (inout [String: Any]) throws -> Void
) throws -> Data {
    var document = try JSONSerialization.jsonObject(
        with: Data(V1CompleteGraphFixture.json.utf8)
    ) as! [String: Any]
    try mutation(&document)
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func encodedJSONDictionary<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value)
    ) as? [String: Any] else {
        throw RawJSONMutationError.unexpectedShape
    }
    return dictionary
}

private func encodedJSONValue<Value: Encodable>(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func jsonData(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func requiredItemID(in state: CalendarState) throws -> UUID {
    try #require(state.items.keys.first)
}

private func requiredSeriesID(in state: CalendarState) throws -> UUID {
    try #require(state.recurrence.series.keys.first)
}

private func dictionary(at key: String, in value: Any?) throws -> [String: Any] {
    guard let outer = value as? [String: Any],
          let nested = outer[key] as? [String: Any]
    else {
        throw RawJSONMutationError.missingKey
    }
    return nested
}

private func mutateItem(
    _ document: inout [String: Any],
    id: UUID,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    var state = try dictionary(at: "state", in: document)
    var items = try keyedEntries(at: "items", in: state)
    try mutateMapValue(&items, for: id.uuidString, mutation: mutation)
    state["items"] = items
    document["state"] = state
}

private func mutateSeries(
    _ document: inout [String: Any],
    id: UUID,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    var state = try dictionary(at: "state", in: document)
    var recurrence = try dictionary(at: "recurrence", in: state)
    var series = try keyedEntries(at: "series", in: recurrence)
    try mutateMapValue(&series, for: id.uuidString, mutation: mutation)
    recurrence["series"] = series
    state["recurrence"] = recurrence
    document["state"] = state
}

private func mutateRecurrence(
    _ document: inout [String: Any],
    mutation: (inout [String: Any]) throws -> Void
) throws {
    var state = try dictionary(at: "state", in: document)
    var recurrence = try dictionary(at: "recurrence", in: state)
    try mutation(&recurrence)
    state["recurrence"] = recurrence
    document["state"] = state
}

private func renameDictionaryKey(
    _ document: inout [String: Any],
    stateCollection: String,
    from oldKey: String,
    to newKey: String
) throws {
    var state = try dictionary(at: "state", in: document)
    var collection = try keyedEntries(at: stateCollection, in: state)
    try renameMapKey(&collection, from: oldKey, to: newKey)
    state[stateCollection] = collection
    document["state"] = state
}

private func renameRecurrenceSeriesKey(
    _ document: inout [String: Any],
    from oldKey: String,
    to newKey: String
) throws {
    var state = try dictionary(at: "state", in: document)
    var recurrence = try dictionary(at: "recurrence", in: state)
    var series = try keyedEntries(at: "series", in: recurrence)
    try renameMapKey(&series, from: oldKey, to: newKey)
    recurrence["series"] = series
    state["recurrence"] = recurrence
    document["state"] = state
}

private func keyedEntries(at key: String, in value: [String: Any]) throws -> [Any] {
    guard let entries = value[key] as? [Any], entries.count.isMultiple(of: 2) else {
        throw RawJSONMutationError.unexpectedShape
    }
    return entries
}

private func mutateMapValue(
    _ entries: inout [Any],
    for key: String,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    guard let index = stride(from: 0, to: entries.count, by: 2).first(where: {
        entries[$0] as? String == key
    }), var value = entries[index + 1] as? [String: Any]
    else {
        throw RawJSONMutationError.missingKey
    }
    try mutation(&value)
    entries[index + 1] = value
}

private func renameMapKey(
    _ entries: inout [Any],
    from oldKey: String,
    to newKey: String
) throws {
    guard let index = stride(from: 0, to: entries.count, by: 2).first(where: {
        entries[$0] as? String == oldKey
    }) else {
        throw RawJSONMutationError.missingKey
    }
    entries[index] = newKey
}

private func mutateFirstOccurrenceKey(
    in document: inout [String: Any],
    collection: String,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    try mutateOccurrencePair(in: &document, collection: collection) { key, _ in
        try mutation(&key)
    }
}

private func mutateFirstOccurrenceValue(
    in document: inout [String: Any],
    collection: String,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    try mutateOccurrencePair(in: &document, collection: collection) { _, value in
        try mutation(&value)
    }
}

private func mutateOccurrencePair(
    in document: inout [String: Any],
    collection: String,
    mutation: (inout [String: Any], inout [String: Any]) throws -> Void
) throws {
    var state = try dictionary(at: "state", in: document)
    var recurrence = try dictionary(at: "recurrence", in: state)
    guard var values = recurrence[collection] as? [Any], values.count >= 2,
          var key = values[0] as? [String: Any],
          var value = values[1] as? [String: Any]
    else {
        throw RawJSONMutationError.unexpectedShape
    }
    try mutation(&key, &value)
    values[0] = key
    values[1] = value
    recurrence[collection] = values
    state["recurrence"] = recurrence
    document["state"] = state
}

private enum RawJSONMutationError: Error {
    case unexpectedShape
    case missingKey
}

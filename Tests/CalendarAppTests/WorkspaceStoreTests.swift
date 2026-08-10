import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceStoreTests")
@MainActor
struct WorkspaceStoreTests {
    @Test func ordinaryMutationsAreRejectedUntilTheInitialLoadCompletes() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "too early")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)

        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await store.sendCalendar(.createItem(item), undoLabel: "too early")
        }
        #expect(store.phase == .notLoaded)
        #expect(await repository.saveCount == 0)
    }

    @Test func initialOpaqueAndUnreadableLoadsProjectTheirTypedRecoveryModes() async throws {
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: UUID(), now: .distantPast))
        let opaqueRepository = WorkspaceStoreTestRepository(initial: initial)
        await opaqueRepository.failNextLoad()
        await opaqueRepository.setReloaded(.opaqueInvalid(.init(sha256: "opaque", byteCount: 6)))
        let opaque = WorkspaceStore(initialState: initial, repository: opaqueRepository)

        await opaque.load()

        #expect(opaque.phase == .opaquePrimaryLoadFailed)
        let unreadableRepository = WorkspaceStoreTestRepository(initial: initial)
        await unreadableRepository.failNextLoad()
        await unreadableRepository.setReloaded(.unreadableUnknown)
        let unreadable = WorkspaceStore(initialState: initial, repository: unreadableRepository)

        await unreadable.load()

        #expect(unreadable.phase == .unreadablePrimaryLoadFailed)
        let blocked = try await unreadable.sendCalendar(.createItem(
            try makeItem(id: UUID(), categoryID: initial.calendar.uncategorizedID, title: "blocked")
        ))
        #expect(blocked == .persistenceBlocked(transactionID: nil, reason: .unreadablePrimary, journal: .clean))
    }

    @Test func queueDropsPreAppendCancellationWithoutRunningTheOperation() async throws {
        let queue = WorkspaceTransactionQueue()
        let start = AsyncTestGate()
        let calls = AsyncTestCounter()
        let task = Task { @MainActor in
            await start.wait()
            return try await queue.enqueue { _ in
                await calls.increment()
                return .noChange(.identical, journal: .clean)
            }
        }
        await start.waitUntilWaited()
        task.cancel()
        await start.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await calls.value == 0)
    }

    @Test func queueCompletesAnAppendedCallerExactlyOnceAfterCancellation() async throws {
        let queue = WorkspaceTransactionQueue()
        let started = AsyncTestGate()
        let finish = AsyncTestGate()
        let calls = AsyncTestCounter()
        let task = Task { @MainActor in
            try await queue.enqueue { _ in
                await calls.increment()
                await started.open()
                await finish.wait()
                return .noChange(.identical, journal: .clean)
            }
        }
        await started.wait()
        task.cancel()
        await finish.open()

        #expect(try await task.value == .noChange(.identical, journal: .clean))
        #expect(await calls.value == 1)
    }

    @Test func directSourceChangeTerminatesAlreadyQueuedCallersWithoutPublishingThem() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let firstItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "first")
        let secondItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "second")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.suspendNextSave()
        await repository.failNextSaveWithSourceChanged()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let first = Task { @MainActor in try await store.sendCalendar(.createItem(firstItem), undoLabel: "first") }
        await repository.waitForSaveStart()
        let second = Task { @MainActor in try await store.sendCalendar(.createItem(secondItem), undoLabel: "second") }
        await repository.resumeSave()

        let outcome = try await first.value
        guard case let .externalSourceChanged(headID?, _, _, _) = outcome else { Issue.record("Expected direct source change"); return }
        let queuedOutcome = try await second.value
        guard case let .externalSourceChanged(queuedID?, reason, _, _) = queuedOutcome else {
            Issue.record("Expected typed terminal source-change outcome for the queued caller")
            return
        }
        #expect(queuedID != headID)
        #expect(reason == .externalBytesChanged)
        #expect(store.state.calendar.items[firstItem.id] == nil)
        #expect(store.state.calendar.items[secondItem.id] == nil)
        #expect(await repository.saveCount == 0)
    }

    @Test func nonPersistedNoChangeTerminatesQueuedCallersWithTheirOwnTypedOutcomes() async throws {
        let (state, _, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-queued-not-persisted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let item = try makeItem(id: UUID(), categoryID: state.calendar.uncategorizedID, title: "must not publish")
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.notPersisted)
        await repository.suspendNextVerification()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        let first = Task { @MainActor in try await store.submitDraft(submission) }
        await repository.waitForVerificationStart()
        let second = Task { @MainActor in try await store.sendCalendar(.createItem(item), undoLabel: "queued") }
        await repository.resumeVerification()

        let firstOutcome = try await first.value
        let secondOutcome = try await second.value
        guard case let .externalSourceChanged(firstID?, firstReason, _, _) = firstOutcome,
              case let .externalSourceChanged(secondID?, secondReason, _, _) = secondOutcome
        else { Issue.record("Expected typed non-persisted source outcomes for both callers"); return }
        #expect(firstReason == .publishedDraftNotPersisted)
        #expect(secondReason == .publishedDraftNotPersisted)
        #expect(firstID != secondID)
        #expect(store.state == state)
        #expect(store.phase == .externalSourceChanged(.publishedDraftNotPersisted))
    }

    @Test func unreadableNoChangeTerminatesQueuedCallersWithTypedPersistenceBlocks() async throws {
        let (state, _, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-queued-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let item = try makeItem(id: UUID(), categoryID: state.calendar.uncategorizedID, title: "must not publish")
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.unreadableUnknown)
        await repository.suspendNextVerification()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        let first = Task { @MainActor in try await store.submitDraft(submission) }
        await repository.waitForVerificationStart()
        let second = Task { @MainActor in try await store.sendCalendar(.createItem(item), undoLabel: "queued") }
        await repository.resumeVerification()

        let firstOutcome = try await first.value
        let secondOutcome = try await second.value
        guard case let .persistenceBlocked(firstID?, firstReason, _) = firstOutcome,
              case let .persistenceBlocked(secondID?, secondReason, _) = secondOutcome
        else { Issue.record("Expected typed unreadable blocks for both callers"); return }
        #expect(firstReason == .unreadablePrimary)
        #expect(secondReason == .unreadablePrimary)
        #expect(firstID != secondID)
        #expect(store.state == state)
        #expect(store.phase == .unreadablePrimaryLoadFailed)
    }

    @Test func unreadablePrimarySaveFailureFreezesAndTerminatesAlreadyQueuedOrdinaryCaller() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let firstItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "unreadable head")
        let secondItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "must not drain")
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.suspendNextSave()
        await repository.failNextSaveWithUnreadablePrimary()
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let head = Task { @MainActor in try await store.sendCalendar(.createItem(firstItem), undoLabel: "head") }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(secondItem), undoLabel: "tail") }
        await repository.resumeSave()

        let headOutcome = try await head.value
        let queuedOutcome = try await queued.value
        guard case let .persistenceBlocked(headID?, headReason, headJournal) = headOutcome,
              case let .persistenceBlocked(queuedID?, queuedReason, queuedJournal) = queuedOutcome
        else {
            Issue.record("An unreadable primary save must freeze its head and terminate its already-appended tail")
            return
        }
        #expect(headID != queuedID)
        #expect(headReason == .unreadablePrimary)
        #expect(queuedReason == .unreadablePrimary)
        #expect(headJournal == .clean)
        #expect(queuedJournal == .clean)
        #expect(store.state == initial)
        #expect(store.canUndo == false)
        #expect(store.canRedo == false)
        #expect(store.phase == .unreadablePrimaryLoadFailed)
        #expect(await repository.saveCount == 0)
    }

    @Test func unreadablePrimaryDraftSaveUnbindsItsJournalAndFreezesWithoutPublishing() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "must remain only journaled"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-unreadable-draft-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.failNextSaveWithUnreadablePrimary()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        let outcome = try await store.submitDraft(submission)

        guard case let .persistenceBlocked(transactionID?, reason, journalStatus) = outcome else {
            Issue.record("An unreadable draft save must return a typed persistence block")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(reason == .unreadablePrimary)
        #expect(journalStatus == .clean)
        let protected = try #require(await journal.current()?.records.first)
        #expect(protected.pendingReceipt == nil)
        #expect(protected.savedReceipt == nil)
        #expect(store.state == state)
        #expect(store.phase == .unreadablePrimaryLoadFailed)
        #expect(await repository.saveCount == 0)
    }

    @Test func realJSONUnreadablePrimaryAfterValidLoadReturnsTypedPersistenceBlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-real-unreadable-primary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let document = directory.appendingPathComponent("calendar-v1.json")
        let alternate = directory.appendingPathComponent("alternate.json")
        try WorkspaceDocumentCodec.encode(initial).write(to: document)
        try WorkspaceDocumentCodec.encode(initial).write(to: alternate)
        let repository = JSONWorkspaceRepository(documentURL: document, seed: { initial })
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        try FileManager.default.removeItem(at: document)
        try FileManager.default.createSymbolicLink(at: document, withDestinationURL: alternate)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "real unreadable")

        let outcome = try await store.sendCalendar(.createItem(item), undoLabel: "must fail closed")

        guard case let .persistenceBlocked(transactionID?, reason, journalStatus) = outcome else {
            Issue.record("A no-follow JSON primary probe must not become a normal not-committed write failure")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(reason == .unreadablePrimary)
        #expect(journalStatus == .clean)
        #expect(store.state == initial)
        #expect(store.canUndo == false)
        #expect(store.phase == .unreadablePrimaryLoadFailed)
    }

    @Test func realJSONUnreadablePrimaryCannotExportRawRecoveryBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-6c-unreadable-raw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let document = directory.appendingPathComponent("calendar-v1.json")
        let alternate = directory.appendingPathComponent("alternate.json")
        try WorkspaceDocumentCodec.encode(initial).write(to: document)
        try WorkspaceDocumentCodec.encode(initial).write(to: alternate)
        let store = WorkspaceStore(
            initialState: initial,
            repository: JSONWorkspaceRepository(documentURL: document, seed: { initial })
        )
        await store.load()
        try FileManager.default.removeItem(at: document)
        try FileManager.default.createSymbolicLink(at: document, withDestinationURL: alternate)

        let blocked = try await store.sendCalendar(
            .createItem(try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "must remain unreadable")),
            undoLabel: "blocked"
        )
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await store.rawRecoveryData()
        }
        let presentation = WorkspaceMutationOutcomePresenter.presentation(for: blocked)
        #expect(presentation.message == "本地数据暂时无法读取，原始字节也不可用；当前输入未保存。")
        #expect(presentation.recoveryAction == nil)
    }

    @Test func invalidDraftContextSaveErrorStillThrowsInsteadOfBecomingATerminalOutcome() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "valid caller context, invalid repository response"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.failNextSaveWithInvalidDraftContext()
        let store = WorkspaceStore(initialState: state, repository: repository)
        await store.load()

        await #expect(throws: WorkspacePersistenceError.invalidDraftContext) {
            _ = try await store.submitDraft(submission)
        }

        #expect(store.state == state)
        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 0)
    }

    @Test func queuedCalendarCommandsReduceAgainstTheLatestPublishedState() async throws {
        let calendar = CalendarState.empty(
            uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000006031")!, now: .distantPast
        )
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000006032")!, kind: .task,
            title: "queued", categoryID: calendar.uncategorizedID,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 10)!, endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, clock: { .distantPast })
        await store.load()
        let first = Task { @MainActor in try await store.sendCalendar(.createItem(item), undoLabel: "创建") }
        let second = Task { @MainActor in try await store.sendCalendar(.setTaskCompleted(item.id, Date(timeIntervalSince1970: 3)), undoLabel: "完成") }
        _ = try await first.value
        _ = try await second.value
        #expect(store.calendarState.items[item.id]?.completedAt == Date(timeIntervalSince1970: 3))
        #expect(store.state.revision == 2)
    }

    @Test func deterministicClockIsCapturedOnceForEachDequeuedHead() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let firstItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "first")
        let secondItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "second")
        let clock = CountingTestClock()
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, clock: { clock.now() })
        await store.load()

        _ = try await store.sendCalendar(.createItem(firstItem), undoLabel: "first")
        _ = try await store.sendCalendar(.createItem(secondItem), undoLabel: "second")

        #expect(clock.calls == 2)
    }

    @Test func uncertainHeadParksAlreadyQueuedCallerUntilExplicitRetry() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let firstItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "first")
        let secondItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "second")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, clock: { .distantPast })
        await store.load()
        let first = Task { @MainActor in try await store.sendCalendar(.createItem(firstItem), undoLabel: "first") }
        await repository.waitForSaveStart()
        let second = Task { @MainActor in try await store.sendCalendar(.createItem(secondItem), undoLabel: "second") }
        await repository.resumeSave()
        let pending = try await first.value
        guard case let .commitPending(id, _) = pending else { Issue.record("Expected commit pending"); return }
        #expect(await repository.saveCount == 0)
        await repository.setReconciliation(.notCommitted(.init()))
        _ = try await store.retryPendingCommit(id)
        _ = try await second.value
        #expect(store.calendarState.items[secondItem.id] != nil)
        #expect(await repository.saveCount == 1)
    }

    @Test func stillPendingRetryDoesNotResumeTheOriginalCallerOrStartTheQueuedHead() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let firstItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "first")
        let secondItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "second")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let artifacts = WorkspacePendingCommitArtifacts()
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(artifacts))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let first = Task { @MainActor in try await store.sendCalendar(.createItem(firstItem), undoLabel: "first") }
        await repository.waitForSaveStart()
        let second = Task { @MainActor in try await store.sendCalendar(.createItem(secondItem), undoLabel: "second") }
        await repository.resumeSave()
        let initial = try await first.value
        let transactionID = try #require({ if case let .commitPending(value, _) = initial { value } else { nil } }())

        #expect(try await store.retryPendingCommit(transactionID) == .stillPending(transactionID: transactionID, artifacts: artifacts))
        #expect(await repository.saveCount == 0)
        await repository.setReconciliation(.notCommitted(artifacts))
        _ = try await store.retryPendingCommit(transactionID)
        _ = try await second.value

        #expect(store.state.calendar.items[firstItem.id] == nil)
        #expect(store.state.calendar.items[secondItem.id] != nil)
        #expect(await repository.saveCount == 1)
    }

    @Test func committedRetryPublishesTheParkedCandidateExactlyOnce() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "parked")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.makeNextSaveUncertain()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let pending = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        let id = try #require({ if case let .commitPending(value, _) = pending { value } else { nil } }())
        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 1, persistedDraft: nil))))

        #expect(try await store.retryPendingCommit(id) == .committed(.save(.init(workspaceRevision: 1, persistedDraft: nil)), journal: .clean))
        #expect(store.calendarState.items[item.id] != nil)
        #expect(store.state.revision == 1)
        #expect(store.canUndo)
    }

    @Test func immediateUncertainDraftCommitRecordsAndClearsItsExactJournalReceipt() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "uncertain committed"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-immediate-uncertain-committed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 2, persistedDraft: nil))))
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        let outcome = try await store.submitDraft(submission)

        guard case .committed(_, journal: .clean) = outcome else {
            Issue.record("Immediate committed reconciliation must resolve its Journal receipt")
            return
        }
        #expect(store.state.notes[submission.noteID]?.title == "uncertain committed")
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func immediateUncertainDraftNotCommittedUnbindsWithoutPublishingOrParkingCleanup() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "uncertain rejected"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-immediate-uncertain-not-committed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.notCommitted(.init()))
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        let outcome = try await store.submitDraft(submission)

        guard case .notCommitted(_, journal: .clean, _) = outcome else {
            Issue.record("Immediate not-committed reconciliation must exact-unbind its Journal receipt")
            return
        }
        let record = try #require(await journal.current()?.records.first)
        #expect(record.pendingReceipt == nil)
        #expect(record.savedReceipt == nil)
        #expect(store.state == state)
        #expect(store.phase == .ready)
    }

    @Test func uncertainNotCommittedDraftWithUnbindFailureParksOnlyThatCleanupStep() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "uncertain then rejected"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-uncertain-not-committed-unbind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        writer.failOnWriteNumber = 3
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.notCommitted(.init()))
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        let result = try await store.submitDraft(submission)
        let identity = DraftJournalIdentity(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID))

        guard case let .notCommitted(_, journal: status, artifacts: _) = result else {
            Issue.record("Expected a typed not-committed cleanup result")
            return
        }
        #expect(status == .cleanupPending(identity: identity, step: .unbind))
        #expect(store.phase == .parkedJournalCleanup(identity, .unbind))
        #expect(store.state == state)
        writer.failOnWriteNumber = nil

        #expect(await store.retryJournalCleanup(identity) == .clean)
        let protected = try #require(await journal.current()?.records.first)
        #expect(protected.pendingReceipt == nil)
        #expect(protected.savedReceipt == nil)
        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 0)
    }

    @Test func definiteSaveFailureWithUnbindCleanupFailureReturnsTypedTerminalAndPausesTheQueuedCaller() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "must remain journaled"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-definite-unbind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        writer.failOnWriteNumber = 3
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.suspendNextSave()
        await repository.failNextSave()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        let tail = try makeItem(id: UUID(), categoryID: state.calendar.uncategorizedID, title: "must wait")

        let head = Task { @MainActor in try await store.submitDraft(submission) }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(tail), undoLabel: "tail") }
        await repository.resumeSave()
        let outcome = try await head.value
        let identity = DraftJournalIdentity(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID))

        guard case let .notCommitted(transactionID, journalStatus, artifacts) = outcome else {
            Issue.record("The definite save failure must return a typed terminal outcome when exact unbind is pending")
            return
        }
        #expect(journalStatus == .cleanupPending(identity: identity, step: .unbind))
        #expect(artifacts == .init())
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(store.phase == .parkedJournalCleanup(identity, .unbind))
        #expect(store.state == state)
        writer.failOnWriteNumber = nil
        #expect(await store.retryJournalCleanup(identity) == .clean)
        _ = try await queued.value
        #expect(store.calendarState.items[tail.id] != nil)
    }

    @Test func sourceChangedRetryNeverPublishesTheParkedCandidate() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "lost")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.makeNextSaveUncertain()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let pending = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        let id = try #require({ if case let .commitPending(value, _) = pending { value } else { nil } }())
        await repository.setReconciliation(.sourceChanged(.init()))

        let retry = try await store.retryPendingCommit(id)

        guard case .sourceChanged = retry else { Issue.record("Expected source changed terminal retry"); return }
        #expect(store.calendarState.items[item.id] == nil)
        #expect(store.canUndo == false)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
    }

    @Test func sourceChangedRetryTerminatesTheCallerAlreadyQueuedBehindItsParkedHead() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let firstItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "parked")
        let secondItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "queued")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let first = Task { @MainActor in try await store.sendCalendar(.createItem(firstItem), undoLabel: "first") }
        await repository.waitForSaveStart()
        let second = Task { @MainActor in try await store.sendCalendar(.createItem(secondItem), undoLabel: "second") }
        await repository.resumeSave()
        let pending = try await first.value
        let transactionID = try #require({ if case let .commitPending(value, _) = pending { value } else { nil } }())
        await repository.setReconciliation(.sourceChanged(.init()))

        _ = try await store.retryPendingCommit(transactionID)
        let queued = try await second.value

        guard case let .externalSourceChanged(queuedID?, reason, _, _) = queued else {
            Issue.record("The queued caller must receive a terminal source-changed outcome")
            return
        }
        #expect(queuedID != transactionID)
        #expect(reason == .externalBytesChanged)
        #expect(store.state.calendar.items[firstItem.id] == nil)
        #expect(store.state.calendar.items[secondItem.id] == nil)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(await repository.saveCount == 0)
    }

    @Test func definiteSaveFailureReturnsTypedNotCommittedWithoutPublishingRevisionOrUndo() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "unsaved")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.failNextSave()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let outcome = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        guard case let .notCommitted(transactionID, journal, artifacts) = outcome else {
            Issue.record("A definite repository failure must not escape as an ambiguous caller throw")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(journal == .clean)
        #expect(artifacts == .init())
        #expect(store.state.revision == 0)
        #expect(store.calendarState.items[item.id] == nil)
        #expect(store.canUndo == false)
    }

    @Test func staleUpdatePayloadCannotOverwriteLatestCompletion() async throws {
        var calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "completed")
        let completion = Date(timeIntervalSince1970: 44)
        var current = item
        current.completedAt = completion
        calendar.items[item.id] = current
        var staleEditorPayload = item
        staleEditorPayload.title = "renamed"
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()

        _ = try await store.sendCalendar(.updateItem(staleEditorPayload), undoLabel: "rename")

        #expect(store.calendarState.items[item.id]?.title == "renamed")
        #expect(store.calendarState.items[item.id]?.completedAt == completion)
    }

    @Test func queuedEditorUpdateAndDedicatedCompletionEachReduceAtTheirOwnLatestQueueHead() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "original")
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.calendar.items[item.id] = item
        initial.revision = 1
        var editorPayload = item
        editorPayload.title = "renamed"
        let completion = Date(timeIntervalSince1970: 99)
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let update = Task { @MainActor in try await store.sendCalendar(.updateItem(editorPayload), undoLabel: "rename") }
        await repository.waitForSaveStart()
        let complete = Task { @MainActor in try await store.sendCalendar(.setTaskCompleted(item.id, completion), undoLabel: "complete") }
        await repository.resumeSave()
        _ = try await update.value
        _ = try await complete.value

        #expect(store.calendarState.items[item.id]?.title == "renamed")
        #expect(store.calendarState.items[item.id]?.completedAt == completion)
        #expect(store.state.revision == 3)
    }

    @Test func queuedDedicatedCompletionThenStaleEditorUpdatePreservesTheCompletionAtItsOwnLatestHead() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "original")
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.calendar.items[item.id] = item
        initial.revision = 1
        var staleEditorPayload = item
        staleEditorPayload.title = "renamed after completion"
        let completion = Date(timeIntervalSince1970: 101)
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let complete = Task { @MainActor in
            try await store.sendCalendar(.setTaskCompleted(item.id, completion), undoLabel: "complete")
        }
        await repository.waitForSaveStart()
        let update = Task { @MainActor in
            try await store.sendCalendar(.updateItem(staleEditorPayload), undoLabel: "rename")
        }
        await repository.resumeSave()
        _ = try await complete.value
        _ = try await update.value

        #expect(store.calendarState.items[item.id]?.title == "renamed after completion")
        #expect(store.calendarState.items[item.id]?.completedAt == completion)
        #expect(store.state.revision == 3)
    }

    @Test func suspendedCalendarSaveThenQueuedDraftReducesAgainstThePublishedCalendarHead() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "draft after calendar"
        let draft = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let item = try makeItem(id: UUID(), categoryID: state.calendar.uncategorizedID, title: "calendar head")
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: state, repository: repository)
        await store.load()

        let calendarHead = Task { @MainActor in try await store.sendCalendar(.createItem(item), undoLabel: "calendar") }
        await repository.waitForSaveStart()
        let queuedDraft = Task { @MainActor in try await store.submitDraft(draft) }
        await repository.resumeSave()
        _ = try await calendarHead.value
        _ = try await queuedDraft.value

        #expect(store.calendarState.items[item.id] != nil)
        #expect(store.state.notes[draft.noteID]?.title == "draft after calendar")
        #expect(store.state.revision == state.revision + 2)
    }

    @Test func undoRedoAndUndoRemainPersistedTransactions() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "roundtrip")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        let firstRevision = store.state.revision
        _ = try await store.undo()
        let undoRevision = store.state.revision
        _ = try await store.redo()
        let redoRevision = store.state.revision
        _ = try await store.undo()

        #expect(firstRevision == 1)
        #expect(undoRevision == 2)
        #expect(redoRevision == 3)
        #expect(store.state.revision == 4)
        #expect(store.calendarState.items[item.id] == nil)
    }

    @Test func uncertainUndoParksItsExactStackTransitionAndBlocksTheNextCallerUntilRetry() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let created = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "created")
        let later = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "later")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendCalendar(.createItem(created), undoLabel: "create")
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))

        let undoTask = Task { @MainActor in try await store.undo() }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(later), undoLabel: "later") }
        await repository.resumeSave()
        let undo = try await undoTask.value
        let transactionID = try #require({ if case let .commitPending(value, _) = undo { value } else { nil } }())

        #expect(store.calendarState.items[created.id] != nil)
        #expect(store.calendarState.items[later.id] == nil)
        #expect(store.canUndo)
        #expect(store.canRedo == false)
        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 2, persistedDraft: nil))))
        #expect(try await store.retryPendingCommit(transactionID) == .committed(.save(.init(workspaceRevision: 2, persistedDraft: nil)), journal: .clean))
        _ = try await queued.value
        #expect(store.calendarState.items[created.id] == nil)
        #expect(store.calendarState.items[later.id] != nil)
        #expect(store.canUndo)
    }

    @Test func notCommittedUndoRetryKeepsItsUndoStackAndPublishedCandidateUntouched() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "undo not committed")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let pending = try await store.undo()
        let transactionID = try #require({ if case let .commitPending(id, _) = pending { id } else { nil } }())
        await repository.setReconciliation(.notCommitted(.init()))

        #expect(try await store.retryPendingCommit(transactionID) == .notCommitted(transactionID: transactionID, journal: .clean, artifacts: .init()))
        #expect(store.calendarState.items[item.id] != nil)
        #expect(store.canUndo)
        #expect(store.canRedo == false)
        #expect(store.phase == .ready)
    }

    @Test func sourceChangedUndoRetryNeverConsumesTheUndoStackOrPublishesTheCandidate() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "undo source changed")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let pending = try await store.undo()
        let transactionID = try #require({ if case let .commitPending(id, _) = pending { id } else { nil } }())
        await repository.setReconciliation(.sourceChanged(.init()))

        #expect(try await store.retryPendingCommit(transactionID) == .sourceChanged(transactionID: transactionID, journal: .clean, artifacts: .init()))
        #expect(store.calendarState.items[item.id] != nil)
        #expect(store.canUndo)
        #expect(store.canRedo == false)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
    }

    @Test func uncertainRedoLeavesTheRedoRecordUntilItsExactRetryCommits() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "redo pending")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        _ = try await store.undo()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))

        let pending = try await store.redo()
        let transactionID = try #require({ if case let .commitPending(id, _) = pending { id } else { nil } }())
        #expect(store.calendarState.items[item.id] == nil)
        #expect(store.canRedo)
        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 3, persistedDraft: nil))))

        #expect(try await store.retryPendingCommit(transactionID) == .committed(.save(.init(workspaceRevision: 3, persistedDraft: nil)), journal: .clean))
        #expect(store.calendarState.items[item.id] != nil)
        #expect(store.canUndo)
        #expect(store.canRedo == false)
    }

    @Test func redoRetryNotCommittedAndSourceChangedNeverConsumeTheRedoRecord() async throws {
        for sourceChanged in [false, true] {
            let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
            let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "redo terminal")
            let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
            let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
            await store.load()
            _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
            _ = try await store.undo()
            await repository.makeNextSaveUncertain()
            await repository.setReconciliation(.stillPending(.init()))
            let pending = try await store.redo()
            let transactionID = try #require({ if case let .commitPending(id, _) = pending { id } else { nil } }())
            await repository.setReconciliation(sourceChanged ? .sourceChanged(.init()) : .notCommitted(.init()))

            let retry = try await store.retryPendingCommit(transactionID)

            if sourceChanged {
                #expect(retry == .sourceChanged(transactionID: transactionID, journal: .clean, artifacts: .init()))
                #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
            } else {
                #expect(retry == .notCommitted(transactionID: transactionID, journal: .clean, artifacts: .init()))
                #expect(store.phase == .ready)
            }
            #expect(store.calendarState.items[item.id] == nil)
            #expect(store.canRedo)
            #expect(store.canUndo == false)
        }
    }

    @Test func definiteNewSaveFailureReturnsTypedOutcomeAndLeavesRedoStackAndPublishedStateUntouched() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let original = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "original")
        let replacement = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "replacement")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendCalendar(.createItem(original), undoLabel: "create")
        _ = try await store.undo()
        #expect(store.canRedo)
        await repository.failNextSave()

        let outcome = try await store.sendCalendar(.createItem(replacement), undoLabel: "failed replacement")
        guard case let .notCommitted(transactionID, journal, artifacts) = outcome else {
            Issue.record("A definite new-save failure must have a terminal typed outcome")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(journal == .clean)
        #expect(artifacts == .init())

        #expect(store.calendarState.items[replacement.id] == nil)
        #expect(store.canRedo)
        _ = try await store.redo()
        #expect(store.calendarState.items[original.id] != nil)
        #expect(store.calendarState.items[replacement.id] == nil)
    }

    @Test func definiteUndoSaveFailureReturnsTypedOutcomeAndLeavesPublishedStateAndBothStacksUsable() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "undo must stay")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        let published = store.state
        await repository.failNextSave()

        let outcome = try await store.undo()
        guard case let .notCommitted(transactionID, journal, artifacts) = outcome else {
            Issue.record("A definite undo-save failure must have a terminal typed outcome")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(journal == .clean)
        #expect(artifacts == .init())

        #expect(store.state == published)
        #expect(store.canUndo)
        #expect(store.canRedo == false)
        _ = try await store.undo()
        #expect(store.calendarState.items[item.id] == nil)
        #expect(store.canRedo)
    }

    @Test func undoRevisionOverflowDoesNotSaveOrConsumeTheOptimisticUndoRecord() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.revision = Int64.max - 1
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "overflow")
        let repository = WorkspaceStoreTestRepository(initial: initial)
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        let published = store.state
        await #expect(throws: WorkspaceUndoReducerError.revisionOverflow) {
            _ = try await store.undo()
        }

        #expect(store.state == published)
        #expect(store.canUndo)
        #expect(store.canRedo == false)
        #expect(await repository.saveCount == 1)
    }

    @Test func verifiedIdenticalDraftAcknowledgesJournalWithoutSavingOrPublishing() async throws {
        let (state, note, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-nochange-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = PersistedDraftReceipt(noteID: note.id, editSessionID: .editor(submission.editSessionID), draftGeneration: submission.draftGeneration, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.verified(receipt))
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal, clock: { .distantPast })
        await store.load()

        #expect(try await store.submitDraft(submission) == .noChange(.identical, journal: .clean))
        #expect(await repository.saveCount == 0)
        #expect(store.state == state)
        #expect(store.canUndo == false)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func startupBareJournalUsesLockedVerificationThenAcknowledgesAndClears() async throws {
        let (state, note, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.revision = note.revision
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-startup-bare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        try await journal.persist(try DraftJournalCoordinator.entry(submission: submission, workspaceRevision: state.revision, clock: { .distantPast }))
        let receipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(submission.editSessionID), draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.verified(receipt))
        let store = WorkspaceStore(initialState: .empty(calendar: state.calendar), repository: repository, journal: journal)

        await store.load()

        #expect(store.phase == .ready)
        #expect(store.state == state)
        #expect(try await journal.current()?.records.isEmpty == true)
        #expect(await repository.saveCount == 0)
    }

    @Test func queuedLaterDraftGenerationReplaysOnlyItsDeltaAfterTheEarlierSave() async throws {
        let (state, _, original) = try draftFixture()
        var firstSnapshot = original.snapshot
        firstSnapshot.title = "first"
        let firstDraft = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 1,
            snapshot: firstSnapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(firstSnapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        var secondSnapshot = original.snapshot
        secondSnapshot.title = "second"
        let secondDraft = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 2,
            snapshot: secondSnapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(secondSnapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal, clock: { .distantPast })
        await store.load()
        let first = Task { @MainActor in try await store.submitDraft(firstDraft) }
        await repository.waitForSaveStart()
        let second = Task { @MainActor in try await store.submitDraft(secondDraft) }
        for _ in 0..<100 {
            if try await journal.current()?.records.first?.entry.draftGeneration == 2 { break }
            await Task.yield()
        }
        await repository.resumeSave()

        let firstOutcome = try await first.value
        guard case .committed(_, journal: .clean) = firstOutcome else {
            Issue.record("Earlier generation must not park cleanup after a newer generation replaces its Journal entry")
            return
        }
        guard case .committed(_, journal: .clean) = try await second.value else {
            Issue.record("Later generation should persist after a field-delta rebase")
            return
        }
        #expect(store.state.notes[original.noteID]?.title == "second")
        #expect(await repository.saveCount == 2)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func queuedDisjointLaterGenerationKeepsTheEarlierGenerationFieldInsteadOfReplacingItsSnapshot() async throws {
        var state: WorkspaceState
        let fixture = try draftFixture()
        state = fixture.0
        let original = fixture.2
        let secondCategory = UUID()
        state.calendar.categories[secondCategory] = .init(
            id: secondCategory, name: "later category", colorHex: "#007AFF", sortIndex: 1,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        var firstSnapshot = original.snapshot
        firstSnapshot.title = "first generation title"
        let first = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 1,
            snapshot: firstSnapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(firstSnapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        var secondSnapshot = original.snapshot
        secondSnapshot.categoryID = secondCategory
        let second = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 2,
            snapshot: secondSnapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(secondSnapshot),
            modifiedFields: [.categoryID], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-sequential-disjoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        let firstTask = Task { @MainActor in try await store.submitDraft(first) }
        await repository.waitForSaveStart()
        let secondTask = Task { @MainActor in try await store.submitDraft(second) }
        await repository.resumeSave()

        guard case .committed = try await firstTask.value,
              case .committed = try await secondTask.value
        else {
            Issue.record("Both disjoint generations must persist")
            return
        }
        #expect(store.state.notes[original.noteID]?.title == "first generation title")
        #expect(store.state.notes[original.noteID]?.categoryID == secondCategory)
        #expect(await repository.saveCount == 2)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func queuedThirdPartySameFieldDraftConflictsAndLeavesItsJournalRecordProtected() async throws {
        let (state, _, original) = try draftFixture()
        var firstSnapshot = original.snapshot
        firstSnapshot.title = "first editor"
        let first = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 1,
            snapshot: firstSnapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(firstSnapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        var thirdPartySnapshot = original.snapshot
        thirdPartySnapshot.title = "second editor"
        let thirdPartySession = UUID()
        let thirdParty = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: thirdPartySession, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 1,
            snapshot: thirdPartySnapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(thirdPartySnapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-sequential-third-party-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        let firstTask = Task { @MainActor in try await store.submitDraft(first) }
        await repository.waitForSaveStart()
        let thirdPartyTask = Task { @MainActor in try await store.submitDraft(thirdParty) }
        await repository.resumeSave()

        guard case .committed = try await firstTask.value,
              case .conflict = try await thirdPartyTask.value
        else {
            Issue.record("A third-party same-field draft must conflict rather than overwrite the accepted generation")
            return
        }
        #expect(store.state.notes[original.noteID]?.title == "first editor")
        let identity = DraftJournalIdentity(noteID: original.noteID, editSessionID: .editor(thirdPartySession))
        #expect(try await journal.current()?.records.contains { $0.identity == identity } == true)
        #expect(await repository.saveCount == 1)
    }

    @Test func startupResolvesExactPendingAndSavedJournalReceiptsIndependently() async throws {
        let (state, note, original) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-startup-receipts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let pendingSession = UUID()
        let savedSession = UUID()
        let pendingSubmission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: pendingSession, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 4,
            snapshot: note, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        let savedSubmission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: savedSession, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 5,
            snapshot: note, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        try await journal.persist(try DraftJournalCoordinator.entry(submission: pendingSubmission, workspaceRevision: state.revision, clock: { .distantPast }))
        try await journal.persist(try DraftJournalCoordinator.entry(submission: savedSubmission, workspaceRevision: state.revision, clock: { .distantPast }))
        let pendingReceipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(pendingSession), draftGeneration: 4,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        let savedReceipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(savedSession), draftGeneration: 5,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        _ = try await journal.rebaseAndBind(expected: .init(identity: .init(noteID: note.id, editSessionID: pendingReceipt.editSessionID), draftGeneration: 4), finalCandidateNote: note, receipt: pendingReceipt)
        _ = try await journal.rebaseAndBind(expected: .init(identity: .init(noteID: note.id, editSessionID: savedReceipt.editSessionID), draftGeneration: 5), finalCandidateNote: note, receipt: savedReceipt)
        _ = try await journal.record(savedReceipt)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.verified(pendingReceipt))
        let store = WorkspaceStore(initialState: .empty(calendar: state.calendar), repository: repository, journal: journal)

        await store.load()

        #expect(store.phase == .ready)
        #expect(try await journal.current()?.records.isEmpty == true)
        #expect(await repository.saveCount == 0)
    }

    @Test func startupPendingPreviousUnbindDoesNotLeaveALaterSavedReceiptBehind() async throws {
        let (state, note, original) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-startup-previous-then-saved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let previousSession = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let savedSession = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let previous = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: previousSession, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 1,
            snapshot: note, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        let saved = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: savedSession, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: 1,
            snapshot: note, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        try await journal.persist(try DraftJournalCoordinator.entry(submission: previous, workspaceRevision: state.revision, clock: { .distantPast }))
        try await journal.persist(try DraftJournalCoordinator.entry(submission: saved, workspaceRevision: state.revision, clock: { .distantPast }))
        let previousReceipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(previousSession), draftGeneration: 1,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        let savedReceipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(savedSession), draftGeneration: 1,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        _ = try await journal.rebaseAndBind(
            expected: .init(identity: .init(noteID: note.id, editSessionID: previousReceipt.editSessionID), draftGeneration: 1),
            finalCandidateNote: note, receipt: previousReceipt
        )
        _ = try await journal.rebaseAndBind(
            expected: .init(identity: .init(noteID: note.id, editSessionID: savedReceipt.editSessionID), draftGeneration: 1),
            finalCandidateNote: note, receipt: savedReceipt
        )
        _ = try await journal.record(savedReceipt)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.notPersisted)
        let store = WorkspaceStore(initialState: .empty(calendar: state.calendar), repository: repository, journal: journal)

        await store.load()

        #expect(store.phase == .ready)
        let envelope = try await journal.current()
        let remaining = try #require(envelope?.records)
        #expect(remaining.count == 1)
        #expect(remaining.first?.identity == .init(noteID: note.id, editSessionID: previousReceipt.editSessionID))
        #expect(remaining.first?.pendingReceipt == nil)
        #expect(remaining.first?.savedReceipt == nil)
    }

    @Test func startupPendingReceiptWithChangedMainSourceFreezesAndPreservesItsExactBoundJournalRecord() async throws {
        let (state, note, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-startup-pending-source-changed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let entry = try DraftJournalCoordinator.entry(submission: submission, workspaceRevision: state.revision, clock: { .distantPast })
        try await journal.persist(entry)
        let receipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(submission.editSessionID), draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        _ = try await journal.rebaseAndBind(
            expected: .init(identity: .init(noteID: note.id, editSessionID: receipt.editSessionID), draftGeneration: receipt.draftGeneration),
            finalCandidateNote: note, receipt: receipt
        )
        let expectedBoundRecord = try #require(await journal.current()?.records.first)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.sourceChanged)
        let store = WorkspaceStore(initialState: .empty(calendar: state.calendar), repository: repository, journal: journal)

        await store.load()

        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(store.state == state)
        let protected = try #require(await journal.current()?.records.first)
        #expect(protected == expectedBoundRecord)
        #expect(await repository.saveCount == 0)
    }

    @Test func startupBareJournalWithUnreadableMainStaysProtectedAndNeverPublishesItsDraft() async throws {
        let (state, _, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-startup-bare-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let entry = try DraftJournalCoordinator.entry(submission: submission, workspaceRevision: state.revision, clock: { .distantPast })
        try await journal.persist(entry)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.unreadableUnknown)
        let store = WorkspaceStore(initialState: .empty(calendar: state.calendar), repository: repository, journal: journal)

        await store.load()

        #expect(store.phase == .unreadablePrimaryLoadFailed)
        #expect(store.state == state)
        let protected = try #require(await journal.current()?.records.first)
        #expect(protected.entry == entry)
        #expect(protected.pendingReceipt == nil)
        #expect(protected.savedReceipt == nil)
        #expect(await repository.saveCount == 0)
    }

    @Test func startupUnreadableJournalFreezesWithoutTreatingItsBytesAsAbsent() async throws {
        let (state, _, _) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-startup-corrupt-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("draft.json")
        let corrupt = Data("not a journal".utf8)
        try corrupt.write(to: file)
        let journal = DraftJournalRepository(fileURL: file)
        let repository = WorkspaceStoreTestRepository(initial: state)
        let store = WorkspaceStore(initialState: .empty(calendar: state.calendar), repository: repository, journal: journal)

        await store.load()

        #expect(store.phase == .unreadablePrimaryLoadFailed)
        #expect(try Data(contentsOf: file) == corrupt)
        #expect(store.state == state)
    }

    @Test func unverifiedIdenticalDraftFreezesAsPublishedDraftNotPersisted() async throws {
        let (state, _, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-not-persisted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.notPersisted)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal, clock: { .distantPast })
        await store.load()

        let outcome = try await store.submitDraft(submission)

        guard case let .externalSourceChanged(_, reason, _, _) = outcome else { Issue.record("Expected external-source typed result"); return }
        #expect(reason == .publishedDraftNotPersisted)
        #expect(store.phase == .externalSourceChanged(.publishedDraftNotPersisted))
        #expect(await repository.saveCount == 0)
    }

    @Test func sourceChangedIdenticalDraftFreezesWithExternalBytesReason() async throws {
        let (state, _, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-source-changed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.sourceChanged)
        let store = WorkspaceStore(initialState: state, repository: repository, journal: DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json")))
        await store.load()
        let outcome = try await store.submitDraft(submission)
        guard case let .externalSourceChanged(_, reason, _, _) = outcome else { Issue.record("Expected external source change"); return }
        #expect(reason == .externalBytesChanged)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
    }

    @Test func unreadableIdenticalDraftBecomesTypedPersistenceBlock() async throws {
        let (state, _, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.unreadableUnknown)
        let store = WorkspaceStore(initialState: state, repository: repository, journal: DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json")))
        await store.load()
        let outcome = try await store.submitDraft(submission)
        guard case let .persistenceBlocked(transactionID, reason, journalStatus) = outcome else { Issue.record("Expected persistence block"); return }
        #expect(transactionID != nil)
        #expect(reason == .unreadablePrimary)
        #expect(journalStatus == .clean)
        #expect(store.phase == .unreadablePrimaryLoadFailed)
    }

    @Test func newOrdinaryRequestAfterAnUnreadableDraftVerificationGetsTheSameTypedBlock() async throws {
        let (state, _, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-unreadable-next-request-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.unreadableUnknown)
        let store = WorkspaceStore(
            initialState: state,
            repository: repository,
            journal: DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        )
        await store.load()
        _ = try await store.submitDraft(submission)
        let item = try makeItem(id: UUID(), categoryID: state.calendar.uncategorizedID, title: "must remain blocked")

        let outcome = try await store.sendCalendar(.createItem(item), undoLabel: "blocked")

        #expect(outcome == .persistenceBlocked(transactionID: nil, reason: .unreadablePrimary, journal: .clean))
        #expect(store.state == state)
        #expect(await repository.saveCount == 0)
    }

    @Test func journalRecordCleanupParksThenRetriesWithoutRepublishing() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "saved draft"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-store-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let repository = WorkspaceStoreTestRepository(initial: state)
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        writer.failOnWriteNumber = 3
        let result = try await store.submitDraft(submission)
        guard case let .committed(_, journal: .cleanupPending(identity, step)) = result else { Issue.record("Expected cleanup parking"); return }
        #expect(step == .record)
        let published = store.state
        writer.failOnWriteNumber = nil

        #expect(await store.retryJournalCleanup(identity) == .clean)
        #expect(store.state == published)
        #expect(await repository.saveCount == 1)
        #expect(await repository.reconciliationCount == 0)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func recordCleanupRetryAdvancesToClearAndSecondRetryUsesOnlyTheNewStep() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "两阶段清理"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6c-two-stage-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let repository = WorkspaceStoreTestRepository(initial: state)
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()
        writer.failOnWriteNumber = 3

        let first = try await store.submitDraft(submission)
        let identity = DraftJournalIdentity(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID))
        guard case .committed(_, journal: .cleanupPending(identity, .record)) = first else {
            Issue.record("初次 record 失败必须停车在 record")
            return
        }
        #expect(store.phase == .parkedJournalCleanup(identity, .record))
        writer.failOnWriteNumber = 5

        #expect(await store.retryJournalCleanup(identity) == .cleanupPending(identity: identity, step: .clear))
        #expect(store.phase == .parkedJournalCleanup(identity, .clear))
        let afterRecord = try #require(await journal.current()?.records.first)
        #expect(afterRecord.savedReceipt != nil)
        writer.failOnWriteNumber = nil

        #expect(await store.retryJournalCleanup(identity) == .clean)
        #expect(store.phase == .ready)
        #expect(try await journal.current()?.records.isEmpty == true)
        #expect(await repository.saveCount == 1)
    }

    @Test func verifiedNoChangeAcknowledgementFailureRetriesTheSameJournalStep() async throws {
        let (state, note, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-ack-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let receipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(submission.editSessionID), draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.verified(receipt))
        writer.failOnWriteNumber = 2
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        let outcome = try await store.submitDraft(submission)
        let identity = DraftJournalIdentity(noteID: note.id, editSessionID: receipt.editSessionID)
        #expect(outcome == .noChange(.identical, journal: .cleanupPending(identity: identity, step: .acknowledge)))
        #expect(store.phase == .parkedJournalCleanup(identity, .acknowledge))
        writer.failOnWriteNumber = nil

        #expect(await store.retryJournalCleanup(identity) == .clean)
        #expect(try await journal.current()?.records.isEmpty == true)
        #expect(store.state == state)
        #expect(await repository.saveCount == 0)
    }

    @Test func journalBindFailureKeepsThePersistedDraftBareAndPreventsTheMainSave() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "bound only after a final candidate exists"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-bind-before-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        writer.failOnWriteNumber = 2
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let repository = WorkspaceStoreTestRepository(initial: state)
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.submitDraft(submission)
        }

        #expect(store.state == state)
        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 0)
        let protected = try #require(await journal.current()?.records.first)
        #expect(protected.entry.noteSnapshotChecksum == submission.noteSnapshotChecksum)
        #expect(protected.pendingReceipt == nil)
        #expect(protected.savedReceipt == nil)
    }

    @Test func directSourceChangeUnbindFailureParksAndRetriesOnlyTheUnbind() async throws {
        let (state, _, original) = try draftFixture()
        var snapshot = original.snapshot
        snapshot.title = "unsaved changed draft"
        let submission = NoteDraftSubmission(
            noteID: original.noteID, editSessionID: original.editSessionID, baseNoteRevision: original.baseNoteRevision,
            baseNoteSnapshotChecksum: original.baseNoteSnapshotChecksum, baseSnapshot: original.baseSnapshot,
            baseLinkedTaskBlockLinks: original.baseLinkedTaskBlockLinks, draftGeneration: original.draftGeneration,
            snapshot: snapshot, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(snapshot),
            modifiedFields: [.title], linkedBlockDeletionDispositions: [:]
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-unbind-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        writer.failOnWriteNumber = 3
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.failNextSaveWithSourceChanged()
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        let result = try await store.submitDraft(submission)
        let identity = DraftJournalIdentity(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID))
        guard case let .externalSourceChanged(_, _, journalStatus, _) = result else { Issue.record("Expected source-change result"); return }
        #expect(journalStatus == .cleanupPending(identity: identity, step: .unbind))
        #expect(store.phase == .parkedJournalCleanup(identity, .unbind))
        writer.failOnWriteNumber = nil

        #expect(await store.retryJournalCleanup(identity) == .clean)
        let envelope = try await journal.current()
        let record = try #require(envelope?.records.first)
        #expect(record.pendingReceipt == nil)
        #expect(record.savedReceipt == nil)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(store.state == state)
        #expect(await repository.saveCount == 0)
    }

    @Test func verifiedNoChangeClearFailureRetriesOnlyTheClear() async throws {
        let (state, note, submission) = try draftFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-clear-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableStoreJournalWriter()
        writer.failOnWriteNumber = 3
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        let receipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(submission.editSessionID), draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), persistedNoteRevision: note.revision
        )
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setVerification(.verified(receipt))
        let store = WorkspaceStore(initialState: state, repository: repository, journal: journal)
        await store.load()

        let outcome = try await store.submitDraft(submission)
        let identity = DraftJournalIdentity(noteID: note.id, editSessionID: receipt.editSessionID)
        #expect(outcome == .noChange(.identical, journal: .cleanupPending(identity: identity, step: .clear)))
        writer.failOnWriteNumber = nil

        #expect(await store.retryJournalCleanup(identity) == .clean)
        #expect(try await journal.current()?.records.isEmpty == true)
        #expect(store.state == state)
        #expect(await repository.saveCount == 0)
    }

    @Test func restoreInspectsThenPublishesOnceWithAbsentPrimaryArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let item = try makeItem(id: UUID(), categoryID: category, title: "restored")
        var restored = initial
        restored.calendar.items[item.id] = item
        restored.revision = 1
        let source = directory.appendingPathComponent("source.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initial })
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        let preview = try await BackupService().inspectRestoreSource(source)

        let outcome = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))

        guard case let .restored(restoration) = outcome else { Issue.record("Expected restored outcome"); return }
        #expect(restoration.rollback == .nonePreviousSourceAbsent)
        #expect(store.state.calendar.items[item.id] != nil)
        #expect(store.state.revision == 2)
    }

    @Test func restoreKeepsDeletedNoteHighWatermarkForLaterSameIDRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-note-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let calendar = CalendarState.empty(uncategorizedID: category, now: .distantPast)
        let noteID = NoteID(UUID())
        var initial = WorkspaceState.empty(calendar: calendar)
        var original = Note.empty(id: noteID, categoryID: category, now: .distantPast)
        original.revision = 5
        initial.notes[noteID] = original
        initial.revision = 5
        let initialState = initial
        var restored = WorkspaceState.empty(calendar: calendar)
        restored.revision = 5
        let source = directory.appendingPathComponent("without-note.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initialState }
        )
        let store = WorkspaceStore(initialState: initialState, repository: repository, clock: { .distantPast })
        await store.load()
        let preview = try await store.inspectRestoreSource(at: source)

        _ = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))
        #expect(store.state.notes[noteID] == nil)
        let recreated = Note.empty(id: noteID, categoryID: category, now: .distantPast)
        _ = try await store.sendWorkspace(.createNote(.init(note: recreated)), undoLabel: "recreate")

        #expect(store.state.notes[noteID]?.revision == 6)
        #expect(store.state.notes[noteID]?.revision != 1)
    }

    @Test func opaqueExternalPrimaryCanBeRecoveredOnlyThroughConfirmedRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-opaque-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let restoredItem = try makeItem(id: UUID(), categoryID: category, title: "recovered")
        var restored = initial
        restored.calendar.items[restoredItem.id] = restoredItem
        restored.revision = 1
        let document = directory.appendingPathComponent("calendar-v1.json")
        let source = directory.appendingPathComponent("restore.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: document, seed: { initial })
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        try Data("opaque primary bytes".utf8).write(to: document)

        _ = try await store.reloadExternalSource()
        #expect(store.phase == .opaquePrimaryLoadFailed)
        let preview = try await store.inspectRestoreSource(at: source)

        let outcome = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))

        guard case .restored = outcome else { Issue.record("Expected opaque primary recovery restore"); return }
        #expect(store.state.calendar.items[restoredItem.id] != nil)
        #expect(store.phase == .ready)
    }

    @Test func restoreIsAllowedFromThePublishedDraftNotPersistedExternalReason() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-published-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let calendar = CalendarState.empty(uncategorizedID: category, now: .distantPast)
        let note = Note.empty(id: NoteID(UUID()), categoryID: category, now: .distantPast)
        var initial = WorkspaceState.empty(calendar: calendar)
        initial.notes[note.id] = note
        let initialState = initial
        let draft = NoteDraftSubmission(
            noteID: note.id, editSessionID: UUID(), baseNoteRevision: note.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), baseSnapshot: note,
            baseLinkedTaskBlockLinks: [], draftGeneration: 1, snapshot: note,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        let restoredItem = try makeItem(id: UUID(), categoryID: category, title: "restored after draft warning")
        var restored = WorkspaceState.empty(calendar: calendar)
        restored.revision = 1
        restored.calendar.items[restoredItem.id] = restoredItem
        let source = directory.appendingPathComponent("restore.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initialState })
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: initialState, repository: repository, journal: journal)
        await store.load()

        let warning = try await store.submitDraft(draft)
        guard case .externalSourceChanged(_, .publishedDraftNotPersisted, _, _) = warning else {
            Issue.record("Expected the bare draft verification to freeze as published-not-persisted")
            return
        }
        let preview = try await store.inspectRestoreSource(at: source)

        let outcome = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))

        guard case .restored = outcome else { Issue.record("Restore must be permitted from every external-source reason"); return }
        #expect(store.calendarState.items[restoredItem.id] != nil)
        #expect(store.phase == .ready)
    }

    @Test func repairableExternalCandidateCanBeReplacedByConfirmedRestoreWithoutPublishingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-repair-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        var repairable = initial
        repairable.revision = 1
        repairable.calendarNoteRelations.baselines[.item(UUID())] = .init(primaryNoteID: nil, referenceNoteIDs: [])
        let item = try makeItem(id: UUID(), categoryID: category, title: "restored")
        var restored = initial
        restored.revision = 1
        restored.calendar.items[item.id] = item
        let source = directory.appendingPathComponent("restore.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let backing = JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initial }
        )
        let repository = RestoreCountingRepository(backing: backing)
        await repository.setReloaded(.valid(.init(
            state: repairable,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "repairable", sourceByteCount: 1),
            consistencyIssues: WorkspaceConsistencyInspector.inspect(repairable).issues
        )))
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        _ = try await store.reloadExternalSource()
        #expect(store.phase == .needsRelationshipRepair)
        #expect(store.state == initial)
        let preview = try await store.inspectRestoreSource(at: source)

        _ = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))

        #expect(store.state.calendar.items[item.id] != nil)
        #expect(store.phase == .ready)
    }

    @Test func restoreSourceChangedAfterUncertainCommitDiscardsItsPreparedCapability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let restoredItem = try makeItem(id: UUID(), categoryID: category, title: "restored")
        var restored = initial
        restored.calendar.items[restoredItem.id] = restoredItem
        restored.revision = 1
        let source = directory.appendingPathComponent("source.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let backing = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initial })
        let repository = RestoreCountingRepository(backing: backing)
        await repository.setCommitMode(.uncertain)
        await repository.setReconciliation(.sourceChanged(.init()))
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        let preview = try await BackupService().inspectRestoreSource(source)

        let outcome = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))

        guard case .externalSourceChanged = outcome else { Issue.record("Expected source-change restoration outcome"); return }
        #expect(await repository.discardCount == 1)
        #expect(store.state == initial)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
    }

    @Test func restoreCommitFailureAfterPrepareDiscardsTheCapabilityWithoutPublishing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-commit-failure-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let restoredItem = try makeItem(id: UUID(), categoryID: category, title: "never published")
        var restored = initial
        restored.revision = 1
        restored.calendar.items[restoredItem.id] = restoredItem
        let source = directory.appendingPathComponent("source.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let backing = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initial })
        let repository = RestoreCountingRepository(backing: backing)
        await repository.setCommitMode(.atomicWriteFailure)
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        let preview = try await store.inspectRestoreSource(at: source)

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))
        }

        #expect(await repository.discardCount == 1)
        #expect(store.state == initial)
        #expect(store.phase == .ready)
        #expect(store.canUndo == false)
        #expect(store.canRedo == false)
    }

    @Test func pendingRestoreRetryPublishesTheNormalizedCandidateOnceWithItsRollbackArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let restoredItem = try makeItem(id: UUID(), categoryID: category, title: "restored")
        var restored = initial
        restored.calendar.items[restoredItem.id] = restoredItem
        restored.revision = 1
        let source = directory.appendingPathComponent("source.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let backing = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initial })
        let repository = RestoreCountingRepository(backing: backing)
        let artifacts = WorkspacePendingCommitArtifacts(rollback: .nonePreviousSourceAbsent)
        await repository.setCommitMode(.uncertain)
        await repository.setReconciliation(.stillPending(artifacts))
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        let preview = try await BackupService().inspectRestoreSource(source)

        let pending = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))
        let transactionID = try #require({ if case let .commitPending(value, _) = pending { value } else { nil } }())
        #expect(store.state == initial)
        #expect(store.phase == .parkedCommitUncertain(transactionID))
        #expect(BackupRecoveryPolicy.actions(for: store.phase) == [.retryPendingCommit(transactionID)])
        let restoredOutcome = WorkspaceRestoreOutcome(
            receipt: .init(workspaceRevision: 2, persistedDraft: nil), rollback: .nonePreviousSourceAbsent
        )
        await repository.setReconciliation(.committed(.restore(restoredOutcome)))

        #expect(try await store.retryPendingCommit(transactionID) == .committed(.restore(restoredOutcome), journal: .clean))
        #expect(store.state.calendar.items[restoredItem.id] != nil)
        #expect(store.state.revision == 2)
        #expect(store.canUndo == false)
        #expect(store.canRedo == false)
    }

    @Test func pendingRestoreNotCommittedRetryPreservesArtifactsAndDiscardsItsPreparedCapability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-not-committed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let item = try makeItem(id: UUID(), categoryID: category, title: "not committed")
        var restored = initial
        restored.revision = 1
        restored.calendar.items[item.id] = item
        let source = directory.appendingPathComponent("source.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let backing = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initial })
        let repository = RestoreCountingRepository(backing: backing)
        let artifacts = WorkspacePendingCommitArtifacts(rollback: .nonePreviousSourceAbsent)
        await repository.setCommitMode(.uncertain)
        await repository.setReconciliation(.stillPending(artifacts))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        let preview = try await store.inspectRestoreSource(at: source)
        let pending = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))
        let transactionID = try #require({ if case let .commitPending(value, _) = pending { value } else { nil } }())
        await repository.setReconciliation(.notCommitted(artifacts))

        let retry = try await store.retryPendingCommit(transactionID)

        #expect(retry == .notCommitted(transactionID: transactionID, journal: .clean, artifacts: artifacts))
        #expect(await repository.discardCount == 1)
        #expect(store.state == initial)
        #expect(store.phase == .ready)
    }

    @Test func pendingRestoreSourceChangedRetryPreservesArtifactsDiscardsAndFreezes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-restore-retry-source-changed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let item = try makeItem(id: UUID(), categoryID: category, title: "source changed")
        var restored = initial
        restored.revision = 1
        restored.calendar.items[item.id] = item
        let source = directory.appendingPathComponent("source.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let backing = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initial })
        let repository = RestoreCountingRepository(backing: backing)
        let artifacts = WorkspacePendingCommitArtifacts(rollback: .nonePreviousSourceAbsent)
        await repository.setCommitMode(.uncertain)
        await repository.setReconciliation(.stillPending(artifacts))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        let preview = try await store.inspectRestoreSource(at: source)
        let pending = try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))
        let transactionID = try #require({ if case let .commitPending(value, _) = pending { value } else { nil } }())
        await repository.setReconciliation(.sourceChanged(artifacts))

        let retry = try await store.retryPendingCommit(transactionID)

        #expect(retry == .sourceChanged(transactionID: transactionID, journal: .clean, artifacts: artifacts))
        #expect(await repository.discardCount == 1)
        #expect(store.state == initial)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
    }

    @Test func queuedDraftAfterV1V2OrV3RestoreIsConflictedAndItsJournalEntrySurvives() async throws {
        for schema in [1, 2, 3] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "jelly-6b-restore-draft-\(schema)-\(UUID().uuidString)", isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let category = UUID()
            let calendar = CalendarState.empty(uncategorizedID: category, now: .distantPast)
            let base = Note.empty(id: NoteID(UUID()), categoryID: category, now: .distantPast)
            var note = base
            note.revision = 1
            var initial = WorkspaceState.empty(calendar: calendar)
            initial.revision = 1
            initial.notes[note.id] = note
            let initialState = initial
            let submission = NoteDraftSubmission(
                noteID: note.id, editSessionID: UUID(), baseNoteRevision: note.revision,
                baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
                baseSnapshot: note, baseLinkedTaskBlockLinks: [], draftGeneration: 1,
                snapshot: note, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
                modifiedFields: [], linkedBlockDeletionDispositions: [:]
            )
            let source = directory.appendingPathComponent("restore-\(schema).json")
            try writeLegacyOrWorkspaceRestoreSource(schema: schema, calendar: calendar, to: source)
            let backing = JSONWorkspaceRepository(
                documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initialState }
            )
            let repository = RestoreCountingRepository(backing: backing)
            await repository.suspendNextCommit()
            let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
            let store = WorkspaceStore(initialState: initial, repository: repository, journal: journal, clock: { .distantPast })
            await store.load()
            let preview: WorkspaceRestorePreview
            do {
                preview = try await store.inspectRestoreSource(at: source)
            } catch {
                Issue.record("Schema \(schema) restore preview unexpectedly failed: \(error)")
                continue
            }
            #expect(preview.loadResult.provenance.sourceSchema == schema)

            let restoreTask = Task { @MainActor in
                try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("rollbacks", isDirectory: true))
            }
            await repository.waitForCommitStart()
            let draftTask = Task { @MainActor in try await store.submitDraft(submission) }
            await Task.yield()
            await repository.resumeCommit()

            guard case .restored = try await restoreTask.value else {
                Issue.record("Expected schema \(schema) restore to commit")
                continue
            }
            guard case .conflict = try await draftTask.value else {
                Issue.record("Queued draft must conflict after schema \(schema) restores its Note away")
                continue
            }
            let envelope = try #require(await journal.current())
            #expect(envelope.records.contains { $0.identity.noteID == note.id })
            #expect(store.state.notes[note.id] == nil)

            let restartRepository = JSONWorkspaceRepository(
                documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { initialState }
            )
            let restarted = WorkspaceStore(initialState: initialState, repository: restartRepository)
            await restarted.load()
            #expect(restarted.phase == .ready)
            #expect(restarted.state.revision == store.state.revision)
            #expect(restarted.state.notes.values.allSatisfy { $0.revision <= restarted.state.revision })
        }
    }

    @Test func externalNormalizationPublishesOnlyAfterRepositorySave() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "external")
        var external = initial
        external.calendar.items[item.id] = item
        external.revision = 1
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(state: external, provenance: .init(sourceSchema: 3, sourceBytesSHA256: "external", sourceByteCount: 1), consistencyIssues: [])))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        _ = try await store.reloadExternalSource()

        #expect(store.state.calendar.items[item.id] != nil)
        #expect(await repository.saveCount == 1)
        #expect(store.phase == .ready)
    }

    @Test func uncertainExternalNormalizationParksItsCandidateUntilTheExactRetryCommitsThenDrainsItsQueuedTail() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "external pending")
        let tail = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "queued after external")
        var external = initial
        external.revision = 1
        external.calendar.items[item.id] = item
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external, provenance: .init(sourceSchema: 2, sourceBytesSHA256: "normalize", sourceByteCount: 1), consistencyIssues: []
        )))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let head = Task { @MainActor in try await store.reloadExternalSource() }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(tail), undoLabel: "ordinary tail") }
        await repository.resumeSave()
        let outcome = try await head.value
        let transactionID = try #require({
            if case let .transaction(.commitPending(id, _)) = outcome { id } else { nil }
        }())
        #expect(store.state == initial)
        #expect(try await store.retryPendingCommit(transactionID) == .stillPending(transactionID: transactionID, artifacts: .init()))
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 1, persistedDraft: nil))))

        #expect(try await store.retryPendingCommit(transactionID) == .committed(.save(.init(workspaceRevision: 1, persistedDraft: nil)), journal: .clean))
        guard case .committed = try await queued.value else {
            Issue.record("The queued tail must only run after the external normalization head commits")
            return
        }
        #expect(store.state.calendar.items[item.id] != nil)
        #expect(store.state.calendar.items[tail.id] != nil)
        #expect(store.phase == .ready)
    }

    @Test func reloadDuringAnInFlightLocalHeadIsRejectedBeforeItCanPublishExternalState() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let localItem = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "local head")
        var exactExternal = initial
        exactExternal.revision = 7
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: exactExternal,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "exact-external", sourceByteCount: 1),
            consistencyIssues: []
        )))
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        let local = Task { @MainActor in
            try await store.sendCalendar(.createItem(localItem), undoLabel: "local")
        }
        await repository.waitForSaveStart()

        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await store.reloadExternalSource()
        }
        #expect(store.state == initial)

        await repository.resumeSave()
        _ = try await local.value
        #expect(store.state.calendar.items[localItem.id] != nil)
        #expect(store.state.revision == 1)
    }

    @Test func exactCurrentV3ExternalSourceUsesTheDirectAdoptionPredicateWithoutSaving() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: initial,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "exact-current", sourceByteCount: 1),
            consistencyIssues: []
        )))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        _ = try await store.reloadExternalSource()

        #expect(store.state == initial)
        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 0)
    }

    @Test func absentAndUnreadableExternalReloadsFreezeWithoutPublishingAnUnverifiedState() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let absentRepository = WorkspaceStoreTestRepository(initial: initial)
        await absentRepository.setReloaded(.absent)
        let absentStore = WorkspaceStore(initialState: initial, repository: absentRepository)
        await absentStore.load()

        _ = try await absentStore.reloadExternalSource()

        #expect(absentStore.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(absentStore.state == initial)
        let unreadableRepository = WorkspaceStoreTestRepository(initial: initial)
        await unreadableRepository.setReloaded(.unreadableUnknown)
        let unreadableStore = WorkspaceStore(initialState: initial, repository: unreadableRepository)
        await unreadableStore.load()

        _ = try await unreadableStore.reloadExternalSource()

        #expect(unreadableStore.phase == .unreadablePrimaryLoadFailed)
        #expect(unreadableStore.state == initial)
    }

    @Test func externalNormalizationSaveFailureReturnsTypedOutcomeAndLeavesPublishedStateAndLedgerUnadvanced() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "external")
        var external = initial
        external.calendar.items[item.id] = item
        external.revision = 1
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(state: external, provenance: .init(sourceSchema: 3, sourceBytesSHA256: "external", sourceByteCount: 1), consistencyIssues: [])))
        await repository.failNextSave()
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let outcome = try await store.reloadExternalSource()
        guard case let .transaction(.notCommitted(transactionID, journal, artifacts)) = outcome else {
            Issue.record("A definite normalization save failure must not escape as a throw")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(journal == .clean)
        #expect(artifacts == .init())

        #expect(store.state == initial)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(await repository.saveCount == 0)
    }

    @Test func externalNormalizationFailureDoesNotPublishOrAdvanceTheExternalNoteLedger() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let noteID = NoteID(UUID())
        var external = initial
        var externalNote = Note.empty(id: noteID, categoryID: calendar.uncategorizedID, now: .distantPast)
        externalNote.revision = 8
        external.notes[noteID] = externalNote
        external.revision = 8
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "external-note", sourceByteCount: 1),
            consistencyIssues: []
        )))
        await repository.failNextSave()
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let outcome = try await store.reloadExternalSource()
        guard case let .transaction(.notCommitted(transactionID, journal, artifacts)) = outcome else {
            Issue.record("The failed normalized external note must remain a typed terminal outcome")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(journal == .clean)
        #expect(artifacts == .init())
        #expect(store.state.notes[noteID] == nil)
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(await repository.saveCount == 0)
    }

    @Test func externalRelationshipRepairHoldsTheCandidateUntilExplicitRepairIsPersisted() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        var external = initial
        external.revision = 1
        external.calendarNoteRelations.baselines[.item(UUID())] = .init(
            primaryNoteID: nil, referenceNoteIDs: []
        )
        let report = WorkspaceConsistencyInspector.inspect(external)
        #expect(report.issues.count == 1)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "external-repair", sourceByteCount: 1),
            consistencyIssues: report.issues
        )))
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()

        _ = try await store.reloadExternalSource()

        #expect(store.phase == .needsRelationshipRepair)
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)

        let outcome = try await store.sendWorkspace(.repairConsistency(repair))

        guard case .committed = outcome else { Issue.record("Expected persisted external repair"); return }
        #expect(WorkspaceConsistencyInspector.inspect(store.state).issues.isEmpty)
        #expect(store.state.calendarNoteRelations.baselines.isEmpty)
        #expect(await repository.saveCount == 1)
        #expect(store.phase == .ready)
    }

    @Test func uncertainExternalRepairParksTheRepairCandidateUntilTheExactRetryCommitsThenDrainsItsQueuedTail() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        var external = initial
        external.revision = 1
        external.calendarNoteRelations.baselines[.item(UUID())] = .init(primaryNoteID: nil, referenceNoteIDs: [])
        let report = WorkspaceConsistencyInspector.inspect(external)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        let tail = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "after repair")
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external, provenance: .init(sourceSchema: 3, sourceBytesSHA256: "repair pending", sourceByteCount: 1), consistencyIssues: report.issues
        )))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        _ = try await store.reloadExternalSource()
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))

        let head = Task { @MainActor in try await store.sendWorkspace(.repairConsistency(repair)) }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(tail), undoLabel: "ordinary tail") }
        await repository.resumeSave()
        let pending = try await head.value
        let transactionID = try #require({ if case let .commitPending(id, _) = pending { id } else { nil } }())
        #expect(store.state == initial)
        #expect(try await store.retryPendingCommit(transactionID) == .stillPending(transactionID: transactionID, artifacts: .init()))
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 2, persistedDraft: nil))))

        #expect(try await store.retryPendingCommit(transactionID) == .committed(.save(.init(workspaceRevision: 2, persistedDraft: nil)), journal: .clean))
        guard case .committed = try await queued.value else {
            Issue.record("The ordinary tail must wait for the external repair commit")
            return
        }
        #expect(WorkspaceConsistencyInspector.inspect(store.state).issues.isEmpty)
        #expect(store.state.calendar.items[tail.id] != nil)
        #expect(store.phase == .ready)
    }

    @Test func notCommittedExternalRepairTerminatesItsQueuedOrdinaryTailAndRetainsTheRepairCandidate() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        var external = initial
        external.revision = 1
        external.calendarNoteRelations.baselines[.item(UUID())] = .init(primaryNoteID: nil, referenceNoteIDs: [])
        let report = WorkspaceConsistencyInspector.inspect(external)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        let tail = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "must not bypass repair")
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external, provenance: .init(sourceSchema: 3, sourceBytesSHA256: "repair retry", sourceByteCount: 1), consistencyIssues: report.issues
        )))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        _ = try await store.reloadExternalSource()

        let head = Task { @MainActor in try await store.sendWorkspace(.repairConsistency(repair)) }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(tail), undoLabel: "ordinary tail") }
        await repository.resumeSave()
        let pending = try await head.value
        let transactionID = try #require({ if case let .commitPending(id, _) = pending { id } else { nil } }())
        #expect(try await store.retryPendingCommit(transactionID) == .stillPending(transactionID: transactionID, artifacts: .init()))
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
        await repository.setReconciliation(.notCommitted(.init()))

        #expect(try await store.retryPendingCommit(transactionID) == .notCommitted(transactionID: transactionID, journal: .clean, artifacts: .init()))
        let tailOutcome = try await queued.value
        guard case .notCommitted = tailOutcome else {
            Issue.record("The queued ordinary command must terminate without reducing against the retained repair candidate")
            return
        }
        #expect(store.phase == .needsRelationshipRepair)
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
    }

    @Test func notCommittedExternalNormalizationFreezesAndTerminatesItsQueuedOrdinaryTail() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let adopted = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "external candidate")
        let tail = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "must re-reload")
        var external = initial
        external.revision = 1
        external.calendar.items[adopted.id] = adopted
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external, provenance: .init(sourceSchema: 2, sourceBytesSHA256: "normalization retry", sourceByteCount: 1), consistencyIssues: []
        )))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let head = Task { @MainActor in try await store.reloadExternalSource() }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(tail), undoLabel: "ordinary tail") }
        await repository.resumeSave()
        let pending = try await head.value
        let transactionID = try #require({
            if case let .transaction(.commitPending(id, _)) = pending { id } else { nil }
        }())
        #expect(try await store.retryPendingCommit(transactionID) == .stillPending(transactionID: transactionID, artifacts: .init()))
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
        await repository.setReconciliation(.notCommitted(.init()))

        #expect(try await store.retryPendingCommit(transactionID) == .notCommitted(transactionID: transactionID, journal: .clean, artifacts: .init()))
        let tailOutcome = try await queued.value
        guard case .externalSourceChanged = tailOutcome else {
            Issue.record("The queued ordinary command must not run after normalization requires re-reload")
            return
        }
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
    }

    @Test func sourceChangedExternalNormalizationFreezesAndTerminatesItsQueuedOrdinaryTail() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let adopted = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "external source changed")
        let tail = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "must not run")
        var external = initial
        external.revision = 1
        external.calendar.items[adopted.id] = adopted
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external, provenance: .init(sourceSchema: 2, sourceBytesSHA256: "normalization source changed", sourceByteCount: 1), consistencyIssues: []
        )))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        let head = Task { @MainActor in try await store.reloadExternalSource() }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(tail), undoLabel: "ordinary tail") }
        await repository.resumeSave()
        let pending = try await head.value
        let transactionID = try #require({
            if case let .transaction(.commitPending(id, _)) = pending { id } else { nil }
        }())
        #expect(try await store.retryPendingCommit(transactionID) == .stillPending(transactionID: transactionID, artifacts: .init()))
        await repository.setReconciliation(.sourceChanged(.init()))

        #expect(try await store.retryPendingCommit(transactionID) == .sourceChanged(transactionID: transactionID, journal: .clean, artifacts: .init()))
        let tailOutcome = try await queued.value
        guard case let .externalSourceChanged(tailID, reason, journal, artifacts) = tailOutcome else {
            Issue.record("The queued normalization tail must receive a typed external-source terminal outcome")
            return
        }
        #expect(tailID != transactionID)
        #expect(reason == .externalBytesChanged)
        #expect(journal == .clean)
        #expect(artifacts == .init())
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
    }

    @Test func sourceChangedExternalRepairFreezesAndTerminatesItsQueuedOrdinaryTail() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        var external = initial
        external.revision = 1
        external.calendarNoteRelations.baselines[.item(UUID())] = .init(primaryNoteID: nil, referenceNoteIDs: [])
        let report = WorkspaceConsistencyInspector.inspect(external)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        let tail = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "must not bypass changed repair")
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external, provenance: .init(sourceSchema: 3, sourceBytesSHA256: "repair source changed", sourceByteCount: 1), consistencyIssues: report.issues
        )))
        await repository.suspendNextSave()
        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        _ = try await store.reloadExternalSource()

        let head = Task { @MainActor in try await store.sendWorkspace(.repairConsistency(repair)) }
        await repository.waitForSaveStart()
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(tail), undoLabel: "ordinary tail") }
        await repository.resumeSave()
        let pending = try await head.value
        let transactionID = try #require({ if case let .commitPending(id, _) = pending { id } else { nil } }())
        #expect(try await store.retryPendingCommit(transactionID) == .stillPending(transactionID: transactionID, artifacts: .init()))
        await repository.setReconciliation(.sourceChanged(.init()))

        #expect(try await store.retryPendingCommit(transactionID) == .sourceChanged(transactionID: transactionID, journal: .clean, artifacts: .init()))
        let tailOutcome = try await queued.value
        guard case let .externalSourceChanged(tailID, reason, journal, artifacts) = tailOutcome else {
            Issue.record("The queued repair tail must receive a typed external-source terminal outcome")
            return
        }
        #expect(tailID != transactionID)
        #expect(reason == .externalBytesChanged)
        #expect(journal == .clean)
        #expect(artifacts == .init())
        #expect(store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(store.state == initial)
        #expect(await repository.saveCount == 0)
    }

    @Test func definiteExternalRepairSaveFailureReturnsTypedOutcomeAndKeepsTheRepairableCandidateFrozen() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        var external = initial
        external.revision = 1
        external.calendarNoteRelations.baselines[.item(UUID())] = .init(
            primaryNoteID: nil, referenceNoteIDs: []
        )
        let report = WorkspaceConsistencyInspector.inspect(external)
        let repair = WorkspaceConsistencyRepairPayload(
            expectedIssuesChecksum: report.issuesChecksum,
            resolutions: Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, .unlink) })
        )
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.setReloaded(.valid(.init(
            state: external,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "external-repair-failure", sourceByteCount: 1),
            consistencyIssues: report.issues
        )))
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        _ = try await store.reloadExternalSource()
        await repository.failNextSave()

        let outcome = try await store.sendWorkspace(.repairConsistency(repair))
        guard case let .notCommitted(transactionID, journal, artifacts) = outcome else {
            Issue.record("A definite repair-save failure must have a terminal typed outcome")
            return
        }
        #expect(transactionID.uuidString.isEmpty == false)
        #expect(journal == .clean)
        #expect(artifacts == .init())

        #expect(store.state == initial)
        #expect(store.phase == .needsRelationshipRepair)
        #expect(await repository.saveCount == 0)
        _ = try await store.sendWorkspace(.repairConsistency(repair))
        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 1)
    }

    @Test func storeOwnedBackupExportUsesOnlyItsWorkspaceRepositoryBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-store-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let category = UUID()
        let state = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let repository = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("calendar-v1.json"), seed: { state })
        let store = WorkspaceStore(initialState: state, repository: repository)
        await store.load()
        let item = try makeItem(id: UUID(), categoryID: category, title: "persist before export")
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        let destination = directory.appendingPathComponent("backup.json")

        try await store.exportBackup(to: destination)

        let exported = try Data(contentsOf: destination)
        let current = try await store.currentDocumentData()
        #expect(exported == current)
    }

    @Test func storeOwnedRawRecoveryCopyExportsOpaqueEvidenceWithoutPublishingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-raw-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = WorkspaceState.empty(calendar: .empty(uncategorizedID: UUID(), now: .distantPast))
        let raw = Data("opaque bytes".utf8)
        let artifact = WorkspaceRawRecoveryArtifact(
            rawData: raw, identity: .init(sha256: "evidence", byteCount: raw.count)
        )
        let repository = WorkspaceStoreTestRepository(initial: state)
        await repository.setRawRecoveryArtifact(artifact)
        let store = WorkspaceStore(initialState: state, repository: repository)
        await store.load()
        let destination = directory.appendingPathComponent("opaque-copy.json")

        _ = try await store.exportRawRecoveryCopy(to: destination)

        #expect(try Data(contentsOf: destination) == raw)
        #expect(store.state == state)
    }

    private func draftFixture() throws -> (WorkspaceState, Note, NoteDraftSubmission) {
        let category = UUID()
        let calendar = CalendarState.empty(uncategorizedID: category, now: .distantPast)
        let base = Note.empty(id: NoteID(UUID()), categoryID: category, now: .distantPast)
        var note = base
        note.revision = 1
        var state = WorkspaceState.empty(calendar: calendar)
        state.revision = 1
        state.notes[note.id] = note
        let submission = NoteDraftSubmission(
            noteID: note.id, editSessionID: UUID(), baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base, baseLinkedTaskBlockLinks: [], draftGeneration: 1,
            snapshot: base, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        return (state, note, submission)
    }

    private func makeItem(id: UUID, categoryID: UUID, title: String) throws -> CalendarItem {
        try CalendarItem(
            id: id, kind: .task, title: title, categoryID: categoryID,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 10)!, endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
    }

    private func writeLegacyOrWorkspaceRestoreSource(
        schema: Int,
        calendar: CalendarState,
        to destination: URL
    ) throws {
        let data: Data
        switch schema {
        case 1:
            data = Data("""
            {"schemaVersion":1,"state":{"categories":["00000000-0000-0000-0000-000000000501",{"id":"00000000-0000-0000-0000-000000000501","name":"未分类","colorHex":"#8E8E93","sortIndex":0,"createdAt":0,"updatedAt":0}],"items":[],"recurrence":{"series":[],"exceptions":[],"completions":[]},"uncategorizedID":"00000000-0000-0000-0000-000000000501"}}
            """.utf8)
        case 2:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            data = try encoder.encode(CalendarDocument(state: calendar))
        case 3:
            data = try WorkspaceDocumentCodec.encode(.empty(calendar: calendar))
        default:
            fatalError("Unexpected test schema")
        }
        try data.write(to: destination)
    }
}

private final class SwitchableStoreJournalWriter: AtomicFileWriting, @unchecked Sendable {
    var shouldFail = false
    var failOnWriteNumber: Int?
    private var writeCount = 0
    func replaceAtomically(data: Data, at destination: URL) throws {
        writeCount += 1
        if shouldFail || failOnWriteNumber == writeCount { throw WorkspacePersistenceError.atomicWriteFailed }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

private actor AsyncTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observedWaiter = false
    private var observedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        observedWaiter = true
        let observers = observedWaiters; observedWaiters.removeAll(); observers.forEach { $0.resume() }
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() }
    }

    func waitUntilWaited() async {
        guard !observedWaiter else { return }
        await withCheckedContinuation { observedWaiters.append($0) }
    }

}

private actor AsyncTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class CountingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var calls: Int { lock.withLock { storage } }
    func now() -> Date {
        lock.withLock {
            storage += 1
            return Date(timeIntervalSinceReferenceDate: TimeInterval(storage))
        }
    }
}

private actor RestoreCountingRepository: WorkspaceRepository {
    enum CommitMode: Sendable { case passthrough, directSourceChanged, uncertain, atomicWriteFailure }

    private let backing: JSONWorkspaceRepository
    private var mode: CommitMode = .passthrough
    private var reconciliation: WorkspaceCommitReconciliation?
    private var reloaded: WorkspaceReloadedSource?
    private var discardCountStorage = 0
    private var commitSuspended = false
    private var commitStarted = false
    private var saveCountStorage = 0
    private var commitStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitResumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(backing: JSONWorkspaceRepository) { self.backing = backing }

    func load() async throws -> WorkspaceLoadResult { try await backing.load() }
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt {
        let receipt = try await backing.save(state, draft: draft)
        saveCountStorage += 1
        return receipt
    }
    func verifyPersistedDraft(_ context: PersistableDraftContext) async throws -> WorkspaceDraftPersistenceVerification { try await backing.verifyPersistedDraft(context) }
    func prepareRestore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) async throws -> PreparedWorkspaceRestore {
        try await backing.prepareRestore(preview, rollbackDirectoryURL: rollbackDirectoryURL)
    }
    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) async -> Bool {
        discardCountStorage += 1
        return await backing.discardPreparedRestore(prepared)
    }
    func commitRestore(_ prepared: PreparedWorkspaceRestore, state: WorkspaceState) async throws -> WorkspaceRestoreOutcome {
        if commitSuspended {
            commitStarted = true
            let waiters = commitStartWaiters; commitStartWaiters.removeAll(); waiters.forEach { $0.resume() }
            await withCheckedContinuation { commitResumeWaiters.append($0) }
        }
        switch mode {
        case .passthrough:
            return try await backing.commitRestore(prepared, state: state)
        case .directSourceChanged:
            throw WorkspaceDirectCommitFailure.sourceChanged(.init())
        case .uncertain:
            throw WorkspacePersistenceError.commitUncertain
        case .atomicWriteFailure:
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }
    func currentDocumentData() async throws -> Data { try await backing.currentDocumentData() }
    func reloadCurrentSourceAfterExternalChange() async throws -> WorkspaceReloadedSource {
        if let reloaded { return reloaded }
        return try await backing.reloadCurrentSourceAfterExternalChange()
    }
    func currentRawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact { try await backing.currentRawRecoveryData() }
    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation {
        if let reconciliation { return reconciliation }
        return try await backing.reconcilePendingCommit()
    }

    func setCommitMode(_ mode: CommitMode) { self.mode = mode }
    func setReconciliation(_ value: WorkspaceCommitReconciliation) { reconciliation = value }
    func setReloaded(_ value: WorkspaceReloadedSource) { reloaded = value }
    func suspendNextCommit() { commitSuspended = true }
    func waitForCommitStart() async {
        guard !commitStarted else { return }
        await withCheckedContinuation { commitStartWaiters.append($0) }
    }
    func resumeCommit() {
        commitSuspended = false
        let waiters = commitResumeWaiters; commitResumeWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
    var discardCount: Int { discardCountStorage }
    var saveCount: Int { saveCountStorage }
}

actor WorkspaceStoreTestRepository: WorkspaceRepository {
    private var state: WorkspaceState
    private var loadFailure = false
    private var loadSuspended = false
    private var loadStarted = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadResumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveCountStorage = 0
    private var failSave = false
    private var unreadablePrimarySave = false
    private var invalidDraftContextSave = false
    private var sourceChangedSave = false
    private var saveUncertain = false
    private var verification: WorkspaceDraftPersistenceVerification = .notPersisted
    private var verificationSuspended = false
    private var verificationStarted = false
    private var verificationWaiters: [CheckedContinuation<Void, Never>] = []
    private var verificationResumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var reconciliation: WorkspaceCommitReconciliation = .stillPending(.init())
    private var reconciliationCountStorage = 0
    private var reloaded: WorkspaceReloadedSource?
    private var rawRecoveryArtifact: WorkspaceRawRecoveryArtifact?
    private var saveSuspended = false
    private var saveStarted = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveResumeWaiters: [CheckedContinuation<Void, Never>] = []
    init(initial: WorkspaceState) { state = initial }
    func load() async throws -> WorkspaceLoadResult {
        if loadSuspended {
            loadStarted = true
            let waiters = loadWaiters; loadWaiters.removeAll(); waiters.forEach { $0.resume() }
            await withCheckedContinuation { loadResumeWaiters.append($0) }
        }
        if loadFailure { loadFailure = false; throw WorkspacePersistenceError.invalidDocument }
        return .init(state: state, provenance: .init(sourceSchema: 3, sourceBytesSHA256: "test", sourceByteCount: 0), consistencyIssues: [])
    }
    func save(_ next: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt {
        if saveSuspended {
            saveStarted = true
            let waiters = saveWaiters; saveWaiters.removeAll(); waiters.forEach { $0.resume() }
            await withCheckedContinuation { saveResumeWaiters.append($0) }
        }
        if saveUncertain { saveUncertain = false; throw WorkspacePersistenceError.commitUncertain }
        if sourceChangedSave { sourceChangedSave = false; throw WorkspaceDirectCommitFailure.sourceChanged(.init()) }
        if unreadablePrimarySave {
            unreadablePrimarySave = false
            reloaded = .unreadableUnknown
            throw WorkspacePersistenceError.invalidDocument
        }
        if invalidDraftContextSave {
            invalidDraftContextSave = false
            throw WorkspacePersistenceError.invalidDraftContext
        }
        if failSave { failSave = false; throw WorkspacePersistenceError.atomicWriteFailed }
        state = next; saveCountStorage += 1
        return .init(workspaceRevision: next.revision, persistedDraft: draft.map { .init(noteID: $0.noteID, editSessionID: $0.editSessionID, draftGeneration: $0.draftGeneration, noteSnapshotChecksum: $0.noteSnapshotChecksum, persistedNoteRevision: $0.persistedNoteRevision) })
    }
    func verifyPersistedDraft(_ context: PersistableDraftContext) async throws -> WorkspaceDraftPersistenceVerification {
        if verificationSuspended {
            verificationStarted = true
            let waiters = verificationWaiters; verificationWaiters.removeAll(); waiters.forEach { $0.resume() }
            await withCheckedContinuation { verificationResumeWaiters.append($0) }
        }
        return verification
    }
    func prepareRestore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) throws -> PreparedWorkspaceRestore { throw WorkspacePersistenceError.invalidRestoreCapability }
    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) -> Bool { false }
    func commitRestore(_ prepared: PreparedWorkspaceRestore, state: WorkspaceState) throws -> WorkspaceRestoreOutcome { throw WorkspacePersistenceError.invalidRestoreCapability }
    func currentDocumentData() throws -> Data { Data() }
    func reloadCurrentSourceAfterExternalChange() async throws -> WorkspaceReloadedSource {
        if let reloaded { return reloaded }
        return .valid(try await load())
    }
    func currentRawRecoveryData() throws -> WorkspaceRawRecoveryArtifact {
        guard let rawRecoveryArtifact else { throw WorkspacePersistenceError.invalidDocument }
        return rawRecoveryArtifact
    }
    func reconcilePendingCommit() throws -> WorkspaceCommitReconciliation {
        reconciliationCountStorage += 1
        return reconciliation
    }
    var saveCount: Int { saveCountStorage }
    var persistedState: WorkspaceState { state }
    var reconciliationCount: Int { reconciliationCountStorage }
    func failNextLoad() { loadFailure = true }
    func suspendNextLoad() { loadSuspended = true }
    func waitForLoadStart() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }
    func resumeLoad() {
        loadSuspended = false
        let waiters = loadResumeWaiters; loadResumeWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
    func failNextSave() { failSave = true }
    func failNextSaveWithUnreadablePrimary() { unreadablePrimarySave = true }
    func failNextSaveWithInvalidDraftContext() { invalidDraftContextSave = true }
    func failNextSaveWithSourceChanged() { sourceChangedSave = true }
    func makeNextSaveUncertain() { saveUncertain = true }
    func setVerification(_ value: WorkspaceDraftPersistenceVerification) { verification = value }
    func suspendNextVerification() { verificationSuspended = true }
    func waitForVerificationStart() async {
        guard !verificationStarted else { return }
        await withCheckedContinuation { verificationWaiters.append($0) }
    }
    func resumeVerification() {
        verificationSuspended = false
        let waiters = verificationResumeWaiters; verificationResumeWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
    func setReloaded(_ value: WorkspaceReloadedSource) { reloaded = value }
    func setRawRecoveryArtifact(_ value: WorkspaceRawRecoveryArtifact) { rawRecoveryArtifact = value }
    func setReconciliation(_ value: WorkspaceCommitReconciliation) { reconciliation = value }
    func suspendNextSave() { saveSuspended = true }
    func waitForSaveStart() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }
    func resumeSave() {
        saveSuspended = false
        let waiters = saveResumeWaiters; saveResumeWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
}

// These are direct behavioral ports of the deleted calendar-store assertions.
// Workspace now queues an in-flight operation rather than throwing for every
// concurrent caller, so the restore port proves the stronger invariant: a
// queued command cannot reduce or publish before its restore commits.
@MainActor
extension WorkspaceStoreTests {
    @Test func legacyV1PrimaryProjectionAndUndoRoundTripKeepsCrossDayIdentity() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("calendar-v1.json")
        try legacyStoreV1CompleteGraphData.write(to: primary)
        let seed = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { seed })
        let store = WorkspaceStore(initialState: seed, repository: repository, clock: { .distantPast })

        await store.load()
        #expect(store.phase == .ready)
        let migrated = store.state
        try legacyAssertCompleteV1Graph(migrated.calendar)
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001201")!, kind: .task,
            title: "跨层跨日事项", categoryID: legacyStoreCategoryID,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 30)!, endDate: .init(year: 2026, month: 9, day: 2)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )

        guard case .committed = try await store.sendCalendar(.createItem(item), undoLabel: "添加跨日事项") else {
            Issue.record("跨日事项必须先持久化后才发布")
            return
        }
        let projection = TimelineProjection.make(
            in: .init(start: .init(year: 2026, month: 8, day: 3)!, end: .init(year: 2026, month: 9, day: 6)!),
            state: store.calendarState, hiddenCategoryIDs: []
        )
        #expect(projection.entries.filter { $0.id == .item(item.id) }.count == 1)
        #expect(projection.entries.contains { $0.id == .item(legacyStoreItemID) })
        #expect(projection.entries.first { $0.id == .occurrence(legacyStoreMovedKey) }?.title == "已移动")
        #expect(projection.entries.first { $0.id == .occurrence(legacyStoreMovedKey) }?.schedule == legacyStoreMovedSchedule)
        #expect(projection.entries.first { $0.id == .occurrence(legacyStoreCompletionKey) }?.completedAt == legacyStoreOccurrenceCompletionDate)
        #expect(projection.entries.contains { $0.id == .occurrence(legacyStoreSkippedKey) } == false)
        #expect(try await repository.load().state == store.state)
        let primaryAfterMutation = try Data(contentsOf: primary)
        #expect(try legacyStoreSchemaVersion(in: primaryAfterMutation) == WorkspaceDocument.currentSchemaVersion)

        _ = try await store.undo()
        // Workspace revisions are monotonic across undo; the restored content
        // itself must still be the complete migrated snapshot.
        #expect(store.state.calendar == migrated.calendar)
        #expect(store.state.notes == migrated.notes)
        #expect(store.state.calendar.items[item.id] == nil)
        try legacyAssertCompleteV1Graph(store.calendarState)
        #expect(try await repository.load().state == store.state)
        let primaryAfterUndo = try Data(contentsOf: primary)
        #expect(try legacyStoreSchemaVersion(in: primaryAfterUndo) == WorkspaceDocument.currentSchemaVersion)
    }

    @Test func legacyV1BackupRestoreMigratesAndCorruptBackupCannotOverwriteIt() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("main.json")
        let initial = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        try WorkspaceDocumentCodec.encode(initial).write(to: primary)
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initial })
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        let beforePrimary = try Data(contentsOf: primary)
        let source = directory.appendingPathComponent("schema-one-backup.json")
        try legacyStoreV1CompleteGraphData.write(to: source)

        let restored = try await store.restore(
            try await store.inspectRestoreSource(at: source),
            rollbackDirectoryURL: directory.appendingPathComponent("Rollbacks", isDirectory: true)
        )
        guard case let .restored(outcome) = restored, case let .file(rollbackURL, _) = outcome.rollback else {
            Issue.record("有主数据的恢复必须返回原始 rollback")
            return
        }
        try legacyAssertCompleteV1Graph(store.calendarState)
        #expect(try Data(contentsOf: rollbackURL) == beforePrimary)
        let persisted = try Data(contentsOf: primary)

        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("{not-valid-json".utf8).write(to: corrupt)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await store.inspectRestoreSource(at: corrupt) }
        #expect(try Data(contentsOf: primary) == persisted)
        #expect(try Data(contentsOf: rollbackURL) == beforePrimary)
    }

    @Test func legacyFailedReductionReturnsReadyWithoutSaveOrUndo() async throws {
        let initial = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: UUID(), now: .distantPast))
        let repository = WorkspaceStoreTestRepository(initial: initial)
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        await #expect(throws: WorkspaceReducerError.calendarFailure(.missingItem)) {
            _ = try await store.sendCalendar(.deleteItem(UUID()), undoLabel: "删除")
        }
        #expect(store.phase == .ready)
        #expect(store.state == initial)
        #expect(store.canUndo == false)
        #expect(await repository.saveCount == 0)
    }

    @Test func legacySuccessfulSendPersistsBeforePublishing() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let initial = WorkspaceState.empty(calendar: calendar)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "持久化优先")
        let repository = WorkspaceStoreTestRepository(initial: initial)
        await repository.suspendNextSave()
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        let operation = Task { @MainActor in try await store.sendCalendar(.createItem(item), undoLabel: "添加事项") }
        await repository.waitForSaveStart()

        #expect(store.state == initial)
        #expect(store.canUndo == false)
        await repository.resumeSave()
        guard case .committed = try await operation.value else { Issue.record("保存成功必须提交"); return }
        #expect(store.state.calendar.items[item.id] == item)
        #expect(await repository.persistedState == store.state)
        #expect(store.canUndo)
    }

    @Test func legacyUndoRestoresWholeSnapshotAfterSuccessfulSave() async throws {
        let uncategorized = UUID()
        let deleted = UUID()
        let target = UUID()
        var calendar = CalendarState.empty(uncategorizedID: uncategorized, now: .distantPast)
        calendar.categories[deleted] = .init(id: deleted, name: "删除", colorHex: "#4F7FFF", sortIndex: 1, createdAt: .distantPast, updatedAt: .distantPast)
        calendar.categories[target] = .init(id: target, name: "迁移", colorHex: "#D65772", sortIndex: 2, createdAt: .distantPast, updatedAt: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: deleted, title: "应跟随分类迁移")
        calendar.items[item.id] = item
        let initial = WorkspaceState.empty(calendar: calendar)
        let repository = WorkspaceStoreTestRepository(initial: initial)
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()

        _ = try await store.sendWorkspace(.deleteCategory(deleted), undoLabel: "删除分类")
        #expect(store.state != initial)
        _ = try await store.undo()

        #expect(store.state.calendar == initial.calendar)
        #expect(store.state.notes == initial.notes)
        #expect(await repository.persistedState == store.state)
        #expect(store.canUndo == false)
    }

    @Test func legacySendDuringLoadIsRejectedBeforeSeedCanReduce() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let disk = WorkspaceState.empty(calendar: calendar)
        let repository = WorkspaceStoreTestRepository(initial: disk)
        await repository.suspendNextLoad()
        let store = WorkspaceStore(initialState: .empty(calendar: CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)), repository: repository)
        let loading = Task { @MainActor in await store.load() }
        await repository.waitForLoadStart()

        await #expect(throws: WorkspaceStoreError.frozen) {
            _ = try await store.sendCalendar(.deleteItem(UUID()), undoLabel: "删除")
        }
        #expect(await repository.saveCount == 0)
        await repository.resumeLoad()
        await loading.value
        #expect(store.phase == .ready)
        #expect(store.state == disk)
    }

    @Test func legacyRestorePreventsQueuedMutationAndUndoFromPublishingEarly() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        let source = directory.appendingPathComponent("restore.json")
        try legacyStoreV1CompleteGraphData.write(to: source)
        let backing = JSONWorkspaceRepository(documentURL: directory.appendingPathComponent("main.json"), seed: { initial })
        let repository = RestoreCountingRepository(backing: backing)
        let store = WorkspaceStore(initialState: initial, repository: repository, clock: { .distantPast })
        await store.load()
        let preRestoreItem = try makeItem(
            id: UUID(),
            categoryID: legacyStoreCategoryID,
            title: "恢复前用于建立撤销记录"
        )
        guard case .committed = try await store.sendCalendar(
            .createItem(preRestoreItem),
            undoLabel: "恢复前撤销记录"
        ) else {
            Issue.record("恢复前必须真实建立 undo record")
            return
        }
        #expect(store.canUndo)
        #expect(await repository.saveCount == 1)
        let stateBeforeRestore = store.state
        let generationBeforeRestore = store.statePublicationGeneration
        let primaryBeforeRestore = try Data(contentsOf: directory.appendingPathComponent("main.json"))

        let preview = try await store.inspectRestoreSource(at: source)
        await repository.suspendNextCommit()
        let restoring = Task { @MainActor in try await store.restore(preview, rollbackDirectoryURL: directory.appendingPathComponent("Rollbacks", isDirectory: true)) }
        await repository.waitForCommitStart()
        let queuedItem = try makeItem(id: UUID(), categoryID: legacyStoreCategoryID, title: "不得抢跑")
        let queued = Task { @MainActor in try await store.sendCalendar(.createItem(queuedItem), undoLabel: "队列事项") }
        await Task.yield()
        let queuedUndo = Task { @MainActor in try await store.undo() }
        await Task.yield()

        #expect(store.phase == .mutating)
        #expect(store.state == stateBeforeRestore)
        #expect(store.statePublicationGeneration == generationBeforeRestore)
        #expect(store.state.calendar.items[queuedItem.id] == nil)
        #expect(store.state.calendar.items[preRestoreItem.id] == preRestoreItem)
        #expect(await repository.saveCount == 1)
        #expect(try Data(contentsOf: directory.appendingPathComponent("main.json")) == primaryBeforeRestore)

        await repository.resumeCommit()
        guard case .restored = try await restoring.value else { Issue.record("恢复必须完成"); return }
        guard case .committed = try await queued.value else { Issue.record("恢复后的队列事务必须再独立提交"); return }
        await #expect(throws: WorkspaceUndoReducerError.conflict) {
            _ = try await queuedUndo.value
        }

        #expect(store.statePublicationGeneration == generationBeforeRestore + 2)
        #expect(await repository.saveCount == 2)
        #expect(store.state.calendar.items[preRestoreItem.id] == nil)
        #expect(store.state.calendar.items[queuedItem.id] != nil)
        var restoredCalendar = store.calendarState
        #expect(restoredCalendar.items.removeValue(forKey: queuedItem.id) == queuedItem)
        try legacyAssertCompleteV1Graph(restoredCalendar)
        let persisted = try WorkspaceDocumentCodec.decode(
            Data(contentsOf: directory.appendingPathComponent("main.json"))
        ).state
        #expect(persisted == store.state)
    }

    @Test func legacyCorruptPrimaryCanRestoreValidBackupAndPreserveRawRollback() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("main.json")
        let opaque = Data("corrupt primary bytes".utf8)
        try opaque.write(to: primary)
        let seed = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        let store = WorkspaceStore(initialState: seed, repository: JSONWorkspaceRepository(documentURL: primary, seed: { seed }))
        await store.load()
        #expect(store.phase == .opaquePrimaryLoadFailed)
        let source = directory.appendingPathComponent("valid-v1.json")
        try legacyStoreV1CompleteGraphData.write(to: source)

        let outcome = try await store.restore(try await store.inspectRestoreSource(at: source), rollbackDirectoryURL: directory.appendingPathComponent("Rollbacks", isDirectory: true))
        guard case let .restored(restoration) = outcome, case let .file(rollbackURL, _) = restoration.rollback else { Issue.record("opaque 主文件也必须有原始 rollback"); return }
        #expect(try Data(contentsOf: rollbackURL) == opaque)
        #expect(store.phase == .ready)
        try legacyAssertCompleteV1Graph(store.calendarState)
    }

    @Test func legacyInvalidSemanticV1RestoreKeepsMemoryDiskAndUndoUntouched() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        let primary = directory.appendingPathComponent("main.json")
        try WorkspaceDocumentCodec.encode(initial).write(to: primary)
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initial })
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        let category = CalendarCategory(id: UUID(), name: "保留撤销", colorHex: "#4F7FFF", sortIndex: 1, createdAt: .distantPast, updatedAt: .distantPast)
        _ = try await store.sendWorkspace(.createCategory(category), undoLabel: "添加分类")
        let before = store.state
        let beforeBytes = try Data(contentsOf: primary)
        let beforeGeneration = store.statePublicationGeneration
        let invalid = Data(String(decoding: legacyStoreV1CompleteGraphData, as: UTF8.self)
            .replacingOccurrences(of: "\"categoryID\":\"00000000-0000-0000-0000-000000000100\"", with: "\"categoryID\":\"00000000-0000-0000-0000-000000000199\"").utf8)
        let source = directory.appendingPathComponent("invalid-v1.json")
        try invalid.write(to: source)

        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await store.inspectRestoreSource(at: source) }
        #expect(store.state == before)
        #expect(store.statePublicationGeneration == beforeGeneration)
        #expect(try Data(contentsOf: primary) == beforeBytes)
        #expect(store.canUndo)
    }

    @Test func legacyFailedV1RestoreRollbackWriteDoesNotPublishMigratedState() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        let primary = directory.appendingPathComponent("main.json")
        try WorkspaceDocumentCodec.encode(initial).write(to: primary)
        let writer = LegacyStoreFailingRollbackWriter()
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initial }, rollbackWriter: writer)
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        let before = store.state
        let beforeGeneration = store.statePublicationGeneration
        let beforeBytes = try Data(contentsOf: primary)
        let source = directory.appendingPathComponent("v1.json")
        try legacyStoreV1CompleteGraphData.write(to: source)
        writer.failNextWrite = true

        await #expect(throws: WorkspacePersistenceError.rollbackWriteFailed) {
            _ = try await store.restore(try await store.inspectRestoreSource(at: source), rollbackDirectoryURL: directory.appendingPathComponent("Rollbacks", isDirectory: true))
        }
        #expect(store.state == before)
        #expect(store.statePublicationGeneration == beforeGeneration)
        #expect(try Data(contentsOf: primary) == beforeBytes)
    }

    @Test func legacyFailedV1RestorePrimarySaveDoesNotPublishState() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        let primary = directory.appendingPathComponent("main.json")
        try WorkspaceDocumentCodec.encode(initial).write(to: primary)
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initial }, mainFileWriter: LegacyStoreAlwaysFailingMainWriter())
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        let before = store.state
        let beforeGeneration = store.statePublicationGeneration
        let beforeBytes = try Data(contentsOf: primary)
        let source = directory.appendingPathComponent("v1.json")
        try legacyStoreV1CompleteGraphData.write(to: source)

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.restore(try await store.inspectRestoreSource(at: source), rollbackDirectoryURL: directory.appendingPathComponent("Rollbacks", isDirectory: true))
        }
        #expect(store.state == before)
        #expect(store.statePublicationGeneration == beforeGeneration)
        #expect(try Data(contentsOf: primary) == beforeBytes)
        let rollbackDirectory = directory.appendingPathComponent("Rollbacks", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: rollbackDirectory.path))
        let rollbackFiles = try FileManager.default.contentsOfDirectory(
            at: rollbackDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(rollbackFiles.count == 1)
        let rollbackFile = try #require(rollbackFiles.first)
        #expect(try Data(contentsOf: rollbackFile) == beforeBytes)
    }

    @Test func legacySuccessfulRestorePublishesOnceAndClearsUndo() async throws {
        let directory = try legacyStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = WorkspaceState.empty(calendar: CalendarState.empty(uncategorizedID: legacyStoreCategoryID, now: .distantPast))
        let primary = directory.appendingPathComponent("main.json")
        try WorkspaceDocumentCodec.encode(initial).write(to: primary)
        let repository = JSONWorkspaceRepository(documentURL: primary, seed: { initial })
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createCategory(.init(id: UUID(), name: "待撤销", colorHex: "#4F7FFF", sortIndex: 1, createdAt: .distantPast, updatedAt: .distantPast)), undoLabel: "添加分类")
        let beforeRestore = store.state
        let beforeBytes = try Data(contentsOf: primary)
        let beforeGeneration = store.statePublicationGeneration
        let source = directory.appendingPathComponent("v1.json")
        try legacyStoreV1CompleteGraphData.write(to: source)

        let outcome = try await store.restore(try await store.inspectRestoreSource(at: source), rollbackDirectoryURL: directory.appendingPathComponent("Rollbacks", isDirectory: true))
        guard case let .restored(restoration) = outcome, case let .file(rollbackURL, _) = restoration.rollback else { Issue.record("恢复必须携带 rollback"); return }
        try legacyAssertCompleteV1Graph(store.calendarState)
        #expect(store.statePublicationGeneration == beforeGeneration + 1)
        #expect(try Data(contentsOf: rollbackURL) == beforeBytes)
        #expect(store.canUndo == false)
        #expect(store.canRedo == false)
        #expect(store.state != beforeRestore)
        #expect(store.state.revision > beforeRestore.revision)
        await #expect(throws: WorkspaceStoreError.nothingToUndo) {
            _ = try await store.undo()
        }
        let reopened = JSONWorkspaceRepository(documentURL: primary, seed: { initial })
        #expect(try await reopened.load().state == store.state)
    }
}

private let legacyStoreCategoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
private let legacyStoreItemID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
private let legacyStoreSeriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
private let legacyStoreMovedKey = OccurrenceKey(seriesID: legacyStoreSeriesID, originalDate: .init(year: 2026, month: 8, day: 10)!)
private let legacyStoreSkippedKey = OccurrenceKey(seriesID: legacyStoreSeriesID, originalDate: .init(year: 2026, month: 8, day: 12)!)
private let legacyStoreCompletionKey = OccurrenceKey(seriesID: legacyStoreSeriesID, originalDate: .init(year: 2026, month: 8, day: 17)!)
private let legacyStoreOccurrenceCompletionDate = Date(timeIntervalSince1970: 1_700_000_300.5)
private let legacyStoreMovedSchedule = try! CalendarSchedule(
    startDate: .init(year: 2026, month: 8, day: 13)!,
    endDate: .init(year: 2026, month: 8, day: 13)!,
    startTime: MinuteOfDay(hour: 11, minute: 0),
    endTime: MinuteOfDay(hour: 12, minute: 0)
)

private func legacyStoreDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("JellyLegacyStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func legacyStoreSchemaVersion(in data: Data) throws -> Int {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(object?["schemaVersion"] as? Int)
}

private func legacyAssertCompleteV1Graph(_ state: CalendarState) throws {
    #expect(state.uncategorizedID == legacyStoreCategoryID)
    #expect(state.categories.count == 1)
    #expect(state.items.count == 1)
    #expect(state.recurrence.series.count == 1)
    #expect(state.recurrence.exceptions.count == 2)
    #expect(state.recurrence.completions.count == 1)

    let category = try #require(state.categories[legacyStoreCategoryID])
    #expect(category.id == legacyStoreCategoryID)
    #expect(category.name == "未分类")
    #expect(category.colorHex == "#8E8E93")
    #expect(category.sortIndex == 0)
    #expect(category.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(category.updatedAt == Date(timeIntervalSince1970: 1_700_000_000.1))

    let item = try #require(state.items[legacyStoreItemID])
    let expectedItemSchedule = try CalendarSchedule(
        startDate: .init(year: 2026, month: 8, day: 6)!,
        endDate: .init(year: 2026, month: 8, day: 6)!,
        startTime: MinuteOfDay(hour: 9, minute: 0),
        endTime: MinuteOfDay(hour: 10, minute: 0)
    )
    #expect(item.id == legacyStoreItemID)
    #expect(item.kind == .task)
    #expect(item.title == "单日事项")
    #expect(item.categoryID == legacyStoreCategoryID)
    #expect(item.schedule == expectedItemSchedule)
    #expect(item.creationTimeZoneIdentifier == "Asia/Shanghai")
    #expect(item.completedAt == Date(timeIntervalSince1970: 1_700_000_100.25))
    #expect(item.createdAt == Date(timeIntervalSince1970: 1_700_000_000.2))
    #expect(item.updatedAt == Date(timeIntervalSince1970: 1_700_000_000.3))

    let series = try #require(state.recurrence.series[legacyStoreSeriesID])
    #expect(series.id == legacyStoreSeriesID)
    #expect(series.kind == .task)
    #expect(series.title == "每周回顾")
    #expect(series.categoryID == legacyStoreCategoryID)
    #expect(series.ruleStartDate == .init(year: 2026, month: 8, day: 3)!)
    #expect(series.recurrenceEndDate == .init(year: 2026, month: 8, day: 31)!)
    #expect(series.weekdays == [.monday, .thursday])
    #expect(series.durationDays == 1)
    #expect(series.startTime == MinuteOfDay(hour: 9, minute: 30))
    #expect(series.endTime == MinuteOfDay(hour: 10, minute: 15))
    #expect(series.creationTimeZoneIdentifier == "Asia/Shanghai")
    #expect(series.createdAt == Date(timeIntervalSince1970: 1_700_000_000.4))
    #expect(series.updatedAt == Date(timeIntervalSince1970: 1_700_000_000.5))

    let moved = try #require(state.recurrence.exceptions[legacyStoreMovedKey])
    guard case let .modified(override) = moved else {
        Issue.record("完整 V1 图中的移动例外必须保持移动例外")
        return
    }
    #expect(override.displayedSchedule == legacyStoreMovedSchedule)
    #expect(override.title == "已移动")
    #expect(override.kind == .task)
    #expect(override.categoryID == legacyStoreCategoryID)
    #expect(state.recurrence.exceptions[legacyStoreSkippedKey] == .skipped)
    let completion = try #require(state.recurrence.completions[legacyStoreCompletionKey])
    #expect(completion.key == legacyStoreCompletionKey)
    #expect(completion.completedAt == legacyStoreOccurrenceCompletionDate)
}

private final class LegacyStoreFailingRollbackWriter: ExclusiveFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    var failNextWrite: Bool { get { lock.withLock { shouldFail } } set { lock.withLock { shouldFail = newValue } } }
    func createExclusively(data: Data, at destination: URL) throws {
        if lock.withLock({ defer { shouldFail = false }; return shouldFail }) { throw LegacyStoreInjectedFailure.requested }
        try FoundationExclusiveFileWriter().createExclusively(data: data, at: destination)
    }
}

private enum LegacyStoreInjectedFailure: Error { case requested }

private struct LegacyStoreAlwaysFailingMainWriter: MainFileCompareAndReplaceWriting {
    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult { throw WorkspacePersistenceError.atomicWriteFailed }
    func replaceIfSHA256Matches(expectedSHA256: String, candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult { throw WorkspacePersistenceError.atomicWriteFailed }
    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult { throw WorkspacePersistenceError.atomicWriteFailed }
    func replaceIfSHA256MatchesUnlocked(expectedSHA256: String, candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult { throw WorkspacePersistenceError.atomicWriteFailed }
}

private let legacyStoreV1CompleteGraphData = Data(#"""
{"schemaVersion":1,"state":{"categories":["00000000-0000-0000-0000-000000000100",{"id":"00000000-0000-0000-0000-000000000100","name":"未分类","colorHex":"#8E8E93","sortIndex":0,"createdAt":1700000000000,"updatedAt":1700000000100}],"items":["00000000-0000-0000-0000-000000000101",{"id":"00000000-0000-0000-0000-000000000101","kind":"task","title":"单日事项","categoryID":"00000000-0000-0000-0000-000000000100","date":{"year":2026,"month":8,"day":6},"timeRange":{"start":{"value":540},"end":{"value":600}},"creationTimeZoneIdentifier":"Asia/Shanghai","completedAt":1700000100250,"createdAt":1700000000200,"updatedAt":1700000000300}],"recurrence":{"series":["00000000-0000-0000-0000-000000000102",{"id":"00000000-0000-0000-0000-000000000102","kind":"task","title":"每周回顾","categoryID":"00000000-0000-0000-0000-000000000100","startDate":{"year":2026,"month":8,"day":3},"endDate":{"year":2026,"month":8,"day":31},"weekdays":[1,4],"timeRange":{"start":{"value":570},"end":{"value":615}},"creationTimeZoneIdentifier":"Asia/Shanghai","createdAt":1700000000400,"updatedAt":1700000000500}],"exceptions":[{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":10}},{"modified":{"_0":{"displayedDate":{"year":2026,"month":8,"day":13},"title":"已移动","kind":"task","categoryID":"00000000-0000-0000-0000-000000000100","timeRange":{"start":{"value":660},"end":{"value":720}}}}},{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":12}},{"skipped":{}}],"completions":[{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":17}},{"key":{"seriesID":"00000000-0000-0000-0000-000000000102","originalDate":{"year":2026,"month":8,"day":17}},"completedAt":1700000300500}]},"uncategorizedID":"00000000-0000-0000-0000-000000000100"}}
"""#.utf8)

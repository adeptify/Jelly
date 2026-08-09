import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceStoreTests")
@MainActor
struct WorkspaceStoreTests {
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

    @Test func sourceChangedRetryNeverPublishesTheParkedCandidate() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "lost")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.makeNextSaveUncertain()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
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

    @Test func failedSaveDoesNotPublishRevisionOrUndo() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "unsaved")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        await repository.failNextSave()
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        }
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

        _ = try await store.sendCalendar(.updateItem(staleEditorPayload), undoLabel: "rename")

        #expect(store.calendarState.items[item.id]?.title == "renamed")
        #expect(store.calendarState.items[item.id]?.completedAt == completion)
    }

    @Test func undoRedoAndUndoRemainPersistedTransactions() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "roundtrip")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
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

    @Test func failedNewTransactionLeavesRedoStackAndPublishedStateUntouched() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let original = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "original")
        let replacement = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "replacement")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        _ = try await store.sendCalendar(.createItem(original), undoLabel: "create")
        _ = try await store.undo()
        #expect(store.canRedo)
        await repository.failNextSave()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.sendCalendar(.createItem(replacement), undoLabel: "failed replacement")
        }

        #expect(store.calendarState.items[replacement.id] == nil)
        #expect(store.canRedo)
        _ = try await store.redo()
        #expect(store.calendarState.items[original.id] != nil)
        #expect(store.calendarState.items[replacement.id] == nil)
    }

    @Test func failedUndoPersistenceLeavesPublishedStateAndBothStacksUsable() async throws {
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        let item = try makeItem(id: UUID(), categoryID: calendar.uncategorizedID, title: "undo must stay")
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "create")
        let published = store.state
        await repository.failNextSave()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.undo()
        }

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

        _ = try await store.reloadExternalSource()

        #expect(store.state.calendar.items[item.id] != nil)
        #expect(await repository.saveCount == 1)
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

        _ = try await absentStore.reloadExternalSource()

        #expect(absentStore.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(absentStore.state == initial)
        let unreadableRepository = WorkspaceStoreTestRepository(initial: initial)
        await unreadableRepository.setReloaded(.unreadableUnknown)
        let unreadableStore = WorkspaceStore(initialState: initial, repository: unreadableRepository)

        _ = try await unreadableStore.reloadExternalSource()

        #expect(unreadableStore.phase == .unreadablePrimaryLoadFailed)
        #expect(unreadableStore.state == initial)
    }

    @Test func externalNormalizationSaveFailureLeavesPublishedStateAndLedgerUnadvanced() async throws {
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

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.reloadExternalSource()
        }

        #expect(store.state == initial)
        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 0)
    }

    @Test func externalNormalizationFailureDoesNotRaiseTheDeletedNoteLedgerBeforeALaterSameIDCreate() async throws {
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

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.reloadExternalSource()
        }
        let recreated = Note.empty(id: noteID, categoryID: calendar.uncategorizedID, now: .distantPast)
        _ = try await store.sendWorkspace(.createNote(.init(note: recreated)), undoLabel: "recreate")

        #expect(store.state.notes[noteID]?.revision == 1)
        #expect(store.state.notes[noteID]?.revision != 9)
        #expect(await repository.saveCount == 1)
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

    @Test func failedExternalRepairKeepsTheRepairableCandidateFrozenWithoutPublishingIt() async throws {
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
        _ = try await store.reloadExternalSource()
        await repository.failNextSave()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await store.sendWorkspace(.repairConsistency(repair))
        }

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
        let destination = directory.appendingPathComponent("opaque-copy.json")

        try await store.exportRawRecoveryCopy(to: destination)

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
    private var commitStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitResumeWaiters: [CheckedContinuation<Void, Never>] = []

    init(backing: JSONWorkspaceRepository) { self.backing = backing }

    func load() async throws -> WorkspaceLoadResult { try await backing.load() }
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt { try await backing.save(state, draft: draft) }
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
}

actor WorkspaceStoreTestRepository: WorkspaceRepository {
    private var state: WorkspaceState
    private var saveCountStorage = 0
    private var failSave = false
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
    func load() throws -> WorkspaceLoadResult { .init(state: state, provenance: .init(sourceSchema: 3, sourceBytesSHA256: "test", sourceByteCount: 0), consistencyIssues: []) }
    func save(_ next: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt {
        if saveSuspended {
            saveStarted = true
            let waiters = saveWaiters; saveWaiters.removeAll(); waiters.forEach { $0.resume() }
            await withCheckedContinuation { saveResumeWaiters.append($0) }
        }
        if saveUncertain { saveUncertain = false; throw WorkspacePersistenceError.commitUncertain }
        if sourceChangedSave { sourceChangedSave = false; throw WorkspaceDirectCommitFailure.sourceChanged(.init()) }
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
    func reloadCurrentSourceAfterExternalChange() throws -> WorkspaceReloadedSource {
        if let reloaded { return reloaded }
        return .valid(try load())
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
    var reconciliationCount: Int { reconciliationCountStorage }
    func failNextSave() { failSave = true }
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

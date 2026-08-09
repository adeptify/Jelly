import CalendarDomain
import Foundation

extension WorkspaceReducer {
    static func scheduleNote(
        _ payload: ScheduleNoteOnCalendarPayload,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws {
        guard candidate.notes[payload.noteID] != nil else {
            throw WorkspaceReducerError.missingNote(payload.noteID)
        }
        guard payload.item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceReducerError.invalidLegacyAuthorization
        }
        try applyCalendar(.createItem(payload.item), to: &candidate, now: now, metadata: &metadata)
        candidate.calendarNoteRelations.baselines[.item(payload.item.id)] = .init(
            primaryNoteID: payload.noteID,
            referenceNoteIDs: []
        )
    }

    static func attachReferenceNote(
        _ scope: CalendarRelationScope,
        noteID: NoteID,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws {
        guard candidate.notes[noteID] != nil else { throw WorkspaceReducerError.missingNote(noteID) }
        let effective = try prepare(scope, in: &candidate, now: now, metadata: &metadata)
        var set = try resolvedSet(for: effective, in: candidate)
        guard set.primaryNoteID != noteID else { return }
        set.referenceNoteIDs.insert(noteID)
        try write(set, for: effective, in: &candidate)
    }

    static func detachNote(
        _ scope: CalendarRelationScope,
        noteID: NoteID,
        linkedTaskDisposition: TaskBlockPrimaryChangeDisposition?,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws {
        guard candidate.notes[noteID] != nil else { throw WorkspaceReducerError.missingNote(noteID) }
        let effective = try prepare(scope, in: &candidate, now: now, metadata: &metadata)
        var set = try resolvedSet(for: effective, in: candidate)
        let removesPrimary = set.primaryNoteID == noteID
        try handleLinkedPrimaryChange(
            scope: effective,
            oldPrimary: removesPrimary ? noteID : nil,
            disposition: linkedTaskDisposition,
            candidate: &candidate
        )
        if removesPrimary { set.primaryNoteID = nil }
        set.referenceNoteIDs.remove(noteID)
        try write(set, for: effective, in: &candidate)
    }

    static func attachPrimaryNote(
        _ payload: AttachPrimaryNotePayload,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws -> WorkspaceCommandControl {
        guard candidate.notes[payload.noteID] != nil else {
            throw WorkspaceReducerError.missingNote(payload.noteID)
        }

        var legacyPreview: LegacyMarkdownMigrationPreview?
        switch payload.legacyResolution {
        case .cancel:
            return .result(.noChange(.cancelled))
        case let .previewAndMerge(expectedRevision, authorization):
            guard candidate.notes[payload.noteID]?.revision == expectedRevision else {
                return .result(.noChange(.staleLegacyPreview))
            }
            let validation = try validateLegacyAuthorization(
                authorization,
                scope: payload.scope,
                in: candidate
            )
            if let result = validation.result { return .result(result) }
            legacyPreview = validation.preview
        case nil:
            if try hasLegacyMarkdown(payload.scope, in: candidate) {
                throw WorkspaceReducerError.invalidLegacyAuthorization
            }
        }

        if let preview = legacyPreview {
            try requireCollisionFree(preview.document.blocks.map(\.id), in: candidate)
        }
        let effective = try prepare(payload.scope, in: &candidate, now: now, metadata: &metadata)
        var set = try resolvedSet(for: effective, in: candidate)
        let oldPrimary = set.primaryNoteID
        if oldPrimary != nil, oldPrimary != payload.noteID {
            guard let replacing = payload.replacing else {
                throw WorkspaceReducerError.primaryReplacementDispositionRequired
            }
            try handleLinkedPrimaryChange(
                scope: effective,
                oldPrimary: oldPrimary,
                disposition: payload.linkedTaskDisposition,
                candidate: &candidate
            )
            if replacing == .demoteOldPrimaryToReference, let oldPrimary {
                set.referenceNoteIDs.insert(oldPrimary)
            }
        } else {
            guard payload.replacing == nil else {
                throw WorkspaceReducerError.unexpectedPrimaryReplacementDisposition
            }
            try handleLinkedPrimaryChange(
                scope: effective,
                oldPrimary: nil,
                disposition: payload.linkedTaskDisposition,
                candidate: &candidate
            )
        }
        set.primaryNoteID = payload.noteID
        set.referenceNoteIDs.remove(payload.noteID)
        try write(set, for: effective, in: &candidate)

        if let preview = legacyPreview {
            guard var note = candidate.notes[payload.noteID] else {
                throw WorkspaceReducerError.missingNote(payload.noteID)
            }
            if isCanonicalEmpty(note.document) {
                note.document = preview.document
            } else {
                note.document.blocks.append(contentsOf: preview.document.blocks)
            }
            note.updatedAt = now
            try validateProposedNote(note, in: candidate)
            candidate.notes[note.id] = note
            try clearLegacyMarkdown(for: effective, originalScope: payload.scope, in: &candidate, now: now)
        }
        return .proceed
    }

    static func createPrimaryNote(
        _ payload: CreatePrimaryNoteForCalendarPayload,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws -> WorkspaceCommandControl {
        guard candidate.notes[payload.note.id] == nil else {
            throw WorkspaceReducerError.duplicateNote(payload.note.id)
        }
        try validateProposedNote(payload.note, in: candidate)
        var preview: LegacyMarkdownMigrationPreview?
        if let authorization = payload.legacyImportAuthorization {
            let validation = try validateLegacyAuthorization(
                authorization,
                scope: payload.scope,
                in: candidate
            )
            if let result = validation.result { return .result(result) }
            preview = validation.preview
            guard payload.note.document == preview?.document else {
                throw WorkspaceReducerError.invalidLegacyAuthorization
            }
            try requireCollisionFree(payload.note.document.blocks.map(\.id), in: candidate)
        } else if try hasLegacyMarkdown(payload.scope, in: candidate) {
            throw WorkspaceReducerError.invalidLegacyAuthorization
        }
        let effective = try prepare(payload.scope, in: &candidate, now: now, metadata: &metadata)
        var set = try resolvedSet(for: effective, in: candidate)
        guard set.primaryNoteID == nil else {
            throw WorkspaceReducerError.primaryReplacementDispositionRequired
        }
        try createNote(payload.note, in: &candidate)
        set.primaryNoteID = payload.note.id
        set.referenceNoteIDs.remove(payload.note.id)
        try write(set, for: effective, in: &candidate)
        if preview != nil {
            try clearLegacyMarkdown(for: effective, originalScope: payload.scope, in: &candidate, now: now)
        }
        return .proceed
    }

    private struct LegacyAuthorizationValidation {
        var preview: LegacyMarkdownMigrationPreview?
        var result: WorkspaceReductionResult?
    }

    private static func validateLegacyAuthorization(
        _ authorization: LegacyMarkdownImportAuthorization,
        scope: CalendarRelationScope,
        in state: WorkspaceState
    ) throws -> LegacyAuthorizationValidation {
        let currentMarkdown = try LegacyMarkdownMigrationPlanner.markdown(for: scope, in: state)
        guard LegacyMarkdownMigrationPlanner.sourceChecksum(
            scope: scope,
            markdown: currentMarkdown
        ) == authorization.expectedSourceChecksum else {
            return .init(preview: nil, result: .noChange(.staleLegacyPreview))
        }
        let preview: LegacyMarkdownMigrationPreview
        do {
            preview = try LegacyMarkdownMigrationPlanner.preview(
                scope: scope,
                in: state,
                injectedBlockIDs: authorization.injectedBlockIDs,
                checkedTaskCompletedAt: authorization.checkedTaskCompletedAt
            )
        } catch is BlockMarkdownCodecError {
            throw WorkspaceReducerError.invalidLegacyAuthorization
        }
        guard preview.sourceChecksum == authorization.expectedSourceChecksum else {
            return .init(preview: nil, result: .noChange(.staleLegacyPreview))
        }
        switch authorization.diagnostics {
        case .rejectIfPresent:
            guard preview.diagnostics.isEmpty else {
                throw WorkspaceReducerError.legacyDiagnosticsRequireConfirmation
            }
        case let .accept(expected):
            guard expected == preview.diagnosticsChecksum else {
                return .init(preview: nil, result: .noChange(.staleLegacyPreview))
            }
        }
        return .init(preview: preview, result: nil)
    }

    private static func prepare(
        _ scope: CalendarRelationScope,
        in candidate: inout WorkspaceState,
        now: Date,
        metadata: inout WorkspaceMutationMetadata
    ) throws -> CalendarRelationScope {
        switch scope {
        case let .occurrenceThisAndFuture(key, newSeriesID):
            try applyCalendar(
                .mutateSeries(
                    key,
                    scope: .thisAndFuture,
                    edit: .patch(.init()),
                    newSeriesID: newSeriesID
                ),
                to: &candidate,
                now: now,
                metadata: &metadata
            )
            guard case let .split(_, outcomeNewID, _, _, _)? = metadata.seriesOutcome,
                  outcomeNewID == newSeriesID
            else {
                throw WorkspaceReducerError.finalValidationFailed
            }
            return .series(newSeriesID)
        case .item, .series, .occurrenceOnly:
            _ = try resolvedSet(for: scope, in: candidate)
            return scope
        }
    }

    private static func resolvedSet(
        for scope: CalendarRelationScope,
        in state: WorkspaceState
    ) throws -> CalendarNoteSet {
        let target: CalendarTargetID
        switch scope {
        case let .item(id): target = .item(id)
        case let .series(id): target = .series(id)
        case let .occurrenceOnly(key): target = .occurrence(key)
        case .occurrenceThisAndFuture:
            throw WorkspaceReducerError.missingCalendarTarget
        }
        do {
            return try CalendarNoteRelationResolver.resolve(
                target,
                calendar: state.calendar,
                relations: state.calendarNoteRelations
            ).noteSet
        } catch {
            throw WorkspaceReducerError.missingCalendarTarget
        }
    }

    private static func write(
        _ set: CalendarNoteSet,
        for scope: CalendarRelationScope,
        in candidate: inout WorkspaceState
    ) throws {
        switch scope {
        case let .item(id):
            writeBaseline(set, owner: .item(id), in: &candidate)
        case let .series(id):
            writeBaseline(set, owner: .series(id), in: &candidate)
        case let .occurrenceOnly(key):
            let baseline = candidate.calendarNoteRelations.baselines[.series(key.seriesID)]
                ?? .init(primaryNoteID: nil, referenceNoteIDs: [])
            let primary: OccurrencePrimaryOverride
            if set.primaryNoteID == baseline.primaryNoteID {
                primary = .inherit
            } else if let noteID = set.primaryNoteID {
                primary = .replace(noteID)
            } else {
                primary = .clear
            }
            var added = set.referenceNoteIDs.subtracting(baseline.referenceNoteIDs)
            let removed = baseline.referenceNoteIDs.subtracting(set.referenceNoteIDs)
            if let primaryID = set.primaryNoteID { added.remove(primaryID) }
            let override = OccurrenceNoteOverride(
                key: key,
                primary: primary,
                addedReferenceNoteIDs: added,
                removedReferenceNoteIDs: removed
            )
            if primary == .inherit, added.isEmpty, removed.isEmpty {
                candidate.calendarNoteRelations.occurrenceOverrides.removeValue(forKey: key)
            } else {
                candidate.calendarNoteRelations.occurrenceOverrides[key] = override
            }
        case .occurrenceThisAndFuture:
            throw WorkspaceReducerError.missingCalendarTarget
        }
    }

    private static func writeBaseline(
        _ set: CalendarNoteSet,
        owner: CalendarNoteOwnerID,
        in candidate: inout WorkspaceState
    ) {
        if set.primaryNoteID == nil && set.referenceNoteIDs.isEmpty {
            candidate.calendarNoteRelations.baselines.removeValue(forKey: owner)
        } else {
            candidate.calendarNoteRelations.baselines[owner] = set
        }
    }

    private static func handleLinkedPrimaryChange(
        scope: CalendarRelationScope,
        oldPrimary: NoteID?,
        disposition: TaskBlockPrimaryChangeDisposition?,
        candidate: inout WorkspaceState
    ) throws {
        let link: TaskBlockCalendarLink?
        if case let .item(itemID) = scope, let oldPrimary {
            link = candidate.taskBlockLinks.first {
                $0.calendarItemID == itemID && $0.noteID == oldPrimary
            }
        } else {
            link = nil
        }
        if let link {
            guard disposition == .unlinkPreservingCompletion else {
                throw WorkspaceReducerError.linkedTaskDispositionRequired
            }
            candidate.taskBlockLinks.remove(link)
        } else if disposition != nil {
            throw WorkspaceReducerError.unexpectedLinkedTaskDisposition
        }
    }

    private static func requireCollisionFree(
        _ ids: [BlockID],
        in state: WorkspaceState
    ) throws {
        guard Set(ids).count == ids.count else {
            throw WorkspaceReducerError.invalidLegacyAuthorization
        }
        let existing = Set(state.notes.values.flatMap { $0.document.blocks.map(\.id) })
        guard existing.isDisjoint(with: ids) else {
            throw WorkspaceReducerError.invalidLegacyAuthorization
        }
    }

    private static func hasLegacyMarkdown(
        _ scope: CalendarRelationScope,
        in state: WorkspaceState
    ) throws -> Bool {
        !(try LegacyMarkdownMigrationPlanner.markdown(for: scope, in: state))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func clearLegacyMarkdown(
        for effective: CalendarRelationScope,
        originalScope: CalendarRelationScope,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws {
        switch effective {
        case let .item(id):
            guard var item = candidate.calendar.items[id] else {
                throw WorkspaceReducerError.missingCalendarTarget
            }
            item.notes = ""
            do {
                candidate.calendar = try CalendarReducer.reduce(
                    candidate.calendar,
                    command: .updateItem(item),
                    now: now
                )
            } catch let error as ReducerError {
                throw WorkspaceReducerError.calendarFailure(error)
            }
        case let .series(id):
            guard candidate.calendar.recurrence.series[id] != nil else {
                throw WorkspaceReducerError.missingCalendarTarget
            }
            candidate.calendar.recurrence.series[id]?.notes = ""
            candidate.calendar.recurrence.series[id]?.updatedAt = now
        case let .occurrenceOnly(key):
            var localMetadata = WorkspaceMutationMetadata()
            try applyCalendar(
                .mutateSeries(
                    key,
                    scope: .onlyThis,
                    edit: .patch(.init(notes: "")),
                    newSeriesID: key.seriesID
                ),
                to: &candidate,
                now: now,
                metadata: &localMetadata
            )
        case .occurrenceThisAndFuture:
            throw WorkspaceReducerError.missingCalendarTarget
        }
        _ = originalScope
    }

    private static func isCanonicalEmpty(_ document: BlockDocument) -> Bool {
        guard document.blocks.count == 1, let block = document.blocks.first else { return false }
        return block.kind == .paragraph
            && block.inlineContent.spans.allSatisfy { $0.text.isEmpty && $0.linkURL == nil }
            && block.taskState == nil
            && block.indentLevel == 0
            && block.codeInfoString == nil
    }

    static func reduceConsistencyRepair(
        _ state: WorkspaceState,
        payload: WorkspaceConsistencyRepairPayload
    ) throws -> WorkspaceReductionResult {
        let report = WorkspaceConsistencyInspector.inspect(state)
        guard !report.hasFatalIssues else { throw WorkspaceReducerError.fatalConsistencyIssues }
        guard payload.expectedIssuesChecksum == report.issuesChecksum else {
            return .noChange(.staleConsistencyPreview)
        }
        guard Set(payload.resolutions.keys) == Set(report.issues.map(\.id)) else {
            throw WorkspaceReducerError.invalidConsistencyRepair
        }
        var candidate = state
        let grouped = Dictionary(grouping: report.issues, by: \.locator)
        let orderedLocators = grouped.keys.sorted { lhs, rhs in
            let leftPriority = consistencyRepairPriority(lhs)
            let rightPriority = consistencyRepairPriority(rhs)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return WorkspaceConsistencyInspector.canonical(lhs)
                < WorkspaceConsistencyInspector.canonical(rhs)
        }
        for locator in orderedLocators {
            guard let issues = grouped[locator] else { continue }
            let resolutions = issues.map { ($0, payload.resolutions[$0.id]!) }
            try applyConsistencyResolutions(
                locator: locator,
                resolutions: resolutions,
                to: &candidate
            )
        }
        guard WorkspaceContentSnapshot(state: candidate) != WorkspaceContentSnapshot(state: state) else {
            return .noChange(.identical)
        }
        let changed = try allocateRevisions(from: state, to: &candidate)
        do {
            try WorkspaceValidator.validate(candidate)
        } catch {
            throw WorkspaceReducerError.finalValidationFailed
        }
        return .changed(.init(
            state: candidate,
            changedNoteIDs: changed,
            draftContext: nil,
            seriesOutcome: nil
        ))
    }

    private static func consistencyRepairPriority(_ locator: WorkspaceRelationshipLocator) -> Int {
        switch locator {
        case .calendarNote, .inspirationNote: 0
        case .calendarBaseline, .occurrenceOverride: 1
        case .taskBlock: 2
        }
    }

    private static func applyConsistencyResolutions(
        locator: WorkspaceRelationshipLocator,
        resolutions: [(WorkspaceConsistencyIssue, WorkspaceConsistencyResolution)],
        to candidate: inout WorkspaceState
    ) throws {
        switch locator {
        case let .calendarBaseline(owner):
            guard resolutions.count == 1 else {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            switch resolutions[0].1 {
            case .unlink:
                candidate.calendarNoteRelations.baselines.removeValue(forKey: owner)
            case let .relink(.calendarOwner(newOwner)):
                guard let set = candidate.calendarNoteRelations.baselines.removeValue(forKey: owner)
                else { throw WorkspaceReducerError.invalidConsistencyRepair }
                guard candidate.calendarNoteRelations.baselines[newOwner] == nil,
                      contains(newOwner, in: candidate.calendar)
                else { throw WorkspaceReducerError.invalidConsistencyRepair }
                candidate.calendarNoteRelations.baselines[newOwner] = set
            default:
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
        case let .occurrenceOverride(key):
            guard var override = candidate.calendarNoteRelations.occurrenceOverrides.removeValue(forKey: key),
                  resolutions.count == 1
            else { throw WorkspaceReducerError.invalidConsistencyRepair }
            switch resolutions[0].1 {
            case .unlink:
                break
            case let .relink(.occurrence(newKey)):
                guard candidate.calendarNoteRelations.occurrenceOverrides[newKey] == nil,
                      CalendarNoteRelationResolver.isLogicalInstance(newKey, in: candidate.calendar.recurrence)
                else { throw WorkspaceReducerError.invalidConsistencyRepair }
                override = .init(
                    key: newKey,
                    primary: override.primary,
                    addedReferenceNoteIDs: override.addedReferenceNoteIDs,
                    removedReferenceNoteIDs: override.removedReferenceNoteIDs
                )
                candidate.calendarNoteRelations.occurrenceOverrides[newKey] = override
            default:
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
        case let .calendarNote(slot):
            guard resolutions.count == 1 else { throw WorkspaceReducerError.invalidConsistencyRepair }
            let newNote: NoteID?
            switch resolutions[0].1 {
            case .unlink: newNote = nil
            case let .relink(.note(noteID)) where candidate.notes[noteID] != nil: newNote = noteID
            default: throw WorkspaceReducerError.invalidConsistencyRepair
            }
            try repairCalendarNote(slot, replacement: newNote, in: &candidate)
        case let .taskBlock(link):
            candidate.taskBlockLinks.remove(link)
            if resolutions.contains(where: { if case .unlink = $0.1 { true } else { false } }) {
                guard resolutions.allSatisfy({ if case .unlink = $0.1 { true } else { false } }) else {
                    throw WorkspaceReducerError.invalidConsistencyRepair
                }
                return
            }
            var replacement = link
            for (issue, resolution) in resolutions {
                switch (issue.defect, resolution) {
                case (.missingCalendarItem, let .relink(.calendarItem(itemID))):
                    replacement = .init(noteID: replacement.noteID, blockID: replacement.blockID, calendarItemID: itemID)
                case (.missingTaskBlock, let .relink(.taskBlock(noteID, blockID))):
                    replacement = .init(noteID: noteID, blockID: blockID, calendarItemID: replacement.calendarItemID)
                default:
                    throw WorkspaceReducerError.invalidConsistencyRepair
                }
            }
            guard candidate.calendar.items[replacement.calendarItemID] != nil,
                  let note = candidate.notes[replacement.noteID],
                  let block = note.document.blocks.first(where: {
                      $0.id == replacement.blockID && $0.kind == .task
                  }),
                  candidate.calendarNoteRelations.baselines[.item(replacement.calendarItemID)]?.primaryNoteID
                    == replacement.noteID,
                  candidate.calendar.items[replacement.calendarItemID]?.completedAt
                    == block.taskState?.completedAt,
                  !candidate.taskBlockLinks.contains(where: {
                      $0.blockID == replacement.blockID || $0.calendarItemID == replacement.calendarItemID
                  })
            else { throw WorkspaceReducerError.invalidConsistencyRepair }
            candidate.taskBlockLinks.insert(replacement)
        case let .inspirationNote(link):
            candidate.inspirationNoteLinks.remove(link)
            if resolutions.contains(where: { if case .unlink = $0.1 { true } else { false } }) {
                guard resolutions.allSatisfy({ if case .unlink = $0.1 { true } else { false } }) else {
                    throw WorkspaceReducerError.invalidConsistencyRepair
                }
                return
            }
            var noteID = link.noteID
            var source = link.source
            for (issue, resolution) in resolutions {
                switch (issue.defect, resolution) {
                case (.missingNote, let .relink(.note(id))): noteID = id
                case (.missingInspiration, let .relink(.inspiration(id))): source = .live(id)
                default: throw WorkspaceReducerError.invalidConsistencyRepair
                }
            }
            guard candidate.notes[noteID] != nil else { throw WorkspaceReducerError.invalidConsistencyRepair }
            if case let .live(id) = source, candidate.inspirations[id] == nil {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            let replacement = InspirationNoteLink(source: source, noteID: noteID, createdAt: link.createdAt)
            guard !candidate.inspirationNoteLinks.contains(replacement) else {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            candidate.inspirationNoteLinks.insert(replacement)
        }
    }

    private static func repairCalendarNote(
        _ slot: CalendarNoteRelationSlot,
        replacement: NoteID?,
        in candidate: inout WorkspaceState
    ) throws {
        switch slot {
        case let .baselinePrimary(owner, _):
            guard var set = candidate.calendarNoteRelations.baselines[owner] else {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            set.primaryNoteID = replacement
            writeBaseline(set, owner: owner, in: &candidate)
        case let .baselineReference(owner, oldID):
            guard var set = candidate.calendarNoteRelations.baselines[owner] else {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            set.referenceNoteIDs.remove(oldID)
            if let replacement { set.referenceNoteIDs.insert(replacement) }
            writeBaseline(set, owner: owner, in: &candidate)
        case let .occurrencePrimary(key, _):
            guard var override = candidate.calendarNoteRelations.occurrenceOverrides[key] else {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            override.primary = replacement.map(OccurrencePrimaryOverride.replace) ?? .clear
            candidate.calendarNoteRelations.occurrenceOverrides[key] = override
        case let .occurrenceAddedReference(key, oldID):
            guard var override = candidate.calendarNoteRelations.occurrenceOverrides[key] else {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            override.addedReferenceNoteIDs.remove(oldID)
            if let replacement { override.addedReferenceNoteIDs.insert(replacement) }
            candidate.calendarNoteRelations.occurrenceOverrides[key] = override
        case let .occurrenceRemovedReference(key, oldID):
            guard var override = candidate.calendarNoteRelations.occurrenceOverrides[key] else {
                throw WorkspaceReducerError.invalidConsistencyRepair
            }
            override.removedReferenceNoteIDs.remove(oldID)
            if let replacement { override.removedReferenceNoteIDs.insert(replacement) }
            candidate.calendarNoteRelations.occurrenceOverrides[key] = override
        }
    }

    private static func contains(_ owner: CalendarNoteOwnerID, in calendar: CalendarState) -> Bool {
        switch owner {
        case let .item(id): calendar.items[id] != nil
        case let .series(id): calendar.recurrence.series[id] != nil
        }
    }
}

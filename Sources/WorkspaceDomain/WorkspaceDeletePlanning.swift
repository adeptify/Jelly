import CalendarDomain
import Foundation

public enum WorkspaceDeletePlanningError: Error, Equatable, Sendable {
    case missingSubject
}

public enum PermanentDeletePlanner {
    public static func preview(
        _ subject: PermanentDeleteSubject,
        in state: WorkspaceState
    ) throws -> PermanentDeletePreview {
        var effects: [PermanentDeleteEffect] = []
        switch subject {
        case let .note(noteID):
            guard state.notes[noteID] != nil else { throw WorkspaceDeletePlanningError.missingSubject }
            for (owner, set) in state.calendarNoteRelations.baselines {
                if set.primaryNoteID == noteID { effects.append(.clearBaselinePrimary(owner)) }
                if set.referenceNoteIDs.contains(noteID) { effects.append(.removeBaselineReference(owner)) }
            }
            for (key, override) in state.calendarNoteRelations.occurrenceOverrides {
                if case let .replace(linkedNoteID) = override.primary, linkedNoteID == noteID {
                    effects.append(.clearOccurrenceReplacement(key))
                }
                if override.addedReferenceNoteIDs.contains(noteID) {
                    effects.append(.removeOccurrenceAddedReference(key))
                }
                if override.removedReferenceNoteIDs.contains(noteID) {
                    effects.append(.removeOccurrenceRemovedReference(key))
                }
            }
            effects.append(contentsOf: state.taskBlockLinks
                .filter { $0.noteID == noteID }
                .map(PermanentDeleteEffect.removeTaskBlockLink))
            effects.append(contentsOf: state.inspirationNoteLinks
                .filter { $0.noteID == noteID }
                .map(PermanentDeleteEffect.removeInspirationNoteLink))
        case let .inspiration(inspirationID, _):
            guard state.inspirations[inspirationID] != nil else {
                throw WorkspaceDeletePlanningError.missingSubject
            }
            effects.append(contentsOf: state.inspirationNoteLinks.compactMap { link in
                guard case let .live(linkedID) = link.source, linkedID == inspirationID else { return nil }
                return .tombstoneInspirationNoteLink(noteID: link.noteID, inspirationID: inspirationID)
            })
        }
        effects.sort { canonical($0) < canonical($1) }
        let checksum = WorkspaceChecksum.sha256Hex(
            "delete-preview-v1|\(canonical(subject))|\(state.revision)|"
                + effects.map(canonical).joined(separator: "\n")
        )
        return .init(
            subject: subject,
            sourceWorkspaceRevision: state.revision,
            effects: effects,
            checksum: checksum
        )
    }

    static func canonical(_ subject: PermanentDeleteSubject) -> String {
        switch subject {
        case let .note(id): "note|\(id.rawValue.uuidString)"
        case let .inspiration(id, deletedAt):
            "inspiration|\(id.rawValue.uuidString)|\(deletedAt.timeIntervalSince1970)"
        }
    }

    static func canonical(_ effect: PermanentDeleteEffect) -> String {
        switch effect {
        case let .clearBaselinePrimary(owner):
            "01|\(WorkspaceConsistencyInspector.canonical(owner))"
        case let .removeBaselineReference(owner):
            "02|\(WorkspaceConsistencyInspector.canonical(owner))"
        case let .clearOccurrenceReplacement(key):
            "03|\(WorkspaceConsistencyInspector.canonical(key))"
        case let .removeOccurrenceAddedReference(key):
            "04|\(WorkspaceConsistencyInspector.canonical(key))"
        case let .removeOccurrenceRemovedReference(key):
            "05|\(WorkspaceConsistencyInspector.canonical(key))"
        case let .removeTaskBlockLink(link):
            "06|\(link.noteID.rawValue.uuidString)|\(link.blockID.rawValue.uuidString)|\(link.calendarItemID.uuidString)"
        case let .removeInspirationNoteLink(link):
            "07|\(link.noteID.rawValue.uuidString)|\(canonical(link.source))|\(link.createdAt.timeIntervalSince1970)"
        case let .tombstoneInspirationNoteLink(noteID, inspirationID):
            "08|\(noteID.rawValue.uuidString)|\(inspirationID.rawValue.uuidString)"
        }
    }

    private static func canonical(_ source: InspirationSourceReference) -> String {
        switch source {
        case let .live(id): "live|\(id.rawValue.uuidString)"
        case let .deleted(id, at): "deleted|\(id.rawValue.uuidString)|\(at.timeIntervalSince1970)"
        }
    }
}

public enum LegacyMarkdownMigrationPlanner {
    public static func preview(
        scope: CalendarRelationScope,
        in state: WorkspaceState,
        injectedBlockIDs: [BlockID],
        checkedTaskCompletedAt: Date
    ) throws -> LegacyMarkdownMigrationPreview {
        let markdown = try markdown(for: scope, in: state)
        let imported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(injectedBlockIDs),
            checkedTaskCompletedAt: checkedTaskCompletedAt
        )
        guard imported.document.blocks.count == injectedBlockIDs.count,
              imported.document.blocks.map(\.id) == injectedBlockIDs
        else {
            throw WorkspaceReducerError.invalidLegacyAuthorization
        }
        return .init(
            scope: scope,
            document: imported.document,
            diagnostics: imported.diagnostics,
            sourceChecksum: sourceChecksum(scope: scope, markdown: markdown),
            diagnosticsChecksum: WorkspaceChecksum.diagnosticsChecksum(imported.diagnostics)
        )
    }

    static func markdown(for scope: CalendarRelationScope, in state: WorkspaceState) throws -> String {
        switch scope {
        case let .item(id):
            guard let item = state.calendar.items[id] else { throw WorkspaceReducerError.missingCalendarTarget }
            return item.notes
        case let .series(id):
            guard let series = state.calendar.recurrence.series[id] else {
                throw WorkspaceReducerError.missingCalendarTarget
            }
            return series.notes
        case let .occurrenceOnly(key), let .occurrenceThisAndFuture(key, _):
            guard let series = state.calendar.recurrence.series[key.seriesID],
                  CalendarNoteRelationResolver.isLogicalInstance(key, in: state.calendar.recurrence)
            else {
                throw WorkspaceReducerError.missingCalendarTarget
            }
            if case let .modified(override) = state.calendar.recurrence.exceptions[key] {
                return override.notes
            }
            return series.notes
        }
    }

    public static func sourceChecksum(scope: CalendarRelationScope, markdown: String) -> String {
        var data = Data("legacy-source-v1\u{0}".utf8)
        data.append(Data(canonical(scope).utf8))
        data.append(0)
        data.append(Data(markdown.utf8))
        return WorkspaceChecksum.sha256Hex(data)
    }

    static func canonical(_ scope: CalendarRelationScope) -> String {
        switch scope {
        case let .item(id): "item|\(id.uuidString)"
        case let .series(id): "series|\(id.uuidString)"
        case let .occurrenceOnly(key):
            "occurrence-only|\(WorkspaceConsistencyInspector.canonical(key))"
        case let .occurrenceThisAndFuture(key, newSeriesID):
            "occurrence-future|\(WorkspaceConsistencyInspector.canonical(key))|\(newSeriesID.uuidString)|\(key.originalDate.year)-\(key.originalDate.month)-\(key.originalDate.day)"
        }
    }
}

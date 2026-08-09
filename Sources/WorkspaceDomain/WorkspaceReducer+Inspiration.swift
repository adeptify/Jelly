import Foundation

extension WorkspaceReducer {
    static func createInspiration(
        _ inspiration: Inspiration,
        in candidate: inout WorkspaceState
    ) throws {
        guard candidate.inspirations[inspiration.id] == nil else {
            throw WorkspaceReducerError.duplicateInspiration(inspiration.id)
        }
        var probe = candidate
        probe.inspirations[inspiration.id] = inspiration
        do {
            try WorkspaceValidator.validate(probe)
        } catch {
            throw WorkspaceReducerError.invalidInspiration
        }
        candidate.inspirations[inspiration.id] = inspiration
    }

    static func updateInspirationMetadata(
        _ id: InspirationID,
        expectation: InspirationMetadataExpectation,
        metadata: SourceMetadata,
        kind: ResolvedSourceKind,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard WorkspaceChecksum.inspirationSourceChecksum(inspiration) == expectation.sourceChecksum else {
            return .result(.noChange(.staleMetadata))
        }
        guard inspiration.resolvedMetadata != metadata || inspiration.resolvedSourceKind != kind else {
            return .result(.noChange(.identical))
        }
        inspiration.resolvedMetadata = metadata
        inspiration.resolvedSourceKind = kind
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func convertInspiration(
        _ payload: ConvertInspirationToNotePayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard candidate.inspirations[payload.inspirationID] != nil else {
            throw WorkspaceReducerError.missingInspiration(payload.inspirationID)
        }
        if let existing = candidate.inspirationNoteLinks.first(where: { link in
            if case let .live(linkedID) = link.source { linkedID == payload.inspirationID } else { false }
        }) {
            return .result(.noChange(.inspirationAlreadyConverted(existing.noteID)))
        }
        try createNote(payload.proposedNote, in: &candidate)
        candidate.inspirationNoteLinks.insert(.init(
            source: .live(payload.inspirationID),
            noteID: payload.proposedNote.id,
            createdAt: now
        ))
        return .proceed
    }

    static func setInspirationLifecycle(
        _ id: InspirationID,
        lifecycle: InspirationLifecycle,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard inspiration.lifecycle != lifecycle else { return }
        inspiration.lifecycle = lifecycle
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
    }

    static func permanentlyDeleteInspiration(
        _ id: InspirationID,
        deletedAt: Date,
        authorization: PermanentDeleteAuthorization,
        in candidate: inout WorkspaceState
    ) throws -> WorkspaceCommandControl {
        guard candidate.inspirations[id] != nil else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        let subject = PermanentDeleteSubject.inspiration(id, deletedAt: deletedAt)
        let preview = try PermanentDeletePlanner.preview(subject, in: candidate)
        guard authorization.subject == subject,
              authorization.sourceWorkspaceRevision == preview.sourceWorkspaceRevision,
              authorization.impactChecksum == preview.checksum
        else {
            return .result(.noChange(.staleDeleteAuthorization))
        }
        candidate.inspirationNoteLinks = Set(candidate.inspirationNoteLinks.map { link in
            guard case let .live(linkedID) = link.source, linkedID == id else { return link }
            return InspirationNoteLink(
                source: .deleted(originalID: id, deletedAt: deletedAt),
                noteID: link.noteID,
                createdAt: link.createdAt
            )
        })
        candidate.inspirations.removeValue(forKey: id)
        return .proceed
    }
}

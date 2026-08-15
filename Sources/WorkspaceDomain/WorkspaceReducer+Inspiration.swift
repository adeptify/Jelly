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

    static func updateInspirationText(
        _ id: InspirationID,
        rawText: String,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard inspiration.inputKind == .text,
              inspiration.lifecycle == .active,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !candidate.inspirationNoteLinks.contains(where: { link in
                  if case let .live(sourceID) = link.source { return sourceID == id }
                  return false
              }) else {
            throw WorkspaceReducerError.invalidInspiration
        }
        guard inspiration.rawText != rawText else {
            return .result(.noChange(.identical))
        }
        inspiration.rawText = rawText
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
        return .proceed
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
        let existing = candidate.inspirationNoteLinks
            .filter { link in
                if case let .live(linkedID) = link.source { linkedID == payload.inspirationID } else { false }
            }
            .min { lhs, rhs in
                lhs.noteID.rawValue.uuidString < rhs.noteID.rawValue.uuidString
            }
        if let existing {
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

    static func changeInspirationCategory(
        _ id: InspirationID,
        categoryID: UUID,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard var inspiration = candidate.inspirations[id],
              candidate.calendar.categories[categoryID] != nil else {
            throw WorkspaceReducerError.invalidInspiration
        }
        guard inspiration.categoryID != categoryID else {
            return .result(.noChange(.identical))
        }
        inspiration.categoryID = categoryID
        inspiration.updatedAt = now
        candidate.inspirations[id] = inspiration
        return .proceed
    }

    static func permanentlyDeleteInspiration(
        _ id: InspirationID,
        deletedAt: Date,
        authorization: PermanentDeleteAuthorization,
        in candidate: inout WorkspaceState
    ) throws -> WorkspaceCommandControl {
        guard let inspiration = candidate.inspirations[id] else {
            throw WorkspaceReducerError.missingInspiration(id)
        }
        guard inspiration.lifecycle == .archived else {
            throw WorkspaceReducerError.permanentDeleteRequiresArchivedSubject
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

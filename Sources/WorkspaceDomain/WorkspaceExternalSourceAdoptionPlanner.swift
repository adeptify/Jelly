import Foundation

public struct WorkspaceExternalSourceAdoption: Equatable, Sendable {
    public let candidate: WorkspaceState
    public let noteRevisionHighWatermarks: [NoteID: Int64]
    public let requiresNormalization: Bool
    public let consistencyIssues: [WorkspaceConsistencyIssue]

    public init(
        candidate: WorkspaceState,
        noteRevisionHighWatermarks: [NoteID: Int64],
        requiresNormalization: Bool,
        consistencyIssues: [WorkspaceConsistencyIssue]
    ) {
        self.candidate = candidate
        self.noteRevisionHighWatermarks = noteRevisionHighWatermarks
        self.requiresNormalization = requiresNormalization
        self.consistencyIssues = consistencyIssues
    }
}

public enum WorkspaceExternalSourceAdoptionError: Error, Equatable, Sendable {
    case revisionOverflow
}

public enum WorkspaceExternalSourceAdoptionPlanner {
    public static func plan(
        current: WorkspaceState,
        external: WorkspaceState,
        sessionNoteHighWatermarks: [NoteID: Int64]
    ) throws -> WorkspaceExternalSourceAdoption {
        var candidate = external
        let contentIsIdentical = WorkspaceReducer.businessEquivalent(current, external)
        candidate.revision = try revision(
            current: current.revision,
            external: external.revision,
            identical: contentIsIdentical
        )

        var highWatermarks = sessionNoteHighWatermarks
        for id in Set(current.notes.keys).union(external.notes.keys) {
            let known = highWatermarks[id] ?? 0
            let currentRevision = current.notes[id]?.revision ?? 0
            let externalRevision = external.notes[id]?.revision ?? 0
            let highWatermark = max(known, currentRevision, externalRevision)
            highWatermarks[id] = highWatermark

            guard var externalNote = candidate.notes[id] else { continue }
            let notesAreIdentical: Bool
            if let currentNote = current.notes[id], let sourceNote = external.notes[id] {
                notesAreIdentical = WorkspaceReducer.noteBusinessEquivalent(currentNote, sourceNote)
            } else {
                notesAreIdentical = false
            }
            externalNote.revision = try revision(
                current: max(known, currentRevision),
                external: externalRevision,
                identical: notesAreIdentical
            )
            candidate.notes[id] = externalNote
            highWatermarks[id] = max(highWatermarks[id] ?? 0, externalNote.revision)
        }

        let consistencyIssues = WorkspaceConsistencyInspector.inspect(external).issues
        return WorkspaceExternalSourceAdoption(
            candidate: candidate,
            noteRevisionHighWatermarks: highWatermarks,
            requiresNormalization: candidate != external || !consistencyIssues.isEmpty,
            consistencyIssues: consistencyIssues
        )
    }

    private static func revision(
        current: Int64,
        external: Int64,
        identical: Bool
    ) throws -> Int64 {
        let maximum = max(current, external)
        guard maximum >= 0 else { throw WorkspaceExternalSourceAdoptionError.revisionOverflow }
        if identical { return maximum }
        guard maximum < Int64.max else { throw WorkspaceExternalSourceAdoptionError.revisionOverflow }
        return maximum + 1
    }
}

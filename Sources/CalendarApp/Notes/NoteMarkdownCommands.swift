import AppKit
import Foundation
import WorkspaceDomain

enum NoteMarkdownImportModeChoice: Equatable, Sendable {
    case replace
    case append
    case cancel
}

struct NoteMarkdownImportPlan: Equatable, Sendable {
    let result: BlockMarkdownImportResult
    let mode: BlockDocumentIngestMode
}

enum NoteMarkdownCommandError: Error, Equatable, Sendable {
    case userCancelled
    case emptyImport
    case writeFailed
    case readbackMismatch
    case invalidDocument
}

struct NoteMarkdownLiveSnapshot: Equatable, Sendable {
    let noteID: NoteID
    let editSessionID: UUID
    let document: BlockDocument
}

enum NoteMarkdownExportSource {
    static func document(
        persistedNoteID: NoteID,
        persistedDocument: BlockDocument,
        editorIdentity: NoteEditorIdentity?,
        liveSnapshot: NoteMarkdownLiveSnapshot?
    ) -> BlockDocument {
        guard let editorIdentity,
              editorIdentity.noteID == persistedNoteID,
              let liveSnapshot,
              liveSnapshot.noteID == persistedNoteID,
              liveSnapshot.editSessionID == editorIdentity.editSessionID
        else { return persistedDocument }
        return liveSnapshot.document
    }
}

/// Pure helpers for Note Markdown import/export. Presentation owns panels;
/// this type never mutates the editor session itself.
enum NoteMarkdownCommands {
    static func planImport(
        markdown: String,
        mode: BlockDocumentIngestMode,
        checkedTaskCompletedAt: Date
    ) throws -> NoteMarkdownImportPlan {
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .random,
            checkedTaskCompletedAt: checkedTaskCompletedAt
        )
        guard !result.document.blocks.isEmpty else { throw NoteMarkdownCommandError.emptyImport }
        try BlockDocumentValidator.validate(result.document)
        return .init(result: result, mode: mode)
    }

    static func exportMarkdown(from document: BlockDocument) throws -> String {
        try BlockMarkdownCodec.exportMarkdown(document)
    }

    static func writeExport(
        markdown: String,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let data = Data(markdown.utf8)
        try data.write(to: url, options: .atomic)
        let readback = try Data(contentsOf: url)
        guard readback == data else { throw NoteMarkdownCommandError.readbackMismatch }
    }
}

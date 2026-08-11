import WorkspaceDomain

enum TaskBlockDeletionConfirmation {
    static func requiredLinkedBlocks(
        noteID: NoteID,
        before: BlockDocument,
        after: BlockDocument,
        links: Set<TaskBlockCalendarLink>
    ) -> [BlockID] {
        let beforeIDs = Set(before.blocks.map(\.id))
        let afterIDs = Set(after.blocks.map(\.id))
        let removedIDs = beforeIDs.subtracting(afterIDs)
        return links.compactMap { link in
            guard link.noteID == noteID, removedIDs.contains(link.blockID) else { return nil }
            return link.blockID
        }
        .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }
}

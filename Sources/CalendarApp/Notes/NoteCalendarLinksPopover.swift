import SwiftUI
import WorkspaceDomain

/// Notes-side surface listing calendar items that use this note as primary or
/// reference. Full two-way navigation is completed as Task 11 wiring matures.
struct NoteCalendarLinksPopover: View {
    let store: WorkspaceStore
    let noteID: NoteID

    private var linkedItemIDs: [UUID] {
        var ids: [UUID] = []
        for (owner, set) in store.state.calendarNoteRelations.baselines {
            let linked = set.primaryNoteID == noteID || set.referenceNoteIDs.contains(noteID)
            guard linked else { continue }
            if case let .item(itemID) = owner {
                ids.append(itemID)
            }
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关联的日历事项")
                .font(.headline)
            if linkedItemIDs.isEmpty {
                Text("当前笔记未关联日历事项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(linkedItemIDs, id: \.self) { itemID in
                    let title = store.calendarState.items[itemID]?.title ?? itemID.uuidString
                    Text(title)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 240)
    }
}

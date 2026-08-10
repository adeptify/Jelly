import SwiftUI
import WorkspaceDomain

struct CalendarNotePicker: View {
    let store: WorkspaceStore
    let title: String
    let onPick: (NoteID) -> Void
    let onCancel: () -> Void

    @State private var query = ""

    private var notes: [Note] {
        store.state.notes.values
            .filter { $0.archivedAt == nil }
            .filter {
                query.isEmpty
                    || $0.title.localizedCaseInsensitiveContains(query)
            }
            .sorted {
                $0.updatedAt != $1.updatedAt
                    ? $0.updatedAt > $1.updatedAt
                    : $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("搜索笔记", text: $query)
                .textFieldStyle(.roundedBorder)
            List(notes) { note in
                Button {
                    onPick(note.id)
                } label: {
                    Text(note.title.isEmpty ? "无标题" : note.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
            }
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 360)
    }
}

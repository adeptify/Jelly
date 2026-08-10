import SwiftUI
import WorkspaceDomain

struct NoteBrowserView: View {
    @Bindable var viewModel: NotesWorkspaceViewModel
    let onSelect: (NoteID) async -> Void
    let onCreate: () async -> Void
    let onShowCategoryManager: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索笔记", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索笔记")
                Button("分类", action: onShowCategoryManager)
                    .accessibilityLabel("管理分类")
            }
            .padding(12)

            List {
                Section("最近编辑") {
                    noteRows(viewModel.recentNotes, empty: "暂无最近笔记")
                }
                Section("全部笔记") {
                    noteRows(viewModel.allNotes, empty: "暂无笔记")
                }
                Section("归档") {
                    noteRows(viewModel.archivedNotes, empty: "归档为空")
                }
            }
            .listStyle(.sidebar)

            Button {
                Task { await onCreate() }
            } label: {
                Label("新建", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(12)
            .accessibilityLabel("新建笔记")
        }
    }

    @ViewBuilder
    private func noteRows(_ notes: [Note], empty: String) -> some View {
        if notes.isEmpty {
            Text(empty)
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            ForEach(notes) { note in
                Button {
                    Task { await onSelect(note.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title.isEmpty ? "无标题" : note.title)
                            .lineLimit(1)
                            .font(.body.weight(viewModel.selectedNoteID == note.id ? .semibold : .regular))
                        Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    viewModel.selectedNoteID == note.id
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
                .accessibilityLabel(note.title.isEmpty ? "无标题笔记" : note.title)
                .accessibilityAddTraits(viewModel.selectedNoteID == note.id ? .isSelected : [])
            }
        }
    }
}

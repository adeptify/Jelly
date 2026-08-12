import CalendarDomain
import SwiftUI
import WorkspaceDomain

struct NoteBrowserView: View {
    @Bindable var viewModel: NotesWorkspaceViewModel
    let categories: [CalendarCategory]
    let onSelect: (NoteID) async -> Void
    let onCreate: () async -> Void
    let onToggleBrowser: () -> Void
    let onShowCategoryManager: () -> Void

    @State private var partition: NotesBrowserPartition = .recent
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            browserHeader
            searchAndFilter
            partitionPicker
            noteList
            createButton
        }
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
    }

    private var browserHeader: some View {
        HStack(spacing: 10) {
            Text("笔记")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Button(action: onToggleBrowser) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help("隐藏笔记列表")
            .accessibilityLabel("隐藏笔记列表")
        }
        .padding(.horizontal, 14)
        .frame(height: CalendarTheme.toolbarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
    }

    private var searchAndFilter: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                TextField("搜索标题和正文", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索笔记")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.subtleBorder.opacity(0.5), lineWidth: 0.5)
            }

            categoryMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var categoryMenu: some View {
        Menu {
            Button {
                viewModel.categoryFilterID = nil
            } label: {
                categoryMenuLabel("全部分类", selected: viewModel.categoryFilterID == nil)
            }
            ForEach(categories) { category in
                Button {
                    viewModel.categoryFilterID = category.id
                } label: {
                    categoryMenuLabel(category.name, selected: viewModel.categoryFilterID == category.id)
                }
            }
            Divider()
            Button("管理分类…", action: onShowCategoryManager)
        } label: {
            Image(systemName: viewModel.categoryFilterID == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(viewModel.categoryFilterID == nil ? theme.secondaryText : theme.controlAccent)
                .frame(width: 30, height: 30)
                .background(theme.canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("按分类筛选；也可管理分类")
        .accessibilityLabel("筛选笔记分类")
    }

    private func categoryMenuLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected { Image(systemName: "checkmark") }
        }
    }

    private var partitionPicker: some View {
        Picker("笔记范围", selection: $partition) {
            ForEach(NotesBrowserPartition.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .tint(theme.controlAccent)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityLabel("笔记范围")
    }

    private var noteList: some View {
        List {
            noteRows(viewModel.displayedNotes(in: partition), empty: partition.emptyMessage)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.elevatedSurface)
    }

    private var createButton: some View {
        Button {
            Task { await onCreate() }
        } label: {
            Label("新建笔记", systemImage: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(theme.rangePreviewFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(12)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
        .accessibilityLabel("新建笔记")
    }

    @ViewBuilder
    private func noteRows(_ notes: [Note], empty: String) -> some View {
        if notes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: partition == .archived ? "archivebox" : "note.text")
                    .font(.system(size: 20))
                Text(empty).font(.caption)
            }
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(notes) { note in
                Button {
                    Task { await onSelect(note.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title.isEmpty ? "无标题" : note.title)
                            .lineLimit(1)
                            .font(.system(size: 13, weight: viewModel.selectedNoteID == note.id ? .semibold : .regular))
                            .foregroundStyle(theme.primaryText)
                        Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        if viewModel.selectedNoteID == note.id {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.rangePreviewFill)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityLabel(note.title.isEmpty ? "无标题笔记" : note.title)
                .accessibilityAddTraits(viewModel.selectedNoteID == note.id ? .isSelected : [])
            }
        }
    }
}

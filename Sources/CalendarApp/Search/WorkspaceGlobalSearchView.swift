import CalendarDomain
import Combine
import SwiftUI
import WorkspaceDomain

@MainActor
final class WorkspaceSearchRouter: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    func present() { isPresented = true }
}

private struct WorkspaceGlobalSearchResult: Identifiable {
    let record: WorkspaceSearchRecord
    let title: String
    let preview: String
    let category: String

    var id: WorkspaceObjectID { record.objectID }

    var icon: String {
        switch record.kind {
        case .calendarItem: "calendar"
        case .note: "note.text"
        case .inspiration: "lightbulb"
        }
    }

    var kindTitle: String {
        switch record.kind {
        case .calendarItem: "日历"
        case .note: "笔记"
        case .inspiration: "灵感"
        }
    }
}

struct WorkspaceGlobalSearchView: View {
    let store: WorkspaceStore
    let searchIndex: WorkspaceSearchIndex
    let onOpen: (WorkspaceObjectID) -> Void
    @ObservedObject var router: WorkspaceSearchRouter

    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.secondaryText)
                TextField("查找事项、笔记和灵感", text: $router.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                if !router.query.isEmpty {
                    Button {
                        router.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider()

            if router.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "开始查找",
                    systemImage: "magnifyingglass",
                    description: Text("输入标题、正文、链接或随记中的文字。")
                )
            } else if results.isEmpty {
                ContentUnavailableView.search(text: router.query)
            } else {
                List(results) { result in
                    Button {
                        dismiss()
                        onOpen(result.record.objectID)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.icon)
                                .frame(width: 24, height: 24)
                                .foregroundStyle(theme.controlAccent)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(highlighted(result.title))
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(result.kindTitle)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                if !result.preview.isEmpty {
                                    Text(highlighted(result.preview))
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.secondaryText)
                                        .lineLimit(2)
                                }
                                Text(result.category)
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 560, height: 480)
        .background(theme.elevatedSurface)
        .onAppear { searchFocused = true }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var results: [WorkspaceGlobalSearchResult] {
        let records = (try? searchIndex.search(
            query: router.query,
            kind: nil,
            includeArchived: false,
            in: store.state
        )) ?? []
        return records.prefix(100).compactMap(makeResult)
    }

    private func highlighted(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        let query = router.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let sourceRange = source.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive]
              ),
              let attributedRange = Range(sourceRange, in: result)
        else { return result }
        result[attributedRange].backgroundColor = theme.controlAccent.opacity(0.18)
        result[attributedRange].foregroundColor = theme.primaryText
        return result
    }

    private func makeResult(_ record: WorkspaceSearchRecord) -> WorkspaceGlobalSearchResult? {
        let category = record.categoryID.flatMap { store.calendarState.categories[$0]?.name } ?? "未分类"
        switch record.objectID {
        case let .calendarItem(id):
            guard let item = store.calendarState.items[id] else { return nil }
            return .init(record: record, title: item.title, preview: item.notes, category: category)
        case let .note(id):
            guard let note = store.state.notes[id] else { return nil }
            let body = note.document.blocks
                .flatMap(\.inlineContent.spans)
                .map(\.text)
                .joined(separator: " ")
            return .init(
                record: record,
                title: note.title.isEmpty ? "无标题" : note.title,
                preview: body,
                category: category
            )
        case let .inspiration(id):
            guard let inspiration = store.state.inspirations[id] else { return nil }
            let title = inspiration.resolvedMetadata?.title
                ?? inspiration.rawText
                ?? inspiration.rawURL?.absoluteString
                ?? "灵感"
            let preview = inspiration.rawURL?.absoluteString ?? inspiration.rawText ?? ""
            return .init(record: record, title: title, preview: preview, category: category)
        }
    }
}

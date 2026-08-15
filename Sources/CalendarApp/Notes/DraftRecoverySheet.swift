import SwiftUI
import WorkspaceDomain

enum DraftRecoveryDiffChange: Equatable, Sendable {
    case unchanged
    case modified
    case onlyInCurrentNote
    case onlyInExitVersion
}

struct DraftRecoveryBodyRow: Equatable, Sendable {
    let currentNote: DocumentBlock?
    let exitVersion: DocumentBlock?
    let change: DraftRecoveryDiffChange
}

struct DraftRecoveryComparison: Equatable, Sendable {
    let changedFields: [String]
    let addedBodyBlocks: Int
    let removedBodyBlocks: Int
    let modifiedBodyBlocks: Int
    let bodyRows: [DraftRecoveryBodyRow]

    var summary: String {
        guard changedFields.isEmpty == false else { return "两个版本内容相同" }
        if changedFields == ["正文"] {
            if addedBodyBlocks > 0,
               removedBodyBlocks == 0,
               modifiedBodyBlocks == 0 {
                return "退出前版本包含当前笔记全部内容，并新增 \(addedBodyBlocks) 段"
            }
            return "正文有 \(addedBodyBlocks + removedBodyBlocks + modifiedBodyBlocks) 处不同"
        }
        return "\(changedFields.joined(separator: "、"))不同"
    }
}

/// Presents a single reviewed draft-recovery candidate with the three contract
/// actions. Stale tokens refresh rather than inventing success.
struct DraftRecoverySheet: View {
    let candidate: DraftRecoveryCandidate
    let statusMessage: String?
    let isResolving: Bool
    let onRestoreAsCurrent: () -> Void
    let onKeepPersisted: () -> Void
    let onSaveAsNew: () -> Void

    @State private var hoveredVersion: RecoveryVersion?
    @State private var showsAllRows = false

    private enum RecoveryVersion: Equatable {
        case currentNote
        case exitVersion
    }

    private var comparison: DraftRecoveryComparison {
        DraftRecoveryPresentation.comparison(for: candidate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("恢复未保存的笔记")
                .font(.title2.weight(.semibold))
            Text(statusMessage ?? "Jelly 找到一份退出前保留的内容。对比后，选择继续使用哪一版。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label(comparison.summary, systemImage: "arrow.left.and.right")
                    .font(.subheadline.weight(.semibold))
                if isResolving {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("正在保存你的选择…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let persisted = candidate.persisted {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 14) {
                        recoveryChoiceCard(
                            version: .currentNote,
                            label: "当前笔记",
                            timeLabel: "上次成功保存",
                            note: persisted,
                            date: persisted.updatedAt,
                            action: onKeepPersisted
                        )
                        recoveryChoiceCard(
                            version: .exitVersion,
                            label: "退出前版本",
                            timeLabel: "退出前自动保留",
                            note: candidate.draft,
                            date: candidate.updatedAt,
                            action: onRestoreAsCurrent
                        )
                    }
                    .padding(1)
                }
                .frame(maxHeight: showsAllRows ? 500 : 390)

                if comparison.bodyRows.count > focusedRows.count {
                    Button(showsAllRows ? "只看差异附近" : "查看全部内容") {
                        showsAllRows.toggle()
                    }
                    .buttonStyle(.link)
                    .disabled(isResolving)
                }

                keepBothChoice
            } else {
                recoveryChoiceCard(
                    version: .exitVersion,
                    label: "退出前版本",
                    timeLabel: "尚未写入当前笔记",
                    note: candidate.draft,
                    date: candidate.updatedAt,
                    action: onRestoreAsCurrent
                )
                .frame(maxWidth: 560)

                HStack {
                    Text("如果不需要恢复，这份内容将被丢弃。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("不恢复这份内容", role: .destructive, action: onKeepPersisted)
                        .disabled(isResolving)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 760, idealWidth: 860)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("恢复未保存的笔记")
    }

    private var keepBothChoice: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("不确定选哪版？")
                        .font(.subheadline.weight(.semibold))
                    Text("当前笔记保持不变，退出前版本会另存为一篇新笔记。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button("两个版本都保留", action: onSaveAsNew)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isResolving)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.blue.opacity(0.18), lineWidth: 1)
        }
    }

    private func recoveryChoiceCard(
        version: RecoveryVersion,
        label: String,
        timeLabel: String,
        note: Note,
        date: Date?,
        action: @escaping () -> Void
    ) -> some View {
        let tint = version == .currentNote ? Color.orange : Color.blue
        let isHovered = hoveredVersion == version
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.headline)
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(isHovered ? tint : .secondary.opacity(0.45))
                }
                if let date {
                    Text("\(timeLabel) · \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(note.title.isEmpty ? "无标题" : note.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        comparison.changedFields.contains("标题") ? tint.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(displayedRows.enumerated()), id: \.offset) { _, row in
                        recoveryBodyRow(row, version: version, tint: tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Spacer(minLength: 4)
                HStack {
                    Text("用这版继续")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(tint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
            .background(
                isHovered ? tint.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isHovered ? tint.opacity(0.72) : .secondary.opacity(0.16), lineWidth: isHovered ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
        .onHover { hovering in
            hoveredVersion = hovering ? version : nil
        }
        .accessibilityLabel("\(label)，\(note.title.isEmpty ? "无标题" : note.title)，用这版继续")
        .accessibilityHint("选择后可以在继续编辑前撤销")
    }

    private var displayedRows: [DraftRecoveryBodyRow] {
        showsAllRows ? comparison.bodyRows : focusedRows
    }

    private var focusedRows: [DraftRecoveryBodyRow] {
        let rows = comparison.bodyRows
        guard rows.count > 12 else { return rows }
        var indices: Set<Int> = []
        for index in rows.indices where rows[index].change != .unchanged {
            indices.insert(index)
            if index > rows.startIndex { indices.insert(index - 1) }
            if index < rows.index(before: rows.endIndex) { indices.insert(index + 1) }
        }
        if indices.isEmpty { return Array(rows.prefix(12)) }
        return indices.sorted().prefix(12).map { rows[$0] }
    }

    private func recoveryBodyRow(
        _ row: DraftRecoveryBodyRow,
        version: RecoveryVersion,
        tint: Color
    ) -> some View {
        let block = version == .currentNote ? row.currentNote : row.exitVersion
        let isChanged = row.change != .unchanged
        return HStack(alignment: .top, spacing: 7) {
            if isChanged {
                Text(changeLabel(for: row, version: version))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12), in: Capsule())
            }
            if let block {
                Text(blockMarker(block))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(blockText(block))
                    .font(blockFont(block.kind))
                    .foregroundStyle(row.change == .unchanged ? .secondary : .primary)
                    .lineLimit(showsAllRows ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("这一版没有此段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        .background(
            isChanged ? tint.opacity(block == nil ? 0.045 : 0.09) : .clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .opacity(row.change == .unchanged ? 0.72 : 1)
    }

    private func changeLabel(
        for row: DraftRecoveryBodyRow,
        version: RecoveryVersion
    ) -> String {
        switch row.change {
        case .unchanged: "相同"
        case .modified: "已修改"
        case .onlyInCurrentNote:
            version == .currentNote ? "仅此版" : "另一版独有"
        case .onlyInExitVersion:
            version == .exitVersion ? "仅此版" : "另一版独有"
        }
    }

    private func blockText(_ block: DocumentBlock) -> String {
        let text = block.inlineContent.spans.map(\.text).joined()
        return text.isEmpty ? "（空段落）" : text
    }

    private func blockMarker(_ block: DocumentBlock) -> String {
        switch block.kind {
        case .bullet: "•"
        case .ordered: "1."
        case .task: block.taskState?.completedAt == nil ? "☐" : "☑"
        case .quote: "│"
        case .divider: "—"
        case .paragraph, .heading1, .heading2, .heading3, .code, .link: ""
        }
    }

    private func blockFont(_ kind: BlockKind) -> Font {
        switch kind {
        case .heading1: .title2.weight(.bold)
        case .heading2: .title3.weight(.semibold)
        case .heading3: .headline
        case .code: .system(.body, design: .monospaced)
        case .quote: .body.italic()
        case .paragraph, .bullet, .ordered, .task, .divider, .link: .body
        }
    }
}

/// Presentation helper that maps Store phase → sheet models without owning recovery.
@MainActor
enum DraftRecoveryPresentation {
    static func candidates(from store: WorkspaceStore) -> [DraftRecoveryCandidate] {
        if case let .needsDraftRecovery(candidates) = store.phase {
            return candidates
        }
        return []
    }

    static func statusMessage(for store: WorkspaceStore) -> String? {
        switch store.phase {
        case .needsDraftRecovery:
            return "Jelly 找到一份退出前保留的内容。对比后，选择继续使用哪一版。"
        case .reconcilingDraftRecovery, .resolvingDraftRecovery:
            return "正在保存你的选择…"
        default:
            return nil
        }
    }

    static func isResolving(_ store: WorkspaceStore) -> Bool {
        switch store.phase {
        case .reconcilingDraftRecovery, .resolvingDraftRecovery: true
        default: false
        }
    }

    static func comparison(for candidate: DraftRecoveryCandidate) -> DraftRecoveryComparison {
        guard let persisted = candidate.persisted else {
            return .init(
                changedFields: ["正文"],
                addedBodyBlocks: candidate.draft.document.blocks.count,
                removedBodyBlocks: 0,
                modifiedBodyBlocks: 0,
                bodyRows: candidate.draft.document.blocks.map {
                    .init(currentNote: nil, exitVersion: $0, change: .onlyInExitVersion)
                }
            )
        }
        var fields: [String] = []
        if persisted.title != candidate.draft.title { fields.append("标题") }
        if persisted.document != candidate.draft.document { fields.append("正文") }
        if persisted.categoryID != candidate.draft.categoryID { fields.append("分类") }
        if persisted.archivedAt != candidate.draft.archivedAt { fields.append("归档状态") }
        let bodyRows = alignedBodyRows(
            persisted: persisted.document,
            draft: candidate.draft.document
        )
        let added = bodyRows.count { $0.change == .onlyInExitVersion }
        let removed = bodyRows.count { $0.change == .onlyInCurrentNote }
        var modified = bodyRows.count { $0.change == .modified }
        if added == 0,
           removed == 0,
           modified == 0,
           persisted.document != candidate.draft.document {
            modified = 1
        }
        return .init(
            changedFields: fields,
            addedBodyBlocks: added,
            removedBodyBlocks: removed,
            modifiedBodyBlocks: modified,
            bodyRows: bodyRows
        )
    }

    private static func alignedBodyRows(
        persisted: BlockDocument,
        draft: BlockDocument
    ) -> [DraftRecoveryBodyRow] {
        let currentBlocks = persisted.blocks
        let exitBlocks = draft.blocks
        let currentIndex = Dictionary(uniqueKeysWithValues: currentBlocks.enumerated().map { ($0.element.id, $0.offset) })
        let exitIndex = Dictionary(uniqueKeysWithValues: exitBlocks.enumerated().map { ($0.element.id, $0.offset) })
        var rows: [DraftRecoveryBodyRow] = []
        var current = 0
        var exit = 0

        while current < currentBlocks.count || exit < exitBlocks.count {
            guard current < currentBlocks.count else {
                rows.append(.init(
                    currentNote: nil,
                    exitVersion: exitBlocks[exit],
                    change: .onlyInExitVersion
                ))
                exit += 1
                continue
            }
            guard exit < exitBlocks.count else {
                rows.append(.init(
                    currentNote: currentBlocks[current],
                    exitVersion: nil,
                    change: .onlyInCurrentNote
                ))
                current += 1
                continue
            }

            let currentBlock = currentBlocks[current]
            let exitBlock = exitBlocks[exit]
            if currentBlock.id == exitBlock.id {
                rows.append(.init(
                    currentNote: currentBlock,
                    exitVersion: exitBlock,
                    change: currentBlock == exitBlock ? .unchanged : .modified
                ))
                current += 1
                exit += 1
            } else if exitIndex[currentBlock.id] == nil || exitIndex[currentBlock.id, default: -1] < exit {
                rows.append(.init(
                    currentNote: currentBlock,
                    exitVersion: nil,
                    change: .onlyInCurrentNote
                ))
                current += 1
            } else if currentIndex[exitBlock.id] == nil || currentIndex[exitBlock.id, default: -1] < current {
                rows.append(.init(
                    currentNote: nil,
                    exitVersion: exitBlock,
                    change: .onlyInExitVersion
                ))
                exit += 1
            } else {
                rows.append(.init(
                    currentNote: currentBlock,
                    exitVersion: nil,
                    change: .onlyInCurrentNote
                ))
                current += 1
            }
        }
        return rows
    }

    static func replacementBlockIDs(for document: BlockDocument) -> [BlockID] {
        document.blocks.map { _ in BlockID() }
    }
}

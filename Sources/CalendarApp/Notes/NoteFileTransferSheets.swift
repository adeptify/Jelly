import SwiftUI
import WorkspaceDomain

struct NoteFileImportSheet: View {
    let plan: NoteFileImportPlan
    let onCancel: () -> Void
    let onImport: (BlockDocumentIngestMode) -> Void

    @State private var mode: BlockDocumentIngestMode

    init(
        plan: NoteFileImportPlan,
        onCancel: @escaping () -> Void,
        onImport: @escaping (BlockDocumentIngestMode) -> Void
    ) {
        self.plan = plan
        self.onCancel = onCancel
        self.onImport = onImport
        _mode = State(initialValue: plan.mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入笔记内容")
                    .font(.title2.weight(.semibold))
                Text("确认文件和导入位置后再写入；原笔记不会在这一步被静默覆盖。")
                    .foregroundStyle(.secondary)
            }

            fileSummary

            VStack(alignment: .leading, spacing: 10) {
                Text("放到哪里？")
                    .font(.headline)
                HStack(spacing: 10) {
                    modeCard(
                        .replace,
                        title: "替换当前正文",
                        detail: "标题和分类不变，正文替换为文件内容",
                        symbol: "arrow.triangle.2.circlepath"
                    )
                    modeCard(
                        .append,
                        title: "追加到正文末尾",
                        detail: "保留现有正文，把文件内容接在最后",
                        symbol: "text.append"
                    )
                }
            }

            if !plan.result.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("有些内容无法原样保留", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                    ForEach(plan.result.diagnostics, id: \.self) { message in
                        Text("• \(message)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button(mode == .replace ? "替换正文" : "追加内容") {
                    onImport(mode)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("导入笔记内容")
    }

    private var fileSummary: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: plan.format.systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 38, height: 38)
                .foregroundStyle(.tint)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(plan.format.displayName) · \(plan.result.document.blocks.count) 个内容块")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(previewText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var previewText: String {
        let text = plan.result.document.blocks
            .prefix(4)
            .map { $0.inlineContent.plainText }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return text.isEmpty ? "文件中没有可预览的文字" : text
    }

    private func modeCard(
        _ value: BlockDocumentIngestMode,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        let selected = mode == value
        return Button {
            mode = value
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.16), lineWidth: selected ? 1.5 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NoteFileExportSheet: View {
    let onCancel: () -> Void
    let onExport: (NoteFileFormat) -> Void

    @State private var format: NoteFileFormat = .markdown

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导出笔记")
                    .font(.title2.weight(.semibold))
                Text("选择用途最合适的格式。导出的内容来自当前正在编辑的版本。")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(NoteFileFormat.allCases) { candidate in
                    formatCard(candidate)
                }
            }

            Text("RTF、TXT、DOCX 和 PDF 暂不提供，避免导出后出现看似成功但格式丢失的文件。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("导出为 \(format.displayName)") {
                    onExport(format)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("导出笔记")
    }

    private func formatCard(_ candidate: NoteFileFormat) -> some View {
        let selected = format == candidate
        return Button {
            format = candidate
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: candidate.systemImage)
                        .font(.system(size: 18, weight: .medium))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                Text(candidate.displayName)
                    .font(.headline)
                Text(candidate.exportDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.16), lineWidth: selected ? 1.5 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.displayName)，\(candidate.exportDescription)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

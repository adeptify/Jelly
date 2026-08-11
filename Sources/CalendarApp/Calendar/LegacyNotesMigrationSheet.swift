import SwiftUI
import WorkspaceDomain

/// When legacy item notes are nonempty, attaching an existing primary requires
/// an explicit merge / create-new / cancel choice. The model holds the exact
/// preview IDs, source checksum and target note revision until the user acts.
struct LegacyNotesMigrationSheet: View {
    let model: CalendarNoteIntegrationModel
    let noteID: NoteID
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("旧随记转换")
                .font(.title3.weight(.semibold))
            Text("该事项仍有旧版 Markdown 随记。在关联主笔记前必须明确处理方式。")
                .foregroundStyle(.secondary)
            GroupBox("旧随记预览") {
                ScrollView {
                    Text(model.legacyMarkdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
            if let preview = model.legacyMigrationPreview,
               !preview.diagnostics.isEmpty {
                GroupBox("转换提示") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text("第 \(diagnostic.lineNumber) 行：\(diagnostic.message)")
                                .font(.caption)
                        }
                    }
                }
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("另建主笔记") {
                    Task {
                        _ = try? await model.createPrimaryNoteFromLegacyPreview()
                    }
                }
                Button("合并到所选笔记") {
                    Task {
                        _ = try? await model.mergeLegacyIntoExistingPrimary(noteID)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

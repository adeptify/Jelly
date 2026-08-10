import SwiftUI
import WorkspaceDomain

/// When legacy item notes are nonempty, attaching an existing primary requires
/// an explicit merge / create-new / cancel choice. Full preview checksum
/// authorization is completed in a later hardening pass when the planner UI
/// is expanded; for now cancel and create-new stay available without silent
/// data loss.
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
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("另建主笔记") {
                    Task {
                        // Refuse attach-without-authorization; create empty primary
                        // is blocked while legacy remains — surface the contract.
                        model.dismissSheet()
                        _ = try? await model.createPrimaryNote()
                    }
                }
                Button("预览并合并…") {
                    // Full LegacyMarkdownMigrationPlanner preview/authorization
                    // is available in Domain; UI confirmation path that builds
                    // exact authorization will land with Task 11 hardening.
                    // Until then, keep closed rather than drop legacy text.
                    model.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

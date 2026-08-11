import CalendarDomain
import SwiftUI
import WorkspaceDomain

/// Compact 笔记 section for item detail: primary first, references below.
struct CalendarNoteRelationPopover: View {
    @Bindable var model: CalendarNoteIntegrationModel
    let store: WorkspaceStore
    var onOpenNote: (NoteID) -> Void
    @State private var pendingLinkedTaskDetach: NoteID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("笔记")
                .font(.headline)

            if let primary = model.primaryNote {
                noteRow(primary, badge: "主笔记") {
                    if model.requiresTaskUnlinkBeforeDetaching(primary.id) {
                        pendingLinkedTaskDetach = primary.id
                    } else {
                        Task { _ = try? await model.detach(primary.id) }
                    }
                }
            } else {
                Text("尚未关联主笔记")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.referenceNotes.isEmpty {
                Text("参考笔记")
                    .font(.subheadline)
                ForEach(model.referenceNotes) { note in
                    noteRow(note, badge: note.archivedAt == nil ? nil : "已归档") {
                        Task { _ = try? await model.detach(note.id) }
                    }
                }
            }

            if model.hasLegacyMarkdown {
                Text("存在旧版随记正文，关联主笔记前需转换。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("转成笔记…") {
                    model.openNotePicker(isPrimary: true)
                }
            }

            HStack {
                Button("新建主笔记") {
                    Task { _ = try? await model.createPrimaryNote() }
                }
                .disabled(store.phase != .ready || model.hasLegacyMarkdown)
                Button("添加已有笔记") {
                    model.openNotePicker(isPrimary: model.primaryNote == nil)
                }
                .disabled(store.phase != .ready)
            }

            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .sheet(item: legacySheetBinding) { noteID in
            LegacyNotesMigrationSheet(
                model: model,
                noteID: noteID,
                onCancel: { model.dismissSheet() }
            )
        }
        .sheet(isPresented: notePickerPresented) {
            CalendarNotePicker(
                store: store,
                title: model.primaryNote == nil ? "选择主笔记" : "添加参考笔记"
            ) { noteID in
                Task {
                    if model.primaryNote == nil {
                        _ = try? await model.chooseExistingPrimary(noteID)
                    } else {
                        _ = try? await model.attachReference(noteID)
                        model.dismissSheet()
                    }
                }
            } onCancel: {
                model.dismissSheet()
            }
        }
        .confirmationDialog(
            "先解除待办与日历的联动？",
            isPresented: Binding(
                get: { pendingLinkedTaskDetach != nil },
                set: { if !$0 { pendingLinkedTaskDetach = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("解除联动并取消主笔记", role: .destructive) {
                guard let noteID = pendingLinkedTaskDetach else { return }
                pendingLinkedTaskDetach = nil
                Task {
                    _ = try? await model.detach(
                        noteID,
                        linkedTaskDisposition: .unlinkPreservingCompletion
                    )
                }
            }
            Button("取消", role: .cancel) { pendingLinkedTaskDetach = nil }
        } message: {
            Text("这篇主笔记里有待办与当前日历事项联动。解除后两边内容和完成状态都会保留，但之后各自独立。")
        }
    }

    private func noteRow(
        _ note: Note,
        badge: String?,
        onDetach: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "无标题" : note.title)
                    .lineLimit(1)
                if let badge {
                    Text(badge).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("打开") { onOpenNote(note.id) }
                .controlSize(.small)
            Button("取消关联", role: .destructive, action: onDetach)
                .controlSize(.small)
        }
    }

    private var legacySheetBinding: Binding<NoteID?> {
        Binding(
            get: {
                if case let .legacyNotesResolution(id) = model.presentedSheet { return id }
                return nil
            },
            set: { if $0 == nil { model.dismissSheet() } }
        )
    }

    private var notePickerPresented: Binding<Bool> {
        Binding(
            get: {
                if case .notePicker = model.presentedSheet { return true }
                return false
            },
            set: { if !$0 { model.dismissSheet() } }
        )
    }
}

extension NoteID: Identifiable {
    public var id: NoteID { self }
}

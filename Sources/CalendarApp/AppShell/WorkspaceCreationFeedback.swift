import CalendarDomain
import SwiftUI

enum WorkspaceCreationFeedback {
    static func calendar(
        title: String,
        date: CalendarDate,
        categoryName: String
    ) -> String {
        let object = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = object.isEmpty ? "未命名事项" : object
        return "已创建《\(resolvedTitle)》 · \(date.month)月\(date.day)日 · \(categoryName)"
    }

    static func note(categoryName: String) -> String {
        "已新建笔记 · \(categoryName)"
    }

    static func inspiration(text: String, categoryName: String) -> String {
        let oneLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "新灵感"
        let preview = oneLine.count > 18 ? String(oneLine.prefix(18)) + "…" : oneLine
        return "已捕获“\(preview)” · \(categoryName)"
    }

    static func isCreationUndoLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        return label.hasPrefix("已创建《")
            || label.hasPrefix("已新建笔记 · ")
            || label.hasPrefix("已捕获“")
    }
}

struct WorkspaceCreationToast: View {
    let message: String
    let onUndo: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(message, systemImage: "checkmark.circle.fill")
                .lineLimit(1)
            Button("撤销", action: onUndo)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .foregroundStyle(theme.primaryText)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(theme.subtleBorder.opacity(0.65), lineWidth: 0.5))
        .shadow(color: theme.subtleShadow.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-creation-toast")
    }
}

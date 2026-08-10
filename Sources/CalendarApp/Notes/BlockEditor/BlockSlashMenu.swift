import SwiftUI
import WorkspaceDomain

struct BlockSlashMenuState: Equatable, Sendable {
    let blockID: BlockID
    let queryRange: Range<Int>
    let query: String
    private(set) var selectedIndex: Int
    private(set) var dismissedRevision: UInt?

    static func open(blockID: BlockID, queryRange: Range<Int>, query: String, revision: UInt) -> BlockSlashMenuState {
        .init(blockID: blockID, queryRange: queryRange, query: query, selectedIndex: 0, dismissedRevision: nil)
    }

    mutating func dismiss(revision: UInt) { dismissedRevision = revision }

    mutating func moveSelection(by delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func shouldOpen(blockID: BlockID, queryRange: Range<Int>, query: String, revision: UInt) -> Bool {
        guard self.blockID == blockID, self.queryRange == queryRange, self.query == query else { return true }
        return dismissedRevision != revision
    }
}

struct BlockSlashMenu: View {
    let state: BlockSlashMenuState
    let options: [BlockKind]
    let onChoose: (BlockKind) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element) { index, kind in
                Button {
                    onChoose(kind)
                } label: {
                    HStack {
                        Text(title(for: kind))
                        Spacer()
                        if index == state.selectedIndex { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(for: kind))
                .accessibilityValue(index == state.selectedIndex ? "当前项" : "")
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("斜杠菜单")
        .onExitCommand(perform: onDismiss)
    }

    private func title(for kind: BlockKind) -> String {
        switch kind {
        case .paragraph: "正文"
        case .heading1: "一级标题"
        case .heading2: "二级标题"
        case .heading3: "三级标题"
        case .bullet: "无序列表"
        case .ordered: "有序列表"
        case .task: "待办"
        case .quote: "引用"
        case .code: "代码"
        case .divider: "分割线"
        case .link: "链接"
        }
    }
}

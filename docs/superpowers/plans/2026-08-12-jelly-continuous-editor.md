# Jelly 轻量连续编辑器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Jelly 笔记正文从“每个 Block 一个输入框”改成一个低摩擦、原生、连续的编辑表面，同时保留 Block 数据、Task Block ↔ Calendar 闭环、自动保存和恢复能力。

**Architecture:** `BlockDocument` 和 `BlockInputReducer` 继续是结构与编辑语义的唯一真相；新增纯函数投影层，把完整文档映射成一个 `NSAttributedString` 和全局 UTF-16/Block 坐标表；一个 `NSTextView` 负责光标、跨段选择、输入法和原生手势；Session 把 AppKit 事件翻译成既有 reducer command，并只投影发生变化的最小文档区间。Task Block 不新增独立 `Task` 对象：正文块承载行动内容，Calendar Item 承载时间属性，关联期间标题和完成状态原子一致。

**Tech Stack:** Swift 6.3、SwiftUI、AppKit/TextKit 1、Swift Testing、现有 `WorkspaceDomain` / `CalendarDomain` / `CalendarPersistence`。

## Global Constraints

- 正确仓库固定为 `/Users/oreal/adeptify-home/repos/Jelly`，工作分支固定为 `codex/jelly-editor-fluidity`。
- 本轮不新增独立 `Task` 聚合对象，不实现 Goal/Task 拆解、自然语言日期识别、AI 建议或新的 Block 类型。
- 数据层继续 Block 化；用户正文必须只有一个连续文字焦点域。普通 Block 不显示拖拽柄、卡片、独立边框或永久操作按钮。
- 保留现有 reducer、Markdown codec、草稿保护、恢复中心和已关联 Task 删除处置合同；迁移 UI 不重写已经验证过的领域逻辑。
- 每个行为先写失败测试，再写最小实现；每个任务完成后运行该任务列出的 focused tests，并做一次小提交。
- 不以 mock 截图、编译成功或测试全绿冒充真实产品验收。最终必须测试打包后的 `Jelly.app`。
- 所有用户可见文案和辅助功能名称使用中文；“取消关联”统一改成“解除任务联动”。

---

## Task 1: 锁定 Task Block ↔ Calendar 的领域合同

**Files:**

- Modify: `Sources/WorkspaceDomain/WorkspaceCommand.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceReducer.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceReducer+Notes.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceReducer+Relations.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceValidator.swift`
- Modify: `Sources/WorkspaceDomain/WorkspaceConsistencyIssue.swift`
- Modify: `Sources/CalendarApp/Notes/TaskBlockScheduleSheet.swift`
- Modify: `Sources/CalendarApp/Notes/TaskBlockCalendarBadge.swift`
- Modify: `Sources/CalendarApp/Notes/TaskBlockCalendarIntegration.swift`
- Modify: `Sources/CalendarPersistence/WorkspaceDocument.swift`
- Modify: `Sources/CalendarPersistence/WorkspaceDocumentCodec.swift`
- Test: `Tests/WorkspaceDomainTests/TaskBlockCalendarLinkTests.swift`
- Test: `Tests/WorkspaceDomainTests/WorkspaceReducerTests.swift`
- Test: `Tests/CalendarAppTests/TaskBlockCalendarIntegrationTests.swift`

### Contract

```swift
// No new Task aggregate.
TaskBlockState.completedAt        // completion source in the note document
CalendarItem.title               // same user-visible title while linked
CalendarItem.completedAt         // exact same timestamp while linked
CalendarItem.schedule/priority   // calendar-owned properties
```

`WorkspaceValidator` must enforce both equality rules for every live `TaskBlockCalendarLink`:

```swift
item.completedAt == block.taskState?.completedAt
item.title == block.inlineContent.plainText
```

Edits may start from either surface. The reducer must update both sides within one `WorkspaceReduction`; no UI layer may publish two independent writes and hope they converge.

### Steps

- [x] Add failing tests proving that scheduling a completed Task Block succeeds only when the new item receives the exact existing `completedAt` and exact block text.
- [x] Add failing validator tests for linked title mismatch and linked completion mismatch.
- [x] Add failing draft tests proving that editing a linked Task Block title or completion through `updateNote` atomically updates the linked Calendar Item, while changing ordinary text does not touch Calendar.
- [x] Add failing calendar-command tests proving that `.updateItem` title changes and `.setTaskCompleted` changes atomically update the linked Task Block; schedule and priority changes do not rewrite block content.
- [x] Replace `linkedTaskCompletionRequiresTaskCommand` rejection in `updateNote` with explicit linked-field propagation. Use Calendar reducers for the calendar mutation so timestamps, revision allocation and validation remain centralized.
- [x] After applying a calendar command, propagate linked title/completion into the exact source block before final workspace validation. A calendar-side title edit replaces the Task Block inline content with one plain span; this loss of inline title styling is explicit and covered by a test.
- [x] Enforce title equality in `WorkspaceValidator`; add a typed `taskTitleMismatch` validation error beside the existing completion mismatch.
- [x] Bump workspace persistence to Schema 4. Migrate linked V3 titles deterministically from the Task Block while preserving repairable relationship issues for the existing repair flow.
- [x] Change `TaskBlockScheduleSheet` so the title is not an independently editable duplicate. Show the Task Block title as the source, construct the item with that exact title, and pass `block.taskState?.completedAt` instead of hard-coded `nil`.
- [x] Keep unlink behavior unchanged at the data level: remove only `TaskBlockCalendarLink`; retain both objects, their current title/completion values, and the Calendar Item's primary Note relation.
- [x] Rename the integration undo label and UI-facing wording to “解除任务联动”.

### Focused verification

```bash
swift test --filter TaskBlockCalendarLinkTests
swift test --filter WorkspaceReducerTests
swift test --filter TaskBlockCalendarIntegrationTests
```

### Commit

```bash
git add Sources/WorkspaceDomain Sources/CalendarApp/Notes/TaskBlockScheduleSheet.swift Sources/CalendarApp/Notes/TaskBlockCalendarIntegration.swift Tests/WorkspaceDomainTests Tests/CalendarAppTests/TaskBlockCalendarIntegrationTests.swift
git commit -m "fix(tasks): unify linked task title and completion"
```

---

## Task 2: 建立完整文档的连续投影与坐标桥

**Files:**

- Create: `Sources/CalendarApp/Notes/BlockEditor/BlockDocumentTextProjection.swift`
- Create: `Sources/CalendarApp/Notes/BlockEditor/BlockDocumentProjectionDiff.swift`
- Create: `Sources/CalendarApp/Notes/BlockEditor/BlockTextStyle.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextView.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockSelectionController.swift`
- Test: `Tests/CalendarAppTests/BlockDocumentTextProjectionTests.swift`
- Test: `Tests/CalendarAppTests/BlockEditorBridgeTests.swift`

### Interface

```swift
struct BlockDocumentTextProjection: Equatable {
    struct Segment: Equatable {
        let blockID: BlockID
        let kind: BlockKind
        let contentRange: NSRange
        let displayRange: NSRange
    }

    let attributedString: NSAttributedString
    let segments: [Segment]

    init(document: BlockDocument, appearance: CalendarSemanticAppearance)
    func textPosition(atUTF16Offset offset: Int, affinity: SelectionAffinity) throws -> BlockTextPosition
    func utf16Offset(for position: BlockTextPosition) throws -> Int
    func nsRange(for selection: BlockEditorSelection) throws -> NSRange
    func selection(for range: NSRange, preserving direction: SelectionDirection,
                   typingAttributes: BlockTypingAttributes) throws -> BlockEditorSelection
}

struct BlockDocumentProjectionDiff: Equatable {
    let oldRange: NSRange
    let replacement: NSAttributedString
    let changedBlockIDs: Set<BlockID>

    static func make(from old: BlockDocumentTextProjection,
                     to new: BlockDocumentTextProjection) -> Self?
}
```

### Mapping rules

- Block 文本原样进入 projection；Block 之间只有一个结构换行符，不写回领域数据。
- 结构换行符前的插入点属于上一 Block 末尾，结构换行符后的插入点属于下一 Block 开头。
- 空段仍有独立的零长度 `contentRange`，通过相邻结构换行区分身份。
- Divider 使用带 Block 属性的 U+FFFC 展示占位符；复制纯文本时剥离该字符，领域位置始终映射为该 Divider 的 offset 0。
- 全部换算严格使用 UTF-16 ↔ grapheme 边界；组合字符、emoji、旗帜和家庭 emoji 的中间位置必须抛 typed error，不能向下取整。
- 正向与反向选区都保留 anchor/focus 方向。

### Steps

- [x] Write failing round-trip tests for one paragraph, multiple paragraphs, consecutive empty blocks, a trailing empty block, all supported Block kinds, divider, soft breaks, Chinese, combining marks and emoji.
- [x] Write failing cross-block forward/reverse selection tests, including exact copy text without internal U+FFFC.
- [x] Extract the current font, inline mark, link and paragraph-style logic from `BlockEditorTextView` into `BlockTextStyle`, then make both the legacy host and continuous projection use it during migration; do not keep two visual style sources.
- [x] Implement global selection mapping and typed failures for missing blocks, invalid offsets, integer overflow and mid-grapheme boundaries.
- [x] Implement minimal diff calculation using equal common Block prefixes/suffixes. A single-block keystroke may replace that Block's display range, not the entire document.
- [x] Add tests that a one-character edit in a 500-Block document reports exactly one changed Block and a bounded replacement range.

### Focused verification

```bash
swift test --filter BlockDocumentTextProjectionTests
swift test --filter BlockEditorBridgeTests
```

### Commit

```bash
git add Sources/CalendarApp/Notes/BlockEditor Tests/CalendarAppTests/BlockDocumentTextProjectionTests.swift Tests/CalendarAppTests/BlockEditorBridgeTests.swift
git commit -m "feat(editor): add continuous document projection"
```

---

## Task 3: 用一个原生 NSTextView 承载全部正文输入

**Files:**

- Create: `Sources/CalendarApp/Notes/BlockEditor/ContinuousBlockEditorTextView.swift`
- Create: `Sources/CalendarApp/Notes/BlockEditor/ContinuousBlockEditorRepresentable.swift`
- Create: `Sources/CalendarApp/Notes/BlockEditor/ContinuousBlockEditorHostView.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorSession.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorSelection.swift`
- Remove after migration: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextViewRepresentable.swift`
- Test: `Tests/CalendarAppTests/ContinuousBlockEditorHostTests.swift`
- Modify: `Tests/CalendarAppTests/BlockEditorUndoTests.swift`
- Modify: `Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift`

### Session boundary

```swift
@MainActor
protocol ContinuousBlockEditorHost: AnyObject {
    var textView: ContinuousBlockEditorTextView { get }
    func apply(diff: BlockDocumentProjectionDiff?,
               projection: BlockDocumentTextProjection,
               selectedRange: NSRange)
    func focus(at position: BlockTextPosition)
}

@MainActor
final class BlockEditorSession: ObservableObject {
    func attach(host: ContinuousBlockEditorHost, hostToken: UUID)
    func detach(hostToken: UUID)
    func adoptNativeSelection(_ range: NSRange, direction: SelectionDirection)
    func dispatchNativeReplacement(range: NSRange, replacement: String) throws -> Bool
    func focusDocumentStart()
    func focusDocumentEnd()
}
```

### Steps

- [x] Add a failing hosted-view test asserting that a 20-Block document creates exactly one editable `NSTextView`, one native selection and one editor undo manager.
- [x] Add failing tests for cross-three-paragraph mouse selection, left/right movement over one Block boundary, Enter split, Shift-Enter soft break, Backspace merge and deleting the last visible character.
- [x] Add failing IME tests for repeated `setMarkedText`, candidate replacement, `unmarkText`, cancel, Enter/Backspace during composition, Chinese and emoji. Candidate updates must not publish a `BlockDocument`; terminal commit must publish once and create one undo record.
- [x] Refactor the production path of `BlockEditorSession` from per-Block host leases to one document host lease. Preserve the existing reducer-consumption legality matrix, typing coalescing and session-owned undo manager; retain direct native-host seams only for isolated legacy regression tests.
- [x] Implement `ContinuousBlockEditorTextView` event routing for `insertText`, selectors, selection changes, copy/cut/paste, undo/redo and marked text. Native storage is temporary presentation during composition only; all committed text goes through `BlockInputReducer`.
- [x] Apply `BlockDocumentProjectionDiff` to `NSTextStorage` with `replaceCharacters(in:with:)`; restore only the affected attributes and selection. Do not call `setAttributedString` for an ordinary single-Block keystroke.
- [x] Make the native view vertically resize inside the existing Notes scroll surface. `ContinuousBlockEditorHostView` reports used TextKit height without creating a nested scroll view.
- [x] Replace `ForEach(session.document.blocks)` in `BlockEditorView` with one `ContinuousBlockEditorRepresentable`.
- [x] Remove ordinary Block drag handles and their drop gutters from the production UI. Keep reducer drag commands and non-UI tests because future explicit reorder work may reuse them.
- [x] Make the area below the last laid-out line focus the last editable Block; if the document ends in Divider, dispatch one Enter-equivalent to create a single trailing paragraph.
- [x] Delete the legacy per-Block production representable and update tests to assert the new one-host production path. Retain legacy native test seams plus shared style/clipboard helpers only where regression coverage still uses them.

### Focused verification

```bash
swift test --filter ContinuousBlockEditorHostTests
swift test --filter BlockEditorUndoTests
swift test --filter BlockEditorAccessibilityTests
swift test --filter BlockEditorInputTests
```

### Commit

```bash
git add Sources/CalendarApp/Notes/BlockEditor Tests/CalendarAppTests
git commit -m "refactor(editor): use one continuous native text surface"
```

---

## Task 4: 完成零摩擦新建、单一空状态和固定格式栏

**Files:**

- Create: `Sources/CalendarApp/Notes/BlockEditor/BlockFormattingBar.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/ContinuousBlockEditorTextView.swift`
- Modify: `Sources/CalendarApp/Notes/NoteEditorView.swift`
- Modify: `Sources/CalendarApp/Notes/NoteTitleTextField.swift`
- Modify: `Sources/CalendarApp/Notes/NotesSplitView.swift`
- Modify: `Sources/CalendarApp/Notes/NotesViewModel.swift`
- Test: `Tests/CalendarAppTests/NotesEditorIdentityTests.swift`
- Test: `Tests/CalendarAppTests/NotesVerticalIntegrationTests.swift`
- Test: `Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift`

### Focus contract

```swift
enum NoteInitialFocus: Equatable {
    case title
    case bodyStart
}

// New note: .title
// Inspiration-converted note with a derived title: .bodyStart
// Existing selected note: preserve session state; do not refocus on redraw.
```

### Steps

- [x] Keep `Command-N` and the Notes new button on the same `createNote()` route: create Note, mint a new editor identity, focus title, Enter focuses body start, and presentation-only placeholder text is never persisted. The command route and mounted editor identity/focus flow are covered here; the actual button press remains in the packaged GUI matrix.
- [x] Add a failing test that inspiration conversion opens the exact generated Note and focuses body when title already exists.
- [x] Extend `NoteTitleTextField` with an explicit `onReturn` callback. Return commits the title and asks the current `BlockEditorSession` to focus the body; it must not insert a title newline.
- [x] Implement one empty-document placeholder in the continuous text view. Draw “开始写点什么…” only when the complete document has no visible text and no composition; never draw it per empty Block.
- [x] Add `BlockFormattingBar` fixed to the bottom of `NoteEditorView`, outside the document layout. It is collapsible and includes paragraph/heading, bold, italic, inline code, bullet, ordered list, task, quote, divider and link using existing reducer commands.
- [x] Ensure toolbar actions preserve the current native selection and immediately restore the text view as first responder. Collapsed selection changes typing attributes; non-empty selection formats atomically.
- [x] Remove the current selection-dependent inline formatting row. Selection never causes document layout to move or reveal a floating toolbar.
- [x] Add exact Chinese accessibility labels and identifiers for every formatting action and the expand/collapse control.
- [x] Constrain content to max 720pt with at least 28pt horizontal safety margin when possible; use 16pt body text, 1.45 line-height and theme-derived warm surfaces without per-Block cards.

### Focused verification

```bash
swift test --filter NotesEditorIdentityTests
swift test --filter NotesVerticalIntegrationTests
swift test --filter BlockEditorAccessibilityTests
```

### Commit

```bash
git add Sources/CalendarApp/Notes Tests/CalendarAppTests
git commit -m "feat(editor): add zero-friction focus and fixed formatting bar"
```

---

## Task 5: 把 Task Block 做成轻量且真实可操作的正文能力

**Files:**

- Create: `Sources/CalendarApp/Notes/BlockEditor/TaskBlockCheckboxOverlay.swift`
- Create: `Sources/CalendarApp/Notes/BlockEditor/TaskBlockContextControls.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorSelection.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockInputReducer.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorSession.swift`
- Modify: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift`
- Modify: `Sources/CalendarApp/Notes/TaskBlockCalendarBadge.swift`
- Modify: `Sources/CalendarApp/Notes/TaskBlockCalendarIntegration.swift`
- Test: `Tests/CalendarAppTests/BlockEditorInputTests.swift`
- Test: `Tests/CalendarAppTests/TaskBlockCompletionPresentationTests.swift`
- Test: `Tests/CalendarAppTests/TaskBlockCalendarIntegrationTests.swift`
- Test: `Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift`

### Reducer command

```swift
enum BlockInputCommand {
    // Existing cases...
    case setTaskCompletion(blockID: BlockID, completedAt: Date?)
}

enum BlockUndoAction {
    // Existing cases...
    case taskCompletion
}
```

This command changes only the editor document and is one atomic editor undo step. Autosave then submits the draft; Task 1 ensures a linked Calendar Item changes in the same workspace reduction.

### Steps

- [x] Add failing reducer tests for completing/reopening an unlinked Task Block, rejecting a non-task target, preserving Block ID/text/indent, and one-step undo/redo.
- [x] Add failing presentation tests asserting a real semantic checkbox exists for every Task Block, ordinary paragraphs have none, and completed text has a quiet completed appearance.
- [x] Implement `setTaskCompletion` in the reducer and expose `BlockEditorSession.toggleTaskCompletion(blockID:at:)`.
- [x] Use TextKit glyph rectangles from the current projection to position real `NSButton` checkboxes in a narrow pass-through overlay. The overlay exists only for Task Blocks and returns text focus after invocation.
- [x] Give each checkbox label/value/action: “完成待办/重开待办”, “未完成/已完成”, and a stable identifier containing the Block ID. Accessibility Tree can locate and invoke it.
- [x] Keep the calendar controls contextual to the Task Block containing the caret instead of showing a permanent duplicate task row.
- [x] Unlinked controls: checkbox plus “安排到日历”. Linked controls: checkbox, a quiet date badge/open action, and “解除任务联动”.
- [x] Route checkbox clicks through the editor reducer for both linked and unlinked blocks; do not require a Calendar link merely to complete a local Task Block.
- [x] Confirm schedule creation copies exact text and current completion. Confirm opening targets the exact Calendar Item contract. Confirm unlink retains both objects and the source Note relationship.
- [x] Preserve the existing confirmation dialog when deleting or converting a linked Task Block: keep Calendar Item, delete both, or cancel and restore the editor document.

### Focused verification

```bash
swift test --filter BlockEditorInputTests
swift test --filter TaskBlockCompletionPresentationTests
swift test --filter TaskBlockCalendarIntegrationTests
swift test --filter BlockEditorAccessibilityTests
```

### Commit

```bash
git add Sources/CalendarApp/Notes Tests/CalendarAppTests
git commit -m "feat(tasks): make task blocks directly actionable"
```

---

## Task 6: 守住自动保存、恢复、搜索与 Markdown 回归

**Files:**

- Modify only if tests expose a real integration gap: `Sources/CalendarApp/Notes/NoteAutosaveCoordinator.swift`
- Modify only if tests expose a real integration gap: `Sources/CalendarApp/Notes/NoteEditorView.swift`
- Modify only if tests expose a real integration gap: `Sources/CalendarApp/Notes/NotesViewModel.swift`
- Test: `Tests/CalendarAppTests/NoteAutosaveCoordinatorTests.swift`
- Test: `Tests/CalendarAppTests/NotesVerticalIntegrationTests.swift`
- Test: `Tests/WorkspaceDomainTests/BlockMarkdownCodecTests.swift`
- Test: `Tests/CalendarPersistenceTests/WorkspaceRepositoryTests.swift`

### Steps

- [ ] Add integration coverage for typing then immediately switching to Calendar, selecting another Note, closing the window and quitting. Each path must terminally finalize IME, protect the latest draft and use the existing close barrier.
- [ ] Add recovery coverage for a protected continuous-editor document containing soft breaks, inline formatting, empty blocks and linked/unlinked Task Blocks.
- [ ] Add failure coverage showing a main-save failure keeps journal recovery evidence and exposes a clear Chinese status; normal successful saves remain visually quiet.
- [ ] Run search tests for Chinese title, English/Chinese body and URL after the projection migration; search must read domain data, never attributed presentation text.
- [ ] Run Markdown round-trip tests for every supported Block kind, inline marks, checked tasks, soft breaks and unsupported-structure diagnostics.
- [ ] Change production code only for failures caused by the new host boundary. Do not simplify or replace the typed draft/recovery state machine.

### Focused verification

```bash
swift test --filter NoteAutosaveCoordinatorTests
swift test --filter NotesVerticalIntegrationTests
swift test --filter BlockMarkdownCodecTests
swift test --filter WorkspaceRepositoryTests
```

### Commit

```bash
git add Sources/CalendarApp/Notes Tests/CalendarAppTests Tests/WorkspaceDomainTests Tests/CalendarPersistenceTests
git commit -m "test(editor): preserve autosave recovery and markdown contracts"
```

---

## Task 7: 建立可重复的性能、视觉和辅助功能门禁

**Files:**

- Create: `Sources/CalendarApp/Notes/BlockEditor/BlockEditorPerformanceProbe.swift`
- Create: `Tests/CalendarAppTests/BlockEditorPerformanceTests.swift`
- Create: `Tests/CalendarAppTests/BlockEditorVisualContractTests.swift`
- Modify: `Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift`
- Create: `Scripts/test-editor-performance.sh`
- Create: `docs/acceptance/editor-performance-method.md`

### Fixed datasets and gates

| Dataset | Size | Reducer p95 | Projection p95 | Key-to-visible p95 / max | Open |
|---|---:|---:|---:|---:|---:|
| Daily | 20 Blocks / 2,000 chars | 2ms | 8ms | 33ms / 100ms | 150ms |
| Long | 200 Blocks / 20,000 chars | 4ms | 12ms | 50ms / 100ms | 300ms |
| Stress | 500 Blocks / 50,000 chars | 8ms | 16ms | 75ms / 150ms | 600ms |

### Steps

- [ ] Build deterministic fixtures for all three datasets with mixed Chinese, English, emoji, headings, lists, tasks, quotes and code.
- [ ] Add reducer and projection benchmarks with 10 warmups and at least 100 measured edits. Compute p95 from sorted monotonic-clock samples and fail with the measured distribution in the error message.
- [ ] Add a hosted AppKit benchmark that measures native event dispatch through TextKit layout completion. Record p95, max and open time; assert the table above.
- [ ] Add an instrumentation assertion that 200 sequential ordinary characters do not call full-document `setAttributedString` per key and do not report more than the changed Block in the projection diff.
- [ ] Make `Scripts/test-editor-performance.sh` build release test artifacts, run only the performance suite, and print a compact table suitable for acceptance evidence.
- [ ] Add visual contract tests for one placeholder only, max content width, no ordinary drag handles, fixed toolbar outside document flow, Task-only checkbox gutter and readable semantic colors in light/dark appearance.
- [ ] Add accessibility-tree tests proving there is one body text area, no per-Block Tab stops, every visible icon button has a Chinese name, Task checkboxes expose status/action, and reduced-motion mode does not rely on positional animation.
- [ ] Document machine model, macOS version, build configuration, sampling method and cold/warm distinction in `docs/acceptance/editor-performance-method.md`; thresholds without this context are not accepted as evidence.

### Focused verification

```bash
swift test --filter BlockEditorPerformanceTests
swift test --filter BlockEditorVisualContractTests
swift test --filter BlockEditorAccessibilityTests
Scripts/test-editor-performance.sh
```

### Commit

```bash
git add Sources/CalendarApp/Notes/BlockEditor Tests/CalendarAppTests Scripts/test-editor-performance.sh docs/acceptance/editor-performance-method.md
git commit -m "test(editor): add performance visual and accessibility gates"
```

---

## Task 8: 全量回归、打包和真实产品验收

**Files:**

- Create: `docs/acceptance/2026-08-12-editor-real-app-acceptance.md`
- Add screenshots under: `docs/acceptance/assets/2026-08-12-editor/`
- Modify only for verified defects: files owned by Tasks 1–7

### Automated gates

- [ ] Run all focused suites again after a clean build.
- [ ] Run the full debug suite and release build:

```bash
swift test
swift build -c release --product PersonalCalendar
```

- [ ] Build the distributable app and verify its executable/signature using the existing script:

```bash
Scripts/build-app.sh
```

- [ ] Record exact commit, app version/build number, artifact checksum and test counts in the acceptance document.

### Real packaged-App flows

- [ ] Launch the newly packaged `Jelly.app`, not an older installed copy. Record the executable path and About/version evidence.
- [ ] Keyboard-only new-note path: `Command-2 → Command-N → title → Enter → body`; repeat for two blank notes and verify no state/undo leakage.
- [ ] Empty and continuous editing: one placeholder, click below content, type at least 20 mixed-language paragraphs, Enter/Shift-Enter/Backspace, arrows across boundaries, forward/reverse cross-three-paragraph selection, copy/cut/paste, undo/redo.
- [ ] System Chinese Pinyin: enter at least ten sentences with candidate changes, Enter/Backspace during composition, emoji and cancellation; verify no duplicates, loss or caret jump.
- [ ] Formatting: Markdown prefixes and every fixed-toolbar action; verify toolbar expand/collapse does not move content, steal selection or scroll away from caret.
- [ ] Task Block: create explicitly, complete/reopen before scheduling, schedule while completed, open exact Calendar Item, edit title from both Notes and Calendar, toggle completion from both surfaces, change date without rewriting text, unlink, then confirm both objects and source Note relation remain.
- [ ] Deletion safety: delete/convert a linked Task Block and exercise keep item, delete both and cancel paths.
- [ ] Persistence: type and immediately switch module, select another Note, close window and quit; relaunch after each path and confirm content. Exercise a controlled save-failure/recovery fixture without altering user data.
- [ ] Visual: capture light/dark, 360–500pt narrow width, normal split view and full screen for empty, long, cross-selection, toolbar, Task and save-error states. Check no overlap, clipping, horizontal scroll, duplicate placeholder or competing visual center.
- [ ] Accessibility/Computer Use: locate and invoke new note, title, body, format controls, Task checkbox, schedule, open item and unlink by semantic names rather than guessed coordinates.
- [ ] Performance: run the three fixtures in the packaged app, scroll to the middle and type; attach the measured table and state any missed gate truthfully.

### Defect loop

- [ ] For every defect found in packaged-App testing, first add the smallest failing automated regression where feasible, implement the fix, rerun its focused suite, rebuild the package and replay the exact failed product flow.
- [ ] Do not mark a flow passed based on source tests after its packaged build failed; only the rebuilt artifact can close it.

### Final verification

```bash
git status --short
git diff --check
swift test
swift build -c release --product PersonalCalendar
Scripts/build-app.sh
```

### Commit

```bash
git add docs/acceptance Sources Tests Scripts
git commit -m "test(editor): record packaged app acceptance"
git push origin codex/jelly-editor-fluidity
```

---

## Spec Coverage Map

| Spec | Implementation tasks |
|---|---|
| F1 zero-friction create/focus | Task 4, Task 8 |
| F2 single empty state/clickable page | Task 2–4, Task 8 |
| F3 continuous input | Task 2–3, Task 8 |
| F4 selection/clipboard/undo | Task 2–3, Task 8 |
| F5 IME/performance | Task 3, Task 7–8 |
| F6 limited structure | Task 2–4, Task 6 |
| F7 one surface/fixed toolbar | Task 3–4 |
| F8 visual rhythm/theme | Task 2, Task 4, Task 7–8 |
| F9 Task Block action loop | Task 1, Task 5, Task 8 |
| F10 autosave/recovery | Task 6, Task 8 |
| F11 search/archive/Markdown | Task 6 |
| F12 keyboard/accessibility | Task 3–5, Task 7–8 |

## Final Non-goals Audit

Before declaring the goal complete, confirm the diff contains none of the following:

- `struct Task` or another new task aggregate/store/repository.
- Goal hierarchy, subtask graph or task-center navigation.
- Natural-language date/task parsing, AI suggestion UI or model calls.
- New Block kinds, table/database/collaboration features.
- Ordinary Block drag handles, selection floating toolbar or permanent per-Block action columns.
- Placeholder text persisted into `BlockDocument`.

Run:

```bash
rg -n "struct Task|class Task|GoalTask|NLP|自然语言|AI 建议|selection toolbar|drag handle" Sources Tests
git diff --check
```

Any match must be explained as an existing allowed symbol or removed before completion.

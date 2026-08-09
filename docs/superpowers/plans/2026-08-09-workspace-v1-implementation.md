# Jelly Workspace V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 在不回退现有月历能力、真实数据安全和恢复能力的前提下，将 Jelly 升级为以 WorkspaceState 为唯一真相源的 macOS 工作空间，交付可独立使用的日历、Block 笔记、日历—笔记关系、待办 Block 联动与灵感收件箱。

**Architecture:** 保留 CalendarDomain 作为稳定日历子图；新增 WorkspaceDomain 承载 Note、Inspiration、BlockDocument、跨对象关系与唯一 WorkspaceReducer；CalendarPersistence 升级为唯一 Workspace V3 repository；CalendarApp 只持有一个 WorkspaceStore。所有业务变更先基于最新状态归约、全局校验、单次原子持久化，再发布 UI；Draft Journal 仅是恢复 sidecar，搜索仅是可重建投影。

**Tech Stack:** Swift 6.3、SwiftUI、AppKit NSTextView、Observation、Swift Testing、Foundation JSON/CryptoKit、macOS 14+、现有 shell 构建与打包脚本。

## Global Constraints

- 实施依据是 docs/superpowers/specs/2026-08-09-workspace-notes-inspiration-design.md；若计划与规格冲突，以已确认规格为准并先修订计划。
- 用户已授权连续执行。任务间不询问是否继续；只有真实 blocker、必须由用户决定的产品冲突或完整 Goal 全部验收通过才停。
- 每个实现任务采用 RED → GREEN → refactor → focused tests → fresh Sol xhigh review → finding fix → scoped re-review；implementer 和 reviewer 不能是同一 agent。
- 每条命令必须在 /Users/oreal/adeptify-home/repos/Jelly 执行。不得修改、覆盖或删除用户真实数据做验收。
- 所有文件修改使用 apply_patch；不得通过 shell 重定向、cat 或 Python 写文件。
- 任何子图都不得独立写盘：Calendar、Note、Inspiration、分类、备份和恢复只能通过 WorkspaceStore → JSONWorkspaceRepository。
- 现有 calendar-v1.json 文件名保持不变；它是兼容主路径，不新建第二个业务主文件。
- V3 第一次覆盖 V1/V2 前必须保存原始字节、校验 SHA-256、原子登记 RecoveryManifest，并重新确认主文件 hash 未变化。任一步失败都不得覆盖主文件。
- Workspace revision 与 Note revision 单调递增。撤销是新的持久事务，不能恢复旧 revision。
- BlockEditor 有焦点时 Command-Z/Shift-Command-Z 只进入编辑会话 UndoManager；其他场景才进入 Workspace undo/redo。
- WorkspaceStore 使用单写事务队列；任何 UI 命令和自动保存都在出队时对最新状态归约，不能以过期 WorkspaceState 覆盖新状态。
- 旧 MarkdownNotesEditor 与 MarkdownRichTextCodec 只服务日历旧随记。新 BlockMarkdownCodec 必须位于 WorkspaceDomain，且只依赖 Foundation。
- 未形成真实闭环的 Notes/Inspiration 路由不显示为可点击空 Tab。
- 第一阶段不实现 AI、文件上传、全文/音视频提取、知识库、云同步、移动端和全局捕获。
- 每个 task 的最后一步提交该 task 的完整闭环；push 由主 Agent 在 review 通过后执行并核对远端 SHA。

## Module and Ownership Contract

~~~text
CalendarDomain
      ↑
WorkspaceDomain
      ↑             ↑
CalendarPersistence │
      ↑             │
       CalendarApp ─┘
~~~

- WorkspaceDomain → CalendarDomain。
- CalendarPersistence → WorkspaceDomain + CalendarDomain；它仍直接读取 V1/V2 日历 DTO。
- CalendarApp → WorkspaceDomain + CalendarDomain + CalendarPersistence。
- CalendarState 继续拥有 categories、items、recurrence、uncategorizedID；WorkspaceState 用 calendar 字段包含它。
- WorkspaceState 直接拥有 notes、inspirations、calendarNoteRelations、taskBlockLinks、inspirationNoteLinks、revision。
- 分类唯一权威位置仍是 workspace.calendar.categories；只有 WorkspaceCommand 的分类命令可以修改。
- CalendarStore 与 CalendarRepository 在单 Store 切换任务内退役；不得与 WorkspaceStore 并存。

## Persistence and Revision Contract

~~~swift
public struct WorkspaceLoadProvenance: Equatable, Sendable {
    public let sourceSchema: Int
    public let sourceBytesSHA256: String
    public let sourceByteCount: Int
}

public struct WorkspaceLoadResult: Equatable, Sendable {
    public let state: WorkspaceState
    public let provenance: WorkspaceLoadProvenance
    public let consistencyIssues: [WorkspaceConsistencyIssue]
}

public struct PersistedDraftReceipt: Equatable, Codable, Sendable {
    public let noteID: NoteID
    public let draftGeneration: UInt64
    public let noteSnapshotChecksum: String
    public let persistedNoteRevision: Int64
}

public struct WorkspaceSaveReceipt: Equatable, Sendable {
    public let workspaceRevision: Int64
    public let persistedDraft: PersistedDraftReceipt?
}

private struct LoadedSource: Sendable {
    let rawData: Data
    let provenance: WorkspaceLoadProvenance
}
~~~

第一次 V3 保存必须在同一个 JSONWorkspaceRepository actor 中严格执行：

~~~text
load 原始字节并保留 source schema/hash
→ 内存迁移为 WorkspaceState
→ WorkspaceValidator
→ 保存字节精确快照
→ 重新读取快照并校验 hash
→ 原子写 RecoveryManifest
→ 重新读取主文件并确认仍为 load hash
→ 编码 V3 并原子替换主文件
→ 返回 WorkspaceSaveReceipt
~~~

若源是已登记的 V3，后续保存只走验证、编码、原子替换和 receipt；若主文件在 load 后被外部修改，返回 sourceChanged 并保持当前文件。

## Transaction, Undo, and Journal Contract

~~~swift
public enum WorkspaceTransaction {
    case command(WorkspaceCommand, undoLabel: String?)
    case noteDraft(NoteDraftSubmission)
    case restore(WorkspaceRestoreRequest)
    case undo
    case redo
}

@MainActor
@Observable final class WorkspaceStore {
    private(set) var state: WorkspaceState
    var calendarState: CalendarState { state.calendar }

    func send(_ command: WorkspaceCommand, undoLabel: String?) async throws
    func sendCalendar(_ command: CalendarCommand, undoLabel: String?) async throws
    func submitDraft(_ submission: NoteDraftSubmission) async throws
    func restore(_ request: WorkspaceRestoreRequest) async throws
    func undo() async throws
    func redo() async throws
}
~~~

- send、sendCalendar、submitDraft、restore、undo、redo 只入队，不因上一条正在保存而拒绝。
- drain 每次取一条，在执行时读取最新 state，构造 candidate，WorkspaceValidator 校验，repository.save 成功后才发布。
- Note draft 只携带 noteID、draftGeneration、snapshot 和 checksum，不携带整个 WorkspaceState。
- generation 5 的 receipt 到达时若 Journal 已是 generation 6，不能清理 generation 6。
- Journal 清理失败不回滚已成功的主保存；保留可识别的已持久 receipt，启动时按 receipt 精确消解。
- UndoRecord 保存业务内容前后态；undo/redo 恢复业务值后，workspace.revision = current + 1，受影响 Note revision = 当前该 Note revision + 1。

## Task 1: Add WorkspaceDomain and Lock Core Models

**Files**

- Modify: Package.swift
- Create: Sources/WorkspaceDomain/WorkspaceIDs.swift
- Create: Sources/WorkspaceDomain/WorkspaceState.swift
- Create: Sources/WorkspaceDomain/Note.swift
- Create: Sources/WorkspaceDomain/Inspiration.swift
- Create: Sources/WorkspaceDomain/BlockDocument.swift
- Create: Sources/WorkspaceDomain/BlockDocumentValidator.swift
- Create: Sources/WorkspaceDomain/WorkspaceValidator.swift
- Create: Sources/WorkspaceDomain/WorkspaceChecksum.swift
- Create: Sources/WorkspaceDomain/DraftContracts.swift
- Create: Sources/WorkspaceDomain/WorkspaceConsistencyIssue.swift
- Create: Sources/WorkspaceDomain/CalendarNoteRelations.swift
- Create: Sources/WorkspaceDomain/TaskBlockCalendarLink.swift
- Create: Sources/WorkspaceDomain/InspirationNoteLink.swift
- Create: Tests/WorkspaceDomainTests/WorkspaceModelTests.swift
- Create: Tests/WorkspaceDomainTests/BlockDocumentValidatorTests.swift

**Produces:** Stable typed IDs, versioned BlockDocument, Note/Inspiration lifecycle models, relation/link storage models, WorkspaceState V3 in-memory root, deterministic normalized checksum input, and full graph validation entry point.

**Consumes:** CalendarDomain.CalendarState and CalendarStateValidator.

- [x] Add the WorkspaceDomain product/target and WorkspaceDomainTests target; update persistence/app test dependencies exactly as defined in the module contract.

~~~swift
.library(name: "WorkspaceDomain", targets: ["WorkspaceDomain"])

.target(
    name: "WorkspaceDomain",
    dependencies: ["CalendarDomain"]
)
~~~

- [x] Write model tests proving stable Codable round trips, archivedAt lifecycle, task completedAt payload, input/resolved inspiration enums, and WorkspaceState preserving the exact CalendarState.

~~~swift
@Test func workspaceRoundTripPreservesCalendarAndStableIDs() throws {
    let workspace = WorkspaceFixtures.workspaceWithEveryBlockType()
    let data = try JSONEncoder.workspaceDeterministic.encode(workspace)
    let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
    #expect(decoded == workspace)
    #expect(decoded.calendar == workspace.calendar)
}

@Test func taskCompletionStoresOneTimestamp() throws {
    let completedAt = Date(timeIntervalSince1970: 1_786_220_400)
    let block = try DocumentBlock.task(
        id: BlockID(),
        text: "写方案",
        indentLevel: 0,
        completedAt: completedAt
    )
    #expect(block.taskState?.completedAt == completedAt)
}
~~~

- [x] Run RED and confirm both filters fail because the target/types do not exist.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceModelTests
./Scripts/test.sh --filter WorkspaceDomainTests.BlockDocumentValidatorTests
~~~

- [x] Implement typed IDs and exact model enums.

~~~swift
public struct NoteID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum CaptureInputKind: String, Codable, Sendable {
    case text
    case url
    case file
}

public enum ResolvedSourceKind: String, Codable, Sendable {
    case plainText, article, socialPost, video, audio, image, document, unknown
}

public enum BlockKind: String, Codable, Sendable {
    case paragraph, heading1, heading2, heading3
    case bullet, ordered, task, quote, code, divider, link
}

public struct InlineContent: Codable, Equatable, Sendable {
    public var spans: [InlineSpan]
}

public struct InlineSpan: Codable, Equatable, Sendable {
    public var text: String
    public var marks: Set<InlineMark>
    public var linkURL: URL?
}

public enum InlineMark: String, Codable, Hashable, Sendable {
    case bold
    case italic
    case code
}

public struct NoteDraftSubmission: Equatable, Sendable {
    public let noteID: NoteID
    public let editSessionID: UUID
    public let baseSnapshot: Note
    public let baseNoteRevision: Int64
    public let baseNoteSnapshotChecksum: String
    public let baseLinkedTaskBlockLinks: Set<TaskBlockCalendarLink>
    public let draftGeneration: UInt64
    public let snapshot: Note
    public let noteSnapshotChecksum: String
    public let modifiedFields: Set<NoteDraftField>
    public let linkedBlockDeletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition]
}

public enum NoteDraftField: String, Codable, Hashable, Sendable {
    case title
    case document
    case categoryID
    case archivedAt
}

public enum LinkedTaskBlockDeletionDisposition: String, Codable, Sendable {
    case keepCalendarItem
    case deleteCalendarItem
}

public struct PersistableDraftContext: Equatable, Sendable {
    public let noteID: NoteID
    public let draftGeneration: UInt64
    public let noteSnapshotChecksum: String
}

public struct Inspiration: Identifiable, Codable, Equatable, Sendable {
    public let id: InspirationID
    public let inputKind: CaptureInputKind
    public var rawText: String?
    public var rawURL: URL?
    public var rawFile: FileReference?
    public var resolvedSourceKind: ResolvedSourceKind
    public var resolvedMetadata: SourceMetadata?
    public var categoryID: UUID
    public var lifecycle: InspirationLifecycle
    public var createdAt: Date
    public var updatedAt: Date
}

public struct FileReference: Codable, Equatable, Sendable {
    public let bookmarkData: Data
    public let displayName: String
}

public struct SourceMetadata: Codable, Equatable, Sendable {
    public var title: String?
    public var siteName: String?
    public var domain: String?
    public var thumbnailURL: URL?
    public var fetchStatus: MetadataFetchStatus
}
~~~

- [x] Implement BlockDocumentValidator with explicit errors for duplicate block IDs, unsupported schema, indent outside 0...3, orphaned nested list/task blocks, task payload on non-task block, missing task payload on task block, non-list indent, divider carrying text, and invalid link URL.

~~~swift
public enum BlockDocumentValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case duplicateBlockID(BlockID)
    case invalidIndent(BlockID, Int)
    case orphanedIndent(BlockID, Int)
    case missingTaskState(BlockID)
    case unexpectedTaskState(BlockID)
    case dividerHasContent(BlockID)
    case invalidLink(BlockID)
}
~~~

- [x] Implement WorkspaceChecksum as a deterministic normalized representation over NoteID, title, BlockDocument, categoryID and archivedAt; prove dictionary order and encoder formatting do not change the checksum.
- [x] Define the Codable storage shapes for CalendarNoteRelationGraph, TaskBlockCalendarLink and InspirationNoteLink so WorkspaceState compiles as the complete V3 root. Task 3 adds recurrence resolution/migration behavior; Task 4 adds transactional behavior.
- [x] Implement WorkspaceValidator as one public validation entry point that validates CalendarState, categories, Notes, Inspirations, relation endpoints, tombstones, task links, primary-note uniqueness and primary-vs-reference disjointness. Task 3 extends this same validator with effective occurrence resolution and the rule that an effective primary Note cannot coexist with nonempty legacy Markdown in the same item/series/occurrence scope; no task adds a bypass validator.
- [x] Run GREEN, then the pre-existing CalendarDomain suite.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceModelTests
./Scripts/test.sh --filter WorkspaceDomainTests.BlockDocumentValidatorTests
./Scripts/test.sh --filter CalendarDomainTests
git diff --check
~~~

- [x] Commit.

~~~zsh
git add Package.swift Sources/WorkspaceDomain Tests/WorkspaceDomainTests
git commit -m "feat(workspace): 建立工作空间领域模型与校验"
~~~

## Task 2: Implement the Pure Block Markdown Codec

**Files**

- Create: Sources/WorkspaceDomain/BlockMarkdownCodec.swift
- Create: Tests/WorkspaceDomainTests/BlockMarkdownCodecTests.swift
- Modify: Sources/WorkspaceDomain/BlockDocument.swift
- Modify: Sources/WorkspaceDomain/BlockDocumentValidator.swift
- Modify: Sources/WorkspaceDomain/WorkspaceChecksum.swift
- Modify: Tests/WorkspaceDomainTests/WorkspaceModelTests.swift
- Modify: Tests/WorkspaceDomainTests/BlockDocumentValidatorTests.swift
- Read only: Sources/CalendarApp/Editing/MarkdownRichTextCodec.swift
- Read only: Tests/CalendarAppTests/MarkdownRichTextCodecTests.swift

**Produces:** Foundation-only import/export for paragraph, H1-H3, bullet, ordered, task, quote, fenced code, divider, link, inline emphasis and soft line breaks.

**Consumes:** Task 1 BlockDocument types and validator. The AppKit legacy codec is a fixture source only, never a dependency.

**Preflight contract amendment:** `DocumentBlock` persists the complete fenced-code info string as `codeInfoString: String? = nil`; a first-token language is only a derived projection, never the stored truth. Missing legacy JSON decodes to `nil`, and `WorkspaceChecksum` includes this field. Non-code blocks require `nil`. Code blocks accept `nil` or a canonical nonempty string with leading/trailing ASCII space/tab removed; CR, LF and NUL are invalid, while internal spaces, tabs, punctuation and backticks are preserved. When an info string contains a backtick, export uses a tilde fence; otherwise export chooses a backtick or tilde fence longer than every matching delimiter run in the source, so complete info metadata and code text round-trip without loss.

**Checked-task import contract:** Markdown preserves checked/unchecked state but intentionally omits the exact `completedAt`. `importMarkdown` therefore requires one explicit `checkedTaskCompletedAt: Date`; every `[x]` in that import uses the same injected value and every `[ ]` uses `nil`. The codec never calls `Date()`, invents a sentinel, or mutates revisions. Exporting an arbitrary completed timestamp and reimporting it preserves completion semantics but replaces the timestamp with the injected value, so the exact `WorkspaceChecksum` changes. Migration/retry callers must capture one stable operation time and reuse it.

**Continuation boundary amendment:** canonical export reserves the case-sensitive controls `<!--jelly:continue-soft:v1-->` and `<!--jelly:continue-hard:v1-->`. For paragraph, H1–H3, bullet, ordered, task, quote and link content, a normal internal LF emits soft; semantic `"  \n"` removes those two spaces and emits hard. Task 2R's logical-EOL grammar below supersedes the former token-at-physical-suffix rule. Tolerant external Markdown without manifests may still import the legacy token-at-physical-EOL form, but canonical export never emits that older form. The lexer consumes another physical line only from an active continuation event and never guesses from the next line. Malformed or escaped controls remain verbatim and emit diagnostics. Without an active continuation, ATX heading/list/task end on the current line, paragraph follows Markdown paragraph aggregation, quote consumes only `>` lines, and a standalone multiline link uses a bracket/escape-aware scanner. Blank lines end a block unless the preceding active continuation explicitly includes that blank content line.

**Task 2R breaker contract — span-aware inline serialization:** the five-round patch loop is retired. Replace the inline String post-processor with one shared lexer/serializer. Canonical Markdown additionally reserves `<!--jelly:span:v1;m=<marks>;u=<url>-->`, where marks use fixed `b,c,i` order or `~`, and URL is `~` or canonical unpadded base64url of `URL.absoluteString` UTF-8. Every `InlineSpan` emits exactly one manifest after its complete wrapper; an attribute-bearing empty span has no visible wrapper and its manifest is the authoritative marks/linkURL encoding. `InlineContent(spans: [])` emits the in-payload sentinel `<!--jelly:spans:v1;n=0-->`. A `.link` block begins with `<!--jelly:block:link:v1-->`. This preserves exact adjacent/equal/empty span segmentation, zero-span content, mixed URL/nil URL spans and block kind without changing `InlineContent` equality or `WorkspaceChecksum`.

Wrapper order is fixed as link outer → bold/italic → code inner → payload → code close → bold/italic close → link close → span manifest. A continuation token belongs to the span containing the LF and is emitted inside every active wrapper. If the same span continues after the LF, logical EOL is `token + physical LF` while that span's wrapper/lexer state remains open and no manifest is emitted yet. If the LF ends the current span, logical EOL is `token + legal LIFO closers + current-span manifest + physical LF/EOF`. The lexer, not the block scanner, validates both branches. Per span, LF preceded in that same span by at least two ASCII spaces emits hard after removing exactly the last two spaces; all earlier spaces/tabs remain. Every other LF emits soft. Spaces and LF split across spans remain soft and retain their original spans. Terminal LF remains in its marked/link span; terminal empty spans are preserved by manifests. Do not trim terminal space/tab: the manifest prevents physical trailing whitespace.

All Jelly controls share parity rules. Plain Markdown escape maps `k` literal backslashes before an active control to `2k` and before a literal control to `2k+1`. Inline-code raw context applies that same reversible `k → 2k` / `k → 2k+1` mapping itself. The importer recognizes controls before Markdown unescape and restores the original run. Malformed control prefixes remain verbatim and add line diagnostics.

The shared lexer state covers plain/escape, code delimiter length, emphasis stack, link label/destination, Jelly control and after-boundary legal suffix. It emits text, soft/hard boundary, span manifest and physical-line events. Code treats everything except its matching delimiter and Jelly controls as raw. For a nonempty span, manifest marks/URL/base64url and visible wrapper must agree; a mismatch never overwrites visible content and instead remains literal with a diagnostic. For an empty span, the manifest is authoritative because no visible wrapper exists. Manifest mode restores exact spans; ordinary external Markdown without manifests uses the tolerant canonical fallback. Block scanner, multiline link handling and inline parser must call this one control lexer and may not retain duplicate token/parity algorithms.

Code and divider use canonical domain shapes instead of invisible metadata inside their Markdown bodies. Validator adds one invariant: a `.code` block has exactly one unmarked, unlinked span; a `.divider` has exactly one empty, unmarked, unlinked span. Existing V3 data has not shipped; Task 2R updates fixtures/import paths before the first V3 writer. Code text stays entirely inside its fence, divider stays `---`, and neither emits span manifests. Every other block kind uses manifests/sentinel as defined above.

Delete or fully replace the old inline layer: `ProseInlineExport`, `exportInline`, `exportProseInline`, `exportProseText`, `exportProseCodeText`, `terminalContinuationBoundary`, `removingTerminalContinuationBoundary`, `canonicalizeProseTrailingWhitespace`, `parseInline`, `parseInlineMarkdown`, `parseInlineLinkLabel`, `decodeContinuationBoundaries`, `trailingContinuationBoundary`, `removeTrailingContinuationBoundary`, `appendMalformedContinuationDiagnostic`, `append(_:to:)`, the old `unescapedDelimiterIndex`, and standalone-link token/parity branches. Public codec API, BlockDocument data shape and checksum remain unchanged; only the code/divider validator invariants above are added.

- [x] Write table-driven round-trip tests for every block kind, 0...3 indentation, checked and unchecked tasks with completedAt intentionally omitted from Markdown export, Chinese text, inline links, fenced code and escaped marker characters. Lock old JSON without `codeInfoString`, `nil`/`swift`/`swift linenums=1`, non-code rejection, whitespace canonicalization, CR/LF/NUL rejection, backtick-bearing info strings, longer delimiter runs, checksum sensitivity and full Markdown → model → Markdown → model info-string preservation. Use a fixed injected completion time for equality fixtures; separately prove multiple `[x]` share it, `[ ]` remains `nil`, and reimporting a different original completion time preserves the boolean state while replacing the timestamp and changing checksum. For continuation boundaries, exercise all prose kinds with soft/hard/chained/EOF breaks, literal token and 0/1/2/3 backslash parity; H1–H3/bullet/ordered/task/link followed without a marker by bare paragraph, every supported block marker, single/multiline link, unsupported raw text and blank+paragraph; and list/task indent 0...3 sibling/child/parent transitions. Explicitly lock `# 标题\n正文` as heading + paragraph and `# 标题\n[A\nB](URL)` as heading + multiline link, while marked continuation lines starting with any block marker remain content. All cases use public import/export plus validator and preserve unsupported raw characters with diagnostics.

- [x] Before Task 2R production edits, add public RED fixtures for code/bold/italic/bold+italic/code+bold+italic with internal and terminal LF, with and without linkURL; inline-code active/literal control after 0/1/2/3 backslashes; span-owned hard/soft across same and split spans; adjacent equal spans, mixed URL/nil spans, zero spans, single and multiple attribute-bearing empty spans; terminal LF followed by empty spans; terminal plain space/tab; multi-span `.link` blocks; literal/malformed manifests; both internal-LF and span-terminal-LF grammar branches; and code/divider rejection of every noncanonical span shape. Assert exact `DocumentBlock` equality, validator success, no physical trailing whitespace/LF, and diagnostics/raw preservation for invalid controls.

~~~swift
@Test(arguments: BlockMarkdownFixture.all)
func roundTripPreservesSupportedStructure(_ fixture: BlockMarkdownFixture) throws {
    let imported = try BlockMarkdownCodec.importMarkdown(
        fixture.markdown,
        idSource: fixture.ids,
        checkedTaskCompletedAt: fixture.checkedTaskCompletedAt
    )
    #expect(imported.document == fixture.document)
    #expect(try BlockMarkdownCodec.exportMarkdown(imported.document) == fixture.canonicalMarkdown)
}
~~~

- [x] Run RED.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.BlockMarkdownCodecTests
~~~

- [x] Implement a line scanner and inline parser that return a document plus line-numbered diagnostics. Unsupported Markdown becomes paragraph/code text containing every original character; it is never discarded or silently converted into a different supported meaning.

~~~swift
public struct BlockMarkdownImportResult: Equatable, Sendable {
    public let document: BlockDocument
    public let diagnostics: [BlockMarkdownDiagnostic]
}

public enum BlockMarkdownCodec {
    public static func importMarkdown(
        _ markdown: String,
        idSource: BlockIDSource = .random,
        checkedTaskCompletedAt: Date
    ) throws -> BlockMarkdownImportResult

    public static func exportMarkdown(_ document: BlockDocument) throws -> String
}
~~~

- [x] Define canonical export rules: LF newlines, four spaces per indent level, one blank line between prose blocks, no trailing whitespace, deterministic ordered-list numbering, and fenced code language preservation. Import accepts valid nesting, clamps levels deeper than 3 to level 3 and preserves every character.
- [x] Add regression fixtures adapted from the existing Markdown tests without importing AppKit or CalendarApp.
- [x] Run GREEN and confirm WorkspaceDomain has no AppKit import.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.BlockMarkdownCodecTests
! rg -n '^import AppKit' Sources/WorkspaceDomain
git diff --check
~~~

- [x] Commit.

~~~zsh
git add Sources/WorkspaceDomain/BlockMarkdownCodec.swift Tests/WorkspaceDomainTests/BlockMarkdownCodecTests.swift
git commit -m "feat(notes): 增加结构化 Block Markdown 编解码"
~~~

## Task 3: Return Series Outcomes and Resolve Calendar-Note Relations

**Files**

- Modify: Sources/CalendarDomain/SeriesMutationEngine.swift
- Modify: Sources/CalendarDomain/CalendarReducer.swift
- Modify: Sources/WorkspaceDomain/CalendarNoteRelations.swift
- Create: Sources/WorkspaceDomain/SeriesRelationMigration.swift
- Modify: Sources/WorkspaceDomain/WorkspaceValidator.swift
- Modify: Tests/CalendarDomainTests/SeriesMutationEngineTests.swift
- Modify: Tests/CalendarDomainTests/CalendarReducerTests.swift
- Create: Tests/WorkspaceDomainTests/CalendarNoteRelationResolverTests.swift
- Create: Tests/WorkspaceDomainTests/SeriesRelationMigrationTests.swift

**Produces:** One authoritative future-series outcome threaded from engine through CalendarReducer to Workspace relation migration; effective primary/reference resolution for item, series and occurrence.

**Consumes:** Existing recurrence split/delete algorithm and Task 1 Note IDs.

**Pre-implementation Gate contract — outcome and wrapper semantics:** the selected `boundary` is always `OccurrenceKey.originalDate`, and `>= boundary` is future-inclusive. Modified displayed dates/times never choose the partition. Split `dayDelta` is civil-day arithmetic from selected `originalDate` to `patch.displayedStartDate`; key remap is `old.originalDate.addingDays(dayDelta)` and never reads `Calendar.current`, a clock or creation timezone. `SeriesMutationEngine.apply` delegates to `applyWithOutcome(...).graph`, and `CalendarReducer.reduce` delegates to `reduceWithOutcome(...).state`; neither wrapper keeps a second switch. Only `.thisAndFuture` split/delete can return an outcome. `.onlyThis` and non-series commands return nil. Split uses the exact command-injected `newSeriesID`; same/existing ID throws `duplicateSeriesID`, while delete/only-this ignore that otherwise-unused parameter and never report it as an outcome.

`historicalOwnerRetained` is returned by the same close/remove helper that mutates the old owner: split with prior real occurrences is true; first-real-occurrence split is false; delete-future with prior real occurrences is true; first-real-occurrence delete is false. The latter is the existing representation of entire-series delete: mutate the first real occurrence with `.thisAndFuture + .delete`; do not add a third scope. First-real-occurrence is computed from actual recurrence projection, not `boundary == ruleStartDate`. A bounded rule with no real occurrence throws without graph/outcome.

**Resolver and logical-instance contract:**

~~~swift
public struct ResolvedCalendarNoteRelation: Equatable, Sendable {
    public let noteSet: CalendarNoteSet
    public let isClickable: Bool
}

public enum CalendarNoteRelationResolver {
    public static func resolve(
        _ target: CalendarTargetID,
        calendar: CalendarState,
        relations: CalendarNoteRelationGraph
    ) throws -> ResolvedCalendarNoteRelation
}
~~~

An occurrence key is a logical instance only when it is inside inclusive rule/end bounds and is either a natural recurrence weekday or has a `.modified` / `.skipped` exception. Completion alone does not create identity. A skipped instance may retain an override but resolves `isClickable == false`; a nonweekday relation-only key without an exception is invalid. Resolver errors and migration errors are `Equatable, Sendable`.

**Raw override and legacy Markdown contract:** effective references are `(baselineRefs - removed) ∪ added - effectivePrimary`. `.replace(x)` may promote an inherited baseline reference and removes it from effective references. Raw `addedReferenceNoteIDs` containing the effective primary is rejected only when it is an explicit added-primary overlap; added/removed intersection is always rejected. Item legacy text reads `CalendarItem.notes`; series reads `WeeklySeries.notes`; a modified occurrence reads its `OccurrenceOverride.notes`, otherwise occurrence scope inherits series notes. Trimmed whitespace/newlines determine nonempty. Reference-only relations may coexist with legacy text. Skipped occurrences still validate endpoints/raw storage but skip effective-primary/legacy conflict so retained undo data cannot make skip invalid.

**Migration contract:**

~~~swift
public static func apply(
    _ outcome: SeriesFutureMutationOutcome,
    resultingGraph: RecurrenceGraph,
    to relations: CalendarNoteRelationGraph
) throws -> CalendarNoteRelationGraph
~~~

Migration rejects outcome/resulting-graph mismatch and destination baseline/override collisions; it never overwrites. Split reads the old baseline first, copies it only when present, then maps every relation override at/after the inclusive original-date boundary by civil `dayDelta`. It retains destination keys only when the resulting series considers them logical instances under the resolver rule; `.modified` and `.skipped` exception keys remain valid, while completion-only and invalid relation-only weekday keys do not. `historicalOwnerRetained == false` removes the old baseline and every old override only after the copy/mapping candidate validates. Delete-future removes future overrides; false also removes the old baseline and all remaining old overrides. Input relations remain unchanged on every error.

Task 3 does not implement undo APIs. It proves only-this skip preserves its relation override, resolver makes it non-clickable and the input relation graph is not destroyed. `WorkspaceReducer.restoreContent` coverage belongs to Task 4; persistent undo/redo and monotonic revisions belong to Task 6.

- [x] Write RED tests for only-this move/resize retaining a stable key and nil outcome, only-this primary/reference override, first-actual-instance split, split with retained history, future delete with and without retained history, first-actual-instance `.thisAndFuture + .delete` as entire-series delete, positive/negative/cross-month/DST civil dayDelta remap, skipped occurrence preserved but not clickable, modified occurrence, completion remap, and a relation override that has no matching recurrence exception/completion. Include no-occurrence bounded rules, exact injected ID, same/existing ID collisions, modified displayed dates crossing the boundary without changing their original-date partition, wrapper equality, outcome/resulting-graph mismatch, destination baseline collision and destination override collision; every migration error leaves the input relation graph byte-for-byte/Equatable unchanged.

- [x] Write resolver/validator RED for item/series/occurrence inherit-replace-clear; natural, modified, skipped, completion-only and invalid nonweekday keys; raw added/removed and explicit-added-primary overlap; `.replace` promoting an inherited reference; item/series/modified-occurrence legacy Markdown; inherited series primary with occurrence notes; skipped primary retention; reference-only coexistence; explicit empty baseline copied versus absent baseline not synthesized; and stale old-future keys rejected after split.

~~~swift
@Test func relationOverrideMigratesWithoutRecurrenceState() throws {
    let migrated = try SeriesRelationMigration.apply(
        outcome,
        resultingGraph: result.graph,
        to: relations
    )
    #expect(migrated.occurrenceOverrides[newKey]?.primary == .replace(noteID))
    #expect(migrated.occurrenceOverrides[oldKey] == nil)
}
~~~

- [x] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarDomainTests.SeriesMutationEngineTests
./Scripts/test.sh --filter CalendarDomainTests.CalendarReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.CalendarNoteRelationResolverTests
./Scripts/test.sh --filter WorkspaceDomainTests.SeriesRelationMigrationTests
~~~

- [x] Add one outcome API and keep old APIs only as wrappers around it.

~~~swift
public struct SeriesMutationResult: Equatable, Sendable {
    public let graph: RecurrenceGraph
    public let futureOutcome: SeriesFutureMutationOutcome?
}

public struct CalendarReduction: Equatable, Sendable {
    public let state: CalendarState
    public let seriesOutcome: SeriesFutureMutationOutcome?
}
~~~

- [x] Build SeriesFutureMutationOutcome in the same code path that closes or removes the historical series. The close/remove helper returns `historicalOwnerRetained`; the outcome uses the confirmed exact cases below and `SeriesMutationResult.graph` is passed explicitly to relationship migration.

~~~swift
public enum SeriesFutureMutationOutcome: Equatable, Sendable {
    case split(
        oldSeriesID: UUID,
        newSeriesID: UUID,
        boundary: CalendarDate,
        dayDelta: Int,
        historicalOwnerRetained: Bool
    )
    case deleteFuture(
        seriesID: UUID,
        boundary: CalendarDate,
        historicalOwnerRetained: Bool
    )
}
~~~

- [x] Implement CalendarNoteRelationGraph with owner baselines and occurrence overrides. References are sets, and primary is at most one.

~~~swift
public struct CalendarNoteSet: Codable, Equatable, Sendable {
    public var primaryNoteID: NoteID?
    public var referenceNoteIDs: Set<NoteID>
}

public enum OccurrencePrimaryOverride: Codable, Equatable, Sendable {
    case inherit
    case replace(NoteID)
    case clear
}

public struct OccurrenceNoteOverride: Codable, Equatable, Sendable {
    public let key: OccurrenceKey
    public var primary: OccurrencePrimaryOverride
    public var addedReferenceNoteIDs: Set<NoteID>
    public var removedReferenceNoteIDs: Set<NoteID>
}

public struct CalendarNoteRelationGraph: Codable, Equatable, Sendable {
    public var baselines: [CalendarNoteOwnerID: CalendarNoteSet]
    public var occurrenceOverrides: [OccurrenceKey: OccurrenceNoteOverride]
}
~~~

- [x] Implement `CalendarNoteRelationResolver`: item reads item baseline; occurrence validates logical identity, inherits series baseline, applies primary inherit/replace/clear and reference subtraction/addition, removes the effective primary from references, and reports skipped clickability.
- [x] Extend WorkspaceValidator to reject baselines/overrides for deleted owners, invalid relation-only keys, duplicate logical instances under old/new keys, raw added/removed or explicit-added-primary overlap, and effective primary with nonempty legacy Markdown under the scope rules above. Skipped overrides retain endpoint/raw validation but skip effective-primary/legacy conflict.
- [x] Implement `SeriesRelationMigration` using outcome plus explicit resulting graph. Split visits every relation override at/after boundary, maps originalDate by civil dayDelta, retains only logical instances in the new series and copies an existing baseline entry—including an explicitly empty `CalendarNoteSet`—before old-owner cleanup; it does not synthesize a baseline when the old key is absent. Delete future removes future overrides. Collision/mismatch errors are atomic and old baseline retention follows `historicalOwnerRetained`.
- [x] Preserve only-this overrides on the stable OccurrenceKey; keep skipped-instance overrides for future undo while excluding them from clickable projections; first-occurrence delete removes its baseline and all overrides without deleting any Note. Task 4, not this task, migrates first and applies a requested relation exactly once to the selected new target.
- [x] Run GREEN plus all recurrence tests.

~~~zsh
./Scripts/test.sh --filter CalendarDomainTests.SeriesMutationEngineTests
./Scripts/test.sh --filter CalendarDomainTests.CalendarReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.CalendarNoteRelationResolverTests
./Scripts/test.sh --filter WorkspaceDomainTests.SeriesRelationMigrationTests
./Scripts/test.sh --filter CalendarDomainTests
./Scripts/test.sh --filter WorkspaceDomainTests
git diff --check
~~~

- [x] Request fresh Sol xhigh review of engine → CalendarReducer → Workspace migration contract; fix every Critical/Important finding and rerun scoped tests.
- [x] Commit.

~~~zsh
git add Sources/CalendarDomain Sources/WorkspaceDomain Tests/CalendarDomainTests Tests/WorkspaceDomainTests
git commit -m "feat(workspace): 串联重复事项与笔记关系迁移"
~~~

## Task 4: Implement Atomic Workspace Commands

**Files**

- Create: Sources/WorkspaceDomain/WorkspaceCommand.swift
- Create: Sources/WorkspaceDomain/WorkspaceReducer.swift
- Create: Sources/WorkspaceDomain/WorkspaceReducer+Notes.swift
- Create: Sources/WorkspaceDomain/WorkspaceReducer+Relations.swift
- Create: Sources/WorkspaceDomain/WorkspaceReducer+Inspiration.swift
- Create: Sources/WorkspaceDomain/WorkspaceReducer+Categories.swift
- Modify: Sources/WorkspaceDomain/DraftContracts.swift
- Modify: Sources/WorkspaceDomain/WorkspaceConsistencyIssue.swift
- Modify: Sources/WorkspaceDomain/WorkspaceChecksum.swift
- Create: Sources/WorkspaceDomain/WorkspaceDeletePlanning.swift
- Modify: Sources/WorkspaceDomain/TaskBlockCalendarLink.swift
- Modify: Sources/WorkspaceDomain/InspirationNoteLink.swift
- Create: Sources/WorkspaceDomain/WorkspaceContentSnapshot.swift
- Modify: Sources/WorkspaceDomain/WorkspaceValidator.swift
- Create: Tests/WorkspaceDomainTests/WorkspaceReducerTests.swift
- Create: Tests/WorkspaceDomainTests/WorkspaceCategoryCommandTests.swift
- Create: Tests/WorkspaceDomainTests/TaskBlockCalendarLinkTests.swift
- Create: Tests/WorkspaceDomainTests/InspirationLifecycleTests.swift
- Modify: Tests/WorkspaceDomainTests/WorkspaceModelTests.swift

**Produces:** Pure, deterministic, cross-object transactions for calendar, notes, relations, task links, inspiration links, categories, delete/archive and undo content restoration.

**Consumes:** CalendarReducer.reduceWithOutcome, BlockMarkdownCodec, relation migration and WorkspaceValidator.

For every calendar/relationship transaction the reducer order is fixed: validate the input Workspace; copy a candidate; call `CalendarReducer.reduceWithOutcome`; call `SeriesRelationMigration.apply(outcome, resultingGraph:)`; apply the requested relationship exactly once; compare business content and return noChange when equal; otherwise allocate Note/Workspace revisions; run the final `WorkspaceValidator` over that exact revision-bearing candidate; then return. An optional pre-revision candidate check may fail early, but never replaces the final validation. `occurrenceThisAndFuture` performs the injected-ID empty `SeriesPatch()` split, migrates relations, and applies the relation once to `.series(outcome.newSeriesID)`. Any calendar, collision, migration or validator failure returns the exact input Workspace with no revision/undo/save side effect.

**Pre-implementation Gate amendment — result semantics:** cancellation and an identical desired business state return typed `noChange`; a stale async metadata result is also a typed, silent noChange. Stale legacy/delete/consistency previews return typed noChange reasons so App can refresh the preview. A draft three-way conflict returns `.conflict` with a complete public conflict payload and leaves the Journal eligible for recovery. Structurally invalid commands throw an `Equatable, Sendable` `WorkspaceReducerError`. None of these paths allocates revision or changed-note IDs.

**Draft three-way merge contract:** `NoteDraftSubmission` additionally carries a normalized `baseSnapshot: Note` and the complete `baseLinkedTaskBlockLinks` for that Note when editing began. Its ID/revision/checksum must agree with `noteID`, `baseNoteRevision` and `baseNoteSnapshotChecksum`; every base link must belong to that Note and a task Block in the base document. `modifiedFields` must equal the fields whose normalized business values differ between base and submitted snapshot. Each field merges independently: submitted equals base keeps current; current equals base takes submitted; submitted equals current takes either; otherwise the whole submission returns a conflict naming that field. Unmodified submitted fields never overwrite current fields. A changed Note keeps `createdAt`, takes `updatedAt = now`, and receives one later revision allocation.

For a submitted document, derive `affectedBlockIDs` from added/removed Blocks and any stable Block whose normalized kind/content/taskState changed from base to submitted. Compare base versus current link projections for this Note at those IDs; any concurrent link add, delete or rebind is a draft conflict, while links on unaffected Block IDs merge independently. Then derive the exact set of currently linked task Blocks that are absent or no longer `.task` in the submitted document. `linkedBlockDeletionDispositions.keys` must equal that set byte-for-byte; missing or extra keys are errors. `.keepCalendarItem` removes only the TaskBlock link and preserves the item, item relation and the last equal completion value. `.deleteCalendarItem` also removes the item and its item-owned relation while preserving the Note. A retained linked task Block may change text/marks but its `completedAt` cannot be changed through `updateNote`; completion must use `setTaskCompletion`.

**Consistency repair exception:** `.repairConsistency` is the only command that cannot run the normal strict input validator because its input is intentionally dangling. It first runs the public consistency inspector and structural safety checks, requires the payload checksum and resolution-key set to match every current repairable relationship issue, applies all resolutions atomically, then runs the same strict final `WorkspaceValidator`. This is not a public bypass validator. Non-relationship problems such as `invalidBlockDocument` are fatal load issues handled by backup/restore, not relink/unlink. Ordinary commands retain strict input and final validation.

- [ ] Write RED tests proving every successful state-changing command is all-or-nothing and increments Workspace revision exactly once. Cancellation, idempotent completion, stale metadata and any other no-op return noChange and cause no revision, save or undo record.

- [ ] Write discriminating RED for the Gate amendments: disjoint/same-field Note draft merge and forged modifiedFields; exact linked-Block disposition keys plus task→non-task/completion rejection; base-link-context concurrent add, delete and rebind at an affected Block plus a non-affected-link positive merge; fixed-ID legacy replay with accepted/rejected/stale diagnostics; repeated completion preserving its first timestamp; exact Inspiration raw-source checksum; canonical delete preview and stale authorization; multiple dangling edges repaired in one payload plus shared-link multi-defect grouping; restore with distinct per-Note source revisions; and every typed noChange/conflict reason.

~~~swift
@Test func deletingCategoryMigratesEveryWorkspaceReferenceAtomically() throws {
    let reduction = try WorkspaceReducer.reduce(
        fixture.workspace,
        command: .deleteCategory(categoryID),
        now: now
    )
    let result = try #require(reduction.change)
    #expect(result.state.calendar.items.values.allSatisfy { $0.categoryID != categoryID })
    #expect(result.state.notes.values.allSatisfy { $0.categoryID != categoryID })
    #expect(result.state.inspirations.values.allSatisfy { $0.categoryID != categoryID })
    #expect(result.state.revision == fixture.workspace.revision + 1)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceCategoryCommandTests
./Scripts/test.sh --filter WorkspaceDomainTests.TaskBlockCalendarLinkTests
./Scripts/test.sh --filter WorkspaceDomainTests.InspirationLifecycleTests
~~~

- [ ] Define commands with explicit payloads; no UI-derived implicit branch.

~~~swift
public enum LegacyDiagnosticDisposition: Equatable, Sendable {
    case rejectIfPresent
    case accept(expectedDiagnosticsChecksum: String)
}

public struct LegacyMarkdownImportAuthorization: Equatable, Sendable {
    public let expectedSourceChecksum: String
    public let injectedBlockIDs: [BlockID]
    public let checkedTaskCompletedAt: Date
    public let diagnostics: LegacyDiagnosticDisposition
}

public enum ExistingPrimaryLegacyResolution: Equatable, Sendable {
    case previewAndMerge(
        expectedNoteRevision: Int64,
        importAuthorization: LegacyMarkdownImportAuthorization
    )
    case cancel
}

public enum PrimaryReplacementDisposition: Sendable {
    case demoteOldPrimaryToReference
    case detachOldPrimary
}

public enum TaskBlockPrimaryChangeDisposition: Sendable {
    case unlinkPreservingCompletion
}

public enum PermanentDeleteSubject: Hashable, Sendable {
    case note(NoteID)
    case inspiration(InspirationID, deletedAt: Date)
}

public struct PermanentDeleteAuthorization: Equatable, Sendable {
    public let subject: PermanentDeleteSubject
    public let sourceWorkspaceRevision: Int64
    public let impactChecksum: String
}

public struct PermanentDeletePreview: Equatable, Sendable {
    public let subject: PermanentDeleteSubject
    public let sourceWorkspaceRevision: Int64
    public let effects: [PermanentDeleteEffect]
    public let checksum: String
}

public enum PermanentDeleteEffect: Hashable, Codable, Sendable {
    case clearBaselinePrimary(CalendarNoteOwnerID)
    case removeBaselineReference(CalendarNoteOwnerID)
    case clearOccurrenceReplacement(OccurrenceKey)
    case removeOccurrenceAddedReference(OccurrenceKey)
    case removeOccurrenceRemovedReference(OccurrenceKey)
    case removeTaskBlockLink(TaskBlockCalendarLink)
    case removeInspirationNoteLink(InspirationNoteLink)
    case tombstoneInspirationNoteLink(noteID: NoteID, inspirationID: InspirationID)
}

public enum CalendarRelationScope: Equatable, Sendable {
    case item(UUID)
    case series(UUID)
    case occurrenceOnly(OccurrenceKey)
    case occurrenceThisAndFuture(OccurrenceKey, newSeriesID: UUID)
}

public struct AttachPrimaryNotePayload: Sendable {
    public let scope: CalendarRelationScope
    public let noteID: NoteID
    public let legacyResolution: ExistingPrimaryLegacyResolution?
    public let replacing: PrimaryReplacementDisposition?
    public let linkedTaskDisposition: TaskBlockPrimaryChangeDisposition?
}

public struct CreatePrimaryNoteForCalendarPayload: Sendable {
    public let scope: CalendarRelationScope
    public let note: Note
    public let legacyImportAuthorization: LegacyMarkdownImportAuthorization?
}

public struct ScheduleNoteOnCalendarPayload: Sendable {
    public let noteID: NoteID
    public let item: CalendarItem
}

public struct ScheduleTaskBlockPayload: Sendable {
    public let noteID: NoteID
    public let blockID: BlockID
    public let item: CalendarItem
}

public struct CreateNotePayload: Sendable {
    public let note: Note
}

public struct CreateInspirationPayload: Sendable {
    public let inspiration: Inspiration
}

public struct ConvertInspirationToNotePayload: Sendable {
    public let inspirationID: InspirationID
    public let proposedNote: Note
}

public enum TaskCompletionTarget: Hashable, Sendable {
    case calendarItem(UUID)
    case taskBlock(noteID: NoteID, blockID: BlockID)
}

public enum TaskCompletionValue: Equatable, Sendable {
    case incomplete
    case complete(ifTransitioningAt: Date)
}

public struct InspirationMetadataExpectation: Equatable, Sendable {
    public let sourceChecksum: String
}

public struct WorkspaceConsistencyRepairPayload: Equatable, Sendable {
    public let expectedIssuesChecksum: String
    public let resolutions: [WorkspaceConsistencyIssueID: WorkspaceConsistencyResolution]
}

public struct WorkspaceRestoreContentPayload: Equatable, Sendable {
    public let content: WorkspaceContentSnapshot
    public let sourceRevisionHighWatermark: Int64
    public let sourceNoteRevisions: [NoteID: Int64]
}

public struct WorkspaceConsistencyIssueID: Hashable, Codable, Sendable {
    public let rawValue: String
}

public struct WorkspaceConsistencyIssue: Hashable, Codable, Sendable {
    public let id: WorkspaceConsistencyIssueID
    public let locator: WorkspaceRelationshipLocator
    public let defect: WorkspaceRelationshipDefect
}

public enum WorkspaceRelationshipLocator: Hashable, Codable, Sendable {
    case calendarBaseline(CalendarNoteOwnerID)
    case occurrenceOverride(OccurrenceKey)
    case calendarNote(CalendarNoteRelationSlot)
    case taskBlock(TaskBlockCalendarLink)
    case inspirationNote(InspirationNoteLink)
}

public enum CalendarNoteRelationSlot: Hashable, Codable, Sendable {
    case baselinePrimary(owner: CalendarNoteOwnerID, noteID: NoteID)
    case baselineReference(owner: CalendarNoteOwnerID, noteID: NoteID)
    case occurrencePrimary(key: OccurrenceKey, noteID: NoteID)
    case occurrenceAddedReference(key: OccurrenceKey, noteID: NoteID)
    case occurrenceRemovedReference(key: OccurrenceKey, noteID: NoteID)
}

public enum WorkspaceRelationshipDefect: Hashable, Codable, Sendable {
    case missingCalendarOwner
    case missingOccurrence
    case missingNote
    case missingCalendarItem
    case missingTaskBlock
    case missingInspiration
}

public enum WorkspaceRelationshipEndpoint: Hashable, Codable, Sendable {
    case calendarOwner(CalendarNoteOwnerID)
    case occurrence(OccurrenceKey)
    case note(NoteID)
    case calendarItem(UUID)
    case taskBlock(noteID: NoteID, blockID: BlockID)
    case inspiration(InspirationID)
}

public enum WorkspaceConsistencyResolution: Hashable, Codable, Sendable {
    case unlink
    case relink(WorkspaceRelationshipEndpoint)
}

public enum WorkspaceCommand: Sendable {
    case calendar(CalendarCommand)
    case createNote(CreateNotePayload)
    case updateNote(NoteDraftSubmission)
    case archiveNote(NoteID, at: Date)
    case restoreNote(NoteID, at: Date)
    case permanentlyDeleteNote(NoteID, authorization: PermanentDeleteAuthorization)
    case createPrimaryNoteForCalendar(CreatePrimaryNoteForCalendarPayload)
    case attachPrimaryNote(AttachPrimaryNotePayload)
    case attachReferenceNote(CalendarRelationScope, NoteID)
    case detachNote(
        CalendarRelationScope,
        NoteID,
        linkedTaskDisposition: TaskBlockPrimaryChangeDisposition?
    )
    case scheduleNoteOnCalendar(ScheduleNoteOnCalendarPayload)
    case scheduleTaskBlock(ScheduleTaskBlockPayload)
    case setTaskCompletion(TaskCompletionTarget, value: TaskCompletionValue)
    case createInspiration(CreateInspirationPayload)
    case updateInspirationMetadata(
        InspirationID,
        expectedSource: InspirationMetadataExpectation,
        metadata: SourceMetadata,
        resolvedKind: ResolvedSourceKind
    )
    case convertInspirationToNote(ConvertInspirationToNotePayload)
    case archiveInspiration(InspirationID, at: Date)
    case restoreInspiration(InspirationID, at: Date)
    case permanentlyDeleteInspiration(
        InspirationID,
        at: Date,
        authorization: PermanentDeleteAuthorization
    )
    case createCategory(CalendarCategory)
    case updateCategory(CalendarCategory)
    case reorderCategories([UUID])
    case deleteCategory(UUID)
    case repairConsistency(WorkspaceConsistencyRepairPayload)
    case restoreContent(WorkspaceRestoreContentPayload)
}
~~~

- [ ] Implement one reducer pipeline: copy current state, apply command, and return noChange when business content is identical. For a real change, increment changed Note revisions, increment Workspace revision once, run WorkspaceValidator, and return candidate plus changed-note IDs and optional persisted-draft context.

~~~swift
public enum WorkspaceReductionResult: Equatable, Sendable {
    case noChange(WorkspaceNoChangeReason)
    case conflict(WorkspaceConflict)
    case changed(WorkspaceReduction)

    public var change: WorkspaceReduction? {
        if case let .changed(value) = self { value } else { nil }
    }
}

public enum WorkspaceNoChangeReason: Equatable, Sendable {
    case identical
    case cancelled
    case staleLegacyPreview
    case staleMetadata
    case staleDeleteAuthorization
    case staleConsistencyPreview
    case inspirationAlreadyConverted(NoteID)
}

public enum WorkspaceConflict: Equatable, Sendable {
    case noteDraft(NoteDraftConflict)
}

public struct NoteDraftConflict: Equatable, Sendable {
    public let noteID: NoteID
    public let currentRevision: Int64
    public let conflictingFields: Set<NoteDraftField>
    public let base: Note
    public let submitted: Note
    public let current: Note
}

public struct WorkspaceReduction: Equatable, Sendable {
    public let state: WorkspaceState
    public let changedNoteIDs: Set<NoteID>
    public let draftContext: PersistableDraftContext?
    public let seriesOutcome: SeriesFutureMutationOutcome?
}
~~~

- [ ] Define and test the raw CalendarCommand allow/intercept matrix. Workspace category commands sent through .calendar are rejected. Item deletion is intercepted to remove item relation/task links without deleting Notes. Series mutation uses reduceWithOutcome then migrates relations. Entire-series deletion removes its baseline/overrides. All remaining allowed item/series commands still pass through CalendarReducer and final WorkspaceValidator.
- [ ] Implement legacy Markdown resolution atomically with context-legal payloads. Existing-note attach accepts only previewAndMerge/cancel; choosing “create new” dispatches `createPrimaryNoteForCalendar` carrying the complete injected Note seed and import authorization. The reducer re-imports with exactly the authorized fixed Block IDs and checked-task timestamp; those IDs must be sufficient, exhausted exactly and collision-free. The created Note document must equal the authorized preview. Merge replaces a canonical empty Note document, otherwise appends imported Blocks in order. Success clears only the selected scope: item notes, a notes-empty only-this OccurrenceOverride, or the newly split series notes. Cancel returns typed noChange.
- [ ] Add public deterministic `LegacyMarkdownMigrationPlanner.preview` and checksum helpers. `expectedSourceChecksum` covers scope identity, owner/OccurrenceKey, this-and-future boundary and exact Markdown bytes. Diagnostics checksum covers the ordered `(lineNumber,message)` list. `.rejectIfPresent` rejects any diagnostic; `.accept` must match the re-imported diagnostic checksum. Re-check source, target Note revision, IDs, preview document and diagnostics only when the command dequeues; any mismatch returns `.noChange(.staleLegacyPreview)` and does not split, create/modify Note or clear text.
- [ ] Implement updateNote as the exact three-way merge above. Validate base snapshot/checksum/derived modified fields; return the complete typed conflict on any same-field or relevant link-context conflict. Generic drafts cannot change a retained linked Task Block completion. Derive and require the exact removal-disposition key set before changing any document, link or item.
- [ ] Implement typed composite reducers for createPrimaryNoteForCalendar, attachPrimaryNote, scheduleNoteOnCalendar and scheduleTaskBlock. Each accepts every required stable ID, scope and newSeriesID in one payload; no App task performs two commands to emulate one transaction.
- [ ] Add reducer failure probes at each composite boundary: invalid Note, Markdown diagnostic requiring confirmation, duplicate item ID, unknown block, recurring item, primary conflict, split failure and post-mutation validator failure. Each leaves item, series, Note, links, legacy notes and revisions equal to the input state.
- [ ] Implement primary/reference commands, explicit old-primary demote/detach choice, and multiple Notes per calendar target with at most one primary. If a target's current primary owns a TaskBlock link, changing/removing it requires `unlinkPreservingCompletion`; an extra disposition is rejected. The link is removed first, both sides keep their last identical completion, then the primary/reference change applies.
- [ ] Implement public `PermanentDeletePlanner.preview(subject,in:)` as the only authorization oracle. It canonical-sorts exact effects by case tag plus stable IDs and hashes subject + source Workspace revision + effects with deterministic encoding. Authorization must match subject, current revision and checksum. Note delete sets baseline primary to nil, removes baseline references, changes occurrence `.replace(deleted)` to `.clear`, removes the Note from added/removed occurrence sets, removes TaskBlock/InspirationNote links, and preserves CalendarItems/Inspirations. Empty relation entries are compacted except an intentional `.clear`. Inspiration delete converts every matching live link to the authorized `deletedAt` tombstone, then removes only the Inspiration. Stale authorization returns typed noChange.
- [ ] Implement TaskBlockCalendarLink: one task Block ↔ at most one non-recurring CalendarItem; one item ↔ at most one task Block; both share the same primary Note; one completedAt is written to both; recurrence is rejected. `TaskCompletionTarget` resolves either side to the same link. `.complete(ifTransitioningAt:)` uses the supplied instant only when both sides are incomplete; if both are already complete it preserves the old timestamp and returns typed noChange. `.incomplete` writes nil to both; repeated incomplete is noChange. Invalid/mismatched input is rejected before mutation.
- [ ] Cover link lifecycle: deleting the calendar item unlinks while preserving Block completion; a NoteDraftSubmission that removes a linked Block must carry a per-Block keep-item/delete-item disposition; changing/removing the primary must carry unlinkPreservingCompletion; unlink preserves the last identical completedAt then permits independent changes.
- [ ] Implement InspirationNoteLink as bidirectional inspectable data. First conversion consumes the payload's complete proposed Note with stable Note/Block IDs, validates it, creates it and the live link in one transaction. Repeated conversion ignores the unused proposal and returns `.noChange(.inspirationAlreadyConverted(existingNoteID))` so App opens the one existing derived Note. Define `WorkspaceChecksum.inspirationSourceChecksum` over Inspiration ID, inputKind and exact raw input: text bytes; URL absoluteString; or bookmark bytes plus displayName. Metadata expectation excludes current metadata, includes no normalized substitute, and a mismatch returns `.noChange(.staleMetadata)` without touching raw input.
- [ ] Implement public consistency inspection with deterministic issue IDs/checksum from canonical locator + defect. `WorkspaceConsistencyRepairPayload` must cover every current repairable issue exactly once; missing/extra IDs, stale checksum or incompatible endpoint kinds do not mutate. `.unlink` removes only the located edge; `.relink` changes only its invalid endpoint and rejects collisions. When one original link has multiple defective endpoints, group its resolutions by the original locator and construct the one replacement edge only after all endpoint resolutions validate. All surviving Notes, Calendar objects and Inspirations remain. Apply the complete set atomically so the one final strict WorkspaceValidator can pass. A report containing fatal non-relationship issues cannot be repaired by this command.
- [ ] Implement WorkspaceContentSnapshot with revisions excluded plus `WorkspaceRestoreContentPayload(content, sourceRevisionHighWatermark, sourceNoteRevisions)`. The revision map keys equal the snapshot Note IDs exactly and every value is in `0...sourceRevisionHighWatermark`; invalid metadata or Int64 overflow is rejected before mutation. Restore chooses candidate Workspace revision as max(current Workspace revision, source high watermark, every source/current Note revision) + 1. For each surviving Note: unchanged business content keeps max(current, source) revision; changed content uses max(current, source) + 1; a Note absent from current but restored uses the candidate Workspace revision. WorkspaceValidator enforces every Note revision is nonnegative and no greater than Workspace revision.
- [ ] Run GREEN and full domain tests.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceCategoryCommandTests
./Scripts/test.sh --filter WorkspaceDomainTests.TaskBlockCalendarLinkTests
./Scripts/test.sh --filter WorkspaceDomainTests.InspirationLifecycleTests
./Scripts/test.sh --filter WorkspaceDomainTests
./Scripts/test.sh --filter CalendarDomainTests
git diff --check
~~~

- [ ] Commit.

~~~zsh
git add Sources/WorkspaceDomain Tests/WorkspaceDomainTests
git commit -m "feat(workspace): 完成跨对象原子命令"
~~~

## Task 5: Build V3 Migration, Provenance, Snapshot, Recovery, and Journal Persistence

**Files**

- Modify: Package.swift
- Create: Sources/CalendarPersistence/WorkspaceDocument.swift
- Create: Sources/CalendarPersistence/V2CalendarDocument.swift
- Create: Sources/CalendarPersistence/WorkspaceDocumentCodec.swift
- Create: Sources/CalendarPersistence/WorkspaceRepository.swift
- Create: Sources/CalendarPersistence/JSONWorkspaceRepository.swift
- Create: Sources/CalendarPersistence/AtomicFileWriter.swift
- Create: Sources/CalendarPersistence/MigrationSnapshotStore.swift
- Create: Sources/CalendarPersistence/RecoveryManifest.swift
- Create: Sources/CalendarPersistence/DraftJournal.swift
- Create: Sources/CalendarPersistence/DraftJournalRepository.swift
- Create: Sources/CalendarPersistence/WorkspaceRestorePlan.swift
- Modify: Sources/CalendarPersistence/BackupService.swift
- Retain for legacy decode: Sources/CalendarPersistence/CalendarDocument.swift
- Retain for legacy decode: Sources/CalendarPersistence/V1CalendarDocument.swift
- Modify temporarily: Sources/CalendarPersistence/CalendarRepository.swift
- Retain only until Task 6 cutover: Sources/CalendarPersistence/JSONCalendarRepository.swift
- Create: Tests/CalendarPersistenceTests/WorkspaceDocumentCodecTests.swift
- Create: Tests/CalendarPersistenceTests/WorkspaceMigrationSnapshotTests.swift
- Create: Tests/CalendarPersistenceTests/WorkspaceBackupServiceTests.swift
- Create: Tests/CalendarPersistenceTests/DraftJournalRepositoryTests.swift
- Create: Tests/CalendarPersistenceTests/WorkspaceRepositoryFailureTests.swift
- Create: Tests/CalendarPersistenceTests/JSONWorkspaceRepositoryTests.swift
- Retain only until Task 6 assertion port: Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift

**Produces:** Schema-aware V1/V2/V3 loading, byte provenance, safe first V3 overwrite, recovery manifest, Workspace backup/restore, exact Journal receipt persistence.

**Consumes:** Existing atomic writer, V1/V2 codecs, WorkspaceState/validator/checksum.

- [ ] Write RED codec tests for V1 → V2 → V3, raw V2 → V3, exact V3 round trip, unknown schema rejection, corrupted payload rejection, deterministic dictionary/set encoding, and non-destructive reporting of a dangling relationship.

~~~swift
@Test func v2LoadReturnsRawByteProvenance() throws {
    let data = try FixtureData.v2CalendarDocument()
    let result = try WorkspaceDocumentCodec.decode(data)
    #expect(result.provenance.sourceSchema == 2)
    #expect(result.provenance.sourceBytesSHA256 == SHA256.hex(data))
    #expect(result.state.calendar == FixtureData.calendarState)
}
~~~

- [ ] Write RED failure-injection tests for snapshot write, snapshot read/hash verification, manifest write, source hash recheck and main replace. Assert main bytes remain byte-for-byte V1/V2 for every pre-replace failure.
- [ ] Add RED cases for source changed before snapshot producing neither snapshot nor manifest entry, source changed after manifest but before replace preserving the changed main, identical source hash reusing the verified record, and a different source hash adding a record without deleting the old snapshot/record.
- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceDocumentCodecTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceMigrationSnapshotTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceBackupServiceTests
./Scripts/test.sh --filter CalendarPersistenceTests.DraftJournalRepositoryTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceRepositoryFailureTests
./Scripts/test.sh --filter CalendarPersistenceTests.JSONWorkspaceRepositoryTests
~~~

- [ ] Implement an envelope-first decoder. V1 uses the existing V1 DTO to construct valid V2 CalendarState semantics before wrapping V3; unknown schema returns before payload decode.
- [ ] Move AtomicFileWriting and FoundationAtomicFileWriter unchanged into AtomicFileWriter.swift. Port every applicable atomic-write, snapshot, rollback, corruption and reopen assertion from JSONCalendarRepositoryTests into the Workspace repository suites. Keep the now-protocol-only CalendarRepository and JSONCalendarRepository just long enough for the still-unmigrated Task 5 App to compile; Task 6 removes both and the old tests in the same single-Store cutover. CalendarDocument/V1CalendarDocument remain decode-only DTO/codecs, never repositories.
- [ ] Define repository load/save contracts.

~~~swift
public protocol WorkspaceRepository: Sendable {
    func load() async throws -> WorkspaceLoadResult
    func save(
        _ state: WorkspaceState,
        draft: PersistableDraftContext?
    ) async throws -> WorkspaceSaveReceipt
    func prepareRestore(_ request: WorkspaceRestoreRequest) async throws -> PreparedWorkspaceRestore
    func commitRestore(
        _ prepared: PreparedWorkspaceRestore,
        state: WorkspaceState
    ) async throws -> WorkspaceSaveReceipt
    func currentDocumentData() async throws -> Data
}
~~~

- [ ] Implement JSONWorkspaceRepository as one actor retaining LoadedSource(rawData, provenance). Snapshot bytes come only from LoadedSource.rawData, never a decoded/re-encoded state. Before first V3 replace: preflight current main against the loaded hash, write raw snapshot, read and hash it, atomically register manifest, re-read main hash, then replace.

~~~swift
public struct RecoveryManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var entries: [RecoverySnapshotRecord]
}

public struct RecoverySnapshotRecord: Codable, Equatable, Sendable {
    public let sourceSchema: Int
    public let sourceSHA256: String
    public let sourceByteCount: Int
    public let snapshotFileName: String
    public let registeredAt: Date
}
~~~

- [ ] Make manifest and Journal independent atomic files. The manifest appends a new record for new source bytes, reuses a verified record for identical bytes, and never discards older records. A snapshot without a verified manifest entry cannot permit main replacement.
- [ ] Apply compare-and-swap protection to every save, not only migration: re-read the current main hash immediately before replace, reject external changes, and after each successful own replace update the actor’s expected hash to the newly written bytes.
- [ ] Implement DraftJournal entries with noteID, baseWorkspaceRevision Int64, baseNoteRevision Int64, draftGeneration UInt64, full Note snapshot, updatedAt, normalized noteSnapshotChecksum, journalChecksum and optional saved receipt. Validate journalChecksum before any recovery comparison and clear only on an exact receipt match.
- [ ] Treat a missing main file as a fresh V3 seed with no legacy snapshot requirement. A V1/V2 source requires the migration chain; an already registered V3 source uses normal atomic saves.
- [ ] On load, run a non-destructive WorkspaceConsistencyInspector before strict mutation validation. Dangling relationships remain in the decoded state but are excluded from clickable projections and returned as WorkspaceLoadResult.consistencyIssues. The Store enters needsRelationshipRepair and permits only backup/restore or an explicit relink/unlink command until issues are resolved; it never silently drops the relationship to make a save pass.
- [ ] Add tests for generation 5 receipt after generation 6, unrelated calendar saves, title-only edits, Journal clear failure and restart reconciliation.
- [ ] Add pure BackupService validation/planning for JSONWorkspaceRepository.prepareRestore. PreparedWorkspaceRestore contains decoded business content, source revision high watermark, source schema/hash and validated raw source bytes. To keep Task 5 independently compiling, retain the existing deprecated Calendar-only export(state:), validatedState and restore(from:repository:rollbackURL:) wrappers unchanged and backed only by the temporary JSONCalendarRepository actor. Task 6 migrates BackupCommands/Store and removes those wrappers together with the old repository. In the final architecture, the Store applies WorkspaceReducer.restoreContent against latest FIFO state, then JSONWorkspaceRepository.commitRestore creates raw rollback and atomically replaces the main file with the normalized-revision V3 candidate; no BackupService or UI path writes the main file outside that actor.
- [ ] Run GREEN and full persistence tests.

~~~zsh
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceDocumentCodecTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceMigrationSnapshotTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceBackupServiceTests
./Scripts/test.sh --filter CalendarPersistenceTests.DraftJournalRepositoryTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceRepositoryFailureTests
./Scripts/test.sh --filter CalendarPersistenceTests.JSONWorkspaceRepositoryTests
./Scripts/test.sh --filter CalendarPersistenceTests
swift build
git diff --check
~~~

- [ ] Request fresh Sol xhigh review focused on raw-byte identity, source-change race, manifest ordering, atomic replacement and recovery; fix every Critical/Important finding and rerun all Task 5 filters.
- [ ] Commit.

~~~zsh
git add Package.swift Sources/CalendarPersistence Tests/CalendarPersistenceTests
git commit -m "feat(storage): 安全迁移工作空间 V3 并增加草稿恢复"
~~~

## Task 6: Replace CalendarStore with the Single Queued WorkspaceStore

**Files**

- Create: Sources/CalendarApp/Workspace/WorkspaceStore.swift
- Create: Sources/CalendarApp/Workspace/WorkspaceTransactionQueue.swift
- Create: Sources/CalendarApp/Workspace/WorkspaceUndoRecord.swift
- Create: Sources/CalendarApp/Workspace/DraftJournalCoordinator.swift
- Create: Sources/CalendarApp/Workspace/AppDataDirectoryResolver.swift
- Modify: Sources/CalendarApp/AppEnvironment.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Modify: Sources/CalendarApp/CalendarUndoCommands.swift
- Modify: Sources/CalendarApp/Backup/BackupCommands.swift
- Modify: Sources/CalendarPersistence/BackupService.swift
- Modify all production files containing CalendarStore
- Remove after final cutover: Sources/CalendarPersistence/CalendarRepository.swift
- Remove after final cutover: Sources/CalendarPersistence/JSONCalendarRepository.swift
- Remove after assertion port: Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift
- Remove after migration: Sources/CalendarApp/CalendarStore.swift
- Remove after porting every assertion: Tests/CalendarAppTests/CalendarStoreTests.swift
- Modify: Tests/CalendarAppTests/TestSupport.swift
- Modify every CalendarApp test containing CalendarStore or InMemoryCalendarRepository
- Create: Tests/CalendarAppTests/WorkspaceStoreTests.swift
- Create: Tests/CalendarAppTests/DraftJournalCoordinatorTests.swift
- Create: Tests/CalendarAppTests/AppDataDirectoryResolverTests.swift

**Produces:** One in-memory/store truth, one queued save path, monotonic revisions, focus-routed undo/redo, Journal-first autosave and explicit isolated acceptance data path.

**Consumes:** WorkspaceReducer and JSONWorkspaceRepository.

- [ ] Inventory every production/test reference before editing. Port failure-before-publish, restore, undo and in-memory repository assertions from CalendarStoreTests into WorkspaceStoreTests; replace InMemoryCalendarRepository with an InMemoryWorkspaceRepository across TestSupport and all CalendarApp tests; then remove the old test file. Make the gate fail if CalendarStore, CalendarRepository or JSONCalendarRepository remains anywhere in Sources or Tests.

~~~zsh
rg -n 'CalendarStore|CalendarRepository|JSONCalendarRepository' Sources/CalendarApp
~~~

- [ ] Write RED tests for failure-before-publish, two queued commands, noChange causing no save/revision/undo, edit-save while calendar mutates, calendar-save while typing continues, queued restore of an older V3/V2/V1 source concurrent with a newer draft, restore failure-before-publish, restart after restore preserving normalized monotonic revisions, old receipt late arrival, Journal clear failure, load failure, undo/redo monotonic revisions and editor-focus undo routing.

~~~swift
@Test func queuedDraftReducesAfterCalendarMutationAgainstLatestState() async throws {
    let repository = SuspendedWorkspaceRepository()
    let store = WorkspaceStore(initialState: fixture, repository: repository, journal: journal, clock: clock)
    async let first: Void = store.sendCalendar(.createItem(item), undoLabel: "新建事项")
    await repository.waitUntilSaveStarted()
    async let second: Void = store.submitDraft(generation6)
    await repository.resumeSave()
    try await first
    try await second
    #expect(store.calendarState.items[item.id] == item)
    #expect(store.state.notes[noteID]?.title == generation6.snapshot.title)
}

@Test func undoCreatesNewMonotonicRevisions() async throws {
    let afterEdit = try await store.apply(noteEdit)
    let workspaceRevision = afterEdit.revision
    let noteRevision = afterEdit.notes[noteID]!.revision
    try await store.undo()
    #expect(store.state.revision == workspaceRevision + 1)
    #expect(store.state.notes[noteID]!.revision == noteRevision + 1)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.WorkspaceStoreTests
./Scripts/test.sh --filter CalendarAppTests.DraftJournalCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.AppDataDirectoryResolverTests
~~~

- [ ] Implement WorkspaceTransactionQueue as a MainActor FIFO. Each request is reduced only when dequeued; while repository.save awaits, newer requests remain queued. Resume each continuation exactly once.
- [ ] Implement WorkspaceStore with calendarState projection and sendCalendar wrapper. sendCalendar creates WorkspaceCommand.calendar and follows the same reducer/validator/repository path.
- [ ] Route restore through WorkspaceTransactionQueue as prepareRestore → WorkspaceReducer.restoreContent against latest state → commitRestore. A successful restore publishes once and clears incompatible undo/redo only after disk replacement; failure keeps state/stacks unchanged. A draft queued after restore reduces against the restored latest state and remains protected/conflicted rather than disappearing.
- [ ] A Note draft applies only its modifiedFields to the latest Note. Disjoint category/archive/title/document changes are merged; a same-field change whose base revision/checksum no longer matches becomes an explicit draft conflict and remains in Journal. A draft can never overwrite the entire latest Note or Workspace merely because its snapshot is older.
- [ ] Implement failure semantics: reducer/validator/repository failure leaves published state, revision and undo stacks unchanged; successful save publishes once and then updates undo/redo metadata.
- [ ] Implement WorkspaceUndoRecord as business-content snapshots plus changed Note IDs. Undo/redo are queued persisted commands with current + 1 revisions; redo clears only after a successful new user transaction.
- [ ] Replace global undo routing with editor focus priority.

~~~swift
@MainActor
final class EditorFocusRegistry: ObservableObject {
    weak var focusedUndoManager: UndoManager?
    var hasFocusedBlockEditor: Bool { focusedUndoManager != nil }
}

func performUndo() {
    if let manager = focusRegistry.focusedUndoManager {
        manager.undo()
    } else {
        Task { try await workspaceStore.undo() }
    }
}
~~~

- [ ] Implement DraftJournalCoordinator ordering: persist Journal entry before enqueueing draft; record receipt; clear only exact noteID + generation + checksum + persistedNoteRevision. Journal clear failure preserves the receipt for restart reconciliation.
- [ ] Add AppDataDirectoryResolver. Default remains Application Support/PersonalCalendar; a nonempty JELLY_ACCEPTANCE_DATA_DIRECTORY places main/snapshot/manifest/journal/backup below the supplied directory. Never alter HOME.

~~~swift
enum AppDataDirectoryResolver {
    static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> AppDataURLs
}
~~~

- [ ] Migrate MonthView, editors, categories, backup and restore to WorkspaceStore. CategoryManagerViewModel sends Workspace category commands. Remove the old Store and old business repository path.
- [ ] Remove the deprecated Calendar-only BackupService export/validate/restore wrappers after BackupCommands and WorkspaceStore use prepareRestore/queued commitRestore. Port their useful tests to WorkspaceBackupServiceTests before deletion.
- [ ] Run GREEN, all existing app tests and release compile.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.WorkspaceStoreTests
./Scripts/test.sh --filter CalendarAppTests.DraftJournalCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.AppDataDirectoryResolverTests
./Scripts/test.sh --filter CalendarAppTests
! rg -n 'CalendarStore|CalendarRepository|JSONCalendarRepository' Sources Tests
swift build -c release
git diff --check
~~~

- [ ] Request fresh Sol xhigh review focused on single-store ownership, queue ordering, failure publication, revision monotonicity, Journal receipts and undo focus; fix every Critical/Important finding and rerun all Task 6 filters plus CalendarAppTests.
- [ ] Commit.

~~~zsh
git add Sources/CalendarApp Sources/CalendarPersistence Tests/CalendarAppTests Tests/CalendarPersistenceTests
git commit -m "refactor(app): 切换为唯一工作空间存储与串行保存"
~~~

## Task 7: Add a Feature-Gated App Shell and Preserve Calendar Behavior

**Files**

- Create: Sources/CalendarApp/AppShell/AppShellView.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceRoute.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceNavigationRail.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceRouteState.swift
- Create: Sources/CalendarApp/Calendar/CalendarModuleView.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Create: Tests/CalendarAppTests/WorkspaceNavigationTests.swift
- Create: Tests/CalendarAppTests/WorkspaceWindowLayoutTests.swift

**Produces:** Fixed narrow icon rail, route persistence, Command-1/2/3, 1044pt minimum width and an unchanged calendar module.

**Consumes:** WorkspaceStore and existing MonthView.

- [ ] Write RED tests for route order, hover labels, warm selected appearance token, accessibility labels, Command-1/2/3, route-aware Command-N, independent route selection state, 64pt rail width, 1044pt minimum window width and feature-gated visible routes.

~~~swift
@Test func unfinishedRoutesAreNotClickable() {
    let features = WorkspaceFeatures(notes: false, inspiration: false)
    #expect(WorkspaceRoute.visibleRoutes(features) == [.calendar])
    var state = WorkspaceRouteState(route: .calendar)
    #expect(state.activate(.notes, features: features) == false)
    #expect(state.handleCommandShortcut("2", features: features) == false)
    #expect(state.route == .calendar)
    #expect(state.commandNAction(features: features) == .createCalendarItem)
}

@Test func shortcutsMapToStableRoutes() {
    #expect(WorkspaceRoute.commandShortcut("1") == .calendar)
    #expect(WorkspaceRoute.commandShortcut("2") == .notes)
    #expect(WorkspaceRoute.commandShortcut("3") == .inspiration)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.WorkspaceNavigationTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceWindowLayoutTests
~~~

- [ ] Implement AppShell with a fixed 64pt leading rail and CalendarModuleView retaining the existing 980pt minimum. Notes and Inspiration remain hidden while their feature flags are false.

~~~swift
struct WorkspaceFeatures: Equatable, Sendable {
    var notes: Bool
    var inspiration: Bool
    static let calendarOnly = Self(notes: false, inspiration: false)
}
~~~

- [ ] Wrap MonthView without changing internal layout, gestures, continuous scrolling, DayDrawer, create/edit overlay or category sheet. Route state owns only current route; each module owns its own selection and scroll state.
- [ ] Add Command-1/2/3 and route-aware Command-N. Add Chinese hover labels and VoiceOver names 日历、笔记、灵感; selected state uses a warm light rounded tile plus a non-color accessibility value, while inactive icons stay low contrast.
- [ ] Run GREEN plus focused interaction regressions and release build.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.WorkspaceNavigationTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceWindowLayoutTests
./Scripts/test.sh --filter CalendarAppTests.CalendarInteractionCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.WeekRowPresentationTests
swift build -c release
git diff --check
~~~

- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/AppShell Sources/CalendarApp/Calendar Sources/CalendarApp/PersonalCalendarApp.swift Tests/CalendarAppTests
git commit -m "feat(app): 增加工作空间导航外壳"
~~~

## Task 8: Implement the Pure Block Input State Machine

**Files**

- Create: Sources/CalendarApp/Notes/BlockEditor/BlockInputReducer.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockEditorSelection.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockPasteParser.swift
- Create: Tests/CalendarAppTests/BlockEditorInputTests.swift

**Produces:** UI-independent commands for Enter, Shift-Enter, Backspace, Tab, Shift-Tab, arrows, slash conversion, paste, multi-block deletion and drag reorder.

**Consumes:** WorkspaceDomain BlockDocument and BlockDocumentValidator.

- [ ] Write RED table tests for the full keyboard matrix in specification §5.2, including empty-list exit, empty heading to paragraph, start-of-block merge, list/task 0...3 parent validation, code-block text indentation, up/down preferred column, Markdown prefix shortcuts, inline formatting across selection, multi-block copy/cut/delete, root-plus-descendant drag, Chinese marked-text guard and undo grouping boundaries.

~~~swift
@Test(arguments: BlockInputFixture.keyboardMatrix)
func keyboardMatrix(_ fixture: BlockInputFixture) throws {
    let result = try BlockInputReducer.reduce(
        fixture.document,
        selection: fixture.selection,
        command: fixture.command
    )
    #expect(result.document == fixture.expectedDocument)
    #expect(result.selection == fixture.expectedSelection)
}

@Test func returnDuringMarkedTextDoesNotSplitBlock() throws {
    let result = try BlockInputReducer.reduce(
        document,
        selection: selection,
        command: .enter(isComposingText: true)
    )
    #expect(result.effect == .deferToTextSystem)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
~~~

- [ ] Define an exhaustive command/result interface.

~~~swift
enum BlockInputCommand: Equatable {
    case enter(isComposingText: Bool)
    case softBreak
    case backspace
    case indent
    case outdent
    case moveUp
    case moveDown
    case convert(BlockKind)
    case applyMarkdownShortcut(prefix: String, isComposingText: Bool)
    case toggleInlineMark(InlineMark)
    case setLink(URL?)
    case replaceSelection(BlockPastePayload)
    case deleteSelection
    case moveBlocks(IndexSet, before: Int)
}

struct BlockInputResult: Equatable {
    let document: BlockDocument
    let selection: BlockEditorSelection
    let undoGroup: BlockUndoGroup
    let effect: BlockInputEffect
}
~~~

- [ ] Implement every transition as pure data transformation followed by BlockDocumentValidator. Preserve existing Block IDs for content edits, allocate IDs only for inserted blocks, and preserve task completedAt only while a task remains a task.
- [ ] toggleInlineMark and setLink operate on the supported inline spans across the current text selection; collapsed selections update typing attributes without rewriting unrelated spans. Clearing a link preserves its text.
- [ ] Implement BlockPasteParser for plain text and supported NSAttributedString semantics; unsupported styling becomes plain inline text without dropping characters.
- [ ] Run GREEN and repeat each table with Chinese and emoji grapheme clusters.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
git diff --check
~~~

- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Notes/BlockEditor Tests/CalendarAppTests/BlockEditorInputTests.swift
git commit -m "feat(notes): 锁定 Block 编辑输入状态机"
~~~

## Task 9: Build the AppKit Block Editor and Focused Undo

**Files**

- Create: Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockEditorSession.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextView.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextViewRepresentable.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockSlashMenu.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockSelectionController.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockDragCoordinator.swift
- Create: Tests/CalendarAppTests/BlockEditorBridgeTests.swift
- Create: Tests/CalendarAppTests/BlockEditorUndoTests.swift
- Create: Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift

**Produces:** Minimal, quiet, structured Block editor with IME-safe input, selection, paste, slash menu, drag reorder and editor-local undo.

**Consumes:** Task 8 state machine, Workspace focus registry and BlockDocument.

- [ ] Write RED hosted AppKit tests proving delegate command routing, marked-text behavior, selection mapping, cross-block copy/cut/delete/format/link, paste conversion, slash keyboard navigation, drag reorder, focus registry registration/removal and uninterrupted UndoManager grouping across autosave callbacks.

~~~swift
@MainActor
@Test func commandZUsesEditorUndoWhileFocused() throws {
    let harness = BlockEditorHarness(document: fixture)
    harness.focus(blockID)
    harness.type("甲")
    harness.storeAutosaveDidComplete()
    harness.pressCommandZ()
    #expect(harness.document == fixture)
    #expect(harness.workspaceUndoCalls == 0)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorBridgeTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorUndoTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorAccessibilityTests
~~~

- [ ] Implement one NSTextView per visible text block coordinated by BlockEditorSession. NSTextView storage is a view projection; BlockDocument remains session truth and committed edits go through BlockInputReducer.
- [ ] In doCommandBy, defer Enter/Backspace when hasMarkedText is true. Apply structural commands only after composition commits. Add Pinyin candidate and emoji probes.
- [ ] Map NSTextView ranges to BlockEditorSelection. Cross-block delete produces one undo group and one document callback.
- [ ] Show the restrained inline-format/link controls only for a nonempty supported text selection or explicit keyboard shortcut; route cross-block copy, cut and supported formatting through the selection controller without losing unrecognized text.
- [ ] Implement slash menu only for slash-prefixed paragraphs; arrows navigate, Return confirms, Escape closes, IME never opens it.
- [ ] Implement a 20pt drag affordance on hover/focus, keyboard Move Up/Down alternatives, stable-ID reorder and accessible position announcements. Keep controls visually restrained.
- [ ] Register the editor session UndoManager in EditorFocusRegistry on focus and clear it on blur/deinit. Autosave observers cannot end groups or replace the session.
- [ ] Run GREEN.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorBridgeTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorUndoTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorAccessibilityTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
git diff --check
~~~

- [ ] Request fresh Sol xhigh review focused on IME, focus undo, selection identity, autosave boundaries and accessibility; fix every Critical/Important finding and rerun all BlockEditor filters.
- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Notes/BlockEditor Tests/CalendarAppTests
git commit -m "feat(notes): 交付极简结构化 Block 编辑器"
~~~

## Task 10: Deliver the First Notes Vertical Slice and Restart Recovery

**Files**

- Create: Sources/CalendarApp/Notes/NotesSplitView.swift
- Create: Sources/CalendarApp/Notes/NoteBrowserView.swift
- Create: Sources/CalendarApp/Notes/NoteEditorView.swift
- Create: Sources/CalendarApp/Notes/NotesViewModel.swift
- Create: Sources/CalendarApp/Notes/NoteAutosaveCoordinator.swift
- Create: Sources/CalendarApp/Notes/DraftRecoverySheet.swift
- Create: Sources/CalendarApp/Notes/NoteMarkdownCommands.swift
- Modify: Sources/CalendarApp/AppShell/WorkspaceRoute.swift
- Modify: Sources/CalendarApp/AppShell/AppShellView.swift
- Modify: Sources/CalendarApp/AppShell/WorkspaceNavigationRail.swift
- Create: Tests/CalendarAppTests/NotesWorkspaceViewModelTests.swift
- Create: Tests/CalendarAppTests/NoteAutosaveCoordinatorTests.swift
- Create: Tests/CalendarAppTests/DraftRecoveryPresentationTests.swift
- Create: Tests/CalendarAppTests/NoteMarkdownCommandTests.swift

**Produces:** A visible Notes tab with create/select/edit, title + Block content, debounced Journal-first autosave, save state and restart recovery choice.

**Consumes:** WorkspaceStore, BlockEditor and DraftJournalCoordinator.

- [ ] Write RED tests for create/select/delete-selection fallback, empty state, title edit, 150ms Journal and 650ms main-save debounce, coalesced generations, save failure, recovered-newer-draft preview, 恢复为当前版本, 保留磁盘版本, 另存为新笔记, Markdown import fidelity and Markdown export.

~~~swift
@Test func typingWritesJournalBeforeDebouncedMainSave() async throws {
    let model = NotesViewModel(store: store, scheduler: scheduler)
    model.select(noteID)
    model.editTitle("新标题")
    #expect(await journal.latest(noteID) == nil)
    #expect(repository.saveCount == 0)
    await scheduler.advance(by: .milliseconds(150))
    #expect(await journal.latest(noteID)?.draftGeneration == 1)
    #expect(repository.saveCount == 0)
    await scheduler.advance(by: .milliseconds(500))
    #expect(repository.saveCount == 1)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.NotesWorkspaceViewModelTests
./Scripts/test.sh --filter CalendarAppTests.NoteAutosaveCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.DraftRecoveryPresentationTests
./Scripts/test.sh --filter CalendarAppTests.NoteMarkdownCommandTests
~~~

- [ ] Implement a collapsible two-column NotesSplitView. The left column contains search, shared-category filter, 最近编辑, 全部笔记, 归档, Note list and 新建. The right column contains borderless title, BlockEditor and only category, exceptional save state, 安排到日历 and more at the top. Calendar relations appear on demand, not as a permanent side panel. Expose the shared Category manager from the Notes toolbar without making it a fourth route. Do not add AI buttons in V1.
- [ ] Add 导入 Markdown and 导出 Markdown under the Note more menu. Import previews BlockMarkdownImportResult diagnostics before replacing/appending; cancel leaves the Note unchanged. Export writes the canonical Markdown selected by the user and reports write failure truthfully.
- [ ] Enable Notes only after create/edit/autosave/recovery paths are wired. Inspiration remains hidden.
- [ ] Every edit increments draftGeneration and computes checksum, coalesces Journal writes at 150ms, then saves the main Workspace at 650ms total. submitDraft carries only that Note snapshot/generation. Flush both layers on selection change, app inactive and window close.
- [ ] On launch, validate journalChecksum, then compare Journal, persisted receipt and current Note snapshot. Silently discard exact persisted receipts; for a materially newer/different draft show a preview with 恢复为当前版本, 保留磁盘版本 and 另存为新笔记. Recovery and save-as-new are queued new revisions; choosing disk deletes only the exact reviewed Journal entry.
- [ ] Show truthful states: 正在保护草稿, 草稿已保护, 正在保存, 已保存, 保存失败—草稿已保护, 已恢复草稿. Failed main save keeps editor editable and Journal intact. If Journal and main both fail, block silent close and offer copy/export.
- [ ] Run GREEN and an isolated vertical integration test: raw V2 load/migrate, verify byte-exact snapshot plus manifest, create Note with stable ID, edit Block content, verify Journal protection precedes main save, persist, construct a fresh Store, reload, and verify the Note plus exact original CalendarState and calendar interaction projections.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.NotesWorkspaceViewModelTests
./Scripts/test.sh --filter CalendarAppTests.NoteAutosaveCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.DraftRecoveryPresentationTests
./Scripts/test.sh --filter CalendarAppTests.NoteMarkdownCommandTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceStoreTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceMigrationSnapshotTests
swift build -c release
git diff --check
~~~

- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Notes Sources/CalendarApp/AppShell Tests/CalendarAppTests
git commit -m "feat(notes): 打通笔记编辑保存与重启恢复"
~~~

## Task 11: Connect Calendar Items to Primary and Reference Notes

**Files**

- Create: Sources/CalendarApp/Calendar/CalendarNoteRelationPopover.swift
- Create: Sources/CalendarApp/Calendar/CalendarNotePicker.swift
- Create: Sources/CalendarApp/Calendar/LegacyNotesMigrationSheet.swift
- Create: Sources/CalendarApp/Calendar/NoteScheduleSheet.swift
- Create: Sources/CalendarApp/Notes/NoteCalendarLinksPopover.swift
- Modify: Sources/CalendarApp/Editing/ItemDetailPopover.swift
- Modify: Sources/CalendarApp/Editing/ItemEditorViewModel.swift
- Modify: Sources/CalendarApp/Editing/QuickCreatePopover.swift
- Modify: Sources/CalendarApp/Month/MonthView.swift
- Create: Tests/CalendarAppTests/CalendarNoteIntegrationTests.swift
- Create: Tests/CalendarAppTests/CalendarNoteRelationPresentationTests.swift
- Create: Tests/CalendarAppTests/LegacyNotesMigrationPresentationTests.swift

**Produces:** Calendar item ↔ multiple Notes, at most one primary; create/open/link/unlink flows; legacy Markdown decision UI; item/series/occurrence scope.

**Consumes:** Workspace relation commands, effective relation resolver and Note route.

- [ ] Write RED tests for zero/one primary, multiple reference IDs as a set, old-primary demote/detach choice, one Note linked by multiple items, open linked Note routing, create Note from item, create item from Note, detach without deleting either object, exact series scope, and calendar legacy Markdown changing after preview but before command execution.

~~~swift
@Test func addingExistingNoteToLegacyTextRequiresExplicitChoice() async throws {
    let model = CalendarNoteIntegrationModel(target: targetWithLegacyMarkdown, store: store)
    await model.chooseExistingPrimary(noteID)
    #expect(model.presentedSheet == .legacyNotesResolution(noteID))
    #expect(store.state.calendarNoteRelations.relation(for: target).primaryNoteID == nil)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.CalendarNoteIntegrationTests
./Scripts/test.sh --filter CalendarAppTests.CalendarNoteRelationPresentationTests
./Scripts/test.sh --filter CalendarAppTests.LegacyNotesMigrationPresentationTests
~~~

- [ ] Add a compact 笔记 section to item detail: primary Note first, references below, 添加已有笔记, 新建主笔记, and detach menu. Existing title/date/category layout and calendar gestures remain unchanged.
- [ ] Keep archived Note relations intact. Calendar renders 已归档 on the linked Note and offers open/restore; unlinking or deleting a calendar item never deletes or copies Note content.
- [ ] When legacy notes are nonempty, show 转成笔记. Attaching an existing primary presents 预览并合并, 另建主笔记, 取消. Preview captures imported blocks, target Note revision and legacy-source checksum; either stale value returns to a refreshed preview without saving. Confirmation sends one createPrimaryNoteForCalendar or attachPrimaryNote composite payload, never a sequence of App commands.
- [ ] Implement item, series baseline and occurrence override scopes. UI exposes 当前实例, 整个系列 and applicable 本次及未来; it sends one Workspace command and consumes SeriesFutureMutationOutcome.
- [ ] Add 从笔记安排到日历. It sends one scheduleNoteOnCalendar payload that creates a non-recurring item and attaches the Note as primary in one transaction, with date range, optional time and shared category.
- [ ] Run GREEN plus recurrence and calendar interaction suites.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.CalendarNoteIntegrationTests
./Scripts/test.sh --filter CalendarAppTests.CalendarNoteRelationPresentationTests
./Scripts/test.sh --filter CalendarAppTests.LegacyNotesMigrationPresentationTests
./Scripts/test.sh --filter CalendarDomainTests.SeriesMutationEngineTests
./Scripts/test.sh --filter CalendarAppTests.CalendarInteractionCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.WeekRowPresentationTests
git diff --check
~~~

- [ ] Request fresh Sol xhigh review focused on legacy text loss, primary uniqueness, recurrence scopes and relation cleanup; fix every Critical/Important finding and rerun Task 11 filters.
- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Calendar Sources/CalendarApp/Notes Sources/CalendarApp/Editing Sources/CalendarApp/Month Tests/CalendarAppTests
git commit -m "feat(calendar): 打通日历事项与多篇笔记关系"
~~~

## Task 12: Link Task Blocks and Calendar Items

**Files**

- Create: Sources/CalendarApp/Notes/TaskBlockScheduleSheet.swift
- Create: Sources/CalendarApp/Notes/TaskBlockCalendarBadge.swift
- Modify: Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift
- Modify: Sources/CalendarApp/Calendar/CalendarNoteRelationPopover.swift
- Modify: Sources/CalendarApp/Editing/ItemDetailPopover.swift
- Create: Tests/CalendarAppTests/TaskBlockCalendarIntegrationTests.swift
- Create: Tests/CalendarAppTests/TaskBlockCompletionPresentationTests.swift

**Produces:** Schedule/unlink/reschedule from Task Block, visible relation in both surfaces, and exact bidirectional completedAt.

**Consumes:** scheduleTaskBlock composite command, TaskBlockCalendarLink invariants and non-recurring CalendarItem creation.

- [ ] Write RED tests for schedule, reject recurrence, one task ↔ one item, same-primary requirement, idempotent reschedule, unlink, complete/reopen from either side, exact old-time undo, delete-item unlink, delete-block keep-item/delete-both choice, primary-change confirmation and one injected timestamp.

~~~swift
@Test func calendarCompletionUsesExactlyTheBlockTimestamp() async throws {
    clock.now = completedAt
    try await integration.completeCalendarItem(itemID)
    let item = store.calendarState.items[itemID]!
    let block = store.state.notes[noteID]!.document.block(blockID)!
    #expect(item.completedAt == completedAt)
    #expect(block.taskState?.completedAt == completedAt)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.TaskBlockCalendarIntegrationTests
./Scripts/test.sh --filter CalendarAppTests.TaskBlockCompletionPresentationTests
~~~

- [ ] Add an unobtrusive calendar badge/action on Task Block hover/focus and context menu. Scheduling creates a non-recurring item using task text, shared category and current Note as primary.
- [ ] Render linked date/status inline without turning every Block into a card. Clicking opens item detail; unlink preserves both objects.
- [ ] Route both completion gestures through one WorkspaceCommand.setTaskCompletion with Store-injected clock. Never call Date independently in two UI paths.
- [ ] On Block delete, present 保留独立日历事项 / 一起删除 / 取消. On item delete, unlink automatically while preserving the Block completion value. On primary Note removal/change, require unlink confirmation first. Unlink leaves both sides at their last identical completedAt.
- [ ] Run GREEN and item-completion regressions.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.TaskBlockCalendarIntegrationTests
./Scripts/test.sh --filter CalendarAppTests.TaskBlockCompletionPresentationTests
./Scripts/test.sh --filter CalendarAppTests.CalendarItemRowPresentationTests
./Scripts/test.sh --filter CalendarAppTests.CalendarInteractionCoordinatorTests
git diff --check
~~~

- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Notes Sources/CalendarApp/Calendar Sources/CalendarApp/Editing Tests/CalendarAppTests
git commit -m "feat(notes): 联动待办 Block 与日历事项"
~~~

## Task 13: Deliver the Inspiration Capture and Incubation Loop

**Files**

- Create: Sources/CalendarApp/Inspiration/InspirationSplitView.swift
- Create: Sources/CalendarApp/Inspiration/InspirationInboxView.swift
- Create: Sources/CalendarApp/Inspiration/InspirationDetailView.swift
- Create: Sources/CalendarApp/Inspiration/InspirationCaptureView.swift
- Create: Sources/CalendarApp/Inspiration/InspirationConversionSheet.swift
- Create: Sources/CalendarApp/Inspiration/InspirationViewModel.swift
- Create: Sources/CalendarApp/Inspiration/URLMetadataResolver.swift
- Modify: Sources/CalendarApp/AppShell/WorkspaceRoute.swift
- Modify: Sources/CalendarApp/AppShell/AppShellView.swift
- Modify: Sources/CalendarApp/AppShell/WorkspaceNavigationRail.swift
- Create: Tests/CalendarAppTests/InspirationWorkspaceViewModelTests.swift
- Create: Tests/CalendarAppTests/URLMetadataResolverTests.swift
- Create: Tests/CalendarAppTests/InspirationConversionPresentationTests.swift

**Produces:** Plain text/URL fast capture, immutable raw input, failure-safe asynchronous metadata, structured incubator notes, convert-to-Note, archive and deleted-source tombstone.

**Consumes:** Workspace inspiration commands, shared categories and InspirationNoteLink.

- [ ] Write RED tests for text capture, URL capture saved before network, offline/timeout/malformed metadata, stale response ignored when raw URL or updatedAt changed, convert to Note, repeated conversion idempotence, archive/restore, permanent delete and Note tombstone display.

~~~swift
@Test func urlIsDurableBeforeMetadataStarts() async throws {
    let resolver = SuspendedURLMetadataResolver()
    let model = InspirationViewModel(store: store, resolver: resolver)
    let id = try await model.capture("https://example.com/article")
    #expect(store.state.inspirations[id]?.rawURL == URL(string: "https://example.com/article"))
    #expect(repository.lastSavedState?.inspirations[id] != nil)
    #expect(await resolver.startedURLs.count == 1)
}
~~~

- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.InspirationWorkspaceViewModelTests
./Scripts/test.sh --filter CalendarAppTests.URLMetadataResolverTests
./Scripts/test.sh --filter CalendarAppTests.InspirationConversionPresentationTests
~~~

- [ ] Implement a content-first inbox/detail split. The left column derives 待处理, 已形成笔记 and 已归档 from lifecycle plus live links; the right shows original content, source metadata, created time, shared category and actions. A persistently visible capture field accepts plain text or URL with one Return. Expose the same Category manager from this module’s toolbar; File remains reserved without an active picker.
- [ ] Save rawText or rawURL before URL metadata; a URL starts with resolvedSourceKind .unknown and fetch status pending. URLMetadataResolver uses URLSession with explicit timeout, response size cap, accepted content types and no script execution. Failure changes only enrichment state and exposes retry.
- [ ] Apply metadata with inspirationID + the public InspirationMetadataExpectation sourceChecksum captured before fetch; it covers ID/inputKind and exact raw source bytes but not metadata/updatedAt. Stale responses return the typed staleMetadata noChange without adding an Inspiration-only revision. Unknown resolvedKind remains valid.
- [ ] Convert to Note in one transaction: text becomes an initial paragraph; URL becomes a supported link Block using resolved title when available; add InspirationNoteLink and keep the Inspiration as the authoritative live source record. The Note source UI resolves through that link rather than storing a hidden metadata copy. Repeated conversion opens the existing Note.
- [ ] Add an in-app shortcut that activates the Inspiration quick-input field, plus 转成笔记, 归档, 恢复, 复制链接 and metadata retry actions. Drive the rail’s restrained pending dot/count from active Inspirations without a live Note link. Enable Inspiration only after capture/detail/failure/conversion/archive paths are live.
- [ ] Run GREEN.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.InspirationWorkspaceViewModelTests
./Scripts/test.sh --filter CalendarAppTests.URLMetadataResolverTests
./Scripts/test.sh --filter CalendarAppTests.InspirationConversionPresentationTests
./Scripts/test.sh --filter WorkspaceDomainTests.InspirationLifecycleTests
git diff --check
~~~

- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Inspiration Sources/CalendarApp/AppShell Tests/CalendarAppTests
git commit -m "feat(inspiration): 交付灵感捕获整理与转笔记闭环"
~~~

## Task 14: Finish Search, Archive, Recovery UI, Accessibility, and Error States

**Files**

- Create: Sources/WorkspaceDomain/WorkspaceSearchProjection.swift
- Create: Sources/CalendarApp/Search/WorkspaceSearchIndex.swift
- Create: Sources/CalendarApp/Recovery/RecoveryCenterView.swift
- Modify: Sources/CalendarApp/Notes/NotesSplitView.swift
- Modify: Sources/CalendarApp/Inspiration/InspirationSplitView.swift
- Modify: Sources/CalendarApp/AppShell/AppShellView.swift
- Modify: Sources/CalendarApp/Backup/BackupCommands.swift
- Create: Tests/WorkspaceDomainTests/WorkspaceSearchProjectionTests.swift
- Create: Tests/CalendarAppTests/WorkspaceSearchIndexTests.swift
- Create: Tests/CalendarAppTests/RecoveryCenterViewModelTests.swift
- Create: Tests/CalendarAppTests/WorkspaceAccessibilityTests.swift

**Produces:** Rebuildable local search, archive filters, user-visible snapshot/Journal recovery, truthful errors, keyboard/VoiceOver coverage and no hidden data-loss state.

**Consumes:** V3 repository manifest/Journal, Workspace models and three live modules.

- [ ] Write RED tests for Chinese/title/body/source search, deterministic rebuild, archived exclusion/inclusion, deleted-source tombstone, corrupt index rebuild, recovery manifest display, restore preview, Journal status and accessibility labels/actions.
- [ ] Run RED.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceSearchProjectionTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceSearchIndexTests
./Scripts/test.sh --filter CalendarAppTests.RecoveryCenterViewModelTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceAccessibilityTests
~~~

- [ ] Implement versioned WorkspaceSearchProjection containing only IDs, normalized text, object kind, categoryID and archived state.

~~~swift
public struct WorkspaceSearchRecord: Codable, Equatable, Sendable {
    public let objectID: WorkspaceObjectID
    public let kind: WorkspaceObjectKind
    public let normalizedText: String
    public let categoryID: UUID?
    public let isArchived: Bool
}
~~~

- [ ] Implement WorkspaceSearchIndex with atomic replace, schema check and rebuild on missing/corrupt/stale revision. Resolve results through current WorkspaceState and drop deleted IDs.
- [ ] Expose only module-scoped Note and Inspiration search/filter UI in V1; do not add a cross-module global search entry or ranking.
- [ ] Add archive filters and empty states. Ordinary 删除 on Note/Inspiration is implemented as archive; permanent delete appears only from the archive view, requires an impact preview/confirmation, unlinks safely and records the required tombstone or recovery evidence. Restore returns Inspiration to active and derives 待处理/已形成笔记 from live links.
- [ ] Add RecoveryCenterView listing verified pre-V3 snapshot, source schema/hash/date, backups, protected Journal drafts and isolated relationship issues. Restore previews decoded counts and creates rollback first; each relationship issue offers explicit relink/unlink with both surviving endpoints shown.
- [ ] Add truthful UI for load failed, main save failed with Journal protected, Journal write failed before save, source changed externally, snapshot failure, restore failure and URL metadata failure.
- [ ] Verify keyboard and VoiceOver for rail, Notes list/editor blocks, relation controls, task completion, Inspiration and recovery. Respect Reduce Motion and light/dark contrast.
- [ ] Run GREEN plus all tests.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceSearchProjectionTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceSearchIndexTests
./Scripts/test.sh --filter CalendarAppTests.RecoveryCenterViewModelTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceAccessibilityTests
./Scripts/test.sh
swift build -c release
git diff --check
~~~

- [ ] Request fresh Sol xhigh overall code review; fix every Critical/Important finding and perform scoped re-review.
- [ ] Commit.

~~~zsh
git add Sources Tests
git commit -m "feat(workspace): 收口搜索恢复与无障碍体验"
~~~

## Task 15: Run Full Package, Upgrade, Recovery, and Real GUI Acceptance

**Files**

- Modify: Scripts/build-app.sh only if V3 resources require packaging changes
- Create: Scripts/run-workspace-v3-acceptance.sh
- Create: Scripts/install-desktop-app-safely.sh
- Create: Tests/CalendarAppTests/WorkspaceEndToEndTests.swift
- Create: docs/validation/workspace-v3/acceptance.md
- Create: docs/validation/workspace-v3/visual-checklist.md
- Create: docs/validation/workspace-v3/evidence/ only for generated screenshots/log summaries

**Produces:** Current-run automated, release, archive, signing, isolated upgrade/recovery and real GUI evidence; a distributable Jelly.app that leaves user data untouched.

**Consumes:** All previous tasks.

- [ ] Write an automated end-to-end test for the first vertical slice and complete object loop.

~~~swift
@Test func v2UpgradeNotesRelationsInspirationAndRestart() async throws {
    let fixture = try EndToEndFixture.seededWithRawV2Bytes()
    let first = try await fixture.launchStore()
    let noteID = try await first.createAndPersistNote()
    let itemID = try await first.schedulePrimaryNote(noteID)
    let inspirationID = try await first.captureAndConvertInspiration()
    let second = try await fixture.restartStore()
    #expect(second.calendarState == fixture.originalCalendarState.withAddedItem(itemID))
    #expect(second.state.notes[noteID] != nil)
    #expect(second.state.inspirations[inspirationID] != nil)
    #expect(try fixture.snapshotMatchesOriginalV2Bytes())
}
~~~

- [ ] Run full automated and build gates from a clean process.

~~~zsh
./Scripts/test.sh
swift build -c release
./Scripts/build-app.sh
./Scripts/test-build-app-archive.sh
./Scripts/test-build-app-failures.sh
./Scripts/test-build-app-symlink.sh
codesign --verify --deep --strict dist/Jelly.app
git diff --check
~~~

- [ ] Build run-workspace-v3-acceptance.sh around JELLY_ACCEPTANCE_DATA_DIRECTORY. It creates a task-specific mktemp directory, copies a V2 fixture into calendar-v1.json, launches the freshly unpacked executable directly, and prints artifact paths. It never sets HOME or uses real Application Support.

~~~zsh
acceptance_root="$(mktemp -d "$TMPDIR/jelly-v3-acceptance.XXXXXX")"
JELLY_ACCEPTANCE_DATA_DIRECTORY="$acceptance_root/data" \
  "$acceptance_root/Jelly.app/Contents/MacOS/Jelly"
~~~

- [ ] Before any GUI launch, recursively inventory the entire default Application Support/PersonalCalendar directory as relative path, file type, symlink target, byte count, mtime and SHA-256. After every acceptance/install-path launch, generate the same inventory and require exact equality; this detects modified/deleted files and sidecars that did not exist before. Record only metadata/hashes, never user content.
- [ ] Fresh-unpack the archive and perform the GUI checklist:
  1. Launch raw V2 copy; categories/items/recurrences/legacy notes and existing month interactions remain correct.
  2. Confirm byte-identical snapshot and RecoveryManifest exist before main becomes V3.
  3. Navigate by mouse and Command-1/2/3; verify 1044pt, full screen, light/dark, Reduce Motion and VoiceOver.
  4. Create Note; type Chinese with Pinyin; paste; exercise Enter/Shift-Enter/Backspace/Tab, slash, cross-block selection, drag and editor undo/redo.
  5. Force main-save failure after Journal succeeds; restart, recover, save, restart again and verify exact content.
  6. Convert nonempty legacy notes with merge and new-primary; attach references; open both ways; detach safely.
  7. Exercise series baseline, current occurrence and this-and-future relations across months.
  8. Schedule Task Block, complete/reopen from each side, verify one timestamp and unlink safely.
  9. Capture text/URL Inspirations; verify offline failure preserves raw input; convert, archive, permanently delete source and show 原始灵感已删除.
  10. Search Chinese content, toggle archive, corrupt derived index and verify rebuild.
  11. Restore verified V2 snapshot after rollback; restart and verify pre-upgrade calendar.
  12. Re-run calendar body drag, two resize handles, completion, cross-month scroll, DayDrawer vertical scroll and swipe delete.

- [ ] Launch the unmodified signed artifact once from a uniquely named app under /Applications with an explicit JELLY_ACCEPTANCE_DATA_DIRECTORY, verify startup and its real executable path, then move only that acceptance copy to Trash. Do not replace an existing /Applications/Jelly.app and do not launch this copy against default data.
- [ ] After every gate passes, install the reviewed artifact to /Users/oreal/Desktop/Jelly.app with install-desktop-app-safely.sh: quit the old process, hash the current app, move it to a timestamped /Users/oreal/Desktop/Jelly-app-backups entry, stage the new app under a unique sibling name, verify signature/hash, and rename into place. Launch the installed executable for verification only with JELLY_ACCEPTANCE_DATA_DIRECTORY; never perform a default-data launch during acceptance. Restore the backup automatically if any pre-install or isolated-launch check fails, and report the recoverable backup path. State in the handoff that the user’s first later normal save will run the verified snapshot/manifest migration path.
- [ ] Capture screenshots and concise logs under docs/validation/workspace-v3/evidence. acceptance.md records commands, counts, archive checksum, signing, isolated path, real-data hashes and residual limitations.
- [ ] Run fresh Sol xhigh final review over complete diff/evidence. Fix every Critical/Important finding; rerun affected gates, then full suite, release, package/signing and relevant GUI rows.
- [ ] Confirm scope and no temporary scaffolding or dead compatibility paths.

~~~zsh
rg -n '临时实现|未完成实现|占位实现' Sources Tests Scripts docs/validation/workspace-v3
! rg -n 'CalendarStore|CalendarRepository|JSONCalendarRepository' Sources Tests
git diff --check
git status --short
~~~

- [ ] Verify finalization readiness: every preceding Task 1–15 implementation/evidence checkbox is complete, reviews are approved, the default data inventory is unchanged, and this checkbox is marked as the final planned file edit before staging.

Finalization invariant (intentionally not another mutable checkbox): commit and push the reviewed delivery, then verify local HEAD equals origin/main and the worktree is clean. If any command fails, keep the Goal active, fix the failure in a follow-up commit, and rerun the remote/clean checks without editing completion markers again.

~~~zsh
git add Sources Tests Scripts docs Package.swift
git commit -m "feat(workspace): 交付日历笔记灵感工作空间 V1"
git push origin main
git fetch origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
test -z "$(git status --short)"
~~~

## Specification Coverage Matrix

| Confirmed specification | Implemented and accepted in |
|---|---|
| §3 fixed rail, three modules, route state | Tasks 7, 10, 13, 15 |
| §4.1 Workspace root and monotonic revisions | Tasks 1, 4, 5, 6 |
| §4.2 calendar target identities | Tasks 1, 3, 11 |
| §4.3 Note lifecycle and shared category | Tasks 1, 4, 10, 14 |
| §4.4 one primary plus many references | Tasks 1, 3, 4, 11 |
| §4.5 series inheritance, split and delete remap | Tasks 3, 4, 11, 15 |
| §4.6 Inspiration raw input, resolved kinds and source tombstone | Tasks 1, 4, 13, 14 |
| §4.7 one authoritative category command path | Tasks 4, 6, 11, 13 |
| §5.1 versioned BlockDocument and stable IDs | Tasks 1, 8, 9 |
| §5.2 Notion/Feishu keyboard, IME, selection and drag matrix | Tasks 8, 9, 15 |
| §5.3 Markdown import/export and legacy conversion | Tasks 2, 4, 11 |
| §5.4 Task Block calendar link and exact completion time | Tasks 4, 12, 15 |
| §6 calendar, Notes and Inspiration page interactions | Tasks 7, 10, 11, 12, 13 |
| §7 archive, delete and relationship lifecycle | Tasks 4, 11, 13, 14 |
| §8.1 V1 → V2 → V3 | Tasks 5, 6, 10, 15 |
| §8.2 atomic writes and byte-exact migration snapshot | Tasks 5, 15 |
| §8.3 autosave and failure states | Tasks 5, 6, 10, 14, 15 |
| §8.4 Draft Journal and recovery choices | Tasks 1, 5, 6, 10, 14, 15 |
| §9 module-scoped search and rebuildable projections | Task 14 |
| §10 AI/knowledge-base extension boundaries without fake controls | Tasks 1, 4, 10, 13 |
| §11 first-phase scope and exclusions | Global Constraints, Tasks 10–15 |
| §12 automated and real-product acceptance | Task 15 |
| §13 implementation safety gates | Tasks 3, 5, 6, 9, 11, 14, 15 |

## Task 16: 自动继续下一任务

This final section is an execution invariant, not mutable completion state, so it does not create a self-referential dirty-worktree checkbox after the final push.

- After each task review passes, update Tasks 1–15 checkboxes and the active Goal plan, push the reviewed commit, and immediately start the next unchecked task.
- If a test, build, package, migration, recovery, GUI or review gate fails, keep the Goal active, write a focused RED reproduction, fix it, obtain scoped re-review, and resume from the failed checkbox.
- Stop only when every checkbox in Tasks 1–15 is complete, local HEAD equals origin/main, worktree is clean, freshly unpacked Jelly.app passes the full isolated GUI checklist, the default data-directory inventory is unchanged, final Sol xhigh review is approved, and the user receives an evidence-backed handoff.

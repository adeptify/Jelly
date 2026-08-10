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
- CalendarStore 与 CalendarRepository 在 Task 6C 的单次消费者切换中退役。Task 6B 允许新的 WorkspaceStore 作为尚未接入 AppEnvironment 的、仅由 focused tests 构造的 dormant core 与旧 CalendarStore 源码短暂同仓；任何生产 composition root、视图或命令不得同时构造或调用两者，也不得形成第二条 Workspace 业务写路径。Task 6C 完成后 Sources/Tests 中不得再存在旧类型、别名或 wrapper。

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

public enum DraftJournalSessionID: Hashable, Codable, Sendable {
    case editor(UUID)
    case legacyTask5
}

public struct PersistedDraftReceipt: Equatable, Codable, Sendable {
    public let noteID: NoteID
    public let editSessionID: DraftJournalSessionID
    public let draftGeneration: UInt64
    public let noteSnapshotChecksum: String
    public let persistedNoteRevision: Int64
}

public struct WorkspaceSaveReceipt: Equatable, Sendable {
    public let workspaceRevision: Int64
    public let persistedDraft: PersistedDraftReceipt?
}

public enum WorkspaceCommittedOperation: Equatable, Sendable {
    case save(WorkspaceSaveReceipt)
    case restore(WorkspaceRestoreOutcome)
}

public enum WorkspaceCommitReconciliation: Equatable, Sendable {
    case committed(WorkspaceCommittedOperation)
    case notCommitted(WorkspacePendingCommitArtifacts)
    case sourceChanged(WorkspacePendingCommitArtifacts)
    case stillPending(WorkspacePendingCommitArtifacts)
}

public struct WorkspaceRawSourceIdentity: Equatable, Codable, Sendable {
    public let sha256: String
    public let byteCount: Int
}

public enum WorkspaceRollbackArtifact: Equatable, Sendable {
    case file(URL, WorkspaceRawSourceIdentity)
    case nonePreviousSourceAbsent
}

public struct WorkspaceRestoreOutcome: Equatable, Sendable {
    public let receipt: WorkspaceSaveReceipt
    public let rollback: WorkspaceRollbackArtifact
}

public struct WorkspacePendingCommitArtifacts: Equatable, Sendable {
    public let rollback: WorkspaceRollbackArtifact?
}

public enum WorkspaceDirectCommitFailure: Error, Equatable, Sendable {
    case sourceChanged(WorkspacePendingCommitArtifacts)
}

public enum WorkspacePersistenceBlockReason: Equatable, Sendable {
    case unreadablePrimary
    case opaqueInvalidPrimary
    case loadFailed
}

public enum WorkspaceExternalSourceChangeReason: Equatable, Sendable {
    case externalBytesChanged
    case publishedDraftNotPersisted
}

private enum LoadedSource: Sendable {
    case absent
    case valid(rawData: Data, result: WorkspaceLoadResult)
    case opaqueInvalid(rawData: Data, identity: WorkspaceRawSourceIdentity)
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
→ 在共享协调锁内比较主文件与 load hash，并原子替换为编码后的 V3
→ 读回 V3 并整体更新 LoadedSource
→ 返回 WorkspaceSaveReceipt
~~~

若源是已登记的 V3，后续保存只走验证、编码、协调式 CAS、读回和 receipt；若主文件在 load 后被协作式写入者修改，返回 sourceChanged 并保持当前文件。从 snapshot preflight 到 CAS、读回和 LoadedSource 更新不得出现 actor suspension。主文件 compare-and-replace 的保证范围是所有 Jelly 进程和遵守同一文件协调/锁协议的写入者；普通文件系统无法阻止完全不协作的进程在任意两条系统调用之间改写文件，因此不得宣称对这种写入者具备绝对 CAS。每次成功 save/restore 后必须用候选 V3 的 exact rawData 与新 provenance 整体替换 LoadedSource，不能只更新 expected hash。若 rename 已成功但同锁内 exact readback 失败，CAS 返回独立 `commitUncertain`，repository 保留旧 bytes、candidate、receipt 与 restore capability 的 pending binding，并阻止后续普通保存和重复 load；它不能把这个状态降级成普通 `atomicWriteFailed`。底层原子写 helper 即使抛错也不证明 rename 未发生：CAS 必须在同一锁内以 no-follow 三态 probe 重新读取，candidate 视为已提交、exact previous 或由 `open`/`lstat` 明确得到 `ENOENT` 的真实 absent 视为确定未提交，`EACCES`、`ELOOP`、父目录不可搜索、不可读或第三值均视为 `commitUncertain`；`FileManager.fileExists == false` 永远不能单独证明 absent。

## Transaction, Undo, and Journal Contract

~~~swift
public enum WorkspaceTransaction {
    case command(WorkspaceCommand, undoLabel: String?)
    case noteDraft(NoteDraftSubmission)
    case restore(preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL)
    case undo
    case redo
}

public enum WorkspaceTransactionOutcome: Equatable, Sendable {
    case committed(WorkspaceSaveReceipt, journal: JournalResolutionStatus)
    case restored(WorkspaceRestoreOutcome)
    case noChange(WorkspaceNoChangeReason, journal: JournalResolutionStatus)
    case conflict(WorkspaceConflict)
    case draftSuperseded
    case commitPending(transactionID: UUID, artifacts: WorkspacePendingCommitArtifacts)
    case notCommitted(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case externalSourceChanged(transactionID: UUID?, reason: WorkspaceExternalSourceChangeReason, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case persistenceBlocked(transactionID: UUID?, reason: WorkspacePersistenceBlockReason, journal: JournalResolutionStatus)
}

public enum PendingCommitRetryOutcome: Equatable, Sendable {
    case committed(WorkspaceCommittedOperation, journal: JournalResolutionStatus)
    case notCommitted(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case sourceChanged(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case stillPending(transactionID: UUID, artifacts: WorkspacePendingCommitArtifacts)
}

@MainActor
@Observable final class WorkspaceStore {
    private(set) var state: WorkspaceState
    var calendarState: CalendarState { state.calendar }

    func sendWorkspace(_ command: WorkspaceCommand, undoLabel: String?) async throws -> WorkspaceTransactionOutcome
    func sendCalendar(_ command: CalendarCommand, undoLabel: String?) async throws -> WorkspaceTransactionOutcome
    func submitDraft(_ submission: NoteDraftSubmission) async throws -> WorkspaceTransactionOutcome
    func restore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) async throws -> WorkspaceTransactionOutcome
    func undo() async throws -> WorkspaceTransactionOutcome
    func redo() async throws -> WorkspaceTransactionOutcome
    func retryPendingCommit(_ transactionID: UUID) async throws -> PendingCommitRetryOutcome
    func retryJournalCleanup(_ identity: DraftJournalIdentity) async -> JournalResolutionStatus
}
~~~

- sendWorkspace、sendCalendar、submitDraft、restore、undo、redo 只入队，不因上一条正在保存而拒绝。
- drain 每次取一条，在执行时读取最新 state，构造 candidate，WorkspaceValidator 校验，repository.save 成功后才发布。
- Note draft 携带 noteID、editSessionID、draftGeneration、baseSnapshot、modifiedFields、snapshot 和 checksum，不携带整个 WorkspaceState。PersistableDraftContext、DraftJournalEntry 和 PersistedDraftReceipt 都必须携带同一个 editSessionID。
- generation 5 的 receipt 到达时若 Journal 已是 generation 6，不能清理 generation 6。
- Journal 清理失败不回滚已成功的主保存；保留可识别的已持久 receipt，启动时按 receipt 精确消解。
- Draft Journal 是按 `(noteID, editSessionID)` 分区的多记录 envelope，不是一个全局槽位；不同 Note 或不同编辑会话的 generation 互不覆盖。
- UndoRecord 保存可逆 optimistic write-set 与受影响 Note 的 revision high-watermark，不保存/恢复整个 WorkspaceState。undo/redo 只在 touched before/after 值仍匹配时应用 delta；workspace.revision = current + 1，受影响 Note revision 从 session ledger 当前高水位 + 1，已删除 Note 的高水位也不得丢失。

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

- [x] Write RED tests proving every successful state-changing command is all-or-nothing and increments Workspace revision exactly once. Cancellation, idempotent completion, stale metadata and any other no-op return noChange and cause no revision, save or undo record.

- [x] Write discriminating RED for the Gate amendments: disjoint/same-field Note draft merge and forged modifiedFields; exact linked-Block disposition keys plus task→non-task/completion rejection; base-link-context concurrent add, delete and rebind at an affected Block plus a non-affected-link positive merge; fixed-ID legacy replay with accepted/rejected/stale diagnostics; repeated completion preserving its first timestamp; exact Inspiration raw-source checksum; canonical delete preview and stale authorization; multiple dangling edges repaired in one payload plus shared-link multi-defect grouping; restore with distinct per-Note source revisions; and every typed noChange/conflict reason.

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

- [x] Run RED.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceCategoryCommandTests
./Scripts/test.sh --filter WorkspaceDomainTests.TaskBlockCalendarLinkTests
./Scripts/test.sh --filter WorkspaceDomainTests.InspirationLifecycleTests
~~~

- [x] Define commands with explicit payloads; no UI-derived implicit branch.

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

- [x] Implement one reducer pipeline: copy current state, apply command, and return noChange when business content is identical. For a real change, increment changed Note revisions, increment Workspace revision once, run WorkspaceValidator, and return candidate plus changed-note IDs and optional persisted-draft context.

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

- [x] Define and test the raw CalendarCommand allow/intercept matrix. Workspace category commands sent through .calendar are rejected. Item deletion is intercepted to remove item relation/task links without deleting Notes. Series mutation uses reduceWithOutcome then migrates relations. Entire-series deletion removes its baseline/overrides. All remaining allowed item/series commands still pass through CalendarReducer and final WorkspaceValidator.
- [x] Implement legacy Markdown resolution atomically with context-legal payloads. Existing-note attach accepts only previewAndMerge/cancel; choosing “create new” dispatches `createPrimaryNoteForCalendar` carrying the complete injected Note seed and import authorization. The reducer re-imports with exactly the authorized fixed Block IDs and checked-task timestamp; those IDs must be sufficient, exhausted exactly and collision-free. The created Note document must equal the authorized preview. Merge replaces a canonical empty Note document, otherwise appends imported Blocks in order. Success clears only the selected scope: item notes, a notes-empty only-this OccurrenceOverride, or the newly split series notes. Cancel returns typed noChange.
- [x] Add public deterministic `LegacyMarkdownMigrationPlanner.preview` and checksum helpers. `expectedSourceChecksum` covers scope identity, owner/OccurrenceKey, this-and-future boundary and exact Markdown bytes. Diagnostics checksum covers the ordered `(lineNumber,message)` list. `.rejectIfPresent` rejects any diagnostic; `.accept` must match the re-imported diagnostic checksum. Re-check source, target Note revision, IDs, preview document and diagnostics only when the command dequeues; any mismatch returns `.noChange(.staleLegacyPreview)` and does not split, create/modify Note or clear text.
- [x] Implement updateNote as the exact three-way merge above. Validate base snapshot/checksum/derived modified fields; return the complete typed conflict on any same-field or relevant link-context conflict. Generic drafts cannot change a retained linked Task Block completion. Derive and require the exact removal-disposition key set before changing any document, link or item.
- [x] Implement typed composite reducers for createPrimaryNoteForCalendar, attachPrimaryNote, scheduleNoteOnCalendar and scheduleTaskBlock. Each accepts every required stable ID, scope and newSeriesID in one payload; no App task performs two commands to emulate one transaction.
- [x] Add reducer failure probes at each composite boundary: invalid Note, Markdown diagnostic requiring confirmation, duplicate item ID, unknown block, recurring item, primary conflict, split failure and post-mutation validator failure. Each leaves item, series, Note, links, legacy notes and revisions equal to the input state.
- [x] Implement primary/reference commands, explicit old-primary demote/detach choice, and multiple Notes per calendar target with at most one primary. If a target's current primary owns a TaskBlock link, changing/removing it requires `unlinkPreservingCompletion`; an extra disposition is rejected. The link is removed first, both sides keep their last identical completedAt, then the primary/reference change applies.
- [x] Implement public `PermanentDeletePlanner.preview(subject,in:)` as the only authorization oracle. It canonical-sorts exact effects by case tag plus stable IDs and hashes subject + source Workspace revision + effects with deterministic encoding. Authorization must match subject, current revision and checksum. Note delete sets baseline primary to nil, removes baseline references, changes occurrence `.replace(deleted)` to `.clear`, removes the Note from added/removed occurrence sets, removes TaskBlock/InspirationNote links, and preserves CalendarItems/Inspirations. Empty relation entries are compacted except an intentional `.clear`. Inspiration delete converts every matching live link to the authorized `deletedAt` tombstone, then removes only the Inspiration. Stale authorization returns typed noChange.
- [x] Implement TaskBlockCalendarLink: one task Block ↔ at most one non-recurring CalendarItem; one item ↔ at most one task Block; both share the same primary Note; one completedAt is written to both; recurrence is rejected. `TaskCompletionTarget` resolves either side to the same link. `.complete(ifTransitioningAt:)` uses the supplied instant only when both sides are incomplete; if both are already complete it preserves the old timestamp and returns typed noChange. `.incomplete` writes nil to both; repeated incomplete is noChange. Invalid/mismatched input is rejected before mutation.
- [x] Cover link lifecycle: deleting the calendar item unlinks while preserving Block completion; a NoteDraftSubmission that removes a linked Block must carry a per-Block keep-item/delete-item disposition; changing/removing the primary must carry unlinkPreservingCompletion; unlink preserves the last identical completedAt then permits independent changes.
- [x] Implement InspirationNoteLink as bidirectional inspectable data. First conversion consumes the payload's complete proposed Note with stable Note/Block IDs, validates it, creates it and the live link in one transaction. Repeated conversion ignores the unused proposal and returns `.noChange(.inspirationAlreadyConverted(existingNoteID))` so App opens the one existing derived Note. Define `WorkspaceChecksum.inspirationSourceChecksum` over Inspiration ID, inputKind and exact raw input: text bytes; URL absoluteString; or bookmark bytes plus displayName. Metadata expectation excludes current metadata, includes no normalized substitute, and a mismatch returns `.noChange(.staleMetadata)` without touching raw input.
- [x] Implement public consistency inspection with deterministic issue IDs/checksum from canonical locator + defect. `WorkspaceConsistencyRepairPayload` must cover every current repairable issue exactly once; missing/extra IDs, stale checksum or incompatible endpoint kinds do not mutate. `.unlink` removes only the located edge; `.relink` changes only its invalid endpoint and rejects collisions. When one original link has multiple defective endpoints, group its resolutions by the original locator and construct the one replacement edge only after all endpoint resolutions validate. All surviving Notes, Calendar objects and Inspirations remain. Apply the complete set atomically so the one final strict WorkspaceValidator can pass. A report containing fatal non-relationship issues cannot be repaired by this command.
- [x] Implement WorkspaceContentSnapshot with revisions excluded plus `WorkspaceRestoreContentPayload(content, sourceRevisionHighWatermark, sourceNoteRevisions)`. The revision map keys equal the snapshot Note IDs exactly and every value is in `0...sourceRevisionHighWatermark`; invalid metadata or Int64 overflow is rejected before mutation. Restore chooses candidate Workspace revision as max(current Workspace revision, source high watermark, every source/current Note revision) + 1. For each surviving Note: unchanged business content keeps max(current, source) revision; changed content uses max(current, source) + 1; a Note absent from current but restored uses the candidate Workspace revision. WorkspaceValidator enforces every Note revision is nonnegative and no greater than Workspace revision.
- [x] Run GREEN and full domain tests.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceCategoryCommandTests
./Scripts/test.sh --filter WorkspaceDomainTests.TaskBlockCalendarLinkTests
./Scripts/test.sh --filter WorkspaceDomainTests.InspirationLifecycleTests
./Scripts/test.sh --filter WorkspaceDomainTests
./Scripts/test.sh --filter CalendarDomainTests
git diff --check
~~~

- [x] Commit.

~~~zsh
git add Sources/WorkspaceDomain Tests/WorkspaceDomainTests
git commit -m "feat(workspace): 完成跨对象原子命令"
~~~

## Task 5: Build V3 Migration, Provenance, Snapshot, Recovery, and Journal Persistence

> **Historical baseline superseded by Task 6A:** the checked Task 5 protocol, `LoadedSource.bytes`, single-record Journal and restore signatures below describe the safely shipped baseline at `e4db14c`. Task 6A replaces those shapes in place with the one complete protocol and migration contract in Task 6; implementers must not preserve Task 5 shapes as compatibility overloads or a second business path.

**Files**

- Create: Sources/CalendarPersistence/WorkspaceDocument.swift
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
- Retain and freeze as the only V2 DTO/decoder: Sources/CalendarPersistence/CalendarDocument.swift
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

- [x] Write RED codec tests for V1 → V2 → V3, raw V2 → V3, exact V3 round trip, unknown schema rejection, corrupted payload rejection, deterministic dictionary/set encoding, and non-destructive reporting of a dangling relationship.

~~~swift
@Test func v2LoadReturnsRawByteProvenance() throws {
    let data = try FixtureData.v2CalendarDocument()
    let result = try WorkspaceDocumentCodec.decode(data)
    #expect(result.provenance.sourceSchema == 2)
    #expect(result.provenance.sourceBytesSHA256 == SHA256.hex(data))
    #expect(result.state.calendar == FixtureData.calendarState)
}
~~~

- [x] Write RED failure-injection tests for snapshot write, snapshot read/hash verification, manifest write, source hash recheck, coordinated compare-and-replace and main replace. Assert main bytes remain byte-for-byte V1/V2 for every pre-replace failure. Add a hook that attempts a cooperating main-file mutation after the repository has prepared the candidate but before the CAS primitive compares and renames; the stale candidate must lose without overwrite.
- [x] Add RED cases for source changed before snapshot producing neither snapshot nor manifest entry, source changed after manifest but before replace preserving the changed main, identical source hash reusing the verified record, and a different source hash adding a record without deleting the old snapshot/record.
- [x] Add RED concurrency cases for two saves and for save interleaved with commitRestore. The second transaction must not enter the snapshot/manifest/CAS chain until the first has finished and LoadedSource has been replaced. No test may pass merely because an outdated actor continuation resumes last.
- [x] Run RED.

~~~zsh
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceDocumentCodecTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceMigrationSnapshotTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceBackupServiceTests
./Scripts/test.sh --filter CalendarPersistenceTests.DraftJournalRepositoryTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceRepositoryFailureTests
./Scripts/test.sh --filter CalendarPersistenceTests.JSONWorkspaceRepositoryTests
~~~

- [x] Implement an envelope-first decoder. V1 uses the existing V1 DTO to construct valid V2 CalendarState semantics before wrapping V3; unknown schema returns before payload decode.
- [x] Move the existing unconditional AtomicFileWriting and FoundationAtomicFileWriter API into AtomicFileWriter.swift for sidecars, and add a separate main-file CAS primitive that accepts expected SHA-256 plus candidate bytes. It acquires the shared Jelly advisory lock/file-coordination critical section, re-reads and compares the main file inside that same critical section, renames without releasing the lock, then performs exact candidate readback before returning `.replaced(verifiedRawData)`. A post-rename readback failure returns `.commitUncertain`, never a generic pre-commit error. If the underlying atomic writer throws, the CAS must still classify the destination under that same lock with one shared no-follow tri-state probe: exact candidate returns `.replaced`; exact previous bytes, or a true absence proven only by `ENOENT`, rethrows the definite pre-commit failure; unreadable/unknown/third bytes return `.commitUncertain`. `FileManager.fileExists` is not an absence proof because inaccessible parents also return false. Its stated guarantee covers Jelly/cooperating writers only; a typed sourceChanged result is not an assertion of impossible protection from an uncooperative process. Port every applicable atomic-write, snapshot, rollback, corruption and reopen assertion from JSONCalendarRepositoryTests into the Workspace repository suites. Keep the now-protocol-only CalendarRepository and JSONCalendarRepository just long enough for the still-unmigrated Task 5 App to compile; Task 6 removes both and the old tests in the same single-Store cutover. CalendarDocument is the one frozen schema-2 DTO/decoder and V1CalendarDocument is schema 1; do not create a parallel V2 migration algorithm.
- [x] Define repository load/save contracts.

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
    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation
}
~~~

- [x] Implement JSONWorkspaceRepository as one actor retaining `LoadedSource.absent` or `LoadedSource.bytes(rawData, provenance)`. Snapshot bytes come only from LoadedSource rawData, never a decoded/re-encoded state. Before first V3 replace: preflight current main against the loaded hash, write raw snapshot, read and hash it, atomically register manifest, then invoke the main-file CAS. From preflight through snapshot/manifest/CAS and LoadedSource replacement, the repository must not `await` or call a reentrant actor: all file helpers are synchronous actor-isolated value/reference helpers, or the whole chain is guarded by an explicit non-reentrant transaction lock. An absent main is not represented by fake zero bytes; its first seed write is a coordinated create-if-absent CAS, is read back and verified, and only then becomes `.bytes`. Before CAS it records an in-memory pending commit containing old raw bytes, candidate raw bytes/state, exact receipt and optional restore capability. `reconcilePendingCommit` reuses the same no-follow three-state probe under the same coordination lock: candidate bytes return `.committed(receipt)` and atomically update LoadedSource/consume capability; old bytes or confirmed `ENOENT` for a previous absent source return `.notCommitted`; exact third bytes return `.sourceChanged`. Unreadable/unknown state, lock failure, or candidate decode/provenance failure throws `commitUncertain` and preserves pending plus capability identity for a later retry; it may not fabricate `.sourceChanged` or discard the exact receipt. A repository with pending uncertainty rejects load, save, restore and current-data operations until reconciliation.

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

- [x] Make manifest and Journal independent atomic files. Before acquiring the manifest lock, idempotently create and validate its parent directory so a custom nested manifest URL works on first use. The manifest appends a new record for new source bytes, reuses a record only after re-reading the referenced snapshot and matching hash plus byteCount, and never discards older records. Reject absolute snapshot paths, `..`, symlink/path escape outside the snapshot directory and malformed manifests; fail closed. A snapshot without a verified manifest entry cannot permit main replacement.
- [x] Apply the coordinated compare-and-replace primitive to every save, not only migration. For cooperating writers the compare and rename occur in one critical section. After each successful own replace, read back the exact candidate and replace the actor's complete LoadedSource with schema-3 raw bytes, hash and byte count.
- [x] Define the durable Journal envelope and actor API. `StoredDraftJournalRecord(entry,pendingReceipt,savedReceipt,recordChecksum)` is the atomic on-disk unit. `persist(entry)`, `bindPending(receipt)`, `record(receipt)` and `clear(ifMatching:)` each perform one actor-isolated read-validate-modify-atomic-write operation. The Store persists the draft before enqueue; after reducer allocation and before main save it atomically binds the exact final candidate receipt. `record` accepts only that exact pending receipt, and `clear` accepts only the exact saved receipt. Never compare `persistedNoteRevision` to the draft snapshot's old revision; require it to be greater than the base Note revision, while exact equality comes from the actor-issued pending binding. A generation-5 binding/receipt cannot overwrite or clear generation 6. Validate the record checksum before any recovery comparison; Journal-clear failure leaves the matching receipt durable for restart reconciliation.
- [x] Before `save(state,draft:)` encodes anything, validate WorkspaceState and, when draft is present, require its Note to exist and its normalized checksum to equal `PersistableDraftContext.noteSnapshotChecksum`. Construct the persisted receipt only from that exact Note's revision in the candidate being written. Add missing-Note, checksum-mismatch and correct-receipt REDs.
- [x] Treat a missing main file as `.absent` and a fresh V3 seed with no legacy snapshot requirement. The create-if-absent write failure leaves it absent. A V1/V2 source requires the migration chain; an already registered V3 source uses normal coordinated saves. Add missing seed failure, V1 load followed by two saves, and reopen provenance tests.
- [x] On load, run a non-destructive WorkspaceConsistencyInspector before strict mutation validation. Dangling relationships remain in the decoded state but are excluded from clickable projections and returned as WorkspaceLoadResult.consistencyIssues. The Store enters needsRelationshipRepair and permits only backup/restore or an explicit relink/unlink command until issues are resolved; it never silently drops the relationship to make a save pass.
- [x] Add tests for generation 5 receipt after generation 6, unrelated calendar saves, title-only edits, Journal clear failure and restart reconciliation.
- [x] Add pure BackupService validation/planning for JSONWorkspaceRepository.prepareRestore. `PreparedWorkspaceRestore` carries validated raw source bytes and provenance, `WorkspaceContentSnapshot`, source revision high watermark, exact `[NoteID: Int64]` source revisions, and a unique rollback URL. The Note-revision keys must equal prepared content Note IDs. `commitRestore(prepared,state:)` revalidates raw hash/count, requires the candidate business content to equal prepared content, validates the candidate Workspace, and rejects any binding mismatch before writing rollback.
- [x] Fix commitRestore ordering: while holding the same non-reentrant repository transaction, lock/read the current exact main bytes, consume the one-shot restore capability as rollback creation begins, write a unique raw rollback, read it back and verify hash plus byteCount, then invoke the coordinated main-file CAS and finally replace LoadedSource. A commit-uncertain attempt transfers the reconciliation identity into PendingWorkspaceCommit; every rollback readback, snapshot/manifest, definite CAS failure, sourceChanged, reconcile-old or reconcile-third path leaves the old capability invalid and requires a fresh prepare with a new rollback URL. Rollback write/readback corruption, sourceChanged and main replace failures must leave the main bytes untouched. A rollback is recovery evidence and is never silently deleted on failure.
- [x] Add the public Workspace backup export path that Task 6 will call, for example `BackupService.exportCurrent(from:to:)`. It reads, envelope-validates and exports the repository's exact currently persisted raw V1, V2 or V3 bytes, atomically writes the destination and reads back hash plus byteCount. A V1/V2 load whose first user action is backup therefore succeeds without forcing or simulating a V3 migration save; add that RED. It never re-encodes an in-memory subgraph. To keep Task 5 independently compiling, retain the existing deprecated Calendar-only export(state:), validatedState and restore(from:repository:rollbackURL:) wrappers unchanged and backed only by the temporary JSONCalendarRepository actor. Task 6 migrates BackupCommands/Store to the Workspace export/prepareRestore APIs and removes those wrappers together with the old repository. In the final architecture, the Store applies WorkspaceReducer.restoreContent against latest FIFO state, then JSONWorkspaceRepository.commitRestore performs the verified rollback/CAS transaction; no BackupService or UI path writes the main file outside that actor.
- [x] Run GREEN and full persistence tests.

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

- [x] Request fresh Sol xhigh review focused on raw-byte identity, source-change race, manifest ordering, atomic replacement and recovery; fix every Critical/Important finding and rerun all Task 5 filters.
- [x] Commit.

~~~zsh
git add Sources/CalendarPersistence Tests/CalendarPersistenceTests
git commit -m "feat(storage): 安全迁移工作空间 V3 并增加草稿恢复"
~~~

## Task 6: Replace CalendarStore with the Single Queued WorkspaceStore

**Files**

- Create: Sources/CalendarApp/Workspace/WorkspaceStore.swift
- Create: Sources/CalendarApp/Workspace/WorkspaceTransactionQueue.swift
- Create: Sources/CalendarApp/Workspace/WorkspaceUndoRecord.swift
- Create: Sources/CalendarApp/Workspace/DraftJournalCoordinator.swift
- Create: Sources/CalendarApp/Workspace/AppDataDirectoryResolver.swift
- Create: Sources/CalendarApp/Workspace/EditorFocusRegistry.swift
- Create: Sources/WorkspaceDomain/WorkspaceUndoReducer.swift
- Create: Sources/WorkspaceDomain/WorkspaceExternalSourceAdoptionPlanner.swift
- Create: Sources/WorkspaceDomain/NoteDraftSequenceRebasePlanner.swift
- Modify: Sources/WorkspaceDomain/DraftContracts.swift
- Modify: Sources/WorkspaceDomain/WorkspaceReducer.swift
- Modify: Sources/WorkspaceDomain/WorkspaceReducer+Notes.swift
- Modify: Sources/CalendarPersistence/WorkspaceRepository.swift
- Modify: Sources/CalendarPersistence/WorkspaceDocument.swift
- Modify: Sources/CalendarPersistence/WorkspaceRestorePlan.swift
- Modify: Sources/CalendarPersistence/JSONWorkspaceRepository.swift
- Modify: Sources/CalendarPersistence/DraftJournal.swift
- Modify: Sources/CalendarPersistence/DraftJournalRepository.swift
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
- Create: Tests/WorkspaceDomainTests/WorkspaceUndoReducerTests.swift
- Create: Tests/WorkspaceDomainTests/WorkspaceExternalSourceAdoptionPlannerTests.swift
- Create: Tests/WorkspaceDomainTests/NoteDraftSequenceRebasePlannerTests.swift
- Modify: Tests/CalendarPersistenceTests/DraftJournalRepositoryTests.swift
- Modify: Tests/CalendarPersistenceTests/JSONWorkspaceRepositoryTests.swift
- Modify: Tests/CalendarPersistenceTests/WorkspaceBackupServiceTests.swift
- Modify: Tests/CalendarPersistenceTests/WorkspaceRepositoryFailureTests.swift
- Create: docs/validation/workspace-v3/task-6-legacy-assertion-map.md
- Create: docs/validation/workspace-v3/task-6-legacy-test-inventory.txt
- Create: Scripts/verify-task6-legacy-assertion-map.sh

**Produces:** One in-memory/store truth, one queued save path, monotonic revisions, focus-routed undo/redo, Journal-first autosave and explicit isolated acceptance data path.

**Consumes:** WorkspaceReducer and JSONWorkspaceRepository.

**Task 6 scoped execution order:** this task is three independently reviewed slices. 6A adds persistence prerequisites and must pass CalendarPersistence before Store production code. 6B adds the typed queue/Store/Journal/undo/resolver while the old CalendarStore remains only as a compile scaffold; no App consumer is half-migrated. 6C migrates every App/test consumer and then deletes all legacy Store/repository/wrapper paths in one final cutover. Each slice gets its own implementation commit and fresh Sol xhigh scoped review; findings are fixed before the next slice starts.

### Task 6A persistence prerequisite contract

- The Journal is a multi-record durable envelope keyed by `DraftJournalIdentity(noteID, editSessionID)`, not one global record. Add `editSessionID` to DraftJournalEntry, PersistableDraftContext and PersistedDraftReceipt. Generation ordering is scoped to one identity; Note A generation 6 never suppresses Note B generation 1. The envelope is canonical-sorted and checksummed, and corrupt/unreadable storage is never treated as absent.
- The current Task 5 single-record file is a versioned legacy DTO, not corrupt data. Decode it only when its complete old shape and checksums are valid; map its entry, pendingReceipt and savedReceipt to the namespaced `.legacyTask5` session case, then atomically replace it with the multi-record envelope. A migration write failure preserves the exact old bytes and reports failure; malformed current or legacy bytes are `invalidJournal`, never absent. New submissions map their UUID to `.editor(uuid)`, so legacy and editor identities cannot collide even when UUID bytes match.
- Lock the public persistence protocol before RED so Store and test doubles share one executable contract:

~~~swift
public struct PersistableDraftContext: Equatable, Sendable {
    public let noteID: NoteID
    public let editSessionID: DraftJournalSessionID
    public let draftGeneration: UInt64
    public let noteSnapshotChecksum: String
    public let persistedNoteRevision: Int64
}

public enum WorkspaceDraftPersistenceVerification: Equatable, Sendable {
    case verified(PersistedDraftReceipt)
    case notPersisted
    case sourceChanged
    case unreadableUnknown
}

public enum WorkspaceReloadedSource: Equatable, Sendable {
    case absent
    case valid(WorkspaceLoadResult)
    case opaqueInvalid(WorkspaceRawSourceIdentity)
    case unreadableUnknown
}

public struct WorkspaceRestorePreview: Equatable, Sendable {
    public let sourceURL: URL
    public let rawSourceData: Data
    public let sourceIdentity: WorkspaceRawSourceIdentity
    public let loadResult: WorkspaceLoadResult
    public let sourceNoteRevisions: [NoteID: Int64]
}

public struct WorkspaceRawRecoveryArtifact: Equatable, Sendable {
    public let rawData: Data
    public let identity: WorkspaceRawSourceIdentity
}

public protocol WorkspaceRepository: Sendable {
    func load() async throws -> WorkspaceLoadResult
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws
        -> WorkspaceSaveReceipt
    func verifyPersistedDraft(_ context: PersistableDraftContext) async throws
        -> WorkspaceDraftPersistenceVerification
    func prepareRestore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) async throws
        -> PreparedWorkspaceRestore
    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) async -> Bool
    func commitRestore(_ prepared: PreparedWorkspaceRestore, state: WorkspaceState) async throws
        -> WorkspaceRestoreOutcome
    func currentDocumentData() async throws -> Data
    func reloadCurrentSourceAfterExternalChange() async throws -> WorkspaceReloadedSource
    func currentRawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact
    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation
}
~~~

  This full protocol supersedes the Task 5 shape in one compile step; remove the old `prepareRestore(WorkspaceRestoreRequest)` and `commitRestore(...)->WorkspaceSaveReceipt` overloads rather than retaining parallel paths. Task 5's checked-off text records the earlier implementation state, while this block is the authoritative post-Task-6 protocol. `BackupService.inspectRestoreSource(_ sourceURL: URL) async throws -> WorkspaceRestorePreview` is a pure read/validate operation and issues no capability. `verifyPersistedDraft` runs under the same coordination lock and distinguishes exact main-file proof, Note mismatch, readable third source and unreadable/unknown probing; only `.verified` authorizes Journal acknowledgement. `WorkspaceRawRecoveryArtifact` carries the exact bytes and identity but is explicitly not a validated backup. `save` rejects a draft context unless its note/session/generation/checksum identify the candidate Note and `context.persistedNoteRevision == state.notes[noteID].revision`; the repository constructs and returns the same exact receipt from that candidate.
- Add one atomic Journal RMW API:

~~~swift
rebaseAndBind(
    expected: DraftJournalIdentityAndGeneration,
    finalCandidateNote: Note,
    receipt: PersistedDraftReceipt
) -> DraftJournalBindingResult // bound | supersededByNewerDraft
~~~

  It validates the old exact record, rewrites its protected snapshot/checksum to the final merged candidate and binds the exact receipt in the same file replacement. Add exact `record`, `unbindPending`, `acknowledgeAlreadyPersisted` and `clear` operations for one identity. No sequence may overwrite a newer generation between rebase and bind.
- WorkspaceReducer emits draftContext only after revision allocation and uses the final candidate Note checksum plus editSessionID. A disjoint merge therefore persists and receipts the merged candidate rather than the stale submitted snapshot. If rebaseAndBind reports a newer Journal record, the older draft transaction performs no main save, publish or undo mutation, never touches the newer Journal record, and returns `draftSuperseded`; it must not persist the superseded candidate without a receipt.
- Identical draft noChange never writes the Workspace. Before exact Journal acknowledgement, WorkspaceRepository verifies under its coordination lock that the currently persisted main file contains the final Note checksum/revision; only that proof may drive `acknowledgeAlreadyPersisted` and clear. Conflict or failed verification preserves the Journal.
- Map every nonverified noChange result explicitly: `.sourceChanged` enters externalSourceChanged(reason: externalBytesChanged), fails queued callers once and preserves the bare Journal entry; `.unreadableUnknown` enters unreadablePrimaryLoadFailed and preserves it; `.notPersisted` enters externalSourceChanged(reason: publishedDraftNotPersisted), because the published state was not proven to match the valid main file. The last case never claims noChange or cleanupPending. Its recovery is explicit reload/adoption of the valid main source followed by re-enqueueing the still-protected Journal entry against that adopted state. Until that succeeds, ordinary commands stay frozen.
- Continuations for those mappings are terminal and exact: sourceChanged and notPersisted return `.externalSourceChanged` for the current head and every already queued caller exactly once, each with its own transaction ID, then reject new ordinary calls immediately in the frozen phase. unreadableUnknown returns `.persistenceBlocked(reason: .unreadablePrimary)` to the current head and every queued caller exactly once, then immediately returns the same typed block for new ordinary calls. None of these paths leaves a continuation suspended or clears the bare Journal entry.
- Split restore inspection from capability issuance. `BackupService.inspectRestoreSource` returns a pure WorkspaceRestorePreview with exact source hash/count/schema, content, per-Note revisions and consistency issues; it does not mutate repository state. `prepareRestore` is called only at the queue head after confirmation and binds the expected preview identity. Add exact `discardPreparedRestore`, invoked on every post-prepare noChange, stale preview, reducer error or cancellation.
- Extend LoadedSource with opaque-invalid exact raw bytes/hash/count. A readable corrupt primary is retained as opaque before load throws; it supports an explicitly labelled raw recovery copy and a verified rollback+CAS restore. An absent primary restores through create-if-absent and returns `rollback: .nonePreviousSourceAbsent`. An unreadable/unknown primary fails closed and is neither absent nor replaceable.
- `reloadCurrentSourceAfterExternalChange()` runs under the same Jelly lock/no-follow probe and wholly rebinds `.absent`, `.valid(rawData, WorkspaceLoadResult)` or `.opaqueInvalid(rawData, identity)`; it returns the typed public projection above. Unreadable remains frozen. `currentRawRecoveryData()` exposes opaque recovery evidence without pretending it is a valid backup. Ordinary `currentDocumentData()` remains envelope-valid only.
- Add WorkspaceExternalSourceAdoptionPlanner with the exact pure signature `plan(current:external:sessionNoteHighWatermarks:) throws -> WorkspaceExternalSourceAdoption`. Its output contains candidate, updated high-watermarks, requiresNormalization and consistencyIssues. Workspace revision is `max(current, source)` when revision-insensitive business content is identical and `checked(max(current, source) + 1)` when it differs. Each surviving Note follows the same per-Note rule; externally deleted Notes still contribute their current/source maximum to the returned ledger, so a later same-ID recreation cannot regress. Overflow is a typed failure. A source with repairable issues is held as an unpublished pending external repair candidate; explicit repair runs against that candidate, then the same normalization planner runs again, and only a successful save publishes candidate and commits the returned ledger. Absent, opaque, unreadable, planner failure and save failure leave published state and ledger unchanged.

### Task 6B queue, Store, Journal and undo contract

- Public requests return the typed WorkspaceTransactionOutcome from the global contract. Reducer noChange/conflict, a deterministically not-committed write and external source change are never collapsed into Void or a generic error. Restore uses `.restored(WorkspaceRestoreOutcome)` so the exact rollback artifact is not lost.
- `retryPendingCommit(transactionID)` returns `PendingCommitRetryOutcome`; it is the only API that can return `.stillPending`. This keeps the original transaction's one-time `commitPending` response distinct from a later explicit retry's committed/notCommitted/sourceChanged terminal result.
- WorkspaceTransactionQueue is MainActor FIFO and reduces only when dequeued against the latest published state. Enqueue allocates a stable transaction ID. Cancellation before append rejects; after append the transaction is non-cancellable. Every caller continuation is resumed exactly once.
- WorkspaceStore receives one deterministic `@Sendable () -> Date` clock and uses one captured instant per dequeued transaction; reducers, completion commands and undo/redo never call Date independently.
- On repository commitUncertain the head performs one immediate reconciliation only. Once a repository pending identity exists, `reconcilePendingCommit` must return `.stillPending(artifacts)` for every unreadable/unknown/lock/decode uncertainty rather than rethrowing a payload-less commitUncertain; this is how the Store obtains rollback evidence for commitPending. If reconciliation is still pending, the head parks with candidate, committed-operation metadata, undo metadata and Journal binding intact; its caller is resumed once with commitPending and its continuation is discarded. No automatic retry loop runs. `retryPendingCommit(transactionID)` is explicit and never resumes the old caller again.
- Pending metadata distinguishes `.save(receipt)` from `.restore(outcome)`. A restore exposes its rollback artifact in the initial commitPending artifacts as soon as rollback creation is verified; a later committed reconciliation returns `.restore(WorkspaceRestoreOutcome)`. notCommitted and sourceChanged also return the already generated rollback artifact, which remains durable recovery evidence and is never silently deleted. An ordinary save has `rollback == nil`.
- A definite direct CAS sourceChanged does not enter pending reconciliation. Once restore rollback creation has begun, JSONWorkspaceRepository throws `WorkspaceDirectCommitFailure.sourceChanged(artifacts)` with the verified rollback file or `.nonePreviousSourceAbsent`; an ordinary save uses the same typed failure with `rollback == nil`. Store converts it to `.externalSourceChanged` and preserves/exposes the artifact. A payload-less `WorkspacePersistenceError.sourceChanged` is removed in Task 6A. RED covers ordinary save, valid/opaque previous-source restore and absent create-race restore.
- Reconciliation terminal matrix is fixed:
  - committed: publish candidate and update undo/redo exactly once even if later Journal cleanup fails; record/clear the exact Journal receipt and release the head with the typed Journal resolution below;
  - notCommitted: do not publish or alter undo, exact-unbind the pending Journal receipt while retaining its entry; only successful unbind releases the head and continues FIFO;
  - sourceChanged: do not publish, exact-unbind while retaining the entry, fail every queued caller exactly once, and enter externalSourceChanged until explicit reload/adoption or verified restore; unbind failure is retained as observable cleanup work rather than misreported as a save failure;
  - stillPending: remain parked with the returned artifacts, without busy-loop or duplicate continuation.
- Journal terminal side effects use a typed `JournalResolutionStatus = .clean | .cleanupPending(identity, step)` where step is record, acknowledge, unbind or clear. Bind is intentionally excluded: bind failure occurs before main save, preserves the bare Journal entry, returns a pre-commit transaction failure and never enters terminal cleanup or releases the candidate through cleanup retry. A committed main file is always published once and returns `.committed(receipt, cleanupPending)` if record/clear fails; it is never rolled back or reported as not saved. noChange exact proof similarly returns `.noChange(reason, cleanupPending)` if acknowledgement/clear fails. Any cleanupPending parks FIFO at `parkedJournalCleanup`; notCommitted/sourceChanged never carry a dirty pending receipt into a later business transaction. `retryJournalCleanup(identity)` retries only the stored exact Journal transition, never calls repository reconciliation, never republishes state and never resumes the already completed original continuation. Success releases a committed/noChange/notCommitted cleanup park and drains FIFO; sourceChanged becomes cleanup-clean but remains frozen until reload/adoption/restore. Another failure remains parked with the same token. Startup resolves: bare entry through locked main verification → acknowledge → clear; pending + main exact receipt → record → clear; pending + definite previous → unbind; saved → clear; unreadable/unknown main or Journal → frozen with bytes untouched.
- Store phases are typed and observable: notLoaded, loading, ready, mutating, parkedCommitUncertain(transactionID), parkedJournalCleanup(identity, step), needsRelationshipRepair, externalSourceChanged(reason), opaquePrimaryLoadFailed, unreadablePrimaryLoadFailed and loadFailed. External-source reasons include externalBytesChanged and publishedDraftNotPersisted. Repair/frozen modes permit only valid backup/raw recovery, reload/adoption, protected-draft replay, restore and exact repairConsistency as applicable; ordinary commands, drafts, undo and redo are rejected.
- Journal terminal status is executable, not a display string:

~~~swift
public enum JournalCleanupStep: Equatable, Sendable {
    case record, acknowledge, unbind, clear
}

public enum JournalResolutionStatus: Equatable, Sendable {
    case clean
    case cleanupPending(identity: DraftJournalIdentity, step: JournalCleanupStep)
}
~~~

- DraftJournalCoordinator persists the entry before enqueue, atomically rebases/binds the final candidate before main save, and applies the exact reconciliation and cleanup matrix. Journal write/bind failure prevents main save; post-commit record/clear failure follows the committed cleanupPending rule above.
- Add pure `NoteDraftSequenceRebasePlanner` with `plan(previousAccepted: PreviousAcceptedDraft, next: NoteDraftSubmission, latest: Note) throws -> NoteDraftSequenceRebaseResult`. For a queued N+1 of the same Journal identity, retain its original base and field delta. Rebase is authorized only when every field changed by the prior accepted N in latest still exactly equals N's accepted after-value; the planner then substitutes that accepted after-value as N+1's new base and replays only N+1's delta. It never merely raises a revision/checksum or replaces a whole Note. A third-party change to the same field remains a typed conflict; disjoint latest changes survive. Store retains the last accepted original-base/accepted-after metadata per active identity until no queued generation depends on it. Tests cover suspended N followed by same-field N+1, disjoint N+1, and a third-party same-field edit between them.
- WorkspaceUndoRecord is a reversible optimistic write-set, not a whole-Workspace restore. It stores revision-insensitive before/after business projections only for touched fields in the calendar subgraph, Notes, Inspirations and relation/link entries, plus per-Note revision high-watermarks. Note structural create/delete entries additionally store the expected incarnation revision at materialization; independent same-ID recreation therefore conflicts even if its business content is identical. `WorkspaceUndoReducer.apply` compares ordinary field projections while ignoring revision/updatedAt bookkeeping, but compares structural lifecycle entries against exact absence or the expected incarnation. It applies inverse/forward deltas to the latest state and returns both candidate and a remapped reverse record whose expected projection/incarnation matches the newly materialized values. This makes immediate redo and repeated undo legal after new revisions are allocated. Unrelated later Note drafts survive calendar-only undo; a later edit to a touched field conflicts. Store keeps a session Note revision ledger including deleted Notes as max-seen revisions; same-ID recreation advances from that ledger. Workspace revision is checked current+1 for each successful undo/redo; affected Notes use checked ledger+1, untouched Notes keep their revisions. Overflow, validation, touched-value/incarnation conflict or persistence failure leaves state, both stacks and ledger byte-for-byte/Equatable unchanged; a new transaction clears redo only after successful persistence.
- Calendar `.updateItem` is normalized at dequeue to preserve latest `completedAt`; completion is owned only by the dedicated completion command. Add both queue order REDs so an old editor payload cannot reopen/complete a task accidentally.
- EditorFocusRegistry weakly holds the focused UndoManager and pairs it with an owner token. Undo/redo routing returns `.noFocusedOwner`, `.focusedPerformed` or `.focusedUnavailable`: only `.noFocusedOwner` permits WorkspaceStore fallback; an alive focused manager with an empty/disabled stack returns `.focusedUnavailable` and consumes/disables the command, never undoing the workspace. If the weak manager is released, the registry first clears that exact owner token and may then return `.noFocusedOwner`. A stale blur/deinit from Editor A cannot clear Editor B. Commands expose Command-Z and Shift-Command-Z; observable canUndo/canRedo switches with focus ownership and follows the focused editor, otherwise WorkspaceStore.
- BackupCommands owns no repository. It calls Store methods only: exportBackup, inspectRestoreSource, restore(preview:rollbackDirectoryURL:), exportRawRecoveryCopy, retryPendingCommit and retryJournalCleanup. Restore returns typed receipt plus rollback artifact so UI never claims a rollback file for an absent previous source.
- Explicit external adoption publishes directly only when the source is valid, has no consistency issues, `external.provenance.sourceSchema == 3`, `candidate == external.state` and `requiresNormalization == false`. Otherwise the candidate and returned ledger remain unpublished until normalization save succeeds. External repair runs first against the held external candidate, then re-runs the same planner; planner overflow, validator failure or save failure keeps published state and the session ledger unchanged.

### Task 6C App cutover and data-directory contract

- AppDataURLs explicitly contains root, mainDocument, migrationSnapshotDirectory, recoveryManifest, draftJournal, rollbackDirectory and automaticRecoveryDirectory. A trimmed nonempty JELLY_ACCEPTANCE_DATA_DIRECTORY must be an absolute non-root path, is standardized and created without modifying HOME, and fails closed if it is a file, cannot be searched/written, or resolves through a symlink escape. User-selected export destinations remain outside this automatic-sidecar root.
- WorkspaceStore exposes WorkspaceState as `state`, CalendarState as read-only `calendarState`, sendWorkspace and sendCalendar wrappers, typed phase/errors/outcomes, statePublicationGeneration, undo/redo availability and the repair/recovery methods above. All Calendar views read calendarState; no compatibility alias named CalendarStore remains after cutover.
- CategoryManagerViewModel sends only Workspace create/update/reorder/delete category commands. Raw Calendar category commands remain rejected.
- Before editing the legacy tests, capture their exact 25 + 14 `@Test` function names in `task-6-legacy-test-inventory.txt`. Maintain `task-6-legacy-assertion-map.md` with exactly one row per inventory name. `Scripts/verify-task6-legacy-assertion-map.sh --inventory` verifies inventory counts/uniqueness and, while old files exist, exact extraction; it permits targets marked `UNMAPPED`. `--complete` rejects missing/blank/UNMAPPED/duplicate targets and verifies every mapped target test exists in Tests. Preflight runs only `--inventory`; deletion requires `--complete` plus green mapped targets, and final post-deletion verification again runs `--complete` from the committed inventory.

- [x] Preflight before implementation: inventory every production/test reference across Sources and Tests, record exact counts, capture the 25 + 14 legacy test names in the committed inventory, create one `UNMAPPED` row per legacy name, and make the script's `--inventory` mode pass against the still-present legacy files. Do not run `--complete`, create any Task 6B test or add any Store production file during 6A.

~~~zsh
rg -n 'CalendarStore|CalendarRepository|JSONCalendarRepository|InMemoryCalendarRepository' Sources Tests
~~~

- [x] **Task 6A RED only:** write persistence/domain prerequisite tests for multi-Note/session Journal records and deterministic legacy single-record migration; disjoint-merge final-candidate context and atomic rebase+bind; conflict/noChange/superseded generation; exact actor-level record/acknowledge/unbind/clear failure atomicity and durability; corrupt/unreadable Journal; pure restore preview/cancel/discard; absent and opaque-primary restore; raw recovery export; unreadable fail-closed; reload valid/opaque/absent/unreadable external sources; lower-revision adoption, deleted-Note ledger, overflow and external repairable issues. Store publication/save-failure nonpublication, parking, continuation and terminal cleanup orchestration belong only to 6B. Run these REDs before editing production, then implement 6A without creating WorkspaceStore, WorkspaceTransactionQueue, DraftJournalCoordinator or any 6B test file.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceExternalSourceAdoptionPlannerTests
./Scripts/test.sh --filter CalendarPersistenceTests.DraftJournalRepositoryTests
./Scripts/test.sh --filter CalendarPersistenceTests.JSONWorkspaceRepositoryTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceBackupServiceTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceRepositoryFailureTests
~~~

- [x] **Task 6A GREEN/review/commit:** implement only the 6A persistence prerequisites: multi-record Journal with atomic rebase/bind/unbind and legacy migration, final-candidate draft context, verified noChange, pure restore preview/discard, opaque/absent restore, raw recovery copy, external-source reload and adoption planner. Run WorkspaceDomainTests, CalendarPersistenceTests and full tests. Obtain fresh Sol xhigh scoped review, fix every Critical/Important finding, rerun, and commit 6A before any 6B RED lands.
- [x] **Task 6B RED only after the reviewed 6A commit:** create queue/Store/Coordinator/undo/focus/resolver tests for failure-before-publish, two queued commands, pre/post-enqueue cancellation, every continuation exactly once, verified noChange causing no save/revision/undo, all three nonverified noChange mappings, edit-save while calendar mutates, sequential generations while save is suspended, calendar-save while typing continues, every Journal cleanup failure, the complete commitUncertain park/retry terminal matrix including restore rollback artifacts, queued restore of older V3/V2/V1 concurrent with a newer draft, restore failure-before-publish, restart after restore preserving normalized revisions, old receipt late arrival, consistency repair mode, sourceChanged reload/adoption and adoption-save failure nonpublication, opaque/unreadable load, optimistic delta undo/redo, revision overflow and owner-token editor focus routing. Include create→undo→redo→undo, delete→undo→redo→undo, same-ID recreation conflict, unrelated draft survival, same-field late conflict, weak UndoManager deallocation/focus transfer/fallback, and old `.updateItem` completion payload queue order.

~~~swift
@Test func queuedDraftReducesAfterCalendarMutationAgainstLatestState() async throws {
    let repository = SuspendedWorkspaceRepository()
    let store = WorkspaceStore(initialState: fixture, repository: repository, journal: journal, clock: clock)
    async let first = store.sendCalendar(.createItem(item), undoLabel: "新建事项")
    await repository.waitUntilSaveStarted()
    async let second = store.submitDraft(generation6)
    await repository.resumeSave()
    #expect(try await first == .committed(expectedCalendarReceipt, journal: .clean))
    #expect(try await second == .committed(expectedDraftReceipt, journal: .clean))
    #expect(store.calendarState.items[item.id] == item)
    #expect(store.state.notes[noteID]?.title == generation6.snapshot.title)
}

@Test func undoCreatesNewMonotonicRevisions() async throws {
    _ = try await store.sendWorkspace(noteEdit, undoLabel: "编辑笔记")
    let workspaceRevision = store.state.revision
    let noteRevision = store.state.notes[noteID]!.revision
    _ = try await store.undo()
    #expect(store.state.revision == workspaceRevision + 1)
    #expect(store.state.notes[noteID]!.revision == noteRevision + 1)
}
~~~

- [x] Run the Task 6B RED set. These files do not exist during 6A, so SwiftPM can compile and green the 6A test targets independently.

~~~zsh
./Scripts/test.sh --filter WorkspaceDomainTests.WorkspaceUndoReducerTests
./Scripts/test.sh --filter WorkspaceDomainTests.NoteDraftSequenceRebasePlannerTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceStoreTests
./Scripts/test.sh --filter CalendarAppTests.DraftJournalCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.AppDataDirectoryResolverTests
~~~

- [x] Implement WorkspaceTransactionQueue with the fixed typed FIFO/park/retry/continuation matrix. It must never busy-loop, suspend a caller forever, resume twice, or start a later head while one is parked.
- [x] Implement WorkspaceStore with state/calendarState projections, typed outcomes/phases, sendWorkspace/sendCalendar, consistency repair mode, external reload/adoption and Store-owned backup/recovery APIs. sendCalendar creates WorkspaceCommand.calendar and follows the same reducer/validator/repository path.
- [x] Route restore as inspect without capability → user confirmation → queue head reduce against latest preview → exact prepare → commitRestore. Discard any issued capability on every non-commit path. Successful restore publishes once and clears incompatible undo/redo only after disk replacement; failure keeps state/stacks unchanged. A draft queued after restore reduces against the restored latest state and remains protected/conflicted rather than disappearing.
- [x] A Note draft applies only its modifiedFields to the latest Note. Disjoint changes use final-candidate Journal rebase; same-field change becomes typed conflict and remains protected. Sequential generations in the same edit session rebase on the last applied generation, while a newer Journal record prevents an older transaction from touching its receipt. A draft never overwrites the entire latest Note or Workspace because its original snapshot is older.
- [x] Implement failure semantics: reducer/validator/repository failure leaves published state, revision and undo stacks unchanged; successful save publishes once and then updates undo/redo metadata.
- [x] Implement WorkspaceUndoRecord and pure WorkspaceUndoReducer as the optimistic reversible write-set and revision-ledger contract above. Undo/redo are queued persisted transactions; touched-value conflict, validation, overflow or persistence failure leaves state/stacks byte-for-byte/Equatable unchanged.
- [x] Replace global undo routing with owner-token editor focus priority for both undo and redo.

~~~swift
@MainActor
final class EditorFocusRegistry: ObservableObject {
    func register(_ manager: UndoManager, ownerID: UUID)
    func clear(ownerID: UUID)
    func routeUndo() -> EditorUndoRouteResult
    func routeRedo() -> EditorUndoRouteResult
}

enum EditorUndoRouteResult: Equatable, Sendable {
    case noFocusedOwner
    case focusedPerformed
    case focusedUnavailable
}

func performUndo() {
    if focusRegistry.routeUndo() == .noFocusedOwner {
        Task { _ = try await workspaceStore.undo() }
    }
}

func performRedo() {
    if focusRegistry.routeRedo() == .noFocusedOwner {
        Task { _ = try await workspaceStore.redo() }
    }
}
~~~

- [x] Implement DraftJournalCoordinator ordering with the multi-record atomic rebase/bind contract. Persist before enqueue; bind final candidate before save; record only returned/reconciled receipt; exact-unbind notCommitted/sourceChanged; clear only the exact saved identity/generation/checksum/revision. A parked commit retains the binding. Journal clear failure preserves the saved receipt for restart.
- [x] Add AppDataDirectoryResolver and AppDataURLs with the strict override and sidecar-path contract above. Default remains Application Support/PersonalCalendar. Never alter HOME.

~~~swift
enum AppDataDirectoryResolver {
    static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> AppDataURLs
}
~~~

- [x] **Task 6B GREEN/review/commit:** run WorkspaceDomainTests, CalendarPersistenceTests, focused CalendarApp Store tests and full tests. Obtain fresh Sol xhigh review focused on queue continuation/park/retry, Journal cleanup, failure publication, repair/adoption, sequential generation delta replay, multi-round delta undo revisions and focus ownership; fix every Critical/Important finding, rerun, and commit while WorkspaceStore remains dormant and unconstructed by the App composition root.
- [x] **Task 6C cutover:** only after the reviewed 6B commit, port every row in the assertion map, replace InMemoryCalendarRepository with InMemoryWorkspaceRepository across TestSupport, and migrate MonthView, WeekView, DayDrawer, editors, drag/drop, progress, categories, backup/restore, AppEnvironment, PersonalCalendarApp and all tests to WorkspaceStore in one consumer cutover. Views read calendarState; CategoryManagerViewModel sends Workspace category commands; BackupCommands calls Store only.
- [x] Remove the deprecated Calendar-only BackupService export/validate/restore wrappers after BackupCommands and WorkspaceStore use prepareRestore/queued commitRestore. Port their useful tests to WorkspaceBackupServiceTests before deletion.
- [x] Complete and verify every row in the 39-row legacy assertion map with `Scripts/verify-task6-legacy-assertion-map.sh --complete`, run every mapped target, then in the same final cutover delete CalendarStore, CalendarRepository, JSONCalendarRepository, InMemoryCalendarRepository, their old tests and all deprecated wrappers. Run `--complete` again after deletion from the committed inventory. Do not leave aliases, compatibility shims or a second business save path.
- [x] Run GREEN, all existing app tests and release compile.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.WorkspaceStoreTests
./Scripts/test.sh --filter CalendarAppTests.DraftJournalCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.AppDataDirectoryResolverTests
./Scripts/test.sh --filter CalendarPersistenceTests
./Scripts/test.sh --filter CalendarAppTests
./Scripts/test.sh
./Scripts/verify-task6-legacy-assertion-map.sh --complete
! rg -n 'CalendarStore|CalendarRepository|JSONCalendarRepository' Sources Tests
! rg -n 'InMemoryCalendarRepository' Sources Tests
swift build -c release
git diff --check
~~~

- [x] Request fresh Sol xhigh final Task 6 review focused on single-store ownership, all 39 legacy assertion mappings, Calendar behavior preservation, queue/Journal/restore UI wiring and dead-path removal; fix every Critical/Important finding and rerun CalendarAppTests, CalendarPersistenceTests, full tests and release build.
- [x] Commit the 6A persistence prerequisite, 6B Store core and 6C cutover as separately reviewable commits; add one final tracking commit only after all Task 6 checkboxes and gates pass.

~~~zsh
git add Sources/CalendarApp Sources/CalendarPersistence Sources/WorkspaceDomain Tests/CalendarAppTests Tests/CalendarPersistenceTests Tests/WorkspaceDomainTests Scripts/verify-task6-legacy-assertion-map.sh docs/validation/workspace-v3/task-6-legacy-assertion-map.md docs/validation/workspace-v3/task-6-legacy-test-inventory.txt
git commit -m "refactor(app): 切换为唯一工作空间存储与串行保存"
~~~

## Task 7: Add a Feature-Gated App Shell and Preserve Calendar Behavior

**Files**

- Create: Sources/CalendarApp/AppShell/AppShellView.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceRoute.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceNavigationRail.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceRouteState.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceCommands.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceNewItemRouter.swift
- Create: Sources/CalendarApp/Calendar/CalendarModuleView.swift
- Create: Sources/CalendarApp/Calendar/CalendarNewItemRequestPolicy.swift
- Modify: Sources/CalendarApp/AppEnvironment.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Modify: Sources/CalendarApp/Month/MonthView.swift
- Modify: Sources/CalendarApp/DayDrawer/DayDrawerView.swift
- Create: Tests/CalendarAppTests/WorkspaceNavigationTests.swift
- Create: Tests/CalendarAppTests/WorkspaceWindowLayoutTests.swift
- Create: Tests/CalendarAppTests/WorkspaceCommandRoutingTests.swift
- Modify: Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift

**Produces:** Fixed narrow icon rail, route persistence, Command-1/2/3, 1044pt minimum width and an unchanged calendar module.

**Consumes:** WorkspaceStore and existing MonthView.

- [ ] **Task 7A Core RED:** write tests for route order, Chinese help/accessibility metadata, warm selected and inactive appearance tokens, stable Command-1/2/3 mapping, route-aware Command-N requests, UI-only preference normalization/writeback, independent route selection state, 64pt rail width, 980pt Calendar content width, 1044pt shell/window minimum and feature-gated visible routes. Automated metadata tests do not count as real hover or VoiceOver validation. Stable view-host lifetime belongs to 7B, after the host exists.

~~~swift
@Test func unfinishedRoutesAreNotClickable() {
    let features = WorkspaceFeatures(notes: false, inspiration: false)
    #expect(WorkspaceRoute.visibleRoutes(features) == [.calendar])
    let preferences = SpyWorkspaceRoutePreferenceStore(initial: "calendar")
    let state = WorkspaceRouteState(features: features, preferences: preferences)
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

@Test func persistedDisabledOrUnknownRouteNormalizesAndWritesBackCalendar() {
    let features = WorkspaceFeatures.calendarOnly
    let preferences = SpyWorkspaceRoutePreferenceStore(initial: "notes")
    let state = WorkspaceRouteState(features: features, preferences: preferences)
    #expect(state.route == .calendar)
    #expect(preferences.writes == ["calendar"])
}

@Test func calendarNewItemUsesOneRequestAndStableDatePrecedence() {
    let router = WorkspaceNewItemRouter()
    let request = router.requestNewItem(route: .calendar, features: .calendarOnly)
    #expect(router.consume(request!.id, route: .calendar) != nil)
    #expect(router.consume(request!.id, route: .calendar) == nil)
    #expect(CalendarNewItemRequestPolicy.resolve(
        dayDrawerDate: drawerDate,
        selectedDate: selectedDate,
        today: today,
        isQuickCreatePresented: false,
        isItemEditorPresented: false
    ) == drawerDate)
}
~~~

- [ ] `WorkspaceFeatures.production` is the only production feature truth and defaults to `.calendarOnly`. `AppEnvironment.features = .production`, and AppEnvironment tests assert the preset; `WorkspaceNewItemRouter` is UI-session state created by PersonalCalendarApp, not part of the persistence environment. UserDefaults, environment variables and user actions must not enable unfinished modules. Task 10 may enable Notes only after its real loop is complete; Task 13 may enable the complete Workspace only after Inspiration is complete. Disabled routes are not visible, instantiated, selectable or shortcut-activated.
- [ ] Define injectable UI-only `WorkspaceRoutePreferenceStore`; its production adapter uses only UserDefaults key `workspace.selectedRoute`. `WorkspaceRouteState` owns only `route`: unknown/persisted-disabled values normalize to Calendar and write `calendar` exactly once; successful activation writes the target raw value once; rejected disabled activation changes neither route nor storage. Feature Gate state itself never reads or writes UserDefaults. Cover initialization fallback, accepted write and rejected zero-write with a spy store.
- [ ] `WorkspaceCommands` is the only owner of Command-1/2/3/N. It adds navigation commands and replaces `.newItem` without touching `.undoRedo` or `EditorFocusRegistry`. `WorkspaceNewItemRouter` emits only one-shot `(route, requestID)` requests and never receives Calendar dates or editor state. Remove DayDrawer's `.keyboardShortcut("n")` but keep its button; Rail buttons install no shortcuts. MonthView first consumes a matching request exactly once, then pure `CalendarNewItemRequestPolicy` returns nil when quick-create/item editor is already presented, otherwise resolves `selectedDayDrawerDate ?? model.selectedDate ?? model.today`. A draft-blocked request stays consumed and never replays after the editor closes; wrong-route consumers do not consume it. Command-2/3 remain stable mappings but do nothing while gated off.
- [ ] Run Task 7A RED, implement Route/Features/RouteState/layout constants/NewItemRouter/CalendarNewItemRequestPolicy, run focused GREEN and an intermediate build before creating Shell views.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.WorkspaceNavigationTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceWindowLayoutTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceCommandRoutingTests
swift build
~~~

- [ ] **Task 7B Wiring:** implement AppShell with `HStack(spacing: 0)`, a fixed 64pt leading Rail and CalendarModuleView retaining exactly the existing 980pt content minimum. Draw the divider inside the Rail so it adds no layout width. AppShell/window min width is 1044 and min height remains 680; keep the existing window ID, default size, Store load task and appearance binding, and set `.windowResizability(.contentMinSize)`. Move the current 1044 frame off MonthView to the shell boundary.

~~~swift
struct WorkspaceFeatures: Equatable, Sendable {
    var notes: Bool
    var inspiration: Bool
    static let calendarOnly = Self(notes: false, inspiration: false)
}
~~~

- [ ] Wrap MonthView without changing internal layout, gestures, continuous scrolling, DayDrawer, create/edit overlay or category sheet. Route state owns only current route; each module owns its own selection and scroll state.
- [ ] In Task 7B, AppShell retains one stable host lifetime for every enabled module and switches visibility only; hidden hosts disable hit testing and are accessibility-hidden. Feature-disabled module builders are invoked zero times and no `EmptyView`/placeholder page may satisfy route exhaustiveness. Use injectable sentinel modules to prove object identity, selection and scroll tokens survive route round trips, and explicitly test inactive-host interaction/accessibility flags; repeat with real Calendar↔Notes in Task 10.
- [ ] Rail descriptors use Chinese help/VoiceOver names 日历、笔记、灵感. Selected state uses `theme.rangePreviewFill` in a rounded tile plus selected trait/non-color accessibility value; Rail background uses `theme.elevatedSurface`; inactive icons use `theme.secondaryText`. Only enabled route buttons are constructed.
- [ ] Run GREEN plus focused interaction regressions, full CalendarAppTests and release build. Confirm static uniqueness: only AppEnvironment constructs WorkspaceStore, only WorkspaceCommands owns 1/2/3/N and DayDrawer/Rail own no duplicate shortcuts.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.WorkspaceNavigationTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceWindowLayoutTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceCommandRoutingTests
./Scripts/test.sh --filter CalendarAppTests.CalendarInteractionCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.WeekRowPresentationTests
./Scripts/test.sh --filter CalendarAppTests
swift build -c release
git diff --check
~~~

- [ ] Build a fresh packaged artifact, verify its signature, then launch that exact bundle with an isolated `JELLY_ACCEPTANCE_DATA_DIRECTORY`; verify real tooltip hover, 1044pt minimum resize, warm selected tile and unchanged Calendar create/edit/scroll/DayDrawer basics. Record VoiceOver as unverified until the final accessibility Gate unless it is actually run; metadata tests alone must not claim live VoiceOver success.

~~~zsh
./Scripts/build-app.sh
codesign --verify --deep --strict dist/Jelly.app
acceptance_root="$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)jelly-task7-gui.XXXXXX")"
open -n --env "JELLY_ACCEPTANCE_DATA_DIRECTORY=$acceptance_root" dist/Jelly.app
~~~

- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/AppShell Sources/CalendarApp/Calendar Sources/CalendarApp/AppEnvironment.swift Sources/CalendarApp/Month/MonthView.swift Sources/CalendarApp/DayDrawer/DayDrawerView.swift Sources/CalendarApp/PersonalCalendarApp.swift Tests/CalendarAppTests
git commit -m "feat(app): 增加工作空间导航外壳"
~~~

## Task 8: Implement the Pure Block Input State Machine

**Files**

- Create: Sources/CalendarApp/Notes/BlockEditor/BlockInputReducer.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockEditorSelection.swift
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockPasteParser.swift
- Create: Tests/CalendarAppTests/BlockEditorInputTests.swift
- Create: Tests/CalendarAppTests/BlockEditorPurityGateTests.swift
- Create: Scripts/verify-block-input-purity.sh

**Produces:** UI-independent commands for Enter, Shift-Enter, Backspace, Tab, Shift-Tab, arrows, slash conversion, paste, multi-block deletion and drag reorder.

**Consumes:** WorkspaceDomain BlockDocument and BlockDocumentValidator.

- [ ] Keep all Task 8 production types `internal` to CalendarApp and test them through `@testable import CalendarApp`. The three pure implementation files may import only `Foundation` and `WorkspaceDomain`; they must not import AppKit or SwiftUI. Do not depend on WorkspaceDomain's internal `supportsIndentation`, `isEmpty`, `canonicalCodeInfoString` or local-validator helpers: use exhaustive Task 8 switches/helpers over the public model. Task 9 alone owns AppKit `NSRange` and `NSAttributedString` adaptation.

- [ ] Define a direction-preserving, grapheme-based selection contract. Reducer offsets count extended grapheme clusters, never UTF-16 code units. A divider accepts only offset zero. Anchor/focus direction is preserved in the value; commands derive a normalized range from current document order without rewriting the stored direction. Pointer selection and every edit or horizontal move clear `preferredColumn`; consecutive vertical moves preserve it.

~~~swift
struct BlockTextPosition: Equatable, Sendable {
    let blockID: BlockID
    let graphemeOffset: Int
}

struct BlockTypingAttributes: Equatable, Sendable {
    var marks: Set<InlineMark>
    var linkURL: URL?
}

enum BlockEditorSelection: Equatable, Sendable {
    case text(
        anchor: BlockTextPosition,
        focus: BlockTextPosition,
        preferredColumn: Int?,
        typingAttributes: BlockTypingAttributes
    )
    case blocks(anchor: BlockID, focus: BlockID)
}
~~~

- [ ] Define the complete command, environment, result, clipboard and typed-error interfaces before production behavior. `BlockIDSource.fixed` is consumed deterministically inside one reduce call; every inserted or fallback Block receives the next ID. Exhausted IDs, duplicate supplied IDs or collision with an existing Block ID throw before publishing any candidate. Never call `BlockDocument.empty()` from the reducer.

~~~swift
enum BlockHorizontalDirection: Equatable, Sendable { case backward, forward }
enum BlockVerticalDirection: Equatable, Sendable { case up, down }

enum BlockInputCommand: Equatable, Sendable {
    case insertText(String)
    case enter
    case softBreak
    case backspace
    case indent
    case outdent
    case moveHorizontal(BlockHorizontalDirection, extending: Bool)
    case moveVertical(BlockVerticalDirection, extending: Bool)
    case convert(BlockKind)
    case applyMarkdownShortcut
    case applySlashConversion(BlockKind)
    case toggleInlineMark(InlineMark)
    case setLink(URL?)
    case copySelection
    case cutSelection
    case replaceSelection(BlockPastePayload)
    case deleteSelection
    case moveBlockRoots([BlockID], before: BlockID?)
}

struct BlockInputEnvironment: Sendable {
    let isComposingText: Bool
    let idSource: BlockIDSource
}

enum BlockInputMutation: Equatable, Sendable {
    case none(BlockInputNoChangeReason)
    case selectionOnly
    case document
}

enum BlockInputNoChangeReason: Equatable, Sendable {
    case composingText
    case documentBoundary
    case textSystemOwnsMovement
    case unsupportedBlockKind
    case emptySelection
    case missingListParent
    case indentationLimit
    case samePosition
}

enum BlockInputEffect: Equatable, Sendable {
    case handled
    case deferToTextSystem
    case writeClipboard(BlockClipboardPayload)
}

enum BlockUndoDirective: Equatable, Sendable {
    case none
    case breakCoalescing
    case coalesceTyping(BlockID)
    case atomic(BlockUndoAction)
}

enum BlockUndoAction: Equatable, Sendable {
    case enter
    case softBreak
    case backspace
    case indentation
    case conversion
    case formatting
    case link
    case cut
    case paste
    case deletion
    case drag
}

struct BlockInputResult: Equatable, Sendable {
    let document: BlockDocument
    let selection: BlockEditorSelection
    let mutation: BlockInputMutation
    let effect: BlockInputEffect
    let undo: BlockUndoDirective
}

enum BlockInputError: Error, Equatable, Sendable {
    case invalidInputDocument
    case invalidSelection
    case insufficientBlockIDs
    case duplicateBlockID(BlockID)
    case invalidLink
    case invalidMove
    case invalidCandidate
}
~~~

`BlockInputEffect.handled` means the key/command was consumed and has no external side effect. Every non-composition no-change returns `.handled`; composition defer returns `.deferToTextSystem`; copy/cut return `.writeClipboard`. A thrown `BlockInputError` returns no `BlockInputResult` at all.

- [ ] Define Task 8's AppKit-free paste and clipboard values. Payloads never contain Block IDs, fonts, colors, paragraph styles or completion timestamps. Task 9 converts `NSAttributedString` into these values; unsupported attributes lose styling only, never characters. A pasted task always starts with `completedAt == nil`.

~~~swift
enum BlockPastePayload: Equatable, Sendable {
    case plainText(String)
    case richText(blocks: [BlockPasteBlock], fallbackPlainText: String)
}

struct BlockPasteBlock: Equatable, Sendable {
    let kind: BlockKind
    let inlineContent: InlineContent
    let indentLevel: Int
    let codeInfoString: String?
}

struct BlockClipboardPayload: Equatable, Sendable {
    let plainText: String
    let richBlocks: [BlockPasteBlock]
}

enum ParsedBlockPastePayload: Equatable, Sendable {
    case plainLines([String])
    case richBlocks([BlockPasteBlock])
}

enum BlockPasteParserError: Error, Equatable, Sendable {
    case invalidBlock(index: Int)
    case invalidIndent(index: Int)
    case invalidLink(index: Int)
    case invalidCodeInfo(index: Int)
}

protocol BlockPasteParsing {
    static func parse(_ payload: BlockPastePayload) throws -> ParsedBlockPastePayload
}
~~~

`BlockPasteParser` is an internal namespace that conforms to `BlockPasteParsing` with a complete implementation in `BlockPasteParser.swift`; do not land the illegal body-less enum declaration shown in the rejected Gate. Plain text parsing cannot fail. Rich parsing is all-or-nothing and reports the first indexed `BlockPasteParserError`; the reducer catches any rich parse/validation error and reparses the exact `fallbackPlainText` as plain text, without consuming IDs or publishing a partial rich candidate. A fallback candidate that cannot validate throws `BlockInputError.invalidCandidate`.

- [ ] Write RED selection and Unicode tables before production code. A text position's offset is measured over the grapheme sequence of the Block's concatenated span text; mapping back to spans preserves original span boundaries, including adjacent equal and zero-length spans. Cover same-Block and cross-Block forward/reverse text selections, Block selection, missing IDs, negative/out-of-range offsets, collapsed typing attributes and preferred-column reset/preservation. Repeat split, delete, format, link and paste with ASCII, Chinese, `e` plus combining acute, flag emoji, skin-tone emoji and a ZWJ family. Task 8 itself must expose no `NSRange`; Task 9 owns the hosted UTF-16 bridge matrix specified below.

- [ ] Write RED `Enter`/`softBreak`/`Backspace` tables for every Block kind, empty/nonempty content, collapsed caret at start/middle/end and nonempty selection. Lock these behaviors:
  - paragraph splits to paragraph; headings keep the left heading and create a right paragraph, while an empty heading changes its existing ID to paragraph without allocating an ID;
  - bullet/ordered/task split to the same kind and indent, with a new task `completedAt == nil`; an empty list/task changes its existing ID to paragraph; a task retains `completedAt` only while that same Block remains task, and every conversion away clears it;
  - a nonempty quote splits to quote, while an empty quote changes its existing ID to paragraph;
  - Enter in code follows the authoritative §5.2 rule and splits into two code Blocks: the left preserves its ID, the right consumes one ID, both inherit the exact canonical `codeInfoString`, and task state remains nil. SoftBreak alone inserts `\n` into the same code Block and allocates no ID; code Tab/Shift-Tab behavior is tested separately;
  - a link split keeps the left as link only if its remaining spans still contain a valid URL, otherwise changes it to paragraph; the right side is paragraph. Empty link becomes paragraph. Divider Enter inserts one empty paragraph after the divider and selects it;
  - softBreak inserts `\n` only into text-capable Blocks and is a typed no-change for divider;
  - Backspace with a nonempty selection delegates to the atomic delete rule; inside content it deletes exactly one preceding grapheme. At offset zero, an empty special Block first changes its existing ID to paragraph and clears task/code/link-only metadata; a first paragraph is no-change; otherwise merge into the previous text-capable Block, or remove an immediately preceding divider before retrying the merge position. No path may split a grapheme or leave an invalid local Block.

- [ ] Write RED indentation and movement tables. List/task indent is clamped to 0...3 and may increase only when the preceding continuous list group contains a valid parent at the target level; outdent and indent move each selected root with all of its consecutive descendants. Mixed list kinds still use structural level, not visual marker equality. In code, Tab inserts four spaces at each selected logical line and Shift-Tab removes at most four leading spaces per selected logical line without changing `indentLevel`; other kinds are typed no-change. Horizontal movement crosses Block boundaries without leaving the document. With a nonempty text selection and `extending == false`, backward collapses to normalized start and forward to normalized end without an extra grapheme step; `extending == true` keeps the original anchor and advances only focus. Vertical movement stays deferred to the text system inside an internal logical line and only crosses Blocks at a logical boundary. On the first reducer-owned vertical move with `preferredColumn == nil`, record the source caret's logical-line grapheme column before clamping to the target line; consecutive up/down moves retain that original column, including long→short→long, while horizontal movement, edit and pointer selection clear it. Document edges are typed no-change. After any collapsed movement, typing attributes are derived from the character immediately before the caret, otherwise the character immediately after it, otherwise the pre-move typing attributes for an empty Block. A moved or collapsed selection never keeps an invalid link URL.

- [ ] Write RED Markdown/IME tables. While `environment.isComposingText` is true, `insertText`, Enter, softBreak, Backspace, shortcut/slash conversion and structural arrow commands return the unchanged document/selection with `.none(.composingText)`, `.deferToTextSystem` and `.none` undo. After composition commits, Task 9 sends the complete replacement as one `.insertText`. Supported Markdown prefixes are exactly `# `, `## `, `### `, `- `, `* `, `1. `, `[] `, `[ ] `, `> ` and triple-backtick plus optional code info; conversion removes only the recognized prefix, preserves the Block ID, is disabled outside a leading collapsed paragraph caret and never fires for a partial/unrecognized prefix. Slash conversion is an explicit confirmed command; Escape is handled by Task 9 and leaves the slash query text unchanged.

- [ ] Write RED inline/link and typing-attribute tables before implementation. Toggle adds the mark to the whole normalized selection unless every covered character already has it, in which case it removes it. Split spans only at selection boundaries; preserve all out-of-selection spans, adjacent equal spans and zero-length spans exactly. Collapsed selection changes typing attributes only. A collapsed `.insertText` creates/replaces text with the current typing marks/link, then keeps those attributes for subsequent coalesced typing; a range replacement uses the selection's typing attributes for all inserted text. `setLink(nil)` preserves text; when a link Block loses its final URL, change that Block's existing ID to paragraph. Match WorkspaceDomain validation exactly: a non-nil link is valid only when `scheme != nil && host != nil`; relative, scheme-only, `mailto:` and control-character values are rejected before mutation. Code/divider and any range crossing an unsupported kind must be a whole-command typed no-change, never partial formatting. Forward and reverse ranges produce the same document and leave a collapsed caret at normalized start with attributes derived by the caret-affinity rule above.

- [ ] Write RED copy/cut/delete/paste tables. Copy emits `.writeClipboard` and no document mutation/undo; clipboard payloads contain no IDs. A collapsed text selection returns `.none(.emptySelection)`. A Block selection normalizes its inclusive anchor/focus range, and copy/cut/delete operate on those complete Blocks; cut and delete also include each selected list root's consecutive descendants exactly once. Cut emits one clipboard effect, one document mutation and one atomic undo. Cross-Block text deletion preserves the prefix of normalized start plus suffix of normalized end in the start Block, removes covered Blocks, and leaves one collapsed caret there. If the operation removes every Block, consume one injected ID and create exactly one empty paragraph. Plain text paste is not parsed as Markdown: normalize CRLF/CR to LF, insert the first segment at the selection start, create a paragraph per subsequent physical line including leading/trailing/consecutive empty segments, and append the replaced end suffix to the final inserted Block.

- [ ] Lock rich replacement as a deterministic block splice rather than guessing inline structure:
  - Task 9 writes a private Jelly pasteboard type containing encoded `BlockClipboardPayload` for same-app copy/cut. External `NSAttributedString` has no Block structure: split its exact string on normalized physical newlines into paragraph `BlockPasteBlock`s, keep only supported inline marks/links, set indent zero/code info nil, and pass the full original string as `fallbackPlainText`. Unsupported attributes lose style only. If the custom payload cannot decode or any rich block fails validation, use its complete plain pasteboard string as `.plainText`; never invent heading/list/task/code structure from fonts or paragraphs.
  - For a text selection, first derive the untouched prefix of the start Block and suffix of the end Block without publishing. Across different Blocks, each nonempty original boundary fragment retains its own original Block ID. Within one Block, the sole nonempty original fragment retains that Block's ID; when both prefix and suffix are nonempty, prefix retains the original ID and suffix consumes a fresh ID. Each retained-ID fragment keeps original kind/metadata when locally valid, otherwise a link fragment downgrades to paragraph. Any task fragment assigned a fresh ID has `completedAt == nil`; only the fragment retaining the original task ID may retain its prior completion. Insert the validated rich blocks between the fragments. Every pasted Block gets a fresh ID except when both boundary fragments are empty, in which case the first pasted Block reuses the start Block ID; pasted task `completedAt` is always nil. Empty prefix/suffix fragments are omitted. If there are no pasted blocks, use the ordinary delete-selection rule; a collapsed empty payload is `.none(.emptySelection)`. RED includes same-Block offset-zero partial replacement of a completed task, both-boundary split and exact ID/completion ownership.
  - For a Block selection, remove its normalized complete roots/descendants, reuse the first removed root ID for the first pasted Block, allocate IDs for the remainder, and create the injected empty-paragraph fallback when the rich list is empty. Code/divider/link are inserted as complete validated Blocks and are never merged with boundary text. Exact ID consumption is asserted for collapsed, same-Block range, cross-Block range, Block selection, empty payload and fallback-to-plain paths.

- [ ] Write RED stable-ID drag tables. `.moveBlockRoots([BlockID], before: BlockID?)` treats a root's descendants as the immediately following Blocks while `indentLevel > root.indentLevel`; passing both root and descendant deduplicates the descendant, while passing the same root twice throws `invalidMove`. Normalize distinct selected roots into current document order before moving, regardless of parameter order, and preserve IDs/content/order within each moved closure. `nil` means document end. Missing roots or target and any move whose resulting parent structure is invalid throw `invalidMove`. A target inside a moved closure or a move producing the existing order returns `.none(.samePosition)`, `effect == .handled` and `.none` undo. Every thrown failure keeps the input and selection exact, consumes no IDs and produces no result; every no-change has `.handled` as the explicit no-external-side-effect value.

- [ ] Write RED atomicity and undo tables. Reduction order is: validate input document; validate selection IDs/grapheme offsets; build a local candidate using injected IDs; enforce `candidate.blocks` is nonempty and make the full-deletion path create its one empty paragraph fallback; run `BlockDocumentValidator`; only then return effects/undo/callback-worthy mutation. Do not require every otherwise-valid document to contain a paragraph. Any failure returns no candidate/effect/undo. Consecutive plain inserts in the same Block use `.coalesceTyping(blockID)`; structural edit, cut, paste, format and drag each use one `.atomic`; selection-only motion uses `.none`; copy/defer/no-change uses `.none` and cannot trigger Task 9's document callback.

- [ ] Write `Scripts/verify-block-input-purity.sh` before production code. It enumerates every `import` in the three Task 8 files and permits only exact `Foundation` and `WorkspaceDomain`, including rejecting indented or `@preconcurrency import AppKit`, `SwiftUI`, `CalendarDomain` and submodule imports. It also rejects any `public` declaration regardless of leading whitespace or declaration attributes. `--self-test` creates disposable fixtures proving one valid case passes and each forbidden import/public spelling fails; `BlockEditorPurityGateTests` runs the self-test and a real-source scan. The script must be executable.

~~~swift
@Test(arguments: BlockInputFixture.keyboardMatrix)
func keyboardMatrix(_ fixture: BlockInputFixture) throws {
    let result = try BlockInputReducer.reduce(
        fixture.document,
        selection: fixture.selection,
        command: fixture.command,
        environment: fixture.environment
    )
    #expect(result == fixture.expectedResult)
}

@Test func returnDuringMarkedTextDoesNotSplitBlock() throws {
    let result = try BlockInputReducer.reduce(
        document,
        selection: selection,
        command: .enter,
        environment: .init(isComposingText: true, idSource: .fixed([]))
    )
    #expect(result.document == document)
    #expect(result.effect == .deferToTextSystem)
    #expect(result.undo == .none)
}
~~~

- [ ] Run the complete RED suite and record behavior failures, not test-fixture compilation mistakes. Do not create production files until the RED command fails only because the Task 8 APIs/behavior are absent.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorPurityGateTests
~~~

- [ ] Implement the minimum pure selection utilities, deterministic ID generator, inline span slicer, a complete `BlockPasteParser: BlockPasteParsing` and exhaustive BlockInputReducer needed to turn the tables GREEN. Preserve existing Block IDs for content edits and allocate only for inserted/fallback Blocks. Task 9 must be able to dispatch every committed edit through this reducer and emit exactly one document callback only for `.document`. After the public-shaped Task 8 interfaces compile, run `swift build --target CalendarApp` before filling behavior so an illegal declaration or inaccessible WorkspaceDomain helper cannot hide behind later test failures.

- [ ] Run focused GREEN, WorkspaceDomain regression and the complete repository suite; verify no AppKit/SwiftUI import entered the three pure files and no Task 8 type became public.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorPurityGateTests
./Scripts/test.sh --filter WorkspaceDomainTests
./Scripts/test.sh
sh Scripts/verify-block-input-purity.sh --self-test
sh Scripts/verify-block-input-purity.sh Sources/CalendarApp/Notes/BlockEditor
git diff --check
~~~

- [ ] Request fresh Sol xhigh review focused on selection direction, grapheme safety, exhaustive kind tables, ID/validator atomicity, inline span preservation, paste fidelity, stable-ID drag, undo directives and Task 9 bridge readiness. Fix every Critical/Important finding and rerun the full Task 8 gates.

- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Notes/BlockEditor Tests/CalendarAppTests/BlockEditorInputTests.swift Tests/CalendarAppTests/BlockEditorPurityGateTests.swift Scripts/verify-block-input-purity.sh
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
- Create: Sources/CalendarApp/Notes/BlockEditor/BlockPasteboardAdapter.swift
- Modify: Sources/CalendarApp/Workspace/EditorFocusRegistry.swift
- Modify: Sources/CalendarApp/CalendarUndoCommands.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Create: Tests/CalendarAppTests/BlockEditorBridgeTests.swift
- Create: Tests/CalendarAppTests/BlockEditorUndoTests.swift
- Create: Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift
- Create: Tests/CalendarAppTests/CalendarUndoCommandRoutingTests.swift

**Produces:** Minimal, quiet, structured Block editor with IME-safe input, selection, paste, slash menu, drag reorder and editor-local undo.

**Consumes:** Task 8 state machine, Workspace focus registry and BlockDocument.

- [ ] Do not begin Task 9 until Task 8 is reviewed, committed and the following preflight is GREEN. Task 9 must consume the committed reducer rather than adding editor-only mutation algorithms.

~~~zsh
test -f Sources/CalendarApp/Notes/BlockEditor/BlockInputReducer.swift
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorPurityGateTests
swift build --target CalendarApp
~~~

- [ ] Define and RED-test the complete bidirectional UTF-16 bridge before delegate code. It operates on the concatenated span string, accepts divider offset zero only, validates missing Block/negative/overflow/`NSNotFound`/past-end, and accepts only exact `Character` boundaries or end index—never floor/clamp. A same-Block `NSRange` validates both endpoints atomically. Cross-Block selections remain two `BlockTextPosition`s and never become a synthetic global `NSRange`.

~~~swift
enum BlockEditorBridgeError: Error, Equatable, Sendable {
    case missingBlock(BlockID)
    case negativeUTF16Offset
    case nsNotFound
    case integerOverflow
    case utf16OffsetOutOfRange
    case midGraphemeBoundary
    case crossBlockRange
}

struct BlockTextRange: Equatable, Sendable {
    let start: BlockTextPosition
    let end: BlockTextPosition
}

protocol BlockSelectionBridging {
    static func graphemePosition(
        blockID: BlockID,
        utf16Offset: Int,
        document: BlockDocument
    ) throws -> BlockTextPosition

    static func utf16Offset(
        position: BlockTextPosition,
        document: BlockDocument
    ) throws -> Int

    static func graphemeRange(
        blockID: BlockID,
        nsRange: NSRange,
        document: BlockDocument
    ) throws -> BlockTextRange

    static func nsRange(
        textRange: BlockTextRange,
        document: BlockDocument
    ) throws -> NSRange
}
~~~

`BlockSelectionBridge` is the complete internal implementation in `BlockSelectionController.swift`. `nsRange(textRange:)` accepts only a normalized same-Block `start <= end`; reverse Task 8 selections are normalized for the AppKit projection while `BlockSelectionController` separately preserves the original anchor/focus direction. Round-trip tables cover forward and reverse selection plus ASCII, Chinese, combining acute, flag, skin-tone emoji and ZWJ family; both endpoints of every range receive mid-grapheme probes.

- [ ] Make the existing focus registry a production composition dependency. `PersonalCalendarApp` creates one `@StateObject EditorFocusRegistry`, injects that exact instance into `CalendarUndoCommands`, and Task 10 will pass the same instance to the Notes editor when it enables the route. Replace the tuple-only availability with a distinguishable snapshot while keeping the manager weak and owner-token clear semantics.

~~~swift
enum EditorFocusAvailability: Equatable, Sendable {
    case noFocusedOwner
    case focused(canUndo: Bool, canRedo: Bool)
}
~~~

Both menu enablement and execution re-read the same registry state:

- `.noFocusedOwner` alone may query/call WorkspaceStore undo or redo;
- for any `.focused(...)`, read the requested side's boolean independently; if that side is false, consume/disable it and return `.focusedUnavailable` without Workspace fallback, regardless of whether the opposite side is available;
- a focused available action calls only the session `UndoManager`;
- if the weak manager has deallocated, registry clears that owner and becomes `.noFocusedOwner`;
- install both Command-Z and Shift-Command-Z. A stale host A blur/dismantle may clear only A's lease and cannot clear a newer host B.

- [ ] Define one stable `BlockEditorSession` per `(noteID, editSessionID)`. `BlockEditorView` creates it once with `@StateObject`; SwiftUI parent redraws and autosave receipts must not recreate it. The session strongly owns one shared `UndoManager`, authoritative `BlockDocument`, direction-preserving `BlockEditorSelection`, synthetic cross-host selection, composition state and attached host registry. `EditorFocusRegistry` remains a weak observer of that manager.

~~~swift
enum BlockEditorSaveStatus: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}

struct BlockEditorDispatchOutcome: Equatable, Sendable {
    let result: BlockInputResult
    let commandHandled: Bool
}

@MainActor
protocol BlockEditorSessionContract: AnyObject {
    var noteID: NoteID { get }
    var editSessionID: UUID { get }
    var undoManager: UndoManager { get }
    var document: BlockDocument { get }
    var selection: BlockEditorSelection { get }
    func attach(blockID: BlockID, hostToken: UUID, textView: BlockEditorTextView)
    func detach(hostToken: UUID)
    func dispatch(_ command: BlockInputCommand) throws -> BlockEditorDispatchOutcome
    func autosaveDidResolve(_ status: BlockEditorSaveStatus)
}
~~~

`BlockEditorSession` is the complete internal `ObservableObject & BlockEditorSessionContract` implementation. Its sole initializer is:

~~~swift
init(
    noteID: NoteID,
    editSessionID: UUID,
    initialDocument: BlockDocument,
    initialSelection: BlockEditorSelection,
    focusRegistry: EditorFocusRegistry,
    onDocumentChange: @escaping (BlockDocument) -> Void
)
~~~

`BlockEditorView` uses only this entry to create its `@StateObject` once. Representable, host, selection and drag coordinators receive that session and may not create another registry, session, manager or document callback. These signatures are the exact Task 10 integration surface.

Each host gets a unique lease token. Replacement host attach wins; stale detach only removes its exact token. Programmatic projection runs behind a reentrancy guard and cannot call the reducer, document callback or UndoManager. `onDocumentChange` is synchronous and fires exactly once only after an accepted `.document` result. Autosave status changes only save UI state; it never replaces session document/selection, ends a group or clears undo. An explicit recovery/new-note action creates a new editSessionID instead of silently rebasing the live session.

- [ ] Lock the only legal `BlockInputResult` consumption combinations and RED-test every row plus invalid combinations:

| Mutation | Effect | Undo | Delegate/session behavior |
|---|---|---|---|
| `.none` | `.handled` | `.none` | return handled; no callback/clipboard/undo |
| `.none` | `.deferToTextSystem` | `.none` | return not-handled; no callback/undo |
| `.none` | `.writeClipboard` | `.none` | copy once; no callback/undo |
| `.none` | `.handled` | `.breakCoalescing` | close active typing group; handled; zero callback/clipboard/new undo |
| `.selectionOnly` | `.handled` | `.none` | update session + host projections; close typing coalescing; no callback |
| `.document` | `.handled` | `.coalesceTyping(id)` | publish/callback once; continue only same Block and continuous caret |
| `.document` | `.handled` | `.atomic(action)` | close typing group, register exactly one undo group, callback once |
| `.document` | `.writeClipboard` | `.atomic(.cut)` | write full plain string successfully before publishing; one clipboard/undo/callback |

Every other combination is a typed/asserted integration error with zero side effects; any `.breakCoalescing` combination other than its table row is illegal. A custom pasteboard write may fail and still leave the mandatory plain string; a failed plain-string write prevents cut publication entirely. Before each accepted document mutation, capture the prior document/selection. Atomic undo restores that validated snapshot and registers the inverse redo; typing coalescing retains the first before-snapshot and latest after-snapshot. Undo/redo publish authoritative session truth and one document callback without passing through NSTextView storage or creating another user edit; this snapshot restore is the sole sanctioned non-reducer document transition inside a live session.

- [ ] Define IME and host projection ordering, then write real delegate RED probes. The first `setMarkedText` freezes the authoritative document, Block ID, direction-preserving selection and explicit replacement range as one composition baseline. Later marked updates modify only the NSTextView transient projection. `insertText(_:replacementRange:)` while composing commits the complete candidate string exactly once against the frozen baseline, then reprojects session truth. If AppKit ends a live composition through `unmarkText` without a preceding insert, commit the current marked string exactly once; `cancelOperation:`/abandoned composition restores the frozen projection with zero reducer/callback/undo. Repeated insert/unmark after terminal commit/cancel is ignored by composition token. For ordinary insert, `NSNotFound` uses session selection and an explicit range goes through `BlockSelectionBridge`. While `hasMarkedText`, Return, Backspace, Tab/Backtab, arrows, Shift-arrows, slash and Escape defer to the input system and return not-handled. No marked storage becomes session truth before the terminal transition. Script Pinyin multi-update, insert commit, unmark commit, cancel, committed Chinese and emoji probes.

- [ ] Route all production text commands explicitly: Enter, Shift-Enter, Backspace, Tab, Backtab, left/right/up/down, each `...AndModifySelection:` selector, insertText with selected/explicit replacement, copy, cut, paste and supported formatting/link shortcuts. Menu-open keys are handled by slash state first; composing keys are deferred first; all other accepted edits dispatch exactly one Task 8 command. Return handled/not-handled from the legal consumption table instead of letting NSTextView repeat an already-dispatched command.

- [ ] Implement session-owned cross-Block selection. `BlockSelectionController` owns anchor/focus direction and pointer/Shift-key extension across host frames; each NSTextView only projects the intersection for its Block. Pointer drag, forward/reverse Shift extension and keyboard crossing preserve direction. Cross-Block copy/cut/delete/format/link dispatch once through Task 8, never concatenate independent `selectedRange` values. Unsupported mixed selections are one atomic no-change. Block selection is a separate stable-ID mode.

- [ ] Define the private pasteboard contract. `BlockPasteboardAdapter` owns `NSPasteboard.PasteboardType("com.adeptify.jelly.block-clipboard.v1")` and a version-1 Codable DTO envelope that contains only plain text and Block kind/inline spans/indent/code info—never BlockID or completedAt. Copy/cut writes both custom data and complete `.string`; corrupt JSON, unknown version or invalid rich data falls back to the full `.string`. Bold/italic come only from font symbolic traits, links only from `.link` passing Task 8 validation, and inline-code only from a Jelly semantic attribute, never merely a monospace font. Paragraph/font/color styles do not infer Block kinds. Attachments/unsupported attributes lose styling but keep their characters, including U+FFFC, and `fallbackPlainText == attributed.string` exactly.

- [ ] Define slash-menu state as `(blockID, queryRange, query, selectedIndex, dismissedRevision)`. It opens only for a leading slash query in a collapsed paragraph, closes during composition, recomputes after committed text/caret change, and does not immediately reopen for the same dismissed text/caret revision. Up/Down changes selection, Return dispatches one `.applySlashConversion`, Escape closes while preserving original text. Confirm/cancel are once-only and stale host/menu callbacks are ignored.

- [ ] Define drag and keyboard reorder entirely in stable IDs. Normalize UI roots in document order, remove passed descendants, derive each continuous descendant closure, and compute `before:` from current Task 8 document. Drop inside a moved closure and same position are no-op. Move Up/Down selects the previous/next valid root boundary. One action performs one reducer dispatch, undo group and callback; keep selection on the same IDs and ignore stale host/index data. Provide a restrained 20pt affordance on hover/focus, keyboard alternatives and position announcements.

- [ ] Accessibility contracts are production behavior: each Block exposes role/value, selection state and stable identifier; handles expose label, Move Up/Down actions and `第 n 项，共 m 项`; divider is selectable/operable; slash menu has deterministic focus/order/current-item state. Inline controls appear only for a nonempty supported text selection or explicit shortcut and remain keyboard reachable.

- [ ] Write RED through real production paths, not only coordinator fakes. For editor behavior, initialize `NSApplication`, a key `NSWindow`, and `NSHostingView(BlockEditorView)` using production Session/TextView/Representable/FocusRegistry; IME, selection projection, pasteboard, drag, accessibility and the shared session UndoManager run there. Scene-level `CalendarUndoCommands: Commands` cannot be mounted in `NSHostingView`: `CalendarUndoCommandRoutingTests` instead call the production command router with the exact registry and WorkspaceStore, proving enablement/execution for no owner, undo-only, redo-only, both and focused-unavailable states without reimplementing routing. Actual App-menu Command-Z/Shift-Command-Z key equivalents remain a final packaged GUI Gate and are not claimed by SwiftPM hosted tests.

~~~swift
@MainActor
@Test func commandZUsesEditorUndoWhileFocused() throws {
    let harness = try HostedBlockEditorHarness(document: fixture)
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
./Scripts/test.sh --filter CalendarAppTests.CalendarUndoCommandRoutingTests
~~~

- [ ] Add the complete public-shaped internal API skeleton and production composition changes, then run `swift build --target CalendarApp` before filling delegate behavior. Do not weaken MainActor isolation or use `@preconcurrency` to hide an unsafe editor path.

- [ ] Implement the minimum production Session, bridge, text hosts, selection, pasteboard, slash, drag, focus-command routing and accessibility behavior that turns every RED matrix GREEN. The old `MarkdownNotesEditor` and `MarkdownRichTextCodec` remain untouched and serve legacy calendar notes only.

- [ ] Run GREEN plus Task 8, command routing, CalendarApp, full and release gates. Verify only one PersonalCalendarApp focus registry, one editor session/UndoManager per editSessionID and no AppKit mutation bypass around `BlockInputReducer`.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorBridgeTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorUndoTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorAccessibilityTests
./Scripts/test.sh --filter CalendarAppTests.CalendarUndoCommandRoutingTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceCommandRoutingTests
./Scripts/test.sh --filter CalendarAppTests
./Scripts/test.sh
swift build -c release
git diff --check
~~~

- [ ] Request fresh Sol xhigh review focused on real production command routing, IME baseline/commit/cancel, result-consumption atomicity, synthetic selection identity, pasteboard fallback, stable session/autosave boundaries and accessibility; fix every Critical/Important finding and rerun all BlockEditor filters plus full/release gates.
- [ ] Commit.

~~~zsh
git add Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift Sources/CalendarApp/Notes/BlockEditor/BlockEditorSession.swift Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextView.swift Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextViewRepresentable.swift Sources/CalendarApp/Notes/BlockEditor/BlockSlashMenu.swift Sources/CalendarApp/Notes/BlockEditor/BlockSelectionController.swift Sources/CalendarApp/Notes/BlockEditor/BlockDragCoordinator.swift Sources/CalendarApp/Notes/BlockEditor/BlockPasteboardAdapter.swift Sources/CalendarApp/Workspace/EditorFocusRegistry.swift Sources/CalendarApp/CalendarUndoCommands.swift Sources/CalendarApp/PersonalCalendarApp.swift Tests/CalendarAppTests/BlockEditorBridgeTests.swift Tests/CalendarAppTests/BlockEditorUndoTests.swift Tests/CalendarAppTests/BlockEditorAccessibilityTests.swift Tests/CalendarAppTests/CalendarUndoCommandRoutingTests.swift
git commit -m "feat(notes): 交付极简结构化 Block 编辑器"
~~~

## Task 10: Deliver the First Notes Vertical Slice and Restart Recovery

**Produces:** A visible Notes tab with create/select/edit, title + Block content, debounced Journal-first autosave, truthful close protection and restart recovery choice.

**Consumes:** An independently approved Task 9 BlockEditor, WorkspaceStore, the single PersonalCalendarApp EditorFocusRegistry, DraftJournalCoordinator and BlockMarkdownCodec.

### Task 10 hard entry Gate

- [ ] Do not create a Task 10 production file until the frozen Task 9 package has a fresh Sol review verdict of `0 Critical / 0 Important`. Any Task 9 API change made for Task 10 receives a scoped Task 9 re-review before Notes is feature-enabled.
- [ ] Re-run the Task 9 focused, Task 8, CalendarApp, full and Release gates. The Task 10 implementation may consume only the reviewed `(noteID, editSessionID)` session surface.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.BlockEditorBridgeTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorUndoTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorAccessibilityTests
./Scripts/test.sh --filter CalendarAppTests.CalendarUndoCommandRoutingTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceCommandRoutingTests
./Scripts/test.sh --filter CalendarAppTests
./Scripts/test.sh
swift build -c release
~~~

### Task 10A: Store-owned two-phase draft protection and restart recovery

**Files**

- Modify: Sources/WorkspaceDomain/DraftContracts.swift
- Modify: Sources/CalendarPersistence/DraftJournal.swift
- Modify: Sources/CalendarPersistence/DraftJournalRepository.swift
- Modify: Sources/CalendarApp/Workspace/DraftJournalCoordinator.swift
- Modify: Sources/CalendarApp/Workspace/WorkspaceStore.swift
- Modify: Sources/CalendarApp/Workspace/WorkspaceMutationOutcomePresenter.swift
- Modify: Sources/CalendarApp/Backup/BackupRecoveryPolicy.swift
- Modify: Sources/CalendarApp/Backup/BackupCommands.swift
- Modify: Tests/CalendarPersistenceTests/DraftJournalRepositoryTests.swift
- Create: Tests/CalendarPersistenceTests/DraftJournalRecoveryRepositoryTests.swift
- Modify: Tests/CalendarAppTests/DraftJournalCoordinatorTests.swift
- Modify: Tests/CalendarAppTests/WorkspaceStoreTests.swift
- Create: Tests/CalendarAppTests/NoteDraftRecoveryStoreTests.swift
- Modify: Tests/CalendarAppTests/WorkspaceMutationPresentationTests.swift
- Modify: Tests/CalendarAppTests/BackupRecoveryPolicyTests.swift

- [ ] Preserve `submitDraft(_:)` as a compatibility wrapper, but make the authoritative path two-stage and Store-owned. UI code never receives a Journal repository and never performs a sidecar write itself. Lock internal public-shaped contracts with semantics equivalent to:

~~~swift
// CalendarApp/Workspace/WorkspaceStore.swift. This type is internal to the
// app module so its fileprivate initializer and capability never cross a
// module boundary; Notes code can only pass back a Store-issued value.
struct ProtectedNoteDraft: Equatable, Sendable {
    fileprivate let capability: UUID
    let identityAndGeneration: DraftJournalIdentityAndGeneration
    let noteSnapshotChecksum: String
    let journalChecksum: String
}

enum DraftProtectionOutcome: Equatable, Sendable {
    case protected(ProtectedNoteDraft)
    case superseded(currentGeneration: UInt64)
}

struct DraftRecoveryToken: Hashable, Codable, Sendable {
    let identityAndGeneration: DraftJournalIdentityAndGeneration
    let noteSnapshotChecksum: String
    let journalChecksum: String
}

struct DraftRecoveryCandidate: Equatable, Sendable {
    let token: DraftRecoveryToken
    let draft: Note
    let persisted: Note?
    let updatedAt: Date
}

enum DraftRecoveryAction: Equatable, Sendable {
    case restoreAsCurrent
    case keepPersisted
    case saveAsNew(noteID: NoteID, blockIDs: [BlockID])
}

func protectDraft(_ submission: NoteDraftSubmission) async throws -> DraftProtectionOutcome
func commitProtectedDraft(_ protected: ProtectedNoteDraft) async throws -> WorkspaceTransactionOutcome
func resolveDraftRecovery(_ token: DraftRecoveryToken, action: DraftRecoveryAction) async throws -> WorkspaceTransactionOutcome
~~~

- [ ] Put `DraftRecoveryToken` (and only the non-authorizing exact record identity needed by Persistence) in `WorkspaceDomain/DraftContracts.swift` with public Codable access so `DraftJournalRepository` can compare it. The token is forgeable but not authority: compare-and-discard succeeds only against the exact locked record. Keep `ProtectedNoteDraft`, `DraftProtectionOutcome`, `DraftRecoveryCandidate` and `DraftRecoveryAction` internal to CalendarApp; only the protected capability is authorization.
- [ ] `ProtectedNoteDraft` lives in the same `WorkspaceStore.swift` file as its `fileprivate` initializer/capability; do not place an inaccessible `fileprivate` member in `WorkspaceDomain`. It is an opaque, Store-issued, single-use capability. The Store retains `capability → complete frozen NoteDraftSubmission`, including base snapshot/checksum, base task links, modified fields and every deletion disposition. `commitProtectedDraft` accepts no replacement submission and queues only the frozen value. A newer protected generation invalidates the older capability; first commit attempt consumes it into the queue/pending record, and replay cannot queue or save twice. After a definite `.notCommitted` has exact-unbound the same bare Journal generation, `protectDraft` may issue one fresh capability for that still-current exact record; the consumed capability remains invalid. Restart loses in-memory capabilities and exposes the durable bare record only through the recovery flow.
- [ ] `DraftJournalRepository` performs protect/supersede and recovery discard under its existing cross-process advisory lock. Add an atomic compare-and-discard keyed by exact identity, generation, entry checksum and note snapshot checksum. A stale preview can never delete or replace a newer generation. Keep the old `persist` API as a compatibility wrapper over the same single algorithm.
- [ ] `commitProtectedDraft` never writes the Journal again. It verifies that the Store-owned capability still identifies the current bare record, then queues only its frozen submission. A newer record returns `.draftSuperseded`; missing/mismatched/corrupt evidence fails closed. The existing queue, rebase-and-bind, receipt, uncertain commit and cleanup machinery remains the only main-file writer.
- [ ] Extend startup recovery from the current `publishedDraftNotPersisted` freeze to an observable `.needsDraftRecovery` phase with validated `DraftRecoveryCandidate`s. Exact persisted receipts are silently acknowledged/cleared. Bare materially different records become candidates; corrupt bytes remain errors and are never treated as absent. Resolving one identity cannot change another record.
- [ ] `restoreAsCurrent` is one queued revision. It overwrites the current Note with the reviewed snapshot, or recreates the same Note ID if absent. Recovery relation rules are exact and are derived from the current Workspace graph plus the reviewed draft, never from guessed historical edges: a retained linked Task Block is normalized to the current Calendar item's `completedAt`; a removed or non-task replacement unlinks and keeps the Calendar item; a missing/dangling Calendar side leaves the Journal untouched and enters relationship repair. A link added after the draft is retained when its Block survives, with the same completion normalization. `saveAsNew` requires fresh Block IDs whose count equals the draft block count, maps them in document order, rejects duplicate/source IDs, carries zero task/calendar relations, preserves task completion as independent content, and resets archive/revision/timestamps through the reducer. Both clear the original recovery record only after the main save is committed; commit-uncertain parks a typed draft-recovery completion so reconciliation publishes/resolves the reviewed identity exactly once. `keepPersisted` performs only the exact compare-and-discard.
- [ ] Add `JournalCleanupStep.discardRecovery` (or an equivalent typed step) and retain the exact recovery token for retry. Update every exhaustive `WorkspaceStorePhase` and `JournalCleanupStep` consumer in this file list in the same compile slice; `BackupRecoveryPolicy`, `BackupCommands` and `WorkspaceMutationOutcomePresenter` must expose the exact recovery identity/step and never relabel discard as ordinary receipt cleanup. If post-commit discard fails, publish the committed state once and enter cleanup-pending; if keep-persisted discard fails, do not claim the draft was dismissed. Retry never replays the main save.
- [ ] `.needsDraftRecovery` blocks ordinary mutation, backup restore and external reload until every candidate and cleanup is resolved. It still permits read-only main-file backup plus explicit draft copy/Markdown export; opaque-primary raw export retains its existing repository precondition. Backup policy and menu labels must describe draft recovery rather than offering an action that Store will reject. The last exact candidate/cleanup transition alone restores the previous valid Store phase.
- [ ] Because the current Journal has one record per identity, `.commitPending` and every Journal cleanup-pending state are temporarily read-only: title, Block, category and archive edits do not create or protect a successor generation until reconcile/cleanup reaches a terminal state. `.notCommitted` restores editing only after exact unbind; committed reconcile refreshes the base snapshot/revision before editing resumes. This Task does not introduce a hidden second pending/successor record.
- [ ] Write public RED first. Cover opaque capability construction/replay, complete frozen submission binding, exact generation/checksum, supersede, multi-record isolation, exact persisted receipt cleanup, bare candidate publication, missing Note, retained/removed/new/dangling task links, restore current, save-as-new ordered ID remap, keep persisted, stale discard, corrupt Journal raw-byte preservation, commitPending/read-only/notCommitted-unbind/resume/sourceChanged/unreadable and every recovery cleanup failure. Cover `.needsDraftRecovery` backup/restore/reload policy and raw evidence preservation. Task 10A has no debounce or Notes UI test.

~~~zsh
./Scripts/test.sh --filter CalendarPersistenceTests.DraftJournalRecoveryRepositoryTests
./Scripts/test.sh --filter CalendarAppTests.NoteDraftRecoveryStoreTests
swift build --target CalendarApp
./Scripts/test.sh --filter CalendarPersistenceTests.DraftJournalRepositoryTests
./Scripts/test.sh --filter CalendarAppTests.DraftJournalCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceStoreTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceMutationPresentationTests
./Scripts/test.sh --filter CalendarAppTests.BackupRecoveryPolicyTests
git diff --check
~~~

- [ ] Request fresh Sol xhigh review of Task 10A, fix every Critical/Important finding, explicitly stage only the 10A file list, verify the cached file list and commit it before creating 10B tests.

~~~zsh
git add Sources/WorkspaceDomain/DraftContracts.swift Sources/CalendarPersistence/DraftJournal.swift Sources/CalendarPersistence/DraftJournalRepository.swift Sources/CalendarApp/Workspace/DraftJournalCoordinator.swift Sources/CalendarApp/Workspace/WorkspaceStore.swift Sources/CalendarApp/Workspace/WorkspaceMutationOutcomePresenter.swift Sources/CalendarApp/Backup/BackupRecoveryPolicy.swift Sources/CalendarApp/Backup/BackupCommands.swift Tests/CalendarPersistenceTests/DraftJournalRepositoryTests.swift Tests/CalendarPersistenceTests/DraftJournalRecoveryRepositoryTests.swift Tests/CalendarAppTests/DraftJournalCoordinatorTests.swift Tests/CalendarAppTests/WorkspaceStoreTests.swift Tests/CalendarAppTests/NoteDraftRecoveryStoreTests.swift Tests/CalendarAppTests/WorkspaceMutationPresentationTests.swift Tests/CalendarAppTests/BackupRecoveryPolicyTests.swift
git diff --cached --name-only
git commit -m "feat(notes): 建立草稿保护与重启恢复"
~~~

### Task 10B: Notes browser, derived search/archive truth and debounced autosave model

**Files**

- Create: Sources/CalendarApp/Notes/NotesViewModel.swift
- Create: Sources/CalendarApp/Notes/NoteAutosaveCoordinator.swift
- Create: Sources/CalendarApp/Notes/NoteCloseProtectionBridge.swift
- Create: Tests/CalendarAppTests/NotesWorkspaceViewModelTests.swift
- Create: Tests/CalendarAppTests/NoteAutosaveCoordinatorTests.swift
- Create: Tests/CalendarAppTests/NoteCloseProtectionTests.swift

- [ ] Add an injected scheduler and a single generation owner. Every title, Block or category draft edit increments `draftGeneration` and computes the complete `NoteDraftSubmission` from the selected session's immutable base Note, base checksum, base task links, modified fields and required linked-block dispositions. Archive/restore are not draft edits and never create an `archivedAt` generation. No view constructs a partial submission.
- [ ] Debounce from the latest edit timestamp: at 150ms protect only the latest generation; at 650ms total commit that exact protected token. A newer edit cancels both old timers. `flushLatest` is one MainActor-linearized barrier shared by selection change, route change, app inactive, window close and termination. It has two explicit stages: first enter `.finalizingNativeInput(permit)` and invoke the injected 10B finalizer contract. During that stage ordinary edits and stale hosts are rejected, while exactly one authoritative callback carrying the exact `(nonce, noteID, editSessionID, activeHostToken)` permit may commit the current marked candidate and synchronously increment generation; the permit is consumed once. If finalization succeeds (including no pending candidate), enter sealed read-only state, capture `(identity, generation, noteSnapshotChecksum)`, then protect/commit that exact value. As a defensive invariant, if generation/checksum nevertheless changes while awaiting Journal/main I/O, the barrier loops from finalization/protection for the new latest value and never releases a caller on an older result. Concurrent inactive+close+route callers await the same task; success is returned only when the terminal receipt/protection identity equals the then-current latest triple. Finalization failure does not capture or persist anything, keeps the window/route/selection unchanged and returns to the truthful editable state. Once a commit is uncertain, no later generation is submitted until the exact pending transaction is reconciled.
- [ ] Lock a complete `NoteAutosaveState` mapping for `.committed`, `.noChange`, `.conflict`, `.draftSuperseded`, `.commitPending`, `.notCommitted`, `.externalSourceChanged`, `.persistenceBlocked` and Journal cleanup-pending. A definite main failure after exact unbind stays editable and says `保存失败—草稿已保护`; commit-uncertain and cleanup-pending are visibly read-only until their exact retry completes; protection failure says the draft is not protected and blocks silent close. No non-throw outcome is silently promoted to saved.
- [ ] `NoteCloseProtectionBridge` owns the real main-window/application lifecycle seam. It returns false/terminate-later while the shared linearized flush is pending, closes after the exact current generation is protected-or-persisted, and keeps the window open when Journal and main protection both fail until explicit copy/export succeeds. A result for generation N never closes while generation N+1 exists. `.onDisappear` alone is not accepted as close protection.
- [ ] Deliver deterministic in-memory browser truth in Task 10: Chinese title plus concatenated Block-text search; search ∩ shared-category filter; 最近编辑 sorted by `updatedAt desc`, then `note.id.rawValue.uuidString.lowercased()` ascending; 全部 and 归档 partitions. Archived Notes are excluded from recent/all and shown only in 归档. Task 14 may replace this with a rebuildable persisted index but must preserve the same result contract.
- [ ] Create/select/archive/restore/delete-selection fallback are queued Workspace commands. Archiving first requires the latest draft to be committed to the main file—not merely Journal-protected—then sends exactly one `.archiveNote`; restore sends one `.restoreNote`. A protected-only/main-failed draft does not archive. Only a successful archive/restore changes selection; use the item now occupying the same displayed index or the preceding item, and show a real empty state when none remain. Category definitions always come from the shared Workspace calendar categories; category edits on a Note are Journal-protected draft fields.
- [ ] Define the native-input finalizer as an injected 10B contract/closure using only `noteID`, `editSessionID`, active host token and an opaque nonce generated and consumed by the MainActor `NoteAutosaveCoordinator` barrier owner. This nonce authorizes only one current-editor native callback; it is not WorkspaceStore/Journal authority and never crosses into Persistence. 10B must compile and test without any AppKit/Task 9 production type. The 10C editor supplies the real implementation. Write RED for 149/150ms and 649/650ms, continuous generations, exact permitted terminal callback accepted once, duplicate/ordinary/stale-host callbacks rejected, edit-during-await, exact latest-triple comparison, concurrent inactive+close+route callers sharing one barrier, pending/cleanup read-only and terminal resume, selection-save races, each Store outcome, Journal/main dual failure, copy/export close release, Chinese title/body search, category intersection, exact UUID-string tie break, recent/all/archive, committed-flush-before-archive, archive failure selection stability, restore once and no second Journal repository.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.NotesWorkspaceViewModelTests
./Scripts/test.sh --filter CalendarAppTests.NoteAutosaveCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.NoteCloseProtectionTests
swift build --target CalendarApp
git diff --check
~~~

- [ ] Request fresh Sol xhigh review of Task 10B, fix every Critical/Important finding, explicitly stage only the 10B file list, verify the cached file list and commit it before creating 10C tests.

~~~zsh
git add Sources/CalendarApp/Notes/NotesViewModel.swift Sources/CalendarApp/Notes/NoteAutosaveCoordinator.swift Sources/CalendarApp/Notes/NoteCloseProtectionBridge.swift Tests/CalendarAppTests/NotesWorkspaceViewModelTests.swift Tests/CalendarAppTests/NoteAutosaveCoordinatorTests.swift Tests/CalendarAppTests/NoteCloseProtectionTests.swift
git diff --cached --name-only
git commit -m "feat(notes): 建立笔记浏览与自动保存"
~~~

### Task 10C: Editor identity, Markdown and production Notes composition

**Files**

- Create: Sources/CalendarApp/Notes/NotesSplitView.swift
- Create: Sources/CalendarApp/Notes/NoteBrowserView.swift
- Create: Sources/CalendarApp/Notes/NoteEditorView.swift
- Create: Sources/CalendarApp/Notes/NoteTitleTextField.swift
- Create: Sources/CalendarApp/Notes/DraftRecoverySheet.swift
- Create: Sources/CalendarApp/Notes/NoteMarkdownCommands.swift
- Modify: Sources/CalendarApp/Notes/BlockEditor/BlockEditorSelection.swift
- Modify: Sources/CalendarApp/Notes/BlockEditor/BlockInputReducer.swift
- Modify: Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift
- Modify: Sources/CalendarApp/Notes/BlockEditor/BlockEditorSession.swift
- Modify: Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextView.swift
- Modify: Sources/CalendarApp/AppShell/AppShellView.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Create: Tests/CalendarAppTests/NotesEditorIdentityTests.swift
- Create: Tests/CalendarAppTests/DraftRecoveryPresentationTests.swift
- Create: Tests/CalendarAppTests/NoteMarkdownCommandTests.swift
- Modify: Tests/CalendarAppTests/BlockEditorInputTests.swift
- Modify: Tests/CalendarAppTests/BlockEditorUndoTests.swift
- Modify: Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift

- [ ] Define `EditorKey(noteID, editSessionID)` as the SwiftUI identity. Ordinary redraws, Store publications, autosave status and category truth changes preserve the same `BlockEditorSession` and UndoManager. Selection change first runs the same native-input terminalization plus exact-latest flush barrier for the old Note, then opens the new Note with a fresh editSessionID; switching back is an explicit reopen and also gets a fresh editSessionID. Recovery and save-as-new always create a new key.
- [ ] Thread the exact `PersonalCalendarApp` `EditorFocusRegistry` object through AppShell → NotesSplitView → NoteEditorView → BlockEditorView. No Notes, view model, representable or preview creates another production registry. `NoteTitleTextField` registers its real field-editor UndoManager with that same registry while focused, so Command-Z in the title cannot fall back to Workspace undo; stale title/Block detach clears only its own owner token.
- [ ] Add the production implementation of the injected `NoteNativeInputFinalizer`, owned by the current EditorKey. During `.finalizingNativeInput(permit)` it asks the real title field editor or active `BlockEditorTextView` to terminally commit marked text through the normal authoritative callback/reducer transaction carrying that permit; focus ownership means at most one current field editor may consume it. It never reads private marked storage into a parallel model and never silently calls cancel/discard. After the one permitted callback (or confirmed no candidate), the coordinator seals editing and captures the updated generation. If AppKit cannot commit a live composition, finalization fails closed, leaves the current route/window/EditorKey open and presents an explicit `请先完成或取消正在输入的文字` state; only an explicit user cancel may discard the candidate. A duplicate permit use or stale host/token cannot mutate, finalize or clear the current host.
- [ ] Add a dedicated reducer-backed document-import command; do not reuse or widen the clipboard DTO. Its payload carries complete validated `DocumentBlock`s, including checked-task `completedAt`, and an explicit replace/append mode. Replace/append reject duplicate IDs and invalid documents before effects, preserve `[x]` task completion exactly, return one `.document/.handled/.atomic` result, and produce one session callback/undo. Clipboard payloads remain completion-free. Each accepted import stays in the current EditorKey; cancel and diagnostics produce zero changes. Directly replacing the `@StateObject` document is forbidden and the Task 8/9 API modification receives scoped reviews.
- [ ] Add 导入 Markdown and 导出 Markdown under the Note more menu. Import shows `BlockMarkdownImportResult` diagnostics and an explicit replace/append/cancel choice. Export writes the canonical Markdown selected by the user, readbacks the chosen file and reports write failure truthfully.
- [ ] Implement a collapsible two-column NotesSplitView. The left column contains search, shared-category filter, 最近编辑, 全部笔记, 归档, Note list and 新建. The right column contains borderless title, BlockEditor, category, exceptional save state and more. Reuse `CategoryManagerView(store:)`; do not create a fourth route or another category model. Inspiration remains hidden. Calendar links and `安排到日历` remain absent until Task 11 has a real transaction flow—no disabled or empty placeholder control.
- [ ] `DraftRecoverySheet` renders the reviewed current/draft difference and the exact candidate token. It offers 恢复为当前版本, 保留磁盘版本 and 另存为新笔记; stale actions refresh rather than deleting newer evidence. Pending/cleanup/external/unreadable outcomes reuse the shared truthful recovery presentation and never claim saved.
- [ ] Write RED through real `NSApplication` + key `NSWindow` + `NSHostingView` production composition for stable identity, Note switching, title-vs-Block undo routing, recovery key replacement, import undo, category reuse, close veto and absence of Task 11 controls. Add hosted IME-during-note-switch, route-change, window-close and termination cases for both title and Block input: the exact permit callback commits the candidate once before generation capture, while an ordinary callback and a stale/duplicate permit are rejected; otherwise the transition is vetoed with no candidate loss.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.NotesEditorIdentityTests
./Scripts/test.sh --filter CalendarAppTests.DraftRecoveryPresentationTests
./Scripts/test.sh --filter CalendarAppTests.NoteMarkdownCommandTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorInputTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorBridgeTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorUndoTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorAccessibilityTests
./Scripts/test.sh --filter CalendarAppTests.CalendarUndoCommandRoutingTests
./Scripts/test.sh --filter CalendarAppTests
./Scripts/test.sh
swift build --target CalendarApp
git diff --check
~~~

- [ ] Write the import reducer RED, add its public-shaped skeleton, run `swift build --target CalendarApp`, then implement behavior. Request fresh Sol xhigh review of the modified Task 8/9 surfaces; fix every Critical/Important finding, explicitly stage only the 10C file list, verify the cached file list and commit it.

~~~zsh
git add Sources/CalendarApp/Notes/NotesSplitView.swift Sources/CalendarApp/Notes/NoteBrowserView.swift Sources/CalendarApp/Notes/NoteEditorView.swift Sources/CalendarApp/Notes/NoteTitleTextField.swift Sources/CalendarApp/Notes/DraftRecoverySheet.swift Sources/CalendarApp/Notes/NoteMarkdownCommands.swift Sources/CalendarApp/Notes/BlockEditor/BlockEditorSelection.swift Sources/CalendarApp/Notes/BlockEditor/BlockInputReducer.swift Sources/CalendarApp/Notes/BlockEditor/BlockEditorView.swift Sources/CalendarApp/Notes/BlockEditor/BlockEditorSession.swift Sources/CalendarApp/Notes/BlockEditor/BlockEditorTextView.swift Sources/CalendarApp/AppShell/AppShellView.swift Sources/CalendarApp/PersonalCalendarApp.swift Tests/CalendarAppTests/NotesEditorIdentityTests.swift Tests/CalendarAppTests/DraftRecoveryPresentationTests.swift Tests/CalendarAppTests/NoteMarkdownCommandTests.swift Tests/CalendarAppTests/BlockEditorInputTests.swift Tests/CalendarAppTests/BlockEditorUndoTests.swift Tests/CalendarAppTests/AppEnvironmentWorkspaceCutoverTests.swift
git diff --cached --name-only
git commit -m "feat(notes): 组合笔记编辑与 Markdown 恢复界面"
~~~

### Task 10D: Feature activation and real V2 → V3 → restart vertical slice

**Files**

- Modify: Sources/CalendarApp/AppShell/WorkspaceRoute.swift
- Modify: Sources/CalendarApp/AppShell/AppShellView.swift
- Modify: Sources/CalendarApp/AppShell/WorkspaceNavigationRail.swift
- Modify: Sources/CalendarApp/AppShell/WorkspaceCommands.swift
- Modify: Sources/CalendarApp/AppShell/WorkspaceRouteState.swift
- Create: Sources/CalendarApp/AppShell/WorkspaceRouteTransitionCoordinator.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Create: Tests/CalendarAppTests/NotesVerticalIntegrationTests.swift
- Modify: Tests/CalendarAppTests/WorkspaceNavigationTests.swift
- Modify: Tests/CalendarAppTests/WorkspaceCommandRoutingTests.swift
- Create: Tests/CalendarAppTests/WorkspaceRouteTransitionTests.swift

- [ ] Keep `WorkspaceFeatures.production.notes == false` through 10A–10C. In 10D, first run the real integration RED, then set production to Notes enabled and Inspiration disabled. Production host composition must build one stable Notes module, rail/menu/Command-2/Command-N expose only enabled routes, and no `EmptyView`, fatal placeholder or Task 11 control is reachable.
- [ ] Add one async `WorkspaceRouteTransitionCoordinator` used by the rail, menu and Command-1/2/3. Leaving Notes first awaits the same idempotent latest-generation flush barrier; only a protected-or-persisted terminal outcome activates the target once. Protection failure, commitPending/cleanup read-only, external-source or persistence block leaves the route and EditorKey unchanged. No user transition calls `WorkspaceRouteState.activate` directly after this cutover.
- [ ] The vertical integration test uses real raw V2 bytes, `JSONWorkspaceRepository`, migration snapshot/manifest, DraftJournalRepository, WorkspaceStore, NotesViewModel and a fresh second repository/Store. It must prove this exact order:

~~~text
raw V2 bytes
  → load/migrate + byte-exact snapshot and manifest
  → host production AppShellView and activate the visible Notes route
  → invoke the production 新建 action
  → type through the real title field and BlockEditor callback
  → exact Journal generation is durable before main save
  → main Workspace persists
  → construct a fresh repository and Store
  → reload the exact Note
  → original CalendarState and calendar interaction projections are unchanged
~~~

- [ ] Add restart recovery branches to the same real hosted/repository fixture: exact persisted receipt cleans silently; a newer bare draft presents recovery; keep/restore/save-as-new each affect only the reviewed identity; corrupt Journal preserves evidence and blocks a false success. A view-model-only test cannot satisfy this vertical Gate.
- [ ] Run all Task 10 slices, Store/Persistence migrations, Task 9 regressions, CalendarApp, full, Release, fresh app bundle and an isolated data-directory GUI smoke. Automated metadata/hosted tests do not claim live VoiceOver; record unavailable GUI interactions truthfully.

~~~zsh
./Scripts/test.sh --filter CalendarAppTests.NoteDraftRecoveryStoreTests
./Scripts/test.sh --filter CalendarAppTests.NotesWorkspaceViewModelTests
./Scripts/test.sh --filter CalendarAppTests.NoteAutosaveCoordinatorTests
./Scripts/test.sh --filter CalendarAppTests.NoteCloseProtectionTests
./Scripts/test.sh --filter CalendarAppTests.NotesEditorIdentityTests
./Scripts/test.sh --filter CalendarAppTests.DraftRecoveryPresentationTests
./Scripts/test.sh --filter CalendarAppTests.NoteMarkdownCommandTests
./Scripts/test.sh --filter CalendarAppTests.NotesVerticalIntegrationTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceRouteTransitionTests
./Scripts/test.sh --filter CalendarAppTests.WorkspaceStoreTests
./Scripts/test.sh --filter CalendarPersistenceTests.DraftJournalRecoveryRepositoryTests
./Scripts/test.sh --filter CalendarPersistenceTests.WorkspaceMigrationSnapshotTests
./Scripts/test.sh --filter CalendarAppTests.BlockEditorUndoTests
./Scripts/test.sh --filter CalendarAppTests.CalendarUndoCommandRoutingTests
./Scripts/test.sh --filter CalendarAppTests
./Scripts/test.sh
swift build -c release
./Scripts/build-app.sh
codesign --verify --deep --strict dist/Jelly.app
task10_gui_root="$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)jelly-task10-gui.XXXXXX")"
open -n --env "JELLY_ACCEPTANCE_DATA_DIRECTORY=$task10_gui_root" dist/Jelly.app
git diff --check
~~~

- [ ] In the isolated packaged app, verify the Calendar route first, open Notes from the real rail and menu, create one Note, edit its title and at least two different Block kinds, wait through Journal protection and main save, switch Calendar → Notes without losing editor/selection state, terminate and relaunch against the same isolated directory, and verify the exact Note plus unchanged Calendar content. Repeat with a newer bare Journal draft and exercise keep/restore/save-as-new. Record menu Command-Z/Shift-Command-Z, resize/scroll and VoiceOver as `PASS`, `FAIL` or `UNVERIFIED`; hosted tests never substitute for these observations. Inventory the default production data directory before and after and require byte/name equality.

- [ ] Request a final fresh Sol xhigh cumulative Task 10 review of commits 10A–10C plus the uncommitted 10D package, focused on two-stage durability, recovery evidence identity, close truth, session/focus identity, async route gating, feature gating and V2 restart preservation. Fix every Critical/Important finding before the Task 10D commit.
- [ ] Explicitly stage only the 10D file list above. Compare `git diff --cached --name-only` against that exact list and fail if any path is missing or extra; do not use directory-wide `git add`.

~~~zsh
git add Sources/CalendarApp/AppShell/WorkspaceRoute.swift Sources/CalendarApp/AppShell/AppShellView.swift Sources/CalendarApp/AppShell/WorkspaceNavigationRail.swift Sources/CalendarApp/AppShell/WorkspaceCommands.swift Sources/CalendarApp/AppShell/WorkspaceRouteState.swift Sources/CalendarApp/AppShell/WorkspaceRouteTransitionCoordinator.swift Sources/CalendarApp/PersonalCalendarApp.swift Tests/CalendarAppTests/NotesVerticalIntegrationTests.swift Tests/CalendarAppTests/WorkspaceNavigationTests.swift Tests/CalendarAppTests/WorkspaceCommandRoutingTests.swift Tests/CalendarAppTests/WorkspaceRouteTransitionTests.swift
git diff --cached --name-only
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

自动继续下一任务

# Jelly 工作空间：日历、笔记与灵感设计规格

> 状态：已获用户逐节确认；本规格用于锁定后续实现合同
>
> 日期：2026-08-09
>
> 平台：macOS 桌面应用，本地优先
>
> 基线：Calendar V2 与现有所见即所得 Markdown 随记

## 1. 背景与目标

Jelly 当前已经是一款可独立使用的月历应用，但领域根仍是“必须有日期的事项”。下一阶段把它扩展为个人工作空间，同时保留日历已经形成的高密度连续周流与拖拽体验。

工作空间只有三个一级入口：

- **日历**：决定何时行动，以及行动是否完成。
- **笔记**：承载长期内容、结构化文档与未来 AI 协作。
- **灵感**：快速捕捉尚未整理的文字与材料，并推动其形成笔记或归档。

本阶段的核心不是增加三个页面，而是建立三者之间清晰、可恢复、不会产生内容副本冲突的流转合同。

成功必须同时满足：

- 现有日历数据、视觉与交互无回归。
- 笔记和灵感可以没有日期而独立存在。
- 日历与笔记解耦存储、自然关联，正文只有一个业务来源。
- 一篇笔记可关联多个日历行动；一个日历行动可关联多篇不同角色的笔记。
- 待办 Block 安排到日历后只有一个用户可感知的完成状态。
- 旧数据可备份、迁移、恢复，跨对象操作不会只成功一半。
- 第一阶段形成真实可用闭环，不以空 Tab 或假的 AI 能力冒充完成。

## 2. 产品原则

### 2.1 解耦但不割裂

“同一份内容”不等于“同一个业务对象”。日历事项与笔记是独立对象：前者负责时间和行动，后者负责文档内容。两者通过显式关系连接，用户无需维护两个正文副本。

灵感也不是另一种笔记。它是捕捉与孵化收件箱：保留原始输入，允许生成或关联正式笔记，处理完成后归档。

### 2.2 极简 Block

Block 是文档结构，不是视觉卡片：

- 默认不显示块边框、永久工具条或厚重容器。
- 拖拽柄只在悬停时出现。
- 斜杠菜单只在输入 `/` 时出现。
- 格式工具只在选中文字时出现。
- 选中态使用轻微底色，不使用粗描边。
- 首版严格限制 Block 类型，不建设组件市场。

### 2.3 原始输入优先

灵感文字、原始 URL 和现有日历正文必须先可靠保存，再发生解析、转换或未来 AI 处理。任何网络、格式或模型失败都不能覆盖原始内容。

### 2.4 AI 只提交建议

第一阶段不提供 AI。后续 AI 生成结果必须以可审阅草稿存在，只有用户明确应用后才改变笔记；每次应用都保留目标 Block、原版本、变更与来源。

## 3. 全局信息架构

### 3.1 固定窄图标栏

主窗口左侧增加约 64pt 的固定图标栏，只提供三个入口：日历、笔记、灵感。

- 当前模块使用温暖浅色的圆角底块突出。
- 非当前模块保持低对比度。
- 悬停显示中文名称。
- `Command-1`、`Command-2`、`Command-3` 分别切换日历、笔记、灵感。
- 每个入口提供中文辅助功能名称与可识别的选中状态。
- 灵感存在未处理条目时，可在图标右上角显示克制的小圆点或数量。
- 切换模块保留各自的滚动、选择、筛选与编辑位置。

全局图标栏不会扩展为固定宽侧栏。笔记浏览栏、灵感收件箱等二级结构属于对应页面，可独立收起。

分类管理不成为第四个一级入口；三个模块共享同一套分类，并从各自工具栏进入分类管理。

现有 MonthView 的最小内容宽度为 980pt。加入 64pt 图标栏后，主窗口最小宽度不得仍停在 980pt，而应至少为 `64 + 980 = 1044pt`；日历必须继续获得原有 980pt 内容空间。若实现加入分隔线或安全边距，总最小宽度相应增加，并重新执行最小窗口视觉验收。

### 3.2 页面职责

- 日历继续提供现有连续周流，并增加笔记关联入口。
- 笔记采用文档列表与沉浸式编辑器双栏布局。
- 灵感采用收件箱列表与原始内容详情双栏布局。
- `Command-N` 根据当前模块分别新建日历事项、笔记或灵感。

## 4. 领域模型

### 4.1 工作空间根

现有 `CalendarState` 不再承担整个应用根。新的版本化工作空间根包含：

```swift
struct WorkspaceState {
    var revision: Int64
    var calendar: CalendarState
    var notes: [NoteID: Note]
    var inspirations: [InspirationID: Inspiration]
    var calendarNoteRelations: CalendarNoteRelationGraph
    var taskBlockLinks: Set<TaskBlockCalendarLink>
    var inspirationNoteLinks: Set<InspirationNoteLink>
}
```

名称允许实现阶段按仓库约定调整，但边界不可改变：现有 Calendar 领域作为子图完整保留，Note、Inspiration 与关系是独立一等数据。

### 4.2 日历目标身份

关联关系不能只支持普通 `CalendarItem`，还必须覆盖现有重复实例：

```swift
enum CalendarNoteOwnerID: Hashable, Codable {
    case item(UUID)
    case series(UUID)
}

enum CalendarTargetID: Hashable, Codable {
    case item(UUID)
    case series(UUID)
    case occurrence(OccurrenceKey)
}
```

- 普通事项关联 `.item`。
- 从笔记创建的重复安排关联 `.series`。
- 对某个重复实例执行“仅本次”时，可关联 `.occurrence`。
- 对重复实例执行“本次及以后”时，沿用现有系列拆分语义，再关联新系列。
- 取消不写入任何关系。

### 4.3 笔记

```swift
struct Note {
    let id: NoteID
    var title: String
    var document: BlockDocument
    var categoryID: UUID
    var archivedAt: Date?
    var revision: Int64
    var createdAt: Date
    var updatedAt: Date
}
```

笔记允许没有任何日历关系。正文只存在于 `BlockDocument`，关联它的日历事项不得保存同步副本。

### 4.4 日历与笔记关系

```swift
struct CalendarNoteSet: Equatable, Codable {
    var primaryNoteID: NoteID?
    var referenceNoteIDs: Set<NoteID>
}

enum OccurrencePrimaryOverride: Equatable, Codable {
    case inherit
    case replace(NoteID)
    case clear
}

struct OccurrenceNoteOverride: Equatable, Codable {
    let key: OccurrenceKey
    var primary: OccurrencePrimaryOverride
    var addedReferenceNoteIDs: Set<NoteID>
    var removedReferenceNoteIDs: Set<NoteID>
}

struct CalendarNoteRelationGraph: Equatable, Codable {
    var baselines: [CalendarNoteOwnerID: CalendarNoteSet]
    var occurrenceOverrides: [OccurrenceKey: OccurrenceNoteOverride]
}
```

基数与不变量：

- 一个日历目标可关联 0–1 篇主笔记与 0–N 篇参考笔记。
- 一篇笔记可关联 0–N 个日历目标。
- 同一 Note ID 不能同时出现在同一目标的主笔记与参考集合中。
- `primaryNoteID` 的单值结构保证同一目标最多一篇主笔记。
- 主笔记是点击事项时默认进入的文档。
- 参考笔记只作为相关材料展示，不承担事项正文。
- 更换主笔记是一条原子命令；旧主笔记可降为参考或解除关联，由用户选择。
- 只要一个目标存在有效主笔记，该目标对应作用域内的旧 Markdown 随记必须为空；参考笔记可以与旧随记共存。

### 4.5 重复关系的继承与迁移

重复实例的有效关系按以下顺序计算：

- 普通事项直接读取 `.item` baseline。
- 重复实例先读取所属 `.series` baseline。
- occurrence 的 `primary == .inherit` 时沿用系列主笔记；`.replace(noteID)` 时替换系列主笔记；`.clear` 时明确取消本次主笔记。
- occurrence 的有效参考集合为 `系列参考 - removedReferenceNoteIDs + addedReferenceNoteIDs`，再移除与有效主笔记相同的 Note ID。
- occurrence override 只能覆盖或清除主笔记，不能与系列主笔记叠加出两篇有效主笔记。

重复修改合同：

| 操作 | 关系处理 |
|---|---|
| 仅本次移动或缩放 | `OccurrenceKey` 保持稳定，override 原样保留 |
| 仅本次更换主笔记 | 写入 occurrence primary override，不修改 series baseline |
| 仅本次增删参考笔记 | 分别写入 added/removed 集合，不修改 series baseline |
| 跳过本次实例 | override 暂时保留以支持撤销，但不投影为可点击关系 |
| 本次及以后修改 | 按现有引擎创建新 series；复制 baseline，并确定性迁移分界点及之后的 occurrence overrides |
| 本次及以后删除 | 不创建新 series；移除分界点及之后的 occurrence overrides，并截断或删除旧 owner |
| 删除整个系列 | 删除该 series baseline 与全部 occurrence overrides，任何 Note 都不级联删除 |

“本次及以后”必须让现有系列引擎返回描述真实分支的确定性结果，而不是让关系层猜新 ID 或只映射引擎已经知道的 exception/completion：

```swift
enum SeriesFutureMutationOutcome {
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
```

关系层按 outcome 处理自己持有、可能完全不在 recurrence exception/completion 中出现的 key：

- `.split`：复制旧 baseline 给新 series；遍历关系图中所有 `oldSeriesID && originalDate >= boundary` 的 override，把 key 确定性改为 `newSeriesID + originalDate.addingDays(dayDelta)`；只有新系列范围内的有效实例才保留。
- `.split` 且 `historicalOwnerRetained == true`：旧 baseline 和分界点之前的 override 留给历史；未来 override 只存在于新 key。
- `.split` 且 `historicalOwnerRetained == false`：复制完成后删除旧 baseline 和全部旧 override，不能留下悬空 owner。
- `.deleteFuture`：不创建、不复制 baseline；删除分界点及之后的关系 override。历史 owner 保留时继续保留 baseline，历史 owner 被引擎删除时同步删除 baseline 与剩余 override。
- 关系 override、recurrence exception 与 completion 的 key 来源不要求互为子集；outcome 的 `boundary + dayDelta + 新系列实际边界` 必须能转换三者 key 的并集。

事务顺序固定为：

1. 系列引擎完成修改或删除并生成 `SeriesFutureMutationOutcome`。
2. Workspace 用 outcome 迁移或清理 baseline 与 occurrence overrides。
3. 如果本次命令本身修改关系，只在对应的新 series、历史 series 或 occurrence 目标上应用一次。
4. WorkspaceValidator 拒绝任何指向已删除 series 的 baseline/override，以及同一逻辑实例的新旧双 key。
5. 系列、例外、完成记录与关系图一次性原子保存；任何一步失败全部回滚。

系列拆分、未来删除、首个实例导致旧系列移除、历史保留、跳过、撤销和恢复必须验证 effective relation，而不只测试三类 ID 的静态增删。

### 4.6 灵感

用户提交的输入介质与系统识别出的材料语义分开建模：

```swift
enum CaptureInputKind: String, Codable {
    case text
    case url
    case file
}

enum ResolvedSourceKind: String, Codable {
    case plainText
    case article
    case socialPost
    case video
    case audio
    case image
    case document
    case unknown
}

enum InspirationLifecycle: String, Codable {
    case active
    case archived
}
```

```swift
struct Inspiration {
    let id: InspirationID
    let inputKind: CaptureInputKind
    var rawText: String?
    var rawURL: URL?
    var rawFile: FileReference?
    var resolvedSourceKind: ResolvedSourceKind
    var resolvedMetadata: SourceMetadata?
    var categoryID: UUID
    var lifecycle: InspirationLifecycle
    var createdAt: Date
    var updatedAt: Date
}

enum InspirationSourceReference: Hashable, Codable {
    case live(InspirationID)
    case deleted(originalID: InspirationID, deletedAt: Date)
}

struct InspirationNoteLink: Hashable, Codable {
    var source: InspirationSourceReference
    let noteID: NoteID
    let createdAt: Date
}
```

首版 UI 只创建 `.text` 与 `.url`；`.file` 为后续材料输入保留合同。URL 的文章、社交帖子、视频或音频类型来自解析结果，不由用户在输入前手动选择。无法识别时使用 `.unknown`。

输入不变量：

- `.text` 必须有非空 `rawText`，且不携带 URL 或文件引用。
- `.url` 必须有可解析的 `rawURL`，且不携带正文或文件引用。
- `.file` 必须有可恢复的 `rawFile` 引用，且不携带正文或 URL。
- `SourceMetadata` 首版只包含可选标题、站点、域名、缩略图 URL 与抓取状态；它不是原始输入的替代品。

灵感转成笔记后保留原始记录，并新增一条 `InspirationNoteLink`；它不会被替换或静默删除。首版“转成笔记”对同一灵感只创建一篇笔记，重复操作进入已有笔记；关系结构允许未来显式增加多篇派生笔记。

左栏状态是生命周期与关系的派生结果，不把“已形成笔记”和“已归档”塞进互斥枚举：

- `lifecycle == .active` 且没有 live Note 关系：待处理。
- `lifecycle == .active` 且存在 live Note 关系：已形成笔记。
- `lifecycle == .archived`：已归档；详情仍显示是否形成过笔记。
- 从归档恢复统一回到 `.active`，再根据关系自动进入“待处理”或“已形成笔记”。
- 永久删除有关联的灵感时，同一事务把每条 `.live(id)` 关系改为 `.deleted(originalID:deletedAt:)`，再删除原始对象；墓碑不保留原文或 URL，Note 只显示“原始灵感已删除”。

### 4.7 共享分类

Note、Inspiration 和 Calendar 继续引用同一套 Category ID：

- 笔记和日历都必须拥有一个分类，可使用“未分类”。
- 灵感快速记录时不要求显式选择，但保存时归入“未分类”。
- 分类改名、改色在三个模块同步生效。
- 删除分类时，三个模块中的引用都迁移到“未分类”，不能留下悬空 ID。
- 分类的唯一业务真相仍是 `workspace.calendar.categories`；Note 和 Inspiration 只保存其 ID。
- 创建、改名、改色、排序和删除只能经过 Workspace 级分类命令。现有 Calendar 分类 reducer 降为该命令内部步骤，页面不能再直接调用它修改持久状态。
- Workspace 分类删除在一次事务中迁移 Calendar、Note 和 Inspiration 的全部引用，再运行 `WorkspaceValidator` 并保存。
- `WorkspaceValidator` 必须保证“未分类”存在且所有跨模块 categoryID 可解析；任何模块迁移失败都回滚整条命令。

## 5. Block 文档合同

### 5.1 结构化文档与可迁移性

笔记不以 Markdown 或整体富文本作为唯一业务真相，而使用带版本号的结构化 Block 文档：

```swift
struct BlockDocument {
    var schemaVersion: Int
    var blocks: [DocumentBlock]
}

struct DocumentBlock: Identifiable {
    let id: UUID
    var kind: DocumentBlockKind
    var inlineContent: InlineContent
    var taskState: TaskBlockState?
    var indentLevel: Int
}

struct TaskBlockState: Equatable, Codable {
    var completedAt: Date?
}
```

首版 Block 类型：

- 正文
- 一级至三级标题
- 无序列表项
- 有序列表项
- 待办
- 引用
- 代码
- 分割线
- 链接

每个 Block 拥有稳定 ID。行内内容保留最小必要的粗体、斜体、行内代码与链接标记。图片、表格、附件和第三方嵌入不进入首版。

只有待办 Block 可以拥有 `taskState`，其他类型必须为 `nil`。待办是否完成以 `completedAt != nil` 判断，而不是另存一个可能冲突的布尔值。

缩进不变量：

- 只有无序列表、有序列表和待办允许 `indentLevel` 为 0...3；其他 Block 必须为 0。
- `indentLevel > 0` 的 Block 前方同一连续列表组中必须存在 `indentLevel - 1` 的父级，不能形成孤立缩进。
- `Tab` 到 3 后不再增加；`Shift-Tab` 到 0 后不再减少。
- 多 Block 拖动必须把选中根及其连续后代作为一个结构移动，不能留下孤儿。
- Markdown 导出每级使用确定的四空格嵌套；导入接受受支持的合法嵌套并归一到 0...3，超过深度的内容保留文字并降到第 3 级，不能丢失。

### 5.2 编辑体验

笔记编辑器以 Notion、飞书文档的核心编辑质感为目标，但不复制其全部功能：

- 标题与正文直接编辑，没有表单式边框。
- 支持 Markdown 快捷输入和斜杠菜单。
- 支持块选择、拖动排序、快捷删除、撤销与重做。
- 支持富文本粘贴；无法识别的内容降级为普通文本，不丢字。
- 支持标题、列表、待办、引用与链接的键盘连续编辑。
- 格式控件按需出现，正文保持安静。
- 自动保存正常时不持续打扰用户，失败时明确显示状态和重试入口。

首版键盘合同：

| 输入 | 必须行为 |
|---|---|
| `Enter` | 在光标处分割 Block；标题后新建正文；列表或待办延续同类 |
| 空列表或空待办中 `Enter` | 退出当前结构并变成正文，不继续制造空列表 |
| `Shift-Enter` | 在当前 Block 内插入软换行，不创建新 Block |
| 行首 `Backspace` | 先把空的特殊 Block 降为正文；再次操作才与前一 Block 合并或删除 |
| `Tab` / `Shift-Tab` | 列表与待办在 0...3 内缩进或反缩进；代码块插入或移除文本缩进；其他 Block 保持 0 且不改变类型 |
| 上下方向键 | 在边界自然跨 Block 移动光标，不能跳到文档外或丢失选择 |
| `/` 菜单 | 上下键选择、`Enter` 确认、`Escape` 关闭；关闭后原始输入可恢复 |
| 跨 Block 文本选择 | `Shift` 键与指针可连续选择、复制、剪切或格式化受支持内容 |
| Block 多选 | 从悬停柄选择，`Shift` 扩展范围；删除后至少保留一个可编辑正文 Block |
| 多 Block 拖动 | 保持原 Block ID、顺序与内容，整次拖动只产生一个撤销步骤 |
| 中文 IME 组合态 | marked text 期间不触发 Markdown 转换、斜杠菜单命令或 Block 分割；`Enter` 优先完成候选输入 |
| 粘贴 | 支持的富文本转成对应 Block；不支持的内容降级为原样普通文本 |
| `Command-Z` / `Shift-Command-Z` | 用户动作可逆；后台自动保存不能打断撤销分组 |

上述行为必须在中英文、emoji、空文档、文档首尾和多 Block 选择下拥有自动化或真实输入验收，不能只验证工具栏按钮存在。

### 5.3 Markdown 适配

- 支持首版 Block 类型的 Markdown 导入与导出。
- 对受支持结构，导入后再导出必须保持业务等价。
- 无法映射的 Markdown 结构保留原始文本，禁止静默丢弃。
- 现有日历事项中的 Markdown 随记在“转成笔记”时解析为 Block。
- 转换成功并完成持久化后，原日历事项不再保留该正文副本。

### 5.4 待办 Block 与日历

```swift
struct TaskBlockCalendarLink: Hashable, Codable {
    let noteID: NoteID
    let blockID: UUID
    let calendarItemID: UUID
}
```

合同：

- 一个待办 Block 同一时间最多关联一个非重复日历事项。
- 一个日历事项最多由一个待办 Block 驱动。
- 从待办 Block 安排到日历时，创建事项、建立主笔记关系和 Block 关系必须原子完成。
- Block 关系成立时，该事项的主笔记必须是拥有这个 Block 的 Note。
- 再次安排同一 Block 修改已有事项日期，不重复创建。
- 重复安排不进入首版 Block 流程；需要重复的行动应创建普通日历安排。
- Block 关系存在时不能把事项改成重复系列；用户必须先解除 Block 关系，或另建普通重复安排。
- 更换或移除这类事项的主笔记前，必须先确认解除 Block 关系。
- 在任一侧切换完成状态时，使用一个领域命令原子更新另一侧。
- 完成命令从注入的 Clock 只取一次时间：完成时把同一个 `completedAt` 写入 CalendarItem 与 TaskBlock，取消完成时两侧同时写入 `nil`。
- 持久化状态必须满足两侧 `completedAt` 完全相等，而不只是布尔状态相同；任何半成功都回滚。
- 重复提交相同目标状态是幂等操作，不刷新完成时间；撤销恢复两侧精确的旧时间值。
- 删除日历事项时，待办 Block 保留当前完成值并解除日期安排。
- 删除仍有关联事项的待办 Block 时，用户选择保留为独立日历事项或一起删除。
- 解除关系时，两侧保留解除前完全相同的 `completedAt`，之后独立演进。

未来 AI 拆解子任务时先创建待办 Block；只有用户选择安排的 Block 才创建日历事项。

## 6. 页面与交互

### 6.1 日历页

现有连续周流、创建、拖选、跨日缩放、完成、重复、筛选和分类管理保持不变。

新增：

- 新建入口提供“新建事项”与“从笔记安排”。
- “从笔记安排”可搜索笔记并选择主笔记，再填写行动标题和时间。
- 事项编辑卡片增加笔记区域，展示主笔记摘要与参考笔记列表。
- 用户开始输入非空正文后显示“转成笔记”；空正文不显示。
- 点击主笔记切换到笔记页并定位文档。
- 可搜索并添加已有笔记为主笔记或参考笔记；添加参考笔记不会改变事项随记。
- 已有主笔记时，不再显示“转成笔记”，改为进入或更换主笔记。

设置已有主笔记前必须先检查所选普通事项、系列或 occurrence 作用域内的有效 Markdown 随记：

- 随记为空时可以直接建立主笔记关系。
- 随记非空时禁止直接建立关系，也禁止静默清空。界面必须提供“预览并迁入所选笔记”“转成一篇新的主笔记”“取消”三种明确选择。
- “预览并迁入”先展示将追加到所选笔记末尾的 Block；确认后在一个事务中解析并追加 Block、清空该作用域的随记、建立主笔记关系。
- “转成一篇新的主笔记”走下述标准转换事务，不修改刚才选中的已有笔记。
- 用户只想保留事项随记时，可以退出主笔记流程并把已有笔记添加为参考。
- 普通事项清空自己的 `notes`；“仅本次”创建或修改 notes 为空的 `OccurrenceOverride`，不清空系列正文；“本次及以后”先拆分系列，再只清空新系列正文。
- 合并解析、Note 更新、随记清空、系列拆分或关系保存任一步失败时，所选笔记与日历内容都保持操作前状态。

“转成笔记”是一条事务：

1. 以事项标题与正文创建 Note。
2. 把 Markdown 正文解析为 Block。
3. 建立 `.primary` 关系。
4. 只有前三步全部可持久化后，才按普通事项、仅本次或本次及以后作用域移除事项正文副本。
5. 成功后切换到笔记页并继续编辑；失败时事项正文原样保留。

重复实例上的关系操作复用现有“仅本次 / 本次及以后 / 取消”范围确认，不静默把单次意图扩散到整个系列。

### 6.2 笔记页

笔记页采用可收起的双栏布局：

- 左栏：搜索、分类、最近编辑、全部笔记、归档、笔记列表与新建。
- 右栏：标题、极简 Block 正文，以及少量文档级元信息和操作。
- 顶部只保留分类、保存异常状态、“安排到日历”和更多操作。
- 关联日历事项和参考关系通过按需浮层或文档信息入口查看，不永久挤压正文。
- 从日历进入时直接定位并聚焦目标笔记。

“安排到日历”从当前笔记创建一个新的日历事项，并将当前笔记设为主笔记。用户可多次执行，从而让一篇笔记拥有多个不同标题、日期和完成状态的行动。

### 6.3 灵感页

灵感页是处理收件箱：

- 左栏：待处理、已形成笔记、已归档、条目列表。
- 右栏：原始内容、来源信息、创建时间、分类和处理操作。
- 顶部提供始终可见的快速输入框。
- 粘贴 URL 时识别为 `.url`；其他非空输入保存为 `.text`。
- 首版操作为“转成笔记”“归档”“复制链接”。
- 转成笔记后保留原始灵感，并显示笔记入口。
- App 内提供快速进入输入区的快捷键；系统级全局捕捉窗口不进入首版。

URL 保存顺序固定为：

1. 原子保存原始 URL 与 `.unknown` 来源类型。
2. 异步尝试解析基础元数据。
3. 成功后更新标题、站点与解析类型。
4. 失败时保留原始 URL，显示可重试状态，不影响入箱。

第一阶段不抓取全文、不生成摘要，也不把网络错误描述成 AI 处理结果。

## 7. 删除、归档与关系生命周期

- 删除日历事项永远不会自动删除笔记或灵感。
- 首版的普通“删除”动作等价于归档；只有从归档列表执行“永久删除”才会物理删除。
- 归档笔记仍保留关系；日历中显示已归档状态并允许恢复。
- 永久删除仍有关联目标的笔记前，必须展示影响并确认解除关系。
- 解除笔记关系不会复制正文回日历事项。
- 灵感归档不影响由它形成的笔记。
- 永久删除灵感不级联删除笔记，但笔记中已有的来源引用显示“原始灵感已删除”。
- 普通解除关系与归档必须经过领域命令并参与撤销；永久删除经过独立确认并生成可审计 tombstone 或恢复快照，视图不得直接修改集合。

## 8. 持久化、迁移与恢复

### 8.1 Schema V3

当前 `CalendarDocument` schema 为 2。工作空间持久化提升为 schema 3，并使用显式 V2 DTO 迁移，禁止通过新字段默认值猜测旧数据。

V2 → V3：

- 把完整 V2 `CalendarState` 原样放入新的 `WorkspaceState.calendar`。
- Workspace revision 初始化为 0；Notes、Inspirations 与所有关系图初始化为空。
- 保留所有事项、系列、例外、分类、完成状态、优先级、随记、时间戳和稳定 ID。
- 现有事项随记不会自动转成笔记，仍留在事项中，直到用户明确点击“转成笔记”。
- V1 备份继续通过现有 V1 → V2 → V3 链路恢复，不跳过中间校验。

### 8.2 写入合同

- 跨对象命令在同一个工作空间事务中验证并原子写入。
- 每次成功的持久状态命令单调递增 Workspace revision；Note 内容或元信息变化同时递增该 Note revision。失败命令不递增任何 revision。
- 写入采用临时文件、同步、替换的现有原子持久化合同。
- 迁移只先发生在内存；正常保存或恢复确认前不覆盖旧主文件。
- 迁移、校验或保存失败不能覆盖最后一份有效主文件。
- 第一次用 V3 替换 V2 主文件前，必须先把 V2 原始字节写成独立、字节精确的迁移快照。
- 快照文件名包含源字节 SHA-256；相同源字节已有有效快照时复用，不覆盖；源字节不同则创建新的快照，旧快照仍保留。
- 快照使用临时文件、同步和原子替换；快照写入或校验失败时禁止第一次 V3 覆盖，并在界面提供重试。
- 快照登记到恢复清单中，可从恢复入口真实读取并走 V2 → V3 校验链路；不能只留下用户找不到的文件。
- 未知 schema 在业务 payload 解码前拒绝。
- 搜索索引是可重建投影，不能成为正文、原始灵感或关系的唯一来源。

### 8.3 自动保存与失败恢复

- Block 编辑使用短延迟自动保存并合并连续输入，避免每次按键单独写盘。
- 窗口关闭、模块切换和应用退出前触发最终刷新。
- 正常保存保持安静；失败时显示“未保存”、原因、重试与保留草稿状态。
- 主工作空间写盘失败后，当前内存草稿和最后一份磁盘版本都必须保持不被覆盖。
- URL 元数据失败、Block 解析失败和关系目标缺失分别报告，不使用笼统成功状态。
- 启动一致性检查发现悬空关系时，隔离关系并保留两侧内容，再提供修复或解除入口。

### 8.4 草稿恢复 Journal

仅靠内存无法兑现崩溃或重启恢复。Block 编辑必须使用独立于主 Workspace 文件的恢复 Journal：

```swift
struct DraftJournalEntry: Codable {
    let noteID: NoteID
    let baseWorkspaceRevision: Int64
    let baseNoteRevision: Int64
    let draftGeneration: UInt64
    let noteSnapshot: Note
    let updatedAt: Date
    let noteSnapshotChecksum: String
    let journalChecksum: String
}

struct PersistedDraftReceipt: Equatable {
    let noteID: NoteID
    let draftGeneration: UInt64
    let noteSnapshotChecksum: String
    let persistedNoteRevision: Int64
}
```

- Note 创建时立即获得稳定 ID；新笔记也可以写入 Journal。
- 每次编辑都单调递增仅属于编辑草稿的 `draftGeneration`，即使主 Workspace 尚未成功保存也会递增；它与持久 Note revision 不是同一计数器。
- 编辑发生后先以短延迟原子写入最新 Journal，再按较长延迟保存主 Workspace；Journal 写成功只表示“草稿已保护”，不冒充主文件已保存。
- `noteSnapshotChecksum` 使用确定性编码覆盖所有受 Journal 保护的用户状态：Note ID、标题、BlockDocument、categoryID 与 archivedAt；排除 revision、updatedAt 等非内容字段。标题修改与正文修改拥有同等恢复保障。
- 保存 Note 时把当前 `draftGeneration` 和 `noteSnapshotChecksum` 一起传入保存请求；成功结果必须返回对应的 `PersistedDraftReceipt`。
- 只有 receipt 明确包含同一个 draft generation，且主文件中该 Note 的规范化 snapshot checksum 与 Journal 完全相同时，才清理 Journal。一次无关日历保存、仅 revision 相等或 `>=` 都没有清理资格。
- Journal 清理失败不影响主文件；下次启动只有在主文件 snapshot checksum 与 Journal snapshot checksum 相同时才安全丢弃旧 Journal。
- 启动时先校验 `journalChecksum`，再比较 snapshot checksum 和 revision。snapshot 不同时显示恢复预览，由用户选择“恢复为当前版本”“保留磁盘版本”或“另存为新笔记”，禁止静默覆盖。
- 损坏的 Journal 被隔离并报告，不覆盖主文件。
- 如果主文件与 Journal 都写失败，界面必须明确说明“重启后可能无法恢复”，阻止无提示关闭，并提供复制正文或导出草稿；此时不得声称已经安全保存。
- 自动化必须分别注入主文件失败、Journal 失败、两者同时失败、Journal 清理失败和启动冲突。

## 9. 搜索与投影

- 笔记首版支持标题与正文全文搜索，并可按共享分类筛选。
- 灵感支持原始文字、URL、已解析标题与域名搜索，并可按状态和分类筛选。
- 搜索结果使用稳定对象 ID，索引更新失败不影响对象保存。
- 关联日历列表、灵感数量徽标和分类计数均为可重建投影。
- 第一阶段不提供跨三个模块的全局搜索入口，避免把捕捉、行动与文档结果混成一个未定义排序的列表。

## 10. 未来 AI 与知识库扩展点

第一阶段只建立数据合同，不展示不可用的 AI 按钮。

后续 AI 能力包括：

- 对选中文字、目标 Block 或整篇文档发起讨论。
- 把结果作为差异草稿预览，用户应用后写入。
- 根据笔记内容生成待办 Block，再由用户选择安排到日历。
- 对灵感进行梳理、延展、搜索和相关材料发现。
- 对文章、音频、视频和文件生成带来源的提炼结果。
- 基于 Note、Inspiration、Source 与显式关系构建知识库，而不是复制第四份正文。

AI 会话、建议、来源和应用记录应独立建模。它们不能被塞进 `BlockDocument` 作为不可区分的正文，也不能直接覆盖原始灵感。

## 11. 第一阶段范围

### 11.1 包含

- 固定窄图标导航栏与三个真实页面。
- 日历能力和数据完整保留。
- Workspace、Note、Inspiration、带角色 Note 关系与 Task Block 关系。
- 极简 Block 编辑器首版及受支持 Markdown 导入导出。
- 笔记创建、搜索、分类、编辑、自动保存、归档与恢复。
- 事项转成主笔记、关联主笔记与多篇参考笔记。
- 一篇笔记创建多个普通或独立的日历行动。
- 待办 Block 的单次日历安排与完成状态双向同步。
- 灵感文字或 URL 入箱、分类、转成笔记与归档。
- URL 基础元数据的失败安全解析。
- 快捷键、键盘操作与基础辅助功能。
- V2 → V3 迁移、V1 恢复链路、备份与错误恢复。

### 11.2 不包含

- AI 对话、改写、拆任务或自动应用。
- 文章、音频、视频的全文获取、提炼与总结。
- 文件上传、图片、表格、附件和复杂嵌入 Block。
- 知识库、关系图谱和跨模块全局搜索界面。
- 云同步、多人协作与移动端。
- 系统级全局快速记录窗口。
- 待办 Block 的重复日历系列。
- Notion、飞书的完整高级功能集合。

## 12. 验收合同

### 12.1 自动化

- Workspace、Note、Inspiration 与关系不变量的领域测试。
- 普通事项、系列和 occurrence 三类 CalendarTarget 的 effective relation 测试。
- 系列“仅本次 / 本次及以后修改 / 本次及以后删除 / 无历史旧系列移除 / 跳过 / 撤销”的 relation outcome、override 和 effective relation 测试。
- 主笔记唯一、参考笔记多选和更换主笔记的命令测试。
- 非空事项随记设置已有主笔记时的合并预览、转成新笔记、取消和失败回滚测试。
- 待办 Block 安排、改期、双向完成时间戳、幂等、解除与删除分支测试。
- Block 编解码、0...3 层列表结构、首版 Markdown 等价往返和失败保真测试。
- Enter、Backspace、Tab、方向键、Slash、多 Block、中文 IME、粘贴和 Undo 的编辑器输入矩阵。
- V2 → V3、V1 → V2 → V3、未知 schema、损坏数据和恢复回滚测试。
- V2 原始字节快照的写入失败、幂等、不同 hash、恢复清单和字节等价测试。
- 转成笔记、安排到日历和灵感转笔记的事务失败注入测试。
- URL 保存先于元数据解析及解析失败测试。
- 灵感待处理、已形成笔记、归档、恢复与永久删除 tombstone 的派生状态测试。
- Workspace 分类命令迁移三个模块引用及任一模块失败时全量回滚测试。
- 主文件与 Draft Journal 各类单独或组合失败、无关保存不得清理、generation/checksum 匹配、清理失败和启动冲突恢复测试。
- 搜索索引可重建与索引失败不丢正文测试。
- 现有 Calendar 全量测试保持绿色。

### 12.2 真实产品验收

- 在升级前数据的副本上启动打包后的 Jelly.app，确认现有日历内容与交互无损。
- 三个一级入口可通过点击、快捷键和辅助功能切换，并保留页面状态。
- 笔记可独立创建、编辑、搜索、分类、归档、恢复，并在重启后保持。
- 事项转成笔记后正文不重复、不丢失；失败时原事项仍完整。
- 有随记的事项关联已有主笔记时必须经过合并或转换选择，不允许产生双正文。
- 一个事项可正确展示一篇主笔记和多篇参考笔记。
- 重复系列拆分后，历史与未来实例分别保持正确的主笔记和参考笔记。
- 一篇笔记可创建多个标题、日期和完成状态互相独立的日历行动。
- 待办 Block 与关联日历事项完成状态双向一致，不重复创建事项。
- 灵感从文字或 URL 入箱、形成笔记到归档形成闭环。
- 离线或解析失败时 URL 仍可保存，界面不显示虚假摘要。
- 模拟写盘失败后，未保存状态、重试和重启恢复均真实可用。
- 浅色、深色、至少 1044pt 的最小窗口、全屏、键盘、中文 IME、VoiceOver 与 Reduce Motion 通过体验检查。
- Release 构建、应用打包和从 `/Applications` 等真实安装位置启动通过。

## 13. 实施前门禁

本规格获书面审阅确认后，下一步才进入实现计划。实现计划必须：

- 先锁定 Workspace V3、迁移与关系命令，再开始页面 UI。
- 将 Block 编辑器、笔记闭环、日历关联、灵感闭环拆成可独立验收的纵向任务。
- 每个任务包含领域测试、持久化测试和必要的真实应用验证。
- 不以空页面、内存假数据或不可用 AI 控件算作完成。
- 最后执行全量自动化、Release 构建、打包后端到端验收与独立整体审查。
- 在完整 Goal 全部通过前连续推进；每轮计划最后一项必须是“自动继续下一任务”。

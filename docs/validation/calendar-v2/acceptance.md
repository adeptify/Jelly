# 个人月历 V2 验收记录

验收日期：2026-08-04（Asia/Shanghai）

本记录严格区分自动化验证、可交付包验证与原生 GUI 验收。自动化绿色只证明对应合同；未实际启动最终打包应用完成的鼠标、窗口、视觉与辅助功能路径一律保持 `PENDING / NOT RUN`，不得记为通过。

## 当前结论

- 自动化领域／应用／持久化测试：`PASS`，`302 tests / 24 suites`，非零匹配。
- 打包 archive、fault-injection、symlink/non-regular 三道门禁：`PASS`。
- 正式 `Scripts/build-app.sh` 与 `swift build --product PersonalCalendar`：`PASS`。
- ZIP 新鲜解包与 DMG `-readonly -nobrowse` 挂载后的 plist、真实可执行文件、严格签名、Applications 链接和 CDHash 一致性：`PASS`。
- 最终打包应用的九项原生 GUI 验收：`PENDING / NOT RUN`，待主 Agent 使用下述最终包执行。

## 自动化与集成证据

`CalendarStoreTests.v1PrimaryToV2StoreProjectionAndUndoRoundTripKeepsOneCrossDayIdentity` 使用真实临时磁盘上的非空 schema 1 primary。fixture 含固定 ID 与 metadata 的 category/item/series、modified/skipped exception 和 completion；经 `JSONCalendarRepository → CalendarStore → TimelineProjection` 后逐项核对迁移结果，再创建跨月事项。投影保留完整图语义且新事项只有一个来源身份；撤销后内存与磁盘完全相等，primary 为 schema 2。

`CalendarStoreTests.v1BackupRestoreMigratesThroughStoreAndCorruptBackupCannotOverwriteIt` 使用同一非空 schema 1 完整图恢复到 V2 Store。有效恢复生成的 rollback 与恢复前 primary 原始 bytes 完全相等；随后损坏备份不改变内存、schema 2 primary 或既有 rollback，也不生成 rejected rollback。V1 迁移 DTO 解码仍保留；临时运行时兼容 initializer/property、`MonthViewModel` 的 fixed-month façade 与固定月格 business-truth 已删除。

最终命令结果：

| 门禁 | 结果 | 证据 |
| --- | --- | --- |
| `Scripts/test.sh` | PASS | 302 tests / 24 suites |
| `Scripts/test-build-app-archive.sh` | PASS | ZIP 新鲜解包与只读 DMG 中 app 均严格签名，且 CDHash 相同 |
| `Scripts/test-build-app-failures.sh` | PASS | 创建失败、发布中断、验证失败、两个有效签名但 CDHash 不同、首次发布失败及尽力启动副本失败均保持或恢复权威 pair；正式 published DMG 的 mount-point 元数据缺失、首次 detach 失败，以及 rollback verify 自身首次 detach 失败均由完整 attachment 集合保留身份并最终清理。定点用例硬断言三个 one-shot marker 各为一条 `fired`，正式 DMG attach occurrence 精确为 `1 2`（published／rollback），旧 pair 精确字节不变，测试结束无临时 image-path/device/mount 残留；临时禁用 rollback remove 注入时 mutation gate 按预期因 marker 缺失转红 |
| `Scripts/test-build-app-symlink.sh` | PASS | symlink dist、非普通 ZIP 目标、symlink DMG 目标均拒绝，sentinel 不变 |
| `Scripts/build-app.sh` | PASS | 同一事务发布正式 ZIP/DMG pair |
| `swift build -c release --product PersonalCalendar` | PASS | release 产品构建完成 |

清理复核命令 `rg 'MonthProjection|MonthGridBuilder|dropDestination|@available.*deprecated|deprecated' Sources Tests` 只剩 `WeekRowView` 的两个真实 `.dropDestination` 消费点；没有 deprecated API 命中。已删除：

- `Sources/CalendarDomain/MonthProjection.swift`
- `Sources/CalendarApp/Month/MonthGridBuilder.swift`
- `Sources/CalendarApp/Month/DayCellView.swift`
- `Tests/CalendarAppTests/MonthGridBuilderTests.swift`

`CalendarTransferPayload: Transferable` 因 `WeekRowView` 的真实拖放消费者继续保留。

`MonthViewModel` 生产与测试调用现使用 `centeredOn`、`moveWeekStreamFocus(to:)` 和 `projectedItem(withID:)`。旧 `displayedMonth`、`goToPreviousMonth`、`goToNextMonth`、`goToToday` 与 `item(withID:)` façade 在 Sources/Tests 中零引用并已物理移除。

## 最终交付物

| 制品 | 绝对路径 | SHA-256 |
| --- | --- | --- |
| 权威 ZIP | `/Users/oreal/Documents/个人管理工具/.worktrees/calendar-v1/dist/个人月历.app.zip` | `0d633281f79a7c00a8016c17e0f316f1e0e877d4f2f2feabcdcfadcc5e9e86f2` |
| Finder 友好 DMG | `/Users/oreal/Documents/个人管理工具/.worktrees/calendar-v1/dist/个人月历.dmg` | `5098f5c81a52d2984b73898534eba58f423bb7fbb28d76c06069bfb5af0f2eb1` |

- ZIP 新鲜解包 app CDHash：`7f2d81c00ab594e1d8931c74af8256df6f9db0a6`
- DMG 只读挂载 app CDHash：`7f2d81c00ab594e1d8931c74af8256df6f9db0a6`
- DMG 包含 `Applications -> /Applications`；ZIP 与 DMG 中 app 均通过 `plutil -lint`、真实 `CFBundleExecutable` 普通文件／可执行检查及 `codesign --verify --deep --strict`。
- `dist/个人月历.app` 是尽力发布的本机启动副本；正式交付身份由 ZIP/DMG pair 共同承担。

## 原生打包应用验收

以下九项均未在本任务中启动最终包执行，状态统一为 `PENDING / NOT RUN`：

| # | 待验场景 | 状态 |
| --- | --- | --- |
| 1 | 单击窗口四个边缘附近日期，创建卡片跟随日期就近出现并在必要时自动翻边 | PENDING / NOT RUN |
| 2 | 正向与反向拖选跨月范围，持续高亮并把归一化起止日期正确预填到创建卡 | PENDING / NOT RUN |
| 3 | 全屏向前、向后连续滚动至少各 52 周；扩展不跳位，标题跟随中心周跨月更新 | PENDING / NOT RUN |
| 4 | 单日 10 条直接可见，第 11 条产生正确 overflow，且条带身份不重复 | PENDING / NOT RUN |
| 5 | 普通跨日条带主体移动、左右真实外端缩放与 Command-Z 原子撤销 | PENDING / NOT RUN |
| 6 | 重复跨日条带的“仅本次／本次及以后／取消”，并覆盖保存失败后的可重试恢复 | PENDING / NOT RUN |
| 7 | 关闭并重启最终打包应用后，范围、完成状态、分类和重复实例保持 | PENDING / NOT RUN |
| 8 | schema 1 备份恢复成功；无效或损坏备份不覆盖当前数据 | PENDING / NOT RUN |
| 9 | 浅色／深色、五组色板、自定义极端颜色、VoiceOver 元素顺序与减少动态效果 | PENDING / NOT RUN |

逐项操作与记录栏见 [V2 原生视觉与交互清单](visual-checklist.md)。收到原生操作证据前，本记录不宣称 V2 已完成真实 GUI 验收。

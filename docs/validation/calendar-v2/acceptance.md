# 个人月历 V2 验收记录

验收日期：2026-08-04（Asia/Shanghai）

本记录区分自动化合同、可交付制品、真实原生 GUI 和用户环境保护。最终 GUI 验收使用 ZIP 中新鲜解包的真实可执行文件；为避免与用户正在运行的同 Bundle ID 应用串进程，只复制该可执行文件并为临时验收壳更换 Bundle ID。验收壳可执行文件与最终 ZIP 中可执行文件的 SHA-256 完全一致，业务代码没有改动。更换 `Info.plist` 身份后，临时壳的原始 bundle 签名按设计失效，因此临时壳不作为签名证据；签名、plist、可执行权限、Applications 链接与 CDHash 均在未修改的最终 ZIP／DMG app 上单独严格验证。

## 最终结论

- 自动化领域／应用／持久化：`PASS`，`312 tests / 24 suites`，零失败（含 `0215f65` 新增完成态迁移回归）。
- Debug、Release、archive、fault-injection、symlink/non-regular 与正式双制品发布门禁：`PASS`（2026-08-04 续接后已重跑）。
- ZIP／DMG 的 plist、真实可执行文件、严格深度签名、Applications 链接、可执行字节和 CDHash 一致性：`PASS`（制品已按 `0215f65` 重建）。
- 九项最终打包应用原生 GUI 验收：`PASS`（证据与操作在 `93c8d8f` 冻结二进制上完成；见下方“续接增量”）。
- fresh Sol ultra 原生交互修复复审：`PASS`，`0 Critical / 0 Important / 0 Minor`。
- fresh Sol ultra 打包门禁 finding scoped re-review：`PASS`，`0 Critical / 0 Important / 0 Minor`；先前 `3 Important / 1 Minor` 全部关闭。
- Session 末尾 Important（事件系列单次改待办后，thisAndFuture 调整丢失完成态）：已以 `0215f65` 修复，领域回归测试覆盖；未再扩 GUI 九项重跑。

## 验收对象与隔离边界

| 项目 | 值 |
| --- | --- |
| ZIP 新鲜解包 app | `/tmp/personal-calendar-v2-final-gui.TkF6cM/unzip/个人月历.app` |
| 临时验收壳 | `/tmp/personal-calendar-v2-final-gui.TkF6cM/harness/个人月历最终验收.app` |
| 最终／验收壳可执行 SHA-256（GUI 冻结时） | `60eeff08157dd56d60f6e852fa50cae939f4eb9209b5e898966531cd8024f384` |
| 当前权威可执行 SHA-256（`0215f65` 重建） | `86e2c08f7ecbacf3aa82232509f56f0f3e818fd4bcc3da2fc49d878fe04c5cd2` |
| 最终 Bundle ID | `com.oreal.personalcalendar` |
| 临时验收 Bundle ID | `com.oreal.personalcalendar.acceptance.final` |
| 临时壳签名边界 | `Info.plist` 身份修改使最终包签名不再适用；不用于签名结论 |
| 隔离 HOME 根目录 | `/tmp/personal-calendar-v2-final-gui.TkF6cM/homes` |

原生 GUI 分别使用 `primary`、`density`、`restore`、`failure`、`recurring` 五套隔离 Application Support。用户真实数据 `/Users/oreal/Library/Application Support/PersonalCalendar/calendar-v1.json` 未作为验收输入；验收结束后其修改时间仍为 `2026-08-04 00:19:05`，SHA-256 为 `6e48cfbc0f41b7ddb3820e5ba0a04ccab49d8d45e09905cc1cb6455e6316df2a`。用户从 DMG 运行的进程 PID `37615` 在整个最终验收后仍存活，用户挂载的 `disk4`／`disk5` 未被卸载。

## 自动化与构建门禁

`CalendarStoreTests.v1PrimaryToV2StoreProjectionAndUndoRoundTripKeepsOneCrossDayIdentity` 使用真实临时磁盘上的非空 schema 1 primary，覆盖固定身份的 category/item/series、modified/skipped exception、completion、跨月来源唯一性与撤销后内存／磁盘精确还原。

`CalendarStoreTests.v1BackupRestoreMigratesThroughStoreAndCorruptBackupCannotOverwriteIt` 覆盖 schema 1 完整图恢复、rollback 原始字节、损坏备份拒绝和既有 rollback 保持。

| 门禁 | 结果 | 关键证据 |
| --- | --- | --- |
| `Scripts/test.sh` | PASS | 312 tests / 24 suites |
| `swift build` Debug／Release | PASS | 两种配置均完成 |
| `Scripts/test-build-app-archive.sh` | PASS | ZIP 新鲜解包与只读 DMG app 严格签名且 CDHash 相同；attach 后先登记本次 device，mount metadata 缺失与首次 detach 失败都按该 device 清理且无残留 |
| `Scripts/test-build-app-failures.sh` | PASS | candidate ZIP 解包／签名与 candidate DMG attach／内容四条失败路径、正式发布、签名错配、attach/detach 与 rollback verify 故障均保持或恢复权威 pair；detach event 精确绑定 source、occurrence、device；无临时发布或挂载残留 |
| `Scripts/test-build-app-symlink.sh` | PASS | symlink dist、symlink／非普通 ZIP／DMG 目标均拒绝，ZIP／DMG 两端 sentinel 对称保持 |
| `Scripts/build-app.sh` | PASS | ZIP／DMG 在同一事务中发布 |

生产交互修复引入 `WeekStreamCenteringCoordinator`，把启动居中、Today 重复点击、延迟 frame/viewport 确认与滚动解锁统一为同一状态机；mutation gate 已证明连续 Today 集成测试会杀死绕过真实编排的实现。fresh Sol ultra scoped re-review 独立重跑 32/32 定点测试、311/24 全量测试、Debug/Release 与 diff-check，结果为零 finding。

### 续接增量（Grok session，2026-08-04）

Codex session `019fc266-2e5d-7871-8701-266b024535db` 在提交 `93c8d8f` 后留下未提交工作树：事件系列 `thisAndFuture` 调整时，若未来实例已被单独改成待办并完成，完成态应迁移；自然生成的日程完成态仍应丢弃。修复见 `Sources/CalendarDomain/SeriesMutationEngine.swift` 与 `eventSeriesFutureLeadingResizeKeepsModifiedTaskCompletionAndDropsNaturalEventCompletion`。

| 门禁 | 续接结果 |
| --- | --- |
| `Scripts/test.sh` | PASS，312/24 |
| `Scripts/test-build-app-archive.sh` | PASS |
| `Scripts/test-build-app-failures.sh` | PASS |
| `Scripts/test-build-app-symlink.sh` | PASS |
| ZIP／DMG 解包或挂载后 `codesign --verify --deep --strict` | PASS，CDHash 一致，可执行字节一致 |
| 九项原生 GUI | 未对 `0215f65` 二进制重跑；领域回归已覆盖本 finding |

## 最终交付物

| 制品 | 绝对路径 | SHA-256 |
| --- | --- | --- |
| 权威 ZIP | `/Users/oreal/Documents/个人管理工具/.worktrees/calendar-v1/dist/个人月历.app.zip` | `6dd8e2d0e00964381e9cab48d26f568edc14772db51cd8c61113e8e569e519cd` |
| Finder 友好 DMG | `/Users/oreal/Documents/个人管理工具/.worktrees/calendar-v1/dist/个人月历.dmg` | `b5f02b7c1aa7430b4596662163dde395f3f0c159b44a3101793fbed240b86903` |

- ZIP 新鲜解包 app CDHash：`f0756cb061eafcabbec62b5b1b0afebdc63e1b3b`
- DMG 只读挂载 app CDHash：`f0756cb061eafcabbec62b5b1b0afebdc63e1b3b`
- 可执行文件 SHA-256：`86e2c08f7ecbacf3aa82232509f56f0f3e818fd4bcc3da2fc49d878fe04c5cd2`
- DMG 包含 `Applications -> /Applications`；ZIP 与 DMG app 均通过 `plutil -lint`、真实 `CFBundleExecutable` 普通文件／可执行检查和 `codesign --verify --deep --strict`。
- 续接验证挂载使用临时 `disk6`／`disk7`，已精确卸载。

## 原生打包应用验收

| # | 场景 | 结果与证据 | 状态 |
| --- | --- | --- | --- |
| 1 | 四角日期创建卡跟随与翻边 | [左上](evidence/final-quick-create-top-left.jpeg)、[右上](evidence/final-quick-create-top-right.jpeg)、[左下](evidence/final-quick-create-bottom-left.jpeg)、[右下](evidence/final-quick-create-bottom-right.jpeg)；卡片就近锚定且标题自动聚焦 | PASS |
| 2 | 正／反向跨月拖选 | [正向](evidence/final-range-forward-cross-month.jpeg)、[反向](evidence/final-range-reverse-cross-month.jpeg) 都归一化为 `2026-07-31 → 2026-08-04`，松手卡片跟随释放端 | PASS |
| 3 | 跨月连续滚动与 Today 状态机 | 向未来超过 52 周到 [2027 年 9 月](evidence/final-scroll-future-52-weeks.jpeg)，向过去超过 52 周到 [2023 年 8 月](evidence/final-scroll-past-52-weeks.jpeg)；[重复 Today 后仍可手动滚动](evidence/final-repeated-today-scroll-unlocked.jpeg) | PASS |
| 4 | 单日高密度 | [10 条直接显示并出现“还有1项”](evidence/final-density-10-plus-overflow.jpeg)；[抽屉列出 11 个唯一来源](evidence/final-density-drawer-11-items.jpeg)，跨日来源只出现一次 | PASS |
| 5 | 普通跨日移动、两端缩放、完成与撤销 | [主体移动](evidence/final-multi-day-body-moved.jpeg) 保持 5 天跨度；[尾端缩放](evidence/final-multi-day-trailing-resized.jpeg) 只改结束；[首端缩放](evidence/final-multi-day-leading-resized.jpeg) 只改开始；每次 Command-Z 恢复；[跨周整体完成](evidence/final-multi-day-completed.jpeg) 两段同步 | PASS |
| 6 | 重复跨日范围与保存恢复 | [范围提示](evidence/final-recurring-scope-prompt.jpeg) 含“仅本次／本次及以后／取消”；取消前后哈希同为 `bfc214…6320`；[仅本次](evidence/final-recurring-only-this.jpeg) 只把首例改为 8/4–8/6；[本次及以后](evidence/final-recurring-this-and-future.jpeg) 从下一例起改为周二 3 天；[失败提示](evidence/final-save-failure-alert.jpeg) 时 primary 哈希保持 `edad5b…b05`，[修复权限重试](evidence/final-save-retry-success.jpeg) 后仅有一条事项 | PASS |
| 7 | 彻底退出与重启持久化 | [重启后](evidence/final-restart-persisted-completed.jpeg) `7/31–8/4` 范围及跨周完成状态保持，启动仍居中今天 | PASS |
| 8 | V1 恢复与无效备份拒绝 | [V1 完整图迁移](evidence/final-v1-restore-migrated.jpeg) 保留 item、series、2 exceptions、completion；[语义无效备份被拒绝](evidence/final-invalid-restore-rejected.jpeg)，恢复前后哈希同为 `28c1983080936e78205f15d1165954fc2e75fa5c40b298b88afee6744abd1c5f` | PASS |
| 9 | 主题、色板、自定义色、减少动态、VoiceOver/AX | 深色 [五组色系入口](evidence/final-category-palettes-dark.jpeg)，[马卡龙 8 色](evidence/final-category-palette-macaron.jpeg)，自定义 [黑](evidence/final-custom-color-black.jpeg)／[白](evidence/final-custom-color-white.jpeg) 都显示浅深对比度；[暖色浅色主题](evidence/final-theme-light.jpeg)；系统实际[开启减少动态](evidence/final-reduce-motion-enabled.jpeg) 后[远距回到今天](evidence/final-reduce-motion-today-centered.jpeg)；系统实际[开启 VoiceOver](evidence/final-voiceover-enabled.jpeg)，跨周条带 AX 完整读出范围及[前后周延续语义](evidence/final-voiceover-cross-week-ax.jpeg) | PASS |

## 失败证据与修复闭环

- 修复前打包应用重启落在错误位置，保留证据 [restart-wrong-initial-position.jpeg](evidence/restart-wrong-initial-position.jpeg)；修复后 [final-startup-centered.jpeg](evidence/final-startup-centered.jpeg) 与重复 Today 用例均通过。
- 修复前空白跨日拖选未进入范围创建；该 finding 促成范围手势命中区域与事项手势优先级修复，最终正／反向跨月证据均通过。
- 保存失败用例不是只测错误弹窗：只读目录下失败时旧 primary 字节不变；权限恢复后原卡片、标题与保存动作仍在，重试后落盘仅一条同名事项。
- 首次最终整体审查曾给出打包门禁 `0 Critical / 3 Important / 1 Minor`，没有被覆盖为成功；修复提交 `eb67d06` 通过了错误 device、candidate contains 匹配与 DMG 拒绝前破坏 ZIP 的定向 mutation，并经 scoped Sol 复审降为 `0 / 0 / 0`。
- Session 总审末尾 Important：事件系列未来实例改待办并完成后，`thisAndFuture` 首端缩放会丢完成态；`0215f65` 去掉「仅 future.kind == task 才迁移完成态」的错误门槛，并按 exception／系列 kind 判定可完成实例。

详细逐项操作边界见 [V2 原生视觉与交互清单](visual-checklist.md)。

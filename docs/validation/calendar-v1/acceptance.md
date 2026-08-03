# 个人月历 V1 验收记录

验收日期：2026-08-03

权威交付物：`dist/个人月历.app.zip`。`dist/个人月历.app` 只是尽力发布的本机启动副本；该工作目录位于 Documents 时，FileProvider 扩展属性可能污染裸 App，故不得把它写成权威交付物或权威签名包。
证据原则：自动化测试只证明其覆盖的语义；涉及真实窗口、交互、外观、重启或文件面板的条目，必须以从权威 ZIP 解出的 App 的实际操作和对应 PNG/命令证据确认，不能由源码检查替代。

## 最终交付指纹

- 构建来源提交：`c573369`（拖拽自定义类型声明修复）
- 交付物证据批次：`20260803-c573369-drag-uti`
- `dist/个人月历.app.zip` SHA-256：`f4084fc79383ff7ad3fb35c071e5001cc77905d2fe1234b14da6acc72df61837`
- 从该 ZIP 解出的 `个人月历.app` CDHash：`787e7fd7d736945e8dee18d68286bb9162f99caf`
- `dark-980x680.png` SHA-256：`b4ae004a49d137206fd0bbb4a6e37f31e8f8b63788cc1ea26b45a2c32552b9a5`
- `light-980x680.png` SHA-256：`03584c6bc18579a877aba0f7cd8e5a64af4f9f135c5c0c6fd704a5d8f91392a0`
- 严格校验：ZIP 新鲜解包后 `plutil -lint`、`codesign --verify --deep --strict` 通过，且无 `com.apple.FinderInfo` / `com.apple.fileprovider` 扩展属性；产物内 `UTExportedTypeDeclarations` 精确声明 `com.oreal.personalcalendar.item`，描述为“个人月历事项”，并符合 `public.json`。
- 视觉截图沿用 `e4b9fb7` 的最终视觉批次；本次提交只修改 bundle 类型声明和打包回归脚本，没有修改 SwiftUI、主题、布局或业务状态。截图继续作为未受影响的视觉基线，不作为本次拖拽手势通过证据。

| # | 场景 | Expected | Automated evidence | Manual evidence | Result |
| --- | --- | --- | --- | --- | --- |
| 1 | 分类创建、颜色和排序 | 可创建“工作”“生活”等不同颜色分类并调整顺序；分类名称和颜色始终共同呈现 | `CategoryManagerViewModelTests.emptyAndDuplicateNamesAreRejectedCaseInsensitively`、`colorHexAcceptsOnlyASCIIHashRRGGBBAndNormalizesUppercase`、`defaultPaletteUsesTheSameReadabilityValidation`、`CategoryReorderMoveTests` | 已真实创建多分类、改色并打开独立管理窗口；`category-manager-previews.png` 显示浅/深预览。`sky.drag` 未触发，因此使用低噪声可访问备用入口：初始未选中时上下均禁用；选末位“健康”后上移启用/下移禁用；点击上移使顺序从“未分类/工作/生活/健康”变为“未分类/工作/健康/生活”，选中保持；分类窗口 Command-Z 原子恢复原顺序并重新禁用下移 | 通过（拖动手势未确认，但真实备用入口完成排序合同） |
| 2 | 无时间任务与定时日程 | 同一月格能分别创建无时间任务和带同日起止时间的日程；任务有完成框，日程无完成框 | `ItemEditorViewModelTests.untimedDraftCreatesItemWithNoTimeRange`、`CalendarReducerTests.projectionSortsUntimedBeforeTimed` | 最终 fixture 与四张基础图均有无时间待办和 `09:00–10:00` 日程 | 通过 |
| 3 | 任务完成/取消，日程无完成状态 | 任务可完成后再取消；日程没有可点击的完成框且不能完成 | `CalendarReducerTests.completingEventThrows`、`ItemEditorViewModelTests.completingAndUncompletingRecurringTaskAreEachUndoable`、`ItemEditorViewModelTests.completionClickDoesNotOpenDetail` | 真实点击“完成月历验收”：完成→取消→再完成；相邻“产品同步会”没有 checkbox。后续恢复回未完成，最终图仍有 8/12 重复任务完成态 | 通过 |
| 4 | 每周首次实例与含结束日 | 起始日不在所选星期时首项落在之后首个匹配日；结束日当天包含、次日不再生成 | `RecurrenceEngineTests.firstOccurrenceIsFirstSelectedWeekdayOnOrAfterStart`、`inclusiveEndDateProducesOccurrence`、`ItemEditorViewModelTests.recurrenceNeedsAtLeastOneInstanceBeforeInclusiveEnd` | 真实创建 8/7 起、每周一、8/17 止的“边界重复验收”；界面仅出现 8/10、8/17，8/7、8/24 均无 | 通过 |
| 5 | 重复任务独立完成 | 完成本周实例不影响下一次实例；重复日程没有完成状态 | `RecurrenceEngineTests.completingOneTaskOccurrenceDoesNotCompleteNext`、`RecurrenceEngineTests.eventDoesNotExposeCompletion` | 真实完成 8/12 重复实例；8/19 及以后实例仍未完成 | 通过 |
| 6 | 仅本次编辑/移动 | 仅本次生成稳定身份例外，移动后原日期不重复生成，其他周期不变 | `SeriesMutationEngineTests.onlyThisMoveCreatesOneModifiedException`、`RecurrenceEngineTests.movedExceptionSuppressesOriginalAndKeepsStableKey` | 8/19“每周复盘”选择仅本次，改名并移动至 8/20“单次复盘验收”；8/19 消失，8/20 出现，8/12、8/26、9/2 保持 | 通过 |
| 7 | 本次及以后编辑与例外迁移 | 历史实例、例外与完成保持；未来采用新规则，未来单次例外按合同迁移 | `SeriesMutationEngineTests.splittingPreservesPastAndMigratesFutureExceptions`、`RecurrenceEngineTests.explicitExceptionSurvivesNonMatchingWeekdayAfterSplit` | 从 8/12 选本次及以后改为“未来复盘验收”；8/12 完成态保留，8/20 单次例外保留，8/26、9/2 用新标题 | 通过 |
| 8 | 周一/周三拖至周二后的整段平移与撤销 | 选择“本次及以后”后未来从周一/周三变周二/周四；撤销原子恢复系列、例外和完成记录 | `SeriesMutationEngineTests.thisAndFutureMoveShiftsMondayWednesdayToTuesdayThursday`、`futureMoveShiftsExplicitStateAndEmbeddedCompletionKey`、`CalendarDropCoordinatorTests.recurringDropWaitsForScopeAndShiftsFuturePattern`；archive 回归从最终 ZIP 解包的 plist 校验拖拽 UTI 声明 | 原生范围 dialog 的三个选项真实出现且有图。受控诊断确认修复前源 payload 已生成但日期格不进入 targeted；只补 bundle UTI 声明后，日期格立即高亮并显示“移到 8月4日”。最终包的 CUA 坐标注入本轮报 `noWindowsAvailable`，未能替代真实鼠标完成松手、范围选择、整段平移与撤销 | 部分通过：目标识别根因已修；完整真实拖拽仍待用户鼠标确认 |
| 9 | 重复事项删除范围与撤销 | 单次删除只跳过该实例；本次及以后删除保留过去历史；两者均可撤销 | `SeriesMutationEngineTests.onlyThisDeleteCreatesOneSkippedException`、`thisAndFutureDeleteEndsOldSeriesAndRemovesFutureState`、`ItemEditorViewModelTests.deletingOccurrenceUsesChosenScope` | 对“边界重复验收”真实仅本次删除：8/10 消失、8/17 保留，Command-Z 恢复；本次及以后删除：8/10、8/17 均消失，Command-Z 恢复 | 通过 |
| 10 | 普通事项拖动和撤销 | 普通事项改期，定时时间/时长保持，Command-Z 恢复原日期 | `CalendarReducerTests.movingTimedItemPreservesTimeRange`、`CalendarDropCoordinatorTests.oneOffDropPreservesTimeAndRegistersOneUndo`；archive 回归校验实际产物 UTI | 修复前“产品同步会”拖拽源已启动，但日期格因 bundle 未注册自定义类型而拒绝；加入声明后同一共享 drop target 已能进入 targeted 并显示目的日期。最终完成移动与 Command-Z 仍需真实鼠标确认 | 部分通过：阻断拖拽的类型注册缺失已修；完整手势与撤销待用户确认 |
| 11 | 日期格三热区 | 日期数字/溢出打开当天抽屉；空白区打开快速创建；已有事项打开详情，入口不冲突 | `ItemEditorViewModelTests.overflowAndDateNumberOpenDayWhileBlankCreates`、`DayCellInteractionTests.emptyCellSurfaceUsesQuickCreateWithoutStealingControls` | 日期数字打开 8/3 抽屉、事项打开详情；空白 8/7、8/8 打开快速创建且标题立即聚焦。图展示浮层、文本和焦点环/插入位置 | 通过 |
| 12 | 溢出、筛选重计与当天抽屉 | 内容超容量显示“还有 N 项”；隐藏分类后 N 重新计算；抽屉显示完整列表 | `MonthViewModelTests.monthViewModelOrdersUntimedBeforeTimedAndComputesOverflow`、`hiddenCategoriesAreExcludedFromFreshProjectionAndOverflow`、`CalendarReducerTests.hiddenCategoriesDoNotCountTowardOverflow` | 980 窗口 8/3 显示“还有 3 项”；隐藏工作后剩健康/生活两条且溢出消失，恢复后“还有 3 项”返回；抽屉显示 4 项 | 通过 |
| 13 | 在用分类删除迁移与撤销 | 删除在用分类要求明确迁移或未分类；无悬空引用；撤销原子恢复分类和全部引用 | `CalendarReducerTests.deletingCategoryMigratesEveryReferenceAtomically`、`CategoryManagerViewModelTests.deleteRequiresExplicitMigrationChoice`、`deleteToUncategorizedAtomicallyMigratesAllReferencesAndUndoRestoresEverything` | 真实删除在用“生活”并迁移至未分类，分类消失；分类窗口 Command-Z 后“生活”及主月历两条引用恢复，无悬空 | 通过 |
| 14 | 时间合法性 | 时间只能全空或全有；结束不晚于开始时就地提示、不能保存且草稿不丢失 | `CoreModelTests.partialTimeRangeJSONFailsDecode`、`CoreModelTests.timeRangeRejectsEqualEndpoints`、`ItemEditorViewModelTests.editorRejectsReversedTimeWithoutClearingDraft` | 新建日程输入 `10:00→09:00`，保存后原地显示“结束时间必须晚于开始时间”；popover 与两时间值完整保留，未写入 | 通过 |
| 15 | 月份导航/今天/选中日 | 上月、下月、今天正确改变月份；今天和选中日期有清晰标识 | `MonthGridBuilderTests.august2026ProducesMondayFirstFortyTwoCellGrid`、`MonthViewModelTests.monthNavigationAndTodaySelectionUseCivilMonthArithmetic` | 真实上月到 2026 年 7 月、下月回 8 月、今天回当前月 | 通过 |
| 16 | 关闭重启后持久化 | 分类、事项、重复例外与完成状态在进程重启后仍完整 | `JSONCalendarRepositoryTests.saveThenReopenRoundTripsState`、`completeGraphRoundTripsExactly` | 多次 quit/relaunch；有效恢复后再次重启，4 分类/7 事项/2 系列、8/12 完成、8/20 单次例外均完整 | 通过 |
| 17 | 导出、无效恢复和有效 rollback 恢复 | 导出本应用备份；无效文件零覆盖；有效恢复前保存原始 rollback（含无法读取 primary 时的原始字节），恢复后完整替换并清 undo | `JSONCalendarRepositoryTests.invalidBackupNeverOverwritesCurrentState`、`decodableDanglingCategoryBackupIsRejected`、`validRestoreWritesRollbackBeforeReplacement`、`corruptPrimarySnapshotPreservesRawBytes`；`CalendarStoreTests.invalidSemanticRestoreKeepsMemoryDiskAndRollbackUntouched`、`successfulRestorePublishesOnceAndClearsUndo`、`corruptPrimaryCanRestoreValidBackup` | File 菜单真实导出 `/private/tmp/calendar-v1-manual-backup.json`；ready-state 修改后恢复，确认显示 `分类 4 个，事项 7 项，重复系列 2 个 → 4/7/2`、完整替换说明和精确 Rollbacks 路径；恢复后任务回到未完成且 stale undo 清空，成功 alert 给出 rollback。语义无效 JSON 报“当前数据未修改”，primary SHA-256 前后同为 `674f43d245fb8f3f017ce16cf5306b1acefede591ed6695dcd84cf61d53d8a19`。另真实覆盖 loadFailed：安全保存 primary 后以 16 字节 `{not-valid-json\\n` 损坏，启动 alert 显示“无法读取本地日历。请检查备份后再尝试恢复。”；导出禁用、恢复启用。选择有效备份后确认精确显示“当前数据无法读取 → 分类4/事项7/系列2”、完整替换和原始字节保留；rollback 与损坏 primary 逐字节相同（SHA-256 均为 `a8cc9214dcbbe1dfaa07fb707820a6585f169a2f31116e2943ffdfc4a10bf6c7`），恢复后的 primary 与有效备份逐字节相同（SHA-256 均为 `674f43d245fb8f3f017ce16cf5306b1acefede591ed6695dcd84cf61d53d8a19`） | 通过 |
| 18 | 浅色/深色可读性与月格密度 | 浅深外观下分类色+文字均可读；任务/日程可辨；完成任务降权但可读；最小尺寸无裁切，六周月和“还有 N 项”可扫读 | `CategoryManagerViewModelTests.readabilityForCustomColorMatchesRenderedTheme`、`completedTaskAccentUsesRenderedOpacityWhenDecidingItsOutline`、`MonthViewModelTests.itemCapacityPreservesOneOverflowRow`、`CalendarItemRowPresentationTests.compactTimedRowKeepsFullStartTimeReadableCategoryAndTitle`、`compactTimedRowUsesReadableCategoryPrefixInsteadOfMeaninglessEllipsis`、`compactTimedLayoutUsesReducedTypographyWhileStandardKeepsOriginalSize`、`narrowUntimedRowAlsoKeepsReadableCategoryPrefixAndTitle` | 主控从指纹对应的权威 ZIP 解出 App 后，以真实 CUA 在同一 fixture 重采浅/深 980 图。两种外观下，紧凑行显示分类色条与单字符分类 `工/生/健/未`，定时行完整显示 `09:00` 和标题“产品同步会”，8 月 3 日显示“还有 2 项”；六周、多分类色、完成态和月格均无裁切。可访问树仍报告完整“工作, 09:00, 产品同步会”以及“生活”“健康”“未分类”，没有把视觉缩写泄漏给辅助功能。截图实际为 980×768（含标题栏；内容高度不低于 680），系统外观最终恢复深色。 | 通过 |

## 截图清单与检查点

| 文件 | 要求 | 状态 |
| --- | --- | --- |
| `light-1180x820.png` | 打包 App 浅色、1180×820、六周月份、无时间任务、定时日程、完成任务、多分类色及“还有 N 项” | 已采集并目检：最终浅色 fixture、实际像素 1180×712；CUA 虚拟显示限制，内容最小高 680，非 820px 总高 |
| `dark-1180x820.png` | 同一真实 fixture 的深色、1180×820 | 已采集并目检：最终深色 fixture、实际像素 1180×712；同受 CUA 虚拟显示限制 |
| `light-980x680.png` | 从指纹对应的权威 ZIP 解出的 App：浅色最小窗口、同一完整 fixture、无裁切 | 已重采并目检：实际 980×768；分类色和 `工/生/健/未`、完整 `09:00`、完整“产品同步会”、“还有 2 项”及六周月格均可读 |
| `dark-980x680.png` | 从指纹对应的权威 ZIP 解出的 App：深色最小窗口、同一完整 fixture、无裁切 | 已重采并目检：实际 980×768；与浅色使用同一 fixture，分类语义、完整时间和标题、“还有 2 项”均未丢失 |
| `quick-create-focus-light.png` | 浅色日期格旁快速创建浮层，标题插入点/焦点明显 | 已采集并目检：实际像素 1180×712；快速创建浮层、标题文本和蓝色焦点框可见 |
| `day-drawer-980x680.png` | 最小窗口拥挤日期的“还有 N 项”与完整当天抽屉 | 已采集并目检：实际像素 980×712；月格“还有 3 项”和右侧当天完整抽屉可见 |
| `category-manager-previews.png` | 独立分类管理窗口，同时显示浅/深色预览和对比值 | 已采集并目检：实际像素 900×552；浅/深预览同时显示，对比值为 14.38:1 与 13.12:1 |
| `recurring-scope-dialog.png` | 月格上方的“仅本次 / 本次及以后 / 取消”确认 | 已采集并目检：实际像素 3024×1964；三个范围选项清晰可见 |

最终结论：18 条场景中，16 条已完成自动化与真实手动路径并通过。用户报告的“完全拖不动”已定位为 bundle 未声明自定义拖拽 UTI；修复后受控诊断已确认日期格能够识别 payload 并进入 targeted，最终 ZIP 也包含并自动回归该声明。#8、#10 仍只记为“部分通过”，因为本轮 CUA 坐标注入失败，未替代用户真实鼠标完成松手后的移动、范围选择与撤销；收到用户确认前不写成 18/18。#18 的视觉基线未受本次纯 metadata/回归脚本修复影响。#1 的排序需求已由真实可访问备用入口与 Command-Z 完成。

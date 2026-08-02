# 个人月历 V1 验收记录

验收日期：2026-08-03

打包目标：`dist/个人月历.app`
证据原则：自动化测试只证明其覆盖的语义；涉及真实窗口、交互、外观、重启或文件面板的条目，必须以打包 App 的实际操作和对应 PNG/命令证据确认，不能由源码检查替代。

| # | 场景 | Expected | Automated evidence | Manual evidence | Result |
| --- | --- | --- | --- | --- | --- |
| 1 | 分类创建、颜色和排序 | 可创建“工作”“生活”等不同颜色分类并调整顺序；分类名称和颜色始终共同呈现 | `CategoryManagerViewModelTests.emptyAndDuplicateNamesAreRejectedCaseInsensitively`、`colorHexAcceptsOnlyASCIIHashRRGGBBAndNormalizesUppercase`、`defaultPaletteUsesTheSameReadabilityValidation`、`CategoryReorderMoveTests` | 已真实创建多分类、改色并打开独立管理窗口；`category-manager-previews.png` 显示浅/深预览。`sky.drag` 未触发，因此使用低噪声可访问备用入口：初始未选中时上下均禁用；选末位“健康”后上移启用/下移禁用；点击上移使顺序从“未分类/工作/生活/健康”变为“未分类/工作/健康/生活”，选中保持；分类窗口 Command-Z 原子恢复原顺序并重新禁用下移 | 通过（拖动手势未确认，但真实备用入口完成排序合同） |
| 2 | 无时间任务与定时日程 | 同一月格能分别创建无时间任务和带同日起止时间的日程；任务有完成框，日程无完成框 | `ItemEditorViewModelTests.untimedDraftCreatesItemWithNoTimeRange`、`CalendarReducerTests.projectionSortsUntimedBeforeTimed` | 最终 fixture 与四张基础图均有无时间待办和 `09:00–10:00` 日程 | 通过 |
| 3 | 任务完成/取消，日程无完成状态 | 任务可完成后再取消；日程没有可点击的完成框且不能完成 | `CalendarReducerTests.completingEventThrows`、`ItemEditorViewModelTests.completingAndUncompletingRecurringTaskAreEachUndoable`、`ItemEditorViewModelTests.completionClickDoesNotOpenDetail` | 真实点击“完成月历验收”：完成→取消→再完成；相邻“产品同步会”没有 checkbox。后续恢复回未完成，最终图仍有 8/12 重复任务完成态 | 通过 |
| 4 | 每周首次实例与含结束日 | 起始日不在所选星期时首项落在之后首个匹配日；结束日当天包含、次日不再生成 | `RecurrenceEngineTests.firstOccurrenceIsFirstSelectedWeekdayOnOrAfterStart`、`inclusiveEndDateProducesOccurrence`、`ItemEditorViewModelTests.recurrenceNeedsAtLeastOneInstanceBeforeInclusiveEnd` | 真实创建 8/7 起、每周一、8/17 止的“边界重复验收”；界面仅出现 8/10、8/17，8/7、8/24 均无 | 通过 |
| 5 | 重复任务独立完成 | 完成本周实例不影响下一次实例；重复日程没有完成状态 | `RecurrenceEngineTests.completingOneTaskOccurrenceDoesNotCompleteNext`、`RecurrenceEngineTests.eventDoesNotExposeCompletion` | 真实完成 8/12 重复实例；8/19 及以后实例仍未完成 | 通过 |
| 6 | 仅本次编辑/移动 | 仅本次生成稳定身份例外，移动后原日期不重复生成，其他周期不变 | `SeriesMutationEngineTests.onlyThisMoveCreatesOneModifiedException`、`RecurrenceEngineTests.movedExceptionSuppressesOriginalAndKeepsStableKey` | 8/19“每周复盘”选择仅本次，改名并移动至 8/20“单次复盘验收”；8/19 消失，8/20 出现，8/12、8/26、9/2 保持 | 通过 |
| 7 | 本次及以后编辑与例外迁移 | 历史实例、例外与完成保持；未来采用新规则，未来单次例外按合同迁移 | `SeriesMutationEngineTests.splittingPreservesPastAndMigratesFutureExceptions`、`RecurrenceEngineTests.explicitExceptionSurvivesNonMatchingWeekdayAfterSplit` | 从 8/12 选本次及以后改为“未来复盘验收”；8/12 完成态保留，8/20 单次例外保留，8/26、9/2 用新标题 | 通过 |
| 8 | 周一/周三拖至周二后的整段平移与撤销 | 选择“本次及以后”后未来从周一/周三变周二/周四；撤销原子恢复系列、例外和完成记录 | `SeriesMutationEngineTests.thisAndFutureMoveShiftsMondayWednesdayToTuesdayThursday`、`futureMoveShiftsExplicitStateAndEmbeddedCompletionKey`、`CalendarDropCoordinatorTests.recurringDropWaitsForScopeAndShiftsFuturePattern` | 原生范围 dialog 的三个选项真实出现且有图；`sky.drag` 对月格 row 未触发，未能实测周一/周三→周二/周四与撤销 | 部分通过：自动化与范围 UI 通过；真实拖拽未确认 |
| 9 | 重复事项删除范围与撤销 | 单次删除只跳过该实例；本次及以后删除保留过去历史；两者均可撤销 | `SeriesMutationEngineTests.onlyThisDeleteCreatesOneSkippedException`、`thisAndFutureDeleteEndsOldSeriesAndRemovesFutureState`、`ItemEditorViewModelTests.deletingOccurrenceUsesChosenScope` | 对“边界重复验收”真实仅本次删除：8/10 消失、8/17 保留，Command-Z 恢复；本次及以后删除：8/10、8/17 均消失，Command-Z 恢复 | 通过 |
| 10 | 普通事项拖动和撤销 | 普通事项改期，定时时间/时长保持，Command-Z 恢复原日期 | `CalendarReducerTests.movingTimedItemPreservesTimeRange`、`CalendarDropCoordinatorTests.oneOffDropPreservesTimeAndRegistersOneUndo` | 对“产品同步会”真实 `sky.drag` 未触发，未能完成手势路径 | 部分通过：自动化通过；真实拖拽手势未确认 |
| 11 | 日期格三热区 | 日期数字/溢出打开当天抽屉；空白区打开快速创建；已有事项打开详情，入口不冲突 | `ItemEditorViewModelTests.overflowAndDateNumberOpenDayWhileBlankCreates`、`DayCellInteractionTests.emptyCellSurfaceUsesQuickCreateWithoutStealingControls` | 日期数字打开 8/3 抽屉、事项打开详情；空白 8/7、8/8 打开快速创建且标题立即聚焦。图展示浮层、文本和焦点环/插入位置 | 通过 |
| 12 | 溢出、筛选重计与当天抽屉 | 内容超容量显示“还有 N 项”；隐藏分类后 N 重新计算；抽屉显示完整列表 | `MonthViewModelTests.monthViewModelOrdersUntimedBeforeTimedAndComputesOverflow`、`hiddenCategoriesAreExcludedFromFreshProjectionAndOverflow`、`CalendarReducerTests.hiddenCategoriesDoNotCountTowardOverflow` | 980 窗口 8/3 显示“还有 3 项”；隐藏工作后剩健康/生活两条且溢出消失，恢复后“还有 3 项”返回；抽屉显示 4 项 | 通过 |
| 13 | 在用分类删除迁移与撤销 | 删除在用分类要求明确迁移或未分类；无悬空引用；撤销原子恢复分类和全部引用 | `CalendarReducerTests.deletingCategoryMigratesEveryReferenceAtomically`、`CategoryManagerViewModelTests.deleteRequiresExplicitMigrationChoice`、`deleteToUncategorizedAtomicallyMigratesAllReferencesAndUndoRestoresEverything` | 真实删除在用“生活”并迁移至未分类，分类消失；分类窗口 Command-Z 后“生活”及主月历两条引用恢复，无悬空 | 通过 |
| 14 | 时间合法性 | 时间只能全空或全有；结束不晚于开始时就地提示、不能保存且草稿不丢失 | `CoreModelTests.partialTimeRangeJSONFailsDecode`、`CoreModelTests.timeRangeRejectsEqualEndpoints`、`ItemEditorViewModelTests.editorRejectsReversedTimeWithoutClearingDraft` | 新建日程输入 `10:00→09:00`，保存后原地显示“结束时间必须晚于开始时间”；popover 与两时间值完整保留，未写入 | 通过 |
| 15 | 月份导航/今天/选中日 | 上月、下月、今天正确改变月份；今天和选中日期有清晰标识 | `MonthGridBuilderTests.august2026ProducesMondayFirstFortyTwoCellGrid`、`MonthViewModelTests.monthNavigationAndTodaySelectionUseCivilMonthArithmetic` | 真实上月到 2026 年 7 月、下月回 8 月、今天回当前月 | 通过 |
| 16 | 关闭重启后持久化 | 分类、事项、重复例外与完成状态在进程重启后仍完整 | `JSONCalendarRepositoryTests.saveThenReopenRoundTripsState`、`completeGraphRoundTripsExactly` | 多次 quit/relaunch；有效恢复后再次重启，4 分类/7 事项/2 系列、8/12 完成、8/20 单次例外均完整 | 通过 |
| 17 | 导出、无效恢复和有效 rollback 恢复 | 导出本应用备份；无效文件零覆盖；有效恢复前保存原始 rollback（含无法读取 primary 时的原始字节），恢复后完整替换并清 undo | `JSONCalendarRepositoryTests.invalidBackupNeverOverwritesCurrentState`、`decodableDanglingCategoryBackupIsRejected`、`validRestoreWritesRollbackBeforeReplacement`、`corruptPrimarySnapshotPreservesRawBytes`；`CalendarStoreTests.invalidSemanticRestoreKeepsMemoryDiskAndRollbackUntouched`、`successfulRestorePublishesOnceAndClearsUndo`、`corruptPrimaryCanRestoreValidBackup` | File 菜单真实导出 `/private/tmp/calendar-v1-manual-backup.json`；ready-state 修改后恢复，确认显示 `分类 4 个，事项 7 项，重复系列 2 个 → 4/7/2`、完整替换说明和精确 Rollbacks 路径；恢复后任务回到未完成且 stale undo 清空，成功 alert 给出 rollback。语义无效 JSON 报“当前数据未修改”，primary SHA-256 前后同为 `674f43d245fb8f3f017ce16cf5306b1acefede591ed6695dcd84cf61d53d8a19`。另真实覆盖 loadFailed：安全保存 primary 后以 16 字节 `{not-valid-json\\n` 损坏，启动 alert 显示“无法读取本地日历。请检查备份后再尝试恢复。”；导出禁用、恢复启用。选择有效备份后确认精确显示“当前数据无法读取 → 分类4/事项7/系列2”、完整替换和原始字节保留；rollback 与损坏 primary 逐字节相同（SHA-256 均为 `a8cc9214dcbbe1dfaa07fb707820a6585f169a2f31116e2943ffdfc4a10bf6c7`），恢复后的 primary 与有效备份逐字节相同（SHA-256 均为 `674f43d245fb8f3f017ce16cf5306b1acefede591ed6695dcd84cf61d53d8a19`） | 通过 |
| 18 | 浅色/深色可读性与月格密度 | 浅深外观下分类色+文字均可读；任务/日程可辨；完成任务降权但可读；最小尺寸无裁切，六周月和“还有 N 项”可扫读 | `CategoryManagerViewModelTests.readabilityForCustomColorMatchesRenderedTheme`、`completedTaskAccentUsesRenderedOpacityWhenDecidingItsOutline`、`MonthViewModelTests.itemCapacityPreservesOneOverflowRow`、`CalendarItemRowPresentationTests.compactTimedRowKeepsFullStartTimeAndPrioritizesTitleOverCategory` | 最终同一 fixture 的浅/深、1180 宽/980 宽均真实采集；六周、多色、任务/日程/完成、溢出与完整 `09:00` 均可读。CUA 虚拟显示限制使 1180 图像实际为 1180×712、980 图为 980×712（包含标题栏、内容最小高 680），不是 820px 总高 | 通过（视觉与最小内容高度已验；截图总高度受 CUA 环境限制，未声称 820px 像素图） |

## 截图清单与检查点

| 文件 | 要求 | 状态 |
| --- | --- | --- |
| `light-1180x820.png` | 打包 App 浅色、1180×820、六周月份、无时间任务、定时日程、完成任务、多分类色及“还有 N 项” | 已采集并目检：最终浅色 fixture、实际像素 1180×712；CUA 虚拟显示限制，内容最小高 680，非 820px 总高 |
| `dark-1180x820.png` | 同一真实 fixture 的深色、1180×820 | 已采集并目检：最终深色 fixture、实际像素 1180×712；同受 CUA 虚拟显示限制 |
| `light-980x680.png` | 打包 App 浅色最小窗口、同一完整 fixture、无裁切 | 已采集并目检：最终浅色最小窗口、实际像素 980×712；定时行完整 `09:00` |
| `dark-980x680.png` | 打包 App 深色最小窗口、同一完整 fixture、无裁切 | 已采集并目检：最终深色最小窗口、实际像素 980×712；定时行完整 `09:00` |
| `quick-create-focus-light.png` | 浅色日期格旁快速创建浮层，标题插入点/焦点明显 | 已采集并目检：实际像素 1180×712；快速创建浮层、标题文本和蓝色焦点框可见 |
| `day-drawer-980x680.png` | 最小窗口拥挤日期的“还有 N 项”与完整当天抽屉 | 已采集并目检：实际像素 980×712；月格“还有 3 项”和右侧当天完整抽屉可见 |
| `category-manager-previews.png` | 独立分类管理窗口，同时显示浅/深色预览和对比值 | 已采集并目检：实际像素 900×552；浅/深预览同时显示，对比值为 14.38:1 与 13.12:1 |
| `recurring-scope-dialog.png` | 月格上方的“仅本次 / 本次及以后 / 取消”确认 | 已采集并目检：实际像素 3024×1964；三个范围选项清晰可见 |

最终结论：18 条场景中，16 条已完成自动化与真实手动路径并通过；#8 重复事项整段拖拽、#10 普通事项拖拽的真实 `sky.drag` 手势未触发，故保留为“部分通过/真实手势未确认”，不把它们写成全绿。#1 的排序需求已由真实可访问备用入口与 Command-Z 完成。四张基础截图受 CUA 虚拟显示限制为 712px 总高，已如实记录；这不影响已确认的最小内容高度和可见视觉合同。

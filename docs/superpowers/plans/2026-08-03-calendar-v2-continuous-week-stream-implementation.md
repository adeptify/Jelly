# 个人月历 V2 连续周流 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Calendar V1 升级为跨月连续周流，并完整支持跨日创建、移动、两端缩放、每周重复、锚定编辑器、五组分类色和 C「安静生活感」。

**Architecture:** 先把跨日范围提升为领域模型和 schema 2，再以任意日期范围投影替换固定 42 格投影；视图以完整 `WeekRow` 为布局单元，由统一交互协调器管理空白拖选、条带移动与两端缩放。所有确认操作继续经过单一 `CalendarStore` 事务入口，旧 schema 1 数据显式迁移且读时不覆盖源文件。

**Tech Stack:** Swift 6.3、SwiftUI、Observation/Combine、swift-testing、macOS 14、JSON 本地持久化、zsh 打包门禁。

## Global Constraints

- 只做 macOS 本地月历；不新增清单、提醒、同步、AI、日/周/年视图或新的重复频率。
- 一周从星期一开始；日历始终是跨月跨年的连续周流；全屏常用尺寸约显示三周且每天优先显示 8–10 条。
- 待办与日程都支持首尾包含的日期范围；跨日待办只有一个整体完成状态。
- 每个每周重复星期都是独立实例起点，使用相同跨度，允许实例重叠；重复截止约束最后允许开始日。
- 重复移动与缩放只提供“仅本次 / 本次及以后 / 取消”；一次确认只写入一个领域命令并注册一条撤销。
- schema 1 → schema 2 必须显式迁移；读取旧文件不立即覆盖；未知版本和损坏数据不得覆盖有效主文件。
- 核心月历交互使用应用内统一手势；系统 `Transferable` 只保留兼容用途。
- 视觉采用 C「安静生活感」；分类提供基础、马卡龙、莫兰迪、自然、鲜亮五组各八色并保留自定义色。
- 不新增第三方依赖；保持 `Package.swift` 的 macOS 14 下限。
- 严格 TDD：每个生产行为先写测试并观察正确失败，再写最小实现；不得用源码文本断言替代行为测试。
- 每个任务完成前运行其 focused tests；最终必须运行 `Scripts/test.sh`、打包故障门禁和真实 `.app` 验收。

---

## File Structure

新增文件按责任拆分：

- `Sources/CalendarDomain/TimelineProjection.swift`：任意日期范围事项投影。
- `Sources/CalendarDomain/WeekSegmentLayout.swift`：跨日条带按周切段、lane 与 overflow。
- `Sources/CalendarPersistence/V1CalendarDocument.swift`：只负责 schema 1 DTO 与 V1 → V2 迁移。
- `Sources/CalendarApp/Month/WeekStreamModel.swift`：周窗口、焦点周、月份跳转与扩展锚点。
- `Sources/CalendarApp/Month/WeekRowView.swift`：一周七列背景、日期头、单日事项与跨日 overlay。
- `Sources/CalendarApp/Month/CalendarInteractionCoordinator.swift`：互斥手势状态与 preview。
- `Sources/CalendarApp/Month/AnchoredEditorLayout.swift`：日期 frame map 与编辑卡四向放置。
- `Sources/CalendarApp/Categories/CategoryPalette.swift`：五组预设色及语义颜色解析。

现有 `MonthProjection.swift`、`MonthGridBuilder.swift` 和旧 DnD 协调器在新路径全部接通后删除或收缩为兼容适配；迁移过程中不得让两套业务真相长期并存。

---

### Task 1: 跨日时间范围与普通事项领域合同

**Files:**
- Modify: `Sources/CalendarDomain/CalendarTime.swift`
- Modify: `Sources/CalendarDomain/CalendarModels.swift`
- Modify: `Sources/CalendarDomain/CalendarCommand.swift`
- Modify: `Sources/CalendarDomain/CalendarReducer.swift`
- Test: `Tests/CalendarDomainTests/CoreModelTests.swift`
- Test: `Tests/CalendarDomainTests/CalendarReducerTests.swift`

**Interfaces:**
- Produces: `CalendarSchedule`, `CalendarItem.schedule`, existing `.moveItem(UUID, to: CalendarDate)` with span-preserving semantics.
- Consumes: `CalendarDate`, `MinuteOfDay`, existing Store/reducer transaction path.

- [ ] **Step 1: Write failing schedule tests**

```swift
@Test func crossDayScheduleAllowsOvernightClockTimes() throws {
    let schedule = try CalendarSchedule(
        startDate: date(2026, 8, 6), endDate: date(2026, 8, 7),
        startTime: minute(23, 0), endTime: minute(1, 0)
    )
    #expect(schedule.durationDays == 2)
}

@Test func sameDayScheduleRejectsEqualOrReversedClockTimes() {
    #expect(throws: DomainValidationError.invalidTimeRange) {
        try CalendarSchedule(
            startDate: date(2026, 8, 6), endDate: date(2026, 8, 6),
            startTime: minute(9, 0), endTime: minute(9, 0)
        )
    }
}

@Test func scheduleRejectsReversedDatesAndPartialTimes() {
    #expect(throws: DomainValidationError.invalidDateRange) {
        try CalendarSchedule(
            startDate: date(2026, 8, 7), endDate: date(2026, 8, 6),
            startTime: nil, endTime: nil
        )
    }
    #expect(throws: DomainValidationError.invalidTimeRange) {
        try CalendarSchedule(
            startDate: date(2026, 8, 6), endDate: date(2026, 8, 7),
            startTime: minute(9, 0), endTime: nil
        )
    }
}
```

- [ ] **Step 2: Run RED for the new value type**

Run: `Scripts/test.sh --filter CoreModelTests`

Expected: compile failure because `CalendarSchedule` and `invalidDateRange` do not exist.

- [ ] **Step 3: Implement `CalendarSchedule` and migrate `CalendarItem` in memory**

```swift
public struct CalendarSchedule: Codable, Equatable, Hashable, Sendable {
    public let startDate: CalendarDate
    public let endDate: CalendarDate
    public let startTime: MinuteOfDay?
    public let endTime: MinuteOfDay?

    public var durationDays: Int { startDate.days(until: endDate) + 1 }

    public init(
        startDate: CalendarDate, endDate: CalendarDate,
        startTime: MinuteOfDay?, endTime: MinuteOfDay?
    ) throws {
        guard endDate >= startDate else { throw DomainValidationError.invalidDateRange }
        guard (startTime == nil) == (endTime == nil) else {
            throw DomainValidationError.invalidTimeRange
        }
        if startDate == endDate, let startTime, let endTime, endTime <= startTime {
            throw DomainValidationError.invalidTimeRange
        }
        self.startDate = startDate
        self.endDate = endDate
        self.startTime = startTime
        self.endTime = endTime
    }

    public func shifted(byDays delta: Int) throws -> CalendarSchedule {
        try CalendarSchedule(
            startDate: startDate.addingDays(delta), endDate: endDate.addingDays(delta),
            startTime: startTime, endTime: endTime
        )
    }
}
```

Replace `CalendarItem.date/timeRange` with `schedule`, update validation/Codable, and preserve task/event completion invariants.

- [ ] **Step 4: Add reducer RED tests for moving and completing a span**

```swift
@Test func movingMultiDayItemPreservesInclusiveDurationAndTimes() throws {
    let original = try makeItem(
        schedule: schedule("2026-08-06", "2026-08-08", "23:00", "01:00")
    )
    let result = try reduce(state(containing: original), .moveItem(original.id, to: date(2026, 8, 10)))
    #expect(result.items[original.id]?.schedule == schedule("2026-08-10", "2026-08-12", "23:00", "01:00"))
}

@Test func completingMultiDayTaskUpdatesTheSingleSourceItem() throws {
    let result = try reduce(taskSpanState, .setTaskCompleted(taskID, completedAt))
    #expect(result.items[taskID]?.completedAt == completedAt)
    #expect(result.items.count == 1)
}
```

Run: `Scripts/test.sh --filter CalendarReducerTests`

Expected: FAIL because move still writes a single date or the old fields no longer compile.

- [ ] **Step 5: Implement span-preserving move and run GREEN**

In `.moveItem`, compute `delta = item.schedule.startDate.days(until: destination)` and replace the schedule with `try item.schedule.shifted(byDays: delta)`.

Run: `Scripts/test.sh --filter 'CoreModelTests|CalendarReducerTests'`

Expected: selected suites pass with zero failures.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/CalendarDomain Tests/CalendarDomainTests
git commit -m "feat: 引入跨日事项时间范围"
```

---

### Task 2: 重复实例跨度与移动缩放语义

**Files:**
- Modify: `Sources/CalendarDomain/RecurrenceModels.swift`
- Modify: `Sources/CalendarDomain/RecurrenceEngine.swift`
- Modify: `Sources/CalendarDomain/SeriesMutationEngine.swift`
- Modify: `Sources/CalendarDomain/CalendarReducer.swift`
- Test: `Tests/CalendarDomainTests/RecurrenceEngineTests.swift`
- Test: `Tests/CalendarDomainTests/SeriesMutationEngineTests.swift`
- Test: `Tests/CalendarDomainTests/CalendarReducerTests.swift`

**Interfaces:**
- Consumes: `CalendarSchedule` from Task 1.
- Produces: `WeeklySeries.ruleStartDate/recurrenceEndDate/durationDays/startTime/endTime`, `CalendarOccurrence.schedule`, `OccurrenceOverride.displayedSchedule`, `SeriesPatch.displayedStartDate/durationDays/startTime/endTime`.

- [ ] **Step 1: Write failing recurrence projection tests**

```swift
@Test func eachSelectedWeekdayStartsAnIndependentOverlappingSpan() throws {
    let series = try makeSeries(
        ruleStart: "2026-08-03", weekdays: [.wednesday, .thursday], durationDays: 2
    )
    let occurrences = RecurrenceEngine.occurrences(
        of: series, in: range("2026-08-05", "2026-08-07"), exceptions: [:], completions: [:]
    )
    #expect(occurrences.map(\.schedule) == [
        schedule("2026-08-05", "2026-08-06"),
        schedule("2026-08-06", "2026-08-07")
    ])
}

@Test func recurrenceEndLimitsStartButDoesNotClipFinalSpan() throws {
    let series = try makeSeries(
        ruleStart: "2026-08-03", recurrenceEnd: "2026-08-05",
        weekdays: [.wednesday], durationDays: 3
    )
    #expect(project(series).single.schedule.endDate == date(2026, 8, 7))
}
```

Run: `Scripts/test.sh --filter RecurrenceEngineTests`

Expected: compile failure because series and occurrence span fields do not exist.

- [ ] **Step 2: Implement V2 recurrence model and engine**

Construct each natural occurrence from `originalDate` plus `durationDays - 1`; a modified exception uses its full override schedule. Keep `OccurrenceKey.originalDate` unchanged and derive completion from that key.

```swift
let schedule = try CalendarSchedule(
    startDate: displayedStart,
    endDate: displayedStart.addingDays(durationDays - 1),
    startTime: startTime,
    endTime: endTime
)
```

Query natural starts through `min(range.end, recurrenceEndDate)` and accept an occurrence when its schedule intersects the query range.

- [ ] **Step 3: Write failing series mutation tests**

```swift
@Test func onlyThisLeadingResizeKeepsStableKeyAndChangesWholeSchedule() throws {
    let result = try applyOnlyThis(
        key: key("2026-08-12"),
        patch: .init(displayedStartDate: date(2026, 8, 11), durationDays: 3)
    )
    let override = result.modifiedOverride(for: key("2026-08-12"))
    #expect(override.displayedSchedule.startDate == date(2026, 8, 11))
    #expect(override.displayedSchedule.endDate == date(2026, 8, 13))
}

@Test func futureLeadingResizeShiftsRuleWeekdaysDeadlineExceptionsAndCompletions() throws {
    let result = try applyFuture(
        key: key("2026-08-12"),
        patch: .init(displayedStartDate: date(2026, 8, 11), durationDays: 3)
    )
    #expect(result.futureSeries.ruleStartDate == date(2026, 8, 11))
    #expect(result.futureSeries.weekdays == [.tuesday])
    #expect(result.futureSeries.recurrenceEndDate == date(2026, 9, 29))
    #expect(result.futureCompletionKeys.allSatisfy { $0.originalDate.weekday == .tuesday })
}

@Test func futureTrailingResizeChangesDurationWithoutMovingDeadline() throws {
    let result = try applyFuture(
        key: key("2026-08-12"), patch: .init(durationDays: 4)
    )
    #expect(result.futureSeries.durationDays == 4)
    #expect(result.futureSeries.recurrenceEndDate == originalDeadline)
}
```

Run: `Scripts/test.sh --filter SeriesMutationEngineTests`

Expected: FAIL because span patches are unsupported.

- [ ] **Step 4: Extend `SeriesMutationEngine` with atomic schedule patches**

Use `displayedStartDate` to compute the future day delta. Apply `durationDays/startTime/endTime` to only-this overrides and future series. Shift deadline, future exception schedules, original keys and embedded completion keys only when day delta is non-zero. Right-edge resize has zero day delta.

- [ ] **Step 5: Run recurrence and reducer GREEN**

Run: `Scripts/test.sh --filter 'RecurrenceEngineTests|SeriesMutationEngineTests|CalendarReducerTests'`

Expected: all selected suites pass; no prior moved-boundary regression returns.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/CalendarDomain Tests/CalendarDomainTests
git commit -m "feat: 支持重复事项跨日跨度"
```

---

### Task 3: Schema 2 与显式 V1 迁移

**Files:**
- Create: `Sources/CalendarPersistence/V1CalendarDocument.swift`
- Modify: `Sources/CalendarPersistence/CalendarDocument.swift`
- Modify: `Sources/CalendarPersistence/JSONCalendarRepository.swift`
- Modify: `Sources/CalendarPersistence/BackupService.swift`
- Test: `Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift`

**Interfaces:**
- Consumes: Task 1–2 V2 domain models.
- Produces: `CalendarDocument.currentSchemaVersion == 2`, `V1CalendarDocument.migratedState()`, codec accepting only schema 1 and 2.

- [ ] **Step 1: Add literal V1 fixtures and failing migration tests**

```swift
@Test func schemaOneMigratesSingleDayItemsSeriesOverridesAndCompletionsWithoutChangingIdentity() async throws {
    let originalBytes = Data(v1CompleteGraphJSON.utf8)
    let state = try CalendarDocumentCodec.decode(originalBytes)
    #expect(state.items[itemID]?.schedule == schedule("2026-08-06", "2026-08-06", "09:00", "10:00"))
    #expect(state.recurrence.series[seriesID]?.durationDays == 1)
    #expect(state.recurrence.series[seriesID]?.startTime == minute(9, 30))
    #expect(state.recurrence.series[seriesID]?.endTime == minute(10, 15))
    #expect(state.recurrence.exceptions[movedKey] == .modified(.init(
        displayedSchedule: schedule("2026-08-13", "2026-08-13", "11:00", "12:00"),
        title: "已移动", kind: .task, categoryID: categoryID
    )))
    #expect(state.recurrence.exceptions[skippedKey] == .skipped)
    #expect(state.recurrence.completions[occurrenceKey]?.completedAt == completionDate)
    #expect(originalBytes == Data(v1CompleteGraphJSON.utf8))
}

@Test func loadingSchemaOneDoesNotRewritePrimaryUntilNormalSave() async throws {
    try v1Bytes.write(to: repository.fileURL)
    _ = try await repository.load()
    #expect(try Data(contentsOf: repository.fileURL) == v1Bytes)
    try await repository.save(migratedState)
    #expect(try schemaVersion(at: repository.fileURL) == 2)
}
```

Run: `Scripts/test.sh --filter JSONCalendarRepositoryTests`

Expected: FAIL because schema 1 currently decodes directly into the new model or is rejected.

- [ ] **Step 2: Implement exact schema 1 DTOs and migration**

Define exact `V1CalendarItemDTO`, `V1WeeklySeriesDTO`, `V1OccurrenceOverrideDTO`, `V1OccurrenceExceptionKindDTO`, recurrence graph, state and document DTOs. Mirror the old persisted fields (`date`, `timeRange`, `startDate`, `endDate`, `displayedDate`, content fields and stable keys) exactly. Convert item and series time ranges to V2 start/end clocks with `durationDays = 1`; convert modified overrides to single-day `displayedSchedule`; preserve `.skipped`, completions, IDs and timestamps. Do not reuse V2 `Codable` defaults.

```swift
switch schemaVersion {
case 1:
    return try decoder.decode(V1CalendarDocument.self, from: data).migratedState()
case CalendarDocument.currentSchemaVersion:
    return try decodeAndValidateV2(data)
default:
    throw BackupError.unsupportedSchema(schemaVersion)
}
```

- [ ] **Step 3: Add corruption and rollback RED tests**

```swift
@Test func malformedV1SpanMigrationDoesNotOverwritePrimaryOrRollback() async throws {
    let beforePrimary = try Data(contentsOf: repository.fileURL)
    let beforeRollback = try Data(contentsOf: rollbackURL)
    await #expect(throws: BackupError.invalidDocument) {
        try await service.restore(from: malformedV1URL, repository: repository, rollbackURL: rollbackURL)
    }
    #expect(try Data(contentsOf: repository.fileURL) == beforePrimary)
    #expect(try Data(contentsOf: rollbackURL) == beforeRollback)
}

@Test func rollbackFailureLeavesOriginalPrimaryBytesAndDoesNotPublishMigratedState() async throws {
    let beforePrimary = try Data(contentsOf: repository.fileURL)
    rollbackWriter.failNextWrite = true
    await #expect(throws: BackupError.rollbackWriteFailed) {
        try await service.restore(from: validV1URL, repository: repository, rollbackURL: rollbackURL)
    }
    #expect(try Data(contentsOf: repository.fileURL) == beforePrimary)
    #expect(store.state == stateBeforeRestore)
}
```

Run: `Scripts/test.sh --filter JSONCalendarRepositoryTests`

Expected: FAIL until restore uses migrated validation before any writes.

- [ ] **Step 4: Make restore migration transactional and run GREEN**

Enforce this order: schema envelope → version DTO decode → migrate → full V2 validation → write original current-primary bytes to rollback → atomically write V2 primary → publish memory. Decode/validation/rollback/atomic-write failures must leave primary bytes and published state unchanged.

Run: `Scripts/test.sh --filter JSONCalendarRepositoryTests`

Expected: persistence suite passes, including all V1 fault tests.

- [ ] **Step 5: Run domain + persistence regression**

Run: `Scripts/test.sh --filter 'CalendarDomainTests|CalendarPersistenceTests'`

Expected: all selected tests pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/CalendarPersistence Tests/CalendarPersistenceTests
git commit -m "feat: 无损迁移日历数据到版本二"
```

---

### Task 4: 任意范围投影、周段与 lane/overflow

**Files:**
- Create: `Sources/CalendarDomain/TimelineProjection.swift`
- Create: `Sources/CalendarDomain/WeekSegmentLayout.swift`
- Modify: `Sources/CalendarDomain/MonthProjection.swift`
- Test: `Tests/CalendarDomainTests/TimelineProjectionTests.swift`
- Test: `Tests/CalendarDomainTests/WeekSegmentLayoutTests.swift`

**Interfaces:**
- Consumes: full `CalendarSchedule` for one-off and occurrence sources.
- Produces: `ProjectedEntry`, `ProjectedEntryID`, `TimelineProjection.make(in:state:hiddenCategoryIDs:)`, `WeekSegment`, `WeekLayout`.

- [ ] **Step 1: Write failing intersection projection tests**

```swift
@Test func itemStartingBeforeViewportButEndingInsideIsProjectedOnce() throws {
    let projection = TimelineProjection.make(
        in: range("2026-08-10", "2026-08-16"),
        state: state(item: span("2026-08-08", "2026-08-11")),
        hiddenCategoryIDs: []
    )
    #expect(projection.entries.map(\.schedule) == [schedule("2026-08-08", "2026-08-11")])
}

@Test func extendedRecurringOverrideEnteringViewportIsProjected() throws {
    let projection = TimelineProjection.make(
        in: range("2026-08-10", "2026-08-16"), state: stateWithOverrideEndingOnAugust10,
        hiddenCategoryIDs: []
    )
    #expect(projection.entries.map(\.id) == [.occurrence(overrideKey)])
}

@Test func modifiedExceptionsMovedIntoViewportFromEitherSideSuppressTheirOriginalPosition() throws {
    let projection = TimelineProjection.make(
        in: range("2026-08-10", "2026-08-16"),
        state: stateWithOriginalDatesBeforeAndAfterButDisplayedSchedulesInside,
        hiddenCategoryIDs: []
    )
    #expect(projection.entries.map(\.id) == [
        .occurrence(movedForwardKey), .occurrence(movedBackwardKey)
    ])
    #expect(projection.entries.allSatisfy { range("2026-08-10", "2026-08-16").intersects($0.schedule) })
}

@Test func skippedAndMovedExceptionsAreDeduplicatedByOccurrenceKey() throws {
    let projection = TimelineProjection.make(
        in: range("2026-08-10", "2026-08-16"), state: stateWithSkippedAndMovedKeys,
        hiddenCategoryIDs: []
    )
    #expect(projection.entries.filter { $0.id == .occurrence(movedKey) }.count == 1)
    #expect(!projection.entries.contains { $0.id == .occurrence(skippedKey) })
}
```

Run: `Scripts/test.sh --filter TimelineProjectionTests`

Expected: compile failure because `TimelineProjection` does not exist.

- [ ] **Step 2: Implement identity-preserving range projection**

Project ordinary items by interval intersection. Recurrence candidates are the union of natural starts from the base-duration lookback range and every modified exception whose `displayedSchedule` intersects the visible range, regardless of `originalDate`; deduplicate by `OccurrenceKey`, let modified entries suppress natural positions, and omit `.skipped`. Sort by multi-day first, untimed before timed, then start time, creation time and stable ID.

- [ ] **Step 3: Write failing segment/lane/overflow tests**

```swift
@Test func crossWeekEntryProducesOnlyTrueOuterHandles() throws {
    let layouts = WeekSegmentLayout.make(
        entries: [entry("2026-08-08", "2026-08-12")],
        weekStarts: [date(2026, 8, 3), date(2026, 8, 10)], laneCapacity: 10
    )
    #expect(layouts[0].segments.single.showsLeadingHandle)
    #expect(!layouts[0].segments.single.showsTrailingHandle)
    #expect(!layouts[1].segments.single.showsLeadingHandle)
    #expect(layouts[1].segments.single.showsTrailingHandle)
}

@Test func overflowingMultiDaySegmentIsHiddenAtomicallyAndCountedOnEveryCoveredDate() throws {
    let layout = layoutWithElevenEntries(laneCapacity: 10)
    #expect(layout.visibleSegments.contains(where: { $0.source == overflowingID }) == false)
    #expect(layout.overflowByDate[date(2026, 8, 11)] == 1)
    #expect(layout.overflowByDate[date(2026, 8, 12)] == 1)
}
```

Run: `Scripts/test.sh --filter WeekSegmentLayoutTests`

Expected: compile failure because `WeekSegmentLayout` does not exist.

- [ ] **Step 4: Implement deterministic interval partitioning**

Assign the first lane whose previous segment ends before the candidate start column; reserve a segment’s lane through its end column. Apply capacity to the entire segment and accumulate hidden counts per covered date. Use stable source ID as final tie-breaker.

- [ ] **Step 5: Run projection GREEN and remove old projection as business truth**

Run: `Scripts/test.sh --filter 'TimelineProjectionTests|WeekSegmentLayoutTests|RecurrenceEngineTests'`

Expected: all selected suites pass. Keep `MonthProjection` only as a temporary adapter if existing V1 UI still compiles; it must delegate to `TimelineProjection`.

- [ ] **Step 6: Commit Task 4**

```bash
git add Sources/CalendarDomain Tests/CalendarDomainTests
git commit -m "feat: 按连续周投影跨日条带"
```

---

### Task 5: 编辑草稿支持起止日期时间

**Files:**
- Modify: `Sources/CalendarApp/Editing/ItemDraft.swift`
- Modify: `Sources/CalendarApp/Editing/ItemEditorViewModel.swift`
- Modify: `Sources/CalendarApp/Editing/QuickCreatePopover.swift`
- Modify: `Sources/CalendarApp/Editing/ItemDetailPopover.swift`
- Test: `Tests/CalendarAppTests/ItemEditorViewModelTests.swift`

**Interfaces:**
- Consumes: V2 domain constructors and series patches.
- Produces: `ItemDraft.startDate/endDate/startTime/endTime`, `ItemDraft.newItem(from:through:categoryID:)` and correct create/update/series commands.

- [ ] **Step 1: Write failing draft/command tests**

```swift
@Test func rangeDraftCreatesOneMultiDayItem() throws {
    let vm = ItemEditorViewModel(
        mode: .create,
        draft: .newItem(from: date(2026, 8, 6), through: date(2026, 8, 8), categoryID: categoryID)
    )
    let command = try vm.makeCommand(now: now, newItemID: itemID, newSeriesID: seriesID, timeZoneIdentifier: zone)
    #expect(command.createdItem?.schedule == schedule("2026-08-06", "2026-08-08"))
}

@Test func timedRangeDraftAllowsOvernightButRejectsReversedDatesWithoutClearingInput() throws {
    var draft = ItemDraft.newItem(from: date(2026, 8, 7), through: date(2026, 8, 6), categoryID: categoryID)
    draft.usesTime = true
    draft.startTime = minute(23, 0)
    draft.endTime = minute(1, 0)
    let vm = ItemEditorViewModel(mode: .create, draft: draft)
    #expect(throws: ItemEditorError.invalidDateRange) {
        try vm.makeCommand(
            now: Date(timeIntervalSince1970: 1_775_664_000),
            newItemID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            newSeriesID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            timeZoneIdentifier: "Asia/Shanghai"
        )
    }
    #expect(vm.draft.startDate == date(2026, 8, 7))
}
```

Run: `Scripts/test.sh --filter ItemEditorViewModelTests`

Expected: compile failure because range draft fields and factories do not exist.

- [ ] **Step 2: Implement draft conversion and error messages**

Map ordinary items to `CalendarSchedule`; map recurring drafts to `ruleStartDate`, `recurrenceEndDate`, `durationDays` and paired times. For edit occurrence, emit a patch carrying displayed start and duration. Add `invalidDateRange` message “结束日期不能早于开始日期”.

- [ ] **Step 3: Update create and edit forms**

Render start/end date pickers; when `usesTime` is on, render start/end time beside the corresponding date. The recurrence deadline control keeps the label “重复结束日期” so it is not confused with instance end date.

- [ ] **Step 4: Run editor GREEN**

Run: `Scripts/test.sh --filter ItemEditorViewModelTests`

Expected: editor suite passes, including existing authoritative-draft and undo command tests.

- [ ] **Step 5: Build the app target**

Run: `swift build --product PersonalCalendar`

Expected: exit 0 with no compile errors.

- [ ] **Step 6: Commit Task 5**

```bash
git add Sources/CalendarApp/Editing Tests/CalendarAppTests/ItemEditorViewModelTests.swift
git commit -m "feat: 在事项卡片编辑跨日范围"
```

---

### Task 6: 连续周窗口、焦点月份与导航

**Files:**
- Create: `Sources/CalendarApp/Month/WeekStreamModel.swift`
- Modify: `Sources/CalendarApp/Month/MonthViewModel.swift`
- Test: `Tests/CalendarAppTests/WeekStreamModelTests.swift`
- Modify: `Tests/CalendarAppTests/MonthViewModelTests.swift`

**Interfaces:**
- Consumes: `TimelineProjection` and `WeekSegmentLayout`.
- Produces: `WeekStreamModel.weekStarts`, `focusWeek`, `monthTitleDate`, `jumpTargetForPreviousMonth()`, `jumpTargetForNextMonth()`, `todayTarget(_:)`, `prependAnchor`.

- [ ] **Step 1: Write failing week-window tests**

```swift
@Test func initialWindowContainsCurrentWeekPlusOrMinusFiftyTwoWeeks() {
    let model = WeekStreamModel(centeredOn: date(2026, 8, 6))
    #expect(model.weekStarts.count == 105)
    #expect(model.weekStarts[52] == date(2026, 8, 3))
}

@Test func focusMonthUsesThursdayAndMonthArrowsPreserveCivilDayIntent() {
    var model = WeekStreamModel(centeredOn: date(2026, 8, 31))
    model.updateFocus(toWeekStarting: date(2026, 8, 31))
    #expect(model.monthTitleDate == date(2026, 9, 3))
    #expect(model.jumpTargetForNextMonth().month == 10)
}

@Test func prependReturnsStableVisibleWeekAndOffsetAnchor() {
    var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
    let anchor = model.extendEarlier(visibleWeek: date(2025, 8, 4), pixelOffset: 37)
    #expect(anchor.weekStart == date(2025, 8, 4))
    #expect(anchor.pixelOffset == 37)
}

@Test func repeatedExtensionKeepsAtMostOneHundredFiftySevenWeeksAndTrimsTheFarSide() {
    var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
    _ = model.extendLater(visibleWeek: date(2027, 8, 2), pixelOffset: 19)
    let anchor = model.extendLater(visibleWeek: date(2028, 8, 7), pixelOffset: 19)
    #expect(model.weekStarts.count == 157)
    #expect(anchor.weekStart == date(2028, 8, 7))
    #expect(anchor.pixelOffset == 19)
}
```

Run: `Scripts/test.sh --filter WeekStreamModelTests`

Expected: compile failure because `WeekStreamModel` does not exist.

- [ ] **Step 2: Implement pure week-window/navigation model**

Normalize every week start to Monday. Initialize 52 earlier + center + 52 later weeks; extend by exactly 52. Cap the window at 157 consecutive weeks and trim 52 from the end farthest from focus, returning the same visible-week/pixel anchor for restoration. Track focus separately from selection. Implement civil-month clamping for dates such as January 31 → February 28/29.

- [ ] **Step 3: Connect `MonthViewModel` to arbitrary visible range**

Replace `displayedMonth`/42-cell projection with a week stream and a projection covering the loaded first Monday through final Sunday. Preserve hidden-category and today refresh behavior.

- [ ] **Step 4: Run model GREEN**

Run: `Scripts/test.sh --filter 'WeekStreamModelTests|MonthViewModelTests|MonthViewTodayRefreshPolicyTests'`

Expected: all selected suites pass.

- [ ] **Step 5: Build the app target**

Run: `swift build --product PersonalCalendar`

Expected: exit 0; the old view may still render through a compatibility adapter until Task 7.

- [ ] **Step 6: Commit Task 6**

```bash
git add Sources/CalendarApp/Month Tests/CalendarAppTests
git commit -m "feat: 建立跨月连续周窗口"
```

---

### Task 7: `WeekRow` 高密度渲染与连续条带

**Files:**
- Create: `Sources/CalendarApp/Month/WeekRowView.swift`
- Modify: `Sources/CalendarApp/Month/CalendarItemRow.swift`
- Modify: `Sources/CalendarApp/Month/DayCellView.swift`
- Modify: `Sources/CalendarApp/Month/MonthView.swift`
- Modify: `Sources/CalendarApp/Month/MonthGridBuilder.swift`
- Test: `Tests/CalendarAppTests/CalendarItemRowPresentationTests.swift`
- Test: `Tests/CalendarAppTests/MonthGridBuilderTests.swift`
- Test: `Tests/CalendarAppTests/WeekRowPresentationTests.swift`

**Interfaces:**
- Consumes: `WeekLayout` per loaded Monday.
- Produces: `WeekRowView`, `WeekRowPresentation`, full-range accessibility labels and one visual segment per visible lane.

- [ ] **Step 1: Write failing presentation tests**

```swift
@Test func crossDaySegmentPresentationUsesContinuousColumnsAndContinuationEdges() {
    let presentation = WeekRowPresentation(layout: crossMonthWeekLayout)
    #expect(presentation.segment(sourceID).startColumn == 5)
    #expect(presentation.segment(sourceID).endColumn == 6)
    #expect(presentation.segment(sourceID).trailingContinuation)
}

@Test func fullScreenWeekHeightExposesTenRowsBeforeOverflow() {
    #expect(WeekRowMetrics.itemCapacity(height: 252) == 10)
    #expect(WeekRowMetrics.itemCapacity(height: 210) < 10)
}

@Test func accessibilityReadsCompleteRangeAcrossSegments() {
    #expect(presentation.accessibilityLabel == "待办，工作，产品发布，8月29日至9月2日，延续到下一周，未完成")
}
```

Run: `Scripts/test.sh --filter WeekRowPresentationTests`

Expected: compile failure because WeekRow presentation types do not exist.

- [ ] **Step 2: Implement `WeekRowView` as one seven-column coordinate space**

Draw date backgrounds and headers in a seven-column grid, then draw lane segments in one overlay using `startColumn/endColumn`. Single-day rows and multi-day bars use the same source identity and completion callback.

- [ ] **Step 3: Replace the six-row `LazyVGrid` with a lazy vertical week stream**

Use `ScrollView` + `LazyVStack(spacing: 0)` and stable Monday IDs. Keep weekday header pinned above it. Set the default row height to 252pt and never divide viewport height by six.

- [ ] **Step 4: Connect focus/title/navigation and overflow drawer**

Update focus from the week closest to viewport center. Month arrows and Today use `ScrollViewReader` to center a target Monday. “还有 N 项” remains date-specific and opens the existing day drawer projected for that date.

- [ ] **Step 5: Run rendering GREEN and build**

Run: `Scripts/test.sh --filter 'WeekRowPresentationTests|CalendarItemRowPresentationTests|MonthGridBuilderTests|MonthViewModelTests'`

Run: `swift build --product PersonalCalendar`

Expected: tests and build pass. Delete `MonthGridBuilder` only if no source references remain; otherwise leave a deprecated test-only compatibility function for this task and remove it in Task 12.

- [ ] **Step 6: Commit Task 7**

```bash
git add Sources/CalendarApp/Month Tests/CalendarAppTests
git commit -m "feat: 渲染高密度连续周流"
```

---

### Task 8: 空白拖选与锚定创建卡片

**Files:**
- Create: `Sources/CalendarApp/Month/CalendarInteractionCoordinator.swift`
- Create: `Sources/CalendarApp/Month/AnchoredEditorLayout.swift`
- Modify: `Sources/CalendarApp/Month/WeekRowView.swift`
- Modify: `Sources/CalendarApp/Month/MonthView.swift`
- Modify: `Sources/CalendarApp/Editing/QuickCreatePopover.swift`
- Test: `Tests/CalendarAppTests/CalendarInteractionCoordinatorTests.swift`
- Test: `Tests/CalendarAppTests/AnchoredEditorLayoutTests.swift`
- Test: `Tests/CalendarAppTests/DayCellInteractionTests.swift`

**Interfaces:**
- Produces: coordinator states `idle/selectingRange/moving/resizingLeading/resizingTrailing/pendingRecurrenceScope/editing`; `AnchoredEditorLayout.place(cardSize:anchorFrame:windowBounds:)`.
- Consumes: date cell frame map from `WeekRowView` and range draft factory from Task 5.

- [ ] **Step 1: Write failing gesture state tests**

```swift
@Test func emptyPressBelowSevenPointsStaysAClick() {
    var coordinator = CalendarInteractionCoordinator()
    coordinator.pointerDown(on: date(2026, 8, 6), target: .emptyCell, point: .zero)
    let action = coordinator.pointerUp(at: CGPoint(x: 6, y: 0), over: date(2026, 8, 6))
    #expect(action == .openCreate(range(date(2026, 8, 6), date(2026, 8, 6)), anchor: date(2026, 8, 6)))
}

@Test func reverseRangeDragNormalizesDatesAndAnchorsReleaseDate() {
    var coordinator = CalendarInteractionCoordinator()
    coordinator.beginRange(on: date(2026, 8, 8), point: .zero)
    coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(2026, 8, 6))
    #expect(coordinator.previewRange == range(date(2026, 8, 6), date(2026, 8, 8)))
    #expect(coordinator.endInteraction() == .openCreate(
        range(date(2026, 8, 6), date(2026, 8, 8)),
        anchor: date(2026, 8, 6)
    ))
}
```

Run: `Scripts/test.sh --filter CalendarInteractionCoordinatorTests`

Expected: compile failure because the coordinator does not exist.

- [ ] **Step 2: Implement range-selection state machine and auto-scroll intent**

Only empty-cell presses may enter selection. Expose `.scrollEarlier/.scrollLater` intent when the pointer is within 28pt of viewport edges, throttled to one week per 180ms. Keep Store untouched during preview.

- [ ] **Step 3: Write failing four-direction placement tests**

```swift
@Test func cardPrefersRightThenFlipsLeftAtWindowEdge() {
    #expect(place(anchor: centeredCell).edge == .right)
    #expect(place(anchor: rightEdgeCell).edge == .left)
}

@Test func offscreenAnchorPinsToNearestSafeWindowEdgeWithoutDiscardingDraft() {
    let result = AnchoredEditorLayout.place(cardSize: card, anchorFrame: offscreenBelow, windowBounds: window)
    #expect(result.frame.maxY <= window.maxY - 12)
    #expect(result.pinnedToWindowEdge)
}
```

Run: `Scripts/test.sh --filter AnchoredEditorLayoutTests`

Expected: compile failure because layout placement does not exist.

- [ ] **Step 4: Implement root-overlay editor and persistent range highlight**

Collect date frames with a preference key. Replace root `.popover` for quick create with an overlay card placed by `AnchoredEditorLayout`. Range highlight remains visible while the draft is open; Escape or successful save clears it.

- [ ] **Step 5: Run interaction GREEN and build**

Run: `Scripts/test.sh --filter 'CalendarInteractionCoordinatorTests|AnchoredEditorLayoutTests|DayCellInteractionTests|ItemEditorViewModelTests'`

Run: `swift build --product PersonalCalendar`

Expected: tests/build pass; empty click, controls, drag selection and card placement have separate behavior tests.

- [ ] **Step 6: Commit Task 8**

```bash
git add Sources/CalendarApp/Month Sources/CalendarApp/Editing Tests/CalendarAppTests
git commit -m "feat: 拖选日期并锚定创建卡片"
```

---

### Task 9: 条带主体移动、两端缩放与重复范围确认

**Files:**
- Modify: `Sources/CalendarApp/Month/CalendarInteractionCoordinator.swift`
- Modify: `Sources/CalendarApp/Month/WeekRowView.swift`
- Modify: `Sources/CalendarApp/Month/MonthView.swift`
- Modify: `Sources/CalendarApp/DragDrop/CalendarDropCoordinator.swift`
- Modify: `Sources/CalendarApp/DragDrop/RecurringDropPresentationController.swift`
- Test: `Tests/CalendarAppTests/CalendarInteractionCoordinatorTests.swift`
- Test: `Tests/CalendarAppTests/CalendarDropCoordinatorTests.swift`
- Test: `Tests/CalendarAppTests/RecurringDropPresentationControllerTests.swift`
- Test: `Tests/CalendarAppTests/CalendarStoreTests.swift`

**Interfaces:**
- Consumes: source `ProjectedEntry`, preview schedules, Task 2 patches.
- Produces: `PendingCalendarMutation` for ordinary item or recurring occurrence, submitted exactly once after optional scope selection.

- [ ] **Step 1: Write failing move/resize preview tests**

```swift
@Test func bodyMovePreservesDurationAcrossWeeks() {
    var coordinator = coordinatorMoving(schedule("2026-08-06", "2026-08-08"))
    coordinator.update(over: date(2026, 8, 11))
    #expect(coordinator.previewSchedule == schedule("2026-08-11", "2026-08-13"))
}

@Test func leadingAndTrailingResizeClampToOneDay() {
    #expect(resizeLeading(span("2026-08-06", "2026-08-08"), to: date(2026, 8, 10)) == span("2026-08-08", "2026-08-08"))
    #expect(resizeTrailing(span("2026-08-06", "2026-08-08"), to: date(2026, 8, 4)) == span("2026-08-06", "2026-08-06"))
}
```

Run: `Scripts/test.sh --filter CalendarInteractionCoordinatorTests`

Expected: FAIL because item interactions are not implemented.

- [ ] **Step 2: Implement hit priority and preview-only move/resize**

Completion button wins over handle, handle wins over body, body wins over cell background. Only true outer segment endpoints expose handles. Moving/resizing updates the same cross-week highlight and edge auto-scroll intent as selection.

- [ ] **Step 3: Write failing atomic command/undo tests**

```swift
@Test func recurringResizeWaitsForScopeAndSubmitsExactlyOneCommand() async throws {
    let pending = coordinator.finishRecurringTrailingResize(to: date(2026, 8, 15))
    #expect(repository.saveCount == 0)
    try await coordinator.resolve(pending, scope: .thisAndFuture)
    #expect(repository.saveCount == 1)
    #expect(store.canUndo)
}

@Test func cancelRecurringResizeLeavesMemoryDiskAndUndoUntouched() async {
    let before = store.state
    coordinator.cancelPendingMutation()
    #expect(store.state == before)
    #expect(repository.saveCount == 0)
    #expect(!store.canUndo)
}

@Test func failedSaveRollsPreviewBackWithoutHalfSplitSeries() async {
    repository.failNextSave = true
    await #expect(throws: StoreError.persistenceFailed) { try await submitFutureResize() }
    #expect(store.state == originalState)
    #expect(coordinator.state == .idle)
}
```

Run: `Scripts/test.sh --filter 'CalendarDropCoordinatorTests|CalendarStoreTests'`

Expected: FAIL until range mutations use a captured pending command and one Store send.

- [ ] **Step 4: Unify pending mutation and recurrence confirmation**

Capture the source identity and preview schedule before presenting the dialog. Selection closes the dialog synchronously, then submits the captured command once. Preserve retry behavior after persistence failure. Ordinary items submit `.moveItem` or `.updateItem`; recurring entries submit one `.mutateSeries` patch.

- [ ] **Step 5: Run full interaction GREEN and build**

Run: `Scripts/test.sh --filter 'CalendarInteractionCoordinatorTests|CalendarDropCoordinatorTests|RecurringDropPresentationControllerTests|CalendarStoreTests|SeriesMutationEngineTests'`

Run: `swift build --product PersonalCalendar`

Expected: all selected suites/build pass.

- [ ] **Step 6: Commit Task 9**

```bash
git add Sources/CalendarApp Tests/CalendarAppTests
git commit -m "feat: 移动并缩放跨日事项"
```

---

### Task 10: 五组分类色与浅深语义角色

**Files:**
- Create: `Sources/CalendarApp/Categories/CategoryPalette.swift`
- Modify: `Sources/CalendarApp/DesignSystem/CalendarTheme.swift`
- Modify: `Sources/CalendarApp/Categories/CategoryManagerViewModel.swift`
- Modify: `Sources/CalendarApp/Categories/CategoryManagerView.swift`
- Test: `Tests/CalendarAppTests/CategoryManagerViewModelTests.swift`
- Test: `Tests/CalendarAppTests/CategoryPaletteTests.swift`

**Interfaces:**
- Produces: `CategoryColorFamily`, `CategoryPalette.families`, `CategoryColorResolver.roles(for:appearance:)` containing accent/background/outline.
- Consumes: persisted base `colorHex`; no schema change.

- [ ] **Step 1: Write failing palette/selection tests**

```swift
@Test func paletteContainsFiveNamedFamiliesWithEightUniqueColorsEach() {
    #expect(CategoryPalette.families.map(\.name) == ["基础", "马卡龙", "莫兰迪", "自然", "鲜亮"])
    #expect(CategoryPalette.families.allSatisfy { $0.colors.count == 8 })
    #expect(Set(CategoryPalette.families.flatMap(\.colors)).count == 40)
}

@Test func changingFamilyDoesNotChangeDraftUntilColorIsChosen() {
    model.beginEditing(category)
    model.selectFamily(.macaron)
    #expect(model.draftColorHex == category.colorHex)
    model.selectPreset("#8FB8F4")
    #expect(model.draftColorHex == "#8FB8F4")
}
```

Run: `Scripts/test.sh --filter 'CategoryPaletteTests|CategoryManagerViewModelTests'`

Expected: compile failure because family and palette types do not exist.

- [ ] **Step 2: Implement the exact 40-color table from the design spec**

Use the five rows and exact hex values from `docs/superpowers/specs/2026-08-03-calendar-v2-continuous-week-stream-design.md` section 9.2. Expose Chinese family/color accessibility names; persist only the selected base hex.

- [ ] **Step 3: Write failing role contrast tests**

```swift
@Test func everyPresetAndCustomExtremeProducesReadableLightAndDarkRoles() throws {
    for hex in CategoryPalette.families.flatMap(\.colors) + ["#FFFFFF", "#000000"] {
        for appearance in [CalendarAppearance.light, .dark] {
            let roles = try CategoryColorResolver.roles(for: hex, appearance: appearance)
            #expect(roles.textContrast >= 4.5)
            #expect(roles.accentContrast >= 3.0)
        }
    }
}

@Test func eachFamilyRemainsDistinguishableUnderCommonRedGreenDeficiencySimulation() throws {
    for family in CategoryPalette.families {
        #expect(try family.minimumPairwiseDeltaE(simulation: .protanopia) >= 3)
        #expect(try family.minimumPairwiseDeltaE(simulation: .deuteranopia) >= 3)
    }
}
```

Run: `Scripts/test.sh --filter CategoryPaletteTests`

Expected: FAIL until resolver adjusts accent lightness against oat/warm-black surfaces.

- [ ] **Step 4: Implement deterministic role resolver and family UI**

Resolve `accent`, `softBackground`, and `outline` from a base sRGB color. Composite soft background over the appearance canvas; iteratively adjust accent lightness toward the higher-contrast pole until 3:1. Body text remains semantic warm black/white and must meet 4.5:1. Add deterministic protanopia/deuteranopia matrix simulation and CIE Lab Delta E checks against the exact design-spec table; every pair in a family must remain at least Delta E 3. Category manager shows compact family tabs and eight swatches; ColorPicker and hex input remain.

- [ ] **Step 5: Run category GREEN and build**

Run: `Scripts/test.sh --filter 'CategoryPaletteTests|CategoryManagerViewModelTests'`

Run: `swift build --product PersonalCalendar`

Expected: tests/build pass; existing category delete/reorder/undo behavior remains green.

- [ ] **Step 6: Commit Task 10**

```bash
git add Sources/CalendarApp/Categories Sources/CalendarApp/DesignSystem Tests/CalendarAppTests
git commit -m "feat: 扩展分类色系与可读配色"
```

---

### Task 11: C「安静生活感」、无障碍与减少动态效果

**Files:**
- Modify: `Sources/CalendarApp/DesignSystem/CalendarTheme.swift`
- Modify: `Sources/CalendarApp/Month/MonthView.swift`
- Modify: `Sources/CalendarApp/Month/WeekRowView.swift`
- Modify: `Sources/CalendarApp/Month/CalendarItemRow.swift`
- Modify: `Sources/CalendarApp/Editing/QuickCreatePopover.swift`
- Modify: `Sources/CalendarApp/Editing/ItemDetailPopover.swift`
- Modify: `Sources/CalendarApp/Categories/CategoryManagerView.swift`
- Test: `Tests/CalendarAppTests/CalendarItemRowPresentationTests.swift`
- Test: `Tests/CalendarAppTests/WeekRowPresentationTests.swift`
- Test: `Tests/CalendarAppTests/CalendarThemeTests.swift`

**Interfaces:**
- Produces: semantic appearance tokens for oat/warm-black canvases, separators, selection, range preview and motion policy.
- Consumes: category role resolver and complete schedule accessibility text.

- [ ] **Step 1: Write failing semantic-role and accessibility tests**

```swift
@Test func lightAndDarkThemesUseWarmCanvasAndReadablePrimaryText() {
    #expect(CalendarTheme.light.canvasHex == "#F7F1E7")
    #expect(CalendarTheme.dark.canvasHex == "#211E1B")
    #expect(CalendarTheme.light.primaryTextContrast >= 4.5)
    #expect(CalendarTheme.dark.primaryTextContrast >= 4.5)
}

@Test func continuationAccessibilityNamesBothRangeAndDirection() {
    #expect(segment.accessibilityLabel.contains("8月29日至9月2日"))
    #expect(segment.accessibilityLabel.contains("从前一周继续"))
    #expect(segment.accessibilityLabel.contains("延续到下一周"))
}

@Test func reducedMotionDisablesAnimatedSnapButKeepsTargetWeek() {
    #expect(CalendarMotionPolicy(reduceMotion: true).snapAnimation == nil)
    #expect(CalendarMotionPolicy(reduceMotion: true).shouldAlignToWeek)
}
```

Run: `Scripts/test.sh --filter 'CalendarThemeTests|WeekRowPresentationTests|CalendarItemRowPresentationTests'`

Expected: compile/test failure because warm semantic theme and motion policy do not exist.

- [ ] **Step 2: Implement semantic theme tokens**

Define appearance structs for canvas, elevated surface, separator, primary/secondary text, today, selection, range preview and subtle shadow. Replace cold system canvas/accent uses in the touched views; do not alter macOS keyboard/menu/window behavior.

- [ ] **Step 3: Complete accessibility and handle semantics**

Expose complete start/end date-time, type, category, completion, continuation direction and handle purpose. Multiple week segments retain the source identifier in their accessibility value. Keep keyboard editing of dates as a non-drag alternative.

- [ ] **Step 4: Add reduced-motion behavior and density check**

When `accessibilityReduceMotion` is true, remove animated snap/overlay transitions but still align navigation targets. Verify metrics still give 10 item lanes at 252pt.

- [ ] **Step 5: Run visual-policy GREEN and build**

Run: `Scripts/test.sh --filter 'CalendarThemeTests|WeekRowPresentationTests|CalendarItemRowPresentationTests|CategoryPaletteTests'`

Run: `swift build --product PersonalCalendar`

Expected: selected suites/build pass.

- [ ] **Step 6: Commit Task 11**

```bash
git add Sources/CalendarApp Tests/CalendarAppTests
git commit -m "feat: 应用安静生活感月历主题"
```

---

### Task 12: 集成清理、真实应用验收与可交付包

**Files:**
- Modify: `Sources/CalendarApp/Month/MonthView.swift`
- Delete when unused: `Sources/CalendarDomain/MonthProjection.swift`
- Delete when unused: `Sources/CalendarApp/Month/MonthGridBuilder.swift`
- Modify: `Tests/CalendarAppTests/TestSupport.swift`
- Modify: `Scripts/test-build-app-archive.sh`
- Modify: `docs/validation/calendar-v1/acceptance.md`
- Create: `docs/validation/calendar-v2/acceptance.md`
- Create: `docs/validation/calendar-v2/visual-checklist.md`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: one authoritative signed `.app.zip`, one verified DMG, exact hashes and a truthfully marked acceptance record.

- [ ] **Step 1: Add final integration regression tests before cleanup**

```swift
@Test func v1BackupToV2StoreToProjectionToUndoRoundTripKeepsOneCrossDayIdentity() async throws {
    let store = try await loadStore(from: v1Fixture)
    let created = try await createCrossDayRange(in: store)
    let projection = TimelineProjection.make(in: visibleRange, state: store.state, hiddenCategoryIDs: [])
    #expect(projection.entries.filter { $0.id == .item(created.id) }.count == 1)
    try await store.undo()
    #expect(store.state.items[created.id] == nil)
    #expect(try await repository.load() == store.state)
}
```

Run: `Scripts/test.sh --filter 'CalendarStoreTests|JSONCalendarRepositoryTests|TimelineProjectionTests'`

Expected: FAIL if any cross-layer migration, persistence, identity or undo wiring is incomplete.

- [ ] **Step 2: Remove old business-truth paths and run full automated suite**

Use `rg 'MonthProjection|MonthGridBuilder|dropDestination' Sources Tests` to resolve remaining production references. Delete obsolete fixed-grid paths; retain `Transferable` only if it has a real compatibility consumer.

Run: `Scripts/test.sh`

Expected: every suite passes with zero failures and no “zero tests matched” result.

- [ ] **Step 3: Run packaging and fault gates**

Run:

```bash
Scripts/test-build-app-archive.sh
Scripts/test-build-app-failures.sh
Scripts/test-build-app-symlink.sh
Scripts/build-app.sh
```

Expected: all scripts exit 0; failed candidate builds preserve the prior authoritative archive; fresh extraction passes `codesign --verify --deep --strict` and plist checks.

- [ ] **Step 4: Perform native packaged-app acceptance**

Launch the freshly extracted `.app`, not `.build/debug`. Record each result separately in `docs/validation/calendar-v2/acceptance.md`:

```text
1. 单击四个窗口边缘日期，创建卡片就近出现并自动翻边。
2. 正向/反向拖选跨月范围，范围持续高亮并预填正确。
3. 全屏连续滚动前后至少 52 周，扩展不跳位，标题跟随中心周。
4. 单日 10 条直接可见，第 11 条 overflow 正确。
5. 普通跨日条带主体移动、左右端缩放、Cmd-Z。
6. 重复跨日条带仅本次/本次及以后/取消，含保存失败重试。
7. 重启后范围、完成、分类和重复实例保持。
8. schema 1 备份恢复成功；无效备份不覆盖当前数据。
9. 浅色/深色、五组色板、自定义极端色、VoiceOver 和减少动态效果。
```

- [ ] **Step 5: Produce final ZIP/DMG evidence**

Record final artifact absolute paths, SHA-256, fresh-extract CDHash, test count, packaging gate results and any remaining manual-only boundary. Do not mark an unperformed native gesture as PASS.

- [ ] **Step 6: Commit Task 12**

```bash
git add Sources Tests Scripts docs/validation/calendar-v2 docs/validation/calendar-v1/acceptance.md
git commit -m "test: 完成连续月历交付验收"
```

---

## Plan Self-Review Checklist

- [x] 每条设计规格都能映射到至少一个任务和验收项。
- [x] 没有 `TBD`、`TODO`、占位测试或仅检查源码文本的测试。
- [x] `CalendarDate`、`MinuteOfDay`、`ItemKind`、`CalendarSchedule`、`OccurrenceKey` 名称在任务间一致。
- [x] Task 1–4 先建立领域、迁移和投影；Task 5–11 只依赖已存在接口；Task 12 才删除兼容路径。
- [x] 每个任务都有 RED 命令、最小实现方向、GREEN 命令、构建或回归门禁和独立 commit。
- [x] 用户已明确授权直接执行，采用 subagent-driven development，不再请求执行方式选择。

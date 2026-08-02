# 个人月历 Calendar V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 构建一个 macOS 原生、本地离线、只提供月视图的个人彩色排期应用，支持任务与日程、单分类颜色、可选起止时间、每周固定星期重复、单次例外、完成状态、撤销与本应用备份恢复。

**Architecture:** 使用 SwiftUI + AppKit 构建原生桌面界面；业务语义放在无 UI 依赖的 CalendarDomain 纯 Swift 模块中，JSON 原子持久化放在 CalendarPersistence actor 中，CalendarApp 只负责窗口、视图模型和交互。重复事项不预写无限实例，而由 WeeklySeries + 稳定 OccurrenceKey + Exception/Completion 在查询月份时投影；所有变更先经过纯 reducer，再原子保存，从而让撤销、备份和测试使用同一份语义。

**Tech Stack:** Swift 6.3、SwiftUI、AppKit、Foundation、Swift Package Manager、Swift Testing。产品运行时零外部依赖；由于当前 Command Line Tools 未向 SwiftPM 暴露 Testing 模块，测试 target 唯一使用官方 swiftlang/swift-testing 源码依赖，锁定 Swift 6.3.2 发布提交 `70eff261d7f462cad1fff51e05bcc74aa0b0f420`并提交 Package.resolved。最低部署目标 macOS 14；当前验证环境为 Apple Silicon、macOS 26.5.2、Swift 6.3.3、Command Line Tools（不假设已安装完整 Xcode）。

官方依赖基线：[swiftlang/swift-testing](https://github.com/swiftlang/swift-testing/tree/70eff261d7f462cad1fff51e05bcc74aa0b0f420)。

## Global Constraints

- 唯一产品规格：docs/superpowers/specs/2026-08-02-calendar-v1-design.md。
- 第一版只支持 macOS 桌面月视图；不创建日、周、年、列表、时间线或移动端空入口。
- 不实现通知、提醒、清单、跨天事项、外部日历、旧数据导入、账号、云同步、AI 或 Chat。
- 每个任务或日程必须且只能有一个分类；系统“未分类”不可删除。
- 时间只能“两者都空”或“开始、结束都有”，且同日 end > start。
- 普通事项和重复系列都持久化创建时的系统时区标识；V1 只使用本地墙上时钟，不暴露时区选择器。
- 重复只支持每周固定星期几；所有本次/本次及以后行为必须严格遵守规格中的实例身份和历史保留合同。
- 视觉参考滴答清单的中性画布、月格密度、颜色扫读和短路径浮层，但不得复制品牌素材、图标、专有文案或逐像素布局。
- 运行时完全离线；不增加网络权限、遥测或账号 SDK。
- 所有持久化写入必须原子化；无效备份不得覆盖当前数据。
- 每个 Task 使用 TDD：先观察目标测试失败，再写最小实现，再跑目标测试和全量测试。
- 每个 FooTests.swift 在 imports 之后声明同名 @Suite("FooTests") struct FooTests，文中的 @Test 代码均放入该 suite 体内；CalendarAppTests 的 suite 同时标注 @MainActor。因此 swift test --filter FooTests 必须实际执行非零条测试，无测试匹配视为 Gate 失败。
- 每个 bounded Task 由 fresh Terra xhigh implementer 执行，完成后由 fresh Sol xhigh 做规格与代码质量 Gate；finding 修复后 scoped re-review。主 Agent 只在最终全量门禁通过后报告完成。
- 只提交计划内文件；当前 .gstack/ 属于工具状态，不作为产品源码。

---

## 1. Planned File Structure

~~~text
.
├── Package.swift
├── Package.resolved
├── .gitignore
├── Sources
│   ├── CalendarDomain
│   │   ├── CalendarDate.swift
│   │   ├── CalendarTime.swift
│   │   ├── CalendarModels.swift
│   │   ├── RecurrenceModels.swift
│   │   ├── RecurrenceEngine.swift
│   │   ├── SeriesMutationEngine.swift
│   │   ├── CalendarState.swift
│   │   ├── CalendarCommand.swift
│   │   ├── CalendarReducer.swift
│   │   └── MonthProjection.swift
│   ├── CalendarPersistence
│   │   ├── CalendarDocument.swift
│   │   ├── CalendarRepository.swift
│   │   ├── JSONCalendarRepository.swift
│   │   └── BackupService.swift
│   └── CalendarApp
│       ├── PersonalCalendarApp.swift
│       ├── AppEnvironment.swift
│       ├── CalendarStore.swift
│       ├── DesignSystem
│       │   └── CalendarTheme.swift
│       ├── Month
│       │   ├── MonthGridBuilder.swift
│       │   ├── MonthViewModel.swift
│       │   ├── MonthView.swift
│       │   ├── DayCellView.swift
│       │   └── CalendarItemRow.swift
│       ├── Editing
│       │   ├── ItemDraft.swift
│       │   ├── ItemEditorViewModel.swift
│       │   ├── QuickCreatePopover.swift
│       │   └── ItemDetailPopover.swift
│       ├── DayDrawer
│       │   ├── DayDrawerViewModel.swift
│       │   └── DayDrawerView.swift
│       ├── Categories
│       │   ├── CategoryManagerViewModel.swift
│       │   ├── CategoryManagerView.swift
│       │   └── CategoryFilterView.swift
│       ├── DragDrop
│       │   ├── CalendarItemTransfer.swift
│       │   └── CalendarDropCoordinator.swift
│       └── Backup
│           └── BackupCommands.swift
├── Tests
│   ├── CalendarDomainTests
│   │   ├── CoreModelTests.swift
│   │   ├── RecurrenceEngineTests.swift
│   │   ├── SeriesMutationEngineTests.swift
│   │   └── CalendarReducerTests.swift
│   ├── CalendarPersistenceTests
│   │   └── JSONCalendarRepositoryTests.swift
│   └── CalendarAppTests
│       ├── MonthGridBuilderTests.swift
│       ├── MonthViewModelTests.swift
│       ├── CalendarStoreTests.swift
│       ├── ItemEditorViewModelTests.swift
│       ├── CategoryManagerViewModelTests.swift
│       ├── CalendarDropCoordinatorTests.swift
│       └── TestSupport.swift
├── Support
│   └── Info.plist
├── Scripts
│   ├── test.sh
│   └── build-app.sh
└── docs
    └── validation
        └── calendar-v1
            └── acceptance.md
~~~

CalendarDomain owns all durable semantics and must not import SwiftUI/AppKit. CalendarPersistence owns disk formats and atomic I/O. CalendarApp owns transient view state, windows, keyboard interaction and visual layout. No source file should exceed one primary responsibility.

---

### Task 1: Bootstrap the package and core one-off calendar model

**Deliverable:** Swift package builds without full Xcode; category, local date/time and one-off task/event rules are testable independently of UI.

**Files:**
- Create: Package.swift
- Create: Scripts/test.sh
- Create: .gitignore
- Create: Sources/CalendarDomain/CalendarDate.swift
- Create: Sources/CalendarDomain/CalendarTime.swift
- Create: Sources/CalendarDomain/CalendarModels.swift
- Test: Tests/CalendarDomainTests/CoreModelTests.swift

**Interfaces:**
- Produces: CalendarDate, Weekday, MinuteOfDay, LocalTimeRange, CalendarCategory, CalendarItem, ItemKind, DomainValidationError.
- CalendarDate must be Codable, Hashable, Comparable, Sendable and expose addingDays(_:), previousDay, weekday.
- LocalTimeRange.init(start:end:) throws when end <= start.
- CalendarItem.init enforces event.completedAt == nil and exactly one categoryID.

- [ ] **Step 1: Add the package manifest and a failing core-model test**

Package.swift must initially expose only CalendarDomain and its tests:

~~~swift
// swift-tools-version: 6.3
import PackageDescription

let commandLineToolsTestingLibraryPath =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let testingLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", commandLineToolsTestingLibraryPath,
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingLibraryPath
    ], .when(platforms: [.macOS]))
]

let package = Package(
    name: "PersonalCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CalendarDomain", targets: ["CalendarDomain"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "70eff261d7f462cad1fff51e05bcc74aa0b0f420"
        )
    ],
    targets: [
        .target(name: "CalendarDomain"),
        .testTarget(
            name: "CalendarDomainTests",
            dependencies: [
                "CalendarDomain",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: testingLinkerSettings
        )
    ]
)
~~~

Run `test -f "/Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib"` and `swift package resolve` before the first test, verify Package.resolved pins both swift-testing and its transitive swift-syntax revision, and commit it. Every later test target adds the same `.product(name: "Testing", package: "swift-testing")` dependency and `linkerSettings: testingLinkerSettings`. The explicit CLT library path is required in this verified environment to resolve `_TestingInterop`; without it the link fails. Product/library/executable targets must not depend on Testing, the unsafe linker settings, or any transitive package, so the packaged app remains fully offline and runtime-zero-dependency.

Scripts/test.sh prevents SwiftPM's zero-match warning from exiting successfully:

~~~bash
#!/bin/zsh
set -euo pipefail

TEST_LOG=$(mktemp "${TMPDIR:-/tmp}/personal-calendar-tests.XXXXXX")
trap 'rm -f "$TEST_LOG"' EXIT

set +e
swift test "$@" 2>&1 | tee "$TEST_LOG"
TEST_STATUS=$?
set -e
if (( TEST_STATUS != 0 )); then
  exit "$TEST_STATUS"
fi
if grep -q "No matching test cases were run" "$TEST_LOG"; then
  echo "Focused test filter matched zero tests" >&2
  exit 3
fi
~~~

Mark it executable. All focused test commands in this plan use this wrapper; full-suite final gates may call either `zsh Scripts/test.sh` or `swift test`.

CoreModelTests.swift must begin with these observable contracts:

~~~swift
import Testing
@testable import CalendarDomain

@Test func timeRangeRejectsReversedRange() throws {
    #expect(throws: DomainValidationError.invalidTimeRange) {
        try LocalTimeRange(
            start: MinuteOfDay(hour: 10, minute: 30)!,
            end: MinuteOfDay(hour: 9, minute: 30)!
        )
    }
}

@Test func eventCannotCarryCompletion() throws {
    let category = UUID()
    #expect(throws: DomainValidationError.eventCannotComplete) {
        try CalendarItem(
            id: UUID(),
            kind: .event,
            title: "评审",
            categoryID: category,
            date: CalendarDate(year: 2026, month: 8, day: 3)!,
            timeRange: nil,
            completedAt: .now,
            createdAt: .now,
            updatedAt: .now
        )
    }
}

@Test func calendarDateUsesLocalCalendarDays() {
    let date = CalendarDate(year: 2026, month: 8, day: 31)!
    #expect(date.addingDays(1) == CalendarDate(year: 2026, month: 9, day: 1)!)
    #expect(date.weekday == .monday)
}
~~~

The suite also adds invalidMinuteOfDayReturnsNil for -1/24:00 and partialTimeRangeJSONFailsDecode for a persisted range containing start but no end. The type shape makes one-sided time impossible in memory; the decoder makes it impossible on disk. Add localDayUsesSuppliedSystemTimeZone: the same fixed instant near midnight maps to the expected next day in Asia/Shanghai and prior day in America/Los_Angeles. MonthViewModel uses this API for today rather than UTC components.

- [ ] **Step 2: Run the test and verify the intended failure**

Run: zsh Scripts/test.sh --filter CoreModelTests

Expected: build fails because CalendarDate, LocalTimeRange and CalendarItem do not exist.

- [ ] **Step 3: Implement the smallest complete value model**

Use integer calendar components instead of Date for all-day identity:

~~~swift
public struct CalendarDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int)
    public static func localDay(containing instant: Date, in timeZone: TimeZone) -> CalendarDate
    public func addingDays(_ count: Int) -> CalendarDate
    public func days(until other: CalendarDate) -> Int
    public var previousDay: CalendarDate { get }
    public var weekday: Weekday { get }
    public static func < (lhs: Self, rhs: Self) -> Bool
}

public enum Weekday: Int, Codable, CaseIterable, Hashable, Sendable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}

public struct MinuteOfDay: Codable, Hashable, Comparable, Sendable {
    public let value: Int
    public init?(hour: Int, minute: Int)
    public static func < (lhs: Self, rhs: Self) -> Bool
}

public struct LocalTimeRange: Codable, Hashable, Sendable {
    public let start: MinuteOfDay
    public let end: MinuteOfDay
    public init(start: MinuteOfDay, end: MinuteOfDay) throws
}

public enum ItemKind: String, Codable, Equatable, Hashable, Sendable {
    case task, event
}

public enum DomainValidationError: Error, Equatable, Sendable {
    case invalidTimeRange
    case emptyTitle
    case eventCannotComplete
    case invalidTimeZoneIdentifier
    case emptyWeekdaySet
    case invalidRecurrenceEnd
    case noOccurrenceInRange
}

public struct CalendarCategory: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public init(
        id: UUID, name: String, colorHex: String, sortIndex: Int,
        createdAt: Date, updatedAt: Date
    )
}

public struct CalendarItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    public var title: String
    public var categoryID: UUID
    public var date: CalendarDate
    public var timeRange: LocalTimeRange?
    public var creationTimeZoneIdentifier: String
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        categoryID: UUID,
        date: CalendarDate,
        timeRange: LocalTimeRange?,
        creationTimeZoneIdentifier: String = TimeZone.current.identifier,
        completedAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) throws
}
~~~

CalendarDate must use Calendar(identifier: .gregorian) pinned to UTC only for component arithmetic; it represents a local civil day and never an instant. CalendarDate and MinuteOfDay require custom Decodable implementations that reject invalid components/value ranges instead of accepting malformed backup data. MinuteOfDay.init? accepts only 00:00...23:59. CalendarItem trims titles, rejects empty titles and rejects an empty/unknown creationTimeZoneIdentifier.

- [ ] **Step 4: Run focused and full tests**

Run: zsh Scripts/test.sh --filter CoreModelTests

Expected: all CoreModelTests pass.

Run: swift test

Expected: all tests pass.

- [ ] **Step 5: Commit the bounded deliverable**

~~~bash
git add Package.swift Package.resolved .gitignore Scripts/test.sh Sources/CalendarDomain Tests/CalendarDomainTests/CoreModelTests.swift
git commit -m "feat: 建立月历核心数据模型"
~~~

---

### Task 2: Project weekly recurrence into stable occurrences

**Deliverable:** Querying any date range produces deterministic weekly occurrences with inclusive boundaries, completion state and single-occurrence exceptions.

**Files:**
- Create: Sources/CalendarDomain/RecurrenceModels.swift
- Create: Sources/CalendarDomain/RecurrenceEngine.swift
- Test: Tests/CalendarDomainTests/RecurrenceEngineTests.swift

**Interfaces:**
- Consumes: CalendarDate, Weekday, LocalTimeRange, ItemKind from Task 1.
- Produces: WeeklySeries, OccurrenceKey, OccurrenceException, OccurrenceCompletion, CalendarOccurrence, RecurrenceEngine.occurrences.

The exact public types are:

~~~swift
public struct WeeklySeries: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    public var title: String
    public var categoryID: UUID
    public var startDate: CalendarDate
    public var endDate: CalendarDate?
    public var weekdays: Set<Weekday>
    public var timeRange: LocalTimeRange?
    public var creationTimeZoneIdentifier: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        categoryID: UUID,
        startDate: CalendarDate,
        endDate: CalendarDate?,
        weekdays: Set<Weekday>,
        timeRange: LocalTimeRange?,
        creationTimeZoneIdentifier: String = TimeZone.current.identifier,
        createdAt: Date,
        updatedAt: Date
    ) throws
}

public struct OccurrenceKey: Codable, Hashable, Sendable {
    public let seriesID: UUID
    public let originalDate: CalendarDate
    public init(seriesID: UUID, originalDate: CalendarDate)
}

public enum OccurrenceExceptionKind: Codable, Equatable, Sendable {
    case skipped
    case modified(OccurrenceOverride)
}

public struct OccurrenceOverride: Codable, Equatable, Sendable {
    public var displayedDate: CalendarDate
    public var title: String
    public var kind: ItemKind
    public var categoryID: UUID
    public var timeRange: LocalTimeRange?
    public init(
        displayedDate: CalendarDate, title: String, kind: ItemKind,
        categoryID: UUID, timeRange: LocalTimeRange?
    )
}

public struct OccurrenceCompletion: Codable, Equatable, Sendable {
    public let key: OccurrenceKey
    public var completedAt: Date
    public init(key: OccurrenceKey, completedAt: Date)
}

public struct CalendarOccurrence: Identifiable, Equatable, Sendable {
    public let key: OccurrenceKey
    public let displayedDate: CalendarDate
    public let title: String
    public let kind: ItemKind
    public let categoryID: UUID
    public let timeRange: LocalTimeRange?
    public let creationTimeZoneIdentifier: String
    public let completedAt: Date?
    public let createdAt: Date
    public var id: OccurrenceKey { key }
    public init(
        key: OccurrenceKey,
        displayedDate: CalendarDate,
        title: String,
        kind: ItemKind,
        categoryID: UUID,
        timeRange: LocalTimeRange?,
        creationTimeZoneIdentifier: String,
        completedAt: Date?,
        createdAt: Date
    )
}
~~~

WeeklySeries.init trims and validates title, requires at least one weekday, rejects endDate < startDate, rejects a bounded range with no matching weekday, and validates creationTimeZoneIdentifier. Every public value type above has the explicit public initializer shown or an equivalent explicit initializer; do not rely on an internal synthesized memberwise initializer across SwiftPM targets.

- [ ] **Step 1: Write recurrence boundary and identity tests**

~~~swift
import Testing
@testable import CalendarDomain

@Test func firstOccurrenceIsFirstSelectedWeekdayOnOrAfterStart() throws {
    let series = try WeeklySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        kind: .task,
        title: "固定复盘",
        categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        startDate: .init(year: 2026, month: 8, day: 4)!, // Tuesday
        endDate: .init(year: 2026, month: 8, day: 12)!,
        weekdays: [.monday, .wednesday],
        timeRange: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    let result = RecurrenceEngine.occurrences(
        of: series,
        in: .init(
            start: .init(year: 2026, month: 8, day: 1)!,
            end: .init(year: 2026, month: 8, day: 31)!
        ),
        exceptions: [:],
        completions: [:]
    )
    #expect(result.map(\.key.originalDate) == [
        .init(year: 2026, month: 8, day: 5)!,
        .init(year: 2026, month: 8, day: 10)!,
        .init(year: 2026, month: 8, day: 12)!
    ])
}

@Test func movedExceptionSuppressesOriginalAndKeepsStableKey() throws {
    let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let series = try WeeklySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
        kind: .task,
        title: "周计划",
        categoryID: categoryID,
        startDate: .init(year: 2026, month: 8, day: 3)!,
        endDate: nil,
        weekdays: [.monday, .wednesday],
        timeRange: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    let monday = CalendarDate(year: 2026, month: 8, day: 3)!
    let key = OccurrenceKey(seriesID: series.id, originalDate: monday)
    let moved = OccurrenceOverride(
        displayedDate: .init(year: 2026, month: 8, day: 4)!,
        title: series.title,
        kind: series.kind,
        categoryID: series.categoryID,
        timeRange: series.timeRange
    )
    let result = RecurrenceEngine.occurrences(
        of: series,
        in: .init(
            start: .init(year: 2026, month: 8, day: 1)!,
            end: .init(year: 2026, month: 8, day: 31)!
        ),
        exceptions: [key: .modified(moved)],
        completions: [:]
    )
    let matchingKey = result.filter { $0.key == key }
    #expect(matchingKey.count == 1)
    #expect(matchingKey.first?.displayedDate == moved.displayedDate)
    #expect(result.filter { $0.displayedDate == monday }.isEmpty)
}
~~~

The same test file must include these exact regression functions:

| Test function | Setup | Required assertion |
| --- | --- | --- |
| inclusiveEndDateProducesOccurrence | Monday-only series ending on a Monday | result contains the end-date key and contains no later key |
| skippedExceptionRemovesOnlyItsStableKey | Monday/Wednesday series with one skipped Monday | skipped key absent; adjacent Wednesday present |
| eventDoesNotExposeCompletion | event series plus a completion entry for its key | projected event completedAt is nil |
| completingOneTaskOccurrenceDoesNotCompleteNext | two Monday task instances, completion for first key only | first completedAt non-nil; second completedAt nil |
| explicitExceptionSurvivesNonMatchingWeekdayAfterSplit | Tuesday-only series plus a modified exception whose original date is an in-range Monday and displayed date is Wednesday | exactly one occurrence with that stable key appears on Wednesday even though Monday is not generated by the rule |

- [ ] **Step 2: Run the tests and observe missing-type failures**

Run: zsh Scripts/test.sh --filter RecurrenceEngineTests

Expected: build fails because recurrence types and engine do not exist.

- [ ] **Step 3: Implement the range projector**

~~~swift
public struct CalendarDateRange: Equatable, Sendable {
    public let start: CalendarDate
    public let end: CalendarDate
    public init(start: CalendarDate, end: CalendarDate)
}

public enum RecurrenceEngine {
    public static func occurrences(
        of series: WeeklySeries,
        in range: CalendarDateRange,
        exceptions: [OccurrenceKey: OccurrenceExceptionKind],
        completions: [OccurrenceKey: OccurrenceCompletion]
    ) -> [CalendarOccurrence]
}
~~~

CalendarDateRange.init preconditions end >= start because ranges are built only from already-validated internal month/series bounds. RecurrenceEngine must ignore completion entries for events and expose the series createdAt/time-zone identifier on every projected occurrence.

Iterate civil days from max(series.startDate, range.start) through min(series.endDate ?? range.end, range.end), inclusive. Create a base occurrence only when weekdays contains date.weekday. Apply exception by stable key before filtering on displayedDate so a moved instance can enter or leave the queried month. Then traverse every modified exception belonging to this series whose displayedDate lies in the query and merge any stable key not already consumed, regardless of whether originalDate is inside the query or matches the current weekday rule. This preserves explicit instances migrated after a split. Deduplicate by OccurrenceKey and sort by displayedDate, untimed before timed, start time, then originalDate.

- [ ] **Step 4: Run recurrence and full tests**

Run: zsh Scripts/test.sh --filter RecurrenceEngineTests

Expected: all recurrence tests pass.

Run: swift test

Expected: all tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/CalendarDomain/RecurrenceModels.swift Sources/CalendarDomain/RecurrenceEngine.swift Tests/CalendarDomainTests/RecurrenceEngineTests.swift
git commit -m "feat: 实现每周重复实例投影"
~~~

---

### Task 3: Implement only-this and this-and-future series mutations

**Deliverable:** Editing, moving or deleting one occurrence or the future segment produces one deterministic, reversible recurrence graph.

**Files:**
- Create: Sources/CalendarDomain/SeriesMutationEngine.swift
- Test: Tests/CalendarDomainTests/SeriesMutationEngineTests.swift

**Interfaces:**
- Consumes: WeeklySeries, OccurrenceKey, exception/completion types.
- Produces: RecurrenceGraph, SeriesScope, SeriesEdit, SeriesMutationEngine.apply.

~~~swift
public struct RecurrenceGraph: Codable, Equatable, Sendable {
    public var series: [UUID: WeeklySeries]
    public var exceptions: [OccurrenceKey: OccurrenceExceptionKind]
    public var completions: [OccurrenceKey: OccurrenceCompletion]
    public init(
        series: [UUID: WeeklySeries],
        exceptions: [OccurrenceKey: OccurrenceExceptionKind],
        completions: [OccurrenceKey: OccurrenceCompletion]
    )
}

public enum SeriesScope: Equatable, Sendable { case onlyThis, thisAndFuture }

public enum OptionalPatch<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)
    case clear
}

public struct SeriesPatch: Sendable {
    public var title: String?
    public var kind: ItemKind?
    public var categoryID: UUID?
    public var timeRange: OptionalPatch<LocalTimeRange>
    public var displayedDate: CalendarDate?
    public var weekdays: Set<Weekday>?
    public var endDate: OptionalPatch<CalendarDate>
    public init(
        title: String? = nil,
        kind: ItemKind? = nil,
        categoryID: UUID? = nil,
        timeRange: OptionalPatch<LocalTimeRange> = .unchanged,
        displayedDate: CalendarDate? = nil,
        weekdays: Set<Weekday>? = nil,
        endDate: OptionalPatch<CalendarDate> = .unchanged
    )
}

public enum SeriesEdit: Sendable {
    case patch(SeriesPatch)
    case delete
}

public enum SeriesMutationError: Error, Equatable, Sendable {
    case unknownSeries
    case unknownOccurrence
    case invalidOnlyThisRulePatch
    case duplicateSeriesID
}

public enum SeriesMutationEngine {
    public static func apply(
        edit: SeriesEdit,
        to key: OccurrenceKey,
        scope: SeriesScope,
        in graph: RecurrenceGraph,
        newSeriesID: UUID,
        now: Date
    ) throws -> RecurrenceGraph
}
~~~

- [ ] **Step 1: Write the exact split, migration and shift tests**

~~~swift
@Test func thisAndFutureMoveShiftsMondayWednesdayToTuesdayThursday() throws {
    let series = try makeMondayWednesdaySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    )
    let boundary = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 10)!
    )
    let before = RecurrenceGraph(
        series: [series.id: series],
        exceptions: [:],
        completions: [:]
    )
    let after = try SeriesMutationEngine.apply(
        edit: .patch(.init(
            displayedDate: .init(year: 2026, month: 8, day: 11)!
        )),
        to: boundary,
        scope: .thisAndFuture,
        in: before,
        newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
        now: .now
    )

    let old = try #require(after.series[series.id])
    #expect(old.endDate == CalendarDate(year: 2026, month: 8, day: 9)!)
    let future = try #require(after.series.values.first { $0.id != series.id })
    #expect(future.startDate == CalendarDate(year: 2026, month: 8, day: 11)!)
    #expect(future.weekdays == [.tuesday, .thursday])
}

@Test func splittingPreservesPastAndMigratesFutureExceptions() throws {
    let series = try makeMondayWednesdaySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    )
    let pastKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 3)!
    )
    let boundaryKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 10)!
    )
    let futureKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 17)!
    )
    let modified = OccurrenceOverride(
        displayedDate: .init(year: 2026, month: 8, day: 18)!,
        title: "已明确改动",
        kind: .task,
        categoryID: series.categoryID,
        timeRange: nil
    )
    let completedAt = Date(timeIntervalSince1970: 100)
    let graph = RecurrenceGraph(
        series: [series.id: series],
        exceptions: [futureKey: .modified(modified)],
        completions: [pastKey: .init(key: pastKey, completedAt: completedAt)]
    )
    let after = try SeriesMutationEngine.apply(
        edit: .patch(.init(
            title: nil,
            kind: nil,
            categoryID: nil,
            timeRange: .unchanged,
            displayedDate: nil,
            weekdays: [.tuesday],
            endDate: .unchanged
        )),
        to: boundaryKey,
        scope: .thisAndFuture,
        in: graph,
        newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000212")!,
        now: Date(timeIntervalSince1970: 200)
    )

    #expect(after.completions[pastKey]?.completedAt == completedAt)
    let futureSeries = try #require(after.series.values.first { $0.id != series.id })
    let migratedKey = OccurrenceKey(
        seriesID: futureSeries.id,
        originalDate: futureKey.originalDate
    )
    #expect(after.exceptions[migratedKey] == .modified(modified))
    #expect(after.series[series.id]?.endDate ==
        CalendarDate(year: 2026, month: 8, day: 9)!)
}
~~~

Define this test-local helper directly in SeriesMutationEngineTests.swift:

~~~swift
private func makeMondayWednesdaySeries(id: UUID) throws -> WeeklySeries {
    try WeeklySeries(
        id: id,
        kind: .task,
        title: "周计划",
        categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        startDate: .init(year: 2026, month: 8, day: 3)!,
        endDate: nil,
        weekdays: [.monday, .wednesday],
        timeRange: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}
~~~

The same file must add these named cases with the stated exact result:

| Test function | Required result |
| --- | --- |
| onlyThisMoveCreatesOneModifiedException | input series unchanged; exactly one modified exception at original key; override displayedDate equals destination |
| onlyThisDeleteCreatesOneSkippedException | seed completion at selected key; input series unchanged, exception at key equals skipped, and same-key completion is removed |
| onlyThisPatchBuildsOnExistingModifiedException | title-only patch preserves the existing override displayedDate/category/time and changes only title |
| onlyThisTaskToEventClearsSelectedCompletion | selected key has a task completion; only-this kind patch to event removes that key's completion and the event override has no completion |
| thisAndFutureDeleteEndsOldSeriesAndRemovesFutureState | old endDate equals boundary.previousDay; no second series; no exception/completion key on or after boundary |
| changingTaskSeriesToEventRemovesFutureCompletions | past completion retained; migrated/future completion entries absent |
| futureMoveShiftsExplicitStateAndEmbeddedCompletionKey | seed one future modified exception and one future completion; after +1-day split, dictionary keys use newSeriesID and originalDate+1, OccurrenceCompletion.key equals its shifted dictionary key, override.displayedDate is +1, and no old future keys remain |
| splitAtFirstOccurrenceRemovesEmptyHistoricalSeries | boundary is the first generated instance; result contains no old series with endDate before startDate and contains only the valid future series |
| titleOnlyFuturePatchOnMovedBoundaryDoesNotShiftWeekdays | boundary has an existing moved override; patch displayedDate is nil; future weekdays/start/end dates are not shifted and boundary displayedDate is preserved |
| weekdayPatchDropsOnlyNonexistentFutureCompletions | future completions include one still generated by new weekdays, one backed by a migrated modified task exception, and one no longer represented; migrate first two to newSeriesID, remove third, and preserve all past state |
| shorteningFutureSeriesDropsStateBeyondNewEnd | patch sets an earlier inclusive end; migrate only exception/completion keys whose mapped originalDate is <= new end, remove every key beyond it, and project no occurrence beyond end |
| unknownBoundaryThrows | apply throws SeriesMutationError.unknownOccurrence and input graph remains exactly equal to before |

- [ ] **Step 2: Run the focused tests**

Run: zsh Scripts/test.sh --filter SeriesMutationEngineTests

Expected: build fails because SeriesMutationEngine does not exist.

- [ ] **Step 3: Implement mutations as pure value transforms**

For onlyThis, reject non-nil weekdays/endDate patches, materialize the current effective occurrence (existing modified exception first, otherwise the generated base), apply only changed title/kind/category/time/displayedDate fields, and replace one modified exception at the original key. If its effective kind becomes event, remove that key's completion in the same graph. For thisAndFuture, a migrated boundary modified exception is likewise based on its effective value; changed content fields update both the new series default and that boundary override, while a nil displayedDate preserves its existing one-off placement and causes no weekday shift. Then:

1. Validate that key identifies a generated or explicit instance.
2. End the old series on key.originalDate.previousDay only when at least one historical instance/explicit exception remains before the boundary; when splitting or deleting at the first occurrence, remove the empty old series instead of creating endDate < startDate.
3. For a non-delete future mutation, create the split series with the caller-supplied newSeriesID and boundary start. The explicit ID keeps the value transform deterministic and makes retries idempotent.
4. When patch.displayedDate is present, compute dayDelta = destination - originalDate, shift weekdays modulo seven, start/end dates, future exception dates and future completion keys by the same civil-day delta; apply the remaining fields in the same returned graph so a date+content edit is one transaction.
5. Migrate future explicit exceptions to the new series ID even if the new weekdays do not naturally generate their dates, but only when the mapped originalDate lies within the new series' inclusive start/end bounds; shortening endDate removes exception/skipped/completion state beyond the new end.
6. For a task series, migrate a future completion only when its mapped key is still naturally generated by the new weekday/bounds or is backed by a migrated modified task exception. Drop completions for skipped/nonexistent instances. A kind change to event drops all boundary/future completions. Always rewrite both the completion dictionary key and embedded OccurrenceCompletion.key.
7. Keep all keys before the boundary unchanged.
8. For delete, remove every instance/exception/completion at or after the boundary and do not create a future series. onlyThis delete writes skipped and removes that same key's completion atomically.

The engine must never mutate its input graph in place; return a new graph so CalendarReducer can register one atomic undo snapshot.

- [ ] **Step 4: Run focused and full tests**

Run: zsh Scripts/test.sh --filter SeriesMutationEngineTests

Expected: all mutation tests pass.

Run: swift test

Expected: all tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/CalendarDomain/SeriesMutationEngine.swift Tests/CalendarDomainTests/SeriesMutationEngineTests.swift
git commit -m "feat: 完成重复系列变更语义"
~~~

---

### Task 4: Add pure application state, commands, projections and atomic undo inputs

**Deliverable:** Every user-visible mutation is a pure CalendarState -> CalendarState command with validated category references and month/day projections.

**Files:**
- Create: Sources/CalendarDomain/CalendarState.swift
- Create: Sources/CalendarDomain/CalendarCommand.swift
- Create: Sources/CalendarDomain/CalendarReducer.swift
- Create: Sources/CalendarDomain/MonthProjection.swift
- Test: Tests/CalendarDomainTests/CalendarReducerTests.swift

**Interfaces:**

~~~swift
public struct CalendarState: Codable, Equatable, Sendable {
    public var categories: [UUID: CalendarCategory]
    public var items: [UUID: CalendarItem]
    public var recurrence: RecurrenceGraph
    public let uncategorizedID: UUID
    public init(
        categories: [UUID: CalendarCategory],
        items: [UUID: CalendarItem],
        recurrence: RecurrenceGraph,
        uncategorizedID: UUID
    )
    public static func empty(uncategorizedID: UUID, now: Date) -> CalendarState
}

public enum CalendarCommand: Sendable {
    case createItem(CalendarItem)
    case updateItem(CalendarItem)
    case deleteItem(UUID)
    case moveItem(UUID, to: CalendarDate)
    case setTaskCompleted(UUID, Date?)
    case setOccurrenceCompleted(OccurrenceKey, Date?)
    case createSeries(WeeklySeries)
    case mutateSeries(
        OccurrenceKey,
        scope: SeriesScope,
        edit: SeriesEdit,
        newSeriesID: UUID
    )
    case createCategory(CalendarCategory)
    case updateCategory(CalendarCategory)
    case reorderCategories([UUID])
    case deleteCategory(UUID, migrateTo: UUID)
}

public enum ReducerError: Error, Equatable, Sendable {
    case missingItem
    case missingSeries
    case unknownCategory
    case duplicateCategoryName
    case invalidCategoryColor
    case invalidCategoryOrder
    case protectedCategory
    case invalidMigrationTarget
    case eventCannotComplete
    case invalidState
}

public enum CalendarReducer {
    public static func reduce(
        _ state: CalendarState,
        command: CalendarCommand,
        now: Date
    ) throws -> CalendarState
}

public enum CalendarStateValidator {
    public static func validate(_ state: CalendarState) throws
}

public struct MonthProjection: Equatable, Sendable {
    public let days: [ProjectedDay]
    public static func make(
        monthContaining date: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>
    ) -> MonthProjection
    public func day(_ date: CalendarDate) -> ProjectedDay
}

public struct ProjectedDay: Equatable, Sendable {
    public let date: CalendarDate
    public let items: [ProjectedItem]
}

public enum ProjectedItem: Identifiable, Equatable, Sendable {
    case item(CalendarItem)
    case occurrence(CalendarOccurrence)
    public var id: String { get }
    public var displayedDate: CalendarDate { get }
    public var title: String { get }
    public var kind: ItemKind { get }
    public var categoryID: UUID { get }
    public var timeRange: LocalTimeRange? { get }
    public var creationTimeZoneIdentifier: String { get }
    public var completedAt: Date? { get }
    public var createdAt: Date { get }
}
~~~

- [ ] **Step 1: Write failing reducer tests**

Create this fixture helper at the bottom of CalendarReducerTests.swift:

~~~swift
private struct CategoryReferenceFixture {
    let state: CalendarState
    let deletedCategoryID: UUID
    let targetCategoryID: UUID
}

private func makeCategoryReferenceFixture() throws -> CategoryReferenceFixture {
    let deleted = CalendarCategory(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
        name: "工作",
        colorHex: "#4F7FFF",
        sortIndex: 1,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let target = CalendarCategory(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
        name: "生活",
        colorHex: "#53A66F",
        sortIndex: 2,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let uncategorized = CalendarCategory(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000300")!,
        name: "未分类",
        colorHex: "#8E8E93",
        sortIndex: 0,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let item = try CalendarItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
        kind: .task,
        title: "写方案",
        categoryID: deleted.id,
        date: .init(year: 2026, month: 8, day: 3)!,
        timeRange: nil,
        completedAt: nil,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let series = try WeeklySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
        kind: .event,
        title: "例会",
        categoryID: deleted.id,
        startDate: .init(year: 2026, month: 8, day: 3)!,
        endDate: nil,
        weekdays: [.monday],
        timeRange: nil,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let exceptionKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 10)!
    )
    let exception = OccurrenceOverride(
        displayedDate: exceptionKey.originalDate,
        title: "改期例会",
        kind: .event,
        categoryID: deleted.id,
        timeRange: nil
    )
    return .init(
        state: .init(
            categories: [
                uncategorized.id: uncategorized,
                deleted.id: deleted,
                target.id: target
            ],
            items: [item.id: item],
            recurrence: .init(
                series: [series.id: series],
                exceptions: [exceptionKey: .modified(exception)],
                completions: [:]
            ),
            uncategorizedID: uncategorized.id
        ),
        deletedCategoryID: deleted.id,
        targetCategoryID: target.id
    )
}
~~~

Then add these concrete reducer tests:

~~~swift
@Test func deletingCategoryMigratesEveryReferenceAtomically() throws {
    let fixture = try makeCategoryReferenceFixture()
    let result = try CalendarReducer.reduce(
        fixture.state,
        command: .deleteCategory(
            fixture.deletedCategoryID,
            migrateTo: fixture.targetCategoryID
        ),
        now: .now
    )
    #expect(result.categories[fixture.deletedCategoryID] == nil)
    #expect(result.items.values.allSatisfy { $0.categoryID != fixture.deletedCategoryID })
    #expect(result.recurrence.series.values.allSatisfy {
        $0.categoryID != fixture.deletedCategoryID
    })
    #expect(result.recurrence.exceptions.values.allSatisfy {
        switch $0 {
        case .skipped:
            return true
        case .modified(let override):
            return override.categoryID != fixture.deletedCategoryID
        }
    })
}

@Test func hiddenCategoriesDoNotCountTowardOverflow() throws {
    let fixture = try makeCategoryReferenceFixture()
    var state = fixture.state
    let date = CalendarDate(year: 2026, month: 8, day: 3)!
    for index in 0..<6 {
        let categoryID = index < 3 ? fixture.deletedCategoryID : fixture.targetCategoryID
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "事项 \(index)",
            categoryID: categoryID, date: date, timeRange: nil,
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
        state.items[item.id] = item
    }
    let projection = MonthProjection.make(
        monthContaining: .init(year: 2026, month: 8, day: 1)!,
        state: state,
        hiddenCategoryIDs: [fixture.deletedCategoryID]
    )
    #expect(projection.day(date).items.count == 3)
}
~~~

The same file must contain these exact cases:

| Test function | Required assertion |
| --- | --- |
| completingEventThrows | reduce(.setTaskCompleted(eventID, now)) throws ReducerError.eventCannotComplete and input state remains equal |
| deletingUncategorizedThrows | reduce(.deleteCategory(uncategorizedID, migrateTo: targetID)) throws ReducerError.protectedCategory |
| renamingOrRecoloringUncategorizedThrows | updateCategory changing its protected name or #8E8E93 color throws protectedCategory; reorder alone remains valid |
| movingTimedItemPreservesTimeRange | result date equals destination and timeRange equals original |
| completingOneRecurringTaskDoesNotCompleteNext | setOccurrenceCompleted writes exactly the selected stable key; the next projected occurrence remains incomplete |
| completingRecurringEventThrows | setOccurrenceCompleted on an event occurrence throws ReducerError.eventCannotComplete and state remains equal |
| updatingCompletedTaskToEventClearsCompletion | updateItem changing task -> event atomically sets completedAt nil while preserving id/createdAt; resulting state validates |
| projectionSortsUntimedBeforeTimed | projected IDs equal [untimedID, earlyTimedID, lateTimedID] |
| equalTimeProjectionUsesCreationThenStableID | two equal-time items sort by createdAt, then UUID string |
| validatorAcceptsFirstOccurrenceSplitWithoutOldShell | embed Task 3's first-occurrence split in a category-complete state; validation succeeds and every series has nil end or end >= start |
| validatorAcceptsFilteredFutureCompletionMigration | embed Task 3's weekday/end-date patch graph; validation accepts generated/modified-task completions and rejects injected skipped/nonexistent/event completion keys |

- [ ] **Step 2: Run reducer tests and observe missing-type failures**

Run: zsh Scripts/test.sh --filter CalendarReducerTests

Expected: build fails because CalendarState/Reducer/Projection do not exist.

- [ ] **Step 3: Implement the reducer and projection**

Reducer rules:

- Validate every categoryID before accepting an item/series/override.
- Never delete uncategorizedID.
- deleteCategory must rewrite items, series and modified exceptions in one returned state.
- setTaskCompleted and setOccurrenceCompleted reject events; recurring completions are keyed only by OccurrenceKey.
- Changing a completed one-off task to event clears CalendarItem.completedAt in the same update. Changing only one recurring task occurrence to event removes that key's completion; changing this-and-future to event removes every migrated/future completion while preserving past task completions.
- mutateSeries delegates only to SeriesMutationEngine.
- Preserve createdAt and update only updatedAt on edits.
- Treat CalendarCategory.sortIndex as the only durable ordering authority. create appends max+1; updateCategory preserves the stored index; reorderCategories requires every current category ID exactly once and rewrites all indices to contiguous 0..<count; delete compacts the remaining indices. Validate trimmed, case-insensitively unique category names, #RRGGBB colors, unique contiguous sortIndex values, the protected uncategorized category, every category reference, and every exception/completion series reference. Never maintain a second category-order array.

MonthProjection queries non-recurring items by displayed date and recurrence instances using a range that includes adjacent-month cells. It returns untimed entries first, then timed entries by start, then createdAt and stable ID.

ProjectedItem.id uses disjoint stable strings (`item:<uuid>` and `occurrence:<series-uuid>:<yyyy-mm-dd>`) so a one-off UUID cannot collide with a recurrence key in SwiftUI diffing.

CalendarStateValidator is called after decoding a primary document or backup and after every reducer result. It rechecks every construction invariant even when synthesized Codable bypasses a public initializer: non-empty trimmed titles/names, valid #RRGGBB, valid known time-zone identifiers, paired and increasing times, event-without-completion, non-empty weekdays, end >= start and at least one bounded occurrence. It also requires each categories/items/series dictionary key to equal payload.id, each completion dictionary key to equal OccurrenceCompletion.key, every reference to exist, every exception key.originalDate to lie inside its series' inclusive start/end bounds (weekday mismatch is allowed for an explicit exception and displayedDate may move outside), every completion key to represent a task occurrence or preserved explicit task exception, unique contiguous sortIndex values, and the protected uncategorizedID payload to retain name “未分类” plus neutral color #8E8E93. CalendarDate and MinuteOfDay still use custom Decodable to reject impossible primitive values; all higher-level decoded data must pass this validator before use or rewrite.

- [ ] **Step 4: Run all domain tests**

Run: zsh Scripts/test.sh --filter CalendarReducerTests

Expected: focused tests pass.

Run: swift test

Expected: all domain tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/CalendarDomain/CalendarState.swift Sources/CalendarDomain/CalendarCommand.swift Sources/CalendarDomain/CalendarReducer.swift Sources/CalendarDomain/MonthProjection.swift Tests/CalendarDomainTests/CalendarReducerTests.swift
git commit -m "feat: 建立月历状态与命令归约"
~~~

---

### Task 5: Persist one versioned document and implement safe backup/restore

**Deliverable:** Confirmed state survives process restart; manual backup and restore are versioned, validated and rollback-safe.

**Files:**
- Modify: Package.swift
- Create: Sources/CalendarPersistence/CalendarDocument.swift
- Create: Sources/CalendarPersistence/CalendarRepository.swift
- Create: Sources/CalendarPersistence/JSONCalendarRepository.swift
- Create: Sources/CalendarPersistence/BackupService.swift
- Test: Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift

**Interfaces:**

~~~swift
public struct CalendarDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var state: CalendarState
    public init(schemaVersion: Int = currentSchemaVersion, state: CalendarState)
}

public enum BackupError: Error, Equatable, Sendable {
    case invalidDocument
    case unsupportedSchema(Int)
    case atomicWriteFailed
    case rollbackWriteFailed
}

public protocol CalendarRepository: Sendable {
    func load() async throws -> CalendarState
    func save(_ state: CalendarState) async throws
    func snapshotCurrentDocument(to destination: URL) async throws
}

public protocol AtomicFileWriting: Sendable {
    func replaceAtomically(data: Data, at destination: URL) throws
}

public struct FoundationAtomicFileWriter: AtomicFileWriting {
    public init()
    public func replaceAtomically(data: Data, at destination: URL) throws
}

public actor JSONCalendarRepository: CalendarRepository {
    public init(
        documentURL: URL,
        seed: @escaping @Sendable () -> CalendarState,
        writer: any AtomicFileWriting = FoundationAtomicFileWriter()
    )
    public func load() async throws -> CalendarState
    public func save(_ state: CalendarState) async throws
    public func snapshotCurrentDocument(to destination: URL) async throws
}

public actor BackupService {
    public init(writer: any AtomicFileWriting = FoundationAtomicFileWriter())
    public func export(state: CalendarState, to destination: URL) async throws
    public func validatedState(from source: URL) async throws -> CalendarState
    public func restore(
        from source: URL,
        repository: any CalendarRepository,
        rollbackURL: URL
    ) async throws -> CalendarState
}
~~~

- [ ] **Step 1: Add the persistence target and failing disk tests**

Modify Package.swift to add CalendarPersistence and CalendarPersistenceTests. Tests must use a unique FileManager.default.temporaryDirectory child and remove only that explicit child in teardown.

~~~swift
private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalCalendarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func makePopulatedState() throws -> CalendarState {
    let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000400")!
    var state = CalendarState.empty(
        uncategorizedID: uncategorizedID,
        now: Date(timeIntervalSince1970: 0)
    )
    let item = try CalendarItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
        kind: .task,
        title: "持久化测试",
        categoryID: uncategorizedID,
        date: .init(year: 2026, month: 8, day: 3)!,
        timeRange: nil,
        completedAt: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    state.items[item.id] = item
    let series = try WeeklySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
        kind: .task,
        title: "周复盘",
        categoryID: uncategorizedID,
        startDate: .init(year: 2026, month: 8, day: 3)!,
        endDate: .init(year: 2026, month: 8, day: 31)!,
        weekdays: [.monday, .wednesday],
        timeRange: nil,
        creationTimeZoneIdentifier: "Asia/Shanghai",
        createdAt: Date(timeIntervalSince1970: 0.123456),
        updatedAt: Date(timeIntervalSince1970: 0.123456)
    )
    let modifiedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 10)!
    )
    let skippedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 12)!
    )
    let completedKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 17)!
    )
    state.recurrence = RecurrenceGraph(
        series: [series.id: series],
        exceptions: [
            modifiedKey: .modified(.init(
                displayedDate: .init(year: 2026, month: 8, day: 11)!,
                title: "改期复盘",
                kind: .task,
                categoryID: uncategorizedID,
                timeRange: nil
            )),
            skippedKey: .skipped
        ],
        completions: [
            completedKey: .init(
                key: completedKey,
                completedAt: Date(timeIntervalSince1970: 0.456789)
            )
        ]
    )
    return state
}

@Test func saveThenReopenRoundTripsState() async throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let url = directory.file("calendar.json")
    let expected = try makePopulatedState()
    let empty = CalendarState.empty(
        uncategorizedID: expected.uncategorizedID,
        now: Date(timeIntervalSince1970: 0)
    )
    let writer = JSONCalendarRepository(documentURL: url) { empty }
    try await writer.save(expected)
    let reader = JSONCalendarRepository(documentURL: url) { empty }
    #expect(try await reader.load() == expected)
}

@Test func invalidBackupNeverOverwritesCurrentState() async throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let current = try makePopulatedState()
    let repository = JSONCalendarRepository(
        documentURL: directory.file("calendar.json")
    ) { current }
    try await repository.save(current)
    let badBackup = directory.file("bad-backup.json")
    let rollback = directory.file("rollback.json")
    try Data("not-json".utf8).write(to: badBackup)
    let backup = BackupService()
    await #expect(throws: BackupError.invalidDocument) {
        try await backup.restore(
            from: badBackup,
            repository: repository,
            rollbackURL: rollback
        )
    }
    #expect(try await repository.load() == current)
    #expect(FileManager.default.fileExists(atPath: rollback.path) == false)
}
~~~

The file must also contain these named tests with exact outcomes:

| Test function | Setup | Required assertion |
| --- | --- | --- |
| unknownSchemaDoesNotRewriteFile | write valid JSON with schemaVersion 999 | load throws BackupError.unsupportedSchema(999) and file bytes remain identical |
| missingFileSeedsExactlyOnce | seed closure increments a locked counter; call load twice | counter equals 1 and both states equal |
| validRestoreWritesRollbackBeforeReplacement | save current, restore different valid backup | rollback bytes equal the prior primary document and decode to current; repository loads restored |
| firstRestoreCreatesMissingRollbackDirectory | Rollbacks directory does not exist; restore to a nested timestamped rollback URL | only that parent directory is created, rollback is written, and restored state loads |
| corruptPrimarySnapshotPreservesRawBytes | write invalid raw bytes as primary and use a valid source backup | snapshotCurrentDocument copies the exact corrupt bytes before save; restored primary is valid |
| failedAtomicReplaceKeepsPreviousDocument | save current with FoundationAtomicFileWriter; reopen repository with a test AtomicFileWriting that writes a complete sibling temp file and then throws injectedReplaceFailure before replacement; attempt second save | save throws, original file bytes are unchanged, and a repository using the real writer reopens current |
| fractionalDatesRoundTripWithoutChangingSortOrder | use createdAt 0.123456 and 0.456789 seconds, save/reopen | decoded Date values equal inputs and item ordering is unchanged |
| completeGraphRoundTripsExactly | makePopulatedState contains category, item, weekly series, modified+skipped exceptions and completion | reopened CalendarState equals every nested value exactly |
| decodableDanglingCategoryBackupIsRejected | encode a schema-1 document whose item references a missing category | validatedState/restore throws invalidDocument; primary bytes unchanged and no rollback file exists |
| decodableInvalidRecurrenceBackupIsRejected | construct raw schema-1 JSON variants for empty weekdays, end before start, no occurrence in bounded range, exception/completion pointing to a missing series, exception originalDate outside series bounds, and event completion | every variant is rejected before repository.save; primary bytes and current loaded state remain unchanged |
| decodablePartialOrReversedTimeIsRejected | raw schema-1 JSON contains a missing range endpoint or end <= start | decode/validation rejects and performs no write/rollback |
| decodableConstructorAndIdentityViolationsAreRejected | raw schema-1 variants contain empty title, unknown time zone, category/item/series dictionary key != payload.id, or completion dictionary key != embedded key | every variant throws invalidDocument and leaves primary bytes/current state/rollback unchanged |

- [ ] **Step 2: Run persistence tests**

Run: zsh Scripts/test.sh --filter JSONCalendarRepositoryTests

Expected: build fails because CalendarPersistence does not exist.

- [ ] **Step 3: Implement atomic JSON I/O**

Encode with JSONEncoder using sortedKeys and dates as millisecondsSince1970; decode with the matching strategy. Do not use Foundation's .iso8601 strategy because it drops fractional seconds and can change stable createdAt ordering after restart. FoundationAtomicFileWriter creates a uniquely named sibling temporary file, writes through FileHandle, synchronize()s, closes, and then uses FileManager.replaceItemAt when a destination exists or moveItem when it does not. It removes only its own explicit temp URL on failure and never truncates the live file. AtomicFileWriting is the single deterministic failure seam used by tests; production always receives FoundationAtomicFileWriter. On load:

- Missing file -> call seed exactly once, validate it, atomically persist it, and return the same state.
- Unsupported schema -> throw BackupError.unsupportedSchema.
- Decode/CalendarStateValidator error -> throw without rewriting.

Restore sequence is validate source -> create only rollbackURL's explicit parent directory if missing -> repository.snapshotCurrentDocument(to: rollbackURL) -> repository.save(restored) -> return restored. JSONCalendarRepository snapshots the primary document's raw bytes, so a load-failed/corrupt primary is still preserved before rescue; a normal primary snapshot remains a valid app backup. If rollback creation fails, abort before save. If save fails, the atomic writer leaves the primary bytes unchanged and the rollback remains available.

- [ ] **Step 4: Run persistence and full tests**

Run: zsh Scripts/test.sh --filter JSONCalendarRepositoryTests

Expected: persistence tests pass.

Run: swift test

Expected: all tests pass.

- [ ] **Step 5: Commit**

~~~bash
git add Package.swift Sources/CalendarPersistence Tests/CalendarPersistenceTests
git commit -m "feat: 增加本地原子存储与备份恢复"
~~~

---

### Task 6: 搭建原生应用外壳、滴答清单参考月格与视觉变量

**Deliverable:** A launchable SwiftUI executable displays a native, low-noise 42-cell month grid at desktop and minimum window sizes.

**Files:**
- Modify: Package.swift
- Create: Sources/CalendarApp/PersonalCalendarApp.swift
- Create: Sources/CalendarApp/AppEnvironment.swift
- Create: Sources/CalendarApp/CalendarStore.swift
- Create: Sources/CalendarApp/DesignSystem/CalendarTheme.swift
- Create: Sources/CalendarApp/Month/MonthGridBuilder.swift
- Create: Sources/CalendarApp/Month/MonthViewModel.swift
- Create: Sources/CalendarApp/Month/MonthView.swift
- Create: Sources/CalendarApp/Month/DayCellView.swift
- Create: Sources/CalendarApp/Month/CalendarItemRow.swift
- Test: Tests/CalendarAppTests/MonthGridBuilderTests.swift
- Test: Tests/CalendarAppTests/MonthViewModelTests.swift
- Test: Tests/CalendarAppTests/CalendarStoreTests.swift
- Create: Tests/CalendarAppTests/TestSupport.swift

**Interfaces:**

~~~swift
@MainActor
struct AppEnvironment {
    let store: CalendarStore
    let backupService: BackupService
    static func live() -> AppEnvironment
}

enum StorePhase: Equatable {
    case notLoaded
    case loading
    case ready
    case mutating
    case restoring
    case loadFailed
}

enum StoreError: Error, Equatable {
    case notReady
    case mutationInProgress
    case nothingToUndo
    case persistenceFailed
    case restoreFailed
}

@MainActor
@Observable final class CalendarStore {
    private(set) var state: CalendarState
    private(set) var loadError: String?
    private(set) var mutationError: String?
    private(set) var phase: StorePhase
    var isMutating: Bool { phase == .mutating || phase == .restoring }
    private(set) var canUndo: Bool
    private(set) var undoNotice: String?
    let repository: any CalendarRepository

    init(initialState: CalendarState, repository: any CalendarRepository)
    func load() async
    func send(_ command: CalendarCommand, undoLabel: String?) async throws
    func undo() async throws
    func restore(
        from source: URL,
        using backupService: BackupService,
        rollbackURL: URL
    ) async throws
}

struct MonthCellModel: Identifiable, Equatable {
    let date: CalendarDate
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let items: [ProjectedItem]
    var id: CalendarDate { date }
}

enum MonthGridBuilder {
    static func cells(containing month: CalendarDate) -> [CalendarDate]
}

@MainActor
final class MonthViewModel: ObservableObject {
    @Published private(set) var displayedMonth: CalendarDate
    @Published var selectedDate: CalendarDate?
    @Published private(set) var state: CalendarState
    @Published private(set) var hiddenCategoryIDs: Set<UUID>
    @Published private(set) var today: CalendarDate
    init(
        displayedMonth: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    )
    func cell(for date: CalendarDate) -> MonthCellModel
    func visibleItems(in cell: MonthCellModel, capacity: Int) -> [ProjectedItem]
    func overflowCount(in cell: MonthCellModel, capacity: Int) -> Int
    func update(
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    )
    func goToPreviousMonth()
    func goToNextMonth()
    func goToToday(_ today: CalendarDate)
}

enum MonthLayout {
    static func itemCapacity(cellHeight: CGFloat) -> Int
}
~~~

AppEnvironment.live resolves Application Support/PersonalCalendar/calendar-v1.json, creates that one application directory if missing, and seeds exactly one protected “未分类” category. CalendarStore owns the complete phase machine. load() changes notLoaded -> loading before its first await, then ready only after repository.load; repeated load calls in any other phase are no-ops. send/undo require ready and set mutating before any await. restore is allowed from ready or loadFailed, switches to restoring before awaiting, and uses repository raw-document snapshot semantics when the primary could not decode. Therefore a click during startup or restore cannot reduce from seed state or overwrite a newer document, while a corrupt primary can still be rescued with a valid user backup. send reduces from the published state, saves the candidate, then publishes; when undoLabel is non-nil it also pushes one `(label, beforeState)` snapshot and publishes that label as undoNotice, while a nil label intentionally creates no undo entry. One defer/catch path restores the prior ready phase after any reducer/validator or repository error: reduction failure performs zero save, and every failure leaves published state plus undo stack untouched. undo/restore likewise restore their exact entry phase on failure; undo saves the prior snapshot before publishing and pops only after success. A successful restore sets ready, clears loadError/stale undo, and publishes only after rollback plus repository save succeed; it performs no second disk write. Keep at most 50 snapshots. Ordinary UI actions are enabled only in ready and show loadError/mutationError in a plain-language alert.

- [ ] **Step 1: Add the executable/app-test targets and failing grid tests**

Package.swift adds these exact entries (alongside the existing library products/targets):

~~~swift
products: [
    .library(name: "CalendarDomain", targets: ["CalendarDomain"]),
    .library(name: "CalendarPersistence", targets: ["CalendarPersistence"]),
    .executable(name: "PersonalCalendar", targets: ["CalendarApp"])
],
targets: [
    // Existing CalendarDomain, CalendarPersistence and their tests remain.
    .executableTarget(
        name: "CalendarApp",
        dependencies: ["CalendarDomain", "CalendarPersistence"]
    ),
    .testTarget(
        name: "CalendarAppTests",
        dependencies: [
            "CalendarApp",
            "CalendarDomain",
            "CalendarPersistence",
            .product(name: "Testing", package: "swift-testing")
        ],
        linkerSettings: testingLinkerSettings
    )
]
~~~

Do not rely on SwiftPM's implicit executable product name: every later `--product PersonalCalendar` and packaging path depends on the explicit product above. When editing the real manifest, preserve the Task 1 dependency list and the CalendarPersistence test target rather than literally duplicating array labels.

~~~swift
@Test func august2026ProducesMondayFirstFortyTwoCellGrid() {
    let cells = MonthGridBuilder.cells(
        containing: .init(year: 2026, month: 8, day: 1)!
    )
    #expect(cells.count == 42)
    #expect(cells.first == CalendarDate(year: 2026, month: 7, day: 27)!)
    #expect(cells.last == CalendarDate(year: 2026, month: 9, day: 6)!)
}

@MainActor
@Test func monthViewModelOrdersUntimedBeforeTimedAndComputesOverflow() throws {
    let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000500")!
    var state = CalendarState.empty(
        uncategorizedID: categoryID,
        now: Date(timeIntervalSince1970: 0)
    )
    let date = CalendarDate(year: 2026, month: 8, day: 3)!
    for index in 0..<7 {
        let range = index == 0 ? nil : try LocalTimeRange(
            start: MinuteOfDay(hour: 8 + index, minute: 0)!,
            end: MinuteOfDay(hour: 9 + index, minute: 0)!
        )
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "事项 \(index)",
            categoryID: categoryID, date: date, timeRange: range,
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
        state.items[item.id] = item
    }
    let model = MonthViewModel(
        displayedMonth: date,
        state: state,
        hiddenCategoryIDs: [],
        today: date
    )
    let cell = model.cell(for: date)
    #expect(cell.items.first?.timeRange == nil)
    #expect(model.visibleItems(in: cell, capacity: 4).count == 3)
    #expect(model.overflowCount(in: cell, capacity: 4) == 4)
}
~~~

CalendarStoreTests.swift uses an InMemoryCalendarRepository declared in TestSupport.swift and includes these exact cases:

| Test function | Required assertion |
| --- | --- |
| failedSaveDoesNotPublishOrRegisterUndo | repository injects a save failure; state remains byte-for-byte equal, canUndo is false, mutationError is non-nil |
| failedReductionReturnsReadyWithoutSaveOrUndo | send a stale/missing-category command; reducer throws, phase returns ready, repository save count stays zero, state/canUndo remain unchanged |
| successfulSendPersistsBeforePublishing | repository records saved state; after await send, repository and published state equal the reducer result |
| undoRestoresWholeSnapshotAfterSuccessfulSave | one category delete command migrates all references; one await undo restores the original full state and persisted state |
| concurrentMutationIsRejected | first repository save is suspended; second send throws StoreError.mutationInProgress and cannot overwrite the first candidate |
| sendDuringLoadIsRejected | repository load is suspended after phase becomes loading; send throws StoreError.notReady, performs no save, then loaded disk state wins |
| restoreBlocksSendAndUndo | BackupService restore is suspended before replacement; phase is restoring, send/undo are rejected, then one restored state becomes both persisted and published |
| corruptPrimaryCanRestoreValidBackup | load invalid primary -> loadFailed; restore a valid backup; exact corrupt bytes exist at rollback URL, phase becomes ready, loadError clears, and restored state is persisted/published |

TestSupport.swift also defines @MainActor `makeReadyStore(initialState:) async throws -> (CalendarStore, InMemoryCalendarRepository)`: construct a notLoaded store, await load(), require phase == ready, then return it. InMemoryCalendarRepository implements all three repository methods, including snapshotCurrentDocument by encoding its currently saved CalendarDocument with the production date strategy. Every App test not specifically exercising loading/failed phases must use this helper or explicitly await store.load() before send/undo/drop/category commands.

MonthViewModelTests additionally asserts previous/next month arithmetic, today navigation selecting today, and capacity boundaries. MonthLayout computes max(1, floor((cellHeight - 28 date-header points - 6 bottom-padding points) / 24)); therefore a 91-point minimum-window cell returns 2 and a 116-point normal cell returns 3. capacity counts total row slots: when items exceed capacity, reserve one slot for “还有 N 项”, so capacity 4 with seven visible items renders three items plus “还有 4 项”. MonthView observes CalendarStore.state and the persisted hidden-category set and calls update on either change; update rebuilds the projection so completion, category recolor/deletion and filtering cannot leave stale rows. Add stateUpdateRefreshesProjectedRowsAndColors to assert the same VM reflects an item completion and category color change after update, and hidden-category updates recalculate overflow.

- [ ] **Step 2: Run the tests**

Run: zsh Scripts/test.sh --filter MonthGridBuilderTests

Expected: build fails because CalendarApp and grid types do not exist.

- [ ] **Step 3: Implement app shell and exact visual baseline**

PersonalCalendarApp must open one main window titled “个人月历”:

~~~swift
@MainActor
@main
struct PersonalCalendarApp: App {
    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: .live())
    }

    var body: some Scene {
        Window("个人月历", id: "main-calendar") {
            MonthView(store: environment.store)
                .frame(minWidth: 980, minHeight: 680)
                .task { await environment.store.load() }
        }
        .defaultSize(width: 1180, height: 820)
    }
}
~~~

Use the single-instance Window scene above, not WindowGroup, and do not add a “新建窗口” command. The category-manager Window is the only second window allowed by the V1 information architecture.

CalendarTheme locks these initial tokens:

- toolbarHeight: 52
- weekdayHeaderHeight: 28
- cellPadding: 6
- itemRowHeight: 21
- itemSpacing: 3
- cornerRadius: 5
- monthTitle font: system 17 semibold
- date/item font: system 12
- grid stroke: separator color at 0.55 opacity
- selected day: accent color at 0.10 opacity
- item background: category color at 0.14 opacity
- item accent bar: 3 points, full category color
- completed-task background: category color at 0.07 opacity
- completed-task accent bar: category color at 0.45 opacity
- completed-task text: system secondaryLabelColor plus a checked control; never lower opacity on the entire row

Use system background/label/separator colors so dark mode works. Each row visibly includes a compact category name, optional start time, title, and task checkbox only for tasks. A completed task must be visibly lighter than its incomplete neighbor through the dedicated tokens above while its text still meets 4.5:1 in the rendered light/dark preview; do not apply one blanket opacity that makes text unreadable. Use SF Symbols only for generic navigation; do not copy 滴答清单 icons.

When CalendarState contains no one-off items and no recurrence series, keep the complete usable month grid and place one low-emphasis “点击日期开始创建” hint below the month title. Do not show this hint merely because filters hide all items. It disappears after the first item/series and never becomes a marketing illustration, modal or separate empty-state page.

- [ ] **Step 4: Build and run tests**

Run: zsh Scripts/test.sh --filter MonthGridBuilderTests

Expected: grid tests pass.

Run: zsh Scripts/test.sh --filter MonthViewModelTests

Expected: ordering/overflow tests pass.

Run: zsh Scripts/test.sh --filter CalendarStoreTests

Expected: phase, persistence ordering and atomic undo tests pass.

Run: swift build --product PersonalCalendar

Expected: build completes with no errors under Command Line Tools.

- [ ] **Step 5: Perform the first visual smoke check**

Run: swift run PersonalCalendar

Expected: one native window opens at 1180x820, can resize no smaller than 980x680, shows the current month in a 7x6 grid, Monday first, and has no permanent sidebar.

Stop the process after inspection. Do not call the shell launch alone visual acceptance; record any density defects for Task 10.

- [ ] **Step 6: Commit**

~~~bash
git add Package.swift Sources/CalendarApp Tests/CalendarAppTests/MonthGridBuilderTests.swift Tests/CalendarAppTests/MonthViewModelTests.swift Tests/CalendarAppTests/CalendarStoreTests.swift Tests/CalendarAppTests/TestSupport.swift
git commit -m "feat: 搭建原生月历主界面"
~~~

---

### Task 7: Add quick create, item editing, day drawer and category filtering

**Deliverable:** The three non-overlapping date-cell hotspots perform quick create, open day drawer and edit items; editor validation and filter counts are test-backed.

**Files:**
- Create: Sources/CalendarApp/Editing/ItemDraft.swift
- Create: Sources/CalendarApp/Editing/ItemEditorViewModel.swift
- Create: Sources/CalendarApp/Editing/QuickCreatePopover.swift
- Create: Sources/CalendarApp/Editing/ItemDetailPopover.swift
- Create: Sources/CalendarApp/DayDrawer/DayDrawerViewModel.swift
- Create: Sources/CalendarApp/DayDrawer/DayDrawerView.swift
- Create: Sources/CalendarApp/Categories/CategoryFilterView.swift
- Modify: Sources/CalendarApp/Month/MonthView.swift
- Modify: Sources/CalendarApp/Month/DayCellView.swift
- Test: Tests/CalendarAppTests/ItemEditorViewModelTests.swift
- Modify: Tests/CalendarAppTests/MonthViewModelTests.swift

**Interfaces:**

~~~swift
struct ItemDraft: Equatable {
    var kind: ItemKind
    var title: String
    var categoryID: UUID
    var date: CalendarDate
    var usesTime: Bool
    var start: MinuteOfDay
    var end: MinuteOfDay
    var repeatsWeekly: Bool
    var weekdays: Set<Weekday>
    var recurrenceEndDate: CalendarDate?
}

enum ItemEditorMode: Equatable {
    case create
    case editItem(CalendarItem)
    case editOccurrence(
        series: WeeklySeries,
        key: OccurrenceKey,
        scope: SeriesScope
    )
}

enum ItemEditorError: Error, Equatable {
    case emptyTitle
    case invalidTimeRange
    case emptyWeekdays
    case invalidRecurrenceEnd
    case noOccurrenceInRange
    case invalidEditorMode
}

enum DayCellHitTarget: Equatable {
    case dateNumber
    case emptyArea
    case item(String)
    case overflow
}

enum DayCellAction: Equatable {
    case openDay(CalendarDate)
    case quickCreate(CalendarDate)
    case openItem(String)
}

enum DayCellInteractionRouter {
    static func action(
        for target: DayCellHitTarget,
        date: CalendarDate
    ) -> DayCellAction
}

@MainActor
final class ItemEditorViewModel: ObservableObject {
    let mode: ItemEditorMode
    private let originalDraft: ItemDraft
    @Published var draft: ItemDraft
    @Published private(set) var validationMessage: String?
    init(mode: ItemEditorMode, draft: ItemDraft)
    func makeCommand(
        now: Date,
        newItemID: UUID,
        newSeriesID: UUID,
        timeZoneIdentifier: String
    ) throws -> CalendarCommand
    func makeDeleteCommand(newSeriesID: UUID) throws -> CalendarCommand
}
~~~

- [ ] **Step 1: Write editor and filtering tests**

~~~swift
@Test func untimedDraftCreatesItemWithNoTimeRange() throws {
    let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
    let draft = ItemDraft(
        kind: .task,
        title: "整理桌面",
        categoryID: categoryID,
        date: .init(year: 2026, month: 8, day: 3)!,
        usesTime: false,
        start: MinuteOfDay(hour: 9, minute: 0)!,
        end: MinuteOfDay(hour: 10, minute: 0)!,
        repeatsWeekly: false,
        weekdays: [],
        recurrenceEndDate: nil
    )
    let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
    let vm = ItemEditorViewModel(mode: .create, draft: draft)
    let command = try vm.makeCommand(
        now: Date(timeIntervalSince1970: 0),
        newItemID: itemID,
        newSeriesID: UUID(),
        timeZoneIdentifier: "Asia/Shanghai"
    )
    guard case .createItem(let item) = command else {
        Issue.record("Expected createItem")
        return
    }
    #expect(item.id == itemID)
    #expect(item.timeRange == nil)
    #expect(item.creationTimeZoneIdentifier == "Asia/Shanghai")
}

@Test func editorRejectsReversedTimeWithoutClearingDraft() {
    let draft = ItemDraft(
        kind: .event,
        title: "评审",
        categoryID: UUID(),
        date: .init(year: 2026, month: 8, day: 4)!,
        usesTime: true,
        start: MinuteOfDay(hour: 9, minute: 0)!,
        end: MinuteOfDay(hour: 8, minute: 0)!,
        repeatsWeekly: false,
        weekdays: [],
        recurrenceEndDate: nil
    )
    let vm = ItemEditorViewModel(mode: .create, draft: draft)
    #expect(throws: ItemEditorError.invalidTimeRange) {
        try vm.makeCommand(
            now: .now,
            newItemID: UUID(),
            newSeriesID: UUID(),
            timeZoneIdentifier: "Asia/Shanghai"
        )
    }
    #expect(vm.validationMessage == "结束时间必须晚于开始时间")
    #expect(vm.draft == draft)
}

@Test func recurrenceNeedsAtLeastOneInstanceBeforeInclusiveEnd() {
    let draft = ItemDraft(
        kind: .task,
        title: "周复盘",
        categoryID: UUID(),
        date: .init(year: 2026, month: 8, day: 4)!, // Tuesday
        usesTime: false,
        start: MinuteOfDay(hour: 9, minute: 0)!,
        end: MinuteOfDay(hour: 10, minute: 0)!,
        repeatsWeekly: true,
        weekdays: [.monday],
        recurrenceEndDate: .init(year: 2026, month: 8, day: 8)! // Saturday
    )
    let vm = ItemEditorViewModel(mode: .create, draft: draft)
    #expect(throws: ItemEditorError.noOccurrenceInRange) {
        try vm.makeCommand(
            now: .now,
            newItemID: UUID(),
            newSeriesID: UUID(),
            timeZoneIdentifier: "Asia/Shanghai"
        )
    }
}
~~~

The same file must include these exact cases:

| Test function | Required assertion |
| --- | --- |
| validWeeklyDraftCreatesSeriesNotItem | command is createSeries; weekdays/end date/time zone equal draft/input |
| editingItemPreservesIdentityAndCreationMetadata | command is updateItem with original id/createdAt/time-zone and new content |
| editingCompletedTaskIntoEventClearsCompletion | editItem draft changes kind to event; emitted updateItem keeps identity/creation metadata and has completedAt nil |
| editingOccurrenceCarriesStableKeyAndChosenScope | command is mutateSeries with original OccurrenceKey, chosen SeriesScope, supplied newSeriesID and one SeriesPatch containing the draft changes |
| editingMovedExceptionTitleDoesNotShiftFuturePattern | construct the initial draft from the moved exception's displayed date; change only title, then assert the emitted SeriesPatch.displayedDate is nil and reducing thisAndFuture leaves weekdays unchanged while updating title (do not access the VM's private originalDraft) |
| deletingOneOffItemReturnsDeleteItem | editItem mode returns deleteItem(originalID), and sending it with undoLabel removes once then one store.undo restores the full item |
| deletingOccurrenceUsesChosenScope | makeDeleteCommand returns one mutateSeries delete command with the same stable key/scope |
| completionRouterUsesStableOccurrenceKey | an incomplete item/occurrence maps to its set-completed command with now; an already-completed item/occurrence maps to the same stable ID/key with nil; events map to nil |
| completingAndUncompletingRecurringTaskAreEachUndoable | send completion, send nil cancellation, and after each action one await store.undo restores the exact prior persisted/published state |
| overflowAndDateNumberOpenDayWhileBlankCreates | overflow/dateNumber each return exactly openDay(date); emptyArea returns exactly quickCreate(date); item returns only openItem(id) |
| completionClickDoesNotOpenDetail | completion hit returns only the completion command/action and leaves selected detail ID nil; row-body hit opens detail and emits no completion command |

- [ ] **Step 2: Run focused tests**

Run: zsh Scripts/test.sh --filter ItemEditorViewModelTests

Expected: build fails because editor types do not exist.

- [ ] **Step 3: Implement the three explicit hit regions**

DayCellView must use:

- Date-number Button -> sets selectedDayDrawerDate.
- Empty-cell contentShape Rectangle + tap -> sets quickCreateDate and opens popover.
- CalendarItemRow is an HStack with sibling controls, never a Button nested inside another Button: the task checkbox Button occupies only its own hit region, while a separate row-body Button opens detail. Event rows contain only the row-body Button and do not reserve an empty checkbox hit region.
- Overflow Button titled “还有 N 项” -> sets selectedDayDrawerDate and consumes the click; it never reaches the empty-cell quick-create gesture.

QuickCreatePopover explicitly renders: focused title field; task/event segmented choice; one existing-category picker showing name+color; “具体时间” switch with paired start/end pickers; “每周重复” switch with Monday–Sunday multi-select and optional inclusive end date; Save/Cancel. The category picker's final action opens the independent category-manager Window and does not edit categories inline. Enter calls makeCommand/send, Esc closes without saving. ItemDetailPopover edits in a draft and commits only through Save/Enter. Date-only mode emits nil timeRange even though the transient pickers retain defaults. Weekly repeat creates WeeklySeries instead of a one-off item. New records receive TimeZone.current.identifier; edits preserve their stored creation time zone. ItemEditorViewModel snapshots originalDraft at init and emits a field-wise diff: displayedDate is nil unless the user actually changed the visible date, including when the starting draft came from an already-moved exception. It must not copy every draft field into a patch and accidentally shift a series on a title-only edit.

For a one-off row, ItemDetailPopover exposes Edit and Delete; confirmed Delete sends deleteItem(originalID) with undoLabel “已删除事项”, closes only after save succeeds, and leaves the popover open with an error on failure. For a recurring row, opening details is read-only until Edit or Delete is chosen. That action first presents exactly “仅本次”, “本次及以后”, “取消”; only a non-cancel choice constructs ItemEditorMode.editOccurrence or a delete command. The editor hides weekday/end-date controls under onlyThis and exposes them under thisAndFuture. One Save produces one mutateSeries command, including date and content changes atomically. Every successful delete uses CalendarStore's undo notice; ordinary and recurring deletes restore with one undo.

CategoryFilterView maintains hiddenCategoryIDs in AppStorage as encoded UUID strings. It displays name + color, includes “全部显示”, and triggers a fresh MonthProjection; hidden entries do not count toward overflow.

- [ ] **Step 4: Implement the day drawer**

DayDrawerView opens as an inspector-style trailing overlay, not a new day view. It shows all visible items for one date, untimed first then start time, supports task completion, opening details and quick create. It has no hourly timeline. CalendarItemRow and DayDrawer must both call the same completion router: one-off tasks send setTaskCompleted, recurring tasks send setOccurrenceCompleted with the projected stable key, and events expose no completion control. Clicking an incomplete task sends now; clicking a completed task sends nil, so cancellation is explicit. Each successful completion/cancellation uses CalendarStore.send with one undo snapshot and an undo notice; Task 9 wires Command-Z to that same store undo.

- [ ] **Step 5: Run tests and build**

Run: zsh Scripts/test.sh --filter ItemEditorViewModelTests

Expected: editor tests pass.

Run: zsh Scripts/test.sh --filter MonthViewModelTests

Expected: filter and overflow tests pass.

Run: swift test && swift build --product PersonalCalendar

Expected: all tests and build pass.

- [ ] **Step 6: Commit**

~~~bash
git add Sources/CalendarApp/Editing Sources/CalendarApp/DayDrawer Sources/CalendarApp/Categories/CategoryFilterView.swift Sources/CalendarApp/Month Tests/CalendarAppTests
git commit -m "feat: 完成月历快速创建与详情交互"
~~~

---

### Task 8: Build the independent category manager and atomic migration

**Deliverable:** A separate native window creates, renames, recolors, reorders and safely deletes categories.

**Files:**
- Create: Sources/CalendarApp/Categories/CategoryManagerViewModel.swift
- Create: Sources/CalendarApp/Categories/CategoryManagerView.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Modify: Sources/CalendarApp/CalendarStore.swift
- Test: Tests/CalendarAppTests/CategoryManagerViewModelTests.swift

**Interfaces:**

~~~swift
enum CalendarAppearance: Sendable { case light, dark }

struct CategoryPreviewPalette: Sendable {
    let lightCanvasHex: String
    let lightTextHex: String
    let darkCanvasHex: String
    let darkTextHex: String
    let categoryBackgroundOpacity: Double
    static let production: CategoryPreviewPalette
}

enum CategoryColorValidator {
    static func normalizedHex(_ input: String) throws -> String
    static func itemContrastRatio(
        colorHex: String,
        appearance: CalendarAppearance,
        palette: CategoryPreviewPalette = .production
    ) throws -> Double
    static func validateReadableInBothAppearances(
        _ colorHex: String,
        palette: CategoryPreviewPalette = .production
    ) throws
    static func accentNeedsOutline(
        colorHex: String,
        appearance: CalendarAppearance,
        palette: CategoryPreviewPalette = .production
    ) throws -> Bool
}

enum CategoryManagerError: Error, Equatable {
    case emptyName
    case duplicateName
    case invalidColor
    case insufficientContrast
    case protectedCategory
    case migrationRequired
    case invalidMigrationTarget
}

@MainActor
final class CategoryManagerViewModel: ObservableObject {
    private let store: CalendarStore
    private let previewPalette: CategoryPreviewPalette
    @Published var draftName = ""
    @Published var draftColorHex = "#4F7FFF"
    @Published var categoryToDelete: CalendarCategory?
    @Published var migrationTargetID: UUID?

    init(
        store: CalendarStore,
        previewPalette: CategoryPreviewPalette = .production
    )
    func create() async throws
    func update(_ category: CalendarCategory) async throws
    func reorder(_ ids: [UUID]) async throws
    func deleteConfirmed() async throws
}
~~~

CategoryPreviewPalette.production is exactly light canvas #FFFFFF / text #1D1D1F, dark canvas #1C1C1E / text #F5F5F7, and categoryBackgroundOpacity 0.14. CalendarTheme uses the corresponding system colors at runtime, while this fixed sRGB preview contract makes validation and tests deterministic.

The initial restrained category palette is exactly #4F7FFF, #7A67D8, #D65E73, #D9893D, #53A66F, #2E9DA7, #8A6A4A and #8E8E93; every swatch passes the same light/dark readability and accent-visibility logic as a custom color.

- [ ] **Step 1: Write view-model tests**

Concrete tests must assert:

- Empty/duplicate names are rejected case-insensitively.
- colorHex accepts exactly #RRGGBB and normalizes uppercase.
- Color validation composites the category color at CalendarTheme's 0.14 item-background opacity over the fixed light/dark preview canvases, compares against the matching primary text color with WCAG relative luminance, and requires a ratio >= 4.5 in both appearances.
- The full-color 3pt accent bar is also checked against its adjacent canvas at the WCAG 3:1 non-text threshold; when below 3:1 (for example white in light appearance), CalendarTheme adds a 1pt contrasting separator outline instead of silently rendering an invisible bar.
- uncategorized cannot be renamed, recolored or deleted; only its sort position may change through the shared reorder action.
- delete cannot proceed without explicit migration target.
- delete/reassign changes every reference in one store state.
- choosing “转入未分类” passes state.uncategorizedID as the explicit migration target and leaves no dangling item/series/modified-exception reference.
- undo restores category order, category and all references in one action.

~~~swift
@Test func deleteRequiresExplicitMigrationChoice() async throws {
    let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
    var state = CalendarState.empty(
        uncategorizedID: uncategorizedID,
        now: Date(timeIntervalSince1970: 0)
    )
    let work = CalendarCategory(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
        name: "工作",
        colorHex: "#4F7FFF",
        sortIndex: 1,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    state.categories[work.id] = work
    let repository = InMemoryCalendarRepository(initialState: state)
    let store = CalendarStore(initialState: state, repository: repository)
    await store.load()
    let vm = CategoryManagerViewModel(store: store)
    vm.categoryToDelete = work
    vm.migrationTargetID = nil
    await #expect(throws: CategoryManagerError.migrationRequired) {
        try await vm.deleteConfirmed()
    }
    #expect(store.state == state)
}
~~~

InMemoryCalendarRepository is the concrete actor declared in CalendarAppTests/TestSupport.swift in Task 6; its initialState, savedState and injected failure/suspension controls are explicit test-only state, not a production mock path. CategoryManagerViewModelTests must call the real CalendarStore/CalendarReducer. The deletion/undo test awaits vm.deleteConfirmed(), then awaits store.undo(), and compares the full state plus repository.savedState to the exact original state.

Add readabilityForCustomColorMatchesRenderedTheme: normalize a fixed custom #7f53ac to #7F53AC, assert light and dark itemContrastRatio are each >= 4.5, and assert CalendarTheme uses those same canvas/text/background-alpha constants. Add extremeAccentColorsReceiveVisibleOutline: #FFFFFF needs an outline in light appearance and #000000 needs one in dark appearance; the opposite appearance still has >= 3:1 direct contrast. Add unreadableColorDoesNotCommit by injecting a test preview palette whose text/background pair produces < 4.5; CategoryColorValidator throws CategoryManagerError.insufficientContrast and the store receives no command. The production palette is not weakened to make this negative test pass—inject only the preview constants, not the validation outcome.

- [ ] **Step 2: Run failing tests**

Run: zsh Scripts/test.sh --filter CategoryManagerViewModelTests

Expected: build fails because CategoryManagerViewModel does not exist.

- [ ] **Step 3: Implement the independent Window**

Add:

~~~swift
Window("分类管理", id: "category-manager") {
    CategoryManagerView(store: environment.store)
        .frame(minWidth: 440, minHeight: 520)
}
~~~

The toolbar entry uses openWindow(id: "category-manager"). CategoryManagerView includes default palette swatches plus SwiftUI ColorPicker with supportsOpacity false, a live light/dark preview driven by the same CalendarTheme compositing constants, drag handles for reordering, and a delete confirmation requiring either another category or “未分类”. When “未分类” is selected, name/color/delete controls are disabled with a short protected-system-category explanation; its row remains draggable for ordering. On every editable swatch/picker change, show the two computed contrast results; disable Save and show a plain-language reason if either is below 4.5. Do not place full category editing inside quick create.

- [ ] **Step 4: Run tests and visual smoke**

Run: zsh Scripts/test.sh --filter CategoryManagerViewModelTests

Expected: tests pass.

Run: swift test && swift build --product PersonalCalendar

Expected: every existing test passes and PersonalCalendar builds successfully.

Launch with swift run PersonalCalendar and verify the category window opens independently, main month remains usable, and changing a color updates existing rows immediately.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/CalendarApp/Categories Sources/CalendarApp/PersonalCalendarApp.swift Sources/CalendarApp/CalendarStore.swift Tests/CalendarAppTests/CategoryManagerViewModelTests.swift
git commit -m "feat: 增加独立分类管理窗口"
~~~

---

### Task 9: Add date drag/drop, recurrence scope confirmation and Command-Z integration

**Deliverable:** One-off and recurring rows drag safely across dates; scope choices and Command-Z operate atomically.

**Files:**
- Create: Sources/CalendarApp/DragDrop/CalendarItemTransfer.swift
- Create: Sources/CalendarApp/DragDrop/CalendarDropCoordinator.swift
- Modify: Sources/CalendarApp/CalendarStore.swift
- Modify: Sources/CalendarApp/Month/CalendarItemRow.swift
- Modify: Sources/CalendarApp/Month/DayCellView.swift
- Modify: Sources/CalendarApp/Month/MonthView.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Test: Tests/CalendarAppTests/CalendarDropCoordinatorTests.swift

**Interfaces:**

~~~swift
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let personalCalendarItem = UTType(
        exportedAs: "com.oreal.personalcalendar.item"
    )
}

enum CalendarTransferPayload: Codable, Transferable {
    case item(UUID)
    case occurrence(OccurrenceKey)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .personalCalendarItem)
    }
}

struct PendingRecurringDrop: Equatable {
    let key: OccurrenceKey
    let destination: CalendarDate
    let newSeriesID: UUID
}

@MainActor
final class CalendarDropCoordinator: ObservableObject {
    private let store: CalendarStore
    @Published var pendingRecurringDrop: PendingRecurringDrop?
    @Published private(set) var dropTargetDate: CalendarDate?
    init(store: CalendarStore)
    func setTargeted(_ isTargeted: Bool, date: CalendarDate)
    func accept(_ payload: CalendarTransferPayload, on date: CalendarDate) async throws
    func resolve(scope: SeriesScope) async throws
    func cancel()
}
~~~

- [ ] **Step 1: Write drag and undo tests**

~~~swift
@Test func oneOffDropPreservesTimeAndRegistersOneUndo() async throws {
    let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
    var original = CalendarState.empty(
        uncategorizedID: uncategorizedID,
        now: Date(timeIntervalSince1970: 0)
    )
    let originalRange = try LocalTimeRange(
        start: MinuteOfDay(hour: 9, minute: 0)!,
        end: MinuteOfDay(hour: 10, minute: 0)!
    )
    let item = try CalendarItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!,
        kind: .task,
        title: "专注时段",
        categoryID: uncategorizedID,
        date: .init(year: 2026, month: 8, day: 3)!,
        timeRange: originalRange,
        creationTimeZoneIdentifier: "Asia/Shanghai",
        completedAt: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    original.items[item.id] = item
    let repository = InMemoryCalendarRepository(initialState: original)
    let store = CalendarStore(initialState: original, repository: repository)
    await store.load()
    let coordinator = CalendarDropCoordinator(store: store)
    try await coordinator.accept(
        .item(item.id),
        on: .init(year: 2026, month: 8, day: 8)!
    )
    #expect(store.state.items[item.id]?.date ==
        CalendarDate(year: 2026, month: 8, day: 8)!)
    #expect(store.state.items[item.id]?.timeRange == originalRange)
    try await store.undo()
    #expect(store.state == original)
    let persistedAfterUndo = await repository.currentState()
    #expect(persistedAfterUndo == original)
}

@Test func recurringDropWaitsForScopeAndShiftsFuturePattern() async throws {
    let harness = try makeMondayWednesdayDropHarness()
    let repository = InMemoryCalendarRepository(initialState: harness.originalState)
    let store = CalendarStore(
        initialState: harness.originalState,
        repository: repository
    )
    await store.load()
    let coordinator = CalendarDropCoordinator(store: store)
    try await coordinator.accept(
        .occurrence(harness.boundaryMonday),
        on: harness.destinationTuesday
    )
    let pending = try #require(coordinator.pendingRecurringDrop)
    #expect(store.state == harness.originalState)
    try await coordinator.resolve(scope: .thisAndFuture)

    let future = try #require(store.state.recurrence.series[pending.newSeriesID])
    #expect(future.weekdays == [.tuesday, .thursday])
    let shiftedExceptionKey = OccurrenceKey(
        seriesID: pending.newSeriesID,
        originalDate: harness.futureExceptionKey.originalDate.addingDays(1)
    )
    guard case .some(.modified(let shiftedOverride)) =
        store.state.recurrence.exceptions[shiftedExceptionKey] else {
        Issue.record("Expected shifted modified exception")
        return
    }
    #expect(shiftedOverride.displayedDate ==
        harness.futureExceptionDisplayedDate.addingDays(1))
    let shiftedCompletionKey = OccurrenceKey(
        seriesID: pending.newSeriesID,
        originalDate: harness.futureCompletionKey.originalDate.addingDays(1)
    )
    #expect(store.state.recurrence.completions[shiftedCompletionKey]?.key ==
        shiftedCompletionKey)
    #expect(store.state.recurrence.completions[shiftedCompletionKey]?.completedAt ==
        harness.futureCompletedAt)
    #expect(store.state.recurrence.exceptions[harness.futureExceptionKey] == nil)
    #expect(store.state.recurrence.completions[harness.futureCompletionKey] == nil)
    #expect(store.state.recurrence.exceptions[harness.pastExceptionKey] ==
        harness.originalState.recurrence.exceptions[harness.pastExceptionKey])
    #expect(store.state.recurrence.completions[harness.pastCompletionKey] ==
        harness.originalState.recurrence.completions[harness.pastCompletionKey])

    try await store.undo()
    #expect(store.state == harness.originalState)
    let persistedAfterUndo = await repository.currentState()
    #expect(persistedAfterUndo == harness.originalState)
}
~~~

Define makeMondayWednesdayDropHarness() in CalendarDropCoordinatorTests.swift with fixed UUIDs. It creates a task series starting Monday 2026-08-03 with weekdays Monday/Wednesday; boundaryMonday is 2026-08-10, destinationTuesday is 2026-08-11, futureExceptionKey is Monday 2026-08-17 with a modified displayed date of Tuesday 2026-08-18, and futureCompletionKey is Wednesday 2026-08-19 with a fixed futureCompletedAt. Also seed a past modified exception on 2026-08-05 and a past completion on 2026-08-03. Store these keys/values plus the complete originalState in a concrete DropHarness struct so the assertions above compile without hidden global fixtures.

- [ ] **Step 2: Run failing tests**

Run: zsh Scripts/test.sh --filter CalendarDropCoordinatorTests

Expected: build fails because drag/drop types do not exist.

- [ ] **Step 3: Implement Transferable and drop coordinator**

Use SwiftUI draggable/dropDestination. Its isTargeted callback sets only transient dropTargetDate; the target cell gets an accent 0.16 overlay plus the visible date label “移到 8月11日”. Leaving clears that state. hoverTargetShowsFeedbackWithoutMutation asserts repeated target enter/leave changes only the transient target date and repository save count remains zero. A one-off drop sends moveItem immediately. A recurring drop allocates newSeriesID once, stores PendingRecurringDrop and presents one confirmation dialog with “仅本次”, “本次及以后”, “取消”; only resolution sends mutateSeries with SeriesEdit.patch(displayedDate: destination) and that stored ID. Cancellation clears pending state without a write.

PersonalCalendarApp replaces the Undo command group with a button titled “撤销”, keyboard shortcut Command-Z, disabled when !store.canUndo || store.isMutating; its action awaits store.undo(). MonthView shows store.undoNotice as a lightweight transient banner with a visible “撤销” button calling the same async method. Do not use UndoManager callbacks: CalendarStore's save-before-publish snapshot stack from Task 6 is the single undo implementation for main and category windows.

- [ ] **Step 4: Run tests and keyboard smoke**

Run: zsh Scripts/test.sh --filter CalendarDropCoordinatorTests

Expected: all drag tests pass.

Run: swift test

Expected: all tests pass.

Launch app, move one task, press Command-Z, and confirm one keypress restores date. Repeat for category deletion and this-and-future series move; each must restore in one keypress.

- [ ] **Step 5: Commit**

~~~bash
git add Sources/CalendarApp/DragDrop Sources/CalendarApp/CalendarStore.swift Sources/CalendarApp/Month Sources/CalendarApp/PersonalCalendarApp.swift Tests/CalendarAppTests/CalendarDropCoordinatorTests.swift
git commit -m "feat: 完成月历拖拽与原子撤销"
~~~

---

### Task 10: Add backup UI, package the app and execute the complete acceptance gate

**Deliverable:** A signed local .app bundle can export/restore its own data and passes automated, visual, failure and restart acceptance.

**Files:**
- Create: Sources/CalendarApp/Backup/BackupCommands.swift
- Modify: Sources/CalendarApp/PersonalCalendarApp.swift
- Create: Support/Info.plist
- Create: Scripts/build-app.sh
- Create: docs/validation/calendar-v1/acceptance.md
- Modify: .gitignore

**Interfaces:**

~~~swift
@MainActor
struct BackupCommands: Commands {
    let store: CalendarStore
    let backupService: BackupService
}
~~~

- [ ] **Step 1: Add backup commands with explicit failure behavior**

Add File menu commands:

- “导出备份…” -> NSSavePanel -> BackupService.export.
- “恢复备份…” -> NSOpenPanel -> validatedState -> show “当前数据 → 备份数据” counts for categories/items/series, state that restore replaces the complete current document, and show the exact rollback path -> confirm -> CalendarStore.restore (which revalidates inside BackupService before the write). In loadFailed, show “当前数据无法读取” instead of invented counts.
- Restore validation failure displays a plain-language alert and does not call repository.save.
- CalendarStore holds its mutation guard through rollback creation and repository save; successful restore publishes once after repository save succeeds, clears stale undo, and does not write the document twice.
- Before the first restore, create the explicit Application Support/PersonalCalendar/Rollbacks directory with intermediate directories; restore creates a timestamp+UUID rollback file there so names cannot collide.

Enable Export only when store.phase == .ready; enable Restore when phase is ready or loadFailed so a corrupt primary can be rescued. Export snapshots store.state on MainActor before awaiting disk I/O. Restore remains disabled until the selected file has validated and the user confirms; no other mutation is admitted once store enters restoring. In loadFailed, the confirmation explains that the unreadable primary's exact raw bytes will be preserved at the shown rollback path before replacement.

CalendarStoreTests adds invalidSemanticRestoreKeepsMemoryDiskAndRollbackUntouched: begin from a populated stored state, choose a schema-1 backup with a dangling category reference, call store.restore, assert the thrown error, exact published state, exact primary bytes, canUndo value and absence of the proposed rollback URL. Add successfulRestorePublishesOnceAndClearsUndo: seed one undo entry, restore a complete recurrence graph while the Rollbacks directory is initially absent, assert repository and store equal restored, the directory was created, rollback equals pre-restore state, and canUndo is false. The corruptPrimaryCanRestoreValidBackup test from Task 6 covers the loadFailed rescue UI/store path.

No import wording may mention 滴答清单 or generic ICS; this is own-format backup only.

- [ ] **Step 2: Add app metadata and deterministic packaging**

Support/Info.plist must declare:

~~~xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PersonalCalendar</string>
  <key>CFBundleIdentifier</key><string>com.oreal.personalcalendar</string>
  <key>CFBundleName</key><string>个人月历</string>
  <key>CFBundleDisplayName</key><string>个人月历</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
~~~

Scripts/build-app.sh:

~~~bash
#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
DIST_DIR="$PROJECT_DIR/dist"

cd "$PROJECT_DIR"
swift build -c release --product PersonalCalendar
BIN_DIR=$(swift build -c release --show-bin-path)
if [[ -L "$DIST_DIR" ]]; then
  echo "Refusing symlinked dist directory: $DIST_DIR" >&2
  exit 2
fi
mkdir -p "$DIST_DIR"
DIST_REAL=$(cd "$DIST_DIR" && pwd -P)
[[ "$DIST_REAL" == "$PROJECT_DIR/dist" ]] || {
  echo "Unexpected physical dist path: $DIST_REAL" >&2
  exit 2
}
APP_DIR="$DIST_REAL/个人月历.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
[[ "$APP_DIR" == "$PROJECT_DIR/dist/个人月历.app" ]] || {
  echo "Unexpected app output path: $APP_DIR" >&2
  exit 2
}
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_DIR/PersonalCalendar" "$MACOS_DIR/PersonalCalendar"
cp "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/PersonalCalendar"
plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
~~~

The destructive rm target is the explicit, physical dist/个人月历.app path assembled from the checked-in script directory, never a symlink, home/workspace root or unresolved external variable. Add a packaging regression shell check that replaces a temporary copy's dist with a symlink to a sentinel directory; build-app.sh must exit 2 and the sentinel 个人月历.app remains byte-for-byte untouched.

- [ ] **Step 3: Run all automated gates**

Run: swift test

Expected: every Domain, Persistence and App test passes.

Run: swift build -c release --product PersonalCalendar

Expected: release build passes.

Run: zsh Scripts/build-app.sh

Expected: prints the absolute dist/个人月历.app path after plist and code-sign verification pass.

Run: open "dist/个人月历.app"

Expected: packaged app opens, not only swift run.

- [ ] **Step 4: Execute the full product acceptance matrix**

Create docs/validation/calendar-v1/acceptance.md with one row per specification acceptance item and columns: scenario, expected, automated evidence, manual evidence, result. Execute all 18 scenarios from spec section 11, including:

- weekly start/end inclusive boundary;
- only-this stable identity;
- this-and-future split, exception migration and Monday/Wednesday -> Tuesday/Thursday shift;
- atomic undo after series move and category deletion;
- three date-cell hit regions;
- filtered overflow recount;
- invalid time;
- restart persistence;
- invalid backup non-overwrite and valid rollback restore.

No row may be marked PASS from code inspection alone when the requirement is visual or runtime.

- [ ] **Step 5: Perform visual/product-experience review**

Capture and inspect these four screenshots from the packaged app:

- docs/validation/calendar-v1/light-1180x820.png
- docs/validation/calendar-v1/dark-1180x820.png
- docs/validation/calendar-v1/light-980x680.png
- docs/validation/calendar-v1/dark-980x680.png

Capture these interaction states as separate evidence rather than inferring them from the four base screenshots:

- docs/validation/calendar-v1/quick-create-focus-light.png — popover anchored to a date cell with title focus ring/caret.
- docs/validation/calendar-v1/day-drawer-980x680.png — overflow cell and its full day drawer at minimum size.
- docs/validation/calendar-v1/category-manager-previews.png — independent window with simultaneous light/dark color previews and contrast values.
- docs/validation/calendar-v1/recurring-scope-dialog.png — only-this / this-and-future / cancel confirmation over the month grid.

Each of the four base month screenshots must include a six-week month, at least one date-only task, one timed event, one completed task, multiple category colors and one “还有 N 项” cell. The four interaction screenshots contain only the state named in their filename/description and are not required to duplicate the entire base fixture. Across the applicable images, verify:

- 滴答清单式的低噪声信息密度，但不复制其品牌表达；
- visible category name + color;
- task checkbox/event distinction;
- completed task is clearly lower-weight than an adjacent incomplete task, while title/category remain readable at >= 4.5:1 and the event row is unaffected;
- readable adjacent-month dates;
- no clipped title/date at minimum size;
- popovers remain anchored and keyboard focus is obvious;
- dark-mode contrast remains readable.

For every defect, classify it before fixing. A state, ordering, capacity, keyboard-routing or geometry-calculation defect requires a named failing regression test in the relevant existing test file before the fix. A pure visual-token defect that cannot be asserted without snapshot infrastructure requires an acceptance.md entry containing screenshot name, measured symptom, exact token before/after and the recaptured result. Then rerun all tests, rebuild and recapture all affected appearances/sizes. Do not declare completion from the first screenshot.

- [ ] **Step 6: Fresh final review and clean-tree gate**

Dispatch a fresh Sol xhigh overall reviewer against the product spec, implementation plan, code, tests and validation evidence. Fix every P0/P1 finding and run a scoped re-review.

Then run:

~~~bash
git diff --check
swift test
swift build -c release --product PersonalCalendar
zsh Scripts/build-app.sh
git status --short
~~~

Expected: formatting clean; tests/build/package pass; only intentional validation artifacts or known tool-state files remain.

- [ ] **Step 7: Commit the final bounded deliverable**

~~~bash
git add Sources/CalendarApp/Backup Sources/CalendarApp/PersonalCalendarApp.swift Sources/CalendarApp/CalendarStore.swift Support/Info.plist Scripts/build-app.sh .gitignore docs/validation/calendar-v1
git commit -m "feat: 完成个人月历 V1 验收交付"
~~~

---

## Execution Definition

- “设计完成”仅表示规格与本计划获批。
- “实现完成”要求所有计划 Task、自动化测试、打包、主路径、异常路径和恢复路径通过。
- “个人可用”还要求用户在真实数据下连续使用，没有发生数据丢失、重复错位或明显操作阻塞；实现绿色不能替代这一结论。
- 本计划不授权第二阶段灵感/材料能力，也不创建其占位页面。

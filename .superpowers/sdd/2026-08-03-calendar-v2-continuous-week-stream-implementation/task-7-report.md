# Task 7 — WeekRow 高密度渲染与连续周流

## RED / GREEN

- RED：新增 `WeekRowPresentationTests` 后运行 `Scripts/test.sh --filter WeekRowPresentationTests`。测试因 `WeekRowPresentation`、`WeekRowMetrics`、视口 focus/扩展锚点纯计算尚不存在而按预期编译失败。
- GREEN：实现 `WeekRowView.swift` 的七列周坐标空间、layout-derived presentation、252pt/10 lane 指标及视口帮助器；同一测试通过。
- RED：跨月条目在 9 月 1 日的当天抽屉缺失；旧 `MonthProjection` 只把条目放在一个起始日期。GREEN：抽屉改为使用仅覆盖目标日期的 `TimelineProjection`，跨日 source 在每个覆盖日可见。
- RED：连续周中位于旧 42 格 facade 以外的可见条目不能开启详情。GREEN：`MonthViewModel` 的 lookup 从整个加载周窗口的唯一 timeline 投影构建，旧格子映射仍只保留兼容范围。
- RED：周行 overlay 覆盖时没有可测试的整行 drop column 映射。GREEN：`WeekRowDropTarget` 将横向位置稳定位映射至对应日期，父级 drop destination 覆盖跨日条带。

## 布局、滚动与无障碍合同

- `WeekRowPresentation` 仅从 `WeekLayout` 派生：保留 `WeekSegmentID`/source、连续 start/end column、lane、真实外端 handle 和按日期 overflow；跨周 continuation 由 source schedule 与该周边界推导。
- 一周是共享七列坐标空间：日期头/背景在底层，所有可见 segment 以整段 overlay 渲染。单日与跨日均交给同一 `CalendarItemRow`/完成回调；真正外端显示调整柄，续前/续后显示方向箭头且 VoiceOver 文本明确说明。
- `WeekRowMetrics.itemCapacity(height: 252) == 10`，由 24pt 日期头、21pt lane 和 2pt lane 间距共同计算；较矮周行会减少 capacity，不再按视口除以六。
- `MonthView` 使用固定 weekday header、`ScrollView + LazyVStack(spacing: 0)` 和 stable Monday IDs，默认每行 252pt。导航和今天均以 `ScrollViewReader` 居中目标周；视口中心最近周由纯 `WeekStreamViewport.focusWeek` 更新 focus/title。
- 临近加载窗口边缘时，只有窗口边界行与 viewport/边缘带相交才生成 earlier/later。恢复状态锁定扩展，等待新 window revision 的真实布局帧，再通过 AppKit `NSScrollView` 协调器恢复锚点行的签名 `minY`；新帧确认前不解锁。
- VoiceOver label 包含事项类型、完整分类/标题、完整日期/时间范围、跨周续接和任务完成态；覆盖跨月、跨周、跨年定时范围。视觉紧凑行仍以 schedule 的 startTime 为真相，不读取 V1 `ProjectedItem.timeRange`。
- 日期专属 overflow 留在对应日期头并打开既有当天抽屉；当天抽屉现在列出所有覆盖该日期的 source。

## 验证

- `Scripts/test.sh --filter 'WeekRowPresentationTests|CalendarItemRowPresentationTests|MonthGridBuilderTests|MonthViewModelTests'` — PASS（41 tests / 4 suites）
- `swift build --product PersonalCalendar` — PASS
- `Scripts/test.sh` — PASS（228 tests / 21 suites）
- `git diff --check` — PASS

## Review fix round 1/5

- RED：新增严格边缘相交、新旧 window revision、签名 anchor minY、later append 零位移、far-side trim、重复 preference 锁定与坐标方向测试；旧实现缺少对应合同而编译失败。
- GREEN：生产路径已改为 window-revision 驱动的两阶段恢复状态机，不再使用同步 `scrollTo(.top)` 伪装像素保持。
- 追加 RED：滚动容器尚未 resolve 时，旧状态会提前标记 correction 已应用而永久等待；clamp 只应用部分位移时也缺少进展/恢复语义。
- 追加 GREEN：协调器返回按 flipped/non-flipped 方向归一的真实已应用 viewport delta。未 resolve 不消耗修正机会；成功应用后先等几何帧变化，部分 clamp 继续尝试余量，零进展则明确释放锁，不会永久 wait。

## Review fix round 2/5

- RED：以真实 `NSScrollView` 覆盖排队 correction 的零进展解锁、部分 clamp 后旧帧等待/新帧余量、重复 resolve 仅完成一次，以及旧 token 完成不得解锁；旧接口因 correction/completion 不带 token 且 attach 丢弃结果而按预期编译失败。
- GREEN：每次 correction 绑定唯一 token 与 window revision；恢复状态只接受当前 outstanding token 的完成。协调器无论直达或排队均走同一主线程 completion bridge，并在滚动后读取 `clipView.bounds.origin` 计算真实 applied delta；排队 correction 在成功 apply 前不会被清除，重复 resolve 不会重放。
- 生命周期：`MonthView` 以 `WeekStreamRestorationController` 持有恢复状态，coordinator 通过弱引用回传结果，避免闭包持有环；未收到完成时同一 frame 只保留一个 outstanding correction。
- 验证：聚焦 44 tests / 4 suites、`swift build --product PersonalCalendar`、全量 231 tests / 21 suites 与 `git diff --check` 均通过。

## Concerns

- `MonthGridBuilder` 仅保留为 deprecated 的 V1 compatibility test helper，Task 12 清理；现有 V1 compatibility API 因此仍有既有 deprecation warnings。
- 本任务没有实现 Task 8 的新手势/缩放交互或 Task 11 暖色主题。像素 anchor 状态机、坐标换算和生产 `NSScrollView` 接线已完成程序化验证；实际滚动手感、真实鼠标 DnD/手势和打包应用验收仍需 Task 12。

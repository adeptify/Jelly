import AppKit
import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("WeekRowPresentationTests")
struct WeekRowPresentationTests {
    @Test func todayDateBadgeUsesADotAndAnnouncesOnlyToday() {
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        let presentation = CalendarDateBadgePresentation(
            date: date,
            isToday: true,
            isSelected: false
        )

        #expect(presentation.showsTodayDot)
        #expect(presentation.showsSelectionRing == false)
        #expect(presentation.accessibilityLabel == "8月3日，今天，打开当天事项")
        #expect(presentation.accessibilityValue == "今天")
    }

    @Test func selectedDateBadgeUsesARingAndAnnouncesOnlySelection() {
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        let presentation = CalendarDateBadgePresentation(
            date: date,
            isToday: false,
            isSelected: true
        )

        #expect(presentation.showsTodayDot == false)
        #expect(presentation.showsSelectionRing)
        #expect(presentation.accessibilityLabel == "8月3日，已选中，打开当天事项")
        #expect(presentation.accessibilityValue == "已选中")
    }

    @Test func todayAndSelectedDateBadgeStacksBothMarkersAndBothAnnouncements() {
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        let presentation = CalendarDateBadgePresentation(
            date: date,
            isToday: true,
            isSelected: true
        )

        #expect(presentation.showsTodayDot)
        #expect(presentation.showsSelectionRing)
        #expect(presentation.accessibilityLabel == "8月3日，今天，已选中，打开当天事项")
        #expect(presentation.accessibilityValue == "今天，已选中")
    }

    @Test func ordinaryDateBadgeDoesNotMisreportTodayOrSelection() {
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        let presentation = CalendarDateBadgePresentation(
            date: date,
            isToday: false,
            isSelected: false
        )

        #expect(presentation.showsTodayDot == false)
        #expect(presentation.showsSelectionRing == false)
        #expect(presentation.accessibilityLabel == "8月3日，打开当天事项")
        #expect(presentation.accessibilityValue == "普通日期")
    }

    @Test func productionWeekRowDateCellConsumesBothMarkerAndAccessibilityStates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/CalendarApp/Month/WeekRowView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("let badge = CalendarDateBadgePresentation("))
        #expect(source.contains("if badge.showsTodayDot"))
        #expect(source.contains("if badge.showsSelectionRing"))
        #expect(source.contains(".accessibilityLabel(badge.accessibilityLabel)"))
        #expect(source.contains(".accessibilityValue(badge.accessibilityValue)"))
        #expect(WeekRowMetrics.dateHeaderHeight == 24)
        #expect(WeekRowMetrics.itemCapacity(height: 252) == 10)
    }

    @Test func crossDaySegmentsKeepContinuousColumnsStableIdentityAndTrueOuterEdges() throws {
        let fixture = try makeCrossMonthFixture()
        let layouts = WeekSegmentLayout.make(
            entries: [.item(fixture.item)],
            weekStarts: [fixture.firstWeek, fixture.secondWeek],
            laneCapacity: 10
        )

        let first = try #require(layouts.first)
        let second = try #require(layouts.last)
        let firstSegment = try #require(WeekRowPresentation(layout: first).segment(.item(fixture.item.id)))
        let secondSegment = try #require(WeekRowPresentation(layout: second).segment(.item(fixture.item.id)))

        #expect(firstSegment.id == WeekSegmentID(sourceID: .item(fixture.item.id), weekStart: fixture.firstWeek))
        #expect(firstSegment.source == .item(fixture.item.id))
        #expect(firstSegment.startColumn == 5)
        #expect(firstSegment.endColumn == 6)
        #expect(firstSegment.continuesBefore == false)
        #expect(firstSegment.continuesAfter == true)
        #expect(firstSegment.showsLeadingHandle == true)
        #expect(firstSegment.showsTrailingHandle == false)

        #expect(secondSegment.id == WeekSegmentID(sourceID: .item(fixture.item.id), weekStart: fixture.secondWeek))
        #expect(secondSegment.startColumn == 0)
        #expect(secondSegment.endColumn == 2)
        #expect(secondSegment.continuesBefore == true)
        #expect(secondSegment.continuesAfter == false)
        #expect(secondSegment.showsLeadingHandle == false)
        #expect(secondSegment.showsTrailingHandle == true)
    }

    @Test func fullScreenWeekHeightExposesTenRowsBeforeOverflow() {
        #expect(WeekRowMetrics.itemCapacity(height: 252) == 10)
        #expect(WeekRowMetrics.itemCapacity(height: 210) < 10)
    }

    @Test func accessibilityReadsCompleteRangeAcrossSegments() throws {
        let fixture = try makeCrossMonthFixture()
        let layout = try #require(WeekSegmentLayout.make(
            entries: [.item(fixture.item)],
            weekStarts: [fixture.firstWeek],
            laneCapacity: 10
        ).first)

        let presentation = WeekRowPresentation(
            layout: layout,
            categories: [fixture.category.id: fixture.category]
        )

        #expect(presentation.accessibilityLabel == "待办，工作，产品发布，8月29日至9月2日，延续到下一周，未完成")
        #expect(presentation.segment(.item(fixture.item.id))?.accessibilityLabel
            == "待办，工作，产品发布，8月29日至9月2日，延续到下一周，未完成")
    }

    @Test func continuationAccessibilityNamesFullRangeBothDirectionsAndStableSourceIdentity() throws {
        let fixture = try makeCrossMonthFixture()
        let longItem = try CalendarItem(
            id: fixture.item.id,
            kind: fixture.item.kind,
            title: fixture.item.title,
            categoryID: fixture.item.categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 20)!,
                endDate: CalendarDate(year: 2026, month: 9, day: 12)!,
                startTime: MinuteOfDay(hour: 9, minute: 15)!,
                endTime: MinuteOfDay(hour: 18, minute: 30)!
            ),
            completedAt: Date(timeIntervalSince1970: 1),
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let middleWeek = CalendarDate(year: 2026, month: 8, day: 24)!
        let nextWeek = middleWeek.addingDays(7)
        let layouts = WeekSegmentLayout.make(
            entries: [.item(longItem)],
            weekStarts: [middleWeek, nextWeek],
            laneCapacity: 10
        )
        let firstLayout = try #require(layouts.first)
        let secondLayout = try #require(layouts.last)
        let first = try #require(WeekRowPresentation(
            layout: firstLayout,
            categories: [fixture.category.id: fixture.category]
        ).segment(.item(longItem.id)))
        let second = try #require(WeekRowPresentation(
            layout: secondLayout,
            categories: [fixture.category.id: fixture.category]
        ).segment(.item(longItem.id)))

        #expect(first.accessibilityLabel.contains("8月20日 09:15至9月12日 18:30"))
        #expect(first.accessibilityLabel.contains("从前一周继续"))
        #expect(first.accessibilityLabel.contains("延续到下一周"))
        #expect(first.accessibilityLabel.contains("已完成"))
        #expect(first.accessibilityValue == second.accessibilityValue)
        #expect(first.accessibilityValue == "来源事项 item:\(longItem.id.uuidString)")
    }

    @Test func onlyTrueOuterHandlesExposePurposeAndCurrentDate() throws {
        let fixture = try makeCrossMonthFixture()
        let layouts = WeekSegmentLayout.make(
            entries: [.item(fixture.item)],
            weekStarts: [fixture.firstWeek, fixture.secondWeek],
            laneCapacity: 10
        )
        let firstLayout = try #require(layouts.first)
        let secondLayout = try #require(layouts.last)
        let first = try #require(WeekRowPresentation(layout: firstLayout)
            .segment(.item(fixture.item.id)))
        let second = try #require(WeekRowPresentation(layout: secondLayout)
            .segment(.item(fixture.item.id)))

        #expect(first.leadingHandleAccessibility?.label == "调整开始日期")
        #expect(first.leadingHandleAccessibility?.value == "2026年8月29日")
        #expect(first.trailingHandleAccessibility == nil)
        #expect(second.leadingHandleAccessibility == nil)
        #expect(second.trailingHandleAccessibility?.label == "调整结束日期")
        #expect(second.trailingHandleAccessibility?.value == "2026年9月2日")
    }

    @Test func accessibilityReadsBothDatesAndTimesForAContinuationAcrossYears() throws {
        let category = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000705")!,
            name: "发布",
            colorHex: "#007AFF",
            sortIndex: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000706")!,
            kind: .event,
            title: "跨年值守",
            categoryID: category.id,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 12, day: 31)!,
                endDate: CalendarDate(year: 2027, month: 1, day: 2)!,
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let weekStart = CalendarDate(year: 2026, month: 12, day: 28)!
        let layout = try #require(WeekSegmentLayout.make(
            entries: [.item(item)],
            weekStarts: [weekStart],
            laneCapacity: 10
        ).first)

        let label = WeekRowPresentation(
            layout: layout,
            categories: [category.id: category]
        ).accessibilityLabel

        #expect(label == "日程，发布，跨年值守，2026年12月31日 23:00至2027年1月2日 01:00")
    }

    @Test func focusResolverChoosesTheWeekNearestToViewportCenter() {
        let previous = CalendarDate(year: 2026, month: 8, day: 3)!
        let current = CalendarDate(year: 2026, month: 8, day: 10)!
        let next = CalendarDate(year: 2026, month: 8, day: 17)!

        let focus = WeekStreamViewport.focusWeek(
            in: [
                .init(weekStart: previous, minY: -252, maxY: 0),
                .init(weekStart: current, minY: 0, maxY: 252),
                .init(weekStart: next, minY: 252, maxY: 504)
            ],
            viewportHeight: 600
        )

        #expect(focus == next)
    }

    @Test func centeringBlocksOldAndTemporaryFramesUntilTheCurrentTargetIsCentered() {
        let target = CalendarDate(year: 2026, month: 8, day: 3)!
        let oldRevision = WeekStreamWindowRevision(
            first: target.addingDays(-7),
            last: target.addingDays(7),
            count: 3
        )
        let currentRevision = WeekStreamWindowRevision(
            first: target.addingDays(-364),
            last: target.addingDays(364),
            count: 105
        )
        var state = WeekStreamCenteringState()
        let request = state.begin(weekStart: target, windowRevision: currentRevision)

        #expect(state.blocksViewportUpdates)
        #expect(state.receive(frames: [
            .init(weekStart: target, minY: 258, maxY: 510, windowRevision: oldRevision)
        ], viewportHeight: 768) == .wait)
        let didIssueInitialScroll = state.markScrollIssued(for: request)
        #expect(didIssueInitialScroll)
        #expect(state.receive(frames: [
            .init(weekStart: target, minY: 258, maxY: 510, windowRevision: oldRevision)
        ], viewportHeight: 768) == .wait)
        #expect(state.receive(frames: [
            .init(weekStart: target, minY: 0, maxY: 252, windowRevision: currentRevision)
        ], viewportHeight: 768) == .retry(request))
        #expect(state.blocksViewportUpdates)
        #expect(state.receive(frames: [
            .init(weekStart: target, minY: 258, maxY: 510, windowRevision: currentRevision)
        ], viewportHeight: 768) == .ready)
        #expect(state.blocksViewportUpdates == false)
    }

    @Test func repeatedCenteringRequestsForTheSameTodayTargetAreNeverDeduplicated() {
        let target = CalendarDate(year: 2026, month: 8, day: 3)!
        let revision = WeekStreamWindowRevision(
            first: target.addingDays(-364),
            last: target.addingDays(364),
            count: 105
        )
        let centeredFrames = [WeekRowViewportFrame(
            weekStart: target,
            minY: 258,
            maxY: 510,
            windowRevision: revision
        )]
        var state = WeekStreamCenteringState()
        let first = state.begin(weekStart: target, windowRevision: revision)
        let firstIssueAccepted = state.markScrollIssued(for: first)
        #expect(firstIssueAccepted)
        // A centered Today target can leave preference frames unchanged because scrollTo is a
        // no-op. The cached frame must still release the request.
        #expect(state.receive(frames: centeredFrames, viewportHeight: 768) == .ready)
        #expect(state.blocksViewportUpdates == false)

        let second = state.begin(weekStart: target, windowRevision: revision)
        #expect(first != second)
        let staleIssueAccepted = state.markScrollIssued(for: first)
        let secondIssueAccepted = state.markScrollIssued(for: second)
        #expect(staleIssueAccepted == false)
        #expect(secondIssueAccepted)
        #expect(state.receive(frames: centeredFrames, viewportHeight: 768) == .ready)
        #expect(state.blocksViewportUpdates == false)

        let nextWeek = target.addingDays(7)
        #expect(WeekStreamViewport.focusWeek(
            in: [
                .init(weekStart: target, minY: -128, maxY: 124, windowRevision: revision),
                .init(weekStart: nextWeek, minY: 124, maxY: 376, windowRevision: revision)
            ],
            viewportHeight: 500
        ) == nextWeek)
    }

    @Test func animatedCenteringWaitsForStableFramesWhileReducedMotionSettlesDirectly() {
        let target = CalendarDate(year: 2026, month: 8, day: 3)!
        let revision = WeekStreamWindowRevision(
            first: target.addingDays(-364),
            last: target.addingDays(364),
            count: 105
        )
        let intermediateFrames = [WeekRowViewportFrame(
            weekStart: target,
            minY: 0,
            maxY: 252,
            windowRevision: revision
        )]

        var standardMotion = WeekStreamCenteringState()
        let standardRequest = standardMotion.begin(weekStart: target, windowRevision: revision)
        let animatedIssueAccepted = standardMotion.markScrollIssued(
            for: standardRequest,
            animated: true
        )
        #expect(animatedIssueAccepted)
        #expect(standardMotion.receive(frames: intermediateFrames, viewportHeight: 768) == .wait)
        #expect(standardMotion.blocksViewportUpdates)
        let animationSettled = standardMotion.markAnimationSettled(for: standardRequest)
        #expect(animationSettled)
        #expect(standardMotion.receive(frames: intermediateFrames, viewportHeight: 768)
            == .retry(standardRequest))
        let retryIssueAccepted = standardMotion.markScrollIssued(
            for: standardRequest,
            animated: false
        )
        #expect(retryIssueAccepted)
        #expect(standardMotion.receive(frames: intermediateFrames, viewportHeight: 768) == .wait)

        var reducedMotion = WeekStreamCenteringState()
        let reducedRequest = reducedMotion.begin(weekStart: target, windowRevision: revision)
        let reducedIssueAccepted = reducedMotion.markScrollIssued(
            for: reducedRequest,
            animated: false
        )
        #expect(reducedIssueAccepted)
        #expect(reducedMotion.receive(frames: intermediateFrames, viewportHeight: 768)
            == .retry(reducedRequest))
    }

    @Test func nearLeadingWindowEdgeRequestsExtensionAndPreservesTheVisibleWeekAnchor() {
        let first = CalendarDate(year: 2026, month: 8, day: 3)!
        let second = CalendarDate(year: 2026, month: 8, day: 10)!
        let request = WeekStreamViewport.extensionRequest(
            in: [
                .init(weekStart: first, minY: -180, maxY: 72),
                .init(weekStart: second, minY: 72, maxY: 324)
            ],
            loadedWeekStarts: [first, second],
            viewportHeight: 500
        )

        #expect(request == .init(direction: .earlier, anchor: .init(weekStart: first, pixelOffset: 180)))
        #expect(request?.desiredMinY == -180)
        #expect(WeekStreamViewport.restorationIntent(for: request!.anchor)
            == .init(weekStart: first, pixelOffset: 180))
    }

    @Test func offscreenBoundaryFramesDoNotExtendButAnIntersectingTrailingEdgeDoes() throws {
        let first = CalendarDate(year: 2026, month: 8, day: 3)!
        let middle = CalendarDate(year: 2026, month: 8, day: 10)!
        let last = CalendarDate(year: 2026, month: 8, day: 17)!

        let offscreen = WeekStreamViewport.extensionRequest(
            in: [
                .init(weekStart: first, minY: -1_000, maxY: -748),
                .init(weekStart: last, minY: 1_000, maxY: 1_252)
            ],
            loadedWeekStarts: [first, middle, last],
            viewportHeight: 500
        )
        #expect(offscreen == nil)

        let trailing = try #require(WeekStreamViewport.extensionRequest(
            in: [
                .init(weekStart: middle, minY: 198, maxY: 450),
                .init(weekStart: last, minY: 450, maxY: 702)
            ],
            loadedWeekStarts: [first, middle, last],
            viewportHeight: 500
        ))
        #expect(trailing.direction == .later)
        #expect(trailing.anchor == .init(weekStart: middle, pixelOffset: 0))
        #expect(trailing.desiredMinY == 198)
    }

    @Test func prependRestorationWaitsForNewLayoutAppliesOnceAndUnlocksOnlyAfterConfirmation() throws {
        let anchorWeek = CalendarDate(year: 2026, month: 8, day: 3)!
        let oldRevision = WeekStreamWindowRevision(first: anchorWeek, last: anchorWeek, count: 1)
        let newRevision = WeekStreamWindowRevision(
            first: anchorWeek.addingDays(-364),
            last: anchorWeek,
            count: 53
        )
        let request = WeekStreamExtensionRequest(
            direction: .earlier,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 180),
            desiredMinY: -180
        )
        var restoration = WeekStreamRestorationState()

        let didBegin = restoration.begin(request: request)
        #expect(didBegin)
        restoration.expect(anchor: request.anchor, windowRevision: newRevision)
        #expect(restoration.isLocked)
        #expect(restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: -180, maxY: 72, windowRevision: oldRevision)
        ]) == .wait)

        let correction = try #require(adjustment(from: restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 126, maxY: 378, windowRevision: newRevision)
        ])))
        #expect(correction.windowRevision == newRevision)
        #expect(correction.viewportDeltaY == 306)
        restoration.recordAppliedAdjustment(.init(
            correction: correction,
            appliedViewportDeltaY: 306
        ))
        #expect(restoration.isLocked)
        #expect(restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 126, maxY: 378, windowRevision: newRevision)
        ]) == .wait)
        #expect(restoration.isLocked)

        #expect(restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: -180, maxY: 72, windowRevision: newRevision)
        ]) == .confirmed)
        #expect(restoration.isLocked == false)
    }

    @Test func unresolvedScrollViewLeavesTheCorrectionRetryable() throws {
        let anchorWeek = CalendarDate(year: 2026, month: 8, day: 3)!
        let revision = WeekStreamWindowRevision(first: anchorWeek, last: anchorWeek, count: 1)
        let request = WeekStreamExtensionRequest(
            direction: .earlier,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 180),
            desiredMinY: -180
        )
        let frames = [WeekRowViewportFrame(
            weekStart: anchorWeek,
            minY: 126,
            maxY: 378,
            windowRevision: revision
        )]
        var restoration = WeekStreamRestorationState()

        let didBegin = restoration.begin(request: request)
        #expect(didBegin)
        restoration.expect(anchor: request.anchor, windowRevision: revision)
        let correction = try #require(adjustment(from: restoration.receive(frames: frames)))
        #expect(correction.viewportDeltaY == 306)

        // One correction remains outstanding until its coordinator completion arrives.
        #expect(restoration.receive(frames: frames) == .wait)
        #expect(restoration.isLocked)
    }

    @Test func clampedScrollProgressRetriesTheRemainderThenRecoversWithoutPermanentLock() throws {
        let anchorWeek = CalendarDate(year: 2026, month: 8, day: 3)!
        let revision = WeekStreamWindowRevision(first: anchorWeek, last: anchorWeek, count: 1)
        let request = WeekStreamExtensionRequest(
            direction: .earlier,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            desiredMinY: 0
        )
        var restoration = WeekStreamRestorationState()

        let didBegin = restoration.begin(request: request)
        #expect(didBegin)
        restoration.expect(anchor: request.anchor, windowRevision: revision)
        let firstCorrection = try #require(adjustment(from: restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 200, maxY: 452, windowRevision: revision)
        ])))
        #expect(firstCorrection.viewportDeltaY == 200)
        restoration.recordAppliedAdjustment(.init(
            correction: firstCorrection,
            appliedViewportDeltaY: 50
        ))

        // Do not apply twice while geometry still reports the pre-scroll frame.
        #expect(restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 200, maxY: 452, windowRevision: revision)
        ]) == .wait)
        let remainder = try #require(adjustment(from: restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 150, maxY: 402, windowRevision: revision)
        ])))
        #expect(remainder.viewportDeltaY == 150)
        #expect(remainder.token != firstCorrection.token)
        restoration.recordAppliedAdjustment(.init(
            correction: remainder,
            appliedViewportDeltaY: 0
        ))
        #expect(restoration.isLocked == false)

        var fullyClamped = WeekStreamRestorationState()
        let didBeginFullyClamped = fullyClamped.begin(request: request)
        #expect(didBeginFullyClamped)
        fullyClamped.expect(anchor: request.anchor, windowRevision: revision)
        let clampedCorrection = try #require(adjustment(from: fullyClamped.receive(frames: [
            .init(weekStart: anchorWeek, minY: 200, maxY: 452, windowRevision: revision)
        ])))
        fullyClamped.recordAppliedAdjustment(.init(
            correction: clampedCorrection,
            appliedViewportDeltaY: 0
        ))
        #expect(fullyClamped.isLocked == false)
    }

    @Test func laterAppendWithUnchangedAnchorConfirmsWithoutMovingViewport() {
        let anchorWeek = CalendarDate(year: 2026, month: 8, day: 10)!
        let newRevision = WeekStreamWindowRevision(
            first: CalendarDate(year: 2026, month: 1, day: 5)!,
            last: CalendarDate(year: 2027, month: 8, day: 2)!,
            count: 83
        )
        let request = WeekStreamExtensionRequest(
            direction: .later,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            desiredMinY: 36
        )
        var restoration = WeekStreamRestorationState()

        let didBegin = restoration.begin(request: request)
        #expect(didBegin)
        restoration.expect(anchor: request.anchor, windowRevision: newRevision)

        #expect(restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 36, maxY: 288, windowRevision: newRevision)
        ]) == .confirmed)
        #expect(restoration.isLocked == false)
    }

    @Test func farSideTrimRestoresSignedAnchorPosition() throws {
        let anchorWeek = CalendarDate(year: 2027, month: 8, day: 2)!
        let revision = WeekStreamWindowRevision(
            first: CalendarDate(year: 2026, month: 8, day: 3)!,
            last: CalendarDate(year: 2029, month: 8, day: 6)!,
            count: 157
        )
        let request = WeekStreamExtensionRequest(
            direction: .later,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            desiredMinY: 40
        )
        var restoration = WeekStreamRestorationState()
        let didBegin = restoration.begin(request: request)
        #expect(didBegin)
        restoration.expect(anchor: request.anchor, windowRevision: revision)

        let correction = try #require(adjustment(from: restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: -212, maxY: 40, windowRevision: revision)
        ])))
        #expect(correction.viewportDeltaY == -252)
        restoration.recordAppliedAdjustment(.init(
            correction: correction,
            appliedViewportDeltaY: -252
        ))
        #expect(restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 40, maxY: 292, windowRevision: revision)
        ]) == .confirmed)
    }

    @Test @MainActor func queuedZeroProgressCompletionFlowsBackAndUnlocksExactlyOnce() throws {
        let anchorWeek = CalendarDate(year: 2026, month: 8, day: 3)!
        let revision = WeekStreamWindowRevision(first: anchorWeek, last: anchorWeek, count: 1)
        let restoration = WeekStreamRestorationController()
        let recorder = WeekStreamAdjustmentRecorder()
        let coordinator = WeekStreamScrollCoordinator { [weak restoration] adjustment in
            recorder.record(adjustment)
            restoration?.recordAppliedAdjustment(adjustment)
        }
        let frames = [WeekRowViewportFrame(
            weekStart: anchorWeek,
            minY: 100,
            maxY: 352,
            windowRevision: revision
        )]

        let didBegin = restoration.begin(request: .init(
            direction: .earlier,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            desiredMinY: 0
        ))
        #expect(didBegin)
        restoration.expect(
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            windowRevision: revision
        )
        let correction = try #require(adjustment(from: restoration.receive(frames: frames)))

        coordinator.adjustViewport(correction)
        #expect(recorder.adjustments.isEmpty)

        let harness = makeScrollHarness(documentHeight: 100, viewportHeight: 100, originY: 0)
        coordinator.resolve(from: harness.marker)
        coordinator.resolve(from: harness.marker)

        #expect(recorder.adjustments.count == 1)
        #expect(recorder.adjustments.first?.correction.token == correction.token)
        #expect(recorder.adjustments.first?.appliedViewportDeltaY == 0)
        #expect(restoration.isLocked == false)
    }

    @Test @MainActor func queuedPartialCompletionWaitsForNewFrameThenIssuesOneNewToken() throws {
        let anchorWeek = CalendarDate(year: 2026, month: 8, day: 3)!
        let revision = WeekStreamWindowRevision(first: anchorWeek, last: anchorWeek, count: 1)
        let restoration = WeekStreamRestorationController()
        let recorder = WeekStreamAdjustmentRecorder()
        let coordinator = WeekStreamScrollCoordinator { [weak restoration] adjustment in
            recorder.record(adjustment)
            restoration?.recordAppliedAdjustment(adjustment)
        }
        let oldFrames = [WeekRowViewportFrame(
            weekStart: anchorWeek,
            minY: 100,
            maxY: 352,
            windowRevision: revision
        )]

        #expect(restoration.begin(request: .init(
            direction: .earlier,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            desiredMinY: 0
        )))
        restoration.expect(
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            windowRevision: revision
        )
        let firstCorrection = try #require(adjustment(from: restoration.receive(frames: oldFrames)))
        coordinator.adjustViewport(firstCorrection)

        let harness = makeScrollHarness(documentHeight: 250, viewportHeight: 100, originY: 100)
        let originBefore = harness.scrollView.contentView.bounds.origin.y
        coordinator.resolve(from: harness.marker)
        coordinator.resolve(from: harness.marker)
        let originAfter = harness.scrollView.contentView.bounds.origin.y

        #expect(recorder.adjustments.count == 1)
        #expect(recorder.adjustments.first?.appliedViewportDeltaY == originAfter - originBefore)
        #expect(recorder.adjustments.first?.appliedViewportDeltaY == 50)
        #expect(restoration.receive(frames: oldFrames) == .wait)

        let remainder = try #require(adjustment(from: restoration.receive(frames: [
            .init(weekStart: anchorWeek, minY: 50, maxY: 302, windowRevision: revision)
        ])))
        #expect(remainder.viewportDeltaY == 50)
        #expect(remainder.token != firstCorrection.token)
        #expect(recorder.adjustments.count == 1)
    }

    @Test func staleCorrectionCompletionCannotUnlockOrAdvanceRestoration() throws {
        let anchorWeek = CalendarDate(year: 2026, month: 8, day: 3)!
        let revision = WeekStreamWindowRevision(first: anchorWeek, last: anchorWeek, count: 1)
        let frames = [WeekRowViewportFrame(
            weekStart: anchorWeek,
            minY: 100,
            maxY: 352,
            windowRevision: revision
        )]
        var restoration = WeekStreamRestorationState()
        let didBegin = restoration.begin(request: .init(
            direction: .earlier,
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            desiredMinY: 0
        ))
        #expect(didBegin)
        restoration.expect(
            anchor: .init(weekStart: anchorWeek, pixelOffset: 0),
            windowRevision: revision
        )
        let correction = try #require(adjustment(from: restoration.receive(frames: frames)))
        let stale = WeekStreamScrollCorrection(
            token: .init(),
            windowRevision: revision,
            viewportDeltaY: correction.viewportDeltaY
        )

        restoration.recordAppliedAdjustment(.init(
            correction: stale,
            appliedViewportDeltaY: 0
        ))

        #expect(restoration.isLocked)
        #expect(restoration.receive(frames: frames) == .wait)
        restoration.recordAppliedAdjustment(.init(
            correction: correction,
            appliedViewportDeltaY: 0
        ))
        #expect(restoration.isLocked == false)
    }

    @Test func lockedRestorationRejectsRepeatedExtensionBegins() {
        let week = CalendarDate(year: 2026, month: 8, day: 3)!
        let request = WeekStreamExtensionRequest(
            direction: .earlier,
            anchor: .init(weekStart: week, pixelOffset: 0),
            desiredMinY: 0
        )
        var restoration = WeekStreamRestorationState()

        let firstBegin = restoration.begin(request: request)
        let repeatedBegin = restoration.begin(request: request)
        #expect(firstBegin)
        #expect(repeatedBegin == false)
        #expect(restoration.isLocked)
    }

    @Test @MainActor func farProgrammaticCenteringCancelsOldRestorationAndQueuedCorrection() throws {
        let extensionAnchor = CalendarDate(year: 2026, month: 8, day: 3)!
        let oldRevision = WeekStreamWindowRevision(
            first: extensionAnchor,
            last: extensionAnchor.addingDays(364),
            count: 53
        )
        let farToday = CalendarDate(year: 2027, month: 8, day: 2)!
        let recenteredRevision = WeekStreamWindowRevision(
            first: farToday.addingDays(-364),
            last: farToday.addingDays(364),
            count: 105
        )
        let restoration = WeekStreamRestorationController()
        let recorder = WeekStreamAdjustmentRecorder()
        let coordinator = WeekStreamScrollCoordinator(onAdjustment: recorder.record)
        let extensionRequest = WeekStreamExtensionRequest(
            direction: .earlier,
            anchor: .init(weekStart: extensionAnchor, pixelOffset: 0),
            desiredMinY: 0
        )

        #expect(restoration.begin(request: extensionRequest))
        restoration.expect(anchor: extensionRequest.anchor, windowRevision: oldRevision)
        let correction = try #require(adjustment(from: restoration.receive(frames: [
            .init(weekStart: extensionAnchor, minY: 200, maxY: 452, windowRevision: oldRevision)
        ])))
        coordinator.adjustViewport(correction)
        #expect(restoration.isLocked)
        #expect(recorder.adjustments.isEmpty)

        // A far Today action supersedes the extension before its deferred correction can attach.
        restoration.cancel()
        coordinator.invalidateQueuedCorrection()
        #expect(restoration.isLocked == false)
        #expect(restoration.receive(frames: [
            .init(weekStart: extensionAnchor, minY: 200, maxY: 452, windowRevision: oldRevision)
        ]) == .wait)
        let harness = makeScrollHarness(documentHeight: 1_000, viewportHeight: 100, originY: 200)
        coordinator.resolve(from: harness.marker)
        #expect(recorder.adjustments.isEmpty)

        var centering = WeekStreamCenteringState()
        let todayRequest = centering.begin(
            weekStart: farToday,
            windowRevision: recenteredRevision
        )
        let todayIssueAccepted = centering.markScrollIssued(for: todayRequest)
        #expect(todayIssueAccepted)
        #expect(centering.receive(frames: [
            .init(weekStart: farToday, minY: 258, maxY: 510, windowRevision: recenteredRevision)
        ], viewportHeight: 768) == .ready)
        #expect(centering.blocksViewportUpdates == false)
    }

    @Test func scrollOffsetMathUsesDocumentOrientationAndClamps() {
        #expect(WeekStreamScrollOffset.adjustedOriginY(
            currentOriginY: 100,
            viewportDeltaY: 306,
            documentHeight: 2_000,
            viewportHeight: 500,
            documentIsFlipped: true
        ) == 406)
        #expect(WeekStreamScrollOffset.adjustedOriginY(
            currentOriginY: 400,
            viewportDeltaY: 306,
            documentHeight: 2_000,
            viewportHeight: 500,
            documentIsFlipped: false
        ) == 94)
        #expect(WeekStreamScrollOffset.adjustedOriginY(
            currentOriginY: 1_450,
            viewportDeltaY: 200,
            documentHeight: 2_000,
            viewportHeight: 500,
            documentIsFlipped: true
        ) == 1_500)
        #expect(WeekStreamScrollOffset.appliedViewportDeltaY(
            fromOriginY: 1_450,
            toOriginY: 1_500,
            documentIsFlipped: true
        ) == 50)
        #expect(WeekStreamScrollOffset.appliedViewportDeltaY(
            fromOriginY: 400,
            toOriginY: 94,
            documentIsFlipped: false
        ) == 306)
    }

    @Test func aDropOverAnySegmentColumnResolvesToThatColumnDate() {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!

        #expect(WeekRowDropTarget.date(atX: 0, rowWidth: 700, weekStart: weekStart) == weekStart)
        #expect(WeekRowDropTarget.date(atX: 399, rowWidth: 700, weekStart: weekStart)
            == CalendarDate(year: 2026, month: 8, day: 6)!)
        #expect(WeekRowDropTarget.date(atX: 700, rowWidth: 700, weekStart: weekStart)
            == CalendarDate(year: 2026, month: 8, day: 9)!)
    }

    @Test @MainActor func dayDrawerKeepsAProjectedSpanOnEveryCoveredDate() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
        let coveredDate = CalendarDate(year: 2026, month: 9, day: 1)!
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000704")!,
            kind: .event,
            title: "跨月发布",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 29)!,
                endDate: CalendarDate(year: 2026, month: 9, day: 2)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var state = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        state.items[item.id] = item

        let drawer = DayDrawerViewModel(date: coveredDate, state: state, hiddenCategoryIDs: [])

        #expect(drawer.items.map(\.id) == ["item:\(item.id.uuidString)"])
    }

    private func makeCrossMonthFixture() throws -> (
        item: CalendarItem,
        category: CalendarCategory,
        firstWeek: CalendarDate,
        secondWeek: CalendarDate
    ) {
        let category = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            name: "工作",
            colorHex: "#007AFF",
            sortIndex: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            kind: .task,
            title: "产品发布",
            categoryID: category.id,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 29)!,
                endDate: CalendarDate(year: 2026, month: 9, day: 2)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        return (
            item,
            category,
            CalendarDate(year: 2026, month: 8, day: 24)!,
            CalendarDate(year: 2026, month: 8, day: 31)!
        )
    }

    private func adjustment(
        from action: WeekStreamRestorationAction
    ) -> WeekStreamScrollCorrection? {
        guard case let .adjustContentOffset(correction) = action else { return nil }
        return correction
    }

    @MainActor
    private func makeScrollHarness(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        originY: CGFloat
    ) -> (scrollView: NSScrollView, marker: NSView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: viewportHeight))
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        let documentView = WeekStreamFlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 100, height: documentHeight)
        )
        let marker = NSView(frame: .zero)
        documentView.addSubview(marker)
        scrollView.documentView = documentView
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: originY))
        return (scrollView, marker)
    }
}

@MainActor
private final class WeekStreamAdjustmentRecorder {
    private(set) var adjustments: [WeekStreamScrollAdjustment] = []

    func record(_ adjustment: WeekStreamScrollAdjustment) {
        adjustments.append(adjustment)
    }
}

private final class WeekStreamFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

import Foundation

public enum WeekSegmentLayout {
    public static func make(
        entries: [ProjectedEntry],
        weekStarts: [CalendarDate],
        laneCapacity: Int
    ) -> [WeekLayout] {
        let uniqueEntries = deduplicatedEntries(entries)
        let uniqueWeekStarts = Array(Set(weekStarts)).sorted()
        return uniqueWeekStarts.map {
            makeWeekLayout(entries: uniqueEntries, weekStart: $0, laneCapacity: max(0, laneCapacity))
        }
    }

    private static func deduplicatedEntries(_ entries: [ProjectedEntry]) -> [ProjectedEntry] {
        var entriesBySource: [ProjectedEntryID: ProjectedEntry] = [:]
        for entry in entries where entriesBySource[entry.id] == nil {
            entriesBySource[entry.id] = entry
        }
        return entriesBySource.values.sorted {
            stableProjectedEntryID($0.id) < stableProjectedEntryID($1.id)
        }
    }

    private static func makeWeekLayout(
        entries: [ProjectedEntry],
        weekStart: CalendarDate,
        laneCapacity: Int
    ) -> WeekLayout {
        let weekEnd = weekStart.addingDays(6)
        let candidates = entries.compactMap { entry -> Candidate? in
            guard entry.schedule.startDate <= weekEnd, weekStart <= entry.schedule.endDate else {
                return nil
            }

            let segmentStart = max(entry.schedule.startDate, weekStart)
            let segmentEnd = min(entry.schedule.endDate, weekEnd)
            return Candidate(
                entry: entry,
                weekStart: weekStart,
                startColumn: weekStart.days(until: segmentStart),
                endColumn: weekStart.days(until: segmentEnd),
                showsLeadingHandle: entry.schedule.startDate >= weekStart,
                showsTrailingHandle: entry.schedule.endDate <= weekEnd
            )
        }
        .sorted(by: candidatePrecedes)

        var occupiedRangesByLane: [[ClosedRange<Int>]] = []
        var visibleSegments: [WeekSegment] = []
        var overflowByDate: [CalendarDate: Int] = [:]

        for candidate in candidates {
            let occupiedRange = candidate.startColumn...candidate.endColumn
            if let lane = occupiedRangesByLane.indices.first(where: {
                occupiedRangesByLane[$0].allSatisfy { !$0.overlaps(occupiedRange) }
            }) {
                occupiedRangesByLane[lane].append(occupiedRange)
                visibleSegments.append(candidate.segment(in: lane))
            } else if occupiedRangesByLane.count < laneCapacity {
                occupiedRangesByLane.append([occupiedRange])
                visibleSegments.append(candidate.segment(in: occupiedRangesByLane.count - 1))
            } else {
                for column in candidate.startColumn...candidate.endColumn {
                    let date = weekStart.addingDays(column)
                    overflowByDate[date, default: 0] += 1
                }
            }
        }

        return WeekLayout(
            weekStart: weekStart,
            segments: visibleSegments,
            overflowByDate: overflowByDate
        )
    }
}

public struct WeekSegmentID: Hashable, Sendable {
    public let sourceID: ProjectedEntryID
    public let weekStart: CalendarDate

    public init(sourceID: ProjectedEntryID, weekStart: CalendarDate) {
        self.sourceID = sourceID
        self.weekStart = weekStart
    }
}

public struct WeekSegment: Identifiable, Equatable, Sendable {
    public let id: WeekSegmentID
    public let source: ProjectedEntryID
    public let entry: ProjectedEntry
    public let startColumn: Int
    public let endColumn: Int
    public let lane: Int
    public let showsLeadingHandle: Bool
    public let showsTrailingHandle: Bool

    public init(
        source: ProjectedEntryID,
        entry: ProjectedEntry,
        weekStart: CalendarDate,
        startColumn: Int,
        endColumn: Int,
        lane: Int,
        showsLeadingHandle: Bool,
        showsTrailingHandle: Bool
    ) {
        self.id = WeekSegmentID(sourceID: source, weekStart: weekStart)
        self.source = source
        self.entry = entry
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.lane = lane
        self.showsLeadingHandle = showsLeadingHandle
        self.showsTrailingHandle = showsTrailingHandle
    }
}

public struct WeekLayout: Equatable, Sendable {
    public let weekStart: CalendarDate
    public let segments: [WeekSegment]
    public let overflowByDate: [CalendarDate: Int]

    public init(
        weekStart: CalendarDate,
        segments: [WeekSegment],
        overflowByDate: [CalendarDate: Int]
    ) {
        self.weekStart = weekStart
        self.segments = segments
        self.overflowByDate = overflowByDate
    }

    public var visibleSegments: [WeekSegment] { segments }
}

private struct Candidate {
    let entry: ProjectedEntry
    let weekStart: CalendarDate
    let startColumn: Int
    let endColumn: Int
    let showsLeadingHandle: Bool
    let showsTrailingHandle: Bool

    func segment(in lane: Int) -> WeekSegment {
        WeekSegment(
            source: entry.id,
            entry: entry,
            weekStart: weekStart,
            startColumn: startColumn,
            endColumn: endColumn,
            lane: lane,
            showsLeadingHandle: showsLeadingHandle,
            showsTrailingHandle: showsTrailingHandle
        )
    }
}

private func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    let leftPriority = segmentPriority(for: lhs.entry)
    let rightPriority = segmentPriority(for: rhs.entry)
    if leftPriority != rightPriority {
        return leftPriority < rightPriority
    }
    if lhs.startColumn != rhs.startColumn {
        return lhs.startColumn < rhs.startColumn
    }
    if lhs.endColumn != rhs.endColumn {
        return lhs.endColumn > rhs.endColumn
    }
    switch (lhs.entry.schedule.startTime, rhs.entry.schedule.startTime) {
    case (nil, .some):
        return true
    case (.some, nil):
        return false
    case let (.some(left), .some(right)) where left != right:
        return left < right
    default:
        break
    }
    if lhs.entry.schedule.startTime == nil,
       rhs.entry.schedule.startTime == nil,
       lhs.entry.schedule.durationDays == 1,
       rhs.entry.schedule.durationDays == 1,
       lhs.entry.untimedRank != rhs.entry.untimedRank {
        return lhs.entry.untimedRank < rhs.entry.untimedRank
    }
    if lhs.entry.createdAt != rhs.entry.createdAt {
        return lhs.entry.createdAt < rhs.entry.createdAt
    }
    return stableProjectedEntryID(lhs.entry.id) < stableProjectedEntryID(rhs.entry.id)
}

private func segmentPriority(for entry: ProjectedEntry) -> Int {
    if entry.schedule.durationDays > 1 {
        return 0
    }
    return entry.schedule.startTime == nil ? 1 : 2
}

private func stableProjectedEntryID(_ id: ProjectedEntryID) -> String {
    switch id {
    case let .item(itemID):
        return "item:\(itemID.uuidString)"
    case let .occurrence(key):
        return "occurrence:\(key.seriesID.uuidString):\(stableDate(key.originalDate))"
    }
}

private func stableDate(_ date: CalendarDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
}

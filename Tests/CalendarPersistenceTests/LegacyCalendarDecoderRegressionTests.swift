import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain

/// These are behavioral ports of seven deleted calendar-persistence
/// assertions.  They intentionally exercise the still-supported V2 ingest
/// boundary rather than merely checking that a new Workspace test has a
/// similar name.
@Suite("LegacyCalendarDecoderRegressionTests")
struct LegacyCalendarDecoderRegressionTests {
    @Test func decodableInvalidRecurrenceBackupIsRejectedBeforeWorkspaceRestoreCanBegin() throws {
        let state = try legacyPopulatedCalendarState()
        let seriesID = try #require(state.recurrence.series.keys.first)
        let invalidDocuments = try [
            legacyV2DocumentData(from: state) { document in
                try mutateLegacySeries(&document, id: seriesID) { $0["weekdays"] = [] }
            },
            legacyV2DocumentData(from: state) { document in
                try mutateLegacySeries(&document, id: seriesID) {
                    $0["recurrenceEndDate"] = ["year": 2026, "month": 8, "day": 2]
                }
            },
            legacyV2DocumentData(from: state) { document in
                try mutateLegacyRecurrence(&document) { recurrence in
                    recurrence["series"] = []
                }
            }
        ]

        for data in invalidDocuments {
            #expect(throws: WorkspacePersistenceError.invalidDocument) {
                _ = try WorkspaceDocumentCodec.decode(data)
            }
        }
    }

    @Test func weeklySeriesDecoderRejectsMissingV2CoreFields() throws {
        let state = try legacyPopulatedCalendarState()
        let series = try #require(state.recurrence.series.values.first)
        var payload = try legacyEncodedDictionary(series)
        payload.removeValue(forKey: "durationDays")

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WeeklySeries.self, from: try legacyJSONData(payload))
        }
    }

    @Test func weeklySeriesDecoderTreatsEveryV2ScheduleKeyAsV2Shape() throws {
        let state = try legacyPopulatedCalendarState()
        let series = try #require(state.recurrence.series.values.first)
        var legacyBase = try legacyEncodedDictionary(series)
        legacyBase["startDate"] = legacyBase.removeValue(forKey: "ruleStartDate")
        legacyBase["endDate"] = legacyBase.removeValue(forKey: "recurrenceEndDate")
        legacyBase.removeValue(forKey: "durationDays")

        var isolatedRecurrenceEnd = legacyBase
        isolatedRecurrenceEnd["recurrenceEndDate"] = ["year": 2026, "month": 8, "day": 31]
        var isolatedStartTime = legacyBase
        isolatedStartTime["startTime"] = ["value": 540]
        var isolatedEndTime = legacyBase
        isolatedEndTime["endTime"] = ["value": 600]

        for payload in [isolatedRecurrenceEnd, isolatedStartTime, isolatedEndTime] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(WeeklySeries.self, from: try legacyJSONData(payload))
            }
        }
    }

    @Test func v2DomainDecodersRejectLegacyAndMixedScheduleRepresentations() throws {
        let state = try legacyPopulatedCalendarState()
        let item = try #require(state.items.values.first)
        let series = try #require(state.recurrence.series.values.first)
        let occurrenceOverride: OccurrenceOverride = try #require(state.recurrence.exceptions.values.compactMap { exception -> OccurrenceOverride? in
            guard case let .modified(value) = exception else { return nil }
            return value
        }.first)

        var legacyItem = try legacyEncodedDictionary(item)
        legacyItem["date"] = ["year": 2026, "month": 8, "day": 3]
        var mixedSeries = try legacyEncodedDictionary(series)
        mixedSeries["startDate"] = mixedSeries["ruleStartDate"]
        mixedSeries["endDate"] = mixedSeries["recurrenceEndDate"]
        var mixedOverride = try legacyEncodedDictionary(occurrenceOverride)
        mixedOverride["displayedDate"] = ["year": 2026, "month": 8, "day": 11]
        mixedOverride["timeRange"] = ["start": ["value": 540], "end": ["value": 600]]

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CalendarItem.self, from: try legacyJSONData(legacyItem))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WeeklySeries.self, from: try legacyJSONData(mixedSeries))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(OccurrenceOverride.self, from: try legacyJSONData(mixedOverride))
        }
    }

    @Test func occurrenceOverrideDecoderRejectsLegacyScheduleFields() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000400")!
        let displayedDate = CalendarDate(year: 2026, month: 8, day: 11)!
        let range = try LocalTimeRange(
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 10, minute: 0)!
        )
        let override = OccurrenceOverride(
            displayedSchedule: try CalendarSchedule(
                startDate: displayedDate, endDate: displayedDate,
                startTime: range.start, endTime: range.end
            ),
            title: "改期复盘", kind: .task, categoryID: categoryID
        )
        let base = try legacyEncodedDictionary(override)
        var dateConflict = base
        dateConflict["displayedDate"] = try legacyEncodedJSONValue(CalendarDate(year: 2026, month: 8, day: 12)!)
        dateConflict["timeRange"] = try legacyEncodedJSONValue(range)
        var timeConflict = base
        timeConflict["displayedDate"] = try legacyEncodedJSONValue(displayedDate)
        timeConflict["timeRange"] = try legacyEncodedJSONValue(
            LocalTimeRange(start: MinuteOfDay(hour: 11, minute: 0)!, end: MinuteOfDay(hour: 12, minute: 0)!)
        )

        for payload in [dateConflict, timeConflict] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(OccurrenceOverride.self, from: try legacyJSONData(payload))
            }
        }
    }

    @Test func decodablePartialOrReversedTimeIsRejectedBeforeWorkspaceRestoreCanBegin() throws {
        let state = try legacyPopulatedCalendarState()
        let itemID = try #require(state.items.keys.first)
        let invalidDocuments = try [
            legacyV2DocumentData(from: state) { document in
                try mutateLegacyItem(&document, id: itemID) { item in
                    var schedule = try legacyDictionary(at: "schedule", in: item)
                    schedule["startTime"] = ["value": 600]
                    item["schedule"] = schedule
                }
            },
            legacyV2DocumentData(from: state) { document in
                try mutateLegacyItem(&document, id: itemID) { item in
                    var schedule = try legacyDictionary(at: "schedule", in: item)
                    schedule["startTime"] = ["value": 600]
                    schedule["endTime"] = ["value": 600]
                    item["schedule"] = schedule
                }
            }
        ]

        for data in invalidDocuments {
            #expect(throws: WorkspacePersistenceError.invalidDocument) {
                _ = try WorkspaceDocumentCodec.decode(data)
            }
        }
    }

    @Test func decodableConstructorAndIdentityViolationsAreRejectedBeforeWorkspaceRestoreCanBegin() throws {
        let state = try legacyPopulatedCalendarState()
        let itemID = try #require(state.items.keys.first)
        let seriesID = try #require(state.recurrence.series.keys.first)
        let invalidDocuments = try [
            legacyV2DocumentData(from: state) { document in
                try mutateLegacyItem(&document, id: itemID) { $0["title"] = "" }
            },
            legacyV2DocumentData(from: state) { document in
                try mutateLegacyItem(&document, id: itemID) {
                    $0["creationTimeZoneIdentifier"] = "Not/AReal_TimeZone"
                }
            },
            legacyV2DocumentData(from: state) { document in
                try renameLegacyStateMapKey(
                    &document, collection: "items", from: itemID.uuidString,
                    to: UUID(uuidString: "00000000-0000-0000-0000-000000000498")!.uuidString
                )
            },
            legacyV2DocumentData(from: state) { document in
                try renameLegacyRecurrenceSeriesKey(
                    &document, from: seriesID.uuidString,
                    to: UUID(uuidString: "00000000-0000-0000-0000-000000000497")!.uuidString
                )
            }
        ]

        for data in invalidDocuments {
            #expect(throws: WorkspacePersistenceError.invalidDocument) {
                _ = try WorkspaceDocumentCodec.decode(data)
            }
        }
    }
}

private func legacyPopulatedCalendarState() throws -> CalendarState {
    let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000400")!
    var state = CalendarState.empty(uncategorizedID: uncategorizedID, now: .distantPast)
    let item = try CalendarItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!, kind: .task,
        title: "持久化测试", categoryID: uncategorizedID,
        schedule: try CalendarSchedule(
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: .init(year: 2026, month: 8, day: 3)!, startTime: nil, endTime: nil
        ), completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
    )
    state.items[item.id] = item
    let series = try WeeklySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!, kind: .task,
        title: "周复盘", categoryID: uncategorizedID,
        ruleStartDate: .init(year: 2026, month: 8, day: 3)!,
        recurrenceEndDate: .init(year: 2026, month: 8, day: 31)!,
        weekdays: [.monday, .wednesday], durationDays: 1, startTime: nil, endTime: nil,
        creationTimeZoneIdentifier: "Asia/Shanghai", createdAt: .distantPast, updatedAt: .distantPast
    )
    let modifiedKey = OccurrenceKey(seriesID: series.id, originalDate: .init(year: 2026, month: 8, day: 10)!)
    state.recurrence = .init(
        series: [series.id: series],
        exceptions: [
            modifiedKey: .modified(.init(
                displayedSchedule: try CalendarSchedule(
                    startDate: .init(year: 2026, month: 8, day: 11)!,
                    endDate: .init(year: 2026, month: 8, day: 11)!, startTime: nil, endTime: nil
                ), title: "改期复盘", kind: .task, categoryID: uncategorizedID
            ))
        ],
        completions: [:]
    )
    return state
}

private func legacyV2DocumentData(
    from state: CalendarState,
    mutation: (inout [String: Any]) throws -> Void
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var document = try JSONSerialization.jsonObject(with: encoder.encode(CalendarDocument(state: state))) as! [String: Any]
    try mutation(&document)
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func legacyEncodedDictionary<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
        throw LegacyCalendarRegressionError.unexpectedShape
    }
    return dictionary
}

private func legacyEncodedJSONValue<Value: Encodable>(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func legacyJSONData(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func legacyDictionary(at key: String, in value: Any?) throws -> [String: Any] {
    guard let outer = value as? [String: Any], let nested = outer[key] as? [String: Any] else {
        throw LegacyCalendarRegressionError.unexpectedShape
    }
    return nested
}

private func mutateLegacyItem(
    _ document: inout [String: Any], id: UUID,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    var state = try legacyDictionary(at: "state", in: document)
    var items = try legacyKeyedEntries(at: "items", in: state)
    try mutateLegacyMapValue(&items, key: id.uuidString, mutation: mutation)
    state["items"] = items
    document["state"] = state
}

private func mutateLegacySeries(
    _ document: inout [String: Any], id: UUID,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    var state = try legacyDictionary(at: "state", in: document)
    var recurrence = try legacyDictionary(at: "recurrence", in: state)
    var series = try legacyKeyedEntries(at: "series", in: recurrence)
    try mutateLegacyMapValue(&series, key: id.uuidString, mutation: mutation)
    recurrence["series"] = series
    state["recurrence"] = recurrence
    document["state"] = state
}

private func mutateLegacyRecurrence(
    _ document: inout [String: Any],
    mutation: (inout [String: Any]) throws -> Void
) throws {
    var state = try legacyDictionary(at: "state", in: document)
    var recurrence = try legacyDictionary(at: "recurrence", in: state)
    try mutation(&recurrence)
    state["recurrence"] = recurrence
    document["state"] = state
}

private func renameLegacyStateMapKey(
    _ document: inout [String: Any], collection: String, from oldKey: String, to newKey: String
) throws {
    var state = try legacyDictionary(at: "state", in: document)
    var entries = try legacyKeyedEntries(at: collection, in: state)
    try renameLegacyMapKey(&entries, from: oldKey, to: newKey)
    state[collection] = entries
    document["state"] = state
}

private func renameLegacyRecurrenceSeriesKey(
    _ document: inout [String: Any], from oldKey: String, to newKey: String
) throws {
    var state = try legacyDictionary(at: "state", in: document)
    var recurrence = try legacyDictionary(at: "recurrence", in: state)
    var entries = try legacyKeyedEntries(at: "series", in: recurrence)
    try renameLegacyMapKey(&entries, from: oldKey, to: newKey)
    recurrence["series"] = entries
    state["recurrence"] = recurrence
    document["state"] = state
}

private func legacyKeyedEntries(at key: String, in value: [String: Any]) throws -> [Any] {
    guard let entries = value[key] as? [Any], entries.count.isMultiple(of: 2) else {
        throw LegacyCalendarRegressionError.unexpectedShape
    }
    return entries
}

private func mutateLegacyMapValue(
    _ entries: inout [Any], key: String,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    guard let index = stride(from: 0, to: entries.count, by: 2).first(where: { entries[$0] as? String == key }),
          var value = entries[index + 1] as? [String: Any]
    else { throw LegacyCalendarRegressionError.unexpectedShape }
    try mutation(&value)
    entries[index + 1] = value
}

private func renameLegacyMapKey(_ entries: inout [Any], from oldKey: String, to newKey: String) throws {
    guard let index = stride(from: 0, to: entries.count, by: 2).first(where: { entries[$0] as? String == oldKey }) else {
        throw LegacyCalendarRegressionError.unexpectedShape
    }
    entries[index] = newKey
}

private enum LegacyCalendarRegressionError: Error { case unexpectedShape }

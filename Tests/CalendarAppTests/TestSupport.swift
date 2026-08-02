import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
@testable import CalendarApp

@MainActor
func makeReadyStore(
    initialState: CalendarState
) async throws -> (CalendarStore, InMemoryCalendarRepository) {
    let repository = InMemoryCalendarRepository(initialState: initialState)
    let store = CalendarStore(initialState: initialState, repository: repository)
    await store.load()
    try #require(store.phase == .ready)
    return (store, repository)
}

func makeEmptyState() -> CalendarState {
    CalendarState.empty(
        uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
        now: .distantPast
    )
}

func makeCategory(name: String) -> CalendarCategory {
    CalendarCategory(
        id: UUID(), name: name, colorHex: "#007AFF", sortIndex: 1,
        createdAt: .distantPast, updatedAt: .distantPast
    )
}

func makeItem(
    categoryID: UUID,
    title: String = "测试事项",
    date: CalendarDate = CalendarDate(year: 2026, month: 8, day: 3)!
) throws -> CalendarItem {
    try CalendarItem(
        id: UUID(), kind: .task, title: title, categoryID: categoryID, date: date,
        timeRange: nil, completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
    )
}

func makeStateWithOneItem() throws -> CalendarState {
    var state = makeEmptyState()
    let item = try makeItem(categoryID: state.uncategorizedID)
    state.items[item.id] = item
    return state
}

func makeCategoryReferenceFixture() throws -> (
    state: CalendarState,
    deletedCategoryID: UUID,
    targetCategoryID: UUID
) {
    var state = makeEmptyState()
    let deleted = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
    let target = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
    state.categories[deleted] = CalendarCategory(
        id: deleted, name: "待删除", colorHex: "#FF3B30", sortIndex: 1,
        createdAt: .distantPast, updatedAt: .distantPast
    )
    state.categories[target] = CalendarCategory(
        id: target, name: "迁移目标", colorHex: "#34C759", sortIndex: 2,
        createdAt: .distantPast, updatedAt: .distantPast
    )
    let date = CalendarDate(year: 2026, month: 8, day: 3)!
    let item = try makeItem(categoryID: deleted, date: date)
    state.items[item.id] = item
    let series = try WeeklySeries(
        id: UUID(), kind: .task, title: "重复事项", categoryID: deleted,
        startDate: date, endDate: nil, weekdays: [.monday], timeRange: nil,
        createdAt: .distantPast, updatedAt: .distantPast
    )
    state.recurrence.series[series.id] = series
    let key = OccurrenceKey(seriesID: series.id, originalDate: date)
    state.recurrence.exceptions[key] = .modified(.init(
        displayedDate: date, title: "改期事项", kind: .task, categoryID: deleted, timeRange: nil
    ))
    return (state, deleted, target)
}

func makeBackupFile(for state: CalendarState) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CalendarAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("backup.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(CalendarDocument(state: state)).write(to: source)
    return source
}

actor InMemoryCalendarRepository: CalendarRepository {
    private(set) var persistedState: CalendarState
    private(set) var saveCount = 0
    private var rawDocument: Data
    private var failSave = false
    private var suspendLoad = false
    private var suspendSave = false
    private var suspendSnapshot = false
    private var loadStarted = false
    private var saveStarted = false
    private var snapshotStarted = false
    private var loadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var saveContinuations: [CheckedContinuation<Void, Never>] = []
    private var snapshotContinuations: [CheckedContinuation<Void, Never>] = []

    init(initialState: CalendarState) {
        persistedState = initialState
        rawDocument = Self.encodedDocument(initialState)
    }

    func load() async throws -> CalendarState {
        if suspendLoad {
            signalLoadStarted()
            await waitForLoadResume()
        }
        return try Self.decodedState(rawDocument)
    }

    func save(_ state: CalendarState) async throws {
        if suspendSave {
            signalSaveStarted()
            await waitForSaveResume()
        }
        if failSave {
            failSave = false
            throw BackupError.atomicWriteFailed
        }
        persistedState = state
        rawDocument = Self.encodedDocument(state)
        saveCount += 1
    }

    func snapshotCurrentDocument(to destination: URL) async throws {
        if suspendSnapshot {
            signalSnapshotStarted()
            await waitForSnapshotResume()
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try rawDocument.write(to: destination)
    }

    func failNextSave() { failSave = true }
    func replaceRawDocument(with data: Data) { rawDocument = data }
    func rawDocumentData() -> Data { rawDocument }

    func suspendNextLoad() { suspendLoad = true }
    func suspendNextSave() { suspendSave = true }
    func suspendNextSnapshot() { suspendSnapshot = true }

    func waitForLoadToStart() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { loadStartWaiters.append($0) }
    }

    func waitForSaveToStart() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { saveStartWaiters.append($0) }
    }

    func waitForSnapshotToStart() async {
        guard !snapshotStarted else { return }
        await withCheckedContinuation { snapshotStartWaiters.append($0) }
    }

    func resumeLoad() {
        suspendLoad = false
        let waiting = loadContinuations
        loadContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func resumeSave() {
        suspendSave = false
        let waiting = saveContinuations
        saveContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func resumeSnapshot() {
        suspendSnapshot = false
        let waiting = snapshotContinuations
        snapshotContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func signalLoadStarted() {
        loadStarted = true
        let waiting = loadStartWaiters
        loadStartWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func signalSaveStarted() {
        saveStarted = true
        let waiting = saveStartWaiters
        saveStartWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func signalSnapshotStarted() {
        snapshotStarted = true
        let waiting = snapshotStartWaiters
        snapshotStartWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func waitForLoadResume() async {
        await withCheckedContinuation { loadContinuations.append($0) }
    }

    private func waitForSaveResume() async {
        await withCheckedContinuation { saveContinuations.append($0) }
    }

    private func waitForSnapshotResume() async {
        await withCheckedContinuation { snapshotContinuations.append($0) }
    }

    private static func encodedDocument(_ state: CalendarState) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try! encoder.encode(CalendarDocument(state: state))
    }

    private static func decodedState(_ data: Data) throws -> CalendarState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(CalendarDocument.self, from: data).state
        } catch {
            throw BackupError.invalidDocument
        }
    }
}

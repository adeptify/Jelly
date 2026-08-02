import CalendarDomain
import CalendarPersistence
import Foundation
import Observation

enum StorePhase: Equatable, Sendable {
    case notLoaded
    case loading
    case ready
    case mutating
    case restoring
    case loadFailed
}

enum StoreError: Error, Equatable, Sendable {
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

    private var undoSnapshots: [UndoSnapshot] = []

    init(initialState: CalendarState, repository: any CalendarRepository) {
        self.state = initialState
        self.repository = repository
        loadError = nil
        mutationError = nil
        phase = .notLoaded
        canUndo = false
        undoNotice = nil
    }

    func load() async {
        guard phase == .notLoaded else { return }
        phase = .loading
        loadError = nil
        do {
            let loaded = try await repository.load()
            state = loaded
            phase = .ready
        } catch {
            phase = .loadFailed
            loadError = "无法读取本地日历。请检查备份后再尝试恢复。"
        }
    }

    func send(_ command: CalendarCommand, undoLabel: String?) async throws {
        try requireReadyForMutation()
        phase = .mutating
        mutationError = nil
        let previous = state

        let candidate: CalendarState
        do {
            candidate = try CalendarReducer.reduce(previous, command: command, now: Date())
        } catch {
            phase = .ready
            mutationError = "无法完成这项操作，请检查日历内容后重试。"
            throw error
        }

        do {
            try await repository.save(candidate)
        } catch {
            phase = .ready
            mutationError = "保存日历失败，原有内容没有被更改。"
            throw StoreError.persistenceFailed
        }

        state = candidate
        if let undoLabel {
            undoSnapshots.append(.init(label: undoLabel, state: previous))
            if undoSnapshots.count > 50 {
                undoSnapshots.removeFirst(undoSnapshots.count - 50)
            }
            undoNotice = undoLabel
        }
        updateUndoAvailability()
        phase = .ready
    }

    func undo() async throws {
        try requireReadyForMutation()
        guard let snapshot = undoSnapshots.last else {
            mutationError = "没有可撤销的操作。"
            throw StoreError.nothingToUndo
        }
        phase = .mutating
        mutationError = nil

        do {
            try await repository.save(snapshot.state)
        } catch {
            phase = .ready
            mutationError = "撤销没有保存成功，当前内容保持不变。"
            throw StoreError.persistenceFailed
        }

        state = snapshot.state
        undoSnapshots.removeLast()
        updateUndoAvailability()
        phase = .ready
    }

    func restore(
        from source: URL,
        using backupService: BackupService,
        rollbackURL: URL
    ) async throws {
        guard phase == .ready || phase == .loadFailed else {
            throw mutationRejection()
        }
        let entryPhase = phase
        phase = .restoring
        mutationError = nil

        do {
            let restored = try await backupService.restore(
                from: source,
                repository: repository,
                rollbackURL: rollbackURL
            )
            state = restored
            undoSnapshots.removeAll()
            updateUndoAvailability()
            loadError = nil
            mutationError = nil
            phase = .ready
        } catch {
            phase = entryPhase
            mutationError = "恢复备份失败，当前本地文件没有被替换。"
            throw StoreError.restoreFailed
        }
    }

    func dismissErrors() {
        loadError = nil
        mutationError = nil
    }

    func requireReadyForMutation() throws {
        guard phase == .ready else {
            throw mutationRejection()
        }
    }

    private func mutationRejection() -> StoreError {
        if isMutating {
            mutationError = "正在处理上一项操作，请稍候。"
            return .mutationInProgress
        }
        mutationError = "日历尚未准备好，请稍候再试。"
        return .notReady
    }

    private func updateUndoAvailability() {
        canUndo = !undoSnapshots.isEmpty
        undoNotice = undoSnapshots.last?.label
    }

    private struct UndoSnapshot: Sendable {
        let label: String
        let state: CalendarState
    }
}

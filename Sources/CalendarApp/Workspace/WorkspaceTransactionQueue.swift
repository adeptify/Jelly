import Foundation

/// Main-actor FIFO. A request becomes non-cancellable once it is appended, so
/// each caller has exactly one terminal continuation even while a save awaits.
@MainActor
final class WorkspaceTransactionQueue {
    typealias Operation = @MainActor @Sendable (UUID) async throws -> WorkspaceTransactionOutcome

    private struct Entry {
        let id: UUID
        let operation: Operation
        let pausesAfterFailure: @MainActor @Sendable () -> Bool
        let continuation: CheckedContinuation<Result<WorkspaceTransactionOutcome, Error>, Never>
    }

    private var entries: [Entry] = []
    private var draining = false

    func enqueue(
        _ operation: @escaping Operation,
        pausesAfterFailure: @escaping @MainActor @Sendable () -> Bool = { false }
    ) async throws -> WorkspaceTransactionOutcome {
        try Task.checkCancellation()
        let id = UUID()
        return try await withCheckedContinuation { continuation in
            entries.append(.init(id: id, operation: operation, pausesAfterFailure: pausesAfterFailure, continuation: continuation))
            Task { @MainActor [weak self] in await self?.drain() }
        }.get()
    }

    func resume() {
        Task { @MainActor [weak self] in await self?.drain() }
    }

    /// A terminal external/persistence condition belongs to the current head,
    /// but callers already appended behind it must also receive one terminal
    /// result rather than being reduced against a frozen store.
    func terminateQueued(
        with outcome: @escaping @MainActor @Sendable (UUID) -> WorkspaceTransactionOutcome
    ) {
        let pending = entries
        entries.removeAll()
        pending.forEach { entry in
            entry.continuation.resume(returning: .success(outcome(entry.id)))
        }
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            do {
                let outcome = try await entry.operation(entry.id)
                entry.continuation.resume(returning: .success(outcome))
                if outcome.parksFIFO { return }
            } catch {
                entry.continuation.resume(returning: .failure(error))
                if entry.pausesAfterFailure() { return }
            }
        }
    }
}

private extension WorkspaceTransactionOutcome {
    var parksFIFO: Bool {
        switch self {
        case .commitPending, .committed(_, journal: .cleanupPending), .noChange(_, journal: .cleanupPending), .notCommitted(_, journal: .cleanupPending, _):
            true
        default:
            false
        }
    }
}

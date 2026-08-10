import Foundation

enum NoteCloseProtectionReason: Equatable, Sendable {
    case selection
    case route
    case archive
    case appInactive
    case windowClose
    case termination
}

enum NoteCloseProtectionDecision: Equatable, Sendable {
    case allow
    case keepOpen
    case terminateLater
}

struct NoteDraftCopyExportReceipt: Equatable, Sendable {
    let triple: NoteAutosaveTriple
    let snapshotChecksum: String
}

typealias NoteDraftCopyExporter = @MainActor (
    NoteAutosaveTriple,
    String
) async -> NoteDraftCopyExportReceipt?

/// This stays platform-independent. Task 10C supplies the native finalizer
/// and forwards platform lifecycle events through this decision seam.
@MainActor
final class NoteCloseProtectionBridge {
    private let coordinator: NoteAutosaveCoordinator
    private let copyExporter: NoteDraftCopyExporter?

    init(
        coordinator: NoteAutosaveCoordinator,
        copyExporter: NoteDraftCopyExporter? = nil
    ) {
        self.coordinator = coordinator
        self.copyExporter = copyExporter
    }

    func decision(
        for reason: NoteCloseProtectionReason,
        finalizer: NoteNativeInputFinalizer? = nil
    ) async -> NoteCloseProtectionDecision {
        let evidence = await coordinator.flushLatest(finalizer: finalizer)
        return decision(for: reason, evidence: evidence)
    }

    func copyOrExportThenDecide(
        for reason: NoteCloseProtectionReason
    ) async -> NoteCloseProtectionDecision {
        guard !coordinator.hasUnresolvedNativeInput else { return .keepOpen }
        guard let copyExporter,
              let triple = coordinator.currentTriple,
              let snapshotChecksum = coordinator.currentSnapshotChecksum
        else { return .keepOpen }
        guard let receipt = await copyExporter(triple, snapshotChecksum),
              receipt.triple == coordinator.currentTriple,
              receipt.snapshotChecksum == coordinator.currentSnapshotChecksum
        else { return .keepOpen }
        return decision(for: reason, evidence: .protectedOnly(triple))
    }

    private func decision(
        for reason: NoteCloseProtectionReason,
        evidence: NoteAutosaveBarrierEvidence
    ) -> NoteCloseProtectionDecision {
        switch (reason, evidence) {
        case (_, .clean):
            .allow
        case (.selection, .persisted), (.route, .persisted), (.archive, .persisted):
            .allow
        case (.appInactive, .persisted), (.appInactive, .protectedOnly),
             (.windowClose, .persisted), (.windowClose, .protectedOnly),
             (.termination, .persisted), (.termination, .protectedOnly):
            .allow
        case (.termination, .unsafeLatestUnprotected):
            .terminateLater
        case (.selection, .protectedOnly), (.route, .protectedOnly), (.archive, .protectedOnly),
             (_, .unsafeLatestUnprotected):
            .keepOpen
        }
    }
}

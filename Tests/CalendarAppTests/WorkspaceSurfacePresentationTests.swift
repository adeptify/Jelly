import AppKit
import CalendarDomain
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceSurfacePresentationTests")
@MainActor
struct WorkspaceSurfacePresentationTests {
    @Test func notesUsesOnePaneAtCompactWidthsAndNeverClipsTheEditorBehindTheBrowser() {
        #expect(NotesAdaptiveLayout.mode(width: 640, browserCollapsed: false) == .browserOnly)
        #expect(NotesAdaptiveLayout.mode(width: 640, browserCollapsed: true) == .editorOnly)
        #expect(NotesAdaptiveLayout.mode(width: 980, browserCollapsed: false) == .split)
        #expect(NotesAdaptiveLayout.mode(width: 980, browserCollapsed: true) == .editorOnly)
    }

    @Test func noteBrowserPresentsOneExplicitScopeInsteadOfDuplicatingRowsAcrossSections() async throws {
        let calendar = makeEmptyState()
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        var note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        note.title = "只出现一次"
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let model = NotesWorkspaceViewModel(store: store, autosave: NoteAutosaveCoordinator(store: store))

        #expect(model.displayedNotes(in: .recent).map(\.id) == [note.id])
        #expect(model.displayedNotes(in: .all).map(\.id) == [note.id])
        #expect(model.displayedNotes(in: .archived).isEmpty)
        #expect(NotesBrowserPartition.allCases.map(\.title) == ["最近", "全部", "归档"])
    }

    @Test func emptyBlockEditorExplainsWhereWritingStarts() {
        let textView = BlockEditorTextView()
        #expect(textView.accessibilityPlaceholderValue() == "开始写点什么…")
    }

    @Test func inspirationCategoryFilterNarrowsEveryLifecyclePartition() async throws {
        let calendar = makeEmptyState()
        let work = makeCategory(name: "工作")
        var calendarWithWork = calendar
        calendarWithWork.categories[work.id] = work
        let repository = InMemoryWorkspaceRepository(initialState: calendarWithWork)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendarWithWork),
            repository: repository
        )
        await store.load()
        let model = InspirationViewModel(store: store, metadataResolver: FailingSurfaceMetadataResolver())
        _ = try await model.capture("未分类灵感")
        _ = try await model.capture("工作灵感")
        _ = try await model.changeSelectedCategory(to: work.id)

        model.categoryFilterID = work.id

        #expect(model.pending.map(\.rawText) == ["工作灵感"])
        #expect(model.converted.isEmpty)
        #expect(model.archived.isEmpty)
    }

    @Test func convertedInspirationExposesItsExistingNoteAsThePrimaryAction() async throws {
        let calendar = makeEmptyState()
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        let model = InspirationViewModel(store: store, metadataResolver: FailingSurfaceMetadataResolver())
        _ = try await model.capture("已有去向的灵感")
        let noteID = try #require(try await model.convertSelectedToNote())

        #expect(model.selectedConvertedNoteID == noteID)
        #expect(model.selectedPrimaryActionTitle == "打开笔记")
    }

    @Test func metadataStatesUseUserFacingChineseInsteadOfPersistenceRawValues() {
        #expect(MetadataFetchStatus.notRequested.presentationTitle == "未请求")
        #expect(MetadataFetchStatus.loading.presentationTitle == "获取中…")
        #expect(MetadataFetchStatus.succeeded.presentationTitle == "已获取")
        #expect(MetadataFetchStatus.failed.presentationTitle == "获取失败")
    }

    @Test func inspirationScopeFollowsTheSelectedItemsLifecycleAndConversion() {
        #expect(InspirationInboxScope.preferred(lifecycle: .active, isConverted: false) == .pending)
        #expect(InspirationInboxScope.preferred(lifecycle: .active, isConverted: true) == .converted)
        #expect(InspirationInboxScope.preferred(lifecycle: .archived, isConverted: true) == .archived)
    }

    @Test func inspirationDetailExposesOnePrimaryPathAndSeparateSecondaryActionContracts() {
        #expect(InspirationDetailAction.allCases.map(\.rawValue) == [
            "inspiration-primary-action",
            "inspiration-archive-action",
            "inspiration-copy-link-action",
        ])
    }
}

private final class FailingSurfaceMetadataResolver: URLMetadataResolving, @unchecked Sendable {
    func resolve(_ url: URL) async throws -> URLMetadataResolveResult {
        throw CocoaError(.fileReadUnknown)
    }
}

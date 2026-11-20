import Foundation
import SQLite3
import XCTest
@testable import Cleaner

final class CleanerViewModelTests: XCTestCase {
    @MainActor
    func testCancellationRetainsSelectionAndAllowsRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)

        await viewModel.delete(reviewVersion: viewModel.reviewVersion)

        XCTAssertEqual(fixture.library.deletionRequests, [["first", "second"]])
        XCTAssertEqual(viewModel.selection.map(\.id), ["first", "second"])
        XCTAssertNil(viewModel.pending)
        XCTAssertNil(viewModel.result)
        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(viewModel.remaining, 10)
        XCTAssertTrue(viewModel.history.isEmpty)
        XCTAssertTrue(viewModel.canSubmit)
    }

    @MainActor
    func testSuccessSettlesOnceAndSurvivesRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        fixture.library.outcome = .success
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)

        await viewModel.delete(reviewVersion: viewModel.reviewVersion)

        let receipt = try XCTUnwrap(viewModel.result)
        XCTAssertEqual(receipt.count, 2)
        XCTAssertEqual(viewModel.history.map(\.id), [receipt.id])
        XCTAssertEqual(viewModel.remaining, 8)
        XCTAssertTrue(viewModel.selection.isEmpty)
        XCTAssertEqual(viewModel.count, 0)

        let store = try fixture.openStore()
        try store.settle(id: receipt.id)
        let restarted = fixture.makeViewModel()
        XCTAssertEqual(restarted.history.map(\.id), [receipt.id])
        XCTAssertEqual(restarted.remaining, 8)
        XCTAssertNil(restarted.pending)
    }

    @MainActor
    func testRestartSettlesPreviouslyConfirmedBatch() throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        let store = try fixture.openStore()
        try store.prepare(id: "confirmed", assetIDs: ["first", "second"])
        try store.confirm(id: "confirmed", at: .now)

        for _ in 0..<2 {
            let restarted = fixture.makeViewModel()
            XCTAssertNil(restarted.pending)
            XCTAssertEqual(restarted.remaining, 8)
            XCTAssertEqual(restarted.history.map(\.id), ["confirmed"])
        }
        XCTAssertTrue(fixture.library.deletionRequests.isEmpty)
    }

    @MainActor
    func testSettlementFailureRollsBackQuotaAndCanRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        fixture.library.outcome = .success
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)
        try fixture.executeSQL("""
            CREATE TRIGGER fail_history BEFORE INSERT ON history
            BEGIN
                SELECT RAISE(ABORT, 'Simulated history write failure');
            END;
            """)

        await viewModel.delete(reviewVersion: viewModel.reviewVersion)

        let store = try fixture.openStore()
        XCTAssertEqual(try store.remaining(), 10)
        XCTAssertTrue(try store.history().isEmpty)
        let pending = try XCTUnwrap(store.pending())
        XCTAssertNotNil(pending.confirmedAt)
        XCTAssertNil(viewModel.remaining)
        XCTAssertFalse(viewModel.canSubmit)

        try fixture.executeSQL("DROP TRIGGER fail_history")
        let restarted = fixture.makeViewModel()
        XCTAssertNil(restarted.pending)
        XCTAssertEqual(restarted.remaining, 8)
        XCTAssertEqual(restarted.history.map(\.id), [pending.id])
        XCTAssertEqual(fixture.library.deletionRequests.count, 1)
    }

    @MainActor
    func testUnknownBatchBlocksNewCleanupUntilAcknowledged() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        fixture.library.outcome = .unknown
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)
        await viewModel.delete(reviewVersion: viewModel.reviewVersion)
        let unresolvedBatch = try XCTUnwrap(viewModel.pending)

        let restarted = fixture.makeViewModel()
        await fixture.selectAll(in: restarted)
        XCTAssertEqual(restarted.pending?.id, unresolvedBatch.id)
        XCTAssertNil(restarted.pending?.confirmedAt)
        XCTAssertFalse(restarted.canSubmit)
        await restarted.delete(reviewVersion: restarted.reviewVersion)
        XCTAssertEqual(fixture.library.deletionRequests.count, 1)
        XCTAssertEqual(restarted.remaining, 10)
        XCTAssertTrue(restarted.history.isEmpty)

        restarted.acknowledgeUnknown()
        await fixture.selectAll(in: restarted)
        XCTAssertNil(restarted.pending)
        XCTAssertEqual(restarted.remaining, 10)
        XCTAssertTrue(restarted.canSubmit)
    }

    @MainActor
    func testStaleReviewCannotSubmitAfterSelectionChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)
        let oldVersion = viewModel.reviewVersion
        viewModel.remove(fixture.library.items[0])

        await viewModel.delete(reviewVersion: oldVersion)

        XCTAssertTrue(fixture.library.deletionRequests.isEmpty)
        XCTAssertNil(viewModel.pending)
        XCTAssertTrue(viewModel.canSubmit)
    }

    @MainActor
    func testRevokedAccessInvalidatesPreviouslyReviewedSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        fixture.library.access = .limited
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)
        let oldVersion = viewModel.reviewVersion

        fixture.library.access = .denied
        viewModel.setForeground(true)
        await viewModel.delete(reviewVersion: oldVersion)

        XCTAssertEqual(viewModel.access, .denied)
        XCTAssertEqual(viewModel.count, 0)
        XCTAssertTrue(viewModel.selection.isEmpty)
        XCTAssertNotEqual(viewModel.reviewVersion, oldVersion)
        XCTAssertTrue(fixture.library.deletionRequests.isEmpty)
    }

    @MainActor
    func testPermissionChangeBlocksSubmitBeforeLibraryRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)
        let oldVersion = viewModel.reviewVersion

        fixture.library.access = .limited
        await viewModel.delete(reviewVersion: oldVersion)

        XCTAssertEqual(viewModel.access, .limited)
        XCTAssertEqual(viewModel.count, 2)
        XCTAssertTrue(viewModel.selection.isEmpty)
        XCTAssertNotEqual(viewModel.reviewVersion, oldVersion)
        XCTAssertTrue(fixture.library.deletionRequests.isEmpty)
        XCTAssertNil(viewModel.pending)
        XCTAssertEqual(viewModel.remaining, 10)
    }

    @MainActor
    func testAssetDisappearingAfterReviewBlocksDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.removeDatabase() }
        let viewModel = fixture.makeViewModel()
        await fixture.selectAll(in: viewModel)
        let oldVersion = viewModel.reviewVersion
        fixture.library.items.removeLast()

        await viewModel.delete(reviewVersion: oldVersion)

        XCTAssertEqual(viewModel.selection.map(\.id), ["first"])
        XCTAssertNotEqual(viewModel.reviewVersion, oldVersion)
        XCTAssertNotNil(viewModel.notice)
        XCTAssertNil(viewModel.pending)
        XCTAssertTrue(fixture.library.deletionRequests.isEmpty)
        XCTAssertEqual(viewModel.remaining, 10)
    }
}

@MainActor
private final class Fixture {
    let library = TestScreenshotLibrary()
    private let directory: URL
    private var databaseURL: URL { directory.appendingPathComponent("cleanup.sqlite") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func openStore() throws -> CleanupStore {
        try CleanupStore(url: databaseURL)
    }

    func executeSQL(_ sql: String) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(database) }
        try requireSQLiteSuccess(status)
        try requireSQLiteSuccess(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func requireSQLiteSuccess(_ status: Int32) throws {
        guard status == SQLITE_OK else {
            throw NSError(domain: "CleanerTests.SQLite", code: Int(status))
        }
    }

    func makeViewModel() -> CleanerViewModel {
        CleanerViewModel(library: library, openStore: openStore)
    }

    func selectAll(in viewModel: CleanerViewModel) async {
        await viewModel.scan()
        for month in viewModel.visibleMonths(olderOnly: false) {
            for screenshot in month.screenshots {
                viewModel.toggle(screenshot, previewVersion: viewModel.previewVersion)
            }
        }
    }

    func removeDatabase() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class TestScreenshotLibrary: ScreenshotLibraryServing {
    var access: PhotoAccess = .authorized
    var outcome: DeletionOutcome = .cancelled
    var items = ["first", "second"].map { id in
        Screenshot(id: id, revision: .init(
            date: nil, modifiedAt: nil, width: 100, height: 100, isFavorite: false
        ))
    }
    private(set) var deletionRequests: [[String]] = []

    func requestAccess() async {}

    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        NSObject()
    }

    func scan() async throws -> [ScreenshotMonth] {
        items.isEmpty ? [] : [ScreenshotMonth(date: nil, screenshots: items)]
    }

    func current(_ requested: [Screenshot]) -> [Screenshot] {
        guard access.canRead else { return [] }
        return requested.filter { screenshot in
            items.contains { $0.id == screenshot.id && $0.revision == screenshot.revision }
        }
    }

    func delete(_ screenshots: [Screenshot]) async -> DeletionOutcome {
        let ids = screenshots.map(\.id)
        deletionRequests.append(ids)
        if case .success = outcome {
            items.removeAll { ids.contains($0.id) }
        }
        return outcome
    }

    func presentLimitedPicker(onChange: @escaping @MainActor @Sendable () -> Void) {}
}

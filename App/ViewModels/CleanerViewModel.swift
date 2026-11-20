import Foundation
import Observation

@MainActor
@Observable
final class CleanerViewModel {
    private(set) var access: PhotoAccess
    private var months: [ScreenshotMonth] = []
    private(set) var selection: [Screenshot] = []
    private(set) var scanned = false
    private(set) var scanning = false
    private(set) var requestingAccess = false
    private(set) var submitting = false
    private(set) var remaining: Int?
    private(set) var history: [CleanupHistory] = []
    private(set) var notice: LocalizedStringResource?
    private(set) var pending: PendingCleanup?
    private(set) var previewVersion = UUID()
    private(set) var reviewVersion = UUID()
    private(set) var result: CleanupHistory?

    private var foreground = true
    private let library: any ScreenshotLibraryServing
    private let openStore: () throws -> CleanupStore
    @ObservationIgnored private var store: CleanupStore?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var observer: AnyObject?
    @ObservationIgnored private var unsavedReceipt: CleanupHistory?
    @ObservationIgnored private var startedScan = false

    var count: Int { months.reduce(0) { $0 + $1.screenshots.count } }
    var hasAccess: Bool { access.canRead }
    var favoriteCount: Int { selection.filter(\.isFavorite).count }
    var canSubmit: Bool {
        foreground && hasAccess && !scanning && !submitting && pending == nil
            && unsavedReceipt == nil && !selection.isEmpty
            && selection.count <= CleanupLimits.batchSize && selection.count <= (remaining ?? 0)
    }

    init(library: any ScreenshotLibraryServing, openStore: @escaping () throws -> CleanupStore) {
        self.library = library
        self.openStore = openStore
        access = library.access
        reloadStorage()
    }

    func scan() async {
        guard !requestingAccess, !submitting else { return }
        if access == .notDetermined {
            requestingAccess = true
            await library.requestAccess()
            requestingAccess = false
        }
        startedScan = true
        await refresh(force: true)?.value
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            reloadStorage()
            refresh()
        } else {
            scanTask?.cancel()
            scanning = false
            previewVersion = UUID()
            reviewVersion = UUID()
        }
    }

    func managePhotoAccess() {
        library.presentLimitedPicker { [weak self] in self?.refresh() }
    }

    @discardableResult
    private func refresh(force: Bool = false) -> Task<Void, Never>? {
        let updatedAccess = library.access
        if access != updatedAccess {
            access = updatedAccess
            selection = []
            months = []
            previewVersion = UUID()
            reviewVersion = UUID()
        }
        guard hasAccess else {
            scanTask?.cancel()
            observer = nil
            months = []
            selection = []
            scanning = false
            scanned = false
            return nil
        }
        guard foreground, force || startedScan else { return nil }
        if observer == nil {
            observer = library.observeChanges { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }
        scanning = true
        previewVersion = UUID()
        reviewVersion = UUID()
        scanTask?.cancel()
        let task = Task { [weak self, library] in
            do {
                let groups = try await library.scan()
                try Task.checkCancellation()
                guard let self else { return }
                guard access == library.access else {
                    refresh(force: true)
                    return
                }
                let current = Dictionary(uniqueKeysWithValues: groups.flatMap(\.screenshots).map { ($0.id, $0) })
                let previousCount = selection.count
                selection = selection.compactMap { item in
                    guard let updated = current[item.id], updated.revision == item.revision else { return nil }
                    return updated
                }
                if selection.count != previousCount, !submitting {
                    notice = "Some screenshots changed or are no longer accessible. Review your updated selection."
                }
                months = groups
                scanned = true
                scanning = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.scanning = false
                self?.notice = "Couldn’t scan your screenshots. Try again."
            }
        }
        scanTask = task
        return task
    }

    func visibleMonths(olderOnly: Bool) -> [ScreenshotMonth] {
        let calendar = Calendar.current
        guard olderOnly, let cutoff = calendar.date(
            byAdding: .day, value: -30, to: calendar.startOfDay(for: .now)
        ) else { return months }
        return months.compactMap { month in
            let items = month.screenshots.filter { item in
                item.date.map { $0 < cutoff } ?? false
            }
            return items.isEmpty ? nil : ScreenshotMonth(date: month.date, screenshots: items)
        }
    }

    func isSelected(_ item: Screenshot) -> Bool {
        selection.contains { $0.id == item.id }
    }

    func screenshot(id: String) -> Screenshot? {
        for month in months {
            if let item = month.screenshots.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    func toggle(_ item: Screenshot, previewVersion: UUID) {
        guard foreground, !scanning, !submitting, hasAccess, previewVersion == self.previewVersion else { return }
        if isSelected(item) {
            remove(item)
        } else if let current = library.current([item]).first {
            selection.append(current)
            reviewVersion = UUID()
        } else {
            notice = "This screenshot changed or is no longer available."
            refresh(force: true)
        }
    }

    func remove(_ item: Screenshot) {
        guard !submitting else { return }
        selection.removeAll { $0.id == item.id }
        reviewVersion = UUID()
    }

    func delete(reviewVersion: UUID) async {
        guard canSubmit, reviewVersion == self.reviewVersion,
              let store else { return }
        guard access == library.access else {
            await refresh(force: true)?.value
            return
        }
        let reviewed = selection
        let current = library.current(reviewed)
        guard current.count == reviewed.count else {
            let validIDs = Set(current.map(\.id))
            selection = selection.filter { validIDs.contains($0.id) }
            notice = "Some screenshots changed or are no longer accessible. Review your updated selection."
            refresh(force: true)
            return
        }
        let id = UUID().uuidString
        do {
            try store.prepare(id: id, assetIDs: current.map(\.id))
        } catch {
            reloadStorage()
            notice = "Couldn’t prepare the cleanup. Check your remaining items and try again."
            return
        }
        submitting = true
        pending = PendingCleanup(id: id, confirmedAt: nil)
        notice = nil
        let outcome = await library.delete(current)
        submitting = false
        switch outcome {
        case .success:
            let deleted = Set(current.map(\.id))
            selection.removeAll { deleted.contains($0.id) }
            let receipt = CleanupHistory(id: id, date: .now, count: current.count)
            result = receipt
            unsavedReceipt = receipt
            reloadStorage()
        case .unknown:
            reloadStorage()
        case .cancelled, .failed, .changed:
            do {
                try store.discardUnconfirmed(id: id)
                reloadStorage()
                switch outcome {
                case .failed:
                    notice = "Photos couldn’t complete this cleanup. Review the selection and try again."
                case .changed:
                    notice = "The photo library changed. Review your updated selection."
                default:
                    break
                }
            } catch {
                reloadStorage()
                notice = "Couldn’t update the cleanup record. Check your photo library."
            }
        }
        await refresh(force: true)?.value
    }

    func dismissResult() { result = nil }
    func dismissNotice() { notice = nil }

    func acknowledgeUnknown() {
        guard !submitting, unsavedReceipt == nil,
              let pending, pending.confirmedAt == nil, let store else { return }
        do {
            try store.discardUnconfirmed(id: pending.id)
            selection = []
            reloadStorage()
            refresh(force: true)
        } catch {
            notice = "Couldn’t update the cleanup record. Try again."
        }
    }

    func reloadStorage() {
        guard !submitting else { return }
        do {
            if store == nil { store = try openStore() }
            guard let store else { return }
            if let unsavedReceipt {
                try store.confirm(id: unsavedReceipt.id, at: unsavedReceipt.date)
                self.unsavedReceipt = nil
            }
            pending = try store.pending()
            if let pending, pending.confirmedAt != nil {
                try store.settle(id: pending.id)
                self.pending = try store.pending()
            }
            remaining = try store.remaining()
            history = try store.history()
        } catch {
            remaining = nil
            if unsavedReceipt != nil {
                notice = "Photos confirmed the deletion. The cleanup record is waiting to be saved."
            }
        }
    }

    func clearHistory() {
        guard !submitting, let store else { return }
        do {
            try store.clearHistory()
            reloadStorage()
        } catch {
            notice = "Couldn’t clear cleanup history. Try again."
        }
    }
}

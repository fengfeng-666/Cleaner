import Photos
import PhotosUI
import UIKit
import os

struct Screenshot: Identifiable, Sendable {
    let asset: PHAsset
    let revision: Revision

    var id: String { asset.localIdentifier }
    var date: Date? { revision.date }
    var isFavorite: Bool { revision.isFavorite }

    init(asset: PHAsset) {
        self.asset = asset
        revision = Revision(
            date: asset.creationDate, modifiedAt: asset.modificationDate,
            width: asset.pixelWidth, height: asset.pixelHeight,
            isFavorite: asset.isFavorite
        )
    }

    struct Revision: Equatable, Sendable {
        let date: Date?
        let modifiedAt: Date?
        let width: Int
        let height: Int
        let isFavorite: Bool
    }
}

struct ScreenshotMonth: Identifiable, Sendable {
    let date: Date?
    var screenshots: [Screenshot]

    var id: Date? { date }
}

actor ScreenshotLibrary {
    func scan() throws -> [ScreenshotMonth] {
        guard Self.hasAccess else { return [] }
        let assets = PHAsset.fetchAssets(with: Self.options())
        var months: [ScreenshotMonth] = []
        let calendar = Calendar.current
        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            guard Self.isCandidate(asset) else { continue }
            let screenshot = Screenshot(asset: asset)
            let month = screenshot.date.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
            if !months.isEmpty, months[months.count - 1].date == month {
                months[months.count - 1].screenshots.append(screenshot)
            } else {
                months.append(ScreenshotMonth(date: month, screenshots: [screenshot]))
            }
        }
        return months
    }

    nonisolated static var hasAccess: Bool {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return access == .authorized || access == .limited
    }

    nonisolated static func current(_ requested: [Screenshot]) -> [Screenshot] {
        guard hasAccess, !requested.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: requested.map(\.id), options: options())
        let expected = Dictionary(uniqueKeysWithValues: requested.map { ($0.id, $0.revision) })
        var validated: [Screenshot] = []
        assets.enumerateObjects { asset, _, _ in
            guard isCandidate(asset) else { return }
            let screenshot = Screenshot(asset: asset)
            if expected[screenshot.id] == screenshot.revision {
                validated.append(screenshot)
            }
        }
        return validated
    }

    nonisolated static func delete(_ screenshots: [Screenshot]) async -> DeletionOutcome {
        let expectedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let validation = DeletionValidation()
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let current = Self.current(screenshots)
                guard current.count == screenshots.count,
                      PHPhotoLibrary.authorizationStatus(for: .readWrite) == expectedAccess
                else {
                    validation.rejected.withLock { $0 = true }
                    return
                }
                PHAssetChangeRequest.deleteAssets(current.map(\.asset) as NSArray)
            } completionHandler: { success, error in
                if validation.rejected.withLock({ $0 }) {
                    continuation.resume(returning: .changed)
                } else if success {
                    continuation.resume(returning: .success)
                } else if let failure = error as NSError?,
                          (failure.domain == PHPhotosErrorDomain || failure.domain == NSCocoaErrorDomain),
                          failure.code == CocoaError.userCancelled.rawValue {
                    continuation.resume(returning: .cancelled)
                } else if error != nil {
                    continuation.resume(returning: .failed)
                } else {
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    private nonisolated static func options() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = .typeUserLibrary
        options.predicate = NSPredicate(
            format: "mediaType == %d AND (mediaSubtypes & %d) != 0",
            PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    private nonisolated static func isCandidate(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image && asset.mediaSubtypes.contains(.photoScreenshot)
            && !asset.isHidden && asset.sourceType == .typeUserLibrary && asset.canPerform(.delete)
    }
}

enum DeletionOutcome {
    case success, changed, cancelled, failed, unknown
}

private struct DeletionValidation: Sendable {
    let rejected = OSAllocatedUnfairLock(initialState: false)
}

final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

@MainActor
func showLimitedLibraryPicker(onChange: @escaping @MainActor @Sendable () -> Void) {
    guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
          let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          var controller = scene.keyWindow?.rootViewController else { return }
    while let presented = controller.presentedViewController {
        controller = presented
    }
    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
        Task { @MainActor in onChange() }
    }
}

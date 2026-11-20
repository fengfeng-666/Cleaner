import Photos
import PhotosUI
import UIKit
import os

protocol ScreenshotLibraryServing: Sendable {
    @MainActor var access: PhotoAccess { get }
    func requestAccess() async
    @MainActor func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject
    func scan() async throws -> [ScreenshotMonth]
    @MainActor func current(_ requested: [Screenshot]) -> [Screenshot]
    func delete(_ screenshots: [Screenshot]) async -> DeletionOutcome
    @MainActor func presentLimitedPicker(onChange: @escaping @MainActor @Sendable () -> Void)
}

actor ScreenshotLibrary: ScreenshotLibraryServing {
    nonisolated var access: PhotoAccess {
        Self.access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    nonisolated func requestAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    nonisolated func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        LibraryObserver(onChange: onChange)
    }

    func scan() throws -> [ScreenshotMonth] {
        guard access.canRead else { return [] }
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

    nonisolated func current(_ requested: [Screenshot]) -> [Screenshot] {
        Self.validatedAssets(for: requested).map(Screenshot.init(asset:))
    }

    nonisolated static func asset(matching screenshot: Screenshot) -> PHAsset? {
        validatedAssets(for: [screenshot]).first
    }

    private nonisolated static func validatedAssets(for requested: [Screenshot]) -> [PHAsset] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access(for: status).canRead, !requested.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: requested.map(\.id), options: options())
        let expected = Dictionary(uniqueKeysWithValues: requested.map { ($0.id, $0.revision) })
        var validated: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            guard isCandidate(asset) else { return }
            let screenshot = Screenshot(asset: asset)
            if expected[screenshot.id] == screenshot.revision {
                validated.append(asset)
            }
        }
        return validated
    }

    nonisolated func delete(_ screenshots: [Screenshot]) async -> DeletionOutcome {
        let expectedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let validation = DeletionValidation()
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let current = Self.validatedAssets(for: screenshots)
                guard current.count == screenshots.count,
                      PHPhotoLibrary.authorizationStatus(for: .readWrite) == expectedAccess
                else {
                    validation.rejected.withLock { $0 = true }
                    return
                }
                PHAssetChangeRequest.deleteAssets(current as NSArray)
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

    @MainActor
    func presentLimitedPicker(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard access == .limited,
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

    private nonisolated static func access(for status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .unknown
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

private extension Screenshot {
    init(asset: PHAsset) {
        self.init(
            id: asset.localIdentifier,
            revision: Revision(
                date: asset.creationDate, modifiedAt: asset.modificationDate,
                width: asset.pixelWidth, height: asset.pixelHeight,
                isFavorite: asset.isFavorite
            )
        )
    }
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

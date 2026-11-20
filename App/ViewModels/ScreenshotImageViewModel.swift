import Observation
import UIKit

@MainActor
@Observable
final class ScreenshotImageViewModel {
    enum Kind {
        case thumbnail, preview
    }

    private(set) var image: UIImage?
    private(set) var progress: Double?
    private(set) var requestID: UUID? = UUID()

    var isLoading: Bool { requestID != nil }

    func load(_ item: Screenshot, kind: Kind, requestID: UUID?) async {
        guard let requestID, requestID == self.requestID, !Task.isCancelled else { return }
        progress = nil
        let dimension: CGFloat = kind == .thumbnail ? 180 : 1_600
        for await event in ScreenshotImages.events(
            for: item, size: CGSize(width: dimension, height: dimension), network: kind == .preview
        ) {
            guard requestID == self.requestID, !Task.isCancelled else { return }
            switch event {
            case .image(let photo): image = photo
            case .progress(let value): progress = value
            }
        }
        guard requestID == self.requestID, !Task.isCancelled else { return }
        self.requestID = nil
    }

    func cancel() {
        requestID = nil
    }

    func retry() {
        image = nil
        progress = nil
        requestID = UUID()
    }
}

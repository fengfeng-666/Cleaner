import Photos
import UIKit

enum ScreenshotImages {
    enum Event: Sendable {
        case progress(Double)
        case image(UIImage)
    }

    private static let manager = PHImageManager.default()

    static func events(for item: Screenshot, size: CGSize, network: Bool) -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { stream in
            guard let asset = ScreenshotLibrary.asset(matching: item) else {
                stream.finish()
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = network
            if network {
                options.progressHandler = { progress, _, _, _ in stream.yield(.progress(progress)) }
            }
            let request = manager.requestImage(
                for: asset, targetSize: size, contentMode: .aspectFit, options: options
            ) { image, info in
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                if let image { stream.yield(.image(image)) }
                stream.finish()
            }
            stream.onTermination = { reason in
                if case .cancelled = reason {
                    manager.cancelImageRequest(request)
                }
            }
        }
    }
}

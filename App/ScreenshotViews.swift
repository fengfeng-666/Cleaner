import Photos
import SwiftUI

struct ScreenshotList: View {
    let model: CleanerModel
    @State private var olderOnly = false

    private var visibleMonths: [ScreenshotMonth] {
        guard olderOnly, let cutoff = Calendar.current.date(
            byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: .now)
        ) else { return model.months }
        return model.months.compactMap { month in
            let items = month.screenshots.filter { item in
                item.date.map { $0 < cutoff } ?? false
            }
            return items.isEmpty ? nil : ScreenshotMonth(date: month.date, screenshots: items)
        }
    }

    var body: some View {
        List {
            if model.hasAccess && !model.scanning {
                Section {
                    if model.access == .limited { Text("Scanning selected photos only.") }
                    Toggle("Older than 30 days", isOn: $olderOnly)
                }
                if visibleMonths.isEmpty {
                    ContentUnavailableView("No Matching Screenshots", systemImage: "photo")
                }
                ForEach(visibleMonths) { month in
                    Section {
                        ForEach(month.screenshots) { item in
                            NavigationLink {
                                ScreenshotPreview(model: model, id: item.id)
                            } label: {
                                ScreenshotRow(model: model, item: item)
                            }
                            .accessibilityIdentifier("screenshot-row")
                        }
                    } header: {
                        if let date = month.date {
                            Text(date, format: .dateTime.month(.wide).year())
                        } else {
                            Text("Unknown Date")
                        }
                    }
                }
            } else if model.scanning {
                ProgressView("Finding screenshots")
            } else {
                ContentUnavailableView("Photo Access Unavailable", systemImage: "lock")
            }
        }
        .navigationTitle("Screenshots")
        .safeAreaInset(edge: .bottom) {
            if model.hasAccess, !model.selection.isEmpty {
                NavigationLink {
                    CleanupReview(model: model)
                } label: {
                    Text("Review Selection (\(model.selection.count))")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.scanning || model.submitting)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("review-selection")
            }
        }
    }
}

private struct ScreenshotRow: View {
    let model: CleanerModel
    let item: Screenshot

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(item: item)
                .id(model.previewVersion)
            VStack(alignment: .leading, spacing: 4) {
                if let date = item.date {
                    Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                } else {
                    Text("Unknown Date")
                }
                if item.isFavorite {
                    Label("Favorite", systemImage: "heart.fill")
                        .font(.caption)
                }
            }
            Spacer(minLength: 4)
            if model.isSelected(item) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(model.isSelected(item) ? .isSelected : [])
    }
}

private struct PhotoThumbnail: View {
    let item: Screenshot
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: item.id) {
            image = nil
            for await event in PhotoImages.events(
                for: item, size: CGSize(width: 180, height: 180), network: false
            ) {
                guard !Task.isCancelled else { return }
                if case .image(let photo) = event { image = photo }
            }
        }
    }
}

private struct ScreenshotPreview: View {
    let model: CleanerModel
    let id: String

    var body: some View {
        Group {
            if model.hasAccess, !model.scanning, let item = model.screenshot(id: id) {
                PreviewContent(model: model, item: item, version: model.previewVersion)
                    .id(model.previewVersion)
            } else if model.scanning {
                ProgressView("Checking photo access")
            } else {
                ContentUnavailableView("Screenshot Unavailable", systemImage: "photo")
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PreviewContent: View {
    let model: CleanerModel
    let item: Screenshot
    let version: UUID
    @State private var image: UIImage?
    @State private var progress: Double?
    @State private var loading = true
    @State private var attempt = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Screenshot preview")
                } else if loading {
                    Group {
                        if let progress {
                            ProgressView("Loading screenshot", value: progress)
                        } else {
                            ProgressView("Loading screenshot")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                    Button("Cancel Preview Load") { loading = false }
                } else {
                    Text("The screenshot preview isn’t available.")
                    Button("Retry Preview") {
                        progress = nil
                        loading = true
                        attempt = UUID()
                    }
                }
                if item.isFavorite {
                    Label("Favorite. You’ll confirm its removal separately.", systemImage: "heart")
                        .foregroundStyle(.secondary)
                }
                if let date = item.date {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .task(id: loading ? attempt : nil) {
                guard loading else { return }
                for await event in PhotoImages.events(
                    for: item, size: CGSize(width: 1_600, height: 1_600), network: true
                ) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .image(let photo): image = photo
                    case .progress(let value): progress = value
                    }
                }
                if !Task.isCancelled { loading = false }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.toggle(item, previewVersion: version)
            } label: {
                Group {
                    if model.isSelected(item) {
                        Text("Remove from Selection")
                    } else {
                        Text("Select Screenshot")
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled((image == nil && !model.isSelected(item)) || model.submitting)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("select-screenshot")
        }
    }
}

private struct CleanupReview: View {
    let model: CleanerModel
    @State private var confirmedVersion: UUID?

    var body: some View {
        List {
            Section("Selection") {
                LabeledContent("Photos selected", value: model.selection.count.formatted())
                if !model.selection.isEmpty {
                    LabeledContent("Original sizes unavailable", value: model.selection.count.formatted())
                }
                CleanupStatus(model: model)
                if model.selection.count > CleanupLimits.batchSize {
                    Text("Select up to \(CleanupLimits.batchSize) items per cleanup.")
                } else if let remaining = model.remaining, model.selection.count > remaining {
                    Text("Remove items from your selection to stay within your free allowance.")
                }
            }
            if model.hasAccess && !model.scanning {
                ForEach(model.selection) { item in
                    HStack {
                        NavigationLink {
                            ScreenshotPreview(model: model, id: item.id)
                        } label: {
                            ScreenshotRow(model: model, item: item)
                        }
                        Button {
                            model.remove(item)
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove from selection")
                        .disabled(model.submitting)
                    }
                }
            }
            Section("Before You Delete") {
                Text("Selected items move to Recently Deleted in Photos.")
                PhotoRecoveryGuide()
            }
        }
        .navigationTitle("Review Cleanup")
        .safeAreaInset(edge: .bottom) {
            Button(role: .destructive) {
                confirmedVersion = model.reviewVersion
            } label: {
                Text("Delete \(model.selection.count) Items")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.canSubmit)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("delete-selection")
        }
        .confirmationDialog("Move screenshots to Recently Deleted?", isPresented: Binding(
            get: { confirmedVersion != nil },
            set: { if !$0 { confirmedVersion = nil } }
        ), titleVisibility: .visible, presenting: confirmedVersion) { version in
            Button(role: .destructive) {
                Task { await model.delete(reviewVersion: version) }
            } label: {
                if favoriteCount > 0 {
                    Text("Continue Including Favorites")
                } else {
                    Text("Continue to Photos")
                }
            }
        } message: { _ in
            if favoriteCount > 0 {
                Text("Favorites selected for removal: \(favoriteCount). Deletion can sync to other devices and affect Shared Library participants.")
            } else {
                Text("Deletion can sync to your other devices and affect Shared Library participants.")
            }
        }
        .onChange(of: model.reviewVersion) { _, _ in confirmedVersion = nil }
    }

    private var favoriteCount: Int {
        model.selection.filter(\.isFavorite).count
    }
}

private enum PhotoImages {
    enum Event: Sendable {
        case progress(Double)
        case image(UIImage)
    }

    private static let manager = PHImageManager.default()

    static func events(for item: Screenshot, size: CGSize, network: Bool) -> AsyncStream<Event> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { stream in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = network
            if network {
                options.progressHandler = { progress, _, _, _ in stream.yield(.progress(progress)) }
            }
            let request = manager.requestImage(
                for: item.asset, targetSize: size, contentMode: .aspectFit, options: options
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

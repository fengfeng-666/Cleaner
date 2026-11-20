import SwiftUI

struct ScreenshotList: View {
    let viewModel: CleanerViewModel
    @State private var olderOnly = false

    var body: some View {
        List {
            if viewModel.hasAccess && !viewModel.scanning {
                let visibleMonths = viewModel.visibleMonths(olderOnly: olderOnly)
                Section {
                    if viewModel.access == .limited { Text("Scanning selected photos only.") }
                    Toggle("Older than 30 days", isOn: $olderOnly)
                }
                if visibleMonths.isEmpty {
                    ContentUnavailableView("No Matching Screenshots", systemImage: "photo")
                }
                ForEach(visibleMonths) { month in
                    Section {
                        ForEach(month.screenshots) { item in
                            NavigationLink {
                                ScreenshotPreview(viewModel: viewModel, id: item.id)
                            } label: {
                                ScreenshotRow(viewModel: viewModel, item: item)
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
            } else if viewModel.scanning {
                ProgressView("Finding screenshots")
            } else {
                ContentUnavailableView("Photo Access Unavailable", systemImage: "lock")
            }
        }
        .navigationTitle("Screenshots")
        .safeAreaInset(edge: .bottom) {
            if viewModel.hasAccess, !viewModel.selection.isEmpty {
                NavigationLink {
                    CleanupReview(viewModel: viewModel)
                } label: {
                    Text("Review Selection (\(viewModel.selection.count))")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.scanning || viewModel.submitting)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("review-selection")
            }
        }
    }
}

private struct ScreenshotRow: View {
    let viewModel: CleanerViewModel
    let item: Screenshot

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(item: item)
                .id(viewModel.previewVersion)
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
            if viewModel.isSelected(item) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(viewModel.isSelected(item) ? .isSelected : [])
    }
}

private struct PhotoThumbnail: View {
    let item: Screenshot
    @State private var imageViewModel = ScreenshotImageViewModel()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image = imageViewModel.image {
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
            await imageViewModel.load(item, kind: .thumbnail, requestID: imageViewModel.requestID)
        }
    }
}

private struct ScreenshotPreview: View {
    let viewModel: CleanerViewModel
    let id: String

    var body: some View {
        Group {
            if viewModel.hasAccess, !viewModel.scanning, let item = viewModel.screenshot(id: id) {
                PreviewContent(viewModel: viewModel, item: item, version: viewModel.previewVersion)
                    .id(viewModel.previewVersion)
            } else if viewModel.scanning {
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
    let viewModel: CleanerViewModel
    let item: Screenshot
    let version: UUID
    @State private var imageViewModel = ScreenshotImageViewModel()

    var body: some View {
        let requestID = imageViewModel.requestID
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image = imageViewModel.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Screenshot preview")
                } else if imageViewModel.isLoading {
                    Group {
                        if let progress = imageViewModel.progress {
                            ProgressView("Loading screenshot", value: progress)
                        } else {
                            ProgressView("Loading screenshot")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                    Button("Cancel Preview Load") { imageViewModel.cancel() }
                } else {
                    Text("The screenshot preview isn’t available.")
                    Button("Retry Preview") { imageViewModel.retry() }
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
            .task(id: requestID) {
                await imageViewModel.load(item, kind: .preview, requestID: requestID)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                viewModel.toggle(item, previewVersion: version)
            } label: {
                Group {
                    if viewModel.isSelected(item) {
                        Text("Remove from Selection")
                    } else {
                        Text("Select Screenshot")
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled((imageViewModel.image == nil && !viewModel.isSelected(item)) || viewModel.submitting)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("select-screenshot")
        }
    }
}

private struct CleanupReview: View {
    let viewModel: CleanerViewModel
    @State private var confirmedVersion: UUID?

    var body: some View {
        List {
            Section("Selection") {
                LabeledContent("Photos selected", value: viewModel.selection.count.formatted())
                if !viewModel.selection.isEmpty {
                    LabeledContent("Original sizes unavailable", value: viewModel.selection.count.formatted())
                }
                CleanupStatus(viewModel: viewModel)
                if viewModel.selection.count > CleanupLimits.batchSize {
                    Text("Select up to \(CleanupLimits.batchSize) items per cleanup.")
                } else if let remaining = viewModel.remaining, viewModel.selection.count > remaining {
                    Text("Remove items from your selection to stay within your free allowance.")
                }
            }
            if viewModel.hasAccess && !viewModel.scanning {
                ForEach(viewModel.selection) { item in
                    HStack {
                        NavigationLink {
                            ScreenshotPreview(viewModel: viewModel, id: item.id)
                        } label: {
                            ScreenshotRow(viewModel: viewModel, item: item)
                        }
                        Button {
                            viewModel.remove(item)
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove from selection")
                        .disabled(viewModel.submitting)
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
                confirmedVersion = viewModel.reviewVersion
            } label: {
                Text("Delete \(viewModel.selection.count) Items")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!viewModel.canSubmit)
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
                Task { await viewModel.delete(reviewVersion: version) }
            } label: {
                if viewModel.favoriteCount > 0 {
                    Text("Continue Including Favorites")
                } else {
                    Text("Continue to Photos")
                }
            }
        } message: { _ in
            if viewModel.favoriteCount > 0 {
                Text("Favorites selected for removal: \(viewModel.favoriteCount). Deletion can sync to other devices and affect Shared Library participants.")
            } else {
                Text("Deletion can sync to your other devices and affect Shared Library participants.")
            }
        }
        .onChange(of: viewModel.reviewVersion) { _, _ in confirmedVersion = nil }
    }
}

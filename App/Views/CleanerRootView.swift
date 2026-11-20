import SwiftUI

struct CleanerRootView: View {
    let viewModel: CleanerViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                CleanView(viewModel: viewModel)
            }
            .tabItem { Label("Clean", systemImage: "square.stack") }
            NavigationStack {
                SettingsView(viewModel: viewModel)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color(red: 0.05, green: 0.42, blue: 0.36))
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                viewModel.setForeground(true)
            } else if phase == .background {
                viewModel.setForeground(false)
            }
        }
        .alert("Cleaner", isPresented: Binding(
            get: { viewModel.notice != nil },
            set: { if !$0 { viewModel.dismissNotice() } }
        )) {
            Button("OK") { viewModel.dismissNotice() }
        } message: {
            if let notice = viewModel.notice {
                Text(notice)
            }
        }
        .sheet(item: Binding(
            get: { viewModel.result },
            set: { if $0 == nil { viewModel.dismissResult() } }
        )) { result in
            NavigationStack {
                List {
                    Section {
                        Label {
                            Text("\(result.count) items moved to Recently Deleted")
                                .font(.headline)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        PhotoRecoveryGuide()
                    }
                    Section {
                        CleanupStatus(viewModel: viewModel)
                        NavigationLink("Cleanup History") { HistoryView(viewModel: viewModel) }
                    }
                }
                .navigationTitle("Cleanup Complete")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { viewModel.dismissResult() }
                    }
                }
            }
        }
    }
}

private struct CleanView: View {
    let viewModel: CleanerViewModel
    @State private var showSample = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "rectangle.dashed.badge.record")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Clean Up Your Photo Library")
                        .font(.largeTitle.bold())
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Find screenshots you no longer need. Review them on your iPhone before you delete.")
                        .foregroundStyle(.secondary)
                    if viewModel.hasAccess || viewModel.access == .notDetermined {
                        Button {
                            Task { await viewModel.scan() }
                        } label: {
                            Group {
                                if viewModel.scanned {
                                    Text("Refresh Screenshots")
                                } else {
                                    Text("Scan My Photos")
                                }
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.scanning || viewModel.requestingAccess || viewModel.submitting)
                        .accessibilityIdentifier("scan-photos")
                    }
                }
                .padding(.vertical, 12)
            }
            Section {
                PhotoAccessView(viewModel: viewModel)
                if viewModel.scanning {
                    ProgressView("Finding screenshots")
                } else if viewModel.requestingAccess {
                    ProgressView("Waiting for photo access")
                } else if viewModel.scanned, viewModel.hasAccess {
                    if viewModel.count == 0 {
                        Label("No screenshots found in the photos we can access.", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            ScreenshotList(viewModel: viewModel)
                        } label: {
                            LabeledContent {
                                Text(viewModel.count.formatted())
                            } label: {
                                Label("Screenshots", systemImage: "camera.viewfinder")
                            }
                        }
                        .accessibilityIdentifier("screenshots")
                    }
                }
                Button("View Sample Cleanup") { showSample = true }
            }
            Section {
                CleanupStatus(viewModel: viewModel)
                NavigationLink("Cleanup History") { HistoryView(viewModel: viewModel) }
            }
        }
        .navigationTitle("Clean")
        .sheet(isPresented: $showSample) { SampleCleanupView() }
    }
}

private struct PhotoAccessView: View {
    let viewModel: CleanerViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch viewModel.access {
        case .limited:
            Label("Scanning selected photos only.", systemImage: "lock.shield")
            Button("Manage Photo Access") {
                viewModel.managePhotoAccess()
            }
        case .denied:
            Label("Photo access is off.", systemImage: "lock")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .restricted:
            Label("Device restrictions limit photo access.", systemImage: "lock")
        case .authorized:
            Label("Full photo access", systemImage: "photo.on.rectangle")
        case .notDetermined, .unknown:
            Label("Photo access is requested when you scan.", systemImage: "lock")
        }
    }
}

private struct SettingsView: View {
    let viewModel: CleanerViewModel

    var body: some View {
        List {
            Section("Photo Access") { PhotoAccessView(viewModel: viewModel) }
            Section("Cleanup") {
                CleanupStatus(viewModel: viewModel)
                NavigationLink("Cleanup History") { HistoryView(viewModel: viewModel) }
                NavigationLink("Recover Deleted Items") { List { PhotoRecoveryGuide() }.navigationTitle("Recovery") }
            }
            Section("Privacy") {
                Text("Cleaner scans screenshots on this iPhone. Cleanup history and the free allowance are stored on this device.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

struct CleanupStatus: View {
    let viewModel: CleanerViewModel

    var body: some View {
        if viewModel.submitting {
            ProgressView("Waiting for Photos")
        } else if viewModel.remaining == nil {
            Text("The cleanup record is unavailable. Try again to continue.")
            Button("Retry Cleanup Record") { viewModel.reloadStorage() }
        } else if let pending = viewModel.pending, pending.confirmedAt == nil {
            Text("We couldn’t confirm the result. Check Recently Deleted in Photos before continuing.")
            Button("I Checked Photos") { viewModel.acknowledgeUnknown() }
        } else if let remaining = viewModel.remaining {
            LabeledContent("Free items remaining", value: remaining.formatted())
        }
    }
}

private struct HistoryView: View {
    let viewModel: CleanerViewModel
    @State private var confirmClear = false

    var body: some View {
        List {
            if viewModel.history.isEmpty {
                ContentUnavailableView("No Cleanup History", systemImage: "clock")
            } else {
                ForEach(viewModel.history) { entry in
                    LabeledContent {
                        Text(entry.count.formatted())
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                            Text("Screenshots removed").foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Clear History", role: .destructive) { confirmClear = true }
                    .disabled(viewModel.submitting)
            }
        }
        .navigationTitle("Cleanup History")
        .confirmationDialog("Clear cleanup history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { viewModel.clearHistory() }
        } message: {
            Text("Your remaining free allowance stays the same.")
        }
    }
}

struct PhotoRecoveryGuide: View {
    var body: some View {
        if #available(iOS 18, *) {
            Text("To recover items, open Photos and find Recently Deleted under Utilities.")
        } else {
            Text("To recover items, open Photos, tap Albums, then find Recently Deleted under Utilities.")
        }
        Text("If you use iCloud Photos, deletions can sync to your other devices. Deleting items from a Shared Library can affect everyone who uses it.")
    }
}

private struct SampleCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = false

    var body: some View {
        NavigationStack {
            List {
                Section("Sample photos") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Weekend checklist", systemImage: "checklist")
                            .font(.title2.weight(.semibold))
                        Text("Pack charger\nDownload tickets\nCheck train times")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    Toggle("Select sample screenshot", isOn: $selected)
                }
                if selected {
                    Section("Sample Review") {
                        Text("1 screenshot selected")
                        PhotoRecoveryGuide()
                    }
                }
            }
            .navigationTitle("Sample Cleanup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

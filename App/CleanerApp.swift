import Photos
import SwiftUI

@main
struct CleanerApp: App {
    @State private var model = CleanerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    CleanView(model: model)
                }
                .tabItem { Label("Clean", systemImage: "square.stack") }
                NavigationStack {
                    SettingsView(model: model)
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(Color(red: 0.05, green: 0.42, blue: 0.36))
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    model.reloadStorage()
                    model.setForeground(true)
                } else if phase == .background {
                    model.setForeground(false)
                }
            }
            .alert("Cleaner", isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.dismissNotice() } }
            )) {
                Button("OK") { model.dismissNotice() }
            } message: {
                if let notice = model.notice {
                    Text(notice)
                }
            }
            .sheet(item: Binding(
                get: { model.result },
                set: { if $0 == nil { model.dismissResult() } }
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
                            CleanupStatus(model: model)
                            NavigationLink("Cleanup History") { HistoryView(model: model) }
                        }
                    }
                    .navigationTitle("Cleanup Complete")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.dismissResult() }
                        }
                    }
                }
            }
        }
    }
}

private struct CleanView: View {
    let model: CleanerModel
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
                    if model.hasAccess || model.access == .notDetermined {
                        Button {
                            Task { await model.scan() }
                        } label: {
                            Group {
                                if model.scanned {
                                    Text("Refresh Screenshots")
                                } else {
                                    Text("Scan My Photos")
                                }
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.scanning || model.requestingAccess || model.submitting)
                        .accessibilityIdentifier("scan-photos")
                    }
                }
                .padding(.vertical, 12)
            }
            Section {
                PhotoAccessView(model: model)
                if model.scanning {
                    ProgressView("Finding screenshots")
                } else if model.requestingAccess {
                    ProgressView("Waiting for photo access")
                } else if model.scanned, model.hasAccess {
                    if model.count == 0 {
                        Label("No screenshots found in the photos we can access.", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            ScreenshotList(model: model)
                        } label: {
                            LabeledContent {
                                Text(model.count.formatted())
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
                CleanupStatus(model: model)
                NavigationLink("Cleanup History") { HistoryView(model: model) }
            }
        }
        .navigationTitle("Clean")
        .sheet(isPresented: $showSample) { SampleCleanupView() }
    }
}

private struct PhotoAccessView: View {
    let model: CleanerModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch model.access {
        case .limited:
            Label("Scanning selected photos only.", systemImage: "lock.shield")
            Button("Manage Photo Access") {
                showLimitedLibraryPicker { model.refresh() }
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
        default:
            Label("Photo access is requested when you scan.", systemImage: "lock")
        }
    }
}

private struct SettingsView: View {
    let model: CleanerModel

    var body: some View {
        List {
            Section("Photo Access") { PhotoAccessView(model: model) }
            Section("Cleanup") {
                CleanupStatus(model: model)
                NavigationLink("Cleanup History") { HistoryView(model: model) }
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
    let model: CleanerModel

    var body: some View {
        if model.submitting {
            ProgressView("Waiting for Photos")
        } else if model.remaining == nil {
            Text("The cleanup record is unavailable. Try again to continue.")
            Button("Retry Cleanup Record") { model.reloadStorage() }
        } else if let pending = model.pending, pending.confirmedAt == nil {
            Text("We couldn’t confirm the result. Check Recently Deleted in Photos before continuing.")
            Button("I Checked Photos") { model.acknowledgeUnknown() }
        } else if let remaining = model.remaining {
            LabeledContent("Free items remaining", value: remaining.formatted())
        }
    }
}

private struct HistoryView: View {
    let model: CleanerModel
    @State private var confirmClear = false

    var body: some View {
        List {
            if model.history.isEmpty {
                ContentUnavailableView("No Cleanup History", systemImage: "clock")
            } else {
                ForEach(model.history) { entry in
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
                    .disabled(model.submitting)
            }
        }
        .navigationTitle("Cleanup History")
        .confirmationDialog("Clear cleanup history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
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

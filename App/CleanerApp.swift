import SwiftUI

@main
struct CleanerApp: App {
    @State private var viewModel = CleanerViewModel(
        library: ScreenshotLibrary(), openStore: CleanupStore.openLocal
    )

    var body: some Scene {
        WindowGroup {
            CleanerRootView(viewModel: viewModel)
        }
    }
}

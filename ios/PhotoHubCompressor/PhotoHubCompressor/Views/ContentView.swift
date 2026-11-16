import SwiftUI

struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var viewModel: CompressorViewModel

    init(settings: AppSettings) {
        self.settings = settings
        _viewModel = StateObject(wrappedValue: CompressorViewModel(settings: settings))
    }

    var body: some View {
        TabView {
            LibraryView(viewModel: viewModel)
                .tabItem {
                    Label("Compress", systemImage: "photo.stack")
                }

            ServerGalleryView(settings: settings)
                .tabItem {
                    Label("Server", systemImage: "cloud")
                }

            SettingsView(settings: settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

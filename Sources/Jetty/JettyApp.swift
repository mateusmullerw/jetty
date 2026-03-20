import SwiftUI

@main
struct JettyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = PortViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(viewModel)
        } label: {
            Image(systemName: "brakesignal.dashed")
        }
        .menuBarExtraStyle(.window)
    }
}

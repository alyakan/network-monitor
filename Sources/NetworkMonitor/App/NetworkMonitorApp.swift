import AppKit
import SwiftUI

@main
struct NetworkMonitorApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Network Monitor") {
            ContentView(model: model)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    model.start()
                }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Setup Guide", action: model.showGuide)
                    .keyboardShortcut("?", modifiers: .command)
                Link("Network Monitor on GitHub", destination: URL(string: "https://github.com/alyakan/network-monitor")!)
            }
        }
    }
}

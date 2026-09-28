import BharatStockCore
import SwiftUI

@main
struct BharatStockApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("BharatStock Widget", id: "main") {
            MainView(model: model)
                .frame(minWidth: 620, minHeight: 560)
                .onAppear { model.onAppear() }
                .onOpenURL { model.handle(url: $0) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Now") {
                    Task { await model.refreshNow() }
                }
                .keyboardShortcut("r")
                .disabled(model.isRefreshing)

                Divider()

                Button("Reveal Configuration in Finder") { model.revealConfigInFinder() }
                Button("Reveal Logs in Finder") { model.revealLogsInFinder() }
            }
        }
    }
}

import SwiftUI

@main
struct ShareToObsidianApp: App {
    @State private var model: CaptureListModel

    @MainActor
    init() {
        _model = State(initialValue: CaptureListModel())
        BackgroundSyncScheduler.register()
        BackgroundSyncScheduler.schedule()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

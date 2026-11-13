import SwiftUI

@main
struct IndraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        IndraLog.start()
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

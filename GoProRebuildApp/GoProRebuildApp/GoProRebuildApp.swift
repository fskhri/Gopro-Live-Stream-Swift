import GoProKit
import SwiftUI

@main
struct GoProRebuildApp: App {
    /// App-wide services container, replaced Hilt's `AppModule`.
    @StateObject private var services = GoProServices()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                // The direction in DESIGN.md is dark chrome; the remote is used
                // next to a camera, not in daylight reading.
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

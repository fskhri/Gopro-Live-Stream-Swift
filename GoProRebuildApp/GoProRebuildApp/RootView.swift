import GoProKit
import SwiftUI

/// Top-level flow: scan → connected control, back to scan on disconnect.
///
/// Replaces the Android `MainActivity` back stack. Two screens exist in this
/// build, so the stack holds two screens and nothing points at a screen that
/// was not ported yet.
struct RootView: View {
    @EnvironmentObject private var services: GoProServices
    @State private var debugCamera: GoProCamera?

    var body: some View {
        NavigationStack {
            Group {
                if let camera = services.connectedCamera ?? debugCamera {
                    ControlView(camera: camera)
                        .id(camera.device.identifier)
                } else {
                    ScanView(services: services)
                }
            }
            .background(Theme.background)
        }
        .tint(Theme.accent)
        // Debug render check, no-op without the launch argument and compiled
        // out of release builds. See RenderCheck.swift.
        .task {
            #if DEBUG
            if debugCamera == nil {
                debugCamera = RenderCheck.camera(services: services)
            }
            #endif
        }
    }
}

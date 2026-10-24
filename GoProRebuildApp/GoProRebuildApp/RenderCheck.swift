#if DEBUG
import Foundation
import GoProKit

/// Render check for the control screen, debug builds only.
///
/// The iOS simulator has no Bluetooth radio, so a real camera cannot be reached
/// there and the control screen would never render. Launching the app with
/// `-control-screen-check` builds the camera object by hand so the layout can be
/// reviewed at real device size.
///
/// This is a review aid, not product behaviour: it is compiled out of release
/// builds, it only runs when the argument is passed, and the camera it returns
/// describes no real link, which the status strip keeps showing.
enum RenderCheck {
    static let argument = "-control-screen-check"

    /// Same as `argument`, but the control screen opens scrolled to the
    /// bottom so the lower half can be photographed in the simulator.
    static let bottomArgument = "-control-screen-check-bottom"

    /// TikTok live screen review: no camera and no TikTok account needed,
    /// because nothing on that screen reaches the network until it is started.
    static let tiktokArgument = "-tiktok-screen-check"

    /// Same as `tiktokArgument`, opened scrolled to the bottom.
    static let tiktokBottomArgument = "-tiktok-screen-check-bottom"

    static var opensTikTokScreen: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(tiktokArgument) || arguments.contains(tiktokBottomArgument)
    }

    static var opensTikTokScreenBottom: Bool {
        ProcessInfo.processInfo.arguments.contains(tiktokBottomArgument)
    }

    @MainActor
    static func camera(services: GoProServices) -> GoProCamera? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(argument) || arguments.contains(bottomArgument) else { return nil }

        let device = GoProDevice(
            identifier: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!,
            name: "HERO12 Black",
            rssi: -52,
            isPaired: false
        )
        let camera = GoProCamera(
            device: device,
            central: services.central,
            wifi: services.wifi,
            api: services.api
        )
        // The screen under review is the connected layout, so the camera is
        // marked connected; no BLE or WiFi link exists behind it.
        camera.markWiFiOnly()
        return camera
    }
}
#endif

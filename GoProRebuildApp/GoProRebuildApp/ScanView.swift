import GoProKit
import SwiftUI

/// Discovery screen. Port of `ui/screens/ScanScreen.kt`.
///
/// iOS has no bonded-device list, so every camera comes from a live scan; the
/// same 15-second scan window the Android view model used is kept.
struct ScanView: View {
    @ObservedObject private var services: GoProServices
    @ObservedObject private var scanner: GoProScanner
    @ObservedObject private var central: GoProBluetoothCentral

    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showAllDevices = false

    init(services: GoProServices) {
        self.services = services
        self.scanner = services.scanner
        self.central = services.central
    }

    var body: some View {
        VStack(spacing: 0) {
            if scanner.isScanning {
                ProgressView(value: 0.5)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }

            content

            footer
        }
        .background(Theme.background)
        .navigationTitle("Find GoPro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await toggleScan() }
                } label: {
                    Label(
                        scanner.isScanning ? "Stop" : "Scan",
                        systemImage: scanner.isScanning ? "stop.circle" : "arrow.clockwise"
                    )
                }
                .disabled(isConnecting || isBluetoothBlocked)
            }
        }
        .task { await startScan() }
    }

    // MARK: - Body pieces

    @ViewBuilder
    private var content: some View {
        if isConnecting {
            StatusBlock {
                ProgressView()
                    .tint(Theme.accent)
                Text("Connecting…")
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
            }
        } else if isBluetoothBlocked {
            bluetoothBlockedState
        } else if scanner.devices.isEmpty && !scanner.isScanning {
            emptyState
        } else {
            deviceList
        }
    }

    private var bluetoothBlockedState: some View {
        StatusBlock {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.warn)
            Text(bluetoothBlockedTitle)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(bluetoothBlockedHint)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var emptyState: some View {
        StatusBlock {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("No GoPro cameras found")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Make sure your GoPro is turned ON and Bluetooth is enabled on your camera and phone.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Scan Again") {
                Task { await startScan() }
            }
            .buttonStyle(PrimaryButton())
            .frame(maxWidth: 220)
            .padding(.top, 4)
        }
    }

    /// The device that was connected last time, if it is in range.
    private var knownDevice: GoProDevice? {
        guard let lastID = services.lastDeviceIdentifier else { return nil }
        return scanner.devices.first { $0.identifier == lastID }
    }

    /// Hide unknown cameras by default — a crowded area shows dozens.
    private var visibleDevices: [GoProDevice] {
        let sorted = scanner.devices.sorted { $0.rssi > $1.rssi }
        if showAllDevices { return sorted }
        if let known = knownDevice { return [known] }
        return sorted  // No known device yet → show all so user can pick one
    }

    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(visibleDevices) { device in
                    DeviceRow(device: device) {
                        Task { await connect(device) }
                    }
                }

                if let message = errorMessage ?? services.lastError {
                    ErrorBanner(message: message) { errorMessage = nil }
                }

                // Show toggle when there are hidden cameras
                if !showAllDevices, knownDevice != nil, scanner.devices.count > 1 {
                    Button {
                        showAllDevices = true
                    } label: {
                        Text("Show \(scanner.devices.count - 1) other cameras nearby")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.top, 8)
                } else if showAllDevices, knownDevice != nil {
                    Button {
                        showAllDevices = false
                    } label: {
                        Text("Hide other cameras")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let message = errorMessage ?? services.lastError, scanner.devices.isEmpty {
                ErrorBanner(message: message) { errorMessage = nil }
            }

            Button {
                Task { await connectOverWiFi() }
            } label: {
                Label("Connect via camera WiFi (10.5.5.9)", systemImage: "wifi")
            }
            .buttonStyle(SecondaryButton())
            .disabled(isConnecting)
        }
        .padding(16)
        .background(Theme.surface)
    }

    // MARK: - State helpers

    private var isBluetoothBlocked: Bool {
        switch central.state {
        case .poweredOn, .unknown, .resetting: return false
        case .unauthorized, .unsupported, .poweredOff: return true
        }
    }

    private var bluetoothBlockedTitle: String {
        switch central.state {
        case .unauthorized: return "Bluetooth permission denied"
        case .unsupported: return "Bluetooth unavailable"
        default: return "Bluetooth is off"
        }
    }

    private var bluetoothBlockedHint: String {
        switch central.state {
        case .unauthorized:
            return "Allow Bluetooth for this app in Settings to find cameras."
        case .unsupported:
            return "This device cannot scan for GoPro cameras over Bluetooth."
        default:
            return "Turn Bluetooth on, then scan again."
        }
    }

    // MARK: - Actions

    private func toggleScan() async {
        if scanner.isScanning {
            scanner.stopScan()
        } else {
            await startScan()
        }
    }

    private func startScan() async {
        errorMessage = nil
        scanner.clear()
        do {
            try await scanner.startScan()
        } catch {
            // The blocked state already explains the Bluetooth problem; a
            // second banner with the same words just repeats it.
            if !isBluetoothBlocked {
                errorMessage = error.localizedDescription
            }
            return
        }

        // Same auto-stop window as ScanViewModel.startScan().
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        if scanner.isScanning {
            scanner.stopScan()
        }
    }

    private func connect(_ device: GoProDevice) async {
        isConnecting = true
        errorMessage = nil
        let camera = await services.connect(to: device)
        isConnecting = false
        if camera == nil {
            errorMessage = services.lastError
        }
    }

    private func connectOverWiFi() async {
        isConnecting = true
        errorMessage = nil
        let camera = await services.connectOverWiFiOnly()
        isConnecting = false
        if camera == nil {
            errorMessage = services.lastError
        }
    }
}

/// One discovered camera.
private struct DeviceRow: View {
    let device: GoProDevice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(signalLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }

                Spacer(minLength: 8)

                if device.isPaired {
                    Text("Paired")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(16)
            .frame(minHeight: Theme.rowHeight)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            device.isPaired ? "\(device.name), paired, \(signalLabel)" : "\(device.name), \(signalLabel)"
        )
        .accessibilityHint("Connects to this camera")
    }

    private var signalLabel: String {
        device.rssi == 0 ? "Signal unknown" : "Signal \(device.rssi) dBm"
    }
}

/// Inline failure message with a dismiss action.
private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.record)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Dismiss", action: onDismiss)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
    }
}

/// Centred message block used by the connecting, blocked and empty states.
private struct StatusBlock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 12) {
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

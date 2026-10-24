import GoProKit
import SwiftUI

/// Camera control screen. Port of `ui/screens/ControlScreen.kt`.
///
/// The app offers the actions that exist on this build: WiFi join, mode switch,
/// shutter, sleep, disconnect, live preview, and the TikTok live screen.
struct ControlView: View {
    @ObservedObject var camera: GoProCamera
    @EnvironmentObject private var services: GoProServices
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showLiveScreen = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    statusStrip

                    if needsWifi {
                        wifiCard
                    }

                    modeSelector

                    previewSection

                    liveCard

                    storageLine

                    shutter

                    secondaryActions
                }
                .padding(16)
                .id("controlContent")
            }
            // Screenshot aid: the simulator cannot be scrolled from outside,
            // so the render check pins the review copy to the bottom. No-op
            // unless the launch argument is passed, compiled out of release.
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains(RenderCheck.bottomArgument) {
                    proxy.scrollTo("controlContent", anchor: .bottom)
                }
                #endif
            }
        }
        .background(Theme.background)
        .navigationTitle(camera.status.cameraInfo?.model ?? camera.device.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showLiveScreen) {
            TikTokLiveView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { batteryPill }
        }
        .overlay {
            if isBusy {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(20)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
            }
        }
        .alert("Camera error", isPresented: hasError) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await statusLoop() }
        .task { await keepAliveLoop() }
        // The player outlives this screen, so leaving the camera completely (disconnect)
        // stops the stream instead of leaving the camera pushing in background.
        .onDisappear {
            if services.connectedCamera == nil {
                Task {
                    await services.live.stop()
                    await services.preview.stop()
                }
            }
        }
        .onAppear {
            #if DEBUG
            if RenderCheck.opensTikTokScreen {
                showLiveScreen = true
            }
            #endif
        }
    }

    // MARK: - Header pieces

    /// The camera name lives in the navigation title, so the strip carries only
    /// the link state and firmware; repeating the name cost a lot of height at
    /// accessibility text sizes.
    private var statusStrip: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(linkColor)
                .frame(width: 8, height: 8)

            Text(linkLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            if let firmware = camera.status.cameraInfo?.firmware, firmware != "Unknown" {
                Text("FW \(firmware)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    private var batteryPill: some View {
        HStack(spacing: 4) {
            Image(systemName: batterySymbol)
                .font(.system(size: 15))
                .foregroundStyle(batteryColor)
            Text(batteryLabel)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Battery \(batteryLabel)")
    }

    /// Stacked rather than side-by-side: at accessibility text sizes the
    /// row version squeezed the caption into a column and broke the button
    /// word by word.
    private var wifiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .foregroundStyle(Theme.accent)
                Text("Connect WiFi")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }

            Text("Enable higher bitrate control and the camera HTTP API.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Button("Connect") {
                Task { await connectWiFi() }
            }
            .buttonStyle(PrimaryButton())
            .disabled(isBusy)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentDeep.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
        )
    }

    /// Side by side normally; at accessibility text sizes each child keeps its
    /// one-line intrinsic width, so the row runs off the screen. Stacked, every
    /// control gets the full width and the labels fit on one line.
    private var modeSelector: some View {
        let chips = ForEach(PresetGroup.allCases) { mode in
            ModeChip(
                mode: mode,
                isSelected: camera.status.currentMode == mode,
                action: { Task { await setMode(mode) } }
            )
        }

        return Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { chips }
            } else {
                HStack(spacing: 8) { chips }
            }
        }
    }

    /// Live preview: an idle slot that states what it does, the waiting state
    /// while the camera is asked to stream, and the picture once frames arrive.
    private var previewSection: some View {
        PreviewCard(
            player: services.preview,
            canStart: !needsWifi,
            onStart: { Task { await startPreview() } },
            onStop: { Task { await stopPreview() } }
        )
    }

    /// Entry to the TikTok live screen. It carries no state of its own: the
    /// room, the push and the sign in all live behind that screen.
    private var liveCard: some View {
        NavigationLink {
            TikTokLiveView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TikTok Live")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Push the preview to a live room.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the TikTok live screen.")
    }

    private var storageLine: some View {
        HStack {
            Text("SD card free")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text(freeSpaceLabel)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Shutter

    private var shutter: some View {
        Button {
            Task { await toggleShutter() }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(camera.status.isRecording ? 0.4 : 0.9), lineWidth: 4)
                    .frame(width: Theme.shutterDiameter, height: Theme.shutterDiameter)

                shutterCore
            }
            .frame(width: Theme.shutterDiameter, height: Theme.shutterDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || !camera.status.isConnected)
        .opacity(camera.status.isConnected ? 1 : 0.45)
        .accessibilityLabel(camera.status.isRecording ? "Stop recording" : "Start recording")
        .accessibilityHint(shutterModeHint)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var shutterCore: some View {
        if camera.status.isRecording {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.record)
                .frame(width: 32, height: 32)
        } else {
            Circle()
                .fill(camera.status.currentMode == .photo ? Color.white : Theme.record)
                .frame(width: 64, height: 64)
        }
    }

    private var shutterModeHint: String {
        if camera.status.isRecording { return "Stops \(camera.status.currentMode.label.lowercased()) capture" }
        return "Starts \(camera.status.currentMode.label.lowercased()) capture"
    }

    // MARK: - Secondary actions

    private var secondaryActions: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) { sleepButton; disconnectButton }
            } else {
                HStack(spacing: 12) { sleepButton; disconnectButton }
            }
        }
    }

    private var sleepButton: some View {
        Button {
            Task { await sleepCamera() }
        } label: {
            Label("Sleep", systemImage: "moon.zzz")
        }
        .buttonStyle(SecondaryButton())
        .disabled(isBusy)
    }

    private var disconnectButton: some View {
        Button {
            Task { await disconnect() }
        } label: {
            Label("Disconnect", systemImage: "bolt.slash")
        }
        .buttonStyle(SecondaryButton())
    }

    // MARK: - Derived state

    private var needsWifi: Bool {
        if case .connected = camera.wifiState { return false }
        return true
    }

    private var linkLabel: String {
        switch camera.wifiState {
        case .connected: return "WiFi connected"
        case .connecting: return "Connecting WiFi…"
        case .error(let message): return "WiFi error: \(message)"
        case .disconnected:
            switch camera.bleState {
            case .connected: return "Bluetooth LE"
            case .connecting: return "Connecting Bluetooth…"
            case .error(let message): return "Bluetooth error: \(message)"
            case .disconnected: return "Disconnected"
            }
        }
    }

    private var linkColor: Color {
        switch camera.wifiState {
        case .connected: return Theme.ok
        case .error: return Theme.record
        case .connecting: return Theme.warn
        case .disconnected:
            if case .connected = camera.bleState { return Theme.ok }
            return Theme.textMuted
        }
    }

    private var batteryLabel: String {
        camera.status.batteryLevel > 0 ? "\(camera.status.batteryLevel)%" : "--%"
    }

    private var batterySymbol: String {
        switch camera.status.batteryLevel {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 1...: return "battery.25"
        default: return "battery.0"
        }
    }

    private var batteryColor: Color {
        switch camera.status.batteryLevel {
        case 21...: return Theme.ok
        case 1...: return Theme.warn
        default: return Theme.textMuted
        }
    }

    private var freeSpaceLabel: String {
        guard camera.status.sdCardSpaceRemaining > 0 else { return "unknown" }
        return ByteCountFormatter.string(
            fromByteCount: camera.status.sdCardSpaceRemaining,
            countStyle: .file
        )
    }

    private var hasError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - Loops

    /// Android refreshed status every 5 s from the control view model.
    private func statusLoop() async {
        await camera.refreshStatus()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            await camera.refreshStatus()
        }
    }

    /// Android sent a BLE keep alive every 30 s.
    private func keepAliveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            await camera.keepAlive()
        }
    }

    // MARK: - Actions

    private func run(_ action: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func toggleShutter() async {
        await run {
            if camera.status.isRecording {
                try await camera.stopRecording()
            } else {
                try await camera.startRecording()
            }
        }
    }

    private func setMode(_ mode: PresetGroup) async {
        await run { try await camera.setMode(mode) }
    }

    private func connectWiFi() async {
        await run { try await camera.connectWiFi() }
    }

    private func startPreview() async {
        do {
            try await services.preview.start()
        } catch {
            // The player publishes the reason itself, so the card carries the
            // message instead of an alert that would hide the screen.
        }
    }

    private func stopPreview() async {
        await services.preview.stop()
    }

    private func sleepCamera() async {
        await run { try await camera.powerOff() }
    }

    private func disconnect() async {
        await services.preview.stop()
        await services.disconnect()
    }
}

/// Live preview card: the picture, its state, and the single control the
/// current state needs. Stacked so the button keeps full width at
/// accessibility text sizes.
private struct PreviewCard: View {
    @ObservedObject var player: GoProPreviewPlayer
    let canStart: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                PreviewSurface(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                if case .streaming = player.state {
                    liveBadge
                } else {
                    placeholder
                }
            }
            .background(Color.black, in: RoundedRectangle(cornerRadius: Theme.corner))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live camera preview")
            .accessibilityValue(summary)

            actionButton
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            if case .waitingForCamera = player.state {
                ProgressView()
                    .tint(Theme.accent)
                Text("Waiting for the camera…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textMuted)
                Text(placeholderTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !placeholderCaption.isEmpty {
                    Text(placeholderCaption)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.record)
                .frame(width: 8, height: 8)
            Text("LIVE")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.55), in: Capsule())
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Control

    @ViewBuilder
    private var actionButton: some View {
        if isActive {
            Button {
                onStop()
            } label: {
                Label("Stop preview", systemImage: "stop.circle")
            }
            .buttonStyle(SecondaryButton())
        } else {
            VStack(spacing: 6) {
                Button {
                    onStart()
                } label: {
                    Label("Start live preview", systemImage: "play.circle")
                }
                .buttonStyle(PrimaryButton())
                .disabled(!canStart)

                if !canStart {
                    Text("Join the camera's WiFi to use live preview.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Derived

    private var isActive: Bool {
        switch player.state {
        case .streaming, .waitingForCamera: return true
        case .idle, .failed: return false
        }
    }

    private var placeholderSymbol: String {
        if case .failed = player.state { return "exclamationmark.triangle" }
        return "video"
    }

    private var placeholderTitle: String {
        if case .failed = player.state { return "Preview stopped" }
        return "Live preview"
    }

    private var placeholderCaption: String {
        switch player.state {
        case .failed(let message): return message
        case .idle: return "Starts the camera stream over its own WiFi."
        default: return ""
        }
    }

    private var summary: String {
        switch player.state {
        case .idle: return "Stopped"
        case .waitingForCamera: return "Waiting for the camera"
        case .streaming: return "On"
        case .failed: return "Stopped, preview unavailable"
        }
    }
}

/// One capture-mode chip.
private struct ModeChip: View {
    let mode: PresetGroup
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                Text(mode.label)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget)
            .background(
                (isSelected ? Theme.accent : Theme.surfaceRaised),
                in: RoundedRectangle(cornerRadius: Theme.corner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(Color.white.opacity(isSelected ? 0 : 0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.label) mode")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var symbol: String {
        switch mode {
        case .video: return "video.fill"
        case .photo: return "camera.fill"
        case .timelapse: return "timer"
        }
    }
}

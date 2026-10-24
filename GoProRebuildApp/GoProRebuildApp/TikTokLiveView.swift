import GoProKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Opens a TikTok LIVE room and pushes the camera preview into it.
///
/// Port of `ui/screens/TiktokStreamScreen.kt`, matching Android UX:
/// audio VU meter, import file/paste cookies, speaker mute, live overlays.
struct TikTokLiveView: View {
    @EnvironmentObject private var services: GoProServices

    var body: some View {
        TikTokLiveContent(live: services.live, tiktok: services.tiktok, preview: services.preview)
            .navigationTitle("TikTok Live")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Audio VU Meter

/// 14-bar real-time audio meter with green/yellow/red zones.
private struct AudioVuMeter: View {
    let level: Float
    private let barCount = 14

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white)
            Text("GoPro Mic")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.8))
            Spacer(minLength: 4)
            ForEach(0..<barCount, id: \.self) { i in
                let isActive = i < Int(level * Float(barCount)).clamped(to: 0...barCount)
                let color: Color = {
                    if i >= 11 { return Color(red: 1, green: 0.27, blue: 0.23) } // Red (peak)
                    if i >= 8 { return Color(red: 1, green: 0.84, blue: 0.04) }  // Yellow (high)
                    return Color(red: 0.19, green: 0.82, blue: 0.35)             // Green (nominal)
                }()
                RoundedRectangle(cornerRadius: 1)
                    .fill(isActive ? color : color.opacity(0.25))
                    .frame(width: 3, height: CGFloat(7 + i) * 1.1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Content

private struct TikTokLiveContent: View {
    @ObservedObject var live: GoProLiveStreamer
    let tiktok: GoProTikTokService
    @ObservedObject var preview: GoProPreviewPlayer

    @State private var title = "GoPro stream"
    @State private var topic = GoProTikTokTopic.all[0]
    @State private var region = GoProTikTokRegion.all[0]
    @State private var keepReplay = false
    @State private var closeRoomOnEnd = true
    @State private var mature = false
    @State private var gameTags: [String: String] = [:]
    @State private var gameTagID = "0"
    @State private var isLoggedIn = GoProTikTokCookieStore.shared.hasSessionID
    @State private var showingLogin = false
    @State private var showingPasteDialog = false
    @State private var showingFilePicker = false
    @State private var pasteText = ""
    @State private var isStarting = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var copiedLabel: String?
    @State private var isSpeakerMuted = false
    @State private var showAdvancedSettings = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    // 1. HERO: Camera Viewfinder with Live Overlays
                    viewfinderCard
                    
                    // Error/Success messages
                    if let err = errorMessage ?? live.lastError {
                        messageBanner(err, isError: true)
                    }
                    if let warning = live.warning {
                        messageBanner(warning, isError: true)
                    }
                    if let msg = successMessage {
                        messageBanner(msg, isError: false)
                    }
                    
                    // 2. Main Live Control
                    mainControlCard
                    
                    // 3. TikTok Session Status & Cookies
                    sessionCard
                    
                    // 4. Advanced Settings (collapsible)
                    advancedSettingsCard
                }
                .padding(16)
                .id("tiktokContent")
            }
            .onAppear {
                #if DEBUG
                if RenderCheck.opensTikTokScreenBottom {
                    proxy.scrollTo("tiktokContent", anchor: .bottom)
                }
                #endif
                if preview.state == .idle {
                    Task {
                        try? await preview.start()
                    }
                }
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $showingLogin, onDismiss: refreshLoginState) {
            TikTokLoginView()
        }
        .sheet(isPresented: $showingFilePicker) {
            CookieFileImporter(onImport: importCookies)
        }
        .alert("Paste Cookie TikTok", isPresented: $showingPasteDialog) {
            TextField("Paste cookies here...", text: $pasteText, axis: .vertical)
                .lineLimit(5...10)
            Button("Save") {
                if !pasteText.isEmpty {
                    importCookies(pasteText.trimmingCharacters(in: .whitespacesAndNewlines))
                    pasteText = ""
                }
            }
            Button("Cancel", role: .cancel) { pasteText = "" }
        } message: {
            Text("Paste JSON array from EditThisCookie or raw cookie string.")
        }
        .task { await loadGameTags() }
    }

    // MARK: - Viewfinder Card (Android CameraViewfinder equivalent)
    
    private var viewfinderCard: some View {
        ZStack {
            // Preview surface
            PreviewSurface(player: preview)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            
            // Overlay when no preview
            if preview.state != .streaming {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.gray)
                    Text(previewCaption)
                        .font(.caption)
                        .foregroundStyle(Color.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
            }
            
            // Top-left overlay: Live/Standby status
            VStack {
                HStack {
                    liveStatusBadge
                    Spacer()
                    topRightControls
                }
                .padding(10)
                Spacer()
                HStack {
                    audioMeter
                    Spacer()
                }
                .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isLiveActive ? Theme.record : Color(white: 0.18), lineWidth: isLiveActive ? 2 : 1)
        )
        .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 14))
    }
    
    @ViewBuilder
    private var liveStatusBadge: some View {
        let stats = live.statistics
        if live.status == .reconnecting {
            HStack(spacing: 6) {
                ProgressView()
                    .tint(Color.orange)
                    .scaleEffect(0.7)
                Text("RECONNECTING")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
        } else if isLiveActive {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 8, height: 8)
                Text("LIVE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.record)
                Text(formatDuration(stats.durationSeconds))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.white)
                if stats.bitrateKbps > 0 {
                    Text("\(Int(stats.bitrateKbps))k")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                if stats.fps > 0 {
                    Text("\(Int(stats.fps))fps")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                #if os(iOS)
                if preview.pipManager.isPipActive {
                    Text("PiP")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                }
                #endif
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(preview.state == .streaming ? Theme.ok : Color.gray)
                    .frame(width: 7, height: 7)
                Text(preview.state == .streaming ? "STANDBY" : "OFFLINE")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        }
    }
    
    private var topRightControls: some View {
        HStack(spacing: 6) {
            // Picture-in-Picture toggle
            #if os(iOS)
            if preview.pipManager.isPipPossible {
                Button {
                    preview.pipManager.togglePip()
                } label: {
                    Image(systemName: preview.pipManager.isPipActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 14))
                        .foregroundStyle(preview.pipManager.isPipActive ? Theme.accent : Color.white)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.65), in: Circle())
                }
            }
            #endif

            // Speaker mute toggle
            Button {
                isSpeakerMuted.toggle()
                // TODO: Connect to preview audio mute
            } label: {
                Image(systemName: isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isSpeakerMuted ? Theme.record : Color.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.65), in: Circle())
            }
            
            // Refresh preview
            Button {
                Task {
                    await preview.stop()
                    preview.recreateDisplayLayer()
                    try? await preview.start()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.65), in: Circle())
            }
        }
    }
    
    @ViewBuilder
    private var audioMeter: some View {
        // Show VU meter when streaming
        if isLiveActive || preview.state == .streaming {
            AudioVuMeter(level: live.audioLevel)
        }
    }
    
    // MARK: - Message Banners
    
    private func messageBanner(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Theme.record : Theme.ok)
            Text(message)
                .font(.caption)
                .foregroundStyle(isError ? Theme.record : Theme.ok)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isError ? Color.red : Color.green).opacity(0.15),
            in: RoundedRectangle(cornerRadius: Theme.corner)
        )
    }
    
    // MARK: - Main Control Card
    
    private var mainControlCard: some View {
        VStack(spacing: 12) {
            TextField("Live Stream Title", text: $title)
                .padding(10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Theme.textPrimary)
                .disabled(isLiveActive)
            
            if isLiveActive {
                Button {
                    Task { await stopLive() }
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("End Live Streaming")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.record)
            } else {
                Button {
                    Task { await startLive() }
                } label: {
                    if live.status == .starting || isStarting {
                        HStack(spacing: 8) {
                            ProgressView().tint(Color.white)
                            Text("Preparing Live Room & Audio...")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    } else {
                        HStack {
                            Image(systemName: "video.fill")
                            Text("Start Live Streaming to TikTok")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.996, green: 0.173, blue: 0.333)) // TikTok pink
                .disabled(!isLoggedIn || isStarting || live.status == .starting)
            }
            
            // Relay stats when live
            if isLiveActive, live.statistics.videoTags > 0 {
                HStack {
                    Text("GoPro Packets: \(live.statistics.videoTags)")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    Text("Bitrate: \(Int(live.statistics.bitrateKbps)) kbps")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Session Card (Cookies status)
    
    private var sessionCard: some View {
        let hasSession = GoProTikTokCookieStore.shared.hasSessionID
        let cardColor: Color = {
            if isLoggedIn { return Color.green.opacity(0.15) }
            if hasSession { return Color.orange.opacity(0.15) }
            return Color.red.opacity(0.15)
        }()
        let iconColor: Color = {
            if isLoggedIn { return Theme.ok }
            if hasSession { return Color.orange }
            return Theme.record
        }()
        
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isLoggedIn ? "checkmark.circle.fill" : (hasSession ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isLoggedIn ? "TikTok Session Active" : (hasSession ? "Cookie Saved (Not verified)" : "Not Logged In"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(iconColor)
                    Text("sessionid: \(hasSession ? "Available" : "Empty")")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if isLoggedIn || hasSession {
                    Button("Logout") {
                        GoProTikTokCookieStore.shared.clear()
                        refreshLoginState()
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.record)
                }
            }
            
            if !isLoggedIn || !hasSession {
                HStack(spacing: 8) {
                    Button {
                        showingLogin = true
                    } label: {
                        Label("Login Web", systemImage: "globe")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Import File", systemImage: "doc.badge.plus")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                
                Button {
                    showingPasteDialog = true
                } label: {
                    Label("Paste Cookie Manual", systemImage: "doc.on.clipboard")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Advanced Settings Card (collapsible)
    
    private var advancedSettingsCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { showAdvancedSettings.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Theme.accent)
                    Text("Advanced Settings & RTMP Key")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: showAdvancedSettings ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(14)
            }
            
            if showAdvancedSettings {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    
                    // Topic
                    labeled("Topic / Category") {
                        Picker("Topic", selection: topicBinding) {
                            ForEach(GoProTikTokTopic.all) { t in
                                Text(t.label).tag(t)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    // Game tag (if gaming)
                    if topic.id == "gaming", !gameTags.isEmpty {
                        labeled("Game") {
                            Picker("Game", selection: $gameTagID) {
                                Text("None").tag("0")
                                ForEach(gameTags.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                                    Text(name).tag(id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    
                    // Region
                    labeled("Region Priority") {
                        Picker("Region", selection: $region) {
                            ForEach(GoProTikTokRegion.all) { r in
                                Text(r.label).tag(r)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Toggle("Save Replay on TikTok", isOn: $keepReplay)
                        .tint(Theme.accent)
                    
                    Toggle("Close Room when Stream Ends", isOn: $closeRoomOnEnd)
                        .tint(Theme.accent)
                    
                    Toggle("Mature Content", isOn: $mature)
                        .tint(Theme.accent)
                    
                    // RTMP info when live
                    if let info = live.streamInfo {
                        Divider()
                        Text("RTMP Stream Info")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        
                        rtmpInfoRow("Full RTMP URL", value: info.fullRtmpUrl)
                        rtmpInfoRow("Share URL", value: info.shareUrl)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .disabled(isLiveActive)
                .opacity(isLiveActive ? 0.6 : 1)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            content()
        }
    }
    
    private func rtmpInfoRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
            HStack {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = value
                    copiedLabel = "\(label) copied"
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copiedLabel = nil
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers
    
    private var isLiveActive: Bool {
        live.status == .streaming || live.status == .starting || live.status == .reconnecting
    }
    
    private var topicBinding: Binding<GoProTikTokTopic> {
        Binding(
            get: { topic },
            set: { newValue in
                topic = newValue
                gameTagID = "0"
            }
        )
    }
    
    private var previewCaption: String {
        switch preview.state {
        case .idle: return "The preview starts with the live stream."
        case .waitingForCamera: return "Waiting for the camera…"
        case .streaming: return ""
        case .failed(let message): return message
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if hrs > 0 {
            return String(format: "%02d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Actions
    
    private func refreshLoginState() {
        isLoggedIn = GoProTikTokCookieStore.shared.hasSessionID
    }
    
    private func importCookies(_ content: String) {
        // Try JSON array first (EditThisCookie format)
        if content.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            if let data = content.data(using: .utf8),
               let cookies = try? JSONDecoder().decode([EditThisCookie].self, from: data) {
                var cookieString = ""
                for cookie in cookies {
                    if let name = cookie.name, let value = cookie.value {
                        cookieString += "\(name)=\(value); "
                    }
                }
                GoProTikTokCookieStore.shared.import(cookies: cookieString)
                successMessage = "Imported \(cookies.count) cookies from JSON"
            } else {
                errorMessage = "Failed to parse JSON cookie array"
            }
        } else {
            // Raw cookie string
            GoProTikTokCookieStore.shared.import(cookies: content)
            successMessage = "Cookies imported"
        }
        refreshLoginState()
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            successMessage = nil
        }
    }

    private func loadGameTags() async {
        guard gameTags.isEmpty else { return }
        if let tags = try? await tiktok.fetchGameTags() {
            gameTags = tags
        }
    }

    private func startLive() async {
        guard isLoggedIn else { return }
        isStarting = true
        errorMessage = nil

        let options = GoProLiveStreamer.Options(
            title: title.isEmpty ? "GoPro stream" : title,
            hashtagId: topic.hashtagId,
            gameTagId: gameTagID,
            enableReplay: keepReplay,
            regionPriority: region.id,
            mature: mature
        )
        do {
            try await live.start(options: options)
        } catch {
            errorMessage = error.localizedDescription
        }
        isStarting = false
    }

    private func stopLive() async {
        await live.stop()
    }
}

// MARK: - EditThisCookie JSON format

private struct EditThisCookie: Decodable {
    let name: String?
    let value: String?
}

// MARK: - File Importer

private struct CookieFileImporter: UIViewControllerRepresentable {
    let onImport: (String) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.json, .plainText, .data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onImport: onImport)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onImport: (String) -> Void
        
        init(onImport: @escaping (String) -> Void) {
            self.onImport = onImport
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                onImport(content)
            }
        }
    }
}

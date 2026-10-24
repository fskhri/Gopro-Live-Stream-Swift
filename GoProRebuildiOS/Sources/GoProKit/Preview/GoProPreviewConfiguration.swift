import Foundation

/// Wire constants for the gpControl-era UDP live preview (HERO5/6/7).
///
/// Port of `media/PreviewPlayer.kt` and `media/GoProUdpDataSource.kt`. The
/// camera answers `gpStream` by pushing MPEG-TS over UDP to the client's port
/// 8554, and it stops pushing unless the client keeps sending a heartbeat.
public enum GoProPreviewConfiguration {
    /// Fixed camera address while joined to its hotspot.
    public static let cameraHost = "10.5.5.9"

    /// Port the client binds and the camera streams to.
    public static let streamPort: UInt16 = 8554

    /// GoPro header prepended to each preview datagram: sequence counter at
    /// byte 9, big-endian payload length at bytes 10...11, MPEG-TS at byte 12.
    public static let headerSize = 12

    public static let maxDatagramSize = 2048

    public static let transportStreamPacketSize = 188

    public static let syncByte: UInt8 = 0x47

    /// Heartbeat that keeps the camera streaming. Sent as raw ASCII.
    public static let keepAlivePayload = Data("_GPHD_:0:0:2:0.000000\n".utf8)

    /// `PreviewPlayer.kt` uses 2000 ms, `GoProUdpRelay.kt` 2500 ms. This port
    /// follows `PreviewPlayer`, the path that owns the preview socket.
    public static let keepAliveInterval: TimeInterval = 2.0

    /// Receive timeout per read attempt, so the read loop can observe shutdown.
    public static let socketTimeout: TimeInterval = 1.0

    /// Default playback latency window, matching the Android ExoPlayer
    /// `DefaultLoadControl` (min 300 ms, max 1000 ms).
    public static let bufferedFrameBudget = 3

    // MARK: MPEG-TS stream types

    /// Private stream the camera declares on a PID that never carries payload.
    /// `GoProTsExtractorFactory.kt` drops it so no phantom track is registered.
    public static let privateStreamType: UInt8 = 0x80

    /// H.264 video elementary stream.
    public static let h264StreamType: UInt8 = 0x1B

    /// AAC audio elementary stream. Parsed but not consumed yet.
    public static let aacStreamType: UInt8 = 0x0F
}

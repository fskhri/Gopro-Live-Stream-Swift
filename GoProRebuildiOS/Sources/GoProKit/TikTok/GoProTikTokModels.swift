import Foundation

/// Result of opening a TikTok LIVE room.
public struct GoProTikTokStreamInfo: Equatable, Sendable {
    /// Full `rtmp_push_url` the camera's stream has to be pushed to.
    public let fullRtmpUrl: String
    /// Everything up to and including the last `/` of `fullRtmpUrl`.
    public let baseUrl: String
    /// The part after that last `/`; the credential part of the URL.
    public let streamKey: String
    /// Public page of the live room.
    public let shareUrl: String
    /// Room id, needed to close the room again.
    public let roomId: String

    public init(fullRtmpUrl: String, shareUrl: String, roomId: String) {
        self.fullRtmpUrl = fullRtmpUrl
        self.streamKey = Self.streamKey(of: fullRtmpUrl)
        self.baseUrl = Self.baseUrl(of: fullRtmpUrl)
        self.shareUrl = shareUrl
        self.roomId = roomId
    }

    /// Split at the last `/`, the way `TiktokService.kt` does.
    static func streamKey(of url: String) -> String {
        guard let index = url.lastIndex(of: "/") else { return url }
        return String(url[url.index(after: index)...])
    }

    static func baseUrl(of url: String) -> String {
        guard let index = url.lastIndex(of: "/") else { return url }
        return String(url[...index])
    }
}

/// A live category offered on the room form.
public struct GoProTikTokTopic: Equatable, Identifiable, Hashable, Sendable {
    /// Stable key sent as `topic`; `nil` means "none".
    public let id: String?
    public let label: String

    public init(id: String?, label: String) {
        self.id = id
        self.label = label
    }

    /// Same order and ids the Android screen offers.
    public static let all: [GoProTikTokTopic] = [
        GoProTikTokTopic(id: nil, label: "None"),
        GoProTikTokTopic(id: "chat_interview", label: "Chat & Interview"),
        GoProTikTokTopic(id: "gaming", label: "Gaming"),
        GoProTikTokTopic(id: "music", label: "Music"),
        GoProTikTokTopic(id: "dance", label: "Dance"),
        GoProTikTokTopic(id: "beauty", label: "Beauty"),
        GoProTikTokTopic(id: "fashion", label: "Fashion"),
        GoProTikTokTopic(id: "food", label: "Food"),
        GoProTikTokTopic(id: "sports", label: "Sports"),
        GoProTikTokTopic(id: "education", label: "Education"),
    ]

    /// `topic` → `hashtag_id`, copied from `TiktokStreamViewModel.kt`.
    public static let hashtagIds: [String: String] = [
        "chat_interview": "42",
        "gaming": "5",
        "music": "6",
        "dance": "3",
        "beauty": "9",
        "fashion": "9",
        "food": "4",
        "sports": "13",
        "education": "45",
    ]

    public static let defaultHashtagId = "42"

    /// The hashtag id this topic asks for. `None` has no id of its own, so the
    /// room goes out under the default one, as it did on Android.
    public var hashtagId: String {
        Self.hashtagIds[id ?? ""] ?? Self.defaultHashtagId
    }
}

/// Region priority offered on the room form.
public struct GoProTikTokRegion: Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    public static let all: [GoProTikTokRegion] = [
        GoProTikTokRegion(id: "id", label: "Indonesia (id)"),
        GoProTikTokRegion(id: "", label: "Default"),
        GoProTikTokRegion(id: "us", label: "United States (us)"),
        GoProTikTokRegion(id: "gb", label: "United Kingdom (gb)"),
        GoProTikTokRegion(id: "jp", label: "Japan (jp)"),
        GoProTikTokRegion(id: "kr", label: "South Korea (kr)"),
    ]
}

/// State of the RTMP push, mirroring Android's `RelayStatus`.
public enum GoProTikTokRelayStatus: String, Sendable, Equatable {
    case idle
    case starting
    case streaming
    case reconnecting
    case stopping
    case error
}

/// Everything that can go wrong on the TikTok side.
public enum GoProTikTokError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case missingSessionID
    case invalidCookieInput
    case invalidURL(String)
    case malformedResponse(String)
    case http(status: Int, body: String)
    case api(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Log in to TikTok first."
        case .missingSessionID:
            return "The saved cookies have no sessionid. Log in again."
        case .invalidCookieInput:
            return "Could not recognize that cookie format."
        case .invalidURL(let url):
            return "Not a valid URL: \(url)"
        case .malformedResponse(let detail):
            return "TikTok returned an unexpected response: \(detail)"
        case .http(let status, let body):
            return "TikTok HTTP \(status): \(body)"
        case .api(_, let message):
            return message
        }
    }
}

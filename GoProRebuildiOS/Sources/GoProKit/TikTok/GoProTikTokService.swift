import Foundation

/// TikTok LIVE webcast client.
///
/// Port of `tiktok/TiktokService.kt`, byte-for-byte in behaviour: the same
/// endpoints, the same query parameters, the same form fields and the same
/// `sessionid` cookie credential. It impersonates the TikTok LIVE Studio
/// Windows client, which is what the Android app did.
///
/// Requests go through `GoProTikTokTransport`, because the camera's hotspot
/// owns the default route while the preview runs.
public final class GoProTikTokService: @unchecked Sendable {

    private struct Constants {
        static let checkUpdateURL =
            "https://tron-sg.bytelemon.com/api/sdk/check_update" +
            "?pid=7393277106664249610&uid=7464643088460875280&branch=studio/release/stable&buildId=0"
        static let accountInfoURL = "https://www.tiktok.com/passport/web/account/info/"
        static let gameTagsURL = "https://webcast16-normal-c-useast2a.tiktokv.com/webcast/room/hashtag/list/"
        static let defaultStudioVersion = "1.12.0"
        static let webUserAgent =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        /// Order copied from `createStream()`.
        static let createRoomBases = [
            "https://webcast.tiktok.com/",
            "https://webcast-normal.tiktokv.com/",
            "https://webcast16-normal-c-useast1a.tiktokv.com/",
        ]
        static let endRoomBases = [
            "https://webcast.tiktok.com/",
            "https://webcast-normal.tiktokv.com/",
        ]
    }

    private let transport: GoProTikTokHTTPClient
    private let cookies: GoProTikTokCookieStore
    private let lock = NSLock()
    private var studioVersion = Constants.defaultStudioVersion

    public init(
        transport: GoProTikTokHTTPClient = GoProTikTokTransport(),
        cookies: GoProTikTokCookieStore = .shared
    ) {
        self.transport = transport
        self.cookies = cookies
    }

    // MARK: - User agent

    /// The `browser_version` and header value Android builds per request.
    public func desktopUserAgent(version: String) -> String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) TikTokLIVEStudio/\(version) " +
        "Chrome/108.0.5359.215 Electron/22.3.18-tt.8.release.main.44 " +
        "TTElectron/22.3.18-tt.8.release.main.44 Safari/537.36"
    }

    /// Latest Live Studio version, cached for the session. Falls back to the
    /// constant Android starts with when the check is unreachable.
    public func studioVersion() async -> String {
        let cached = readCachedStudioVersion()

        guard let url = URL(string: Constants.checkUpdateURL) else { return cached }
        let request = GoProHTTPRequest(method: "GET", url: url)
        guard let response = try? await transport.send(request),
              response.status == 200,
              let version = Self.studioVersion(from: response.body), !version.isEmpty else {
            return cached
        }

        writeCachedStudioVersion(version)
        return version
    }

    /// The lock stays inside sync helpers: `NSLock` is unavailable on async paths.
    private func readCachedStudioVersion() -> String {
        lock.lock()
        defer { lock.unlock() }
        return studioVersion
    }

    private func writeCachedStudioVersion(_ version: String) {
        lock.lock()
        studioVersion = version
        lock.unlock()
    }

    /// `data.manifest.win32.version` from the update manifest.
    static func studioVersion(from body: Data) -> String? {
        guard let json = Self.json(body) else { return nil }
        guard let data = json["data"] as? [String: Any],
              let manifest = data["manifest"] as? [String: Any],
              let win32 = manifest["win32"] as? [String: Any] else { return nil }
        return win32["version"] as? String
    }

    // MARK: - Login

    /// `true` when the stored cookies still resolve to an account.
    public func checkLoginStatus() async -> Bool {
        guard let stored = cookies.cookies, !stored.isEmpty else { return false }
        guard let url = URL(string: Constants.accountInfoURL) else { return false }

        let request = GoProHTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Cookie": stored,
                "User-Agent": Constants.webUserAgent,
            ]
        )
        guard let response = try? await transport.send(request), response.status == 200 else { return false }
        guard let userId = Self.userId(from: response.body) else { return false }
        return userId > 0
    }

    /// `data.user_id` from the account info endpoint.
    ///
    /// `optLong` on Android also accepted the quoted-digit form TikTok
    /// sometimes returns, so a numeric string is parsed here too.
    static func userId(from body: Data) -> Int64? {
        guard let json = Self.json(body),
              let data = json["data"] as? [String: Any] else { return nil }
        if let number = data["user_id"] as? NSNumber { return number.int64Value }
        if let text = data["user_id"] as? String { return Int64(text) }
        return nil
    }

    // MARK: - Tags

    /// Game tag id → display name, for the gaming topic.
    public func fetchGameTags() async throws -> [String: String] {
        let version = await studioVersion()
        guard let url = URL(string: Constants.gameTagsURL) else { throw GoProTikTokError.invalidURL(Constants.gameTagsURL) }

        let request = GoProHTTPRequest(
            method: "GET",
            url: url,
            headers: ["User-Agent": desktopUserAgent(version: version)]
        )
        let response = try await transport.send(request)
        guard response.status == 200 else {
            throw GoProTikTokError.http(status: response.status, body: response.bodyText)
        }
        guard let json = Self.json(response.body),
              let data = json["data"] as? [String: Any],
              let list = data["game_tag_list"] as? [[String: Any]] else { return [:] }

        var result: [String: String] = [:]
        for item in list {
            guard let id = item["id"] as? String, !id.isEmpty,
                  let name = item["show_name"] as? String, !name.isEmpty else { continue }
            result[id] = name
        }
        return result
    }

    // MARK: - Room lifecycle

    /// Open a live room and return the URL to push to.
    public func createStream(
        title: String,
        hashtagId: String = GoProTikTokTopic.defaultHashtagId,
        gameTagId: String = "0",
        enableReplay: Bool = false,
        closeRoomWhenStreamEnds: Bool = true,
        regionPriority: String = "id",
        isMatureContent: Bool = false
    ) async throws -> GoProTikTokStreamInfo {
        let stored = cookies.cookies
        guard let stored, !stored.isEmpty else { throw GoProTikTokError.notLoggedIn }
        guard GoProTikTokCookieStore.hasSessionID(in: stored) else { throw GoProTikTokError.missingSessionID }

        let version = await studioVersion()
        let userAgent = desktopUserAgent(version: version)
        let sdkVersion = Self.sdkVersion(from: version)
        let effectiveRegion = regionPriority.trimmingCharacters(in: .whitespaces).lowercased()

        var lastError: Error = GoProTikTokError.malformedResponse("no TikTok endpoint answered")

        for baseUrl in Constants.createRoomBases {
            let encodedUA = userAgent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userAgent
            let urlStr = "\(baseUrl)webcast/room/create/?aid=8311&app_name=tiktok_live_studio&channel=studio&device_platform=windows&priority_region=\(effectiveRegion)&live_mode=6&version_code=\(version)&webcast_sdk_version=\(sdkVersion)&webcast_language=en&app_language=en&language=en&browser_version=\(encodedUA)&browser_name=Mozilla&browser_platform=Win32&browser_language=en-US&screen_height=1080&screen_width=1920&timezone_name=Asia/Jakarta&device_id=7378193331631310352&install_id=7378196538524927745"

            guard let url = URL(string: urlStr) else { continue }

            // Ordered form fields matching Android exactly
            var fields: [(String, String)] = [
                ("title", title.trimmingCharacters(in: .whitespacesAndNewlines)),
                ("live_studio", "1"),
                ("gen_replay", enableReplay ? "true" : "false"),
                ("chat_auth", "1"),
                ("cover_uri", ""),
                ("close_room_when_close_stream", closeRoomWhenStreamEnds ? "true" : "false"),
                ("hashtag_id", hashtagId),
                ("game_tag_id", gameTagId),
                ("screenshot_cover_status", "1"),
                ("live_sub_only", "0"),
                ("chat_sub_only_auth", "2"),
                ("multi_stream_scene", "0"),
                ("gift_auth", "1"),
                ("chat_l2", "1"),
                ("star_comment_switch", "true"),
                ("multi_stream_source", "1")
            ]
            if isMatureContent {
                fields.append(("age_restricted", "4"))
            }

            let formBody = Self.formEncode(fields)

            let request = GoProHTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "User-Agent": userAgent,
                    "Cookie": stored,
                    "Content-Type": "application/x-www-form-urlencoded",
                ],
                body: Data(formBody.utf8)
            )

            guard let response = try? await transport.send(request) else { continue }
            if response.status != 200 {
                lastError = GoProTikTokError.http(status: response.status, body: response.bodyText)
                continue
            }
            guard let json = Self.json(response.body) else {
                lastError = GoProTikTokError.malformedResponse("room create returned non-JSON")
                continue
            }

            let statusCode = Self.int(json["status_code"]) ?? -1
            guard statusCode == 0 else {
                let msg = Self.message(from: json)
                lastError = GoProTikTokError.api(status: statusCode, message: msg)
                continue
            }
            guard let data = json["data"] as? [String: Any],
                  let streamUrl = data["stream_url"] as? [String: Any],
                  let rtmp = streamUrl["rtmp_push_url"] as? String, !rtmp.isEmpty else {
                lastError = GoProTikTokError.malformedResponse("room create response has no rtmp_push_url")
                continue
            }

            let roomId = Self.string(data["id_str"]) ?? Self.string(data["id"]) ?? ""
            let shareUrl = Self.string(data["share_url"]) ?? ""
            return GoProTikTokStreamInfo(fullRtmpUrl: rtmp, shareUrl: shareUrl, roomId: roomId)
        }

        throw lastError
    }

    /// Close the room. Returns whether any endpoint accepted it.
    public func endStream(roomId: String) async -> Bool {
        guard let stored = cookies.cookies, !stored.isEmpty else { return false }
        let version = await studioVersion()
        let userAgent = desktopUserAgent(version: version)

        for baseUrl in Constants.endRoomBases {
            guard let url = URL(string: "\(baseUrl)webcast/room/finish_abnormal/") else { continue }
            let request = GoProHTTPRequest(
                method: "POST",
                url: url,
                headers: [
                    "User-Agent": userAgent,
                    "Cookie": stored,
                    "Content-Type": "application/x-www-form-urlencoded",
                ],
                body: Data(Self.formEncode(["room_id": roomId]).utf8)
            )

            guard let response = try? await transport.send(request), response.status == 200,
                  let json = Self.json(response.body) else { continue }
            if (Self.int(json["status_code"]) ?? -1) == 0 { return true }
        }
        return false
    }

    // MARK: - Helpers

    /// `version` with its dots removed, padded to five digits.
    static func sdkVersion(from version: String) -> String {
        let compact = version.replacingOccurrences(of: ".", with: "")
        guard compact.count < 5 else { return compact }
        return compact + String(repeating: "0", count: 5 - compact.count)
    }

    static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    /// Query string for a room request, matching `createStream()`'s parameters.
    static func url(
        path: String,
        baseUrl: String,
        version: String,
        userAgent: String,
        sdkVersion: String,
        region: String
    ) -> URL? {
        var components = URLComponents(string: baseUrl + path)
        components?.queryItems = [
            URLQueryItem(name: "aid", value: "8311"),
            URLQueryItem(name: "app_name", value: "tiktok_live_studio"),
            URLQueryItem(name: "channel", value: "studio"),
            URLQueryItem(name: "device_platform", value: "windows"),
            URLQueryItem(name: "priority_region", value: region),
            URLQueryItem(name: "live_mode", value: "6"),
            URLQueryItem(name: "version_code", value: version),
            URLQueryItem(name: "webcast_sdk_version", value: sdkVersion),
            URLQueryItem(name: "webcast_language", value: "en"),
            URLQueryItem(name: "app_language", value: "en"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "browser_version", value: userAgent),
            URLQueryItem(name: "browser_name", value: "Mozilla"),
            URLQueryItem(name: "browser_platform", value: "Win32"),
            URLQueryItem(name: "browser_language", value: "en-US"),
            URLQueryItem(name: "screen_height", value: "1080"),
            URLQueryItem(name: "screen_width", value: "1920"),
            URLQueryItem(name: "timezone_name", value: TimeZone.current.identifier),
            URLQueryItem(name: "device_id", value: "7378193331631310352"),
            URLQueryItem(name: "install_id", value: "7378196538524927745"),
        ]
        return components?.url
    }

    /// Form encoding as `application/x-www-form-urlencoded` sends it: space is
    /// a `+`, everything outside the unreserved set is percent-escaped.
    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        return fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value
                    .addingPercentEncoding(withAllowedCharacters: allowed)?
                    .replacingOccurrences(of: "%20", with: "+") ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    static func formEncode(_ fields: [String: String]) -> String {
        formEncode(fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    /// Server-side failure text, preferring the user-facing prompt.
    static func message(from json: [String: Any]) -> String {
        if let data = json["data"] as? [String: Any],
           let prompts = data["prompts"] as? String, !prompts.isEmpty {
            return prompts
        }
        if let status = json["status_msg"] as? String, !status.isEmpty {
            return status
        }
        return "TikTok rejected the request (code \(Self.int(json["status_code"]) ?? -1))."
    }

    static func json(_ body: Data) -> [String: Any]? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

import Foundation

/// Stores the TikTok cookie header and reads its shape.
///
/// Port of `tiktok/TiktokRepository.kt`: DataStore becomes `UserDefaults`, and
/// the cookie parsing rules are kept verbatim so a cookie string exported from
/// the Android app still works here.
public final class GoProTikTokCookieStore: @unchecked Sendable {
    public static let shared = GoProTikTokCookieStore()

    private static let key = "gopro.tiktok.cookies"
    private let store: UserDefaults
    private let lock = NSLock()

    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    /// Raw `name=value; name=value` header, or `nil` when nothing is saved.
    public var cookies: String? {
        lock.lock()
        defer { lock.unlock() }
        return store.string(forKey: Self.key)
    }

    public func save(_ cookies: String) {
        lock.lock()
        store.set(cookies, forKey: Self.key)
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        store.removeObject(forKey: Self.key)
        lock.unlock()
    }

    /// Import cookies from any supported format (JSON, Netscape, raw string).
    @discardableResult
    public func `import`(cookies raw: String) -> Bool {
        guard let parsed = try? Self.parse(raw) else { return false }
        save(parsed)
        return true
    }

    /// `true` when the stored header carries a `sessionid`.
    public var hasSessionID: Bool { Self.hasSessionID(in: cookies) }

    /// `true` when the stored header carries a `sid_tt` (partial login).
    public var hasSidTt: Bool { Self.hasSidTt(in: cookies) }

    public static func hasSessionID(in cookies: String?) -> Bool {
        guard let cookies, !cookies.isEmpty else { return false }
        return cookies.contains("sessionid=") || cookies.contains("sessionid =")
    }

    public static func hasSidTt(in cookies: String?) -> Bool {
        guard let cookies, !cookies.isEmpty else { return false }
        return cookies.contains("sid_tt=") || cookies.contains("sid_tt =")
    }

    /// Parse a cookie header from raw text, Netscape export, or JSON.
    ///
    /// Accepts what `parseCookieInput` accepts: an EditThisCookie style JSON
    /// array, a `{"cookies": [...]}` or `{"cookies": {...}}` object, a plain
    /// name→value object, a Netscape tab-separated export, or a bare
    /// `a=1; b=2` header. Returns a normalized `a=1; b=2` string.
    public static func parse(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GoProTikTokError.invalidCookieInput }

        var pairs: [String: String] = [:]
        func add(_ name: String?, _ value: String?) {
            guard let name, let value else { return }
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !val.isEmpty else { return }
            pairs[key] = val
        }

        var parsedAsJSON = false
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            || (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) {
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                if let array = object as? [[String: Any]] {
                    for item in array { add(item["name"] as? String, item["value"] as? String) }
                    parsedAsJSON = true
                } else if let dictionary = object as? [String: Any] {
                    if let nested = dictionary["cookies"] as? [[String: Any]] {
                        for item in nested { add(item["name"] as? String, item["value"] as? String) }
                    } else if let nested = dictionary["cookies"] as? [String: Any] {
                        for (name, value) in nested { add(name, String(describing: value)) }
                    } else {
                        for (name, value) in dictionary { add(name, String(describing: value)) }
                    }
                    parsedAsJSON = true
                }
            }
        }

        if !parsedAsJSON || pairs.isEmpty {
            for rawLine in trimmed.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }

                if line.contains("\t") {
                    // Netscape export: domain, flag, path, secure, expiry, name, value.
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 7 { add(parts[5], parts[6]) }
                } else {
                    for segment in line.components(separatedBy: ";") {
                        guard let equals = segment.firstIndex(of: "=") else { continue }
                        add(String(segment[..<equals]), String(segment[segment.index(after: equals)...]))
                    }
                }
            }
        }

        guard !pairs.isEmpty else { throw GoProTikTokError.invalidCookieInput }
        return pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// Join cookie pairs scraped from a `WKWebsiteDataStore`.
    ///
    /// Port of `getAllCookies()`: TikTok scatters its session across
    /// `www.tiktok.com`, `webcast.tiktok.com` and the bare domain, and the
    /// union thins out to a single pair per name.
    public static func header(from cookies: [HTTPCookie]) -> String {
        var pairs: [String: String] = [:]
        for cookie in cookies where !cookie.value.isEmpty {
            pairs[cookie.name] = cookie.value
        }
        return pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}

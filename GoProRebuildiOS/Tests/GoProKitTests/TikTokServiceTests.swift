import XCTest
@testable import GoProKit

// MARK: - Stub transport

/// Answers from a URL-based table so the service can be exercised offline.
private final class StubTransport: GoProTikTokHTTPClient, @unchecked Sendable {
    struct Rule {
        let host: String
        let response: Result<GoProHTTPResponse, Error>
    }

    var rules: [Rule] = []
    private(set) var requests: [GoProHTTPRequest] = []

    func send(_ request: GoProHTTPRequest) async throws -> GoProHTTPResponse {
        requests.append(request)
        let host = request.url.host ?? ""
        guard let rule = rules.first(where: { $0.host == host }) else {
            throw StubError.noRuleForHost(host)
        }
        return try rule.response.get()
    }
}

private enum StubError: Error {
    case noRuleForHost(String)
}

private func response(status: Int = 200, body: String, headers: [String: String] = [:]) -> GoProHTTPResponse {
    GoProHTTPResponse(status: status, headers: headers, body: Data(body.utf8))
}

private let studioVersionBody = """
{"data":{"manifest":{"win32":{"version":"1.25.0"}}}}
"""

private let accountInfoBody = """
{"data":{"user_id":"7300000000000000001","screen_name":"tester"}}
"""

private let gameTagBody = """
{"data":{"game_tag_list":[{"id":"123","show_name":"Battle Royale"},{"id":"","show_name":"skip me"}]}}
"""

private func roomCreatedBody(rtmp: String = "rtmp://push-rtmp-l1-va01.tiktok.com/live/stream-123?expire=1") -> String {
    """
    {"status_code":0,"data":{"id_str":"74612345","share_url":"https://www.tiktok.com/@u/live/1","stream_url":{"rtmp_push_url":"\(rtmp)"}}}
    """
}

// MARK: - Cookie parsing

final class TikTokCookieTests: XCTestCase {
    func testParsesRawHeader() throws {
        let parsed = try GoProTikTokCookieStore.parse("sessionid=abc123; uid_tt=xyz; ; sid_tt=9")
        XCTAssertEqual(parsed, "sessionid=abc123; sid_tt=9; uid_tt=xyz")
    }

    func testParsesNetscapeExport() throws {
        let exported = """
        # Netscape HTTP Cookie File
        .tiktok.com\tTRUE\t/\tTRUE\t1893456000\tsessionid\tabc123
        .tiktok.com\tTRUE\t/\tTRUE\t1893456000\tuid_tt\txyz
        """
        let parsed = try GoProTikTokCookieStore.parse(exported)
        XCTAssertEqual(parsed, "sessionid=abc123; uid_tt=xyz")
    }

    func testParsesEditThisCookieArray() throws {
        let json = """
        [{"name":"sessionid","value":"abc123"},{"name":"uid_tt","value":"xyz"}]
        """
        XCTAssertEqual(try GoProTikTokCookieStore.parse(json), "sessionid=abc123; uid_tt=xyz")
    }

    func testParsesNestedCookieObject() throws {
        let json = """
        {"cookies":{"sessionid":"abc123","uid_tt":"xyz"}}
        """
        XCTAssertEqual(try GoProTikTokCookieStore.parse(json), "sessionid=abc123; uid_tt=xyz")
    }

    func testRejectsEmptyAndUnreadableInput() {
        XCTAssertThrowsError(try GoProTikTokCookieStore.parse("   "))
        XCTAssertThrowsError(try GoProTikTokCookieStore.parse("not a cookie at all"))
    }

    func testSessionIdAndSidTtDetection() {
        XCTAssertTrue(GoProTikTokCookieStore.hasSessionID(in: "a=1; sessionid=abc"))
        XCTAssertTrue(GoProTikTokCookieStore.hasSidTt(in: "sid_tt=abc; a=1"))
        XCTAssertFalse(GoProTikTokCookieStore.hasSessionID(in: "uid_tt=abc"))
        XCTAssertFalse(GoProTikTokCookieStore.hasSessionID(in: nil))
        XCTAssertFalse(GoProTikTokCookieStore.hasSidTt(in: ""))
    }

    func testStoreRoundTripsThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: "gopro.kit.tiktok.tests")!
        defaults.removeObject(forKey: "gopro.tiktok.cookies")
        defer { defaults.removeObject(forKey: "gopro.tiktok.cookies") }

        let store = GoProTikTokCookieStore(store: defaults)
        XCTAssertNil(store.cookies)
        store.save("sessionid=abc123")
        XCTAssertEqual(store.cookies, "sessionid=abc123")
        XCTAssertTrue(store.hasSessionID)
        store.clear()
        XCTAssertNil(store.cookies)
    }

    func testHeaderFromCookieObjectsIsSortedAndDeduplicated() throws {
        let session = try XCTUnwrap(HTTPCookie(properties: [
            .name: "sessionid", .value: "abc", .domain: ".tiktok.com", .path: "/",
        ]))
        let uid = try XCTUnwrap(HTTPCookie(properties: [
            .name: "uid_tt", .value: "xyz", .domain: ".tiktok.com", .path: "/",
        ]))
        let duplicate = try XCTUnwrap(HTTPCookie(properties: [
            .name: "sessionid", .value: "newer", .domain: ".tiktok.com", .path: "/",
        ]))

        let header = GoProTikTokCookieStore.header(from: [session, uid, duplicate])
        XCTAssertEqual(header, "sessionid=newer; uid_tt=xyz")
    }
}

// MARK: - Service

final class TikTokServiceTests: XCTestCase {
    private var transport: StubTransport!
    private var store: GoProTikTokCookieStore!
    private var service: GoProTikTokService!

    override func setUp() {
        super.setUp()
        transport = StubTransport()
        let defaults = UserDefaults(suiteName: "gopro.kit.tiktok.service.tests")!
        defaults.removeObject(forKey: "gopro.tiktok.cookies")
        store = GoProTikTokCookieStore(store: defaults)
        service = GoProTikTokService(transport: transport, cookies: store)

        transport.rules = [
            .init(host: "tron-sg.bytelemon.com", response: .success(response(body: studioVersionBody))),
        ]
    }

    override func tearDown() {
        store.clear()
        super.tearDown()
    }

    func testCreateStreamSucceedsAndSplitsTheRtmpUrl() async throws {
        transport.rules.append(.init(host: "webcast.tiktok.com", response: .success(response(body: roomCreatedBody()))))
        store.save("sessionid=abc123; uid_tt=xyz")

        let info = try await service.createStream(title: "Hero 6 ride")

        XCTAssertEqual(info.roomId, "74612345")
        XCTAssertEqual(info.shareUrl, "https://www.tiktok.com/@u/live/1")
        XCTAssertEqual(info.baseUrl, "rtmp://push-rtmp-l1-va01.tiktok.com/live/")
        XCTAssertEqual(info.streamKey, "stream-123?expire=1")

        let createRequest = try XCTUnwrap(transport.requests.first { $0.url.host == "webcast.tiktok.com" })
        XCTAssertEqual(createRequest.method, "POST")
        XCTAssertEqual(createRequest.headers["Cookie"], "sessionid=abc123; uid_tt=xyz")
        XCTAssertEqual(createRequest.headers["User-Agent"], service.desktopUserAgent(version: "1.25.0"))

        let query = createRequest.url.query ?? ""
        XCTAssertTrue(query.contains("app_name=tiktok_live_studio"))
        XCTAssertTrue(query.contains("device_platform=windows"))
        XCTAssertTrue(query.contains("version_code=1.25.0"))
        XCTAssertTrue(query.contains("webcast_sdk_version=12500"))
        XCTAssertTrue(query.contains("priority_region=id"))

        let body = String(data: createRequest.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("title=Hero+6+ride"))
        XCTAssertTrue(body.contains("live_studio=1"))
        XCTAssertTrue(body.contains("gen_replay=false"))
        XCTAssertTrue(body.contains("hashtag_id=42"))
    }

    func testCreateStreamFallsBackToTheNextEndpoint() async {
        // Only the second base answers.
        transport.rules.append(.init(host: "webcast-normal.tiktokv.com", response: .success(response(body: roomCreatedBody()))))
        store.save("sessionid=abc123")

        let info = try? await service.createStream(title: "fallback")
        XCTAssertEqual(info?.roomId, "74612345")
    }

    func testCreateStreamWithoutCookiesIsNotLoggedIn() async {
        do {
            _ = try await service.createStream(title: "no session")
            XCTFail("expected notLoggedIn")
        } catch let error as GoProTikTokError {
            XCTAssertEqual(error, .notLoggedIn)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCreateStreamWithoutSessionIdIsRejectedBeforeAnyRequest() async {
        store.save("uid_tt=xyz")

        do {
            _ = try await service.createStream(title: "no sessionid")
            XCTFail("expected missingSessionID")
        } catch let error as GoProTikTokError {
            XCTAssertEqual(error, .missingSessionID)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0, "the request must be refused before any network call")
    }

    func testCreateStreamSurfacesTheServerPrompt() async {
        transport.rules.append(.init(
            host: "webcast.tiktok.com",
            response: .success(response(body: """
            {"status_code":501,"data":{"prompts":"You are not eligible to go live."},"status_msg":"rejected"}
            """))
        ))
        store.save("sessionid=abc123")

        do {
            _ = try await service.createStream(title: "rejected")
            XCTFail("expected a server error")
        } catch let error as GoProTikTokError {
            XCTAssertEqual(error, .api(status: 501, message: "You are not eligible to go live."))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCreateStreamSendsMatureFlagOnlyWhenRequested() async throws {
        transport.rules.append(.init(host: "webcast.tiktok.com", response: .success(response(body: roomCreatedBody()))))
        store.save("sessionid=abc123")

        _ = try? await service.createStream(title: "rated r", isMatureContent: true)
        let body = String(data: transport.requests.last?.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("age_restricted=4"))
    }

    func testCheckLoginStatusReadsUserId() async {
        transport.rules.append(.init(host: "www.tiktok.com", response: .success(response(body: accountInfoBody))))
        store.save("sessionid=abc123")

        let loggedIn = await service.checkLoginStatus()
        XCTAssertTrue(loggedIn)
    }

    func testCheckLoginStatusIsFalseWithoutStoredCookies() async {
        let loggedIn = await service.checkLoginStatus()
        XCTAssertFalse(loggedIn)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFetchGameTagsSkipsEntriesWithoutId() async throws {
        transport.rules.append(.init(host: "webcast16-normal-c-useast2a.tiktokv.com", response: .success(response(body: gameTagBody))))

        let tags = try await service.fetchGameTags()
        XCTAssertEqual(tags, ["123": "Battle Royale"])
    }

    func testEndStreamSendsTheRoomId() async {
        transport.rules.append(.init(
            host: "webcast.tiktok.com",
            response: .success(response(body: """
            {"status_code":0,"data":{}}
            """))
        ))
        store.save("sessionid=abc123")

        let ended = await service.endStream(roomId: "74612345")
        XCTAssertTrue(ended)
        let request = try? XCTUnwrap(transport.requests.first { $0.url.host == "webcast.tiktok.com" })
        XCTAssertEqual(String(data: request?.body ?? Data(), encoding: .utf8), "room_id=74612345")
    }

    func testSdkVersionIsPaddedToFiveDigits() {
        XCTAssertEqual(GoProTikTokService.sdkVersion(from: "1.25.0"), "12500")
        XCTAssertEqual(GoProTikTokService.sdkVersion(from: "1.12.12"), "11212")
        XCTAssertEqual(GoProTikTokService.sdkVersion(from: "1.1"), "11000")
    }
}

// MARK: - HTTP framing

final class TikTokTransportFramingTests: XCTestCase {
    func testContentLengthResponse() {
        let raw = Data((
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        ).utf8)

        guard case .complete(let parsed) = GoProTikTokTransport.response(raw, ended: false) else {
            return XCTFail("expected a complete response")
        }
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.headers["content-type"], "application/json")
        XCTAssertEqual(parsed.bodyText, "{}")
    }

    func testIncompleteBodyAsksForMore() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n12345".utf8)
        guard case .needMore = GoProTikTokTransport.response(raw, ended: false) else {
            return XCTFail("expected needMore")
        }
    }

    func testChunkedResponseIsDecoded() {
        let raw = Data((
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        ).utf8)

        guard case .complete(let parsed) = GoProTikTokTransport.response(raw, ended: false) else {
            return XCTFail("expected a complete response")
        }
        XCTAssertEqual(parsed.bodyText, "hello world")
    }

    func testBodyEndedByThePeerClosing() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nbye".utf8)

        guard case .needMore = GoProTikTokTransport.response(raw, ended: false) else {
            return XCTFail("expected needMore before the close")
        }
        guard case .complete(let parsed) = GoProTikTokTransport.response(raw, ended: true) else {
            return XCTFail("expected a complete response after the close")
        }
        XCTAssertEqual(parsed.bodyText, "bye")
    }

    func testNotAnHttpResponse() {
        let raw = Data("<html>nope</html>".utf8)
        XCTAssertNil(GoProTikTokTransport.response(raw, ended: true))
    }

    func testTruncatedChunkedBodyKeepsReading() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nabc".utf8)
        guard case .needMore = GoProTikTokTransport.response(raw, ended: false) else {
            return XCTFail("expected needMore")
        }
    }

    func testWireDataCarriesHeadersAndBody() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com:8443/live?aid=8311"))
        let request = GoProHTTPRequest(
            method: "POST",
            url: url,
            headers: ["Cookie": "sessionid=abc", "User-Agent": "ua"],
            body: Data("a=1".utf8)
        )
        let text = String(decoding: request.wireData, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("POST /live?aid=8311 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: example.com:8443\r\n"))
        XCTAssertTrue(text.contains("Cookie: sessionid=abc\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 3\r\n"))
        XCTAssertTrue(text.hasSuffix("Connection: close\r\n\r\na=1"))
    }

    func testFormEncodingEscapesAndUsesPlusForSpace() {
        let encoded = GoProTikTokService.formEncode(["title": "hero 6 & ride", "flag": "true"])
        XCTAssertEqual(encoded, "flag=true&title=hero+6+%26+ride")
    }

    func testStreamInfoFallsBackWhenThereIsNoSlash() {
        let info = GoProTikTokStreamInfo(fullRtmpUrl: "rtmp-no-slash", shareUrl: "", roomId: "")
        XCTAssertEqual(info.baseUrl, "rtmp-no-slash")
        XCTAssertEqual(info.streamKey, "rtmp-no-slash")
    }
}

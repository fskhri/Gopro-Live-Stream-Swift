import GoProKit
import SwiftUI
import WebKit

/// Signs in to TikTok so a live room can be opened.
///
/// Port of `ui/screens/TiktokLoginScreen.kt`. The credentials are cookies, not
/// a password: the page is loaded in a `WKWebView` with a desktop user agent,
/// and what lands in the persistent cookie store is what the webcast API is
/// asked with.
///
/// The store is `.default()`, not ephemeral: TikTok puts `sessionid` on the
/// site's domain and httpOnly, so nothing in the page can read it back. It has
/// to outlive the sheet, which is also why the app never sees a password.
struct TikTokLoginView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var pasteError: String?
    @State private var status = "Sign in, then close this screen."
    @State private var savedSession = GoProTikTokCookieStore.shared.hasSessionID
    @State private var pageURL = TikTokLoginView.loginURL
    @State private var reloadToken = UUID()
    @State private var showingPaste = false

    private static let loginURL = "https://www.tiktok.com/login?is_modal=1&hide_toggle_login_signup=1" +
        "&enter_method=live_studio&enter_from=live_studio&lang=en"

    /// Same desktop user agent the webcast calls carry.
    private static let userAgent = GoProTikTokService().desktopUserAgent(version: "1.12.0")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                browser
                if showingPaste {
                    pasteField
                }
                footer
            }
            .background(Theme.background)
            .navigationTitle("TikTok sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Home") { pageURL = "https://www.tiktok.com/foryou"; reloadToken = UUID() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Browser

    private var browser: some View {
        TikTokLoginWebView(
            url: pageURL,
            userAgent: Self.userAgent,
            reloadToken: reloadToken,
            onCookies: handle(cookies:)
        )
        .overlay(alignment: .top) {
            if savedSession {
                savedBanner
            }
        }
    }

    private var savedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.ok)
            Text("Signed in. Cookies saved.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.95))
    }

    // MARK: - Paste

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a cookie header, JSON export, or Netscape file.")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)

            TextField("sessionid=…", text: $pasted, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .font(.footnote.monospaced())
                .padding(10)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Theme.textPrimary)

            if let pasteError {
                Text(pasteError)
                    .font(.caption)
                    .foregroundStyle(Theme.record)
            }

            Button("Save cookies") { savePasted() }
                .buttonStyle(PrimaryButton())
        }
        .padding(12)
        .background(Theme.surface)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status)
                .font(.caption)
                .foregroundStyle(savedSession ? Theme.ok : Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(showingPaste ? "Hide paste" : "Paste cookies") {
                    pasteError = nil
                    showingPaste.toggle()
                }
                .buttonStyle(SecondaryButton())

                if savedSession {
                    Button("Forget") { forget() }
                        .buttonStyle(SecondaryButton())
                }
            }
        }
        .padding(12)
        .background(Theme.surface)
    }

    // MARK: - Cookies

    /// Called after every page the web view finishes: as soon as the sign-in
    /// completes, the cookie header is the credential the API will use.
    private func handle(cookies: [HTTPCookie]) {
        let header = GoProTikTokCookieStore.header(from: cookies)
        guard GoProTikTokCookieStore.hasSessionID(in: header) else {
            status = "Waiting for sign in…"
            return
        }
        GoProTikTokCookieStore.shared.save(header)
        savedSession = true
        status = "Signed in. Cookies saved to this device."
    }

    private func savePasted() {
        pasteError = nil
        do {
            let header = try GoProTikTokCookieStore.parse(pasted)
            guard GoProTikTokCookieStore.hasSessionID(in: header) else {
                pasteError = "That cookie text has no sessionid."
                return
            }
            GoProTikTokCookieStore.shared.save(header)
            savedSession = true
            pasted = ""
            showingPaste = false
            status = "Cookies saved."
        } catch {
            pasteError = error.localizedDescription
        }
    }

    private func forget() {
        GoProTikTokCookieStore.shared.clear()
        savedSession = false
        status = "Cookies removed."
    }
}

/// The sign-in page, with the desktop user agent the webcast calls use.
private struct TikTokLoginWebView: UIViewRepresentable {
    let url: String
    let userAgent: String
    let reloadToken: UUID
    let onCookies: ([HTTPCookie]) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Without the desktop agent TikTok serves a mobile page that hides the
        // Live Studio entry the credentials are meant for.
        view.customUserAgent = userAgent
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.load(url, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(url, in: view, onlyIfChanged: reloadToken)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(userAgent: userAgent, onCookies: onCookies)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var lastLoadedURL: String?
        private var lastToken: UUID?
        private let userAgent: String
        private let onCookies: ([HTTPCookie]) -> Void

        init(userAgent: String, onCookies: @escaping ([HTTPCookie]) -> Void) {
            self.userAgent = userAgent
            self.onCookies = onCookies
        }

        func load(_ url: String, in view: WKWebView, onlyIfChanged token: UUID? = nil) {
            if let token {
                guard token != lastToken else { return }
                lastToken = token
            }
            guard let url = URL(string: url), lastLoadedURL != url.absoluteString else { return }
            lastLoadedURL = url.absoluteString
            view.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            harvest(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Nothing to report: the page itself is the only place the user can
            // see what went wrong.
        }

        private func harvest(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                // httpOnly cookies (`sessionid`) are only visible here, which is
                // the whole reason the login runs in a web view.
                let tiktok = cookies.filter { $0.domain.contains("tiktok") }
                guard !tiktok.isEmpty else { return }
                DispatchQueue.main.async { self.onCookies(tiktok) }
            }
        }
    }
}

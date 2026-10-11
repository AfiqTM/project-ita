import SwiftUI
import WebKit
import Security

// The Website tab: the iTa'leem site shown exactly as in a normal browser (no injected scripts or theme).
// One WKWebView lives for the whole app session, so switching tabs never reloads or loses the page.

@MainActor
final class SiteBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView

    @Published var progress = 0.0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?
    @Published var notice: String?

    private var observers: [NSKeyValueObservation] = []
    private var started = false
    private var loginRetried = false
    private var wantedURL: URL?              // last good page, where to resume after a re-login
    private var retryTask: Task<Void, Never>?
    private var userid = 0
    private var downloads: [ObjectIdentifier: URL] = [:]

    private var home: URL { Site.url.appendingPathComponent("my/") }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        observers = [
            webView.observe(\.estimatedProgress) { [weak self] w, _ in
                let v = w.estimatedProgress
                Task { @MainActor in self?.progress = v }
            },
            webView.observe(\.isLoading) { [weak self] w, _ in
                let v = w.isLoading
                Task { @MainActor in self?.isLoading = v }
            },
            webView.observe(\.canGoBack) { [weak self] w, _ in
                let v = w.canGoBack
                Task { @MainActor in self?.canGoBack = v }
            },
            webView.observe(\.canGoForward) { [weak self] w, _ in
                let v = w.canGoForward
                Task { @MainActor in self?.canGoForward = v }
            },
            webView.observe(\.url) { [weak self] w, _ in
                let v = w.url
                Task { @MainActor in self?.currentURL = v }
            }
        ]
    }

    // ---- loading / sign-in ----
    //
    // Order of attempts, so Moodle's one-key-per-6-minutes limit is rarely touched:
    //   1. the web view's cookie session (restored from the Keychain after a relaunch)
    //   2. a one-time auto-login key, only when there is no usable session
    //   3. if Moodle says "too soon", wait out the cooldown and retry automatically

    // Called when the tab first appears.
    func startIfNeeded(userid: Int) async {
        self.userid = userid
        guard !started else { return }
        started = true
        await restoreSessionCookies()
        await open(home)
    }

    func open(_ target: URL, force: Bool = false) async {
        notice = nil
        retryTask?.cancel(); retryTask = nil
        wantedURL = target
        loginRetried = false
        await MoodleAPI.shared.syncCookies()
        let api = MoodleAPI.shared
        let hasSession = await hasSessionCookie()
        if !force && (hasSession || api.privateToken == nil || api.autologinWait > 0) {
            webView.load(URLRequest(url: target))      // rely on the saved session
        } else {
            loginRetried = true                        // a failed key shouldn't trigger another one
            let u = await api.autologin(target, userid: userid, force: true)
            webView.load(URLRequest(url: u))
        }
    }

    func goHome() { Task { await open(home) } }

    func reload() {
        if webView.url == nil { goHome() } else { webView.reload() }
    }

    private var resumeURL: URL { wantedURL ?? home }

    private func handleFinish(_ w: WKWebView) {
        guard let u = w.url else { return }
        if u.path.contains("/login/") {
            if !loginRetried {
                loginRetried = true
                Task { await recoverSession() }
            } else if retryTask == nil {
                notice = "You're signed out. Sign in on this page; the session is saved, so you shouldn't need to again for a while."
            }
        } else {
            loginRetried = false
            retryTask?.cancel(); retryTask = nil
            if u.host == Site.url.host { wantedURL = u }
            Task {
                await saveSessionCookies()
                await MoodleAPI.shared.syncCookies()   // share this login with the app's own page requests
            }
        }
    }

    // The saved session is gone or expired: get a key if allowed, otherwise wait and retry on our own.
    private func recoverSession() async {
        let api = MoodleAPI.shared
        guard api.privateToken != nil else {
            notice = "You're signed out. Sign in on this page; the session is saved, so you shouldn't need to again for a while."
            return
        }
        let wait = api.autologinWait
        if wait > 0 { waitAndRetry(after: wait + 5); return }
        let u = await api.autologin(resumeURL, userid: userid, force: true)
        if u.path.contains("autologin") {
            webView.load(URLRequest(url: u))
        } else {
            waitAndRetry(after: 60)
        }
    }

    private func waitAndRetry(after seconds: TimeInterval) {
        retryTask?.cancel()
        notice = "Automatic sign-in is on cooldown (Moodle allows one every 6 minutes). Retrying by itself, or sign in on this page."
        retryTask = Task { [weak self] in
            var delay = seconds
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let wait = MoodleAPI.shared.autologinWait
                if wait > 0 { delay = wait + 5; continue }
                let u = await MoodleAPI.shared.autologin(self.resumeURL, userid: self.userid, force: true)
                if u.path.contains("autologin") {
                    self.notice = nil
                    self.retryTask = nil
                    self.webView.load(URLRequest(url: u))
                    return
                }
                delay = 60
            }
            self?.retryTask = nil
        }
    }

    // ---- session cookies: kept in the Keychain so they survive the app being closed ----
    // (WebKit drops cookies that have no expiry date when the app quits.)

    private func hasSessionCookie() async -> Bool {
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return all.contains { $0.name.hasPrefix("MoodleSession") && ($0.expiresDate ?? .distantFuture) > Date() }
    }

    private func saveSessionCookies() async {
        guard let host = Site.url.host else { return }
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let mine = all.filter { Self.belongs($0, to: host) }
        guard !mine.isEmpty else { return }
        CookieVault.save(mine.map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                         secure: $0.isSecure, httpOnly: $0.isHTTPOnly, expires: $0.expiresDate)
        })
    }

    private func restoreSessionCookies() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let existing = await store.allCookies()
        for c in CookieVault.load() {
            if let e = c.expires, e < Date() { continue }
            if existing.contains(where: { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }) { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c.name, .value: c.value, .domain: c.domain, .path: c.path,
                .expires: c.expires ?? Date().addingTimeInterval(7 * 86400)
            ]
            if c.secure { props[.secure] = "TRUE" }
            if c.httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) { await store.setCookie(cookie) }
        }
    }

    private static func belongs(_ c: HTTPCookie, to host: String) -> Bool {
        host.hasSuffix(c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    /// Call when signing out: forgets the website login too, so the next person isn't signed in.
    static func wipeSession() {
        CookieVault.clear()
        if let host = Site.url.host {
            for c in HTTPCookieStorage.shared.cookies ?? [] where belongs(c, to: host) {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {}
        }
    }

    private func report(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }   // page turned into a file download
        notice = "Couldn't load the page: \(e.localizedDescription)"
    }

    // ---- WKNavigationDelegate ----

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { handleFinish(webView) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { report(error) }

    // Only real "other app" links go to iOS; everything else (including javascript: links) stays in the page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, let s = u.scheme?.lowercased(),
           ["mailto", "tel", "sms", "facetime", "itms-apps", "maps"].contains(s) {
            UIApplication.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Files the page can't display (zip, docx forced-download, ...) are downloaded, then offered via the share sheet
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = ((navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        if navigationResponse.isForMainFrame && (!navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment")) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    // ---- WKUIDelegate: links that want a new window open in place ----
    // (JavaScript alert/confirm pop-ups are left at WebKit's defaults on purpose; Moodle uses its own dialogs.)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // ---- WKDownloadDelegate ----

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = suggestedFilename.replacingOccurrences(of: "/", with: "_")
            let dest = dir.appendingPathComponent(name.isEmpty ? "file" : name)
            downloads[ObjectIdentifier(download)] = dest
            completionHandler(dest)
        } catch {
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        var vc = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        let sheet = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = webView
        sheet.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY,
                                                                 width: 1, height: 1)
        vc?.present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads[ObjectIdentifier(download)] = nil
        notice = "Download failed: \(error.localizedDescription)"
    }
}

// MARK: - Views

struct SiteWebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct SiteBrowserView: View {
    @ObservedObject var browser: SiteBrowser
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if browser.isLoading {
                ProgressView(value: browser.progress, total: 1).tint(Theme.accent)
            } else {
                Color.clear.frame(height: 2)
            }
            if let n = browser.notice {
                Text(n)
                    .font(.footnote)
                    .foregroundColor(Theme.txt)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface2)
                    .onTapGesture { browser.notice = nil }
            }
            SiteWebHost(webView: browser.webView)
            bar
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await browser.startIfNeeded(userid: app.site?.userid ?? 0) }
    }

    private var bar: some View {
        HStack(spacing: 26) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack)
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward)
            Spacer()
            Button {
                if browser.isLoading { browser.webView.stopLoading() } else { browser.reload() }
            } label: { Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise") }
            Button { browser.goHome() } label: { Image(systemName: "house") }
            if let u = browser.currentURL {
                Link(destination: u) { Image(systemName: "safari") }
            }
        }
        .font(.title3)
        .foregroundColor(Theme.accent)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }
}


// MARK: - Cookie storage (Keychain)

private struct StoredCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Date?
}

private enum CookieVault {
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "italeem.site-cookies",
         kSecAttrAccount as String: "session"]
    }

    static func save(_ list: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> [StoredCookie] {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return [] }
        return (try? JSONDecoder().decode([StoredCookie].self, from: d)) ?? []
    }

    static func clear() { SecItemDelete(base as CFDictionary) }
}

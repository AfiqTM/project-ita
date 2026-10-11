import SwiftUI
import WebKit

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

    // Called when the tab first appears. Nothing is loaded at app launch, so the single auto-login key
    // (Moodle allows one per 6 minutes) isn't spent before it's needed.
    func startIfNeeded(userid: Int) async {
        self.userid = userid
        guard !started else { return }
        started = true
        await open(home)
    }

    func open(_ target: URL, force: Bool = false) async {
        notice = nil
        await MoodleAPI.shared.syncCookies()
        let u = await MoodleAPI.shared.autologin(target, userid: userid, force: force)
        webView.load(URLRequest(url: u))
    }

    func goHome() { Task { await open(home) } }

    func reload() {
        if webView.url == nil { goHome() } else { webView.reload() }
    }

    private func handleFinish(_ w: WKWebView) {
        if let u = w.url, u.path.contains("/login/") {
            if !loginRetried {
                loginRetried = true
                Task { await retryLogin() }
            } else {
                notice = "You're signed out. Sign in on this page, or tap Home in a few minutes to try automatic sign-in again."
            }
        } else {
            loginRetried = false
            Task { await MoodleAPI.shared.syncCookies() }   // share this login with the app's own page requests
        }
    }

    private func retryLogin() async {
        let u = await MoodleAPI.shared.autologin(home, userid: userid, force: true)
        if u.path.contains("autologin") {
            webView.load(URLRequest(url: u))
        } else {
            notice = "Automatic sign-in is limited to once every 6 minutes. Sign in on this page, or tap Home later."
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

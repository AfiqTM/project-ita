import SwiftUI
import WebKit

// MARK: - Browser-based CAS sign-in (fallback for CASLogin.swift)
//
// CASLogin.swift replays the IIUM CAS login with plain URLSession requests. That can't run the CAS page's
// own JavaScript (device fingerprint, trusted-device cookie), so CAS may ask for the authenticator code again.
// This does the same sign-in in a hidden WKWebView, which behaves like a real browser:
//   1. open the CAS login page, 2. fill in the saved matric no. + password and submit,
//   3. follow the redirect back to iTa'leem, 4. copy the iTa'leem cookies into the Website tab's store
//      (and optionally ask for a mobile token through admin/tool/mobile/launch.php).
// It uses a throw-away data store; only the CAS "trusted device" cookies are kept (in the Keychain, via CASTrust),
// so signing out can't wipe them. The password is only ever typed into a page whose host is the CAS host.
// WebKit only runs while the app is in the foreground, so this is skipped in the background.

enum WebLoginResult: Equatable { case ok, needsCode, badCredentials, failed(String) }

@MainActor
final class WebCASLogin: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = WebCASLogin()

    /// Set (only when the caller asked for a prompt) when CAS wants the authenticator code
    @Published var needsCode = false

    private var task: Task<(result: WebLoginResult, session: Session?), Never>?
    private var lastFail = Date.distantPast
    private var waiter: CheckedContinuation<Bool, Never>?
    private var waitID = 0
    private var caught: URL?
    private var trace: [String] = []        // what the last attempt did, for the developer log
    private var lastNavError: String?   // why the last page failed to load

    private static let tokenNames: Set<String> = ["token", "otp", "code", "totp", "verificationcode", "passcode"]
    private struct Input { let name: String; let type: String }
    private struct Probe { let host: String; let path: String; let inputs: [Input]; let msg: String; let hosts: [String] }

    // MARK: entry point

    /// Signs in with the saved details in a hidden web view. `code`: authenticator code, if CAS asks for one.
    /// `wantToken`: also fetch an app token. `prompt`: show the code sheet when a code is needed.
    /// `source` / `log`: how the attempt is recorded in the auto sign-in log (Save login info); callers that log
    /// the outcome themselves pass `log: false`.
    func refresh(code: String? = nil, wantToken: Bool = false, prompt: Bool = false,
                 source: String = "Hidden browser", log: Bool = true)
        async -> (result: WebLoginResult, session: Session?) {
        if let t = task { return await t.value }
        guard let c = SavedLoginStore.load(), SavedLogin.shared.canRelogin else { return (.failed("No saved login"), nil) }
        guard UIApplication.shared.applicationState == .active else { return (.failed("App is in the background"), nil) }
        let hasCode = !(code ?? "").isEmpty
        if !hasCode, Date().timeIntervalSince(lastFail) < 60 { return (.failed("Waiting before the next attempt"), nil) }

        let t = Task { await self.run(c, code: code, wantToken: wantToken) }
        task = t
        let r = await t.value
        task = nil
        if log { LoginLog.add(source, ok: r.result == .ok, note: LoginLog.describe(r.result)) }
        DevLog.add(.login, "Hidden browser [\(source)] " + (r.result == .ok ? "signed in" : LoginLog.describe(r.result))
                   + (trace.isEmpty ? "" : " | " + trace.joined(separator: " > ")), ok: r.result == .ok)
        switch r.result {
        case .ok: lastFail = .distantPast; needsCode = false
        case .needsCode: lastFail = Date(); if prompt { needsCode = true }
        case .badCredentials: lastFail = Date(); SavedLogin.shared.badCredentials = true
        case .failed: lastFail = Date()
        }
        return r
    }

    // MARK: the sign-in itself

    private func run(_ c: SavedCredentials, code: String?, wantToken: Bool) async -> (result: WebLoginResult, session: Session?) {
        func fail(_ m: String) -> (result: WebLoginResult, session: Session?) { (.failed(m), nil) }
        guard let ssoHost = CASLogin.casURL.host, let siteHost = Site.url.host else { return fail("Bad URLs") }
        let otp = (code ?? "").filter { $0.isNumber }
        trace = []; lastNavError = nil

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: cfg)
        wv.navigationDelegate = self
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(wv)
        defer { wv.stopLoading(); wv.removeFromSuperview(); caught = nil }

        let store = cfg.websiteDataStore.httpCookieStore
        for ck in CASTrust.load() { await store.setCookie(ck) }   // "trusted device" cookie from an earlier sign-in

        guard await navigate({ wv.load(URLRequest(url: CASLogin.casURL)) }) else {
            trace.append("sign-in page did not load")
            return fail("The IIUM sign-in page didn't load" + (lastNavError.map { " (\($0))" } ?? ""))
        }
        trace.append("sign-in page loaded")

        var sentCreds = false, sentCode = false, sentDevice = false, idle = 0, done = false
        for _ in 0..<8 {
            guard let p = await probe(wv) else { return fail("Couldn't read the sign-in page") }
            trace.append("\(p.host)\(p.path)")
            for h in p.hosts { DevLog.host(h, .seen, "referenced by the sign-in page") }
            if p.host == siteHost {
                if p.path.contains("/login/") { return fail("iTa'leem didn't accept the IIUM sign-in") }
                done = true; break
            }
            guard p.host == ssoHost else { return fail("Unexpected page: \(p.host)") }

            let notToken: (Input) -> Bool = { !Self.tokenNames.contains($0.name.lowercased()) }
            let passIn = p.inputs.first { $0.type == "password" && notToken($0) }
            let userIn = p.inputs.first { ["text", "email"].contains($0.type) && notToken($0) }
            let loginAgain = passIn != nil && userIn != nil
            let tokenField = p.inputs.first { Self.tokenNames.contains($0.name.lowercased()) }?.name
                ?? (loginAgain ? nil : p.inputs.first { ["password", "tel", "number"].contains($0.type) }?.name)

            if let tf = tokenField {
                if otp.isEmpty { return (.needsCode, nil) }
                if sentCode { return fail("IIUM rejected the authenticator code. Wait for a fresh one and try again.") }
                var f = [tf: otp]
                if loginAgain, let u = userIn, let pw = passIn { f[u.name] = c.user; f[pw.name] = c.pass }
                guard await submit(wv, f, host: ssoHost) else { return fail("Couldn't send the code") }
                trace.append("sent code")
                sentCode = true; continue
            }
            if loginAgain, let u = userIn, let pw = passIn {
                if sentCode { return fail("IIUM rejected the authenticator code. Wait for a fresh one and try again.") }
                if sentCreds {   // the form came back after the details were sent
                    if p.msg.lowercased().contains("token") { return otp.isEmpty ? (.needsCode, nil) : fail("IIUM needs a step I couldn't finish") }
                    return (.badCredentials, nil)
                }
                guard await submit(wv, [u.name: c.user, pw.name: c.pass], host: ssoHost) else { return fail("Couldn't fill in the sign-in form") }
                trace.append("sent details")
                sentCreds = true; continue
            }
            if !sentDevice, let first = p.inputs.first, p.inputs.allSatisfy({ ["text", "email"].contains($0.type) }) {
                // "trust this device" page: name the device so later sign-ins can skip the code
                guard await submit(wv, [first.name: "iTa'leem iPhone"], host: ssoHost) else { return fail("Couldn't finish the device step") }
                trace.append("named device")
                sentDevice = true; continue
            }
            if p.inputs.isEmpty, idle < 2 { idle += 1; _ = await navigate(timeout: 4) {}; continue }
            return fail("IIUM sign-in needs a step I don't know [\(p.path) | \(p.inputs.map { $0.name + ":" + $0.type }.joined(separator: ","))]")
        }
        guard done else { return fail("IIUM sign-in didn't finish") }

        // keep the CAS trusted-device cookies for next time
        let all = await store.allCookies()
        CASTrust.save(all.filter { ssoHost.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
                         .filter { $0.expiresDate != nil || $0.name.uppercased().contains("TRUST") })

        // share the iTa'leem session with the Website tab and the app's own page requests
        let main = WKWebsiteDataStore.default().httpCookieStore
        for ck in all where siteHost.hasSuffix(ck.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            await main.setCookie(ck)
        }
        await MoodleAPI.shared.syncCookies()

        var session: Session?
        if wantToken {
            var lc = URLComponents(url: Site.url.appendingPathComponent("admin/tool/mobile/launch.php"), resolvingAgainstBaseURL: false)!
            lc.queryItems = [URLQueryItem(name: "service", value: "moodle_mobile_app"),
                             URLQueryItem(name: "passport", value: UUID().uuidString),
                             URLQueryItem(name: "urlscheme", value: "moodlemobile")]
            caught = nil
            _ = await navigate { wv.load(URLRequest(url: lc.url!)) }
            if let u = caught { session = WebAuth.parse(u) }
            if session == nil { return fail("Signed in, but iTa'leem didn't return a token") }
        }
        return (.ok, session)
    }

    // MARK: page helpers

    private func probe(_ wv: WKWebView) async -> Probe? {
        let js = """
        const skip = ['hidden','submit','button','image','reset','checkbox','radio','file'];
        const inputs = [...document.querySelectorAll('input')]
          .filter(i => i.name && !skip.includes((i.type || 'text').toLowerCase()))
          .map(i => ({name: i.name, type: (i.type || 'text').toLowerCase()}));
        const msg = [...document.querySelectorAll('#msg,.alert,.alert-danger,.error,.text-danger')]
          .map(e => (e.innerText || '').trim()).filter(t => t && !/caps/i.test(t)).join(' / ').slice(0, 300);
        const hosts = [...new Set([...document.querySelectorAll('script[src],link[href],img[src],iframe[src]')]
          .map(e => { try { return new URL(e.src || e.href, location.href).host; } catch (_) { return ''; } })
          .filter(h => h))];
        return JSON.stringify({host: location.hostname, path: location.pathname, inputs: inputs, msg: msg, hosts: hosts});
        """
        guard let s = try? await wv.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) as? String,
              let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let ins = (o["inputs"] as? [[String: String]] ?? []).compactMap { i -> Input? in
            guard let n = i["name"], let t = i["type"] else { return nil }
            return Input(name: n, type: t)
        }
        return Probe(host: o["host"] as? String ?? "", path: o["path"] as? String ?? "", inputs: ins, msg: o["msg"] as? String ?? "",
                     hosts: o["hosts"] as? [String] ?? [])
    }

    /// Types the values into the page's fields and submits the form, then waits for the next page.
    /// Refuses unless the page really is on the CAS host, so the password can't be typed anywhere else.
    private func submit(_ wv: WKWebView, _ fields: [String: String], host: String) async -> Bool {
        let js = """
        if (location.hostname !== host) return false;
        let form = null;
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        for (const [n, v] of Object.entries(fields)) {
          const el = [...document.querySelectorAll('input')].find(i => i.name === n);
          if (!el) return false;
          form = form || el.form;
          setter.call(el, v);
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
        }
        if (!form) return false;
        const btn = form.querySelector('[type=submit]');
        if (btn) btn.click(); else if (form.requestSubmit) form.requestSubmit(); else form.submit();
        return true;
        """
        let ok = await navigate {
            Task { @MainActor in
                let r = try? await wv.callAsyncJavaScript(js, arguments: ["fields": fields, "host": host],
                                                          in: nil, contentWorld: .page) as? Bool
                if r != true { self.resolveWait(false) }
            }
        }
        return ok
    }

    /// Runs `start`, then waits until the web view finishes loading a page (or gives up after `timeout`).
    private func navigate(timeout: TimeInterval = 25, _ start: () -> Void) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            waitID += 1
            let id = waitID
            waiter = c
            start()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if self?.waitID == id { self?.resolveWait(false) }
            }
        }
    }

    private func resolveWait(_ ok: Bool) {
        let w = waiter
        waiter = nil
        w?.resume(returning: ok)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") { DevLog.host(DevLog.label(u), .ok, "page loaded") }
        resolveWait(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }   // replaced by a redirect
        lastNavError = "\(e.domain) \(e.code): \(e.localizedDescription)"
        DevLog.network(.login, error, "hidden browser page")
        resolveWait(false)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            DevLog.host(DevLog.label(u), .seen, "visited by the hidden browser")
        }
        if let u = navigationAction.request.url, u.scheme == "moodlemobile" {
            caught = u
            decisionHandler(.cancel)
            resolveWait(true)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Sheet: authenticator code (shown on the Website tab when CAS asks for it)

struct WebLoginCodeSheet: View {
    @ObservedObject var login = WebCASLogin.shared
    var onDone: () -> Void
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("IIUM wants your authenticator code").font(Theme.font(.headline)).foregroundColor(Theme.txt)
            Text("Enter it once. The app signs in with your saved details and CAS remembers this device.")
                .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .padding(12).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))
            if let message { Text(message).font(Theme.font(.footnote)).foregroundColor(.red.opacity(0.85)) }
            HStack(spacing: 20) {
                Button {
                    Task {
                        busy = true; message = nil
                        let r = await login.refresh(code: code, source: "Code sheet")
                        busy = false
                        switch r.result {
                        case .ok: login.needsCode = false; onDone()
                        case .needsCode: message = "That code didn't work. Wait for a new one."
                        case .badCredentials: message = "IIUM says the saved password is wrong."
                        case .failed(let m): message = m
                        }
                    }
                } label: { if busy { ProgressView().tint(Theme.accent) } else { Text("Verify") } }
                .disabled(busy || code.filter { $0.isNumber }.count < 6)
                Button("Cancel") { login.needsCode = false }.disabled(busy)
            }
            .font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.accent)
            Spacer()
        }
        .padding(20)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

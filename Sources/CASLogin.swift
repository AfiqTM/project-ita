import Foundation
import Security

// MARK: - IIUM CAS sign-in (matric no. + password, no browser)
//
// iTa'leem students don't have a Moodle password: they sign in through IIUM's CAS single sign-on
// ("IIUM Student and Staff Login"). Moodle's own login/token.php therefore always answers "wrong password".
// This does what pressing that button does, by itself:
//   1. open the CAS login page for iTa'leem (the page the button leads to)
//   2. send the matric no. + password with the hidden fields CAS put in its form
//   3. CAS sends us back to iTa'leem with a ticket, which logs this session in
//   4. ask iTa'leem for a mobile token (admin/tool/mobile/launch.php); it answers with moodlemobile://token=...
// It uses its own cookie jar, so it never touches the Website tab. It can't complete 2FA / captcha:
// in that case the browser button on the login screen is still there.

enum CASLogin {
    static let casURL: URL = {
        var c = URLComponents(string: "https://sso.iium.edu.my:8448/cas/login")!
        c.queryItems = [URLQueryItem(name: "service",
                                     value: Site.url.absoluteString + "/login/index.php?authCASattras=CASattras")]
        return c.url!
    }()

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Stops the redirect chain when it reaches moodlemobile://... and keeps that address
    private final class Catcher: NSObject, URLSessionTaskDelegate {
        var caught: URL?
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            if let u = request.url, u.scheme == "moodlemobile" { caught = u; completionHandler(nil) }
            else { completionHandler(request) }
        }
    }

    private static let tokenNames: Set<String> = ["token", "otp", "code", "totp", "verificationcode", "passcode"]

    static func login(_ user: String, _ pass: String, code: String? = nil) async throws -> Session {
        let otp = (code ?? "").filter { $0.isNumber }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["User-Agent": ua, "Accept-Language": "en"]
        CASTrust.restore(into: cfg.httpCookieStorage)   // the "trusted device" cookie from an earlier code sign-in
        let http = URLSession(configuration: cfg)
        defer { http.finishTasksAndInvalidate() }

        // 1. the CAS page
        let (pageData, pageResp) = try await http.data(from: casURL)
        let pageURL = pageResp.url ?? casURL
        let html = String(decoding: pageData, as: UTF8.self)
        guard let form = HTMLForm.loginForm(in: html, base: pageURL) else {
            throw APIError(message: "Couldn't find the IIUM sign-in form. Use the browser sign-in instead.", code: "casform")
        }

        // 2. send the details
        var fields = form.fields
        fields[form.userField] = user
        fields[form.passField] = pass
        fillDefaults(&fields)
        var (data, resp) = try await post(http, to: form.action, referer: pageURL, fields: fields)

        // Whatever CAS answers while we are still on its site is another step: the authenticator code,
        // a "trust this device" page, or the sign-in form again (wrong details)
        var sentCode = false, registered = false
        for _ in 0..<4 {
            guard resp.url?.host == casURL.host else { break }   // left CAS: signed in
            let t = String(decoding: data, as: UTF8.self)
            let base = resp.url ?? casURL
            let msg = pageMessage(t)
            guard let step = HTMLForm.stepForm(in: t, base: base) else {
                throw APIError(message: "IIUM sign-in needs another step I couldn't read. Use the browser sign-in instead. [debug: \(base.path) | inputs: \(inputSummary(t)) | page says: \(msg)]",
                               code: "casstep")
            }
            let names = Set(step.visible.map { $0.name })
            let loginAgain = names.contains(form.userField) && names.contains(form.passField)
            let tokenField: String? = step.visible.first(where: { tokenNames.contains($0.name.lowercased()) })?.name
                ?? (loginAgain ? nil : step.visible.first(where: { ["password", "tel", "number"].contains($0.type) })?.name)

            if let tf = tokenField {
                if otp.isEmpty {
                    throw APIError(message: "IIUM wants the code from your authenticator app. Type it in the code box, then sign in again.",
                                   code: "casmfa")
                }
                if sentCode {
                    throw APIError(message: "IIUM rejected the authenticator code. Wait for a fresh code and try again. [debug: inputs: \(inputSummary(t)) | page says: \(msg)]",
                                   code: "casmfarejected")
                }
                var f = step.hidden
                f[tf] = otp
                if loginAgain { f[form.userField] = user; f[form.passField] = pass }
                fillDefaults(&f)
                (data, resp) = try await post(http, to: step.action, referer: base, fields: f)
                sentCode = true
                continue
            }

            if loginAgain {
                if sentCode {
                    throw APIError(message: "IIUM rejected the authenticator code. Wait for a fresh code and try again. [debug: inputs: \(inputSummary(t)) | page says: \(msg)]",
                                   code: "casmfarejected")
                }
                if msg.lowercased().contains("token") {
                    throw APIError(message: "IIUM asked for a second step after your password, but I couldn't find where the code goes. Use the browser sign-in. [debug: inputs: \(inputSummary(t)) | page says: \(msg)]",
                                   code: "casstep")
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let page = resp.url.map { ($0.host ?? "") + $0.path } ?? "?"
                let sent = fields.keys.sorted().joined(separator: ",")
                let cookies = (cfg.httpCookieStorage?.cookies(for: casURL) ?? []).map { $0.name }.sorted().joined(separator: ",")
                throw APIError(message: "Matric no. or password is wrong. [debug: HTTP \(status) \(page) | sent: \(sent) | user field: \(form.userField), pass field: \(form.passField) | cookies: \(cookies.isEmpty ? "none" : cookies) | page says: \(msg)]",
                               code: "invalidlogin")
            }

            if !registered, step.visible.allSatisfy({ ["text", "email"].contains($0.type) }) {
                // a "trust this device" page: name the device so later sign-ins can skip the code
                var f = step.hidden
                f[step.visible[0].name] = "iTa'leem iPhone"
                fillDefaults(&f)
                (data, resp) = try await post(http, to: step.action, referer: base, fields: f)
                registered = true
                continue
            }

            throw APIError(message: "IIUM sign-in needs a step I don't know yet. Use the browser sign-in instead. [debug: \(base.path) | inputs: \(inputSummary(t)) | page says: \(msg)]",
                           code: "casstep")
        }
        guard resp.url?.host != casURL.host else {
            throw APIError(message: "IIUM sign-in didn't finish. Use the browser sign-in instead.", code: "casstep")
        }
        // keep the "trusted device" cookie, if CAS gave one, so the next sign-in can skip the code
        CASTrust.save((cfg.httpCookieStorage?.cookies(for: casURL) ?? []).filter { $0.name.uppercased().contains("TRUST") })

        // 3. + 4. we are signed in to iTa'leem: ask for the app token
        let passport = UUID().uuidString
        var c = URLComponents(url: Site.url.appendingPathComponent("admin/tool/mobile/launch.php"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "service", value: "moodle_mobile_app"),
                        URLQueryItem(name: "passport", value: passport),
                        URLQueryItem(name: "urlscheme", value: "moodlemobile")]
        let catcher = Catcher()
        var launch = URLRequest(url: c.url!)
        launch.setValue("text/html", forHTTPHeaderField: "Accept")
        _ = try? await http.data(for: launch, delegate: catcher)   // ends with a URL error once the redirect is cancelled
        if let u = catcher.caught, let s = WebAuth.parse(u) { return s }
        throw APIError(message: "Signed in to IIUM, but iTa'leem didn't return a token. Mobile access may be disabled, or use the browser sign-in.",
                       code: "notoken")
    }

    /// The visible error text on a CAS page (for the debug part of the error message)
    private static func pageMessage(_ html: String) -> String {
        var h = html
        for tag in ["script", "style"] {
            if let rx = try? NSRegularExpression(pattern: "<\\(tag)\\b.*?</\\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                h = rx.stringByReplacingMatches(in: h, range: NSRange(location: 0, length: (h as NSString).length), withTemplate: " ")
            }
        }
        let ns = h as NSString
        if let rx = try? NSRegularExpression(pattern: "<(div|span|p)\\b[^>]*(id=\"msg\"|class=\"[^\"]*(alert|error|danger)[^\"]*\")[^>]*>(.*?)</\\1>",
                                             options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let found = rx.matches(in: h, range: NSRange(location: 0, length: ns.length))
                .map { strip(ns.substring(with: $0.range(at: 4))) }
                .filter { !$0.isEmpty && !$0.lowercased().contains("caps") }
            if !found.isEmpty { return String(found.joined(separator: " / ").prefix(300)) }
        }
        return "(no error box) " + String(strip(h).prefix(300))
    }

    private static func strip(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func post(_ http: URLSession, to url: URL, referer: URL, fields: [String: String]) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        req.httpBody = fields.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&").data(using: .utf8)
        return try await http.data(for: req)
    }

    private static func fillDefaults(_ f: inout [String: String]) {
        if f["_eventId"] == nil { f["_eventId"] = "submit" }
        // The real page fills this in with JavaScript; a plain request would send it empty
        if let fp = f["deviceFingerprint"], fp.isEmpty { f["deviceFingerprint"] = deviceFingerprint() }
    }

    /// name:type of every <input> on a page (no values), for working out what a CAS step asks for
    private static func inputSummary(_ html: String) -> String {
        guard let rx = try? NSRegularExpression(pattern: "<input\\b[^>]*>", options: .caseInsensitive) else { return "" }
        let ns = html as NSString
        func attr(_ tag: String, _ n: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: "(?<![\\w-])\(n)\\s*=\\s*[\"']([^\"']*)[\"']", options: .caseInsensitive),
                  let m = r.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
            return (tag as NSString).substring(with: m.range(at: 1))
        }
        return rx.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { m -> String in
            let tag = ns.substring(with: m.range)
            return (attr(tag, "name") ?? "?") + ":" + (attr(tag, "type") ?? "text")
        }.joined(separator: ",")
    }

    /// Stable random id standing in for the browser fingerprint the CAS page script would create
    private static func deviceFingerprint() -> String {
        let k = "cas.devicefp"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(s, forKey: k)
        return s
    }

    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Tiny form reader (CAS pages carry hidden fields such as `execution` that must be sent back)

struct HTMLForm {
    var action: URL
    var fields: [String: String]
    var userField: String
    var passField: String

    static func loginForm(in html: String, base: URL) -> HTMLForm? {
        guard let formRx = try? NSRegularExpression(pattern: "<form\\b([^>]*)>(.*?)</form>",
                                                    options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = html as NSString
        for m in formRx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            var fields: [String: String] = [:]
            var pass: String?, user: String?
            for tag in tags("input", in: body) {
                let a = attributes(of: tag)
                guard let name = a["name"], !name.isEmpty else { continue }
                switch (a["type"] ?? "text").lowercased() {
                case "password": pass = name
                case "hidden": fields[name] = a["value"] ?? ""
                case "text", "email":
                    if user == nil || name.lowercased() == "username" { user = name }
                default: break
                }
            }
            guard let p = pass else { continue }
            let act = attributes(of: "<form " + attrs + ">")["action"] ?? ""
            let url = act.isEmpty ? base : (URL(string: act, relativeTo: base)?.absoluteURL ?? base)
            return HTMLForm(action: url, fields: fields, userField: user ?? "username", passField: p)
        }
        return nil
    }

    private static func tags(_ name: String, in s: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: .caseInsensitive) else { return [] }
        let ns = s as NSString
        return rx.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func attributes(of tag: String) -> [String: String] {
        guard let rx = try? NSRegularExpression(pattern: "([a-zA-Z_:-]+)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')") else { return [:] }
        let ns = tag as NSString
        var out: [String: String] = [:]
        for m in rx.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let r = m.range(at: 3).location != NSNotFound ? m.range(at: 3) : m.range(at: 4)
            out[key] = decode(ns.substring(with: r))
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#x3D;", with: "=")
         .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// One page of a CAS flow: hidden fields to send back, and the inputs the person would see
struct StepForm {
    var action: URL
    var hidden: [String: String]
    var visible: [(name: String, type: String)]
}

extension HTMLForm {
    /// The first form that has a visible input (the sign-in form, the code form, a device-name form)
    static func stepForm(in html: String, base: URL) -> StepForm? {
        guard let formRx = try? NSRegularExpression(pattern: "<form\\b([^>]*)>(.*?)</form>",
                                                    options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = html as NSString
        for m in formRx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            var hidden: [String: String] = [:]
            var visible: [(name: String, type: String)] = []
            for tag in tags("input", in: body) {
                let a = attributes(of: tag)
                guard let name = a["name"], !name.isEmpty else { continue }
                let type = (a["type"] ?? "text").lowercased()
                switch type {
                case "hidden": hidden[name] = a["value"] ?? ""
                case "submit", "button", "image", "reset", "checkbox", "radio", "file": break
                default: visible.append((name: name, type: type))
                }
            }
            guard !visible.isEmpty else { continue }
            let act = attributes(of: "<form " + attrs + ">")["action"] ?? ""
            let url = act.isEmpty ? base : (URL(string: act, relativeTo: base)?.absoluteURL ?? base)
            return StepForm(action: url, hidden: hidden, visible: visible)
        }
        return nil
    }
}

/// The CAS "trusted device" cookie, kept in the Keychain so a saved login can skip the authenticator code
enum CASTrust {
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "italeem",
         kSecAttrAccount as String: "cas-trust"]
    }

    static func save(_ cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else { return }
        let list: [[String: Any]] = cookies.map { c in
            var d: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "secure": c.isSecure]
            if let e = c.expiresDate { d["expires"] = e }
            return d
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func restore(into storage: HTTPCookieStorage?) {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let list = (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [[String: Any]] else { return }
        for item in list {
            guard let name = item["name"] as? String, let value = item["value"] as? String,
                  let domain = item["domain"] as? String, let path = item["path"] as? String else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if let e = item["expires"] as? Date {
                if e < Date() { continue }
                props[.expires] = e
            }
            if (item["secure"] as? Bool) == true { props[.secure] = "TRUE" }
            if let c = HTTPCookie(properties: props) { storage?.setCookie(c) }
        }
    }

    static func clear() { SecItemDelete(query() as CFDictionary) }
}
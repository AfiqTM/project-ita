import Foundation

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

    static func login(_ user: String, _ pass: String) async throws -> Session {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["User-Agent": ua, "Accept-Language": "en"]
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
        if fields["_eventId"] == nil { fields["_eventId"] = "submit" }
        var req = URLRequest(url: form.action)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        req.httpBody = fields.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (afterData, afterResp) = try await http.data(for: req)

        // CAS shows the form again when the details are wrong
        if afterResp.url?.host == casURL.host {
            let t = String(decoding: afterData, as: UTF8.self)
            if HTMLForm.loginForm(in: t, base: afterResp.url ?? casURL) != nil {
                let status = (afterResp as? HTTPURLResponse)?.statusCode ?? 0
                let page = afterResp.url.map { ($0.host ?? "") + $0.path } ?? "?"
                let sent = fields.keys.sorted().joined(separator: ",")
                throw APIError(message: "Matric no. or password is wrong. [debug: HTTP \(status) \(page) | sent: \(sent) | user field: \(form.userField), pass field: \(form.passField) | page says: \(pageMessage(t))]",
                               code: "invalidlogin")
            }
            throw APIError(message: "IIUM sign-in needs another step (2FA or a confirmation). Use the browser sign-in instead.", code: "casstep")
        }

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
                                             options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let m = rx.firstMatch(in: h, range: NSRange(location: 0, length: ns.length)) {
            let t = strip(ns.substring(with: m.range(at: 4)))
            if !t.isEmpty { return String(t.prefix(200)) }
        }
        return "(no error box) " + String(strip(h).prefix(160))
    }

    private static func strip(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

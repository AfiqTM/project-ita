import Foundation
import UIKit
import AuthenticationServices

// MARK: - Errors / session

struct APIError: LocalizedError {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
    var isAuth: Bool { code == "invalidtoken" || code == "accessexception" && message.lowercased().contains("token") }
}

struct Session: Codable {
    var token: String
    var privateToken: String?
}

// MARK: - Client

final class MoodleAPI {
    static let shared = MoodleAPI()
    var token = ""
    var privateToken: String?
    private var lastAutologin = Date.distantPast

    private func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // Moodle wants arrays as key[0]=..., dicts as key[name]=...
    private func flatten(_ v: Any, prefix: String?, into out: inout [(String, String)]) {
        if let d = v as? [String: Any] {
            for (k, x) in d { flatten(x, prefix: prefix.map { "\($0)[\(k)]" } ?? k, into: &out) }
        } else if let a = v as? [Any] {
            for (i, x) in a.enumerated() { flatten(x, prefix: "\(prefix ?? "")[\(i)]", into: &out) }
        } else if let p = prefix {
            out.append((p, "\(v)"))
        }
    }

    func call<T: Decodable>(_ fn: String, _ params: [String: Any] = [:]) async throws -> T {
        var items: [(String, String)] = [("wstoken", token), ("wsfunction", fn), ("moodlewsrestformat", "json")]
        flatten(params, prefix: nil, into: &items)
        var req = URLRequest(url: Site.url.appendingPathComponent("webservice/rest/server.php"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = items.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           o["exception"] != nil || o["errorcode"] != nil {
            throw APIError(message: (o["message"] as? String) ?? "Request failed",
                           code: o["errorcode"] as? String)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func siteInfo() async throws -> SiteInfo { try await call("core_webservice_get_site_info") }

    // File URLs need the token and the /webservice/ prefix
    func fileURL(_ s: String) -> URL? {
        var str = s
        if !str.contains("/webservice/pluginfile.php") {
            str = str.replacingOccurrences(of: "/pluginfile.php", with: "/webservice/pluginfile.php")
        }
        str += (str.contains("?") ? "&" : "?") + "token=" + token
        return URL(string: str)
    }

    // Opens a normal website page already logged in. The key is single-use and
    // Moodle rate-limits it to once per 6 minutes; otherwise the web view's cookie session is used.
    func autologin(_ target: URL, userid: Int) async -> URL {
        guard let pt = privateToken, Date().timeIntervalSince(lastAutologin) > 360 else { return target }
        do {
            let r: AutoKey = try await call("tool_mobile_get_autologin_key", ["privatetoken": pt])
            lastAutologin = Date()
            guard var c = URLComponents(string: r.autologinurl) else { return target }
            c.queryItems = [URLQueryItem(name: "userid", value: String(userid)),
                            URLQueryItem(name: "key", value: r.key),
                            URLQueryItem(name: "urltogo", value: target.absoluteString)]
            return c.url ?? target
        } catch { return target }
    }

    // Username + password (accounts WITHOUT 2FA)
    func passwordLogin(_ user: String, _ pass: String) async throws -> Session {
        var req = URLRequest(url: Site.url.appendingPathComponent("login/token.php"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "username=\(enc(user))&password=\(enc(pass))&service=moodle_mobile_app".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let r = try JSONDecoder().decode(TokenResp.self, from: data)
        if let t = r.token { return Session(token: t, privateToken: r.privatetoken) }
        throw APIError(message: r.error ?? "Login failed", code: r.errorcode)
    }
}

// MARK: - Browser login (handles 2FA / SSO)

final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start() async throws -> Session {
        let passport = UUID().uuidString
        var c = URLComponents(url: Site.url.appendingPathComponent("admin/tool/mobile/launch.php"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "service", value: "moodle_mobile_app"),
                        URLQueryItem(name: "passport", value: passport),
                        URLQueryItem(name: "urlscheme", value: "moodlemobile")]
        return try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "moodlemobile") { url, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let url = url, let sess = WebAuth.parse(url) else {
                    cont.resume(throwing: APIError(message: "The site didn't return a login token. Mobile access may be disabled on iTa'leem."))
                    return
                }
                cont.resume(returning: sess)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            s.start()
        }
    }

    // moodlemobile://token=BASE64(siteid:::token:::privatetoken)
    static func parse(_ url: URL) -> Session? {
        let s = url.absoluteString
        guard let r = s.range(of: "token=") else { return nil }
        var b64 = (String(s[r.upperBound...]).removingPercentEncoding ?? "")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64), let dec = String(data: d, encoding: .utf8) else { return nil }
        let p = dec.components(separatedBy: ":::")
        guard p.count >= 2 else { return nil }
        return Session(token: p[1], privateToken: p.count > 2 ? p[2] : nil)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

// MARK: - Models (all tolerant: most fields optional)

struct TokenResp: Decodable { let token: String?; let privatetoken: String?; let error: String?; let errorcode: String? }
struct AutoKey: Decodable { let key: String; let autologinurl: String }

struct SiteInfo: Decodable {
    let userid: Int
    let fullname: String
    let userpictureurl: String?
    let sitename: String?
}

struct CourseList: Decodable { let courses: [Course] }
struct Course: Decodable, Identifiable {
    let id: Int
    let fullname: String
    let shortname: String?
    let progress: Double?
    let isfavourite: Bool?
    let hidden: Bool?
    let courseimage: String?
}

struct CourseSection: Decodable, Identifiable {
    let id: Int
    let name: String
    let summary: String?
    let modules: [Module]
}
struct Module: Decodable, Identifiable {
    let id: Int
    let name: String
    let modname: String
    let instance: Int?
    let url: String?
    let description: String?
    let uservisible: Bool?
    let contents: [ModContent]?
}
struct ModContent: Decodable, Identifiable {
    var id: String { (fileurl ?? "") + (filename ?? "") }
    let type: String?
    let filename: String?
    let fileurl: String?
    let filesize: Int?
    let timemodified: Int?
}

struct EventsResp: Decodable { let events: [TLEvent] }
struct TLEvent: Decodable, Identifiable {
    let id: Int
    let name: String
    let timesort: Int
    let url: String?
    let course: EvCourse?
    let modulename: String?
}
struct EvCourse: Decodable { let id: Int; let fullname: String }

struct NotifResp: Decodable { let notifications: [Notif] }
struct Notif: Decodable, Identifiable {
    let id: Int
    let subject: String?
    let smallmessage: String?
    let timecreated: Int?
    let read: Bool?
    let contexturl: String?
}

struct DiscResp: Decodable { let discussions: [Discussion] }
struct Discussion: Decodable, Identifiable {
    let id: Int
    let discussion: Int
    let name: String?
    let subject: String?
    let message: String?
    let userfullname: String?
    let created: Int?
    let numreplies: Int?
}
struct PostsResp: Decodable { let posts: [Post] }
struct Post: Decodable, Identifiable {
    let id: Int
    let subject: String?
    let message: String?
    let timecreated: Int?
    let author: PAuthor?
}
struct PAuthor: Decodable { let fullname: String? }

struct GradesResp: Decodable { let usergrades: [UserGrade] }
struct UserGrade: Decodable { let gradeitems: [GradeItem] }
struct GradeItem: Decodable, Identifiable {
    let id: Int
    let itemname: String?
    let gradeformatted: String?
    let rangeformatted: String?
    let percentageformatted: String?
}

struct Person: Decodable, Identifiable {
    let id: Int
    let fullname: String
    let profileimageurlsmall: String?
}

struct AssignResp: Decodable { let courses: [AssignCourse] }
struct AssignCourse: Decodable { let id: Int; let assignments: [Assign] }
struct Assign: Decodable, Identifiable {
    let id: Int
    let cmid: Int
    let name: String
    let duedate: Int?
    let intro: String?
}
struct StatusResp: Decodable { let lastattempt: LastAttempt?; let feedback: Feedback? }
struct LastAttempt: Decodable { let submission: Sub?; let gradingstatus: String? }
struct Sub: Decodable { let status: String? }
struct Feedback: Decodable { let gradefordisplay: String? }

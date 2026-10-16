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
    // Remembered across launches: Moodle enforces its 6-minute limit on the server, so a relaunch
    // must not forget that a key was just handed out.
    private var lastAutologin: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "autologin.last")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "autologin.last") }
    }
    /// Seconds until Moodle will give out another auto-login key (0 = available now).
    /// Uses 370s (not 360) as a safety margin for clock drift / server timing.
    var autologinWait: TimeInterval { max(0, 370 - Date().timeIntervalSince(lastAutologin)) }

    // Moodle's autologin function (and some pages) only work for requests whose User-Agent
    // contains "MoodleMobile", which is how the site recognises the official app.
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MoodleMobile"
        ]
        return URLSession(configuration: cfg)
    }()

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

    // Fields that hold HTML are left alone (they go through plainText later); everything else is entity-decoded
    private static let htmlKeys: Set<String> = ["message", "intro", "summary", "description", "smallmessage",
                                                "fullmessage", "fullmessagehtml", "text", "content"]
    private func decodeEntities(_ v: Any, key: String? = nil) -> Any {
        if let s = v as? String { return (key.map { MoodleAPI.htmlKeys.contains($0) } ?? false) ? s : s.decodedEntities }
        if let a = v as? [Any] { return a.map { decodeEntities($0, key: key) } }
        if let d = v as? [String: Any] {
            var out = [String: Any]()
            for (k, x) in d { out[k] = decodeEntities(x, key: k) }
            return out
        }
        return v
    }

    /// Network request that gives up after `limit` seconds (used when a saved copy can stand in)
    private func fetch(_ req: URLRequest, limit: TimeInterval?) async throws -> (Data, URLResponse) {
        guard let limit else { return try await MoodleAPI.session.data(for: req) }
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { g in
            g.addTask { try await MoodleAPI.session.data(for: req) }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw URLError(.unknown) }
            return first
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed]

    /// Name under which the answer to this exact call is saved on disk
    func offlineName(_ fn: String, _ params: [String: Any] = [:]) -> String {
        var keyItems: [(String, String)] = []
        flatten(params, prefix: nil, into: &keyItems)
        return OfflineCache.apiName(fn, keyItems.map { "\($0.0)=\($0.1)" }.sorted().joined(separator: "&"))
    }

    func raw(_ fn: String, _ params: [String: Any] = [:]) async throws -> Data {
        let useCache = OfflineSettings.enabled && OfflineCache.isCacheable(fn)
        let cacheName = useCache ? offlineName(fn, params) : ""
        let saved: Data? = useCache ? OfflineCache.load(cacheName) : nil

        // 1) first paint: saved copy only, no network
        if OfflineCache.cacheOnly && useCache {
            if let saved { return saved }
            throw CancellationError()   // nothing saved yet: screens already ignore cancellation
        }
        // 2) no connection at all: don't wait for a timeout
        if let saved, !OfflineNet.shared.online {
            await OfflineMonitor.shared.markCache()
            return saved
        }

        var items: [(String, String)] = [("wstoken", token), ("wsfunction", fn), ("moodlewsrestformat", "json")]
        flatten(params, prefix: nil, into: &items)
        var req = URLRequest(url: Site.url.appendingPathComponent("webservice/rest/server.php"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = items.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&").data(using: .utf8)

        let data: Data
        do {
            let (d, resp) = try await fetch(req, limit: saved == nil ? nil : OfflineCache.slowLimit)
            if let saved, let h = resp as? HTTPURLResponse, h.statusCode >= 500 {
                await OfflineMonitor.shared.markCache()
                return saved
            }
            data = d
        } catch let e as URLError where saved != nil && MoodleAPI.offlineCodes.contains(e.code) {
            await OfflineMonitor.shared.markCache()
            return saved!
        }
        await OfflineMonitor.shared.markOnline()

        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return data }
        if let o = obj as? [String: Any], o["exception"] != nil || o["errorcode"] != nil {
            throw APIError(message: (o["message"] as? String) ?? "Request failed",
                           code: o["errorcode"] as? String)
        }
        if obj is [String: Any] || obj is [Any],
           let out = try? JSONSerialization.data(withJSONObject: decodeEntities(obj)) {
            if useCache { OfflineCache.save(cacheName, out) }
            return out
        }
        return data
    }

    func call<T: Decodable>(_ fn: String, _ params: [String: Any] = [:]) async throws -> T {
        let data = try await raw(fn, params)
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
    // (Logs the reason for any failure to DebugLog, which is defined in Submission.swift.)
    func autologin(_ target: URL, userid: Int, force: Bool = false) async -> URL {
        guard let pt = privateToken else {
            await DebugLog.shared.add("autologin: no private token stored")
            return target
        }
        if !force && autologinWait > 0 {
            await DebugLog.shared.add("autologin: skipped, cooldown \(Int(autologinWait))s left")
            return target
        }
        do {
            let r: AutoKey = try await call("tool_mobile_get_autologin_key", ["privatetoken": pt])
            lastAutologin = Date()
            guard var c = URLComponents(string: r.autologinurl) else {
                await DebugLog.shared.add("autologin: bad autologinurl")
                return target
            }
            c.queryItems = [URLQueryItem(name: "userid", value: String(userid)),
                            URLQueryItem(name: "key", value: r.key),
                            URLQueryItem(name: "urltogo", value: target.absoluteString)]
            return c.url ?? target
        } catch {
            // If Moodle says we're being rate-limited, remember that so we stop hammering it.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("cooldown") || msg.contains("minute") || msg.contains("wait") || msg.contains("too many") {
                lastAutologin = Date()
            }
            await DebugLog.shared.add("autologin: key request failed: \(error.localizedDescription)")
            return target
        }
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
    let mimetype: String?
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
    let component: String?
    let eventtype: String?
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
struct AssignCfg: Decodable { let subtype: String?; let plugin: String?; let name: String?; let value: String? }
struct Assign: Decodable, Identifiable {
    let id: Int
    let cmid: Int
    let name: String
    let duedate: Int?
    let intro: String?
    let submissiondrafts: Int?
    let configs: [AssignCfg]?
    func cfg(_ plugin: String, _ name: String) -> String? {
        configs?.first { $0.subtype == "assignsubmission" && $0.plugin == plugin && $0.name == name }?.value
    }
    func enabled(_ plugin: String) -> Bool { cfg(plugin, "enabled") == "1" }
}

struct FlexBool: Decodable {
    let value: Bool
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i != 0 }
        else { value = false }
    }
}

struct StatusResp: Decodable { let lastattempt: LastAttempt?; let feedback: Feedback? }
struct LastAttempt: Decodable {
    let submission: Sub?
    let gradingstatus: String?
    let canedit: FlexBool?
    let cansubmit: FlexBool?
    let locked: FlexBool?
}
struct Sub: Decodable { let status: String?; let plugins: [SubPlugin]? }
struct SubPlugin: Decodable { let type: String?; let fileareas: [FileArea]?; let editorfields: [EditorField]? }
struct FileArea: Decodable { let area: String?; let files: [FileRef]? }
struct FileRef: Decodable, Identifiable {
    var id: String { (fileurl ?? "") + (filename ?? "") }
    let filename: String?
    let fileurl: String?
}
struct EditorField: Decodable { let name: String?; let text: String? }
struct Feedback: Decodable { let gradefordisplay: String? }

// Attendance
struct Ignored: Decodable { init(from decoder: Decoder) throws {} }
struct AttCourse: Decodable { let attendance_instances: [AttInstance]? }
struct AttInstance: Decodable { let today_sessions: [AttToday]? }
struct AttToday: Decodable, Identifiable { let id: Int; let attendanceid: Int? }
struct AttSession: Decodable, Identifiable {
    let id: Int
    let attendanceid: Int?
    let sessdate: Int?
    let duration: Int?
    let description: String?
    let studentscanmark: FlexBool?
    let studentpassword: String?
    let statuses: [AttStatus]?
    let attendance_log: [AttLog]?
}
struct AttStatus: Decodable, Identifiable { let id: Int; let acronym: String?; let description: String? }
struct AttLog: Decodable { let studentid: Int?; let statusid: Int? }

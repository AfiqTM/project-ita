import SwiftUI
import UIKit
import Security
import CryptoKit
import AuthenticationServices

// MARK: - Microsoft login (plain OAuth 2.0 + PKCE in a system sheet, no SDK / package needed)
//
// SETUP: register an app in the Microsoft Entra admin centre (see README > Microsoft Teams) and paste
// its "Application (client) ID" below. Redirect URI to add (platform: Mobile & desktop):
//     msauth.com.afiq.italeem://auth

enum MicrosoftConfig {
    static let clientID = "3a22327e-e4bc-463a-a458-2b581b21cae5"

    static var configured: Bool { !clientID.hasPrefix("PASTE") }
    /// School / work accounts. Use "common" instead if you also want personal Microsoft accounts.
    static let authority = "https://login.microsoftonline.com/organizations/oauth2/v2.0"
    static let scheme = "msauth.com.afiq.italeem"
    static var redirect: String { scheme + "://auth" }

    /// Classes (teams), channels and files. None of these need an administrator's approval.
    static let coreScope = "openid profile email offline_access User.Read Team.ReadBasic.All Channel.ReadBasic.All Files.Read.All"
    static let coreRefreshScope = "offline_access User.Read Team.ReadBasic.All Channel.ReadBasic.All Files.Read.All"
    /// Assignments ("work"). Asked for separately, the first time Work is opened, because some schools
    /// only let an administrator approve it. The rest of Teams keeps working without it.
    static let workScope = "https://graph.microsoft.com/EduAssignments.ReadBasic"
}

enum TeamsError: LocalizedError {
    case notSignedIn, needsWorkAccess, unsupported, http(Int, String?), message(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You're not signed in to Microsoft."
        case .needsWorkAccess: return "Microsoft needs your permission to show class work."
        case .unsupported: return "This type of file can't be previewed here."
        case .http(let code, let msg):
            if let msg, !msg.isEmpty { return msg }
            if code == 403 { return "Microsoft Teams denied access (403). Your school may not allow this." }
            return "Microsoft Teams returned an error (\(code))."
        case .message(let m): return m
        }
    }
}

struct MicrosoftTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var name: String?
    var email: String?
    var workToken: String?
    var workExpiry: Date?
}

/// Tokens live in the keychain, so the login survives restarts.
enum MicrosoftKeychain {
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "italeem-microsoft",
         kSecAttrAccount as String: "tokens"]
    }
    static func save(_ t: MicrosoftTokens) {
        guard let d = try? JSONEncoder().encode(t) else { return }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> MicrosoftTokens? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(MicrosoftTokens.self, from: d)
    }
    static func delete() { SecItemDelete(query() as CFDictionary) }
}

final class MicrosoftWebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { cb, err in
                if let cb { cont.resume(returning: cb) }
                else { cont.resume(throwing: err ?? TeamsError.message("Microsoft sign-in was cancelled.")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false      // reuses the browser's Microsoft session
            self.session = s
            if !s.start() { cont.resume(throwing: TeamsError.message("Couldn't open the Microsoft sign-in screen.")) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

@MainActor
final class TeamsAuth: ObservableObject {
    @Published private(set) var tokens: MicrosoftTokens?
    @Published private(set) var busy = false
    @Published var error: String?

    private let web = MicrosoftWebAuth()

    var isSignedIn: Bool { tokens != nil }
    var email: String? { tokens?.email ?? tokens?.name }
    var hasWorkAccess: Bool { tokens?.workToken != nil }

    init() { tokens = MicrosoftKeychain.load() }

    // ---- sign in / out ----

    func signIn() {
        guard MicrosoftConfig.configured else {
            error = "Paste your Microsoft client ID into MicrosoftConfig.clientID (Teams.swift) first."
            return
        }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await performSignIn() }
            catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin { /* user closed it */ }
            catch { self.error = error.localizedDescription }
        }
    }

    func signOut() {
        MicrosoftKeychain.delete()
        tokens = nil
    }

    /// Asks for the separate "assignments" permission. Returns true when it was granted.
    func enableWork() async -> Bool {
        guard let t = tokens else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            let r = try await authorize(scope: "offline_access " + MicrosoftConfig.workScope,
                                        prompt: nil, hint: t.email)
            guard let at = r.access_token else {
                throw TeamsError.message(Self.clean(r.error_description) ?? r.error ?? "Microsoft didn't grant access.")
            }
            update {
                $0.workToken = at
                $0.workExpiry = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
                if let rt = r.refresh_token { $0.refreshToken = rt }
            }
            return true
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func performSignIn() async throws {
        let r = try await authorize(scope: MicrosoftConfig.coreScope, prompt: "select_account", hint: nil)
        guard let at = r.access_token, let rt = r.refresh_token else {
            throw TeamsError.message(Self.clean(r.error_description) ?? r.error ?? "Microsoft didn't return a login.")
        }
        let claims = Self.claims(fromIDToken: r.id_token)
        let t = MicrosoftTokens(
            accessToken: at, refreshToken: rt,
            expiry: Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600)),
            name: claims["name"] as? String,
            email: (claims["preferred_username"] as? String) ?? (claims["email"] as? String))
        MicrosoftKeychain.save(t)
        tokens = t
    }

    // ---- tokens ----

    /// A valid access token for classes / channels / files (renewed automatically)
    func accessToken() async throws -> String {
        guard let t = tokens else { throw TeamsError.notSignedIn }
        if t.expiry > Date().addingTimeInterval(60) { return t.accessToken }
        let r = try await Self.tokenRequest([
            "client_id": MicrosoftConfig.clientID,
            "refresh_token": t.refreshToken,
            "grant_type": "refresh_token",
            "scope": MicrosoftConfig.coreRefreshScope])
        guard let at = r.access_token else {
            if r.error == "invalid_grant" || r.error == "interaction_required" {
                signOut()
                throw TeamsError.message("Your Microsoft login expired. Please sign in again.")
            }
            throw TeamsError.message(Self.clean(r.error_description) ?? r.error ?? "Couldn't refresh the Microsoft login.")
        }
        update {
            $0.accessToken = at
            $0.expiry = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
            if let rt = r.refresh_token { $0.refreshToken = rt }
        }
        return at
    }

    /// A valid access token for assignments. Throws `.needsWorkAccess` until the user has allowed it.
    func workToken() async throws -> String {
        guard let t = tokens else { throw TeamsError.notSignedIn }
        guard t.workToken != nil else { throw TeamsError.needsWorkAccess }
        if let w = t.workToken, let e = t.workExpiry, e > Date().addingTimeInterval(60) { return w }
        let r = try await Self.tokenRequest([
            "client_id": MicrosoftConfig.clientID,
            "refresh_token": t.refreshToken,
            "grant_type": "refresh_token",
            "scope": "offline_access " + MicrosoftConfig.workScope])
        guard let at = r.access_token else {
            update { $0.workToken = nil; $0.workExpiry = nil }
            throw TeamsError.needsWorkAccess
        }
        update {
            $0.workToken = at
            $0.workExpiry = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
            if let rt = r.refresh_token { $0.refreshToken = rt }
        }
        return at
    }

    /// Applies a change to the *current* tokens (two refreshes can overlap) and saves it.
    private func update(_ change: (inout MicrosoftTokens) -> Void) {
        guard var t = tokens else { return }
        change(&t)
        MicrosoftKeychain.save(t)
        tokens = t
    }

    // ---- OAuth helpers ----

    private func authorize(scope: String, prompt: String?, hint: String?) async throws -> TokenResponse {
        let verifier = Self.randomString()
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString

        var c = URLComponents(string: MicrosoftConfig.authority + "/authorize")!
        var q = [
            URLQueryItem(name: "client_id", value: MicrosoftConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: MicrosoftConfig.redirect),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)]
        if let prompt { q.append(URLQueryItem(name: "prompt", value: prompt)) }
        if let hint { q.append(URLQueryItem(name: "login_hint", value: hint)) }
        c.queryItems = q

        let cb = try await web.start(url: c.url!, scheme: MicrosoftConfig.scheme)
        let items = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let e = val("error") {
            throw TeamsError.message(Self.clean(val("error_description")) ?? "Microsoft sign-in failed (\(e)).")
        }
        guard val("state") == state, let code = val("code") else {
            throw TeamsError.message("Microsoft sign-in failed. Please try again.")
        }
        return try await Self.tokenRequest([
            "client_id": MicrosoftConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": MicrosoftConfig.redirect,
            "grant_type": "authorization_code",
            "scope": scope])
    }

    struct TokenResponse: Decodable {
        let access_token: String?; let expires_in: Int?; let refresh_token: String?
        let id_token: String?; let error: String?; let error_description: String?
    }

    private static func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var req = URLRequest(url: URL(string: MicrosoftConfig.authority + "/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\(e($0.key))=\(e($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Microsoft's messages end with trace / correlation ids; keep only the first line.
    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let first = s.components(separatedBy: CharacterSet.newlines).first ?? s
        return first.trimmingCharacters(in: .whitespaces).isEmpty ? nil : first
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func claims(fromIDToken t: String?) -> [String: Any] {
        guard let part = t?.split(separator: ".").dropFirst().first else { return [:] }
        var b = String(part).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
}

// MARK: - Microsoft Graph models + REST client

/// A class (team) the user belongs to
struct TeamRef: Codable, Identifiable, Hashable {
    let id: String
    var displayName: String
    var webUrl: String?

    /// Only teams with "Section" in the name are used (every subject has two; this is the real class).
    var isSection: Bool { displayName.range(of: "section", options: .caseInsensitive) != nil }
    /// "LEED 1301 SECTION 03 ENGLISH FOR WRITING" -> "ENGLISH FOR WRITING" (same rule as the course pages)
    var title: String { Course.cleanSubject(displayName) }
}

struct GraphTeam: Decodable {
    let id: String
    let displayName: String?
    let isArchived: Bool?
    let webUrl: String?
    var ref: TeamRef { TeamRef(id: id, displayName: displayName ?? "Class", webUrl: webUrl) }
}

struct GraphChannel: Decodable, Identifiable { let id: String; let displayName: String? }
struct GraphDriveInfo: Decodable { let id: String }

struct GraphPage<T: Decodable>: Decodable {
    let value: [T]
    let nextLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}

enum GraphDate {
    private static let plain = ISO8601DateFormatter()
    /// Graph sends dates like 2026-10-14T16:00:00.0000000Z
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let t = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        return plain.date(from: t)
    }
}

/// A file or folder inside Teams (SharePoint)
struct GraphItem: Decodable, Identifiable {
    struct Folder: Decodable { let childCount: Int? }
    struct FileInfo: Decodable { let mimeType: String? }
    struct Parent: Decodable { let driveId: String? }
    struct Remote: Decodable { let id: String?; let parentReference: Parent?; let folder: Folder? }

    let id: String
    let name: String
    let size: Int64?
    let lastModifiedDateTime: String?
    let folder: Folder?
    let file: FileInfo?
    let webUrl: String?
    let parentReference: Parent?
    let remoteItem: Remote?
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, lastModifiedDateTime, folder, file, webUrl, parentReference, remoteItem
        case downloadUrl = "@microsoft.graph.downloadUrl"
    }

    var isFolder: Bool { (remoteItem?.folder ?? folder) != nil }

    var ref: TeamItemRef? {
        guard let driveId = remoteItem?.parentReference?.driveId ?? parentReference?.driveId else { return nil }
        return TeamItemRef(driveId: driveId, itemId: remoteItem?.id ?? id, name: name,
                           isFolder: isFolder, webUrl: webUrl)
    }

    var subtitle: String {
        var parts: [String] = []
        if let d = GraphDate.parse(lastModifiedDateTime) { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        if let c = folder?.childCount { parts.append("\(c) item\(c == 1 ? "" : "s")") }
        else if let s = size, !isFolder { parts.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

struct TeamItemRef: Hashable {
    let driveId: String
    let itemId: String
    let name: String
    let isFolder: Bool
    let webUrl: String?
}

/// An assignment in a Teams class ("Work")
struct EduAssignment: Decodable, Identifiable {
    struct Instructions: Decodable { let content: String?; let contentType: String? }
    struct Grading: Decodable { let maxPoints: Double? }

    let id: String
    let displayName: String?
    let dueDateTime: String?
    let status: String?
    let instructions: Instructions?
    let webUrl: String?
    let grading: Grading?

    var due: Date? { GraphDate.parse(dueDateTime) }

    var instructionText: String {
        let raw = instructions?.content ?? ""
        return (instructions?.contentType?.lowercased() == "html" ? raw.plainText : raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum GraphAPI {
    private static let base = "https://graph.microsoft.com/v1.0"

    static func url(_ path: String, _ params: [(String, String)] = []) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~$")
        func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let qs = params.map { "\(e($0.0))=\(e($0.1))" }.joined(separator: "&")
        return URL(string: base + path + (qs.isEmpty ? "" : "?" + qs))!
    }

    private static func check(_ resp: URLResponse, _ data: Data?) throws {
        guard let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) else { return }
        var msg: String?
        if let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let e = o["error"] as? [String: Any] { msg = e["message"] as? String }
        throw TeamsError.http(h.statusCode, msg)
    }

    static func get<T: Decodable>(_ path: String, _ params: [(String, String)] = [], token: String) async throws -> T {
        try await fetch(url(path, params), token: token)
    }

    static func fetch<T: Decodable>(_ u: URL, token: String) async throws -> T {
        var req = URLRequest(url: u)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Downloads the file to a temp folder for QuickLook.
    static func download(_ ref: TeamItemRef, token: String) async throws -> URL {
        if ref.isFolder { throw TeamsError.unsupported }
        let meta: GraphItem = try await get("/drives/\(ref.driveId)/items/\(ref.itemId)", token: token)
        var req: URLRequest
        if let s = meta.downloadUrl, let u = URL(string: s) {
            req = URLRequest(url: u)                       // pre-signed link, no token needed
        } else {
            req = URLRequest(url: url("/drives/\(ref.driveId)/items/\(ref.itemId)/content"))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw TeamsError.http(h.statusCode, nil)
        }
        let name = ref.name.replacingOccurrences(of: "/", with: "_")
        let fm = FileManager.default
        let safeId = ref.itemId.replacingOccurrences(of: "/", with: "_")
        let dir = fm.temporaryDirectory.appendingPathComponent("teams-preview/\(safeId)", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }
}

// MARK: - Saved data: which class is linked to which course (kept on the phone)

@MainActor
final class TeamsLibrary: ObservableObject {
    @Published private(set) var links: [String: TeamRef] = [:]     // courseId -> class
    private let key = "teams.links.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([String: TeamRef].self, from: d) { links = v }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(links) { UserDefaults.standard.set(d, forKey: key) }
    }

    func team(for courseId: Int) -> TeamRef? { links[String(courseId)] }
    func courseId(for team: TeamRef) -> Int? {
        links.first { $0.value.id == team.id }.flatMap { Int($0.key) }
    }

    /// One class belongs to one course (and the other way round), so linking moves it.
    func link(_ team: TeamRef, to courseId: Int) {
        var l = links.filter { $0.value.id != team.id }
        l[String(courseId)] = team
        links = l
        save()
    }
    func unlink(courseId: Int) {
        links[String(courseId)] = nil
        save()
    }
}

// MARK: - The user's classes

@MainActor
final class TeamsCatalog: ObservableObject {
    @Published private(set) var teams: [TeamRef] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published var error: String?

    func loadIfNeeded(auth: TeamsAuth) async { if !loaded { await reload(auth: auth) } }
    func clear() { teams = []; loaded = false; error = nil }

    func reload(auth: TeamsAuth) async {
        guard !loading, auth.isSignedIn else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let token = try await auth.accessToken()
            var all: [GraphTeam] = []
            var page: GraphPage<GraphTeam> = try await GraphAPI.get("/me/joinedTeams", token: token)
            all += page.value
            var n = 0
            while let nl = page.nextLink, let u = URL(string: nl), n < 10 {
                page = try await GraphAPI.fetch(u, token: token)
                all += page.value
                n += 1
            }
            // Only the ones with "Section" in the name, shown without the code / section number
            var seen = Set<String>()
            teams = all.filter { $0.isArchived != true }
                .map { $0.ref }
                .filter { $0.isSection && seen.insert($0.id).inserted }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            loaded = true
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Folder loading

@MainActor
final class TeamFolderModel: ObservableObject {
    @Published var items: [GraphItem] = []
    @Published var loading = false
    @Published var loadedOnce = false
    @Published var error: String?
    private var next: URL?
    private var rootRef: TeamItemRef?
    private var gen = 0
    var hasMore: Bool { next != nil }

    private func sort(_ a: [GraphItem]) -> [GraphItem] {
        a.sorted { x, y in
            if x.isFolder != y.isFolder { return x.isFolder }
            return x.name.localizedCaseInsensitiveCompare(y.name) == .orderedAscending
        }
    }

    private func fail(_ e: Error) {
        loading = false
        if e is CancellationError || (e as? URLError)?.code == .cancelled { return }
        error = e.localizedDescription
    }

    func loadChildren(_ ref: TeamItemRef, auth: TeamsAuth, more: Bool = false) async {
        if more { guard next != nil, !loading else { return } } else { next = nil; gen += 1 }
        let my = gen
        loading = true; error = nil
        do {
            let token = try await auth.accessToken()
            let page: GraphPage<GraphItem>
            if more, let n = next {
                page = try await GraphAPI.fetch(n, token: token)
            } else {
                page = try await GraphAPI.get("/drives/\(ref.driveId)/items/\(ref.itemId)/children",
                                              [("$top", "200")], token: token)
            }
            guard my == gen else { return }
            items = sort(more ? items + page.value : page.value)
            next = page.nextLink.flatMap { URL(string: $0) }
            loadedOnce = true
        } catch {
            guard my == gen else { return }
            fail(error)
        }
        if my == gen { loading = false }
    }

    /// The class's file library (General, Class Materials, ...). If Microsoft won't show the whole
    /// library, falls back to one folder per channel.
    func loadRoot(team: TeamRef, auth: TeamsAuth, more: Bool = false) async {
        if more {
            if let r = rootRef { await loadChildren(r, auth: auth, more: true) }
            return
        }
        gen += 1
        let my = gen
        next = nil; loading = true; error = nil
        var primary: Error?
        do {
            let token = try await auth.accessToken()
            let drive: GraphDriveInfo = try await GraphAPI.get("/groups/\(team.id)/drive", [("$select", "id")], token: token)
            let root: GraphItem = try await GraphAPI.get("/drives/\(drive.id)/root", [("$select", "id")], token: token)
            let ref = TeamItemRef(driveId: drive.id, itemId: root.id, name: team.title, isFolder: true, webUrl: nil)
            rootRef = ref
            loading = false
            await loadChildren(ref, auth: auth)
            return
        } catch let e as TeamsError {
            if case .http = e { primary = e } else { fail(e); return }
        } catch {
            fail(error); return
        }

        do {
            let token = try await auth.accessToken()
            let chans: GraphPage<GraphChannel> = try await GraphAPI.get("/teams/\(team.id)/channels", token: token)
            let teamId = team.id
            let folders = await withTaskGroup(of: GraphItem?.self) { group -> [GraphItem] in
                for c in chans.value {
                    let cid = c.id
                    group.addTask { () -> GraphItem? in
                        let f: GraphItem? = try? await GraphAPI.get("/teams/\(teamId)/channels/\(cid)/filesFolder", token: token)
                        return f
                    }
                }
                var out: [GraphItem] = []
                for await f in group { if let f { out.append(f) } }
                return out
            }
            guard my == gen else { return }
            rootRef = nil; next = nil
            items = sort(folders)
            loadedOnce = true
            if folders.isEmpty, let primary { fail(primary); return }
        } catch {
            guard my == gen else { return }
            fail(primary ?? error)
            return
        }
        if my == gen { loading = false }
    }
}

// MARK: - Teams logo (drawn in the app's colours)

struct TeamsGlyph: View {
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Theme.accent)
            Text("T")
                .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
                .foregroundColor(.black)
                .offset(x: -size * 0.1, y: size * 0.05)
            Circle().fill(Color.black)
                .frame(width: size * 0.2, height: size * 0.2)
                .offset(x: size * 0.26, y: -size * 0.22)
            Capsule().fill(Color.black)
                .frame(width: size * 0.3, height: size * 0.16)
                .offset(x: size * 0.26, y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sign-in gate

struct TeamsGate<Content: View>: View {
    @EnvironmentObject var auth: TeamsAuth
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        if auth.isSignedIn { content() } else { TeamsConnectCard() }
    }
}

struct TeamsConnectCard: View {
    @EnvironmentObject var auth: TeamsAuth

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TeamsGlyph(size: 52)
                Text("Connect Microsoft Teams").font(.title3.weight(.semibold)).foregroundColor(Theme.txt)
                Text("Sign in with your university Microsoft account to browse your classes, work and files here. Access is read-only and you stay signed in.")
                    .font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)

                Button { auth.signIn() } label: {
                    HStack(spacing: 8) {
                        if auth.busy { ProgressView().tint(.black) } else { Image(systemName: "person.badge.key") }
                        Text("Sign in with Microsoft")
                    }
                    .fontWeight(.semibold).foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(auth.busy)

                if let e = auth.error { Text(e).font(.footnote).foregroundColor(Color.red.opacity(0.85)) }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .glowCard()
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

// MARK: - Others > Microsoft Teams (the list of classes)

struct TeamsHomeView: View {
    @EnvironmentObject var auth: TeamsAuth
    @EnvironmentObject var catalog: TeamsCatalog
    @EnvironmentObject var courses: CourseCatalog
    @State private var linking: TeamRef?

    var body: some View {
        TeamsGate {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let e = catalog.error { Text(e).font(.footnote).foregroundColor(Theme.muted) }
                    if !catalog.teams.isEmpty {
                        Text("Link a class to a course and a Teams icon appears at the top right of that course.")
                            .font(.footnote).foregroundColor(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(catalog.teams) { t in TeamRow(team: t, linking: $linking) }
                        }
                        .glowCard()
                    } else if catalog.loading {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                    } else if catalog.loaded && catalog.error == nil {
                        Text("No classes found. Only teams with \u{201C}Section\u{201D} in their name are shown.")
                            .foregroundColor(Theme.muted)
                    }
                }
                .padding(16)
            }
            .refreshable { await catalog.reload(auth: auth) }
            .task {
                await catalog.loadIfNeeded(auth: auth)
                await courses.loadIfNeeded()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Microsoft Teams")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if auth.isSignedIn {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Text(auth.email ?? "Microsoft account")
                        Button(role: .destructive) {
                            auth.signOut(); catalog.clear()
                        } label: { Label("Sign out of Teams", systemImage: "rectangle.portrait.and.arrow.right") }
                    } label: { Image(systemName: "person.crop.circle") }
                }
            }
        }
        .sheet(item: $linking) { LinkCourseSheet(team: $0) }
    }
}

struct TeamRow: View {
    let team: TeamRef
    @Binding var linking: TeamRef?
    @EnvironmentObject var lib: TeamsLibrary
    @EnvironmentObject var courses: CourseCatalog

    private var subtitle: String {
        guard let id = lib.courseId(for: team) else { return "Not linked to a course" }
        if let c = courses.courses.first(where: { $0.id == id }) { return "Linked to \(c.subjectName)" }
        return "Linked to a course"
    }

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink { TeamDetailView(team: team) } label: {
                HStack(spacing: 12) {
                    TeamsGlyph(size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.title).foregroundColor(Theme.txt).lineLimit(2).multilineTextAlignment(.leading)
                        Text(subtitle).font(.caption).foregroundColor(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu { actions } label: {
                Image(systemName: "ellipsis").foregroundColor(Theme.muted)
                    .frame(width: 38, height: 38).contentShape(Rectangle())
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 2)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button { linking = team } label: {
            Label(lib.courseId(for: team) == nil ? "Link to course…" : "Change course…", systemImage: "link")
        }
        if let cid = lib.courseId(for: team) {
            Button(role: .destructive) { lib.unlink(courseId: cid) } label: {
                Label("Unlink from course", systemImage: "minus.circle")
            }
        }
    }
}

// MARK: - Link a class to a course

/// From Others > Microsoft Teams: pick the course this class belongs to
struct LinkCourseSheet: View {
    let team: TeamRef
    @EnvironmentObject var lib: TeamsLibrary
    @EnvironmentObject var catalog: CourseCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose the course that \u{201C}\(team.title)\u{201D} belongs to. A Teams icon will show at the top right of that course.")
                        .font(.footnote).foregroundColor(Theme.muted)
                    if catalog.courses.isEmpty {
                        Text(catalog.loaded ? "No subjects found." : "Loading subjects…")
                            .foregroundColor(Theme.muted).padding(.top, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(catalog.courses) { c in
                                let current = lib.team(for: c.id)
                                let on = current?.id == team.id
                                Button {
                                    if on { lib.unlink(courseId: c.id) } else { lib.link(team, to: c.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(on ? Theme.accent : Theme.muted)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.subjectName).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                                            if let current, !on {
                                                Text("Now linked to \(current.title)")
                                                    .font(.caption).foregroundColor(Theme.muted)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(14).contentShape(Rectangle())
                                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .glowCard()
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Link to course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await catalog.loadIfNeeded() }
    }
}

/// From a course page: pick which class that course should show
struct PickTeamSheet: View {
    let course: Course
    @EnvironmentObject var auth: TeamsAuth
    @EnvironmentObject var lib: TeamsLibrary
    @EnvironmentObject var catalog: TeamsCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TeamsGate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose the Teams class for \u{201C}\(course.subjectName)\u{201D}.")
                            .font(.footnote).foregroundColor(Theme.muted)
                        if let e = catalog.error { Text(e).font(.footnote).foregroundColor(Theme.muted) }
                        if catalog.teams.isEmpty {
                            if catalog.loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                            else if catalog.loaded { Text("No classes found.").foregroundColor(Theme.muted) }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(catalog.teams) { t in
                                    let on = lib.team(for: course.id)?.id == t.id
                                    Button {
                                        lib.link(t, to: course.id)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(on ? Theme.accent : Theme.muted)
                                            Text(t.title).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                                            Spacer()
                                        }
                                        .padding(14).contentShape(Rectangle())
                                        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .glowCard()
                        }
                    }
                    .padding(16)
                }
                .task { await catalog.loadIfNeeded(auth: auth) }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Change class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - A class: Work / Files

enum TeamTab: String, CaseIterable, Identifiable {
    case work = "Work", files = "Files"
    var id: String { rawValue }
}

struct TeamDetailView: View {
    let team: TeamRef
    @State private var tab: TeamTab = .work

    var body: some View {
        TeamsGate {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(TeamTab.allCases) { t in
                            Button { tab = t } label: {
                                Text(t.rawValue)
                                    .fontWeight(tab == t ? .semibold : .regular)
                                    .foregroundColor(tab == t ? Theme.accent : Color(white: 0.66))
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                switch tab {
                case .work: TeamWorkTab(team: team)
                case .files: TeamFilesTab(team: team)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(team.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let s = team.webUrl, let u = URL(string: s) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Link(destination: u) { Image(systemName: "arrow.up.right.square") }
                }
            }
        }
    }
}

// MARK: Work

struct TeamWorkTab: View {
    let team: TeamRef
    @EnvironmentObject var auth: TeamsAuth
    @State private var items: [EduAssignment] = []
    @State private var loading = true
    @State private var loadedOnce = false
    @State private var needsAccess = false
    @State private var error: String?

    // coming up first (soonest first), then no due date, then the ones already past
    private var sorted: [EduAssignment] {
        let now = Date()
        let upcoming = items.filter { ($0.due ?? .distantFuture) >= now }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let past = items.filter { ($0.due ?? .distantFuture) < now }
            .sorted { ($0.due ?? .distantPast) > ($1.due ?? .distantPast) }
        return upcoming + past
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if needsAccess {
                    accessCard
                } else {
                    if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                    if !sorted.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(sorted) { a in
                                NavigationLink { TeamAssignmentView(assignment: a) } label: { row(a) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .glowCard()
                    } else if loading {
                        ProgressView().tint(Theme.accent)
                    } else if loadedOnce && error == nil {
                        Text("No work has been assigned yet.").foregroundColor(Theme.muted)
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ a: EduAssignment) -> some View {
        let past = (a.due ?? .distantFuture) < Date()
        return HStack(spacing: 12) {
            Image(systemName: "square.and.pencil").foregroundColor(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.displayName ?? "Assignment").foregroundColor(Theme.txt)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(a.due.map { "Due " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "No due date")
                    .font(.caption).foregroundColor(past ? Theme.muted : Theme.accent)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.muted)
        }
        .padding(14)
        .contentShape(Rectangle())
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    private var accessCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist").font(.system(size: 38)).foregroundColor(Theme.accent)
            Text("Allow access to class work").font(.headline).foregroundColor(Theme.txt)
            Text("Microsoft asks for a separate permission to read assignments. Allow it once and it's remembered.")
                .font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)
            Button {
                Task { if await auth.enableWork() { await load() } }
            } label: {
                HStack(spacing: 8) {
                    if auth.busy { ProgressView().tint(.black) }
                    Text("Allow")
                }
                .fontWeight(.semibold).foregroundColor(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(auth.busy)
            if let e = auth.error { Text(e).font(.footnote).foregroundColor(Color.red.opacity(0.85)) }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glowCard()
    }

    private func load() async {
        loading = true; error = nil; needsAccess = false
        do {
            let token = try await auth.workToken()
            var all: [EduAssignment] = []
            var page: GraphPage<EduAssignment> = try await GraphAPI.get(
                "/education/classes/\(team.id)/assignments", [("$top", "100")], token: token)
            all += page.value
            var n = 0
            while let nl = page.nextLink, let u = URL(string: nl), n < 10 {
                page = try await GraphAPI.fetch(u, token: token)
                all += page.value
                n += 1
            }
            items = all
        } catch TeamsError.needsWorkAccess {
            needsAccess = true
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        loading = false
        loadedOnce = true
    }
}

struct TeamAssignmentView: View {
    let assignment: EduAssignment

    private func clean(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(assignment.displayName ?? "Assignment")
                        .font(.title3.weight(.semibold)).foregroundColor(Theme.txt)
                    HStack {
                        Text("Due").foregroundColor(Theme.muted)
                        Spacer()
                        Text(assignment.due?.formatted(date: .abbreviated, time: .shortened) ?? "No due date")
                            .foregroundColor(Theme.accent).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    if let p = assignment.grading?.maxPoints {
                        HStack {
                            Text("Points").foregroundColor(Theme.muted)
                            Spacer()
                            Text(clean(p)).foregroundColor(Theme.txt)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()

                if !assignment.instructionText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Instructions").font(.caption.weight(.semibold)).foregroundColor(Theme.muted)
                        Text(assignment.instructionText).foregroundColor(Theme.txt)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()
                }

                if let s = assignment.webUrl, let u = URL(string: s) {
                    Link(destination: u) {
                        Label("Open in Teams to hand in", systemImage: "arrow.up.right.square")
                            .fontWeight(.semibold).foregroundColor(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Assignment")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Files

enum TeamsIcon {
    static func symbol(folder: Bool, name: String) -> String {
        if folder { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv": return "film"
        case "mp3", "m4a", "wav": return "waveform"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "play.rectangle"
        case "zip", "rar", "7z": return "doc.zipper"
        case "doc", "docx", "txt", "rtf", "md", "pages": return "doc.text"
        default: return "doc"
        }
    }
}

struct TeamFilesTab: View {
    let team: TeamRef
    @EnvironmentObject var auth: TeamsAuth
    @StateObject private var model = TeamFolderModel()

    var body: some View {
        ScrollView {
            TeamItemsList(model: model, emptyText: "No files in this class yet.") {
                Task { await model.loadRoot(team: team, auth: auth, more: true) }
            }
            .padding(16)
        }
        .refreshable { await model.loadRoot(team: team, auth: auth) }
        .task { if !model.loadedOnce { await model.loadRoot(team: team, auth: auth) } }
    }
}

struct TeamItemsList: View {
    @ObservedObject var model: TeamFolderModel
    var emptyText = "This folder is empty."
    var more: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if let e = model.error { Text(e).font(.footnote).foregroundColor(Theme.muted) }
            if !model.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.items) { it in TeamItemRow(item: it) }
                    if model.hasMore {
                        ProgressView().tint(Theme.accent).padding().frame(maxWidth: .infinity)
                            .onAppear { more() }
                    }
                }
                .glowCard()
            } else if model.loading {
                ProgressView().tint(Theme.accent)
            } else if model.loadedOnce && model.error == nil {
                Text(emptyText).foregroundColor(Theme.muted)
            }
        }
    }
}

struct TeamItemRow: View {
    let item: GraphItem

    var body: some View {
        if let ref = item.ref {
            NavigationLink { TeamItemDestination(ref: ref) } label: {
                HStack(spacing: 12) {
                    Image(systemName: TeamsIcon.symbol(folder: item.isFolder, name: item.name))
                        .foregroundColor(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).foregroundColor(Theme.txt).lineLimit(2).multilineTextAlignment(.leading)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundColor(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.muted)
                }
                .padding(.vertical, 8).padding(.horizontal, 14)
                .contentShape(Rectangle())
                .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
            }
            .buttonStyle(.plain)
        }
    }
}

struct TeamItemDestination: View {
    let ref: TeamItemRef
    var body: some View {
        if ref.isFolder { TeamFolderView(folder: ref) } else { TeamFilePreviewView(ref: ref) }
    }
}

/// Inside a folder
struct TeamFolderView: View {
    let folder: TeamItemRef
    @EnvironmentObject var auth: TeamsAuth
    @StateObject private var model = TeamFolderModel()

    var body: some View {
        TeamsGate {
            ScrollView {
                TeamItemsList(model: model) {
                    Task { await model.loadChildren(folder, auth: auth, more: true) }
                }
                .padding(16)
            }
            .refreshable { await model.loadChildren(folder, auth: auth) }
            .task { if !model.loadedOnce { await model.loadChildren(folder, auth: auth) } }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// File preview (native QuickLook: PDF, Word, PowerPoint, Excel, images, ...)
struct TeamFilePreviewView: View {
    let ref: TeamItemRef
    @EnvironmentObject var auth: TeamsAuth
    @State private var fileURL: URL?
    @State private var error: String?

    var body: some View {
        TeamsGate {
            Group {
                if let fileURL {
                    QuickLookView(url: fileURL).ignoresSafeArea(edges: .bottom)
                } else if let error {
                    VStack(spacing: 14) {
                        Text(error).font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }.foregroundColor(Theme.accent)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.accent)
                        Text("Opening…").font(.footnote).foregroundColor(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task { if fileURL == nil { await load() } }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let fileURL { ShareLink(item: fileURL) }
                if let s = ref.webUrl, let u = URL(string: s) {
                    Link(destination: u) { Image(systemName: "arrow.up.right.square") }
                }
            }
        }
    }

    private func load() async {
        error = nil
        do {
            let token = try await auth.accessToken()
            fileURL = try await GraphAPI.download(ref, token: token)
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
    }
}

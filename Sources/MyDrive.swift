import SwiftUI
import UIKit
import QuickLook
import Security
import CryptoKit
import AuthenticationServices

// MARK: - Google login (plain OAuth 2.0 + PKCE in a system sheet, no SDK / package needed)
//
// SETUP: paste the OAuth *iOS* client ID from Google Cloud Console below.
// (Bundle ID of the client must match the app's: com.afiq.italeem)

enum GoogleConfig {
    static let clientID = "305018415943-p5u9hpcf6jj5nl45q50irqail65eadug.apps.googleusercontent.com"

    static var configured: Bool { !clientID.hasPrefix("PASTE") }
    /// "123-abc.apps.googleusercontent.com" -> "com.googleusercontent.apps.123-abc"
    static var scheme: String {
        "com.googleusercontent.apps." + (clientID.components(separatedBy: ".apps.googleusercontent.com").first ?? "")
    }
    static var redirect: String { scheme + ":/oauth2redirect" }
    // Full Drive access: the app and the website share one sync file (iTaleem-sync.json) that either
    // side may have created, which the narrower drive.file / appdata scopes cannot reach.
    static let driveScope = "https://www.googleapis.com/auth/drive"
    static let scope = "openid email " + driveScope
}

enum DriveError: LocalizedError {
    case notSignedIn, unsupported, http(Int, String?), message(String)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You're not signed in to Google."
        case .unsupported: return "This type of file can't be previewed here."
        case .http(let code, let msg): return msg ?? "Google Drive returned an error (\(code))."
        case .message(let m): return m
        }
    }
}

struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var email: String?
    var scope: String?            // what Google granted (older logins only had drive.readonly)
}

/// Tokens live in the keychain, so the login survives restarts.
enum GoogleKeychain {
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "italeem-google",
         kSecAttrAccount as String: "tokens"]
    }
    static func save(_ t: GoogleTokens) {
        guard let d = try? JSONEncoder().encode(t) else { return }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> GoogleTokens? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: d)
    }
    static func delete() { SecItemDelete(query() as CFDictionary) }
}

final class GoogleWebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { cb, err in
                if let cb { cont.resume(returning: cb) }
                else { cont.resume(throwing: err ?? DriveError.message("Google sign-in was cancelled.")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false      // reuses the browser's Google session
            self.session = s
            if !s.start() { cont.resume(throwing: DriveError.message("Couldn't open the Google sign-in screen.")) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

@MainActor
final class DriveAuth: ObservableObject {
    @Published private(set) var tokens: GoogleTokens?
    @Published private(set) var restoring = false        // login is restored instantly from the keychain
    @Published private(set) var busy = false
    @Published var error: String?

    private let web = GoogleWebAuth()

    var isSignedIn: Bool { tokens != nil }
    var email: String? { tokens?.email }
    /// true when the saved login may write to Drive (needed for sync)
    var canWrite: Bool { (tokens?.scope ?? "").split(separator: " ").contains(Substring(GoogleConfig.driveScope)) }

    init() { tokens = GoogleKeychain.load() }

    // ---- sign in / out ----

    func signIn() {
        guard GoogleConfig.configured else {
            error = "Paste your Google client ID into GoogleConfig.clientID (MyDrive.swift) first."
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
        GoogleKeychain.delete()
        tokens = nil
    }

    private func performSignIn() async throws {
        let verifier = Self.randomString()
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleConfig.redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleConfig.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")]       // makes Google hand out a refresh token

        let cb = try await web.start(url: c.url!, scheme: GoogleConfig.scheme)
        let items = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let e = val("error") { throw DriveError.message("Google sign-in failed (\(e)).") }
        guard val("state") == state, let code = val("code") else {
            throw DriveError.message("Google sign-in failed. Please try again.")
        }

        let r = try await Self.tokenRequest([
            "client_id": GoogleConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": GoogleConfig.redirect,
            "grant_type": "authorization_code"])
        guard let at = r.access_token, let rt = r.refresh_token else {
            throw DriveError.message(r.error_description ?? r.error ?? "Google didn't return a login.")
        }
        guard (r.scope ?? "").split(separator: " ").contains(Substring(GoogleConfig.driveScope)) else {
            throw DriveError.message("Drive access wasn't granted. Tick the Drive permission and try again.")
        }
        let t = GoogleTokens(accessToken: at, refreshToken: rt,
                             expiry: Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600)),
                             email: Self.email(fromIDToken: r.id_token), scope: r.scope)
        GoogleKeychain.save(t)
        tokens = t
    }

    /// A valid access token (renewed automatically with the saved refresh token)
    func accessToken() async throws -> String {
        guard var t = tokens else { throw DriveError.notSignedIn }
        if t.expiry > Date().addingTimeInterval(60) { return t.accessToken }
        let r = try await Self.tokenRequest([
            "client_id": GoogleConfig.clientID,
            "refresh_token": t.refreshToken,
            "grant_type": "refresh_token"])
        guard let at = r.access_token else {
            if r.error == "invalid_grant" { signOut() }       // login was revoked / expired
            throw DriveError.message(r.error == "invalid_grant"
                ? "Your Google login expired. Please sign in again."
                : (r.error_description ?? r.error ?? "Couldn't refresh the Google login."))
        }
        t.accessToken = at
        t.expiry = Date().addingTimeInterval(TimeInterval(r.expires_in ?? 3600))
        GoogleKeychain.save(t)
        tokens = t
        return at
    }

    // ---- helpers ----

    private struct TokenResponse: Decodable {
        let access_token: String?; let expires_in: Int?; let refresh_token: String?
        let id_token: String?; let scope: String?; let error: String?; let error_description: String?
    }

    private static func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\(e($0.key))=\(e($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
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

    private static func email(fromIDToken t: String?) -> String? {
        guard let part = t?.split(separator: ".").dropFirst().first else { return nil }
        var b = String(part).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["email"] as? String
    }
}

// MARK: - Drive models + REST client

struct DriveRef: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var mimeType: String
    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
}

struct DriveItem: Decodable, Identifiable {
    struct Shortcut: Decodable { let targetId: String?; let targetMimeType: String? }
    let id: String
    let name: String
    let mimeType: String
    let modifiedTime: String?
    let size: String?
    let shortcutDetails: Shortcut?

    /// Shortcuts point at the real file / folder
    var ref: DriveRef {
        if mimeType == "application/vnd.google-apps.shortcut",
           let t = shortcutDetails?.targetId, let m = shortcutDetails?.targetMimeType {
            return DriveRef(id: t, name: name, mimeType: m)
        }
        return DriveRef(id: id, name: name, mimeType: mimeType)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    // Shared formatters: `Date.formatted` and `ByteCountFormatter.string` build a new formatter on every call,
    // which is slow when it runs for every row on every redraw.
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let sizeFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    var subtitle: String {
        var parts: [String] = []
        if let m = modifiedTime, let d = Self.isoFrac.date(from: m) ?? Self.iso.date(from: m) {
            parts.append(Self.dayFmt.string(from: d))
        }
        if let s = size, let n = Int64(s) { parts.append(Self.sizeFmt.string(fromByteCount: n)) }
        return parts.joined(separator: " · ")
    }
}

enum DriveAPI {
    private static let base = "https://www.googleapis.com/drive/v3"

    private static func url(_ path: String, _ params: [(String, String)]) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let qs = params.map { "\(e($0.0))=\(e($0.1))" }.joined(separator: "&")
        return URL(string: base + path + "?" + qs)!
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
    static func parentQuery(_ id: String) -> String { "'\(esc(id))' in parents and trashed = false" }
    static func searchQuery(_ text: String) -> String { "name contains '\(esc(text))' and trashed = false" }

    private static func check(_ resp: URLResponse, _ data: Data?) throws {
        guard let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) else { return }
        var msg: String?
        if let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let e = o["error"] as? [String: Any] { msg = e["message"] as? String }
        throw DriveError.http(h.statusCode, msg)
    }

    static func list(q: String, token: String, pageToken: String?) async throws -> (items: [DriveItem], next: String?) {
        var p: [(String, String)] = [
            ("q", q),
            ("fields", "nextPageToken,files(id,name,mimeType,modifiedTime,size,shortcutDetails(targetId,targetMimeType))"),
            ("orderBy", "folder,name"),
            ("pageSize", "100"),
            ("supportsAllDrives", "true"),
            ("includeItemsFromAllDrives", "true")]
        if let pageToken { p.append(("pageToken", pageToken)) }
        var req = URLRequest(url: url("/files", p))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        struct R: Decodable { let files: [DriveItem]; let nextPageToken: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        return (r.files, r.nextPageToken)
    }

    /// Downloads the file to a temp folder (Google Docs / Sheets / Slides are exported as PDF) for QuickLook.
    static func download(_ ref: DriveRef, token: String) async throws -> URL {
        if ref.isFolder { throw DriveError.unsupported }
        let gprefix = "application/vnd.google-apps."
        let exportable = ["document", "spreadsheet", "presentation", "drawing"].contains { ref.mimeType == gprefix + $0 }
        if ref.mimeType.hasPrefix(gprefix) && !exportable { throw DriveError.unsupported }

        let u = exportable
            ? url("/files/\(ref.id)/export", [("mimeType", "application/pdf")])
            : url("/files/\(ref.id)", [("alt", "media"), ("supportsAllDrives", "true")])
        var req = URLRequest(url: u)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        try check(resp, try? Data(contentsOf: tmp))

        var name = ref.name.replacingOccurrences(of: "/", with: "_")
        if exportable && !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("drive-preview/\(ref.id)", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }
}

// MARK: - Saved data: pins + files saved to a subject (kept on the phone)

@MainActor
final class DriveLibrary: ObservableObject {
    @Published private(set) var pins: [DriveRef] = []
    @Published private(set) var bySubject: [String: [DriveRef]] = [:]     // courseId -> saved files/folders
    private(set) var pinsUpdated = Date(timeIntervalSince1970: 1)           // last change, for syncing
    private(set) var subjectUpdated: [String: Date] = [:]
    private let pinKey = "drive.pins.v1", subjectKey = "drive.subjects.v1", stampKey = "drive.stamps.v1"

    init() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: pinKey), let v = try? JSONDecoder().decode([DriveRef].self, from: d) { pins = v }
        if let d = ud.data(forKey: subjectKey),
           let v = try? JSONDecoder().decode([String: [DriveRef]].self, from: d) { bySubject = v }
        if let s = ud.dictionary(forKey: stampKey) as? [String: Double] {
            if let p = s["pins"] { pinsUpdated = Date(timeIntervalSince1970: p) }
            for (k, v) in s where k != "pins" { subjectUpdated[k] = Date(timeIntervalSince1970: v) }
        }
    }
    private func persist() {
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(pins) { ud.set(d, forKey: pinKey) }
        if let d = try? JSONEncoder().encode(bySubject) { ud.set(d, forKey: subjectKey) }
        var s: [String: Double] = ["pins": pinsUpdated.timeIntervalSince1970]
        for (k, v) in subjectUpdated { s[k] = v.timeIntervalSince1970 }
        ud.set(s, forKey: stampKey)
    }
    private func save() {
        persist()
        NotificationCenter.default.post(name: .syncLocalChanged, object: nil)
    }
    /// Newer data from Drive (does not trigger another upload)
    func applySync(pins newPins: ([DriveRef], Date)?, subjects: [String: ([DriveRef], Date)]) {
        if let (list, at) = newPins { pins = list; pinsUpdated = at }
        for (k, v) in subjects {
            bySubject[k] = v.0.isEmpty ? nil : v.0
            subjectUpdated[k] = v.1
        }
        persist()
    }

    func isPinned(_ r: DriveRef) -> Bool { pins.contains { $0.id == r.id } }
    func togglePin(_ r: DriveRef) {
        if let i = pins.firstIndex(where: { $0.id == r.id }) { pins.remove(at: i) } else { pins.insert(r, at: 0) }
        pinsUpdated = Date()
        save()
    }

    func files(for courseId: Int) -> [DriveRef] { bySubject[String(courseId)] ?? [] }
    func isSaved(_ r: DriveRef, in courseId: Int) -> Bool { files(for: courseId).contains { $0.id == r.id } }
    func toggle(_ r: DriveRef, in courseId: Int) {
        var list = files(for: courseId)
        if let i = list.firstIndex(where: { $0.id == r.id }) { list.remove(at: i) } else { list.append(r) }
        bySubject[String(courseId)] = list.isEmpty ? nil : list
        subjectUpdated[String(courseId)] = Date()
        save()
    }
}

// MARK: - Folder loading

@MainActor
final class DriveFolderModel: ObservableObject {
    @Published var items: [DriveItem] = []
    @Published var loading = false
    @Published var loadedOnce = false
    @Published var error: String?
    private var next: String?
    private var gen = 0
    var hasMore: Bool { next != nil }

    func load(q: String, auth: DriveAuth, more: Bool = false) async {
        if more { guard next != nil, !loading else { return } } else { next = nil; gen += 1 }
        let my = gen
        loading = true; error = nil
        do {
            let token = try await auth.accessToken()
            let r = try await DriveAPI.list(q: q, token: token, pageToken: more ? next : nil)
            guard my == gen else { return }
            if more {
                // never add the same file twice (duplicate ids make a ForEach scroll and jump oddly)
                let seen = Set(items.map(\.id))
                items += r.items.filter { !seen.contains($0.id) }
            } else {
                items = r.items
            }
            next = r.next
            loadedOnce = true
        } catch {
            guard my == gen else { return }
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        if my == gen { loading = false }
    }
}

// MARK: - Sign-in gate

struct DriveGate<Content: View>: View {
    @EnvironmentObject var auth: DriveAuth
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        if auth.isSignedIn { content() }
        else if auth.restoring { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity) }
        else { DriveConnectCard() }
    }
}

struct DriveConnectCard: View {
    @EnvironmentObject var auth: DriveAuth

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "externaldrive").font(.system(size: 44)).foregroundColor(Theme.accent)
                Text("Connect Google Drive").font(Theme.font(.title3).weight(.semibold)).foregroundColor(Theme.txt)
                Text("Sign in once to browse your files here and keep your to-dos, CAMS marks and pins in sync with the website. You stay signed in.")
                    .font(Theme.font(.footnote)).foregroundColor(Theme.muted).multilineTextAlignment(.center)

                Button { auth.signIn() } label: {
                    HStack(spacing: 8) {
                        if auth.busy { ProgressView().tint(Theme.onAccent) } else { Image(systemName: "person.badge.key") }
                        Text("Sign in with Google")
                    }
                    .fontWeight(.semibold).foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(auth.busy)

                if let e = auth.error { Text(e).font(Theme.font(.footnote)).foregroundColor(Color.red.opacity(0.85)) }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .glowCard()
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

// MARK: - Rows

enum DriveIcon {
    static func symbol(_ r: DriveRef) -> String {
        let m = r.mimeType
        if r.isFolder { return "folder.fill" }
        if m.contains("pdf") { return "doc.richtext" }
        if m.hasPrefix("image/") { return "photo" }
        if m.hasPrefix("video/") { return "film" }
        if m.hasPrefix("audio/") { return "waveform" }
        if m.contains("spreadsheet") || m.contains("excel") || m.contains("csv") { return "tablecells" }
        if m.contains("presentation") || m.contains("powerpoint") { return "play.rectangle" }
        if m.contains("zip") || m.contains("compressed") { return "doc.zipper" }
        if m.contains("document") || m.contains("word") || m.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

struct DriveRow: View {
    let ref: DriveRef
    var subtitle: String? = nil
    var showLine = true                    // false for the last row of a card, so the divider doesn't cross the rounded corners
    var onRemove: (() -> Void)? = nil      // set inside a course's My Drive tab

    @EnvironmentObject var lib: DriveLibrary
    @State private var saving = false

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink { DriveDestination(ref: ref) } label: {
                HStack(spacing: 12) {
                    Image(systemName: DriveIcon.symbol(ref)).foregroundColor(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(ref.name).foregroundColor(Theme.txt).lineLimit(2).multilineTextAlignment(.leading)
                            if lib.isPinned(ref) {
                                Image(systemName: "pin.fill").font(Theme.font(.caption2)).foregroundColor(Theme.accent)
                            }
                        }
                        if let s = subtitle, !s.isEmpty { Text(s).font(Theme.font(.caption)).foregroundColor(Theme.muted) }
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
        .overlay(Rectangle().fill(Theme.line).frame(height: showLine ? 1 : 0), alignment: .bottom)
        .contextMenu { actions }
        .sheet(isPresented: $saving) { SaveToSubjectSheet(ref: ref) }
    }

    @ViewBuilder private var actions: some View {
        Button { lib.togglePin(ref) } label: {
            Label(lib.isPinned(ref) ? "Unpin" : "Pin", systemImage: lib.isPinned(ref) ? "pin.slash" : "pin")
        }
        Button { saving = true } label: { Label("Save to subject…", systemImage: "books.vertical") }
        if let onRemove {
            Button(role: .destructive, action: onRemove) {
                Label("Remove from this subject", systemImage: "minus.circle")
            }
        }
    }
}

struct DriveDestination: View {
    let ref: DriveRef
    var body: some View {
        if ref.isFolder { DriveFolderView(folder: ref) } else { DrivePreviewView(ref: ref) }
    }
}

// MARK: - Long lists (search results, folders)

/// A soft halo made of a stack of flat rounded rectangles, each a little bigger and very faint, instead of a
/// blurred `.shadow`. It looks like a glow, but it is plain vector drawing: no blur pass, no off-screen bitmap,
/// so it stays cheap behind a card that is thousands of points tall.
struct StackedGlow: View {
    /// (how far the ring reaches past the card edge in pt, opacity of that ring), outermost first.
    /// Fitted to the three blurred shadows in `GlowCard` (Theme.swift): about 60% at the very edge,
    /// ~20% 5 pt out, ~5% 15 pt out, gone at ~30 pt.
    typealias Ring = (reach: CGFloat, opacity: Double)
    static let glowRings: [Ring] = [(30, 0.011), (23, 0.015), (17, 0.033), (12, 0.054),
                                    (8, 0.091), (5, 0.111), (3, 0.153), (1.5, 0.279)]
    static let softRings: [Ring] = [(18, 0.002), (12, 0.005), (6, 0.0096), (3, 0.0203)]
    static let westernRings: [Ring] = [(18, 0.022), (12, 0.051), (6, 0.116), (3, 0.232)]

    let color: Color
    let rings: [Ring]
    var dy: CGFloat = 0        // vertical offset (drop-shadow look for the light / western themes)
    let radius: CGFloat

    var body: some View {
        ZStack {
            ForEach(rings.indices, id: \.self) { i in
                let d = rings[i].reach
                RoundedRectangle(cornerRadius: radius + d, style: .continuous)
                    .fill(color.opacity(rings[i].opacity))
                    .padding(-d)
            }
        }
        .offset(y: dy)
        .allowsHitTesting(false)
    }
}

/// Card look for long lists. `glowCard()` puts three blurred shadows on the whole card, which is far too heavy
/// around ~100 rows (iOS redraws the entire tall stack through the shadow passes, so scrolling stutters).
/// Here the surface, outline and a cheap stacked glow are drawn behind the rows instead, and the rows stay plain.
struct DriveListCard: ViewModifier {
    var radius: CGFloat = 14
    @ObservedObject private var themes = ThemeStore.shared
    func body(content: Content) -> some View {
        let p = themes.theme.palette
        let pixel = p.card == .pixel
        let western = p.card == .western
        let r = Theme.cardRadius(radius)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        // colour, rings, y offset: fitted to the shadows GlowCard uses for each card style
        let halo: (Color, [StackedGlow.Ring], CGFloat)?
        switch p.card {
        case .glow, .terminal: halo = (Color(hex: p.glow), StackedGlow.glowRings, 0)
        case .soft:            halo = (Color.black, StackedGlow.softRings, 3)
        case .western:         halo = (Color.black, StackedGlow.westernRings, 5)
        case .pixel:           halo = nil          // hard block shadow below, no blur in that theme
        }
        return content
            .background {
                ZStack {
                    if let h = halo {
                        StackedGlow(color: h.0, rings: h.1, dy: h.2, radius: r)
                    }
                    if pixel { shape.fill(Color(hex: p.glow)).offset(x: 3, y: 3) }
                    shape.fill(Color(hex: p.surface))
                        .overlay(alignment: .top) {
                            if western { TornBand().fill(Color(hex: p.accent)).frame(height: 9) }
                        }
                        .clipShape(shape)
                }
            }
            .overlay(shape.stroke(Color(hex: p.line), lineWidth: p.card == .glow ? 0 : (pixel ? 2 : 1))
                .allowsHitTesting(false))
    }
}
extension View {
    func driveListCard() -> some View { modifier(DriveListCard()) }
}

/// The rows of a folder or a search. They are direct children of one LazyVStack, so only the rows on screen
/// are built, and "load more" fires when the spinner at the bottom is really reached.
struct DriveItemList: View {
    let items: [DriveItem]
    let hasMore: Bool
    let loadMore: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                DriveRow(ref: item.ref, subtitle: item.subtitle,
                         showLine: item.id != items.last?.id || hasMore)
            }
            if hasMore {
                ProgressView().tint(Theme.accent).padding().frame(maxWidth: .infinity)
                    .onAppear { loadMore() }
            }
        }
        .driveListCard()
    }
}

// MARK: - Save to subject

struct SaveToSubjectSheet: View {
    let ref: DriveRef
    @EnvironmentObject var lib: DriveLibrary
    @EnvironmentObject var catalog: CourseCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("“\(ref.name)” will show in the My Drive tab of each subject you tick.")
                        .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                    if catalog.courses.isEmpty {
                        Text(catalog.loaded ? "No subjects found." : "Loading subjects…")
                            .foregroundColor(Theme.muted).padding(.top, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(catalog.courses) { c in
                                let on = lib.isSaved(ref, in: c.id)
                                Button { lib.toggle(ref, in: c.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(on ? Theme.accent : Theme.muted)
                                        Text(c.subjectName).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
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
            .navigationTitle("Save to subject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(ThemeStore.shared.theme.scheme)
        .task { await catalog.loadIfNeeded() }
    }
}

// MARK: - Explorer

enum DriveScope: String, CaseIterable, Identifiable {
    case mine = "My Drive", shared = "Shared with me"
    var id: String { rawValue }
    var query: String {
        switch self {
        case .mine: return "'root' in parents and trashed = false"
        case .shared: return "sharedWithMe = true and trashed = false"
        }
    }
}

/// Profile > My Drive (root of the explorer)
struct MyDriveView: View {
    @EnvironmentObject var auth: DriveAuth
    @EnvironmentObject var lib: DriveLibrary
    @StateObject private var model = DriveFolderModel()
    @State private var query = ""
    @State private var scope: DriveScope = .mine
    @FocusState private var searchFocused: Bool

    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var q: String { cleanQuery.isEmpty ? scope.query : DriveAPI.searchQuery(cleanQuery) }

    var body: some View {
        DriveGate {
            ScrollView {
                // A plain VStack: the lazy part is the row list inside `results` (DriveItemList)
                VStack(alignment: .leading, spacing: 14) {
                    searchBar
                    if cleanQuery.isEmpty {
                        scopeBar
                        pinned
                    }
                    results
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.load(q: q, auth: auth) }
            .task(id: q) {
                if !cleanQuery.isEmpty {                       // wait a moment while typing
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if Task.isCancelled { return }
                }
                await model.load(q: q, auth: auth)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("My Drive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if auth.isSignedIn {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Text(auth.email ?? "Google account")
                        Button(role: .destructive) { auth.signOut() } label: {
                            Label("Sign out of Drive", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: { Image(systemName: "person.crop.circle") }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
            TextField("", text: $query, prompt: Text("Search Drive").foregroundColor(Theme.muted))
                .foregroundColor(Theme.txt).tint(Theme.accent)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.muted) }
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(searchFocused ? Theme.accent.opacity(0.6) : Theme.line))
    }

    private var scopeBar: some View {
        HStack(spacing: 22) {
            ForEach(DriveScope.allCases) { s in
                Button { scope = s } label: {
                    Text(s.rawValue)
                        .fontWeight(scope == s ? .semibold : .regular)
                        .foregroundColor(scope == s ? Theme.accent : Theme.txt)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var pinned: some View {
        if !lib.pins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Pinned", systemImage: "pin.fill")
                    .font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.muted)
                VStack(spacing: 0) {
                    ForEach(lib.pins) { DriveRow(ref: $0, subtitle: $0.isFolder ? "Folder" : nil) }
                }
                .glowCard()
            }
        }
    }

    @ViewBuilder private var results: some View {
        if let e = model.error { Text(e).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
        if !model.items.isEmpty {
            DriveItemList(items: model.items, hasMore: model.hasMore) {
                Task { await model.load(q: q, auth: auth, more: true) }
            }
        } else if model.loading {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
        } else if model.loadedOnce && model.error == nil {
            Text(cleanQuery.isEmpty ? "No files here." : "No results for \u{201C}\(cleanQuery)\u{201D}.")
                .foregroundColor(Theme.muted)
        }
    }
}

/// Inside a folder
struct DriveFolderView: View {
    let folder: DriveRef
    @EnvironmentObject var auth: DriveAuth
    @EnvironmentObject var lib: DriveLibrary
    @StateObject private var model = DriveFolderModel()

    private var q: String { DriveAPI.parentQuery(folder.id) }

    var body: some View {
        DriveGate {
            ScrollView {
                VStack(spacing: 14) {
                    if let e = model.error { Text(e).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
                    if !model.items.isEmpty {
                        DriveItemList(items: model.items, hasMore: model.hasMore) {
                            Task { await model.load(q: q, auth: auth, more: true) }
                        }
                    } else if model.loading {
                        ProgressView().tint(Theme.accent)
                    } else if model.loadedOnce && model.error == nil {
                        Text("This folder is empty.").foregroundColor(Theme.muted)
                    }
                }
                .padding(16)
            }
            .refreshable { await model.load(q: q, auth: auth) }
            .task { await model.load(q: q, auth: auth) }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { lib.togglePin(folder) } label: {
                    Image(systemName: lib.isPinned(folder) ? "pin.fill" : "pin")
                }
            }
        }
    }
}

// MARK: - File preview (native QuickLook, not the Google web UI)

struct DrivePreviewView: View {
    let ref: DriveRef
    @EnvironmentObject var auth: DriveAuth
    @EnvironmentObject var lib: DriveLibrary
    @State private var fileURL: URL?
    @State private var error: String?

    var body: some View {
        DriveGate {
            Group {
                if let fileURL {
                    QuickLookView(url: fileURL).ignoresSafeArea(edges: .bottom)
                } else if let error {
                    VStack(spacing: 14) {
                        Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }.foregroundColor(Theme.accent)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.accent)
                        Text("Opening…").font(Theme.font(.footnote)).foregroundColor(Theme.muted)
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
                Button { lib.togglePin(ref) } label: {
                    Image(systemName: lib.isPinned(ref) ? "pin.fill" : "pin")
                }
            }
        }
    }

    private func load() async {
        error = nil
        do {
            let token = try await auth.accessToken()
            fileURL = try await DriveAPI.download(ref, token: token)
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ vc: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; vc.reloadData() }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ u: URL) { url = u }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Course page > My Drive tab

struct CourseDriveTab: View {
    let courseId: Int
    @EnvironmentObject var lib: DriveLibrary

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(lib.files(for: courseId)) { r in
                    DriveRow(ref: r, subtitle: r.isFolder ? "Folder" : nil) {
                        withAnimation { lib.toggle(r, in: courseId) }
                    }
                }
            }
            .glowCard()
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

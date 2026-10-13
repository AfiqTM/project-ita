import SwiftUI
import WebKit
import Security

// MARK: - Microsoft Teams
//
// Teams is the real Teams website running in a hidden-until-needed web view, so the user signs in once
// (Others > Microsoft Teams) and stays signed in. While the page runs, the Microsoft Graph token it uses
// is captured and re-used to list the user's classes, files, assignments and posts natively in the app's UI.
// Classes can be linked to an iTa'leem "Section" course; a Teams icon then shows on that course page.

struct TeamLink: Codable, Hashable {
    var teamId: String
    var teamName: String
}

// MARK: Graph models

struct TGList<T: Decodable>: Decodable {
    let value: [T]
    let nextLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}
struct TGTeam: Decodable, Identifiable, Hashable { let id: String; let displayName: String }
struct TGChannel: Decodable, Identifiable, Hashable { let id: String; let displayName: String }
struct TGFolderFacet: Decodable, Hashable { let childCount: Int? }
struct TGFileFacet: Decodable, Hashable { let mimeType: String? }
struct TGParent: Decodable, Hashable { let driveId: String? }
struct TGItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int?
    let webUrl: String?
    let lastModifiedDateTime: String?
    let folder: TGFolderFacet?
    let file: TGFileFacet?
    let parentReference: TGParent?
    let downloadUrl: String?
    enum CodingKeys: String, CodingKey {
        case id, name, size, webUrl, lastModifiedDateTime, folder, file, parentReference
        case downloadUrl = "@microsoft.graph.downloadUrl"
    }
    var isFolder: Bool { folder != nil }
}
struct TGBody: Decodable, Hashable { let content: String?; let contentType: String? }
struct TGAssignment: Decodable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let dueDateTime: String?
    let status: String?
    let instructions: TGBody?
}
struct TGUserRef: Decodable, Hashable { let displayName: String? }
struct TGFrom: Decodable, Hashable { let user: TGUserRef? }
struct TGMessage: Decodable, Identifiable, Hashable {
    let id: String
    let createdDateTime: String?
    let from: TGFrom?
    let subject: String?
    let body: TGBody?
}

enum TeamsError: LocalizedError {
    case notSignedIn
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Teams. Open Others > Microsoft Teams and sign in."
        case .http(let c) where c == 401 || c == 403: return "Microsoft didn't allow access to this (\(c))."
        case .http(let c) where c == 404: return "Not available for this class (404)."
        case .http(let c): return "Microsoft returned an error (\(c))."
        }
    }
}

func tgDate(_ s: String?) -> String {
    guard let s else { return "-" }
    let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
    guard let d = a.date(from: s) ?? b.date(from: s) else { return "-" }
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
    return f.string(from: d)
}

// MARK: - Hub (web session + Graph + course links)

@MainActor
final class TeamsHub: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView

    @Published var signedIn: Bool
    @Published var teams: [TGTeam] = []
    @Published var loadingTeams = false
    @Published var teamsError: String?
    @Published private(set) var links: [String: TeamLink] = [:]      // courseId -> class

    private var tokens: [String: (exp: Date, scopes: Int)] = [:]
    private let linksKey = "teams.links.v1", signedKey = "teams.signedIn.v1"
    static let home = URL(string: "https://teams.microsoft.com/")!
    private static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    // Captures the Bearer token the Teams page sends to Microsoft Graph
    private static let sniffJS = #"""
    (function(){
      if (window.__itaTok) return; window.__itaTok = true;
      function post(h){ try{ var m=/^Bearer\s+(.+)$/i.exec(h||''); if(m) window.webkit.messageHandlers.msTok.postMessage(m[1]); }catch(e){} }
      function isG(u){ try{ return /(^|\.)graph\.microsoft\.com$/i.test(new URL(u,location.href).hostname); }catch(e){ return false; } }
      var of=window.fetch;
      window.fetch=function(i,o){
        try{ var u=(typeof i==='string')?i:(i&&i.url);
          if(isG(u)){ var h=(o&&o.headers)||(i&&i.headers); var a=null;
            if(h){ if(typeof h.get==='function') a=h.get('Authorization'); else a=h.Authorization||h.authorization; }
            post(a); } }catch(e){}
        return of.apply(this,arguments);
      };
      var ox=XMLHttpRequest.prototype.open, sh=XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open=function(m,u){ this.__g=isG(u); return ox.apply(this,arguments); };
      XMLHttpRequest.prototype.setRequestHeader=function(k,v){ if(this.__g && /^authorization$/i.test(k)) post(v); return sh.apply(this,arguments); };
      // MSAL cache (when stored in clear text)
      function scan(){
        try{ [localStorage, sessionStorage].forEach(function(st){
          for(var i=0;i<st.length;i++){ var k=st.key(i); if(!k||k.toLowerCase().indexOf('accesstoken')<0) continue;
            try{ var v=JSON.parse(st.getItem(k)); if(v&&v.secret&&/graph\.microsoft\.com/i.test(v.target||'')) post('Bearer '+v.secret); }catch(e){} } });
        }catch(e){}
      }
      setInterval(scan, 4000);
    })();
    """#

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame: .zero, configuration: cfg)
        signedIn = UserDefaults.standard.bool(forKey: signedKey)
        super.init()
        webView.customUserAgent = Self.desktopUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        cfg.userContentController.add(self, name: "msTok")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.sniffJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let d = UserDefaults.standard.data(forKey: linksKey),
           let v = try? JSONDecoder().decode([String: TeamLink].self, from: d) { links = v }
        Task { await boot() }
    }

    private func boot() async {
        await restoreCookies()
        webView.load(URLRequest(url: Self.home))
    }

    // MARK: course links

    func linkedTeam(for courseId: Int) -> TeamLink? { links[String(courseId)] }
    func courseId(forTeam id: String) -> Int? {
        links.first(where: { $0.value.teamId == id }).flatMap { Int($0.key) }
    }
    func link(_ t: TGTeam, to courseId: Int) {
        links = links.filter { $0.value.teamId != t.id }           // a class belongs to one course
        links[String(courseId)] = TeamLink(teamId: t.id, teamName: t.displayName)
        saveLinks()
    }
    func unlink(teamId: String) {
        links = links.filter { $0.value.teamId != teamId }
        saveLinks()
    }
    private func saveLinks() {
        if let d = try? JSONEncoder().encode(links) { UserDefaults.standard.set(d, forKey: linksKey) }
    }

    // MARK: token

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "msTok", let raw = m.body as? String else { return }
        receive(raw)
    }

    private func receive(_ raw: String) {
        let parts = raw.split(separator: ".")
        guard parts.count >= 2, let data = Self.b64(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let aud = (obj["aud"] as? String ?? "").lowercased()
        guard aud.contains("graph.microsoft.com") || aud == "00000003-0000-0000-c000-000000000000" else { return }
        let exp = Date(timeIntervalSince1970: (obj["exp"] as? Double) ?? 0)
        guard exp > Date().addingTimeInterval(120) else { return }
        let scopes = (obj["scp"] as? String)?.split(separator: " ").count ?? 0
        tokens[raw] = (exp, scopes)
        if !signedIn { signedIn = true; UserDefaults.standard.set(true, forKey: signedKey) }
        Task { await saveCookies() }
    }

    private static func b64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    private func bestToken() -> String? {
        let now = Date().addingTimeInterval(60)
        tokens = tokens.filter { $0.value.exp > now }
        return tokens.max(by: { $0.value.scopes < $1.value.scopes })?.key
    }

    /// A valid Graph token; if none, reloads the Teams page (which refreshes it) and waits a little.
    private func validToken() async -> String? {
        if let t = bestToken() { return t }
        webView.load(URLRequest(url: Self.home))
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let t = bestToken() { return t }
        }
        return nil
    }

    func graph<T: Decodable>(_ pathOrURL: String, _ type: T.Type) async throws -> T {
        for attempt in 0..<2 {
            guard let tok = await validToken() else { throw TeamsError.notSignedIn }
            let s = pathOrURL.hasPrefix("http") ? pathOrURL : "https://graph.microsoft.com/v1.0" + pathOrURL
            guard let url = URL(string: s) else { throw TeamsError.http(400) }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            let (d, r) = try await URLSession.shared.data(for: req)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { tokens[tok] = nil; tokens = [:]; continue }
            guard (200..<300).contains(code) else { throw TeamsError.http(code) }
            return try JSONDecoder().decode(T.self, from: d)
        }
        throw TeamsError.notSignedIn
    }

    func graphAll<T: Decodable>(_ path: String, _ type: T.Type) async throws -> [T] {
        var out: [T] = []
        var next: String? = path
        var pages = 0
        while let n = next, pages < 10 {
            let r: TGList<T> = try await graph(n, TGList<T>.self)
            out += r.value
            next = r.nextLink
            pages += 1
        }
        return out
    }

    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }

    // MARK: data

    func loadTeams() async {
        guard !loadingTeams else { return }
        loadingTeams = true; teamsError = nil
        defer { loadingTeams = false }
        do {
            let list = try await graphAll("/me/joinedTeams", TGTeam.self)
            teams = list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            // keep the saved names fresh
            for (k, v) in links { if let t = teams.first(where: { $0.id == v.teamId }), t.displayName != v.teamName {
                links[k] = TeamLink(teamId: t.id, teamName: t.displayName) } }
            saveLinks()
        } catch {
            teamsError = error.localizedDescription
        }
    }

    func channels(_ teamId: String) async throws -> [TGChannel] {
        try await graphAll("/teams/\(enc(teamId))/channels", TGChannel.self)
    }

    // MARK: sign-in state

    func signOut() {
        tokens = [:]; teams = []; teamsError = nil
        signedIn = false
        UserDefaults.standard.set(false, forKey: signedKey)
        TeamsCookieVault.clear()
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { recs in
            let ms = recs.filter { TeamsHub.isMicrosoftHost($0.displayName) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: ms) {}
        }
        Task {
            let cs = webView.configuration.websiteDataStore.httpCookieStore
            for c in await cs.allCookies() where Self.isMicrosoftHost(c.domain) { await cs.deleteCookie(c) }
            webView.load(URLRequest(url: Self.home))
        }
    }

    // MARK: cookies (Keychain) so the login survives app restarts

    nonisolated static func isMicrosoftHost(_ h: String) -> Bool {
        let s = h.lowercased()
        return ["microsoft", "live.com", "office.com", "office365", "msft", "msauth", "windows.net",
                "sharepoint", "skype", "cloud.microsoft"].contains { s.contains($0) }
    }

    func saveCookies() async {
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let mine = all.filter { Self.isMicrosoftHost($0.domain) }
        guard !mine.isEmpty else { return }
        TeamsCookieVault.save(mine.map {
            TeamsStoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                              secure: $0.isSecure, httpOnly: $0.isHTTPOnly, expires: $0.expiresDate)
        })
    }

    private func restoreCookies() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for c in TeamsCookieVault.load() {
            if let e = c.expires, e < Date() { continue }
            var p: [HTTPCookiePropertyKey: Any] = [.name: c.name, .value: c.value, .domain: c.domain, .path: c.path]
            if c.secure { p[.secure] = "TRUE" }
            if c.httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let e = c.expires { p[.expires] = e }
            if let ck = HTTPCookie(properties: p) { await store.setCookie(ck) }
        }
    }

    // MARK: web delegates

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await saveCookies() }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)      // pop-ups (e.g. sign-in) open in the same page
        return nil
    }
}

struct TeamsStoredCookie: Codable {
    var name: String, value: String, domain: String, path: String
    var secure: Bool, httpOnly: Bool
    var expires: Date?
}

enum TeamsCookieVault {
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "italeem.teams-cookies",
         kSecAttrAccount as String: "session"]
    }
    static func save(_ list: [TeamsStoredCookie]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> [TeamsStoredCookie] {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return [] }
        return (try? JSONDecoder().decode([TeamsStoredCookie].self, from: d)) ?? []
    }
    static func clear() { SecItemDelete(base as CFDictionary) }
}

// MARK: - Shared bits

struct TeamsWebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct TeamsWebScreen: View {
    @EnvironmentObject var hub: TeamsHub
    var body: some View {
        TeamsWebHost(webView: hub.webView)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Microsoft Teams")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Teams icon shown on a linked course page (top right)
struct TeamsGlyph: View {
    var body: some View {
        Image(systemName: "person.2.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.black)
            .frame(width: 30, height: 30)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TeamsMessage: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(24)
    }
}

// MARK: - Others > Microsoft Teams

struct TeamsOthersView: View {
    @EnvironmentObject var hub: TeamsHub
    @EnvironmentObject var catalog: CourseCatalog
    @State private var linking: TGTeam?
    @State private var confirmSignOut = false

    var body: some View {
        Group {
            if hub.signedIn { classList } else { loginPage }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Microsoft Teams")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hub.signedIn {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        NavigationLink { TeamsWebScreen() } label: { Label("Open Teams website", systemImage: "globe") }
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            Label("Sign out of Teams", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("Sign out of Microsoft Teams?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { hub.signOut() }
        }
        .sheet(item: $linking) { t in TeamLinkSheet(team: t) }
    }

    // Sign-in: the real Teams page; the screen switches to the class list once Teams is up
    private var loginPage: some View {
        VStack(spacing: 0) {
            Text("Sign in with your Microsoft account. You'll stay signed in.")
                .font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                .padding(12)
            TeamsWebHost(webView: hub.webView)
        }
    }

    private var classList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold a class to link it to a course.").font(.footnote).foregroundColor(Theme.muted)
                if hub.loadingTeams && hub.teams.isEmpty {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 30)
                } else if let e = hub.teamsError, hub.teams.isEmpty {
                    VStack(spacing: 12) {
                        TeamsMessage(text: e)
                        Button("Sign in again") { hub.signOut() }
                            .fontWeight(.semibold).foregroundColor(Theme.accent)
                    }
                } else if hub.teams.isEmpty {
                    TeamsMessage(text: "No classes found.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(hub.teams) { t in
                            NavigationLink {
                                TeamsClassView(team: TeamLink(teamId: t.id, teamName: t.displayName))
                            } label: {
                                TeamRow(team: t, linkedName: linkedName(t))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { linking = t } label: { Label("Link to a course", systemImage: "link") }
                                if hub.courseId(forTeam: t.id) != nil {
                                    Button(role: .destructive) { hub.unlink(teamId: t.id) } label: {
                                        Label("Unlink", systemImage: "link.badge.minus")
                                    }
                                }
                            }
                        }
                    }
                    .glowCard()
                }
            }
            .padding(16)
        }
        .refreshable { await hub.loadTeams() }
        .task { await catalog.loadIfNeeded() }
        .task { if hub.teams.isEmpty { await hub.loadTeams() } }
    }

    private func linkedName(_ t: TGTeam) -> String? {
        guard let cid = hub.courseId(forTeam: t.id) else { return nil }
        return catalog.courses.first(where: { $0.id == cid })?.subjectName ?? "Linked"
    }
}

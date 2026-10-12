import SwiftUI
import UIKit
import QuickLook
import GoogleSignIn      // Swift package: https://github.com/google/GoogleSignIn-iOS  (product "GoogleSignIn")

// MARK: - Google sign-in (login is remembered in the keychain by the SDK)

/// Called from App.swift for the Google redirect URL.
enum GoogleLink {
    static func handle(_ url: URL) { _ = GIDSignIn.sharedInstance.handle(url) }
}

enum DriveError: LocalizedError {
    case notSignedIn, unsupported, http(Int, String?)
    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You're not signed in to Google."
        case .unsupported: return "This type of file can't be previewed here."
        case .http(let code, let msg): return msg ?? "Google Drive returned an error (\(code))."
        }
    }
}

@MainActor
final class DriveAuth: ObservableObject {
    static let scope = "https://www.googleapis.com/auth/drive.readonly"

    @Published private(set) var user: GIDGoogleUser?
    @Published private(set) var restoring = true
    @Published private(set) var busy = false
    @Published var error: String?

    var isSignedIn: Bool { user != nil }
    var email: String? { user?.profile?.email }

    init() { restore() }

    /// Brings back the previous login at launch, so the user never has to sign in again.
    private func restore() {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { restoring = false; return }
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, _ in
            Task { @MainActor in
                guard let self else { return }
                if let user, user.grantedScopes?.contains(Self.scope) == true { self.user = user }
                self.restoring = false
            }
        }
    }

    func signIn() {
        guard let vc = Self.topViewController() else {
            error = "Couldn't open the Google sign-in screen."
            return
        }
        busy = true; error = nil
        GIDSignIn.sharedInstance.signIn(withPresenting: vc, hint: nil, additionalScopes: [Self.scope]) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if let u = result?.user {
                    if u.grantedScopes?.contains(Self.scope) == true { self.user = u }
                    else { self.error = "Drive access wasn't granted. Tick the Drive permission and try again." }
                } else if let e = err as NSError?, e.code != -5 {      // -5 = user closed the sign-in window
                    self.error = e.localizedDescription
                }
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        user = nil
    }

    /// A fresh access token (refreshed automatically when it has expired)
    func accessToken() async throws -> String {
        guard let user else { throw DriveError.notSignedIn }
        return try await withCheckedThrowingContinuation { cont in
            user.refreshTokensIfNeeded { u, err in
                if let t = u?.accessToken.tokenString { cont.resume(returning: t) }
                else { cont.resume(throwing: err ?? DriveError.notSignedIn) }
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var vc = scene?.keyWindow?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
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

    var subtitle: String {
        var parts: [String] = []
        if let m = modifiedTime, let d = Self.isoFrac.date(from: m) ?? Self.iso.date(from: m) {
            parts.append(d.formatted(date: .abbreviated, time: .omitted))
        }
        if let s = size, let n = Int64(s) { parts.append(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) }
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
    private let pinKey = "drive.pins.v1", subjectKey = "drive.subjects.v1"

    init() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: pinKey), let v = try? JSONDecoder().decode([DriveRef].self, from: d) { pins = v }
        if let d = ud.data(forKey: subjectKey),
           let v = try? JSONDecoder().decode([String: [DriveRef]].self, from: d) { bySubject = v }
    }
    private func save() {
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(pins) { ud.set(d, forKey: pinKey) }
        if let d = try? JSONEncoder().encode(bySubject) { ud.set(d, forKey: subjectKey) }
    }

    func isPinned(_ r: DriveRef) -> Bool { pins.contains { $0.id == r.id } }
    func togglePin(_ r: DriveRef) {
        if let i = pins.firstIndex(where: { $0.id == r.id }) { pins.remove(at: i) } else { pins.insert(r, at: 0) }
        save()
    }

    func files(for courseId: Int) -> [DriveRef] { bySubject[String(courseId)] ?? [] }
    func isSaved(_ r: DriveRef, in courseId: Int) -> Bool { files(for: courseId).contains { $0.id == r.id } }
    func toggle(_ r: DriveRef, in courseId: Int) {
        var list = files(for: courseId)
        if let i = list.firstIndex(where: { $0.id == r.id }) { list.remove(at: i) } else { list.append(r) }
        bySubject[String(courseId)] = list.isEmpty ? nil : list
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
            items = more ? items + r.items : r.items
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
                Text("Connect Google Drive").font(.title3.weight(.semibold)).foregroundColor(Theme.txt)
                Text("Sign in once to browse your files here. Access is read-only and you stay signed in.")
                    .font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)

                Button { auth.signIn() } label: {
                    HStack(spacing: 8) {
                        if auth.busy { ProgressView().tint(.black) } else { Image(systemName: "person.badge.key") }
                        Text("Sign in with Google")
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
                                Image(systemName: "pin.fill").font(.caption2).foregroundColor(Theme.accent)
                            }
                        }
                        if let s = subtitle, !s.isEmpty { Text(s).font(.caption).foregroundColor(Theme.muted) }
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
                        .font(.footnote).foregroundColor(Theme.muted)
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
        .preferredColorScheme(.dark)
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
                LazyVStack(alignment: .leading, spacing: 14) {
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
                    .font(.caption.weight(.semibold)).foregroundColor(Theme.muted)
                VStack(spacing: 0) {
                    ForEach(lib.pins) { DriveRow(ref: $0, subtitle: $0.isFolder ? "Folder" : nil) }
                }
                .glowCard()
            }
        }
    }

    @ViewBuilder private var results: some View {
        if let e = model.error { Text(e).font(.footnote).foregroundColor(Theme.muted) }
        if !model.items.isEmpty {
            VStack(spacing: 0) {
                ForEach(model.items) { DriveRow(ref: $0.ref, subtitle: $0.subtitle) }
                if model.hasMore {
                    ProgressView().tint(Theme.accent).padding()
                        .frame(maxWidth: .infinity)
                        .onAppear { Task { await model.load(q: q, auth: auth, more: true) } }
                }
            }
            .glowCard()
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
                LazyVStack(spacing: 14) {
                    if let e = model.error { Text(e).font(.footnote).foregroundColor(Theme.muted) }
                    if !model.items.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(model.items) { DriveRow(ref: $0.ref, subtitle: $0.subtitle) }
                            if model.hasMore {
                                ProgressView().tint(Theme.accent).padding().frame(maxWidth: .infinity)
                                    .onAppear { Task { await model.load(q: q, auth: auth, more: true) } }
                            }
                        }
                        .glowCard()
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

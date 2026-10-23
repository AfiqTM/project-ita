import SwiftUI

// MARK: - Sync between the app and the iTa'leem userscript
//
// One JSON file in the root of the user's Google Drive ("iTaleem-sync.json") holds to-dos, CAMS marks,
// pins and files saved to a subject. The app and the website both merge into it: for every item
// the copy with the newer `updated` time wins. Deleted to-dos stay as hidden tombstones so the
// deletion reaches the other device too. All times in the file are milliseconds since 1970.

extension Notification.Name {
    static let syncLocalChanged = Notification.Name("italeem.sync.localChanged")   // a store changed on this device
    static let syncApplied = Notification.Name("italeem.sync.applied")             // newer data arrived from Drive
}

struct SyncTodo: Codable, Equatable {
    var id: String
    var title: String
    var kind: String
    var courseId: Int?
    var courseName: String?
    var due: Int64
    var notes: String?
    var created: Int64
    var completedAt: Int64?
    var updated: Int64
    var deleted: Bool?
}
struct SyncCams: Codable { var updated: Int64; var groups: [CamsGroup] }
struct SyncList: Codable { var updated: Int64; var list: [DriveRef] }
struct SyncDoc: Codable {
    var version = 1
    var todos: [SyncTodo] = []
    var cams: [String: SyncCams] = [:]
    var pins: SyncList?
    var subj: [String: SyncList] = [:]

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        todos = try c.decodeIfPresent([SyncTodo].self, forKey: .todos) ?? []
        cams = try c.decodeIfPresent([String: SyncCams].self, forKey: .cams) ?? [:]
        pins = try c.decodeIfPresent(SyncList.self, forKey: .pins)
        subj = try c.decodeIfPresent([String: SyncList].self, forKey: .subj) ?? [:]
    }
}

func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
func fromMs(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }

@MainActor
final class SyncManager: ObservableObject {
    enum State: Equatable { case idle, syncing, ok(Date), needsPermission, needsSignIn, failed(String) }
    @Published private(set) var state: State = .idle

    static let fileName = "iTaleem-sync.json"
    private weak var todos: TodoStore?
    private weak var lib: DriveLibrary?
    private weak var auth: DriveAuth?
    private var debounce: Task<Void, Never>?
    private var running = false, again = false
    private var lastRun = Date.distantPast
    private var observer: NSObjectProtocol?
    private var netObserver: NSObjectProtocol?

    func configure(todos: TodoStore, lib: DriveLibrary, auth: DriveAuth) {
        self.todos = todos; self.lib = lib; self.auth = auth
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .syncLocalChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
        // Connection came back: send whatever was changed while offline
        netObserver = NotificationCenter.default.addObserver(forName: .offlineNetworkReturned, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.syncNow(force: true)
            }
        }
        syncNow()
    }

    /// Called after every local change: waits a moment so a burst of edits becomes one upload
    func schedule() {
        UserDefaults.standard.set(true, forKey: "sync.dirty")   // a change on this device not yet in Drive
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { await run() }
        }
    }

    /// `force` skips the "not more than once a minute" check (used by the Sync now button)
    func syncNow(force: Bool = false) {
        if !force && Date().timeIntervalSince(lastRun) < 60 { return }
        Task { await run() }
    }

    private func run() async {
        guard let todos, let lib, let auth else { return }
        guard auth.isSignedIn else { state = .needsSignIn; return }
        guard auth.canWrite else { state = .needsPermission; return }
        if running { again = true; return }
        running = true; state = .syncing; lastRun = Date()
        defer { running = false }
        do {
            let token = try await auth.accessToken()
            let fileId = try await Self.findFile(token)
            var remote = SyncDoc()
            if let id = fileId {
                let data = try await Self.download(id, token)
                // a file that can't be read is never overwritten
                if !data.isEmpty {
                    guard let doc = try? JSONDecoder().decode(SyncDoc.self, from: data) else {
                        throw DriveError.message("The sync file in Drive couldn't be read, so it was left untouched.")
                    }
                    remote = doc
                }
            }

            let local = Self.snapshot(todos: todos, lib: lib)
            let (merged, applyLocal, pushRemote) = Self.merge(local: local, remote: remote)
            if applyLocal { Self.apply(merged, todos: todos, lib: lib) }
            if pushRemote || fileId == nil {
                let body = try JSONEncoder().encode(merged)
                try await Self.upload(body, fileId: fileId, token)
            }
            state = .ok(Date())
            // changes made while offline have now gone through
            let d = UserDefaults.standard
            if d.bool(forKey: "sync.dirty") && d.bool(forKey: "sync.offlineFail") {
                await NotificationManager.shared.notify(id: "sync.sent", title: "Changes synced",
                                                        body: "Your changes made offline were sent to Google Drive and the website.")
            }
            d.set(false, forKey: "sync.dirty"); d.set(false, forKey: "sync.offlineFail")
        } catch let e as DriveError {
            if case .notSignedIn = e { state = .needsSignIn } else { state = .failed(e.localizedDescription) }
        } catch {
            if isOfflineError(error) {
                if UserDefaults.standard.bool(forKey: "sync.dirty") { UserDefaults.standard.set(true, forKey: "sync.offlineFail") }
                state = .failed("Offline · will sync when you're back online")
            } else {
                state = .failed(error.localizedDescription)
            }
        }
        if again { again = false; schedule() }
    }

    // MARK: local <-> document

    private static func snapshot(todos: TodoStore, lib: DriveLibrary) -> SyncDoc {
        var d = SyncDoc()
        d.todos = todos.allItems.map { t in
            SyncTodo(id: t.id.uuidString.lowercased(), title: t.title, kind: t.kind.rawValue, courseId: t.courseId,
                     courseName: t.courseName, due: ms(t.due), notes: t.notes, created: ms(t.created),
                     completedAt: t.completedAt.map(ms), updated: ms(t.updated ?? t.created),
                     deleted: t.deleted == true ? true : nil)
        }
        for (id, groups, at) in CamsStore.all() { d.cams[String(id)] = SyncCams(updated: ms(at), groups: groups) }
        d.pins = SyncList(updated: ms(lib.pinsUpdated), list: lib.pins)
        for (cid, list) in lib.bySubject { d.subj[cid] = SyncList(updated: ms(lib.subjectUpdated[cid] ?? Date(timeIntervalSince1970: 1)), list: list) }
        for (cid, at) in lib.subjectUpdated where d.subj[cid] == nil { d.subj[cid] = SyncList(updated: ms(at), list: []) }
        return d
    }

    /// Newer copy of every item wins. Returns the merged document, whether this device must change,
    /// and whether Drive must change.
    private static func merge(local: SyncDoc, remote: SyncDoc) -> (SyncDoc, Bool, Bool) {
        var out = SyncDoc()
        var applyLocal = false, push = false
        let cutoff = ms(Date().addingTimeInterval(-30 * 86400))

        var byId: [String: SyncTodo] = [:]
        for t in local.todos { byId[t.id.lowercased()] = t }
        var rIds = Set<String>()
        for var r in remote.todos {
            r.id = r.id.lowercased(); rIds.insert(r.id)
            if let l = byId[r.id] {
                if r.updated > l.updated { byId[r.id] = r; applyLocal = true }
                else if r.updated < l.updated { push = true }
            } else { byId[r.id] = r; applyLocal = true }
        }
        if byId.keys.contains(where: { !rIds.contains($0) }) { push = true }
        out.todos = byId.values.filter { !($0.deleted == true && $0.updated < cutoff) }.sorted { $0.created < $1.created }
        if out.todos.count != byId.count { push = true; applyLocal = true }

        for key in Set(local.cams.keys).union(remote.cams.keys) {
            switch (local.cams[key], remote.cams[key]) {
            case let (l?, r?):
                if r.updated > l.updated { out.cams[key] = r; applyLocal = true }
                else { out.cams[key] = l; if l.updated > r.updated { push = true } }
            case let (l?, nil): out.cams[key] = l; push = true
            case let (nil, r?): out.cams[key] = r; applyLocal = true
            default: break
            }
        }

        switch (local.pins, remote.pins) {
        case let (l?, r?):
            if r.updated > l.updated { out.pins = r; applyLocal = true }
            else { out.pins = l; if l.updated > r.updated { push = true } }
        case let (l?, nil): out.pins = l; if !l.list.isEmpty { push = true }
        case let (nil, r?): out.pins = r; applyLocal = true
        default: break
        }

        for key in Set(local.subj.keys).union(remote.subj.keys) {
            switch (local.subj[key], remote.subj[key]) {
            case let (l?, r?):
                if r.updated > l.updated { out.subj[key] = r; applyLocal = true }
                else { out.subj[key] = l; if l.updated > r.updated { push = true } }
            case let (l?, nil): out.subj[key] = l; push = true
            case let (nil, r?): out.subj[key] = r; applyLocal = true
            default: break
            }
        }
        return (out, applyLocal, push)
    }

    private static func apply(_ doc: SyncDoc, todos: TodoStore, lib: DriveLibrary) {
        let items: [TodoItem] = doc.todos.compactMap { s in
            guard let id = UUID(uuidString: s.id) else { return nil }
            var t = TodoItem(title: s.title, kind: TodoKind(rawValue: s.kind) ?? .other, courseId: s.courseId,
                             courseName: s.courseName, due: fromMs(s.due), notes: s.notes)
            t.id = id; t.created = fromMs(s.created); t.completedAt = s.completedAt.map(fromMs)
            t.updated = fromMs(s.updated); t.deleted = s.deleted == true ? true : nil
            return t
        }
        todos.applySync(items)
        for (key, c) in doc.cams { if let id = Int(key) { CamsStore.applySync(id, c.groups, at: fromMs(c.updated)) } }
        lib.applySync(pins: doc.pins.map { ($0.list, fromMs($0.updated)) },
                      subjects: doc.subj.mapValues { ($0.list, fromMs($0.updated)) })
        NotificationCenter.default.post(name: .syncApplied, object: nil)
    }

    // MARK: Drive file

    private static func request(_ url: URL, _ method: String, _ token: String) -> URLRequest {
        var r = URLRequest(url: url); r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }
    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) else { return }
        var msg: String?
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = o["error"] as? [String: Any] { msg = e["message"] as? String }
        throw DriveError.http(h.statusCode, msg)
    }

    /// The oldest file with that name in My Drive, so the app and the website always pick the same one
    private static func findFile(_ token: String) async throws -> String? {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            URLQueryItem(name: "q", value: "name = '\(fileName)' and 'root' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "1")]
        let (data, resp) = try await URLSession.shared.data(for: request(c.url!, "GET", token))
        try check(resp, data)
        struct R: Decodable { struct F: Decodable { let id: String }; let files: [F] }
        return try JSONDecoder().decode(R.self, from: data).files.first?.id
    }

    private static func download(_ id: String, _ token: String) async throws -> Data {
        let u = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        let (data, resp) = try await URLSession.shared.data(for: request(u, "GET", token))
        try check(resp, data)
        return data
    }

    private static func upload(_ json: Data, fileId: String?, _ token: String) async throws {
        if let id = fileId {
            var r = request(URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media")!, "PATCH", token)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = json
            let (data, resp) = try await URLSession.shared.data(for: r)
            try check(resp, data)
        } else {
            let boundary = "italeem-" + UUID().uuidString
            var r = request(URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!, "POST", token)
            r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func add(_ s: String) { body.append(s.data(using: .utf8)!) }
            add("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
            add("{\"name\":\"\(fileName)\",\"mimeType\":\"application/json\",\"parents\":[\"root\"]}\r\n")
            add("--\(boundary)\r\nContent-Type: application/json\r\n\r\n")
            body.append(json)
            add("\r\n--\(boundary)--")
            r.httpBody = body
            let (data, resp) = try await URLSession.shared.data(for: r)
            try check(resp, data)
        }
    }
}

// MARK: - Small status row (Others tab)

struct SyncStatusRow: View {
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var auth: DriveAuth

    private var text: String {
        switch sync.state {
        case .idle: return "Not synced yet"
        case .syncing: return "Syncing…"
        case .ok(let d): return "Synced " + d.formatted(date: .omitted, time: .shortened)
        case .needsPermission: return "Allow Drive sync (one-time re-sign-in)"
        case .needsSignIn: return "Connect Google Drive to sync with the website"
        case .failed(let m): return m
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync with website").foregroundColor(Theme.txt).rocks(15, normal: .subheadline.weight(.semibold))
                Text(text).font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(2)
            }
            Spacer()
            switch sync.state {
            case .needsPermission, .needsSignIn:
                Button(sync.state == .needsSignIn ? "Connect" : "Allow") { auth.signIn() }
                    .rocks(17, normal: Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.accent)
            case .syncing:
                ProgressView().tint(Theme.accent)
            default:
                Button("Sync now") { sync.syncNow(force: true) }
                    .rocks(17, normal: Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: auth.canWrite) { ok in if ok { sync.syncNow(force: true) } }
        .onChange(of: auth.isSignedIn) { ok in if ok { sync.syncNow(force: true) } }
    }
}

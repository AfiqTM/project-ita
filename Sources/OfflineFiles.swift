import SwiftUI
import CryptoKit

// MARK: - Offline course files
//
// Separate from "Offline support" data (OfflineCache): real files (PDFs, slides, attachments) are saved in
// their own folder, so turning the data copy off never deletes them, and deleting them never touches the data.
//
//   Download course files (off by default, inside Offline support)
//     - in the normal ~3-day download, every file up to the size limit (10 MB, or 25 / 50 MB) of every
//       course is saved; Wi-Fi only unless "Files on mobile data" is on (it ignores the general mobile-data setting)
//     - a file is downloaded once; it is fetched again only when its last-modified time changes
//     - videos and external links are never included (they aren't real files on the site)
//     - press and hold a file > Download: saves just that file, whatever its size (works with the switch off too)
//     - Delete downloaded files: removes only these files
//   Opening: the file viewer opens the saved copy when there is no internet.

extension OfflineSettings {
    static let filesKey = "offline.files.enabled"
    static let filesMobileKey = "offline.files.mobileData"
    static let filesLimitKey = "offline.files.limitMB"

    /// Automatic downloading of course files (default off)
    static var filesEnabled: Bool { UserDefaults.standard.bool(forKey: filesKey) }
    /// May files use mobile data? (default off = Wi-Fi only; separate from the general setting)
    static var filesMobile: Bool { UserDefaults.standard.bool(forKey: filesMobileKey) }
    /// Largest file saved automatically, in MB (default 10)
    static var filesLimitMB: Int {
        let v = UserDefaults.standard.integer(forKey: filesLimitKey)
        return v > 0 ? v : 10
    }
    /// Online, and on Wi-Fi unless files may use mobile data. Low Data Mode and hotspots count as mobile data.
    static var canDownloadFiles: Bool {
        let n = OfflineNet.shared
        guard n.online else { return false }
        return filesMobile || !(n.expensive || n.constrained)
    }
}

struct OfflineFileEntry: Codable {
    var key: String        // the file's address without the login token
    var name: String
    var rel: String        // <folder>/<file name>, inside the OfflineFiles folder
    var modified: Int      // the site's last-modified time when it was saved
    var size: Int64
    var manual: Bool       // saved by press-and-hold (kept even when over the limit)
    var saved: Date
}

private struct OfflineFileManifest: Codable {
    var entries: [OfflineFileEntry] = []
    var excluded: [String] = []   // files the user removed by hand: not downloaded again automatically
}

final class OfflineFileStore: ObservableObject, @unchecked Sendable {
    static let shared = OfflineFileStore()

    @Published private(set) var revision = 0
    @Published private(set) var busy = Set<String>()
    @Published private(set) var failed = Set<String>()
    @Published private(set) var autoRunning = 0

    private let lock = NSLock()
    private var entries: [String: OfflineFileEntry] = [:]
    private var excluded = Set<String>()
    private var inflight = Set<String>()
    private let root: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("OfflineFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        root = d
        if let data = try? Data(contentsOf: d.appendingPathComponent("manifest.json")),
           let m = try? JSONDecoder().decode(OfflineFileManifest.self, from: data) {
            for e in m.entries { entries[e.key] = e }
            excluded = Set(m.excluded)
        }
    }

    // MARK: keys

    /// The same file gives the same key with or without the token and the /webservice prefix
    static func key(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let q = c.queryItems?.filter { $0.name != "token" }
        c.queryItems = (q?.isEmpty ?? true) ? nil : q
        c.path = c.path.replacingOccurrences(of: "/webservice/pluginfile.php", with: "/pluginfile.php")
        return c.string ?? url.absoluteString
    }
    func key(of f: ModContent) -> String? {
        guard let s = f.fileurl, let u = URL(string: s) else { return nil }
        return Self.key(u)
    }
    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
    private static func safeName(_ s: String) -> String {
        let n = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "file" : n
    }

    // MARK: lookups (any thread)

    func entry(_ key: String) -> OfflineFileEntry? { lock.lock(); defer { lock.unlock() }; return entries[key] }
    func isExcluded(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return excluded.contains(key) }
    func localFile(_ e: OfflineFileEntry) -> URL? {
        let u = root.appendingPathComponent(e.rel)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    func isDownloaded(_ key: String) -> Bool { entry(key).map { localFile($0) != nil } ?? false }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    func sizeText() -> String {
        lock.lock(); let b = entries.values.reduce(Int64(0)) { $0 + $1.size }; lock.unlock()
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// The saved copy the viewer should open: always when there is no internet; with internet only when the
    /// copy is known to be the current version (same last-modified time as the course contents report).
    func localURL(for url: URL, modified: Int?) -> URL? {
        guard let e = entry(Self.key(url)), let f = localFile(e) else { return nil }
        if !OfflineNet.shared.online { return f }
        if let m = modified, m == e.modified { return f }
        return nil
    }

    // MARK: changes

    private func persist() {   // call with the lock held
        let m = OfflineFileManifest(entries: Array(entries.values), excluded: Array(excluded))
        if let d = try? JSONEncoder().encode(m) {
            try? d.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }
    private func bump() { onMain { self.revision += 1 } }
    private func setBusy(_ k: String, _ on: Bool) {
        onMain { if on { self.busy.insert(k) } else { self.busy.remove(k) } }
    }
    private func setFailed(_ k: String, _ on: Bool) {
        onMain { if on { self.failed.insert(k) } else { self.failed.remove(k) } }
    }
    func autoBegin() { onMain { self.autoRunning += 1 } }
    func autoEnd() { onMain { self.autoRunning = max(0, self.autoRunning - 1); self.revision += 1 } }

    private func claim(_ k: String, manual: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inflight.contains(k) { return false }
        inflight.insert(k)
        if manual, excluded.remove(k) != nil { persist() }
        return true
    }
    private func release(_ k: String) {
        lock.lock(); inflight.remove(k); lock.unlock()
        setBusy(k, false)
    }
    private func commit(_ e: OfflineFileEntry) {
        lock.lock(); entries[e.key] = e; persist(); lock.unlock()
    }

    /// byUser: remembered, so the automatic download doesn't fetch it again
    func remove(_ key: String, byUser: Bool) {
        lock.lock()
        let e = entries.removeValue(forKey: key)
        if byUser { excluded.insert(key) }
        persist()
        lock.unlock()
        if let e { try? FileManager.default.removeItem(at: root.appendingPathComponent(e.rel).deletingLastPathComponent()) }
        bump()
    }

    /// Deletes every downloaded file (and only those)
    func clearAll() {
        lock.lock(); entries = [:]; excluded = []; persist(); lock.unlock()
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent != "manifest.json" { try? FileManager.default.removeItem(at: u) }
        bump()
    }

    // MARK: download

    func downloadManually(_ f: ModContent) async { _ = await download(f, manual: true) }

    @discardableResult
    func download(_ file: ModContent, manual: Bool) async -> Bool {
        guard let s = file.fileurl, let url = MoodleAPI.shared.fileURL(s), let k = key(of: file) else { return false }
        guard claim(k, manual: manual) else { return false }
        setBusy(k, true)
        setFailed(k, false)
        defer { release(k) }

        var ok = false
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let name = Self.safeName(file.filename ?? url.lastPathComponent)
                // Moodle answers a bad token / missing file with a small JSON error instead of the file
                let looksLikeError = (resp.mimeType ?? "").lowercased().contains("json")
                    && size < 8192 && !name.lowercased().hasSuffix(".json")
                if size > 0 && !looksLikeError {
                    let folder = Self.hash(k)
                    let dir = root.appendingPathComponent(folder, isDirectory: true)
                    try? FileManager.default.removeItem(at: dir)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent(name))
                    commit(OfflineFileEntry(key: k, name: name, rel: folder + "/" + name,
                                            modified: file.timemodified ?? 0, size: size,
                                            manual: manual, saved: Date()))
                    ok = true
                }
            }
        } catch {}
        setFailed(k, !ok)
        bump()
        return ok
    }

    // MARK: automatic download

    private static let videoExt: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"]

    /// Real files of a course: resources, folders and files attached to pages. No videos, no links.
    static func candidates(_ secs: [CourseSection]) -> [ModContent] {
        var seen = Set<String>()
        var out: [ModContent] = []
        for m in secs.flatMap({ $0.modules }) where m.uservisible != false
            && ["resource", "folder", "page"].contains(m.modname) {
            for c in m.contents ?? [] {
                guard (c.type ?? "file") == "file", let f = c.fileurl, f.contains("pluginfile.php") else { continue }
                let name = (c.filename ?? "").lowercased()
                if m.modname == "page" && name == "index.html" { continue }   // the page text itself
                if (c.mimetype ?? "").lowercased().hasPrefix("video/") { continue }
                if videoExt.contains((name as NSString).pathExtension) { continue }
                guard let k = shared.key(of: c), seen.insert(k).inserted else { continue }
                out.append(c)
            }
        }
        return out
    }

    /// One course: downloads what is new or changed and within the size limit. Called by the normal
    /// ~3-day download (OfflinePrefetch) with the course contents it just checked.
    static func syncCourse(_ secs: [CourseSection]) async {
        guard OfflineSettings.enabled, OfflineSettings.filesEnabled else { return }
        let s = shared
        let limit = Int64(OfflineSettings.filesLimitMB) * 1_048_576
        s.autoBegin()
        defer { s.autoEnd() }
        for f in candidates(secs) {
            guard OfflineSettings.filesEnabled, OfflineSettings.canDownloadFiles else { break }
            guard let k = s.key(of: f) else { continue }
            let mod = f.timemodified ?? 0
            let size = Int64(f.filesize ?? 0)
            if let e = s.entry(k) {
                if e.modified == mod, s.localFile(e) != nil { continue }                 // already have this version
                if !e.manual && !(size > 0 && size <= limit) { s.remove(k, byUser: false); continue }
            } else {
                if s.isExcluded(k) { continue }                                         // removed by hand
                guard size > 0, size <= limit else { continue }
            }
            await s.download(f, manual: s.entry(k)?.manual ?? false)
        }
    }

    private static var syncingAll = false

    /// Files only, right now (switch turned on, mobile data allowed, limit raised). Uses the saved course
    /// lists and contents, so it only goes to the network for files.
    @MainActor
    static func syncAll() async {
        guard OfflineSettings.enabled, OfflineSettings.filesEnabled,
              OfflineSettings.canDownloadFiles, !syncingAll else { return }
        syncingAll = true
        defer { syncingAll = false }
        var ids = Set<Int>()
        for cls in ["inprogress", "past"] {
            if let r = await OfflinePrefetch.courses(cls) { ids.formUnion(r.courses.map { $0.id }) }
        }
        for id in ids.sorted() {
            let secs = await OfflinePrefetch.contents(id)
            await syncCourse(secs ?? [])
        }
    }
}

// MARK: - Press and hold a file: Download / Remove download

struct FileDownloadMenu: ViewModifier {
    let file: ModContent
    @ObservedObject private var store = OfflineFileStore.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            if let k = store.key(of: file) {
                if store.isDownloaded(k) {
                    Button(role: .destructive) { store.remove(k, byUser: true) } label: {
                        Label("Remove download", systemImage: "trash")
                    }
                } else {
                    Button { Task { await store.downloadManually(file) } } label: {
                        Label(downloadTitle, systemImage: "arrow.down.circle")
                    }
                    .disabled(store.busy.contains(k) || !OfflineNet.shared.online)
                }
            }
        }
    }

    private var downloadTitle: String {
        if let sz = file.filesize, sz > 0 {
            return "Download (" + ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file) + ")"
        }
        return "Download"
    }
}

extension View {
    @ViewBuilder func fileDownloadMenu(_ f: ModContent?) -> some View {
        if let f { self.modifier(FileDownloadMenu(file: f)) } else { self }
    }
}

/// Small icon at the end of a file row: spinner while downloading, arrow when saved on the phone
struct FileStateIcon: View {
    let file: ModContent?
    @ObservedObject private var store = OfflineFileStore.shared

    var body: some View {
        if let file, let k = store.key(of: file) {
            if store.busy.contains(k) {
                ProgressView().scaleEffect(0.7).tint(Theme.accent)
            } else if store.isDownloaded(k) {
                Image(systemName: "arrow.down.circle.fill").font(Theme.font(.caption)).foregroundColor(Theme.accent)
            } else if store.failed.contains(k) {
                Image(systemName: "exclamationmark.circle").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            }
        }
    }
}

// MARK: - Settings (inside the Offline support row)

struct OfflineFilesSection: View {
    let offlineOn: Bool
    @AppStorage(OfflineSettings.filesKey) private var filesOn = false
    @AppStorage(OfflineSettings.filesMobileKey) private var mobile = false
    @AppStorage(OfflineSettings.filesLimitKey) private var limit = 10
    @ObservedObject private var store = OfflineFileStore.shared
    @State private var confirmDelete = false

    private var hasFiles: Bool { store.count > 0 }

    var body: some View {
        VStack(spacing: 0) {
            if offlineOn {
                Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 14).padding(.bottom, 14)
                toggleRow(icon: "doc.on.doc", title: "Download course files",
                          subtitle: filesOn
                              ? (store.autoRunning > 0 ? "Downloading…"
                                 : "PDFs and attachments up to \(limit) MB · \(store.sizeText())")
                              : "Off · PDFs and attachments aren't saved",
                          isOn: $filesOn)
                if filesOn {
                    toggleRow(icon: "wifi", title: "Files on mobile data",
                              subtitle: mobile ? "Files also download on mobile data"
                                               : "Off · files wait for Wi-Fi",
                              isOn: $mobile)
                    limitRow
                }
            }
            if filesOn || hasFiles { deleteRow }
        }
        .onChange(of: filesOn) { v in if v { start() } }
        .onChange(of: mobile) { v in if v && filesOn { start() } }
        .onChange(of: limit) { _ in if filesOn { start() } }
        .confirmationDialog("Delete downloaded files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete files", role: .destructive) { store.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(filesOn
                 ? "Only downloaded PDFs and attachments are removed; your offline data stays. Files within the size limit download again at the next update unless you switch off Download course files."
                 : "Only downloaded PDFs and attachments are removed; your offline data stays.")
        }
    }

    private func start() { Task { await OfflineFileStore.syncAll() } }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(Theme.txt).fontWeight(.semibold)
                Text(subtitle).font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var limitRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line").foregroundColor(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Size limit per file").foregroundColor(Theme.txt).fontWeight(.semibold)
                Text("Bigger files are skipped. Press and hold a file to download it anyway.")
                    .font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(3)
            }
            Spacer()
            Picker("", selection: $limit) {
                Text("10 MB").tag(10)
                Text("25 MB").tag(25)
                Text("50 MB").tag(50)
            }
            .pickerStyle(.menu).labelsHidden().tint(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deleteRow: some View {
        Button { confirmDelete = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "trash").foregroundColor(.red).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete downloaded files").foregroundColor(Theme.txt).fontWeight(.semibold)
                    Text(hasFiles
                         ? "\(store.count) file\(store.count == 1 ? "" : "s") · \(store.sizeText()) · offline data is kept"
                         : "No files downloaded")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasFiles)
    }
}

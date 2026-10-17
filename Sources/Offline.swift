import SwiftUI
import Network
import CryptoKit

// MARK: - Offline support
//
// Every read-only call to iTa'leem (courses, course contents, assignments, alerts, ...) is saved to disk
// after it succeeds. A screen then opens in two steps:
//   1. it is filled straight from the saved copy (no waiting, works with no internet),
//   2. the normal online request runs and replaces it as soon as the answer arrives.
// If the request fails (no internet, server error) or takes longer than `OfflineQuality.waitLimit` (4 s on a
// good connection, 1.5 s when it has been slow, 1 s when it has been unstable) the saved copy is used instead.
// A late request is not thrown away: when its answer arrives it is saved and every open screen swaps to it
// at once (`.offlineFreshData`). A small pill at the top shows "Offline" or "Slow connection" meanwhile.
// Turn it on/off in Others > Offline support. Turning it off deletes the saved data.

extension Notification.Name {
    /// The app was showing saved data and the website answered again: screens should reload
    static let offlineBackOnline = Notification.Name("italeem.offline.backOnline")
    /// A slow request finished after the saved copy was shown, and the answer was different: screens swap to it
    static let offlineFreshData = Notification.Name("italeem.offline.freshData")
}

extension View {
    /// Runs `reload` when newer data was just saved in the background. It reads the saved copy only (no
    /// network), so the new data appears at once; state is set without an animation.
    func onFreshData(_ reload: @escaping () async -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .offlineFreshData)) { _ in
            Task { await OfflineCache.paintFromCache { await reload() } }
        }
    }
}

enum OfflineSettings {
    static let key = "offline.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// May background downloads use mobile data? (off = they wait for Wi-Fi)
    static let mobileKey = "offline.mobileData"
    static var mobileData: Bool { UserDefaults.standard.object(forKey: mobileKey) as? Bool ?? true }
}

// MARK: connectivity (readable from any thread)

final class OfflineNet {
    static let shared = OfflineNet()
    private let lock = NSLock()
    private var _online = true
    private var _expensive = false
    private let monitor = NWPathMonitor()

    var online: Bool { lock.lock(); defer { lock.unlock() }; return _online }
    var expensive: Bool { lock.lock(); defer { lock.unlock() }; return _expensive }

    /// Background downloads (prefetch, attendance copies) may run now: online, and on Wi-Fi unless
    /// the user allowed mobile data. Low Data Mode and personal hotspots count as mobile data.
    var canDownload: Bool {
        guard online else { return false }
        return OfflineSettings.mobileData || !(expensive || constrained)
    }
    private var _constrained = false
    var constrained: Bool { lock.lock(); defer { lock.unlock() }; return _constrained }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let ok = path.status == .satisfied
            self.lock.lock()
            let was = self._online
            self._online = ok; self._expensive = path.isExpensive; self._constrained = path.isConstrained
            self.lock.unlock()
            if !ok { OfflineQuality.shared.record(failed: true) }   // dropping out repeatedly = unstable
            Task { @MainActor in
                OfflineMonitor.shared.isOnline = ok
                // connection came back: waiting changes (submissions, to-dos) are sent
                if ok && !was { NotificationCenter.default.post(name: .offlineNetworkReturned, object: nil) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "italeem.offline.net"))
    }
}

@MainActor
final class OfflineMonitor: ObservableObject {
    static let shared = OfflineMonitor()
    @Published var isOnline = true
    /// true while the app is showing saved data because the website couldn't be reached
    @Published var usingCache = false
    /// the connection has been slow or unstable lately (see OfflineQuality)
    @Published var slow = false

    func markCache() { if !usingCache { usingCache = true } }
    /// A late answer arrived and was saved: no reload needed (screens are told with `.offlineFreshData`)
    func markOnlineQuietly() { if usingCache { usingCache = false } }
    func markOnline() {
        guard usingCache else { return }
        usingCache = false
        NotificationCenter.default.post(name: .offlineBackOnline, object: nil)
    }
}

// MARK: connection quality
//
// Every answer from the site is timed. The last few results decide how long the app is willing to wait before
// it shows the saved copy instead:
//   good ........ 4 s
//   slow ........ 1.5 s   (2 of the last 5 answers took 1.5 s or more, or hit the limit)
//   unstable .... 1 s     (2 of the last 5 requests failed, or the connection dropped out)
// Results older than 90 seconds are forgotten, so the app tries the normal wait again after a quiet moment.

enum ConnectionQuality { case good, slow, unstable }

final class OfflineQuality {
    static let shared = OfflineQuality()
    private struct Sample { let at: Date; let seconds: TimeInterval; let failed: Bool }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private static let slowSeconds: TimeInterval = 1.5
    private static let memory: TimeInterval = 90

    func record(seconds: TimeInterval, bytes: Int) {
        // a big answer (course contents) is slow because of its size, not because of the connection
        add(Sample(at: Date(), seconds: bytes > 100_000 ? min(seconds, 1) : seconds, failed: false))
    }
    func record(failed: Bool) { add(Sample(at: Date(), seconds: 0, failed: failed)) }

    private func add(_ s: Sample) {
        lock.lock()
        samples.append(s)
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
        lock.unlock()
        publish()
        // forget old results (and hide the pill) once they have expired, even if nothing else is requested
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.memory + 1) { [weak self] in self?.publish() }
    }

    var quality: ConnectionQuality {
        lock.lock(); defer { lock.unlock() }
        let recent = samples.filter { Date().timeIntervalSince($0.at) < Self.memory }.suffix(5)
        if recent.filter({ $0.failed }).count >= 2 { return .unstable }
        if recent.filter({ $0.seconds >= Self.slowSeconds }).count >= 2 { return .slow }
        return .good
    }

    /// How long a request with a saved copy may take before the saved copy is shown instead
    var waitLimit: TimeInterval {
        switch quality {
        case .good: return 4
        case .slow: return 1.5
        case .unstable: return 1
        }
    }

    private func publish() {
        let q = quality
        Task { @MainActor in
            let slow = q != .good
            if OfflineMonitor.shared.slow != slow { OfflineMonitor.shared.slow = slow }
        }
    }
}

/// One network request per saved answer at a time: a screen asking again while the first request is still
/// on its way joins it instead of sending another one.
final class OfflineInflight {
    static let shared = OfflineInflight()
    private let lock = NSLock()
    private var tasks: [String: Task<(Data, URLResponse), Error>] = [:]

    func task(_ key: String, _ req: URLRequest) -> Task<(Data, URLResponse), Error> {
        lock.lock(); defer { lock.unlock() }
        if let t = tasks[key] { return t }
        let t = Task<(Data, URLResponse), Error> { [weak self] in
            defer { self?.finish(key) }
            return try await MoodleAPI.session.data(for: req)
        }
        tasks[key] = t
        return t
    }
    private func finish(_ key: String) { lock.lock(); tasks[key] = nil; lock.unlock() }
}

/// Lets a continuation be resumed by whichever of two tasks gets there first
final class ResumeOnce {
    private let lock = NSLock()
    private var done = false
    func resume<T>(_ c: CheckedContinuation<T, Never>, _ v: T) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { c.resume(returning: v) }
    }
}

/// Tells the screens that newer data was saved. Several answers arriving together send one message.
enum OfflineFresh {
    @MainActor private static var pending = false
    @MainActor static func announce() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pending = false
            NotificationCenter.default.post(name: .offlineFreshData, object: nil)
        }
    }
}

// MARK: disk store

enum OfflineCache {
    /// While true (inside `paintFromCache`), API calls answer from disk only and never touch the network
    @TaskLocal static var cacheOnly = false

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("OfflineCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        return d
    }()

    /// Only reads are saved. Writes (submit, mark read, star...) and the one-time auto-login key never are.
    static func isCacheable(_ fn: String) -> Bool {
        fn.contains("_get_") && !fn.contains("autologin") && !fn.contains("updates_since")   // the change check must always be live
    }

    private static func file(_ name: String) -> URL {
        let h = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(h + ".bin")
    }
    static func apiName(_ fn: String, _ paramKey: String) -> String { "api|" + fn + "|" + paramKey }

    static func save(_ name: String, _ data: Data) {
        let u = file(name)
        if let old = try? Data(contentsOf: u), old == data {   // unchanged: skip the write, but note it was checked now
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
            return
        }
        try? data.write(to: u, options: .atomic)
    }
    static func load(_ name: String) -> Data? { try? Data(contentsOf: file(name)) }
    static func age(_ name: String) -> TimeInterval? { savedDate(name).map { Date().timeIntervalSince($0) } }
    static func savedDate(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(name).path))?[.modificationDate] as? Date
    }

    // Small typed helpers (used for the attendance page)
    static func saveObject<T: Encodable>(_ name: String, _ v: T) {
        if let d = try? JSONEncoder().encode(v) { save("obj|" + name, d) }
    }
    static func loadObject<T: Decodable>(_ name: String, as: T.Type = T.self) -> T? {
        load("obj|" + name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func sizeText() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Runs `body` once against the saved copy only (instant, silent when nothing is saved), so a screen
    /// can show last time's data first. Call the real load right after it.
    static func paintFromCache(_ body: () async -> Void) async {
        guard OfflineSettings.enabled else { return }
        await $cacheOnly.withValue(true) { await body() }
    }
}

// MARK: background download
//
// What is downloaded again, and when (nothing is fetched twice for the same reason):
//   One download about every 12 hours (random, 10-14 h). In it:
//   course lists, notifications, grades, announcements ... downloaded
//   course contents ..... a cheap "did anything change?" check first (core_course_get_updates_since);
//                         the full contents are only downloaded when it says yes. If the site doesn't
//                         support that check they are downloaded. A copy older than 3 days is replaced
//                         either way, as a safety net.

enum OfflinePrefetch {
    private static var running = false

    // Background downloads happen about every 12 hours, at a random time between 10 and 14 hours after
    // the last one (so the app doesn't hit the site at the same moment as everyone else). The next time is
    // remembered across launches. Opening the app earlier does nothing; switching Offline support on, or
    // allowing mobile data, downloads straight away.
    private static let nextKey = "offline.nextDownload"
    /// When the last download finished (seconds since 1970; 0 = never). Shown in Offline support.
    static let lastKey = "offline.lastDownload"
    private static let nextAttendanceKey = "offline.nextAttendanceCopy"

    private static func randomGap() -> TimeInterval { .random(in: 10 * 3600 ... 14 * 3600) }
    private static func due(_ key: String) -> Bool {
        Date().timeIntervalSince1970 >= UserDefaults.standard.double(forKey: key)   // unset = due now
    }
    private static func scheduleNext(_ key: String) {
        UserDefaults.standard.set(Date().addingTimeInterval(randomGap()).timeIntervalSince1970, forKey: key)
    }
    static func attendanceCopiesDue() -> Bool { due(nextAttendanceKey) }
    static func attendanceCopiesDone() { scheduleNext(nextAttendanceKey) }

    static let listMaxAge: TimeInterval = 11 * 3600          // a list saved by the last download is reused until the next one
    static let freshAge: TimeInterval = 10 * 60
    static let noCheckAge: TimeInterval = 6 * 3600           // only used when the site has no change check
    static let safetyAge: TimeInterval = 3 * 86400           // a copy this old is replaced even if nothing seems to have changed

    // Whether the site answers the change check (learned once per launch)
    private static let flagLock = NSLock()
    private static var _updatesSupported = true
    private static var updatesSupported: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return _updatesSupported }
        set { flagLock.lock(); _updatesSupported = newValue; flagLock.unlock() }
    }

    /// The saved answer to a call, without touching the network
    private static func saved<T: Decodable>(_ fn: String, _ p: [String: Any]) async -> T? {
        await OfflineCache.$cacheOnly.withValue(true) { () async -> T? in
            let r: T? = try? await MoodleAPI.shared.call(fn, p)
            return r
        }
    }

    /// Course list: the saved copy while it is younger than 30 minutes, otherwise downloaded again
    static func courses(_ cls: String) async -> CourseList? {
        let fn = "core_course_get_enrolled_courses_by_timeline_classification"
        let p: [String: Any] = ["classification": cls, "limit": 0, "offset": 0, "sort": "fullname"]
        let api = MoodleAPI.shared
        if let a = OfflineCache.age(api.offlineName(fn, p)), a < listMaxAge {
            let r: CourseList? = await saved(fn, p)
            if let r { return r }
        }
        let r: CourseList? = try? await api.call(fn, p)
        if let r { return r }
        let old: CourseList? = await saved(fn, p)
        return old
    }

    /// true = something changed in the course, false = nothing, nil = couldn't tell
    private static func changed(_ id: Int, since: Date) async -> Bool? {
        guard updatesSupported else { return nil }
        do {
            // 2 minutes of margin for differences between the phone's and the server's clock
            let data = try await MoodleAPI.shared.raw("core_course_get_updates_since",
                ["courseid": id, "since": Int(since.timeIntervalSince1970) - 120])
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inst = o["instances"] as? [Any] else { return nil }
            return !inst.isEmpty
        } catch is APIError {
            updatesSupported = false   // the site doesn't offer it: fall back to the age rule
            return nil
        } catch { return nil }         // network trouble: just fall back this time
    }

    /// Course contents, downloaded only when needed (see the table above)
    static func contents(_ id: Int) async -> [CourseSection]? {
        let fn = "core_course_get_contents"
        let p: [String: Any] = ["courseid": id]
        let api = MoodleAPI.shared
        func download() async -> [CourseSection]? {
            let r: [CourseSection]? = try? await api.call(fn, p)
            if let r { return r }
            let old: [CourseSection]? = await saved(fn, p)
            return old
        }
        func keep() async -> [CourseSection]? {
            let r: [CourseSection]? = await saved(fn, p)
            if let r { return r }
            return await download()
        }
        guard let copy = OfflineCache.savedDate(api.offlineName(fn, p)) else { return await download() }
        let age = Date().timeIntervalSince(copy)
        if age < freshAge { return await keep() }
        if age >= safetyAge { return await download() }
        switch await changed(id, since: copy) {
        case .some(true): return await download()
        case .some(false): return await keep()
        case .none:
            if age >= noCheckAge { return await download() }
            return await keep()
        }
    }

    /// Quietly downloads what the app needs so it is there next time with no internet.
    /// Everything goes through MoodleAPI, which saves each answer.
    @MainActor
    static func run(uid: Int, force: Bool = false) async {
        guard OfflineSettings.enabled, OfflineNet.shared.canDownload, uid > 0, !running else { return }
        if !force && !due(nextKey) { return }
        running = true
        scheduleNext(nextKey)
        if force { UserDefaults.standard.set(0.0, forKey: nextAttendanceKey) }   // attendance pages too, at the next chance
        defer { running = false }
        let api = MoodleAPI.shared

        var ids = Set<Int>()
        var ordered: [Int] = []   // in-progress then past, same order the Assignments tab asks in (so its saved copy is found)
        for cls in ["inprogress", "past", "future", "all", "favourites", "hidden"] {
            if let r = await courses(cls), cls == "inprogress" || cls == "past" {
                ids.formUnion(r.courses.map { $0.id })
                for c in r.courses where !ordered.contains(c.id) { ordered.append(c.id) }
            }
        }
        _ = try? await api.raw("message_popup_get_popup_notifications", ["useridto": uid])

        // Assignments: the list and each one's submission status, so the Assignments tab and every assignment
        // screen open (and take a queued submission) with no internet
        if !ordered.isEmpty,
           let ar: AssignResp = try? await api.call("mod_assign_get_assignments", ["courseids": ordered]) {
            await assignmentStatuses(ar, uid: uid)
        }

        let extras = true   // grades and announcements come with every download (it only happens twice a day)

        // 4 courses at a time
        let list = Array(ids)
        var i = 0
        while i < list.count {
            let chunk = list[i..<min(i + 4, list.count)]
            i += 4
            await withTaskGroup(of: Void.self) { g in
                for id in chunk { g.addTask { await course(id, uid: uid, extras: extras) } }
            }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
    }

    /// The submission status of every assignment (4 at a time), saved under the same request the screens make
    private static func assignmentStatuses(_ r: AssignResp, uid: Int) async {
        let ids = r.courses.flatMap { $0.assignments.map { $0.id } }
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 4, ids.count)])
            i += 4
            await withTaskGroup(of: Void.self) { g in
                for aid in chunk {
                    g.addTask { _ = try? await MoodleAPI.shared.raw("mod_assign_get_submission_status", ["assignid": aid, "userid": uid]) }
                }
            }
        }
    }

    /// One course: its contents, and (hourly) its grades, its announcements forum and the latest posts in it.
    /// The requests are identical to the ones the screens make, so the screens find them saved.
    private static func course(_ id: Int, uid: Int, extras: Bool) async {
        let api = MoodleAPI.shared
        let secs = await contents(id)
        await OfflineFileStore.syncCourse(secs ?? [])   // "Download course files" (off by default; own Wi-Fi/mobile rule)
        guard extras else { return }

        _ = try? await api.raw("gradereport_user_get_grade_items", ["courseid": id, "userid": uid])

        // The assignment screen asks for its own course's assignments (settings, due date, lecturer's files)
        if (secs ?? []).contains(where: { $0.modules.contains { $0.modname == "assign" } }) {
            _ = try? await api.raw("mod_assign_get_assignments", ["courseids": [id]])
        }

        // Announcements: the forum named announcements/news, otherwise the course's first forum
        let forums = (secs ?? []).flatMap { $0.modules }.filter { $0.modname == "forum" && $0.instance != nil }
        let pick = forums.first { m in
            let n = m.name.lowercased()
            return n.contains("announce") || n.contains("news")
        } ?? forums.first
        guard let fid = pick?.instance else { return }
        guard let d: DiscResp = try? await api.call("mod_forum_get_forum_discussions",
                                                    ["forumid": fid, "perpage": 50]) else { return }
        for disc in d.discussions.prefix(5) {   // newest five: the ones people actually open
            _ = try? await api.raw("mod_forum_get_discussion_posts", ["discussionid": disc.discussion])
        }
    }
}

// MARK: attendance copy

struct AttSaved: Codable {
    struct Rec: Codable {
        var date, time, desc, status, points, remarks, kind: String
    }
    var rows: [[String]]
    var points: String?
    var records: [Rec]
    var maxPercent: String?
    var maxPoints: String?
    var total: Int?
    var taken: Int?
    var earned: Double?
    var possible: Double?
    var sample: String
    var saved: Date

    init(_ s: AttSummary) {
        rows = s.rows.map { [$0.0, $0.1] }
        points = s.points
        records = s.records.map { Rec(date: $0.date, time: $0.time, desc: $0.desc, status: $0.status,
                                     points: $0.points, remarks: $0.remarks, kind: $0.kind.rawValue) }
        maxPercent = s.maxPercent; maxPoints = s.maxPoints
        total = s.total; taken = s.taken; earned = s.earned; possible = s.possible
        sample = s.sample
        saved = Date()
    }

    var summary: AttSummary {
        var s = AttSummary()
        s.rows = rows.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        s.points = points
        s.records = records.map {
            AttRecord(date: $0.date, time: $0.time, desc: $0.desc, status: $0.status, points: $0.points,
                      remarks: $0.remarks, kind: AttKind(rawValue: $0.kind) ?? .other)
        }
        s.maxPercent = maxPercent; s.maxPoints = maxPoints
        s.total = total; s.taken = taken; s.earned = earned; s.possible = possible
        s.sample = sample
        return s
    }

    static func key(_ cmid: Int) -> String { "attendance-\(cmid)" }
}

extension MoodleAPI {
    /// Used by the background sync: saves the attendance page of one activity for offline use.
    /// Uses the existing web session only (never asks for an auto-login key).
    @discardableResult
    func saveAttendanceCopy(_ m: Module, courseId: Int, uid: Int) async -> Bool {
        guard OfflineSettings.enabled, OfflineNet.shared.canDownload,
              let base = m.url, var c = URLComponents(string: base) else { return true }
        var q = c.queryItems ?? []
        q.removeAll { $0.name == "view" }
        q.append(URLQueryItem(name: "view", value: "4"))
        c.queryItems = q
        guard let u = c.url, let html = await fetchHTML(u, userid: uid, allowAutologin: false) else { return false }
        var s = parseAttendance(html)
        guard !(s.rows.isEmpty && s.records.isEmpty) else { return true }
        if s.maxPercent == nil || s.total == nil,
           let h = await attendanceMobileContent(cmid: m.id, courseId: courseId, userid: uid) {
            s.mergeMax(from: parseAttendance(h))
        }
        s.fillMax()
        OfflineCache.saveObject(AttSaved.key(m.id), AttSaved(s))
        return true
    }
}

// MARK: UI

/// Small pill at the top of the app while saved data is being shown
struct OfflineBanner: View {
    @ObservedObject private var m = OfflineMonitor.shared

    var body: some View {
        let offline = !m.isOnline
        let show = m.usingCache || (m.slow && OfflineSettings.enabled)
        Group {
            if show {
                HStack(spacing: 6) {
                    Image(systemName: offline ? "wifi.slash" : "wifi.exclamationmark")
                    Text(offline ? "Offline · showing saved data" : "Slow connection · saved data first")
                }
                .font(Theme.font(.caption2).weight(.semibold))
                .foregroundColor(Theme.muted)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.surface2)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line))
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: show)
    }
}

/// Others tab: one row. Tick / untick turns Offline support on or off; tapping the row (or the >) opens the
/// Offline support screen with every other option (mobile data, course files, delete files).
struct OfflineSupportRow: View {
    @AppStorage(OfflineSettings.key) private var on = true
    @EnvironmentObject var app: AppState
    @State private var size = ""
    @State private var open = false

    private func download() {
        guard let uid = app.site?.userid else { return }
        Task { await OfflinePrefetch.run(uid: uid, force: true); size = OfflineCache.sizeText() }
    }

    private var subtitle: String {
        guard on else { return "Off · nothing is saved" }
        return "Opens saved data with no internet" + (size.isEmpty ? "" : " · \(size)")
    }

    var body: some View {
        HStack(spacing: 14) {
            Button { open = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "icloud.and.arrow.down").foregroundColor(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline support").foregroundColor(Theme.txt).fontWeight(.semibold)
                        Text(subtitle).font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: $on).labelsHidden().tint(Theme.accent)

            Button { open = true } label: {
                Image(systemName: "chevron.right").font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.muted)
                    .padding(.vertical, 6).padding(.leading, 2)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
        .navigationDestination(isPresented: $open) { OfflineSupportScreen() }
        .onAppear { size = OfflineCache.sizeText() }
        .onChange(of: open) { v in if !v { size = OfflineCache.sizeText() } }
        .onChange(of: on) { v in
            if v { download() }
            else {
                OfflineCache.clearAll()   // downloaded course files are separate and stay
                OfflineMonitor.shared.usingCache = false
                size = ""
            }
        }
    }
}

/// Offline support > everything else: mobile data for saved data, then Download course files and its options
struct OfflineSupportScreen: View {
    @AppStorage(OfflineSettings.key) private var on = true
    @AppStorage(OfflineSettings.mobileKey) private var mobile = true
    @AppStorage(OfflinePrefetch.lastKey) private var lastDownload = 0.0
    @EnvironmentObject var app: AppState
    @ObservedObject private var monitor = OfflineMonitor.shared
    @State private var downloading = false
    @State private var blocked = false

    private func downloadNow() {
        guard let uid = app.site?.userid, !downloading else { return }
        downloading = true
        blocked = !OfflineNet.shared.canDownload
        Task {
            await OfflinePrefetch.run(uid: uid, force: true)
            downloading = false
        }
    }

    private var lastText: String {
        guard lastDownload > 0 else { return "Last download: never" }
        return "Last download: " + Date(timeIntervalSince1970: lastDownload).formatted(date: .abbreviated, time: .shortened)
    }

    private var downloadNowRow: some View {
        Button { downloadNow() } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").foregroundColor(Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download now").foregroundColor(Theme.txt).fontWeight(.semibold)
                    Text(downloading ? "Downloading…"
                         : !on ? "Switch Offline support on first"
                         : !monitor.isOnline ? "No internet · " + lastText
                         : blocked ? "Waiting for Wi-Fi · " + lastText
                         : lastText)
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(2)
                }
                Spacer()
                if downloading { ProgressView().tint(Theme.accent) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!on || downloading || !monitor.isOnline)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                downloadNowRow          // first option on the screen, with the last download date and time
                OfflineQueueSection()   // submissions waiting to upload: file names, cancel
                if on {
                    HStack(spacing: 14) {
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(Theme.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download on mobile data").foregroundColor(Theme.txt).fontWeight(.semibold)
                            Text(mobile ? "Saved data also updates on mobile data"
                                        : "Off · background downloads wait for Wi-Fi")
                                .font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(2)
                        }
                        Spacer()
                        Toggle("", isOn: $mobile).labelsHidden().tint(Theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Offline support is off. Switch it on in Others to save data for use with no internet.")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }

                // Course files (PDFs, attachments): their own switch, Wi-Fi rule and storage, see OfflineFiles.swift
                OfflineFilesSection(offlineOn: on)
            }
            .glowCard()
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Offline support")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mobile) { v in   // allowed again: catch up now
            guard v, on, let uid = app.site?.userid else { return }
            Task { await OfflinePrefetch.run(uid: uid, force: true) }
        }
    }
}
/// Submissions waiting to be sent: shows the file names, and lets the user cancel one before it goes out
struct OfflineQueueSection: View {
    @ObservedObject private var queue = OfflineQueue.shared
    @ObservedObject private var monitor = OfflineMonitor.shared
    @State private var cancelling: SubmissionJob?

    private func title(_ j: SubmissionJob) -> String {
        switch (j.kind, j.submit) {
        case (.remove, _): return "Removal"
        case (.save, true): return "Submission"
        case (.save, false): return "Saved changes"
        }
    }

    var body: some View {
        if !queue.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "tray.and.arrow.up").foregroundColor(Theme.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting to upload").foregroundColor(Theme.txt).fontWeight(.semibold)
                        Text(monitor.isOnline ? "Sending now…" : "Will be sent when you're back online")
                            .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)

                ForEach(queue.jobs) { j in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(j.name).font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.txt)
                        Text(title(j) + (j.error == nil ? "" : " · couldn't send"))
                            .font(Theme.font(.caption)).foregroundColor(j.error == nil ? Theme.muted : .red)
                        if let e = j.error {
                            Text(e).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                        }
                        ForEach(j.newFiles, id: \.self) { f in
                            Label(f, systemImage: "doc").font(Theme.font(.caption)).foregroundColor(Theme.txt).lineLimit(1)
                        }
                        if j.newFiles.isEmpty && j.kind == .save {
                            Text(j.text == nil ? "No new files" : "Text only").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                        }
                        HStack(spacing: 18) {
                            if j.error != nil { Button("Retry") { queue.retryNow(j.id) } }
                            Button(j.error == nil ? "Cancel upload" : "Discard", role: .destructive) { cancelling = j }
                        }
                        .font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.accent)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line))
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
            .padding(.bottom, 4)
            .confirmationDialog("Cancel this upload?", isPresented: Binding(get: { cancelling != nil },
                                                                           set: { if !$0 { cancelling = nil } }),
                                titleVisibility: .visible) {
                Button("Cancel upload", role: .destructive) {
                    if let j = cancelling { queue.discard(j.id) }
                    cancelling = nil
                }
                Button("Keep", role: .cancel) { cancelling = nil }
            } message: {
                Text("It won't be sent to the site. Your files stay on your phone.")
            }
        }
    }
}

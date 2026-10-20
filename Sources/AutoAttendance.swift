import SwiftUI

// MARK: - Auto attendance (Others > Auto Attendance)
//
// For subjects whose attendance is self-submitted. The user ticks a subject; the class time is read from the
// attendance page (and can be corrected), and a random 15-minute window inside it is chosen. iOS can't run the
// app at an exact time, so the schedule is sent to a small free server (Server/worker.js) that submits for you.
// Only "Section" subjects are listed (the public course pages would repeat the same subject).

// MARK: Parsing helpers

enum AutoAttParse {
    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    private static func groups(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }

    /// "Mon 5Oct 2026" -> 2026-10-05
    static func day(_ s: String) -> DateComponents? {
        guard let g = groups("(\\d{1,2})\\s*([A-Za-z]{3})[A-Za-z]*\\.?\\s*,?\\s*(\\d{4})", s).first,
              let d = Int(g[1]), let m = months[g[2].lowercased()], let y = Int(g[3]) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    /// "9AM - 11AM" / "9:30 am - 11:30 am" / "09:00 - 11:00" -> (540, 660), minutes since midnight
    static func times(_ s: String) -> (Int, Int)? {
        var found: [Int] = []
        for g in groups("(\\d{1,2})(?::(\\d{2}))?\\s*([AaPp])\\.?[Mm]", s) {
            guard let h = Int(g[1]) else { continue }
            let min = Int(g[2]) ?? 0
            found.append((h % 12) * 60 + min + (g[3].lowercased() == "p" ? 720 : 0))
        }
        if found.isEmpty {
            for g in groups("(\\d{1,2}):(\\d{2})", s) {
                if let h = Int(g[1]), let m = Int(g[2]) { found.append(h * 60 + m) }
            }
        }
        guard let a = found.first else { return nil }
        let b = found.count > 1 ? found[1] : a + 60
        return (a, b > a ? b : a + 60)
    }

    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

// MARK: Model

struct AutoSession: Codable, Hashable {
    var day: Double          // start of the session's day, seconds since 1970
    var startMin: Int        // class time, minutes since midnight
    var endMin: Int
}

struct AutoAttConfig: Codable, Identifiable, Equatable {
    var id: Int              // attendance activity (cmid)
    var courseId: Int
    var name: String
    var url: String
    var enabled: Bool
    var startMin: Int?       // the user's correction of the class time (nil = as found on the page)
    var endMin: Int?
    var windowStart: Int?    // where the 15-minute window begins (minutes since midnight)
    var detStart: Int?       // class time found on the attendance page
    var detEnd: Int?
    var sessions: [AutoSession]
    var past: Bool?          // the subject is listed under "past" on the site
}

struct AutoAttState: Codable {
    var master = false       // off by default
    var server = ""
    var key = ""
    var configs: [AutoAttConfig] = []
}

struct AutoJobStatus: Decodable, Identifiable {
    var key: String
    var cmid: Int
    var from: Double
    var to: Double
    var fireAt: Double
    var state: String        // pending / done / failed
    var msg: String?
    var id: String { key }
}

@MainActor
final class AutoAttendance: ObservableObject {
    static let shared = AutoAttendance()
    static let windowMinutes = 15
    private static let storeKey = "autoatt.v1"

    @Published var state: AutoAttState { didSet { save() } }
    @Published var jobs: [AutoJobStatus] = []
    @Published var message: String?
    @Published var loading = false
    @Published var noAttendance: [String] = []     // "Section" subjects with no attendance activity
    @Published var failedCourses: [String] = []    // subjects whose contents couldn't be loaded
    var userid = 0
    private var pushTask: Task<Void, Never>?

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.storeKey),
           let s = try? JSONDecoder().decode(AutoAttState.self, from: d) { state = s } else { state = AutoAttState() }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(state) { UserDefaults.standard.set(d, forKey: Self.storeKey) }
    }

    var enabledCount: Int { state.configs.filter { $0.enabled }.count }
    func config(_ id: Int) -> AutoAttConfig? { state.configs.first { $0.id == id } }

    private var base: URL? {
        var s = state.server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty && !s.lowercased().hasPrefix("http") { s = "https://" + s }
        return URL(string: s)
    }
    var serverReady: Bool { base != nil && !state.key.isEmpty }

    // MARK: edits (every change is sent to the server a moment later)

    func update(_ id: Int, _ change: (inout AutoAttConfig) -> Void) {
        guard let i = state.configs.firstIndex(where: { $0.id == id }) else { return }
        var c = state.configs[i]
        change(&c)
        state.configs[i] = c
        scheduleSync()
    }

    func setMaster(_ on: Bool) { state.master = on; scheduleSync() }

    func setEnabled(_ id: Int, _ on: Bool) {
        update(id) { c in
            c.enabled = on
            if on && c.windowStart == nil { c.windowStart = Self.randomWindowStart(in: Self.classTime(c)) }
        }
    }

    func shuffleWindow(_ id: Int) {
        update(id) { c in c.windowStart = Self.randomWindowStart(in: Self.classTime(c)) }
    }

    func resetTime(_ id: Int) {
        update(id) { c in c.startMin = nil; c.endMin = nil; c.windowStart = Self.randomWindowStart(in: Self.classTime(c)) }
    }

    /// Class time shown for the subject: the user's correction, else what the attendance page says, else 9:00-11:00
    static func classTime(_ c: AutoAttConfig) -> (Int, Int) {
        let s = c.startMin ?? c.detStart ?? 540
        var e = c.endMin ?? c.detEnd ?? (s + 120)
        if e <= s { e = s + 60 }
        return (s, e)
    }

    static func randomWindowStart(in t: (Int, Int)) -> Int {
        let hi = max(t.0, t.1 - windowMinutes)
        let steps = (hi - t.0) / 5
        return t.0 + Int.random(in: 0...max(0, steps)) * 5
    }

    /// The 15 minutes (or the whole class if it is shorter) inside which the server picks a random moment
    static func window(_ c: AutoAttConfig, _ s: AutoSession) -> (Int, Int) {
        let st = c.startMin ?? s.startMin
        var en = c.endMin ?? s.endMin
        if en <= st { en = st + 60 }
        let hi = max(st, en - windowMinutes)
        let ws = min(max(c.windowStart ?? st, st), hi)
        return (ws, min(ws + windowMinutes, en))
    }

    // MARK: finding the subjects and their class times

    func loadSubjects(_ courses: [Course], uid: Int, interactive: Bool) async {
        guard uid > 0 else { return }
        loading = true
        defer { loading = false }
        let api = MoodleAPI.shared

        // current + upcoming subjects, then past ones too (a lecturer may have put a subject under "past" by mistake)
        var list: [(Course, Bool)] = courses.map { ($0, false) }
        var have = Set(courses.map { $0.id })
        func fetch(_ cls: String) async -> [Course] {
            if OfflineSettings.enabled, let r = await OfflinePrefetch.courses(cls) { return r.courses }
            let r: CourseList? = try? await api.call("core_course_get_enrolled_courses_by_timeline_classification",
                                                     ["classification": cls, "limit": 0, "offset": 0, "sort": "fullname"])
            return r?.courses ?? []
        }
        for c in await fetch("past") {
            if have.insert(c.id).inserted { list.append((c, true)) }
        }

        var seen = Set<Int>()
        var noAtt: [String] = []
        var failed: [String] = []
        for (course, isPast) in list where course.isSectionCourse {      // subjects without "Section" are skipped
            var secs: [CourseSection]?
            if OfflineSettings.enabled { secs = await OfflinePrefetch.contents(course.id) }
            else { secs = try? await api.call("core_course_get_contents", ["courseid": course.id]) }
            guard let got = secs else { failed.append(course.subjectName); continue }
            let mods = got.flatMap { $0.modules }.filter { $0.modname == "attendance" && $0.uservisible != false }
            if mods.isEmpty { noAtt.append(course.subjectName) }
            for m in mods {
                seen.insert(m.id)
                let name = mods.count > 1 ? course.subjectName + " · " + m.name : course.subjectName
                if let i = state.configs.firstIndex(where: { $0.id == m.id }) {
                    state.configs[i].name = name
                    state.configs[i].url = m.url ?? state.configs[i].url
                    state.configs[i].past = isPast
                } else {
                    var c = AutoAttConfig(id: m.id, courseId: course.id, name: name, url: m.url ?? "",
                                          enabled: false, startMin: nil, endMin: nil, windowStart: nil,
                                          detStart: nil, detEnd: nil, sessions: [])
                    c.past = isPast
                    state.configs.append(c)
                }
            }
        }
        noAttendance = noAtt
        failedCourses = failed
        if !seen.isEmpty { state.configs = state.configs.filter { seen.contains($0.id) || $0.enabled } }
        state.configs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // class times: ticked subjects, and (when the screen is opened) the current ones; past ones only if ticked
        for c in state.configs where seen.contains(c.id) && (c.enabled || (c.past != true && (c.detStart == nil || interactive))) {
            await readPage(c.id, uid: uid, interactive: interactive)
        }
        scheduleSync()
    }

    /// Reads the attendance page: class time (most common one) and the sessions still to come
    func readPage(_ id: Int, uid: Int, interactive: Bool) async {
        guard let c = config(id), let page = URLComponents(string: c.url) else { return }
        let api = MoodleAPI.shared
        var summary: AttSummary?
        for v in ["5", "4"] {
            var comps = page
            var q = comps.queryItems ?? []
            q.removeAll { $0.name == "view" }
            q.append(URLQueryItem(name: "view", value: v))
            comps.queryItems = q
            guard let u = comps.url, let html = await api.fetchHTML(u, userid: uid, allowAutologin: interactive) else { break }
            let s = api.parseAttendance(html)
            if !s.records.isEmpty { summary = s; break }
        }
        guard let s = summary else { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var sessions: [AutoSession] = []
        var tally: [String: (Int, Int, Int)] = [:]      // "start-end" -> (start, end, how many)
        for r in s.records {
            guard let t = AutoAttParse.times(r.time.isEmpty ? r.date : r.time) else { continue }
            let k = "\(t.0)-\(t.1)"
            tally[k] = (t.0, t.1, (tally[k]?.2 ?? 0) + 1)
            guard r.kind == .pending, let dc = AutoAttParse.day(r.date), let d = cal.date(from: dc), d >= today else { continue }
            sessions.append(AutoSession(day: d.timeIntervalSince1970, startMin: t.0, endMin: t.1))
        }
        let common = tally.values.max { $0.2 < $1.2 }
        update(id) { c in
            c.sessions = sessions
            if let m = common { c.detStart = m.0; c.detEnd = m.1 }
            if c.enabled && c.windowStart == nil { c.windowStart = Self.randomWindowStart(in: Self.classTime(c)) }
        }
    }

    // MARK: server

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard let b = base else { throw APIError(message: "Enter the server address first") }
        var comps = URLComponents(url: b.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(state.key, forHTTPHeaderField: "x-key")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "content-type") }
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 { throw APIError(message: "The server rejected the access key") }
        if code >= 400 { throw APIError(message: "The server answered \(code)") }
        return d
    }

    func test() async {
        do { _ = try await request("ping"); message = "Connected to the server." }
        catch { message = "Couldn't reach the server: \(error.localizedDescription)" }
    }

    private func payload() -> [[String: Any]] {
        let cal = Calendar.current
        var out: [[String: Any]] = []
        for c in state.configs where c.enabled {
            for s in c.sessions {
                let day = Date(timeIntervalSince1970: s.day)
                let w = Self.window(c, s)
                func at(_ m: Int) -> Double {
                    (cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) ?? day).timeIntervalSince1970 * 1000
                }
                let from = at(w.0), to = at(w.1)
                guard to > Date().timeIntervalSince1970 * 1000 else { continue }    // already over
                out.append(["key": "\(c.id)-\(Int(s.day))", "cmid": c.id, "course": c.name, "url": c.url,
                            "from": from, "to": to])
            }
        }
        return out
    }

    func scheduleSync() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    func push() async {
        let uid = userid
        guard uid > 0, serverReady else { return }
        do {
            if !state.master || enabledCount == 0 {
                _ = try await request("sync", method: "DELETE", query: [URLQueryItem(name: "userid", value: String(uid))])
                jobs = []
                message = state.master ? "Tick a subject to start." : "Auto attendance is off."
                return
            }
            let body: [String: Any] = ["userid": uid, "site": Site.url.absoluteString,
                                       "token": MoodleAPI.shared.token,
                                       "privateToken": MoodleAPI.shared.privateToken ?? "",
                                       "jobs": payload()]
            _ = try await request("sync", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
            message = "Schedule sent to the server."
            await fetchStatus()
        } catch { message = "Couldn't update the server: \(error.localizedDescription)" }
    }

    func fetchStatus() async {
        guard userid > 0, serverReady, state.master else { return }
        struct R: Decodable { var jobs: [AutoJobStatus] }
        if let d = try? await request("status", query: [URLQueryItem(name: "userid", value: String(userid))]),
           let r = try? JSONDecoder().decode(R.self, from: d) {
            jobs = r.jobs.sorted { $0.from < $1.from }
        }
    }

    /// App opened: keep the sessions up to date and tell the server
    func refreshAndPush(userid uid: Int) async {
        userid = uid
        guard state.master, serverReady else { return }
        for c in state.configs where c.enabled { await readPage(c.id, uid: uid, interactive: false) }
        await push()
    }
}

// MARK: - Screen

struct AutoAttendanceView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var catalog: CourseCatalog
    @ObservedObject private var m = AutoAttendance.shared
    @State private var open: Int?

    private var uid: Int { app.site?.userid ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                masterCard
                if m.state.master {
                    serverCard
                    subjectsCard
                }
                if let msg = m.message {
                    Text(msg).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Auto Attendance")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { m.userid = uid; await reload() }
    }

    private func reload() async {
        m.userid = uid
        await catalog.loadIfNeeded()
        await m.loadSubjects(catalog.courses, uid: uid, interactive: true)
        await m.fetchStatus()
    }

    // ---- on / off ----

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { m.state.master }, set: { m.setMaster($0) })) {
                Text("Auto attendance").fontWeight(.semibold).foregroundColor(Theme.txt)
            }
            .tint(Theme.accent)
            Text("Submits your attendance for you in subjects where you have to press \"Submit attendance\" yourself. "
                 + "It happens at a random moment inside a 15-minute window you choose. Off by default.")
                .font(Theme.font(.caption)).foregroundColor(Theme.muted)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()
    }

    // ---- server ----

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SERVER").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            Text("iOS doesn't let apps run at an exact time, so a small free server does the submitting. "
                 + "Your sign-in token is sent to it, so only use a server you set up yourself (see Server/README in the project).")
                .font(Theme.font(.caption)).foregroundColor(Theme.muted)
            TextField("https://your-worker.workers.dev", text: Binding(get: { m.state.server }, set: { m.state.server = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .padding(10).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))
            SecureField("Access key", text: Binding(get: { m.state.key }, set: { m.state.key = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 18) {
                Button("Test connection") { Task { await m.test() } }
                Button("Send schedule now") { Task { m.userid = uid; await m.push() } }
            }
            .font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.accent)
            .disabled(!m.serverReady)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()
    }

    // ---- subjects ----

    @State private var showPast = false

    private var subjectsCard: some View {
        let current = m.state.configs.filter { $0.past != true }
        let past = m.state.configs.filter { $0.past == true }
        return VStack(alignment: .leading, spacing: 0) {
            Text("SUBJECTS").font(Theme.font(.caption)).foregroundColor(Theme.muted).padding(16)
            if m.state.configs.isEmpty {
                if m.loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(16) }
                else {
                    Text("No \"Section\" subject with an attendance activity was found.")
                        .font(Theme.font(.subheadline)).foregroundColor(Theme.muted).padding(16)
                }
            }
            ForEach(current) { c in row(c) }
            if !past.isEmpty {
                Button { withAnimation { showPast.toggle() } } label: {
                    HStack {
                        Text("Past subjects (\(past.count))").font(Theme.font(.subheadline).weight(.semibold))
                        Spacer()
                        Image(systemName: showPast ? "chevron.up" : "chevron.down").font(Theme.font(.caption))
                    }
                    .foregroundColor(Theme.accent).padding(14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
                if showPast { ForEach(past) { c in row(c) } }
            }
            if m.loading && !m.state.configs.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(12)
            }
            if !m.noAttendance.isEmpty || !m.failedCourses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !m.noAttendance.isEmpty {
                        Text("No attendance activity: " + m.noAttendance.joined(separator: ", "))
                    }
                    if !m.failedCourses.isEmpty {
                        Text("Couldn't load (pull down to retry): " + m.failedCourses.joined(separator: ", "))
                    }
                }
                .font(Theme.font(.caption2)).foregroundColor(Theme.muted)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).glowCard()
    }

    private func subtitle(_ c: AutoAttConfig) -> String {
        let t = AutoAttendance.classTime(c)
        var s = AutoAttParse.clock(t.0) + " - " + AutoAttParse.clock(t.1)
        if c.enabled { s += " · \(c.sessions.count) upcoming" }
        return s
    }

    private func row(_ c: AutoAttConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { m.setEnabled(c.id, !c.enabled); if !c.enabled { open = c.id } } label: {
                    Image(systemName: c.enabled ? "checkmark.square.fill" : "square")
                        .font(.title3).foregroundColor(c.enabled ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).fontWeight(.semibold).foregroundColor(Theme.txt)
                    Text(subtitle(c)).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
                Spacer(minLength: 0)
                if c.enabled {
                    Image(systemName: open == c.id ? "chevron.up" : "chevron.down")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if c.enabled { open = open == c.id ? nil : c.id } }

            if c.enabled && open == c.id { details(c) }
        }
        .padding(14)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }

    private func minutes(_ get: @escaping () -> Int, _ set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: get() / 60, minute: get() % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                set((c.hour ?? 0) * 60 + (c.minute ?? 0))
            })
    }

    @ViewBuilder private func details(_ c: AutoAttConfig) -> some View {
        let t = AutoAttendance.classTime(c)
        let w = AutoAttendance.window(c, c.sessions.first ?? AutoSession(day: 0, startMin: t.0, endMin: t.1))
        VStack(alignment: .leading, spacing: 12) {
            Text(c.detStart == nil ? "CLASS TIME (not found on the page, set it yourself)" : "CLASS TIME (from the attendance page)")
                .font(Theme.font(.caption)).foregroundColor(Theme.muted)
            HStack(spacing: 8) {
                Text("From").foregroundColor(Theme.txt)
                DatePicker("", selection: minutes({ t.0 }, { v in m.update(c.id) { $0.startMin = v; $0.endMin = max($0.endMin ?? t.1, v + 5) } }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer(minLength: 12)
                Text("To").foregroundColor(Theme.txt)
                DatePicker("", selection: minutes({ t.1 }, { v in m.update(c.id) { $0.endMin = v } }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            if c.startMin != nil || c.endMin != nil {
                Button("Use the time from the page") { m.resetTime(c.id) }
                    .font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.accent)
            }

            Text("SUBMITS AT A RANDOM MOMENT BETWEEN").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            HStack(spacing: 8) {
                Text("Window starts").foregroundColor(Theme.txt)
                Spacer(minLength: 12)
                DatePicker("", selection: minutes({ w.0 }, { v in m.update(c.id) { $0.windowStart = v } }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Button { m.shuffleWindow(c.id) } label: {
                    Image(systemName: "shuffle").foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Text("\(AutoAttParse.clock(w.0)) - \(AutoAttParse.clock(w.1))")
                .font(Theme.font(.title3).bold()).foregroundColor(Theme.accent)

            let mine = m.jobs.filter { $0.cmid == c.id }
            if !mine.isEmpty { jobList(mine) }
        }
    }

    private func jobList(_ list: [AutoJobStatus]) -> some View {
        let finished = Array(list.filter { $0.state != "pending" }.suffix(2))        // latest results first
        let upcoming = list.filter { $0.state == "pending" }
        let next = Array(upcoming.prefix(5))                                          // the nearest ones
        return VStack(alignment: .leading, spacing: 8) {
            Text("SCHEDULE").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            ForEach(finished + next) { j in
                let when = Date(timeIntervalSince1970: j.fireAt / 1000)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(when.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                            .font(Theme.font(.caption)).foregroundColor(Theme.txt)
                        if let msg = j.msg, !msg.isEmpty {
                            Text(msg).font(Theme.font(.caption2)).foregroundColor(Theme.muted)
                        }
                    }
                    Spacer()
                    StatusPill(text: j.state == "done" ? "Submitted" : (j.state == "failed" ? "Failed" : "Scheduled"),
                               color: j.state == "done" ? Tone.green : (j.state == "failed" ? Tone.red : Tone.amber))
                }
            }
            if upcoming.count > next.count {
                Text("+ \(upcoming.count - next.count) more later in the semester")
                    .font(Theme.font(.caption2)).foregroundColor(Theme.muted)
            }
        }
    }
}

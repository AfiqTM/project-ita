import SwiftUI

// MARK: - Daily Info
//
// A page next to "My courses" (swipe left) listing changes to classes: cancelled, online, another venue,
// rescheduled (and other short notices). Entries come from two places:
//   1. The announcements of every subject. Each new announcement is read by AI (Workers AI, through the same
//      free Cloudflare server as Auto Attendance: Server/worker.js, POST /classify). When the server isn't set up,
//      or doesn't answer, a built-in keyword reader (DailyRules) is used instead.
//   2. The user, with the + button (also used to correct anything that was detected wrongly).
// Everything is saved on the phone. Announcements are only re-read when they are new or were edited.

// MARK: Model

enum DailyKind: String, Codable, CaseIterable, Identifiable {
    case cancelled, online, venue, rescheduled, note
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cancelled: return "Cancelled"
        case .online: return "Online"
        case .venue: return "New venue"
        case .rescheduled: return "Rescheduled"
        case .note: return "Notice"
        }
    }
    var icon: String {
        switch self {
        case .cancelled: return "xmark.circle"
        case .online: return "video"
        case .venue: return "mappin.and.ellipse"
        case .rescheduled: return "calendar.badge.clock"
        case .note: return "info.circle"
        }
    }
    var color: Color {
        switch self {
        case .cancelled: return Color(red: 0.92, green: 0.38, blue: 0.38)
        case .online: return Color(red: 0.36, green: 0.66, blue: 0.96)
        case .venue: return Color(red: 0.96, green: 0.66, blue: 0.30)
        case .rescheduled: return Color(red: 0.72, green: 0.58, blue: 0.96)
        case .note: return Theme.accent
        }
    }
}

struct DailyEntry: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case announcement, manual }

    var id: String
    var kind: DailyKind
    var courseId: Int?
    var courseName: String?          // clean subject name, saved so old entries still read well
    var summary: String
    var classDate: Date?             // the day of the class this is about (start of day)
    var startMin: Int?               // its time, minutes since midnight
    var newDate: Date?               // rescheduled: the new day
    var newStartMin: Int?
    var venue: String?               // the new room / the online platform
    var notes: String?
    var source: Source
    var byAI: Bool?
    var discussionId: Int?           // the announcement it came from
    var announcementTitle: String?
    var postedAt: Date
    var edited: Bool?                // the user changed it: never overwritten by a new scan
    var hidden: Bool?                // the user removed it: stays removed
    var updated: Date

    /// Same announcement + same kind + same day always gives the same id, so a re-read never duplicates
    static func makeID(discussion: Int, kind: DailyKind, day: Date?) -> String {
        let d = day.map { String(Int($0.timeIntervalSince1970 / 86400)) } ?? "x"
        return "a\(discussion)-\(kind.rawValue)-\(d)"
    }

    /// The day that matters to the student: the new day when it was moved, otherwise the class day
    var relevantDate: Date? { newDate ?? classDate }

    func isPast(_ now: Date = Date()) -> Bool {
        if let d = relevantDate { return d < Calendar.current.startOfDay(for: now) }
        return now.timeIntervalSince(postedAt) > 7 * 86400
    }
}

struct DailyDraft {
    var kind: DailyKind
    var classDate: Date?
    var startMin: Int?
    var newDate: Date?
    var newStartMin: Int?
    var venue: String?
    var summary: String
}

// MARK: Store + announcement scanner

struct ForumInfo: Decodable {
    let id: Int
    let course: Int
    let type: String?
    let name: String?
}

@MainActor
final class DailyInfoStore: ObservableObject {
    static let shared = DailyInfoStore()
    private static let key = "dailyinfo.v1"
    private static let lookbackDays = 21          // announcements older than this are not read
    private static let keepDays = 60              // detected entries older than this are dropped
    private static let minGap: TimeInterval = 20 * 60

    @Published private(set) var entries: [DailyEntry] = []
    @Published private(set) var seen: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanNote: String?
    private var processed: [String: String] = [:]   // "d<discussion>" -> "<created>-<length>|ai" or "|rules"

    private struct Saved: Codable {
        var entries: [DailyEntry]
        var seen: [String]
        var processed: [String: String]
        var lastScan: Date?
    }

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            entries = s.entries
            seen = Set(s.seen)
            processed = s.processed
            lastScan = s.lastScan
        }
    }

    private func save() {
        let s = Saved(entries: entries, seen: Array(seen), processed: processed, lastScan: lastScan)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Detected changes that are still ahead and not looked at yet (badge on My courses)
    var unseenCount: Int {
        entries.filter { $0.hidden != true && $0.source == .announcement && !seen.contains($0.id) && !$0.isPast() }.count
    }
    var unseenIDs: Set<String> {
        Set(entries.filter { $0.hidden != true && !seen.contains($0.id) }.map { $0.id })
    }

    func markAllSeen() {
        let ids = entries.map { $0.id }
        guard !Set(ids).isSubset(of: seen) else { return }
        seen.formUnion(ids)
        save()
    }

    // MARK: edits

    func add(_ e: DailyEntry) {
        entries.append(e)
        seen.insert(e.id)
        save()
    }
    func update(_ e: DailyEntry) {
        guard let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
        var n = e
        n.edited = true
        n.updated = Date()
        entries[i] = n
        seen.insert(n.id)
        save()
    }
    /// Your own entries are deleted; detected ones are only hidden (so the next scan doesn't bring them back)
    func remove(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[i].source == .manual { entries.remove(at: i) }
        else { entries[i].hidden = true; entries[i].updated = Date() }
        save()
    }
    func unhide(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].hidden = false
        entries[i].updated = Date()
        save()
    }
    func clear() {
        entries = []; seen = []; processed = [:]; lastScan = nil; scanNote = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    // MARK: scan

    private struct Candidate {
        let course: Course
        let disc: Discussion
        let text: String
        let posted: Date
        let sig: String
    }

    /// Reads the newest announcement of every subject and adds what changed in class. Cheap when nothing is new.
    func scan(courses: [Course], force: Bool = false) async {
        guard !scanning, !courses.isEmpty else { return }
        if !force, let l = lastScan, Date().timeIntervalSince(l) < Self.minGap { return }
        scanning = true
        defer { scanning = false }
        let api = MoodleAPI.shared

        // 1. the announcements forum of every subject (type "news"; otherwise a forum named announcements/news)
        var forum: [Int: Int] = [:]
        let found: [ForumInfo]? = try? await api.call("mod_forum_get_forums_by_courses",
                                                      ["courseids": courses.map { $0.id }])
        for f in found ?? [] where f.type == "news" {
            if forum[f.course] == nil { forum[f.course] = f.id }
        }
        for c in courses where forum[c.id] == nil {
            let secs = await OfflinePrefetch.contents(c.id)
            let mods = (secs ?? []).flatMap { $0.modules }.filter { $0.modname == "forum" && $0.instance != nil }
            let pick = mods.first { m in
                let n = m.name.lowercased()
                return n.contains("announce") || n.contains("news")
            }
            if let id = pick?.instance { forum[c.id] = id }
        }

        // 2. new or edited announcements
        let since = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86400)
        let aiReady = DailyInfoAI.ready
        var cands: [Candidate] = []
        var reached = 0
        for c in courses {
            guard let fid = forum[c.id] else { continue }
            guard let r: DiscResp = try? await api.call("mod_forum_get_forum_discussions",
                                                        ["forumid": fid, "perpage": 20]) else { continue }
            reached += 1
            for d in r.discussions {
                guard let created = d.created, created > 0 else { continue }
                let posted = Date(timeIntervalSince1970: TimeInterval(created))
                guard posted >= since else { continue }
                let text = (d.message ?? "").plainText
                let sig = "\(created)-\(text.count)"
                let mark = processed["d\(d.discussion)"]
                let upToDate = mark.map { $0.hasPrefix(sig + "|") && !($0.hasSuffix("|rules") && aiReady) } ?? false
                if !upToDate { cands.append(Candidate(course: c, disc: d, text: text, posted: posted, sig: sig)) }
            }
        }

        // 3. AI first (when the server is set up), the built-in reader for anything the AI didn't answer
        var ai: [String: [DailyDraft]] = [:]
        if aiReady && !cands.isEmpty {
            ai = await DailyInfoAI.classify(cands.map {
                DailyInfoAI.Item(id: "d\($0.disc.discussion)", course: $0.course.subjectName, posted: $0.posted,
                                 title: $0.disc.name ?? $0.disc.subject ?? "", text: $0.text)
            })
        }
        for cand in cands {
            let key = "d\(cand.disc.discussion)"
            let byAI = ai[key] != nil
            let drafts = ai[key] ?? DailyRules.classify(title: cand.disc.name ?? cand.disc.subject ?? "",
                                                        text: cand.text, posted: cand.posted)
            apply(drafts, course: cand.course, disc: cand.disc, posted: cand.posted, byAI: byAI)
            processed[key] = cand.sig + (byAI ? "|ai" : "|rules")
        }

        // 4. tidy up and remember
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86400)
        entries.removeAll { e in
            e.source == .announcement && (e.relevantDate ?? e.postedAt) < cutoff
        }
        if reached > 0 { lastScan = Date() }
        if reached == 0 { scanNote = "Couldn't read the announcements. Showing what was saved." }
        else if aiReady && !cands.isEmpty && ai.isEmpty { scanNote = "The AI server didn't answer, so the basic reader was used." }
        else { scanNote = nil }
        save()
    }

    /// Replaces what was detected from one announcement. Entries the user edited or hid are left alone.
    private func apply(_ drafts: [DailyDraft], course: Course, disc: Discussion, posted: Date, byAI: Bool) {
        let did = disc.discussion
        var keep: [DailyEntry] = []
        for e in entries {
            if e.discussionId == did && e.source == .announcement && e.edited != true && e.hidden != true { continue }
            keep.append(e)
        }
        for d in drafts {
            let id = DailyEntry.makeID(discussion: did, kind: d.kind, day: d.classDate ?? d.newDate)
            if keep.contains(where: { $0.id == id }) { continue }
            keep.append(DailyEntry(
                id: id, kind: d.kind, courseId: course.id, courseName: course.subjectName, summary: d.summary,
                classDate: d.classDate, startMin: d.startMin, newDate: d.newDate, newStartMin: d.newStartMin,
                venue: d.venue, notes: nil, source: .announcement, byAI: byAI, discussionId: did,
                announcementTitle: disc.name ?? disc.subject, postedAt: posted, edited: nil, hidden: nil,
                updated: Date()))
        }
        entries = keep
    }
}

// MARK: - AI (through the user's own Cloudflare server)

enum DailyInfoAI {
    struct Item {
        let id: String
        let course: String
        let posted: Date
        let title: String
        let text: String
    }

    private struct Out: Decodable {
        var kind: String?
        var classDate: String?
        var startTime: String?
        var newDate: String?
        var newStartTime: String?
        var venue: String?
        var summary: String?
    }
    private struct Reply: Decodable {
        var results: [String: [Out]]?
        var failed: [String]?
    }

    @MainActor static var ready: Bool { AutoAttendance.shared.serverReady }

    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = f
        return d
    }

    /// Items the server answered for (an empty list means "no schedule change in this announcement").
    /// Items it couldn't answer are left out, so the caller falls back to the built-in reader.
    @MainActor
    static func classify(_ items: [Item]) async -> [String: [DailyDraft]] {
        let auto = AutoAttendance.shared
        guard auto.serverReady, let base = auto.serverURL else { return [:] }
        let key = auto.state.key
        var all: [String: [DailyDraft]] = [:]
        var i = 0
        while i < items.count {
            let chunk = Array(items[i..<min(i + 4, items.count)])   // a few at a time: keeps each request short
            i += 4
            guard let reply = await request(base: base, key: key, items: chunk) else { continue }
            for it in chunk {
                guard let outs = reply.results?[it.id] else { continue }
                all[it.id] = outs.compactMap { draft($0, posted: it.posted) }
            }
        }
        return all
    }

    private static func request(base: URL, key: String, items: [Item]) async -> Reply? {
        var req = URLRequest(url: base.appendingPathComponent("classify"))
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(key, forHTTPHeaderField: "x-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let day = formatter("yyyy-MM-dd EEEE")
        let stamp = formatter("yyyy-MM-dd EEEE HH:mm")
        let body: [String: Any] = [
            "today": day.string(from: Date()),
            "items": items.map { it -> [String: Any] in
                ["id": it.id, "course": it.course, "posted": stamp.string(from: it.posted),
                 "title": it.title, "text": String(it.text.prefix(3000))]
            },
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: data)
    }

    private static func draft(_ o: Out, posted: Date) -> DailyDraft? {
        guard let k = o.kind, let kind = DailyKind(rawValue: k) else { return nil }
        let df = formatter("yyyy-MM-dd")
        let cal = Calendar.current
        // a date far from the announcement is almost certainly a misreading: drop it
        func day(_ s: String?) -> Date? {
            guard let s, !s.isEmpty, let d = df.date(from: s) else { return nil }
            let dd = cal.startOfDay(for: d)
            guard dd >= posted.addingTimeInterval(-14 * 86400), dd <= posted.addingTimeInterval(200 * 86400) else { return nil }
            return dd
        }
        func minutes(_ s: String?) -> Int? {
            guard let s, !s.isEmpty else { return nil }
            let p = s.split(separator: ":").compactMap { Int($0) }
            guard p.count >= 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
            return p[0] * 60 + p[1]
        }
        func clean(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let cd = day(o.classDate), nd = day(o.newDate)
        let summary = clean(o.summary).map { String($0.prefix(200)) } ?? kind.title
        return DailyDraft(kind: kind, classDate: cd, startMin: minutes(o.startTime), newDate: nd,
                          newStartMin: minutes(o.newStartTime), venue: clean(o.venue).map { String($0.prefix(80)) },
                          summary: summary)
    }
}

// MARK: - Built-in reader (used when the AI server isn't set up or doesn't answer)
//
// Looks at each sentence: is it about a class / lecture / lab / test, and does it say cancelled / moved /
// online / another room? English and the common Malay words. Dates such as "26 Oct", "26/10", "Monday",
// "tomorrow" are worked out from the day the announcement was posted.

enum DailyRules {
    private static let classWords = #"\b(class|classes|lecture|lectures|tutorial|tutorials|tut|lab|labs|session|sessions|kelas|kuliah|makmal|test|quiz|exam|midterm|presentation|meeting|slot)\b"#
    private static let cancelWords = #"cancel|no class|no lecture|no tutorial|no lab|will not be held|won't be held|not be conducted|\bis off\b|\bare off\b|dibatal|tiada kelas|tiada kuliah|ditiadakan"#
    private static let reschedWords = #"reschedul|postpone|brought forward|put forward|moved to|shifted to|moved from|replacement|make[- ]?up|\bganti|ditunda|ditangguh|dijadualkan semula|dipindahkan ke|change of (date|time)|new (date|time)"#
    private static let onlineWords = #"\bonline\b|\bzoom\b|google meet|\bgmeet\b|microsoft teams|ms teams|\bwebex\b|\bvirtual\b|atas talian|dalam talian|secara maya"#
    private static let venueVerbs = #"venue|location|tempat|moved|changed|shifted|relocat|pindah|tukar|bertukar"#
    private static let toAfterVerb = #"(moved|shifted|postponed|rescheduled|brought forward|put forward|ditunda|dipindahkan|dijadualkan semula)[^.\n]{0,40}?\b(to|until|ke|kepada)\b"#

    private static let months = "january|januari|jan|february|februari|feb|march|mac|mar|april|apr|may|mei|june|jun|july|julai|jul|august|ogos|aug|september|sept|sep|october|oktober|okt|oct|november|nov|december|disember|dec|dis"
    private static let weekdays = "monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sunday|isnin|selasa|rabu|khamis|jumaat|sabtu|ahad"
    private static let monthNumber: [String: Int] = ["jan": 1, "feb": 2, "mar": 3, "mac": 3, "apr": 4, "may": 5, "mei": 5,
        "jun": 6, "jul": 7, "aug": 8, "ogo": 8, "sep": 9, "oct": 10, "okt": 10, "nov": 11, "dec": 12, "dis": 12]
    private static let weekdayNumber: [String: Int] = ["mon": 2, "isn": 2, "tue": 3, "sel": 3, "wed": 4, "rab": 4,
        "thu": 5, "kha": 5, "fri": 6, "jum": 6, "sat": 7, "sab": 7, "sun": 1, "aha": 1]

    // MARK: entry point

    static func classify(title: String, text: String, posted: Date) -> [DailyDraft] {
        let whole = [title, text].filter { !$0.isEmpty }.joined(separator: ". ")
        let fallback = dates(in: whole, ref: posted)
        var out: [DailyDraft] = []
        var keys = Set<String>()
        for s in sentences(whole) {
            guard let (kind, venue) = detect(s) else { continue }
            var ds = dates(in: s, ref: posted)
            if ds.isEmpty, let f = fallback.first { ds = [f] }
            let start = AutoAttParse.times(s)?.0
            var d = DailyDraft(kind: kind, classDate: nil, startMin: nil, newDate: nil, newStartMin: nil,
                               venue: nil, summary: tidy(s))
            if kind == .rescheduled {
                if ds.count >= 2 { d.classDate = ds[0]; d.newDate = ds[1]; d.newStartMin = start }
                else if let one = ds.first {
                    if has(s, toAfterVerb) { d.newDate = one; d.newStartMin = start }
                    else { d.classDate = one; d.startMin = start }
                }
            } else {
                d.classDate = ds.first
                d.startMin = start
                if kind == .venue { d.venue = venue }
            }
            let key = "\(kind.rawValue)|\(d.classDate.map { String(Int($0.timeIntervalSince1970)) } ?? "x")|\(d.newDate.map { String(Int($0.timeIntervalSince1970)) } ?? "x")"
            if keys.insert(key).inserted { out.append(d) }
        }
        return Array(out.prefix(4))
    }

    // MARK: sentences and kinds

    private static func sentences(_ s: String) -> [String] {
        var t = s.replacingOccurrences(of: "([.!?;])\\s+", with: "$1\u{1}", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s*\\n+\\s*", with: "\u{1}", options: .regularExpression)
        return t.components(separatedBy: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func tidy(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 160 ? String(t.prefix(157)) + "…" : t
    }

    private static func has(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func detect(_ s: String) -> (DailyKind, String?)? {
        guard has(s, classWords) else { return nil }
        if has(s, cancelWords) { return (.cancelled, nil) }
        if has(s, venueVerbs), let v = venue(in: s) { return (.venue, v) }
        if has(s, reschedWords) { return (.rescheduled, nil) }
        if has(s, onlineWords) { return (.online, nil) }
        return nil
    }

    private static func venue(in s: String) -> String? {
        let room = #"\b((?:lecture\s+hall|dewan(?:\s+kuliah)?|bilik(?:\s+kuliah)?|room|rm\.?|lab|makmal|hall|auditorium|block|blok)\s*(?:[0-9][A-Za-z0-9\-/]*(?:\.\d+)?|[A-Za-z]\b))"#
        if let g = groups(room, s).first, g.count > 1 {
            let v = g[1].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        let generic = #"(?:venue|location|tempat)\s*(?:is|:|-|will be|has been changed to|changed to|moved to)?\s*([^.\n;,]{2,40})"#
        if let g = groups(generic, s).first, g.count > 1 {
            let v = g[1].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: dates

    private static func groups(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }

    private struct Found { let loc: Int; let len: Int; let date: Date }

    private static func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        let cal = Calendar.current
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year == y && c.month == m && c.day == d) ? date : nil   // rejects 30 Feb
    }

    /// Day + month with an optional year: no year means the nearest such day that isn't long past
    private static func resolve(day: Int, month: Int, year: Int?, ref: Date) -> Date? {
        let cal = Calendar.current
        if let y = year { return make(y < 100 ? 2000 + y : y, month, day) }
        let y = cal.component(.year, from: ref)
        guard let a = make(y, month, day) else { return nil }
        if a < ref.addingTimeInterval(-30 * 86400), let b = make(y + 1, month, day) { return b }
        return a
    }

    /// Every date mentioned, in reading order (no repeats)
    static func dates(in s: String, ref: Date) -> [Date] {
        let cal = Calendar.current
        let ns = s as NSString
        let today = cal.startOfDay(for: ref)
        var explicit: [Found] = []

        func add(_ pattern: String, _ build: ([String]) -> Date?) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let g = (0..<m.numberOfRanges).map { i in
                    m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
                }
                if let d = build(g) { explicit.append(Found(loc: m.range.location, len: m.range.length, date: d)) }
            }
        }
        func month(_ w: String) -> Int? { monthNumber[String(w.lowercased().prefix(3))] }

        // 26 Oct, 26th October 2026
        add(#"\b(\d{1,2})(?:st|nd|rd|th)?\s*(?:of\s+)?("# + months + #")\b\.?,?\s*(\d{4})?"#) { g in
            guard let d = Int(g[1]), let m = month(g[2]) else { return nil }
            return resolve(day: d, month: m, year: Int(g[3]), ref: ref)
        }
        // Oct 26, October 26th, 2026
        add(#"\b("# + months + #")\b\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?![:\d])(?:,?\s*(\d{4}))?"#) { g in
            guard let m = month(g[1]), let d = Int(g[2]) else { return nil }
            return resolve(day: d, month: m, year: Int(g[3]), ref: ref)
        }
        // 26/10, 26/10/2026 (day first) and 26-10-2026
        add(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#) { g in
            guard let d = Int(g[1]), let m = Int(g[2]) else { return nil }
            return resolve(day: d, month: m, year: Int(g[3]), ref: ref)
        }
        add(#"\b(\d{1,2})-(\d{1,2})-(\d{2,4})\b"#) { g in
            guard let d = Int(g[1]), let m = Int(g[2]), let y = Int(g[3]) else { return nil }
            return resolve(day: d, month: m, year: y, ref: ref)
        }

        var found = explicit
        func overlapsExplicit(_ loc: Int, _ len: Int) -> Bool {
            // "Monday 26 Oct" / "26 Oct (Monday)": the weekday is part of that date, not a second one
            explicit.contains { e in
                (e.loc >= loc + len && e.loc - (loc + len) <= 4) || (loc >= e.loc + e.len && loc - (e.loc + e.len) <= 4)
                    || (loc >= e.loc && loc < e.loc + e.len)
            }
        }

        // today / tomorrow / the day after
        if let re = try? NSRegularExpression(pattern: #"\b(day after tomorrow|lusa|tomorrow|tmrw|esok|today|tonight|hari ini)\b"#,
                                             options: [.caseInsensitive]) {
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let w = ns.substring(with: m.range(at: 1)).lowercased()
                let add = (w == "day after tomorrow" || w == "lusa") ? 2 : (["tomorrow", "tmrw", "esok"].contains(w) ? 1 : 0)
                if let d = cal.date(byAdding: .day, value: add, to: today) {
                    found.append(Found(loc: m.range.location, len: m.range.length, date: d))
                }
            }
        }
        // Monday, next Thursday: the nearest such day from the announcement on
        if let re = try? NSRegularExpression(pattern: #"\b(?:(?:next|this|coming|upcoming)\s+)?("# + weekdays + #")\b"#,
                                             options: [.caseInsensitive]) {
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                if overlapsExplicit(m.range.location, m.range.length) { continue }
                let w = String(ns.substring(with: m.range(at: 1)).lowercased().prefix(3))
                guard let target = weekdayNumber[w] else { continue }
                let now = cal.component(.weekday, from: today)
                let ahead = (target - now + 7) % 7
                if let d = cal.date(byAdding: .day, value: ahead, to: today) {
                    found.append(Found(loc: m.range.location, len: m.range.length, date: d))
                }
            }
        }

        var out: [Date] = []
        for f in found.sorted(by: { $0.loc < $1.loc }) where !out.contains(f.date) { out.append(f.date) }
        return out
    }
}

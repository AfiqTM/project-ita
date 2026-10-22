import AppIntents
import Foundation
import SwiftUI

// MARK: - Siri / Shortcuts
//
// Ask Siri (or add them in the Shortcuts app):
//   "When is my assignment due in iTa'leem"              next assignments (all subjects)
//   "When is my <subject> assignment in iTa'leem"         next assignment of one subject
//   "When is something due in iTa'leem"                   searches deadlines and events by name ("quiz 2", "lab report")
//   "Who is my <subject> lecturer in iTa'leem"
//   "What section am I in for <subject> in iTa'leem"
//   "How many classes can I miss in <subject> in iTa'leem"   absences left before attendance drops below 80%
//   "Is <subject> class cancelled in iTa'leem"            reads the subject's announcements; Siri asks for the day
//   "Add a to-do in iTa'leem"                             Siri asks what and (optionally) which subject / when
//   "Open <subject> submission in iTa'leem"               opens the assignment page
// A subject can be said as its name, its short form (DES, SE, ENT ...) or its code (BICS 1306).
// iOS 16+. The intents run inside the app process, with the saved login (Keychain).

// MARK: Subjects

struct SiriCourse: Codable, Hashable {
    var id: Int
    var fullname: String
    var shortname: String?

    var course: Course {
        Course(id: id, fullname: fullname, shortname: shortname, progress: nil, isfavourite: nil, hidden: nil, courseimage: nil)
    }
    var name: String { course.subjectName }
    var code: String { course.headerCode }

    private static let skip: Set<String> = ["and", "of", "the", "to", "for", "in", "a", "an", "on", "with"]
    private var words: [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    /// "Digital & Embedded Systems" -> "des"
    var acronym: String {
        words.filter { !Self.skip.contains($0) }.compactMap { $0.first }.map(String.init).joined()
    }

    private static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// How well a spoken / typed subject matches this one (0 = not at all)
    func score(_ query: String) -> Int {
        let q = Self.squash(query)
        guard !q.isEmpty else { return 0 }
        let nameKey = Self.squash(name), codeKey = Self.squash(code), shortKey = Self.squash(shortname ?? "")
        let acr = acronym
        if q == acr || q == nameKey || q == codeKey || q == shortKey { return 100 }
        if nameKey.contains(q) { return 80 }
        if q.count >= 2, acr.hasPrefix(q) { return 70 }
        if words.contains(where: { $0.hasPrefix(q) }) { return 60 }
        if q.count >= 3, codeKey.contains(q) || shortKey.contains(q) { return 60 }
        if q.count >= 3 {                                   // letters in order, e.g. "emb sys"
            var i = nameKey.startIndex
            for ch in q { guard let f = nameKey[i...].firstIndex(of: ch) else { return 0 }; i = nameKey.index(after: f) }
            return 40
        }
        return 0
    }
}

enum SiriError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn, noSubject(String), failed(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Open iTa'leem and sign in first."
        case .noSubject(let s): return "I couldn't find a subject called \(s)."
        case .failed(let m): return "\(m)"
        }
    }
}

enum SiriCatalog {
    private static let key = "siri.courses.v1"

    static func cached() -> [SiriCourse] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let l = try? JSONDecoder().decode([SiriCourse].self, from: d) else { return [] }
        return l
    }

    /// Loads the saved login when the app was started by Siri (nothing else has set it up yet)
    static func prepare() throws {
        if MoodleAPI.shared.token.isEmpty {
            guard let s = Keychain.load() else { throw SiriError.notSignedIn }
            MoodleAPI.shared.token = s.token
            MoodleAPI.shared.privateToken = s.privateToken
        }
    }

    /// Subjects being taken now, plus past ones (as the other screens do); remembered for Siri's subject list
    @discardableResult
    static func refresh() async -> [SiriCourse] {
        guard (try? prepare()) != nil else { return cached() }
        var out: [SiriCourse] = []
        var seen = Set<Int>()
        for cls in ["inprogress", "past"] {
            if let r: CourseList = try? await MoodleAPI.shared.call(
                "core_course_get_enrolled_courses_by_timeline_classification",
                ["classification": cls, "limit": 0, "offset": 0, "sort": "fullname"]) {
                for c in r.courses where seen.insert(c.id).inserted {
                    out.append(SiriCourse(id: c.id, fullname: c.fullname.decodedEntities, shortname: c.shortname))
                }
            }
        }
        guard !out.isEmpty else { return cached() }
        if let d = try? JSONEncoder().encode(out) { UserDefaults.standard.set(d, forKey: key) }
        iTaleemShortcuts.updateAppShortcutParameters()
        return out
    }

    static func all() async -> [SiriCourse] {
        let c = cached()
        return c.isEmpty ? await refresh() : c
    }

    static func course(_ id: Int) async -> SiriCourse? { await all().first { $0.id == id } }

    static func best(_ query: String) async -> SiriCourse? {
        let list = await all()
        return list.map { ($0, $0.score(query)) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }
}

struct CourseEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Subject"
    static var defaultQuery = CourseQuery()

    var id: Int
    var name: String
    var code: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(code)")
    }
    init(_ c: SiriCourse) { id = c.id; name = c.name; code = c.code }
}

struct CourseQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [CourseEntity] {
        await SiriCatalog.all().filter { identifiers.contains($0.id) }.map(CourseEntity.init)
    }
    func entities(matching string: String) async throws -> [CourseEntity] {
        await SiriCatalog.all().map { ($0, $0.score(string)) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.map { CourseEntity($0.0) }
    }
    func suggestedEntities() async throws -> [CourseEntity] {
        await SiriCatalog.all().map(CourseEntity.init)
    }
}

// MARK: Data

enum SiriData {
    static func fmtDay(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
    static func fmtWhen(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
    }

    static func userId() async throws -> Int {
        let saved = UserDefaults.standard.integer(forKey: "siri.uid")
        if saved > 0 { return saved }
        let s = try await MoodleAPI.shared.siteInfo()
        UserDefaults.standard.set(s.userid, forKey: "siri.uid")
        return s.userid
    }

    /// Upcoming things that are not done yet (assignments, quizzes ...), soonest first. From now on.
    static func events(courseId: Int? = nil) async -> [TLEvent] {
        let r: EventsResp? = try? await MoodleAPI.shared.call(
            "core_calendar_get_action_events_by_timesort",
            ["timesortfrom": Int(Date().timeIntervalSince1970), "limitnum": 50])
        var l = (r?.events ?? []).sorted { $0.timesort < $1.timesort }
        if let courseId { l = l.filter { $0.course?.id == courseId } }
        return l
    }

    static func contents(_ courseId: Int) async -> [CourseSection] {
        (try? await MoodleAPI.shared.call("core_course_get_contents", ["courseid": courseId])) ?? []
    }

    /// The course's announcements: the forum named announcements / news, otherwise its first forum
    static func announcements(_ courseId: Int, limit: Int = 25) async -> [Discussion] {
        let forums = await contents(courseId).flatMap { $0.modules }.filter { $0.modname == "forum" && $0.instance != nil }
        let pick = forums.first { m in
            let n = m.name.lowercased()
            return n.contains("announce") || n.contains("news")
        } ?? forums.first
        guard let fid = pick?.instance,
              let d: DiscResp = try? await MoodleAPI.shared.call("mod_forum_get_forum_discussions",
                                                                 ["forumid": fid, "perpage": limit]) else { return [] }
        return d.discussions
    }

    /// The assignment to hand in next for a subject: soonest not-yet-submitted one (due dates not passed first);
    /// otherwise the most recent one.
    static func nextAssignment(_ courseId: Int) async throws -> Assign? {
        let uid = try await userId()
        guard let r: AssignResp = try? await MoodleAPI.shared.call("mod_assign_get_assignments", ["courseids": [courseId]]),
              let list = r.courses.first?.assignments, !list.isEmpty else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        var open: [Assign] = []
        for a in list {
            let s: StatusResp? = try? await MoodleAPI.shared.call("mod_assign_get_submission_status",
                                                                  ["assignid": a.id, "userid": uid])
            let st = s?.lastattempt?.submission?.status ?? ""
            let graded = s?.lastattempt?.gradingstatus == "graded"
            if st != "submitted" && !graded { open.append(a) }
        }
        let future = open.filter { ($0.duedate ?? 0) > now }.sorted { ($0.duedate ?? 0) < ($1.duedate ?? 0) }
        if let f = future.first { return f }
        if let o = open.max(by: { ($0.duedate ?? 0) < ($1.duedate ?? 0) }) { return o }
        return list.max { ($0.duedate ?? 0) < ($1.duedate ?? 0) }
    }
}

// MARK: Deadlines

private func deadlineSentence(_ e: TLEvent) -> String {
    let when = SiriData.fmtWhen(Date(timeIntervalSince1970: TimeInterval(e.timesort)))
    let subj = e.course.map { c in SiriCourse(id: c.id, fullname: c.fullname.decodedEntities, shortname: nil).name } ?? ""
    let forSubj = subj.isEmpty ? "" : " for " + subj
    return e.name.decodedEntities + forSubj + " is due " + when
}

private func deadlineAnswer(courseId: Int?, subjectName: String?) async -> String {
    let all = await SiriData.events(courseId: courseId)
    let assigns = all.filter { ($0.modulename ?? "") == "assign" }
    let l = assigns.isEmpty ? all : assigns
    guard !l.isEmpty else {
        return subjectName.map { "You have nothing due for \($0)." } ?? "You have nothing due."
    }
    var s = "Next up: " + deadlineSentence(l[0]) + "."
    if l.count > 1 { s += " Then " + deadlineSentence(l[1]) + "." }
    if l.count > 2 && courseId == nil { s += " And " + deadlineSentence(l[2]) + "." }
    return s
}

struct NextAssignmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Next assignment"
    static var description = IntentDescription("When your next assignments are due.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        let text = await deadlineAnswer(courseId: nil, subjectName: nil)
        return .result(dialog: "\(text)")
    }
}

struct SubjectAssignmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Subject assignment"
    static var description = IntentDescription("When the next assignment of a subject is due.")
    @Parameter(title: "Subject") var subject: CourseEntity
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        let text = await deadlineAnswer(courseId: subject.id, subjectName: subject.name)
        return .result(dialog: "\(text)")
    }
}

struct WhenIsIntent: AppIntent {
    static var title: LocalizedStringResource = "When is something"
    static var description = IntentDescription("Find the date of an assignment, quiz or other event by name.")
    @Parameter(title: "What", requestValueDialog: "What are you looking for? For example: quiz 2 or lab report.")
    var query: String
    @Parameter(title: "Subject") var subject: CourseEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        let stop: Set<String> = ["when", "whens", "when's", "is", "the", "my", "a", "an", "due", "date", "for", "of", "what", "time", "i", "have"]
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) }
        let courses = await SiriCatalog.all()
        let events = await SiriData.events(courseId: subject?.id)
        let hits = events.filter { e in
            let name = e.name.decodedEntities.lowercased()
            let course = courses.first { $0.id == e.course?.id }
            return tokens.allSatisfy { t in name.contains(t) || (course?.score(t) ?? 0) >= 70 }
        }
        if tokens.isEmpty || hits.isEmpty {
            return .result(dialog: "I couldn't find anything called \(query) coming up.")
        }
        var s = deadlineSentence(hits[0]) + "."
        if hits.count > 1 { s += " Also " + deadlineSentence(hits[1]) + "." }
        return .result(dialog: "\(s)")
    }
}

// MARK: Lecturer / section

struct LecturerIntent: AppIntent {
    static var title: LocalizedStringResource = "Lecturer"
    static var description = IntentDescription("Who the lecturer of a subject is.")
    @Parameter(title: "Subject") var subject: CourseEntity
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        let l = CourseLecturers()
        await l.load(courseId: subject.id)
        let names = l.people.map(\.displayName)
        guard !names.isEmpty else { return .result(dialog: "I couldn't find the lecturer for \(subject.name).") }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return .result(dialog: "Your lecturer for \(subject.name) is \(list).")
    }
}

struct SectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Section"
    static var description = IntentDescription("Which section you are in for a subject.")
    @Parameter(title: "Subject") var subject: CourseEntity
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        guard let c = await SiriCatalog.course(subject.id), let sec = c.course.sectionLabel else {
            return .result(dialog: "I couldn't find a section number for \(subject.name).")
        }
        return .result(dialog: "You're in \(sec) for \(subject.name).")
    }
}

// MARK: Attendance

struct AbsencesLeftIntent: AppIntent {
    static var title: LocalizedStringResource = "Absences left"
    static var description = IntentDescription("How many more classes you can miss before attendance drops below 80%.")
    @Parameter(title: "Subject") var subject: CourseEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        let uid = try await SiriData.userId()
        let api = MoodleAPI.shared
        let secs = await SiriData.contents(subject.id)
        guard let m = secs.flatMap({ $0.modules }).first(where: { $0.modname == "attendance" && $0.uservisible != false }) else {
            return .result(dialog: "\(subject.name) has no attendance record.")
        }
        var summary: AttSummary?
        if let html = await api.attendanceMobileContent(cmid: m.id, courseId: subject.id, userid: uid) {
            var s = api.parseAttendance(html)
            s.fillMax()
            summary = s
        }
        if summary?.absencesLeft() == nil, let saved: AttSaved = OfflineCache.loadObject(AttSaved.key(m.id)) {
            var s = saved.summary          // the copy saved for offline use
            s.fillMax()
            summary = s
        }
        guard let s = summary, let k = s.absencesLeft() else {
            return .result(dialog: "I couldn't read the attendance for \(subject.name) right now.")
        }
        let limit = Int(AttSummary.limitPercent)
        let maxText = s.maxPercent.map { " Your best possible attendance is \($0)." } ?? ""
        if k < 0 {
            return .result(dialog: "Even if you attend every class from now on, \(subject.name) can't reach \(limit) percent.\(maxText)")
        }
        if k == 0 {
            return .result(dialog: "You can't miss any more \(subject.name) classes without going under \(limit) percent.\(maxText)")
        }
        return .result(dialog: "You can miss \(k) more \(subject.name) class\(k == 1 ? "" : "es") before going under \(limit) percent.\(maxText)")
    }
}

// MARK: Class cancelled / moved (reads the announcements)

private enum Announce {
    static let keywords = ["cancel", "no class", "no lecture", "replacement", "replaced", "online", "postpone", "reschedul",
                           "moved", "venue", "change", "switch", "instead", "extra class", "make-up", "make up", "walkover"]

    /// Does the text mention this day (2 Oct, 2nd October, October 2, 2/10, 10/2, Wednesday ...)?
    static func mentions(_ d: Date, in text: String) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.day, .month, .weekday], from: d)
        guard let day = c.day, let month = c.month, let wd = c.weekday else { return false }
        let months = [["january", "jan"], ["february", "feb"], ["march", "mar"], ["april", "apr"], ["may"], ["june", "jun"],
                      ["july", "jul"], ["august", "aug"], ["september", "sept", "sep"], ["october", "oct"],
                      ["november", "nov"], ["december", "dec"]]
        let mon = months[month - 1].joined(separator: "|")
        let dd = "(?<![0-9])0?\(day)(?![0-9])"
        let mm = "0?\(month)"
        let patterns = [
            "\(dd)(st|nd|rd|th)?[\\s\\-]*(of\\s+)?(\(mon))\\b",
            "\\b(\(mon))\\.?\\s*\(dd)",
            "\(dd)\\s*[/\\-.]\\s*\(mm)(?![0-9])",
            "(?<![0-9])\(mm)\\s*[/\\-.]\\s*\(dd)"
        ]
        let t = text.lowercased()
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return true }
        }
        return false
    }

    static func weekdayMentioned(_ d: Date, in text: String) -> Bool {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: d) - 1
        let t = text.lowercased()
        return t.contains(names[wd]) || t.contains(String(names[wd].prefix(3)) + " ") || t.contains(String(names[wd].prefix(3)) + ",")
    }

    static func hasKeyword(_ text: String) -> Bool {
        let t = text.lowercased()
        return keywords.contains { t.contains($0) }
    }

    static func snippet(_ text: String, near: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let low = flat.lowercased()
        var at = low.startIndex
        for k in near { if let r = low.range(of: k) { at = r.lowerBound; break } }
        let start = flat.index(at, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: 220, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
    }

    static func text(_ d: Discussion) -> String {
        ((d.name ?? d.subject ?? "") + ". " + (d.message ?? "").plainText)
    }
}

struct ClassStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Class changes"
    static var description = IntentDescription("Checks the announcements of a subject for cancelled, online or moved classes.")
    @Parameter(title: "Subject") var subject: CourseEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        let list = await SiriData.announcements(subject.id)
        guard !list.isEmpty else { return .result(dialog: "I couldn't read any \(subject.name) announcements.") }
        let cutoff = Int(Date().addingTimeInterval(-21 * 86400).timeIntervalSince1970)
        let hits = list.filter { ($0.created ?? 0) >= cutoff && Announce.hasKeyword(Announce.text($0)) }
        guard let d = hits.first else {
            return .result(dialog: "No recent \(subject.name) announcement mentions a cancelled, online or moved class.")
        }
        let posted = d.created.map { " (posted " + SiriData.fmtDay(Date(timeIntervalSince1970: TimeInterval($0))) + ")" } ?? ""
        return .result(dialog: "\(subject.name) announcement\(posted): \(Announce.snippet(Announce.text(d), near: Announce.keywords))")
    }
}

struct ClassStatusOnDateIntent: AppIntent {
    static var title: LocalizedStringResource = "Class on a date"
    static var description = IntentDescription("Checks the announcements of a subject for a given day: cancelled, online, new venue or rescheduled.")
    @Parameter(title: "Subject") var subject: CourseEntity
    @Parameter(title: "Date", requestValueDialog: "Which day?") var date: Date

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        let list = await SiriData.announcements(subject.id, limit: 40)
        guard !list.isEmpty else { return .result(dialog: "I couldn't read any \(subject.name) announcements.") }
        let day = SiriData.fmtDay(date)
        // 1) an announcement that names the day; 2) one that names the weekday and was posted within 10 days before it
        var hits = list.filter { Announce.mentions(date, in: Announce.text($0)) }
        if hits.isEmpty {
            hits = list.filter { d in
                guard let c = d.created else { return false }
                let posted = Date(timeIntervalSince1970: TimeInterval(c))
                let gap = date.timeIntervalSince(posted)
                return gap > -86400 && gap < 10 * 86400
                    && Announce.weekdayMentioned(date, in: Announce.text(d)) && Announce.hasKeyword(Announce.text(d))
            }
        }
        hits.sort { Announce.hasKeyword(Announce.text($0)) && !Announce.hasKeyword(Announce.text($1)) }
        guard let d = hits.first else {
            return .result(dialog: "I didn't find an announcement about \(subject.name) on \(day), so as far as the announcements say, nothing has changed.")
        }
        let t = Announce.text(d)
        let near = Announce.keywords.filter { t.lowercased().contains($0) }
        let verdict = Announce.hasKeyword(t) ? "There is an announcement that may affect it" : "It is mentioned in an announcement"
        return .result(dialog: "\(verdict) for \(subject.name) on \(day): \(Announce.snippet(t, near: near.isEmpty ? [] : near))")
    }
}

// MARK: To-do

struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to-do"
    static var description = IntentDescription("Adds something to your to-do list.")
    @Parameter(title: "What", requestValueDialog: "What do you want to add?") var what: String
    @Parameter(title: "Subject") var subject: CourseEntity?
    @Parameter(title: "Due") var due: Date?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let when = due ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                of: Date().addingTimeInterval(86400)) ?? Date().addingTimeInterval(86400)
        let item = TodoItem(title: what, kind: .work, courseId: subject?.id, courseName: subject?.name, due: when)
        TodoStore.shared.add(item)
        let tail = due == nil ? "" : ", due " + SiriData.fmtWhen(when)
        let forSubject = subject.map { " for " + $0.name } ?? ""
        return .result(dialog: "Added \(what)\(forSubject) to your to-do list\(tail).")
    }
}

// MARK: Open the submission page

/// Screens that Siri asks the app to open
@MainActor
final class SiriRouter: ObservableObject {
    static let shared = SiriRouter()
    struct Target: Identifiable { let id = UUID(); let courseId: Int; let module: Module }
    @Published var submission: Target?
}

struct OpenSubmissionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open submission"
    static var description = IntentDescription("Opens the submission page of a subject's next assignment.")
    static var openAppWhenRun = true
    @Parameter(title: "Subject") var subject: CourseEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try SiriCatalog.prepare()
        guard let a = try await SiriData.nextAssignment(subject.id) else {
            return .result(dialog: "\(subject.name) has no assignments.")
        }
        let module = AssignItem(a: a, courseId: subject.id, courseName: subject.name, status: nil).module
        SiriRouter.shared.submission = SiriRouter.Target(courseId: subject.id, module: module)
        return .result(dialog: "Opening \(a.name) for \(subject.name).")
    }
}

// MARK: Phrases

struct iTaleemShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextAssignmentIntent(),
                    phrases: ["When is my assignment due in \(.applicationName)",
                              "When is my next assignment in \(.applicationName)",
                              "What is due in \(.applicationName)",
                              "When is the assignment submission in \(.applicationName)"],
                    shortTitle: "Next assignment", systemImageName: "checklist")
        AppShortcut(intent: SubjectAssignmentIntent(),
                    phrases: ["When is my \(\.$subject) assignment in \(.applicationName)",
                              "When is the \(\.$subject) assignment due in \(.applicationName)",
                              "When do I submit \(\.$subject) in \(.applicationName)"],
                    shortTitle: "Subject assignment", systemImageName: "doc.text")
        AppShortcut(intent: WhenIsIntent(),
                    phrases: ["When is something due in \(.applicationName)",
                              "Look up a date in \(.applicationName)",
                              "When is it in \(.applicationName)"],
                    shortTitle: "When is…", systemImageName: "calendar")
        AppShortcut(intent: LecturerIntent(),
                    phrases: ["Who is my \(\.$subject) lecturer in \(.applicationName)",
                              "Who teaches \(\.$subject) in \(.applicationName)",
                              "What is the lecturer name for \(\.$subject) in \(.applicationName)"],
                    shortTitle: "Lecturer", systemImageName: "person.crop.square")
        AppShortcut(intent: SectionIntent(),
                    phrases: ["What section am I in for \(\.$subject) in \(.applicationName)",
                              "Which section is \(\.$subject) in \(.applicationName)"],
                    shortTitle: "Section", systemImageName: "number")
        AppShortcut(intent: AbsencesLeftIntent(),
                    phrases: ["How many classes can I miss in \(\.$subject) in \(.applicationName)",
                              "How many times can I be absent for \(\.$subject) in \(.applicationName)",
                              "How is my \(\.$subject) attendance in \(.applicationName)"],
                    shortTitle: "Absences left", systemImageName: "checkmark.circle")
        AppShortcut(intent: ClassStatusIntent(),
                    phrases: ["Is \(\.$subject) class cancelled in \(.applicationName)",
                              "Is there any change to \(\.$subject) class in \(.applicationName)"],
                    shortTitle: "Class changes", systemImageName: "megaphone")
        AppShortcut(intent: ClassStatusOnDateIntent(),
                    phrases: ["Is \(\.$subject) class cancelled on a date in \(.applicationName)",
                              "Check \(\.$subject) class on a day in \(.applicationName)"],
                    shortTitle: "Class on a date", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: AddTodoIntent(),
                    phrases: ["Add a to-do in \(.applicationName)",
                              "Add to my to-do list in \(.applicationName)",
                              "Remind me to do something in \(.applicationName)"],
                    shortTitle: "Add to-do", systemImageName: "plus.circle")
        AppShortcut(intent: OpenSubmissionIntent(),
                    phrases: ["Open \(\.$subject) submission in \(.applicationName)",
                              "Open the \(\.$subject) assignment in \(.applicationName)"],
                    shortTitle: "Open submission", systemImageName: "tray.and.arrow.up")
    }
}

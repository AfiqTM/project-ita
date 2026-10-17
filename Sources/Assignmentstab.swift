import SwiftUI

// MARK: - Shared colours / pill

// Status colours of the chosen theme (bright on the dark themes, deeper shades on the light one)
enum Tone {
    static var green: Color { Color(hex: ThemeStore.shared.palette.green) }
    static var red: Color { Color(hex: ThemeStore.shared.palette.red) }
    static var amber: Color { Color(hex: ThemeStore.shared.palette.amber) }
    static var blue: Color { Color(hex: ThemeStore.shared.palette.blue) }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Theme.font(.caption).weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16))
            .clipShape(Capsule())
    }
}

// MARK: - Filters

enum AssignFilter: String, CaseIterable, Identifiable {
    case todo = "To do"
    case overdue = "Overdue"
    case submitted = "Submitted"
    case all = "All"
    var id: String { rawValue }
}

// How far ahead the "To do" list (and the tab badge) looks
enum AssignRange: String, CaseIterable, Identifiable {
    case week = "7d", month = "30d", threeMonths = "3m", sixMonths = "6m"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        }
    }

    // Unix time of the end of the window, counted from now
    func end(from now: Date = Date()) -> Int {
        let comp: (Calendar.Component, Int)
        switch self {
        case .week: comp = (.day, 7)
        case .month: comp = (.day, 30)
        case .threeMonths: comp = (.month, 3)
        case .sixMonths: comp = (.month, 6)
        }
        let d = Calendar.current.date(byAdding: comp.0, value: comp.1, to: now) ?? now
        return Int(d.timeIntervalSince1970)
    }
}

// MARK: - Model

struct AssignItem: Identifiable {
    let a: Assign
    let courseId: Int
    let courseName: String
    let status: StatusResp?

    var id: Int { a.id }
    var due: Int { a.duedate ?? 0 }
    var subStatus: String { status?.lastattempt?.submission?.status ?? "" }
    var grade: String { (status?.feedback?.gradefordisplay ?? "").plainText }
    var graded: Bool { status?.lastattempt?.gradingstatus == "graded" || !grade.isEmpty }
    var submitted: Bool { subStatus == "submitted" || graded }

    func overdue(_ now: Int) -> Bool { !submitted && due > 0 && due < now }

    // To do = not submitted, not overdue, due date inside the chosen window.
    // Items without a due date only appear under "All".
    func matches(_ f: AssignFilter, now: Int, limit: Int) -> Bool {
        switch f {
        case .todo: return !submitted && !overdue(now) && due > 0 && due <= limit
        case .overdue: return overdue(now)
        case .submitted: return submitted
        case .all: return true
        }
    }

    // AssignmentView expects a course Module, so build one from the assignment.
    var module: Module {
        var c = URLComponents(url: Site.url.appendingPathComponent("mod/assign/view.php"),
                              resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "id", value: String(a.cmid))]
        return Module(id: a.cmid, name: a.name, modname: "assign", instance: a.id,
                      url: c?.url?.absoluteString, description: nil, uservisible: true, contents: nil)
    }
}

// Owned by RootView so the tab badge is correct from launch, before the tab is ever opened.
@MainActor
final class AssignmentsModel: ObservableObject {
    @Published var items: [AssignItem] = []
    @Published var loading = true
    @Published var error: String?
    @Published var filter: AssignFilter = .todo
    @Published var range: AssignRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "assignRange") }
    }
    private var running = false

    init() {
        range = AssignRange(rawValue: UserDefaults.standard.string(forKey: "assignRange") ?? "") ?? .month
    }

    private var now: Int { Int(Date().timeIntervalSince1970) }

    func count(_ f: AssignFilter) -> Int {
        let lim = range.end()
        let n = now
        return items.filter { $0.matches(f, now: n, limit: lim) }.count
    }

    // Number shown on the tab icon: to-do assignments due inside the selected range
    var badgeCount: Int { count(.todo) }

    func list(_ f: AssignFilter) -> [AssignItem] {
        let lim = range.end()
        let n = now
        let l = items.filter { $0.matches(f, now: n, limit: lim) }
        switch f {
        case .todo, .all:
            // soonest first, no-due-date last
            return l.sorted { x, y in
                if x.due == 0 { return false }
                if y.due == 0 { return true }
                return x.due < y.due
            }
        case .overdue, .submitted:
            return l.sorted { $0.due > $1.due }
        }
    }

    // One call for the course list, one for every assignment, then one status call per assignment (8 at a time).
    // Only the first load shows a spinner; later refreshes update quietly.
    func load(uid: Int) async {
        guard !running else { return }
        running = true
        defer { running = false }
        if items.isEmpty { loading = true }
        error = nil
        do {
            // Courses in progress, plus past ones: lecturers sometimes mark a running course as past.
            let cl: CourseList = try await MoodleAPI.shared.call(
                "core_course_get_enrolled_courses_by_timeline_classification",
                ["classification": "inprogress", "limit": 0, "offset": 0, "sort": "fullname"])
            let past: CourseList? = try? await MoodleAPI.shared.call(
                "core_course_get_enrolled_courses_by_timeline_classification",
                ["classification": "past", "limit": 0, "offset": 0, "sort": "fullname"])
            var seen = Set<Int>()
            let courses = (cl.courses + (past?.courses ?? [])).filter { seen.insert($0.id).inserted }
            let names = Dictionary(courses.map { ($0.id, $0.fullname) }, uniquingKeysWith: { a, _ in a })
            guard !courses.isEmpty else { items = []; loading = false; return }

            let r: AssignResp = try await MoodleAPI.shared.call(
                "mod_assign_get_assignments", ["courseids": courses.map { $0.id }])
            var base: [(Assign, Int, String)] = []
            for c in r.courses {
                for a in c.assignments { base.append((a, c.id, names[c.id] ?? "")) }
            }

            var out: [AssignItem] = []
            var start = 0
            while start < base.count {
                let chunk = Array(base[start..<min(start + 8, base.count)])
                start += 8
                let part = await withTaskGroup(of: AssignItem.self) { g -> [AssignItem] in
                    for (a, cid, cn) in chunk {
                        g.addTask {
                            let s: StatusResp? = try? await MoodleAPI.shared.call(
                                "mod_assign_get_submission_status", ["assignid": a.id, "userid": uid])
                            return AssignItem(a: a, courseId: cid, courseName: cn, status: s)
                        }
                    }
                    var res: [AssignItem] = []
                    for await i in g { res.append(i) }
                    return res
                }
                out.append(contentsOf: part)
            }
            items = out
            if !OfflineCache.cacheOnly { NotificationManager.shared.scheduleAssignments(out) }   // not from the first paint: statuses may be missing
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }
}

// MARK: - Assignments tab

struct AssignmentsTabView: View {
    @ObservedObject var model: AssignmentsModel
    @EnvironmentObject var app: AppState

    private var uid: Int { app.site?.userid ?? 0 }
    private var now: Int { Int(Date().timeIntervalSince1970) }

    private var groups: [(String, [AssignItem])] {
        var out: [(String, [AssignItem])] = []
        for i in model.list(model.filter) {
            let title = i.due == 0
                ? "No due date"
                : Date(timeIntervalSince1970: TimeInterval(i.due)).formatted(date: .complete, time: .omitted)
            if let last = out.last, last.0 == title {
                out[out.count - 1].1.append(i)
            } else {
                out.append((title, [i]))
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Assignments").foregroundColor(Theme.txt).textGlow(radius: 4).pixelHeading(16, normal: .title3.weight(.semibold), pt: 20)
                filterBar
                rangeBar
                if let error = model.error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }

                ForEach(groups, id: \.0) { title, list in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(Theme.font(.footnote).weight(.semibold)).foregroundColor(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(list) { i in row(i) }
                        }
                        .glowCard()
                    }
                }

                if model.loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                else if groups.isEmpty && model.error == nil {
                    Text(model.filter == .todo
                         ? "Nothing due in the next \(model.range.title)."
                         : "Nothing here.")
                        .foregroundColor(Theme.muted)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.load(uid: uid) }
        .onAppear { Task { await model.load(uid: uid) } }   // also refreshes after coming back from an assignment
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(AssignFilter.allCases) { f in
                    Button { model.filter = f } label: {
                        HStack(spacing: 6) {
                            Text(f.rawValue)
                                .fontWeight(model.filter == f ? .semibold : .regular)
                                .foregroundColor(model.filter == f ? Theme.accent : Theme.txt)
                            let n = model.count(f)
                            if (f == .todo || f == .overdue) && n > 0 {
                                Text("\(n)")
                                    .font(Theme.font(.caption2).bold())
                                    .foregroundColor(Theme.onAccent)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(f == .overdue ? Tone.red : Theme.accent)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    // Chooses how far ahead to look; drives the To do list and the number on the tab icon
    private var rangeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DUE WITHIN").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AssignRange.allCases) { r in
                        Button { model.range = r } label: {
                            Text(r.title)
                                .font(Theme.font(.footnote).weight(.semibold))
                                .foregroundColor(model.range == r ? Theme.onAccent : Theme.txt)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(model.range == r ? Theme.accent : Theme.surface2)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func pill(_ i: AssignItem) -> some View {
        if i.graded {
            StatusPill(text: i.grade.isEmpty ? "Graded" : "Graded: \(i.grade)", color: Tone.blue)
        } else if i.submitted {
            StatusPill(text: "Submitted", color: Tone.green)
        } else if i.overdue(now) {
            StatusPill(text: "Overdue", color: Tone.red)
        } else if i.subStatus == "draft" {
            StatusPill(text: "Draft", color: Tone.amber)
        } else {
            StatusPill(text: "Not submitted", color: Theme.muted)
        }
    }

    private func row(_ i: AssignItem) -> some View {
        NavigationLink {
            AssignmentView(courseId: i.courseId, module: i.module)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(i.a.name).foregroundColor(Theme.txt).fontWeight(.medium)
                        .multilineTextAlignment(.leading)
                    Text(i.courseName).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                        .multilineTextAlignment(.leading)
                    if i.due > 0 {
                        Text("Due " + fmt(i.due, time: true)).font(Theme.font(.caption)).foregroundColor(Theme.accent)
                    }
                }
                Spacer()
                pill(i)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
        }
        .buttonStyle(.plain)
    }
}

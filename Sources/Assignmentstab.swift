import SwiftUI

// MARK: - Shared colours / pill

enum Tone {
    static let green = Color(hex: 0x5fbf7f)
    static let red = Color(hex: 0xe0605a)
    static let amber = Color(hex: 0xe0b050)
    static let blue = Color(hex: 0x5a9be0)
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16))
            .clipShape(Capsule())
    }
}

// MARK: - Model

enum AssignFilter: String, CaseIterable, Identifiable {
    case todo = "To do"
    case overdue = "Overdue"
    case submitted = "Submitted"
    case all = "All"
    var id: String { rawValue }
}

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

    func matches(_ f: AssignFilter, _ now: Int) -> Bool {
        switch f {
        case .todo: return !submitted && !overdue(now)
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

// MARK: - Assignments tab

struct AssignmentsTabView: View {
    @EnvironmentObject var app: AppState
    @State private var filter: AssignFilter = .todo
    @State private var items: [AssignItem] = []
    @State private var loading = true
    @State private var error: String?

    private var now: Int { Int(Date().timeIntervalSince1970) }

    private func count(_ f: AssignFilter) -> Int { items.filter { $0.matches(f, now) }.count }

    private var shown: [AssignItem] {
        let list = items.filter { $0.matches(filter, now) }
        switch filter {
        case .todo, .all:
            // soonest first, no-due-date last
            return list.sorted { l, r in
                if l.due == 0 { return false }
                if r.due == 0 { return true }
                return l.due < r.due
            }
        case .overdue, .submitted:
            return list.sorted { $0.due > $1.due }
        }
    }

    private var groups: [(String, [AssignItem])] {
        var out: [(String, [AssignItem])] = []
        for i in shown {
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
                Text("Assignments").font(.title3.weight(.semibold)).foregroundColor(Theme.txt)
                filterBar
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }

                ForEach(groups, id: \.0) { title, list in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(.footnote.weight(.semibold)).foregroundColor(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(list) { i in row(i) }
                        }
                        .glowCard()
                    }
                }

                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                else if shown.isEmpty && error == nil {
                    Text("Nothing here.").foregroundColor(Theme.muted)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(AssignFilter.allCases) { f in
                    Button { filter = f } label: {
                        HStack(spacing: 6) {
                            Text(f.rawValue)
                                .fontWeight(filter == f ? .semibold : .regular)
                                .foregroundColor(filter == f ? Theme.accent : Theme.txt)
                            let n = count(f)
                            if (f == .todo || f == .overdue) && n > 0 {
                                Text("\(n)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.black)
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
                    Text(i.courseName).font(.caption).foregroundColor(Theme.muted)
                        .multilineTextAlignment(.leading)
                    if i.due > 0 {
                        Text("Due " + fmt(i.due, time: true)).font(.caption).foregroundColor(Theme.accent)
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

    // One call for the course list, one for every assignment, then one status call per assignment (8 at a time).
    private func load() async {
        loading = true; error = nil
        do {
            let cl: CourseList = try await MoodleAPI.shared.call(
                "core_course_get_enrolled_courses_by_timeline_classification",
                ["classification": "inprogress", "limit": 0, "offset": 0, "sort": "fullname"])
            let names = Dictionary(cl.courses.map { ($0.id, $0.fullname) }, uniquingKeysWith: { a, _ in a })
            guard !cl.courses.isEmpty else { items = []; loading = false; return }

            let r: AssignResp = try await MoodleAPI.shared.call(
                "mod_assign_get_assignments", ["courseids": cl.courses.map { $0.id }])
            var base: [(Assign, Int, String)] = []
            for c in r.courses {
                for a in c.assignments { base.append((a, c.id, names[c.id] ?? "")) }
            }

            let uid = app.site?.userid ?? 0
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
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }
}

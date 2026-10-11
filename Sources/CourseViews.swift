import SwiftUI
import WebKit

// MARK: - Course detail (Course / Participants / Grades tabs)

enum CourseTab: String, CaseIterable, Identifiable {
    case course = "Course", participants = "Participants", grades = "Grades"
    var id: String { rawValue }
}

struct CourseDetailView: View {
    let course: Course
    @State private var tab: CourseTab = .course

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 26) {
                ForEach(CourseTab.allCases) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .fontWeight(tab == t ? .semibold : .regular)
                            .foregroundColor(tab == t ? Theme.accent : Color(white: 0.66))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            switch tab {
            case .course: CourseContentView(courseId: course.id)
            case .participants: ParticipantsView(courseId: course.id)
            case .grades: GradesView(courseId: course.id)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(course.shortname ?? course.fullname)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CourseContentView: View {
    let courseId: Int
    @State private var sections: [CourseSection] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                ForEach(sections.filter { !$0.modules.isEmpty || !$0.name.isEmpty }) { s in
                    SectionCard(courseId: courseId, section: s)
                }
                if loading { ProgressView().tint(Theme.accent) }
            }
            .padding(16)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            sections = try await MoodleAPI.shared.call("core_course_get_contents", ["courseid": courseId])
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

struct SectionCard: View {
    let courseId: Int
    let section: CourseSection
    @State private var open = true

    var body: some View {
        VStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack {
                    Text(section.name.isEmpty ? "General" : section.name)
                        .fontWeight(.semibold).foregroundColor(Theme.txt)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").foregroundColor(Theme.accent)
                }
                .padding(14)
                .background(Theme.titleBar)
            }
            if open {
                ForEach(section.modules.filter { $0.uservisible != false }) { m in
                    ModuleRow(courseId: courseId, module: m)
                }
            }
        }
        .glowCard()
    }
}

struct ModuleRow: View {
    let courseId: Int
    let module: Module

    private var icon: String {
        switch module.modname {
        case "assign": return "square.and.pencil"
        case "forum": return "bubble.left.and.bubble.right"
        case "resource": return "doc"
        case "folder": return "folder"
        case "url": return "link"
        case "quiz": return "questionmark.circle"
        case "page": return "doc.text"
        case "attendance": return "checkmark.circle"
        default: return "square.grid.2x2"
        }
    }

    private var web: some View {
        WebActivityView(url: URL(string: module.url ?? "") ?? Site.url, title: module.name)
    }

    @ViewBuilder private var destination: some View {
        switch module.modname {
        case "forum":
            ForumView(forumId: module.instance ?? 0, title: module.name)
        case "assign":
            AssignmentView(courseId: courseId, module: module)
        case "folder":
            FolderView(module: module)
        case "resource":
            if let f = module.contents?.first?.fileurl, let u = MoodleAPI.shared.fileURL(f) {
                FileViewer(url: u, title: module.name)
            } else { web }
        default:
            web
        }
    }

    var body: some View {
        if module.modname == "label" {
            if let d = module.description?.plainText, !d.isEmpty {
                Text(d).font(.subheadline).foregroundColor(Theme.muted)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NavigationLink { destination } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 24)
                    Text(module.name).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Files / folders

struct FolderView: View {
    let module: Module
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(module.contents ?? []) { c in
                    if let f = c.fileurl, let u = MoodleAPI.shared.fileURL(f) {
                        NavigationLink { FileViewer(url: u, title: c.filename ?? "File") } label: {
                            HStack {
                                Image(systemName: "doc").foregroundColor(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.filename ?? "File").foregroundColor(Theme.txt)
                                    Text(fmt(c.timemodified, time: false)).font(.caption).foregroundColor(Theme.muted)
                                }
                                Spacer()
                            }
                            .padding(14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .glowCard().padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FileViewer: View {
    let url: URL
    let title: String
    var body: some View {
        WebView(url: url, theme: false)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Forums

struct ForumView: View {
    let forumId: Int
    let title: String
    @State private var items: [Discussion] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                ForEach(items) { d in
                    NavigationLink { PostsView(discussionId: d.discussion, title: d.name ?? d.subject ?? title) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.name ?? d.subject ?? "Discussion")
                                .fontWeight(.semibold).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                            Text("\(d.userfullname ?? "") · \(fmt(d.created, time: false))")
                                .font(.caption).foregroundColor(Theme.muted)
                            if let m = d.message?.plainText, !m.isEmpty {
                                Text(m).font(.subheadline).foregroundColor(Theme.muted).lineLimit(4)
                                    .multilineTextAlignment(.leading)
                            }
                            if let r = d.numreplies, r > 0 {
                                Text("\(r) replies").font(.caption).foregroundColor(Theme.accent)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .glowCard(radius: 12)
                    }
                    .buttonStyle(.plain)
                }
                if loading { ProgressView().tint(Theme.accent) }
                else if items.isEmpty && error == nil { Text("No discussions yet.").foregroundColor(Theme.muted) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let r: DiscResp = try await MoodleAPI.shared.call(
                "mod_forum_get_forum_discussions", ["forumid": forumId, "perpage": 50])
            items = r.discussions
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

struct PostsView: View {
    let discussionId: Int
    let title: String
    @State private var posts: [Post] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                ForEach(posts) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(p.subject ?? "").fontWeight(.semibold).foregroundColor(Theme.txt)
                        Text("\(p.author?.fullname ?? "") · \(fmt(p.timecreated))")
                            .font(.caption).foregroundColor(Theme.muted)
                        Text((p.message ?? "").plainText).foregroundColor(Theme.txt)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .glowCard(radius: 12)
                }
                if loading { ProgressView().tint(Theme.accent) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let r: PostsResp = try await MoodleAPI.shared.call(
                    "mod_forum_get_discussion_posts", ["discussionid": discussionId])
                posts = r.posts
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            loading = false
        }
    }
}

// MARK: - Assignment

struct AssignmentView: View {
    let courseId: Int
    let module: Module
    @EnvironmentObject var app: AppState
    @State private var assign: Assign?
    @State private var status: StatusResp?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                if let a = assign {
                    VStack(alignment: .leading, spacing: 0) {
                        infoRow("Due", fmt(a.duedate))
                        infoRow("Submission status", (status?.lastattempt?.submission?.status ?? "-").capitalized)
                        infoRow("Grading status", (status?.lastattempt?.gradingstatus ?? "-")
                                    .replacingOccurrences(of: "notgraded", with: "Not graded").capitalized)
                        if let g = status?.feedback?.gradefordisplay, !g.isEmpty {
                            infoRow("Grade", g.plainText)
                        }
                    }
                    .glowCard()

                    if let intro = a.intro?.plainText, !intro.isEmpty {
                        Text(intro).foregroundColor(Theme.txt)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .glowCard()
                    }
                }
                NavigationLink {
                    WebActivityView(url: URL(string: module.url ?? "") ?? Site.url, title: module.name)
                } label: {
                    Text("Open submission page")
                        .fontWeight(.semibold).foregroundColor(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(Theme.muted).frame(width: 130, alignment: .leading)
            Text(v).foregroundColor(Theme.txt)
            Spacer()
        }
        .padding(14)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    private func load() async {
        do {
            let r: AssignResp = try await MoodleAPI.shared.call(
                "mod_assign_get_assignments", ["courseids": [courseId]])
            assign = r.courses.first?.assignments.first { $0.cmid == module.id }
            if let a = assign {
                let s: StatusResp? = try? await MoodleAPI.shared.call(
                    "mod_assign_get_submission_status",
                    ["assignid": a.id, "userid": app.site?.userid ?? 0])
                status = s
            }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

// MARK: - Grades

struct GradesView: View {
    let courseId: Int
    @EnvironmentObject var app: AppState
    @State private var items: [GradeItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted).padding() }
                ForEach(items) { g in
                    HStack(alignment: .top) {
                        Text(g.itemname ?? "Course total").foregroundColor(Theme.txt)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(g.gradeformatted ?? "-").foregroundColor(Theme.accent).fontWeight(.semibold)
                            if let r = g.rangeformatted { Text(r).font(.caption).foregroundColor(Theme.muted) }
                        }
                    }
                    .padding(14)
                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                }
                if loading { ProgressView().tint(Theme.accent).padding() }
            }
            .glowCard().padding(16)
        }
        .task {
            do {
                let r: GradesResp = try await MoodleAPI.shared.call(
                    "gradereport_user_get_grade_items",
                    ["courseid": courseId, "userid": app.site?.userid ?? 0])
                items = r.usergrades.first?.gradeitems ?? []
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            loading = false
        }
    }
}

// MARK: - Participants

struct ParticipantsView: View {
    let courseId: Int
    @State private var people: [Person] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    private var shown: [Person] {
        let p = people.sorted { $0.fullname < $1.fullname }
        return query.isEmpty ? p : p.filter { $0.fullname.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TextField("Search participants", text: $query)
                    .foregroundColor(Theme.txt).padding(12)
                    .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                VStack(spacing: 0) {
                    ForEach(shown) { p in
                        HStack(spacing: 12) {
                            AsyncImage(url: p.profileimageurlsmall.flatMap { MoodleAPI.shared.fileURL($0) }) { i in
                                i.resizable().scaledToFill()
                            } placeholder: { Theme.surface2 }
                            .frame(width: 34, height: 34).clipShape(Circle())
                            Text(p.fullname).foregroundColor(Theme.txt)
                            Spacer()
                        }
                        .padding(12)
                        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                    }
                }
                .glowCard()
                if loading { ProgressView().tint(Theme.accent) }
            }
            .padding(16)
        }
        .task {
            do { people = try await MoodleAPI.shared.call("core_enrol_get_enrolled_users", ["courseid": courseId]) }
            catch {
                if !(error is CancellationError) {
                    self.error = "Participant list isn't available for this course (\(error.localizedDescription))"
                }
            }
            loading = false
        }
    }
}

// MARK: - Web (any other activity: quizzes, pages, attendance, ...)

struct WebView: UIViewRepresentable {
    let url: URL
    var theme = true

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        if theme {
            cfg.userContentController.addUserScript(
                WKUserScript(source: WebTheme.js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.backgroundColor = .black
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WebActivityView: View {
    let url: URL
    let title: String
    @EnvironmentObject var app: AppState
    @State private var resolved: URL?

    var body: some View {
        Group {
            if let r = resolved { WebView(url: r) }
            else { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            resolved = await MoodleAPI.shared.autologin(url, userid: app.site?.userid ?? 0)
        }
    }
}

import SwiftUI
import WebKit

// MARK: - Course detail (Course / Participants / Grades tabs)

enum CourseTab: String, CaseIterable, Identifiable {
    case course = "Course", participants = "Participants", drive = "My Drive", todo = "To-Do", grades = "Grades"
    var id: String { rawValue }
}

struct CourseDetailView: View {
    let course: Course
    @EnvironmentObject var todos: TodoStore
    @EnvironmentObject var drive: DriveLibrary
    @EnvironmentObject var teamsLib: TeamsLibrary
    @State private var tab: CourseTab = .course
    @State private var pickingTeam = false

    private var todoCount: Int { todos.count(for: course.id) }
    private var driveCount: Int { drive.files(for: course.id).count }

    // My Drive / To-Do only appear when something is saved for this subject
    private var tabs: [CourseTab] {
        CourseTab.allCases.filter { t in
            switch t {
            case .drive: return driveCount > 0
            case .todo: return todoCount > 0
            default: return true
            }
        }
    }

    /// Top-right Teams icon: opens the linked class, or asks which class to link
    @ViewBuilder private var teamsButton: some View {
        if let team = teamsLib.team(for: course.id) {
            NavigationLink { TeamDetailView(team: team) } label: { TeamsGlyph(size: 26) }
                .contextMenu {
                    Button { pickingTeam = true } label: { Label("Change class…", systemImage: "link") }
                    Button(role: .destructive) { teamsLib.unlink(courseId: course.id) } label: {
                        Label("Unlink class", systemImage: "minus.circle")
                    }
                }
        } else {
            Button { pickingTeam = true } label: { TeamsGlyph(size: 26).opacity(0.55) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 26) {
                    ForEach(tabs) { t in
                        Button { tab = t } label: {
                            HStack(spacing: 6) {
                                Text(t.rawValue)
                                    .fontWeight(tab == t ? .semibold : .regular)
                                    .foregroundColor(tab == t ? Theme.accent : Color(white: 0.66))
                                if t == .todo {
                                    Text("\(todoCount)")
                                        .font(.caption2.weight(.bold)).foregroundColor(.black)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.accent).clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            switch tab {
            case .course: CourseContentView(courseId: course.id)
            case .participants: ParticipantsView(courseId: course.id)
            case .drive: CourseDriveTab(courseId: course.id)
            case .todo: CourseTodoTab(courseId: course.id)
            case .grades: GradesView(courseId: course.id)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(course.shortname ?? course.fullname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { teamsButton }
        }
        .sheet(isPresented: $pickingTeam) { PickTeamSheet(course: course) }
        // the open tab goes away when its last item is removed
        .onChange(of: tabs) { new in if !new.contains(tab) { tab = .course } }
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
        case "attendance":
            AttendanceView(module: module, courseId: courseId)
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

// MARK: - Grades

struct GradesView: View {
    let courseId: Int
    @EnvironmentObject var app: AppState
    @State private var items: [GradeItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CamsCalculatorCard(courseId: courseId)
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
                .glowCard()
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneButton()
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
                        NavigationLink {
                            UserProfileView(userid: p.id, courseId: courseId, name: p.fullname,
                                            imageURL: p.profileimageurlsmall)
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: p.profileimageurlsmall.flatMap { MoodleAPI.shared.fileURL($0) }) { i in
                                    i.resizable().scaledToFill()
                                } placeholder: { Theme.surface2 }
                                .frame(width: 34, height: 34).clipShape(Circle())
                                Text(p.fullname).foregroundColor(Theme.txt)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.muted)
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                        }
                        .buttonStyle(.plain)
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
    var theme = false   // pages are shown as the normal site (no injected dark theme)

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        if theme {
            cfg.userContentController.addUserScript(
                WKUserScript(source: WebTheme.js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let w = WKWebView(frame: .zero, configuration: cfg)
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

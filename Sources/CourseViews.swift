import SwiftUI
import WebKit

// MARK: - Course detail (Course / Participants / Grades tabs; groups live under the Group Selection activity)

enum CourseTab: String, CaseIterable, Identifiable {
    case course = "Course", participants = "Participants", drive = "My Drive", todo = "To-Do", grades = "Grades"
    var id: String { rawValue }
}

struct CourseDetailView: View {
    let course: Course
    @EnvironmentObject var todos: TodoStore
    @EnvironmentObject var drive: DriveLibrary
    @State private var tab: CourseTab = .course
    @State private var coverTab: CourseTab = .course         // the tab the top cover is drawn for. Follows `tab`, except on a jump over
                                                             // several tabs, where the cover must not sweep across the tabs in between
    @State private var scroll = CourseScrollModel()          // how far the Course tab has scrolled (moves the header photo);
                                                             // a reference held in @State so scrolling doesn't redraw this view
    @State private var pager = CoursePagerModel()            // how far a swipe between tabs has moved (slides the top cover with the pages)
    @State private var pageW: CGFloat = 390                  // width of the page area (for the swipe)
    @State private var bottomInset: CGFloat = 0              // height of the floating tab bar's safe area (pages scroll under it)
    @ObservedObject private var themes = ThemeStore.shared

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

    @ViewBuilder private func page(_ t: CourseTab) -> some View {
        switch t {
        case .course: CourseContentView(courseId: course.id, course: course, onScroll: { y in
            scroll.y = max(0, y)
        }, onUnload: {
            // The paged TabView drops pages that are not next to the open one. When the Course list is dropped while another
            // tab is open, its position is gone (it comes back at the top), so the photo and cover go back to "top" too.
            // Without this they kept the old scroll position (a solid black header) until the new list reported in.
            if tab != .course { scroll.y = 0 }
        })
        case .participants: ParticipantsView(courseId: course.id)
        case .drive: CourseDriveTab(courseId: course.id)
        case .todo: CourseTodoTab(courseId: course.id)
        case .grades: GradesView(courseId: course.id)
        }
    }

    private var photoOn: Bool { true }      // the photo header is on in every theme (Light washes it out, see CourseBackdrop)

    /// A tap on the tab strip. The pager only slides ONE page when the tab is several places away, but the cover strips are
    /// laid out one per tab, so animating them would sweep every tab in between across the header (solid black strips over
    /// the photo). A far jump therefore moves the cover straight to the new tab; a neighbour still slides with its page.
    private func select(_ t: CourseTab) {
        guard t != tab else { return }
        let from = tabs.firstIndex(of: tab) ?? 0
        let to = tabs.firstIndex(of: t) ?? 0
        if abs(to - from) > 1 {
            var tr = Transaction(); tr.disablesAnimations = true
            withTransaction(tr) { coverTab = t }
            withAnimation(.easeInOut(duration: 0.25)) { tab = t }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { tab = t; coverTab = t }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            if photoOn {
                CourseBackdrop(scroll: scroll)      // moves up with the Course list; the other tabs' opaque pages slide over it
            }
            content
        }
        // the photo shows through the navigation bar and the tab strip while the Course tab is at the top. The bar's own
        // background is always hidden; the tab strip carries ONE cover (see CourseChromeBackground) that reaches up over
        // the status bar and navigation bar, so the whole top area fades together
        .toolbarBackground(photoOn ? Visibility.hidden : Visibility.automatic, for: .navigationBar)
        .navigationTitle(course.prettyShort ?? course.prettyFull)
        .navigationBarTitleDisplayMode(.inline)
        // the open tab goes away when its last item is removed
        .onChange(of: tabs) { new in if !new.contains(tab) { tab = .course } }
        // the swipe is finished: the strips now sit in their new places, so the swipe offset goes back to 0 (no animation)
        .onChange(of: tab) { newTab in
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                pager.dragX = 0
                coverTab = newTab       // swipes (and removed tabs) change `tab` directly: the cover catches up here
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 26) {
                    ForEach(tabs) { t in
                        Button { select(t) } label: {
                            HStack(spacing: 6) {
                                Text(t.rawValue)
                                    .fontWeight(tab == t ? .semibold : .regular)
                                    .foregroundColor(tab == t ? Theme.accent : Theme.muted)
                                    .rocks(17)
                                if t == .todo {
                                    Text("\(todoCount)")
                                        .font(Theme.font(.caption2).weight(.bold)).foregroundColor(Theme.onAccent)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.accent).clipShape(Capsule())
                                }
                            }
                        }
                        .id(t)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .noTopEdgeEffect(photoOn)
            // clear over the photo at the top of the Course tab, solid everywhere else; extends up over the nav bar.
            // One strip per tab that slides with the pages while swiping (see CourseChromeCover)
            .background { if photoOn { CourseChromeCover(scroll: scroll, pager: pager, tabs: tabs, current: coverTab) } }
            // keep the selected tab visible when swiping between pages
            .onChange(of: tab) { t in withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(t, anchor: .center) } }
            }

            // Swipe right-to-left for the next tab, left-to-right for the previous one.
            // On the first tab (Course) a left-to-right swipe from the screen edge still goes back.
            TabView(selection: $tab) {
                ForEach(tabs) { t in
                    page(t)
                        // the pages run under the floating tab bar (see below), so the list gets that height as bottom room
                        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomInset) }
                        // the list is cut off where it meets the header (pure black), and the cards' glow is a faint grey:
                        // fade the first few points out so there is no hard line between the two
                        .mask(TopFade())
                        .background(t == .course ? Color.clear : Theme.bg)
                        // reads where the pager really is, so the top cover slides exactly as far as the pages
                        .background(CoursePagerProbe(pager: pager, index: tabs.firstIndex(of: tab) ?? 0, count: tabs.count))
                        .tag(t)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The pager stopped at the tab bar's safe area and left a black band behind the floating bar (the page content was
            // cut off along the band's top edge). `.ignoresSafeArea` does not reliably widen a page-style TabView, so its
            // frame is grown by the bar's height instead: the pages now run all the way down, underneath the bar.
            .padding(.bottom, -bottomInset)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { pageW = g.size.width }
                    .onChange(of: g.size.width) { pageW = $0 }
            })
            // fallback only: CoursePagerProbe normally drives the top cover from the pages' real position (the finger runs
            // slightly ahead of the pager, which left the cover misaligned with the page next to it)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard !pager.followsPages,
                              abs(v.translation.width) > abs(v.translation.height),
                              let i = tabs.firstIndex(of: tab) else { return }
                        var dx = v.translation.width
                        if i == 0 { dx = min(dx, 0) }                    // no page before the first tab
                        if i == tabs.count - 1 { dx = max(dx, 0) }       // none after the last
                        pager.dragX = max(-pageW, min(pageW, dx))
                    }
                    .onEnded { v in
                        if pager.followsPages { return }
                        guard abs(v.translation.width) > abs(v.translation.height),
                              let i = tabs.firstIndex(of: tab) else {
                            withAnimation(.easeOut(duration: 0.2)) { pager.dragX = 0 }
                            return
                        }
                        // does the page go on to the next / previous tab? (past half way, counting the flick)
                        let p = v.predictedEndTranslation.width
                        let dir = p < -pageW / 2 ? 1 : (p > pageW / 2 ? -1 : 0)
                        if dir != 0, tabs.indices.contains(i + dir) {
                            withAnimation(.easeOut(duration: 0.25)) { pager.dragX = dir == 1 ? -pageW : pageW }
                        } else {
                            withAnimation(.easeOut(duration: 0.25)) { pager.dragX = 0 }
                        }
                        // the page change itself resets this; if the swipe did not change the tab, put the cover back
                        let at = tab
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            if tab == at { withAnimation(.easeOut(duration: 0.2)) { pager.dragX = 0 } }
                        }
                    }
            )
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { bottomInset = g.safeAreaInsets.bottom }
                .onChange(of: g.safeAreaInsets.bottom) { bottomInset = $0 }
        })
    }
}

/// Hides the first few points of a page and fades them in, so list content melts into the header above it instead of
/// being cut off in a straight line. Kept shorter than the pages' top padding (16) so nothing at rest is dimmed.
private struct TopFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Rectangle().fill(Color.black)
        }
    }
}

struct CourseContentView: View {
    let courseId: Int
    var course: Course? = nil
    var onScroll: (CGFloat) -> Void = { _ in }
    var onUnload: () -> Void = {}                   // the list left the screen for good (page unloaded): its position is gone
    @State private var sections: [CourseSection] = []
    @State private var loading = true
    @State private var error: String?
    @State private var box = CourseScrollBox()      // last scroll position (a plain reference: no redraw while scrolling)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                if let course { CourseHeaderView(course: course) }
                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
                ForEach(sections.filter { !$0.modules.isEmpty || !$0.name.isEmpty }) { s in
                    SectionCard(courseId: courseId, section: s)
                }
                if loading { ProgressView().tint(Theme.accent) }
            }
            .padding(16)
            // the list's real scroll position (read from its UIScrollView), so the header photo moves up with it
            .background(CourseScrollProbe(onChange: { y in
                box.y = y
                onScroll(y)
            }, onDetach: {
                // a list that comes back starts at the top again
                box.y = 0
                onUnload()
            }))
        }
        // coming back to this page (from another tab): put the photo where the list really is
        .onAppear { onScroll(box.y) }
        .noTopEdgeEffect(course != nil)
        .refreshable { await load() }
        .task {
            await OfflineCache.paintFromCache { await load() }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load() } }
        .onFreshData { await load() }
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
                        .rocks(20)
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
        case "choicegroup", "groupselect": return "person.3"
        default: return "square.grid.2x2"
        }
    }

    private var web: some View {
        WebActivityView(url: URL(string: module.url ?? "") ?? Site.url, title: module.name)
    }

    @ViewBuilder var destination: some View {
        switch module.modname {
        case "page":
            PageModuleView(courseId: courseId, module: module)
        case "forum":
            ForumView(forumId: module.instance ?? 0, title: module.name)
        case "assign":
            AssignmentView(courseId: courseId, module: module)
        case "attendance":
            AttendanceView(module: module, courseId: courseId)
        case "choicegroup", "groupselect":
            GroupChoiceView(courseId: courseId, module: module)
        case "folder":
            FolderView(module: module)
        case "resource":
            if let f = module.contents?.first?.fileurl, let u = MoodleAPI.shared.fileURL(f) {
                FileViewer(url: u, title: module.name, modified: module.contents?.first?.timemodified)
            } else { web }
        default:
            if (module.url ?? "").contains("groupselect") {
                GroupChoiceView(courseId: courseId, module: module)
            } else { web }
        }
    }

    var body: some View {
        if module.modname == "label" {
            if let d = module.description?.plainText, !d.isEmpty {
                Text(d).font(Theme.read(.subheadline)).foregroundColor(Theme.muted)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NavigationLink { destination } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).foregroundColor(Theme.accent).frame(width: 24)
                    Text(module.name).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                    Spacer()
                    if module.modname == "resource" { FileStateIcon(file: module.contents?.first) }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fileDownloadMenu(module.modname == "resource" ? module.contents?.first : nil)   // press and hold: Download
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
                        NavigationLink { FileViewer(url: u, title: c.filename ?? "File", modified: c.timemodified) } label: {
                            HStack {
                                Image(systemName: "doc").foregroundColor(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.filename ?? "File").foregroundColor(Theme.txt)
                                    Text(fmt(c.timemodified, time: false)).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                }
                                Spacer()
                                FileStateIcon(file: c)
                            }
                            .padding(14)
                        }
                        .buttonStyle(.plain)
                        .fileDownloadMenu(c)
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
    /// The site's last-modified time of this file (when known), so a saved copy is only used online if it is current
    var modified: Int? = nil
    @ObservedObject private var files = OfflineFileStore.shared

    var body: some View {
        Group {
            // downloaded copy: used with no internet (and online when it is the current version)
            if let local = files.localURL(for: url, modified: modified) {
                QuickLookView(url: local).ignoresSafeArea(edges: .bottom)
            } else {
                WebView(url: url, theme: false)
            }
        }
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
                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
                ForEach(items) { d in
                    NavigationLink { PostsView(discussionId: d.discussion, title: d.name ?? d.subject ?? title) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(d.name ?? d.subject ?? "Discussion")
                                .fontWeight(.semibold).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                            Text("\(d.userfullname ?? "") · \(fmt(d.created, time: false))")
                                .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                            if let m = d.message?.plainText, !m.isEmpty {
                                Text(m).font(Theme.read(.subheadline)).foregroundColor(Theme.muted).lineLimit(4)
                                    .multilineTextAlignment(.leading)
                            }
                            if let r = d.numreplies, r > 0 {
                                Text("\(r) replies").font(Theme.font(.caption)).foregroundColor(Theme.accent)
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
        .task {
            await OfflineCache.paintFromCache { await load() }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load() } }
        .onFreshData { await load() }
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
                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
                ForEach(posts) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(p.subject ?? "").fontWeight(.semibold).foregroundColor(Theme.txt)
                        Text("\(p.author?.fullname ?? "") · \(fmt(p.timecreated))")
                            .font(Theme.font(.caption)).foregroundColor(Theme.muted)
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
            await OfflineCache.paintFromCache { await load() }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load() } }
        .onFreshData { await load() }
    }

    private func load() async {
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
                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted).padding() }
                ForEach(items) { g in
                    HStack(alignment: .top) {
                        Text(g.itemname ?? "Course total").foregroundColor(Theme.txt)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(g.gradeformatted ?? "-").foregroundColor(Theme.accent).fontWeight(.semibold)
                            if let r = g.rangeformatted { Text(r).font(Theme.font(.caption)).foregroundColor(Theme.muted) }
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
            await OfflineCache.paintFromCache { await load() }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load() } }
        .onFreshData { await load() }
    }

    private func load() async {
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
                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
                VStack(spacing: 0) {
                    ForEach(shown) { p in
                        NavigationLink {
                            UserProfileView(userid: p.id, courseId: courseId, name: p.fullname,
                                            imageURL: p.profileimageurlsmall)
                        } label: {
                            HStack(spacing: 12) {
                                ProfilePhoto(name: p.fullname, urls: [p.profileimageurlsmall, p.profileimageurl], size: 34, sizeKey: "f1", outline: false)
                                Text(p.fullname).foregroundColor(Theme.txt)
                                Spacer()
                                Image(systemName: "chevron.right").font(Theme.font(.caption)).foregroundColor(Theme.muted)
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
            do {
                people = try await MoodleAPI.shared.call("core_enrol_get_enrolled_users", ["courseid": courseId])
                people = await ProfileImages.upgraded(people)    // pictures the participant list left out
            }
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


// MARK: - Open any activity by its id (used by Alerts: announcements, assignments, ...)

private struct CMResp: Decodable { let cm: CMInfo }
private struct CMInfo: Decodable { let id: Int; let course: Int }

struct ModuleLoaderView: View {
    let cmid: Int
    let url: URL?
    let title: String
    @State private var found: (course: Int, module: Module)?
    @State private var failed = false

    var body: some View {
        Group {
            if let f = found {
                ModuleRow(courseId: f.course, module: f.module).destination
            } else if failed {
                WebActivityView(url: url ?? Site.url, title: title)   // last resort
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg.ignoresSafeArea())
                    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            do {
                let r: CMResp = try await MoodleAPI.shared.call("core_course_get_course_module", ["cmid": cmid])
                let sections: [CourseSection] = try await MoodleAPI.shared.call(
                    "core_course_get_contents",
                    ["courseid": r.cm.course, "options": [["name": "cmid", "value": cmid]]])
                if let m = sections.flatMap({ $0.modules }).first(where: { $0.id == cmid }) {
                    found = (r.cm.course, m)
                } else { failed = true }
            } catch {
                if !(error is CancellationError) { failed = true }
            }
        }
    }
}

// MARK: - Page activity (announcements are usually Pages) shown inside the app

private struct PagesResp: Decodable { let pages: [PageInfo] }
private struct PageInfo: Decodable { let coursemodule: Int?; let content: String? }

enum PageBlock { case text(AttributedString), image(URL) }

struct PageModuleView: View {
    let courseId: Int
    let module: Module
    @State private var blocks: [PageBlock]?
    @State private var html = ""
    @State private var loading = true
    @State private var openFile: URL?

    /// Files attached to the page that aren't already shown or linked inside the text
    private var attachments: [ModContent] {
        (module.contents ?? []).filter { c in
            guard let n = c.filename, c.fileurl != nil, n.lowercased() != "index.html" else { return false }
            return !html.contains(n) && !html.contains(n.replacingOccurrences(of: " ", with: "%20"))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(module.name)
                        .fontWeight(.semibold).foregroundColor(Theme.txt)
                        .multilineTextAlignment(.leading)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    if let blocks {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                            switch b {
                            case .text(let t):
                                Text(t).font(Theme.read(.subheadline)).lineSpacing(3)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            case .image(let u):
                                NavigationLink { FileViewer(url: u, title: "Image") } label: {
                                    AsyncImage(url: u) { phase in
                                        switch phase {
                                        case .success(let img): img.resizable().scaledToFit()
                                        case .failure: Label("Image couldn't load", systemImage: "photo")
                                                .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                                        default: ProgressView().tint(Theme.accent).frame(height: 120)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if loading {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                    } else {
                        Text("Couldn't load this page.").font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .glowCard(radius: 12)

                if !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Attachments").font(Theme.font(.caption).weight(.medium)).foregroundColor(Theme.muted)
                            .padding(14)
                        ForEach(attachments) { c in
                            if let f = c.fileurl, let u = MoodleAPI.shared.fileURL(f) {
                                NavigationLink { FileViewer(url: u, title: c.filename ?? "File", modified: c.timemodified) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "paperclip").foregroundColor(Theme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.filename ?? "File").foregroundColor(Theme.txt)
                                                .multilineTextAlignment(.leading)
                                            if let sz = c.filesize, sz > 0 {
                                                Text(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file))
                                                    .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                            }
                                        }
                                        Spacer()
                                        FileStateIcon(file: c)
                                        Image(systemName: "chevron.right").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                    }
                                    .padding(14)
                                    .contentShape(Rectangle())
                                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
                                }
                                .buttonStyle(.plain)
                                .fileDownloadMenu(c)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glowCard(radius: 12)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        // links to files on the site open in the app's viewer; other links go to Safari
        .environment(\.openURL, OpenURLAction { url in
            if url.absoluteString.contains("pluginfile.php") { openFile = url; return .handled }
            return .systemAction
        })
        .navigationDestination(isPresented: Binding(get: { openFile != nil },
                                                    set: { if !$0 { openFile = nil } })) {
            if let u = openFile { FileViewer(url: u, title: u.lastPathComponent.removingPercentEncoding ?? "File") }
        }
        .task {
            if let r: PagesResp = try? await MoodleAPI.shared.call(
                "mod_page_get_pages_by_courses", ["courseids": [courseId]]),
               let h = r.pages.first(where: { $0.coursemodule == module.id })?.content {
                html = h
                blocks = HTMLText.blocks(h)
            }
            loading = false
        }
    }
}

/// Turns Moodle HTML into styled text that matches the app (bold, italics, bullets, tappable links).
enum HTMLText {
    static func blocks(_ html: String) -> [PageBlock] {
        var out = AttributedString()
        var blocks: [PageBlock] = []
        var bold = 0, italic = 0
        var link: URL?
        var newlines = 2            // pretend we start after a blank line so nothing leads with spaces
        var pendingSpace = false

        func flush() {
            while let last = out.characters.last, last == "\n" || last == " " { out.characters.removeLast() }
            if !out.characters.isEmpty { blocks.append(.text(out)) }
            out = AttributedString()
            newlines = 2
            pendingSpace = false
        }
        // site files need the user's token; other addresses are used as they are (the token must not leave the site)
        func resolve(_ raw: String) -> URL? {
            let r = raw.decodedEntities
            return r.contains("pluginfile.php") ? MoodleAPI.shared.fileURL(r) : URL(string: r)
        }
        func newline(_ n: Int) {
            guard newlines < n else { return }
            out += AttributedString(String(repeating: "\n", count: n - newlines))
            newlines = n
            pendingSpace = false
        }
        func add(_ s: String) {
            var a = AttributedString(s)
            var f = Theme.read(.subheadline, bold: bold > 0)
            if italic > 0 { f = f.italic() }
            a.font = f
            a.foregroundColor = Theme.txt
            if let link { a.link = link; a.foregroundColor = Theme.accent; a.underlineStyle = .single }
            out += a
            newlines = 0
        }

        guard let re = try? NSRegularExpression(pattern: "<[^>]+>|[^<]+") else { return [.text(AttributedString(html.plainText))] }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            if tok.hasPrefix("<") {
                let t = tok.lowercased()
                let name = t.drop(while: { $0 == "<" || $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber })
                let closing = t.hasPrefix("</")
                switch name {
                case "br": newline(1)
                case "p", "div", "ul", "ol", "blockquote", "table": if closing { newline(2) } else { newline(1) }
                case "li": if closing { newline(1) } else { newline(1); add("•  ") }
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    if closing { bold = max(bold - 1, 0); newline(2) } else { newline(2); bold += 1 }
                case "strong", "b": bold = closing ? max(bold - 1, 0) : bold + 1
                case "em", "i": italic = closing ? max(italic - 1, 0) : italic + 1
                case "a":
                    if closing { link = nil }
                    else if let r = tok.range(of: "href=\"([^\"]*)\"", options: .regularExpression) {
                        link = resolve(String(String(tok[r]).dropFirst(6).dropLast()))
                    }
                case "img":
                    if let r = tok.range(of: "src=\"([^\"]*)\"", options: .regularExpression),
                       let u = resolve(String(String(tok[r]).dropFirst(5).dropLast())) {
                        flush()
                        blocks.append(.image(u))
                    }
                case "iframe":
                    if !closing, let r = tok.range(of: "src=\"([^\"]*)\"", options: .regularExpression),
                       let u = resolve(String(String(tok[r]).dropFirst(5).dropLast())) {
                        let saved = link
                        newline(1); link = u; add("\u{25B6}  Open embedded content"); link = saved; newline(1)
                    }
                case "tr": if closing { newline(1) }
                case "td", "th": if closing { pendingSpace = true }
                default: break
                }
            } else {
                // HTML collapses whitespace; keep a single space between words
                var s = tok.decodedEntities.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if newlines > 0 { s = String(s.drop(while: { $0 == " " })) }
                if s.isEmpty { continue }
                if pendingSpace && newlines == 0 { s = " " + s }
                pendingSpace = false
                add(s)
            }
        }
        flush()
        return blocks
    }
}

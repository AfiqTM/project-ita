import SwiftUI
import UserNotifications

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var assignments = AssignmentsModel()
    @StateObject private var notifs = NotifBadgeModel()
    @StateObject private var browser = SiteBrowser()
    @ObservedObject private var chat = ChatStore.shared   // unread chats, for the app-icon badge

    // Kept here (not inside the tabs) so they survive when the tabs are rebuilt for a new theme:
    // the selected tab and, in Others, the screen that is open (Others > Themes)
    @ObservedObject private var themes = ThemeStore.shared
    @State private var tab = 0
    @State private var othersPath: [OthersRoute] = []
    /// The tab selection; tapping the tab that is already open sends Courses back to its main list
    private var selection: Binding<Int> {
        Binding(get: { tab }, set: { new in
            if new == tab && new == 0 { popToRootAnimated() }
            tab = new
        })
    }

    /// Tapping the open Courses tab again: slide back out of every screen to the main course list (the normal back animation)
    private func popToRootAnimated() {
        func nav(in vc: UIViewController) -> UINavigationController? {
            if let n = vc as? UINavigationController { return n }
            for c in vc.children { if let n = nav(in: c) { return n } }
            return nil
        }
        func tabBar(in vc: UIViewController) -> UITabBarController? {
            if let t = vc as? UITabBarController { return t }
            for c in vc.children { if let t = tabBar(in: c) { return t } }
            if let p = vc.presentedViewController { return tabBar(in: p) }
            return nil
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController,
              let tabs = tabBar(in: root), let selected = tabs.selectedViewController,
              let n = nav(in: selected), n.viewControllers.count > 1 else { return }
        n.popToRootViewController(animated: true)
    }

    var body: some View {
        TabView(selection: selection) {
            NavigationStack { CoursesView() }
                .background(TabBadgeTint(color: Theme.uiAccent, text: Theme.uiOnAccent))   // accent badges (TabBadgeTint.swift)
                .tabItem { Label("Courses", systemImage: "books.vertical") }
                .tag(0)
            NavigationStack { AssignmentsTabView(model: assignments) }
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .badge(assignments.badgeCount)   // to-do items due inside the range chosen in the tab
                .tag(1)
            NavigationStack { AlertsView(badge: notifs) }
                .tabItem { Label("Alerts", systemImage: "bell") }
                .badge(notifs.count)   // unread notifications
                .tag(2)
            NavigationStack { SiteBrowserView(browser: browser) }
                .tabItem { Label("Website", systemImage: "globe") }
                .tag(3)
            NavigationStack(path: $othersPath) {
                ProfileView()
                    .navigationDestination(for: OthersRoute.self) { route in
                        switch route {
                        case .themes: ThemesView()
                        }
                    }
            }
            .tabItem { Label("Others", systemImage: "ellipsis.circle") }
            .tag(4)
        }
        // A new identity per theme: every screen is rebuilt, so all colours are read again
        .id(themes.theme)
        .safeAreaInset(edge: .top, spacing: 0) { OfflineBanner().id(themes.theme) }   // small "Offline" pill, only while saved data is shown
        .overlay { MessagesOverlay() }   // Messages: full-screen, above the tab bar (Messages.swift)
        // Load at launch so the badges are right before either tab is opened
        .task(id: app.site?.userid) {
            guard let uid = app.site?.userid else { return }
            await OfflineCache.paintFromCache { await assignments.load(uid: uid) }   // last download first, instantly
            await assignments.load(uid: uid)                                          // then the online version
        }
        .task { await NotificationManager.shared.requestPermission() }
        // Offline support: download the lists in the background so they open with no internet
        .task(id: app.site?.userid) {
            if let uid = app.site?.userid { await OfflinePrefetch.run(uid: uid) }
        }
        // The website answered again after saved data was shown: refresh
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in
            guard let uid = app.site?.userid else { return }
            Task { await assignments.load(uid: uid); await notifs.refresh(uid: uid) }
        }
        // Newer data was saved in the background (slow connection): show it at once
        .onFreshData {
            guard let uid = app.site?.userid else { return }
            await assignments.load(uid: uid)
            await notifs.refresh(uid: uid)
        }
        // Changes made with no internet are sent when the app opens, and when the connection returns
        .task { await OfflineQueue.shared.flush() }
        .onReceive(NotificationCenter.default.publisher(for: .offlineQueueSent)) { _ in
            guard let uid = app.site?.userid else { return }
            Task { await assignments.load(uid: uid) }
        }
        // Home-screen widget data (maximum possible attendance per subject)
        .task(id: app.site?.userid) {
            if let uid = app.site?.userid { await AttendanceSync.refresh(userid: uid) }
        }
        // Unread alerts: check now, then every 15 s while the app is open
        .task(id: app.site?.userid) {
            guard let uid = app.site?.userid else { return }
            while !Task.isCancelled {
                await notifs.refresh(uid: uid)
                await NotificationManager.shared.checkIncoming(uid: uid)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        // App-icon badge on the home screen = unread alerts + unread chats
        .onChange(of: notifs.count + chat.unread) { n in
            UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { NotificationManager.shared.scheduleRefresh() }
            guard phase == .active, let uid = app.site?.userid else { return }
            Task {
                await OfflineQueue.shared.flush()
                await notifs.refresh(uid: uid)
                await assignments.load(uid: uid)
                await AttendanceSync.refresh(userid: uid)
                await AutoAttendance.shared.refreshAndPush(userid: uid)
                await NotificationManager.shared.checkIncoming(uid: uid)
                await OfflinePrefetch.run(uid: uid)
            }
        }
    }
}

// MARK: - My courses

enum CourseFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case inprogress = "In progress"
    case future = "Future"
    case past = "Past"
    case favourites = "Starred"
    case hidden = "Removed from view"

    var id: String { rawValue }
    var classification: String {
        switch self {
        case .all: return "all"
        case .inprogress: return "inprogress"
        case .future: return "future"
        case .past: return "past"
        case .favourites: return "favourites"
        case .hidden: return "hidden"
        }
    }
}

struct CoursesView: View {
    @EnvironmentObject var app: AppState
    @State private var filter: CourseFilter = .all
    @State private var courses: [Course] = []
    @State private var favOverride: [Int: Bool] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var allCourses: [Course] = []     // every enrolled course, used for search suggestions
    @State private var openCourse: Course?
    @FocusState private var searchFocused: Bool

    // ---- search ----

    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    // 0 = every typed word starts a word in the course name, 1 = just contained somewhere, nil = no match
    private func rank(_ c: Course, _ q: String) -> Int? {
        let words = q.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return 0 }
        let hay = c.fullname + " " + (c.shortname ?? "")
        let hayWords = hay.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var prefixAll = true
        for w in words {
            let f = w.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if !hayWords.contains(where: { $0.hasPrefix(f) }) { prefixAll = false }
            if hay.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return nil }
        }
        return prefixAll ? 0 : 1
    }

    // Suggestions come from all enrolled courses (plus whatever the current filter loaded)
    private var suggestions: [Course] {
        guard !cleanQuery.isEmpty else { return [] }
        var seen = Set<Int>()
        let pool = (allCourses + courses).filter { seen.insert($0.id).inserted }
        return pool.compactMap { c in rank(c, cleanQuery).map { (c, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.fullname < $1.0.fullname }
            .prefix(5).map { $0.0 }
    }

    private var visibleCourses: [Course] {
        cleanQuery.isEmpty ? courses : courses.filter { rank($0, cleanQuery) != nil }
    }

    private func openFromSearch(_ c: Course) {
        searchFocused = false
        query = ""
        openCourse = c
    }

    private var firstTwoNames: String {
        (app.site?.fullname ?? "")
            .split(separator: " ").prefix(2)
            .map { w -> String in
                let s = String(w)
                return s == s.uppercased() ? s.prefix(1) + s.dropFirst().lowercased() : s
            }
            .joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // intro animation per theme (Themes.swift): gunshot, Pac-Man or decoding symbols
                GreetingBar(hello: "Hello,", name: firstTwoNames) {
                    MessagesButton()   // chat icon + unread badge (Messages.swift)
                }

                searchBar
                suggestionList

                filterBar

                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }

                LazyVStack(spacing: 22) {
                    ForEach(visibleCourses) { c in
                        let starred = favOverride[c.id] ?? c.isfavourite ?? false
                        ZStack(alignment: .topTrailing) {
                            NavigationLink { CourseDetailView(course: c) } label: { CourseCard(course: c) }
                                .buttonStyle(.plain)
                            if filter == .hidden {
                                Button { Task { await toggleHide(c) } } label: {
                                    Label("Show again", systemImage: "eye")
                                        .font(Theme.font(.footnote).weight(.semibold))
                                        .foregroundColor(Theme.onAccent)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Theme.accent)
                                        .clipShape(Capsule())
                                }
                                .padding(10)
                            } else {
                                Button { Task { await toggleStar(c) } } label: {
                                    Image(systemName: starred ? "star.fill" : "star")
                                        .foregroundColor(starred ? Color(hex: ThemeStore.shared.theme.onCoverAccent) : Color.white.opacity(0.85))
                                        .padding(10)
                                        .background(Color.black.opacity(0.45))
                                        .clipShape(Circle())
                                }
                                .padding(10)
                            }
                        }
                        .contextMenu {
                            Button { Task { await toggleStar(c) } } label: {
                                Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star")
                            }
                            Button { Task { await toggleHide(c) } } label: {
                                Label(filter == .hidden ? "Show again" : "Remove from view",
                                      systemImage: filter == .hidden ? "eye" : "eye.slash")
                            }
                        }
                    }
                }
                if !loading && visibleCourses.isEmpty && error == nil {
                    Text(cleanQuery.isEmpty ? "No courses here." : "No courses match \u{201C}\(cleanQuery)\u{201D}.")
                        .foregroundColor(Theme.muted)
                }
                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(isPresented: Binding(get: { openCourse != nil },
                                                    set: { if !$0 { openCourse = nil } })) {
            if let c = openCourse { CourseDetailView(course: c) }
        }
        .refreshable { await load(); await loadAll() }
        .task(id: filter) {
            await OfflineCache.paintFromCache { await load() }   // last download first, instantly
            await load()                                          // then the online version
        }
        .task { await loadAll() }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load(); await loadAll() } }
        .onFreshData { await load(); await loadAll() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
            TextField("", text: $query, prompt: Text("Search my courses").foregroundColor(Theme.muted))
                .foregroundColor(Theme.txt)
                .tint(Theme.accent)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { if let c = suggestions.first { openFromSearch(c) } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.muted)
                }
            }
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(searchFocused ? Theme.accent.opacity(0.6) : Theme.line))
    }

    @ViewBuilder private var suggestionList: some View {
        let s = suggestions
        if searchFocused && !s.isEmpty {
            VStack(spacing: 0) {
                ForEach(s) { c in
                    Button { openFromSearch(c) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed").font(Theme.font(.footnote)).foregroundColor(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.prettyFull).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                                if let sn = c.prettyShort, !sn.isEmpty {
                                    Text(sn).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                    }
                    .buttonStyle(.plain)
                }
            }
            .glowCard()
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(CourseFilter.allCases) { f in
                    Button { filter = f } label: {
                        Text(f.rawValue)
                            .fontWeight(filter == f ? .semibold : .regular)
                            .foregroundColor(filter == f ? Theme.accent : Theme.txt)
                            .rocks(17)
                    }
                }
            }
            .padding(.horizontal, 16)      // starts at the page margin, scrolls to the screen edge
        }
        .padding(.horizontal, -16)
    }

    private func load() async {
        loading = true; error = nil
        do {
            let r: CourseList = try await MoodleAPI.shared.call(
                "core_course_get_enrolled_courses_by_timeline_classification",
                ["classification": filter.classification, "limit": 0, "offset": 0, "sort": "fullname"])
            var list = r.courses
            if filter == .hidden && list.isEmpty {
                let a: CourseList? = try? await MoodleAPI.shared.call(
                    "core_course_get_enrolled_courses_by_timeline_classification",
                    ["classification": "allincludinghidden", "limit": 0, "offset": 0, "sort": "fullname"])
                let b: CourseList? = try? await MoodleAPI.shared.call(
                    "core_course_get_enrolled_courses_by_timeline_classification",
                    ["classification": "all", "limit": 0, "offset": 0, "sort": "fullname"])
                if let a, let b {
                    let visible = Set(b.courses.map { $0.id })
                    list = a.courses.filter { !visible.contains($0.id) }
                }
            }
            courses = list
            favOverride = [:]
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }

    // All enrolled courses, loaded once in the background to power the search suggestions
    private func loadAll() async {
        let r: CourseList? = try? await MoodleAPI.shared.call(
            "core_course_get_enrolled_courses_by_timeline_classification",
            ["classification": "all", "limit": 0, "offset": 0, "sort": "fullname"])
        if let r { allCourses = r.courses }
    }

    // Star / unstar. Updates the card immediately and rolls back if Moodle refuses.
    private func toggleStar(_ c: Course) async {
        let now = !(favOverride[c.id] ?? c.isfavourite ?? false)
        favOverride[c.id] = now
        do {
            try await MoodleAPI.shared.setFavourite(c.id, now)
            if filter == .favourites && !now { courses.removeAll { $0.id == c.id } }
        } catch {
            favOverride[c.id] = !now
            self.error = error.localizedDescription
        }
    }

    // "Removed from view" = Moodle's own hide-course preference, so it also applies on the website.
    private func toggleHide(_ c: Course) async {
        let hide = filter != .hidden
        do {
            try await MoodleAPI.shared.setHidden(c.id, hide, userid: app.site?.userid ?? 0)
            courses.removeAll { $0.id == c.id }
            if hide { allCourses.removeAll { $0.id == c.id } } else { await loadAll() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CourseCard: View {
    let course: Course
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover.frame(height: 110).frame(maxWidth: .infinity).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(course.prettyFull)
                    .foregroundColor(Theme.txt)
                    .multilineTextAlignment(.leading)
                    .textGlow(radius: 3)
                    .pixelHeading(12, normal: .subheadline.weight(.semibold), pt: 15)
                if let p = course.progress {
                    ProgressView(value: min(max(p, 0), 100), total: 100).tint(Theme.accent)
                    Text("\(Int(p))% complete").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glowCard()
    }

    @ViewBuilder private var cover: some View {
        if let str = course.courseimage, str.hasPrefix("http"), !str.lowercased().contains(".svg"),
           let u = MoodleAPI.shared.fileURL(str) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .saturation(themes.theme.coverSaturation)
                        .brightness(themes.theme.coverBrightness)
                        .overlay {
                            if let t = themes.theme.coverTint { Color(hex: t).opacity(0.4).blendMode(.multiply) }
                        }
                default: DefaultCover(course: course)
                }
            }
        } else {
            DefaultCover(course: course)
        }
    }
}

// Used when a course has no (usable) image: a tonal gradient picked per course, in the colours of the theme
struct DefaultCover: View {
    let course: Course
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        let covers = themes.theme.covers
        let p = covers[abs(course.id) % covers.count]
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 64))
                .foregroundColor(Theme.accent.opacity(0.16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            Text(course.prettyShort ?? "")
                .foregroundColor(themes.theme.westernHeadings ? Color.white : Theme.accent.opacity(0.92))
                .textGlow()
                .pixelHeading(16, normal: .system(size: 22, weight: .bold), pt: 22)
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(14)
        }
    }
}

// MARK: - Alerts

// Unread-notification count shown on the Alerts tab icon
@MainActor
final class NotifBadgeModel: ObservableObject {
    @Published var count = 0

    func refresh(uid: Int) async {
        do {
            let n: Int = try await MoodleAPI.shared.call(
                "message_popup_get_unread_popup_notification_count", ["useridto": uid])
            count = n
        } catch {
            if error is CancellationError { return }
            // Site doesn't expose the count function: count unread items in the list instead
            if let r: NotifResp = try? await MoodleAPI.shared.call(
                "message_popup_get_popup_notifications", ["useridto": uid]) {
                count = r.notifications.filter { $0.read != true }.count
            }
        }
    }
}

extension Notif {
    /// Forum discussion id taken from the link (".../mod/forum/discuss.php?d=123#p456"), if it is one
    var discussionId: Int? {
        guard let s = contexturl, s.contains("forum/discuss.php"),
              let items = URLComponents(string: s)?.queryItems,
              let d = items.first(where: { $0.name == "d" })?.value else { return nil }
        return Int(d)
    }
    /// Activity id from ".../mod/<type>/view.php?id=123" (assignments, pages/announcements, ...)
    var cmid: Int? {
        guard let s = contexturl, s.contains("/mod/"),
              let items = URLComponents(string: s)?.queryItems,
              let v = items.first(where: { $0.name == "id" })?.value else { return nil }
        return Int(v)
    }
}

struct AlertsView: View {
    @ObservedObject var badge: NotifBadgeModel
    @EnvironmentObject var app: AppState
    @State private var items: [Notif] = []
    @State private var readIds: Set<Int> = []
    @State private var loading = true
    @State private var error: String?

    private var uid: Int { app.site?.userid ?? 0 }
    private func isRead(_ n: Notif) -> Bool { n.read == true || readIds.contains(n.id) }
    private var unread: Int { items.filter { !isRead($0) }.count }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
                ForEach(items) { n in
                    let card = VStack(alignment: .leading, spacing: 4) {
                        Text(n.subject ?? "Notification")
                            .foregroundColor(Theme.txt).fontWeight(isRead(n) ? .regular : .semibold)
                        if let m = n.smallmessage, !m.isEmpty {
                            Text(m.plainText).font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(3)
                        }
                        Text(fmt(n.timecreated)).font(Theme.font(.caption2)).foregroundColor(Theme.muted)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(isRead(n) ? Theme.bg : Theme.surface2)
                    .glowCard()

                    if let d = n.discussionId {
                        // Announcements / forum posts open inside the app, not the website
                        NavigationLink { PostsView(discussionId: d, title: n.subject ?? "Announcement") } label: { card }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { Task { await markRead(n) } })
                    } else if let cm = n.cmid {
                        // Announcements, assignments, pages...: opened with the app's own screens
                        NavigationLink { ModuleLoaderView(cmid: cm, url: n.contexturl.flatMap { URL(string: $0) },
                                                          title: n.subject ?? "Notification") } label: { card }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { Task { await markRead(n) } })
                    } else if let s = n.contexturl, let u = URL(string: s) {
                        NavigationLink { WebActivityView(url: u, title: n.subject ?? "Notification") } label: { card }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { Task { await markRead(n) } })
                    } else {
                        card.onTapGesture { Task { await markRead(n) } }
                    }
                }
                if loading { ProgressView().tint(Theme.accent) }
                else if items.isEmpty && error == nil { Text("You have no notifications").foregroundColor(Theme.muted) }
            }
            .padding(16)
            .padding(.bottom, unread > 0 ? 56 : 0)   // room so the floating button never covers the last card
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if unread > 0 {
                Button { Task { await markAllRead() } } label: {
                    Label("Mark all read", systemImage: "checkmark.circle.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .foregroundColor(Theme.bg)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                }
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: unread > 0)
        .refreshable { await load() }
        .task {
            await OfflineCache.paintFromCache { await load() }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load() } }
        .onFreshData { await load() }
    }

    private func load() async {
        guard app.site?.userid != nil else { loading = false; return }
        do {
            let r: NotifResp = try await MoodleAPI.shared.call(
                "message_popup_get_popup_notifications", ["useridto": uid])
            items = r.notifications
            await badge.refresh(uid: uid)
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }

    // Opening a notification marks it read (on the server too), so the tab badge goes down
    private func markRead(_ n: Notif) async {
        guard !isRead(n) else { return }
        readIds.insert(n.id)
        badge.count = max(badge.count - 1, 0)
        _ = try? await MoodleAPI.shared.raw("core_message_mark_notification_read", ["notificationid": n.id])
    }

    private func markAllRead() async {
        for n in items { readIds.insert(n.id) }
        badge.count = 0
        _ = try? await MoodleAPI.shared.raw("core_message_mark_all_notifications_as_read", ["useridto": uid])
    }
}

// MARK: - Profile

/// Screens in Others that are opened by value, so the open one can be kept when the tabs are rebuilt for a new theme
enum OthersRoute: Hashable { case themes }

struct ProfileView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var todos: TodoStore
    @EnvironmentObject var driveAuth: DriveAuth
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var studyPlan = StudyPlanStore.shared
    @ObservedObject private var autoAtt = AutoAttendance.shared

    /// "AFIQ TAUFIQ BIN MUHAMMAD 2412345" -> "Afiq Taufiq bin Muhammad 2412345" (full name and matric number under My Profile)
    private var shortName: String {
        let words = (app.site?.fullname ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "Your details" }
        let particles: Set<String> = ["bin", "binti", "bt", "bte", "b", "a/l", "a/p"]
        return words.map { w in
            if w.allSatisfy(\.isNumber) { return w }
            let l = w.lowercased()
            return particles.contains(l) ? l : l.prefix(1).uppercased() + l.dropFirst()
        }.joined(separator: " ")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Theme.font(.footnote).weight(.semibold)).foregroundColor(Theme.muted)
            .textCase(.uppercase).padding(.horizontal, 6).padding(.bottom, -8)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. account
                sectionTitle("Account")
                VStack(spacing: 0) {
                    NavigationLink {
                        UserProfileView(userid: app.site?.userid ?? 0,
                                        name: app.site?.fullname ?? "My Profile",
                                        imageURL: app.site?.userpictureurl)
                    } label: {
                        ProfileRow(icon: "person.crop.circle", title: "My Profile",
                                   subtitle: shortName, subtitleLines: 2, showLine: false)
                    }
                }
                .buttonStyle(.plain)
                .glowCard()

                // 2. Academic Tools
                sectionTitle("Academic Tools")
                VStack(spacing: 0) {
                    NavigationLink { TodoListView() } label: {
                        let n = todos.pending.count
                        ProfileRow(icon: "todo.book", title: "To-Do List",
                                   subtitle: n == 0 ? "Nothing to do" : "\(n) to do", badge: n, showLine: true)
                    }
                    NavigationLink { CAMSCalculatorScreen() } label: {
                        ProfileRow(icon: "function", title: "Final Exam Calculator",
                                   subtitle: "Marks needed in the final exam", showLine: true)
                    }
                    NavigationLink { MyDriveView() } label: {
                        ProfileRow(icon: "externaldrive", title: "My Drive",
                                   subtitle: driveAuth.email ?? "Browse your Google Drive", showLine: true)
                    }
                    NavigationLink { AutoAttendanceView() } label: {
                        ProfileRow(icon: "checkmark.circle", title: "Auto Attendance",
                                   subtitle: autoAtt.state.master ? "On · \(autoAtt.enabledCount) subject\(autoAtt.enabledCount == 1 ? "" : "s")" : "Off",
                                   showLine: true)
                    }
                    NavigationLink { StudyPlanTrackerView() } label: {
                        ProfileRow(icon: "calendar.badge.checkmark", title: "Study Plan Tracker",
                                   subtitle: studyPlan.plan == nil ? "Upload your study plan PDF"
                                       : "\(Int((studyPlan.percent * 100).rounded()))% · \(Int(studyPlan.creditsTaken)) of \(Int(studyPlan.totalRequired)) credits",
                                   showLine: true)
                    }
                    NavigationLink { SemesterResourcesView() } label: {
                        ProfileRow(icon: "books.vertical", title: "Semester Resources",
                                   subtitle: "Academic calendar, weekly calendar, CS study plan", showLine: false)
                    }
                }
                .buttonStyle(.plain)
                .glowCard()

                // 3. App Preferences
                sectionTitle("App Preferences")
                VStack(spacing: 0) {
                    NavigationLink(value: OthersRoute.themes) {
                        ProfileRow(icon: "paintpalette", title: "Themes",
                                   subtitle: themes.theme.name, showLine: true)
                    }
                    OfflineSupportRow()
                    Rectangle().fill(Theme.line).frame(height: 1)
                    SyncStatusRow()
                }
                .buttonStyle(.plain)
                .glowCard()

                // sign out, below everything else
                Button(role: .destructive) {
                    SiteBrowser.wipeSession(); AttendanceStore.clear()
                    UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
                    app.signOut()
                } label: {
                    Text("Sign out").font(Theme.font(.subheadline).weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.surface2).foregroundColor(.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 6)
            }
            .padding(24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Others")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProfileRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge = 0
    var subtitleLines = 1
    var showLine = true

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if icon == "todo.book" { TodoBookIcon(size: 22) } else { Image(systemName: icon) }
            }.foregroundColor(Theme.accent).frame(width: 26).textGlow()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundColor(Theme.txt).textGlow(radius: 3).rocksHeading(12, normal: .subheadline.weight(.semibold), pt: 15)
                Text(subtitle).font(Theme.font(.caption)).foregroundColor(Theme.muted).lineLimit(subtitleLines)
            }
            Spacer()
            if badge > 0 {
                Text("\(badge)").font(Theme.font(.caption).weight(.bold)).foregroundColor(Theme.onAccent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent).clipShape(Capsule())
            }
            Image(systemName: "chevron.right").font(Theme.font(.caption)).foregroundColor(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(Rectangle().fill(Theme.line).frame(height: showLine ? 1 : 0), alignment: .bottom)
    }
}

// The calculator lives on its own screen (Others > Final Exam Calculator)
struct CAMSCalculatorScreen: View {
    var body: some View {
        ScrollView {
            FinalExamCalculator().padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }.foregroundColor(Theme.accent)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Final Exam Calculator")
        .navigationBarTitleDisplayMode(.inline)
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Final exam calculator

struct FinalExamCalculator: View {
    private enum Weight: Hashable { case sixty, fifty, custom }
    private enum Field { case cams, custom }

    private struct GradeRow: Identifiable {
        let id: String
        let letter: String
        let threshold: Double
        let remark: String
    }

    // Lowest grade shown is B-
    private let grades: [GradeRow] = [
        .init(id: "A",  letter: "A",  threshold: 80, remark: "Excellent"),
        .init(id: "A-", letter: "A-", threshold: 75, remark: "Extremely Good"),
        .init(id: "B+", letter: "B+", threshold: 70, remark: "Very Good"),
        .init(id: "B",  letter: "B",  threshold: 65, remark: "Good"),
        .init(id: "B-", letter: "B-", threshold: 60, remark: "Fairly Good")
    ]

    @State private var weight: Weight = .sixty
    @State private var customText = ""
    @State private var camsText = ""
    @FocusState private var focus: Field?

    private func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// CAMS total (what the coursework is marked out of)
    private var camsTotal: Double? {
        switch weight {
        case .sixty: return 60
        case .fifty: return 50
        case .custom:
            guard let v = number(customText), v > 0, v < 100 else { return nil }
            return v
        }
    }
    private var examTotal: Double? { camsTotal.map { 100 - $0 } }
    private var cams: Double? { number(camsText) }

    private var customInvalid: Bool {
        weight == .custom && !customText.isEmpty && camsTotal == nil
    }
    private var camsInvalid: Bool {
        guard let c = cams, let t = camsTotal else { return !camsText.isEmpty && cams == nil }
        return c < 0 || c > t
    }
    private var ready: Bool { camsTotal != nil && cams != nil && !camsInvalid }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            weightPicker

            if weight == .custom {
                inputRow(title: "CAMS total", suffix: "marks", placeholder: "e.g. 70",
                         text: $customText, field: .custom, invalid: customInvalid)
            }

            inputRow(title: "Your CAMS mark",
                     suffix: camsTotal.map { "/ \(clean($0))" } ?? "/ ?",
                     placeholder: "0", text: $camsText, field: .cams, invalid: camsInvalid)

            if customInvalid {
                hint("CAMS total must be between 1 and 99.")
            } else if camsInvalid, let t = camsTotal {
                hint("CAMS mark must be between 0 and \(clean(t)).")
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            if ready, let c = cams, let e = examTotal {
                results(cams: c, exam: e)
            } else {
                Text("Enter your CAMS mark to see what you need in the final exam.")
                    .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .glowCard()
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "function").foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Final Exam Calculator").font(Theme.font(.headline)).foregroundColor(Theme.txt)
                Text("Marks needed for each grade").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            }
            Spacer()
            if focus != nil {
                Button { focus = nil; hideKeyboard() } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                        .labelStyle(.iconOnly).font(Theme.font(.title3)).foregroundColor(Theme.accent)
                }
            }
        }
    }

    private var weightPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAMS is out of").font(Theme.font(.caption).weight(.medium)).foregroundColor(Theme.muted)
            HStack(spacing: 8) {
                chip("60", .sixty)
                chip("50", .fifty)
                chip("Custom", .custom)
            }
        }
    }

    private func chip(_ title: String, _ value: Weight) -> some View {
        let on = weight == value
        return Button {
            weight = value
            focus = nil
        } label: {
            Text(title)
                .font(Theme.font(.subheadline).weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(on ? Theme.accent : Theme.surface2)
                .foregroundColor(on ? Theme.onAccent : Theme.txt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? Theme.accent : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func inputRow(title: String, suffix: String, placeholder: String,
                          text: Binding<String>, field: Field, invalid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.font(.caption).weight(.medium)).foregroundColor(Theme.muted)
            HStack {
                TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.muted.opacity(0.6)))
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: field)
                    .foregroundColor(Theme.txt)
                Text(suffix).foregroundColor(Theme.muted).font(Theme.font(.subheadline))
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(invalid ? Color.red.opacity(0.7) : (focus == field ? Theme.accent : Theme.line), lineWidth: 1))
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(Theme.font(.footnote)).foregroundColor(.red.opacity(0.85))
    }

    private func results(cams: Double, exam: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Grade").frame(width: 56, alignment: .leading)
                Text("Remark")
                Spacer()
                Text("Exam needed (/\(clean(exam)))")
            }
            .font(Theme.font(.caption).weight(.medium)).foregroundColor(Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.titleBar)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            ForEach(Array(grades.enumerated()), id: \.element.id) { i, g in
                let needed = ceil((g.threshold - cams) * 100) / 100
                HStack {
                    Text(g.letter).font(Theme.font(.headline)).foregroundColor(Theme.accent)
                        .frame(width: 56, alignment: .leading)
                    Text(g.remark).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                    Spacer()
                    outcome(needed: needed, exam: exam)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                if i < grades.count - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func outcome(needed: Double, exam: Double) -> some View {
        if needed <= 0 {
            Label("Secured", systemImage: "checkmark.circle.fill")
                .font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.accent)
        } else if needed > exam {
            Text("Not achievable").font(Theme.font(.subheadline)).foregroundColor(.red.opacity(0.8))
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(clean(needed / exam * 100))%")
                    .font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.txt)
                Text("\(clean(needed)) / \(clean(exam))")
                    .font(Theme.font(.caption2)).foregroundColor(Theme.muted)
            }
        }
    }

    private func clean(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}

// MARK: - Tab badge colour

// Colours the tab badges (Tasks, Alerts) in the app's accent without a custom UITabBarAppearance.
//
// On iOS 26 a custom UITabBarAppearance makes the glass tab bar lay its items out unevenly, so there the
// appearance is left alone (see Theme.applyAppearance) and the badge colour is set on the UITabBarItems here.
// SwiftUI's own .badge draws the badge and may reset the colour, so it is applied again:
//   - on every layout pass of the tab bar controller (before the frame is drawn, so no red flash), and
//   - whenever an item's badgeValue changes (key-value observing, in the same run-loop pass as the change).
//
// Put it as a .background of a tab that is loaded at launch (the first tab); it finds the UITabBarController
// that SwiftUI built through its parent chain.
struct TabBadgeTint: UIViewControllerRepresentable {
    let color: UIColor
    let text: UIColor

    func makeUIViewController(context: Context) -> TabBadgeProbe { TabBadgeProbe() }

    func updateUIViewController(_ vc: TabBadgeProbe, context: Context) {
        vc.color = color
        vc.text = text
        vc.apply()
    }
}

final class TabBadgeProbe: UIViewController {
    var color: UIColor = .systemRed
    var text: UIColor = .white
    private var observers: [NSKeyValueObservation] = []
    private var observedItems: [ObjectIdentifier] = []

    override func loadView() {
        let v = UIView()
        v.isUserInteractionEnabled = false
        view = v
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        apply()
    }

    func apply() {
        guard let items = tabBarController?.tabBar.items else { return }
        for item in items { paint(item) }

        // Watch each item's badge so a new count is painted straight away. Only re-created when the items change
        // (a theme switch rebuilds the whole TabView).
        let ids = items.map { ObjectIdentifier($0) }
        guard ids != observedItems else { return }
        observedItems = ids
        observers = items.map { item in
            item.observe(\.badgeValue, options: [.new]) { [weak self] item, _ in
                self?.paint(item)
            }
        }
    }

    private func paint(_ item: UITabBarItem) {
        if item.badgeColor != color { item.badgeColor = color }
        item.setBadgeTextAttributes([.foregroundColor: text], for: .normal)
        item.setBadgeTextAttributes([.foregroundColor: text], for: .selected)
    }
}

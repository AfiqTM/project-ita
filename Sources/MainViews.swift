import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var assignments = AssignmentsModel()
    @StateObject private var notifs = NotifBadgeModel()
    @StateObject private var browser = SiteBrowser()

    init() {
        // Tab badges in the app's accent colour with dark text. SwiftUI's .badge ignores
        // UITabBarItem.appearance().badgeColor, so it is set through UITabBarAppearance instead.
        // Starts from the tab bar appearance already set elsewhere (if any) so its look is kept.
        let std = (UITabBar.appearance().standardAppearance.copy() as? UITabBarAppearance) ?? UITabBarAppearance()
        let edge = (UITabBar.appearance().scrollEdgeAppearance?.copy() as? UITabBarAppearance) ?? std
        let color = UIColor(Theme.accent)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.black]
        for ap in [std, edge] {
            for item in [ap.stackedLayoutAppearance, ap.inlineLayoutAppearance, ap.compactInlineLayoutAppearance] {
                item.normal.badgeBackgroundColor = color
                item.normal.badgeTextAttributes = attrs
                item.selected.badgeBackgroundColor = color
                item.selected.badgeTextAttributes = attrs
            }
        }
        UITabBar.appearance().standardAppearance = std
        UITabBar.appearance().scrollEdgeAppearance = edge
    }

    var body: some View {
        TabView {
            NavigationStack { CoursesView() }
                .tabItem { Label("My courses", systemImage: "books.vertical") }
            NavigationStack { AssignmentsTabView(model: assignments) }
                .tabItem { Label("Assignments", systemImage: "checklist") }
                .badge(assignments.badgeCount)   // to-do items due inside the range chosen in the tab
            NavigationStack { AlertsView(badge: notifs) }
                .tabItem { Label("Alerts", systemImage: "bell") }
                .badge(notifs.count)   // unread notifications
            NavigationStack { SiteBrowserView(browser: browser) }
                .tabItem { Label("Website", systemImage: "globe") }
            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person") }
        }
        // Load at launch so the badges are right before either tab is opened
        .task(id: app.site?.userid) {
            if let uid = app.site?.userid { await assignments.load(uid: uid) }
        }
        // Home-screen widget data (maximum possible attendance per subject)
        .task(id: app.site?.userid) {
            if let uid = app.site?.userid { await AttendanceSync.refresh(userid: uid) }
        }
        // Unread alerts: check now, then once a minute while the app is open
        .task(id: app.site?.userid) {
            guard let uid = app.site?.userid else { return }
            while !Task.isCancelled {
                await notifs.refresh(uid: uid)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, let uid = app.site?.userid else { return }
            Task {
                await notifs.refresh(uid: uid)
                await assignments.load(uid: uid)
                await AttendanceSync.refresh(userid: uid)
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Hello,").foregroundColor(Theme.muted)
                    Text(firstTwoNames).foregroundColor(Theme.accent).fontWeight(.semibold)
                }
                .font(.title3)

                searchBar
                suggestionList

                filterBar

                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }

                LazyVStack(spacing: 22) {
                    ForEach(visibleCourses) { c in
                        let starred = favOverride[c.id] ?? c.isfavourite ?? false
                        ZStack(alignment: .topTrailing) {
                            NavigationLink { CourseDetailView(course: c) } label: { CourseCard(course: c) }
                                .buttonStyle(.plain)
                            if filter == .hidden {
                                Button { Task { await toggleHide(c) } } label: {
                                    Label("Show again", systemImage: "eye")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Theme.accent)
                                        .clipShape(Capsule())
                                }
                                .padding(10)
                            } else {
                                Button { Task { await toggleStar(c) } } label: {
                                    Image(systemName: starred ? "star.fill" : "star")
                                        .foregroundColor(starred ? Theme.accent : Color.white.opacity(0.85))
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
        .task(id: filter) { await load() }
        .task { await loadAll() }
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
                            Image(systemName: "book.closed").font(.footnote).foregroundColor(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.fullname).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                                if let sn = c.shortname, !sn.isEmpty {
                                    Text(sn).font(.caption).foregroundColor(Theme.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(Theme.muted)
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
                    }
                }
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover.frame(height: 110).frame(maxWidth: .infinity).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(course.fullname)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.txt)
                    .multilineTextAlignment(.leading)
                if let p = course.progress {
                    ProgressView(value: min(max(p, 0), 100), total: 100).tint(Theme.accent)
                    Text("\(Int(p))% complete").font(.caption).foregroundColor(Theme.muted)
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
                case .success(let img): img.resizable().scaledToFill().brightness(-0.2)
                default: DefaultCover(course: course)
                }
            }
        } else {
            DefaultCover(course: course)
        }
    }
}

// Used when a course has no (usable) image: a dark tonal gradient picked per course
struct DefaultCover: View {
    let course: Course
    private static let palettes: [(UInt32, UInt32)] = [
        (0x1b1712, 0x3a2f22), (0x14181c, 0x2c3a46), (0x1a1417, 0x3d2a33),
        (0x121a16, 0x263b2f), (0x181510, 0x4a3a22), (0x15151c, 0x302f4a)]

    var body: some View {
        let p = Self.palettes[abs(course.id) % Self.palettes.count]
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 64))
                .foregroundColor(Theme.accent.opacity(0.14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            Text(course.shortname ?? "")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.accent.opacity(0.9))
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
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                ForEach(items) { n in
                    let card = VStack(alignment: .leading, spacing: 4) {
                        Text(n.subject ?? "Notification")
                            .foregroundColor(Theme.txt).fontWeight(isRead(n) ? .regular : .semibold)
                        if let m = n.smallmessage, !m.isEmpty {
                            Text(m.plainText).font(.caption).foregroundColor(Theme.muted).lineLimit(3)
                        }
                        Text(fmt(n.timecreated)).font(.caption2).foregroundColor(Theme.muted)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(isRead(n) ? Theme.bg : Theme.surface2)
                    .glowCard()

                    if let s = n.contexturl, let u = URL(string: s) {
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
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if unread > 0 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Mark all read") { Task { await markAllRead() } }
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
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

struct ProfileView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let s = app.site?.userpictureurl, let u = MoodleAPI.shared.fileURL(s) {
                    AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Theme.surface2 }
                        .frame(width: 96, height: 96).clipShape(Circle())
                }
                Text(app.site?.fullname ?? "").font(.title3.weight(.semibold)).foregroundColor(Theme.txt)
                Text(app.site?.sitename ?? "iTa'leem").foregroundColor(Theme.muted)

                FinalExamCalculator()
                    .padding(.top, 6)

                Button(role: .destructive) { SiteBrowser.wipeSession(); AttendanceStore.clear(); app.signOut() } label: {
                    Text("Sign out").frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.surface2).foregroundColor(.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 6)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }.foregroundColor(Theme.accent)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Profile")
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
                    .font(.footnote).foregroundColor(Theme.muted)
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
                Text("Final exam calculator").font(.headline).foregroundColor(Theme.txt)
                Text("Marks needed for each grade").font(.caption).foregroundColor(Theme.muted)
            }
            Spacer()
            if focus != nil {
                Button { focus = nil; hideKeyboard() } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                        .labelStyle(.iconOnly).font(.title3).foregroundColor(Theme.accent)
                }
            }
        }
    }

    private var weightPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAMS is out of").font(.caption.weight(.medium)).foregroundColor(Theme.muted)
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
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(on ? Theme.accent : Theme.surface2)
                .foregroundColor(on ? .black : Theme.txt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? Theme.accent : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func inputRow(title: String, suffix: String, placeholder: String,
                          text: Binding<String>, field: Field, invalid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundColor(Theme.muted)
            HStack {
                TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.muted.opacity(0.6)))
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: field)
                    .foregroundColor(Theme.txt)
                Text(suffix).foregroundColor(Theme.muted).font(.subheadline)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(invalid ? Color.red.opacity(0.7) : (focus == field ? Theme.accent : Theme.line), lineWidth: 1))
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.footnote).foregroundColor(.red.opacity(0.85))
    }

    private func results(cams: Double, exam: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Grade").frame(width: 56, alignment: .leading)
                Text("Remark")
                Spacer()
                Text("Exam needed (/\(clean(exam)))")
            }
            .font(.caption.weight(.medium)).foregroundColor(Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.titleBar)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            ForEach(Array(grades.enumerated()), id: \.element.id) { i, g in
                let needed = ceil((g.threshold - cams) * 100) / 100
                HStack {
                    Text(g.letter).font(.headline).foregroundColor(Theme.accent)
                        .frame(width: 56, alignment: .leading)
                    Text(g.remark).font(.footnote).foregroundColor(Theme.muted)
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
                .font(.subheadline.weight(.semibold)).foregroundColor(Theme.accent)
        } else if needed > exam {
            Text("Not achievable").font(.subheadline).foregroundColor(.red.opacity(0.8))
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(clean(needed / exam * 100))%")
                    .font(.subheadline.weight(.semibold)).foregroundColor(Theme.txt)
                Text("\(clean(needed)) / \(clean(exam))")
                    .font(.caption2).foregroundColor(Theme.muted)
            }
        }
    }

    private func clean(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(format: "%.2f", r).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}

import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { CoursesView() }
                .tabItem { Label("My courses", systemImage: "books.vertical") }
            NavigationStack { AlertsView() }
                .tabItem { Label("Alerts", systemImage: "bell") }
            NavigationStack {
                WebActivityView(url: Site.url.appendingPathComponent("my/"), title: "iTa'leem")
            }
            .tabItem { Label("Website", systemImage: "globe") }
            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person") }
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
    case assignments = "Assignments"

    var id: String { rawValue }
    var classification: String {
        switch self {
        case .all, .assignments: return "all"
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
    @State private var events: [TLEvent] = []
    @State private var loading = false
    @State private var error: String?

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

                filterBar

                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }

                if filter == .assignments {
                    AssignmentsList(events: events)
                } else {
                    LazyVStack(spacing: 22) {
                        ForEach(courses) { c in
                            NavigationLink { CourseDetailView(course: c) } label: { CourseCard(course: c) }
                                .buttonStyle(.plain)
                        }
                    }
                    if !loading && courses.isEmpty && error == nil {
                        Text("No courses here.").foregroundColor(Theme.muted)
                    }
                }
                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load(); await loadEvents() }
        .task(id: filter) { await load() }
        .task { await loadEvents() }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(CourseFilter.allCases) { f in
                    Button { filter = f } label: {
                        HStack(spacing: 6) {
                            Text(f.rawValue)
                                .fontWeight(filter == f ? .semibold : .regular)
                                .foregroundColor(filter == f ? Theme.accent : Theme.txt)
                            if f == .assignments && !events.isEmpty {
                                Text("\(events.count)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.accent)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard filter != .assignments else { return }
        loading = true; error = nil
        do {
            let r: CourseList = try await MoodleAPI.shared.call(
                "core_course_get_enrolled_courses_by_timeline_classification",
                ["classification": filter.classification, "limit": 0, "offset": 0, "sort": "fullname"])
            courses = r.courses
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }

    private func loadEvents() async {
        let now = Int(Date().timeIntervalSince1970)
        do {
            let r: EventsResp = try await MoodleAPI.shared.call(
                "core_calendar_get_action_events_by_timesort",
                ["timesortfrom": now - 7 * 86400, "timesortto": now + 30 * 86400,
                 "limitnum": 50, "limittononsuspendedevents": 1])
            events = r.events
        } catch { /* leave empty */ }
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

    private var placeholder: some View {
        LinearGradient(colors: [Theme.surface2, Theme.accent.opacity(0.25)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder private var cover: some View {
        if let s = course.courseimage, s.hasPrefix("http"), let u = MoodleAPI.shared.fileURL(s) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill().brightness(-0.2)
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }
}

// MARK: - Assignments (Timeline)

struct AssignmentsList: View {
    let events: [TLEvent]

    private var days: [(Date, [TLEvent])] {
        let g = Dictionary(grouping: events) {
            Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.timesort)))
        }
        return g.keys.sorted().map { ($0, g[$0]!.sorted { $0.timesort < $1.timesort }) }
    }

    var body: some View {
        if events.isEmpty {
            Text("No activities require action.").foregroundColor(Theme.muted)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(days, id: \.0) { day, list in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(day.formatted(date: .complete, time: .omitted))
                            .font(.footnote.weight(.semibold)).foregroundColor(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(list) { e in row(e) }
                        }
                        .glowCard()
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ e: TLEvent) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(e.name).foregroundColor(Theme.txt).fontWeight(.medium).multilineTextAlignment(.leading)
            if let c = e.course { Text(c.fullname).font(.caption).foregroundColor(Theme.muted) }
            Text(fmt(e.timesort, time: true)).font(.caption).foregroundColor(Theme.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)

        if let s = e.url, let u = URL(string: s) {
            NavigationLink { WebActivityView(url: u, title: e.name) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Alerts

struct AlertsView: View {
    @EnvironmentObject var app: AppState
    @State private var items: [Notif] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                ForEach(items) { n in
                    let card = VStack(alignment: .leading, spacing: 4) {
                        Text(n.subject ?? "Notification")
                            .foregroundColor(Theme.txt).fontWeight(n.read == true ? .regular : .semibold)
                        if let m = n.smallmessage, !m.isEmpty {
                            Text(m.plainText).font(.caption).foregroundColor(Theme.muted).lineLimit(3)
                        }
                        Text(fmt(n.timecreated)).font(.caption2).foregroundColor(Theme.muted)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(n.read == true ? Theme.bg : Theme.surface2)
                    .glowCard()

                    if let s = n.contexturl, let u = URL(string: s) {
                        NavigationLink { WebActivityView(url: u, title: n.subject ?? "Notification") } label: { card }
                            .buttonStyle(.plain)
                    } else { card }
                }
                if loading { ProgressView().tint(Theme.accent) }
                else if items.isEmpty && error == nil { Text("You have no notifications").foregroundColor(Theme.muted) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let uid = app.site?.userid else { loading = false; return }
        do {
            let r: NotifResp = try await MoodleAPI.shared.call(
                "message_popup_get_popup_notifications", ["useridto": uid])
            items = r.notifications
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

// MARK: - Profile

struct ProfileView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 18) {
            if let s = app.site?.userpictureurl, let u = MoodleAPI.shared.fileURL(s) {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Theme.surface2 }
                    .frame(width: 96, height: 96).clipShape(Circle())
            }
            Text(app.site?.fullname ?? "").font(.title3.weight(.semibold)).foregroundColor(Theme.txt)
            Text(app.site?.sitename ?? "iTa'leem").foregroundColor(Theme.muted)
            Button(role: .destructive) { app.signOut() } label: {
                Text("Sign out").frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.surface2).foregroundColor(.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 16)
            Spacer()
        }
        .padding(24)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

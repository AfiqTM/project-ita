import SwiftUI
import UserNotifications

// Profile screen for another student (opened from a course's Participants list), modelled on the
// Moodle website profile: header + Message button, stats, and About Me / Courses / More Details tabs.
// Uses only the web-service token. Fields the site hides from students simply don't appear.

// MARK: - Models (all optional: what you can see depends on the site's privacy settings)

struct UPField: Decodable { let name: String?; let value: String?; let shortname: String? }
struct UPGroup: Decodable { let id: Int?; let name: String? }
struct UPRole: Decodable { let roleid: Int?; let name: String?; let shortname: String? }
struct UPCourse: Decodable, Identifiable { let id: Int; let fullname: String?; let shortname: String? }
struct UPBadge: Decodable, Identifiable { let id: Int; let name: String?; let badgeurl: String? }
struct UPBadges: Decodable { let badges: [UPBadge]? }

struct UserProfileData: Decodable {
    let id: Int
    let fullname: String?
    let firstname: String?
    let lastname: String?
    let email: String?
    let department: String?
    let institution: String?
    let city: String?
    let country: String?
    let address: String?
    let phone1: String?
    let phone2: String?
    let interests: String?
    let description: String?
    let firstaccess: Int?
    let lastaccess: Int?
    let profileimageurl: String?
    let customfields: [UPField]?
    let groups: [UPGroup]?
    let roles: [UPRole]?
    let enrolledcourses: [UPCourse]?
}

private enum ProfTab: String, CaseIterable, Identifiable {
    case about = "About Me", courses = "Courses", more = "More Details"
    var id: String { rawValue }
}

// MARK: - View

struct UserProfileView: View {
    let userid: Int
    var courseId = 0
    let name: String
    var imageURL: String? = nil

    @EnvironmentObject var app: AppState
    @State private var p: UserProfileData?
    @State private var badges: [UPBadge] = []
    @State private var tab: ProfTab = .about
    @State private var loading = true
    @State private var note: String?

    private var myId: Int { app.site?.userid ?? 0 }
    private var displayName: String { p?.fullname ?? name }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM yyyy, h:mm a"; return f
    }()
    private func dateText(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "Never" }
        return Self.df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if userid != myId { messageButton }
                statsCard
                tabBar
                switch tab {
                case .about: aboutTab
                case .courses: coursesTab
                case .more: moreTab
                }
                if let note { Text(note).font(.footnote).foregroundColor(Theme.muted) }
                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                if userid == myId { signOutButton }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    // ---- sign out (own profile only) ----

    private var signOutButton: some View {
        Button(role: .destructive) {
            SiteBrowser.wipeSession(); AttendanceStore.clear()
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
            app.signOut()
        } label: {
            Text("Sign out").frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.surface2).foregroundColor(.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.top, 6)
    }

    // ---- header ----

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            NavigationLink {
                PhotoViewer(name: displayName, urls: [p?.profileimageurl, imageURL])
            } label: {
                ProfilePhoto(name: displayName, urls: [p?.profileimageurl, imageURL], size: 84)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 8) {
                Text(displayName).font(.title3.bold()).foregroundColor(Theme.txt)
                if let la = p?.lastaccess {
                    (Text("Last access ").fontWeight(.semibold) + Text(dateText(la)))
                        .font(.caption).foregroundColor(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var messageButton: some View {
        NavigationLink {
            ChatOpenView(userid: userid, name: displayName, imageURL: imageURL ?? p?.profileimageurl)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "message")
                Text("Message")
            }
            .fontWeight(.semibold).foregroundColor(.black)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // ---- stats ----

    private var statsCard: some View {
        HStack {
            stat(p?.enrolledcourses?.count ?? 0, "Courses")
            stat(p?.groups?.count ?? 0, "Groups")
            stat(badges.count, "Badges")
        }
        .padding(.vertical, 16)
        .glowCard()
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(n)").font(.title.bold()).foregroundColor(Theme.txt)
            Text(label).font(.caption).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // ---- tabs ----

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(ProfTab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue)
                            .fontWeight(tab == t ? .semibold : .regular)
                            .foregroundColor(tab == t ? Theme.accent : Theme.txt)
                        Rectangle().fill(tab == t ? Theme.accent : Color.clear).frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    private func fieldView(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.subheadline.weight(.semibold)).foregroundColor(Theme.txt)
            Text(v).font(.subheadline).foregroundColor(Theme.muted).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // About Me

    private var shortFields: [(String, String)] {
        guard let p else { return [] }
        var f: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let t = clean(v) { f.append((k, t)) } }
        add("First name", p.firstname)
        add("Last name", p.lastname)
        add("Department", p.department)
        add("Institution", p.institution)
        add("City/town", p.city)
        if let c = clean(p.country) { add("Country", Locale.current.localizedString(forRegionCode: c) ?? c) }
        add("Phone", p.phone1)
        add("Mobile", p.phone2)
        return f
    }

    private var wideFields: [(String, String)] {
        guard let p else { return [] }
        var f: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let t = clean(v) { f.append((k, t)) } }
        add("Email address", p.email)
        add("Address", p.address)
        add("Interests", p.interests)
        return f
    }

    @ViewBuilder private var aboutTab: some View {
        let desc = clean(p?.description?.plainText)
        if shortFields.isEmpty && wideFields.isEmpty && desc == nil {
            if !loading { Text("Nothing to show here.").foregroundColor(Theme.muted) }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if let desc { fieldView("About", desc) }
                if !wideFields.isEmpty {
                    ForEach(wideFields, id: \.0) { f in fieldView(f.0, f.1) }
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                    GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 18) {
                    ForEach(shortFields, id: \.0) { f in fieldView(f.0, f.1) }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glowCard()
        }
    }

    // Courses

    @ViewBuilder private var coursesTab: some View {
        let list = p?.enrolledcourses ?? []
        if list.isEmpty {
            if !loading { Text("No courses to show.").foregroundColor(Theme.muted) }
        } else {
            VStack(spacing: 0) {
                ForEach(list) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.fullname ?? c.shortname ?? "Course").foregroundColor(Theme.txt)
                        if let s = c.shortname, s != c.fullname {
                            Text(s).font(.caption).foregroundColor(Theme.muted)
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                }
            }
            .glowCard()
        }
    }

    // More Details

    private var moreRows: [(String, String)] {
        var f: [(String, String)] = []
        if let p {
            let roles = (p.roles ?? []).compactMap { r -> String? in
                let n = (r.name?.isEmpty == false ? r.name : r.shortname)
                return n?.capitalized
            }
            if !roles.isEmpty { f.append(("Roles", roles.joined(separator: ", "))) }
            let groups = (p.groups ?? []).compactMap { clean($0.name) }
            if !groups.isEmpty { f.append(("Groups", groups.joined(separator: ", "))) }
            f.append(("First access to site", dateText(p.firstaccess)))
            f.append(("Last access to site", dateText(p.lastaccess)))
            for cf in p.customfields ?? [] {
                if let n = clean(cf.name), let v = clean(cf.value?.plainText) { f.append((n, v)) }
            }
        }
        let b = badges.compactMap { clean($0.name) }
        if !b.isEmpty { f.append(("Badges", b.joined(separator: ", "))) }
        return f
    }

    @ViewBuilder private var moreTab: some View {
        let rows = moreRows
        if rows.isEmpty {
            if !loading { Text("Nothing to show here.").foregroundColor(Theme.muted) }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows, id: \.0) { f in fieldView(f.0, f.1) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glowCard()
        }
    }

    // ---- loading ----

    private func load() async {
        defer { loading = false }
        var got: UserProfileData?
        if courseId > 0 {
            let r: [UserProfileData]? = try? await MoodleAPI.shared.call(
                "core_user_get_course_user_profiles",
                ["userlist": [["userid": userid, "courseid": courseId]]])
            got = r?.first
        }
        if got == nil {
            let r: [UserProfileData]? = try? await MoodleAPI.shared.call(
                "core_user_get_users_by_field", ["field": "id", "values": [userid]])
            got = r?.first
        }
        if let got { p = got; note = nil }
        else if p == nil { note = "More details aren't available for this person." }

        if let b: UPBadges = try? await MoodleAPI.shared.call("core_badges_get_user_badges", ["userid": userid]) {
            badges = b.badges ?? []
        }
    }
}

// MARK: - Profile photos

/// Candidate URLs for a profile picture, best first. Moodle serves each picture in sizes:
/// f1 = 100px, f2 = 35px, f3 = original. Each address is tried with the web-service token and without it,
/// and the address that already works in the participants list is kept as the last fallback.
enum PhotoURL {
    static func candidates(_ strings: [String?], size: String) -> [URL] {
        var out: [URL] = []
        func add(_ u: URL?) { if let u, !out.contains(u) { out.append(u) } }
        for case let s? in strings {
            let resized = s.replacingOccurrences(of: "/f[123](?=\\?|$)", with: "/\(size)",
                                                 options: .regularExpression)
            for v in (resized == s ? [s] : [resized, s]) {
                add(MoodleAPI.shared.fileURL(v))
                add(URL(string: v))
            }
        }
        return out
    }
}

private enum PhotoCache { static let store = NSCache<NSURL, UIImage>() }

/// Loads the first candidate URL that really returns an image (a failed one just moves on to the next).
struct RemoteImage<Placeholder: View>: View {
    let candidates: [URL]
    var contentMode: ContentMode
    var minPixels: CGFloat
    let placeholder: (Bool) -> Placeholder      // Bool = every candidate failed
    @State private var image: UIImage?
    @State private var failed = false

    init(candidates: [URL], contentMode: ContentMode = .fill, minPixels: CGFloat = 0,
         @ViewBuilder placeholder: @escaping (Bool) -> Placeholder) {
        self.candidates = candidates
        self.contentMode = contentMode
        self.minPixels = minPixels
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
            }
            else { placeholder(failed) }
        }
        .task(id: candidates) { await load() }
    }

    private func pixelWidth(_ i: UIImage) -> CGFloat { i.size.width * i.scale }

    /// Walks the candidates best-first (cache, then network). The first image that is sharp enough
    /// (>= minPixels wide) wins; a smaller one is only kept as a fallback, so a tiny thumbnail never
    /// sticks when a better version is available.
    private func load() async {
        image = nil; failed = false
        var best: UIImage?
        for u in candidates {
            var img = PhotoCache.store.object(forKey: u as NSURL)
            if img == nil {
                do {
                    let (d, r) = try await MoodleAPI.session.data(from: u)
                    if let h = r as? HTTPURLResponse, h.statusCode != 200 { continue }
                    if let got = UIImage(data: d) {
                        PhotoCache.store.setObject(got, forKey: u as NSURL)
                        img = got
                    }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                }
            }
            guard let img else { continue }
            if pixelWidth(img) >= minPixels { image = img; return }
            if best == nil || pixelWidth(img) > pixelWidth(best!) { best = img }
        }
        if let best { image = best } else { failed = true }
    }
}

/// Round avatar used in the profile header (falls back to initials).
struct ProfilePhoto: View {
    let name: String
    let urls: [String?]
    var size: CGFloat = 84

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Theme.surface2)
            Text(initials).font(.system(size: size * 0.36, weight: .semibold)).foregroundColor(Theme.accent)
            // f3 (large) first so it stays sharp on 3x screens; f1 / the list thumbnail are fallbacks
            RemoteImage(candidates: PhotoURL.candidates(urls, size: "f3") + PhotoURL.candidates(urls, size: "f1"),
                        minPixels: size * UIScreen.main.scale) { _ in Color.clear }
                .frame(width: size, height: size)
                .clipped()
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
    }
}

/// Full-size photo (opened by tapping the avatar). The navigation bar's back button returns to the profile.
/// Pinch to zoom, double-tap to zoom in / out.
struct PhotoViewer: View {
    let name: String
    let urls: [String?]
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteImage(candidates: PhotoURL.candidates(urls, size: "f3"), contentMode: .fit) { failed in
                if failed {
                    Text("No photo available").foregroundColor(Theme.muted)
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .scaleEffect(max(1, min(scale * pinch, 5)))
            .gesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in scale = max(1, min(scale * value, 5)) }
            )
            .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

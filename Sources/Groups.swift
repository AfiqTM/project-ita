import SwiftUI
import WebKit

// MARK: - Groups (course page tab + the "Group Selection" activity)
//
// Groups and their members come from core_enrol_get_enrolled_users, which already lists the groups of every
// participant. Joining / leaving uses the group-selection activity's own web-service functions
// (mod_choicegroup_*). If the site has not enabled those, the screen says so and offers the website page.

// MARK: Models

struct FlexInt: Decodable {
    let value: Int?
    init(value: Int?) { self.value = value }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self) { value = Int(s) }
        else if let b = try? c.decode(Bool.self) { value = b ? 1 : 0 }
        else { value = nil }
    }
}

struct ChoiceGroupOption: Decodable, Identifiable {
    private let rawId: FlexInt?
    let text: String?
    let maxanswers: FlexInt?
    let countanswers: FlexInt?
    let checked: FlexBool?
    let disabled: FlexBool?
    enum CodingKeys: String, CodingKey { case rawId = "id", text, maxanswers, countanswers, checked, disabled }
    /// A bare option built from the participant list (used when the activity's own functions are unavailable)
    init(id: Int, text: String) {
        rawId = FlexInt(value: id); self.text = text
        maxanswers = nil; countanswers = nil; checked = nil; disabled = nil
    }
    var id: Int { rawId?.value ?? 0 }
    var limit: Int { maxanswers?.value ?? 0 }       // 0 = no limit
    var count: Int? { countanswers?.value }
}
struct ChoiceGroupOptionsResp: Decodable { let options: [ChoiceGroupOption] }

struct CourseGroupInfo: Identifiable {
    let id: Int
    let name: String
    let about: String
    var members: [Person]
}

enum GroupBuilder {
    static func build(_ people: [Person], myId: Int) -> [CourseGroupInfo] {
        var byId: [Int: CourseGroupInfo] = [:]
        for p in people {
            for g in p.groups ?? [] {
                var info = byId[g.id] ?? CourseGroupInfo(id: g.id, name: (g.name ?? "Group \(g.id)").decodedEntities,
                                                         about: (g.description ?? "").plainText, members: [])
                info.members.append(p)
                byId[g.id] = info
            }
        }
        return byId.values.sorted {
            let a = $0.members.contains { $0.id == myId }, b = $1.members.contains { $0.id == myId }
            if a != b { return a }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: Shared pieces

private struct Avatar: View {
    let person: Person
    var size: CGFloat = 30
    var body: some View {
        AsyncImage(url: person.profileimageurlsmall.flatMap { MoodleAPI.shared.fileURL($0) }) { i in
            i.resizable().scaledToFill()
        } placeholder: { Theme.surface2 }
        .frame(width: size, height: size).clipShape(Circle())
    }
}

private struct MemberRow: View {
    let person: Person
    let courseId: Int
    let isMe: Bool
    var body: some View {
        NavigationLink {
            UserProfileView(userid: person.id, courseId: courseId, name: person.fullname,
                            imageURL: person.profileimageurlsmall)
        } label: {
            HStack(spacing: 12) {
                Avatar(person: person)
                (Text(person.fullname).foregroundColor(Theme.txt)
                    + Text(isMe ? "  (You)" : "").font(Theme.font(.footnote).weight(.bold)).foregroundColor(Theme.accent))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
        }
        .buttonStyle(.plain)
    }
}

private struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font(.caption2).weight(.bold)).foregroundColor(Theme.onAccent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.accent).clipShape(Capsule())
    }
}

/// Loads the course's participants once and keeps the group list built from them
@MainActor final class CourseGroupsModel: ObservableObject {
    @Published var people: [Person] = []
    @Published var groups: [CourseGroupInfo] = []
    @Published var loading = true
    @Published var error: String?

    func load(courseId: Int, myId: Int) async {
        do {
            people = try await MoodleAPI.shared.call("core_enrol_get_enrolled_users", ["courseid": courseId])
            groups = GroupBuilder.build(people, myId: myId)
            error = nil
        } catch {
            if !(error is CancellationError) {
                self.error = "Groups aren't available for this course (\(error.localizedDescription))"
            }
        }
        loading = false
    }
}

// MARK: - Group Selection (opened from the course page): all groups + join / switch / leave

private struct GroupEntry: Identifiable {
    let id: Int
    let name: String
    let about: String
    let members: [Person]
    let option: ChoiceGroupOption?     // nil = a group that isn't part of this selection activity
}

struct GroupChoiceView: View {
    let courseId: Int
    let module: Module
    @EnvironmentObject var app: AppState
    @StateObject private var model = CourseGroupsModel()
    @State private var options: [ChoiceGroupOption] = []
    @State private var chosen: Int?           // my current group in this activity
    @State private var overridden = false     // an action of mine is newer than any saved copy
    @State private var loading = true
    @State private var busy: Int?             // group id being changed
    @State private var message: String?
    @State private var unsupported = false
    @State private var leaving: GroupEntry?
    @State private var open: Set<Int> = []
    @State private var query = ""
    @State private var webAction: URL?        // join / leave runs on the site's own page (group select plugin)

    private var myId: Int { app.site?.userid ?? 0 }
    private var instance: Int { module.instance ?? 0 }
    private var webURL: URL { URL(string: module.url ?? "") ?? Site.url }
    /// The "Group self-selection" plugin (mod_groupselect) has no app web-service functions, unlike choicegroup:
    /// joining / leaving is done by opening the site's own select / unselect page and confirming it for you.
    private func actionURL(_ key: String, _ groupId: Int) -> URL {
        guard var c = URLComponents(url: webURL, resolvingAgainstBaseURL: false) else { return webURL }
        var items = (c.queryItems ?? []).filter { $0.name != "select" && $0.name != "unselect" }
        if !items.contains(where: { $0.name == "id" }) { items.append(URLQueryItem(name: "id", value: String(module.id))) }
        items.append(URLQueryItem(name: key, value: String(groupId)))
        c.queryItems = items
        return c.url ?? webURL
    }
    private var isGroupSelect: Bool { module.modname == "groupselect" || (module.url ?? "").contains("groupselect") }

    private var entries: [GroupEntry] {
        var out: [GroupEntry] = options.map { o in
            let g = model.groups.first { $0.id == o.id }
            return GroupEntry(id: o.id, name: (o.text ?? g?.name ?? "Group \(o.id)").plainText,
                              about: g?.about ?? "", members: g?.members ?? [], option: o)
        }
        let known = Set(out.map(\.id))
        out += model.groups.filter { !known.contains($0.id) }
            .map { GroupEntry(id: $0.id, name: $0.name, about: $0.about, members: $0.members, option: nil) }
        return out.sorted {
            let a = isMine($0), b = isMine($1)
            if a != b { return a }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func isMine(_ e: GroupEntry) -> Bool {
        e.option != nil ? chosen == e.id : e.members.contains { $0.id == myId }
    }

    private func memberCount(_ e: GroupEntry) -> Int {
        let extra = (isMine(e) && !e.members.contains { $0.id == myId } && overridden) ? 1 : 0
        return max(e.members.count, (e.option?.count ?? 0) + extra)
    }

    private var mine: [GroupEntry] { entries.filter { isMine($0) } }
    private var others: [GroupEntry] {
        let rest = entries.filter { !isMine($0) }
        guard !query.isEmpty else { return rest }
        return rest.filter { e in
            e.name.localizedCaseInsensitiveContains(query)
                || e.members.contains { $0.fullname.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let d = module.description?.plainText, !d.isEmpty {
                    Text(d).font(Theme.read(.subheadline)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message {
                    Text(message).font(Theme.font(.footnote)).foregroundColor(Theme.txt)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let error = model.error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }
                if unsupported {
                    VStack(spacing: 10) {
                        Text("This site may not allow joining groups from the app. If joining or leaving fails, use the website.")
                            .font(Theme.font(.footnote)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                        NavigationLink { WebActivityView(url: webURL, title: module.name) } label: {
                            Text("Open on the website").fontWeight(.semibold).foregroundColor(Theme.onAccent)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Theme.accent).clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity).padding(16).glowCard()
                }

                // my group with all its members
                if !mine.isEmpty {
                    sectionTitle(mine.count == 1 ? "My group" : "My groups")
                    ForEach(mine) { e in groupCard(e, forceOpen: true) }
                } else if !loading && model.error == nil {
                    VStack(spacing: 4) {
                        Text("You're not in a group yet").fontWeight(.semibold).foregroundColor(Theme.txt)
                        Text("Tap Join on a group below.").font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).padding(16).glowCard()
                }

                // everyone else
                if !entries.isEmpty {
                    sectionTitle("All groups")
                    TextField("Search groups or members", text: $query)
                        .foregroundColor(Theme.txt).padding(12)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    ForEach(others) { e in groupCard(e, forceOpen: !query.isEmpty) }
                    if others.isEmpty && !query.isEmpty {
                        Text("No group or member matches \"\(query)\".")
                            .font(Theme.font(.footnote)).foregroundColor(Theme.muted).padding(.top, 8)
                    }
                }
                if !loading && model.error == nil && entries.isEmpty {
                    Text("This course has no groups you can see.")
                        .font(Theme.font(.footnote)).foregroundColor(Theme.muted).padding(.top, 8)
                }
                if loading { ProgressView().tint(Theme.accent) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { overridden = false; await load() }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load() } }
        .onFreshData { await load() }
        .navigationDestination(isPresented: Binding(get: { webAction != nil }, set: { if !$0 { webAction = nil } })) {
            if let u = webAction { GroupWebActionView(url: u, title: module.name) }
        }
        .onChange(of: webAction) { v in
            if v == nil && isGroupSelect { Task { overridden = false; await load() } }
        }
        .alert("Leave this group?", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button("Leave", role: .destructive) { if let e = leaving { Task { await leave(e) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(leaving.map { "You will no longer be in \($0.name)." } ?? "")
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Theme.font(.footnote).weight(.semibold)).foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    private func groupCard(_ e: GroupEntry, forceOpen: Bool) -> some View {
        let mineNow = isMine(e)
        let count = memberCount(e)
        let limit = e.option?.limit ?? 0
        let full = limit > 0 && count >= limit && !mineNow
        let expanded = open.contains(e.id) || forceOpen
        let members = e.members.sorted { $0.fullname < $1.fullname }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                // tapping the title area expands / collapses the member list
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if open.contains(e.id) { open.remove(e.id) } else { open.insert(e.id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.name).fontWeight(.semibold).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                            Text(limit > 0 ? "\(count)/\(limit) members" : "\(count) member\(count == 1 ? "" : "s")")
                                .font(Theme.font(.caption)).foregroundColor(full ? Theme.accent : Theme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if busy == e.id { ProgressView().tint(Theme.accent) }
                else if mineNow {
                    Button { leaving = e } label: {
                        Text("Leave").fontWeight(.semibold).foregroundColor(Theme.txt)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .overlay(Capsule().stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                } else if e.option != nil {
                    Button { Task { await join(e) } } label: {
                        Text(full ? "Full" : (chosen == nil || isGroupSelect ? "Join" : "Switch")).fontWeight(.semibold)
                            .foregroundColor(full ? Theme.muted : Theme.onAccent)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(full ? Theme.surface2 : Theme.accent).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(full || busy != nil || e.option?.disabled?.value == true)
                }
            }
            .padding(12)

            if expanded {
                if !e.about.isEmpty {
                    Text(e.about).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                if members.isEmpty {
                    Text("No members yet").font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
                }
                ForEach(members) { p in MemberRow(person: p, courseId: courseId, isMe: p.id == myId) }
            }
        }
        .glowCard()
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(mineNow ? Theme.accent : .clear, lineWidth: 1.5))
    }

    // MARK: Actions

    private func load() async {
        await model.load(courseId: courseId, myId: myId)
        if isGroupSelect {
            options = model.groups.map { ChoiceGroupOption(id: $0.id, text: $0.name) }
            chosen = model.groups.first { $0.members.contains { $0.id == myId } }?.id
            unsupported = false
            loading = false
            return
        }
        do {
            let r: ChoiceGroupOptionsResp = try await MoodleAPI.shared.call(
                "mod_choicegroup_get_choicegroup_options", ["choicegroupid": instance])
            options = r.options
            if !overridden { chosen = r.options.first { $0.checked?.value == true }?.id
                ?? model.groups.first { g in g.members.contains { $0.id == myId } && r.options.contains { $0.id == g.id } }?.id }
            unsupported = false
        } catch {
            if !(error is CancellationError) {
                // no web-service access to the activity: still show the course's groups from the participant list
                if options.isEmpty {
                    options = model.groups.map { ChoiceGroupOption(id: $0.id, text: $0.name) }
                }
                if !overridden { chosen = model.groups.first { $0.members.contains { $0.id == myId } }?.id }
                unsupported = true
            }
        }
        loading = false
    }

    private func join(_ e: GroupEntry) async {
        if isGroupSelect { webAction = actionURL("select", e.id); return }
        busy = e.id; message = nil
        defer { busy = nil }
        do {
            _ = try await MoodleAPI.shared.raw("mod_choicegroup_submit_choicegroup_response",
                                                ["choicegroupid": instance, "responses": [e.id]])
            overridden = true; chosen = e.id; open.insert(e.id)
            message = "You joined \(e.name)."
            await model.load(courseId: courseId, myId: myId)
        } catch {
            if !(error is CancellationError) { message = "Couldn't join: \(error.localizedDescription)"; unsupported = true }
        }
    }

    private func leave(_ e: GroupEntry) async {
        if isGroupSelect { webAction = actionURL("unselect", e.id); return }
        busy = e.id; message = nil
        defer { busy = nil }
        do {
            _ = try await MoodleAPI.shared.raw("mod_choicegroup_delete_choicegroup_responses",
                                                ["choicegroupid": instance, "responses": [e.id]])
            overridden = true; chosen = nil
            message = "You left \(e.name)."
            await model.load(courseId: courseId, myId: myId)
        } catch {
            if !(error is CancellationError) { message = "Couldn't leave: \(error.localizedDescription)"; unsupported = true }
        }
    }
}


// MARK: - Join / leave through the site's own page (group select plugin)
//
// Opens the select / unselect page (logged in like any other website page), presses its confirm button, and
// goes back when the site has accepted it. If the page has no plain confirm button (a group password, a
// full group, a signed-out session) it simply stays open so you can finish it by hand.

struct GroupWebActionView: View {
    let url: URL
    let title: String
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var resolved: URL?
    @State private var status = "Contacting the site…"

    var body: some View {
        Group {
            if let r = resolved {
                VStack(spacing: 0) {
                    Text(status).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity).padding(8).background(Theme.surface)
                    GroupWebAction(url: r, onStatus: { status = $0 }, onDone: { dismiss() })
                }
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { resolved = await MoodleAPI.shared.autologin(url, userid: app.site?.userid ?? 0) }
    }
}

private struct GroupWebAction: UIViewRepresentable {
    let url: URL
    let onStatus: (String) -> Void
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStatus: onStatus, onDone: onDone) }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onStatus: (String) -> Void
        let onDone: () -> Void
        private var submitted = false
        private var finished = false
        init(onStatus: @escaping (String) -> Void, onDone: @escaping () -> Void) {
            self.onStatus = onStatus; self.onDone = onDone
        }

        // presses the confirm button of the select / unselect page (not a password form, not a log-out form)
        private static let js = """
        (function(){
          var fs = [].slice.call(document.forms).filter(function(f){
            return /groupselect/.test(f.action || '') && f.querySelector('input[name=sesskey]')
              && !f.querySelector('input[type=password], input[name=grouppassword]');
          });
          if (!fs.length) return 'none';
          var f = fs[0], b = f.querySelector('button[type=submit], input[type=submit]');
          if (b) { b.click(); } else { f.submit(); }
          return 'ok';
        })()
        """

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            if w.url?.path.contains("/login/") == true {
                DispatchQueue.main.async { self.onStatus("You're signed out — open the Website tab and sign in, then try again.") }
                return
            }
            if submitted {
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async { self.onStatus("Done") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.onDone() }
                return
            }
            w.evaluateJavaScript(Self.js) { [weak self] r, _ in
                guard let self = self else { return }
                if (r as? String) == "ok" {
                    self.submitted = true
                    DispatchQueue.main.async { self.onStatus("Confirming…") }
                } else {
                    DispatchQueue.main.async {
                        self.onStatus("Finish it on this page, then go back — the list refreshes when you do.")
                    }
                }
            }
        }
    }
}

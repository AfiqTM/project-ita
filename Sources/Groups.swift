import SwiftUI

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
                Text(person.fullname).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                if isMe { Text("You").font(Theme.font(.caption2)).foregroundColor(Theme.muted) }
                Spacer()
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

// MARK: - Groups tab

struct GroupsView: View {
    let courseId: Int
    @EnvironmentObject var app: AppState
    @StateObject private var model = CourseGroupsModel()
    @State private var choiceModules: [Module] = []
    @State private var query = ""
    @State private var open: Set<Int> = []

    private var myId: Int { app.site?.userid ?? 0 }
    private var mine: [CourseGroupInfo] { model.groups.filter { $0.members.contains { $0.id == myId } } }

    private var others: [CourseGroupInfo] {
        let rest = model.groups.filter { g in !g.members.contains { $0.id == myId } }
        guard !query.isEmpty else { return rest }
        return rest.filter { g in
            g.name.localizedCaseInsensitiveContains(query)
                || g.members.contains { $0.fullname.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // join / leave
                if !choiceModules.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(choiceModules.enumerated()), id: \.element.id) { i, m in
                            NavigationLink { GroupChoiceView(courseId: courseId, module: m) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle.badge.plus").foregroundColor(Theme.accent).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.name).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                                        Text("Join or leave a group").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                }
                                .padding(12).contentShape(Rectangle())
                                .overlay(Rectangle().fill(Theme.line).frame(height: i == 0 ? 0 : 1), alignment: .top)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .glowCard()
                }

                if let error = model.error { Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted) }

                // my group(s) with all members
                if !mine.isEmpty {
                    sectionTitle(mine.count == 1 ? "My group" : "My groups")
                    ForEach(mine) { g in groupCard(g, forceOpen: true) }
                } else if !model.loading && model.error == nil {
                    VStack(spacing: 4) {
                        Text("You're not in a group yet").fontWeight(.semibold).foregroundColor(Theme.txt)
                        if !choiceModules.isEmpty {
                            Text("Open the group selection above to join one.")
                                .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(16).glowCard()
                }

                // everyone else
                if !model.groups.isEmpty {
                    sectionTitle("All groups")
                    TextField("Search groups or members", text: $query)
                        .foregroundColor(Theme.txt).padding(12)
                        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    ForEach(others) { g in groupCard(g, forceOpen: !query.isEmpty) }
                    if others.isEmpty && !query.isEmpty {
                        Text("No group or member matches \"\(query)\".")
                            .font(Theme.font(.footnote)).foregroundColor(Theme.muted).padding(.top, 8)
                    }
                }

                if !model.loading && model.error == nil && model.groups.isEmpty {
                    Text("This course has no groups you can see.")
                        .font(Theme.font(.footnote)).foregroundColor(Theme.muted).padding(.top, 8)
                }
                if model.loading { ProgressView().tint(Theme.accent) }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        async let people: Void = model.load(courseId: courseId, myId: myId)
        async let mods: Void = loadChoiceModules()
        _ = await (people, mods)
    }

    private func loadChoiceModules() async {
        if let secs: [CourseSection] = try? await MoodleAPI.shared.call("core_course_get_contents", ["courseid": courseId]) {
            choiceModules = secs.flatMap { $0.modules }.filter { $0.modname == "choicegroup" && $0.uservisible != false }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Theme.font(.footnote).weight(.semibold)).foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    private func groupCard(_ g: CourseGroupInfo, forceOpen: Bool) -> some View {
        let isMine = g.members.contains { $0.id == myId }
        let expanded = open.contains(g.id) || forceOpen
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if open.contains(g.id) { open.remove(g.id) } else { open.insert(g.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.name).fontWeight(.semibold).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                        Text("\(g.members.count) member\(g.members.count == 1 ? "" : "s")")
                            .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    }
                    Spacer()
                    if isMine { Pill(text: "My group") }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
                .padding(12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !g.about.isEmpty {
                    Text(g.about).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                ForEach(g.members.sorted { $0.fullname < $1.fullname }) { p in
                    MemberRow(person: p, courseId: courseId, isMe: p.id == myId)
                }
            }
        }
        .glowCard()
    }
}

// MARK: - Group Selection activity (join / switch / leave)

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
    @State private var leaving: ChoiceGroupOption?
    @State private var open: Set<Int> = []

    private var myId: Int { app.site?.userid ?? 0 }
    private var instance: Int { module.instance ?? 0 }
    private var webURL: URL { URL(string: module.url ?? "") ?? Site.url }

    private func members(of id: Int) -> [Person] {
        model.groups.first { $0.id == id }?.members.sorted { $0.fullname < $1.fullname } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let d = module.description?.plainText, !d.isEmpty {
                    Text(d).font(Theme.read(.subheadline)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message {
                    Text(message).font(Theme.font(.footnote)).foregroundColor(Theme.txt)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if unsupported {
                    VStack(spacing: 10) {
                        Text("This site doesn't allow joining groups from the app.")
                            .foregroundColor(Theme.txt).multilineTextAlignment(.center)
                        NavigationLink { WebActivityView(url: webURL, title: module.name) } label: {
                            Text("Open on the website").fontWeight(.semibold).foregroundColor(Theme.onAccent)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Theme.accent).clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity).padding(16).glowCard()
                }
                ForEach(options) { o in optionCard(o) }
                if loading { ProgressView().tint(Theme.accent) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { overridden = false; await load() }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in Task { await load() } }
        .onFreshData { await load() }
        .alert("Leave this group?", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button("Leave", role: .destructive) { if let o = leaving { Task { await leave(o) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(leaving.map { "You will no longer be in \(($0.text ?? "this group").plainText)." } ?? "")
        }
    }

    private func optionCard(_ o: ChoiceGroupOption) -> some View {
        let isMine = chosen == o.id
        let list = members(of: o.id)
        let count = max(list.count, (o.count ?? 0) + ((isMine && !list.contains { $0.id == myId } && overridden) ? 1 : 0))
        let full = o.limit > 0 && count >= o.limit && !isMine
        let expanded = open.contains(o.id) || isMine
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text((o.text ?? "Group \(o.id)").plainText).fontWeight(.semibold).foregroundColor(Theme.txt)
                    Text(o.limit > 0 ? "\(count)/\(o.limit) members" : "\(count) member\(count == 1 ? "" : "s")")
                        .font(Theme.font(.caption)).foregroundColor(full ? Theme.accent : Theme.muted)
                }
                Spacer()
                if busy == o.id { ProgressView().tint(Theme.accent) }
                else if isMine {
                    Button { leaving = o } label: {
                        Text("Leave").fontWeight(.semibold).foregroundColor(Theme.txt)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .overlay(Capsule().stroke(Theme.line))
                    }
                } else {
                    Button { Task { await join(o) } } label: {
                        Text(full ? "Full" : (chosen == nil ? "Join" : "Switch")).fontWeight(.semibold)
                            .foregroundColor(full ? Theme.muted : Theme.onAccent)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(full ? Theme.surface2 : Theme.accent).clipShape(Capsule())
                    }
                    .disabled(full || busy != nil || o.disabled?.value == true)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if open.contains(o.id) { open.remove(o.id) } else { open.insert(o.id) }
                    }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted).padding(6)
                }
            }
            .padding(12)

            if expanded {
                if list.isEmpty {
                    Text("No members yet").font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
                }
                ForEach(list) { p in MemberRow(person: p, courseId: courseId, isMe: p.id == myId) }
            }
        }
        .glowCard()
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isMine ? Theme.accent : .clear, lineWidth: 1.5))
    }

    // MARK: Actions

    private func load() async {
        await model.load(courseId: courseId, myId: myId)
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
                    chosen = model.groups.first { $0.members.contains { $0.id == myId } }?.id
                }
                unsupported = true
            }
        }
        loading = false
    }

    private func join(_ o: ChoiceGroupOption) async {
        busy = o.id; message = nil
        defer { busy = nil }
        do {
            _ = try await MoodleAPI.shared.raw("mod_choicegroup_submit_choicegroup_response",
                                                ["choicegroupid": instance, "responses": [o.id]])
            overridden = true; chosen = o.id; open.insert(o.id)
            message = "You joined \((o.text ?? "the group").plainText)."
            await model.load(courseId: courseId, myId: myId)
        } catch {
            if !(error is CancellationError) { message = "Couldn't join: \(error.localizedDescription)" }
        }
    }

    private func leave(_ o: ChoiceGroupOption) async {
        busy = o.id; message = nil
        defer { busy = nil }
        do {
            _ = try await MoodleAPI.shared.raw("mod_choicegroup_delete_choicegroup_responses",
                                                ["choicegroupid": instance, "responses": [o.id]])
            overridden = true; chosen = nil
            message = "You left \((o.text ?? "the group").plainText)."
            await model.load(courseId: courseId, myId: myId)
        } catch {
            if !(error is CancellationError) { message = "Couldn't leave: \(error.localizedDescription)" }
        }
    }
}

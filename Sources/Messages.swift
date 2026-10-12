import SwiftUI

// Moodle messaging: chat button (with unread badge) -> conversation list -> thread with reply.
// Uses only the web-service token (core_message_* functions), so it never touches the auto-login key.
//
// HOW TO ADD IT to the Courses tab: put `.messagesToolbar()` on the Courses screen's root view
// (the one inside the NavigationStack). If the tab uses a custom header instead of a navigation bar,
// drop `MessagesButton()` into the header's HStack.

// MARK: - Models

struct ChatConvResp: Decodable { let conversations: [ChatConv] }
struct ChatConv: Decodable, Identifiable {
    let id: Int
    let name: String?
    let subname: String?
    let imageurl: String?
    let type: Int?            // 1 = private, 2 = group, 3 = self
    let membercount: Int?
    let unreadcount: Int?
    let members: [ChatMember]?
    let messages: [ChatMsg]?

    var title: String {
        if let n = name, !n.isEmpty { return n }
        return members?.first?.fullname ?? "Conversation"
    }
    var unread: Int { unreadcount ?? 0 }
    var avatarURL: String? { imageurl ?? members?.first?.profileimageurlsmall }
}
struct ChatMember: Decodable, Identifiable {
    let id: Int
    let fullname: String?
    let profileimageurlsmall: String?
}
struct ChatMsg: Decodable, Identifiable {
    let id: Int
    let useridfrom: Int?
    let text: String?
    let timecreated: Int?
}
struct ChatThreadResp: Decodable {
    let members: [ChatMember]?
    let messages: [ChatMsg]?
}

// MARK: - Time helpers

private enum ChatTime {
    static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    static let dm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, d MMM yyyy"; return f }()

    static func date(_ ts: Int?) -> Date? {
        guard let ts, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }
    /// For the conversation list: time today, "Yesterday", or "5 Oct"
    static func listStamp(_ ts: Int?) -> String {
        guard let d = date(ts) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return hm.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return dm.string(from: d)
    }
    static func timeOnly(_ ts: Int?) -> String { date(ts).map { hm.string(from: $0) } ?? "" }
    static func dayLabel(_ ts: Int?) -> String {
        guard let d = date(ts) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return day.string(from: d)
    }
    static func sameDay(_ a: Int?, _ b: Int?) -> Bool {
        guard let x = date(a), let y = date(b) else { return false }
        return Calendar.current.isDate(x, inSameDayAs: y)
    }
}

// MARK: - Shared store (drives the badge)

@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    @Published var unread = 0

    /// Number of conversations that have unread messages.
    func refreshBadge(userid: Int) async {
        guard userid > 0 else { return }
        do {
            let data = try await MoodleAPI.shared.raw("core_message_get_unread_conversation_counts",
                                                     ["userid": userid])
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            var n = 0
            if let t = o["types"] as? [String: Any] {
                for (k, v) in t where k != "3" { n += (v as? Int) ?? 0 }   // 3 = notes to self
            } else if let t = o["types"] as? [Any] {
                n = t.compactMap { $0 as? Int }.reduce(0, +)
            }
            unread = n
        } catch {
            // messaging disabled / offline: leave the badge as it was
        }
    }
}

// MARK: - Toolbar button with badge

extension View {
    /// Adds the chat icon (with unread badge) to the top-right of the navigation bar.
    func messagesToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { MessagesButton() }
        }
    }
}

struct MessagesButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var store = ChatStore.shared
    @State private var show = false

    private var uid: Int { app.site?.userid ?? 0 }

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "message")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(Theme.txt)
                .padding(6)
                .overlay(alignment: .topTrailing) {
                    if store.unread > 0 {
                        Text(store.unread > 99 ? "99+" : "\(store.unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.bg, lineWidth: 1.5))
                            .offset(x: 6, y: -4)
                    }
                }
        }
        .accessibilityLabel(store.unread > 0 ? "Messages, \(store.unread) unread" : "Messages")
        .sheet(isPresented: $show, onDismiss: {
            Task { await store.refreshBadge(userid: uid) }
        }) {
            ChatListView().environmentObject(app)
        }
        .task(id: uid) {
            while !Task.isCancelled {
                await store.refreshBadge(userid: uid)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
}

// MARK: - Avatar

struct ChatAvatar: View {
    let name: String
    let url: String?
    var size: CGFloat = 46

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return String(parts).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Theme.surface2)
            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(Theme.accent)
            if let s = url, let u = MoodleAPI.shared.fileURL(s) {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Conversation list

struct ChatListView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var convs: [ChatConv] = []
    @State private var loading = true
    @State private var error: String?
    @State private var onlyUnread = false

    private var uid: Int { app.site?.userid ?? 0 }
    private var shown: [ChatConv] { onlyUnread ? convs.filter { $0.unread > 0 } : convs }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Picker("", selection: $onlyUnread) {
                        Text("All").tag(false)
                        Text("Unread").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    if let error {
                        Text(error).font(.footnote).foregroundColor(Theme.muted)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if loading && convs.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.top, 40)
                    } else if shown.isEmpty && error == nil {
                        Text(onlyUnread ? "No unread messages." : "No messages yet.")
                            .foregroundColor(Theme.muted).padding(.top, 40)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { c in
                            NavigationLink { ChatThreadView(conv: c) } label: { row(c) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(Theme.accent)
                }
            }
            .refreshable { await load() }
            .onAppear { Task { await load() } }   // also refreshes when coming back from a thread
        }
    }

    private func row(_ c: ChatConv) -> some View {
        let last = c.messages?.last
        let preview = ((last?.text ?? "").plainText).replacingOccurrences(of: "\n", with: " ")
        let mine = last?.useridfrom == uid
        return HStack(spacing: 12) {
            ChatAvatar(name: c.title, url: c.avatarURL)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(c.title)
                        .fontWeight(c.unread > 0 ? .semibold : .regular)
                        .foregroundColor(Theme.txt).lineLimit(1)
                    Spacer()
                    Text(ChatTime.listStamp(last?.timecreated))
                        .font(.caption)
                        .foregroundColor(c.unread > 0 ? Theme.accent : Theme.muted)
                }
                HStack {
                    Text((mine && !preview.isEmpty ? "You: " : "") + preview)
                        .font(.subheadline)
                        .foregroundColor(c.unread > 0 ? Theme.txt : Theme.muted)
                        .lineLimit(2)
                    Spacer()
                    if c.unread > 0 {
                        Text("\(c.unread)")
                            .font(.caption.bold()).foregroundColor(.black)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.accent).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    private func load() async {
        guard uid > 0 else { loading = false; return }
        do {
            let r: ChatConvResp = try await MoodleAPI.shared.call(
                "core_message_get_conversations",
                ["userid": uid, "limitfrom": 0, "limitnum": 50])
            convs = r.conversations
            error = nil
        } catch {
            if !(error is CancellationError) {
                self.error = "Couldn't load messages: " + error.localizedDescription
            }
        }
        loading = false
        await ChatStore.shared.refreshBadge(userid: uid)
    }
}

// MARK: - Thread (read + reply)

struct ChatThreadView: View {
    let conv: ChatConv
    let toUser: Int?          // set when this chat may not exist yet (opened from a profile)
    @EnvironmentObject var app: AppState
    @State private var convId: Int
    @State private var msgs: [ChatMsg] = []
    @State private var names: [Int: String] = [:]
    @State private var draft = ""
    @State private var sending = false
    @State private var loading = true
    @State private var error: String?
    @State private var limit = 50
    @State private var hasMore = false

    private var uid: Int { app.site?.userid ?? 0 }

    init(conv: ChatConv, toUser: Int? = nil) {
        self.conv = conv
        self.toUser = toUser
        _convId = State(initialValue: conv.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if hasMore {
                        Button("Load earlier messages") {
                            limit += 50
                            Task { await load() }
                        }
                        .font(.subheadline).foregroundColor(Theme.accent).padding(.vertical, 8)
                    }
                    if loading && msgs.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.top, 40)
                    }
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || !ChatTime.sameDay(msgs[i - 1].timecreated, m.timecreated) {
                            Text(ChatTime.dayLabel(m.timecreated))
                                .font(.caption).foregroundColor(Theme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        bubble(m, prev: i > 0 ? msgs[i - 1] : nil)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundColor(.red.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onChange(of: msgs.last?.id) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(conv.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { inputBar }
        .task {
            await load()
            await markRead()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)   // pick up new replies while open
                await load(silent: true)
            }
        }
    }

    // ---- bubbles ----

    private func bubble(_ m: ChatMsg, prev: ChatMsg?) -> some View {
        let mine = m.useridfrom == uid
        let text = (m.text ?? "").plainText
        let showName = !mine && conv.type == 2 && prev?.useridfrom != m.useridfrom
        return VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if showName, let id = m.useridfrom, let n = names[id] {
                Text(n).font(.caption).foregroundColor(Theme.muted).padding(.horizontal, 4)
            }
            Text(text)
                .foregroundColor(mine ? .black : Theme.txt)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Theme.accent : Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .textSelection(.enabled)
            Text(ChatTime.timeOnly(m.timecreated))
                .font(.system(size: 10)).foregroundColor(Theme.muted).padding(.horizontal, 4)
        }
        .padding(mine ? .leading : .trailing, 48)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    // ---- reply bar ----

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .foregroundColor(Theme.txt)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 38, height: 38)
                    .background(canSend ? Theme.accent : Theme.muted.opacity(0.4))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ---- actions ----

    private func merge(_ new: [ChatMsg]) {
        var byId = Dictionary(uniqueKeysWithValues: msgs.map { ($0.id, $0) })
        for m in new { byId[m.id] = m }
        msgs = byId.values.sorted {
            ($0.timecreated ?? 0, $0.id) < ($1.timecreated ?? 0, $1.id)
        }
    }

    private func load(silent: Bool = false) async {
        guard uid > 0, convId > 0 else { loading = false; return }
        do {
            let r: ChatThreadResp = try await MoodleAPI.shared.call(
                "core_message_get_conversation_messages",
                ["currentuserid": uid, "convid": convId, "limitfrom": 0, "limitnum": limit, "newest": 1])
            for mem in r.members ?? [] { if let n = mem.fullname { names[mem.id] = n } }
            let got = r.messages ?? []
            merge(got)
            hasMore = got.count >= limit
            if !silent { error = nil }
        } catch {
            if !silent && !(error is CancellationError) {
                self.error = "Couldn't load messages: " + error.localizedDescription
            }
        }
        loading = false
    }

    private func markRead() async {
        guard convId > 0 else { return }
        _ = try? await MoodleAPI.shared.raw("core_message_mark_all_conversation_messages_as_read",
                                            ["userid": uid, "conversationid": convId])
        await ChatStore.shared.refreshBadge(userid: uid)
    }

    private func send() async {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        sending = true; error = nil
        do {
            if convId == 0, let to = toUser {
                // First message of a brand-new chat: sending it also creates the conversation.
                let data = try await MoodleAPI.shared.raw(
                    "core_message_send_instant_messages",
                    ["messages": [["touserid": to, "text": t, "textformat": 0]]])
                guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                      let o = arr.first else { throw APIError(message: "Unexpected reply from the site") }
                if let e = o["errormessage"] as? String, !e.isEmpty { throw APIError(message: e.plainText) }
                if let cid = o["conversationid"] as? Int, cid > 0 {
                    convId = cid
                } else if let found: ChatConv = try? await MoodleAPI.shared.call(
                    "core_message_get_conversation_between_users",
                    ["userid": uid, "otheruserid": to, "includecontactrequests": 0, "includeprivacyinfo": 0,
                     "memberlimit": 0, "memberoffset": 0, "messagelimit": 0, "messageoffset": 0,
                     "newestmessagefirst": 1]) {
                    convId = found.id
                }
                draft = ""
                merge([ChatMsg(id: (o["msgid"] as? Int) ?? 0, useridfrom: uid, text: t,
                               timecreated: (o["timecreated"] as? Int) ?? Int(Date().timeIntervalSince1970))])
                await load(silent: true)
            } else {
                let sent: [ChatMsg] = try await MoodleAPI.shared.call(
                    "core_message_send_messages_to_conversation",
                    ["conversationid": convId, "messages": [["text": t, "textformat": 0]]])
                draft = ""
                merge(sent)
            }
        } catch {
            self.error = "Couldn't send: " + error.localizedDescription
        }
        sending = false
    }
}

// MARK: - Open (or start) a chat with one person - used by the profile's Message button

struct ChatOpenView: View {
    let userid: Int
    let name: String
    var imageURL: String? = nil
    @EnvironmentObject var app: AppState
    @State private var conv: ChatConv?

    var body: some View {
        Group {
            if let conv {
                ChatThreadView(conv: conv, toUser: userid)
            } else {
                ProgressView().tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg.ignoresSafeArea())
            }
        }
        .task { await find() }
    }

    private func find() async {
        let uid = app.site?.userid ?? 0
        do {
            let r: ChatConv = try await MoodleAPI.shared.call(
                "core_message_get_conversation_between_users",
                ["userid": uid, "otheruserid": userid, "includecontactrequests": 0, "includeprivacyinfo": 0,
                 "memberlimit": 0, "memberoffset": 0, "messagelimit": 0, "messageoffset": 0,
                 "newestmessagefirst": 1])
            conv = ChatConv(id: r.id, name: name, subname: r.subname, imageurl: r.imageurl ?? imageURL,
                            type: r.type ?? 1, membercount: r.membercount, unreadcount: r.unreadcount,
                            members: r.members, messages: nil)
        } catch {
            // no conversation yet: the thread opens empty and the first message creates it
            conv = ChatConv(id: 0, name: name, subname: nil, imageurl: imageURL, type: 1,
                            membercount: 2, unreadcount: 0, members: nil, messages: nil)
        }
    }
}

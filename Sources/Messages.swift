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

    private var uid: Int { app.site?.userid ?? 0 }

    var body: some View {
        Button { MessagesPresenter.shared.open() } label: {
            Image(systemName: "message")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(Theme.txt)
                .padding(6)
                .overlay(alignment: .topTrailing) {
                    if store.unread > 0 {
                        Text(store.unread > 99 ? "99+" : "\(store.unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.bg, lineWidth: 1.5))
                            .offset(x: 6, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.unread > 0 ? "Messages, \(store.unread) unread" : "Messages")
        .task(id: uid) {
            while !Task.isCancelled {
                await store.refreshBadge(userid: uid)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
}

// MARK: - Full-screen Messages layer
//
// Messages sits in its own layer above the whole TabView (placed in RootView with `.overlay`), so it covers
// the tab bar without hiding it: nothing has to be hidden and brought back, which is what made the tab bar
// reappear late after going back. It slides in from the right, and a swipe to the right from anywhere
// on the screen slides it away again.

final class MessagesPresenter: ObservableObject {
    static let shared = MessagesPresenter()
    @Published var isOpen = false
    /// True while a chat is open inside Messages; that screen has its own swipe-back.
    @Published var chatOpen = false

    func open() {
        withAnimation(.easeOut(duration: 0.28)) { isOpen = true }
    }
}

struct MessagesOverlay: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var presenter = MessagesPresenter.shared
    @State private var dragX: CGFloat = 0
    @State private var horizontal: Bool?    // nil until we know which way this drag is going

    var body: some View {
        GeometryReader { geo in
            if presenter.isOpen {
                NavigationStack { ChatListView() }
                    .background(Theme.bg.ignoresSafeArea())
                    .offset(x: dragX)
                    .shadow(color: .black.opacity(dragX > 0 ? 0.35 : 0), radius: 10)
                    .transition(.move(edge: .trailing))
                    .simultaneousGesture(swipeBack(width: geo.size.width))
            }
        }
        .allowsHitTesting(presenter.isOpen)
        .onChange(of: presenter.isOpen) { open in
            if !open { Task { await ChatStore.shared.refreshBadge(userid: app.site?.userid ?? 0) } }
        }
    }

    private func swipeBack(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                guard !presenter.chatOpen else { return }
                if horizontal == nil {   // decided once, so scrolling up and down never drags the page
                    horizontal = g.translation.width > 0 && abs(g.translation.width) > abs(g.translation.height) * 1.3
                }
                if horizontal == true { dragX = max(0, g.translation.width) }
            }
            .onEnded { g in
                let wasHorizontal = horizontal == true
                horizontal = nil
                guard wasHorizontal, !presenter.chatOpen else { dragX = 0; return }
                let far = g.translation.width > width * 0.33 || g.predictedEndTranslation.width > width * 0.6
                if far {
                    // Quick finish, shorter the further you already dragged (about 0.12 to 0.22 s),
                    // like the app's other slides.
                    let remaining = max(0, width - dragX) / max(width, 1)
                    let dur = 0.12 + 0.10 * Double(remaining)
                    withAnimation(.easeOut(duration: dur)) { dragX = width }
                    DispatchQueue.main.asyncAfter(deadline: .now() + dur) {
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { presenter.isOpen = false; dragX = 0 }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { dragX = 0 }   // snap back
                }
            }
    }
}

// MARK: - Avatar

struct ChatAvatar: View {
    let name: String
    let url: String?
    var size: CGFloat = 46

    var body: some View {
        ProfilePhoto(name: name, urls: [url], size: size, sizeKey: "f1", outline: false)
    }
}

// MARK: - Conversation list

struct ChatListView: View {
    @EnvironmentObject var app: AppState
    @State private var convs: [ChatConv] = []
    @State private var loading = true
    @State private var error: String?
    @State private var onlyUnread = false
    @State private var pendingDelete: ChatConv?

    private var uid: Int { app.site?.userid ?? 0 }
    private var shown: [ChatConv] { onlyUnread ? convs.filter { $0.unread > 0 } : convs }

    var body: some View {
        Group {
            // A List (instead of ScrollView + buttons) gives native swipe actions: while a row is being
            // swiped it never counts as a tap, so a chat can't open by accident.
            List {
                Picker("", selection: $onlyUnread) {
                    Text("All").tag(false)
                    Text("Unread").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let error {
                    Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if loading && convs.isEmpty {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if shown.isEmpty && error == nil {
                    Text(onlyUnread ? "No unread messages." : "No messages yet.")
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }

                ForEach(shown) { c in
                    row(c)
                        .background {
                            NavigationLink { ChatThreadView(conv: c) } label: { EmptyView() }.opacity(0)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // long-press: mark as read (swiping right is now "go back", from anywhere)
                        .contextMenu {
                            if c.unread > 0 {
                                Button { Task { await markRead(c) } } label: {
                                    Label("Mark as read", systemImage: "envelope.open")
                                }
                            }
                        }
                        // swipe left: delete (needs a second tap to confirm, no full-swipe)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = c } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .refreshable { await load() }
            .onAppear { Task { await load() } }   // also refreshes when coming back from a thread
            .confirmationDialog(
                "Delete this chat?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { c in
                Button("Delete for me", role: .destructive) { Task { await delete(c) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This only removes the chat from your view. The other person will still have it.")
            }
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
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
                        .font(Theme.font(.caption))
                        .foregroundColor(c.unread > 0 ? Theme.accent : Theme.muted)
                }
                HStack {
                    Text((mine && !preview.isEmpty ? "You: " : "") + preview)
                        .font(Theme.font(.subheadline))
                        .foregroundColor(c.unread > 0 ? Theme.txt : Theme.muted)
                        .lineLimit(2)
                    Spacer()
                    if c.unread > 0 {
                        Text("\(c.unread)")
                            .font(Theme.font(.caption).bold()).foregroundColor(Theme.onAccent)
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

    private func markRead(_ c: ChatConv) async {
        _ = try? await MoodleAPI.shared.raw("core_message_mark_all_conversation_messages_as_read",
                                            ["userid": uid, "conversationid": c.id])
        await load()
    }

    /// Removes the chat from this user's view only (Moodle keeps it for the other person).
    private func delete(_ c: ChatConv) async {
        do {
            _ = try await MoodleAPI.shared.raw("core_message_delete_conversations_by_id",
                                               ["userid": uid, "conversationids": [c.id]])
            convs.removeAll { $0.id == c.id }
            error = nil
        } catch {
            self.error = "Couldn't delete chat: " + error.localizedDescription
        }
        await ChatStore.shared.refreshBadge(userid: uid)
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

// MARK: - Thread (read + reply + select + delete for me)

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

    // selection / delete
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var confirmDelete = false
    @State private var deleting = false
    @FocusState private var inputFocused: Bool

    private var uid: Int { app.site?.userid ?? 0 }

    /// Slightly lighter than the page / input bar so the other person's bubble stands out.
    private var theirBubble: some View {
        ZStack {
            Theme.surface2
            Theme.txt.opacity(0.10)
        }
    }

    init(conv: ChatConv, toUser: Int? = nil) {
        self.conv = conv
        self.toUser = toUser
        _convId = State(initialValue: conv.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if hasMore {
                        Button("Load earlier messages") {
                            limit += 50
                            Task { await load() }
                        }
                        .font(Theme.font(.subheadline)).foregroundColor(Theme.accent).padding(.vertical, 8)
                    }
                    if loading && msgs.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.top, 40)
                    }
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                        let prev: ChatMsg? = i > 0 ? msgs[i - 1] : nil
                        let next: ChatMsg? = i < msgs.count - 1 ? msgs[i + 1] : nil
                        if prev == nil || !ChatTime.sameDay(prev?.timecreated, m.timecreated) {
                            Text(ChatTime.dayLabel(m.timecreated))
                                .font(Theme.font(.caption).weight(.medium)).foregroundColor(Theme.muted)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Theme.surface2.opacity(0.7))
                                .clipShape(Capsule())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        row(m, prev: prev, next: next)
                    }
                    if let error {
                        Text(error).font(Theme.font(.footnote)).foregroundColor(.red.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: msgs.last?.id) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: inputFocused) { focused in
                if focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(selecting ? "\(selected.count) selected" : conv.title)
        .navigationBarTitleDisplayMode(.inline)
        // No back arrow: go back by swiping right from anywhere (EdgeSwipeBack, bottom of this file).
        // The gesture is switched off while selecting so a stray swipe can't leave the screen.
        .navigationBarBackButtonHidden(true)
        .background(EdgeSwipeBack(enabled: !selecting))
        .onAppear { MessagesPresenter.shared.chatOpen = true }
        .onDisappear { MessagesPresenter.shared.chatOpen = false }
        .toolbar(.hidden, for: .tabBar)      // no tab bar when opened from a profile
        .toolbar {
            if selecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { endSelecting() }.foregroundColor(Theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .foregroundColor(selected.isEmpty ? Theme.muted : .red.opacity(0.9))
                    .disabled(selected.isEmpty || deleting)
                }
            } else if msgs.contains(where: { $0.id > 0 }) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Select") { startSelecting(nil) }.foregroundColor(Theme.accent)
                }
            }
        }
        .confirmationDialog(
            "Delete \(selected.count) message\(selected.count == 1 ? "" : "s") for you?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete for me", role: .destructive) { Task { await deleteSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes it from your view. The other person will still see it.")
        }
        .safeAreaInset(edge: .bottom) { if !selecting { inputBar } }
        .task {
            await load()
            await markRead()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)   // pick up new replies while open
                await load(silent: true)
            }
        }
    }

    // ---- rows & bubbles ----

    private func row(_ m: ChatMsg, prev: ChatMsg?, next: ChatMsg?) -> some View {
        let isSel = selected.contains(m.id)
        let sameGroup = prev != nil && prev?.useridfrom == m.useridfrom
            && ChatTime.sameDay(prev?.timecreated, m.timecreated)
        return HStack(spacing: 10) {
            if selecting {
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(Theme.font(.title3))
                    .foregroundColor(isSel ? Theme.accent : Theme.muted)
            }
            bubble(m, prev: prev, next: next)
        }
        .padding(.top, sameGroup ? 2 : 10)
        .padding(.vertical, 1)
        .background(isSel ? Theme.accent.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(m) } else if inputFocused { inputFocused = false }
        }
        .contextMenu {
            if !selecting {
                Button {
                    UIPasteboard.general.string = (m.text ?? "").plainText
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                if m.id > 0 {
                    Button { startSelecting(m) } label: { Label("Select", systemImage: "checkmark.circle") }
                    Button(role: .destructive) {
                        selected = [m.id]
                        confirmDelete = true
                    } label: { Label("Delete for me", systemImage: "trash") }
                }
            }
        }
    }

    private func bubble(_ m: ChatMsg, prev: ChatMsg?, next: ChatMsg?) -> some View {
        let mine = m.useridfrom == uid
        let text = (m.text ?? "").plainText
        let showName = !mine && conv.type == 2 && prev?.useridfrom != m.useridfrom
        let lastInGroup = next == nil || next?.useridfrom != m.useridfrom
            || !ChatTime.sameDay(next?.timecreated, m.timecreated)
        return VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if showName, let id = m.useridfrom, let n = names[id] {
                Text(n).font(Theme.font(.caption).weight(.medium)).foregroundColor(Theme.accent.opacity(0.85))
                    .padding(.horizontal, 4)
            }
            Text(text)
                .foregroundColor(mine ? Theme.onAccent : Theme.txt)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background {
                    if mine { Theme.accent } else { theirBubble }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(mine ? Color.clear : Theme.txt.opacity(0.08), lineWidth: 1)
                )
            if lastInGroup {
                Text(ChatTime.timeOnly(m.timecreated))
                    .font(.system(size: 10)).foregroundColor(Theme.muted).padding(.horizontal, 4)
                    .padding(.top, 1)
            }
        }
        .padding(mine ? .leading : .trailing, 48)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    // ---- reply bar ----

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("", text: $draft,
                      prompt: Text("Message").foregroundColor(Theme.muted),
                      axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .foregroundColor(Theme.txt)
                .tint(Theme.accent)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(inputFocused ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
            if inputFocused {
                Button { inputFocused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Theme.accent)
                        .frame(width: 38, height: 38)
                        .background(Theme.surface2)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Hide keyboard")
            }
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.onAccent)
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

    // ---- selection ----

    private func startSelecting(_ first: ChatMsg?) {
        inputFocused = false
        selecting = true
        selected = first.map { [$0.id] } ?? []
    }

    private func endSelecting() {
        selecting = false
        selected = []
    }

    private func toggle(_ m: ChatMsg) {
        guard m.id > 0 else { return }
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
    }

    /// "Delete for me": Moodle's core_message_delete_message removes the message from this user's view only.
    private func deleteSelected() async {
        let ids = Array(selected)
        guard !ids.isEmpty, !deleting else { return }
        deleting = true; error = nil
        var gone = Set<Int>()
        var failure: String?
        for id in ids {
            do {
                _ = try await MoodleAPI.shared.raw("core_message_delete_message",
                                                   ["messageid": id, "userid": uid, "read": 1])
                gone.insert(id)
            } catch {
                failure = error.localizedDescription
            }
        }
        msgs.removeAll { gone.contains($0.id) }
        selected.subtract(gone)
        if let failure {
            error = "Couldn't delete \(ids.count - gone.count) message(s): " + failure
        } else {
            endSelecting()
        }
        deleting = false
        await ChatStore.shared.refreshBadge(userid: uid)
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

        // Show the message and clear the box straight away; the network call finishes in the background.
        // The placeholder has a negative id (so it can't be selected/deleted) and is swapped for the real one.
        let tempId = -Int.random(in: 1...1_000_000_000)
        draft = ""
        merge([ChatMsg(id: tempId, useridfrom: uid, text: t, timecreated: Int(Date().timeIntervalSince1970))])

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
                msgs.removeAll { $0.id == tempId }
                merge([ChatMsg(id: (o["msgid"] as? Int) ?? 0, useridfrom: uid, text: t,
                               timecreated: (o["timecreated"] as? Int) ?? Int(Date().timeIntervalSince1970))])
                await load(silent: true)
            } else {
                let sent: [ChatMsg] = try await MoodleAPI.shared.call(
                    "core_message_send_messages_to_conversation",
                    ["conversationid": convId, "messages": [["text": t, "textformat": 0]]])
                msgs.removeAll { $0.id == tempId }
                merge(sent)
            }
        } catch {
            // Failed: take the placeholder away and put the text back so nothing is lost
            msgs.removeAll { $0.id == tempId }
            if draft.isEmpty { draft = t }
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
        .toolbar(.hidden, for: .tabBar)      // hide My courses / Alerts / ... tab bar on the chat page
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

// MARK: - Swipe back from anywhere (only for screens that hide the back arrow)

/// Hiding the back arrow switches off iOS's swipe-back. This brings it back for the screen it is attached to,
/// and makes it work from anywhere on the screen, not just the left edge. It drives iOS's own interactive pop
/// (same animation, same cancel when you let go early) with a pan that starts anywhere. Only a rightward,
/// mostly-horizontal drag counts, so scrolling and taps are not affected. When the screen goes away the
/// system's own edge gesture is switched back on, so no other screen is touched.
private struct EdgeSwipeBack: UIViewControllerRepresentable {
    var enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ vc: Controller, context: Context) { vc.enabled = enabled }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var enabled = true
        private static var active = 0          // screens currently using the helper
        private weak var edge: UIGestureRecognizer?
        private var pan: UIPanGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard pan == nil,
                  let e = navigationController?.interactivePopGestureRecognizer,
                  let host = e.view,
                  let targets = e.value(forKey: "targets") as? [AnyObject],
                  let target = targets.first?.value(forKey: "target") else { return }
            let p = UIPanGestureRecognizer(target: target, action: NSSelectorFromString("handleNavigationTransition:"))
            p.maximumNumberOfTouches = 1
            p.delegate = self
            host.addGestureRecognizer(p)
            pan = p
            edge = e
            e.isEnabled = false                // the full-screen pan replaces it
            Controller.active += 1
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard let p = pan else { return }
            p.view?.removeGestureRecognizer(p)
            pan = nil
            Controller.active = max(0, Controller.active - 1)
            if Controller.active == 0 { edge?.isEnabled = true }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, view.window != nil,
                  (navigationController?.viewControllers.count ?? 0) > 1,
                  let p = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = p.velocity(in: p.view)
            return v.x > 0 && abs(v.x) > abs(v.y)
        }
    }
}

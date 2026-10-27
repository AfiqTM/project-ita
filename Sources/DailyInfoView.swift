import SwiftUI
import PhotosUI

// MARK: - Helpers

private func clockText(_ min: Int?) -> String? { min.map { AutoAttParse.clock($0) } }

private func dayText(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let f = DateFormatter()
    f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEE, d MMM" : "EEE, d MMM yyyy"
    return f.string(from: d)
}

private func minutesToDate(_ m: Int, on day: Date = Date()) -> Date {
    Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) ?? day
}

private func dateToMinutes(_ d: Date) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

private extension View {
    func dailyBox(focused: Bool = false) -> some View {
        self.padding(12)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(focused ? Theme.accent : Theme.line, lineWidth: 1))
    }
}

// MARK: - Page container: Noticeboard (left)  <-  swipe left to right  ->  My courses (right)

struct CoursesHome: View {
    @EnvironmentObject var catalog: CourseCatalog
    @ObservedObject private var store = DailyInfoStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 1            // 0 = Noticeboard (left), 1 = My courses (right, home)

    private let tabBarClearance: CGFloat = 96

    private var windowHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.bounds.height ?? 0
    }

    private var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let top = windowTopInset > 0 ? windowTopInset : geo.safeAreaInsets.top
            TabView(selection: $page) {
                DailyInfoView()
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    // the tab bar follows the swipe (see TabBarFollower), so it fades together with the pages
                    .background(TabBarFollower())
                    .tag(0)
                CoursesView()
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: tabBarClearance) }
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .noBottomEdgeEffect()
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // pinned to the full screen so the pages never change size. Never shorter than the window itself: a pager a few points
            // short left a strip of plain background under the tab bar (the pages stopped above the bottom edge of the screen)
            .frame(width: geo.size.width, height: max(geo.size.height, windowHeight), alignment: .top)
            // Apply hidden toolbars to the ROOT container to prevent SwiftUI transition ghosting
            .toolbar(.hidden, for: .navigationBar)
            // The tab bar fades away on Noticeboard and comes back on My courses, in step with the finger (TabBarFollower).
            // Only its opacity changes: hiding it through .toolbar(.hidden, for: .tabBar) re-laid out the safe areas under the
            // pages (the page jumped), and moving it with a transform made it jump up before it faded (UIKit sets the bar's
            // frame on every layout pass, which is undefined while a transform is set). A fade touches neither.
            .background(Theme.bg.ignoresSafeArea())
            .overlay(alignment: .top) {
                LinearGradient(colors: [Theme.bg.opacity(0.92), Theme.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: top + 8)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
            }
        }
        // the container itself no longer follows the safe area, so its size stays the same when the tab bar hides / shows
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .onChange(of: page) { new in
            guard new == 1 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if page == 1 { store.markAllSeen() }
            }
        }
        .task {
            await catalog.loadIfNeeded()
            await store.scan(courses: catalog.courses)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await store.scan(courses: catalog.courses) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlineBackOnline)) { _ in
            Task { await store.scan(courses: catalog.courses) }   // automatic: off while DailyInfoStore.autoScan is false
        }
    }
}

extension View {
    @ViewBuilder func noBottomEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .bottom) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Noticeboard screen

struct DailyInfoView: View {
    @EnvironmentObject var catalog: CourseCatalog
    @ObservedObject private var store = DailyInfoStore.shared
    @State private var kindFilter: DailyKind?
    @State private var courseFilter: Int?
    @State private var showPast = false
    @State private var showRemoved = false
    @State private var editing: DailyEntry?
    @State private var showAdd = false
    @State private var highlight: Set<String> = []
    @State private var showGuide = false
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var reading = false
    @State private var readResult: String?
    @State private var fading: Set<String> = []       // rows that are fading out (first step of removing one)
    @State private var collapsing: Set<String> = []   // rows that are closing up (second step), just before they leave the list

    private var visible: [DailyEntry] {
        store.entries.filter { e in
            (showRemoved ? e.hidden == true : e.hidden != true)
                && (kindFilter == nil || e.kind == kindFilter)
                && (courseFilter == nil || e.courseId == courseFilter)
                && (showRemoved || e.isPast() == showPast)
        }
    }

    private var groups: [(title: String, items: [DailyEntry])] {
        let cal = Calendar.current
        var dict: [Date: [DailyEntry]] = [:]
        var undated: [DailyEntry] = []
        for e in visible {
            if let d = e.relevantDate { dict[cal.startOfDay(for: d), default: []].append(e) } else { undated.append(e) }
        }
        let days = dict.keys.sorted { showPast ? $0 > $1 : $0 < $1 }
        var out = days.map { d in
            (title: dayText(d), items: dict[d]!.sorted { ($0.startMin ?? 0) < ($1.startMin ?? 0) })
        }
        if !undated.isEmpty { out.append((title: "No date", items: undated.sorted { $0.postedAt > $1.postedAt })) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                DailyToolsRow()
                filters
                if let n = store.scanNote {
                    Text(n).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                }
                // One block for all the days, each day carrying its own 16 pt gap, so a day that closes up takes its gap with it
                // and nothing pops when it finally leaves the list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.title) { g in
                        let dayGone = g.items.allSatisfy { collapsing.contains($0.id) }
                        let dayFading = g.items.allSatisfy { fading.contains($0.id) }
                        Collapsible(collapsed: dayGone, clip: false) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(g.title).font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.muted)
                                VStack(spacing: 0) {
                                    ForEach(g.items) { e in
                                        // a day that is going closes as one piece; otherwise just this row closes
                                        Collapsible(collapsed: collapsing.contains(e.id) && !dayGone, clip: true) {
                                            DailyRow(entry: e, isNew: highlight.contains(e.id))
                                                .opacity(fading.contains(e.id) ? 0 : 1)
                                                .onTapGesture { editing = e }
                                                .contextMenu { menu(e) }
                                        }
                                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                                    }
                                }
                                .glowCard(radius: 12)
                            }
                            .padding(.bottom, 16)
                            // the last entry of a day takes the day's heading and card with it
                            .opacity(dayFading ? 0 : 1)
                        }
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                if visible.isEmpty { emptyState.padding(.top, -16).transition(.opacity) }   // -16: the empty block above still has its gap
                Spacer(minLength: 110)
            }
            .padding(16)
            // every add / remove / restore / filter change moves the list the same way, whoever made the change
            .animation(.easeInOut(duration: 0.35), value: visible.map(\.id))
        }
        .background(Theme.bg.ignoresSafeArea())
        .refreshable { await store.scan(courses: catalog.courses, force: true) }
        .sheet(isPresented: $showAdd) { DailyEditSheet() }
        .sheet(isPresented: $showGuide) { DailyBackTapGuide() }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { item in
            guard let item else { return }
            reading = true
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let r = await DailyCapture.process(imageData: data, text: nil)
                reading = false
                photo = nil
                readResult = r.message
            }
        }
        .alert("Noticeboard", isPresented: Binding(get: { readResult != nil }, set: { if !$0 { readResult = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(readResult ?? "") }
        .sheet(item: $editing) { DailyEditSheet(existing: $0) }
        .task {
            await catalog.loadIfNeeded()
            highlight = store.unseenIDs
        }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Noticeboard").font(Theme.font(.largeTitle).weight(.bold)).foregroundColor(Theme.txt)
                Text("Class changes and notices")
                    .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
            }
            Spacer()
            if store.scanning || reading { ProgressView().tint(Theme.accent) }
            else {
                Button { Task { await store.scan(courses: catalog.courses, force: true) } } label: {
                    Image(systemName: "arrow.clockwise").foregroundColor(Theme.accent)
                }
            }
            Menu {
                Button { showAdd = true } label: { Label("Add by hand", systemImage: "square.and.pencil") }
                Button { showPhotos = true } label: { Label("Read a screenshot", systemImage: "photo") }
                Button { showGuide = true } label: { Label("Send with Back Tap", systemImage: "hand.tap") }
            } label: {
                Image(systemName: "plus").font(Theme.font(.body).weight(.bold))
                    .foregroundColor(Theme.onAccent)
                    .frame(width: 34, height: 34).background(Theme.accent).clipShape(Circle())
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pill("All", icon: nil, on: kindFilter == nil) { kindFilter = nil }
                    ForEach(DailyKind.shown) { k in
                        pill(k.title, icon: k.icon, on: kindFilter == k) { kindFilter = (kindFilter == k ? nil : k) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            HStack(spacing: 10) {
                segment("Upcoming", on: !showPast && !showRemoved) { showPast = false; showRemoved = false }
                segment("Past", on: showPast && !showRemoved) { showPast = true; showRemoved = false }
                segment("Removed", on: showRemoved) { showRemoved = true }
                Spacer()
                Menu {
                    Button("All subjects") { courseFilter = nil }
                    ForEach(catalog.courses) { c in
                        Button { courseFilter = c.id } label: {
                            if courseFilter == c.id { Label(c.subjectName, systemImage: "checkmark") }
                            else { Text(c.subjectName) }
                        }
                    }
                } label: {
                    Image(systemName: courseFilter == nil ? "line.3.horizontal.decrease.circle"
                                                          : "line.3.horizontal.decrease.circle.fill")
                        .font(Theme.font(.title3)).foregroundColor(Theme.accent)
                }
            }
        }
    }

    private func pill(_ title: String, icon: String?, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(Theme.font(.footnote).weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? Theme.accent : Theme.surface2)
            .foregroundColor(on ? Theme.onAccent : Theme.txt)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Theme.accent : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func segment(_ title: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title).font(Theme.font(.subheadline).weight(on ? .bold : .regular))
                .foregroundColor(on ? Theme.accent : Theme.muted)
                .padding(.vertical, 4)
                .overlay(Rectangle().fill(on ? Theme.accent : Color.clear).frame(height: 2), alignment: .bottom)
        }
        .buttonStyle(.plain)
    }

    /// Remove / restore in three steps, so the list never draws a row over another one:
    /// 1. wait until the context menu has gone, then fade the row out where it stands;
    /// 2. close the gap it leaves (its height, or the whole day's block, shrinks to nothing) so the rows below glide up;
    /// 3. take it out of the data with no animation: it is already invisible and has no height, so nothing moves.
    private func fadeOut(_ id: String, then change: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            withAnimation(.easeOut(duration: 0.18)) { fading.insert(id) }
            try? await Task.sleep(nanoseconds: 190_000_000)
            withAnimation(.easeInOut(duration: 0.34)) { collapsing.insert(id) }
            try? await Task.sleep(nanoseconds: 360_000_000)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                change()
                fading.remove(id)
                collapsing.remove(id)
            }
        }
    }

    @ViewBuilder private func menu(_ e: DailyEntry) -> some View {
        Button { editing = e } label: { Label("Edit", systemImage: "pencil") }
        if e.hidden == true {
            Button {
                fadeOut(e.id) { store.unhide(e.id) }
            } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
        } else {
            Button(role: .destructive) {
                fadeOut(e.id) { store.remove(e.id) }
            } label: {
                Label(e.source == .manual ? "Delete" : "Remove", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark").font(Theme.font(.largeTitle)).foregroundColor(Theme.accent)
            Text(showRemoved ? "Nothing removed" : (showPast ? "Nothing in the past" : "Nothing coming up"))
                .fontWeight(.semibold).foregroundColor(Theme.txt)
            Text("Cancelled, online or moved classes found in your announcements show up here. You get a reminder 1 hour before each class that has a time. Send a screenshot with Back Tap, or tap + to add your own.")
                .font(Theme.font(.footnote)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
        }
        .padding(.vertical, 40).frame(maxWidth: .infinity)
    }
}

// MARK: - Row

struct DailyRow: View {
    let entry: DailyEntry
    var isNew = false

    private var when: String? {
        var parts: [String] = []
        if let nd = entry.newDate, entry.kind == .rescheduled {
            if let cd = entry.classDate {
                parts.append("From \(dayText(cd))" + (clockText(entry.startMin).map { " \($0)" } ?? ""))
            }
            parts.append("To \(dayText(nd))" + (clockText(entry.newStartMin).map { " \($0)" } ?? ""))
        } else if let cd = entry.classDate {
            parts.append(dayText(cd) + (clockText(entry.startMin).map { " · \($0)" } ?? ""))
        } else if let t = clockText(entry.startMin) {
            parts.append(t)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  →  ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind.icon)
                .font(Theme.font(.body).weight(.semibold))
                .foregroundColor(entry.kind.color)
                .frame(width: 34, height: 34)
                .background(entry.kind.color.opacity(0.16))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.kind.title).font(Theme.font(.caption).weight(.bold)).foregroundColor(entry.kind.color)
                    if isNew {
                        Text("NEW").font(Theme.font(.caption2).weight(.bold)).foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.accent).clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                    Text(entry.source == .manual ? "Added by you" : (entry.source == .screenshot ? "Screenshot" : (entry.byAI == true ? "AI" : "Auto")))
                        .font(Theme.font(.caption2)).foregroundColor(Theme.muted)
                }
                if let n = entry.courseName {
                    Text(n).fontWeight(.semibold).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                }
                if let w = when {
                    Label(w, systemImage: "clock").font(Theme.font(.footnote)).foregroundColor(Theme.txt)
                }
                if let v = entry.venue, !v.isEmpty {
                    Label(v, systemImage: entry.kind == .online ? "video" : "mappin.and.ellipse")
                        .font(Theme.font(.footnote)).foregroundColor(Theme.txt)
                }
                // the whole summary (the links in it can be tapped); the original message is in the entry's sheet
                Text(DailyText.linkified(entry.summary)).font(Theme.read(.footnote)).foregroundColor(Theme.muted)
                    .multilineTextAlignment(.leading)
                if let n = entry.notes, !n.isEmpty {
                    Text(n).font(Theme.read(.footnote)).foregroundColor(Theme.muted).italic()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
        .contentShape(Rectangle())
    }
}

// MARK: - Add / edit

struct DailyEditSheet: View {
    var existing: DailyEntry? = nil

    @EnvironmentObject var catalog: CourseCatalog
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Bool

    @State private var kind: DailyKind
    @State private var courseId: Int?
    @State private var summary: String
    @State private var notes: String
    @State private var venue: String
    @State private var hasDate: Bool
    @State private var classDate: Date
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var hasNewDate: Bool
    @State private var newDate: Date
    @State private var hasNewTime: Bool
    @State private var newTime: Date

    init(existing: DailyEntry? = nil) {
        self.existing = existing
        let base = Calendar.current.startOfDay(for: Date())
        let startKind: DailyKind = (existing?.kind.isWork == false) ? (existing?.kind ?? .cancelled) : .cancelled
        _kind = State(initialValue: startKind)
        _courseId = State(initialValue: existing?.courseId)
        _summary = State(initialValue: existing?.summary ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
        _venue = State(initialValue: existing?.venue ?? "")
        _hasDate = State(initialValue: existing == nil ? true : existing?.classDate != nil)
        _classDate = State(initialValue: existing?.classDate ?? Calendar.current.date(byAdding: .day, value: 1, to: base) ?? base)
        _hasTime = State(initialValue: existing?.startMin != nil)
        _time = State(initialValue: minutesToDate(existing?.startMin ?? 540))
        _hasNewDate = State(initialValue: existing?.newDate != nil)
        _newDate = State(initialValue: existing?.newDate ?? Calendar.current.date(byAdding: .day, value: 2, to: base) ?? base)
        _hasNewTime = State(initialValue: existing?.newStartMin != nil)
        _newTime = State(initialValue: minutesToDate(existing?.newStartMin ?? 540))
    }

    private var subjectName: String? {
        guard let id = courseId else { return nil }
        if let c = catalog.courses.first(where: { $0.id == id }) { return c.subjectName }
        return existing?.courseId == id ? existing?.courseName : nil
    }
    private var canSave: Bool { courseId != nil || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    label("Type")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(DailyKind.shown) { chip($0) }
                    }

                    label("Subject")
                    subjectMenu

                    label(kind == .rescheduled ? "Original class" : "Class on")
                    dateRow(on: $hasDate, date: $classDate, optionalLabel: "Set date")
                    timeRow(on: $hasTime, time: $time, optionalLabel: "Set time")

                    if kind == .rescheduled {
                        label("Moved to")
                        dateRow(on: $hasNewDate, date: $newDate, optionalLabel: "Set new date")
                        timeRow(on: $hasNewTime, time: $newTime, optionalLabel: "Set new time")
                    }

                    if kind == .venue || kind == .online || kind == .rescheduled {
                        label(kind == .online ? "Platform / link (optional)" : "Room / venue (optional)")
                        TextField("", text: $venue,
                                  prompt: Text(kind == .online ? "e.g. Zoom, Google Meet" : "e.g. Room 3.12, KICT")
                                      .foregroundColor(Theme.muted.opacity(0.6)))
                            .foregroundColor(Theme.txt).focused($focus).dailyBox(focused: focus)
                    }

                    label("What changed")
                    TextField("", text: $summary,
                              prompt: Text("e.g. Lecture cancelled, or moved to Room 3.12").foregroundColor(Theme.muted.opacity(0.6)),
                              axis: .vertical)
                        .lineLimit(2...14).foregroundColor(Theme.txt).dailyBox()

                    // the message this was read from, whole and not cropped (links can be tapped)
                    if let full = existing?.fullText, !full.isEmpty {
                        label("Original message")
                        Text(DailyText.linkified(full)).font(Theme.read(.footnote)).foregroundColor(Theme.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).dailyBox()
                    }

                    label("Notes (optional)")
                    TextField("", text: $notes,
                              prompt: Text("Anything else to remember").foregroundColor(Theme.muted.opacity(0.6)),
                              axis: .vertical)
                        .lineLimit(2...6).foregroundColor(Theme.txt).dailyBox()

                    if let e = existing, e.source == .announcement, let t = e.announcementTitle {
                        Text("From the announcement: \(t)").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(existing == nil ? "Add to Noticeboard" : "Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.muted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.fontWeight(.semibold).disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(ThemeStore.shared.theme.scheme)
        .task { await catalog.loadIfNeeded() }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(Theme.font(.caption).weight(.medium)).foregroundColor(Theme.muted)
    }

    private func chip(_ k: DailyKind) -> some View {
        let on = kind == k
        return Button { kind = k } label: {
            Label(k.title, systemImage: k.icon)
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

    private var subjectMenu: some View {
        Menu {
            Button("No subject") { courseId = nil }
            ForEach(catalog.courses) { c in
                Button { courseId = c.id } label: {
                    if courseId == c.id { Label(c.subjectName, systemImage: "checkmark") }
                    else { Text(c.subjectName) }
                }
            }
        } label: {
            HStack {
                Text(subjectName ?? (catalog.loaded ? "Choose subject" : "Loading subjects…"))
                    .foregroundColor(subjectName == nil ? Theme.muted : Theme.txt)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            }
            .dailyBox()
        }
    }

    private func dateRow(on: Binding<Bool>, date: Binding<Date>, optionalLabel: String) -> some View {
        HStack {
            Toggle(optionalLabel, isOn: on).tint(Theme.accent).foregroundColor(Theme.txt)
            if on.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date).labelsHidden().tint(Theme.accent)
            }
        }
        .dailyBox()
    }

    private func timeRow(on: Binding<Bool>, time: Binding<Date>, optionalLabel: String) -> some View {
        HStack {
            Toggle(optionalLabel, isOn: on).tint(Theme.accent).foregroundColor(Theme.txt)
            if on.wrappedValue {
                DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden().tint(Theme.accent)
            }
        }
        .dailyBox()
    }

    private func save() {
        let cal = Calendar.current
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cd = hasDate ? cal.startOfDay(for: classDate) : nil
        let nd = (kind == .rescheduled && hasNewDate) ? cal.startOfDay(for: newDate) : nil
        var e = existing ?? DailyEntry(
            id: "m" + UUID().uuidString, kind: kind, courseId: nil, courseName: nil, summary: "",
            classDate: nil, startMin: nil, newDate: nil, newStartMin: nil, venue: nil, notes: nil,
            source: .manual, byAI: nil, discussionId: nil, announcementTitle: nil, postedAt: Date(),
            edited: nil, hidden: nil, updated: Date())
        e.kind = kind
        e.courseId = courseId
        e.courseName = subjectName
        e.summary = s.isEmpty ? kind.title : s
        e.classDate = cd
        e.startMin = hasTime ? dateToMinutes(time) : nil
        e.newDate = nd
        e.newStartMin = (kind == .rescheduled && hasNewTime) ? dateToMinutes(newTime) : nil
        e.venue = (kind == .venue || kind == .online || kind == .rescheduled) && !v.isEmpty ? v : nil
        e.notes = n.isEmpty ? nil : n
        if existing == nil { DailyInfoStore.shared.add(e) } else { DailyInfoStore.shared.update(e) }
        dismiss()
    }
}


extension Notification.Name {
    /// Posted when a screen is about to be pushed from the Noticeboard (a tool tile was tapped)
    static let noticeBoardPushing = Notification.Name("noticeBoardPushing")
}

// MARK: - Fade the tab bar with the swipe, without touching the layout

/// Put it as a .background of the Noticeboard page inside the pager. It watches where that page really is on screen and
/// fades the tab bar from it on every frame of the swipe: fully there on My courses, gone on Noticeboard, and anything in
/// between while the finger (or the settling animation) moves the pages. Before, the bar faded on a timer once the pages had
/// stopped, which looked like a pop after the slide. No frame, transform or safe area of the bar is changed.
struct TabBarFollower: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) { v.attachIfNeeded() }

    final class ProbeView: UIView {
        private var observation: NSKeyValueObservation?
        private weak var scroll: UIScrollView?
        private weak var bar: UITabBar?

        /// A tool was tapped and its screen is about to slide in. The page only leaves the window when that slide is over,
        /// so waiting for that (below) showed the bar late, after the new screen had already arrived. Show it now, with a
        /// short fade, and stop following the page until it is back.
        private var pushObserver: NSObjectProtocol?
        private var suspended = false

        private func showBarForPush() {
            suspended = true
            stopLink()
            removeVeil()
            guard let bar else { return }
            bar.isUserInteractionEnabled = true
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) { bar.alpha = 1 }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                // another tab or a pushed screen: the bar must be normal there
                observation = nil
                scroll = nil
                stopLink()
                restoreBar()
                if let o = pushObserver { NotificationCenter.default.removeObserver(o); pushObserver = nil }
            } else {
                suspended = false
                if pushObserver == nil {
                    pushObserver = NotificationCenter.default.addObserver(forName: .noticeBoardPushing, object: nil, queue: .main) { [weak self] _ in
                        self?.showBarForPush()
                    }
                }
                attachIfNeeded()
                // the pager may not be in place yet during the first layout pass
                DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
            }
        }

        func attachIfNeeded() {
            guard window != nil else { return }
            if bar == nil { bar = findTabBar() }
            guard observation == nil || scroll == nil else { return }
            var view: UIView? = superview
            while let v = view, !((v as? UIScrollView)?.isPagingEnabled ?? false) { view = v.superview }
            guard let sv = view as? UIScrollView else { return }
            scroll = sv
            observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.follow()
            }
            follow()
        }

        private func findTabBar() -> UITabBar? {
            var r: UIResponder? = self
            while let n = r?.next {
                if let vc = n as? UIViewController, let tbc = vc.tabBarController { return tbc.tabBar }
                r = n
            }
            return nil
        }

        /// 0 = Noticeboard is on screen, 1 = My courses is. Measured on the page itself (like CoursePagerProbe), because the
        /// pager's contentOffset is re-centred now and then and can't be trusted as a position.
        ///
        /// The bar's own alpha is NOT used: the system tab bar is a glass material, and when its alpha drops the glass is
        /// dropped by the system part-way through, so the bar looked like it vanished at about half. Instead the bar stays at
        /// alpha 1 and a veil in the page's background colour is laid over it and faded IN in a straight line: 0 = bar fully
        /// visible, 1 = bar fully covered. It is covered completely exactly when the Daily page has fully arrived.
        private func follow() {
            guard !suspended, window != nil, let bar, let host = bar.superview else { return }
            let w = window?.bounds.width ?? bounds.width
            guard w > 0 else { return }
            let x = convert(bounds, to: nil).minX            // 0 when Noticeboard fills the screen, -w when it is fully left
            let p = min(max(-x / w, 0), 1)                   // 0 = Daily, 1 = My courses

            if p >= 0.995 {
                stopLink()
                // My courses at rest: the plain bar, and no veil anywhere (nothing of it may stay on screen)
                removeVeil()
                bar.alpha = 1
                bar.isUserInteractionEnabled = true
            } else if p <= 0.005 {
                stopLink()
                // Noticeboard at rest: the bar is simply not drawn (the veil was fully opaque a moment ago, so no change shows)
                removeVeil()
                bar.alpha = 0
                bar.isUserInteractionEnabled = false
            } else {
                // in between: the bar stays at alpha 1 and the veil covers it by 1 - p.
                // The page can also be "in between" because a screen is sliding it (coming back from a tool such as the
                // To-Do List with the back swipe): the pager's contentOffset does not change then, so nothing else would
                // call follow() again when the slide ends and the half-covered bar stayed. Keep following frame by frame
                // until the page is at rest.
                startLink()
                bar.alpha = 1
                bar.isUserInteractionEnabled = p > 0.6
                let v = veil ?? makeVeil()
                if v.superview !== host { host.insertSubview(v, aboveSubview: bar) } else { host.bringSubviewToFront(v) }
                // cover only the bar's own pill (the union of its visible parts), not the strip down to the screen edge
                let parts = bar.subviews.filter { !$0.isHidden && $0.frame.width > 1 && $0.frame.height > 1 }
                let pill = parts.reduce(CGRect.null) { $0.union($1.frame) }
                let area = pill.isNull ? bar.bounds : pill
                v.frame = bar.convert(area, to: host).insetBy(dx: -1, dy: -1)
                v.layer.cornerRadius = v.frame.height / 2
                v.layer.masksToBounds = true
                v.backgroundColor = UIColor(Theme.bg)
                v.alpha = 1 - p
            }
        }

        private var link: CADisplayLink?
        private final class LinkTarget: NSObject {
            weak var owner: ProbeView?
            @objc func tick() { owner?.follow() }
        }
        private func startLink() {
            guard link == nil else { return }
            let t = LinkTarget()
            t.owner = self
            let l = CADisplayLink(target: t, selector: #selector(LinkTarget.tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        private func stopLink() {
            link?.invalidate()
            link = nil
        }
        deinit { link?.invalidate() }

        private func removeVeil() {
            veil?.removeFromSuperview()
            veil = nil
        }

        private var veil: UIView?
        private func makeVeil() -> UIView {
            let v = UIView()
            v.isUserInteractionEnabled = false
            veil = v
            return v
        }

        private func restoreBar() {
            removeVeil()
            guard let bar else { return }
            bar.alpha = 1
            bar.isUserInteractionEnabled = true
        }
    }
}


// MARK: - A view that can close up to nothing (used when an entry is removed)

private struct CollapseHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Measures its content, and when `collapsed` turns on animates its height down to zero (SwiftUI can't animate to or from
/// "natural height", so the height is measured first). `clip` hides what overflows while it closes (not for the day blocks:
/// clipping them would cut off the card's glow).
private struct Collapsible<Content: View>: View {
    let collapsed: Bool
    var clip = true
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat?

    var body: some View {
        content()
            .background(GeometryReader { g in Color.clear.preference(key: CollapseHeightKey.self, value: g.size.height) })
            .onPreferenceChange(CollapseHeightKey.self) { h in if !collapsed && h > 0 { height = h } }
            .frame(height: collapsed ? 0 : height, alignment: .top)
            .modifier(OptionalClip(on: clip))
    }
}

private struct OptionalClip: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.clipped() } else { content }
    }
}

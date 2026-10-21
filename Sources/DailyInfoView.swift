import SwiftUI

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

// MARK: - Page container: Daily summary (left)  <-  swipe left to right  ->  My courses (right)
//
// A paged view inside the first tab. My courses is the home page; swipe left-to-right on it to open Daily summary,
// which sits to its left. Swipe right-to-left to come back.
//
// The tab bar is NOT hidden through SwiftUI's .toolbar(.hidden, for: .tabBar). That changes the page's safe area,
// so after the swipe had finished the bar disappeared late (a fixed wait) and Daily summary jumped down by the
// bar's inset the moment it did. Instead PagerTabBarLink (below) slides and fades the UIKit tab bar by the pager's
// own scroll offset: the bar leaves exactly with the finger, and no layout ever changes.
//
// The pager ignores the top and bottom safe area and always fills the screen; pages scroll underneath the status
// bar (soft fade) and the tab bar, and My courses keeps its own room at the bottom.

struct CoursesHome: View {
    @EnvironmentObject var catalog: CourseCatalog
    @ObservedObject private var store = DailyInfoStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 1            // 0 = Daily summary (left), 1 = My courses (right, home)

    /// Room kept free at the bottom of My courses so the last card can scroll up clear of the tab bar
    private let tabBarClearance: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            let top = geo.safeAreaInsets.top
            TabView(selection: $page) {
                DailyInfoView()
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
                    .tag(0)
                CoursesView()
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: tabBarClearance) }
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .noBottomEdgeEffect()                                   // no system band behind the floating tab bar
            .ignoresSafeArea(.container, edges: [.top, .bottom])   // pager size never depends on the bars
            .background(Theme.bg.ignoresSafeArea())
            .background(PagerTabBarLink(page: page).allowsHitTesting(false))
            .overlay(alignment: .top) {
                // soft fade under the status bar instead of a hard cut
                LinearGradient(colors: [Theme.bg.opacity(0.92), Theme.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: top + 8)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: page) { new in
            if new == 1 { store.markAllSeen() }
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
            Task { await store.scan(courses: catalog.courses, force: true) }
        }
    }
}

extension View {
    /// iOS 26 puts a system "edge effect" under floating bars. On this app's pure-black pages it showed up as a thin
    /// black band at the very bottom, behind the tab bar. Hidden for the bottom edge only (iOS 26+, Xcode 26+).
    @ViewBuilder func noBottomEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .bottom) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Tab bar follows the pager

/// Slides and fades the system tab bar in step with the pager's swipe (0 = Daily summary: gone, 1 = My courses:
/// shown). It watches the contentOffset of the pager's paging scroll view. Only the bar's transform and alpha are
/// touched (never the SwiftUI toolbar visibility), so nothing is re-laid out and no page moves.
/// If the pager's scroll view can't be found it falls back to a short slide when the page changes.
private struct PagerTabBarLink: UIViewRepresentable {
    let page: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        let c = context.coordinator
        c.desiredPage = page
        v.windowChanged = { [weak c, weak v] in
            guard let c, let v else { return }
            if v.window != nil { c.attach(from: v, tries: 6) } else { c.release() }
        }
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) {
        context.coordinator.settle(page: page)
    }

    static func dismantleUIView(_ v: ProbeView, coordinator: Coordinator) { coordinator.release() }

    final class ProbeView: UIView {
        var windowChanged: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?()
        }
    }

    final class Coordinator {
        var desiredPage = 1
        private weak var tabBar: UITabBar?
        private weak var pager: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var index = 1            // page the pager rests on (0 = Daily summary, 1 = My courses)
        private var lastDelta: CGFloat = 0

        func attach(from view: UIView, tries: Int) {
            guard let window = view.window else { return }
            // the window's own black must match the page colour, or any gap shows as a black band
            window.backgroundColor = UIColor(Theme.bg)
            tabBar = Self.find(UITabBar.self, in: window) { _ in true }
            pager = Self.find(UIScrollView.self, in: window) { sv in
                sv.isPagingEnabled
                    && abs(sv.bounds.width - window.bounds.width) < 2
                    && sv.contentSize.width > sv.bounds.width * 1.5
                    && sv.contentSize.height <= sv.bounds.height + 1
            }
            index = desiredPage
            lastDelta = 0
            observation = nil
            if let pager {
                observation = pager.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                    self?.scrolled(sv)
                }
            } else if tries > 0 {
                // the pager isn't laid out yet: look again shortly
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attach(from: view, tries: tries - 1)
                }
            }
            apply(CGFloat(index))
        }

        /// The SwiftUI page changed (swipe finished): make sure the bar rests exactly where it belongs.
        func settle(page: Int) {
            desiredPage = page
            if observation == nil {
                // fallback, no live tracking: short slide
                UIView.animate(withDuration: 0.2) { self.apply(CGFloat(page)) }
            } else if abs(lastDelta) < 0.001 {
                index = page
                apply(CGFloat(page))
            }
        }

        func release() {
            observation = nil
            apply(1)
        }

        private func scrolled(_ sv: UIScrollView) {
            let w = sv.bounds.width
            guard w > 0 else { return }
            // -1...1 around the resting position; negative = dragging towards the page on the left
            let delta = (sv.contentOffset.x - w) / w
            // When a page change finishes the pager re-centres itself and the offset jumps by about one page
            let jump = delta - lastDelta
            if jump > 0.5 { index -= 1 } else if jump < -0.5 { index += 1 }
            lastDelta = delta
            apply(CGFloat(index) + delta)
        }

        private func apply(_ progress: CGFloat) {
            guard let bar = tabBar else { return }
            let p = min(max(progress, 0), 1)
            bar.alpha = p
            bar.transform = CGAffineTransform(translationX: 0, y: (1 - p) * (bar.bounds.height + 40))
            bar.isUserInteractionEnabled = p > 0.99
            bar.accessibilityElementsHidden = p < 0.5
        }

        private static func find<T: UIView>(_ type: T.Type, in root: UIView, where ok: (T) -> Bool) -> T? {
            if let t = root as? T, ok(t) { return t }
            for s in root.subviews { if let f = find(type, in: s, where: ok) { return f } }
            return nil
        }
    }
}

// MARK: - Daily Summary screen

struct DailyInfoView: View {
    @EnvironmentObject var catalog: CourseCatalog
    @ObservedObject private var store = DailyInfoStore.shared
    @State private var kindFilter: DailyKind?
    @State private var courseFilter: Int?
    @State private var showPast = false
    @State private var showRemoved = false
    @State private var editing: DailyEntry?
    @State private var showAdd = false
    @State private var highlight: Set<String> = []     // what was new when the page opened

    private var visible: [DailyEntry] {
        store.entries.filter { e in
            (showRemoved ? e.hidden == true : e.hidden != true)
                && (kindFilter == nil || e.kind == kindFilter)
                && (courseFilter == nil || e.courseId == courseFilter)
                && (showRemoved || e.isPast() == showPast)
        }
    }

    /// Upcoming: soonest day first. Past: latest first. Entries without a date go under "No date".
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
                filters
                if let n = store.scanNote {
                    Text(n).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                }
                ForEach(groups, id: \.title) { g in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(g.title).font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.muted)
                        VStack(spacing: 0) {
                            ForEach(g.items) { e in
                                DailyRow(entry: e, isNew: highlight.contains(e.id))
                                    .onTapGesture { editing = e }
                                    .contextMenu { menu(e) }
                            }
                        }
                        .glowCard(radius: 12)
                    }
                }
                if visible.isEmpty { emptyState }
                Spacer(minLength: 50)
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.scan(courses: catalog.courses, force: true) }
        .sheet(isPresented: $showAdd) { DailyEditSheet() }
        .sheet(item: $editing) { DailyEditSheet(existing: $0) }
        .task {
            await catalog.loadIfNeeded()
            highlight = store.unseenIDs
        }
        .onDisappear { store.markAllSeen() }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily summary").font(Theme.font(.largeTitle).weight(.bold)).foregroundColor(Theme.txt)
                Text("Class changes from your announcements")
                    .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
            }
            Spacer()
            if store.scanning { ProgressView().tint(Theme.accent) }
            else {
                Button { Task { await store.scan(courses: catalog.courses, force: true) } } label: {
                    Image(systemName: "arrow.clockwise").foregroundColor(Theme.accent)
                }
            }
            Button { showAdd = true } label: {
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
                    ForEach(DailyKind.allCases) { k in
                        pill(k.title, icon: k.icon, on: kindFilter == k) { kindFilter = (kindFilter == k ? nil : k) }
                    }
                }
                .padding(.horizontal, 16)      // chips start at the page margin...
            }
            .padding(.horizontal, -16)         // ...but scroll all the way to the screen edge instead of being cut early
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

    @ViewBuilder private func menu(_ e: DailyEntry) -> some View {
        Button { editing = e } label: { Label("Edit", systemImage: "pencil") }
        if e.hidden == true {
            Button { store.unhide(e.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
        } else {
            Button(role: .destructive) { withAnimation { store.remove(e.id) } } label: {
                Label(e.source == .manual ? "Delete" : "Remove", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark").font(Theme.font(.largeTitle)).foregroundColor(Theme.accent)
            Text(showRemoved ? "Nothing removed" : (showPast ? "Nothing in the past" : "No class changes"))
                .fontWeight(.semibold).foregroundColor(Theme.txt)
            Text("Cancelled, online, moved or rescheduled classes found in your announcements show up here. Tap + to add your own.")
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
        if entry.kind == .rescheduled, let nd = entry.newDate {
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
                    Text(entry.source == .manual ? "Added by you" : (entry.byAI == true ? "AI" : "Auto"))
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
                Text(entry.summary).font(Theme.read(.footnote)).foregroundColor(Theme.muted)
                    .lineLimit(3).multilineTextAlignment(.leading)
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
        _kind = State(initialValue: existing?.kind ?? .cancelled)
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
                        ForEach(DailyKind.allCases) { chip($0) }
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
                              prompt: Text("e.g. Lecture cancelled, lecturer is away").foregroundColor(Theme.muted.opacity(0.6)),
                              axis: .vertical)
                        .lineLimit(2...5).foregroundColor(Theme.txt).dailyBox()

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
            .navigationTitle(existing == nil ? "Add class change" : "Edit class change")
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

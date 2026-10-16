import SwiftUI

// MARK: - Subjects (Moodle "Section" courses)
//
// Every subject has two course pages on Moodle: a public one and one per class that has the word
// "Section" in its name. Only the "Section" ones are used for to-dos / Drive, and the word
// "Section" (plus the number) is hidden when showing the name.

extension Course {
    /// Set to false if you'd rather keep the semester / course code in the displayed name.
    static let stripCodes = true

    /// "BICS 1303_05" -> "BICS 1303 05"
    var prettyShort: String? { shortname.map { $0.replacingOccurrences(of: "_", with: " ") } }
    var prettyFull: String { fullname.replacingOccurrences(of: "_", with: " ") }

    var isSectionCourse: Bool { fullname.range(of: "section", options: .caseInsensitive) != nil }

    /// "SEM1 BICS 2306 Section 05 Software Engineering" -> "Software Engineering"
    /// "Enterprise Networking Section 5"                -> "Enterprise Networking"
    var subjectName: String { Course.cleanSubject(fullname) }

    static func cleanSubject(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\bsection\\s*\\d*\\b", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        if stripCodes {
            // leading semester / course code such as "SEM1 BICS 2306" (upper-case codes only)
            t = t.replacingOccurrences(of: "^\\s*(SEM\\s*\\d+\\s+)?[A-Z]{2,6}\\s*\\d{3,4}\\b", with: "",
                                       options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:,|()")))
        return t.isEmpty ? s : t
    }
}

/// The user's current "Section" courses, loaded once and shared (used by the subject pickers).
@MainActor
final class CourseCatalog: ObservableObject {
    @Published private(set) var courses: [Course] = []
    @Published private(set) var loaded = false
    private var loading = false

    func loadIfNeeded() async { if !loaded { await reload() } }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        func fetch(_ classification: String) async -> [Course]? {
            let r: CourseList? = try? await MoodleAPI.shared.call(
                "core_course_get_enrolled_courses_by_timeline_classification",
                ["classification": classification, "limit": 0, "offset": 0, "sort": "fullname"])
            return r?.courses
        }
        // Current + upcoming semester first; fall back to every course if that gives nothing
        var list: [Course] = []
        var ok = false
        for c in ["inprogress", "future"] {
            if let got = await fetch(c) { list += got; ok = true }
        }
        if list.filter({ $0.isSectionCourse }).isEmpty, let all = await fetch("all") { list = all; ok = true }
        guard ok else { return }

        var seen = Set<Int>()
        courses = list.filter { $0.isSectionCourse && seen.insert($0.id).inserted }
            .sorted { $0.subjectName.localizedCaseInsensitiveCompare($1.subjectName) == .orderedAscending }
        loaded = true
    }
}

// MARK: - Model

enum TodoKind: String, Codable, CaseIterable, Identifiable {
    case work, extraClass, revise, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "Work to do"
        case .extraClass: return "Extra class"
        case .revise: return "Revise"
        case .other: return "Other"
        }
    }
    var icon: String {
        switch self {
        case .work: return "square.and.pencil"
        case .extraClass: return "person.2"
        case .revise: return "book"
        case .other: return "checklist"
        }
    }
    /// Label in front of the date
    var dueLabel: String {
        switch self {
        case .work: return "Should be done before"
        case .extraClass: return "Class on"
        case .revise: return "Revise before"
        case .other: return "Due by"
        }
    }
    var placeholder: String {
        switch self {
        case .work: return "e.g. Research for assignment 2"
        case .extraClass: return "e.g. Extra class on Chapter 5"
        case .revise: return "e.g. Chapter 4 – Subnetting"
        case .other: return "What do you need to do?"
        }
    }
}

struct TodoItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var kind: TodoKind
    var courseId: Int?
    var courseName: String?      // clean subject name, saved so history still reads well later
    var due: Date
    var notes: String?           // optional description
    var created = Date()
    var completedAt: Date?
}

// MARK: - Store (saved on the phone, survives restarts)

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    private let key = "todo.items.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([TodoItem].self, from: d) { items = list }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
        NotificationManager.shared.scheduleTodos(items)
    }

    var pending: [TodoItem] { items.filter { $0.completedAt == nil }.sorted { $0.due < $1.due } }
    var history: [TodoItem] {
        items.filter { $0.completedAt != nil }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    func pending(for courseId: Int) -> [TodoItem] { pending.filter { $0.courseId == courseId } }
    func count(for courseId: Int) -> Int { items.filter { $0.completedAt == nil && $0.courseId == courseId }.count }

    func add(_ i: TodoItem) { items.append(i); save() }
    func update(_ i: TodoItem) {
        if let n = items.firstIndex(where: { $0.id == i.id }) { items[n] = i; save() }
    }
    func complete(_ id: UUID) {
        if let n = items.firstIndex(where: { $0.id == id }) { items[n].completedAt = Date(); save() }
    }
    func restore(_ id: UUID) {
        if let n = items.firstIndex(where: { $0.id == id }) { items[n].completedAt = nil; save() }
    }
    func delete(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func clearHistory() { items.removeAll { $0.completedAt != nil }; save() }
}

// MARK: - Small helpers

private extension View {
    func fieldBox(focused: Bool = false) -> some View {
        self.padding(12)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(focused ? Theme.accent : Theme.line, lineWidth: 1))
    }
}

private func dueText(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

// MARK: - Row

struct TodoRow: View {
    let item: TodoItem
    var showSubject = true
    let onDone: () -> Void

    private var overdue: Bool { item.due < Date() }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onDone) {
                Image(systemName: "circle").font(.title2).foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).fontWeight(.semibold).foregroundColor(Theme.txt)
                    .multilineTextAlignment(.leading)
                if let d = item.notes, !d.isEmpty {
                    Text(d).font(.subheadline).foregroundColor(Theme.muted)
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
                if showSubject, let n = item.courseName {
                    Label(n, systemImage: item.kind.icon)
                        .font(.caption).foregroundColor(Theme.accent)
                } else if !showSubject {
                    Label(item.kind.title, systemImage: item.kind.icon)
                        .font(.caption).foregroundColor(Theme.accent)
                }
                Text("\(item.kind.dueLabel) \(dueText(item.due))")
                    .font(.caption)
                    .foregroundColor(overdue ? Color.red.opacity(0.85) : Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
        .contentShape(Rectangle())
    }
}

// MARK: - Profile > To-Do List

struct TodoListView: View {
    @EnvironmentObject var todos: TodoStore
    @State private var showAdd = false
    @State private var editing: TodoItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                let list = todos.pending
                if list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist").font(.largeTitle).foregroundColor(Theme.accent)
                        Text("Nothing to do").foregroundColor(Theme.txt).fontWeight(.semibold)
                        Text("Tap + to add work, an extra class or a chapter to revise.")
                            .font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 40).frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(list) { item in
                            TodoRow(item: item) { withAnimation { todos.complete(item.id) } }
                                .contextMenu {
                                    Button { editing = item } label: { Label("Edit", systemImage: "pencil") }
                                    Button(role: .destructive) { todos.delete(item.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .onTapGesture { editing = item }
                        }
                    }
                    .glowCard()
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("To-Do List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                NavigationLink { TodoHistoryView() } label: { Image(systemName: "clock.arrow.circlepath") }
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { TodoEditSheet() }
        .sheet(item: $editing) { TodoEditSheet(existing: $0) }
    }
}

// MARK: - History

struct TodoHistoryView: View {
    @EnvironmentObject var todos: TodoStore
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                let list = todos.history
                if list.isEmpty {
                    Text("Finished to-dos will show up here.")
                        .font(.footnote).foregroundColor(Theme.muted).padding(.top, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(list) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundColor(Theme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).strikethrough().foregroundColor(Theme.muted)
                                    if let d = item.notes, !d.isEmpty {
                                        Text(d).font(.caption).foregroundColor(Theme.muted).lineLimit(2)
                                    }
                                    if let n = item.courseName {
                                        Text(n).font(.caption).foregroundColor(Theme.muted)
                                    }
                                    Text("Done \(dueText(item.completedAt ?? item.due))")
                                        .font(.caption2).foregroundColor(Theme.muted)
                                }
                                Spacer(minLength: 0)
                                Button { withAnimation { todos.restore(item.id) } } label: {
                                    Image(systemName: "arrow.uturn.backward").foregroundColor(Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                            .contextMenu {
                                Button(role: .destructive) { todos.delete(item.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .glowCard()
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !todos.history.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { confirmClear = true }.foregroundColor(Theme.accent)
                }
            }
        }
        .confirmationDialog("Delete all finished to-dos?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { todos.clearHistory() }
        }
    }
}

// MARK: - Add / edit

struct TodoEditSheet: View {
    var existing: TodoItem? = nil

    @EnvironmentObject var todos: TodoStore
    @EnvironmentObject var catalog: CourseCatalog
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @FocusState private var notesFocused: Bool

    @State private var title: String
    @State private var notes: String
    @State private var kind: TodoKind
    @State private var courseId: Int?
    @State private var due: Date

    init(existing: TodoItem? = nil) {
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
        _kind = State(initialValue: existing?.kind ?? .work)
        _courseId = State(initialValue: existing?.courseId)
        _due = State(initialValue: existing?.due
                     ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }

    private var subjectName: String? {
        guard let id = courseId else { return nil }
        if let c = catalog.courses.first(where: { $0.id == id }) { return c.subjectName }
        return existing?.courseId == id ? existing?.courseName : nil
    }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (kind == .other || courseId != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    label("Type")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(TodoKind.allCases) { k in chip(k) }
                    }

                    label("Subject")
                    subjectMenu

                    label("What to do")
                    TextField("", text: $title,
                              prompt: Text(kind.placeholder).foregroundColor(Theme.muted.opacity(0.6)),
                              axis: .vertical)
                        .lineLimit(1...3)
                        .foregroundColor(Theme.txt)
                        .focused($titleFocused)
                        .fieldBox(focused: titleFocused)

                    label("Description (optional)")
                    TextField("", text: $notes,
                              prompt: Text("Add details, links, page numbers…").foregroundColor(Theme.muted.opacity(0.6)),
                              axis: .vertical)
                        .lineLimit(3...8)
                        .foregroundColor(Theme.txt)
                        .focused($notesFocused)
                        .fieldBox(focused: notesFocused)

                    label(kind.dueLabel)
                    HStack {
                        Text(dueText(due)).foregroundColor(Theme.txt)
                        Spacer()
                        DatePicker("", selection: $due, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden().tint(Theme.accent)
                    }
                    .fieldBox()
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(existing == nil ? "New to-do" : "Edit to-do")
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
        .preferredColorScheme(.dark)
        .task { await catalog.loadIfNeeded() }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption.weight(.medium)).foregroundColor(Theme.muted)
    }

    private func chip(_ k: TodoKind) -> some View {
        let on = kind == k
        return Button { kind = k } label: {
            Label(k.title, systemImage: k.icon)
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

    private var subjectMenu: some View {
        Menu {
            if kind == .other {
                Button("No subject") { courseId = nil }
            }
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
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundColor(Theme.muted)
            }
            .fieldBox()
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if var e = existing {
            e.title = t; e.kind = kind; e.courseId = courseId; e.courseName = subjectName; e.due = due
            e.notes = n.isEmpty ? nil : n
            todos.update(e)
        } else {
            todos.add(TodoItem(title: t, kind: kind, courseId: courseId, courseName: subjectName, due: due,
                               notes: n.isEmpty ? nil : n))
        }
        dismiss()
    }
}

// MARK: - Course page > To-Do tab

struct CourseTodoTab: View {
    let courseId: Int
    @EnvironmentObject var todos: TodoStore

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(todos.pending(for: courseId)) { item in
                    TodoRow(item: item, showSubject: false) { withAnimation { todos.complete(item.id) } }
                }
            }
            .glowCard()
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

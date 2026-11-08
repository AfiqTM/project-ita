import Foundation
import WidgetKit

// Shared by the app AND the widget (project.yml compiles it into both).
// The app writes this snapshot into an App Group; the widget only reads it.

struct AttendanceItem: Codable, Identifiable, Hashable {
    var id: Int            // attendance activity (cmid)
    var name: String       // subject
    var percent: Double    // maximum possible attendance, 0-100

    /// Course code extracted from the name (e.g. "BICS 1306") or matched against the saved timetable by title.
    func resolvedCode(timetable: TimetableData?) -> String? {
        if let c = code { return c }
        guard let t = timetable else { return nil }
        let target = displayName.lowercased()
        return t.classes.first { $0.displayTitle.lowercased() == target || $0.title.lowercased() == target }?.code
    }

    /// Course code extracted from the prefix if present, e.g. "BICS 1306".
    var code: String? {
        let pattern = "(?:^|\\b)([A-Z]{2,6}\\s*\\d{3,4})\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let r = Range(m.range(at: 1), in: name) else { return nil }
        let raw = String(name[r]).uppercased().replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let letters = raw.prefix { $0.isLetter }
        let digits = raw.dropFirst(letters.count)
        return "\(letters) \(digits)"
    }

    /// Name without the "SEM1 BICS 1306 Section 04" prefix, e.g.
    /// "SEM1 BICS 1306 Section 04 Digital & Embedded Systems" -> "Digital & Embedded Systems".
    /// Computed only, so it is not part of the saved JSON. Falls back to the full name if stripping leaves nothing.
    var displayName: String {
        let pattern = "^\\s*(?:SEM\\s*\\d+\\s+)?[A-Z]{2,6}\\s*\\d{3,4}\\s+(?:SECTION\\s*\\d+\\s+)?"
        let cleaned = name
            .replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return TimetableText.normalCase(cleaned.isEmpty ? name : cleaned)
    }
}

struct AttendanceSnapshot: Codable {
    var items: [AttendanceItem]
    var updated: Date

    static let sample = AttendanceSnapshot(items: [
        .init(id: 1, name: "SEM1 BICS 1306 Section 04 Digital & Embedded Systems", percent: 90),
        .init(id: 2, name: "SEM1 BICS 2306 Section 05 Software Engineering", percent: 96.7),
        .init(id: 3, name: "SEM1 BIIT 2301 Section 04 User Experience Design", percent: 85)
    ], updated: Date())
}

// MARK: - Tasks (Assignment submissions)

struct TaskWidgetItem: Codable, Identifiable, Hashable {
    var id: Int             // assignment id
    var title: String       // assignment name, e.g. "Assignment 2"
    var courseName: String  // full course name from Moodle
    var due: Int            // unix timestamp

    var dueDate: Date { Date(timeIntervalSince1970: TimeInterval(due)) }

    /// Course code extracted from courseName (e.g. "BICS 1303") or matched against the saved timetable.
    func resolvedCode(timetable: TimetableData?) -> String? {
        let pattern = "(?:^|\\b)([A-Z]{2,6}\\s*\\d{3,4})\\b"
        if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let m = re.firstMatch(in: courseName, range: NSRange(courseName.startIndex..., in: courseName)),
           let r = Range(m.range(at: 1), in: courseName) {
            let raw = String(courseName[r]).uppercased().replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            let letters = raw.prefix { $0.isLetter }
            let digits = raw.dropFirst(letters.count)
            return "\(letters) \(digits)"
        }
        guard let t = timetable else { return nil }
        let target = displayCourseName.lowercased()
        return t.classes.first { $0.displayTitle.lowercased() == target || $0.title.lowercased() == target }?.code
    }

    /// Cleaned subject name without the "SEM1 BICS 1303 Section 04" prefix or parenthetical suffixes.
    var displayCourseName: String {
        let prefix = "^\\s*(?:SEM\\s*\\d+\\s+)?[A-Z]{2,6}\\s*\\d{3,4}\\s+(?:(?:SECTION|SEC)\\s*\\d+\\s+)?"
        var s = courseName.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,"))
        return TimetableText.normalCase(s.isEmpty ? courseName : s)
    }
}

struct TasksSnapshot: Codable {
    var items: [TaskWidgetItem]
    var updated: Date

    /// Unsubmitted tasks that are still due in the future, soonest first.
    func upcoming(from date: Date) -> [TaskWidgetItem] {
        let now = Int(date.timeIntervalSince1970)
        return items.filter { $0.due > now }.sorted { $0.due < $1.due }
    }

    static let sample = TasksSnapshot(items: [
        .init(id: 1, title: "Assignment 2", courseName: "SEM1 BICS 1303 Section 04 Digital Embedded & Systems",
              due: Int(Date().addingTimeInterval(14 * 3600).timeIntervalSince1970))
    ], updated: Date())
}

enum TasksStore {
    private static var fileURL: URL? { AttendanceStore.groupFile("tasks.json") }

    static func save(_ s: TasksSnapshot) {
        guard let url = fileURL, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> TasksSnapshot? {
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TasksSnapshot.self, from: d)
    }

    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}


func formatPercent(_ p: Double) -> String {
    let r = (p * 10).rounded() / 10
    return r == r.rounded() ? "\(Int(r))%" : String(format: "%.1f%%", r)
}

enum AttendanceStore {
    // Must match the group in the entitlements (project.yml). The signer may rewrite bundle ids when
    // sideloading, so "group.<runtime app bundle id>" is tried first, then the original name.
    private static let originalGroup = "group.com.afiq.italeem"

    private static var appBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        let isWidget = Bundle.main.bundlePath.hasSuffix(".appex")
        return isWidget ? id.split(separator: ".").dropLast().joined(separator: ".") : id
    }

    /// A file inside the shared App Group folder (attendance.json, timetable.json)
    static func groupFile(_ name: String) -> URL? {
        for g in ["group." + appBundleID, originalGroup] {
            if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
                return dir.appendingPathComponent(name)
            }
        }
        return nil
    }

    private static var fileURL: URL? { groupFile("attendance.json") }

    /// false = the app and widget were signed without a shared App Group, so no data can be passed
    static var isShared: Bool { fileURL != nil }

    static func save(_ s: AttendanceSnapshot) {
        guard let url = fileURL, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> AttendanceSnapshot? {
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AttendanceSnapshot.self, from: d)
    }

    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - To-Do (Academic Tools > To-Do List)

struct TodoWidgetItem: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String       // what to do, e.g. "Study for assignment 2"
    var courseName: String  // subject name (or kind title when no subject)
    var due: Date

    /// Course code extracted from courseName or matched against the saved timetable.
    func resolvedCode(timetable: TimetableData?) -> String? {
        let pattern = "(?:^|\\b)([A-Z]{2,6}\\s*\\d{3,4})\\b"
        if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let m = re.firstMatch(in: courseName, range: NSRange(courseName.startIndex..., in: courseName)),
           let r = Range(m.range(at: 1), in: courseName) {
            let raw = String(courseName[r]).uppercased().replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            let letters = raw.prefix { $0.isLetter }
            let digits = raw.dropFirst(letters.count)
            return "\(letters) \(digits)"
        }
        guard let t = timetable else { return nil }
        let target = displayCourseName.lowercased()
        guard !target.isEmpty else { return nil }
        return t.classes.first { $0.displayTitle.lowercased() == target || $0.title.lowercased() == target }?.code
    }

    var displayCourseName: String {
        let prefix = "^\\s*(?:SEM\\s*\\d+\\s+)?[A-Z]{2,6}\\s*\\d{3,4}\\s+(?:(?:SECTION|SEC)\\s*\\d+\\s+)?"
        var s = courseName.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,"))
        return TimetableText.normalCase(s.isEmpty ? courseName : s)
    }
}

struct TodoWidgetSnapshot: Codable {
    var items: [TodoWidgetItem]
    var updated: Date

    /// Pending to-dos due in the future (or today), soonest first.
    func upcoming(from date: Date) -> [TodoWidgetItem] {
        items.filter { $0.due > date }.sorted { $0.due < $1.due }
    }

    static let sample = TodoWidgetSnapshot(items: [
        .init(id: UUID(), title: "Study for assignment 2", courseName: "LEED 1301 English for Academic Writing",
              due: Date().addingTimeInterval(14 * 3600))
    ], updated: Date())
}

enum TodoWidgetStore {
    private static var fileURL: URL? { AttendanceStore.groupFile("todos.json") }

    static func save(_ s: TodoWidgetSnapshot) {
        guard let url = fileURL, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> TodoWidgetSnapshot? {
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TodoWidgetSnapshot.self, from: d)
    }

    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Study Plan (Academic Tools > Study Plan Tracker)

struct StudyPlanWidgetCategory: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var taken: Double
    var required: Double
}

struct StudyPlanWidgetSnapshot: Codable {
    var title: String
    var creditsTaken: Double
    var totalRequired: Double
    var categories: [StudyPlanWidgetCategory]
    var updated: Date

    var fraction: Double {
        guard totalRequired > 0 else { return 0 }
        return min(max(creditsTaken / totalRequired, 0), 1)
    }

    var percentInt: Int {
        Int((fraction * 100).rounded())
    }

    static func formatCredits(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    static let sample = StudyPlanWidgetSnapshot(
        title: "Study Plan",
        creditsTaken: 54.5,
        totalRequired: 120,
        categories: [
            .init(name: "University Required", taken: 12, required: 20),
            .init(name: "Core", taken: 30.5, required: 60),
            .init(name: "Elective", taken: 12, required: 40)
        ],
        updated: Date()
    )
}

enum StudyPlanWidgetStore {
    private static var fileURL: URL? { AttendanceStore.groupFile("studyplan.json") }

    static func save(_ s: StudyPlanWidgetSnapshot) {
        guard let url = fileURL, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> StudyPlanWidgetSnapshot? {
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StudyPlanWidgetSnapshot.self, from: d)
    }

    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}



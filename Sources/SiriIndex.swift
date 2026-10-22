import AppIntents
import CoreSpotlight
import Foundation

// MARK: - Content for Siri AI (iOS 18+, built for iOS 27)
//
// Apple Intelligence / the new Siri find an app's content by meaning when the app puts it in the Spotlight index as App
// Entities (Apple: "Making app entities available in Spotlight"). The assignments and announcements the app already
// downloads are donated here, so a loosely worded question ("is there DES class on Friday?", "what's due for the networking
// subject?") can be matched to the actual announcement or assignment, even if the words differ. Nothing here is sent
// anywhere: it goes into the phone's own Spotlight index. Older iOS versions simply skip it.

/// One assignment or announcement, as saved on the phone
struct SiriNote: Codable, Hashable {
    var id: String          // "assign-12" / "post-34"
    var kind: String        // "Assignment" or "Announcement"
    var courseId: Int
    var course: String      // clean subject name
    var title: String
    var body: String        // text Siri can read (due date, status, the announcement itself)
    var date: Double?       // due date (assignment) or posted date (announcement), unix time
}

enum SiriNotes {
    private static let key = "siri.notes.v1"
    private static let limit = 400

    static func all() -> [SiriNote] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let l = try? JSONDecoder().decode([SiriNote].self, from: d) else { return [] }
        return l
    }

    /// Adds or replaces notes (by id); the newest `limit` are kept. Then they are put in the Spotlight index.
    static func donate(_ new: [SiriNote]) async {
        guard !new.isEmpty else { return }
        var byId = Dictionary(all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for n in new { byId[n.id] = n }
        let kept = Array(byId.values.sorted { ($0.date ?? 0) > ($1.date ?? 0) }.prefix(limit))
        if let d = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(d, forKey: key) }
        if #available(iOS 18.0, *) {
            let entities = new.map(StudyItemEntity.init)
            try? await CSSearchableIndex(name: "iTaleemStudy").indexAppEntities(entities)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        if #available(iOS 18.0, *) {
            CSSearchableIndex(name: "iTaleemStudy").deleteAllSearchableItems { _ in }
        }
    }

    // ---- builders used by the screens that already have the data ----

    static func notes(from items: [AssignItem]) -> [SiriNote] {
        items.map { i in
            let course = SiriCourse(id: i.courseId, fullname: i.courseName, shortname: nil).name
            let due = i.due > 0 ? Date(timeIntervalSince1970: TimeInterval(i.due)) : nil
            var body = "Assignment for \(course)."
            if let due { body += " Due " + SiriData.fmtWhen(due) + "." }
            body += i.submitted ? " Already submitted." : " Not submitted yet."
            if let intro = i.a.intro?.plainText, !intro.isEmpty { body += " " + String(intro.prefix(400)) }
            return SiriNote(id: "assign-\(i.a.id)", kind: "Assignment", courseId: i.courseId, course: course,
                            title: i.a.name.decodedEntities, body: body, date: i.due > 0 ? Double(i.due) : nil)
        }
    }

    static func notes(fromAnnouncements list: [Discussion], courseId: Int, course: String) -> [SiriNote] {
        list.map { d in
            let title = (d.name ?? d.subject ?? "Announcement").decodedEntities
            return SiriNote(id: "post-\(d.discussion)", kind: "Announcement", courseId: courseId, course: course,
                            title: title, body: String((d.message ?? "").plainText.prefix(1200)),
                            date: d.created.map(Double.init))
        }
    }
}

@available(iOS 18.0, *)
struct StudyItemEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Study item"
    static var defaultQuery = StudyItemQuery()

    var id: String
    var kind: String
    var course: String
    var title: String
    var text: String
    var date: Date?

    init(_ n: SiriNote) {
        id = n.id; kind = n.kind; course = n.course; title = n.title; text = n.body
        date = n.date.map { Date(timeIntervalSince1970: $0) }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind) · \(course)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let a = CSSearchableItemAttributeSet()
        a.contentDescription = kind + " for " + course + ". " + text
        a.keywords = [kind, course] + course.split(separator: " ").map(String.init)
        return a
    }
}

@available(iOS 18.0, *)
struct StudyItemQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StudyItemEntity] {
        SiriNotes.all().filter { identifiers.contains($0.id) }.map(StudyItemEntity.init)
    }
    func entities(matching string: String) async throws -> [StudyItemEntity] {
        let q = string.lowercased()
        return SiriNotes.all().filter { ($0.title + " " + $0.course + " " + $0.body).lowercased().contains(q) }
            .map(StudyItemEntity.init)
    }
    func suggestedEntities() async throws -> [StudyItemEntity] {
        SiriNotes.all().prefix(20).map(StudyItemEntity.init)
    }
}

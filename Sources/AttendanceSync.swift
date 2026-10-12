import Foundation
import WidgetKit

// APP TARGET ONLY. Works out the maximum possible attendance of every in-progress subject that has an
// attendance activity, and hands the result to the widget. Reuses the app's existing attendance code
// (attendanceMobileContent, fetchHTML, parseAttendance, AttSummary.fillMax) without changing it.

extension AttSummary {
    var maxPercentValue: Double? {
        maxPercent.flatMap { Double($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
    }
}

extension MoodleAPI {
    // 1) Token only (no cookies, no auto-login key): the same call the official app uses.
    fileprivate func tokenMaxPercent(_ m: Module, courseId: Int, uid: Int) async -> Double? {
        guard let h = await attendanceMobileContent(cmid: m.id, courseId: courseId, userid: uid) else { return nil }
        var s = parseAttendance(h)
        s.fillMax()
        return s.maxPercentValue
    }

    // 2) Fallback: the website page, using only the existing web session.
    //    Background sync must NEVER request an auto-login key (allowAutologin: false), otherwise it
    //    uses up Moodle's one-key-per-6-minutes allowance and the user gets logged out later.
    fileprivate func webMaxPercent(_ m: Module, uid: Int) async -> Double? {
        guard let base = m.url, !base.isEmpty else { return nil }
        func page(_ view: String?) -> URL? {
            guard var c = URLComponents(string: base) else { return nil }
            var q = c.queryItems ?? []
            q.removeAll { $0.name == "view" }
            if let view { q.append(URLQueryItem(name: "view", value: view)) }
            c.queryItems = q
            return c.url
        }
        var merged: AttSummary?
        for v in ["4", "5", nil] as [String?] {
            guard let u = page(v), let html = await fetchHTML(u, userid: uid, allowAutologin: false) else {
                if merged == nil { return nil }   // not signed in on the web: don't keep trying
                continue
            }
            let p = parseAttendance(html)
            if merged == nil { merged = p } else { merged?.mergeMax(from: p) }
            var t = merged!
            t.fillMax()
            if let pct = t.maxPercentValue { return pct }
        }
        return nil
    }
}

@MainActor
enum AttendanceSync {
    private static var running = false
    private static var lastRun = Date.distantPast

    /// "Digital Embedded Systems (INFO 3411) Sec 1" -> "Digital Embedded Systems"
    private static func cleanName(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,"))
        return t.isEmpty ? s : t
    }

    /// Refreshes the widget data. Skips if it ran in the last 10 minutes unless `force`.
    static func refresh(userid: Int, force: Bool = false) async {
        guard userid > 0, !running else { return }
        if !force && Date().timeIntervalSince(lastRun) < 600 { return }
        running = true
        defer { running = false }

        let api = MoodleAPI.shared

        // Subjects being taken now (falls back to every enrolled course if the site has no course dates)
        func fetchCourses(_ cls: String) async throws -> [Course] {
            let r: CourseList = try await api.call("core_course_get_enrolled_courses_by_timeline_classification",
                                                   ["classification": cls, "limit": 0, "offset": 0, "sort": "fullname"])
            return r.courses
        }
        var courses: [Course]
        do {
            courses = try await fetchCourses("inprogress")
            if courses.isEmpty { courses = try await fetchCourses("all") }
        } catch { return }   // offline / signed out: keep whatever the widget already has

        // Attendance activities of each course
        let found: [(Course, Module)] = await withTaskGroup(of: [(Course, Module)].self) { group in
            for c in courses {
                group.addTask {
                    let secs: [CourseSection]? = try? await api.call("core_course_get_contents", ["courseid": c.id])
                    return (secs ?? []).flatMap { $0.modules }
                        .filter { $0.modname == "attendance" && $0.uservisible != false }
                        .map { (c, $0) }
                }
            }
            var out: [(Course, Module)] = []
            for await r in group { out += r }
            return out
        }

        // Pass 1 (parallel): token only
        var percent: [Int: Double] = [:]
        await withTaskGroup(of: (Int, Double?).self) { group in
            for (c, m) in found {
                group.addTask { (m.id, await api.tokenMaxPercent(m, courseId: c.id, uid: userid)) }
            }
            for await (id, p) in group { if let p { percent[id] = p } }
        }
        // Pass 2 (one at a time): website page using the existing web session only (never requests a key)
        for (_, m) in found where percent[m.id] == nil {
            if let p = await api.webMaxPercent(m, uid: userid) { percent[m.id] = p }
        }

        // Keep the last known value for anything that couldn't be read this time
        let old = Dictionary((AttendanceStore.load()?.items ?? []).map { ($0.id, $0.percent) },
                            uniquingKeysWith: { a, _ in a })
        let perCourse = Dictionary(grouping: found, by: { $0.0.id }).mapValues { $0.count }

        var items: [AttendanceItem] = []
        for (c, m) in found {
            guard let p = percent[m.id] ?? old[m.id] else { continue }   // subject with attendance but no readable data: left out
            var name = cleanName(c.fullname.decodedEntities)
            if (perCourse[c.id] ?? 1) > 1 { name += " · " + m.name }
            items.append(AttendanceItem(id: m.id, name: name, percent: p))
        }
        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        AttendanceStore.save(AttendanceSnapshot(items: items, updated: Date()))
        lastRun = Date()
    }
}

import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Debug log (only shown on the attendance page when loading fails)

actor DebugLog {
    static let shared = DebugLog()
    private var lines: [String] = []
    func add(_ s: String) { lines.append(s) }
    func reset() { lines = [] }
    func text() -> String { lines.joined(separator: "\n") }
}

// MARK: - Attendance model

enum AttKind: String, CaseIterable, Identifiable {
    case present = "Present"
    case late = "Late"
    case excused = "Excused"
    case absent = "Absent"
    case pending = "Not taken"
    case other = "Other"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .present: return Tone.green
        case .late: return Tone.amber
        case .excused: return Tone.blue
        case .absent: return Tone.red
        case .pending, .other: return Theme.muted
        }
    }

    static func from(_ status: String) -> AttKind {
        let t = status.lowercased().trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "?" || t.contains("not taken") || t.contains("unknown") { return .pending }
        if t.contains("absent") || t == "a" { return .absent }
        if t.contains("excus") || t == "e" { return .excused }
        if t.contains("late") || t == "l" { return .late }
        if t.contains("present") || t == "p" { return .present }
        return .other
    }
}

struct AttRecord: Identifiable {
    let id = UUID()
    var date: String
    var time: String
    var desc: String
    var status: String
    var points: String
    var remarks: String
    var kind: AttKind
}

struct AttSummary {
    var rows: [(String, String)] = []
    var points: String?
    var records: [AttRecord] = []

    // Maximum possible attendance (what you'd finish on if you attend every remaining session)
    var maxPercent: String?      // "96.7%"
    var maxPoints: String?       // "58 / 60"
    var total: Int?              // total number of sessions in the course
    var taken: Int?              // sessions already taken
    var earned: Double?          // points over taken sessions (numerator)
    var possible: Double?        // points over taken sessions (denominator)
    var sample = ""              // text around the summary on the page, shown under "Details" when something is missing

    func count(_ k: AttKind) -> Int { records.filter { $0.kind == k }.count }

    private func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    // Takes the totals (not the session rows) from another copy of the page
    mutating func mergeMax(from o: AttSummary) {
        if maxPercent == nil { maxPercent = o.maxPercent; maxPoints = o.maxPoints }
        if sample.isEmpty { sample = o.sample }
        total = total ?? o.total
        taken = taken ?? o.taken
        earned = earned ?? o.earned
        possible = possible ?? o.possible
    }

    // If the page doesn't state the maximum, work it out:
    // max = points earned + remaining sessions x points per session
    mutating func fillMax() {
        if earned == nil || possible == nil {
            var e = 0.0, p = 0.0, n = 0
            for r in records where r.kind != .pending {
                let parts = r.points.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, let a = parts[0], let b = parts[1] { e += a; p += b; n += 1 }
            }
            if n > 0 { earned = e; possible = p; taken = taken ?? n }
        }
        guard maxPercent == nil, let total, let taken, taken > 0, total >= taken,
              let e = earned, let p = possible, p > 0 else { return }
        let per = p / Double(taken)
        let maxPts = e + Double(total - taken) * per
        let allPts = Double(total) * per
        maxPoints = "\(num(maxPts)) / \(num(allPts))"
        maxPercent = String(format: "%.1f%%", maxPts / allPts * 100)
    }

    // The attendance level the student must not fall below
    static let limitPercent = 80.0

    /// How many of the remaining sessions can still be missed while the final result stays at or above
    /// the limit, worked out from the maximum possible percentage (every session counts the same).
    /// Negative = even perfect attendance from now on can't reach the limit. nil = not enough data.
    func absencesLeft(limit: Double = AttSummary.limitPercent) -> Int? {
        guard let total, total > 0 else { return nil }
        var ratio: Double?
        if let mp = maxPoints {
            let parts = mp.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let a = parts[0], let b = parts[1], b > 0 { ratio = a / b }
        }
        if ratio == nil, let mpct = maxPercent,
           let v = Double(mpct.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
            ratio = v / 100
        }
        guard let r = ratio else { return nil }
        let slack = (r - limit / 100) * Double(total)      // sessions' worth of points above the limit
        if slack < -1e-6 { return -1 }
        var k = Int((slack + 1e-6).rounded(.down))
        if let taken, total >= taken { k = min(k, total - taken) }
        return k
    }
}

// MARK: - API helpers

extension MoodleAPI {

    // ---- Course actions (star / remove from view) ----

    func setFavourite(_ courseId: Int, _ favourite: Bool) async throws {
        _ = try await raw("core_course_set_favourite_courses",
                          ["courses": [["id": courseId, "favourite": favourite ? 1 : 0]]])
    }

    // "Removed from view" is stored by Moodle as a user preference, the same one the website uses.
    // core_user_update_user_preferences wants each preference as {type, value} (not {name, value}); sending
    // "name" is what produced "Invalid parameter value detected". If a site rejects that form,
    // core_user_set_user_preferences ({name, value, userid}) is tried as a fallback.
    func setHidden(_ courseId: Int, _ hidden: Bool, userid: Int) async throws {
        let key = "block_myoverview_hidden_course_\(courseId)"
        if hidden {
            do {
                _ = try await raw("core_user_update_user_preferences",
                                  ["userid": userid, "preferences": [["type": key, "value": "1"]]])
            } catch let e as APIError where e.code == "invalidparameter" {
                _ = try await raw("core_user_set_user_preferences",
                                  ["preferences": [["name": key, "value": "1", "userid": userid]]])
            }
            return
        }
        // Un-hiding = deleting the preference. Sites differ in how they accept that, so each form is tried in turn.
        let attempts: [(String, () async throws -> Void)] = [
            ("update/no-value", { _ = try await self.raw("core_user_update_user_preferences",
                ["userid": userid, "preferences": [["type": key]]]) }),
            ("update/empty", { _ = try await self.raw("core_user_update_user_preferences",
                ["userid": userid, "emptypreferences": [key]]) }),
            ("set/no-value", { _ = try await self.raw("core_user_set_user_preferences",
                ["preferences": [["name": key, "userid": userid]]]) }),
        ]
        var failures: [String] = []
        for (label, call) in attempts {
            do { try await call(); return }
            catch { failures.append("\(label): \(error.localizedDescription)") }
        }
        throw APIError(message: "Couldn't show this course again. " + failures.joined(separator: " | "))
    }

    // The official Moodle app builds its attendance screen from this web-service call, which already includes the
    // totals (total sessions, maximum possible points / percentage).
    func attendanceMobileContent(cmid: Int, courseId: Int, userid: Int) async -> String? {
        var args: [[String: Any]] = [["name": "cmid", "value": String(cmid)],
                                     ["name": "userid", "value": String(userid)]]
        if courseId > 0 { args.append(["name": "courseid", "value": String(courseId)]) }
        do {
            let data = try await raw("tool_mobile_get_content",
                                     ["component": "mod_attendance", "method": "mobile_course_view", "args": args])
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                await DebugLog.shared.add("mobile content: unreadable reply")
                return nil
            }
            var out = ""
            for t in (o["templates"] as? [[String: Any]]) ?? [] { out += (t["html"] as? String ?? "") + "\n" }
            out += (o["otherdata"] as? String ?? "")
            await DebugLog.shared.add("mobile content: \(out.count) chars")
            return out.isEmpty ? nil : out
        } catch {
            await DebugLog.shared.add("mobile content failed: \(error.localizedDescription)")
            return nil
        }
    }

    // ---- Attendance (read-only, parsed from the website page) ----
    // Sessions / percentage are not in the web-service API, so the attendance page is fetched and parsed.

    /// `allowAutologin: false` = only use the existing web session (cookies). Background work (the widget sync)
    /// must pass false so it never uses up Moodle's one-key-per-6-minutes auto-login allowance.
    func fetchHTML(_ url: URL, userid: Int, allowAutologin: Bool = true) async -> String? {
        func get(_ u: URL, _ tag: String) async -> String? {
            do {
                // MoodleAPI.session sends the MoodleMobile User-Agent and shares the cookie storage
                let (d, r) = try await MoodleAPI.session.data(from: u)
                let code = (r as? HTTPURLResponse)?.statusCode ?? -1
                await DebugLog.shared.add("\(tag): status \(code), final path \(r.url?.path ?? "nil"), \(d.count) bytes")
                if (r.url?.path ?? "").contains("/login/") {
                    await DebugLog.shared.add("\(tag): redirected to login")
                    return nil
                }
                return String(decoding: d, as: UTF8.self)
            } catch {
                await DebugLog.shared.add("\(tag): request error \(error)")
                return nil
            }
        }
        await DebugLog.shared.reset()
        await DebugLog.shared.add("fetching path \(url.path)")
        await syncCookies()   // pick up a session the web views already have
        if let h = await get(url, "direct") { return h }
        guard allowAutologin else {
            await DebugLog.shared.add("no web session, auto-login not allowed here")
            return nil
        }
        // Not forced: respects the 6-minute cooldown so we don't burn a request Moodle will reject
        let al = await autologin(url, userid: userid)
        await DebugLog.shared.add("autologin returned path \(al.path), same as input: \(al == url)")
        if al != url, let h = await get(al, "autologin") {
            await syncCookies()   // share the new session with the web views
            return h
        }
        return nil
    }

    // Moodle only gives out one auto-login key per 6 minutes, so a single login has to serve both the web views
    // (WKWebView cookies) and plain URLSession requests. This copies the session cookies in both directions.
    // Moodle's session cookie is a session-only cookie (dies when the app is killed), so it is given a real
    // expiry here so the web session survives relaunches.
    @MainActor
    func syncCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        func persistent(_ c: HTTPCookie) -> HTTPCookie {
            guard c.name.hasPrefix("MoodleSession"), c.expiresDate == nil else { return c }
            var p = c.properties ?? [:]
            p.removeValue(forKey: .discard)
            p[.expires] = Date().addingTimeInterval(7 * 24 * 3600)
            return HTTPCookie(properties: p) ?? c
        }
        for c in await store.allCookies() { HTTPCookieStorage.shared.setCookie(persistent(c)) }
        for c in HTTPCookieStorage.shared.cookies(for: Site.url) ?? [] { await store.setCookie(c) }
    }

    func parseAttendance(_ html: String) -> AttSummary {
        func groups(_ pattern: String, _ s: String,
                    _ opts: NSRegularExpression.Options = [.caseInsensitive]) -> [[String]] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
                (1..<m.numberOfRanges).map { i in
                    m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
                }
            }
        }
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .decodedEntities
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        func hasYear(_ s: String) -> Bool {
            s.range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression) != nil
        }
        // "Mon 5Oct 2026 9AM - 11AM" -> ("Mon 5Oct 2026", "9AM - 11AM")
        func splitDate(_ s: String) -> (String, String) {
            if let r = s.range(of: "\\d{1,2}(:\\d{2})?\\s*[AaPp][Mm]|\\d{1,2}:\\d{2}", options: .regularExpression) {
                let d = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let t = s[r.lowerBound...].trimmingCharacters(in: .whitespaces)
                return d.isEmpty ? (s, "") : (d, t)
            }
            return (s, "")
        }

        let cleaned = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>|<style[\\s\\S]*?</style>",
                                                with: " ", options: [.regularExpression, .caseInsensitive])
        let text = strip(cleaned)
        var sum = AttSummary()
        if let r = text.range(of: "sessions", options: .caseInsensitive) {
            let a = text.index(r.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let b = text.index(r.lowerBound, offsetBy: 420, limitedBy: text.endIndex) ?? text.endIndex
            sum.sample = String(text[a..<b])
        }

        for g in groups("(?<![Pp]ossible\\s)(Percentage[^%\\d]{0,60}?)([\\d.]+)\\s*%", text).prefix(3) {
            let label = g[0].trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            sum.rows.append((label, g[1] + "%"))
        }
        if let g = groups("Points[^\\d]{0,60}?([\\d.]+)\\s*/\\s*([\\d.]+)", text).first {
            sum.points = "\(g[0]) / \(g[1]) points"
        }
        if let g = groups("Taken sessions[\\s:]*(\\d+)", text).first { sum.taken = Int(g[0]) }
        if let g = groups("Total number of sessions[\\s:]*(\\d+)", text).first { sum.total = Int(g[0]) }
        if let g = groups("Points over taken sessions[\\s:]*([\\d.]+)\\s*/\\s*([\\d.]+)", text).first {
            sum.earned = Double(g[0]); sum.possible = Double(g[1])
        }
        if let g = groups("Maximum possible points[\\s:]*([\\d.]+)\\s*/\\s*([\\d.]+)", text).first {
            sum.maxPoints = "\(g[0]) / \(g[1])"
        }
        if let g = groups("Maximum possible percentage[\\s:]*([\\d.]+)\\s*%", text).first {
            sum.maxPercent = g[0] + "%"
        }

        // Session table: columns are found from the header row (Date / Description / Status / Points / Remarks);
        // if there is no usable header the cells are recognised by their content instead.
        for table in groups("<table[^>]*>([\\s\\S]*?)</table>", cleaned) {
            var map: [String: Int] = [:]
            for tr in groups("<tr[^>]*>([\\s\\S]*?)</tr>", table[0]) {
                let rawCells = groups("<t([dh])[^>]*>([\\s\\S]*?)</t[dh]>", tr[0])
                let cells = rawCells.map { strip($0[1]) }
                guard !cells.isEmpty else { continue }

                if rawCells.allSatisfy({ $0[0].lowercased() == "h" }) {
                    map = [:]
                    for (i, c) in cells.enumerated() {
                        let l = c.lowercased()
                        if map["date"] == nil && (l.contains("date") || l == "time") { map["date"] = i }
                        else if l.contains("description") { map["desc"] = i }
                        else if l.contains("status") { map["status"] = i }
                        else if l.contains("point") { map["points"] = i }
                        else if l.contains("remark") { map["remarks"] = i }
                    }
                    continue
                }

                let di = map["date"] ?? cells.firstIndex(where: { hasYear($0) })
                guard cells.count >= 3, let dIdx = di, dIdx < cells.count, hasYear(cells[dIdx]) else { continue }

                func cell(_ k: String) -> String {
                    guard let i = map[k], i < cells.count else { return "" }
                    return cells[i]
                }
                var status = cell("status")
                if map["status"] == nil {
                    status = cells.first(where: { !hasYear($0) && !$0.isEmpty && AttKind.from($0) != .pending
                                                    && AttKind.from($0) != .other }) ?? ""
                    if status.isEmpty && cells.contains("?") { status = "?" }
                }
                var points = cell("points")
                if map["points"] == nil {
                    points = cells.first(where: {
                        $0.range(of: "^[\\d.]+\\s*/\\s*[\\d.]+$", options: .regularExpression) != nil }) ?? ""
                }
                let (d, t) = splitDate(cells[dIdx])
                sum.records.append(AttRecord(date: d, time: t, desc: cell("desc"), status: status,
                                             points: points, remarks: cell("remarks"),
                                             kind: AttKind.from(status)))
            }
        }

        // No percentage on the page: work one out from the sessions
        if sum.rows.isEmpty && !sum.records.isEmpty {
            let attended = sum.count(.present) + sum.count(.late) + sum.count(.excused)
            let taken = attended + sum.count(.absent)
            if taken > 0 {
                sum.rows.append(("Attended (calculated)", String(format: "%.1f%%", Double(attended) * 100 / Double(taken))))
            }
        }
        return sum
    }

    // ---- Assignment submission ----
    // 1) upload to a draft area (returns the draft itemid), 2) save_submission, 3) optionally submit_for_grading

    func uploadDraft(_ file: URL, itemid: Int) async throws -> Int {
        let boundary = "Boundary-" + UUID().uuidString
        var req = URLRequest(url: Site.url.appendingPathComponent("webservice/upload.php"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n"
                .data(using: .utf8)!)
        }
        field("token", token)
        field("filearea", "draft")
        field("itemid", String(itemid))
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_1\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            .data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, _) = try await URLSession.shared.upload(for: req, from: body)
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let arr = obj as? [[String: Any]], let id = arr.first?["itemid"] as? Int { return id }
        if let d = obj as? [String: Any], let e = d["error"] as? String { throw APIError(message: e) }
        throw APIError(message: "Upload failed for \(name)")
    }

    // Downloads a file that is already part of the submission so it can be re-uploaded into a new draft.
    func downloadToTemp(_ f: FileRef) async throws -> URL {
        guard let s = f.fileurl, let u = fileURL(s) else { throw APIError(message: "Bad file link") }
        let (d, _) = try await URLSession.shared.data(from: u)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(f.filename ?? "file")
        try d.write(to: dest)
        return dest
    }

    // A draft item id that has no files in it: saving it clears the submitted files.
    func emptyDraftId() -> Int { Int.random(in: 900_000_000...999_999_999) }

    private func throwIfWarnings(_ data: Data) throws {
        if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let m = arr.first?["message"] as? String {
            throw APIError(message: m.plainText)
        }
    }

    func saveSubmission(assignId: Int, text: String?, draftItemId: Int?) async throws {
        var pd: [String: Any] = [:]
        if let t = text {
            let editor: [String: Any] = ["text": t, "format": 1, "itemid": 0]
            pd["onlinetext_editor"] = editor
        }
        if let f = draftItemId { pd["files_filemanager"] = f }
        let data = try await raw("mod_assign_save_submission", ["assignmentid": assignId, "plugindata": pd])
        try throwIfWarnings(data)
    }

    func submitForGrading(assignId: Int) async throws {
        let data = try await raw("mod_assign_submit_for_grading",
                                 ["assignmentid": assignId, "acceptsubmissionstatement": 1])
        try throwIfWarnings(data)
    }

    // Removes the student's own submission. Uses Moodle's remove-submission function; if the site does not
    // expose it to the mobile service, falls back to saving an empty submission (blank text, empty file area).
    func removeSubmission(assignId: Int, userid: Int, hasText: Bool, hasFiles: Bool) async throws {
        do {
            let data: Data
            do {
                data = try await raw("mod_assign_remove_submission", ["userid": userid, "assignid": assignId])
            } catch let e as APIError where e.code == "invalidparameter" {
                data = try await raw("mod_assign_remove_submission", ["userid": userid, "assignmentid": assignId])
            }
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (o["status"] as? Bool) == false || (o["status"] as? Int) == 0 {
                let m = ((o["warnings"] as? [[String: Any]])?.first?["message"] as? String)
                    ?? "Couldn't remove the submission"
                throw APIError(message: m.plainText, code: "removefailed")
            }
        } catch let e as APIError where e.code != "removefailed" {
            try await saveSubmission(assignId: assignId,
                                     text: hasText ? "" : nil,
                                     draftItemId: hasFiles ? emptyDraftId() : nil)
        }
    }
}

// MARK: - Attendance screen (read-only)

struct AttendanceView: View {
    let module: Module
    var courseId = 0
    @EnvironmentObject var app: AppState
    @State private var summary: AttSummary?
    @State private var note: String? = "Loading attendance..."
    @State private var loading = true
    @State private var debugText = ""
    @State private var kindFilter: AttKind? = nil
    @State private var reversed = false

    private var uid: Int { app.site?.userid ?? 0 }

    private var shown: [AttRecord] {
        let r = (summary?.records ?? []).filter { kindFilter == nil || $0.kind == kindFilter }
        return reversed ? r.reversed() : r
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                maxCard
                summaryCard
                if let s = summary, !s.records.isEmpty {
                    filterBar(s)
                    sessionsCard
                }
                if loading {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                }
                if !debugText.isEmpty {
                    DisclosureGroup("Details") {
                        Text(debugText)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Theme.muted)
                            .textSelection(.enabled)
                    }
                    .foregroundColor(Theme.muted)
                }
                NavigationLink {
                    WebActivityView(url: URL(string: module.url ?? "") ?? Site.url, title: module.name)
                } label: {
                    Text("Open full report on website").font(.subheadline).foregroundColor(Theme.accent)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadSummary() }
        .task { await loadSummary() }
    }

    // ---- maximum possible (top of the screen) ----

    @ViewBuilder private var maxCard: some View {
        if let s = summary, let pct = s.maxPercent {
            VStack(alignment: .leading, spacing: 12) {
                Text("MAXIMUM POSSIBLE ATTENDANCE").font(.caption).foregroundColor(Theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pct).font(Font.largeTitle.bold()).foregroundColor(Theme.accent)
                    Text("if you attend every remaining session").font(.subheadline).foregroundColor(Theme.txt)
                }
                if let p = Double(pct.replacingOccurrences(of: "%", with: "")) {
                    ProgressView(value: min(max(p, 0), 100), total: 100).tint(Theme.accent)
                }
                HStack(spacing: 14) {
                    if let pts = s.maxPoints { Text("\(pts) points").font(.caption).foregroundColor(Theme.muted) }
                    if let t = s.total, let k = s.taken {
                        Text("\(k) of \(t) sessions taken").font(.caption).foregroundColor(Theme.muted)
                    }
                }
                if let k = s.absencesLeft() { absenceRow(k, s) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glowCard()
        }
    }

    // How many absences are left before the final attendance would fall below 80%
    private func absenceRow(_ k: Int, _ s: AttSummary) -> some View {
        let limit = Int(AttSummary.limitPercent)
        let color: Color = k < 0 ? Tone.red : (k == 0 ? Tone.amber : Tone.green)
        let remaining: Int? = (s.total != nil && s.taken != nil) ? max(0, s.total! - s.taken!) : nil
        let title: String
        let detail: String
        if k < 0 {
            title = "Below \(limit)% even with full attendance"
            detail = "The most you can reach is \(s.maxPercent ?? "-")."
        } else if k == 0 {
            title = "No absences to spare"
            detail = "Your next absence takes you below \(limit)%."
        } else {
            title = "\(k) absence\(k == 1 ? "" : "s") available"
            detail = "Miss more than that and you drop below \(limit)%"
                + (remaining.map { " (\($0) sessions left)." } ?? ".")
        }
        return HStack(spacing: 12) {
            Text(k < 0 ? "!" : "\(k)")
                .font(.title.bold()).foregroundColor(color).frame(minWidth: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(Theme.txt)
                Text(detail).font(.caption).foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // ---- summary ----

    @ViewBuilder private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ATTENDANCE").font(.caption).foregroundColor(Theme.muted)
            if let s = summary {
                ForEach(Array(s.rows.enumerated()), id: \.offset) { i, r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(r.1).font(i == 0 ? Font.largeTitle.bold() : Font.title3.bold()).foregroundColor(Theme.accent)
                            Text(r.0).foregroundColor(Theme.txt)
                        }
                        if i == 0, let p = Double(r.1.replacingOccurrences(of: "%", with: "")) {
                            ProgressView(value: min(max(p, 0), 100), total: 100).tint(Theme.accent)
                        }
                    }
                }
                if let p = s.points { Text(p).font(.caption).foregroundColor(Theme.muted) }
                if !s.records.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(AttKind.allCases) { k in
                            let n = s.count(k)
                            if n > 0 { StatusPill(text: "\(k.rawValue) \(n)", color: k.color) }
                        }
                    }
                }
            } else if let n = note {
                Text(n).font(.subheadline).foregroundColor(Theme.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
    }

    // ---- sessions ----

    private func filterBar(_ s: AttSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                Button { kindFilter = nil } label: {
                    Text("All \(s.records.count)")
                        .fontWeight(kindFilter == nil ? .semibold : .regular)
                        .foregroundColor(kindFilter == nil ? Theme.accent : Theme.txt)
                }
                ForEach(AttKind.allCases) { k in
                    let n = s.count(k)
                    if n > 0 {
                        Button { kindFilter = k } label: {
                            Text("\(k.rawValue) \(n)")
                                .fontWeight(kindFilter == k ? .semibold : .regular)
                                .foregroundColor(kindFilter == k ? Theme.accent : Theme.txt)
                        }
                    }
                }
                Button { reversed.toggle() } label: {
                    Image(systemName: "arrow.up.arrow.down").foregroundColor(Theme.muted)
                }
            }
        }
    }

    private var sessionsCard: some View {
        VStack(spacing: 0) {
            ForEach(shown) { r in recordRow(r) }
            if shown.isEmpty {
                Text("No sessions with this status.").foregroundColor(Theme.muted).padding(14)
            }
        }
        .glowCard()
    }

    private func recordRow(_ r: AttRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.date).fontWeight(.medium).foregroundColor(Theme.txt)
                if !r.time.isEmpty { Text(r.time).font(.caption).foregroundColor(Theme.accent) }
                if !r.desc.isEmpty { Text(r.desc).font(.caption).foregroundColor(Theme.muted) }
                if !r.remarks.isEmpty {
                    Text(r.remarks).font(.caption).italic().foregroundColor(Theme.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(text: r.status.isEmpty || r.status == "?" ? AttKind.pending.rawValue : r.status,
                           color: r.kind.color)
                if !r.points.isEmpty {
                    Text(r.points).font(.caption).foregroundColor(Theme.muted)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    private func loadSummary() async {
        defer { loading = false }
        guard var c = URLComponents(string: module.url ?? "") else { note = nil; return }
        var q = c.queryItems ?? []
        q.removeAll { $0.name == "view" }
        q.append(URLQueryItem(name: "view", value: "4"))   // 4 = all sessions
        c.queryItems = q
        guard let u = c.url, let html = await MoodleAPI.shared.fetchHTML(u, userid: uid) else {
            let wait = MoodleAPI.shared.autologinWait
            note = "Couldn't load your attendance." + (wait > 0
                ? " Auto sign-in is on cooldown (about \(Int(wait / 60) + 1) min). Pull down to refresh after that."
                : " Open any page in the Website tab to sign in, then pull down here to refresh.")
            debugText = await DebugLog.shared.text()
            return
        }
        var s = MoodleAPI.shared.parseAttendance(html)
        if s.rows.isEmpty && s.records.isEmpty {
            note = "No attendance data found on the page."
            debugText = await DebugLog.shared.text()
        } else {
            // The "all sessions" view may not carry the totals; the course's normal attendance page does.
            if s.maxPercent == nil || s.total == nil {
                if let h = await MoodleAPI.shared.attendanceMobileContent(cmid: module.id, courseId: courseId, userid: uid) {
                    s.mergeMax(from: MoodleAPI.shared.parseAttendance(h))
                }
            }
            if s.maxPercent == nil || s.total == nil {
                for v in ["5", ""] {   // 5 = all sessions (incl. future); "" = the page's default view
                    guard var c2 = URLComponents(string: module.url ?? "") else { break }
                    var q2 = c2.queryItems ?? []
                    q2.removeAll { $0.name == "view" }
                    if !v.isEmpty { q2.append(URLQueryItem(name: "view", value: v)) }
                    c2.queryItems = q2
                    if let u2 = c2.url, let h2 = await MoodleAPI.shared.fetchHTML(u2, userid: uid) {
                        s.mergeMax(from: MoodleAPI.shared.parseAttendance(h2))
                    }
                    if s.maxPercent != nil || s.total != nil { break }
                }
            }
            s.fillMax()
            summary = s
            debugText = s.maxPercent == nil
                ? "Max possible not found. total=\(s.total.map(String.init) ?? "nil") taken=\(s.taken.map(String.init) ?? "nil") earned=\(s.earned.map { String($0) } ?? "nil") possible=\(s.possible.map { String($0) } ?? "nil")\n" + (await DebugLog.shared.text()) + "\nPage text: " + s.sample
                : ""
        }
    }
}

// MARK: - Assignment screen with built-in submission (submit, edit, remove)

struct AssignmentView: View {
    let courseId: Int
    let module: Module
    @EnvironmentObject var app: AppState
    @State private var assign: Assign?
    @State private var status: StatusResp?
    @State private var loading = true
    @State private var error: String?
    @State private var message: String?
    @State private var text = ""
    @State private var textLoaded = false
    @State private var picked: [URL] = []
    @State private var removedFiles: Set<String> = []
    @State private var showPicker = false
    @State private var confirmRemove = false
    @State private var busy = false
    @State private var introFiles: [IntroFile] = []      // files the lecturer attached to the assignment
    @State private var showShare = false

    private var uid: Int { app.site?.userid ?? 0 }

    private var existingFiles: [FileRef] {
        var out: [FileRef] = []
        let plugins = status?.lastattempt?.submission?.plugins ?? []
        for p in plugins where p.type == "file" {
            for area in p.fileareas ?? [] {
                out.append(contentsOf: area.files ?? [])
            }
        }
        return out
    }

    private var subStatus: String { status?.lastattempt?.submission?.status ?? "" }
    private var canEdit: Bool { status?.lastattempt?.canedit?.value ?? true }
    private var hasSubmission: Bool { ["draft", "submitted", "reopened"].contains(subStatus) }

    private func savedText(_ s: StatusResp?) -> String? {
        let plugins = s?.lastattempt?.submission?.plugins ?? []
        for p in plugins where p.type == "onlinetext" {
            if let t = p.editorfields?.first?.text { return t }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                if let a = assign {
                    infoCard(a)
                    if let intro = a.intro?.linkedText, !intro.characters.isEmpty {
                        Text(intro).foregroundColor(Theme.txt).tint(Theme.accent)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .glowCard()
                    }
                    if !introFiles.isEmpty { attachmentsCard }
                    submissionCard(a)
                }
                NavigationLink {
                    WebActivityView(url: URL(string: module.url ?? "") ?? Site.url, title: module.name)
                } label: {
                    Text("Open on website").font(.subheadline).foregroundColor(Theme.accent)
                }
                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(module.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .sheet(isPresented: $showShare) { SharePickerSheet(files: introFiles) }
    }

    // ---- lecturer's attached files (same as the "attachments" shown on the Moodle website) ----

    private var attachmentsCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("ATTACHMENTS").font(.caption).foregroundColor(Theme.muted)
                ForEach(introFiles) { f in
                    if let s = f.fileurl, let u = MoodleAPI.shared.fileURL(s) {
                        NavigationLink { FileViewer(url: u, title: f.filename ?? "File") } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc").foregroundColor(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.filename ?? "File").foregroundColor(Theme.accent).lineLimit(2)
                                    if let t = f.timemodified {
                                        Text(fmt(t)).font(.caption).foregroundColor(Theme.muted)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button { showShare = true } label: { ShareButtonLabel() }
                .buttonStyle(.plain)
                .accessibilityLabel("Share files")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
    }

    private func loadIntroFiles() async {
        let r: IntroResp? = try? await MoodleAPI.shared.call(
            "mod_assign_get_assignments", ["courseids": [courseId]])
        introFiles = r?.courses.first?.assignments.first { $0.cmid == module.id }?.introattachments ?? []
    }

    // ---- info card ----

    private func infoCard(_ a: Assign) -> some View {
        let grading = (status?.lastattempt?.gradingstatus ?? "-")
            .replacingOccurrences(of: "notgraded", with: "Not graded").capitalized
        let submission = (subStatus.isEmpty ? "-" : subStatus).capitalized
        let grade = status?.feedback?.gradefordisplay ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            infoRow("Due", fmt(a.duedate))
            infoRow("Submission status", submission)
            infoRow("Grading status", grading)
            if !grade.isEmpty { infoRow("Grade", grade.plainText) }
        }
        .glowCard()
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(Theme.muted).frame(width: 130, alignment: .leading)
            Text(v).foregroundColor(Theme.txt)
            Spacer()
        }
        .padding(14)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    // ---- submission UI ----

    @ViewBuilder private func submissionCard(_ a: Assign) -> some View {
        let fileOn = a.enabled("file")
        let textOn = a.enabled("onlinetext")
        VStack(alignment: .leading, spacing: 12) {
            Text("SUBMISSION").font(.caption).foregroundColor(Theme.muted)
            if !(fileOn || textOn) {
                Text("This assignment doesn't accept online submissions.").foregroundColor(Theme.muted)
            } else if !canEdit {
                Text("Submission is locked.").foregroundColor(Theme.muted)
                ForEach(existingFiles) { f in fileLink(f) }
            } else {
                if fileOn { fileSection }
                if textOn { textSection }
                if let message { Text(message).font(.footnote).foregroundColor(Theme.accent) }
                actionButtons(a)
                if hasSubmission { removeButton }
                if busy { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
        .confirmationDialog("Remove your submission?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove submission", role: .destructive) { Task { await removeSubmission(a) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your submitted files and text will be deleted. You can submit again while the assignment is still open.")
        }
    }

    @ViewBuilder private var fileSection: some View {
        ForEach(existingFiles) { f in editableFileRow(f) }
        ForEach(picked, id: \.self) { u in
            HStack {
                Image(systemName: "doc.badge.plus").foregroundColor(Theme.accent)
                Text(u.lastPathComponent).foregroundColor(Theme.txt).lineLimit(1)
                Spacer()
                Button { picked.removeAll { $0 == u } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.muted)
                }
            }
        }
        Button { showPicker = true } label: {
            Label("Add file", systemImage: "paperclip").foregroundColor(Theme.accent)
        }
        if !removedFiles.isEmpty {
            Text("\(removedFiles.count) file(s) will be removed when you save.")
                .font(.caption).foregroundColor(Theme.muted)
        }
    }

    private var textSection: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .foregroundColor(Theme.txt)
            .frame(minHeight: 140)
            .padding(8)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func actionButtons(_ a: Assign) -> some View {
        let usesDrafts = a.submissiondrafts == 1
        let canSubmitDraft = subStatus == "draft" || status?.lastattempt?.cansubmit?.value == true
        let saveLabel = hasSubmission ? (usesDrafts ? "Save changes" : "Update submission")
                                      : (usesDrafts ? "Save draft" : "Submit")
        HStack(spacing: 12) {
            Button { Task { await save(a, submit: false) } } label: {
                Text(saveLabel)
                    .fontWeight(.semibold).foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if usesDrafts && canSubmitDraft {
                Button { Task { await save(a, submit: true) } } label: {
                    Text("Submit for grading")
                        .fontWeight(.semibold).foregroundColor(Theme.txt)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .disabled(busy)
    }

    private var removeButton: some View {
        Button(role: .destructive) { confirmRemove = true } label: {
            Label("Remove submission", systemImage: "trash")
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.surface2)
                .foregroundColor(.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(busy)
    }

    // Read-only file row (locked submissions)
    @ViewBuilder private func fileLink(_ f: FileRef) -> some View {
        if let s = f.fileurl, let u = MoodleAPI.shared.fileURL(s) {
            NavigationLink { FileViewer(url: u, title: f.filename ?? "File") } label: {
                HStack {
                    Image(systemName: "doc").foregroundColor(Theme.accent)
                    Text(f.filename ?? "File").foregroundColor(Theme.txt).lineLimit(1)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    // File row with a remove / undo button (editable submissions)
    @ViewBuilder private func editableFileRow(_ f: FileRef) -> some View {
        let removed = removedFiles.contains(f.id)
        HStack(spacing: 12) {
            if let s = f.fileurl, let u = MoodleAPI.shared.fileURL(s), !removed {
                NavigationLink { FileViewer(url: u, title: f.filename ?? "File") } label: {
                    HStack {
                        Image(systemName: "doc").foregroundColor(Theme.accent)
                        Text(f.filename ?? "File").foregroundColor(Theme.txt).lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Image(systemName: "doc").foregroundColor(Theme.muted)
                    Text(f.filename ?? "File").strikethrough().foregroundColor(Theme.muted).lineLimit(1)
                    Spacer()
                }
            }
            Button {
                if removed { removedFiles.remove(f.id) } else { removedFiles.insert(f.id) }
            } label: {
                Image(systemName: removed ? "arrow.uturn.backward.circle" : "trash")
                    .foregroundColor(removed ? Theme.accent : Color.red.opacity(0.85))
            }
        }
    }

    // ---- actions ----

    private func addFiles(_ urls: [URL]) {
        let tmp = FileManager.default.temporaryDirectory
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = tmp.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: u, to: dest)
                picked.append(dest)
            } catch {
                message = "Couldn't read \(u.lastPathComponent)"
            }
        }
    }

    private func save(_ a: Assign, submit: Bool) async {
        busy = true; message = nil
        do {
            var item: Int? = nil
            let keep = existingFiles.filter { !removedFiles.contains($0.id) }
            if a.enabled("file") && (!picked.isEmpty || !removedFiles.isEmpty) {
                // Saving files replaces the whole file area, so rebuild it: files being kept + new files.
                var toUpload: [URL] = []
                for f in keep { toUpload.append(try await MoodleAPI.shared.downloadToTemp(f)) }
                toUpload.append(contentsOf: picked)
                for f in toUpload {
                    item = try await MoodleAPI.shared.uploadDraft(f, itemid: item ?? 0)
                }
                if toUpload.isEmpty { item = MoodleAPI.shared.emptyDraftId() }   // everything removed
            }
            let body: String? = a.enabled("onlinetext") ? text : nil
            try await MoodleAPI.shared.saveSubmission(assignId: a.id, text: body, draftItemId: item)
            if submit { try await MoodleAPI.shared.submitForGrading(assignId: a.id) }
            picked = []
            removedFiles = []
            if submit {
                message = "Submitted for grading."
            } else if hasSubmission {
                message = "Changes saved."
            } else {
                message = a.submissiondrafts == 1 ? "Draft saved." : "Submitted."
            }
            await loadStatus(a)
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }

    private func removeSubmission(_ a: Assign) async {
        busy = true; message = nil
        do {
            try await MoodleAPI.shared.removeSubmission(assignId: a.id, userid: uid,
                                                        hasText: a.enabled("onlinetext"),
                                                        hasFiles: a.enabled("file"))
            picked = []
            removedFiles = []
            text = ""
            textLoaded = false
            message = "Submission removed."
            await loadStatus(a)
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }

    private func loadStatus(_ a: Assign) async {
        let s: StatusResp? = try? await MoodleAPI.shared.call(
            "mod_assign_get_submission_status",
            ["assignid": a.id, "userid": uid])
        status = s
        if !textLoaded {
            if let t = savedText(s) { text = t.plainText }
            textLoaded = true
        }
    }

    private func load() async {
        do {
            let r: AssignResp = try await MoodleAPI.shared.call(
                "mod_assign_get_assignments", ["courseids": [courseId]])
            assign = r.courses.first?.assignments.first { $0.cmid == module.id }
            if let a = assign { await loadStatus(a) }
            await loadIntroFiles()
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}


// MARK: - Lecturer attachments + share

// Only the bits of mod_assign_get_assignments needed for the lecturer's attached files
// (decoded separately so the existing Assign model stays untouched).
struct IntroFile: Decodable, Identifiable {
    let filename: String?
    let fileurl: String?
    let filesize: Int?
    let timemodified: Int?
    var id: String { fileurl ?? filename ?? "file" }
}
struct IntroResp: Decodable {
    struct Course: Decodable {
        struct A: Decodable {
            let cmid: Int
            let introattachments: [IntroFile]?
        }
        let assignments: [A]
    }
    let courses: [Course]
}

// Share icon in a themed tile (48pt = easy to tap).
struct ShareButtonLabel: View {
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface2)
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1)
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundColor(Theme.accent)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
}

enum Sharer {
    /// Opens the iOS share sheet with the given files (Gemini and other apps appear in it).
    @MainActor static func present(_ urls: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                                              width: 0, height: 0)
        top.present(vc, animated: true)
    }
}

struct SharePickerSheet: View {
    let files: [IntroFile]
    @State private var selected: Set<String>
    @State private var busy = false
    @State private var error: String?

    init(files: [IntroFile]) {
        self.files = files
        _selected = State(initialValue: Set(files.map { $0.id }))
    }

    private var allSelected: Bool { selected.count == files.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ShareButtonLabel(size: 40)
                Text("Share").font(.title3.bold()).foregroundColor(Theme.txt)
                Spacer()
            }
            Button {
                selected = allSelected ? [] : Set(files.map { $0.id })
            } label: {
                HStack {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(allSelected ? Theme.accent : Theme.muted)
                    Text("Select all").foregroundColor(Theme.txt)
                    Spacer()
                    Text("\(selected.count) of \(files.count)").font(.caption).foregroundColor(Theme.muted)
                }
                .padding(14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glowCard()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(files) { f in
                        Button {
                            if selected.contains(f.id) { selected.remove(f.id) } else { selected.insert(f.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(f.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(f.id) ? Theme.accent : Theme.muted)
                                Text(f.filename ?? "File").foregroundColor(Theme.txt).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(14).contentShape(Rectangle())
                            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glowCard()
            }

            if let error { Text(error).font(.footnote).foregroundColor(.red.opacity(0.85)) }

            Button { Task { await send() } } label: {
                HStack {
                    if busy { ProgressView().tint(.black) }
                    Text(busy ? "Preparing..." : (selected.count == 1 ? "Share file" : "Share files"))
                        .fontWeight(.semibold)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Theme.accent.opacity(selected.isEmpty ? 0.35 : 1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(selected.isEmpty || busy)
        }
        .padding(16)
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func send() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            var urls: [URL] = []
            for f in files where selected.contains(f.id) {
                guard let s = f.fileurl, let u = MoodleAPI.shared.fileURL(s) else { continue }
                let (d, _) = try await URLSession.shared.data(from: u)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(f.filename ?? "file")
                try d.write(to: dest)
                urls.append(dest)
            }
            guard !urls.isEmpty else { error = "Couldn't download the selected files."; return }
            Sharer.present(urls)
        } catch {
            self.error = error.localizedDescription
        }
    }
}


// MARK: - HTML -> text with tappable links (assignment description)

extension String {
    /// Turns Moodle HTML into display text where <a href> links and bare URLs are tappable.
    var linkedText: AttributedString {
        func clean(_ h: String) -> String {
            h.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .decodedEntities
        }
        func resolve(_ href: String) -> URL? {
            let h = href.decodedEntities.trimmingCharacters(in: .whitespacesAndNewlines)
            if h.isEmpty || h.hasPrefix("#") || h.lowercased().hasPrefix("javascript") { return nil }
            var abs = h
            if !h.lowercased().hasPrefix("http") && !h.lowercased().hasPrefix("mailto:") && !h.lowercased().hasPrefix("tel:") {
                abs = Site.url.absoluteString + (h.hasPrefix("/") ? h : "/" + h)
            }
            if abs.contains("pluginfile.php") { return MoodleAPI.shared.fileURL(abs) }   // files need the token
            return URL(string: abs) ?? abs.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                .flatMap { URL(string: $0) }
        }

        var pieces: [(String, URL?)] = []
        let ns = self as NSString
        var last = 0
        if let re = try? NSRegularExpression(pattern: "<a\\b[^>]*?href\\s*=\\s*([\"'])(.*?)\\1[^>]*>([\\s\\S]*?)</a>",
                                             options: [.caseInsensitive]) {
            for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
                pieces.append((clean(ns.substring(with: NSRange(location: last, length: m.range.location - last))), nil))
                let label = clean(ns.substring(with: m.range(at: 3))).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = resolve(ns.substring(with: m.range(at: 2)))
                pieces.append((label.isEmpty ? ns.substring(with: m.range(at: 2)) : label, url))
                last = m.range.location + m.range.length
            }
        }
        pieces.append((clean(ns.substring(from: last)), nil))

        // trim the very start / end
        if let f = pieces.first, f.1 == nil {
            pieces[0].0 = String(f.0.drop(while: { $0.isWhitespace || $0.isNewline }))
        }
        if let l = pieces.last, l.1 == nil {
            var t = l.0
            while let c = t.last, c.isWhitespace || c.isNewline { t.removeLast() }
            pieces[pieces.count - 1].0 = t
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var out = AttributedString()
        func link(_ text: String, _ url: URL) {
            var a = AttributedString(text)
            a.link = url
            a.foregroundColor = Theme.accent
            a.underlineStyle = .single
            out += a
        }
        for (text, url) in pieces {
            if let url { link(text, url); continue }
            // plain text: make bare URLs tappable too
            let t = text as NSString
            var pos = 0
            for m in detector?.matches(in: text, range: NSRange(location: 0, length: t.length)) ?? [] {
                guard let u = m.url else { continue }
                out += AttributedString(t.substring(with: NSRange(location: pos, length: m.range.location - pos)))
                link(t.substring(with: m.range), u)
                pos = m.range.location + m.range.length
            }
            out += AttributedString(t.substring(from: pos))
        }
        return out
    }
}

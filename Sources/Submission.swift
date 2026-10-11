import SwiftUI
import UniformTypeIdentifiers

// MARK: - API helpers

struct AttSummary {
    var rows: [(String, String)] = []
    var points: String?
    var absent: [String] = []
}

extension MoodleAPI {
    // ---- Attendance ----
    func attendanceSessions(userid: Int, attendanceId: Int) async throws -> [AttSession] {
        let courses: [AttCourse] = try await call("mod_attendance_get_courses_with_today_sessions", ["userid": userid])
        let ids = courses.flatMap { $0.attendance_instances ?? [] }
            .flatMap { $0.today_sessions ?? [] }
            .filter { $0.attendanceid == nil || $0.attendanceid == attendanceId }
            .map { $0.id }
        var out: [AttSession] = []
        for id in ids {
            let s: AttSession = try await call("mod_attendance_get_session", ["sessionid": id])
            out.append(s)
        }
        return out.sorted { ($0.sessdate ?? 0) < ($1.sessdate ?? 0) }
    }

    func markAttendance(sessionId: Int, userid: Int, statusId: Int, password: String?) async throws {
        _ = try await raw("mod_attendance_submit_session",
                          ["sessionid": sessionId, "studentid": userid,
                           "statusid": statusId, "statuspass": password ?? ""])
    }

    // Percentage / absences are not in the web-service API, so the attendance page is fetched and parsed
    func fetchHTML(_ url: URL, userid: Int) async -> String? {
        func get(_ u: URL) async -> String? {
            guard let (d, r) = try? await URLSession.shared.data(from: u) else { return nil }
            let html = String(decoding: d, as: UTF8.self)
            if (r.url?.path ?? "").contains("/login/") { return nil }
            return html
        }
        if let h = await get(url) { return h }
        let al = await autologin(url, userid: userid, force: true)
        if al != url { return await get(al) }
        return nil
    }

    func parseAttendance(_ html: String) -> AttSummary {
        func groups(_ pattern: String, _ s: String, _ opts: NSRegularExpression.Options = [.caseInsensitive]) -> [[String]] {
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
        let cleaned = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>|<style[\\s\\S]*?</style>",
                                                with: " ", options: [.regularExpression, .caseInsensitive])
        let text = strip(cleaned)
        var sum = AttSummary()
        for g in groups("(Percentage[^%\\d]{0,60}?)([\\d.]+)\\s*%", text).prefix(3) {
            let label = g[0].trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            sum.rows.append((label, g[1] + "%"))
        }
        if let g = groups("Points[^\\d]{0,60}?([\\d.]+)\\s*/\\s*([\\d.]+)", text).first {
            sum.points = "\(g[0]) / \(g[1]) points"
        }
        for tr in groups("<tr[^>]*>([\\s\\S]*?)</tr>", cleaned) {
            let cells = groups("<t[dh][^>]*>([\\s\\S]*?)</t[dh]>", tr[0]).map { strip($0[0]) }
            guard cells.count >= 2, cells[0].range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression) != nil,
                  cells.contains(where: { $0.caseInsensitiveCompare("Absent") == .orderedSame }) else { continue }
            let d = cells[0].replacingOccurrences(of: "\\s*\\d{1,2}(:\\d{2})?\\s*[AaPp][Mm].*$",
                                                  with: "", options: .regularExpression)
            sum.absent.append(d.isEmpty ? cells[0] : d)
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
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        field("token", token)
        field("filearea", "draft")
        field("itemid", String(itemid))
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_1\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, _) = try await URLSession.shared.upload(for: req, from: body)
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let arr = obj as? [[String: Any]], let id = arr.first?["itemid"] as? Int { return id }
        if let d = obj as? [String: Any], let e = d["error"] as? String { throw APIError(message: e) }
        throw APIError(message: "Upload failed for \(name)")
    }

    private func throwIfWarnings(_ data: Data) throws {
        if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let m = arr.first?["message"] as? String {
            throw APIError(message: m.plainText)
        }
    }

    func saveSubmission(assignId: Int, text: String?, draftItemId: Int?) async throws {
        var pd: [String: Any] = [:]
        if let t = text { pd["onlinetext_editor"] = ["text": t, "format": 1, "itemid": 0] as [String: Any] }
        if let f = draftItemId { pd["files_filemanager"] = f }
        let data = try await raw("mod_assign_save_submission", ["assignmentid": assignId, "plugindata": pd])
        try throwIfWarnings(data)
    }

    func submitForGrading(assignId: Int) async throws {
        let data = try await raw("mod_assign_submit_for_grading",
                                 ["assignmentid": assignId, "acceptsubmissionstatement": 1])
        try throwIfWarnings(data)
    }
}

// MARK: - Attendance screen

struct AttendanceView: View {
    let module: Module
    @EnvironmentObject var app: AppState
    @State private var sessions: [AttSession] = []
    @State private var summary: AttSummary?
    @State private var summaryNote: String? = "Loading attendance..."
    @State private var loading = true
    @State private var error: String?
    @State private var info: String?
    @State private var passwords: [Int: String] = [:]
    @State private var needsPass: Set<Int> = []
    @State private var busyId: Int?

    private var uid: Int { app.site?.userid ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard
                Text("Today's sessions").font(.footnote.weight(.semibold)).foregroundColor(Theme.muted)
                if let error { Text(error).font(.footnote).foregroundColor(.red.opacity(0.85)) }
                if let info { Text(info).font(.footnote).foregroundColor(Theme.accent) }
                ForEach(sessions) { s in sessionCard(s) }
                if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                else if sessions.isEmpty && error == nil {
                    Text("No sessions today.").foregroundColor(Theme.muted)
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
        .refreshable { await loadSessions() }
        .task { await loadSessions(); await loadSummary() }
    }

    @ViewBuilder private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATTENDANCE").font(.caption).foregroundColor(Theme.muted)
            if let s = summary {
                ForEach(Array(s.rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 6) {
                        Text(r.0).foregroundColor(Theme.txt)
                        Text(r.1).font(.title3.bold()).foregroundColor(Theme.accent)
                    }
                }
                if let p = s.points { Text(p).font(.caption).foregroundColor(Theme.muted) }
                if !s.absent.isEmpty {
                    Text("ABSENT (\(s.absent.count))").font(.caption).foregroundColor(Theme.muted).padding(.top, 6)
                    ForEach(Array(s.absent.prefix(8).enumerated()), id: \.offset) { _, d in
                        Text(d).font(.subheadline).foregroundColor(Theme.txt)
                    }
                    if s.absent.count > 8 {
                        Text("+ \(s.absent.count - 8) more").font(.caption).foregroundColor(Theme.muted)
                    }
                }
            } else if let n = summaryNote {
                Text(n).font(.subheadline).foregroundColor(Theme.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
    }

    private func currentStatus(_ s: AttSession) -> String? {
        guard let sid = s.attendance_log?.first(where: { $0.studentid == uid })?.statusid,
              let st = s.statuses?.first(where: { $0.id == sid }) else { return nil }
        return st.description ?? st.acronym
    }

    @ViewBuilder private func sessionCard(_ s: AttSession) -> some View {
        let canMark = s.studentscanmark?.value ?? false
        VStack(alignment: .leading, spacing: 10) {
            Text(fmt(s.sessdate)).fontWeight(.semibold).foregroundColor(Theme.txt)
            if let d = s.description?.plainText, !d.isEmpty {
                Text(d).font(.subheadline).foregroundColor(Theme.muted)
            }
            if let c = currentStatus(s) {
                Text("Your status: \(c)").font(.subheadline).foregroundColor(Theme.accent)
            }
            if canMark {
                if needsPass.contains(s.id) || !(s.studentpassword ?? "").isEmpty {
                    SecureField("Session password", text: Binding(
                        get: { passwords[s.id] ?? "" }, set: { passwords[s.id] = $0 }))
                        .foregroundColor(Theme.txt).padding(12)
                        .background(Theme.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(s.statuses ?? []) { st in
                        Button { Task { await mark(s, st) } } label: {
                            Text(st.description ?? st.acronym ?? "Mark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(busyId == s.id)
                    }
                }
            } else {
                Text("Students can't mark this session yet.").font(.caption).foregroundColor(Theme.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
    }

    private func mark(_ s: AttSession, _ st: AttStatus) async {
        busyId = s.id; error = nil; info = nil
        do {
            try await MoodleAPI.shared.markAttendance(sessionId: s.id, userid: uid, statusId: st.id,
                                                      password: passwords[s.id])
            info = "Attendance marked: \(st.description ?? st.acronym ?? "")"
            await loadSessions()
            await loadSummary()
        } catch {
            if error.localizedDescription.lowercased().contains("password") { needsPass.insert(s.id) }
            self.error = error.localizedDescription
        }
        busyId = nil
    }

    private func loadSessions() async {
        do {
            sessions = try await MoodleAPI.shared.attendanceSessions(userid: uid, attendanceId: module.instance ?? 0)
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }

    private func loadSummary() async {
        guard var c = URLComponents(string: module.url ?? "") else { summaryNote = nil; return }
        var q = c.queryItems ?? []
        q.removeAll { $0.name == "view" }
        q.append(URLQueryItem(name: "view", value: "4"))   // 4 = all past sessions
        c.queryItems = q
        guard let u = c.url, let html = await MoodleAPI.shared.fetchHTML(u, userid: uid) else {
            summaryNote = "Couldn't load your attendance percentage."
            return
        }
        let s = MoodleAPI.shared.parseAttendance(html)
        if s.rows.isEmpty { summaryNote = "No attendance percentage found." } else { summary = s }
    }
}

// MARK: - Assignment screen with built-in submission

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
    @State private var showPicker = false
    @State private var busy = false

    private var existingFiles: [FileRef] {
        (status?.lastattempt?.submission?.plugins ?? [])
            .filter { $0.type == "file" }
            .flatMap { $0.fileareas ?? [] }
            .flatMap { $0.files ?? [] }
    }
    private var subStatus: String { status?.lastattempt?.submission?.status ?? "" }
    private var canEdit: Bool { status?.lastattempt?.canedit?.value ?? true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Text(error).font(.footnote).foregroundColor(Theme.muted) }
                if let a = assign {
                    VStack(alignment: .leading, spacing: 0) {
                        infoRow("Due", fmt(a.duedate))
                        infoRow("Submission status", (subStatus.isEmpty ? "-" : subStatus).capitalized)
                        infoRow("Grading status", (status?.lastattempt?.gradingstatus ?? "-")
                                    .replacingOccurrences(of: "notgraded", with: "Not graded").capitalized)
                        if let g = status?.feedback?.gradefordisplay, !g.isEmpty { infoRow("Grade", g.plainText) }
                    }
                    .glowCard()

                    if let intro = a.intro?.plainText, !intro.isEmpty {
                        Text(intro).foregroundColor(Theme.txt)
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .glowCard()
                    }
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
    }

    // ---- submission UI ----
    @ViewBuilder private func submissionCard(_ a: Assign) -> some View {
        let fileOn = a.enabled("file"), textOn = a.enabled("onlinetext")
        VStack(alignment: .leading, spacing: 12) {
            Text("SUBMISSION").font(.caption).foregroundColor(Theme.muted)
            if !(fileOn || textOn) {
                Text("This assignment doesn't accept online submissions.").foregroundColor(Theme.muted)
            } else if !canEdit {
                Text("Submission is locked.").foregroundColor(Theme.muted)
                ForEach(existingFiles) { f in fileRow(f) }
            } else {
                if fileOn {
                    ForEach(existingFiles) { f in fileRow(f) }
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
                        Label("Add file", systemImage: "paperclip")
                            .foregroundColor(Theme.accent)
                    }
                    if !existingFiles.isEmpty && !picked.isEmpty {
                        Text("Saving replaces the files already submitted.")
                            .font(.caption).foregroundColor(Theme.muted)
                    }
                }
                if textOn {
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .foregroundColor(Theme.txt)
                        .frame(minHeight: 140)
                        .padding(8)
                        .background(Theme.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let message { Text(message).font(.footnote).foregroundColor(Theme.accent) }
                HStack(spacing: 12) {
                    Button { Task { await save(a, submit: false) } } label: {
                        Text(a.submissiondrafts == 1 ? "Save draft" : "Submit")
                            .fontWeight(.semibold).foregroundColor(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if a.submissiondrafts == 1 && (subStatus == "draft" || status?.lastattempt?.cansubmit?.value == true) {
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
                if busy { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
    }

    @ViewBuilder private func fileRow(_ f: FileRef) -> some View {
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

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(Theme.muted).frame(width: 130, alignment: .leading)
            Text(v).foregroundColor(Theme.txt)
            Spacer()
        }
        .padding(14)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    // ---- actions ----
    private func addFiles(_ urls: [URL]) {
        let tmp = FileManager.default.temporaryDirectory
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = tmp.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: u, to: dest); picked.append(dest) }
            catch { message = "Couldn't read \(u.lastPathComponent)" }
        }
    }

    private func save(_ a: Assign, submit: Bool) async {
        busy = true; message = nil
        do {
            var item: Int? = nil
            for f in picked { item = try await MoodleAPI.shared.uploadDraft(f, itemid: item ?? 0) }
            try await MoodleAPI.shared.saveSubmission(
                assignId: a.id, text: a.enabled("onlinetext") ? text : nil, draftItemId: item)
            if submit { try await MoodleAPI.shared.submitForGrading(assignId: a.id) }
            picked = []
            message = submit ? "Submitted for grading." : (a.submissiondrafts == 1 ? "Draft saved." : "Submitted.")
            await loadStatus(a)
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }

    private func loadStatus(_ a: Assign) async {
        let s: StatusResp? = try? await MoodleAPI.shared.call(
            "mod_assign_get_submission_status", ["assignid": a.id, "userid": app.site?.userid ?? 0])
        status = s
        if !textLoaded {
            let t = (s?.lastattempt?.submission?.plugins ?? []).first { $0.type == "onlinetext" }?
                .editorfields?.first?.text
            if let t { text = t.plainText }
            textLoaded = true
        }
    }

    private func load() async {
        do {
            let r: AssignResp = try await MoodleAPI.shared.call(
                "mod_assign_get_assignments", ["courseids": [courseId]])
            assign = r.courses.first?.assignments.first { $0.cmid == module.id }
            if let a = assign { await loadStatus(a) }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

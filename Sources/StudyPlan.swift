import Foundation
import PDFKit
import SwiftUI

// MARK: - Study plan tracker: model, PDF reader and saved progress
//
// The student uploads the faculty's study-plan PDF (the "General programme structure" page with the credit-hour table,
// the course lists per category, and the "Proposed study plan" semester by semester). The reader works from where each
// letter sits on the page (PDFKit gives every character's position), so wrapped names and prerequisites are put back
// together. Everything is then tracked like the Excel tracker: tick the subjects you have finished, and the totals per
// degree, per category and per semester follow.

struct PlanCourse: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var credits: Double
    var prereq: String
    var category: String
    var audience: String        // "all", "local" (Malaysian only) or "international" (international only)
    var year: Int
    var sem: Int
    var id: String { "\(year)-\(sem)-\(code)-\(name)" }
}

struct PlanSemester: Codable, Identifiable, Hashable {
    var year: Int
    var sem: Int
    var recommended: Double?
    var courses: [PlanCourse]
    var id: String { "\(year)-\(sem)" }
    var title: String { "Year \(year), Semester \(sem)" }
}

struct PlanRequirement: Codable, Hashable { var category: String; var hours: Double }

struct StudyPlan: Codable {
    var title: String
    var totalRequired: Double
    var requirements: [PlanRequirement]
    var semesters: [PlanSemester]
}

enum StudentType: String, Codable, CaseIterable, Identifiable {
    case local = "Malaysian", international = "International"
    var id: String { rawValue }
    /// subjects marked "(International Only)" / "(Malaysian Only)" in the plan
    func includes(_ audience: String) -> Bool {
        audience == "all" || (audience == "local" && self == .local) || (audience == "international" && self == .international)
    }
}

// MARK: Reader

enum StudyPlanReader {
    private struct Cell { var text: String; var x0: CGFloat; var x1: CGFloat }
    private struct Line { var page: Int; var y: CGFloat; var cells: [Cell]
        var text: String { cells.map(\.text).joined(separator: " ") } }

    private static let categories: [(String, String)] = [
        ("university required", "University Required"), ("core computing", "Core Computing"), ("discipline", "Discipline Core"),
        ("field elective", "Field Elective"), ("free elective", "Free Elective"), ("final year project", "FYP"),
        ("industrial attachment", "Industrial Attachment")]

    private static func categoryOf(_ t: String) -> String? {
        let l = t.lowercased()
        return categories.first { l.contains($0.0) }?.1
    }

    // ---- small text helpers ----
    private static func has(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    private static func sub(_ s: String, _ pattern: String, _ with: String) -> String {
        s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }
    private static func groups(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }
    private static func median(_ a: [CGFloat], _ d: CGFloat) -> CGFloat {
        guard !a.isEmpty else { return d }
        let s = a.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    private static func isCredit(_ s: String) -> Bool { has("^\\d{1,2}(\\.\\d)?$", s) }
    private static func isCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return has("^[A-Z]{2,5}\\s?\\d{4}[A-Z]?,?$", t) || has("^[A-Z]{2,5}/[A-Z]{2,5}(\\s*XXXX)?$", t)
    }

    // ---- 1. characters -> lines -> cells ----
    private static func lines(of doc: PDFDocument) -> [Line] {
        var out: [Line] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p), let s = page.string else { continue }
            let ns = s as NSString
            let n = min(page.numberOfCharacters, ns.length)
            var items: [(ch: String, x0: CGFloat, x1: CGFloat, y: CGFloat)] = []
            for i in 0..<n {
                let ch = ns.substring(with: NSRange(location: i, length: 1))
                if ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let r = page.characterBounds(at: i)
                if r.width <= 0 || r.height <= 0 { continue }
                items.append((ch, r.minX, r.maxX, r.midY))
            }
            items.sort { $0.y > $1.y }                       // top of the page first (PDF y grows upwards)
            var groupsOfChars: [[(ch: String, x0: CGFloat, x1: CGFloat, y: CGFloat)]] = []
            // PDFKit gives each glyph's own ink box, so tall letters (i, l, k, d) sit higher than short ones (a, e, r).
            // A fixed tolerance around a running mean splits one line apart; instead start a new line only where the
            // sorted heights jump (line spacing is far larger than the spread inside one line).
            for it in items {
                if let prev = groupsOfChars.last?.last, prev.y - it.y <= 4 { groupsOfChars[groupsOfChars.count - 1].append(it) }
                else { groupsOfChars.append([it]) }
            }
            for g in groupsOfChars {
                let cs = g.sorted { $0.x0 < $1.x0 }
                var cells: [[(ch: String, x0: CGFloat, x1: CGFloat, y: CGFloat)]] = [[cs[0]]]
                for k in 1..<cs.count {
                    if cs[k].x0 - cs[k - 1].x1 > 9 { cells.append([cs[k]]) } else { cells[cells.count - 1].append(cs[k]) }
                }
                var cl: [Cell] = []
                for cell in cells {
                    var t = ""
                    for (j, c) in cell.enumerated() {
                        if j > 0, c.x0 - cell[j - 1].x1 > 1.2 { t += " " }
                        t += c.ch
                    }
                    cl.append(Cell(text: t, x0: cell[0].x0, x1: cell[cell.count - 1].x1))
                }
                out.append(Line(page: p, y: g.map(\.y).reduce(0, +) / CGFloat(g.count), cells: cl))
            }
        }
        return out
    }

    // ---- 2. sections ----
    private enum Kind { case cat(String), plan(Int, Int) }
    private struct Block { var kind: Kind; var lines: [Line] = [] }

    private static func sections(_ lines: [Line]) -> (blocks: [Block], reqs: [PlanRequirement], total: Double?, title: String) {
        enum Mode { case front, cat, plan, conc }
        var mode = Mode.front
        var blocks: [Block] = []
        var open = false
        var reqs: [PlanRequirement] = []
        var total: Double?
        var title = ""
        for L in lines {
            let txt = L.text.trimmingCharacters(in: .whitespaces)
            if txt.isEmpty { continue }
            let up = txt.uppercased()
            if let m = groups("^YEAR\\s*(\\d)\\s*SEMESTER\\s*(\\d)$", in: up).first, m.count == 3,
               let y = Int(m[1]), let s = Int(m[2]) {
                mode = .plan; blocks.append(Block(kind: .plan(y, s))); open = true; continue
            }
            if up.contains("PROPOSED STUDY PLAN") { mode = .plan; open = false; continue }
            if up.contains("TOTAL GRADUATING") { open = false; continue }
            if up.contains("LIST OF FIELD ELECTIVES") { mode = .conc; open = false; continue }
            if mode == .conc { continue }
            if mode != .plan, L.cells.count == 1, txt == up, let c = categoryOf(txt) {
                mode = .cat; blocks.append(Block(kind: .cat(c))); open = true; continue
            }
            if mode == .front {
                if L.cells.count == 2, has("^\\d{1,3}$", L.cells[1].text), let v = Double(L.cells[1].text) {
                    if L.cells[0].text.lowercased().hasPrefix("total") { total = v }
                    else if let c = categoryOf(L.cells[0].text) { reqs.append(PlanRequirement(category: c, hours: v)) }
                } else if L.cells.count == 1, up.contains("BACHELOR"), title.isEmpty { title = txt.capitalized }
                continue
            }
            if open, !blocks.isEmpty { blocks[blocks.count - 1].lines.append(L) }
        }
        return (blocks, reqs, total, title)
    }

    // ---- 3. rows of a section (a line with a credit number is a row; the lines around it are wrapped text) ----
    private struct Row {
        var page: Int; var y: CGFloat; var credit: Double
        var code: [(CGFloat, String)] = []; var name: [(CGFloat, String)] = []; var pre: [(CGFloat, String)] = []
    }
    private struct RawRow { var code: String; var name: String; var credit: Double; var pre: String }

    private static let headerWords = ["course code", "course name", "credit", "hours", "pre-requisite", "offering", "dept", "course categories"]

    private static func rows(of b: Block) -> (rows: [RawRow], recommended: Double?) {
        var isPlan = false
        if case .plan = b.kind { isPlan = true }
        var anchors: [(Line, Int)] = []
        var orphans: [Line] = []
        var rec: Double?
        for L in b.lines {
            let low = L.text.trimmingCharacters(in: .whitespaces).lowercased()
            if low.hasPrefix("total") {
                if rec == nil, isPlan, let n = L.cells.first(where: { has("^\\d{1,3}(\\.\\d)?$", $0.text) }) { rec = Double(n.text) }
                continue
            }
            if headerWords.contains(low) || low.hasPrefix("course code") || low.hasPrefix("pre-requisite") { continue }
            var ci: Int?
            for (i, c) in L.cells.enumerated() where i >= 1 && isCredit(c.text) { ci = i; break }
            if let ci { anchors.append((L, ci)) }
            else if !(L.cells.count == 1 && isCredit(L.cells[0].text)) { orphans.append(L) }
        }
        var codeX: [CGFloat] = [], nameX: [CGFloat] = [], preX: [CGFloat] = []
        for (L, ci) in anchors {
            let c = L.cells
            let hasCode = isCode(c[0].text)
            if hasCode { codeX.append(c[0].x0) }
            let ni = hasCode ? 1 : 0
            if ni < ci { nameX.append(c[ni].x0) }
            if ci + 1 < c.count { preX.append(c[ci + 1].x0) }
        }
        let cx = median(codeX, 80), nx = median(nameX, cx + 70), px = median(preX, nx + 300)
        var rs: [Row] = []
        for (L, ci) in anchors {
            let c = L.cells
            let hasCode = isCode(c[0].text)
            let ni = hasCode ? 1 : 0
            var r = Row(page: L.page, y: L.y, credit: Double(c[ci].text) ?? 0)
            if hasCode { r.code = [(L.y, c[0].text)] }
            if ni < ci { r.name = [(L.y, c[ni..<ci].map(\.text).joined(separator: " "))] }
            if isPlan, ci + 1 < c.count { r.pre = [(L.y, c[ci + 1].text)] }
            rs.append(r)
        }
        for L in orphans {
            for cell in L.cells {
                var best = -1
                var bestD = CGFloat.greatestFiniteMagnitude
                for (i, r) in rs.enumerated() where r.page == L.page {
                    let d = abs(r.y - L.y)
                    if d < bestD { bestD = d; best = i }
                }
                if best < 0 || bestD > 24 { continue }
                let d = [abs(cell.x0 - cx), abs(cell.x0 - nx), abs(cell.x0 - px)]
                let k = d.firstIndex(of: d.min() ?? 0) ?? 1
                if !isPlan && k == 2 { continue }
                switch k {
                case 0: rs[best].code.append((L.y, cell.text))
                case 1: rs[best].name.append((L.y, cell.text))
                default: rs[best].pre.append((L.y, cell.text))
                }
            }
        }
        func join(_ p: [(CGFloat, String)]) -> String { p.sorted { $0.0 > $1.0 }.map(\.1).joined(separator: " ") }
        return (rs.map { RawRow(code: join($0.code), name: cleanName(join($0.name)), credit: $0.credit, pre: join($0.pre)) }, rec)
    }

    private static func cleanName(_ n: String) -> String {
        var s = sub(n, "\\s+", " ").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
        if s.filter({ $0 == "(" }).count > s.filter({ $0 == ")" }).count { s += ")" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "LMBD1132" -> "LMBD 1132"; "CCSS 1020, CCSS 2010, CCSS 3010" -> "CCSS 1020/2010/3010"
    private static func normCode(_ c: String) -> String {
        var s = sub(c, "\\s+", " ").trimmingCharacters(in: .whitespaces)
        s = sub(s, "^([A-Z]{2,5})(\\d{4})", "$1 $2")
        let codes = groups("([A-Z]{2,5})\\s?(\\d{4}[A-Z]?)", in: s)
        if codes.count > 1, Set(codes.map { $0[1] }).count == 1 {
            return codes[0][1] + " " + codes.map { $0[2] }.joined(separator: "/")
        }
        while s.hasSuffix(",") { s.removeLast() }
        return s
    }

    // ---- 4. everything together ----
    static func read(_ url: URL) -> StudyPlan? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let (blocks, reqs, total, title) = sections(lines(of: doc))

        // which category each subject belongs to (from the course lists)
        var catalog: [String: String] = [:]
        for b in blocks {
            guard case .cat(let cat) = b.kind else { continue }
            for r in rows(of: b).rows {
                let code = r.code.isEmpty ? "" : normCode(r.code)
                let placeholder = code.isEmpty || code.contains("XXXX")
                catalog[(placeholder ? r.name : code).lowercased()] = cat
                catalog[r.name.lowercased()] = cat
            }
        }

        var semesters: [PlanSemester] = []
        for b in blocks {
            guard case .plan(let y, let s) = b.kind else { continue }
            let (rs, rec) = rows(of: b)
            var courses: [PlanCourse] = []
            for r in rs {
                var code = r.code.isEmpty ? "" : normCode(r.code)
                var name = r.name
                var audience = "all"
                if has("(?i)international only", name) { audience = "international" }
                if has("(?i)malaysian only", name) { audience = "local" }
                name = name.replacingOccurrences(of: "\\s*\\((International|Malaysian) Only\\)", with: "",
                                                 options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
                if code.isEmpty || code.contains("XXXX") { code = name }
                var cat = catalog[code.lowercased()] ?? catalog[name.lowercased()]
                if cat == nil {
                    let l = name.lowercased()
                    cat = l.hasPrefix("field elective") ? "Field Elective" : l.hasPrefix("free elective") ? "Free Elective" : "Other"
                }
                var pre = sub(r.pre.trimmingCharacters(in: .whitespaces), "^-+$", "-")
                if pre.isEmpty { pre = "-" }
                courses.append(PlanCourse(code: code, name: name, credits: r.credit, prereq: pre, category: cat ?? "Other",
                                          audience: audience, year: y, sem: s))
            }
            if !courses.isEmpty { semesters.append(PlanSemester(year: y, sem: s, recommended: rec, courses: courses)) }
        }
        guard semesters.reduce(0, { $0 + $1.courses.count }) >= 3 else { return nil }

        var requirements = reqs
        var totalRequired = total ?? 0
        if requirements.isEmpty {         // no credit-hour table found: use what the plan itself adds up to
            var sums: [String: Double] = [:]
            for c in semesters.flatMap(\.courses) where c.audience != "international" { sums[c.category, default: 0] += c.credits }
            requirements = sums.keys.sorted().map { PlanRequirement(category: $0, hours: sums[$0] ?? 0) }
        }
        if totalRequired <= 0 { totalRequired = requirements.reduce(0) { $0 + $1.hours } }
        return StudyPlan(title: title.isEmpty ? "Study plan" : title, totalRequired: totalRequired,
                         requirements: requirements, semesters: semesters)
    }
}

// MARK: Saved plan and progress

@MainActor
final class StudyPlanStore: ObservableObject {
    static let shared = StudyPlanStore()

    @Published private(set) var plan: StudyPlan?
    @Published private(set) var taken: Set<String> = []
    @Published var student: StudentType {
        didSet { UserDefaults.standard.set(student.rawValue, forKey: "studyplan.student") }
    }

    private let planKey = "studyplan.plan.v1", takenKey = "studyplan.taken.v1"

    init() {
        student = StudentType(rawValue: UserDefaults.standard.string(forKey: "studyplan.student") ?? "") ?? .local
        if let d = UserDefaults.standard.data(forKey: planKey), let p = try? JSONDecoder().decode(StudyPlan.self, from: d) { plan = p }
        taken = Set(UserDefaults.standard.stringArray(forKey: takenKey) ?? [])
    }

    private func save() {
        if let p = plan, let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: planKey) }
        else { UserDefaults.standard.removeObject(forKey: planKey) }
        UserDefaults.standard.set(Array(taken), forKey: takenKey)
    }

    /// A newly read plan replaces the old one; ticks are kept for subjects that are still in it
    func replace(with p: StudyPlan) {
        plan = p
        let ids = Set(p.semesters.flatMap(\.courses).map(\.id))
        taken = taken.intersection(ids)
        save()
    }
    func remove() { plan = nil; taken = []; save() }
    func resetProgress() { taken = []; save() }

    func isTaken(_ c: PlanCourse) -> Bool { taken.contains(c.id) }
    func toggle(_ c: PlanCourse) {
        if taken.contains(c.id) { taken.remove(c.id) } else { taken.insert(c.id) }
        save()
    }
    func setAll(_ s: PlanSemester, _ value: Bool) {
        for c in visible(s) { if value { taken.insert(c.id) } else { taken.remove(c.id) } }
        save()
    }

    // ---- the Excel logic ----
    func visible(_ s: PlanSemester) -> [PlanCourse] { s.courses.filter { student.includes($0.audience) } }
    private var allVisible: [PlanCourse] { (plan?.semesters ?? []).flatMap { visible($0) } }

    var totalRequired: Double { plan?.totalRequired ?? 0 }
    var creditsTaken: Double { allVisible.filter { taken.contains($0.id) }.reduce(0) { $0 + $1.credits } }
    var creditsRemaining: Double { max(totalRequired - creditsTaken, 0) }
    var percent: Double { totalRequired > 0 ? min(creditsTaken / totalRequired, 1) : 0 }

    func categoryTaken(_ cat: String) -> Double {
        allVisible.filter { $0.category == cat && taken.contains($0.id) }.reduce(0) { $0 + $1.credits }
    }
    func semesterTaken(_ s: PlanSemester) -> Double { visible(s).filter { taken.contains($0.id) }.reduce(0) { $0 + $1.credits } }
    func semesterPlanned(_ s: PlanSemester) -> Double { visible(s).reduce(0) { $0 + $1.credits } }

    enum Status: String { case complete = "Complete", progress = "In progress", notStarted = "Not started" }
    /// Complete when the credits taken reach the recommended load of the semester (as in the Excel tracker)
    func status(_ s: PlanSemester) -> Status {
        let t = semesterTaken(s)
        if t <= 0 { return .notStarted }
        return t >= (s.recommended ?? semesterPlanned(s)) - 1e-9 ? .complete : .progress
    }

    /// A subject whose prerequisite (one that is in the plan) has not been ticked yet
    func missingPrereq(_ c: PlanCourse) -> String? {
        guard !taken.contains(c.id) else { return nil }
        let codes = (plan?.semesters ?? []).flatMap(\.courses)
        guard let re = try? NSRegularExpression(pattern: "[A-Z]{2,5}\\s?\\d{4}[A-Z]?") else { return nil }
        let ns = c.prereq as NSString
        for m in re.matches(in: c.prereq, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: m.range)
            let want = found.replacingOccurrences(of: " ", with: "")
            if let p = codes.first(where: { $0.code.replacingOccurrences(of: " ", with: "") == want }), !taken.contains(p.id) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Screen

struct StudyPlanTrackerView: View {
    @ObservedObject private var store = StudyPlanStore.shared
    @ObservedObject private var themes = ThemeStore.shared
    @State private var importing = false
    @State private var busy = false
    @State private var failed = false
    @State private var collapsed: Set<String> = []
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let plan = store.plan { content(plan) } else { emptyState }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Study Plan Tracker")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.plan != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { importing = true } label: { Label("Upload a new PDF", systemImage: "arrow.up.doc") }
                        Button { store.resetProgress() } label: { Label("Clear all ticks", systemImage: "arrow.counterclockwise") }
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove plan", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            load(url)
        }
        .alert("Couldn't read this PDF", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: { Text("It should be a study plan with a \"Proposed study plan\" table listing subjects per semester.") }
        .confirmationDialog("Remove the study plan and your ticks?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.remove() }
        }
        .overlay { if busy { ProgressView("Reading…").padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    private func load(_ url: URL) {
        busy = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            // PDFKit reading stays on the main actor; yield once so the spinner shows
            await Task.yield()
            let plan = StudyPlanReader.read(url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            busy = false
            if let plan { store.replace(with: plan); collapsed = [] } else { failed = true }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Track your degree").font(Theme.font(.title3.weight(.semibold))).foregroundStyle(Theme.txt)
            Text("Upload your programme's study plan PDF. It is read on your phone, nothing is sent anywhere. Then tick the subjects you have finished to see credits, categories and semesters add up.")
                .font(Theme.read(.subheadline)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button { importing = true } label: {
                Label("Choose PDF", systemImage: "arrow.up.doc").font(Theme.font(.subheadline.weight(.semibold)))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
            }
            Button("Use the CS study plan from Semester Resources") { useBundled() }
                .font(Theme.read(.footnote)).foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 8)
    }

    private func useBundled() {
        if let u = Bundle.main.url(forResource: "cs_study_plan", withExtension: "pdf") ?? Bundle.main.url(forResource: "cs_study_plan", withExtension: "pdf", subdirectory: "SemesterResources") {
            load(u)
        } else { failed = true }
    }

    @ViewBuilder private func content(_ plan: StudyPlan) -> some View {
        // summary
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(fmt(store.creditsTaken))").font(Theme.font(.largeTitle.weight(.bold))).foregroundStyle(Theme.accent)
                Text("/ \(fmt(store.totalRequired)) credit hours").font(Theme.read(.subheadline)).foregroundStyle(Theme.muted)
                Spacer()
                Text("\(Int((store.percent * 100).rounded()))%").font(Theme.font(.title3.weight(.semibold))).foregroundStyle(Theme.txt)
            }
            Bar(value: store.percent, height: 10)
            HStack {
                Text("\(fmt(store.creditsRemaining)) to go").font(Theme.read(.footnote)).foregroundStyle(Theme.muted)
                Spacer()
                Picker("", selection: $store.student) {
                    ForEach(StudentType.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).tint(Theme.accent)
            }
        }
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

        // categories
        VStack(alignment: .leading, spacing: 10) {
            Text("By category").font(Theme.font(.footnote.weight(.semibold))).foregroundStyle(Theme.muted)
            ForEach(plan.requirements, id: \.category) { r in
                let t = store.categoryTaken(r.category)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.category).font(Theme.read(.subheadline)).foregroundStyle(Theme.txt)
                        Spacer()
                        Text("\(fmt(t)) / \(fmt(r.hours))").font(Theme.read(.footnote)).foregroundStyle(Theme.muted)
                    }
                    Bar(value: r.hours > 0 ? min(t / r.hours, 1) : 0, height: 6)
                }
            }
        }
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))

        // semesters
        ForEach(plan.semesters) { s in semesterCard(s) }
    }

    private func semesterCard(_ s: PlanSemester) -> some View {
        let open = !collapsed.contains(s.id)
        let st = store.status(s)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { if open { collapsed.insert(s.id) } else { collapsed.remove(s.id) } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(Theme.font(.subheadline.weight(.semibold))).foregroundStyle(Theme.txt)
                        Text("\(fmt(store.semesterTaken(s))) / \(fmt(s.recommended ?? store.semesterPlanned(s))) credits")
                            .font(Theme.read(.caption)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(st.rawValue).font(Theme.read(.caption).weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((st == .complete ? Theme.accent : Theme.surface2), in: Capsule())
                        .foregroundStyle(st == .complete ? Theme.onAccent : Theme.muted)
                }
                .padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain)

            if open {
                ForEach(store.visible(s)) { c in
                    Divider().overlay(Theme.line)
                    courseRow(c)
                }
                Divider().overlay(Theme.line)
                HStack {
                    Spacer()
                    let all = store.visible(s).allSatisfy { store.isTaken($0) }
                    Button(all ? "Untick all" : "Tick all") { store.setAll(s, !all) }
                        .font(Theme.read(.footnote)).foregroundStyle(Theme.accent)
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func courseRow(_ c: PlanCourse) -> some View {
        let done = store.isTaken(c)
        let missing = store.missingPrereq(c)
        return Button { store.toggle(c) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(done ? Theme.accent : Theme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).font(Theme.read(.subheadline)).foregroundStyle(Theme.txt)
                        .strikethrough(done, color: Theme.muted).opacity(done ? 0.6 : 1)
                    Text([c.code == c.name ? nil : c.code, c.category].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.read(.caption)).foregroundStyle(Theme.muted)
                    if c.prereq != "-" {
                        Text("Prerequisite: \(c.prereq)").font(Theme.read(.caption))
                            .foregroundStyle(missing != nil ? Color.orange : Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                Text(fmt(c.credits)).font(Theme.font(.subheadline.weight(.semibold))).foregroundStyle(Theme.txt)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private struct Bar: View {
        var value: Double; var height: CGFloat
        var body: some View {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface2)
                    Capsule().fill(Theme.accent).frame(width: max(g.size.width * value, value > 0 ? height : 0))
                }
            }.frame(height: height)
        }
    }
}

import Foundation
import PDFKit
import SwiftUI
import UIKit
import Vision

// MARK: - Study plan tracker: model, PDF reader and saved progress
//
// The student uploads the faculty's study-plan PDF (the "General programme structure" page with the credit-hour table,
// the course lists per category, and the "Proposed study plan" semester by semester). The reader works from where each
// piece of text sits on the page, so wrapped names and prerequisites are put back together, and it checks what it read
// against the totals the PDF prints itself (see "Reader" below). Everything is then tracked like the Excel tracker: tick
// the subjects you have finished, and the totals per degree, per category and per semester follow.

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
    var recommended: Double?        // "Total Credits" printed for Malaysian students
    var recommendedIntl: Double?    // ... for international students (the same number when the PDF prints just one)
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
    var warnings: [String]?         // what did not add up when the PDF was read (nil when everything matched)
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
//
// How a PDF becomes a plan, and why the result can be trusted:
//  1. Text is collected together with where it sits on the page ("tokens"). First from the PDF's own text layer; if that
//     does not check out, from the pages read as pictures (Vision text recognition), which does not depend on how the PDF
//     was built at all.
//  2. Tokens become lines, lines become table cells (a wide gap starts a new cell), and cells become subjects. A line with a
//     credit number is a row; the lines around it are wrapped text that is put back by position.
//  3. The PDF checks itself: every semester prints its "Total Credits", the front page prints the credit-hour table and the
//     last page the graduating total. A reading is only accepted when the subjects add up to those numbers. Otherwise the
//     other reading is tried, the best one wins, and anything that still does not add up is shown to the student as a
//     warning instead of silently wrong numbers.

enum StudyPlanReader {
    /// A piece of text and its place on the page (PDF points, y grows upwards). The text layer gives single characters,
    /// text recognition gives whole words.
    private struct Tok {
        var page: Int
        var x0: CGFloat
        var x1: CGFloat
        var y: CGFloat          // vertical middle
        var h: CGFloat
        var text: String
        var isChar: Bool
    }
    private struct Cell { var text: String; var x0: CGFloat; var x1: CGFloat }
    private struct Line {
        var page: Int
        var y: CGFloat
        var cells: [Cell]
        var text: String { cells.map(\.text).joined(separator: " ") }
    }
    private struct TokGroup { var sum: CGFloat; var items: [Tok] }

    private static let cellGap: CGFloat = 8       // gap between two words that starts a new table cell
    private static let spaceGap: CGFloat = 1.5    // gap between two characters that means "there is a space here"
    private static let rowReach: CGFloat = 24     // how far a wrapped fragment may sit from the row it belongs to

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
    private static func isCredit(_ s: String) -> Bool { has("^\\d{1,2}([.,]\\d)?$", s.trimmingCharacters(in: .whitespaces)) }
    private static func toCredit(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }
    private static func isCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return has("^[A-Z]{2,5}\\s?\\d{4}[A-Z]?,?$", t) || has("^[A-Z]{2,5}/[A-Z]{2,5}(\\s*XXXX)?$", t)
    }
    /// the number at the end of "Total Credits (Local Students)   18.5"
    private static func trailingNumber(_ s: String) -> Double? {
        guard let m = groups("(\\d{1,3}(?:[.,]\\d)?)\\s*$", in: s).first, m.count >= 2 else { return nil }
        return Double(m[1].replacingOccurrences(of: ",", with: "."))
    }
    private static func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    // ---- 1. tokens -> lines -> cells ----
    private static func buildLines(_ tokens: [Tok]) -> [Line] {
        var byPage: [Int: [Tok]] = [:]
        for t in tokens { byPage[t.page, default: []].append(t) }
        var out: [Line] = []
        for page in byPage.keys.sorted() {
            var ts = byPage[page] ?? []
            // a word may be a little higher or lower than its neighbours (letters with tails, capitals...), so the
            // tolerance follows the text size; it stays far below the distance between two lines
            let tol = max(2.5, 0.4 * median(ts.map { $0.h }, 10))
            ts.sort { $0.y > $1.y }                               // top of the page first
            var gs: [TokGroup] = []
            for t in ts {
                if let last = gs.last, abs(last.sum / CGFloat(last.items.count) - t.y) <= tol {
                    gs[gs.count - 1].sum += t.y
                    gs[gs.count - 1].items.append(t)
                } else {
                    gs.append(TokGroup(sum: t.y, items: [t]))
                }
            }
            for g in gs {
                let items = g.items.sorted { $0.x0 < $1.x0 }
                var cells: [Cell] = []
                var prev: Tok? = nil
                for t in items {
                    if let p = prev, !cells.isEmpty {
                        let gap = t.x0 - p.x1
                        if gap > cellGap {
                            cells.append(Cell(text: t.text, x0: t.x0, x1: t.x1))
                        } else {
                            var c = cells[cells.count - 1]
                            if !t.isChar || !p.isChar || gap > spaceGap { c.text += " " }
                            c.text += t.text
                            c.x1 = t.x1
                            cells[cells.count - 1] = c
                        }
                    } else {
                        cells.append(Cell(text: t.text, x0: t.x0, x1: t.x1))
                    }
                    prev = t
                }
                out.append(Line(page: page, y: g.sum / CGFloat(g.items.count), cells: cells))
            }
        }
        return out
    }

    // ---- 2. sections ----
    private enum Kind { case cat(String), plan(Int, Int) }
    private struct Block { var kind: Kind; var lines: [Line] = [] }
    private struct Parsed {
        var blocks: [Block] = []
        var reqs: [PlanRequirement] = []
        var total: Double? = nil
        var title: String = ""
        var gradLocal: Double? = nil      // "Total Graduating Credits" at the end of the plan
        var gradIntl: Double? = nil
    }

    private static func sections(_ lines: [Line]) -> Parsed {
        enum Mode { case front, cat, plan, conc }
        var mode = Mode.front
        var p = Parsed()
        var open = false
        var inGrad = false
        for L in lines {
            let txt = L.text.trimmingCharacters(in: .whitespaces)
            if txt.isEmpty { continue }
            let up = txt.uppercased()
            // "YEAR 2 SEMESTER 1" (a lost letter or a stray "-" in front is fine)
            if txt.count <= 40, let m = groups("Y[A-Z]{1,4}\\s*(\\d)\\s*[-,:]?\\s*SE[A-Z]{2,8}\\s*(\\d)", in: up).first, m.count == 3,
               let y = Int(m[1]), let s = Int(m[2]) {
                mode = .plan; inGrad = false; p.blocks.append(Block(kind: .plan(y, s))); open = true; continue
            }
            if up.contains("PROPOSED STUDY PLAN") { mode = .plan; open = false; continue }
            if up.contains("TOTAL GRADUATING") { open = false; inGrad = true; continue }
            if up.contains("LIST OF FIELD ELECTIVES") { mode = .conc; open = false; continue }
            if mode == .conc { continue }
            if inGrad {
                let low = txt.lowercased()
                if low.hasPrefix("total"), let n = trailingNumber(txt) {
                    let intl = low.contains("international"), loc = low.contains("local")
                    if intl && !loc { p.gradIntl = n }
                    else if loc && !intl { p.gradLocal = n }
                    else if p.gradLocal == nil { p.gradLocal = n }
                }
                continue
            }
            if mode != .plan, txt == up, txt.count <= 45, !has("\\d", txt), let c = categoryOf(txt) {
                mode = .cat; p.blocks.append(Block(kind: .cat(c))); open = true; continue
            }
            if mode == .front {
                if let m = groups("^(.+?)\\s+(\\d{1,3})$", in: txt).first, m.count == 3, let v = Double(m[2]) {
                    if m[1].lowercased().hasPrefix("total") { if p.total == nil { p.total = v } }
                    else if let c = categoryOf(m[1]) { p.reqs.append(PlanRequirement(category: c, hours: v)) }
                } else if up.contains("BACHELOR"), p.title.isEmpty { p.title = txt.capitalized }
                continue
            }
            if open, !p.blocks.isEmpty { p.blocks[p.blocks.count - 1].lines.append(L) }
        }
        return p
    }

    // ---- 3. rows of a section (a line with a credit number is a row; the lines around it are wrapped text) ----
    private struct Row {
        var page: Int; var y: CGFloat; var credit: Double
        var code: [(CGFloat, String)] = []; var name: [(CGFloat, String)] = []; var pre: [(CGFloat, String)] = []
    }
    private struct RawRow { var code: String; var name: String; var credit: Double; var pre: String }
    private struct PrintedTotal { var label: String; var value: Double }

    private static let headerWords: Set<String> = ["course", "code", "name", "credit", "credits", "hours", "hour", "pre-requisite",
        "prerequisite", "pre", "requisite", "offering", "dept", "department", "categories", "category", "core", "non-core", "/"]
    private static let headerKeyWords: Set<String> = ["code", "name", "credit", "credits", "hours", "hour", "pre-requisite",
        "prerequisite", "requisite", "offering", "dept", "department", "categories", "category"]

    /// "Course Code   Course Name   Credit Hours   Pre-requisite" and the pieces of it that wrap onto other lines
    private static func isHeaderLine(_ t: String) -> Bool {
        let words = t.lowercased().replacingOccurrences(of: "|", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
        return !words.isEmpty && words.allSatisfy { headerWords.contains($0) } && words.contains { headerKeyWords.contains($0) }
    }

    private static func rows(of b: Block) -> (rows: [RawRow], totals: [PrintedTotal]) {
        var isPlan = false
        if case .plan = b.kind { isPlan = true }
        var anchors: [(Line, Int)] = []
        var orphans: [Line] = []
        var totals: [PrintedTotal] = []
        for L in b.lines {
            let txt = L.text.trimmingCharacters(in: .whitespaces)
            let low = txt.lowercased()
            if low.hasPrefix("total") {
                if let n = trailingNumber(txt) { totals.append(PrintedTotal(label: low, value: n)) }
                continue
            }
            if isHeaderLine(txt) { continue }
            var ci: Int? = nil
            for (i, c) in L.cells.enumerated() where i >= 1 && isCredit(c.text) { ci = i; break }
            if let k = ci { anchors.append((L, k)) }
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
            var r = Row(page: L.page, y: L.y, credit: toCredit(c[ci].text))
            if hasCode { r.code = [(L.y, c[0].text)] }
            if ni < ci { r.name = [(L.y, c[ni..<ci].map { $0.text }.joined(separator: " "))] }
            if isPlan, ci + 1 < c.count { r.pre = [(L.y, c[(ci + 1)...].map { $0.text }.joined(separator: " "))] }
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
                if best < 0 || bestD > rowReach { continue }
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
        func join(_ p: [(CGFloat, String)]) -> String { p.sorted { $0.0 > $1.0 }.map { $0.1 }.joined(separator: " ") }
        let raw = rs.map { RawRow(code: join($0.code), name: cleanName(join($0.name)), credit: $0.credit, pre: join($0.pre)) }
        return (raw, totals)
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

    // ---- 4. tokens -> plan, and the check against the PDF's own totals ----
    private struct SemAcc {
        var year: Int; var sem: Int; var courses: [PlanCourse]
        var expLocal: Double?; var expIntl: Double?; var nTotals: Int
    }
    private struct Candidate {
        var plan: StudyPlan
        var hard: [String]          // totals that do not add up: something was misread
        var soft: [String]          // category sums that do not add up
        var courseCount: Int
        var score: Int { hard.count * 10 + soft.count }
    }

    private static func localSum(_ cs: [PlanCourse]) -> Double { cs.filter { $0.audience != "international" }.reduce(0) { $0 + $1.credits } }
    private static func intlSum(_ cs: [PlanCourse]) -> Double { cs.filter { $0.audience != "local" }.reduce(0) { $0 + $1.credits } }

    private static func interpret(_ tokens: [Tok]) -> Candidate? {
        if tokens.isEmpty { return nil }
        let parsed = sections(buildLines(tokens))

        // which category each subject belongs to (from the course lists)
        var catalog: [String: String] = [:]
        for b in parsed.blocks {
            guard case .cat(let cat) = b.kind else { continue }
            for r in rows(of: b).rows {
                let code = r.code.isEmpty ? "" : normCode(r.code)
                let placeholder = code.isEmpty || code.contains("XXXX")
                catalog[(placeholder ? r.name : code).lowercased()] = cat
                catalog[r.name.lowercased()] = cat
            }
        }

        // semesters (a semester whose table runs over two pages, or is repeated, is merged)
        var accs: [Int: SemAcc] = [:]
        for b in parsed.blocks {
            guard case .plan(let y, let s) = b.kind else { continue }
            let (rs, totals) = rows(of: b)
            var expLocal: Double? = nil, expIntl: Double? = nil
            for t in totals {
                let intl = t.label.contains("international"), loc = t.label.contains("local")
                if intl && !loc { expIntl = t.value }
                else if loc && !intl { expLocal = t.value }
                else {                                  // "Total Credits (Local/International)": one number for both
                    if expLocal == nil { expLocal = t.value }
                    if expIntl == nil { expIntl = t.value }
                }
            }
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
                var pre = r.pre.trimmingCharacters(in: .whitespaces)
                if pre.isEmpty || has("^[-\u{2013}\u{2014}\\s]+$", pre) { pre = "-" }
                courses.append(PlanCourse(code: code, name: name, credits: r.credit, prereq: pre, category: cat ?? "Other",
                                          audience: audience, year: y, sem: s))
            }
            let key = y * 10 + s
            if var a = accs[key] {
                a.courses += courses
                if a.expLocal == nil { a.expLocal = expLocal }
                if a.expIntl == nil { a.expIntl = expIntl }
                a.nTotals += totals.count
                accs[key] = a
            } else {
                accs[key] = SemAcc(year: y, sem: s, courses: courses, expLocal: expLocal, expIntl: expIntl, nTotals: totals.count)
            }
        }
        let accList = accs.keys.sorted().compactMap { accs[$0] }
        let allCourses = accList.flatMap { $0.courses }
        guard allCourses.count >= 3 else { return nil }

        // the checks
        var hard: [String] = [], soft: [String] = []
        for a in accList {
            let label = "Year \(a.year), Semester \(a.sem)"
            if a.nTotals > 2 { hard.append("\(label): more than one semester seems to be merged together.") }
            if let e = a.expLocal, abs(localSum(a.courses) - e) > 1e-6 {
                hard.append("\(label): read \(num(localSum(a.courses))) credits, the PDF says \(num(e)).")
            } else if let e = a.expIntl, abs(intlSum(a.courses) - e) > 1e-6 {
                hard.append("\(label) (international): read \(num(intlSum(a.courses))) credits, the PDF says \(num(e)).")
            }
        }
        if let g = parsed.gradLocal, abs(localSum(allCourses) - g) > 1e-6 {
            hard.append("All semesters add up to \(num(localSum(allCourses))) credits, the PDF says \(num(g)).")
        }
        let reqSum = parsed.reqs.reduce(0) { $0 + $1.hours }
        if !parsed.reqs.isEmpty, let t = parsed.total, abs(reqSum - t) > 1e-6 {
            hard.append("The credit-hour table on the first page was not read correctly.")
        } else if !parsed.reqs.isEmpty {
            for r in parsed.reqs {
                let got = allCourses.filter { $0.category == r.category && $0.audience != "international" }.reduce(0) { $0 + $1.credits }
                if abs(got - r.hours) > 1e-6 {
                    soft.append("\(r.category): subjects add up to \(num(got)) credits, the PDF says \(num(r.hours)).")
                }
            }
        }

        var requirements = parsed.reqs
        var totalRequired = parsed.total ?? 0
        if requirements.isEmpty {         // no credit-hour table found: use what the plan itself adds up to
            var sums: [String: Double] = [:]
            for c in allCourses where c.audience != "international" { sums[c.category, default: 0] += c.credits }
            requirements = sums.keys.sorted().map { PlanRequirement(category: $0, hours: sums[$0] ?? 0) }
        }
        if totalRequired <= 0 { totalRequired = requirements.reduce(0) { $0 + $1.hours } }
        let sems = accList.map {
            PlanSemester(year: $0.year, sem: $0.sem, recommended: $0.expLocal, recommendedIntl: $0.expIntl, courses: $0.courses)
        }
        let plan = StudyPlan(title: parsed.title.isEmpty ? "Study plan" : parsed.title, totalRequired: totalRequired,
                             requirements: requirements, semesters: sems, warnings: nil)
        return Candidate(plan: plan, hard: hard, soft: soft, courseCount: allCourses.count)
    }

    private static func better(_ a: Candidate?, _ b: Candidate?) -> Candidate? {
        guard let x = a else { return b }
        guard let y = b else { return x }
        if y.score != x.score { return y.score < x.score ? y : x }
        return y.courseCount > x.courseCount ? y : x
    }

    private static func finish(_ c: Candidate) -> StudyPlan {
        var p = c.plan
        let all = c.hard + c.soft
        if all.isEmpty {
            p.warnings = nil
        } else {
            var shown = Array(all.prefix(4))
            if all.count > 4 { shown.append("…and \(all.count - 4) more.") }
            p.warnings = shown
        }
        return p
    }

    // ---- where the tokens come from ----

    /// The PDF's text layer. Every character is asked for as a selection: the selection hands over the character AND its
    /// box together, so the two can never drift apart (pairing page.string with characterBounds(at:) by index can).
    private static func textTokens(of page: PDFPage, index p: Int) -> [Tok] {
        var out: [Tok] = []
        let n = page.numberOfCharacters
        if n <= 0 { return out }
        for i in 0..<n {
            guard let sel = page.selection(for: NSRange(location: i, length: 1)),
                  let s = sel.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let r = sel.bounds(for: page)
            if r.width <= 0 || r.height <= 0 { continue }
            out.append(Tok(page: p, x0: r.minX, x1: r.maxX, y: r.midY, h: r.height, text: s, isChar: true))
        }
        return out
    }

    /// The page drawn as a picture (3x), for text recognition
    private static func render(_ page: PDFPage, box: CGRect, scale: CGFloat) -> CGImage? {
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: cg)
        }
        return image.cgImage
    }

    /// Whitens the table's ruling lines (any straight dark run longer than a few letters, horizontal or vertical).
    /// Letters touching a rule are otherwise read as "|", "l" or "I" and cells get glued together or cut apart.
    private static func eraseRules(_ img: CGImage, minRun: Int = 60) -> CGImage {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return img }
        var src = [UInt8](repeating: 255, count: w * h)
        let drawn = src.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !drawn { return img }
        var out = src
        let dark: UInt8 = 200
        for x in 0..<w {                                   // vertical runs
            var run = 0
            for y in 0...h {
                if y < h, src[y * w + x] < dark { run += 1 }
                else {
                    if run >= minRun { for k in (y - run)..<y { out[k * w + x] = 255 } }
                    run = 0
                }
            }
        }
        for y in 0..<h {                                   // horizontal runs
            var run = 0
            let base = y * w
            for x in 0...w {
                if x < w, src[base + x] < dark { run += 1 }
                else {
                    if run >= minRun { for k in (x - run)..<x { out[base + k] = 255 } }
                    run = 0
                }
            }
        }
        let made: CGImage? = out.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        return made ?? img
    }

    /// Words with their boxes from Vision (positions come back normalised, origin bottom-left, like PDF space)
    private static func recognize(_ image: CGImage, page: Int, width: CGFloat, height: CGFloat) -> [Tok] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false          // codes and numbers must not be "corrected" into words
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        var out: [Tok] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let str = cand.string
            var i = str.startIndex
            while i < str.endIndex {
                while i < str.endIndex, str[i] == " " { i = str.index(after: i) }
                let start = i
                while i < str.endIndex, str[i] != " " { i = str.index(after: i) }
                if start == i { break }
                // table borders are sometimes read as "|" glued to a word
                let word = String(str[start..<i]).trimmingCharacters(in: CharacterSet(charactersIn: "|_"))
                if word.isEmpty { continue }
                guard let box = try? cand.boundingBox(for: start..<i) else { continue }
                let r = box.boundingBox
                out.append(Tok(page: page, x0: r.minX * width, x1: r.maxX * width, y: r.midY * height,
                               h: r.height * height, text: word, isChar: false))
            }
        }
        return out
    }

    // ---- 5. everything together ----
    @MainActor
    static func read(_ url: URL, progress: ((String) -> Void)? = nil) async -> StudyPlan? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }

        // first try: the PDF's own text layer
        var toks: [Tok] = []
        for p in 0..<doc.pageCount {
            if let page = doc.page(at: p) { toks += textTokens(of: page, index: p) }
            await Task.yield()                           // keep the spinner moving
        }
        var best = interpret(toks)
        if let b = best, b.score == 0 { return finish(b) }

        // the numbers did not add up (or there was no usable text, e.g. a scan): read the pages as pictures instead
        progress?("Double-checking with text recognition…")
        var ocr: [Tok] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let box = page.bounds(for: .cropBox)
            guard box.width > 0, box.height > 0, let raw = render(page, box: box, scale: 3) else { continue }
            let image = eraseRules(raw)
            let w = box.width, h = box.height
            let words = await Task.detached(priority: .userInitiated) {
                StudyPlanReader.recognize(image, page: p, width: w, height: h)
            }.value
            ocr += words
        }
        best = better(best, interpret(ocr))
        return best.map { finish($0) }
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

    // v2: plans saved by the earlier reader could be misread (missing or mixed-up semesters), so they are not loaded any more
    private let planKey = "studyplan.plan.v2", takenKey = "studyplan.taken.v1"

    init() {
        UserDefaults.standard.removeObject(forKey: "studyplan.plan.v1")
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
    /// The load the PDF prints for the semester ("Total Credits"), for the selected student type
    func recommended(_ s: PlanSemester) -> Double {
        let r = student == .international ? (s.recommendedIntl ?? s.recommended) : s.recommended
        return r ?? semesterPlanned(s)
    }

    /// Complete when the credits taken reach the recommended load of the semester (as in the Excel tracker)
    func status(_ s: PlanSemester) -> Status {
        let t = semesterTaken(s)
        if t <= 0 { return .notStarted }
        return t >= recommended(s) - 1e-9 ? .complete : .progress
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
    @State private var busyText = "Reading…"
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
        .overlay { if busy { ProgressView(busyText).padding(20).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    private func load(_ url: URL) {
        busyText = "Reading…"
        busy = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            // PDFKit reading stays on the main actor; yield once so the spinner shows
            await Task.yield()
            let plan = await StudyPlanReader.read(url) { text in busyText = text }
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

    /// Shown when the subjects read from the PDF do not add up to the totals printed in the same PDF
    private func warningCard(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                Text("Check this against your PDF").font(Theme.font(.footnote.weight(.semibold))).foregroundStyle(Theme.txt)
            }
            Text("Some numbers read from the PDF don't match the totals it prints, so a subject may be missing or wrong:")
                .font(Theme.read(.caption)).foregroundStyle(Theme.muted)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• " + item).font(Theme.read(.caption)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func content(_ plan: StudyPlan) -> some View {
        if let w = plan.warnings, !w.isEmpty { warningCard(w) }

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
                        Text("\(fmt(store.semesterTaken(s))) / \(fmt(store.recommended(s))) credits")
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

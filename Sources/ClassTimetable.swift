import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Class Timetable (Others > Academic Tools > Class Timetable)
//
// Reads the IIUM "Course Registration Confirmation Slip" PDF on the phone (nothing is sent anywhere):
//   Course  Sec Sta Title                          Chr Day   Time             Venue
//   BICS 1306  4  R Digital & Embedded Systems      3  M-W   10.00 - 11.20 AM ICT LT 1 LEVEL 4D
// and draws the week. The same data feeds the Class Timetable widget (App Group file).

enum TimetableParser {
    private static let dayTok = "(?:MON|TUE|WED|THU|FRI|SAT|SUN|(?:TH|M|T|W|F|S)(?:-(?:TH|M|T|W|F|S))*)"
    private static let timeTok = "\\d{1,2}(?:[.:]\\d{2})?"

    /// Reads the PDF two ways and keeps the one that finds more subjects: rows rebuilt from where each piece of text sits
    /// on the page (reliable for tables), and PDFKit's plain text. `text` is both, so it can be copied when something is off.
    static func read(_ url: URL) -> (data: TimetableData?, text: String) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return (nil, "") }
        var plain = ""
        for i in 0..<doc.pageCount { plain += (doc.page(at: i)?.string ?? "") + "\n" }
        let rows = rowsText(doc)
        let text = "ROWS BY POSITION\n" + rows + "\n\nPLAIN TEXT\n" + plain
        let candidates = [parse(text: rows), parse(text: plain)].compactMap { $0 }
        let best = candidates.max { Set($0.classes.map { $0.code }).count < Set($1.classes.map { $0.code }).count }
        return (best, text)
    }

    /// Text pieces grouped into table rows by their height on the page, left to right inside a row
    private static func rowsText(_ doc: PDFDocument) -> String {
        var out = ""
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let sel = page.selection(for: page.bounds(for: .cropBox)) else { continue }
            var pieces: [(s: String, r: CGRect)] = []
            for l in sel.selectionsByLine() {
                let s = (l.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { pieces.append((s, l.bounds(for: page))) }
            }
            pieces.sort { $0.r.midY > $1.r.midY }   // PDF coordinates start at the bottom, so the top row has the biggest y
            var rows: [[(s: String, r: CGRect)]] = []
            for p in pieces {
                if let first = rows.last?.first, abs(first.r.midY - p.r.midY) < 4 { rows[rows.count - 1].append(p) }
                else { rows.append([p]) }
            }
            for r in rows { out += r.sorted { $0.r.minX < $1.r.minX }.map { $0.s }.joined(separator: " ") + "\n" }
        }
        return out
    }

    static func parse(text raw: String) -> TimetableData? {
        let text = raw.replacingOccurrences(of: "\r", with: "")
        var session = "", semester = ""
        if let m = match(#"Session\s*:\s*(\d{4})\s*/\s*(\d{4})\s+Semester\s*:\s*(\d+)"#, in: text, options: .caseInsensitive) {
            session = group(m, 1, text) + "/" + group(m, 2, text)
            semester = group(m, 3, text)
        }

        // One record per course. PDFKit does not always put a table row on its own line (one row can run into the
        // next), so the text is flattened and cut at every "<code> <section> <status>" ("BICS 1306 4 R") instead,
        // from the table header to the "Total" line. A second day for the same course stays inside its record.
        var flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if let h = flat.range(of: "Venue", options: .caseInsensitive) { flat = String(flat[h.upperBound...]) }
        if let t = flat.range(of: #"\bTotal\b"#, options: [.regularExpression, .caseInsensitive]) { flat = String(flat[..<t.lowerBound]) }
        var records: [String] = []
        if let re = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Z]{3,5}\s?\d{4}\s+\d+\s+[A-Z]\s"#) {
            let ns = flat as NSString
            let starts = re.matches(in: flat, range: NSRange(location: 0, length: ns.length)).map { $0.range.location }
            for (i, s) in starts.enumerated() {
                let e = i + 1 < starts.count ? starts[i + 1] : ns.length
                records.append(ns.substring(with: NSRange(location: s, length: e - s)).trimmingCharacters(in: .whitespaces))
            }
        }
        var out: [TimetableClass] = []
        for var r in records {
            r = r.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let head = #"^([A-Z]{3,5})\s?(\d{4})\s+(\d+)\s+[A-Z]\s+(.+?)\s+(\.\d+|\d+(?:\.\d+)?)\s+(?="# + dayTok + #"\s+\d)"#
            guard let h = match(head, in: r) else { continue }
            let code = group(h, 1, r) + " " + group(h, 2, r)
            let section = Int(group(h, 3, r)) ?? 0
            let title = group(h, 4, r)
            let credit = Double(group(h, 5, r)) ?? 0
            let rest = String(r[Range(h.range, in: r)!.upperBound...])

            let slot = #"(?<![A-Za-z])("# + dayTok + #")\s+("# + timeTok + #")\s*-\s*("# + timeTok + #")\s*(AM|PM)"#
            guard let re = try? NSRegularExpression(pattern: slot) else { continue }
            let ns = rest as NSString
            let ms = re.matches(in: rest, range: NSRange(location: 0, length: ns.length))
            for (i, m) in ms.enumerated() {
                let days = dayNumbers(ns.substring(with: m.range(at: 1)))
                guard let t = times(ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 3)), ns.substring(with: m.range(at: 4))) else { continue }
                let from = m.range.location + m.range.length
                let to = i + 1 < ms.count ? ms[i + 1].range.location : ns.length
                let venue = ns.substring(with: NSRange(location: from, length: max(0, to - from))).trimmingCharacters(in: .whitespaces)
                for d in days {
                    let c = TimetableClass(code: code, section: section, title: title, credit: credit, day: d,
                                           startMin: t.0, endMin: t.1, venue: venue)
                    if !out.contains(where: { $0.id == c.id }) { out.append(c) }
                }
            }
        }
        guard !out.isEmpty else { return nil }
        out.sort { ($0.day, $0.startMin) < ($1.day, $1.startMin) }
        return TimetableData(session: session, semester: semester, classes: out, updated: Date())
    }

    /// "M-W" -> [1, 3], "T-TH" -> [2, 4], "WED" -> [3]
    private static func dayNumbers(_ s: String) -> [Int] {
        let names = ["MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6, "SUN": 7]
        let letters = ["M": 1, "T": 2, "W": 3, "TH": 4, "F": 5, "S": 6]
        if let n = names[s] { return [n] }
        return s.split(separator: "-").compactMap { letters[String($0)] }
    }

    /// "10.00", "11.20", "AM" -> minutes. AM / PM is written once, after the end time; a start that would then fall after
    /// the end ("11.30 - 12.50 PM") is in the morning.
    private static func times(_ a: String, _ b: String, _ ap: String) -> (Int, Int)? {
        func hm(_ s: String) -> (Int, Int)? {
            let p = s.split(whereSeparator: { $0 == "." || $0 == ":" })
            guard let h = Int(p[0]) else { return nil }
            return (h, p.count > 1 ? Int(p[1]) ?? 0 : 0)
        }
        guard let s = hm(a), let e = hm(b) else { return nil }
        let pm = ap.uppercased() == "PM"
        func mins(_ x: (Int, Int), _ pm: Bool) -> Int { ((x.0 % 12) + (pm ? 12 : 0)) * 60 + x.1 }
        let end = mins(e, pm)
        var start = mins(s, pm)
        if start >= end { start = mins(s, !pm) }
        guard start < end else { return nil }
        return (start, end)
    }

    private static func match(_ pattern: String, in s: String, options: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
    }
}

@MainActor
final class TimetableManager: ObservableObject {
    static let shared = TimetableManager()
    private static let key = "timetable.v1"

    @Published private(set) var data: TimetableData?
    /// What was read from the last PDF, so it can be copied when a class comes out wrong
    @Published private(set) var lastText = UserDefaults.standard.string(forKey: "timetable.text") ?? ""

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let t = try? JSONDecoder().decode(TimetableData.self, from: d) { data = t }
        else { data = TimetableStore.load() }
    }

    func replace(with t: TimetableData, text: String = "") {
        data = t
        lastText = text
        UserDefaults.standard.set(text, forKey: "timetable.text")
        if let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: Self.key) }
        TimetableStore.save(t)
    }

    /// An edit made by hand (the text read from the PDF is kept)
    func update(_ t: TimetableData) {
        data = t
        if let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: Self.key) }
        TimetableStore.save(t)
    }

    func remove() {
        data = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
        TimetableStore.clear()
    }
}

// MARK: - Screen

struct TimetableView: View {
    @ObservedObject private var store = TimetableManager.shared
    @ObservedObject private var widgetSettings = TimetableWidgetSettingsModel.shared
    @EnvironmentObject var app: AppState
    @AppStorage(DevMode.key) private var devOn = false
    @State private var importing = false
    @State private var failed = false
    @State private var confirmRemove = false
    @State private var selected: TimetableClass?
    @State private var editing: TimetableEditTarget?

    private var dev: Bool { devOn && DevMode.allowed(app.site?.fullname) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let t = store.data { content(t) } else { emptyState }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Class Timetable")
        .navigationBarTitleDisplayMode(.inline)
        .notebookBack()
        .toolbar {
            if store.data != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { editing = TimetableEditTarget(original: nil) } label: { Label("Add a class", systemImage: "plus") }
                        Button { importing = true } label: { Label("Upload a new PDF", systemImage: "arrow.up.doc") }
                        if dev { Button { UIPasteboard.general.string = store.lastText } label: { Label("Copy text read from PDF", systemImage: "doc.on.doc") } }
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove timetable", systemImage: "trash") }
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
        } message: { Text("It should be the Course Registration Confirmation Slip, with the table of courses, days, times and venues." + (dev ? " The text that was read has been copied." : "")) }
        .sheet(item: $selected) { c in
            TimetableDetail(c: c, onEdit: {
                selected = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = TimetableEditTarget(original: c) }
            })
        }
        .sheet(item: $editing) { target in
            TimetableEditor(original: target.original, siblings: siblings(of: target.original),
                            onSave: { c, others in save(c, original: target.original, others: others) },
                            onDelete: { others in delete(target.original, others: others) })
        }
        .confirmationDialog("Remove the timetable?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.remove() }
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let r = TimetableParser.read(url)
        if let t = r.data { store.replace(with: t, text: r.text) } else { if dev { UIPasteboard.general.string = r.text }; failed = true }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Your classes, one glance").font(Theme.font(.title3.weight(.semibold))).foregroundStyle(Theme.txt)
            Text("Upload your Course Registration Confirmation Slip (PDF). It is read on your phone, nothing is sent anywhere. Then add the Class Timetable widget to your home screen.")
                .font(Theme.read(.subheadline)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button { importing = true } label: {
                Label("Choose PDF", systemImage: "arrow.up.doc").font(Theme.font(.subheadline.weight(.semibold)))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
            }
            Button { editing = TimetableEditTarget(original: nil) } label: {
                Text("or add your classes by hand").font(Theme.font(.subheadline.weight(.semibold))).foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 8)
    }

    @ViewBuilder private func content(_ t: TimetableData) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.txt)
                Text("\(t.codes.count) subjects · \(creditText(t.credits)) credits").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
        TimelineView(.periodic(from: Date(), by: 30)) { ctx in   // so the water level and "today" stay right
            TimetableGrid(data: t, text: Theme.txt, muted: Theme.muted, line: Theme.line, accent: Theme.accent,
                          onSelect: { selected = $0 }, now: ctx.date, animated: true, textScale: 0.9,
                          showCards: widgetSettings.settings.showCards, timeOnTop: widgetSettings.settings.timeOnTop)
        }
        .padding(5)
            .glowCard()

        Text("To add the widget: touch and hold the home screen, tap +, search iTa'leem and pick Class Timetable.")
            .font(Theme.font(.caption)).foregroundColor(Theme.muted).padding(.horizontal, 4)
    }

    private func subjectRow(_ t: TimetableData, _ code: String, last: Bool) -> some View {
        let mine = t.classes.filter { $0.code == code }
        // the same time and venue on several days is one line: "Mon, Wed · 10:00–11:20 AM"
        var slots: [(days: [Int], c: TimetableClass)] = []
        for c in mine {
            if let i = slots.firstIndex(where: { $0.c.startMin == c.startMin && $0.c.endMin == c.endMin && $0.c.venue == c.venue }) { slots[i].days.append(c.day) }
            else { slots.append(([c.day], c)) }
        }
        return HStack(alignment: .top, spacing: 12) {
            Capsule().fill(Theme.accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(code).font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.txt)
                Text(TimetableText.normalCase(mine[0].title)).font(Theme.font(.footnote)).foregroundColor(Theme.txt).lineLimit(2)
                Text("Section \(mine[0].section) · \(creditText(mine[0].credit)) credit\(mine[0].credit == 1 ? "" : "s")")
                    .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                ForEach(Array(slots.enumerated()), id: \.offset) { _, s in
                    let days = s.days.sorted().map { TimetableText.dayNames[$0 - 1] }.joined(separator: ", ")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "clock").font(.system(size: 10)).foregroundColor(Theme.accent).frame(width: 12)
                            Text(days + " · " + s.c.range).font(Theme.font(.caption)).foregroundColor(Theme.txt)
                        }
                        // the venue is never cut: it wraps onto as many rows as it needs
                        if !s.c.venue.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "mappin.and.ellipse").font(.system(size: 10)).foregroundColor(Theme.accent).frame(width: 12)
                                Text(s.c.venue).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.line).frame(height: last ? 0 : 1), alignment: .bottom)
    }

    private func creditText(_ c: Double) -> String { c == c.rounded() ? "\(Int(c))" : String(format: "%.1f", c) }

    // MARK: editing by hand

    /// The same subject at the same time and place on other days (an edit can apply to all of them)
    private func siblings(of o: TimetableClass?) -> [TimetableClass] {
        guard let o, let t = store.data else { return [] }
        return t.classes.filter { $0.id != o.id && $0.code == o.code && $0.section == o.section
            && $0.startMin == o.startMin && $0.endMin == o.endMin && $0.venue == o.venue }
    }

    private func finish(_ t: TimetableData) {
        var t = t
        var seen = Set<String>()
        t.classes = t.classes.filter { seen.insert($0.id).inserted }   // no two identical boxes
        t.updated = Date()
        if t.classes.isEmpty { store.remove() } else { store.update(t) }
    }

    private func save(_ c: TimetableClass, original: TimetableClass?, others: Bool) {
        var t = store.data ?? TimetableData(session: "", semester: "", classes: [], updated: Date())
        if let o = original, let i = t.classes.firstIndex(where: { $0.id == o.id }) {
            if others {
                for j in t.classes.indices where j != i && siblings(of: o).contains(where: { $0.id == t.classes[j].id }) {
                    var s = c
                    s.day = t.classes[j].day
                    t.classes[j] = s
                }
            }
            t.classes[i] = c
        } else {
            t.classes.append(c)
        }
        finish(t)
    }

    private func delete(_ original: TimetableClass?, others: Bool) {
        guard let o = original, var t = store.data else { return }
        let gone = Set([o.id] + (others ? siblings(of: o).map { $0.id } : []))
        t.classes.removeAll { gone.contains($0.id) }
        finish(t)
    }
}

// MARK: - Editor

private struct TimetableEditTarget: Identifiable {
    let id = UUID()
    var original: TimetableClass?     // nil = a new class
}

private func timeDate(_ m: Int) -> Date {
    Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
}

private func creditString(_ c: Double) -> String { c == c.rounded() ? "\(Int(c))" : String(format: "%.1f", c) }

private struct TimetableEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: TimetableClass?
    let siblings: [TimetableClass]
    let onSave: (TimetableClass, Bool) -> Void
    let onDelete: (Bool) -> Void

    @State private var code: String
    @State private var title: String
    @State private var venue: String
    @State private var section: String
    @State private var credit: String
    @State private var day: Int
    @State private var start: Date
    @State private var end: Date
    @State private var withOthers = true
    @State private var confirmDelete = false

    init(original: TimetableClass?, siblings: [TimetableClass],
         onSave: @escaping (TimetableClass, Bool) -> Void, onDelete: @escaping (Bool) -> Void) {
        self.original = original
        self.siblings = siblings
        self.onSave = onSave
        self.onDelete = onDelete
        _code = State(initialValue: original?.code ?? "")
        _title = State(initialValue: original?.title ?? "")
        _venue = State(initialValue: original?.venue ?? "")
        _section = State(initialValue: original.map { String($0.section) } ?? "1")
        _credit = State(initialValue: original.map { creditString($0.credit) } ?? "3")
        _day = State(initialValue: original?.day ?? 1)
        _start = State(initialValue: timeDate(original?.startMin ?? 540))
        _end = State(initialValue: timeDate(original?.endMin ?? 620))
    }

    private func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !clean(code).isEmpty && TimetableText.minutes(end) > TimetableText.minutes(start) }
    private var othersDays: String { siblings.map { TimetableText.dayNames[$0.day - 1] }.sorted().joined(separator: ", ") }

    private func built() -> TimetableClass {
        let c = clean(code).uppercased()
        let t = clean(title)
        return TimetableClass(code: c, section: Int(clean(section)) ?? original?.section ?? 1,
                              title: t.isEmpty ? c : t,
                              credit: Double(clean(credit).replacingOccurrences(of: ",", with: ".")) ?? original?.credit ?? 0,
                              day: day, startMin: TimetableText.minutes(start), endMin: TimetableText.minutes(end),
                              venue: clean(venue))
    }

    private func field(_ label: String, _ text: Binding<String>, caps: Bool = false, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Theme.font(.caption)).foregroundColor(Theme.muted)
            TextField("", text: text)
                .textInputAutocapitalization(caps ? TextInputAutocapitalization.characters : TextInputAutocapitalization.words).autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(10).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Subject code (e.g. BICS 1306)", $code, caps: true)
                    field("Subject name", $title)
                    field("Venue", $venue, caps: true)
                    HStack(spacing: 12) {
                        field("Section", $section, keyboard: .numberPad)
                        field("Credit hours", $credit, keyboard: .decimalPad)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DAY").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                        Picker("Day", selection: $day) {
                            ForEach(1...7, id: \.self) { d in Text(TimetableText.dayNames[d - 1]).tag(d) }
                        }
                        .pickerStyle(.segmented)
                    }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("STARTS").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                            DatePicker("", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ENDS").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                            DatePicker("", selection: $end, displayedComponents: .hourAndMinute).labelsHidden()
                        }
                        Spacer(minLength: 0)
                    }
                    if TimetableText.minutes(end) <= TimetableText.minutes(start) {
                        Text("The end time has to be after the start time.")
                            .font(Theme.font(.caption)).foregroundColor(.red.opacity(0.85))
                    }
                    if !siblings.isEmpty {
                        Toggle(isOn: $withOthers) {
                            Text("Also apply to the same class on \(othersDays)").font(Theme.font(.subheadline)).foregroundColor(Theme.txt)
                        }
                        .tint(Theme.accent)
                    }
                    if original != nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete this class", systemImage: "trash").font(Theme.font(.subheadline.weight(.semibold)))
                        }
                        .padding(.top, 6)
                    }
                    Text("Changes are kept on this phone and shown in the widget. Uploading a new PDF replaces them.")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(original == nil ? "Add class" : "Edit class")
            .navigationBarTitleDisplayMode(.inline)
            .topNavFade()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(built(), withOthers && !siblings.isEmpty); dismiss() }
                        .disabled(!valid)
                }
            }
            .confirmationDialog("Delete this class?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete(withOthers && !siblings.isEmpty); dismiss() }
            } message: {
                Text(!siblings.isEmpty && withOthers ? "It is also removed on \(othersDays)." : "It is removed from the timetable and the widget.")
            }
        }
    }
}

/// A subject from the week, enlarged
private struct TimetableDetail: View {
    let c: TimetableClass
    var onEdit: () -> Void = {}
    @State private var height: CGFloat = 320
    private let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private func row(_ icon: String, _ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(Theme.accent).frame(width: 20)
            Text(s).font(Theme.font(.body)).foregroundColor(Theme.txt).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.code).font(Theme.font(.title.weight(.bold))).foregroundColor(Theme.txt)
                Text(c.displayTitle).font(Theme.font(.headline)).foregroundColor(Theme.txt)
            }
            .padding(.bottom, 4)
            row("calendar", days[max(0, min(6, c.day - 1))])
            row("clock", c.range)
            if !c.venue.isEmpty { row("mappin.and.ellipse", c.venue) }
            row("person.2", "Section \(c.section) · \(c.credit == c.credit.rounded() ? "\(Int(c.credit))" : String(format: "%.1f", c.credit)) credit\(c.credit == 1 ? "" : "s")")
            Button { onEdit() } label: {
                Label("Edit this class", systemImage: "pencil").font(Theme.font(.subheadline.weight(.semibold)))
                    .foregroundColor(Theme.accent)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 12)
        .background(GeometryReader { g in Color.clear.preference(key: TimetableSheetHeight.self, value: g.size.height) })
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg.ignoresSafeArea())
        .onPreferenceChange(TimetableSheetHeight.self) { height = $0 }
        .presentationDetents([.height(height)])   // the sheet is as tall as its content, no empty space under it
    }
}

private struct TimetableSheetHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Widget Settings (Others > App Preferences > Widget Settings)

@MainActor
final class TimetableWidgetSettingsModel: ObservableObject {
    static let shared = TimetableWidgetSettingsModel()

    @Published var settings: TimetableWidgetSettings {
        didSet {
            if settings != oldValue {
                TimetableWidgetSettingsStore.save(settings)
            }
        }
    }

    private init() {
        self.settings = TimetableWidgetSettingsStore.load()
    }
}

struct WidgetSettingsView: View {
    @ObservedObject private var model = TimetableWidgetSettingsModel.shared
    @AppStorage("ui.preferOldCourseCards") private var preferOldCourseCards = false

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(ThemeStore.shared.theme.isNotebook ? Theme.font(.subheadline) : Theme.font(.footnote).weight(.semibold))
            .foregroundColor(Theme.muted)
            .textCase(.uppercase).padding(.horizontal, ThemeStore.shared.theme.isNotebook ? 0 : 6).padding(.bottom, -8)
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>, showLine: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundColor(Theme.txt).fontWeight(.semibold).textGlow(radius: 3)
                Text(subtitle)
                    .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(ThemeStore.shared.theme.isNotebook ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RowDivider().frame(height: showLine ? 1 : 0).opacity(showLine ? 1 : 0), alignment: .bottom)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionTitle("Courses Tab")
                VStack(spacing: 0) {
                    toggleRow(
                        title: "Prefer old course cards",
                        subtitle: "Use the original main page course card layout and titles.",
                        isOn: $preferOldCourseCards,
                        showLine: false
                    )
                }
                .glowCard()

                sectionTitle("Timetable Widget")
                VStack(spacing: 0) {
                    toggleRow(
                        title: "Add cards",
                        subtitle: "Display a dark brown card behind each subject in the timetable.",
                        isOn: $model.settings.showCards,
                        showLine: true
                    )
                    toggleRow(
                        title: "Show class time on top",
                        subtitle: "Place the class time badge above the course code instead of at the bottom.",
                        isOn: $model.settings.timeOnTop,
                        showLine: false
                    )
                }
                .glowCard()
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("UI Preference")
        .navigationBarTitleDisplayMode(.inline)
        .notebookBack()
    }
}

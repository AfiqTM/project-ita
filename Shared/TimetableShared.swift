import SwiftUI
import WidgetKit

// Shared by the app AND the widget (project.yml compiles Shared/ into both).
// The app reads the registration slip PDF and writes the result into the App Group; the widget only reads it.
// TimetableGrid is the one drawing of the week (used by the Class Timetable screen and the large widget).

// MARK: - Data

struct TimetableClass: Codable, Identifiable, Hashable {
    var code: String        // "BICS 1306"
    var section: Int
    var title: String
    var credit: Double
    var day: Int            // 1 = Mon ... 7 = Sun
    var startMin: Int       // minutes after midnight
    var endMin: Int
    var venue: String

    var id: String { "\(code)-\(section)-\(day)-\(startMin)" }
    var range: String { TimetableText.range(startMin, endMin) }
    /// "8:30–10:00" without AM / PM (the hour labels on the side say which), so it fits a narrow block
    var shortRange: String { TimetableText.shortRange(startMin, endMin) }
}

struct TimetableData: Codable {
    var session: String     // "2026/2027"
    var semester: String    // "1"
    var classes: [TimetableClass]
    var updated: Date

    var title: String {
        var t = semester.isEmpty ? "Timetable" : "Semester \(semester)"
        if !session.isEmpty { t += ", \(session)" }
        return t
    }
    var codes: [String] { Array(Set(classes.map { $0.code })).sorted() }
    var credits: Double {
        var seen = Set<String>(); var sum = 0.0
        for c in classes where seen.insert(c.code).inserted { sum += c.credit }
        return sum
    }
    /// Only the days that have a class, so the columns that are left get wider (empty days are not drawn)
    var days: [Int] {
        let used = Array(Set(classes.map { $0.day })).sorted()
        return used.isEmpty ? [1, 2, 3, 4, 5] : used
    }
    func palette(_ code: String) -> TimetablePalette { TimetablePalette.all[(codes.firstIndex(of: code) ?? 0) % TimetablePalette.all.count] }

    static let sample = TimetableData(session: "2026/2027", semester: "1", classes: [
        .init(code: "LEED 1301", section: 51, title: "ENGLISH FOR ACADEMIC WRITING", credit: 3, day: 1, startMin: 510, endMin: 600, venue: ""),
        .init(code: "BICS 1306", section: 4, title: "Digital & Embedded Systems", credit: 3, day: 1, startMin: 600, endMin: 680, venue: "ICT LT 1 LEVEL 4D"),
        .init(code: "BICS 2306", section: 5, title: "Software Engineering", credit: 3, day: 1, startMin: 690, endMin: 770, venue: "ICT TL-E5-01 LEVEL 5E"),
        .init(code: "BIIT 2301", section: 4, title: "User Experience Design", credit: 3, day: 1, startMin: 840, endMin: 920, venue: "ICT HCI LAB LEVEL 4C"),
        .init(code: "BICS 2303", section: 3, title: "Intelligent Systems", credit: 3, day: 2, startMin: 600, endMin: 680, venue: "ICT LT 2 LEVEL 4D"),
        .init(code: "BICS 2301", section: 3, title: "Enterprise Networks", credit: 3, day: 2, startMin: 690, endMin: 770, venue: "ICT CISCO LAB LEVEL 4C"),
        .init(code: "CCFM 2061", section: 31, title: "FAMILY MANAGEMENT", credit: 0.5, day: 2, startMin: 1200, endMin: 1320, venue: "KENMS 4.3 LEVEL 4")
    ], updated: Date())
}

enum TimetableText {
    static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// 1 = Mon ... 7 = Sun
    static func weekday(_ d: Date) -> Int { (Calendar.current.component(.weekday, from: d) + 5) % 7 + 1 }
    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func parts(_ m: Int) -> (String, Bool) {
        let h = m / 60, mm = m % 60
        let h12 = h % 12 == 0 ? 12 : h % 12
        return (mm == 0 ? "\(h12):00" : String(format: "%d:%02d", h12, mm), h < 12)
    }
    static func shortRange(_ a: Int, _ b: Int) -> String { "\(parts(a).0)–\(parts(b).0)" }
    /// "8:30–10:00 AM" or "11:30 AM–12:50 PM"
    static func range(_ a: Int, _ b: Int) -> String {
        let (s, sAM) = parts(a), (e, eAM) = parts(b)
        return sAM == eAM ? "\(s)–\(e) \(eAM ? "AM" : "PM")" : "\(s) \(sAM ? "AM" : "PM")–\(e) \(eAM ? "AM" : "PM")"
    }
    static func hour(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 || h == 24 ? "AM" : "PM")" }
}

extension TimetableData {
    /// The first day (today first) that still has classes, and those classes. For today only classes that have not ended.
    func upcoming(from date: Date) -> (offset: Int, classes: [TimetableClass])? {
        let today = TimetableText.weekday(date), now = TimetableText.minutes(date)
        for off in 0..<7 {
            let wd = (today - 1 + off) % 7 + 1
            let list = classes.filter { $0.day == wd && (off > 0 || $0.endMin > now) }.sorted { $0.startMin < $1.startMin }
            if !list.isEmpty { return (off, list) }
        }
        return nil
    }
}

// MARK: - Colours (one per subject, dark tinted card + brighter edge, like the app's cards)

struct TimetablePalette {
    let fill: Color
    let accent: Color

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
    static let all: [TimetablePalette] = [
        .init(fill: c(0.15, 0.20, 0.07), accent: c(0.62, 0.78, 0.27)),   // green
        .init(fill: c(0.05, 0.20, 0.26), accent: c(0.30, 0.72, 0.82)),   // teal
        .init(fill: c(0.13, 0.12, 0.31), accent: c(0.52, 0.48, 0.96)),   // indigo
        .init(fill: c(0.22, 0.10, 0.30), accent: c(0.72, 0.46, 0.92)),   // purple
        .init(fill: c(0.30, 0.07, 0.12), accent: c(0.92, 0.32, 0.42)),   // red
        .init(fill: c(0.26, 0.15, 0.04), accent: c(0.96, 0.62, 0.22)),   // orange
        .init(fill: c(0.07, 0.17, 0.30), accent: c(0.38, 0.62, 0.96)),   // blue
        .init(fill: c(0.28, 0.09, 0.22), accent: c(0.94, 0.42, 0.74))    // pink
    ]
}

// MARK: - Storage (App Group file, same folder as the attendance data)

enum TimetableStore {
    private static var fileURL: URL? { AttendanceStore.groupFile("timetable.json") }

    static func save(_ t: TimetableData) {
        guard let url = fileURL, let d = try? JSONEncoder().encode(t) else { return }
        try? d.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func load() -> TimetableData? {
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TimetableData.self, from: d)
    }
    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - The week

/// Hours shown and how tall each one is. With `compactGaps` an hour with no class is squeezed (for the widget).
private struct TimetableLayout {
    let startHour: Int
    let endHour: Int
    let weights: [Double]
    let cumulative: [Double]
    var total: Double { cumulative.last ?? 1 }

    init(_ data: TimetableData, compactGaps: Bool) {
        let lo = (data.classes.map { $0.startMin }.min() ?? 480) / 60
        let hi = Int((Double(data.classes.map { $0.endMin }.max() ?? 1020) / 60).rounded(.up))
        startHour = lo
        endHour = max(hi, lo + 1)
        var w: [Double] = []
        for h in startHour..<endHour {
            let busy = data.classes.contains { $0.startMin < (h + 1) * 60 && $0.endMin > h * 60 }
            w.append(busy || !compactGaps ? 1 : 0.3)
        }
        weights = w
        var cum: [Double] = [0]
        for x in w { cum.append(cum.last! + x) }
        cumulative = cum
    }

    /// Position in hour units from the top of the grid
    func y(_ minute: Int) -> Double {
        let h = min(max(minute / 60, startHour), endHour)
        if h >= endHour { return total }
        return cumulative[h - startHour] + Double(minute - h * 60) / 60 * weights[h - startHour]
    }
}

struct TimetableGrid: View {
    let data: TimetableData
    /// nil = fit the height the grid is given (widget)
    var hourHeight: CGFloat? = nil
    var compactGaps = false
    var scale: CGFloat = 1
    var text: Color = Color(white: 0.9)
    var muted: Color = Color(white: 0.6)
    var line: Color = Color(white: 0.13)
    var accent: Color = Color(red: 210 / 255, green: 180 / 255, blue: 140 / 255)

    private var headerH: CGFloat { 20 * scale }

    static func height(for data: TimetableData, hourHeight: CGFloat, scale: CGFloat = 1) -> CGFloat {
        20 * scale + CGFloat(TimetableLayout(data, compactGaps: false).total) * hourHeight
    }

    /// Side by side lanes for classes that overlap in time
    private func lanes(_ list: [TimetableClass]) -> [String: (lane: Int, of: Int)] {
        let sorted = list.sorted { $0.startMin < $1.startMin }
        var laneOf: [String: Int] = [:]
        var ends: [Int] = []
        for c in sorted {
            if let i = ends.firstIndex(where: { $0 <= c.startMin }) { ends[i] = c.endMin; laneOf[c.id] = i }
            else { ends.append(c.endMin); laneOf[c.id] = ends.count - 1 }
        }
        var out: [String: (Int, Int)] = [:]
        for c in sorted {
            let group = sorted.filter { $0.startMin < c.endMin && $0.endMin > c.startMin }
            out[c.id] = (laneOf[c.id] ?? 0, (group.compactMap { laneOf[$0.id] }.max() ?? 0) + 1)
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            let lay = TimetableLayout(data, compactGaps: compactGaps)
            let labelW = 30 * scale
            let days = data.days
            let colW = (g.size.width - labelW) / CGFloat(days.count)
            let bodyH = hourHeight.map { $0 * CGFloat(lay.total) } ?? max(g.size.height - headerH, 1)
            let unit = bodyH / CGFloat(lay.total)
            let today = TimetableText.weekday(Date())

            ZStack(alignment: .topLeading) {
                // today's column
                if let ti = days.firstIndex(of: today) {
                    Rectangle().fill(accent.opacity(0.06))
                        .frame(width: colW, height: bodyH)
                        .offset(x: labelW + CGFloat(ti) * colW, y: headerH)
                }
                // day names
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    Text(TimetableText.dayNames[d - 1])
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(d == today ? accent : muted)
                        .frame(width: colW, height: headerH, alignment: .leading)
                        .padding(.leading, 4 * scale)
                        .offset(x: labelW + CGFloat(i) * colW)
                }
                // hour lines and labels
                ForEach(lay.startHour...lay.endHour, id: \.self) { h in
                    let yy = headerH + CGFloat(lay.y(h * 60)) * unit
                    Rectangle().fill(line).frame(width: g.size.width - labelW, height: 0.5)
                        .offset(x: labelW, y: yy)
                    if h < lay.endHour, lay.weights[h - lay.startHour] >= 1 {
                        Text(TimetableText.hour(h)).font(.system(size: 8 * scale)).foregroundColor(muted)
                            .frame(width: labelW - 4 * scale, alignment: .trailing)
                            .offset(y: yy - 5 * scale)
                    }
                }
                // day separators
                ForEach(0..<days.count, id: \.self) { i in
                    Rectangle().fill(line).frame(width: 0.5, height: bodyH)
                        .offset(x: labelW + CGFloat(i) * colW, y: headerH)
                }
                // classes
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    let list = data.classes.filter { $0.day == d }
                    let ln = lanes(list)
                    ForEach(list) { c in
                        let l = ln[c.id] ?? (0, 1)
                        let w = (colW - 2) / CGFloat(l.of)
                        let y0 = headerH + CGFloat(lay.y(c.startMin)) * unit + 0.5
                        let y1 = headerH + CGFloat(lay.y(c.endMin)) * unit - 0.5
                        TimetableBlock(c: c, accent: accent, width: w - 1, height: max(y1 - y0, 4), scale: scale)
                            .offset(x: labelW + CGFloat(i) * colW + 1 + CGFloat(l.lane) * w, y: y0)
                    }
                }
            }
        }
    }
}

/// One class in the week: as many lines as fit (code, title, time, venue)
struct TimetableBlock: View {
    let c: TimetableClass
    let accent: Color   // the app's accent colour (same for every subject)
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat

    var body: some View {
        let lh = 10.5 * scale
        let n = max(0, min(4, Int((height - 5 * scale) / lh)))
        // the venue always gets two rows so a long location is shown in full
        let lines: [(String, Font, Color, Int)] = [
            (c.code, .system(size: 9.5 * scale, weight: .bold), Color.white.opacity(0.95), 1),
            (c.title, .system(size: 8.5 * scale), Color.white.opacity(0.78), 1),
            (c.shortRange, .system(size: 8 * scale), Color.white.opacity(0.6), 1),
            (c.venue, .system(size: 8 * scale), Color.white.opacity(0.6), 2)
        ]
        let shown = Array(lines.prefix(n)).filter { !$0.0.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, l in
                Text(l.0).font(l.1).foregroundColor(l.2).lineLimit(l.3).minimumScaleFactor(l.3 > 1 ? 1 : 0.75)
                    .fixedSize(horizontal: false, vertical: l.3 > 1)
            }
        }
        .padding(.leading, 6 * scale).padding(.top, 3 * scale)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(accent.opacity(0.16))
        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 2.5 * scale) }
        .overlay(RoundedRectangle(cornerRadius: 5 * scale, style: .continuous).strokeBorder(accent.opacity(0.3), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5 * scale, style: .continuous))
    }
}

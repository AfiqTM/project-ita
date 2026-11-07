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

/// One column per day that has a class, the classes of that day stacked in time order.
/// Every box grows to fit its text (nothing is cut), so the grid is as tall as the longest column.
struct TimetableGrid: View {
    let data: TimetableData
    var scale: CGFloat = 1
    var text: Color = Color(white: 0.9)
    var muted: Color = Color(white: 0.6)
    var line: Color = Color(white: 0.13)
    var accent: Color = Color(red: 210 / 255, green: 180 / 255, blue: 140 / 255)
    /// set in the app: a tap on a subject calls this (the widget leaves it nil)
    var onSelect: ((TimetableClass) -> Void)? = nil

    var body: some View {
        let today = TimetableText.weekday(Date())
        HStack(alignment: .top, spacing: 6 * scale) {
            ForEach(data.days, id: \.self) { d in
                VStack(spacing: 6 * scale) {
                    Text(TimetableText.dayNames[d - 1])
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(d == today ? Color.black : muted)
                        .padding(.horizontal, 10 * scale)
                        .frame(height: 18 * scale)
                        .background(d == today ? accent : Color.clear, in: Capsule())
                        .padding(.bottom, 2 * scale)
                    ForEach(data.classes.filter { $0.day == d }.sorted { $0.startMin < $1.startMin }) { c in
                        TimetableBlock(c: c, accent: accent, text: text, muted: muted, scale: scale)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect?(c) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One class in the week: code, title, time and venue, all wrapped in full. Same padding on every side.
struct TimetableBlock: View {
    let c: TimetableClass
    let accent: Color   // the app's accent colour (same for every subject)
    let text: Color
    let muted: Color
    let scale: CGFloat

    /// dark text on the tan box
    private let ink = Color(red: 0.10, green: 0.08, blue: 0.05)

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(c.code).font(.system(size: 10.5 * scale, weight: .bold)).foregroundColor(ink)
            Text(c.title).font(.system(size: 9 * scale, weight: .medium)).foregroundColor(ink)
            Text(c.shortRange).font(.system(size: 9 * scale, weight: .medium)).foregroundColor(ink)
            if !c.venue.isEmpty {
                Text(c.venue).font(.system(size: 9 * scale)).foregroundColor(ink.opacity(0.65))
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7 * scale)
        .background(Color(red: 0xD2 / 255, green: 0xB4 / 255, blue: 0x8C / 255), in: RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
    }
}

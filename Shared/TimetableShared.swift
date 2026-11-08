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
    /// The title as shown: a title written in all capitals ("ENGLISH FOR ACADEMIC WRITING") becomes
    /// "English for Academic Writing". A title that already has lower-case letters is left as it is.
    var displayTitle: String { TimetableText.normalCase(title) }
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
    /// The start times that rows are made of: one row per start time, earliest first (an evening class comes last)
    var slots: [Int] { Array(Set(classes.map { $0.startMin })).sorted() }
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

    /// Minutes after midnight with the seconds as a fraction (for the water level, which rises smoothly)
    static func exactMinutes(_ d: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }

    private static let smallWords: Set<String> = ["a", "an", "the", "and", "or", "but", "nor", "for", "of", "to", "in", "on",
                                                   "at", "by", "with", "as", "from", "into", "per", "via", "vs"]
    /// short words that are really words (not acronyms like ICT) when written in capitals
    private static let shortWords: Set<String> = ["law", "art", "use", "man", "men", "new", "its", "our", "how", "who", "why",
                                                   "you", "all", "one", "two", "web", "sun", "sea", "air", "map", "tax", "war",
                                                   "oil", "gas", "dna", "pe"]

    /// "ENGLISH FOR ACADEMIC WRITING" -> "English for Academic Writing"; anything with a lower-case letter is returned unchanged.
    /// Roman numerals (II, III) and short acronyms (ICT, AI) stay in capitals.
    static func normalCase(_ t: String) -> String {
        let letters = t.filter { $0.isLetter }
        guard !letters.isEmpty, !letters.contains(where: { $0.isLowercase }) else { return t }
        var first = true
        let words = t.split(separator: " ", omittingEmptySubsequences: false).map { sub -> String in
            let w = String(sub)
            let core = w.filter { $0.isLetter }.lowercased()
            defer { if !core.isEmpty { first = false } }
            guard !core.isEmpty else { return w }
            let roman = core.allSatisfy { "ivxl".contains($0) } && core.count <= 4
            let acronym = core.count <= 3 && !smallWords.contains(core) && !shortWords.contains(core)
            if roman || acronym { return w }
            if smallWords.contains(core) && !first { return w.lowercased() }
            // lower-case everything, then raise the first letter
            var out = w.lowercased()
            if let i = out.firstIndex(where: { $0.isLetter }) { out.replaceSubrange(i...i, with: String(out[i]).uppercased()) }
            return out
        }
        return words.joined(separator: " ")
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

extension TimetableClass {
    /// 0...1 while this class is running (today only), otherwise nil. The water in its box rises with it.
    func progress(at date: Date) -> Double? {
        guard day == TimetableText.weekday(date), endMin > startMin else { return nil }
        let m = TimetableText.exactMinutes(date)
        guard m >= Double(startMin), m < Double(endMin) else { return nil }
        return (m - Double(startMin)) / Double(endMin - startMin)
    }
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

// MARK: - Water

/// The water in a box: `level` 0...1 is how full it is (from the bottom); the surface is a gentle wave.
struct WaterShape: Shape {
    var level: Double
    var phase: Double
    var amp: CGFloat
    var line = false      // true: only the surface (to stroke), false: the filled body

    func path(in r: CGRect) -> Path {
        let lv = min(max(level, 0), 1)
        let y0 = r.maxY - r.height * CGFloat(lv)
        let a = amp * CGFloat(min(1, min(lv, 1 - lv) * 10))   // flat when empty or full
        let steps = max(16, Int(r.width / 3))
        func yAt(_ i: Int) -> CGFloat {
            let t = Double(i) / Double(steps)
            return y0 + CGFloat(sin(t * 2 * Double.pi * 1.3 + phase)) * a
        }
        func xAt(_ i: Int) -> CGFloat { r.minX + r.width * CGFloat(i) / CGFloat(steps) }
        var p = Path()
        if line {
            p.move(to: CGPoint(x: xAt(0), y: yAt(0)))
            for i in 1...steps { p.addLine(to: CGPoint(x: xAt(i), y: yAt(i))) }
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            for i in 0...steps { p.addLine(to: CGPoint(x: xAt(i), y: yAt(i))) }
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
        }
        return p
    }
}

struct WaterFill: View {
    let level: Double
    var scale: CGFloat = 1
    var animated = false      // the app moves the surface; a widget can only show one still picture

    private let tan = Color(red: 0xD2 / 255, green: 0xB4 / 255, blue: 0x8C / 255)

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                layer(ctx.date.timeIntervalSinceReferenceDate * 1.4)
            }
        } else {
            layer(0.8)
        }
    }

    private func layer(_ phase: Double) -> some View {
        let amp = 1.7 * scale
        return ZStack {
            WaterShape(level: level, phase: phase, amp: amp)
                .fill(LinearGradient(colors: [tan.opacity(0.26), tan.opacity(0.08)], startPoint: .top, endPoint: .bottom))
            if level > 0.005 && level < 0.995 {
                WaterShape(level: level, phase: phase, amp: amp, line: true)
                    .stroke(tan.opacity(0.85), style: StrokeStyle(lineWidth: 1.3 * scale, lineCap: .round, lineJoin: .round))
                    .shadow(color: tan.opacity(0.6), radius: 2 * scale)
            }
        }
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
    /// the time the water level is worked out from (the widget passes the timeline date)
    var now: Date = Date()
    var animated = false
    var textScale: CGFloat = 1      // the app screen uses a slightly smaller text than the widget

    var body: some View {
        let today = TimetableText.weekday(now)
        let days = data.days
        VStack(spacing: 4 * scale) {
            // the day names
            HStack(alignment: .top, spacing: 3 * scale) {
                ForEach(days, id: \.self) { d in
                    Text(TimetableText.dayNames[d - 1])
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(d == today ? Color.black : muted)
                        .padding(.horizontal, 10 * scale)
                        .frame(height: 18 * scale)
                        .background(d == today ? accent : Color.clear, in: Capsule())
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2 * scale)
            // one row per start time, earliest first: the same hour lines up across the days, an empty slot stays blank,
            // and the boxes of a row are equally tall
            ForEach(data.slots, id: \.self) { slot in
                HStack(alignment: .top, spacing: 3 * scale) {
                    ForEach(days, id: \.self) { d in
                        VStack(spacing: 4 * scale) {
                            ForEach(data.classes.filter { $0.day == d && $0.startMin == slot }) { c in
                                TimetableBlock(c: c, accent: accent, text: text, muted: muted, scale: scale,
                                               progress: c.progress(at: now), animated: animated, textScale: textScale)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSelect?(c) }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One class in the week: a dark card with a time pill, then code, title and venue wrapped in full.
struct TimetableBlock: View {
    let c: TimetableClass
    let accent: Color   // kept for the callers; the card itself uses the fixed tan below
    let text: Color
    let muted: Color
    let scale: CGFloat
    var progress: Double? = nil     // 0...1 while the class is running: the box fills with water
    var animated = false
    var textScale: CGFloat = 1

    private let tan = Color(red: 0xD2 / 255, green: 0xB4 / 255, blue: 0x8C / 255)

    var body: some View {
        let k = scale * 1.12          // the box is a little bigger than the plain grid scale
        let f = k * 1.14 * textScale              // the text is bigger than the box around it (the padding stays at k)
        let r = 10 * k
        VStack(alignment: .leading, spacing: 3 * k) {
            Text(c.code).font(.system(size: 11 * f, weight: .bold)).foregroundColor(tan)
            Text(c.displayTitle).font(.system(size: 10 * f, weight: .medium)).foregroundColor(text)
            if !c.venue.isEmpty {
                HStack(alignment: .top, spacing: 3 * k) {
                    VenuePin(color: muted, size: 7 * f).padding(.top, 1.5 * k)
                    Text(c.venue).font(.system(size: 9 * f)).foregroundColor(muted)
                }
            }
            Text(c.shortRange.replacingOccurrences(of: "–", with: " – "))
                .font(.system(size: 9.5 * f, weight: .medium)).foregroundColor(tan)
                .lineLimit(1).minimumScaleFactor(0.6)   // the time always stays on one row
                .padding(.horizontal, 6 * k).padding(.vertical, 2 * k)
                .background(tan.opacity(0.18), in: RoundedRectangle(cornerRadius: 6 * k, style: .continuous))
                .padding(.top, 2 * k)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 9 * k).padding(.horizontal, 8 * k)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // fills the row's height
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(tan.opacity(0.08))   // soft tan tint over whatever is behind
                if let p = progress { WaterFill(level: p, scale: k, animated: animated) }
            }
            .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
    }
}

/// The map pin used for venues: a filled teardrop with a round hole (the same one in the design photo)
private struct PinTriangle: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 0.067 * w, y: r.minY + 0.75 * w))
        p.addLine(to: CGPoint(x: r.minX + 0.933 * w, y: r.minY + 0.75 * w))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY + 1.3 * w))
        p.closeSubpath()
        return p
    }
}

struct VenuePin: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Circle().frame(width: size, height: size)
            PinTriangle().frame(width: size, height: size * 1.3)
        }
        .frame(width: size, height: size * 1.3)
        .foregroundColor(color)
        .mask(
            ZStack {
                Rectangle().fill(Color.white)
                Circle().frame(width: size * 0.36, height: size * 0.36)
                    .offset(y: -size * 0.15)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}
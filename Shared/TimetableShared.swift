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
    /// 0...1 while this class is running (today only), otherwise nil. The water in its card rises with it.
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

// MARK: - Look (dark warm cards, tan pills, a water level that rises during class)

enum TimetableLook {
    static func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
    static let card = c(255, 236, 226, 0.075)      // a warm lift over the dark backdrop
    static let pillFill = c(92, 76, 68)
    static let pillText = c(224, 190, 162)
    static let heading = c(228, 192, 172)
    static let text = c(246, 244, 242)
    static let muted = c(150, 146, 144)
    static let dayText = c(165, 160, 158)
    static let water = c(216, 180, 150)
    static let waterLine = c(226, 210, 196)
}

/// The dark, slightly wine-tinted background of the card / widget
struct TimetableBackdrop: View {
    var body: some View {
        ZStack {
            Color(.sRGB, red: 24 / 255, green: 22 / 255, blue: 23 / 255)
            RadialGradient(colors: [TimetableLook.c(96, 70, 72, 0.50), Color.clear], center: .topLeading,
                           startRadius: 0, endRadius: 340)
            RadialGradient(colors: [TimetableLook.c(74, 60, 64, 0.40), Color.clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 380)
        }
    }
}

struct TimetableHeader: View {
    let title: String
    var trailing: String? = nil
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: "calendar").font(.system(size: 12 * scale, weight: .semibold))
            Text(title).font(.system(size: 11 * scale, weight: .semibold)).tracking(0.8 * scale).lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.system(size: 10 * scale, weight: .medium))
                    .foregroundColor(TimetableLook.muted).lineLimit(1)
            }
        }
        .foregroundColor(TimetableLook.heading)
    }
}

// MARK: - Water

/// The water in a card: `level` 0...1 is how full it is (from the bottom); the surface is a gentle wave.
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
                .fill(LinearGradient(colors: [TimetableLook.water.opacity(0.26), TimetableLook.water.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom))
            if level > 0.005 && level < 0.995 {
                WaterShape(level: level, phase: phase, amp: amp, line: true)
                    .stroke(TimetableLook.waterLine.opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.3 * scale, lineCap: .round, lineJoin: .round))
                    .shadow(color: TimetableLook.water.opacity(0.6), radius: 2 * scale)
            }
        }
    }
}

// MARK: - The week

/// Rows are start times (earliest first), columns are the days that have a class. A class sits in the row of its
/// start time, so the same hour lines up across the days; an empty slot is left blank. The cards of a row are equally
/// tall and grow to fit their text (nothing is cut). A class that is running now fills with water.
struct TimetableGrid: View {
    let data: TimetableData
    var scale: CGFloat = 1
    // kept so older call sites still compile: the look is fixed (TimetableLook)
    var text: Color = TimetableLook.text
    var muted: Color = TimetableLook.muted
    var line: Color = Color(white: 0.13)
    var accent: Color = TimetableLook.pillText
    var now: Date = Date()
    var animated = false
    /// set in the app: a tap on a subject calls this (the widget leaves it nil)
    var onSelect: ((TimetableClass) -> Void)? = nil

    var body: some View {
        let today = TimetableText.weekday(now)
        let days = data.days
        let gap = 4 * scale
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                ForEach(days, id: \.self) { d in
                    Text(TimetableText.dayNames[d - 1])
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(d == today ? TimetableLook.text : TimetableLook.dayText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 2 * scale)
            ForEach(data.slots, id: \.self) { slot in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(days, id: \.self) { d in
                        let cell = data.classes.filter { $0.day == d && $0.startMin == slot }
                        VStack(spacing: gap) {
                            ForEach(cell) { c in
                                TimetableBlock(c: c, accent: accent, text: text, muted: muted, scale: scale,
                                               progress: c.progress(at: now), animated: animated)
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

/// One class: a card with a full-width time pill, then code, title and venue wrapped in full.
struct TimetableBlock: View {
    let c: TimetableClass
    let accent: Color   // kept for the callers; the look is fixed (TimetableLook)
    let text: Color
    let muted: Color
    let scale: CGFloat
    var progress: Double? = nil
    var animated = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
        VStack(alignment: .leading, spacing: 3 * scale) {
            Text(c.shortRange.replacingOccurrences(of: "–", with: " – "))
                .font(.system(size: 9.5 * scale, weight: .medium)).foregroundColor(TimetableLook.pillText)
                .lineLimit(1).minimumScaleFactor(0.6)   // the time always stays on one row
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2.5 * scale)
                .background(TimetableLook.pillFill, in: RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
                .padding(.bottom, 2 * scale)
            Text(c.code).font(.system(size: 11 * scale, weight: .bold)).foregroundColor(TimetableLook.text)
            Text(c.title).font(.system(size: 10 * scale, weight: .regular)).foregroundColor(TimetableLook.text)
            if !c.venue.isEmpty {
                HStack(alignment: .top, spacing: 3 * scale) {
                    VenuePin(color: TimetableLook.muted, size: 7 * scale).padding(.top, 1.5 * scale)
                    Text(c.venue).font(.system(size: 9 * scale)).foregroundColor(TimetableLook.muted)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 7 * scale).padding(.horizontal, 7 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                shape.fill(TimetableLook.card)
                if let p = progress { WaterFill(level: p, scale: scale, animated: animated) }
            }
            .clipShape(shape)
        )
    }
}

/// The whole screen card of the app: header, then the week, on the dark backdrop with a glass edge
struct TimetableCard: View {
    let data: TimetableData
    var onSelect: ((TimetableClass) -> Void)? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            TimetableHeader(title: "CLASS TIMETABLE", trailing: data.title, scale: 1.1)
            // refreshed every 30 s so the water level and "today" stay right
            TimelineView(.periodic(from: Date(), by: 30)) { ctx in
                TimetableGrid(data: data, now: ctx.date, animated: true, onSelect: onSelect)
            }
        }
        .padding(14)
        .background(TimetableBackdrop())
        .clipShape(shape)
        .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
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
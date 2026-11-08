import WidgetKit
import SwiftUI

// WIDGET TARGET ONLY (lives in Widget/, built together with Shared/TimetableShared.swift).
// Small: the next class. Medium: the classes of today (or the next day that has any). Large: the whole week,
// in rows by start time. A class that is running fills with water (the level follows the time, refreshed every 5 min).

private enum T {
    static let accent = TimetableLook.pillText
    static let txt    = TimetableLook.text
    static let muted  = TimetableLook.muted
    static let line   = Color(white: 0.13)
}

private extension View {
    /// The dark wine-tinted backdrop of the widget (the same one as the card in the app)
    @ViewBuilder func timetableBackdrop() -> some View {
        if #available(iOS 17.0, *) { containerBackground(for: .widget) { TimetableBackdrop() } }
        else { background(TimetableBackdrop()) }
    }
}

struct TimetableEntry: TimelineEntry {
    let date: Date
    let data: TimetableData?
    var shared = true
}

struct TimetableProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimetableEntry { TimetableEntry(date: Date(), data: .sample) }

    private func entry(_ date: Date) -> TimetableEntry {
        TimetableEntry(date: date, data: TimetableStore.load(), shared: AttendanceStore.isShared)
    }
    func getSnapshot(in context: Context, completion: @escaping (TimetableEntry) -> Void) {
        completion(context.isPreview ? TimetableEntry(date: Date(), data: .sample) : entry(Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TimetableEntry>) -> Void) {
        let now = Date()
        let cal = Calendar.current
        var dates = [now]
        // refresh when a class of today starts or ends, and every 5 minutes while it runs (the water rises)
        if let data = TimetableStore.load() {
            let today = TimetableText.weekday(now)
            let start = cal.startOfDay(for: now)
            for c in data.classes where c.day == today {
                var ms: [Int] = []
                var m = c.startMin
                while m < c.endMin { ms.append(m); m += 5 }
                ms.append(c.endMin)
                for m in ms {
                    if let d = cal.date(byAdding: .minute, value: m, to: start), d > now { dates.append(d) }
                }
            }
        }
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(3600 * 6)
        dates.append(midnight)
        completion(Timeline(entries: dates.sorted().map(entry), policy: .after(midnight.addingTimeInterval(60))))
    }
}

struct TimetableWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimetableEntry

    var body: some View {
        Group {
            if let data = entry.data, !data.classes.isEmpty {
                switch family {
                case .systemSmall: small(data)
                case .systemMedium: medium(data)
                default: large(data)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    header("CLASS TIMETABLE", nil)
                    Spacer(minLength: 0)
                    Text(!entry.shared ? "Can't reach the app's data. The app and widget need the same App Group when signing."
                         : "Open iTa'leem > Others > Class Timetable and upload your registration slip.")
                        .font(.system(size: 12)).foregroundColor(T.muted)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .timetableBackdrop()
        .widgetURL(URL(string: "italeem://timetable"))   // a tap opens Class Timetable in the app
    }

    private func header(_ title: String, _ trailing: String?) -> some View {
        TimetableHeader(title: title, trailing: trailing, scale: 0.9)
    }

    private func dayLabel(_ offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        let d = Calendar.current.date(byAdding: .day, value: offset, to: entry.date) ?? entry.date
        return TimetableText.dayNames[TimetableText.weekday(d) - 1]
    }

    // MARK: small

    @ViewBuilder private func small(_ data: TimetableData) -> some View {
        if let up = data.upcoming(from: entry.date), let c = up.classes.first {
            let p = up.offset == 0 ? c.progress(at: entry.date) : nil
            VStack(alignment: .leading, spacing: 6) {
                header(p != nil ? "NOW" : "NEXT", dayLabel(up.offset))
                TimetableBlock(c: c, accent: T.accent, text: T.txt, muted: T.muted, scale: 1.05, progress: p)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                header("CLASS TIMETABLE", nil)
                Spacer(minLength: 0)
                Text("No more classes this week").font(.system(size: 13, weight: .medium)).foregroundColor(T.txt)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: medium

    @ViewBuilder private func medium(_ data: TimetableData) -> some View {
        if let up = data.upcoming(from: entry.date) {
            let shown = Array(up.classes.prefix(3))
            VStack(alignment: .leading, spacing: 6) {
                header(dayLabel(up.offset).uppercased(), data.title)
                ForEach(shown) { c in row(c, progress: up.offset == 0 ? c.progress(at: entry.date) : nil) }
                if up.classes.count > shown.count {
                    Text("+\(up.classes.count - shown.count) more").font(.system(size: 10)).foregroundColor(T.muted)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                header("CLASS TIMETABLE", data.title)
                Spacer(minLength: 0)
                Text("No more classes this week").font(.system(size: 13, weight: .medium)).foregroundColor(T.txt)
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ c: TimetableClass, progress: Double?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(c.code).font(.system(size: 12, weight: .bold)).foregroundColor(T.txt)
                    Text(c.title).font(.system(size: 11)).foregroundColor(T.txt).lineLimit(1)
                }
                if !c.venue.isEmpty {
                    HStack(spacing: 4) {
                        VenuePin(color: T.muted, size: 6)
                        Text(c.venue).font(.system(size: 9.5)).foregroundColor(T.muted).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(c.shortRange.replacingOccurrences(of: "–", with: " – "))
                .font(.system(size: 9.5, weight: .medium)).foregroundColor(TimetableLook.pillText)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(TimetableLook.pillFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(
            ZStack {
                shape.fill(TimetableLook.card)
                if let p = progress { WaterFill(level: p, scale: 0.9) }
            }
            .clipShape(shape)
        )
    }

    // MARK: large

    /// The week is drawn at the biggest size that fits: a busy timetable is scaled down instead of being cut
    private func large(_ data: TimetableData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header("CLASS TIMETABLE", data.title)
            ViewThatFits(in: .vertical) {
                week(data, 1.0)
                week(data, 0.88)
                week(data, 0.76)
                week(data, 0.66)
                week(data, 0.58)
                week(data, 0.5)
            }
        }
    }

    private func week(_ data: TimetableData, _ scale: CGFloat) -> some View {
        TimetableGrid(data: data, scale: scale, now: entry.date)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TimetableHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimetableWidget", provider: TimetableProvider()) { entry in
            TimetableWidgetView(entry: entry)
        }
        .configurationDisplayName("Class timetable")
        .description("Your next class, today's classes, or the whole week.")
        .supportedFamilies(Self.families)
    }

    /// Small, medium, large, plus the tall one (like the Photos widget) when the app is built with the iOS 27 SDK
    private static var families: [WidgetFamily] {
        var f: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        #if TALL_WIDGET
        if #available(iOS 27.0, *) { f.append(.systemExtraLargePortrait) }
        #endif
        return f
    }
}


// MARK: - Lock screen widget

// Shows the class from 15 minutes before it starts until it ends: subject name and venue.
// Outside that window it draws nothing (iOS keeps the empty slot, there is just nothing in it).

struct TimetableLockEntry: TimelineEntry {
    let date: Date
    let current: TimetableClass?
    let ongoing: Bool
}

struct TimetableLockProvider: TimelineProvider {
    private static let lead = 15   // minutes before the class

    func placeholder(in context: Context) -> TimetableLockEntry {
        TimetableLockEntry(date: Date(), current: TimetableData.sample.classes[2], ongoing: true)
    }

    private func entry(_ date: Date, _ data: TimetableData?) -> TimetableLockEntry {
        let today = TimetableText.weekday(date), m = TimetableText.minutes(date)
        let c = data?.classes
            .filter { $0.day == today && m >= $0.startMin - Self.lead && m < $0.endMin }
            .max { $0.startMin < $1.startMin }   // two in the window: the later one wins, so the next class takes over 15 min before it starts
        return TimetableLockEntry(date: date, current: c, ongoing: c.map { m >= $0.startMin } ?? false)
    }

    func getSnapshot(in context: Context, completion: @escaping (TimetableLockEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(Date(), TimetableStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimetableLockEntry>) -> Void) {
        let now = Date()
        let cal = Calendar.current
        let data = TimetableStore.load()
        var dates = [now]
        // refresh 15 min before each class, when it starts and when it ends
        if let data {
            let today = TimetableText.weekday(now)
            let start = cal.startOfDay(for: now)
            for c in data.classes where c.day == today {
                for m in [c.startMin - Self.lead, c.startMin, c.endMin] {
                    if let d = cal.date(byAdding: .minute, value: m, to: start), d > now { dates.append(d) }
                }
            }
        }
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(3600 * 6)
        dates.append(midnight)
        completion(Timeline(entries: dates.sorted().map { entry($0, data) }, policy: .after(midnight.addingTimeInterval(60))))
    }
}

struct TimetableLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimetableLockEntry

    var body: some View {
        Group {
            if let c = entry.current {
                switch family {
                case .accessoryInline:
                    Text("\(c.title)\(c.venue.isEmpty ? "" : " · " + c.venue)")
                default:
                    VStack(alignment: .leading, spacing: 1) {
                        Text((entry.ongoing ? "NOW" : "SOON") + " · " + c.range)
                            .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).opacity(0.7)
                        Text(c.title).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        if !c.venue.isEmpty {
                            Text(c.venue).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Color.clear   // nothing to show; needs a real view so containerBackground is applied (EmptyView gives the "Please adopt containerBackground" error)
            }
        }
        .widgetURL(URL(string: "italeem://timetable"))
        .widgetBackground(Color.clear)
    }
}

struct TimetableLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimetableLockWidget", provider: TimetableLockProvider()) { entry in
            TimetableLockView(entry: entry)
        }
        .configurationDisplayName("Class now (lock screen)")
        .description("The subject and venue, from 15 minutes before a class until it ends.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Lock screen class timer (circular)

// A ring with the minutes left until the CURRENT class ends (the ring empties as it runs out).
// Nothing is drawn before a class starts or when there is no class.

struct TimetableTimerEntry: TimelineEntry {
    let date: Date
    let minutes: Int?        // nil = nothing to show
    let fraction: Double     // 1 = full ring
}

struct TimetableTimerProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimetableTimerEntry { TimetableTimerEntry(date: Date(), minutes: 12, fraction: 0.8) }

    private func entry(_ date: Date, _ data: TimetableData?) -> TimetableTimerEntry {
        let today = TimetableText.weekday(date), m = TimetableText.minutes(date)
        // the class running now (if two overlap, the one that ends first)
        guard let c = data?.classes
            .filter({ $0.day == today && m >= $0.startMin && m < $0.endMin })
            .min(by: { $0.endMin < $1.endMin })
        else { return TimetableTimerEntry(date: date, minutes: nil, fraction: 0) }
        let left = c.endMin - m
        return TimetableTimerEntry(date: date, minutes: left, fraction: Double(left) / Double(max(c.endMin - c.startMin, 1)))
    }

    func getSnapshot(in context: Context, completion: @escaping (TimetableTimerEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(Date(), TimetableStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimetableTimerEntry>) -> Void) {
        let now = Date()
        let cal = Calendar.current
        let data = TimetableStore.load()
        var dates = [now]
        // one entry per minute while a class is running, so the number counts down
        if let data {
            let today = TimetableText.weekday(now)
            let start = cal.startOfDay(for: now)
            for c in data.classes where c.day == today {
                for m in c.startMin...c.endMin {
                    if let d = cal.date(byAdding: .minute, value: m, to: start), d > now { dates.append(d) }
                }
            }
        }
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(3600 * 6)
        dates.append(midnight)
        completion(Timeline(entries: dates.sorted().map { entry($0, data) }, policy: .after(midnight.addingTimeInterval(60))))
    }
}

struct TimetableTimerView: View {
    let entry: TimetableTimerEntry

    var body: some View {
        Group {
            if let n = entry.minutes {
                Gauge(value: max(0, min(entry.fraction, 1))) {
                    EmptyView()
                } currentValueLabel: {
                    VStack(spacing: -1) {
                        Text("\(n)").font(.system(size: 17, weight: .bold)).minimumScaleFactor(0.6)
                        Text("min").font(.system(size: 8))
                    }
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Color.clear   // blank, but a real view so containerBackground is applied
            }
        }
        .widgetURL(URL(string: "italeem://timetable"))
        .widgetBackground(Color.clear)
    }
}

struct TimetableTimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimetableTimerWidget", provider: TimetableTimerProvider()) { entry in
            TimetableTimerView(entry: entry)
        }
        .configurationDisplayName("Class timer (lock screen)")
        .description("A ring with the minutes left until the current class ends. Blank when there is no class.")
        .supportedFamilies([.accessoryCircular])
    }
}

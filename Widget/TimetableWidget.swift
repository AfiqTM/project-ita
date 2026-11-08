import WidgetKit
import SwiftUI

// WIDGET TARGET ONLY (lives in Widget/, built together with Shared/TimetableShared.swift).
// Small: the next class. Medium: the classes of today (or the next day that has any). Large: the whole week.

private enum T {
    static let bg     = Color.black
    static let accent = Color(red: 210 / 255, green: 180 / 255, blue: 140 / 255)   // iTa'leem tan
    static let txt    = Color(red: 230 / 255, green: 230 / 255, blue: 230 / 255)
    static let muted  = Color(red: 154 / 255, green: 154 / 255, blue: 154 / 255)
    static let line   = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
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
        .amoledBackground()   // the same pure black as the Attendance widget
        .widgetURL(URL(string: "italeem://timetable"))   // a tap opens Class Timetable in the app
    }

    private func header(_ title: String, _ trailing: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundColor(T.accent)
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(T.accent).lineLimit(1)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.system(size: 9)).foregroundColor(T.muted).lineLimit(1) }
        }
    }

    private func dayLabel(_ offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        let d = Calendar.current.date(byAdding: .day, value: offset, to: entry.date) ?? entry.date
        return TimetableText.dayNames[TimetableText.weekday(d) - 1]
    }

    private func isNow(_ c: TimetableClass, _ offset: Int) -> Bool {
        let m = TimetableText.minutes(entry.date)
        return offset == 0 && c.startMin <= m && m < c.endMin
    }

    // MARK: small

    @ViewBuilder private func small(_ data: TimetableData) -> some View {
        if let up = data.upcoming(from: entry.date), let c = up.classes.first {
            let now = isNow(c, up.offset)
            VStack(alignment: .leading, spacing: 4) {
                header(now ? "NOW" : "NEXT", dayLabel(up.offset))
                Spacer(minLength: 0)
                Text(c.code)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(c.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(T.txt)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                let v = c.venue.isEmpty
                    ? (data.classes.first { $0.code == c.code && !$0.venue.isEmpty }?.venue ?? "")
                    : c.venue
                if !v.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        VenuePin(color: T.muted, size: 8).padding(.top, 1.5)
                        Text(v)
                            .font(.system(size: 10))
                            .foregroundColor(T.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 1)
                }
                Text(c.range)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                    .background(Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .offset(x: -1)
                    .padding(.top, 2)
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
            VStack(alignment: .leading, spacing: 7) {
                header(dayLabel(up.offset).uppercased(), data.title)
                ForEach(shown) { c in row(data, c, now: isNow(c, up.offset)) }
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

    private func row(_ data: TimetableData, _ c: TimetableClass, now: Bool) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(T.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(c.code).font(.system(size: 12, weight: .bold)).foregroundColor(T.txt)
                    if now {
                        Text("NOW").font(.system(size: 8, weight: .bold)).foregroundColor(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1).background(T.accent).clipShape(Capsule())
                    }
                    Text(c.displayTitle).font(.system(size: 11)).foregroundColor(T.muted).lineLimit(1)
                }
                // time first, then the venue; the venue may use a second row instead of being cut
                (Text(c.range).foregroundColor(T.accent) + Text(c.venue.isEmpty ? "" : "  " + c.venue).foregroundColor(T.muted))
                    .font(.system(size: 10)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 7)
        .background(
            ZStack {
                LinearGradient(colors: [T.accent.opacity(0.22), T.accent.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
                if now, let p = c.progress(at: entry.date) { WaterFill(level: p, scale: 0.9) }   // fills while the class runs
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    // MARK: large

    /// The tall widget has room for every hour at full height
    private var tall: Bool {
        #if TALL_WIDGET
        if #available(iOS 27.0, *) { return family == .systemExtraLargePortrait }
        #endif
        return false
    }

    private func week(_ data: TimetableData, _ scale: CGFloat) -> some View {
        TimetableGrid(data: data, scale: scale, text: T.txt, muted: T.muted, line: T.line, accent: T.accent, now: entry.date)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func large(_ data: TimetableData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("CLASS TIMETABLE", data.title)
            ViewThatFits(in: .vertical) {
                week(data, 1.0)
                week(data, 0.94)
                week(data, 0.88)
                week(data, 0.82)
                week(data, 0.76)
                week(data, 0.70)
                week(data, 0.64)
                week(data, 0.58)
                week(data, 0.54)
                week(data, 0.5)
            }
        }
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
        .contentMarginsDisabled()   // black to the edges; amoledBackground puts the margins back as padding
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
                    Text("\(c.displayTitle)\(c.venue.isEmpty ? "" : " · " + c.venue)")
                default:
                    VStack(alignment: .leading, spacing: 1) {
                        Text((entry.ongoing ? "NOW" : "SOON") + " · " + c.range)
                            .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).opacity(0.7)
                        Text(c.displayTitle).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
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

// MARK: - Tasks (Assignment submissions) widget

struct TasksEntry: TimelineEntry {
    let date: Date
    let snapshot: TasksSnapshot?
    var shared = true
}

struct TasksProvider: TimelineProvider {
    func placeholder(in context: Context) -> TasksEntry {
        TasksEntry(date: Date(), snapshot: .sample)
    }

    private func entry(_ date: Date) -> TasksEntry {
        TasksEntry(date: date, snapshot: TasksStore.load(), shared: AttendanceStore.isShared)
    }

    func getSnapshot(in context: Context, completion: @escaping (TasksEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksEntry>) -> Void) {
        let now = Date()
        let cal = Calendar.current
        var dates = [now]
        // refresh on the hour so "14 Hours Left" counts down accurately, and at midnight when "Today" flips
        for h in 1...6 {
            if let d = cal.date(byAdding: .hour, value: h, to: now) { dates.append(d) }
        }
        if let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) {
            dates.append(midnight)
        }
        let next = cal.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: dates.sorted().map(entry), policy: .after(next)))
    }
}

struct TasksWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TasksEntry
    private let timetable = TimetableStore.load()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM"
        return f
    }()

    var body: some View {
        Group {
            if let snap = entry.snapshot {
                let list = snap.upcoming(from: entry.date)
                if let closest = snap.closest(from: entry.date) {
                    switch family {
                    case .systemSmall:
                        small(closest.item, count: closest.totalCount)
                    default:
                        mediumOrLarge(list)
                    }
                } else {
                    emptyView("No upcoming tasks due.")
                }
            } else {
                emptyView(!entry.shared
                          ? "Can't reach the app's data. The app and widget need the same App Group when signing."
                          : "Open iTa'leem > Tasks once to load your assignments.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .amoledBackground()
        .widgetURL(URL(string: "italeem://tasks"))
    }

    private func header(count: Int? = nil, _ trailing: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundColor(T.accent)
            Text("TASKS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(T.accent).lineLimit(1)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .background(Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255), in: Capsule())
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.system(size: 9.5, weight: .medium)).foregroundColor(T.muted).lineLimit(1)
            }
        }
    }

    private func emptyView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(nil)
            Spacer(minLength: 0)
            Text(msg).font(.system(size: 13, weight: .medium)).foregroundColor(T.txt)
            Spacer(minLength: 0)
        }
    }

    private func isDueToday(_ t: TaskWidgetItem) -> Bool {
        Calendar.current.isDate(t.dueDate, inSameDayAs: entry.date)
    }

    private func dateLabel(_ t: TaskWidgetItem) -> String {
        isDueToday(t) ? "Today" : Self.dateFmt.string(from: t.dueDate)
    }

    private func hoursLeftText(_ t: TaskWidgetItem) -> String {
        let secs = max(0, t.dueDate.timeIntervalSince(entry.date))
        let hrs = Int(ceil(secs / 3600))
        if hrs <= 1 {
            let mins = max(1, Int(ceil(secs / 60)))
            return mins < 60 ? "\(mins) Min Left" : "1 Hour Left"
        }
        return "\(hrs) Hours Left"
    }

    // MARK: small

    @ViewBuilder private func small(_ t: TaskWidgetItem, count: Int) -> some View {
        let today = isDueToday(t)
        let code = t.resolvedCode(timetable: timetable)
        VStack(alignment: .leading, spacing: 4) {
            header(count: count, dateLabel(t))
            Spacer(minLength: 0)
            if let code {
                Text(code)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(t.displayCourseName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(T.txt)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(t.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(T.muted)
                .lineLimit(today ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
            if today {
                Text(hoursLeftText(t))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                    .background(Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .offset(x: -1)
                    .padding(.top, 2)
            } else {
                Spacer(minLength: 0)
                    .frame(maxHeight: 10)
            }
        }
    }

    // MARK: medium & large

    @ViewBuilder private func mediumOrLarge(_ list: [TaskWidgetItem]) -> some View {
        let maxCount = family == .systemMedium ? 3 : 6
        let shown = Array(list.prefix(maxCount))
        VStack(alignment: .leading, spacing: 8) {
            header(count: list.count, nil)
            ForEach(shown) { t in
                taskRow(t)
            }
            if list.count > shown.count {
                Text("+\(list.count - shown.count) more").font(.system(size: 10)).foregroundColor(T.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func taskRow(_ t: TaskWidgetItem) -> some View {
        let today = isDueToday(t)
        let code = t.resolvedCode(timetable: timetable)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let code {
                        Text(code)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(T.accent)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Text(t.displayCourseName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(T.txt)
                        .lineLimit(1)
                }
                Text(t.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(T.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(today ? hoursLeftText(t) : dateLabel(t))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(today ? T.accent : T.muted)
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    today
                        ? Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }
}

struct TasksHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TasksWidget", provider: TasksProvider()) { entry in
            TasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Tasks")
        .description("Your upcoming assignment submissions.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - To-Do (Academic Tools > To-Do List) widget

struct TodoWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TodoWidgetSnapshot?
    var shared = true
}

struct TodoWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodoWidgetEntry {
        TodoWidgetEntry(date: Date(), snapshot: .sample)
    }

    private func entry(_ date: Date) -> TodoWidgetEntry {
        TodoWidgetEntry(date: date, snapshot: TodoWidgetStore.load(), shared: AttendanceStore.isShared)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoWidgetEntry>) -> Void) {
        let now = Date()
        let cal = Calendar.current
        var dates = [now]
        for h in 1...6 {
            if let d = cal.date(byAdding: .hour, value: h, to: now) { dates.append(d) }
        }
        if let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) {
            dates.append(midnight)
        }
        let next = cal.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: dates.sorted().map(entry), policy: .after(next)))
    }
}

struct TodoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodoWidgetEntry
    private let timetable = TimetableStore.load()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM"
        return f
    }()

    var body: some View {
        Group {
            if let snap = entry.snapshot {
                let list = snap.upcoming(from: entry.date)
                if let closest = snap.closest(from: entry.date) {
                    switch family {
                    case .systemSmall:
                        small(closest.item, count: closest.totalCount)
                    default:
                        mediumOrLarge(list)
                    }
                } else {
                    emptyView("Nothing to do.")
                }
            } else {
                emptyView(!entry.shared
                          ? "Can't reach the app's data. The app and widget need the same App Group when signing."
                          : "Open iTa'leem > Others > To-Do List to add your tasks.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .amoledBackground()
        .widgetURL(URL(string: "italeem://todo"))
    }

    private func header(count: Int? = nil, _ trailing: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundColor(T.accent)
            Text("TO-DO").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(T.accent).lineLimit(1)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .background(Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255), in: Capsule())
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.system(size: 9.5, weight: .medium)).foregroundColor(T.muted).lineLimit(1)
            }
        }
    }

    private func emptyView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(nil)
            Spacer(minLength: 0)
            Text(msg).font(.system(size: 13, weight: .medium)).foregroundColor(T.txt)
            Spacer(minLength: 0)
        }
    }

    private func isDueToday(_ t: TodoWidgetItem) -> Bool {
        Calendar.current.isDate(t.due, inSameDayAs: entry.date)
    }

    private func dateLabel(_ t: TodoWidgetItem) -> String {
        isDueToday(t) ? "Today" : Self.dateFmt.string(from: t.due)
    }

    private func hoursLeftText(_ t: TodoWidgetItem) -> String {
        let secs = max(0, t.due.timeIntervalSince(entry.date))
        let hrs = Int(ceil(secs / 3600))
        if hrs <= 1 {
            let mins = max(1, Int(ceil(secs / 60)))
            return mins < 60 ? "\(mins) Min Left" : "1 Hour Left"
        }
        return "\(hrs) Hours Left"
    }

    // MARK: small

    @ViewBuilder private func small(_ t: TodoWidgetItem, count: Int) -> some View {
        let today = isDueToday(t)
        let code = t.resolvedCode(timetable: timetable)
        VStack(alignment: .leading, spacing: 4) {
            header(count: count, dateLabel(t))
            Spacer(minLength: 0)
            if let code {
                Text(code)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(t.displayCourseName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(T.txt)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(t.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(T.muted)
                .lineLimit(today ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
            if today {
                Text(hoursLeftText(t))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 7).padding(.vertical, 3.5)
                    .background(Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .offset(x: -1)
                    .padding(.top, 2)
            } else {
                Spacer(minLength: 0)
                    .frame(maxHeight: 10)
            }
        }
    }

    // MARK: medium & large

    @ViewBuilder private func mediumOrLarge(_ list: [TodoWidgetItem]) -> some View {
        let maxCount = family == .systemMedium ? 3 : 6
        let shown = Array(list.prefix(maxCount))
        VStack(alignment: .leading, spacing: 8) {
            header(count: list.count, nil)
            ForEach(shown) { t in
                todoRow(t)
            }
            if list.count > shown.count {
                Text("+\(list.count - shown.count) more").font(.system(size: 10)).foregroundColor(T.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func todoRow(_ t: TodoWidgetItem) -> some View {
        let today = isDueToday(t)
        let code = t.resolvedCode(timetable: timetable)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let code {
                        Text(code)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(T.accent)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Text(t.displayCourseName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(T.txt)
                        .lineLimit(1)
                }
                Text(t.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(T.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(today ? hoursLeftText(t) : dateLabel(t))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(today ? T.accent : T.muted)
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    today
                        ? Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }
}

struct TodoHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodoWidget", provider: TodoWidgetProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("To-Do")
        .description("Your upcoming to-do items from Academic Tools.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Study Plan widget (Academic Tools > Study Plan Tracker)

struct StudyPlanWidgetEntry: TimelineEntry {
    let date: Date
    let data: StudyPlanWidgetSnapshot?
    var shared: Bool = true
}

struct StudyPlanWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> StudyPlanWidgetEntry {
        StudyPlanWidgetEntry(date: Date(), data: .sample)
    }
    func getSnapshot(in context: Context, completion: @escaping (StudyPlanWidgetEntry) -> Void) {
        let data = StudyPlanWidgetStore.load() ?? (context.isPreview ? .sample : nil)
        completion(StudyPlanWidgetEntry(date: Date(), data: data, shared: AttendanceStore.isShared))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StudyPlanWidgetEntry>) -> Void) {
        let now = Date()
        let data = StudyPlanWidgetStore.load()
        let shared = AttendanceStore.isShared
        let entry = StudyPlanWidgetEntry(date: now, data: data, shared: shared)
        let reload = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(reload)))
    }
}

struct StudyPlanWidgetView: View {
    let entry: StudyPlanWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var trackColor: Color {
        Color(red: 0x33 / 255, green: 0x2C / 255, blue: 0x22 / 255)
    }

    var body: some View {
        Group {
            if !entry.shared {
                emptyView("App Group isn't shared")
            } else if let s = entry.data {
                switch family {
                case .systemSmall:
                    small(s)
                default:
                    mediumOrLarge(s)
                }
            } else {
                emptyView("No study plan yet")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "italeem://studyplan"))
        .amoledBackground()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(T.accent)
            Text("STUDY PLAN")
                .font(.system(size: 12.5, weight: .bold))
                .tracking(0.8)
                .foregroundColor(T.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
    }

    private func emptyView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            Text(msg).font(.system(size: 13, weight: .medium)).foregroundColor(T.txt)
            Spacer(minLength: 0)
        }
    }

    private func ring(_ s: StudyPlanWidgetSnapshot, size: CGFloat, lineWidth: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(s.fraction))
                .stroke(T.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(s.percentInt)%")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(T.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: size, height: size)
    }

    // MARK: small

    private func small(_ s: StudyPlanWidgetSnapshot) -> some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 4)
            ring(s, size: 76, lineWidth: 5.5, fontSize: 20)
            Spacer(minLength: 4)
            Text("\(StudyPlanWidgetSnapshot.formatCredits(s.creditsTaken)) / \(StudyPlanWidgetSnapshot.formatCredits(s.totalRequired)) Credit Hours done")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(T.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: medium & large

    @ViewBuilder private func mediumOrLarge(_ s: StudyPlanWidgetSnapshot) -> some View {
        let maxCats = family == .systemMedium ? 3 : 6
        let cats = Array(s.categories.prefix(maxCats))
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 6) {
                    ring(s, size: 74, lineWidth: 5.5, fontSize: 19)
                    Text("\(StudyPlanWidgetSnapshot.formatCredits(s.creditsTaken)) / \(StudyPlanWidgetSnapshot.formatCredits(s.totalRequired)) CH")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(T.muted)
                        .lineLimit(1)
                }
                if !cats.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(cats) { cat in
                            categoryRow(cat)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("\(StudyPlanWidgetSnapshot.formatCredits(s.creditsTaken)) / \(StudyPlanWidgetSnapshot.formatCredits(s.totalRequired)) Credit Hours done")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(T.txt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func categoryRow(_ cat: StudyPlanWidgetCategory) -> some View {
        let frac = cat.required > 0 ? min(max(cat.taken / cat.required, 0), 1) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(cat.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(T.txt)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(StudyPlanWidgetSnapshot.formatCredits(cat.taken))/\(StudyPlanWidgetSnapshot.formatCredits(cat.required))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(T.accent)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(trackColor)
                    Capsule().fill(T.accent).frame(width: geo.size.width * CGFloat(frac))
                }
            }
            .frame(height: 4)
        }
    }
}

struct StudyPlanHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StudyPlanWidget", provider: StudyPlanWidgetProvider()) { entry in
            StudyPlanWidgetView(entry: entry)
        }
        .configurationDisplayName("Study Plan")
        .description("Your credit hours completed from Study Plan Tracker.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}


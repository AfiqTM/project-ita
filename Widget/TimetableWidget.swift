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
        // refresh when a class of today starts or ends, so "now" and "next" stay right
        if let data = TimetableStore.load() {
            let today = TimetableText.weekday(now)
            let start = cal.startOfDay(for: now)
            for c in data.classes where c.day == today {
                for m in [c.startMin, c.endMin] {
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
        .widgetBackground(T.bg)
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
            let pal = data.palette(c.code)
            VStack(alignment: .leading, spacing: 4) {
                header(isNow(c, up.offset) ? "NOW" : "NEXT", dayLabel(up.offset))
                Spacer(minLength: 0)
                Text(c.code).font(.system(size: 18, weight: .bold)).foregroundColor(pal.accent).lineLimit(1).minimumScaleFactor(0.7)
                Text(c.title).font(.system(size: 12, weight: .medium)).foregroundColor(T.txt).lineLimit(2)
                Text(c.range).font(.system(size: 11)).foregroundColor(T.muted).lineLimit(1).minimumScaleFactor(0.8)
                if !c.venue.isEmpty { Text(c.venue).font(.system(size: 10)).foregroundColor(T.muted).lineLimit(1) }
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
        let pal = data.palette(c.code)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(pal.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(c.code).font(.system(size: 12, weight: .bold)).foregroundColor(T.txt)
                    if now {
                        Text("NOW").font(.system(size: 8, weight: .bold)).foregroundColor(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1).background(pal.accent).clipShape(Capsule())
                    }
                    Text(c.title).font(.system(size: 11)).foregroundColor(T.muted).lineLimit(1)
                }
                Text(c.range + (c.venue.isEmpty ? "" : " · " + c.venue))
                    .font(.system(size: 10)).foregroundColor(T.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(pal.fill)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: large

    private func large(_ data: TimetableData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("CLASS TIMETABLE", data.title)
            TimetableGrid(data: data, compactGaps: true, scale: 1, text: T.txt, muted: T.muted, line: T.line, accent: T.accent)
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

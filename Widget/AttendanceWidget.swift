import WidgetKit
import SwiftUI

// WIDGET TARGET ONLY (lives in Widget/, built together with Shared/AttendanceShared.swift).

private enum W {
    static let bg     = Color.black
    static let accent = Color(red: 210 / 255, green: 180 / 255, blue: 140 / 255)   // iTa'leem tan
    static let txt    = Color(red: 230 / 255, green: 230 / 255, blue: 230 / 255)
    static let muted  = Color(red: 154 / 255, green: 154 / 255, blue: 154 / 255)
    static let line   = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
}

struct AttendanceEntry: TimelineEntry {
    let date: Date
    let snapshot: AttendanceSnapshot?
    var shared = true
}

struct AttendanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> AttendanceEntry {
        AttendanceEntry(date: Date(), snapshot: .sample)
    }
    private func current() -> AttendanceEntry {
        AttendanceEntry(date: Date(), snapshot: AttendanceStore.load(), shared: AttendanceStore.isShared)
    }
    func getSnapshot(in context: Context, completion: @escaping (AttendanceEntry) -> Void) {
        completion(context.isPreview ? AttendanceEntry(date: Date(), snapshot: .sample) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AttendanceEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

extension View {
    @ViewBuilder func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) { containerBackground(color, for: .widget) } else { background(color) }
    }
}

struct AttendanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttendanceEntry

    private var limit: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 5
        default: return 10
        }
    }
    private var compact: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            Text("MAX ATTENDANCE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(W.muted)

            if let s = entry.snapshot, !s.items.isEmpty {
                ForEach(s.items.prefix(limit)) { row($0) }
                if s.items.count > limit {
                    Text("+\(s.items.count - limit) more").font(.system(size: 10)).foregroundColor(W.muted)
                }
                Spacer(minLength: 0)
                if !compact {
                    HStack(spacing: 4) {
                        Text("Updated").font(.system(size: 9)).foregroundColor(W.muted)
                        Text(s.updated, style: .time).font(.system(size: 9)).foregroundColor(W.muted)
                    }
                }
            } else {
                Spacer(minLength: 0)
                Text(!entry.shared ? "Can't reach the app's data. The app and widget need the same App Group when signing."
                     : entry.snapshot == nil ? "Open iTa'leem once to load your attendance."
                     : "No subjects with attendance.")
                    .font(.system(size: 12)).foregroundColor(W.muted)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground(W.bg)
    }

    private func row(_ i: AttendanceItem) -> some View {
        HStack(spacing: 6) {
            Text(i.name)
                .font(.system(size: compact ? 11 : 13))
                .foregroundColor(W.txt)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            Text(formatPercent(i.percent))
                .font(.system(size: compact ? 12 : 14, weight: .bold))
                .foregroundColor(W.accent)
        }
    }
}

struct AttendanceHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AttendanceWidget", provider: AttendanceProvider()) { entry in
            AttendanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Max attendance")
        .description("The highest attendance you can still reach in each subject.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AttendanceWidgetBundle: WidgetBundle {
    var body: some Widget { AttendanceHomeWidget() }
}

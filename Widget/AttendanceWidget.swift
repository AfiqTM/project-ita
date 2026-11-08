import WidgetKit
import SwiftUI
import UIKit

// WIDGET TARGET ONLY (lives in Widget/, built together with Shared/AttendanceShared.swift).

private enum W {
    static let bg     = Color.black
    static let accent = Color(red: 210 / 255, green: 180 / 255, blue: 140 / 255)   // iTa'leem tan
    static let txt    = Color(red: 230 / 255, green: 230 / 255, blue: 230 / 255)
    static let muted  = Color(red: 154 / 255, green: 154 / 255, blue: 154 / 255)
    static let line   = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
    static let track  = Color(red: 38 / 255, green: 38 / 255, blue: 38 / 255)
    static let warn   = Color(red: 224 / 255, green: 108 / 255, blue: 98 / 255)
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

/// A solid black picture. A widget background that is a picture (like the black-hole one in Widgy) is drawn as it is;
/// a plain Color can be lightened by iOS, which made the widget look grey.
private let blackPicture: Image = {
    let size = CGSize(width: 8, height: 8)
    let img = UIGraphicsImageRenderer(size: size).image { ctx in
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
    return Image(uiImage: img).resizable(resizingMode: .stretch).interpolation(.none)
}()

extension View {
    /// AMOLED black for the home-screen widgets: a black picture as the widget background, and black under the content too
    @ViewBuilder func amoledBackground() -> some View {
        let content = background(blackPicture.ignoresSafeArea())
        if #available(iOS 17.0, *) { content.containerBackground(for: .widget) { blackPicture } }
        else { content }
    }

    @ViewBuilder func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) { containerBackground(color, for: .widget) } else { background(color) }
    }
}

struct AttendanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttendanceEntry

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 4
        default: return 9
        }
    }
    private var compact: Bool { family == .systemSmall }
    private var rowFont: CGFloat { compact ? 11 : 12.5 }

    /// 80% is the usual attendance minimum, so anything under it is tinted red
    private func tint(_ p: Double) -> Color { p >= 80 ? W.accent : W.warn }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            header

            if let s = entry.snapshot, !s.items.isEmpty {
                VStack(alignment: .leading, spacing: compact ? 7 : 9) {
                    ForEach(s.items.prefix(limit)) { row($0) }
                }
                if s.items.count > limit {
                    Text("+\(s.items.count - limit) more").font(.system(size: 10)).foregroundColor(W.muted)
                }
                Spacer(minLength: 0)
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
        .amoledBackground()
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(W.accent)
            Text("ATTENDANCE")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(W.accent)
            Spacer(minLength: 0)
            if !compact, let s = entry.snapshot {
                Text(s.updated, style: .time).font(.system(size: 9)).foregroundColor(W.muted)
            }
        }
    }

    /// Subject name and its maximum possible attendance, with a thin bar under them
    private func row(_ i: AttendanceItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(i.displayName)   // "SEM1 BICS 1306 Section 04 ..." prefix removed
                    .font(.system(size: rowFont))
                    .foregroundColor(W.txt)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(formatPercent(i.percent))
                    .font(.system(size: rowFont, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(tint(i.percent))
                    .lineLimit(1)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(W.track)
                GeometryReader { g in
                    Capsule().fill(tint(i.percent))
                        .frame(width: g.size.width * CGFloat(min(max(i.percent, 0), 100) / 100))
                }
            }
            .frame(height: 3)
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
    var body: some Widget {
        AttendanceHomeWidget()
        TimetableHomeWidget()
        TimetableLockWidget()
        TimetableTimerWidget()
    }
}

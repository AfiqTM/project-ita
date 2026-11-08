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
private let blackPicture: AnyView = {
    let size = CGSize(width: 8, height: 8)
    let img = UIGraphicsImageRenderer(size: size).image { ctx in
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
    let pic = Image(uiImage: img).resizable(resizingMode: .stretch).interpolation(.none)
    // with a tinted / dark home-screen icon style iOS tints the widget background grey; full colour keeps this picture black
    if #available(iOS 18.0, *) { return AnyView(pic.widgetAccentedRenderingMode(.fullColor)) }
    return AnyView(pic)
}()

/// The system's own margins are turned off for the home-screen widgets (`contentMarginsDisabled`), so iOS has no rim
/// of its own background left to draw (that rim was the grey edge). The same margins are put back here as padding,
/// and black is painted under the whole widget, edge to edge.
@available(iOS 17.0, *)
private struct AmoledEdgeToEdge: ViewModifier {
    @Environment(\.widgetContentMargins) private var margins

    func body(content: Content) -> some View {
        content
            .padding(margins)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .containerBackground(for: .widget) { blackPicture }
    }
}

extension View {
    /// AMOLED black for the home-screen widgets, filling the widget to its edges
    @ViewBuilder func amoledBackground() -> some View {
        if #available(iOS 17.0, *) { modifier(AmoledEdgeToEdge()) }
        else { padding(16).background(blackPicture.ignoresSafeArea()) }
    }

    @ViewBuilder func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) { containerBackground(color, for: .widget) } else { background(color) }
    }
}

struct AttendanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AttendanceEntry
    private let timetable = TimetableStore.load()

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 4
        default: return 9
        }
    }
    private var compact: Bool { family == .systemSmall }
    private var codeFont: CGFloat { compact ? 11.5 : 13.5 }
    private var nameFont: CGFloat { codeFont }
    private var codeColumnWidth: CGFloat { compact ? 60 : 72 }

    /// 80% is the usual attendance minimum, so anything under it is tinted red
    private func tint(_ p: Double) -> Color { p >= 80 ? W.accent : W.warn }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            header

            if let s = entry.snapshot, !s.items.isEmpty {
                let shown = Array(s.items.prefix(limit))
                let hasCodes = shown.contains { $0.resolvedCode(timetable: timetable) != nil }
                VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                    ForEach(shown) { row($0, alignCodeColumn: hasCodes) }
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

    /// Tan course code + aligned white subject name on the left, percentage on the right
    private func row(_ i: AttendanceItem, alignCodeColumn: Bool) -> some View {
        let code = i.resolvedCode(timetable: timetable)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if alignCodeColumn {
                Text(code ?? "")
                    .font(.system(size: codeFont, weight: .bold))
                    .foregroundColor(W.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: codeColumnWidth, alignment: .leading)
            }
            Text(i.displayName)
                .font(.system(size: nameFont, weight: .medium))
                .foregroundColor(W.txt)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(formatPercent(i.percent))
                .font(.system(size: codeFont, weight: .bold))
                .monospacedDigit()
                .foregroundColor(tint(i.percent))
                .lineLimit(1)
                .layoutPriority(1)
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
        .contentMarginsDisabled()   // black to the edges; amoledBackground puts the margins back as padding
    }
}

@main
struct AttendanceWidgetBundle: WidgetBundle {
    var body: some Widget {
        AttendanceHomeWidget()
        TimetableHomeWidget()
        TasksHomeWidget()
        TodoHomeWidget()
        StudyPlanHomeWidget()
        TimetableLockWidget()
        TimetableTimerWidget()
    }
}

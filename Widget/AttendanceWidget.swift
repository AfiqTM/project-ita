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

    private var columnsCount: Int {
        switch family {
        case .systemSmall: return 1
        default: return 2
        }
    }
    private var limit: Int {
        switch family {
        case .systemSmall: return 2
        case .systemMedium: return 4
        default: return 8
        }
    }
    private var compact: Bool { family == .systemSmall }

    /// 80% is the usual attendance minimum, so anything under it is tinted red
    private func tint(_ p: Double) -> Color { p >= 80 ? W.accent : W.warn }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let s = entry.snapshot, !s.items.isEmpty {
                let shown = Array(s.items.prefix(limit))
                ViewThatFits(in: .vertical) {
                    grid(shown, scale: 1.0)
                    grid(shown, scale: 0.92)
                    grid(shown, scale: 0.84)
                    grid(shown, scale: 0.76)
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

    @ViewBuilder private func grid(_ items: [AttendanceItem], scale: CGFloat) -> some View {
        let cols = columnsCount
        let rowCount = (items.count + cols - 1) / cols
        VStack(spacing: 5 * scale) {
            ForEach(0..<rowCount, id: \.self) { r in
                HStack(alignment: .top, spacing: 5 * scale) {
                    ForEach(0..<cols, id: \.self) { c in
                        let idx = r * cols + c
                        if idx < items.count {
                            card(items[idx], scale: scale)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Subject card matching the timetable block UI: a soft tan card with a percentage pill, code, title, and bar
    private func card(_ i: AttendanceItem, scale: CGFloat) -> some View {
        let col = tint(i.percent)
        let r = 10 * scale
        return VStack(alignment: .leading, spacing: 3 * scale) {
            HStack(spacing: 6 * scale) {
                Text(formatPercent(i.percent))
                    .font(.system(size: 9.5 * scale, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(col)
                    .lineLimit(1)
                    .padding(.horizontal, 6 * scale).padding(.vertical, 2 * scale)
                    .background(col.opacity(0.18), in: RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
                if let code = i.code {
                    Text(code)
                        .font(.system(size: 10.5 * scale, weight: .bold))
                        .foregroundColor(W.txt)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 1 * scale)

            Text(i.displayName)
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundColor(W.txt)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 2 * scale)

            ZStack(alignment: .leading) {
                Capsule().fill(W.track)
                GeometryReader { g in
                    Capsule().fill(col)
                        .frame(width: g.size.width * CGFloat(min(max(i.percent, 0), 100) / 100))
                }
            }
            .frame(height: 3 * scale)
        }
        .padding(.vertical, 7 * scale).padding(.horizontal, 8 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(col.opacity(0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
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
        TimetableLockWidget()
        TimetableTimerWidget()
    }
}

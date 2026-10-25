import SwiftUI
import PhotosUI

// MARK: - Three shortcut tiles at the top of Daily summary
//
// The student picks up to three of the Academic Tools to keep one tap away: To-Do List, Final Exam Calculator, My Drive,
// Auto Attendance, Study Plan Tracker, Semester Resources. Each tile shows a live line (what is due, on / off, progress).
// Touch and hold a tile to change or remove it.

enum DailyTool: String, CaseIterable, Identifiable {
    case todo, calculator, drive, attendance, studyPlan, resources
    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: return "To-Do List"
        case .calculator: return "Final Exam"
        case .drive: return "My Drive"
        case .attendance: return "Auto Attendance"
        case .studyPlan: return "Study Plan"
        case .resources: return "Resources"
        }
    }
    var fullTitle: String {
        switch self {
        case .todo: return "To-Do List"
        case .calculator: return "Final Exam Calculator"
        case .drive: return "My Drive"
        case .attendance: return "Auto Attendance"
        case .studyPlan: return "Study Plan Tracker"
        case .resources: return "Semester Resources"
        }
    }
    var icon: String {
        switch self {
        case .todo: return "todo.book"
        case .calculator: return "function"
        case .drive: return "externaldrive"
        case .attendance: return "checkmark.circle"
        case .studyPlan: return "calendar.badge.checkmark"
        case .resources: return "books.vertical"
        }
    }
}

/// The tool's icon. "todo.book" is not an SF Symbol (it is drawn, see TodoBookIcon), so Image(systemName:) shows nothing for it
private struct DailyToolIcon: View {
    let tool: DailyTool
    var size: CGFloat = 16
    var body: some View {
        if tool.icon == "todo.book" { TodoBookIcon(size: size) } else { Image(systemName: tool.icon) }
    }
}

@MainActor
final class DailyToolStore: ObservableObject {
    static let shared = DailyToolStore()
    private static let key = "daily.tools.v1"
    static let slotCount = 3

    /// Three slots; nil = empty
    @Published private(set) var slots: [DailyTool?]

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        slots = (0..<Self.slotCount).map { i in i < saved.count ? DailyTool(rawValue: saved[i]) : nil }
    }

    /// A tool lives in one slot only: choosing it again moves it
    func set(_ tool: DailyTool?, at slot: Int) {
        guard slots.indices.contains(slot) else { return }
        if let tool, let old = slots.firstIndex(where: { $0 == tool }) { slots[old] = nil }
        slots[slot] = tool
        UserDefaults.standard.set(slots.map { $0?.rawValue ?? "" }, forKey: Self.key)
    }
}

private struct ToolSlot: Identifiable { let id: Int }

struct DailyToolsRow: View {
    @ObservedObject private var store = DailyToolStore.shared
    @State private var picking: ToolSlot?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<DailyToolStore.slotCount, id: \.self) { i in
                if let tool = store.slots[i] {
                    NavigationLink { destination(tool) } label: { DailyToolTile(tool: tool) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { picking = ToolSlot(id: i) } label: { Label("Change", systemImage: "arrow.triangle.2.circlepath") }
                            Button(role: .destructive) { withAnimation(.snappy) { store.set(nil, at: i) } } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                } else {
                    Button { picking = ToolSlot(id: i) } label: { emptyTile }
                        .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $picking) { slot in DailyToolPicker(slot: slot.id) }
    }

    @ViewBuilder private func destination(_ t: DailyTool) -> some View {
        switch t {
        case .todo: TodoListView()
        case .calculator: CAMSCalculatorScreen()
        case .drive: MyDriveView()
        case .attendance: AutoAttendanceView()
        case .studyPlan: StudyPlanTrackerView()
        case .resources: SemesterResourcesView()
        }
    }

    private var emptyTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus").font(Theme.font(.title3).weight(.semibold)).foregroundColor(Theme.accent)
            Text("Add").font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity).frame(height: 92)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .contentShape(Rectangle())
    }
}

private struct DailyToolTile: View {
    let tool: DailyTool
    @EnvironmentObject var todos: TodoStore
    @EnvironmentObject var driveAuth: DriveAuth
    @ObservedObject private var autoAtt = AutoAttendance.shared
    @ObservedObject private var plan = StudyPlanStore.shared

    private var value: String {
        switch tool {
        case .todo:
            let n = todos.pending.count
            return n == 0 ? "All done" : "\(n) to do"
        case .calculator: return "Marks needed"
        case .drive: return driveAuth.isSignedIn ? "Connected" : "Connect"
        case .attendance: return autoAtt.state.master ? "On · \(autoAtt.enabledCount)" : "Off"
        case .studyPlan: return plan.plan == nil ? "Add plan" : "\(Int((plan.percent * 100).rounded()))% done"
        case .resources: return "Calendars"
        }
    }
    private var badge: Int { tool == .todo ? todos.pending.count : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                DailyToolIcon(tool: tool, size: 18)
                    .font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.accent)
                    .frame(width: 32, height: 32).background(Theme.accent.opacity(0.16)).clipShape(Circle())
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)").font(Theme.font(.caption2).weight(.bold)).foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent).clipShape(Capsule())
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title).font(Theme.font(.footnote).weight(.semibold)).foregroundColor(Theme.txt)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(value).font(Theme.font(.caption2)).foregroundColor(Theme.muted).lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 92)
        .glowCard(radius: 14)
        .contentShape(Rectangle())
    }
}

private struct DailyToolPicker: View {
    let slot: Int
    @ObservedObject private var store = DailyToolStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(DailyTool.allCases) { t in
                        Button {
                            store.set(t, at: slot)
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                DailyToolIcon(tool: t, size: 22).font(Theme.font(.body)).foregroundColor(Theme.accent).frame(width: 26)
                                Text(t.fullTitle).foregroundColor(Theme.txt)
                                Spacer()
                                if store.slots[slot] == t {
                                    Image(systemName: "checkmark").foregroundColor(Theme.accent)
                                } else if store.slots.contains(where: { $0 == t }) {
                                    Text("In use").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                }
                            }
                            .padding(14).contentShape(Rectangle())
                            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glowCard().padding(16)
                Text("Pick a tool to keep one tap away. Touch and hold a tile to change or remove it.")
                    .font(Theme.font(.footnote)).foregroundColor(Theme.muted).padding(.horizontal, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Add a shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() }.foregroundColor(Theme.muted) } }
        }
        .preferredColorScheme(ThemeStore.shared.theme.scheme)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Back Tap setup

struct DailyBackTapGuide: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(String, String)] = [
        ("Make the Shortcut", "Open the Shortcuts app, tap + and add two actions: Take Screenshot, then Send to Daily Summary (search for iTa'leem). Add the second action directly under the first so its Screenshot field fills itself in; if it is empty, tap it and pick the Screenshot output of Take Screenshot. If you made the Shortcut before, delete the old Send to Daily Summary action and add it again. Name it \"Daily summary\"."),
        ("Turn on Back Tap", "Settings > Accessibility > Touch > Back Tap > Double Tap, then choose that Shortcut."),
        ("Use it", "On any screen with a message about a cancelled class, an assignment or a quiz, double-tap the back of the iPhone. The screenshot is read on the phone and the result shows up here."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(i + 1)").font(Theme.font(.subheadline).weight(.bold)).foregroundColor(Theme.onAccent)
                                .frame(width: 28, height: 28).background(Theme.accent).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.0).font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.txt)
                                Text(s.1).font(Theme.read(.footnote)).foregroundColor(Theme.muted)
                            }
                        }
                    }
                    Button {
                        if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                            .font(Theme.font(.subheadline).weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.accent).foregroundColor(Theme.onAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text("Copied a message instead? \"Send Clipboard to Daily Summary\" (its own action, no Screenshot field) uses the picture or text on the clipboard. The subject is found from its name, course code or short form (DES, SE...). Anything it can't place is saved as a notice so you can edit it.")
                        .font(Theme.read(.footnote)).foregroundColor(Theme.muted)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Send with Back Tap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
        }
        .preferredColorScheme(ThemeStore.shared.theme.scheme)
        .presentationDetents([.medium, .large])
    }
}

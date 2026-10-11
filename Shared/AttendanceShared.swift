import Foundation
import WidgetKit

// Shared by the app AND the widget (project.yml compiles it into both).
// The app writes this snapshot into an App Group; the widget only reads it.

struct AttendanceItem: Codable, Identifiable, Hashable {
    var id: Int            // attendance activity (cmid)
    var name: String       // subject
    var percent: Double    // maximum possible attendance, 0-100
}

struct AttendanceSnapshot: Codable {
    var items: [AttendanceItem]
    var updated: Date

    static let sample = AttendanceSnapshot(items: [
        .init(id: 1, name: "Digital Embedded Systems", percent: 90),
        .init(id: 2, name: "Software Engineering", percent: 96.7),
        .init(id: 3, name: "Computer Networks", percent: 85)
    ], updated: Date())
}

func formatPercent(_ p: Double) -> String {
    let r = (p * 10).rounded() / 10
    return r == r.rounded() ? "\(Int(r))%" : String(format: "%.1f%%", r)
}

enum AttendanceStore {
    // Must match the group in the entitlements (project.yml). The signer may rewrite bundle ids when
    // sideloading, so "group.<runtime app bundle id>" is tried first, then the original name.
    private static let originalGroup = "group.com.afiq.italeem"

    private static var appBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        let isWidget = Bundle.main.bundlePath.hasSuffix(".appex")
        return isWidget ? id.split(separator: ".").dropLast().joined(separator: ".") : id
    }

    private static var fileURL: URL? {
        for g in ["group." + appBundleID, originalGroup] {
            if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) {
                return dir.appendingPathComponent("attendance.json")
            }
        }
        return nil
    }

    /// false = the app and widget were signed without a shared App Group, so no data can be passed
    static var isShared: Bool { fileURL != nil }

    static func save(_ s: AttendanceSnapshot) {
        guard let url = fileURL, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> AttendanceSnapshot? {
        guard let url = fileURL, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AttendanceSnapshot.self, from: d)
    }

    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

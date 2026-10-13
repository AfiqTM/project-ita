import Foundation
import UserNotifications
import BackgroundTasks

// Local notifications for:
//  1. To-dos due in 24 h            (scheduled ahead of time, fire even if the app is closed)
//  2. Assignments due in < 24 h     (same)
//  3. New messages / alerts / announcements  (found by polling: every 60 s while the app is open,
//     plus a BGAppRefreshTask in the background, whose timing iOS decides)

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Must match an entry in Info.plist > "Permitted background task scheduler identifiers"
    static let refreshTaskId = "italeem.refresh"

    private var checking = false
    private let defaults = UserDefaults.standard

    // MARK: Setup

    /// Call once from App.init (background tasks must be registered before launch finishes).
    func setup() {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in NotificationManager.shared.handleRefresh(task) }
        }
    }

    /// Call once the user is signed in.
    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    // Show banners even while the app is open
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .list, .sound])
    }

    // MARK: 1 + 2. Deadline reminders

    func scheduleTodos(_ items: [TodoItem]) {
        let entries = items.filter { $0.completedAt == nil }.map {
            Entry(id: "todo.\($0.id.uuidString)",
                  title: "To-do due within 24 hours",
                  body: [$0.title, $0.courseName].compactMap { $0 }.joined(separator: " · "),
                  due: $0.due)
        }
        Task { await schedule(prefix: "due.todo.", entries) }
    }

    func scheduleAssignments(_ items: [AssignItem]) {
        let entries = items
            .filter { $0.status != nil && !$0.submitted && $0.due > 0 }   // status == nil: couldn't load, don't guess
            .map {
                Entry(id: "assign.\($0.a.id)",
                      title: "Assignment due within 24 hours",
                      body: [$0.a.name, $0.courseName].filter { !$0.isEmpty }.joined(separator: " · "),
                      due: Date(timeIntervalSince1970: TimeInterval($0.due)))
            }
        Task { await schedule(prefix: "due.assign.", entries) }
    }

    private struct Entry { let id: String; let title: String; let body: String; let due: Date }

    private func schedule(prefix: String, _ entries: [Entry]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })

        let now = Date()
        var done = Set(defaults.stringArray(forKey: "due.done") ?? [])

        // iOS keeps at most 64 pending notifications, so only the 25 soonest per type are scheduled
        for e in entries.filter({ $0.due > now }).sorted(by: { $0.due < $1.due }).prefix(25) {
            let key = "\(e.id)@\(Int(e.due.timeIntervalSince1970))"   // a changed due date counts as new
            let fireAt = e.due.addingTimeInterval(-24 * 3600)
            let delay: TimeInterval
            if fireAt > now {
                delay = fireAt.timeIntervalSince(now)
                done.insert(key)
            } else {
                // Already inside the 24 h window: remind once, right away
                guard !done.contains(key) else { continue }
                done.insert(key)
                delay = 5
            }
            let c = UNMutableNotificationContent()
            c.title = e.title
            c.body = e.body + " · due " + e.due.formatted(date: .abbreviated, time: .shortened)
            c.sound = .default
            let req = UNNotificationRequest(identifier: prefix + e.id.split(separator: ".", maxSplits: 1).last.map(String.init)!,
                                            content: c,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
            try? await center.add(req)
        }
        defaults.set(Array(done.suffix(500)), forKey: "due.done")
    }

    // MARK: 3. New messages / alerts / announcements

    func checkIncoming(uid: Int) async {
        guard uid > 0, !checking else { return }
        checking = true
        defer { checking = false }
        defaults.set(uid, forKey: "notif.uid")   // the background task has no UI to get this from
        await checkAlerts(uid)
        await checkMessages(uid)
        await updateIconBadge(uid)
    }

    /// Home-screen icon badge = unread alerts + unread chats. Runs on every check, including the
    /// background refresh, so the number stays right even when the app isn't open.
    private func updateIconBadge(_ uid: Int) async {
        var alerts: Int?
        if let n: Int = try? await MoodleAPI.shared.call(
            "message_popup_get_unread_popup_notification_count", ["useridto": uid]) {
            alerts = n
        } else if let r: NotifResp = try? await MoodleAPI.shared.call(
            "message_popup_get_popup_notifications", ["useridto": uid]) {
            alerts = r.notifications.filter { $0.read != true }.count
        }
        guard let alerts else { return }   // offline: leave the badge as it was
        await ChatStore.shared.refreshBadge(userid: uid)
        UNUserNotificationCenter.current().setBadgeCount(alerts + ChatStore.shared.unread) { _ in }
    }

    private func checkAlerts(_ uid: Int) async {
        guard let r: NotifResp = try? await MoodleAPI.shared.call(
            "message_popup_get_popup_notifications", ["useridto": uid]) else { return }
        let last = defaults.object(forKey: "notif.lastId") as? Int
        defer { defaults.set(max(r.notifications.map(\.id).max() ?? 0, last ?? 0), forKey: "notif.lastId") }
        guard let last else { return }   // very first run: remember what exists, don't notify for old items

        let fresh = r.notifications.filter { $0.id > last && $0.read != true }.sorted { $0.id < $1.id }
        for n in fresh.suffix(5) {
            let text = ((n.subject ?? "") + " " + (n.smallmessage ?? "")).lowercased()
            let title: String
            if n.component == "mod_forum" {
                title = (text.contains("announcement") || text.contains("news")) ? "New announcement" : "New forum post"
            } else {
                title = "New alert"
            }
            var body = n.subject ?? ""
            if let m = n.smallmessage?.plainText, !m.isEmpty { body += body.isEmpty ? m : "\n" + m }
            await post(id: "alert.\(n.id)", title: title, body: body)
        }
    }

    private func checkMessages(_ uid: Int) async {
        guard let r: ChatConvResp = try? await MoodleAPI.shared.call(
            "core_message_get_conversations", ["userid": uid, "limitfrom": 0, "limitnum": 50]) else { return }
        let saved = defaults.dictionary(forKey: "msg.seen") as? [String: Int]
        let firstRun = saved == nil
        var seen = saved ?? [:]

        for c in r.conversations where c.type != 3 {   // 3 = notes to self
            guard let m = c.messages?.max(by: { $0.id < $1.id }) else { continue }
            let prev = seen[String(c.id)] ?? 0
            seen[String(c.id)] = max(prev, m.id)
            if !firstRun, m.id > prev, c.unread > 0, m.useridfrom != uid {
                await post(id: "msg.\(m.id)", title: c.title, body: m.text?.plainText ?? "New message")
            }
        }
        defaults.set(seen, forKey: "msg.seen")
    }

    private func post(id: String, title: String, body: String) async {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = String(body.prefix(160))
        c.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: Background refresh

    /// Ask iOS for another background check (call when the app goes to the background).
    func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)   // a minimum, not a promise
        try? BGTaskScheduler.shared.submit(r)
    }

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()   // chain the next one
        let work = Task {
            // The app may have been launched in the background without any UI: load the session ourselves
            if MoodleAPI.shared.token.isEmpty, let s = Keychain.load() {
                MoodleAPI.shared.token = s.token
                MoodleAPI.shared.privateToken = s.privateToken
            }
            await checkIncoming(uid: defaults.integer(forKey: "notif.uid"))
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

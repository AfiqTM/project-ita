import SwiftUI
import Combine

// MARK: - Dev mode (Others > App Preferences > Dev mode)
//
// A switch that shows copyable logs for the things that are hard to debug from the outside:
//   - Saved login: every automatic sign-in and every host the sign-in talked to (for a DNS allowlist)
//   - Auto Attendance: the last attempts the server made, and every call the app made to the server
//   - Noticeboard AI: what was sent to the AI server and what came back, item by item
// Each log is shown inside its own tool's screen (Saved login, Auto Attendance, Noticeboard).
// The logs are always kept (a few dozen short lines each, on this phone only); the switch only shows them.
// Passwords, tokens, access keys and authenticator codes are never written to a log.

enum DevMode {
    static let key = "dev.enabled"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Dev mode is only offered to the account named Muhammad Afiq
    static func allowed(_ fullname: String?) -> Bool {
        (fullname ?? "").lowercased().contains("muhammad afiq")
    }
}

enum DevChannel: String, CaseIterable, Identifiable {
    case login, attendance, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .login: return "Saved login"
        case .attendance: return "Auto Attendance (app and server)"
        case .ai: return "Noticeboard AI"
        }
    }
}

struct DevLine: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var ok: Bool?
    var text: String
}

enum DevHostStatus: String, Codable { case ok, failed, seen }

struct DevHostEntry: Codable {
    var host: String
    var status: DevHostStatus
    var note: String
    var date: Date
}

enum DevLog {
    static let keep = 80
    static let changed = Notification.Name("devlog.changed")
    private static let lock = NSLock()

    private static func key(_ c: DevChannel) -> String { "dev.log." + c.rawValue }

    private static func read(_ c: DevChannel) -> [DevLine] {
        guard let d = UserDefaults.standard.data(forKey: key(c)),
              let a = try? JSONDecoder().decode([DevLine].self, from: d) else { return [] }
        return a
    }

    /// Newest first
    static func load(_ c: DevChannel) -> [DevLine] { lock.lock(); defer { lock.unlock() }; return read(c) }

    static func add(_ c: DevChannel, _ text: String, ok: Bool? = nil) {
        lock.lock()
        var all = read(c)
        all.insert(DevLine(date: Date(), ok: ok, text: String(text.prefix(700))), at: 0)
        if all.count > keep { all = Array(all.prefix(keep)) }
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key(c)) }
        lock.unlock()
        notify()
    }

    static func clear(_ c: DevChannel) {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: key(c))
        lock.unlock()
        notify()
    }

    private static func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM HH:mm:ss"
        return f.string(from: d)
    }

    static func text(_ c: DevChannel) -> String {
        load(c).map { l in
            let mark = l.ok == nil ? "-" : (l.ok == true ? "OK" : "FAIL")
            return "[\(stamp(l.date))] \(mark) \(l.text)"
        }.joined(separator: "\n")
    }

    // MARK: network errors and hosts

    static func label(_ u: URL) -> String { (u.host ?? "") + (u.port.map { ":\($0)" } ?? "") }

    /// The full URL for a log line (scheme, host, port, path, query). Only secrets are blanked out:
    /// ticket / token / key / password / code values, session ids, and anything after a #.
    static func exact(_ u: URL) -> String {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u.absoluteString }
        let secret: Set<String> = ["ticket", "token", "wstoken", "privatetoken", "key", "passport", "password", "pass", "code",
                                   "sesskey", "sid", "sessionid", "jsessionid", "auth", "secret", "otp"]
        c.queryItems = c.queryItems?.map { secret.contains($0.name.lowercased()) ? URLQueryItem(name: $0.name, value: "***") : $0 }
        c.fragment = nil
        c.user = nil
        c.password = nil
        let s = c.string ?? u.absoluteString
        return s.replacingOccurrences(of: ";jsessionid=[^?/#]*", with: ";jsessionid=***", options: [.regularExpression, .caseInsensitive])
    }

    /// Logs a failed request with the host it was for, and remembers that host as failing
    /// (a DNS filter that blocks a host shows up as "cannot find host" / "DNS lookup failed" / timeout).
    static func network(_ c: DevChannel, _ error: Error, _ what: String) {
        let e = error as NSError
        var url: URL?
        if let u = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL { url = u }
        else if let s = e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { url = URL(string: s) }
        var hint = ""
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: hint = " -> DNS could not resolve the host (allowlist it)"
            case NSURLErrorTimedOut: hint = " -> timed out (blocked or very slow)"
            case NSURLErrorCannotConnectToHost: hint = " -> connection refused or blocked"
            case NSURLErrorNotConnectedToInternet: hint = " -> no internet connection"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                hint = " -> TLS failed (a DNS filter can answer with a block page)"
            default: break
            }
        }
        let host = url.map { label($0) }
        add(c, "\(what): \(e.domain) \(e.code) \(e.localizedDescription)\(hint)\(host.map { " [\($0)]" } ?? "")", ok: false)
        if let h = host, !h.isEmpty { self.host(h, .failed, "\(e.domain) \(e.code)") }
    }

    private static let hostKey = "dev.hosts"

    private static func readHosts() -> [String: DevHostEntry] {
        guard let d = UserDefaults.standard.data(forKey: hostKey),
              let a = try? JSONDecoder().decode([String: DevHostEntry].self, from: d) else { return [:] }
        return a
    }

    /// Remembers how the last request to a host went. A host that was only seen in a page is not allowed to
    /// overwrite a real result.
    static func host(_ h: String, _ status: DevHostStatus, _ note: String = "") {
        guard !h.isEmpty else { return }
        lock.lock()
        var all = readHosts()
        if status == .seen, all[h] != nil { lock.unlock(); return }
        all[h] = DevHostEntry(host: h, status: status, note: note, date: Date())
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: hostKey) }
        lock.unlock()
        notify()
    }

    static func hosts() -> [DevHostEntry] {
        lock.lock(); defer { lock.unlock() }
        return readHosts().values.sorted { $0.host < $1.host }
    }

    static func clearHosts() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: hostKey)
        lock.unlock()
        notify()
    }

    // MARK: a stored picture of something read from outside (the server's last attempts)

    static func setSnapshot(_ c: DevChannel, _ lines: [String]) {
        UserDefaults.standard.set(["date": Date().timeIntervalSince1970, "lines": lines] as [String: Any],
                                  forKey: "dev.snap." + c.rawValue)
        notify()
    }

    static func snapshot(_ c: DevChannel) -> (date: Date, lines: [String])? {
        guard let o = UserDefaults.standard.dictionary(forKey: "dev.snap." + c.rawValue),
              let t = o["date"] as? Double, let l = o["lines"] as? [String] else { return nil }
        return (Date(timeIntervalSince1970: t), l)
    }
}

// MARK: - Cards

/// The log of one channel, as text that can be selected and copied
struct DevLogCard: View {
    let channel: DevChannel
    var title: String?
    @State private var lines: [DevLine] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text((title ?? channel.title).uppercased()).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = DevLog.text(channel)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(lines.isEmpty)
                if !lines.isEmpty { Button("Clear") { DevLog.clear(channel) } }
            }
            .font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.accent)
            if lines.isEmpty {
                Text("Nothing logged yet.").font(Theme.font(.caption)).foregroundColor(Theme.muted)
            } else {
                Text(verbatim: DevLog.text(channel))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.txt)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()
        .onAppear { lines = DevLog.load(channel) }
        .onReceive(NotificationCenter.default.publisher(for: DevLog.changed)) { _ in lines = DevLog.load(channel) }
    }
}

/// Every host the app has talked to, and how the last request went: the list to put in a DNS allowlist
struct DevHostsCard: View {
    @ObservedObject private var att = AutoAttendance.shared
    @State private var rows: [DevHostEntry] = []
    @State private var copied = false

    /// Hosts the app is known to need, even before any request was made to them
    private var expected: [String] {
        var h: [String] = []
        if let s = Site.url.host { h.append(s) }
        h.append(DevLog.label(CASLogin.casURL))
        if let s = att.serverURL, let host = s.host, !host.isEmpty { h.append(DevLog.label(s)) }
        return h
    }

    private var merged: [DevHostEntry] {
        var out = rows
        for h in expected where !out.contains(where: { $0.host == h }) {
            out.append(DevHostEntry(host: h, status: .seen, note: "not tried yet", date: .distantPast))
        }
        return out.sorted { $0.host < $1.host }
    }

    private func icon(_ s: DevHostStatus) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .seen: return "circle.dashed"
        }
    }

    private func tint(_ s: DevHostStatus) -> Color {
        switch s {
        case .ok: return Color.green
        case .failed: return Color.red.opacity(0.85)
        case .seen: return Theme.muted
        }
    }

    private func bare(_ h: String) -> String { String(h.split(separator: ":").first ?? Substring(h)) }

    private var allowlist: String {
        Array(Set(merged.map { bare($0.host) })).sorted().joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("HOSTS (FOR A DNS ALLOWLIST)").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                Spacer()
                Button(copied ? "Copied" : "Copy list") {
                    UIPasteboard.general.string = allowlist
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                if !rows.isEmpty { Button("Clear") { DevLog.clearHosts() } }
            }
            .font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.accent)
            ForEach(merged, id: \.host) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(r.status)).foregroundColor(tint(r.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: r.host).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.txt)
                            .textSelection(.enabled)
                        Text(r.date == .distantPast ? r.note : r.note + " · " + DevLog.stamp(r.date))
                            .font(Theme.font(.caption2)).foregroundColor(Theme.muted)
                    }
                }
            }
            Text("Failed hosts are the ones your DNS blocks. The copied list has the host names only (no port).")
                .font(Theme.font(.caption2)).foregroundColor(Theme.muted)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()
        .onAppear { rows = DevLog.hosts() }
        .onReceive(NotificationCenter.default.publisher(for: DevLog.changed)) { _ in rows = DevLog.hosts() }
    }
}

/// The last attempts the server made (read from its status), and what the app did with the server
struct DevAttendanceCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var m = AutoAttendance.shared
    @State private var snapDate: Date?
    @State private var snapLines: [String] = []
    @State private var net: [DevLine] = []
    @State private var copied = false
    @State private var busy = false

    private var fullText: String {
        var s = "LAST ATTEMPTS"
        if let d = snapDate { s += " (server status read " + DevLog.stamp(d) + ")" }
        s += "\n" + (snapLines.isEmpty ? "none yet" : snapLines.joined(separator: "\n"))
        s += "\n\nAPP <-> SERVER\n" + (net.isEmpty ? "nothing logged yet" : DevLog.text(.attendance))
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("AUTO ATTENDANCE LOG").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = fullText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button { Task { await refresh() } } label: {
                    if busy { ProgressView().tint(Theme.accent) } else { Text("Refresh") }
                }
                .disabled(busy || !m.serverReady)
                if !net.isEmpty { Button("Clear") { DevLog.clear(.attendance) } }
            }
            .font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.accent)
            Text(verbatim: fullText)
                .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.txt)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !m.serverReady {
                Text("The server address or access key isn't set, so there is nothing to read from it.")
                    .font(Theme.font(.caption2)).foregroundColor(Theme.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: DevLog.changed)) { _ in load() }
        .task { await refresh() }
    }

    private func load() {
        net = DevLog.load(.attendance)
        if let s = DevLog.snapshot(.attendance) { snapDate = s.date; snapLines = s.lines }
    }

    private func refresh() async {
        guard m.serverReady else { load(); return }
        busy = true
        if let uid = app.site?.userid, uid > 0 { m.userid = uid }
        await m.fetchStatus()
        load()
        busy = false
    }
}

// MARK: - Rows for Others > App Preferences

// MARK: - Screen with all of them (opened with the > on the Dev mode row)

struct DevLogsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Everything here is stored on this phone only. Tap and hold a log to select text, or use Copy. The same logs also show inside each tool.")
                    .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                DevHostsCard()
                DevLogCard(channel: .login)
                DevAttendanceCard()
                DevLogCard(channel: .ai)
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Dev tools")
        .navigationBarTitleDisplayMode(.inline)
        .notebookBack()
    }
}

// MARK: - Row for Others > App Preferences: the switch, and a > that opens all the logs

struct DevModeRow: View {
    @AppStorage(DevMode.key) private var on = false
    @State private var open = false

    var body: some View {
        HStack(spacing: 14) {
            Button { open = true } label: {
                HStack(spacing: 14) {
                    RowIcon { Image(systemName: "hammer") }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dev mode").foregroundColor(Theme.txt).rocks(15, normal: .subheadline.weight(.semibold))
                        Text(on ? "On · copyable logs" : "Off").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: $on).labelsHidden().tint(Theme.accent)

            Button { open = true } label: {
                Image(systemName: "chevron.right").font(Theme.font(.caption).weight(.semibold)).foregroundColor(Theme.muted)
                    .padding(.vertical, 6).padding(.leading, 2)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RowDivider(), alignment: .bottom)
        .navigationDestination(isPresented: $open) { DevLogsView() }
    }
}
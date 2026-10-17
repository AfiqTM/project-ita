import SwiftUI

// MARK: - Changes made with no internet
//
// Submitting / saving / removing an assignment submission while offline is kept on the phone and sent
// automatically once the connection is back (and again whenever the app is opened). A notification tells
// the user when it went through, or why the site refused it. To-dos, CAMS marks, pins and files saved to
// a subject are already stored on the phone first; SyncManager sends them when the connection returns
// (see SyncManager.swift).
//
// A job the site refuses (deadline passed, submission locked, ...) is NOT thrown away: it stays on the
// assignment screen with the reason, with Retry and Discard buttons.

extension Notification.Name {
    /// The phone got a connection again after being offline
    static let offlineNetworkReturned = Notification.Name("italeem.offline.networkReturned")
    /// A queued change reached the site
    static let offlineQueueSent = Notification.Name("italeem.offline.queueSent")
}

func isOfflineError(_ e: Error) -> Bool {
    guard let u = e as? URLError else { return false }
    return MoodleAPI.offlineCodes.contains(u.code)
}

struct KeptFile: Codable { var name: String; var url: String }

struct SubmissionJob: Codable, Identifiable {
    enum Kind: String, Codable { case save, remove }
    var id = UUID()
    var kind: Kind
    var assignId: Int
    var name: String                 // assignment name, for the notification
    var due: Int?                    // assignment due time (seconds since 1970), for the "still waiting" reminders
    var created = Date()
    // save
    var text: String?
    var submit = false
    var rebuildFiles = false         // the file area must be rebuilt (files added or removed)
    var keep: [KeptFile] = []        // files already on the site that stay (downloaded again when sent)
    var newFiles: [String] = []      // names of the new files kept in the queue folder
    // remove
    var userid = 0
    var hasText = false
    var hasFiles = false
    // set when the site refused it
    var error: String?
    // background upload progress (see BackgroundUpload.swift); optional so older queue files still load
    var bgActive: Bool?              // a file of this job is being sent by iOS right now
    var bgStarted: Double?           // when it was handed to iOS (seconds since 1970)
    var bgNext: Int?                 // index of the next file to upload; == newFiles.count when all are up
    var bgItem: Int?                 // draft item id returned by the site for the files uploaded so far
}

extension MoodleAPI {
    /// Does one job against the site. Used for a normal tap and for a queued job alike.
    func run(_ job: SubmissionJob, newFiles: [URL]) async throws {
        switch job.kind {
        case .remove:
            try await removeSubmission(assignId: job.assignId, userid: job.userid,
                                       hasText: job.hasText, hasFiles: job.hasFiles)
        case .save:
            var item: Int? = nil
            if job.rebuildFiles {
                // Saving files replaces the whole file area, so rebuild it: files being kept + new files.
                var toUpload: [URL] = []
                for f in job.keep {
                    toUpload.append(try await downloadToTemp(FileRef(filename: f.name, fileurl: f.url)))
                }
                toUpload.append(contentsOf: newFiles)
                for f in toUpload { item = try await uploadDraft(f, itemid: item ?? 0) }
                if toUpload.isEmpty { item = emptyDraftId() }   // everything removed
            }
            try await saveSubmission(assignId: job.assignId, text: job.text, draftItemId: item)
            if job.submit { try await submitForGrading(assignId: job.assignId) }
        }
    }
}

@MainActor
final class OfflineQueue: ObservableObject {
    static let shared = OfflineQueue()
    @Published private(set) var jobs: [SubmissionJob] = []

    private var flushing = false
    private var retry: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("OfflineQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        return d
    }()
    private var indexURL: URL { dir.appendingPathComponent("queue.json") }

    private init() {
        if let d = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([SubmissionJob].self, from: d) { jobs = list }
        observer = NotificationCenter.default.addObserver(forName: .offlineNetworkReturned, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // let the connection settle
                await self?.flush()
            }
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: indexURL, options: .atomic) }
    }
    private func folder(_ j: SubmissionJob) -> URL { dir.appendingPathComponent(j.id.uuidString, isDirectory: true) }
    private func files(_ j: SubmissionJob) -> [URL] { j.newFiles.map { folder(j).appendingPathComponent($0) } }

    func job(for assignId: Int) -> SubmissionJob? { jobs.first { $0.assignId == assignId } }

    /// Only when offline support is on and the failure really was "no connection"
    func shouldQueue(_ error: Error) -> Bool { OfflineSettings.enabled && isOfflineError(error) }

    /// Keeps the job (and copies of its files) on the phone. A newer change to the same assignment replaces the older one.
    func enqueue(_ job: SubmissionJob, files picked: [URL]) {
        var j = job
        for old in jobs where old.assignId == j.assignId {
            try? FileManager.default.removeItem(at: folder(old))
            NotificationManager.shared.cancelQueueReminders(old.id)   // its reminders go with it
        }
        jobs.removeAll { $0.assignId == j.assignId }
        try? FileManager.default.createDirectory(at: folder(j), withIntermediateDirectories: true)
        j.newFiles = []
        for u in picked {
            let dest = folder(j).appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { j.newFiles.append(u.lastPathComponent) }
        }
        jobs.append(j)
        persist()
        scheduleRetry()
        NotificationManager.shared.scheduleQueueReminders(j)
        // New files: let iOS upload them even if the app gets closed (and wait for a connection if there is none)
        if BackgroundUploader.handles(j) { Task { _ = await startBackground(j.id) } }
    }

    func discard(_ id: UUID) {
        if let j = jobs.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: folder(j)) }
        jobs.removeAll { $0.id == id }
        persist()
        NotificationManager.shared.cancelQueueReminders(id)
        BackgroundUploader.shared.cancel(id)
    }

    func clear() {
        for j in jobs { NotificationManager.shared.cancelQueueReminders(j.id) }
        BackgroundUploader.shared.cancelAll()
        jobs = []
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Retry a job the site refused earlier
    func retryNow(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].error = nil; persist()
            NotificationManager.shared.scheduleQueueReminders(jobs[i])   // waiting again
        }
        Task { await flush() }
    }

    /// Sends everything waiting. Safe to call any time (app opened, connection back, background refresh).
    func flush() async {
        guard !flushing, OfflineNet.shared.online, !jobs.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        var sentAny = false
        for j in jobs where j.error == nil {
            // new files only: iOS uploads them in the background, save + submit follow when it is done
            if BackgroundUploader.handles(j), await startBackground(j.id) { continue }
            do {
                try await MoodleAPI.shared.run(j, newFiles: files(j))
                try? FileManager.default.removeItem(at: folder(j))
                jobs.removeAll { $0.id == j.id }
                persist()
                NotificationManager.shared.cancelQueueReminders(j.id)
                sentAny = true
                let title: String
                switch (j.kind, j.submit) {
                case (.remove, _): title = "Submission removed: \(j.name)"
                case (.save, true): title = "Submitted: \(j.name)"
                case (.save, false): title = "Saved: \(j.name)"
                }
                await NotificationManager.shared.notify(id: "queue.\(j.id.uuidString)", title: title,
                                                        body: "Sent now that you're back online.")
            } catch {
                if isOfflineError(error) || error is CancellationError { scheduleRetry(); break }   // still no connection
                // the site said no: keep it, with the reason
                if let i = jobs.firstIndex(where: { $0.id == j.id }) {
                    jobs[i].error = error.localizedDescription
                    persist()
                }
                NotificationManager.shared.cancelQueueReminders(j.id)   // the site refused it: no point nagging
                await NotificationManager.shared.notify(
                    id: "queue.\(j.id.uuidString)", title: "Couldn't send: \(j.name)",
                    body: error.localizedDescription + " Open the assignment to retry or discard it.")
            }
        }
        if sentAny { NotificationCenter.default.post(name: .offlineQueueSent, object: nil) }
    }

    // MARK: background upload (the file transfer itself is done by iOS, see BackgroundUpload.swift)

    private var finishing = Set<UUID>()

    /// The app may have been started by iOS with no screen: load the saved session ourselves
    private func restoreSession() {
        if MoodleAPI.shared.token.isEmpty, let s = Keychain.load() {
            MoodleAPI.shared.token = s.token
            MoodleAPI.shared.privateToken = s.privateToken
        }
    }

    /// Hands the next file of a job to iOS, or runs save + submit when every file is up.
    /// Returns false when the job can't go this way, so the normal path in flush() takes over.
    func startBackground(_ id: UUID) async -> Bool {
        restoreSession()
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return true }
        if jobs[i].bgActive == true {
            // already with iOS: only take it back if iOS has lost track of it
            if Date().timeIntervalSince1970 - (jobs[i].bgStarted ?? 0) < 120 { return true }
            if await BackgroundUploader.shared.isRunning(id) { return true }
            guard let k = jobs.firstIndex(where: { $0.id == id }) else { return true }
            jobs[k].bgActive = false
        }
        guard let k = jobs.firstIndex(where: { $0.id == id }) else { return true }
        let next = jobs[k].bgNext ?? 0
        if next >= jobs[k].newFiles.count { await finishBackground(id); return true }
        do {
            try BackgroundUploader.shared.start(file: files(jobs[k])[next], itemid: jobs[k].bgItem ?? 0,
                                                token: MoodleAPI.shared.token, jobId: id, index: next,
                                                dir: folder(jobs[k]))
        } catch {
            return false
        }
        jobs[k].bgActive = true
        jobs[k].bgStarted = Date().timeIntervalSince1970
        persist()
        return true
    }

    /// iOS finished (or gave up on) one file of a job. May run in a relaunched app with no screen.
    func backgroundUploadFinished(desc: String, body: Data?, error: Error?) async {
        restoreSession()
        let parts = desc.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let idx = Int(parts[1]),
              let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].bgActive = false
        try? FileManager.default.removeItem(at: folder(jobs[i]).appendingPathComponent("upload-\(idx).body"))
        if let error {
            persist()
            if (error as? URLError)?.code == .cancelled { return }          // discarded
            if isOfflineError(error) { scheduleRetry(); return }            // restarted when the connection is back
            await fail(id, error.localizedDescription)
            return
        }
        let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        if let arr = obj as? [[String: Any]], let item = arr.first?["itemid"] as? Int {
            jobs[i].bgItem = item
            jobs[i].bgNext = idx + 1
            persist()
            _ = await startBackground(id)   // the next file, or save + submit after the last one
        } else {
            await fail(id, ((obj as? [String: Any])?["error"] as? String) ?? "Upload failed")
        }
    }

    /// All files are up: save the submission, submit it if that was asked, then tell the user
    private func finishBackground(_ id: UUID) async {
        guard !finishing.contains(id), let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        finishing.insert(id)
        defer { finishing.remove(id) }
        let j = jobs[i]
        do {
            try await MoodleAPI.shared.saveSubmission(assignId: j.assignId, text: j.text, draftItemId: j.bgItem)
            if j.submit { try await MoodleAPI.shared.submitForGrading(assignId: j.assignId) }
            try? FileManager.default.removeItem(at: folder(j))
            jobs.removeAll { $0.id == j.id }
            persist()
            NotificationManager.shared.cancelQueueReminders(j.id)
            let title = j.submit ? "Submitted: \(j.name)" : "Saved: \(j.name)"
            await NotificationManager.shared.notify(id: "queue.\(j.id.uuidString)", title: title,
                                                    body: "Sent in the background, you didn't need to open the app.")
            NotificationCenter.default.post(name: .offlineQueueSent, object: nil)
        } catch {
            if isOfflineError(error) || error is CancellationError { scheduleRetry(); return }   // retried later
            await fail(id, error.localizedDescription)
        }
    }

    /// The site refused it (or the upload failed for good): keep the job with the reason, tell the user
    private func fail(_ id: UUID, _ message: String) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].error = message
        persist()
        NotificationManager.shared.cancelQueueReminders(id)
        await NotificationManager.shared.notify(
            id: "queue.\(id.uuidString)", title: "Couldn't send: \(jobs[i].name)",
            body: message + " Open the assignment to retry or discard it.")
    }

    /// If the connection looks fine but the send failed, try again in a while
    private func scheduleRetry() {
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !Task.isCancelled { await flush() }
        }
    }
}

// MARK: - Note on the assignment screen

struct QueuedNote: View {
    let assignId: Int
    @ObservedObject private var queue = OfflineQueue.shared

    var body: some View {
        if let j = queue.job(for: assignId) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: j.error == nil ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                    Text(j.error == nil
                         ? "Waiting for internet · your \(j.kind == .remove ? "removal" : (j.submit ? "submission" : "changes")) will be sent automatically"
                         : "Couldn't send: \(j.error ?? "")")
                        .font(Theme.font(.caption))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if j.error != nil {
                    HStack(spacing: 18) {
                        Button("Retry") { queue.retryNow(j.id) }
                        Button("Discard", role: .destructive) { queue.discard(j.id) }
                    }
                    .font(Theme.font(.caption).weight(.semibold))
                    .foregroundColor(Theme.accent)
                } else {
                    Button("Cancel", role: .destructive) { queue.discard(j.id) }
                        .font(Theme.font(.caption).weight(.semibold))
                }
            }
            .foregroundColor(Theme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line))
        }
    }
}

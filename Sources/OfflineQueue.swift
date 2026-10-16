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
        for old in jobs where old.assignId == j.assignId { try? FileManager.default.removeItem(at: folder(old)) }
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
    }

    func discard(_ id: UUID) {
        if let j = jobs.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: folder(j)) }
        jobs.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        jobs = []
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Retry a job the site refused earlier
    func retryNow(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].error = nil; persist() }
        Task { await flush() }
    }

    /// Sends everything waiting. Safe to call any time (app opened, connection back, background refresh).
    func flush() async {
        guard !flushing, OfflineNet.shared.online, !jobs.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        var sentAny = false
        for j in jobs where j.error == nil {
            do {
                try await MoodleAPI.shared.run(j, newFiles: files(j))
                try? FileManager.default.removeItem(at: folder(j))
                jobs.removeAll { $0.id == j.id }
                persist()
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
                await NotificationManager.shared.notify(
                    id: "queue.\(j.id.uuidString)", title: "Couldn't send: \(j.name)",
                    body: error.localizedDescription + " Open the assignment to retry or discard it.")
            }
        }
        if sentAny { NotificationCenter.default.post(name: .offlineQueueSent, object: nil) }
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
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if j.error != nil {
                    HStack(spacing: 18) {
                        Button("Retry") { queue.retryNow(j.id) }
                        Button("Discard", role: .destructive) { queue.discard(j.id) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
                } else {
                    Button("Cancel", role: .destructive) { queue.discard(j.id) }
                        .font(.caption.weight(.semibold))
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

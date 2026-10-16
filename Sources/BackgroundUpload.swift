import SwiftUI

// MARK: - Uploads that keep going when the app is closed
//
// A submission that was queued offline uploads its new files through a *background* URLSession: iOS
// performs the transfer itself (waiting for a connection if there isn't one), even while the app is
// suspended or closed. When a file has gone up, iOS starts the app for a few seconds and calls the
// delegate below; OfflineQueue then uploads the next file, or, after the last one, runs "save" and
// "submit" (two small calls) and posts the "Submitted" notification.
//
// Only the simple case goes this way (see `handles`): new files and nothing kept from an earlier
// submission. Anything else is sent by the normal OfflineQueue.flush() when the app is open.
// If the app was force-quit, iOS finishes the upload but does not start the app again, so save/submit
// wait until the next time it is opened.

final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let identifier = "com.afiq.italeem.upload"

    /// Handed over by iOS when it starts the app for finished transfers; called once everything is processed
    var systemCompletion: (() -> Void)?

    private let lock = NSLock()
    private var received: [Int: Data] = [:]
    private var work: [Task<Void, Never>] = []

    /// Created on first use; with the same identifier after a relaunch, so iOS delivers the finished transfers
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.waitsForConnectivity = true          // no connection yet: wait instead of failing
        c.sessionSendsLaunchEvents = true      // start the app when a transfer finishes
        c.isDiscretionary = false              // don't hold it back for Wi-Fi / charging
        c.timeoutIntervalForResource = 3 * 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// A job this uploader can take: a save with new files and nothing to download first
    static func handles(_ j: SubmissionJob) -> Bool {
        j.kind == .save && j.rebuildFiles && j.keep.isEmpty && !j.newFiles.isEmpty
    }

    // MARK: start / cancel

    /// Builds the multipart body in a file (a 50 MB file is never held in memory) and hands it to iOS
    func start(file: URL, itemid: Int, token: String, jobId: UUID, index: Int, dir: URL) throws {
        let boundary = "Boundary-" + UUID().uuidString
        let bodyURL = dir.appendingPathComponent("upload-\(index).body")
        try? FileManager.default.removeItem(at: bodyURL)
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw APIError(message: "Couldn't prepare the upload")
        }
        let out = try FileHandle(forWritingTo: bodyURL)
        func put(_ s: String) throws { try out.write(contentsOf: Data(s.utf8)) }
        do {
            for (n, v) in [("token", token), ("filearea", "draft"), ("itemid", String(itemid))] {
                try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n")
            }
            let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
            try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_1\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try put("\r\n--\(boundary)--\r\n")
            try out.close()
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }

        var req = URLRequest(url: Site.url.appendingPathComponent("webservice/upload.php"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: req, fromFile: bodyURL)
        task.taskDescription = "\(jobId.uuidString)|\(index)"
        task.resume()
    }

    /// Is a transfer for this job still known to iOS?
    func isRunning(_ jobId: UUID) async -> Bool {
        let tasks = await session.allTasks
        return tasks.contains { ($0.taskDescription ?? "").hasPrefix(jobId.uuidString) && $0.state != .completed }
    }

    func cancel(_ jobId: UUID) {
        session.getAllTasks { tasks in
            for t in tasks where (t.taskDescription ?? "").hasPrefix(jobId.uuidString) { t.cancel() }
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    // MARK: URLSession delegate (runs on a background queue, also when iOS started the app for it)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); received[dataTask.taskIdentifier, default: Data()].append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let body = received.removeValue(forKey: task.taskIdentifier); lock.unlock()
        var failure = error
        if failure == nil, let h = task.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            failure = APIError(message: "The site refused the upload (HTTP \(h.statusCode))")
        }
        let desc = task.taskDescription ?? ""
        let finalError = failure
        let t = Task { @MainActor in
            // keep the app alive long enough for save + submit after the last file
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = UIApplication.shared.beginBackgroundTask(withName: "submission") {
                UIApplication.shared.endBackgroundTask(bg); bg = .invalid
            }
            await OfflineQueue.shared.backgroundUploadFinished(desc: desc, body: body, error: finalError)
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        lock.lock(); work.append(t); lock.unlock()
    }

    /// iOS has delivered every event it was holding: finish the work, then tell iOS we are done
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let pending = work; work = []; lock.unlock()
        Task { @MainActor in
            for t in pending { await t.value }
            let done = self.systemCompletion
            self.systemCompletion = nil
            done?()
        }
    }
}

// MARK: - App delegate: iOS starts the app here when a background transfer has finished

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.identifier else { completionHandler(); return }
        BackgroundUploader.shared.systemCompletion = completionHandler
        _ = BackgroundUploader.shared.session   // recreate the session so the held events are delivered
    }
}

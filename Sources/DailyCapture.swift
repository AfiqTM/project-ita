import SwiftUI
import UIKit
import Vision
import ImageIO
import AppIntents

// MARK: - Send a screenshot to Daily summary
//
// The screenshot is read on the phone (Vision text recognition), then the same readers as for announcements look at it:
// the AI server when it is set up, the built-in keyword reader otherwise. Class changes, assignments and quizzes become
// entries in Daily summary; the subject is found from the text (name, course code or short form such as DES / SE).
// Anything the readers can't place is still saved as a Notice with the text, so a screenshot is never lost.
//
// Double-tap on the back of the iPhone: Settings > Accessibility > Touch > Back Tap > Double Tap > a Shortcut that does
// "Take Screenshot" and then "Send to Daily Summary" (this file's App Intent). The steps are shown in Daily summary too.

enum DailyCapture {
    struct Outcome {
        var message: String
        var entries: [DailyEntry]
    }

    // MARK: reading the image

    /// Text in the picture, line by line (Vision runs off the main thread)
    static func recognizeText(data: Data) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                func run(_ make: () -> VNImageRequestHandler?) -> String {
                    guard let handler = make() else { return "" }
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .accurate
                    req.usesLanguageCorrection = true
                    req.usesCPUOnly = true               // a Shortcut may run us in the background, where the GPU is off limits
                    try? handler.perform([req])
                    let lines = (req.results ?? []).compactMap { ($0 as? VNRecognizedTextObservation)?.topCandidates(1).first?.string }
                    return lines.joined(separator: "\n")
                }
                var text = run { VNImageRequestHandler(data: data, options: [:]) }
                if text.isEmpty, let ui = UIImage(data: data), let cg = ui.cgImage {      // a second way in (HEIC, odd colour spaces)
                    text = run { VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(ui.imageOrientation), options: [:]) }
                }
                cont.resume(returning: text)
            }
        }
    }

    /// OCR breaks a sentence at the edge of the screen: join lines unless one ends a sentence
    private static func tidy(_ raw: String) -> String {
        var out = ""
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let last = out.last, ".!?:;".contains(last) { out += "\n" } else if !out.isEmpty { out += " " }
            out += t
        }
        return out
    }

    // MARK: finding the subject

    private static let stop: Set<String> = ["and", "of", "the", "to", "in", "for", "a", "an", "on", "with", "&"]

    private static func alnum(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func match(_ text: String, in courses: [Course]) -> Course? {
        let padded = " " + alnum(text) + " "
        let compact = padded.replacingOccurrences(of: " ", with: "")
        var best: (course: Course, score: Int)?
        for c in courses {
            var score = 0
            let name = alnum(c.subjectName)
            if name.count > 3, padded.contains(" " + name + " ") { score = 100 }
            // course code: BICS 2306 / BICS2306
            if let re = try? NSRegularExpression(pattern: "[A-Za-z]{2,5}\\s?\\d{4}") {
                for src in [c.fullname, c.shortname ?? ""] {
                    let ns = src as NSString
                    for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                        let code = ns.substring(with: m.range).lowercased().replacingOccurrences(of: " ", with: "")
                        if compact.contains(code) { score = max(score, 90) }
                    }
                }
            }
            // short form: first letters of the subject name (Digital & Embedded Systems -> DES, Software Engineering -> SE)
            let words = name.split(separator: " ").map(String.init).filter { !stop.contains($0) }
            if words.count >= 2 {
                let ac = words.compactMap { $0.first }.map { String($0) }.joined()
                let pattern = "\\b" + ac.uppercased() + "\\b"
                let opts: String.CompareOptions = ac.count == 2 ? [.regularExpression] : [.regularExpression, .caseInsensitive]
                if text.range(of: pattern, options: opts) != nil { score = max(score, 70) }
                // most of the long words of the name
                let long = words.filter { $0.count > 3 }
                if long.count >= 2 {
                    let hit = long.filter { padded.contains(" " + $0) }.count
                    if hit * 3 >= long.count * 2 { score = max(score, 40 + 30 * hit / long.count) }
                }
            }
            if score > (best?.score ?? 39) { best = (c, score) }
        }
        return best?.course
    }

    // MARK: the whole job

    @MainActor
    static func process(imageData: Data?, text: String?) async -> Outcome {
        // started from a Shortcut with the app closed: the sign-in is in the Keychain
        if MoodleAPI.shared.token.isEmpty, let s = Keychain.load() {
            MoodleAPI.shared.token = s.token
            MoodleAPI.shared.privateToken = s.privateToken
        }
        var raw = text ?? ""
        if let d = imageData { raw = await recognizeText(data: d) }
        let clean = tidy(raw)
        guard clean.count > 5 else {
            let why: String
            if imageData == nil && (text ?? "").isEmpty {
                why = "No screenshot reached the action. In the Shortcut, put Take Screenshot first and make sure Send to Daily Summary's Screenshot field is set to \"Screenshot\"."
            } else if imageData != nil {
                why = "I couldn't read any text in that picture."
            } else { why = "There was no text to read." }
            return Outcome(message: why + " Nothing was added.", entries: [])
        }

        let catalog = CourseCatalog()
        await catalog.loadIfNeeded()
        let course = match(clean, in: catalog.courses)
        let now = Date()

        var drafts: [DailyDraft] = []
        if DailyInfoAI.ready {
            let answer = await DailyInfoAI.classify([
                DailyInfoAI.Item(id: "shot", course: course?.subjectName ?? "", posted: now, title: "Screenshot", text: clean)])
            drafts = answer["shot"] ?? []
        }
        if drafts.isEmpty { drafts = DailyRules.classify(title: "", text: clean, posted: now) }
        if drafts.isEmpty {
            let note = clean.replacingOccurrences(of: "\n", with: " ")
            drafts = [DailyDraft(kind: .note, classDate: nil, startMin: nil, newDate: nil, newStartMin: nil, venue: nil,
                                 summary: note.count > 160 ? String(note.prefix(157)) + "…" : note)]
        }
        let added = DailyInfoStore.shared.addCaptured(drafts, course: course, text: clean)

        let first = added[0]
        var bits = [first.kind.title]
        if let n = first.courseName { bits.append(n) }
        if let d = first.newDate ?? first.classDate { bits.append(shortDay(d)) }
        let extra = added.count > 1 ? " (+\(added.count - 1) more)" : ""
        let unsure = (first.kind == .note && drafts.count == 1) ? " I wasn't sure what it was, so it is saved as a notice." : ""
        return Outcome(message: "Added to Daily summary: " + bits.joined(separator: " · ") + extra + "." + unsure, entries: added)
    }

    private static func shortDay(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM"
        return f.string(from: d)
    }
}

private extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - App Intents (Shortcuts, Back Tap, Siri)

struct SendToDailySummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to Daily Summary"
    static var description = IntentDescription(
        "Reads a screenshot and adds the class change, assignment or quiz in it to Daily summary. With no screenshot it uses the picture on the clipboard.",
        categoryName: "Daily summary")
    static var openAppWhenRun = false

    @Parameter(title: "Screenshot", supportedTypeIdentifiers: ["public.image"])
    var screenshot: IntentFile?

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$screenshot) to Daily Summary") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var data: Data? = screenshot?.data
        if (data?.isEmpty ?? true), let u = screenshot?.fileURL { data = try? Data(contentsOf: u) }   // some senders only give a file
        if data?.isEmpty == true { data = nil }
        var text: String?
        if data == nil {                                     // nothing handed over: use what was copied
            if let img = UIPasteboard.general.image { data = img.pngData() }
            else if let s = UIPasteboard.general.string { text = s }
        }
        let r = await DailyCapture.process(imageData: data, text: text)
        return .result(dialog: "\(r.message)")
    }
}

struct SendTextToDailySummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Text to Daily Summary"
    static var description = IntentDescription("Reads a message (for example a copied WhatsApp text) and adds the class change, assignment or quiz in it to Daily summary.",
                                               categoryName: "Daily summary")
    static var openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to Daily Summary") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = await DailyCapture.process(imageData: nil, text: text)
        return .result(dialog: "\(r.message)")
    }
}

struct iTaleemShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToDailySummaryIntent(),
                    phrases: ["Send to \(.applicationName) Daily Summary", "Add to \(.applicationName) Daily Summary"],
                    shortTitle: "Send to Daily Summary", systemImageName: "tray.and.arrow.down")
    }
}

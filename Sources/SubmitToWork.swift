import SwiftUI

// MARK: - Submit a My Drive file to a work (assignment)
//
// Opened from the paper-plane button when a My Drive file is viewed (Others > My Drive and a subject's My Drive tab
// both open the same viewer). Steps: subject -> assignment that accepts files -> save as draft / submit.
// Files already on the submission are kept; a file with the same name is replaced.

struct SubmitToWorkSheet: View {
    let fileURL: URL
    @EnvironmentObject var catalog: CourseCatalog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose the subject, then the work to send “\(fileURL.lastPathComponent)” to.")
                        .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                    if catalog.courses.isEmpty {
                        Text(catalog.loaded ? "No subjects found." : "Loading subjects…")
                            .foregroundColor(Theme.muted).padding(.top, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(catalog.courses) { c in
                                NavigationLink {
                                    SubmitWorkList(course: c, fileURL: fileURL, close: { dismiss() })
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(c.subjectName).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(Theme.font(.caption).weight(.semibold))
                                            .foregroundColor(Theme.muted)
                                    }
                                    .padding(14).contentShape(Rectangle())
                                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .glowCard()
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Submit to work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(ThemeStore.shared.theme.scheme)
        .task { await catalog.loadIfNeeded() }
    }
}

private struct SubmitWorkList: View {
    let course: Course
    let fileURL: URL
    let close: () -> Void
    @State private var items: [Assign] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loading {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.top, 20)
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error).font(Theme.font(.footnote)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }.foregroundColor(Theme.accent)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 20)
                } else if items.isEmpty {
                    Text("No assignments in this subject take a file.")
                        .font(Theme.font(.footnote)).foregroundColor(Theme.muted).padding(.top, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { a in
                            NavigationLink {
                                SubmitConfirmView(assign: a, fileURL: fileURL, close: close)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(a.name.decodedEntities).foregroundColor(Theme.txt).multilineTextAlignment(.leading)
                                        Text(due(a)).font(Theme.font(.caption)).foregroundColor(Theme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(Theme.font(.caption).weight(.semibold))
                                        .foregroundColor(Theme.muted)
                                }
                                .padding(14).contentShape(Rectangle())
                                .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .glowCard()
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(course.subjectName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func due(_ a: Assign) -> String {
        guard let d = a.duedate, d > 0 else { return "No due date" }
        return "Due " + fmt(d)
    }

    private func load() async {
        loading = true; error = nil
        do {
            let r: AssignResp = try await MoodleAPI.shared.call("mod_assign_get_assignments", ["courseids": [course.id]])
            items = (r.courses.first?.assignments ?? []).filter { $0.enabled("file") }
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loading = false
    }
}

private struct SubmitConfirmView: View {
    let assign: Assign
    let fileURL: URL
    let close: () -> Void
    @EnvironmentObject var app: AppState
    @ObservedObject private var queue = OfflineQueue.shared
    @State private var status: StatusResp?
    @State private var loading = true
    @State private var loadError: String?
    @State private var busy = false
    @State private var message: String?
    @State private var done = false
    @State private var confirmSubmit = false

    private var uid: Int { app.site?.userid ?? 0 }
    private var newName: String { fileURL.lastPathComponent }
    private var usesDrafts: Bool { assign.submissiondrafts == 1 }
    private var canEdit: Bool { status?.lastattempt?.canedit?.value ?? true }

    private var existing: [FileRef] {
        var out: [FileRef] = []
        for p in status?.lastattempt?.shown?.plugins ?? [] where p.type == "file" {
            for area in p.fileareas ?? [] { out.append(contentsOf: area.files ?? []) }
        }
        return out.filter { $0.fileurl != nil }
    }
    private var replaced: [FileRef] { existing.filter { $0.filename == newName } }
    private var kept: [FileRef] { existing.filter { $0.filename != newName } }

    private var existingText: String? {
        for p in status?.lastattempt?.shown?.plugins ?? [] where p.type == "onlinetext" {
            if let t = p.editorfields?.first?.text { return t }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(assign.name.decodedEntities).font(Theme.font(.headline)).foregroundColor(Theme.txt)
                    Label(newName, systemImage: "paperplane").font(Theme.font(.subheadline)).foregroundColor(Theme.accent)
                    ForEach(replaced) { f in
                        Text("Replaces the submitted “\(f.filename ?? "file")”.")
                            .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    }
                    if !kept.isEmpty {
                        Text("Already submitted and kept: " + kept.map { $0.filename ?? "file" }.joined(separator: ", "))
                            .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()

                if loading {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
                } else if let loadError {
                    VStack(spacing: 10) {
                        Text(loadError).font(Theme.font(.footnote)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                        Button("Try again") { Task { await loadStatus() } }.foregroundColor(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                } else if !canEdit {
                    Text("This assignment can't be edited right now (locked or already graded).")
                        .font(Theme.font(.footnote)).foregroundColor(.red.opacity(0.85))
                } else if done {
                    Button { close() } label: { actionLabel("Done", filled: true) }
                } else {
                    if usesDrafts {
                        Button { Task { await send(submit: false) } } label: { actionLabel("Save as draft", filled: true) }
                        Button { confirmSubmit = true } label: { actionLabel("Submit for grading", filled: false) }
                    } else {
                        Button { Task { await send(submit: false) } } label: { actionLabel("Submit", filled: true) }
                    }
                }
                if busy { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                if let message {
                    Text(message).font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Submit")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadStatus() }
        .confirmationDialog("Submit for grading? You may not be able to change it afterwards.",
                            isPresented: $confirmSubmit, titleVisibility: .visible) {
            Button("Submit for grading") { Task { await send(submit: true) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func actionLabel(_ t: String, filled: Bool) -> some View {
        Text(t).fontWeight(.semibold)
            .foregroundColor(filled ? Theme.onAccent : Theme.txt)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(filled ? Theme.accent : Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(busy ? 0.5 : 1)
    }

    private func loadStatus() async {
        loading = true; loadError = nil
        do {
            status = try await MoodleAPI.shared.call("mod_assign_get_submission_status",
                                                     ["assignid": assign.id, "userid": uid])
        } catch {
            // without the current files the submission could be overwritten, so don't go on
            if !(error is CancellationError) { loadError = "Couldn't load your current submission: \(error.localizedDescription)" }
        }
        loading = false
    }

    private func send(submit: Bool) async {
        guard !busy else { return }
        busy = true; message = nil
        // a private copy, so the queue / upload never depends on the preview's temp folder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send-" + UUID().uuidString)
        let copy = dir.appendingPathComponent(newName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL, to: copy)
        } catch {
            message = "Couldn't read the file: \(error.localizedDescription)"
            busy = false
            return
        }
        let job = SubmissionJob(
            kind: .save, assignId: assign.id, name: assign.name, due: assign.duedate,
            text: assign.enabled("onlinetext") ? (existingText ?? "") : nil,   // keep any typed text as it is
            submit: submit, rebuildFiles: true,
            keep: kept.map { KeptFile(name: $0.filename ?? "file", url: $0.fileurl ?? "") })
        do {
            try await MoodleAPI.shared.run(job, newFiles: [copy])
            message = submit ? "Submitted for grading." : (usesDrafts ? "Draft saved." : "Submitted.")
            done = true
            await loadStatus()
        } catch {
            if queue.shouldQueue(error) {
                queue.enqueue(job, files: [copy])
                message = "No internet. Saved on your phone, it will be sent automatically when you're back online."
                done = true
            } else {
                message = error.localizedDescription
            }
        }
        busy = false
    }
}

import SwiftUI

// MARK: - Save login info (Others > App Preferences > Save login info)
//
// Matric no. + password are kept in the iPhone Keychain. When the site token stops working (or the app
// is signed out without you pressing "Sign out"), the app signs in again by itself with them.
//
// Safeguards:
//  - a wrong password is never retried (that is how accounts get locked): it stops until you save new details
//  - after a failed attempt it waits a minute before trying again
//  - pressing "Sign out" yourself does not sign you back in
//  - it uses the username + password sign-in, so it can't complete 2FA

struct SavedCredentials: Codable { var user: String; var pass: String }

enum SavedLoginStore {
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "italeem",
         kSecAttrAccount as String: "credentials"]
    }
    static func save(_ c: SavedCredentials) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock   // background refreshes can read it
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> SavedCredentials? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(SavedCredentials.self, from: d)
    }
    static func delete() { SecItemDelete(query() as CFDictionary) }
}

enum ReloginResult { case ok, unavailable, offline }

final class SavedLogin: @unchecked Sendable {
    static let shared = SavedLogin()

    private let lock = NSLock()
    private var inflight: Task<ReloginResult, Never>?
    private var lastFail = Date.distantPast
    private let d = UserDefaults.standard

    /// The "Sign in automatically" switch (on by default once details are saved)
    var enabled: Bool {
        get { d.object(forKey: "savedlogin.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "savedlogin.enabled") }
    }
    /// The site said the saved password is wrong: stop trying until new details are saved
    var badCredentials: Bool {
        get { d.bool(forKey: "savedlogin.bad") }
        set { d.set(newValue, forKey: "savedlogin.bad") }
    }
    /// "Sign out" was pressed: stay signed out until the next sign-in
    var manualSignOut: Bool {
        get { d.bool(forKey: "savedlogin.manualOut") }
        set { d.set(newValue, forKey: "savedlogin.manualOut") }
    }

    var hasSaved: Bool { SavedLoginStore.load() != nil }
    var canRelogin: Bool { enabled && !badCredentials && !manualSignOut && hasSaved }

    private func claim() -> Task<ReloginResult, Never>? {
        lock.lock(); defer { lock.unlock() }
        if let t = inflight { return t }                              // one attempt at a time; everyone shares it
        guard canRelogin, Date().timeIntervalSince(lastFail) > 60 else { return nil }
        let t = Task<ReloginResult, Never> { await SavedLogin.shared.perform() }
        inflight = t
        return t
    }
    private func release(failed: Bool) {
        lock.lock()
        inflight = nil
        if failed { lastFail = Date() }
        lock.unlock()
    }

    /// Signs in again with the saved details and stores the new token (used when a request is refused as "invalid token")
    func relogin() async -> ReloginResult {
        guard let t = claim() else { return .unavailable }
        let r = await t.value
        release(failed: r != .ok)
        return r
    }

    private func perform() async -> ReloginResult {
        guard let c = SavedLoginStore.load() else { return .unavailable }
        do {
            let s = try await MoodleAPI.shared.passwordLogin(c.user, c.pass)
            MoodleAPI.shared.token = s.token
            MoodleAPI.shared.privateToken = s.privateToken
            Keychain.save(s)
            return .ok
        } catch let e as APIError {
            if e.code == "invalidlogin" { badCredentials = true }
            return .unavailable
        } catch {
            return isOfflineError(error) ? .offline : .unavailable
        }
    }

    /// For the login screen: sign in with the saved details right now (no waiting period)
    @MainActor func signInFromSaved(_ app: AppState) async throws {
        guard let c = SavedLoginStore.load() else { return }
        do {
            let s = try await MoodleAPI.shared.passwordLogin(c.user, c.pass)
            try await app.signIn(s)
        } catch let e as APIError {
            if e.code == "invalidlogin" { badCredentials = true }
            throw e
        }
    }

    /// Checks the details with the site without touching the current session, then stores them
    func verifyAndSave(user: String, pass: String) async throws {
        _ = try await MoodleAPI.shared.passwordLogin(user, pass)
        SavedLoginStore.save(SavedCredentials(user: user, pass: pass))
        badCredentials = false
        enabled = true
    }

    func remove() {
        SavedLoginStore.delete()
        badCredentials = false
    }
}

// MARK: - Screen

struct SavedLoginView: View {
    @State private var user = ""
    @State private var pass = ""
    @State private var auto = SavedLogin.shared.enabled
    @State private var saved = SavedLogin.shared.hasSaved
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(get: { auto }, set: { auto = $0; SavedLogin.shared.enabled = $0 })) {
                        Text("Sign in automatically").fontWeight(.semibold).foregroundColor(Theme.txt)
                    }
                    .tint(Theme.accent)
                    Text("When you get signed out, the app signs back in with these details, so attendance and everything else keeps working. "
                         + "They are stored in this iPhone's Keychain and only sent to iTa'leem.")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("LOGIN DETAILS").font(Theme.font(.caption)).foregroundColor(Theme.muted)
                    TextField("Matric no.", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(10).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))
                    SecureField(saved ? "Password (saved · type to change)" : "Password", text: $pass)
                        .padding(10).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 18) {
                        Button { Task { await save() } } label: {
                            if busy { ProgressView().tint(Theme.accent) } else { Text("Save") }
                        }
                        .disabled(busy || !canSave)
                        if saved {
                            Button("Remove", role: .destructive) {
                                SavedLogin.shared.remove()
                                saved = false; user = ""; pass = ""
                                failed = false; message = "Saved login removed."
                            }
                            .disabled(busy)
                        }
                    }
                    .font(Theme.font(.subheadline).weight(.semibold)).foregroundColor(Theme.accent)

                    if let message {
                        Text(message).font(Theme.font(.caption))
                            .foregroundColor(failed ? .red.opacity(0.85) : Theme.muted)
                    } else if saved && SavedLogin.shared.badCredentials {
                        Text("The site rejected the saved password, so automatic sign-in is paused. Save your new password to resume.")
                            .font(Theme.font(.caption)).foregroundColor(.red.opacity(0.85))
                    }
                    Text("The details are checked with the site before they are saved. This uses the username & password sign-in, "
                         + "so it can't complete 2FA.")
                        .font(Theme.font(.caption)).foregroundColor(Theme.muted)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).glowCard()
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Save login info")
        .navigationBarTitleDisplayMode(.inline)
        .notebookBack()
        .onAppear { if user.isEmpty { user = SavedLoginStore.load()?.user ?? "" } }
    }

    private var canSave: Bool {
        let u = user.trimmingCharacters(in: .whitespaces)
        if u.isEmpty { return false }
        if !pass.isEmpty { return true }
        return false   // a password is needed to save (it is not shown again once saved)
    }

    private func save() async {
        busy = true; message = nil; failed = false
        let u = user.trimmingCharacters(in: .whitespaces)
        do {
            try await SavedLogin.shared.verifyAndSave(user: u, pass: pass)
            saved = true; pass = ""
            message = "Saved. The app will sign in for you when it's signed out."
        } catch {
            failed = true
            message = (error as? APIError)?.code == "invalidlogin"
                ? "Matric no. or password is wrong, nothing was saved."
                : "Couldn't check the details: \(error.localizedDescription)"
        }
        busy = false
    }
}

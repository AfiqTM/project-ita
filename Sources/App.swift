import SwiftUI
import Security
import WebKit

enum Site {
    static let url = URL(string: "https://italeemc.iium.edu.my")!
}

@main
struct iTaleemApp: App {
    @StateObject private var app = AppState()
    @StateObject private var todos = TodoStore()
    @StateObject private var driveLib = DriveLibrary()
    @StateObject private var driveAuth = DriveAuth()
    @StateObject private var catalog = CourseCatalog()
    init() { Theme.applyAppearance() }

    var body: some Scene {
        WindowGroup {
            Group {
                if app.loggedIn { RootView() } else { LoginView() }
            }
            .environmentObject(app)
            .environmentObject(todos)
            .environmentObject(driveLib)
            .environmentObject(driveAuth)
            .environmentObject(catalog)
            .onOpenURL { GoogleLink.handle($0) }   // Google sign-in redirect
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .background(Theme.bg.ignoresSafeArea())
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var loggedIn = false
    @Published var site: SiteInfo?

    init() {
        if let s = Keychain.load() {
            MoodleAPI.shared.token = s.token
            MoodleAPI.shared.privateToken = s.privateToken
            loggedIn = true
            Task { await refreshSite() }
        }
    }

    func signIn(_ s: Session) async throws {
        MoodleAPI.shared.token = s.token
        MoodleAPI.shared.privateToken = s.privateToken
        site = try await MoodleAPI.shared.siteInfo()
        Keychain.save(s)
        loggedIn = true
    }

    func refreshSite() async {
        do { site = try await MoodleAPI.shared.siteInfo() }
        catch let e as APIError where e.isAuth { signOut() }
        catch { /* offline: keep cached session */ }
    }

    func signOut() {
        Keychain.delete()
        MoodleAPI.shared.token = ""
        MoodleAPI.shared.privateToken = nil
        site = nil
        loggedIn = false
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast) {}
    }
}

enum Keychain {
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "italeem",
         kSecAttrAccount as String: "session"]
    }
    static func save(_ s: Session) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load() -> Session? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }
    static func delete() { SecItemDelete(query() as CFDictionary) }
}

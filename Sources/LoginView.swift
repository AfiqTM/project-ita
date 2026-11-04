import SwiftUI

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showPassword = true
    @State private var saveLogin = false
    @State private var code = ""
    private let webAuth = WebAuth()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Spacer().frame(height: 60)
                Text("iTa'leem")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(Theme.accent)
                Text("Sign in to continue")
                    .foregroundColor(Theme.muted)

                Text("IIUM Student and Staff Login")
                    .font(Theme.font(.subheadline)).foregroundColor(Theme.muted)

                if showPassword {
                    VStack(spacing: 12) {
                        field { TextField("Matric no.", text: $user)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled() }
                        field { SecureField("Password", text: $pass) }
                        field { TextField("Authenticator code (if asked)", text: $code)
                                    .keyboardType(.numberPad) }
                        Toggle("Save login info", isOn: $saveLogin).tint(Theme.accent).foregroundColor(Theme.txt)
                        Button { Task { await passwordLogin() } } label: {
                            Text("Sign in")
                                .fontWeight(.semibold)
                                .foregroundColor(Theme.onAccent)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(busy || user.isEmpty || pass.isEmpty)
                        Text("Use your IIUM matric no. and CAS password. The app signs in through IIUM single sign-on for you.")
                            .font(Theme.font(.footnote)).foregroundColor(Theme.muted)
                        Button { Task { await browserLogin() } } label: {
                            Text("Having trouble? Sign in with the browser")
                                .foregroundColor(Theme.accent).font(Theme.font(.subheadline))
                        }
                        .disabled(busy)
                    }
                }

                if busy { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                if let error { Text(error).font(Theme.font(.footnote)).foregroundColor(.red.opacity(0.85)) }
            }
            .padding(24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await autoLogin() }
    }

    /// Signed out without pressing "Sign out": sign in again with the saved login info
    private func autoLogin() async {
        guard !busy, SavedLogin.shared.canRelogin else { return }
        busy = true; error = nil
        do { try await SavedLogin.shared.signInFromSaved(app) }
        catch { self.error = "Automatic sign-in failed: \(error.localizedDescription)" }
        busy = false
    }

    private func field<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().foregroundColor(Theme.txt)
            .padding(14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    private func browserLogin() async {
        busy = true; error = nil
        do {
            let s = try await webAuth.start()
            try await app.signIn(s)
        } catch {
            let ns = error as NSError
            // 1 = user cancelled the sheet
            if ns.domain != "com.apple.AuthenticationServices.WebAuthenticationSession" || ns.code != 1 {
                self.error = error.localizedDescription
            }
        }
        busy = false
    }

    private func passwordLogin() async {
        busy = true; error = nil
        do {
            let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = try await MoodleAPI.shared.passwordLogin(u, pass, code: code)
            try await app.signIn(s)
            if saveLogin {
                SavedLoginStore.save(SavedCredentials(user: u, pass: pass))
                SavedLogin.shared.badCredentials = false
                SavedLogin.shared.enabled = true
            }
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}
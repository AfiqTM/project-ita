import SwiftUI

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showPassword = false
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

                Button { Task { await browserLogin() } } label: {
                    Text("Sign in with iTa'leem (supports 2FA)")
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.onAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(busy)

                Button { withAnimation { showPassword.toggle() } } label: {
                    Text(showPassword ? "Hide password sign-in" : "Use username & password instead")
                        .foregroundColor(Theme.accent).font(.subheadline)
                }

                if showPassword {
                    VStack(spacing: 12) {
                        field { TextField("Username / Matric no.", text: $user)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled() }
                        field { SecureField("Password", text: $pass) }
                        Button { Task { await passwordLogin() } } label: {
                            Text("Sign in")
                                .foregroundColor(Theme.txt)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Theme.surface2)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(busy || user.isEmpty || pass.isEmpty)
                        Text("Password sign-in can't complete 2FA. If your account uses 2FA, use the button above.")
                            .font(.footnote).foregroundColor(Theme.muted)
                    }
                }

                if busy { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
                if let error { Text(error).font(.footnote).foregroundColor(.red.opacity(0.85)) }
            }
            .padding(24)
        }
        .background(Theme.bg.ignoresSafeArea())
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
            let s = try await MoodleAPI.shared.passwordLogin(user, pass)
            try await app.signIn(s)
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}

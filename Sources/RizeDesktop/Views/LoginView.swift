import SwiftUI

/// Minimal email/password sign-in sheet, per the RIZ-41 brief's "minimal
/// login UI ... reachable from the menu" requirement. Presents both sign-in
/// and create-account as the same form, since both take an identical
/// email/password/device payload
/// (`documentation/api-reference.md` §Auth).
struct LoginView: View {
    let authSession: AuthSessionViewModel
    let onFinished: () -> Void

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to RizeClone")
                .font(.headline)

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage = authSession.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Create Account") {
                    Task { await submit(authSession.register) }
                }
                Spacer()
                Button("Sign In") {
                    Task { await submit(authSession.login) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(authSession.isBusy || email.isEmpty || password.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
        .onChange(of: authSession.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                onFinished()
            }
        }
    }

    private func submit(_ action: (String, String) async -> Void) async {
        await action(email, password)
    }
}

#if DEBUG
    @MainActor
    private func previewAuthSession() -> AuthSessionViewModel {
        let authAPI = RemoteAuthAPIClient(
            transport: URLSessionHTTPTransport(),
            baseURLProvider: UserDefaultsBaseURLProvider()
        )
        let tokenManager = AuthTokenManager(api: authAPI, storage: KeychainAuthTokenStorage())
        return AuthSessionViewModel(tokenManager: tokenManager)
    }

    #Preview {
        LoginView(authSession: previewAuthSession(), onFinished: {})
    }
#endif

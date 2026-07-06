import Foundation
import Observation

/// UI-facing auth state for the menu-bar login sheet and sync status row,
/// per the RIZ-41 brief's "minimal login UI ... sync status in the menu"
/// requirement.
///
/// `@MainActor`-isolated so its `@Observable` properties are only ever
/// mutated on the main actor, matching the RIZ-40 lesson recorded on
/// `MenuContentViewModel`. `AuthTokenManager` itself is an actor and does the
/// actual networking/token work off the main actor; this view model only
/// reads a snapshot of its state before/after each `await`, never mutating
/// `@Observable` state across an await.
@MainActor
@Observable
final class AuthSessionViewModel {
    private(set) var isSignedIn = false
    private(set) var userEmail: String?
    private(set) var errorMessage: String?
    private(set) var isBusy = false

    private let tokenManager: AuthTokenManager

    init(tokenManager: AuthTokenManager) {
        self.tokenManager = tokenManager
    }

    /// Reflects the token manager's current session state, e.g. after app
    /// launch (if a future ticket restores a session eagerly) or after a
    /// background sign-out triggered by a failed refresh.
    func refresh() async {
        let signedIn = await tokenManager.isSignedIn
        let user = await tokenManager.user
        isSignedIn = signedIn
        userEmail = user?.email
    }

    func login(email: String, password: String) async {
        isBusy = true
        errorMessage = nil
        do {
            let user = try await tokenManager.login(email: email, password: password)
            isSignedIn = true
            userEmail = user.email
        } catch {
            isSignedIn = false
            userEmail = nil
            errorMessage = Self.message(for: error)
        }
        isBusy = false
    }

    func register(email: String, password: String) async {
        isBusy = true
        errorMessage = nil
        do {
            let user = try await tokenManager.register(email: email, password: password)
            isSignedIn = true
            userEmail = user.email
        } catch {
            isSignedIn = false
            userEmail = nil
            errorMessage = Self.message(for: error)
        }
        isBusy = false
    }

    func logout() async {
        isBusy = true
        await tokenManager.logout()
        isSignedIn = false
        userEmail = nil
        isBusy = false
    }

    private static func message(for error: Error) -> String {
        switch error {
        case APIError.unauthorized:
            "Incorrect email or password."
        case let APIError.server(_, problem):
            problem?.detail ?? "Something went wrong. Please try again."
        default:
            "Couldn't reach the server. Please try again."
        }
    }
}

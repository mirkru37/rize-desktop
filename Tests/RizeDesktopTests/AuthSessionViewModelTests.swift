@testable import RizeDesktop
import XCTest

/// Exercises `AuthSessionViewModel`'s UI-facing auth state (the menu-bar
/// login sheet backing model) against a real `AuthTokenManager` wired to
/// `FakeAuthAPIClient`/`InMemoryAuthTokenStorage` — no Keychain, no network —
/// per the RIZ-41 brief's "minimal login UI" requirement.
@MainActor
final class AuthSessionViewModelTests: XCTestCase {
    // MARK: - Login

    func testLoginSuccessUpdatesSignedInStateAndClearsBusyFlag() async {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.success(makeAuthResponse(accessToken: "access-1")))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))

        await viewModel.login(email: "user@example.com", password: "correct-horse-battery-staple")

        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.userEmail, "user@example.com")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isBusy)
    }

    func testLoginFailureWithUnauthorizedSurfacesIncorrectCredentialsMessage() async {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.failure(APIError.unauthorized(nil)))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))

        await viewModel.login(email: "user@example.com", password: "wrong")

        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNil(viewModel.userEmail)
        XCTAssertEqual(viewModel.errorMessage, "Incorrect email or password.")
        XCTAssertFalse(viewModel.isBusy)
    }

    func testLoginFailureWithServerProblemSurfacesProblemDetail() async {
        let api = FakeAuthAPIClient()
        let problem = ProblemDetail(type: "about:blank", title: "Server Error", status: 500, detail: "db is down")
        await api.setLoginBehavior(.failure(APIError.server(status: 500, problem: problem)))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))

        await viewModel.login(email: "user@example.com", password: "wrong")

        XCTAssertEqual(viewModel.errorMessage, "db is down")
    }

    func testLoginFailureWithNetworkErrorSurfacesGenericMessage() async {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.failure(TestError.network))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))

        await viewModel.login(email: "user@example.com", password: "wrong")

        XCTAssertEqual(viewModel.errorMessage, "Couldn't reach the server. Please try again.")
    }

    // MARK: - Register

    func testRegisterSuccessUpdatesSignedInState() async {
        let api = FakeAuthAPIClient()
        await api.setRegisterBehavior(.success(makeAuthResponse(accessToken: "access-1")))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))

        await viewModel.register(email: "user@example.com", password: "correct-horse-battery-staple")

        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.userEmail, "user@example.com")
    }

    func testRegisterFailureLeavesSignedOutWithErrorMessage() async {
        let api = FakeAuthAPIClient()
        await api.setRegisterBehavior(.failure(APIError.unauthorized(nil)))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))

        await viewModel.register(email: "user@example.com", password: "taken")

        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNil(viewModel.userEmail)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Logout

    func testLogoutClearsSignedInState() async {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.success(makeAuthResponse(accessToken: "access-1")))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))
        await viewModel.login(email: "user@example.com", password: "correct-horse-battery-staple")

        await viewModel.logout()

        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNil(viewModel.userEmail)
        XCTAssertFalse(viewModel.isBusy)
    }

    // MARK: - Refresh

    func testRefreshReflectsSignedInStateFromTokenManager() async throws {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.success(makeAuthResponse(accessToken: "access-1")))
        let tokenManager = makeAuthTokenManager(api: api)
        _ = try await tokenManager.login(email: "user@example.com", password: "correct-horse-battery-staple")
        let viewModel = AuthSessionViewModel(tokenManager: tokenManager)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.isSignedIn)
        XCTAssertEqual(viewModel.userEmail, "user@example.com")
    }

    func testRefreshWithNoSessionLeavesSignedOut() async {
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager())

        await viewModel.refresh()

        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertNil(viewModel.userEmail)
    }
}

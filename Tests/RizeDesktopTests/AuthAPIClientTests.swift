@testable import RizeDesktop
import XCTest

/// Exercises `RemoteAuthAPIClient` against a `FakeHTTPTransport` — no real
/// network — covering request shaping (method/path/headers) and response
/// validation (success decode, 401, other non-2xx, undecodable body) per
/// `documentation/api-reference.md` §Auth worked examples.
final class AuthAPIClientTests: XCTestCase {
    private let device = DeviceRequestDTO(
        id: nil,
        platform: "macos",
        name: "Test Mac",
        model: "Mac15,3",
        osVersion: "14.5",
        appVersion: "0.1.0"
    )

    private func makeClient(transport: FakeHTTPTransport) -> RemoteAuthAPIClient {
        RemoteAuthAPIClient(transport: transport, baseURLProvider: FixedBaseURLProvider())
    }

    // MARK: - register / login

    func testRegisterSendsPostToRegisterPathAndDecodesResponse() async throws {
        let transport = FakeHTTPTransport()
        try await transport.setOutcome(.success(HTTPResponse(statusCode: 201, body: makeAuthResponseData())))
        let client = makeClient(transport: transport)

        let response = try await client.register(email: "user@example.com", password: "secret", device: device)

        XCTAssertEqual(response.accessToken, "access-token-1")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.method, .post)
        XCTAssertEqual(request?.path, "/auth/register")
        XCTAssertEqual(request?.headers["Content-Type"], "application/json")
    }

    func testLoginSendsPostToLoginPathAndDecodesResponse() async throws {
        let transport = FakeHTTPTransport()
        try await transport.setOutcome(.success(HTTPResponse(statusCode: 200, body: makeAuthResponseData())))
        let client = makeClient(transport: transport)

        let response = try await client.login(email: "user@example.com", password: "secret", device: device)

        XCTAssertEqual(response.refreshToken, "refresh-token-1")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.path, "/auth/login")
    }

    func testRefreshSendsPostToRefreshPathAndDecodesResponse() async throws {
        let transport = FakeHTTPTransport()
        try await transport.setOutcome(.success(HTTPResponse(statusCode: 200, body: makeAuthResponseData())))
        let client = makeClient(transport: transport)

        let response = try await client.refresh(refreshToken: "refresh-token-1", device: nil)

        XCTAssertEqual(response.accessToken, "access-token-1")
        let request = await transport.lastRequest
        XCTAssertEqual(request?.path, "/auth/refresh")
    }

    // MARK: - logout

    func testLogoutSendsAuthorizedPostAndDoesNotDecodeABody() async throws {
        let transport = FakeHTTPTransport()
        await transport.setOutcome(.success(HTTPResponse(statusCode: 204, body: Data())))
        let client = makeClient(transport: transport)

        try await client.logout(refreshToken: "refresh-token-1", accessToken: "access-token-1")

        let request = await transport.lastRequest
        XCTAssertEqual(request?.path, "/auth/logout")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer access-token-1")
    }

    // MARK: - Error responses

    func testUnauthorizedResponseThrowsWithDecodedProblemDetail() async throws {
        let transport = FakeHTTPTransport()
        let problemData = try makeProblemData(detail: "Incorrect email or password.")
        await transport.setOutcome(.success(HTTPResponse(statusCode: 401, body: problemData)))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.login(email: "user@example.com", password: "wrong", device: device)
            XCTFail("expected login to throw")
        } catch let APIError.unauthorized(problem) {
            XCTAssertEqual(problem?.detail, "Incorrect email or password.")
        }
    }

    func testServerErrorResponseThrowsWithStatusAndProblemDetail() async throws {
        let transport = FakeHTTPTransport()
        let problemData = try makeProblemData(status: 500, type: "internal-error", detail: "db is down")
        await transport.setOutcome(.success(HTTPResponse(statusCode: 500, body: problemData)))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.login(email: "user@example.com", password: "wrong", device: device)
            XCTFail("expected login to throw")
        } catch let APIError.server(status, problem) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(problem?.detail, "db is down")
        }
    }

    func testUndecodableSuccessBodyThrowsDecodingFailed() async throws {
        let transport = FakeHTTPTransport()
        await transport.setOutcome(.success(HTTPResponse(statusCode: 200, body: Data("not json".utf8))))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.login(email: "user@example.com", password: "secret", device: device)
            XCTFail("expected login to throw")
        } catch APIError.decodingFailed {
            // expected
        }
    }

    func testTransportFailurePropagates() async throws {
        let transport = FakeHTTPTransport()
        await transport.setOutcome(.failure(TestError.network))
        let client = makeClient(transport: transport)

        do {
            _ = try await client.login(email: "user@example.com", password: "secret", device: device)
            XCTFail("expected login to throw")
        } catch TestError.network {
            // expected
        }
    }
}

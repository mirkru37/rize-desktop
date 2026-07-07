import Foundation
@testable import RizeDesktop

// Shared test doubles for the networking-client suites
// (`AuthAPIClientTests`, `SyncAPIClientTests`, `HTTPTransportTests`). Kept in
// one file, like `SyncAuthTestDoubles`, since these test files all need the
// same handful of transport/base-URL seams.

/// Queue-free `HTTPTransport` fake: each call resolves from a single
/// configurable outcome and records the last request sent, so tests can
/// assert on method/path/headers/body without a real network round-trip.
actor FakeHTTPTransport: HTTPTransport {
    enum Outcome {
        case success(HTTPResponse)
        case failure(Error)
    }

    private var outcome: Outcome = .success(HTTPResponse(statusCode: 200, body: Data()))
    private(set) var lastRequest: HTTPRequest?
    private(set) var lastBaseURL: URL?
    private(set) var sendCallCount = 0

    func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func send(_ request: HTTPRequest, baseURL: URL) async throws -> HTTPResponse {
        sendCallCount += 1
        lastRequest = request
        lastBaseURL = baseURL
        switch outcome {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        }
    }
}

/// Fixed `BaseURLProvider`, for networking-client tests that don't exercise
/// `UserDefaultsBaseURLProvider`'s own resolution logic (covered separately
/// by `BaseURLProviderTests`).
struct FixedBaseURLProvider: BaseURLProvider {
    static let fixedURL: URL = {
        guard let url = URL(string: "https://api.example.com/v1") else {
            fatalError("Invalid hardcoded test base URL")
        }
        return url
    }()

    let url: URL

    init(_ url: URL = FixedBaseURLProvider.fixedURL) {
        self.url = url
    }

    func baseURL() -> URL {
        url
    }
}

/// Builds a successful `AuthResponseDTO`-shaped `HTTPResponse` body, for
/// stubbing `FakeHTTPTransport` responses to the auth endpoints.
func makeAuthResponseData(
    accessToken: String = "access-token-1",
    refreshToken: String = "refresh-token-1"
) throws -> Data {
    let response = makeAuthResponse(accessToken: accessToken, refreshToken: refreshToken)
    return try JSONEncoder.rizeAPIEncoder.encode(response)
}

/// Builds a problem-detail-shaped `HTTPResponse` body, matching
/// `documentation/api-reference.md` §Conventions' RFC 7807-style error
/// envelope.
func makeProblemData(
    status: Int = 401,
    type: String = "invalid-credentials",
    title: String = "Invalid credentials",
    detail: String = "Incorrect email or password."
) throws -> Data {
    let problem = ProblemDetail(type: type, title: title, status: status, detail: detail)
    return try JSONEncoder.rizeAPIEncoder.encode(problem)
}

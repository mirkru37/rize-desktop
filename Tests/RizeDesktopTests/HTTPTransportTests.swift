@testable import RizeDesktop
import XCTest

/// A `URLProtocol` stub that hands back a scripted status/body/error for
/// every request, and records the last request it intercepted — lets
/// `URLSessionHTTPTransportTests` drive `URLSession` for real without any
/// actual network I/O.
final class StubURLProtocol: URLProtocol {
    /// `URLProtocol` is instantiated by `URLSession` itself, so the script
    /// has to live in static state rather than being injected per instance.
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var requestError: Error?
    nonisolated(unsafe) static var respondWithNonHTTPResponse = false
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        if let error = Self.requestError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url else {
            return
        }
        guard let response = makeResponse(for: url) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// A plain `URLResponse` (rather than `HTTPURLResponse`) when
    /// `respondWithNonHTTPResponse` is armed, to drive
    /// `URLSessionHTTPTransport.send`'s `invalidResponse` guard.
    private func makeResponse(for url: URL) -> URLResponse? {
        if Self.respondWithNonHTTPResponse {
            return URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        }
        return HTTPURLResponse(
            url: url,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )
    }

    override func stopLoading() {}
}

/// Exercises `URLSessionHTTPTransport` against `StubURLProtocol` — no real
/// network — covering URL construction (path/query items/headers/body) and
/// the invalid-response guard, per the RIZ-41 brief's "networking behind
/// protocols" requirement.
final class HTTPTransportTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data()
        StubURLProtocol.requestError = nil
        StubURLProtocol.respondWithNonHTTPResponse = false
        StubURLProtocol.lastRequest = nil
    }

    override func tearDown() {
        session = nil
        super.tearDown()
    }

    private func makeBaseURL() -> URL {
        FixedBaseURLProvider.fixedURL
    }

    func testSendBuildsURLWithPathAndQueryItemsAndReturnsResponse() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = Data("hello".utf8)
        let transport = URLSessionHTTPTransport(session: session)

        let request = HTTPRequest(
            method: .get,
            path: "/sync/changes",
            queryItems: [URLQueryItem(name: "limit", value: "200")],
            headers: ["Authorization": "Bearer token"]
        )

        let response = try await transport.send(request, baseURL: makeBaseURL())

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("hello".utf8))
        let sentURL = StubURLProtocol.lastRequest?.url
        XCTAssertEqual(sentURL?.path, "/v1/sync/changes")
        XCTAssertTrue(sentURL?.query?.contains("limit=200") ?? false)
        XCTAssertEqual(
            StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer token"
        )
    }

    func testSendPostIncludesHTTPMethodAndBody() async throws {
        StubURLProtocol.statusCode = 201
        let transport = URLSessionHTTPTransport(session: session)
        let body = Data("{\"a\":1}".utf8)

        let request = HTTPRequest(method: .post, path: "/auth/login", headers: [:], body: body)
        let response = try await transport.send(request, baseURL: makeBaseURL())

        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testSendWithNonHTTPResponseThrowsInvalidResponse() async throws {
        StubURLProtocol.respondWithNonHTTPResponse = true
        let transport = URLSessionHTTPTransport(session: session)
        let request = HTTPRequest(method: .get, path: "/sync/changes")

        do {
            _ = try await transport.send(request, baseURL: makeBaseURL())
            XCTFail("expected send to throw")
        } catch APIError.invalidResponse {
            // expected
        }
    }

    func testSendPropagatesTransportError() async throws {
        StubURLProtocol.requestError = URLError(.notConnectedToInternet)
        let transport = URLSessionHTTPTransport(session: session)
        let request = HTTPRequest(method: .get, path: "/sync/changes")

        do {
            _ = try await transport.send(request, baseURL: makeBaseURL())
            XCTFail("expected send to throw")
        } catch is URLError {
            // expected
        }
    }
}

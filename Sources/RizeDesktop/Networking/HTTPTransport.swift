import Foundation

/// A single outgoing HTTP request, independent of `URLSession` so callers
/// (and tests) never construct `URLRequest`/`URLSession` directly.
struct HTTPRequest {
    enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    var method: Method
    var path: String
    var queryItems: [URLQueryItem] = []
    var headers: [String: String] = [:]
    var body: Data?
}

/// The response to an `HTTPRequest`, independent of `URLSession`.
struct HTTPResponse {
    var statusCode: Int
    var body: Data
}

/// Abstraction over the network transport so `APIClient` is testable with a
/// mock transport, per `documentation/architecture-desktop.md` §Offline-First
/// Store & Sync Loop and the RIZ-41 brief's "networking behind protocols"
/// requirement.
protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest, baseURL: URL) async throws -> HTTPResponse
}

/// Production transport backed by `URLSession`.
struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: HTTPRequest, baseURL: URL) async throws -> HTTPResponse {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidRequest
        }
        if !request.queryItems.isEmpty {
            components.queryItems = request.queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidRequest
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return HTTPResponse(statusCode: httpResponse.statusCode, body: data)
    }
}

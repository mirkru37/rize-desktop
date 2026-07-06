import Foundation

/// The RFC 7807-style problem body every backend error response carries, per
/// `documentation/api-reference.md` §Conventions.
struct ProblemDetail: Codable, Equatable {
    var type: String
    var title: String
    var status: Int
    var detail: String
}

/// Errors surfaced by the networking layer.
enum APIError: Error, Equatable {
    /// The request could not be constructed (invalid URL/path).
    case invalidRequest
    /// The transport returned something that isn't a valid HTTP response.
    case invalidResponse
    /// The response body could not be decoded as the expected type.
    case decodingFailed
    /// The server rejected the request with a 401; carries the decoded
    /// problem body when available so callers can distinguish
    /// `invalid-credentials` from `refresh-token-reuse-detected`, etc.
    case unauthorized(ProblemDetail?)
    /// Any other non-2xx response.
    case server(status: Int, problem: ProblemDetail?)
}

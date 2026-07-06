import Foundation

/// The two sync endpoints `SyncEngine` calls, per
/// `documentation/sync-protocol.md` §Flow. Deliberately carries no notion of
/// an access token: authentication (attaching the bearer token, refreshing
/// and retrying once on `401`) is entirely `AuthorizingSyncAPIClient`'s
/// concern, so `SyncEngine` and its tests never deal with tokens at all.
protocol SyncAPIClient: Sendable {
    func pushEvents(_ items: [SyncPushItemDTO], deviceID: String) async throws -> [SyncPushResultDTO]
    func fetchChanges(cursor: String?, limit: Int) async throws -> SyncChangesResponseDTO
}

/// The two sync endpoints from `documentation/sync-protocol.md`, at the raw
/// transport level: both are authenticated
/// (`Authorization: Bearer <access-token>`) and the caller supplies a
/// concrete access token per call. Wrapped by `AuthorizingSyncAPIClient`,
/// which is what actually implements the token-free `SyncAPIClient` protocol
/// above.
protocol TokenizedSyncAPIClient: Sendable {
    func pushEvents(_ items: [SyncPushItemDTO], deviceID: String, accessToken: String) async throws
        -> [SyncPushResultDTO]
    func fetchChanges(cursor: String?, limit: Int, accessToken: String) async throws -> SyncChangesResponseDTO
}

/// `HTTPTransport`-backed implementation of `TokenizedSyncAPIClient`.
struct RemoteSyncAPIClient: TokenizedSyncAPIClient {
    private let transport: HTTPTransport
    private let baseURLProvider: BaseURLProvider
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        transport: HTTPTransport,
        baseURLProvider: BaseURLProvider,
        decoder: JSONDecoder = .rizeAPIDecoder,
        encoder: JSONEncoder = .rizeAPIEncoder
    ) {
        self.transport = transport
        self.baseURLProvider = baseURLProvider
        self.decoder = decoder
        self.encoder = encoder
    }

    func pushEvents(
        _ items: [SyncPushItemDTO],
        deviceID: String,
        accessToken: String
    ) async throws -> [SyncPushResultDTO] {
        let body = SyncPushRequestDTO(deviceID: deviceID, items: items)
        let request = try HTTPRequest(
            method: .post,
            path: "/sync/events",
            headers: authorizedJSONHeaders(accessToken: accessToken),
            body: encoder.encode(body)
        )
        let response = try await transport.send(request, baseURL: baseURLProvider.baseURL())
        try validate(response)
        guard let decoded = try? decoder.decode(SyncPushResponseDTO.self, from: response.body) else {
            throw APIError.decodingFailed
        }
        return decoded.results
    }

    func fetchChanges(cursor: String?, limit: Int, accessToken: String) async throws -> SyncChangesResponseDTO {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let request = HTTPRequest(
            method: .get,
            path: "/sync/changes",
            queryItems: queryItems,
            headers: authorizedJSONHeaders(accessToken: accessToken)
        )
        let response = try await transport.send(request, baseURL: baseURLProvider.baseURL())
        try validate(response)
        guard let decoded = try? decoder.decode(SyncChangesResponseDTO.self, from: response.body) else {
            throw APIError.decodingFailed
        }
        return decoded
    }

    private func authorizedJSONHeaders(accessToken: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(accessToken)"
        ]
    }

    private func validate(_ response: HTTPResponse) throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            let problem = try? decoder.decode(ProblemDetail.self, from: response.body)
            if response.statusCode == 401 {
                throw APIError.unauthorized(problem)
            }
            throw APIError.server(status: response.statusCode, problem: problem)
        }
    }
}

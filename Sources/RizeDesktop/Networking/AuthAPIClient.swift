import Foundation

/// The auth endpoints from `documentation/api-reference.md` §Auth worked
/// examples: register/login/refresh return the shared `authResponse` shape;
/// logout takes only `refresh_token` and returns no body.
protocol AuthAPIClient: Sendable {
    func register(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO
    func login(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO
    func refresh(refreshToken: String, device: DeviceRequestDTO?) async throws -> AuthResponseDTO
    func logout(refreshToken: String, accessToken: String) async throws
}

/// `HTTPTransport`-backed implementation of `AuthAPIClient`.
struct RemoteAuthAPIClient: AuthAPIClient {
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

    func register(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO {
        let body = RegisterRequestDTO(email: email, password: password, device: device)
        return try await post(path: "/auth/register", body: body)
    }

    func login(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO {
        let body = LoginRequestDTO(email: email, password: password, device: device)
        return try await post(path: "/auth/login", body: body)
    }

    func refresh(refreshToken: String, device: DeviceRequestDTO?) async throws -> AuthResponseDTO {
        let body = RefreshRequestDTO(refreshToken: refreshToken, device: device)
        return try await post(path: "/auth/refresh", body: body)
    }

    func logout(refreshToken: String, accessToken: String) async throws {
        let body = LogoutRequestDTO(refreshToken: refreshToken)
        let request = try HTTPRequest(
            method: .post,
            path: "/auth/logout",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(accessToken)"
            ],
            body: encoder.encode(body)
        )
        let response = try await transport.send(request, baseURL: baseURLProvider.baseURL())
        try Self.validate(response)
    }

    private func post<Response: Decodable>(path: String, body: some Encodable) async throws -> Response {
        let request = try HTTPRequest(
            method: .post,
            path: path,
            headers: ["Content-Type": "application/json"],
            body: encoder.encode(body)
        )
        let response = try await transport.send(request, baseURL: baseURLProvider.baseURL())
        try Self.validate(response)
        guard let decoded = try? decoder.decode(Response.self, from: response.body) else {
            throw APIError.decodingFailed
        }
        return decoded
    }

    private static func validate(_ response: HTTPResponse) throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            let problem = try? JSONDecoder.rizeAPIDecoder.decode(ProblemDetail.self, from: response.body)
            if response.statusCode == 401 {
                throw APIError.unauthorized(problem)
            }
            throw APIError.server(status: response.statusCode, problem: problem)
        }
    }
}

extension JSONDecoder {
    static let rizeAPIDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let rizeAPIEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

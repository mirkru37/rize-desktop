import Foundation

/// The `device` object required on `register`/`login` and optional on
/// `refresh`, per `documentation/api-reference.md` §Auth worked examples.
/// `id` is omitted by the client for a brand-new device and echoed back by
/// the server on the response so the client can reuse it on later calls.
struct DeviceRequestDTO: Codable, Equatable {
    var id: UUID?
    var platform: String
    var name: String
    var model: String
    var osVersion: String
    var appVersion: String

    enum CodingKeys: String, CodingKey {
        case id, platform, name, model
        case osVersion = "os_version"
        case appVersion = "app_version"
    }
}

struct DeviceResponseDTO: Codable, Equatable {
    var id: UUID
    var platform: String
    var name: String
    var model: String
    var osVersion: String
    var appVersion: String

    enum CodingKeys: String, CodingKey {
        case id, platform, name, model
        case osVersion = "os_version"
        case appVersion = "app_version"
    }
}

struct UserDTO: Codable, Equatable {
    var id: String
    var email: String
    var role: String
}

/// The shared `authResponse` shape returned by `register`, `login`, and
/// `refresh` (`documentation/api-reference.md` §Auth).
struct AuthResponseDTO: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresIn: Int
    var user: UserDTO
    var device: DeviceResponseDTO

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case user, device
    }
}

struct RegisterRequestDTO: Codable {
    var email: String
    var password: String
    var device: DeviceRequestDTO
}

struct LoginRequestDTO: Codable {
    var email: String
    var password: String
    var device: DeviceRequestDTO
}

struct RefreshRequestDTO: Codable {
    var refreshToken: String
    var device: DeviceRequestDTO?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case device
    }
}

struct LogoutRequestDTO: Codable {
    var refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

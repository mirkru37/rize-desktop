import Foundation
#if canImport(AppKit)
    import AppKit
#endif

/// Builds the `device` object sent on register/login/refresh
/// (`documentation/api-reference.md` §Auth), reusing a previously-assigned
/// server `device.id` when one has been persisted so the backend matches the
/// existing device row rather than creating a new one.
protocol DeviceInfoProviding: Sendable {
    func makeDevice(existingID: UUID?) -> DeviceRequestDTO
}

struct SystemDeviceInfoProvider: DeviceInfoProviding {
    func makeDevice(existingID: UUID?) -> DeviceRequestDTO {
        DeviceRequestDTO(
            id: existingID,
            platform: "macos",
            name: hostName(),
            model: modelIdentifier(),
            osVersion: osVersionString(),
            appVersion: appVersionString()
        )
    }

    private func hostName() -> String {
        #if canImport(AppKit)
            Host.current().localizedName ?? "Mac"
        #else
            "Mac"
        #endif
    }

    private func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else {
            return "unknown"
        }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func osVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func appVersionString() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

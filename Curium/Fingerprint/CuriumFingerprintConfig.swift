import Foundation

/// Schema version shared with `third_party/blink/public/common/curium/curium_fingerprint_config.h`.
enum CuriumFingerprintSchema {
    static let version = 1
    static let maxPayloadBytes = 65_536
    static let validDeviceMemoryBuckets: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]
    static let validFormFactors: Set<String> = [
        "Desktop", "Automotive", "Mobile", "Tablet", "XR", "EInk", "Watch",
    ]
}

enum CuriumDefaultSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case mobile
    case desktop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mobile: return "Mobile Default (Dual-Slot)"
        case .desktop: return "Desktop First (Including Workers)"
        }
    }
}

enum CuriumPointerType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case coarse
    case fine

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .coarse: return "Coarse (Touch)"
        case .fine: return "Fine (Mouse)"
        }
    }
}

enum CuriumHoverType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case hover

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .hover: return "Hover Capable"
        }
    }
}

enum CuriumWebRTCPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case `default` = "default"
    case defaultPublicAndPrivateInterfaces = "default_public_and_private_interfaces"
    case defaultPublicInterfaceOnly = "default_public_interface_only"
    case disableNonProxiedUdp = "disable_non_proxied_udp"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .default: return "Default"
        case .defaultPublicAndPrivateInterfaces: return "Public & Private Interfaces"
        case .defaultPublicInterfaceOnly: return "Public Interface Only"
        case .disableNonProxiedUdp: return "Disable Non-Proxied UDP"
        }
    }
}

struct CuriumBrandVersion: Codable, Equatable, Sendable {
    var brand: String
    var version: String
}

/// Optional per-slot identity, input capability, and WebGL debug string spec.
/// Any `nil` hardware/GPU/input field preserves authentic native device behavior.
struct CuriumIdentitySlot: Codable, Equatable, Sendable {
    var uaString: String?
    var osCpu: String?
    var productVersion: String?
    var appendMobileToken: Bool?
    /// `nil` = omit (default "Google Chrome"); `""` = Chromium-only (2 brands); non-empty = custom primary brand.
    var primaryBrand: String?
    var majorVersion: String?
    var fullVersion: String?
    var brands: [CuriumBrandVersion]?
    var fullVersionBrands: [CuriumBrandVersion]?
    var platform: String?
    var platformVersion: String?
    var architecture: String?
    var bitness: String?
    var model: String?
    var mobile: Bool?
    var wow64: Bool?
    var formFactors: [String]?
    var navigatorPlatform: String?
    var maxTouchPoints: Int?
    var pointerType: CuriumPointerType?
    var hoverType: CuriumHoverType?
    var webglVendor: String?
    var webglRenderer: String?

    var hasWebGLOverride: Bool {
        webglVendor != nil || webglRenderer != nil
    }

    var hasInputOverride: Bool {
        maxTouchPoints != nil || pointerType != nil || hoverType != nil
    }
}

/// Strictly mutually exclusive 3-way proxy policy matching Chromium NetworkContext + Patch 0009.
enum CuriumProxyConfig: Equatable, Sendable {
    case system
    case direct
    case fixed(rules: String, bypassRules: String?)

    var modeName: String {
        switch self {
        case .system: return "system"
        case .direct: return "direct"
        case .fixed: return "fixed"
        }
    }

    var summary: String {
        switch self {
        case .system: return "System Proxy"
        case .direct: return "Direct (Bypass System Proxy)"
        case .fixed(let rules, _): return "Fixed (\(rules))"
        }
    }
}

extension CuriumProxyConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case rules
        case bypassRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "system":
            self = .system
        case "direct":
            self = .direct
        case "fixed":
            let rules = try container.decode(String.self, forKey: .rules)
            let bypass = try container.decodeIfPresent(String.self, forKey: .bypassRules)
            self = .fixed(rules: rules, bypassRules: bypass)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: container,
                debugDescription: "Unsupported proxy mode: \(mode)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system:
            try container.encode("system", forKey: .mode)
        case .direct:
            try container.encode("direct", forKey: .mode)
        case .fixed(let rules, let bypassRules):
            try container.encode("fixed", forKey: .mode)
            try container.encode(rules, forKey: .rules)
            if let bypassRules, !bypassRules.isEmpty {
                try container.encode(bypassRules, forKey: .bypassRules)
            }
        }
    }
}

/// Optional launch-scoped hardware & environment overrides.
/// When all fields are `nil`, Curium reports 100% authentic native hardware & timezone.
struct CuriumHardwareOverrides: Codable, Equatable, Sendable {
    var hardwareConcurrency: Int?
    var deviceMemoryGB: Double?
    var timezone: String?

    static let native = CuriumHardwareOverrides()

    var isNative: Bool {
        hardwareConcurrency == nil && deviceMemoryGB == nil && timezone == nil
    }
}

struct CuriumFingerprintProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var notes: String
    var isBuiltIn: Bool
    var revision: UInt64
    var defaultSlot: CuriumDefaultSlot
    var mobile: CuriumIdentitySlot
    var desktop: CuriumIdentitySlot
    /// `nil` resolves iOS preferred languages at launch; non-nil uses this exact ordered BCP-47 list.
    var languages: [String]?
    var proxy: CuriumProxyConfig
    var webrtcIpHandlingPolicy: CuriumWebRTCPolicy
    var enableDoNotTrack: Bool
    var enableGlobalPrivacyControl: Bool
    var hardware: CuriumHardwareOverrides

    var usesNativeHardwareAndGPU: Bool {
        hardware.isNative && !mobile.hasWebGLOverride && !desktop.hasWebGLOverride
    }

    /// Serializes strictly the engine wire schema (`schemaVersion: 1`) without UI metadata.
    func makeEngineLaunchJSON(preferredSystemLanguages: [String] = Locale.preferredLanguages) throws -> Data {
        let resolvedLanguages: [String]
        if let explicit = languages, !explicit.isEmpty {
            resolvedLanguages = explicit
        } else {
            let normalized = CuriumNormalizedAcceptLanguages(preferredSystemLanguages)
            resolvedLanguages = normalized.split(separator: ",").map(String.init)
        }

        let payload = EngineWirePayload(
            schemaVersion: CuriumFingerprintSchema.version,
            revision: revision,
            profileId: id,
            defaultSlot: defaultSlot,
            mobile: mobile,
            desktop: desktop,
            languages: resolvedLanguages,
            proxy: proxy,
            webrtcIpHandlingPolicy: webrtcIpHandlingPolicy,
            enableDoNotTrack: enableDoNotTrack,
            enableGlobalPrivacyControl: enableGlobalPrivacyControl,
            hardware: hardware
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private struct EngineWirePayload: Encodable {
        let schemaVersion: Int
        let revision: UInt64
        let profileId: String
        let defaultSlot: CuriumDefaultSlot
        let mobile: CuriumIdentitySlot
        let desktop: CuriumIdentitySlot
        let languages: [String]
        let proxy: CuriumProxyConfig
        let webrtcIpHandlingPolicy: CuriumWebRTCPolicy
        let enableDoNotTrack: Bool
        let enableGlobalPrivacyControl: Bool
        let hardware: CuriumHardwareOverrides
    }
}

/// Authoritative status acknowledgement returned by `CrIOSEngineBootstrap.activeFingerprintStatus`.
struct CuriumEngineFingerprintStatus: Equatable, Sendable {
    let contractVersion: Int
    let state: String
    let appliedProfileId: String
    let profileDirectoryOpened: Bool
    let appliedConfigRevision: UInt64
    let defaultSlot: String
    let proxyMode: String
    let hardwareOverridesActive: Bool
    let rejectionCode: Int?
    let rejectionReason: String?

    init(dictionary: [String: Any]) {
        contractVersion = (dictionary["contractVersion"] as? NSNumber)?.intValue ?? 0
        state = (dictionary["state"] as? String) ?? "unsupported"
        appliedProfileId = (dictionary["appliedProfileId"] as? String) ?? "default"
        profileDirectoryOpened = (dictionary["profileDirectoryOpened"] as? NSNumber)?.boolValue ?? false
        appliedConfigRevision = (dictionary["appliedConfigRevision"] as? NSNumber)?.uint64Value ?? 0
        defaultSlot = (dictionary["defaultSlot"] as? String) ?? "mobile"
        proxyMode = (dictionary["proxyMode"] as? String) ?? "system"
        hardwareOverridesActive = (dictionary["hardwareOverridesActive"] as? NSNumber)?.boolValue ?? false
        rejectionCode = (dictionary["rejectionCode"] as? NSNumber)?.intValue
        rejectionReason = dictionary["rejectionReason"] as? String
    }
}

struct CuriumEngineFingerprintCapabilities: Equatable, Sendable {
    let contractVersion: Int
    let maxConfigBytes: Int
    let features: [String: Bool]
    let activationScopes: [String: String]

    var supportsLaunchFingerprintConfig: Bool {
        contractVersion >= CuriumFingerprintSchema.version
    }

    init(dictionary: [String: Any]?) {
        guard let dictionary else {
            contractVersion = 0
            maxConfigBytes = 0
            features = [:]
            activationScopes = [:]
            return
        }
        contractVersion = (dictionary["contractVersion"] as? NSNumber)?.intValue ?? 0
        maxConfigBytes = (dictionary["maxConfigBytes"] as? NSNumber)?.intValue ?? 0
        if let rawFeatures = dictionary["features"] as? [String: Any] {
            var parsed: [String: Bool] = [:]
            for (k, v) in rawFeatures {
                if let num = v as? NSNumber {
                    parsed[k] = num.boolValue
                }
            }
            features = parsed
        } else {
            features = [:]
        }
        activationScopes = (dictionary["activationScopes"] as? [String: String]) ?? [:]
    }
}

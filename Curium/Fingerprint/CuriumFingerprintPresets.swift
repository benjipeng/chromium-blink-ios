import Foundation

/// Built-in downstream fingerprint profiles. Adding or tuning presets requires
/// only Swift edits — no Chromium rebuild needed.
enum CuriumFingerprintPresets {
    static let allBuiltIns: [CuriumFingerprintProfile] = [
        defaultAuthenticChrome,
        iosBlinkAuthentic,
        macosDesktopFirst,
        windowsWorkstation,
        privacyHardened,
    ]

    /// Build 39 authentic Chrome dual-slot profile with 100% native Apple hardware & GPU.
    static let defaultAuthenticChrome = CuriumFingerprintProfile(
        id: "default",
        displayName: "Authentic Chrome (Default)",
        notes: "Android 15 Chrome on Mobile, macOS arm64 Chrome on Desktop. Preserves native Apple hardware and Metal GPU.",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .mobile,
        mobile: CuriumIdentitySlot(
            osCpu: "Linux; Android 10; K",
            appendMobileToken: true,
            primaryBrand: "Google Chrome",
            platform: "Android",
            platformVersion: "15.0.0",
            architecture: "",
            bitness: "",
            model: "",
            mobile: true,
            wow64: false,
            formFactors: ["Mobile"],
            navigatorPlatform: "Linux armv81"
        ),
        desktop: CuriumIdentitySlot(
            osCpu: "Macintosh; Intel Mac OS X 10_15_7",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "macOS",
            architecture: "arm",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "MacIntel"
        ),
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .default,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: .native
    )

    /// iOS 18_7 mobile UA with macOS desktop slot and 100% native Apple hardware & GPU.
    static let iosBlinkAuthentic = CuriumFingerprintProfile(
        id: "ios-blink",
        displayName: "iOS Blink + macOS Desktop",
        notes: "Isolated profile using iOS 18_7 mobile UA and macOS Desktop slot with native Apple hardware.",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .mobile,
        mobile: CuriumIdentitySlot(
            osCpu: "iPhone; CPU iPhone OS 18_7 like Mac OS X",
            appendMobileToken: true,
            primaryBrand: "Google Chrome",
            platform: "iOS",
            platformVersion: "18.7.0",
            architecture: "arm",
            bitness: "64",
            model: "",
            mobile: true,
            wow64: false,
            formFactors: ["Mobile"],
            navigatorPlatform: "iPhone"
        ),
        desktop: CuriumIdentitySlot(
            osCpu: "Macintosh; Intel Mac OS X 10_15_7",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "macOS",
            architecture: "arm",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "MacIntel"
        ),
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .default,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: .native
    )

    /// Desktop-first macOS Chrome profile (including ServiceWorkers & SharedWorkers) with native Apple Silicon.
    static let macosDesktopFirst = CuriumFingerprintProfile(
        id: "macos-desktop",
        displayName: "macOS Desktop-First",
        notes: "Isolated profile presenting macOS arm64 Chrome across all tabs and ServiceWorkers with native Apple hardware.",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .desktop,
        mobile: CuriumIdentitySlot(
            osCpu: "Macintosh; Intel Mac OS X 10_15_7",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "macOS",
            architecture: "arm",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "MacIntel"
        ),
        desktop: CuriumIdentitySlot(
            osCpu: "Macintosh; Intel Mac OS X 10_15_7",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "macOS",
            architecture: "arm",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "MacIntel"
        ),
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .default,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: .native
    )

    /// Example profile with opt-in non-Apple hardware & GPU overrides (Windows 11 x64 workstation).
    static let windowsWorkstation = CuriumFingerprintProfile(
        id: "win11-workstation",
        displayName: "Windows 11 Workstation",
        notes: "Isolated Windows 11 x64 Desktop profile with opt-in CPU, memory, desktop pointer, and Intel ANGLE WebGL overrides.",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .desktop,
        mobile: CuriumIdentitySlot(
            osCpu: "Windows NT 10.0; Win64; x64",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "Windows",
            platformVersion: "19.0.0",
            architecture: "x86",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "Win32",
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)"
        ),
        desktop: CuriumIdentitySlot(
            osCpu: "Windows NT 10.0; Win64; x64",
            appendMobileToken: false,
            primaryBrand: "Google Chrome",
            platform: "Windows",
            platformVersion: "19.0.0",
            architecture: "x86",
            bitness: "64",
            model: "",
            mobile: false,
            wow64: false,
            formFactors: ["Desktop"],
            navigatorPlatform: "Win32",
            maxTouchPoints: 0,
            pointerType: .fine,
            hoverType: .hover,
            webglVendor: "Google Inc. (Intel)",
            webglRenderer: "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)"
        ),
        languages: ["en-US", "en"],
        proxy: .system,
        webrtcIpHandlingPolicy: .defaultPublicInterfaceOnly,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: false,
        hardware: CuriumHardwareOverrides(
            hardwareConcurrency: 8,
            deviceMemoryGB: 8,
            timezone: nil
        )
    )

    /// Privacy-hardened profile keeping native Apple hardware while locking down WebRTC UDP & enabling GPC.
    static let privacyHardened = CuriumFingerprintProfile(
        id: "privacy-hardened",
        displayName: "Privacy Hardened",
        notes: "Isolated profile with native Apple hardware, non-proxied WebRTC UDP disabled, and Global Privacy Control enabled.",
        isBuiltIn: true,
        revision: 1,
        defaultSlot: .mobile,
        mobile: defaultAuthenticChrome.mobile,
        desktop: defaultAuthenticChrome.desktop,
        languages: nil,
        proxy: .system,
        webrtcIpHandlingPolicy: .disableNonProxiedUdp,
        enableDoNotTrack: false,
        enableGlobalPrivacyControl: true,
        hardware: .native
    )
}

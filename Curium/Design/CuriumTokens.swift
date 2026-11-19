import SwiftUI
import UIKit

enum CuriumPalette: String, CaseIterable, Identifiable, Sendable {
    case violet, thorium, neptunium

    var id: Self { self }

    var title: String {
        switch self {
        case .violet: "Curium Violet"
        case .thorium: "Thorium Teal"
        case .neptunium: "Neptunium Blue"
        }
    }

    var notation: String {
        switch self {
        case .violet: "96 Cm"
        case .thorium: "90 Th"
        case .neptunium: "93 Np"
        }
    }

    var tint: Color { Color(uiColor: ink) }

    // Each pair exceeds 4.5:1 on its corresponding system background.
    var ink: UIColor {
        switch self {
        case .violet: Self.dynamic(light: 0x57349C, dark: 0xC5AEFF)
        case .thorium: Self.dynamic(light: 0x006255, dark: 0x80DDCC)
        case .neptunium: Self.dynamic(light: 0x225494, dark: 0xA6CAFF)
        }
    }

    var tile: Color {
        switch self {
        case .violet: Color(uiColor: Self.dynamic(light: 0xEEE6FA, dark: 0x262035))
        case .thorium: Color(uiColor: Self.dynamic(light: 0xDFF3EE, dark: 0x162F2B))
        case .neptunium: Color(uiColor: Self.dynamic(light: 0xE4EFFD, dark: 0x172B44))
        }
    }

    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1
            )
        }
    }
}

extension EnvironmentValues {
    @Entry var curiumPalette = CuriumPalette.violet
}

enum CuriumSpace {
    static let omniboxWidth: CGFloat = 520
    static let tapTarget: CGFloat = 44
    static let secondaryInk = Color(uiColor: CuriumPalette.dynamic(light: 0x565260, dark: 0xB9B5C4))
}

import CoreText
import SwiftUI
import UIKit

/// Rapid Review's design tokens for Pi Chat, taken from the design system's
/// tokens.css. Every colour has a light and a dark value; the phone's own
/// appearance setting picks one.
enum Theme {
    // MARK: Grounds and lines

    /// The page behind panels (Settings).
    static let bg = Color(light: 0xF5F6F7, dark: 0x0F1114)
    /// Cards, panels, the header and the chat itself.
    static let surface = Color(light: 0xFFFFFF, dark: 0x16191D)
    /// Starter rows, neutral fills.
    static let surface2 = Color(light: 0xF0F1F3, dark: 0x1D2126)
    /// Every hairline.
    static let line = Color(light: 0xE2E4E8, dark: 0x282D33)
    /// Borders of inputs and secondary buttons.
    static let lineStrong = Color(light: 0xCDD1D7, dark: 0x383E46)
    /// Background of code.
    static let code = Color(light: 0xF6F7F9, dark: 0x121418)

    // MARK: Text

    static let text = Color(light: 0x14161A, dark: 0xE9EBEE)
    static let text2 = Color(light: 0x454B54, dark: 0xB4BAC3)
    static let text3 = Color(light: 0x646B76, dark: 0x8D949E)

    // MARK: Ink: every control

    static let accent = Color(light: 0x1F2328, dark: 0xE9EBEE)
    static let accentSoft = Color(light: 0xEEF0F2, dark: 0x262A30)
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0F1114)

    // MARK: Signal: where you are and what is chosen, never an action

    /// Electric blue: the assistant's mark, the focused message box and the chosen model.
    static let signal = Color(light: 0x0527FC, dark: 0x3094FF)
    static let signalSoft = Color(light: 0xEBEEFF, dark: 0x001C4D)
    static let onSignal = Color(light: 0xFFFFFF, dark: 0x0F1114)

    // MARK: Status

    static let fixed = Color(light: 0x13795B, dark: 0x5CCB9C)
    static let fixedSoft = Color(light: 0xE7F5EF, dark: 0x17312A)
    static let major = Color(light: 0xBC4C00, dark: 0xF5A35B)
    static let majorSoft = Color(light: 0xFFF1E5, dark: 0x3A2A18)
    static let crit = Color(light: 0xCF222E, dark: 0xF85149)
    static let critSoft = Color(light: 0xFFEBE9, dark: 0x3A1D1F)
    static let onCrit = Color(light: 0xFFFFFF, dark: 0x0F1114)

    // MARK: Type

    enum Weight { case regular, medium, semibold, bold }

    /// Instrument Sans, scaled with Dynamic Type.
    static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = "InstrumentSans-Regular"
        case .medium: name = "InstrumentSans-Medium"
        case .semibold: name = "InstrumentSans-SemiBold"
        case .bold: name = "InstrumentSans-Bold"
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    /// JetBrains Mono, for model names and code. Ships in 400 and 500.
    static func mono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name = (weight == .regular) ? "JetBrainsMono-Regular" : "JetBrainsMono-Medium"
        return .custom(name, size: size, relativeTo: .body)
    }

    /// 16, a message's text.
    static let lead = sans(16)
    /// 14, body text.
    static let body = sans(14)
    /// 15 semibold, panel titles.
    static let section = sans(15, .semibold)
    /// 26 semibold, the one big title (track it with `pageTitleTracking`).
    static let pageTitle = sans(26, .semibold)
    static let pageTitleTracking: CGFloat = -0.39
}

/// Registers the fonts that ship in the app bundle, so no Info.plist entry is needed.
enum BundledFonts {
    static func register() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    /// A colour that follows the phone's light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

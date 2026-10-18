import AppKit
import SwiftUI
import UsageCore

enum Theme {
    static func accent(_ provider: Provider) -> Color { Color(nsColor: nsAccent(provider)) }

    static func nsAccent(_ provider: Provider) -> NSColor {
        switch provider {
        case .claude: NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)  // #D97757
        case .codex: NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)   // #10A37F
        case .agy: NSColor(srgbRed: 0.259, green: 0.522, blue: 0.957, alpha: 1)     // #4285F4
        }
    }

    static let amber = NSColor(srgbRed: 0.961, green: 0.647, blue: 0.141, alpha: 1)  // #F5A524
    static let red = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)    // #E5484D

    /// Предупреждающий цвет по доле использования; nil — всё спокойно.
    /// Порог — по округлённому проценту, как в подписи: «90%» не должно быть янтарным.
    static func warning(_ used: Double) -> NSColor? {
        let percent = (used * 100).rounded()
        return percent >= 90 ? red : percent >= 70 ? amber : nil
    }

    static func bar(_ used: Double, _ provider: Provider) -> Color {
        Color(nsColor: warning(used) ?? nsAccent(provider))
    }
}

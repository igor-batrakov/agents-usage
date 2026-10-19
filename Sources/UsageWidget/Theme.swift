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
        // Copilot, Cursor and Kimi have black brand colors, OpenRouter gray: on the bars they would
        // blend with the track and "no data". Use distinct tones, far from amber and red.
        case .copilot: NSColor(srgbRed: 0.545, green: 0.361, blue: 0.965, alpha: 1)  // #8B5CF6
        case .cursor: NSColor(srgbRed: 0.851, green: 0.275, blue: 0.937, alpha: 1)   // #D946EF
        case .kimi: NSColor(srgbRed: 0.024, green: 0.714, blue: 0.831, alpha: 1)     // #06B6D4
        case .openrouter: NSColor(srgbRed: 0.392, green: 0.404, blue: 0.949, alpha: 1)  // #6467F2
        case .moonshot: NSColor(srgbRed: 0.518, green: 0.800, blue: 0.086, alpha: 1)  // #84CC16
        }
    }

    static let amber = NSColor(srgbRed: 0.961, green: 0.647, blue: 0.141, alpha: 1)  // #F5A524
    static let red = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)    // #E5484D

    /// Warning color for a usage fraction; nil when all is calm.
    /// The threshold uses the rounded percentage, as in the label: "90%" must not be amber.
    static func warning(_ used: Double) -> NSColor? {
        let percent = (used * 100).rounded()
        return percent >= 90 ? red : percent >= 70 ? amber : nil
    }

    static func bar(_ used: Double, _ provider: Provider) -> Color {
        Color(nsColor: warning(used) ?? nsAccent(provider))
    }
}

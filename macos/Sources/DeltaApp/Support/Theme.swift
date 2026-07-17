import AppKit
import SwiftUI

/// Estuary brand constants — the single source for the app name and palette
/// (see meta/issues/estuary-rebrand.md for the role table). Views take colors
/// from here instead of `Color.accentColor`, which ignores `.tint` on macOS
/// and can't adapt deep teal out of dark mode.
enum EstuaryTheme {
    static let appName = "Estuary"
    static let tagline = "Where conversations converge."

    static let deepTealHex = "#0F3D3E"
    static let seaGlassHex = "#7FBDB4"
    static let midnightBlueHex = "#0D1B2A"
    static let slateHex = "#4B5B66"
    static let warmIvoryHex = "#F6F4EF"
    static let coralHex = "#FF6F61"

    static let paletteHex = [
        deepTealHex, seaGlassHex, midnightBlueHex,
        slateHex, warmIvoryHex, coralHex,
    ]

    /// Accent per appearance: deep teal reads as near-black on dark
    /// backgrounds, so dark mode lightens to sea glass.
    static func accentHex(dark: Bool) -> String {
        dark ? seaGlassHex : deepTealHex
    }

    /// Adaptive primary accent (send button, links, selection tint) as
    /// NSColor for AppKit consumers (LinkText attributes). The dynamic
    /// provider re-resolves on appearance changes; a plain color picked at
    /// view-build time would not.
    static let accentNSColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(Color(hex: accentHex(dark: dark)))
    }

    /// SwiftUI face of `accentNSColor`.
    static let accent = Color(nsColor: accentNSColor)

    /// Outgoing bubble fill: deep teal in BOTH appearances — bubbles carry
    /// white text, and the dark-mode accent (sea glass) is too light for it.
    static let bubble = Color(hex: deepTealHex)

    /// Attention color: unread badges (muted chats stay gray).
    static let badge = Color(hex: coralHex)

    /// Badge numerals: white on coral is only ~2.7:1, so the badge carries
    /// dark text instead (muted gray badges keep white).
    static let badgeText = Color(hex: midnightBlueHex)

    /// The wave-into-speech-bubble logo (transparent PNG, bundled). Optional:
    /// callers fall back to an SF symbol if the resource is missing.
    @MainActor static let logo: NSImage? = {
        guard let url = Bundle.module.url(
            forResource: "estuary-logo", withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }()
}

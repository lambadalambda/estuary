import Testing
import SwiftUI
@testable import DeltaApp

// Guards the brand constants: a typo'd hex silently renders gray (Color(hex:)
// fallback), so validity is worth a real test.

@Suite struct EstuaryThemeTests {
    @Test func appNameIsEstuary() {
        #expect(EstuaryTheme.appName == "Estuary")
    }

    @Test func paletteHexValuesAreWellFormed() {
        for hex in EstuaryTheme.paletteHex {
            #expect(Color(hex: hex) != Color.gray, "malformed palette hex: \(hex)")
        }
    }

    @Test func paletteRolesAreDistinct() {
        #expect(Set(EstuaryTheme.paletteHex).count == EstuaryTheme.paletteHex.count)
    }

    @Test func accentAdaptsBetweenLightAndDark() {
        // Deep teal is near-invisible on dark backgrounds; dark mode must
        // resolve to a different (lighter) accent.
        #expect(EstuaryTheme.accentHex(dark: false) == EstuaryTheme.deepTealHex)
        #expect(EstuaryTheme.accentHex(dark: true) == EstuaryTheme.seaGlassHex)
    }

    @Test func chatSurfaceIsIvoryInLightMidnightInDark() {
        #expect(EstuaryTheme.chatSurfaceHex(dark: false) == EstuaryTheme.warmIvoryHex)
        #expect(EstuaryTheme.chatSurfaceHex(dark: true) == EstuaryTheme.midnightBlueHex)
    }

    @Test func incomingBubbleDiffersFromSurfaceInBothModes() {
        // Guards accidental same-color pairs only. The fills are DESIGNED
        // to sit close (calm); visual delineation comes from the bubble
        // shadow in ChatDetailView, which no color assertion can cover.
        for dark in [false, true] {
            #expect(EstuaryTheme.incomingBubbleHex(dark: dark)
                != EstuaryTheme.chatSurfaceHex(dark: dark))
            #expect(Color(hex: EstuaryTheme.incomingBubbleHex(dark: dark)) != Color.gray)
        }
    }

    @Test func bubbleStaysDeepTealForWhiteTextContrast() {
        // Outgoing bubbles carry white text; the dark-mode accent (sea
        // glass) would wash it out, so the bubble must not follow the
        // adaptive accent.
        #expect(EstuaryTheme.bubble == Color(hex: EstuaryTheme.deepTealHex))
        #expect(EstuaryTheme.bubble != Color(hex: EstuaryTheme.seaGlassHex))
    }

    @Test @MainActor func chatTilesLoadForBothModes() {
        // Guards the tile resource declarations; a missing tile silently
        // degrades to the flat surface color.
        #expect(EstuaryTheme.chatTile(dark: false) != nil)
        #expect(EstuaryTheme.chatTile(dark: true) != nil)
    }

    @Test @MainActor func logoResourceLoads() {
        // Guards the Package.swift resource declaration: a typo'd resource
        // path fails at runtime (onboarding shows the SF-symbol fallback),
        // not at build time.
        #expect(EstuaryTheme.logo != nil)
    }

    @Test func badgeIsCoralWithDarkText() {
        #expect(EstuaryTheme.badge == Color(hex: EstuaryTheme.coralHex))
        // White on coral is ~2.7:1 — badge numerals need the dark palette
        // color, not white.
        #expect(EstuaryTheme.badgeText == Color(hex: EstuaryTheme.midnightBlueHex))
    }
}

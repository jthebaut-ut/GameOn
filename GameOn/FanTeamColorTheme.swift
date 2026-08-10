import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Subtle Team-color chrome for **identity cards only** (list / detail header / chat preview).
/// When `colorHex` is nil/invalid, callers keep the existing untinted white/dark card look.
enum FanTeamColorTheme {
    /// Fill overlay opacity on top of the standard card background (~5–8% light, slightly more in dark).
    static func tintOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.10 : 0.07
    }

    /// Border opacity (~10–15%).
    static func strokeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.16 : 0.12
    }

    /// Accent adjusted so very dark colors still tint visibly in dark mode and
    /// very light colors remain perceptible in light mode.
    static func accentColor(colorHex: String?, colorScheme: ColorScheme) -> Color? {
        guard let hex = FanTeamColorPalette.normalized(colorHex),
              let base = Color(fanTeamHex: hex) else {
            return nil
        }
#if canImport(UIKit)
        let ui = UIColor(base)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return base }
        let luminance = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
        if colorScheme == .dark, luminance < 0.22 {
            // Lift near-black Team colors so the tint reads as a soft wash, not a void.
            let lifted = UIColor(
                red: min(1, r + 0.35),
                green: min(1, g + 0.35),
                blue: min(1, b + 0.35),
                alpha: 1
            )
            return Color(lifted)
        }
        if colorScheme == .light, luminance > 0.88 {
            // Slightly deepen near-white customs so the wash stays visible on white cards.
            let deepened = UIColor(
                red: max(0, r * 0.78),
                green: max(0, g * 0.78),
                blue: max(0, b * 0.78),
                alpha: 1
            )
            return Color(deepened)
        }
#endif
        return base
    }

    static func hasCustomColor(_ colorHex: String?) -> Bool {
        accentColor(colorHex: colorHex, colorScheme: .light) != nil
    }

    static func strokeColor(
        colorHex: String?,
        colorScheme: ColorScheme,
        fallback: Color
    ) -> Color {
        guard let accent = accentColor(colorHex: colorHex, colorScheme: colorScheme) else {
            return fallback
        }
        return accent.opacity(strokeOpacity(for: colorScheme))
    }

    /// Team-linked Discover Pickup preview accent.
    /// Valid custom Team color (contrast-adjusted) → that color; otherwise FanGeo Play orange.
    static func pickupDiscoverPreviewAccent(
        colorHex: String?,
        colorScheme: ColorScheme
    ) -> Color {
        accentColor(colorHex: colorHex, colorScheme: colorScheme) ?? FGColor.intentPlay
    }

    /// Discover Team preview card wash (slightly stronger than identity-card tint so it reads on map glass).
    static func discoverPreviewWashOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.14 : 0.10
    }

    /// Discover Team preview border — stronger than wash, still translucent.
    static func discoverPreviewStrokeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.55 : 0.42
    }

    /// Soft ambient glow under the Team-linked Discover preview card.
    static func discoverPreviewGlowOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.18 : 0.10
    }
}

/// Standard rounded card fill: base card + optional Team tint wash.
struct FanTeamIdentityCardFill: View {
    let colorHex: String?
    let colorScheme: ColorScheme
    var cornerRadius: CGFloat = 18
    var baseOpacityDark: Double = 0.82
    var baseOpacityLight: Double = 0.98

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(
                FGColor.cardBackground(colorScheme)
                    .opacity(colorScheme == .dark ? baseOpacityDark : baseOpacityLight)
            )
            if let accent = FanTeamColorTheme.accentColor(colorHex: colorHex, colorScheme: colorScheme) {
                shape.fill(accent.opacity(FanTeamColorTheme.tintOpacity(for: colorScheme)))
            }
        }
    }
}

extension View {
    /// Applies identity-card fill + border. When no Team color, matches prior untinted chrome.
    func fanTeamIdentityCardChrome(
        colorHex: String?,
        colorScheme: ColorScheme,
        cornerRadius: CGFloat = 18,
        baseOpacityDark: Double = 0.82,
        baseOpacityLight: Double = 0.98,
        highlightedBorder: Bool = false
    ) -> some View {
        let fallbackStroke = FGColor.divider(colorScheme).opacity(0.45)
        return self
            .background {
                FanTeamIdentityCardFill(
                    colorHex: colorHex,
                    colorScheme: colorScheme,
                    cornerRadius: cornerRadius,
                    baseOpacityDark: baseOpacityDark,
                    baseOpacityLight: baseOpacityLight
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        highlightedBorder
                            ? FGColor.accentGreen.opacity(0.85)
                            : FanTeamColorTheme.strokeColor(
                                colorHex: colorHex,
                                colorScheme: colorScheme,
                                fallback: fallbackStroke
                            ),
                        lineWidth: highlightedBorder ? 2 : 1
                    )
            }
    }
}

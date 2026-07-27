import SwiftUI

/// Shared curated profile-background hero artwork.
///
/// Loads exactly one full asset. Thumbnails are never used here.
/// Upper band stays clearly recognizable; white dissolve begins in the lower
/// artwork so identity text sits on a light surface without a hard seam.
struct ProfileBackgroundHeroArtwork: View {
    let option: ProfileBackgroundOption
    var showsReadabilityScrim: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            Image(option.fullAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    if showsReadabilityScrim {
                        topReadabilityScrim
                    }
                }
                .overlay {
                    whiteDissolveOverlay
                }
                .overlay {
                    edgeSofteningOverlay
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Minimal top darkening only — not a full-image dark scrim.
    private var topReadabilityScrim: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(colorScheme == .dark ? 0.12 : 0.03),
                Color.clear
            ],
            startPoint: .top,
            endPoint: UnitPoint(x: 0.5, y: 0.18)
        )
    }

    /// Transparent → white dissolve. Strong artwork through ~upper 45%; near-opaque
    /// white by the identity-text baseline (`identityTopInset` / `artworkHeight` ≈ 0.72).
    private var whiteDissolveOverlay: some View {
        let surface = colorScheme == .dark
            ? Color(red: 0.07, green: 0.08, blue: 0.10)
            : Color.white
        return LinearGradient(
            stops: [
                .init(color: surface.opacity(0.00), location: 0.00),
                .init(color: surface.opacity(0.00), location: 0.38),
                .init(color: surface.opacity(0.10), location: 0.48),
                .init(color: surface.opacity(0.32), location: 0.58),
                .init(color: surface.opacity(0.62), location: 0.66),
                .init(color: surface.opacity(0.88), location: 0.74),
                .init(color: surface.opacity(1.00), location: 0.84),
                .init(color: surface.opacity(1.00), location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// Subtle left/right softening so the image does not end abruptly.
    private var edgeSofteningOverlay: some View {
        let edge = colorScheme == .dark ? Color.black : Color.white
        return HStack(spacing: 0) {
            LinearGradient(
                colors: [edge.opacity(colorScheme == .dark ? 0.12 : 0.12), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 12)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [Color.clear, edge.opacity(colorScheme == .dark ? 0.12 : 0.12)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 12)
        }
        .allowsHitTesting(false)
    }
}

/// Own-profile / public-profile hero fill that layers curated artwork over the light surface.
struct ProfileBackgroundHeroFill: View {
    let option: ProfileBackgroundOption
    /// When set, pins artwork to a fixed hero band.
    var artworkHeight: CGFloat? = ProfileHeroMetrics.artworkHeight

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            surfaceBase
            if let artworkHeight {
                ProfileBackgroundHeroArtwork(option: option)
                    .frame(height: artworkHeight)
                    .frame(maxWidth: .infinity)
            } else {
                ProfileBackgroundHeroArtwork(option: option)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var surfaceBase: some View {
        colorScheme == .dark
            ? Color(red: 0.07, green: 0.08, blue: 0.10)
            : Color.white
    }
}

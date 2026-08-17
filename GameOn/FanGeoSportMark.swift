import SwiftUI

/// Official FanGeo circular sport mark.
/// Dark field, inner accent glow, thin colored ring, white custom silhouette.
/// Vector-only. No runtime image generation and no network fetch.
struct FanGeoSportMark: View {
    let sport: String
    var subtype: String? = nil
    var size: CGFloat = 48
    var wordmark: String? = nil

    private var descriptor: FanGeoSportMarkDescriptor {
        FanGeoSportMarkCatalog.descriptor(sport: sport, subtype: subtype)
    }

    private var ringWidth: CGFloat {
        max(1.5, size * 0.045)
    }

    private var compactWordmark: String {
        let raw = wordmark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard size >= 56, !raw.isEmpty else { return "" }
        return FanGeoSportMarkCatalog.compactWordmark(from: raw)
    }

    var body: some View {
        let accent = descriptor.accent
        ZStack {
            Circle()
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            accent.opacity(0.42),
                            accent.opacity(0.10),
                            Color.clear
                        ],
                        center: .bottom,
                        startRadius: size * 0.04,
                        endRadius: size * 0.62
                    )
                )
            FanGeoSportMarkGlyph(kind: descriptor.kind)
                .stroke(Color.white.opacity(0.96), style: StrokeStyle(
                    lineWidth: max(1.4, size * 0.038),
                    lineCap: .round,
                    lineJoin: .round
                ))
                .background {
                    FanGeoSportMarkGlyph(kind: descriptor.kind)
                        .fill(Color.white.opacity(0.94))
                }
                .padding(size * (compactWordmark.isEmpty ? 0.18 : 0.22))
                .offset(y: compactWordmark.isEmpty ? 0 : size * -0.06)
            if !compactWordmark.isEmpty {
                Text(compactWordmark)
                    .font(.system(size: max(7, size * 0.11), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, size * 0.10)
                    .offset(y: size * 0.28)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .strokeBorder(accent.opacity(0.92), lineWidth: ringWidth)
        }
        .accessibilityHidden(true)
    }
}

/// Large faded silhouette used as Discover Team card hero art.
struct FanGeoSportMarkWatermark: View {
    let sport: String
    var subtype: String? = nil
    var size: CGFloat = 132

    private var descriptor: FanGeoSportMarkDescriptor {
        FanGeoSportMarkCatalog.descriptor(sport: sport, subtype: subtype)
    }

    var body: some View {
        FanGeoSportMarkGlyph(kind: descriptor.kind)
            .stroke(descriptor.accent.opacity(0.22), style: StrokeStyle(
                lineWidth: 3.2,
                lineCap: .round,
                lineJoin: .round
            ))
            .background {
                FanGeoSportMarkGlyph(kind: descriptor.kind)
                    .fill(descriptor.accent.opacity(0.10))
            }
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Premium recruiting badge. Uses existing recruiting copy; uppercase is presentation-only.
struct FanTeamRecruitingBadge: View {
    let kind: FanTeamRecruitingKind
    let languageCode: String
    var accent: Color = FGColor.intentTeams

    var body: some View {
        HStack(spacing: 6) {
            FanGeoRecruitingShieldGlyph()
                .fill(accent)
                .frame(width: 11, height: 13)
            Text(L10n.t(kind.localizationKey, languageCode: languageCode))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .tracking(0.6)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t(kind.localizationKey, languageCode: languageCode))
    }
}

/// Compact metadata chip used on Discover Team cards.
struct FanGeoTeamCardChip: View {
    let title: String
    let systemImage: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(FGTypography.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(FGColor.secondaryText(colorScheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        )
        .accessibilityHidden(true)
    }
}

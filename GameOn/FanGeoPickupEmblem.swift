import SwiftUI

/// Standalone Pickup sport emblem: orange ring, white center, sport glyph.
/// Distinct from Team marks (dark field + sport-colored ring). Pickup stays orange.
struct FanGeoPickupEmblem: View {
    let sport: String
    var subtype: String? = nil
    var size: CGFloat = 76
    var status: FanGeoPickupEmblemStatus? = nil
    var languageCode: String = L10n.defaultLanguageCode
    var showsStatusDot: Bool = true

    private var kind: FanGeoSportMarkKind {
        FanGeoSportMarkCatalog.kind(sport: sport, subtype: subtype)
    }

    private var ringWidth: CGFloat {
        max(3.5, size * 0.09)
    }

    var body: some View {
        let orange = FGColor.intentPlay
        ZStack(alignment: .topLeading) {
            ZStack {
                Circle()
                    .fill(orange.opacity(0.22))
                    .frame(width: size + 10, height: size + 10)
                    .blur(radius: 8)
                Circle()
                    .fill(Color.white)
                    .frame(width: size, height: size)
                    .shadow(color: orange.opacity(0.38), radius: 10, y: 4)
                    .shadow(color: Color.black.opacity(0.10), radius: 6, y: 3)
                Circle()
                    .strokeBorder(orange, lineWidth: ringWidth)
                    .frame(width: size, height: size)
                FanGeoSportMarkGlyph(kind: kind)
                    .stroke(orange, style: StrokeStyle(
                        lineWidth: max(1.6, size * 0.045),
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .background {
                        FanGeoSportMarkGlyph(kind: kind)
                            .fill(orange.opacity(0.92))
                    }
                    .padding(size * 0.22)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
                if showsStatusDot {
                    Circle()
                        .fill(orange)
                        .frame(width: max(8, size * 0.14), height: max(8, size * 0.14))
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 1.5)
                        }
                        .offset(x: size * 0.34, y: size * 0.34)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)

            if let status {
                FanGeoPickupEmblemStatusBubble(
                    status: status,
                    languageCode: languageCode
                )
                .offset(x: -6, y: -8)
            }
        }
        .frame(width: size, height: size)
        .padding(.top, status == nil ? 0 : 10)
        .padding(.leading, status == nil ? 0 : 4)
        .accessibilityHidden(true)
    }
}

struct FanGeoPickupEmblemStatusBubble: View {
    let status: FanGeoPickupEmblemStatus
    let languageCode: String

    var body: some View {
        Text(L10n.t(status.localizationKey, languageCode: languageCode))
            .font(.caption2.weight(.bold))
            .foregroundStyle(FGColor.intentPlay)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.intentPlay.opacity(0.16))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.intentPlay.opacity(0.28), lineWidth: 0.8)
            }
            .fixedSize()
            .accessibilityLabel(L10n.t(status.localizationKey, languageCode: languageCode))
    }
}

/// Orange PICKUP GAME pill for standalone Discover cards.
struct FanGeoPickupGameFormatPill: View {
    let languageCode: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "figure.run")
                .font(.caption2.weight(.bold))
            Text(L10n.t("discover_pickup_card_format_badge", languageCode: languageCode))
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(FGColor.intentPlay)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(FGColor.intentPlay.opacity(0.14))
        )
        .accessibilityLabel(L10n.t("discover_pickup_card_format_badge", languageCode: languageCode))
    }
}

struct FanGeoPickupSpotsPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(FGColor.intentPlay)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.intentPlay.opacity(0.14))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.intentPlay.opacity(0.22), lineWidth: 0.8)
            }
    }
}

/// Faded sport glyph used as standalone Pickup card hero art. Always orange.
struct FanGeoPickupEmblemWatermark: View {
    let sport: String
    var subtype: String? = nil
    var size: CGFloat = 150

    private var kind: FanGeoSportMarkKind {
        FanGeoSportMarkCatalog.kind(sport: sport, subtype: subtype)
    }

    var body: some View {
        FanGeoSportMarkGlyph(kind: kind)
            .stroke(FGColor.intentPlay.opacity(0.16), style: StrokeStyle(
                lineWidth: 3,
                lineCap: .round,
                lineJoin: .round
            ))
            .background {
                FanGeoSportMarkGlyph(kind: kind)
                    .fill(FGColor.intentPlay.opacity(0.07))
            }
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct FanGeoPickupPreviewActionRow: View {
    let row: PickupGameRow
    let guestMapsActionsToLogin: Bool
    let detailTitle: String
    let showsDetailsButton: Bool
    let colorScheme: ColorScheme
    let openDetailAction: () -> Void
    let openDirections: (URL) -> Void

    var body: some View {
        HStack(spacing: FGSpacing.sm) {
            if !guestMapsActionsToLogin, let lat = row.latitude, let lon = row.longitude {
                Button {
                    if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                        openDirections(url)
                    }
                } label: {
                    Label("Directions", systemImage: "map")
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(FGColor.intentPlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if showsDetailsButton {
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                        openDetailAction()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(detailTitle)
                            .font(FGTypography.metadata.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                    }
                    .foregroundStyle(FGColor.intentPlay)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(FGColor.intentPlay.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

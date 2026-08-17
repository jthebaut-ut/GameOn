import CoreLocation
import SwiftUI
import UIKit

/// Compact Play → Places Team discovery card (public-safe fields only).
struct DiscoverFanTeamPreviewCard: View {
    let team: DiscoverableFanTeamMapRow
    let distanceMiles: Double?
    let languageCode: String
    let onDismiss: () -> Void
    let onViewTeam: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var mainInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
    }

    private var subInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.70) : FGColor.secondaryText(colorScheme)
    }

    private var accent: Color {
        FanGeoSportMarkCatalog.accent(sport: team.sport, subtype: team.sportSubtype)
    }

    private var recruitingKind: FanTeamRecruitingKind? {
        FanTeamRecruitingKind.advertised(lookingForPlayers: team.lookingForPlayers)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FanGeoSportMarkWatermark(
                sport: team.sport,
                subtype: team.sportSubtype,
                size: 148
            )
            .offset(x: 36, y: 8)
            .opacity(0.95)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                FanTeamMarkView(
                    sport: team.sport,
                    logoURL: team.logoURL,
                    logoThumbnailURL: team.logoThumbnailURL,
                    colorHex: team.colorHex,
                    sportSubtype: team.sportSubtype,
                    size: 78,
                    wordmark: team.hasCustomLogo ? nil : team.name,
                    displayRefreshToken: team.displayRefreshToken
                )
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        if let recruitingKind {
                            FanTeamRecruitingBadge(
                                kind: recruitingKind,
                                languageCode: languageCode,
                                accent: accent
                            )
                        }
                        Text(team.name)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(mainInk)
                            .lineLimit(2)
                        Text(team.sportIdentityLine(languageCode: languageCode))
                            .font(FGTypography.metadata.weight(.medium))
                            .foregroundStyle(subInk)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.65) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("discover_team_preview_dismiss", languageCode: languageCode))
                }

                HStack(spacing: 8) {
                    if team.memberCount > 0 {
                        FanGeoTeamCardChip(
                            title: memberCountText,
                            systemImage: "person.2.fill",
                            colorScheme: colorScheme
                        )
                    }
                    if let distanceText {
                        FanGeoTeamCardChip(
                            title: distanceText,
                            systemImage: "mappin.and.ellipse",
                            colorScheme: colorScheme
                        )
                    }
                }

                let locality = team.localityDisplayLine()
                if !locality.isEmpty {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(subInk)
                        Text(locality)
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(subInk)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(
                            L10n.t(
                                team.precision == .specific
                                    ? "team_discovery_specific_location"
                                    : "team_discovery_general_area",
                                languageCode: languageCode
                            )
                        )
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                        )
                    }
                }

                Button(action: onViewTeam) {
                    HStack(spacing: 6) {
                        Text(L10n.t("discover_team_view_team", languageCode: languageCode))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(FGColor.intentTeams, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("discover_team_view_team", languageCode: languageCode))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.12) : Color.white)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    accent.opacity(colorScheme == .dark ? 0.38 : 0.18),
                    lineWidth: 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(previewAccessibilityLabel)
    }

    private var memberCountText: String {
        if team.memberCount == 1 {
            return L10n.t("discover_team_members_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("discover_team_members_other_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(team.memberCount)
        )
    }

    private var distanceText: String? {
        guard let distanceMiles, distanceMiles.isFinite, distanceMiles >= 0 else { return nil }
        return String(
            format: L10n.t("discover_team_distance_miles_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            distanceMiles
        )
    }

    private var previewAccessibilityLabel: String {
        var parts = [team.mapAccessibilityLabel(languageCode: languageCode)]
        if let distanceText { parts.append(distanceText) }
        parts.append(L10n.t("discover_team_view_team", languageCode: languageCode))
        return parts.joined(separator: ". ")
    }
}

/// Compact public-safe preview for Edit Team → Discovery. Uses the same
/// `DiscoverableFanTeamMapRow` presentation helpers as Play → Places.
struct DiscoverFanTeamEditorPreviewCard: View {
    let team: DiscoverableFanTeamMapRow
    let languageCode: String
    var localPreviewImage: UIImage? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var sportLine: String {
        team.sportIdentityLine(languageCode: languageCode)
    }

    private var memberCountText: String? {
        guard team.memberCount > 0 else { return nil }
        if team.memberCount == 1 {
            return L10n.t("discover_team_members_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("discover_team_members_other_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(team.memberCount)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                FanTeamMarkView(
                    sport: team.sport,
                    logoURL: team.logoURL,
                    logoThumbnailURL: team.logoThumbnailURL,
                    colorHex: team.colorHex,
                    sportSubtype: team.sportSubtype,
                    size: 56,
                    wordmark: team.hasCustomLogo ? nil : team.name,
                    localPreviewImage: localPreviewImage,
                    displayRefreshToken: team.displayRefreshToken
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(team.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if team.lookingForPlayers {
                        FanTeamRecruitingBadge(
                            kind: .players,
                            languageCode: languageCode,
                            accent: FanGeoSportMarkCatalog.accent(sport: team.sport, subtype: team.sportSubtype)
                        )
                    }
                    if !sportLine.isEmpty {
                        Text(sportLine)
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let locality = team.localityDisplayLine()
                    if !locality.isEmpty {
                        Label(locality, systemImage: "mappin.circle.fill")
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                previewBadge(
                    title: L10n.t(
                        team.precision == .specific
                            ? "team_discovery_specific_location"
                            : "team_discovery_general_area",
                        languageCode: languageCode
                    )
                )
                if let memberCountText {
                    previewBadge(title: memberCountText)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(team.mapAccessibilityLabel(languageCode: languageCode))
    }

    private func previewBadge(title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.12))
            )
    }
}

struct DiscoverFanTeamMapMarker: View {
    let team: DiscoverableFanTeamMapRow
    let isSelected: Bool
    let languageCode: String
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    private var markSize: CGFloat { isSelected ? 42 : 36 }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(FGColor.intentTeams.opacity(isSelected ? 0.55 : 0), lineWidth: 3)
                    .frame(width: 64, height: 64)
                    .scaleEffect(isSelected && pulse ? 1.14 : 0.96)
                    .opacity(isSelected ? (pulse ? 0.32 : 0.78) : 0)
                    .animation(
                        isSelected
                            ? .easeInOut(duration: 1.15).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.18),
                        value: pulse
                    )

                Circle()
                    .fill(FGColor.intentTeams.opacity(isSelected ? 0.42 : 0.22))
                    .frame(width: isSelected ? 56 : 48, height: isSelected ? 56 : 48)
                    .blur(radius: isSelected ? 5 : 2.5)

                FanTeamMarkView(
                    sport: team.sport,
                    logoURL: team.logoURL,
                    logoThumbnailURL: team.logoThumbnailURL,
                    colorHex: team.colorHex,
                    sportSubtype: team.sportSubtype,
                    size: markSize,
                    displayRefreshToken: team.displayRefreshToken
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? FGColor.intentTeams : Color.white.opacity(0.92),
                            lineWidth: isSelected ? 3 : 2
                        )
                }
                .shadow(
                    color: FGColor.intentTeams.opacity(colorScheme == .dark ? 0.42 : 0.28),
                    radius: isSelected ? 10 : 7,
                    y: isSelected ? 5 : 3
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.22), radius: isSelected ? 8 : 6, y: 4)
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(team.mapAccessibilityLabel(languageCode: languageCode))
        .accessibilityAddTraits(.isButton)
        .onAppear { pulse = isSelected }
        .onChange(of: isSelected) { _, selected in
            pulse = selected
        }
    }
}

struct DiscoverFanTeamClusterMarker: View {
    let cluster: DiscoverableFanTeamCluster
    let languageCode: String
    let onTap: () -> Void

    var body: some View {
        DiscoverMapEntityClusterMarker(
            kind: .teams,
            count: cluster.count,
            languageCode: languageCode,
            onTap: onTap
        )
    }
}

struct DiscoverFanTeamClusterSheet: View {
    let cluster: DiscoverableFanTeamCluster
    let currentUserLocation: CLLocationCoordinate2D?
    let languageCode: String
    let onSelect: (DiscoverableFanTeamMapRow) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(cluster.rows) { team in
                        Button {
                            onSelect(team)
                            dismiss()
                        } label: {
                            clusterRow(team)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(
                String(
                    format: L10n.t("discover_team_cluster_title_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(cluster.count)
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        dismiss()
                    }
                    .font(FGTypography.metadata.weight(.semibold))
                }
            }
        }
    }

    private func clusterRow(_ team: DiscoverableFanTeamMapRow) -> some View {
        HStack(spacing: 12) {
            FanTeamMarkView(
                sport: team.sport,
                logoURL: team.logoURL,
                logoThumbnailURL: team.logoThumbnailURL,
                colorHex: team.colorHex,
                sportSubtype: team.sportSubtype,
                size: 40,
                displayRefreshToken: team.displayRefreshToken
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(team.name)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text(team.sportIdentityLine(languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                let locality = team.localityDisplayLine()
                if !locality.isEmpty {
                    Text(locality)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let miles = distanceMiles(to: team) {
                Text(
                    String(
                        format: L10n.t("discover_team_distance_miles_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        miles
                    )
                )
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(team.mapAccessibilityLabel(languageCode: languageCode))
    }

    private func distanceMiles(to team: DiscoverableFanTeamMapRow) -> Double? {
        guard let user = currentUserLocation,
              CLLocationCoordinate2DIsValid(user),
              CLLocationCoordinate2DIsValid(team.coordinate) else { return nil }
        let from = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let to = CLLocation(latitude: team.latitude, longitude: team.longitude)
        return from.distance(from: to) / 1609.344
    }
}

import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Edit Team → Discovery & Location. Visual hierarchy only; draft state still
/// lives on `FanTeamDiscoverySettings` and persists through `update_fan_team_discovery`.
struct FanTeamDiscoveryEditorSection: View {
    @Binding var discovery: FanTeamDiscoverySettings
    let team: FanTeamSummary
    let draftName: String
    let draftSport: String
    let draftColorHex: String
    let logoURL: String?
    let logoThumbnailURL: String?
    let localPreviewImage: UIImage?
    let isLoading: Bool
    let languageCode: String
    let onChooseLocation: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var chrome: FanTeamDiscoveryEditorPresentation.LocationChrome {
        FanTeamDiscoveryEditorPresentation.locationChrome(for: discovery)
    }

    private var publicPreviewRow: DiscoverableFanTeamMapRow? {
        FanTeamDiscoveryEditorPresentation.publicPreviewRow(
            settings: discovery,
            teamId: team.id,
            name: draftName,
            sport: draftSport,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: draftColorHex,
            memberCount: team.memberCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditProfileSection(title: L10n.t("team_discovery_section_title", languageCode: languageCode)) {
                discoverabilityRow
                EditProfileRowDivider()
                recruitingRow
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 8)
                }
            }

            switch chrome {
            case .compactSetup:
                compactLocationCard(hasLocation: false)
            case .compactConfigured:
                compactLocationCard(hasLocation: true)
            case .prominentMissing:
                prominentMissingLocationCard
            case .prominentConfigured:
                prominentConfiguredLocationCard
            }

            if FanTeamDiscoveryEditorPresentation.showsPublicPreview(settings: discovery),
               let publicPreviewRow {
                whatOthersWillSeeCard(publicPreviewRow)
            }

            editorsOnlyFooter
        }
    }

    private var discoverabilityRow: some View {
        discoveryToggleRow(
            systemImage: "globe",
            title: L10n.t("team_discovery_show_on_discover", languageCode: languageCode),
            supporting: L10n.t("team_discovery_show_on_discover_supporting", languageCode: languageCode),
            isOn: $discovery.isDiscoverable
        )
    }

    private var recruitingRow: some View {
        discoveryToggleRow(
            systemImage: "person.2.fill",
            title: L10n.t("team_discovery_looking_for_players", languageCode: languageCode),
            supporting: L10n.t("team_discovery_looking_for_players_supporting", languageCode: languageCode),
            isOn: $discovery.lookingForPlayers,
            dimmed: !discovery.isDiscoverable,
            hint: discovery.isDiscoverable
                ? nil
                : L10n.t("team_discovery_looking_for_players_private_hint", languageCode: languageCode)
        )
    }

    private func discoveryToggleRow(
        systemImage: String,
        title: String,
        supporting: String,
        isOn: Binding<Bool>,
        dimmed: Bool = false,
        hint: String? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            discoveryGlyph(systemImage)
                .accessibilityHidden(true)

            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(supporting)
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(FGColor.accentGreen)
            .accessibilityLabel(title)
            .accessibilityHint(hint ?? supporting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(dimmed ? 0.62 : 1)
    }

    private func discoveryGlyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(FGColor.accentGreen)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.14))
            )
    }

    private func compactLocationCard(hasLocation: Bool) -> some View {
        FanTeamDiscoverySettingsCard {
            Button(action: onChooseLocation) {
                HStack(alignment: .center, spacing: 10) {
                    discoveryGlyph("mappin.and.ellipse")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("team_discovery_location_title", languageCode: languageCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            hasLocation
                                ? discovery.displayLocationSummary(languageCode: languageCode)
                                : L10n.t("team_discovery_location_supporting", languageCode: languageCode)
                        )
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(
                        L10n.t(
                            hasLocation ? "team_discovery_change" : "team_discovery_add_location",
                            languageCode: languageCode
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentGreen)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("team_discovery_location_title", languageCode: languageCode))
            .accessibilityHint(
                L10n.t(
                    hasLocation ? "team_discovery_change" : "team_discovery_add_location",
                    languageCode: languageCode
                )
            )
            .accessibilityAddTraits(.isButton)
        }
    }

    private var prominentMissingLocationCard: some View {
        FanTeamDiscoverySettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                locationCardHeader(showsChange: false)

                Text(L10n.t("team_discovery_location_required_supporting", languageCode: languageCode))
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onChooseLocation) {
                    Text(L10n.t("team_discovery_choose_location", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(FGColor.accentGreen)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("team_discovery_choose_location", languageCode: languageCode))
                .accessibilityAddTraits(.isButton)
            }
            .padding(14)
        }
    }

    private var prominentConfiguredLocationCard: some View {
        FanTeamDiscoverySettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                locationCardHeader(showsChange: true)

                Text(L10n.t("team_discovery_location_supporting", languageCode: languageCode))
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                locationMapAndAddressRow

                precisionSelector

                Text(
                    L10n.t(
                        discovery.precision == .specific
                            ? "team_discovery_specific_explainer"
                            : "team_discovery_general_explainer",
                        languageCode: languageCode
                    )
                )
                .font(.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    discovery.precision == .specific
                        ? L10n.t("team_discovery_specific_location", languageCode: languageCode)
                        : L10n.t("team_discovery_general_area", languageCode: languageCode)
                )
                .accessibilityValue(
                    L10n.t(
                        discovery.precision == .specific
                            ? "team_discovery_specific_explainer"
                            : "team_discovery_general_explainer",
                        languageCode: languageCode
                    )
                )

                privacyBanner
            }
            .padding(14)
        }
    }

    private func locationCardHeader(showsChange: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.t("team_discovery_location_title", languageCode: languageCode))
                .font(.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if showsChange {
                Button(action: onChooseLocation) {
                    HStack(spacing: 2) {
                        Text(L10n.t("team_discovery_change", languageCode: languageCode))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("team_discovery_change", languageCode: languageCode))
                .accessibilityHint(L10n.t("team_discovery_location_title", languageCode: languageCode))
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private var locationMapAndAddressRow: some View {
        HStack(alignment: .top, spacing: 12) {
            FanTeamDiscoveryMiniMap(
                settings: discovery,
                languageCode: languageCode
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(discovery.displayLocationSummary(languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                precisionBadge
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var precisionBadge: some View {
        let specific = discovery.precision == .specific
        return HStack(spacing: 4) {
            Image(systemName: specific ? "mappin.circle.fill" : "circle.dotted")
                .font(.caption.weight(.semibold))
            Text(
                L10n.t(
                    specific ? "team_discovery_specific_location" : "team_discovery_general_area",
                    languageCode: languageCode
                )
            )
            .font(.caption.weight(.semibold))
        }
        .foregroundStyle(FGColor.accentGreen)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.t(
                specific ? "team_discovery_specific_location" : "team_discovery_general_area",
                languageCode: languageCode
            )
        )
    }

    private var precisionSelector: some View {
        Picker("", selection: $discovery.precision) {
            Text(L10n.t("team_discovery_specific_location", languageCode: languageCode))
                .tag(FanTeamDiscoveryLocationPrecision.specific)
            Text(L10n.t("team_discovery_general_area", languageCode: languageCode))
                .tag(FanTeamDiscoveryLocationPrecision.generalArea)
        }
        .pickerStyle(.segmented)
        .tint(FGColor.accentGreen)
        .accessibilityLabel(L10n.t("team_discovery_location_title", languageCode: languageCode))
    }

    private var privacyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.accentGreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("team_discovery_location_privacy", languageCode: languageCode))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("team_discovery_location_privacy_home", languageCode: languageCode))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.82))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
        )
        .accessibilityElement(children: .combine)
    }

    private func whatOthersWillSeeCard(_ row: DiscoverableFanTeamMapRow) -> some View {
        FanTeamDiscoverySettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("team_discovery_what_others_will_see", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                DiscoverFanTeamEditorPreviewCard(
                    team: row,
                    languageCode: languageCode,
                    localPreviewImage: localPreviewImage
                )
            }
            .padding(14)
        }
    }

    private var editorsOnlyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption2.weight(.semibold))
            Text(L10n.t("team_discovery_editors_only", languageCode: languageCode))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(FGColor.mutedText(colorScheme))
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct FanTeamDiscoverySettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Compact non-interactive MapKit preview of the draft Team discovery coordinate.
struct FanTeamDiscoveryMiniMap: View {
    let settings: FanTeamDiscoverySettings
    let languageCode: String

    private var coordinate: CLLocationCoordinate2D? {
        guard settings.hasValidDiscoveryCoordinate,
              let latitude = settings.latitude,
              let longitude = settings.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var region: MKCoordinateRegion? {
        guard let camera = FanTeamDiscoveryEditorPresentation.mapCamera(for: settings) else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
            span: MKCoordinateSpan(latitudeDelta: camera.delta, longitudeDelta: camera.delta)
        )
    }

    private var accessibilityText: String {
        let key = settings.precision == .specific
            ? "team_discovery_map_preview_specific_a11y"
            : "team_discovery_map_preview_general_a11y"
        return L10n.t(key, languageCode: languageCode)
    }

    var body: some View {
        Group {
            if let coordinate, let region {
                Map(initialPosition: .region(region), interactionModes: []) {
                    if settings.precision == .generalArea {
                        MapCircle(center: coordinate, radius: FanTeamDiscoveryEditorPresentation.generalAreaRadiusMeters)
                            .foregroundStyle(FGColor.accentGreen.opacity(0.22))
                            .stroke(FGColor.accentGreen.opacity(0.55), lineWidth: 1.5)
                    }
                    Annotation("", coordinate: coordinate) {
                        if settings.precision == .specific {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundStyle(FGColor.accentGreen)
                                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        } else {
                            ZStack {
                                Circle()
                                    .fill(FGColor.accentGreen.opacity(0.28))
                                    .frame(width: 16, height: 16)
                                Circle()
                                    .fill(FGColor.accentGreen.opacity(0.82))
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .id(FanTeamDiscoveryEditorPresentation.mapIdentity(for: settings))
            } else {
                Color.clear
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

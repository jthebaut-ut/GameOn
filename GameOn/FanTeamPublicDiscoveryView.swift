import SwiftUI

/// Public-safe Team discovery destination for visitors who are not authorized members/guardians.
/// Does not load member-only Team Detail, chat, schedule, roster, or permissions.
struct FanTeamPublicDiscoveryView: View {
    let team: DiscoverableFanTeamMapRow
    var distanceMiles: Double? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var resolvedTeam: DiscoverableFanTeamMapRow

    init(team: DiscoverableFanTeamMapRow, distanceMiles: Double? = nil) {
        self.team = team
        self.distanceMiles = distanceMiles
        _resolvedTeam = State(initialValue: team)
    }

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    private var recruitingKind: FanTeamRecruitingKind? {
        FanTeamRecruitingKind.advertised(lookingForPlayers: resolvedTeam.lookingForPlayers)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    FanTeamMarkView(
                        sport: resolvedTeam.sport,
                        logoURL: resolvedTeam.logoURL,
                        logoThumbnailURL: resolvedTeam.logoThumbnailURL,
                        colorHex: resolvedTeam.colorHex,
                        sportSubtype: resolvedTeam.sportSubtype,
                        size: 96,
                        wordmark: resolvedTeam.hasCustomLogo ? nil : resolvedTeam.name,
                        preferDetailURL: true
                    )
                    .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text(resolvedTeam.name)
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.center)
                        Text(resolvedTeam.sportIdentityLine(languageCode: languageCode))
                            .font(FGTypography.body)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.center)
                        if let recruitingKind {
                            FanTeamRecruitingBadge(
                                kind: recruitingKind,
                                languageCode: languageCode,
                                accent: FanGeoSportMarkCatalog.accent(
                                    sport: resolvedTeam.sport,
                                    subtype: resolvedTeam.sportSubtype
                                )
                            )
                        }
                    }

                    if hasPublicInfoContent {
                        publicInfoCard
                    }
                    teamInfoCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
            .navigationTitle(L10n.t("discover_team_view_team", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) { dismiss() }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(resolvedTeam.mapAccessibilityLabel(languageCode: languageCode))
            .task(id: team.id) {
                await refreshPublicSummaryIfAvailable()
            }
        }
    }

    private var hasPublicInfoContent: Bool {
        !resolvedTeam.localityDisplayLine().isEmpty
            || resolvedTeam.memberCount > 0
            || distanceText != nil
    }

    private var publicInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            let locality = resolvedTeam.localityDisplayLine()
            if !locality.isEmpty {
                publicRow(
                    title: L10n.t("team_discovery_location_title", languageCode: languageCode),
                    value: locality,
                    systemImage: "mappin.circle.fill",
                    accessory: L10n.t(
                        resolvedTeam.precision == .specific
                            ? "team_discovery_specific_location"
                            : "team_discovery_general_area",
                        languageCode: languageCode
                    )
                )
            }
            if resolvedTeam.memberCount > 0 {
                publicRow(
                    title: L10n.t("fan_teams_members_label", languageCode: languageCode),
                    value: memberCountText,
                    systemImage: "person.2.fill",
                    accessory: nil
                )
            }
            if let distanceText {
                publicRow(
                    title: distanceText,
                    value: distanceText,
                    systemImage: "location.fill",
                    accessory: nil,
                    showsTitle: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// Sport identity only. Competition level, created date, and Team Leadership
    /// are omitted because they are not in the public-safe RPC projection.
    private var teamInfoCard: some View {
        let sportLine = resolvedTeam.sportIdentityLine(languageCode: languageCode)
        return Group {
            if !sportLine.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("fan_teams_team_info", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    publicRow(
                        title: L10n.t("fan_teams_sport", languageCode: languageCode),
                        value: sportLine,
                        systemImage: "sportscourt.fill",
                        accessory: nil
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
        }
    }

    private func publicRow(
        title: String,
        value: String,
        systemImage: String,
        accessory: String?,
        showsTitle: Bool = true
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FGColor.intentTeams)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                if showsTitle {
                    Text(title)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Text(value)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            Spacer(minLength: 8)
            if let accessory, !accessory.isEmpty {
                Text(accessory)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FanGeoSportMarkCatalog.accent(
                        sport: resolvedTeam.sport,
                        subtype: resolvedTeam.sportSubtype
                    ))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var memberCountText: String {
        if resolvedTeam.memberCount == 1 {
            return L10n.t("discover_team_members_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("discover_team_members_other_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(resolvedTeam.memberCount)
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

    /// Refresh from the public-safe RPC only. Never roster, schedule, chat, or membership detail.
    private func refreshPublicSummaryIfAvailable() async {
        do {
            let fresh = try await FanTeamsService().getPublicFanTeamSummary(teamId: team.id)
            resolvedTeam = fresh
        } catch {
#if DEBUG
            print("[DiscoverFanTeams] public summary refresh skipped error=\(error.localizedDescription)")
#endif
        }
    }
}

import SwiftUI

struct FavoriteFollowingAthleteDirectoryView: View {
    let title: String
    let athletes: [FavoriteTeam]
    @Binding var selectedIDs: [String]
    let accent: Color
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    private var uniqueAthletes: [FavoriteTeam] {
        FavoriteFollowingCountryBrowse.uniquedTeams(athletes)
    }

    var body: some View {
        ScrollView {
            if uniqueAthletes.isEmpty {
                Text(L10n.t("following_athletes_coming_soon", languageCode: languageCode))
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FGSpacing.md)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(uniqueAthletes) { athlete in
                        FollowingCatalogTeamCard(
                            team: athlete,
                            isSelected: selectedIDs.contains(athlete.id),
                            accent: accent,
                            languageCode: languageCode,
                            showsLeague: true,
                            followStyle: .plus
                        ) {
                            if selectedIDs.contains(athlete.id) {
                                selectedIDs = FavoriteTeamsStore.removing(athlete.id, from: selectedIDs)
                            } else {
                                selectedIDs = FavoriteTeamsStore.adding(athlete.id, to: selectedIDs)
                            }
                        }
                    }
                }
                .padding(FGSpacing.md)
            }
        }
        .fanGeoScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FavoriteFollowingAthleteLeagueView: View {
    let leagueName: String
    let athletes: [FavoriteTeam]
    @Binding var selectedIDs: [String]
    let accent: Color
    let languageCode: String

    private var teams: [FavoriteFollowingLeagueSummary] {
        FavoriteFollowingCountryBrowse.athleteTeams(from: athletes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !teams.isEmpty {
                    Text(L10n.t("following_browse_by_team", languageCode: languageCode))
                        .font(FGTypography.cardTitle.weight(.bold))
                        .padding(.horizontal, FGSpacing.md)
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(teams) { summary in
                            NavigationLink(value: FavoriteFollowingAthleteTeamRoute(id: summary.id, name: summary.name)) {
                                FollowingLeagueCard(summary: summary, accent: accent, languageCode: languageCode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, FGSpacing.md)
                }

                Text(L10n.t("following_all_athletes", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .padding(.horizontal, FGSpacing.md)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(FavoriteFollowingCountryBrowse.uniquedTeams(athletes)) { athlete in
                        FollowingCatalogTeamCard(
                            team: athlete,
                            isSelected: selectedIDs.contains(athlete.id),
                            accent: accent,
                            languageCode: languageCode
                        ) {
                            if selectedIDs.contains(athlete.id) {
                                selectedIDs = FavoriteTeamsStore.removing(athlete.id, from: selectedIDs)
                            } else {
                                selectedIDs = FavoriteTeamsStore.adding(athlete.id, to: selectedIDs)
                            }
                        }
                    }
                }
                .padding(.horizontal, FGSpacing.md)
            }
            .padding(.vertical, 12)
        }
        .fanGeoScreenBackground()
        .navigationTitle(leagueName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

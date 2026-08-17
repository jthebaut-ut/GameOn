import SwiftUI

// MARK: - Shared catalog team card

struct FollowingCatalogTeamCard: View {
    let team: FavoriteTeam
    let isSelected: Bool
    let accent: Color
    let languageCode: String
    var showsLeague: Bool = true
    var followStyle: FollowStyle = .plus
    var onToggle: () -> Void

    enum FollowStyle {
        case plus
        case followLabel
        case remove
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let followLabel = isSelected
            ? L10n.t("following_unfollow", languageCode: languageCode)
            : L10n.t("following_follow", languageCode: languageCode)
        let stateLabel = isSelected
            ? L10n.t("following_a11y_followed", languageCode: languageCode)
            : L10n.t("following_a11y_not_followed", languageCode: languageCode)

        Button(action: onToggle) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    SportsIdentityArtworkView(favoriteTeam: team, diameter: 52)
                    if followStyle == .remove {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                            .offset(x: 8, y: -8)
                            .accessibilityHidden(true)
                    }
                }

                Text(team.name)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)

                if showsLeague, !team.league.isEmpty {
                    Text(team.league)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                if followStyle != .remove {
                    followControl
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(width: 108, height: followStyle == .remove ? 148 : 168, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent.opacity(0.45) : FGColor.divider(colorScheme).opacity(0.40),
                        lineWidth: isSelected ? 1.35 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(team.name), \(team.league), \(stateLabel)")
        .accessibilityHint("\(followLabel) \(team.name)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var followControl: some View {
        switch followStyle {
        case .plus, .remove:
            Image(systemName: isSelected ? "checkmark" : "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : accent)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(isSelected ? accent : Color.clear)
                }
                .overlay {
                    Circle()
                        .strokeBorder(accent.opacity(isSelected ? 0 : 0.55), lineWidth: 1.5)
                }
                .accessibilityHidden(true)
        case .followLabel:
            Text(
                isSelected
                    ? L10n.t("following_a11y_followed", languageCode: languageCode)
                    : L10n.t("following_follow", languageCode: languageCode)
            )
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(isSelected ? Color.white : accent)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                Capsule().fill(isSelected ? accent : Color.clear)
            }
            .overlay {
                Capsule()
                    .strokeBorder(accent.opacity(isSelected ? 0 : 0.55), lineWidth: 1.5)
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Country card

struct FollowingCountryCard: View {
    let option: FavoriteFollowingCountryOption
    let accent: Color
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    .frame(width: 56, height: 56)
                if option.isOther {
                    Image(systemName: "globe")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accent)
                } else {
                    Text(CountryFlagHelper.flagEmoji(forRegionCode: option.id))
                        .font(.system(size: 30))
                }
            }
            Text(option.displayName)
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
            if option.itemCount > 0 {
                Text("\(option.itemCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 108, height: 136, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.40), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.displayName)
        .accessibilityHint(L10n.t("following_country_open_hint", languageCode: languageCode))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - League card

struct FollowingLeagueCard: View {
    let summary: FavoriteFollowingLeagueSummary
    let accent: Color
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            if let team = summary.artworkTeam {
                SportsIdentityArtworkView(favoriteTeam: team, diameter: 52)
            } else {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(accent.opacity(0.12)))
            }
            Text(summary.name)
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
            if summary.teamCount > 0 {
                Text(
                    String(
                        format: L10n.t("following_league_teams_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        summary.teamCount
                    )
                )
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 124, height: 148, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.40), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.name), \(summary.teamCount)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Country detail

struct FavoriteFollowingCountryDetailView: View {
    let route: FavoriteFollowingCountryRoute
    let sport: FavoriteTeamSport
    let categoryID: String?
    @Binding var selectedIDs: [String]
    let accent: Color
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var allTeamsSearch = ""
    @State private var selectedLeagueName: String?
    @State private var sortAscending = true

    private var countryTeams: [FavoriteTeam] {
        let base = FavoriteTeamCatalog.teams(sport: sport, categoryID: categoryID)
        return FavoriteFollowingCountryBrowse.teams(from: base, countryID: route.id)
    }

    private var leagues: [FavoriteFollowingLeagueSummary] {
        FavoriteFollowingCountryBrowse.leagues(from: countryTeams)
    }

    private var popular: [FavoriteTeam] {
        FavoriteFollowingCountryBrowse.popularTeams(from: countryTeams)
    }

    private var allTeams: [FavoriteTeam] {
        FavoriteFollowingCountryBrowse.filteredAllTeams(
            from: countryTeams,
            search: allTeamsSearch,
            leagueName: selectedLeagueName,
            sortAscending: sortAscending
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                topLeaguesSection
                popularSection
                allTeamsHeader
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.top, 8)

            if allTeams.isEmpty {
                Text(L10n.t("following_no_teams_in_country", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, 16)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(allTeams) { team in
                        FollowingCatalogTeamCard(
                            team: team,
                            isSelected: selectedIDs.contains(team.id),
                            accent: accent,
                            languageCode: languageCode,
                            followStyle: .plus
                        ) {
                            toggle(team)
                        }
                    }
                }
                .padding(.horizontal, FGSpacing.md)
            }
        }
        .padding(.bottom, 32)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .fanGeoScreenBackground()
        .navigationTitle(route.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FavoriteFollowingLeagueRoute.self) { route in
            AnyView(
                FollowingLeagueTeamsView(
                    leagueName: route.name,
                    teams: FavoriteFollowingCountryBrowse.teams(from: countryTeams, leagueName: route.name),
                    selectedIDs: $selectedIDs,
                    accent: accent,
                    languageCode: languageCode
                )
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if route.isUnclassified {
                    Image(systemName: "globe")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(accent)
                } else {
                    Text(CountryFlagHelper.flagEmoji(forRegionCode: route.id))
                        .font(.system(size: 44))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.displayName)
                        .font(FGTypography.screenTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(countsLine)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(route.displayName), \(countsLine)")
    }

    private var countsLine: String {
        String(
            format: L10n.t("following_country_counts_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            FavoriteFollowingCountryBrowse.teamCount(from: countryTeams),
            FavoriteFollowingCountryBrowse.leagueCount(from: countryTeams)
        )
    }

    @ViewBuilder
    private var topLeaguesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("following_top_leagues", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if leagues.count > 4 {
                    NavigationLink {
                        FollowingAllLeaguesView(
                            leagues: leagues,
                            countryTeams: countryTeams,
                            selectedIDs: $selectedIDs,
                            accent: accent,
                            languageCode: languageCode
                        )
                    } label: {
                        HStack(spacing: 2) {
                            Text(L10n.t("following_view_all", languageCode: languageCode))
                                .font(FGTypography.caption.weight(.bold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(accent)
                    }
                    .frame(minHeight: 44)
                }
            }

            if leagues.isEmpty {
                Text(L10n.t("following_no_leagues_yet", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(leagues) { league in
                            NavigationLink(value: league.route) {
                                FollowingLeagueCard(
                                    summary: league,
                                    accent: accent,
                                    languageCode: languageCode
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var popularSection: some View {
        if !popular.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("following_popular_teams", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(popular) { team in
                        FollowingCatalogTeamCard(
                            team: team,
                            isSelected: selectedIDs.contains(team.id),
                            accent: accent,
                            languageCode: languageCode,
                            followStyle: .followLabel
                        ) {
                            toggle(team)
                        }
                    }
                }
            }
        }
    }

    private var allTeamsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("following_all_teams", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text("\(countryTeams.count)")
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .accessibilityHidden(true)
                TextField(
                    String(
                        format: L10n.t("following_search_teams_in_country_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        route.displayName
                    ),
                    text: $allTeamsSearch
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(FGTypography.body)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            }

            HStack(spacing: 8) {
                Menu {
                    Button(L10n.t("following_all_leagues", languageCode: languageCode)) {
                        selectedLeagueName = nil
                    }
                    ForEach(leagues) { league in
                        Button(league.name) { selectedLeagueName = league.name }
                    }
                } label: {
                    filterChipLabel(selectedLeagueName ?? L10n.t("following_all_leagues", languageCode: languageCode))
                }
                .frame(minHeight: 44)

                Button {
                    sortAscending.toggle()
                } label: {
                    filterChipLabel(
                        sortAscending
                            ? L10n.t("following_sort_az", languageCode: languageCode)
                            : L10n.t("following_sort_za", languageCode: languageCode)
                    )
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
    }

    private func filterChipLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(FGTypography.caption.weight(.bold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(FGColor.primaryText(colorScheme))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background {
            Capsule().fill(Color(.tertiarySystemFill))
        }
    }

    private func toggle(_ team: FavoriteTeam) {
        selectedIDs = FavoriteTeamsStore.toggling(team.id, in: selectedIDs)
    }
}

// MARK: - League teams

struct FollowingLeagueTeamsView: View {
    let leagueName: String
    let teams: [FavoriteTeam]
    @Binding var selectedIDs: [String]
    let accent: Color
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    private var uniqueTeams: [FavoriteTeam] {
        FavoriteFollowingCountryBrowse.uniquedTeams(teams)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(uniqueTeams) { team in
                    FollowingCatalogTeamCard(
                        team: team,
                        isSelected: selectedIDs.contains(team.id),
                        accent: accent,
                        languageCode: languageCode
                    ) {
                        if selectedIDs.contains(team.id) {
                            selectedIDs = FavoriteTeamsStore.removing(team.id, from: selectedIDs)
                        } else {
                            selectedIDs = FavoriteTeamsStore.adding(team.id, to: selectedIDs)
                        }
                    }
                }
            }
            .padding(FGSpacing.md)
        }
        .fanGeoScreenBackground()
        .navigationTitle(leagueName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FollowingAllLeaguesView: View {
    let leagues: [FavoriteFollowingLeagueSummary]
    let countryTeams: [FavoriteTeam]
    @Binding var selectedIDs: [String]
    let accent: Color
    let languageCode: String

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(leagues) { league in
                    NavigationLink {
                        FollowingLeagueTeamsView(
                            leagueName: league.name,
                            teams: FavoriteFollowingCountryBrowse.teams(from: countryTeams, leagueName: league.name),
                            selectedIDs: $selectedIDs,
                            accent: accent,
                            languageCode: languageCode
                        )
                    } label: {
                        FollowingLeagueCard(summary: league, accent: accent, languageCode: languageCode)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(FGSpacing.md)
        }
        .fanGeoScreenBackground()
        .navigationTitle(L10n.t("following_top_leagues", languageCode: languageCode))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - All countries

struct FavoriteFollowingAllCountriesView: View {
    let countries: [FavoriteFollowingCountryOption]
    let accent: Color
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""

    private var filtered: [FavoriteFollowingCountryOption] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = FavoriteFollowingCountryBrowse.uniquedCountries(countries)
        guard !q.isEmpty else { return source }
        return source.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { option in
                if let route = FavoriteFollowingCountryBrowse.route(for: option) {
                    NavigationLink(value: route) {
                        HStack(spacing: 10) {
                            if option.isOther {
                                Image(systemName: "globe")
                                    .font(.title3)
                                    .foregroundStyle(accent)
                                    .frame(width: 34)
                            } else {
                                Text(CountryFlagHelper.flagEmoji(forRegionCode: option.id))
                                    .font(.title3)
                                    .frame(width: 34)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.displayName)
                                    .font(FGTypography.body.weight(.semibold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Text("\(option.itemCount)")
                                    .font(FGTypography.caption)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(
            text: $query,
            prompt: L10n.t("following_country_search", languageCode: languageCode)
        )
        .navigationTitle(L10n.t("following_browse_by_country", languageCode: languageCode))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Manage favorites

struct FollowingManageFavoritesView: View {
    @Binding var selectedIDs: [String]
    let languageCode: String
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var teams: [FavoriteTeam] {
        FavoriteFollowingCountryBrowse.uniquedTeams(
            FavoriteTeamsStore.resolvedTeams(fromIDs: selectedIDs)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if teams.isEmpty {
                    Text(L10n.t("following_add_favorite_teams", languageCode: languageCode))
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(teams, id: \.id) { team in
                            HStack(spacing: 12) {
                                SportsIdentityArtworkView(favoriteTeam: team, diameter: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(team.name)
                                        .font(FGTypography.body.weight(.semibold))
                                    if !team.league.isEmpty {
                                        Text(team.league)
                                            .font(FGTypography.caption)
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                }
                                Spacer(minLength: 0)
                                Button {
                                    selectedIDs = FavoriteTeamsStore.removing(team.id, from: selectedIDs)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(FGColor.mutedText(colorScheme))
                                }
                                .buttonStyle(.plain)
                                .frame(width: 44, height: 44)
                                .accessibilityLabel(L10n.t("following_unfollow", languageCode: languageCode))
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("favorite_teams", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("done", languageCode: languageCode)) { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
/// Instantiates Following picker / country-detail SwiftUI trees so duplicate IDs and
/// NavigationStack destination metadata crash at test time, not on the first user tap.
enum FavoriteFollowingCountryViewConstructionSelfTests {
    @MainActor
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FollowingCountryBrowseTest] PASS \(name)")
            } else {
                failures += 1
                print("[FollowingCountryBrowseTest] FAIL \(name)")
            }
        }

        var selected: [String] = []
        let binding = Binding(
            get: { selected },
            set: { selected = $0 }
        )

        func layout(_ view: some View, name: String) {
            let host = UIHostingController(rootView: AnyView(view))
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            expect(host.view.bounds.width == 390, "18 view construction \(name) laid out")
        }

        layout(
            FavoriteTeamsPickerSheet(selectedIDs: binding),
            name: "FavoriteTeamsPickerSheet"
        )
        layout(
            FavoriteFollowingCountryDetailView(
                route: FavoriteFollowingCountryRoute(id: "GB", displayName: "United Kingdom"),
                sport: .soccer,
                categoryID: "soccer-clubs",
                selectedIDs: binding,
                accent: .green,
                languageCode: "en"
            ),
            name: "country detail GB soccer"
        )
        layout(
            FavoriteFollowingCountryDetailView(
                route: FavoriteFollowingCountryRoute(id: "ZZ", displayName: "Nowhere"),
                sport: .soccer,
                categoryID: "soccer-clubs",
                selectedIDs: binding,
                accent: .green,
                languageCode: "en"
            ),
            name: "country detail empty/malformed ISO"
        )
        layout(
            FavoriteFollowingCountryDetailView(
                route: FavoriteFollowingCountryRoute(
                    id: FavoriteFollowingCountryOption.otherID,
                    displayName: "Other"
                ),
                sport: .soccer,
                categoryID: "soccer-clubs",
                selectedIDs: binding,
                accent: .green,
                languageCode: "en"
            ),
            name: "country detail unclassified"
        )
        layout(
            FavoriteFollowingAllCountriesView(
                countries: FavoriteFollowingCountryBrowse.countries(
                    from: FavoriteTeamCatalog.teams(sport: .soccer, categoryID: "soccer-clubs"),
                    languageCode: "en",
                    unclassifiedTitle: "Other"
                ),
                accent: .green,
                languageCode: "en"
            ),
            name: "all countries"
        )
        layout(
            FollowingLeagueTeamsView(
                leagueName: "Premier League",
                teams: [
                    FavoriteTeam(
                        id: "dup-view",
                        name: "A",
                        sport: .soccer,
                        league: "Premier League",
                        region: "Europe",
                        kind: .team,
                        shortCode: nil,
                        searchAliases: [],
                        fallbackSymbol: "sportscourt",
                        badgeRed: 0.2,
                        badgeGreen: 0.2,
                        badgeBlue: 0.2
                    ),
                    FavoriteTeam(
                        id: "dup-view",
                        name: "B",
                        sport: .soccer,
                        league: "Premier League",
                        region: "Europe",
                        kind: .team,
                        shortCode: nil,
                        searchAliases: [],
                        fallbackSymbol: "sportscourt",
                        badgeRed: 0.2,
                        badgeGreen: 0.2,
                        badgeBlue: 0.2
                    ),
                    FavoriteTeam(
                        id: "",
                        name: "Blank",
                        sport: .soccer,
                        league: "Premier League",
                        region: "Europe",
                        kind: .team,
                        shortCode: nil,
                        searchAliases: [],
                        fallbackSymbol: "sportscourt",
                        badgeRed: 0.2,
                        badgeGreen: 0.2,
                        badgeBlue: 0.2
                    )
                ],
                selectedIDs: binding,
                accent: .green,
                languageCode: "en"
            ),
            name: "league teams with duplicate and empty IDs"
        )
        if let mbappe = FavoriteTeamCatalog.team(id: "player-kylian-mbappe") {
            layout(
                SportsIdentityArtworkView(favoriteTeam: mbappe, diameter: 28),
                name: "Featured Athlete compact Person-with-Star"
            )
            layout(
                SportsIdentityArtworkView(favoriteTeam: mbappe, diameter: 118, plate: .neutralLogo),
                name: "Featured Athlete large Person-with-Star"
            )
            layout(
                FavoriteTeamRichCard(team: mbappe, isPrimary: false, style: .ownProfile, languageCode: "en") {
                    EmptyView()
                },
                name: "Featured Athlete picker card"
            )
            layout(
                FavoriteFollowingAthleteDirectoryView(
                    title: "Los Angeles Lakers",
                    athletes: [mbappe],
                    selectedIDs: binding,
                    accent: .green,
                    languageCode: "en"
                ),
                name: "Featured Athlete roster directory"
            )
        } else {
            expect(false, "18 Kylian Mbappé catalog identity exists")
        }

        if failures == 0 {
            print("[FollowingCountryBrowseTest] construction ALL PASSED")
        } else {
            print("[FollowingCountryBrowseTest] construction failures=\(failures)")
        }
    }
}
#endif

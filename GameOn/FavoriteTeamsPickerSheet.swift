import SwiftUI

/// Sheet to pick favorite teams from the canonical ``FavoriteTeamCatalog/allEntities`` catalog
/// (Sport → Category → Country detail + search). Shared by fan signup, profile, Following, and business hosts.
/// Root browse is favorites + countries — not a league-by-league catalog dump.
struct FavoriteTeamsPickerSheet: View {
    @Binding var selectedIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var sportFilter: FavoriteTeamSport = FavoriteTeamCatalog.defaultSport
    @State private var categoryFilter: String? = FavoriteTeamCatalog.defaultCategoryID(for: FavoriteTeamCatalog.defaultSport)
    @State private var searchText = ""
    @State private var isDismissingPicker = false
    @State private var showManageFavorites = false
    @State private var athleteCatalogRevision = 0
    @FocusState private var isSearchFocused: Bool

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var browseCountries: [FavoriteFollowingCountryOption] {
        FavoriteFollowingCountryBrowse.countries(
            from: baseCategoryTeams,
            languageCode: languageCode,
            unclassifiedTitle: L10n.t("following_country_unclassified", languageCode: languageCode)
        )
    }

    private var featuredCountries: [FavoriteFollowingCountryOption] {
        FavoriteFollowingCountryBrowse.featuredCountries(from: browseCountries)
    }

    private var followedTeamsForSport: [FavoriteTeam] {
        FavoriteFollowingCountryBrowse.uniquedTeams(
            FavoriteTeamsStore.resolvedTeams(fromIDs: selectedIDs).filter { team in
                if sportFilter == .basketball {
                    return team.sport == .basketball || team.sport == .ncaa
                }
                return team.sport == sportFilter
            }
        )
    }

    private var recommendedTeams: [FavoriteTeam] {
        if isAthleteCategory {
            return FavoriteFollowingCountryBrowse.recommendedAthletes(
                from: baseCategoryTeams,
                followedIdentities: FavoriteTeamsStore.resolvedTeams(fromIDs: selectedIDs),
                excludingIDs: Set(selectedIDs),
                curatedIDs: Set(FavoriteTeamCatalog.curatedCatalog.map(\.id))
            )
        }
        return FavoriteFollowingCountryBrowse.recommendedTeams(
            from: baseCategoryTeams,
            excludingIDs: Set(selectedIDs)
        )
    }

    private var isAthleteCategory: Bool {
        FavoriteFollowingCountryBrowse.isAthleteCategory(id: categoryFilter)
    }

    private var athleteLeagues: [FavoriteFollowingLeagueSummary] {
        FavoriteFollowingCountryBrowse.athleteLeagues(from: baseCategoryTeams)
    }

    private var athleteTeams: [FavoriteFollowingLeagueSummary] {
        FavoriteFollowingCountryBrowse.athleteTeams(from: baseCategoryTeams)
    }

    private var availableCategories: [FavoriteTeamCategory] {
        FavoriteTeamCatalog.categories(for: sportFilter)
    }

    private var sportAccent: Color {
        sportFilter.accentColor
    }

    /// Sport + category only. Country drill-down is a pushed screen, not an in-place filter.
    private var baseCategoryTeams: [FavoriteTeam] {
        FavoriteTeamCatalog.teams(sport: sportFilter, categoryID: categoryFilter)
    }

    private var filteredTeams: [FavoriteTeam] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return FavoriteFollowingCountryBrowse.uniquedTeams(baseCategoryTeams) }
        let allowed = Set(baseCategoryTeams.map(\.id))
        return FavoriteFollowingCountryBrowse.uniquedTeams(
            FavoriteFollowingSearch.rankedResults(
                query: query,
                prioritizingSelectedIDs: Set(selectedIDs)
            ).filter { allowed.contains($0.id) }
        )
    }

    private var searchPlaceholder: String {
        let title = availableCategories.first(where: { $0.id == categoryFilter })?.title ?? "Teams"
        return FollowingPresentationCopy.searchPlaceholder(categoryTitle: title, languageCode: languageCode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterHeader
                pickerResultsContent
            }
            .fanGeoScreenBackground()
            .onAppear {
                isDismissingPicker = false
                sanitizeFilters()
#if DEBUG
                print("[FavoriteTeamsDebug] unlimitedFavoritesEnabled=true")
                print("[FavoriteTeamsDebug] selectedFavoriteTeamsCount=\(selectedIDs.count)")
                print("[FavoriteTeamsLogoAudit] source=SportsIdentityArtworkView authorization=providerAPIAsIs|fanGeoOwned|systemProvided")
                let categoryTitle = availableCategories.first(where: { $0.id == categoryFilter })?.title ?? "Teams"
                FollowingPresentationCopy.logResolvedKeys(languageCode: languageCode, categoryTitle: categoryTitle)
#endif
                Task { await enrichVisibleLeagueArtwork() }
            }
            .onChange(of: sportFilter) { _, _ in
                sanitizeFilters()
                Task { await enrichVisibleLeagueArtwork() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sportsProviderAthleteCatalogDidChange)) { _ in
                athleteCatalogRevision += 1
            }
            .navigationTitle(L10n.t("following_picker_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: FavoriteFollowingCountryRoute.self) { route in
                AnyView(
                    FavoriteFollowingCountryDetailView(
                        route: route,
                        sport: sportFilter,
                        categoryID: categoryFilter,
                        selectedIDs: $selectedIDs,
                        accent: sportAccent,
                        languageCode: languageCode
                    )
                )
            }
            .navigationDestination(for: FavoriteFollowingAllCountriesRoute.self) { _ in
                AnyView(
                    FavoriteFollowingAllCountriesView(
                        countries: browseCountries,
                        accent: sportAccent,
                        languageCode: languageCode
                    )
                )
            }
            .navigationDestination(for: FavoriteFollowingAthleteLeagueRoute.self) { route in
                FavoriteFollowingAthleteLeagueView(
                    leagueName: route.name,
                    athletes: FavoriteFollowingCountryBrowse.athletes(from: baseCategoryTeams, leagueName: route.name),
                    selectedIDs: $selectedIDs,
                    accent: sportAccent,
                    languageCode: languageCode
                )
            }
            .navigationDestination(for: FavoriteFollowingAthleteTeamRoute.self) { route in
                FavoriteFollowingAthleteDirectoryView(
                    title: route.name,
                    athletes: FavoriteFollowingCountryBrowse.athletes(from: baseCategoryTeams, teamName: route.name),
                    selectedIDs: $selectedIDs,
                    accent: sportAccent,
                    languageCode: languageCode
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    doneButton
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.t("done", languageCode: languageCode)) {
                        isSearchFocused = false
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showManageFavorites) {
                AnyView(
                    FollowingManageFavoritesView(
                        selectedIDs: $selectedIDs,
                        languageCode: languageCode,
                        accent: sportAccent
                    )
                )
            }
        }
    }

    private var doneButton: some View {
        Button(L10n.t("done", languageCode: languageCode)) {
            dismissPicker()
        }
        .fontWeight(.semibold)
        .disabled(isDismissingPicker)
        .accessibilityLabel(L10n.t("done", languageCode: languageCode))
        .accessibilityHint(L10n.t("onboarding_favorite_teams_done_hint", languageCode: languageCode))
    }

    private func localizedCategoryTitle(_ title: String) -> String {
        switch title {
        case "Teams":
            return L10n.t("following_category_teams", languageCode: languageCode)
        case "National Teams":
            return L10n.t("following_category_national_teams", languageCode: languageCode)
        case "Featured Athletes":
            return L10n.t("following_category_featured_athletes", languageCode: languageCode)
        case "Competitions & Tournaments":
            return L10n.t("following_category_competitions", languageCode: languageCode)
        case "Fighters":
            return L10n.t("following_category_fighters", languageCode: languageCode)
        case "Drivers":
            return L10n.t("following_category_drivers", languageCode: languageCode)
        default:
            return title
        }
    }

    private func categoryChipSymbol(_ title: String) -> String {
        switch title {
        case "National Teams": return "shield.fill"
        case "Featured Athletes", "Fighters", "Drivers": return "person.fill"
        case "Competitions & Tournaments": return "trophy.fill"
        default: return "person.3.fill"
        }
    }

    private func enrichVisibleLeagueArtwork() async {
        let leagues = Array(
            Set(
                baseCategoryTeams
                    .prefix(60)
                    .map(\.league)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).prefix(2)
        for league in leagues {
            await SportsArtworkEnrichmentService.shared.enrichLeague(league)
        }
        let selected = FavoriteTeamsStore.resolvedTeams(fromIDs: selectedIDs)
        if !selected.isEmpty {
            await SportsArtworkEnrichmentService.shared.enrich(favorites: selected)
        }
        let missing = baseCategoryTeams.prefix(60).filter { team in
            switch team.kind {
            case .team, .nationalTeam:
                return SportsArtworkURLStore.shared.badgeURL(league: team.league, teamName: team.name) == nil
            default:
                return false
            }
        }.prefix(8)
        for team in missing {
            await SportsArtworkEnrichmentService.shared.enrichNamedTeam(
                name: team.name,
                sport: team.sport,
                league: team.league
            )
        }
    }

    private func dismissPicker() {
        guard !isDismissingPicker else { return }
        isDismissingPicker = true
        isSearchFocused = false
        dismiss()
    }

    @ViewBuilder
    private var pickerResultsContent: some View {
        ScrollView {
            let _ = athleteCatalogRevision
            VStack(alignment: .leading, spacing: 22) {
                if isSearching {
                    searchResultsSection
                } else if isAthleteCategory {
                    favoriteTeamsSection
                    browseByLeagueSection
                    browseByTeamSection
                    recommendedSection
                    if athleteLeagues.isEmpty && athleteTeams.isEmpty && recommendedTeams.isEmpty && followedTeamsForSport.isEmpty {
                        athleteComingSoonSection
                    }
                } else {
                    favoriteTeamsSection
                    browseByCountrySection
                    recommendedSection
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchResultsSection: some View {
        Group {
            if filteredTeams.isEmpty {
                emptyStateRow
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(filteredTeams, id: \.id) { team in
                        FollowingCatalogTeamCard(
                            team: team,
                            isSelected: selectedIDs.contains(team.id),
                            accent: sportAccent,
                            languageCode: languageCode
                        ) {
                            toggleTeam(team)
                        }
                    }
                }
            }
        }
    }

    private var favoriteTeamsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("favorite_teams", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button {
                    showManageFavorites = true
                } label: {
                    Text(verbatim: FollowingPresentationCopy.manage(languageCode: languageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(sportAccent)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel(FollowingPresentationCopy.manage(languageCode: languageCode))
            }

            if followedTeamsForSport.isEmpty {
                Text(L10n.t("following_add_favorite_teams", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(followedTeamsForSport, id: \.id) { team in
                            FollowingCatalogTeamCard(
                                team: team,
                                isSelected: true,
                                accent: sportAccent,
                                languageCode: languageCode,
                                showsLeague: true,
                                followStyle: .remove
                            ) {
                                toggleTeam(team)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var browseByCountrySection: some View {
        if !featuredCountries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.t("following_browse_by_country", languageCode: languageCode))
                        .font(FGTypography.cardTitle.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    NavigationLink(value: FavoriteFollowingAllCountriesRoute()) {
                        HStack(spacing: 2) {
                            Text(L10n.t("following_view_all", languageCode: languageCode))
                                .font(FGTypography.caption.weight(.bold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(sportAccent)
                    }
                    .frame(minHeight: 44)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(featuredCountries) { option in
                            if let route = FavoriteFollowingCountryBrowse.route(for: option) {
                                NavigationLink(value: route) {
                                    FollowingCountryCard(
                                        option: option,
                                        accent: sportAccent,
                                        languageCode: languageCode
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var browseByLeagueSection: some View {
        if !athleteLeagues.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("following_browse_by_league", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(athleteLeagues) { summary in
                            NavigationLink(value: FavoriteFollowingAthleteLeagueRoute(id: summary.id, name: summary.name)) {
                                FollowingLeagueCard(summary: summary, accent: sportAccent, languageCode: languageCode)
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
    private var browseByTeamSection: some View {
        if !athleteTeams.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("following_browse_by_team", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(athleteTeams.prefix(16)) { summary in
                            NavigationLink(value: FavoriteFollowingAthleteTeamRoute(id: summary.id, name: summary.name)) {
                                FollowingLeagueCard(summary: summary, accent: sportAccent, languageCode: languageCode)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var athleteComingSoonSection: some View {
        Text(L10n.t("following_athletes_coming_soon", languageCode: languageCode))
            .font(FGTypography.body)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recommendedSection: some View {
        if !recommendedTeams.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: FollowingPresentationCopy.recommendedForYou(languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(recommendedTeams, id: \.id) { team in
                            FollowingCatalogTeamCard(
                                team: team,
                                isSelected: selectedIDs.contains(team.id),
                                accent: sportAccent,
                                languageCode: languageCode,
                                followStyle: .plus
                            ) {
                                toggleTeam(team)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            filterStep(title: L10n.t("following_filter_sport", languageCode: languageCode)) {
                sportSelector
            }

            if !availableCategories.isEmpty {
                filterStep(title: L10n.t("following_filter_category", languageCode: languageCode)) {
                    categorySelector
                }
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.top, FGSpacing.sm)
        .padding(.bottom, FGSpacing.sm)
        .background {
            Rectangle()
                .fill(FGColor.background(colorScheme).opacity(0.96))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityHidden(true)
            TextField(
                "",
                text: $searchText,
                prompt: Text(verbatim: searchPlaceholder)
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .font(FGTypography.body)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("following_search_clear", languageCode: languageCode))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(searchPlaceholder)
    }

    private func filterStep<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(FGTypography.metadata.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var sportSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FavoriteTeamCatalog.selectorSports) { sport in
                    SportFilterChip(
                        sport: sport.discoverSportToken,
                        displayTitle: sport.chipTitle,
                        isSelected: sportFilter == sport,
                        isCompact: true
                    ) {
                        selectSport(sport)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableCategories) { category in
                    labeledFilterChip(
                        title: localizedCategoryTitle(category.title),
                        systemImage: categoryChipSymbol(category.title),
                        isSelected: categoryFilter == category.id,
                        filledWhenSelected: true
                    ) {
                        selectCategory(category)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func labeledFilterChip(
        title: String,
        systemImage: String,
        isSelected: Bool,
        filledWhenSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isSelected
                    ? (filledWhenSelected ? Color.white : sportAccent)
                    : FGColor.primaryText(colorScheme)
            )
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isSelected && filledWhenSelected
                            ? AnyShapeStyle(sportAccent)
                            : AnyShapeStyle(Color(.tertiarySystemFill))
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected && !filledWhenSelected ? sportAccent : Color.clear,
                        lineWidth: 1.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var emptyStateRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text(L10n.t("following_picker_no_results", languageCode: languageCode))
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(L10n.t("following_empty_try_filters", languageCode: languageCode))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func selectSport(_ sport: FavoriteTeamSport) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            sportFilter = sport
            categoryFilter = FavoriteTeamCatalog.defaultCategoryID(for: sport)
        }
    }

    private func selectCategory(_ category: FavoriteTeamCategory) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            categoryFilter = category.id
        }
    }

    private func sanitizeFilters() {
        if let categoryFilter,
           !availableCategories.contains(where: { $0.id == categoryFilter }) {
            self.categoryFilter = FavoriteTeamCatalog.defaultCategoryID(for: sportFilter)
        }
    }

    private func toggleTeam(_ team: FavoriteTeam) {
        selectedIDs = FavoriteTeamsStore.toggling(team.id, in: selectedIDs)
    }
}

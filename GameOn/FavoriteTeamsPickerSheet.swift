import SwiftUI

/// Sheet to pick favorite teams from the canonical ``FavoriteTeamCatalog/allEntities`` catalog
/// (Sport → Category → Region → Country + search). Shared by fan signup, profile, Following, and business hosts.
struct FavoriteTeamsPickerSheet: View {
    @Binding var selectedIDs: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var sportFilter: FavoriteTeamSport = FavoriteTeamCatalog.defaultSport
    @State private var categoryFilter: String? = FavoriteTeamCatalog.defaultCategoryID(for: FavoriteTeamCatalog.defaultSport)
    @State private var regionFilter: FavoriteFollowingContinent = .all
    @State private var countryFilterID: String = FavoriteFollowingCountryOption.allID
    @State private var searchText = ""
    @State private var isDismissingPicker = false
    @State private var showCountryPicker = false
    @State private var expandedShelfIDs: Set<String> = []
    @FocusState private var isSearchFocused: Bool

    private static let shelfPreviewLimit = 8

    struct FavoritePickerTeamShelf: Identifiable {
        let id: String
        let title: String
        let accent: Color
        let teams: [FavoriteTeam]
    }

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var availableCategories: [FavoriteTeamCategory] {
        FavoriteTeamCatalog.categories(for: sportFilter)
    }

    private var sportAccent: Color {
        sportFilter.accentColor
    }

    /// Sport + category only (before region/country/search).
    private var baseCategoryTeams: [FavoriteTeam] {
        FavoriteTeamCatalog.teams(sport: sportFilter, categoryID: categoryFilter)
    }

    private var filteredTeams: [FavoriteTeam] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var teams = baseCategoryTeams.filter {
            FavoriteFollowingGeo.matchesContinent($0, regionFilter)
                && FavoriteFollowingGeo.matchesCountry($0, countryID: countryFilterID)
        }
        if !query.isEmpty {
            let ranked = FavoriteFollowingSearch.rankedResults(
                query: query,
                prioritizingSelectedIDs: selectedIDs
            )
            let allowed = Set(teams.map(\.id))
            teams = ranked.filter { allowed.contains($0.id) }
        }
        return teams
    }

    private var availableContinents: [FavoriteFollowingContinent] {
        let present = FavoriteFollowingGeo.continentsWithResults(in: baseCategoryTeams)
        var chips = FavoriteFollowingContinent.primaryCases.filter { continent in
            continent == .all || present.contains(continent)
        }
        if present.contains(.other) {
            chips.append(.other)
        }
        return chips
    }

    private var countryOptions: [FavoriteFollowingCountryOption] {
        FavoriteFollowingGeo.countryOptions(
            from: baseCategoryTeams,
            continent: regionFilter,
            languageCode: languageCode,
            allCountriesTitle: L10n.t("following_country_all", languageCode: languageCode),
            unclassifiedTitle: L10n.t("following_country_unclassified", languageCode: languageCode)
        )
    }

    private var selectedCountryOption: FavoriteFollowingCountryOption? {
        countryOptions.first(where: { $0.id == countryFilterID })
            ?? countryOptions.first(where: { $0.isAll })
    }

    private var teamShelves: [FavoritePickerTeamShelf] {
        FavoriteTeamsPickerShelves.sections(
            from: filteredTeams,
            sport: sportFilter,
            categoryID: categoryFilter,
            accent: sportAccent
        )
    }

    private var selectedCategoryTitle: String {
        guard let id = categoryFilter,
              let category = availableCategories.first(where: { $0.id == id }) else {
            return L10n.t("following_category_teams", languageCode: languageCode)
        }
        return localizedCategoryTitle(category.title)
    }

    private var searchPlaceholder: String {
        let title = availableCategories.first(where: { $0.id == categoryFilter })?.title ?? "Teams"
        switch title {
        case "National Teams":
            return L10n.t("following_search_national_teams", languageCode: languageCode)
        case "Featured Athletes", "Fighters", "Drivers":
            return L10n.t("following_search_athletes", languageCode: languageCode)
        case "Competitions & Tournaments":
            return L10n.t("following_search_competitions", languageCode: languageCode)
        default:
            return L10n.t("following_search_teams_or_competitions", languageCode: languageCode)
        }
    }

    private var browsingSummaryText: String {
        let regionLabel: String = {
            if !countryFilterID.isEmpty,
               countryFilterID != FavoriteFollowingCountryOption.allID,
               let country = selectedCountryOption, !country.isAll {
                return country.displayName
            }
            return L10n.t(regionFilter.localizationKey, languageCode: languageCode)
        }()
        return String(
            format: L10n.t("following_browsing_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            regionLabel,
            selectedCategoryTitle,
            sportFilter.chipTitle
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterHeader
                browsingSummaryStrip
                pickerResultsContent
            }
            .fanGeoScreenBackground()
            .onAppear {
                isDismissingPicker = false
                sanitizeFilters()
#if DEBUG
                print("[FavoriteTeamsDebug] unlimitedFavoritesEnabled=true")
                print("[FavoriteTeamsDebug] selectedFavoriteTeamsCount=\(selectedIDs.count)")
                print("[FavoriteTeamsLogoAudit] source=SportsIdentityArtworkView authorization=fanGeoOwned|systemProvided remoteMarks=false verifiedLicensedCount=0")
#endif
            }
            .onChange(of: sportFilter) { _, _ in
                sanitizeFilters()
            }
            .onChange(of: categoryFilter) { _, _ in
                sanitizeFilters()
            }
            .onChange(of: regionFilter) { _, _ in
                sanitizeCountryForRegion()
            }
            .navigationTitle(L10n.t("following_picker_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
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
            .sheet(isPresented: $showCountryPicker) {
                FollowingCountryPickerSheet(
                    options: countryOptions,
                    selectedID: $countryFilterID,
                    accent: sportAccent
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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

    private func dismissPicker() {
        guard !isDismissingPicker else { return }
        isDismissingPicker = true
        isSearchFocused = false
        dismiss()
    }

    @ViewBuilder
    private var pickerResultsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if filteredTeams.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(teamShelves) { shelf in
                        teamShelfSection(shelf)
                    }
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 88)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottomTrailing) {
            countryFAB
                .padding(.trailing, FGSpacing.md)
                .padding(.bottom, FGSpacing.md)
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

            if !availableContinents.isEmpty {
                filterStep(title: L10n.t("following_filter_region", languageCode: languageCode)) {
                    regionSelector
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
            TextField(searchPlaceholder, text: $searchText)
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
    }

    private var browsingSummaryStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: sportFilter.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sportAccent)
                .accessibilityHidden(true)
            Text(browsingSummaryText)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(sportAccent.opacity(colorScheme == .dark ? 0.16 : 0.10))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(browsingSummaryText)
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

    private var regionSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableContinents) { continent in
                    labeledFilterChip(
                        title: L10n.t(continent.localizationKey, languageCode: languageCode),
                        systemImage: continent.symbolName,
                        isSelected: regionFilter == continent,
                        filledWhenSelected: false
                    ) {
                        selectRegion(continent)
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

    private var countryFAB: some View {
        Button {
            showCountryPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .bold))
                Text(L10n.t("following_country", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(sportAccent)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background {
                Capsule(style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 10, y: 4)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(sportAccent.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.t("following_country_selected_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                selectedCountryOption?.displayName
                    ?? L10n.t("following_country_all", languageCode: languageCode)
            )
        )
        .accessibilityHint(L10n.t("following_country_picker_hint", languageCode: languageCode))
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

    private func teamShelfSection(_ shelf: FavoritePickerTeamShelf) -> some View {
        let isExpanded = expandedShelfIDs.contains(shelf.id)
        let visibleTeams = isExpanded ? shelf.teams : Array(shelf.teams.prefix(Self.shelfPreviewLimit))
        let canExpand = shelf.teams.count > Self.shelfPreviewLimit

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shelf.title)
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if canExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded {
                                expandedShelfIDs.remove(shelf.id)
                            } else {
                                expandedShelfIDs.insert(shelf.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(
                                isExpanded
                                    ? L10n.t("following_show_less", languageCode: languageCode)
                                    : L10n.t("following_view_all", languageCode: languageCode)
                            )
                            .font(FGTypography.caption.weight(.bold))
                            if !isExpanded {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .foregroundStyle(sportAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(visibleTeams) { team in
                        teamShelfCard(team)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
        }
    }

    private func teamShelfCard(_ team: FavoriteTeam) -> some View {
        let isSelected = selectedIDs.contains(team.id)
        let followLabel = isSelected
            ? L10n.t("following_unfollow", languageCode: languageCode)
            : L10n.t("following_follow", languageCode: languageCode)
        let stateLabel = isSelected
            ? L10n.t("following_a11y_followed", languageCode: languageCode)
            : L10n.t("following_a11y_not_followed", languageCode: languageCode)

        return Button {
            toggleTeam(team)
        } label: {
            VStack(spacing: 8) {
                SportsIdentityArtworkView(favoriteTeam: team, diameter: 52)

                Text(team.name)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)

                Image(systemName: isSelected ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white : sportAccent)
                    .frame(width: 28, height: 28)
                    .background {
                        Circle()
                            .fill(isSelected ? sportAccent : Color.clear)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(sportAccent.opacity(isSelected ? 0 : 0.55), lineWidth: 1.5)
                    }
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(width: 108, height: 148, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? sportAccent.opacity(0.45) : FGColor.divider(colorScheme).opacity(0.40),
                        lineWidth: isSelected ? 1.35 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(team.name), \(team.league), \(stateLabel)")
        .accessibilityHint("\(followLabel) \(team.name)")
        .accessibilityAddTraits(.isButton)
    }

    private func selectSport(_ sport: FavoriteTeamSport) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            sportFilter = sport
            categoryFilter = FavoriteTeamCatalog.defaultCategoryID(for: sport)
            regionFilter = .all
            countryFilterID = FavoriteFollowingCountryOption.allID
            expandedShelfIDs.removeAll()
        }
    }

    private func selectCategory(_ category: FavoriteTeamCategory) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            categoryFilter = category.id
            regionFilter = .all
            countryFilterID = FavoriteFollowingCountryOption.allID
            expandedShelfIDs.removeAll()
        }
    }

    private func selectRegion(_ continent: FavoriteFollowingContinent) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            regionFilter = continent
            sanitizeCountryForRegion()
            expandedShelfIDs.removeAll()
        }
    }

    private func sanitizeFilters() {
        if let categoryFilter,
           !availableCategories.contains(where: { $0.id == categoryFilter }) {
            self.categoryFilter = FavoriteTeamCatalog.defaultCategoryID(for: sportFilter)
        }
        if !availableContinents.contains(regionFilter) {
            regionFilter = .all
        }
        sanitizeCountryForRegion()
    }

    private func sanitizeCountryForRegion() {
        let valid = Set(countryOptions.map(\.id))
        if !valid.contains(countryFilterID) {
            countryFilterID = FavoriteFollowingCountryOption.allID
        }
    }

    private func toggleTeam(_ team: FavoriteTeam) {
        if selectedIDs.contains(team.id) {
            selectedIDs.remove(team.id)
        } else {
            selectedIDs.insert(team.id)
        }
    }
}

// MARK: - Country picker

private struct FollowingCountryPickerSheet: View {
    let options: [FavoriteFollowingCountryOption]
    @Binding var selectedID: String
    let accent: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var query = ""

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var filtered: [FavoriteFollowingCountryOption] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return options }
        return options.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { option in
                    Button {
                        selectedID = option.id
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            if !option.isAll, !option.isOther {
                                Text(CountryFlagHelper.flagEmoji(forRegionCode: option.id))
                                    .font(.title3)
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.displayName)
                                    .font(FGTypography.body.weight(.semibold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                if option.itemCount > 0, !option.isAll {
                                    Text("\(option.itemCount)")
                                        .font(FGTypography.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                            }
                            Spacer(minLength: 0)
                            if selectedID == option.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.bold))
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    .accessibilityAddTraits(selectedID == option.id ? [.isSelected, .isButton] : .isButton)
                }
            }
            .listStyle(.plain)
            .searchable(
                text: $query,
                prompt: L10n.t("following_country_search", languageCode: languageCode)
            )
            .navigationTitle(L10n.t("following_choose_country", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("done", languageCode: languageCode)) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Shelves

private enum FavoriteTeamsPickerShelves {
    static func sections(
        from teams: [FavoriteTeam],
        sport: FavoriteTeamSport,
        categoryID: String?,
        accent: Color
    ) -> [FavoriteTeamsPickerSheet.FavoritePickerTeamShelf] {
        // Prefer league/competition grouping when metadata is reliable.
        let groups = FavoriteTeamCatalog.sectionGroups(for: teams)
        if !groups.isEmpty {
            return groups.map { title, shelfTeams in
                FavoriteTeamsPickerSheet.FavoritePickerTeamShelf(
                    id: title.favoritePickerID,
                    title: title,
                    accent: accent,
                    teams: shelfTeams
                )
            }
        }

        let groupedByShelf = Dictionary(grouping: teams, by: { shelfTitle(for: $0, categoryID: categoryID) })
        return groupedByShelf.map { title, shelfTeams in
            FavoriteTeamsPickerSheet.FavoritePickerTeamShelf(
                id: title.favoritePickerID,
                title: title,
                accent: accent,
                teams: shelfTeams.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
        .sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func shelfTitle(for team: FavoriteTeam, categoryID: String?) -> String {
        if team.kind == .nationalTeam { return "National Teams" }
        if team.kind == .player || team.kind == .driver || team.kind == .fighter {
            return "Featured Athletes"
        }
        if team.kind == .interest { return team.region }
        if team.kind.isCompetitionLike { return "Competitions & Tournaments" }
        if categoryID?.contains("national") == true { return "National Teams" }
        return team.league.isEmpty ? team.region : team.league
    }
}

private extension String {
    var favoritePickerID: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
    }
}

private extension FavoriteTeamSport {
    var systemImageName: String {
        SportFilterCatalog.resolve(chipTitle).systemImage
    }
}

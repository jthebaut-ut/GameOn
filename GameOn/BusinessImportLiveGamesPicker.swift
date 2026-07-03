import SwiftUI

// MARK: - Pro calendar filter helpers (shared with Schedule > Pro semantics)

enum CalendarProGamesFilterSupport {
    static let visibleSportFilters: [(selection: String, display: String?)] = [
        ("All", nil),
        ("Soccer", nil),
        ("Basketball", nil),
        ("Football", nil),
        ("Baseball", nil),
        ("Hockey", nil),
        ("MMA", "Combat"),
        ("Racing", nil),
        ("Golf", nil),
        ("Tennis", nil),
        ("badminton", "Badminton")
    ]

    static func filtered(
        matches: [LiveMatch],
        selectedDate: Date,
        sportFilter: String,
        featuredEvent: FeaturedEvent?,
        worldCupOnly: Bool = false,
        selectedLeagueCountries: Set<String> = []
    ) -> [LiveMatch] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDate)
        let sport = sportFilter.trimmingCharacters(in: .whitespacesAndNewlines)

        return matches
            .filter { cal.isDate($0.startTime, inSameDayAs: day) }
            .filter { match in
                guard featuredEvent == nil else { return true }
                return sport.isEmpty
                    || sport.localizedCaseInsensitiveCompare("All") == .orderedSame
                    || match.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
                    || SportFilterCatalog.storedSport(match.sport, matchesSearchQuery: sport)
            }
            .filter { match in
                if let featuredEvent {
                    return LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: featuredEvent)
                }
                return !worldCupOnly || LiveMatchFilters.isFifaWorldCupMatch(match)
            }
            .filter { match in
                guard featuredEvent == nil else { return true }
                return LiveMatchFilters.matchesLeagueCountry(match, selectedCountries: selectedLeagueCountries)
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                if lhs.league != rhs.league {
                    return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
                }
                return "\(lhs.awayTeam) \(lhs.homeTeam)".localizedCaseInsensitiveCompare("\(rhs.awayTeam) \(rhs.homeTeam)") == .orderedAscending
            }
    }

    static func featuredEvent(
        for match: LiveMatch,
        activeFeaturedEvents: [FeaturedEvent]
    ) -> FeaturedEvent? {
        if let featuredEventSlug = match.featuredEventSlug {
            let normalizedSlug = LiveMatchFilters.normalizedSearchText(featuredEventSlug)
            if let direct = activeFeaturedEvents.first(where: {
                LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug
            }) {
                return direct
            }
        }
        return activeFeaturedEvents.first {
            LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: $0)
        }
    }

    static func teamDisplayName(_ teamName: String) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              CountryFlagHelper.isCountry(trimmed),
              let flag = CountryFlagHelper.flag(for: trimmed),
              !flag.isEmpty else {
            return trimmed
        }
        return "\(flag) \(trimmed)"
    }

    static func proGameStartTimeText(_ match: LiveMatch, timeZoneOption: TimeZoneOption) -> String {
        CompactGameTimeFormatter.timeWithZone(
            for: match.startTime,
            timeZoneOption: timeZoneOption
        )
    }

    static func proGameStatusText(_ match: LiveMatch) -> String {
        switch match.matchStatus {
        case .live:
            if let minute = match.minute {
                return "LIVE \(minute)'"
            }
            return "LIVE"
        case .halfTime:
            return "HT"
        case .fullTime:
            return "Final"
        case .scheduled:
            return "Scheduled"
        }
    }

    static func shouldShowScore(_ match: LiveMatch) -> Bool {
        if match.matchStatus.isHappeningNow || match.matchStatus == .fullTime { return true }
        return match.matchStatus == .scheduled && match.scoresAreAvailable
    }
}

// MARK: - Horizontal date strip (Schedule > Pro style)

struct CalendarProHorizontalDateStrip: View {
    @Binding var selectedDate: Date
    var showsCalendarPicker: Bool = true
    var onCalendarPickerTap: (() -> Void)? = nil
    var onDateSelected: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if showsCalendarPicker, let onCalendarPickerTap {
                    Button(action: onCalendarPickerTap) {
                        Image(systemName: "calendar")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                            .frame(width: 44, height: 52)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open calendar picker")
                }

                ForEach(stripDates, id: \.timeIntervalSince1970) { date in
                    dateButton(date)
                }
            }
        }
    }

    private var stripDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: selectedDate)
        let sixDaysFromToday = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        let startDay = (today...sixDaysFromToday).contains(selectedDay) ? today : selectedDay

        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDay)
        }
    }

    private func dateButton(_ date: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                selectedDate = date
            }
            onDateSelected()
        } label: {
            VStack(spacing: 4) {
                Text(isToday ? "Today" : Self.weekdayFormatter.string(from: date))
                    .font(.caption.weight(.heavy))
                    .lineLimit(1)
                Text(Self.dayFormatter.string(from: date))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
            .frame(width: 68, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.48 : 0.34)
                            : FGColor.divider(colorScheme).opacity(0.55),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityFormatter.string(from: date))
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let accessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Sport / featured-event filter strip (Schedule > Pro style)

struct CalendarProSportFilterStrip: View {
    @Binding var sportFilter: String
    @Binding var featuredEventFilterSlug: String?
    let featuredEvents: [FeaturedEvent]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CalendarProGamesFilterSupport.visibleSportFilters, id: \.selection) { item in
                    sportChip(selection: item.selection, displayTitle: item.display)
                    if item.selection == "All" {
                        ForEach(featuredEvents) { featuredEvent in
                            featuredEventChip(featuredEvent)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var selectedFeaturedEvent: FeaturedEvent? {
        guard let featuredEventFilterSlug else { return nil }
        return featuredEvents.first { $0.slug == featuredEventFilterSlug }
    }

    private func sportChip(selection: String, displayTitle: String?) -> some View {
        SportFilterChip(
            sport: selection,
            displayTitle: displayTitle,
            isSelected: selectedFeaturedEvent == nil
                && DiscoverSportFilterRowLayout.selectionTokensMatch(sportFilter, selection),
            isCompact: true
        ) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                featuredEventFilterSlug = nil
                sportFilter = selection
            }
        }
    }

    private func featuredEventChip(_ featuredEvent: FeaturedEvent) -> some View {
        SportFilterChip(
            sport: featuredEvent.sport ?? "Soccer",
            displayTitle: featuredEvent.leagueChipLabel,
            isSelected: selectedFeaturedEvent?.slug == featuredEvent.slug,
            isCompact: true,
            preferSystemSymbol: false
        ) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                sportFilter = "All"
                featuredEventFilterSlug = selectedFeaturedEvent?.slug == featuredEvent.slug
                    ? nil
                    : featuredEvent.slug
            }
        }
    }
}

// MARK: - Importable live game card (Schedule > Pro card + import CTA)

struct BusinessImportLiveGameCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme

    let match: LiveMatch
    let featuredEvents: [FeaturedEvent]
    let onImport: () -> Void

    private var featuredEvent: FeaturedEvent? {
        CalendarProGamesFilterSupport.featuredEvent(for: match, activeFeaturedEvents: featuredEvents)
    }

    private var accent: Color {
        match.matchStatus.isHappeningNow ? FGColor.dangerRed : viewModel.colorForSport(match.liveSportVisualType.sportFilterCatalogKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(CalendarProGamesFilterSupport.proGameStartTimeText(match, timeZoneOption: viewModel.selectedTimeZone))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accent)

                        if match.matchStatus.isHappeningNow || match.matchStatus == .fullTime {
                            Text(CalendarProGamesFilterSupport.proGameStatusText(match))
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(match.matchStatus.isHappeningNow ? FGColor.dangerRed : FGColor.secondaryText(colorScheme))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    (match.matchStatus.isHappeningNow ? FGColor.dangerRed : FGColor.secondaryText(colorScheme))
                                        .opacity(colorScheme == .dark ? 0.18 : 0.10),
                                    in: Capsule(style: .continuous)
                                )
                        }
                    }

                    if match.matchStatus.isHappeningNow || match.matchStatus == .fullTime {
                        ProGameLeagueChip(
                            sportType: match.liveSportVisualType,
                            featuredEvent: featuredEvent,
                            league: match.league
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            teamLine(match.awayTeam, badgeURL: match.awayTeamBadgeURL)
                            teamLine(match.homeTeam, badgeURL: match.homeTeamBadgeURL)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(featuredEvent?.emptyStateTitle ?? match.league)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text(match.league)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 104, alignment: .leading)

                ProGameSportBadgeView(
                    sportType: match.liveSportVisualType,
                    diameter: 54,
                    featuredEvent: featuredEvent,
                    featuredEventSlug: match.featuredEventSlug
                )
            }

            if CalendarProGamesFilterSupport.shouldShowScore(match) {
                ProGameScoreBlock(
                    awayTeam: match.awayTeam,
                    homeTeam: match.homeTeam,
                    awayScore: match.scoreAway,
                    homeScore: match.scoreHome,
                    awayBadgeURL: match.awayTeamBadgeURL,
                    homeBadgeURL: match.homeTeamBadgeURL,
                    source: "BusinessImport",
                    isFinal: match.matchStatus == .fullTime,
                    isLive: match.matchStatus.isHappeningNow,
                    accentColor: accent,
                    style: ProGameScoreboardStyle(
                        scoreFont: .headline.weight(.black).monospacedDigit(),
                        separatorFont: .headline.weight(.bold),
                        teamNameFont: .caption.weight(.semibold),
                        emblemSize: 22,
                        showsTeamEmblems: false
                    ),
                    timelineSummary: match.resolvedGoalDisplaySummary,
                    cardTimelineSummary: match.resolvedCardTimelineSummary,
                    gameId: SavedProGame.stableKey(for: match),
                    showsFramedFinalBackground: false,
                    flagSource: "BusinessImport"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onImport) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption.weight(.bold))
                    Text("Add to Venue")
                        .font(.caption.weight(.heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(FGColor.accentGreen)
                .foregroundStyle(.white)
                .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to Venue")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.045), radius: 8, y: 3)
    }

    @ViewBuilder
    private func teamLine(_ team: String, badgeURL: String?) -> some View {
        HStack(spacing: 8) {
            teamLeadingContent(for: team, badgeURL: badgeURL)
            Text(CalendarProGamesFilterSupport.teamDisplayName(team))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private func teamLeadingContent(for team: String, badgeURL: String?) -> some View {
        switch ProGameTeamScoreIdentity.resolve(teamName: team, badgeURL: badgeURL, source: "BusinessImport").leading {
        case let .flag(flag):
            Text(flag)
                .font(.title3)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                Color.clear
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .none:
            EmptyView()
        }
    }
}

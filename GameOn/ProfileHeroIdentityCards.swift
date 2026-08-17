import SwiftUI

/// Shared metrics for own + public profile hero artwork / identity.
enum ProfileHeroMetrics {
    /// Curated-background band (~40% of a typical hero; full-width, scaledToFill).
    /// Taller band (+24pt / ~11.5%) for a more premium Apple-like hero.
    static let artworkHeight: CGFloat = 232
    /// Top inset so identity text sits on the near-white dissolve (artwork remains above).
    /// Raised with the taller cover so avatar + identity sit ~18pt lower.
    static let identityTopInset: CGFloat = 166
    /// Avatar overlap into the artwork → light transition (bridges the fade).
    static let avatarOverlapOffset: CGFloat = 52
    /// Shared avatar diameter (own + public + self-preview).
    static let avatarDiameter: CGFloat = 140
    /// Spacing between identity/actions and the two-row information container.
    static let identityToCardsSpacing: CGFloat = 8
    /// Bottom padding after the second identity row inside the hero.
    static let heroBottomPadding: CGFloat = 12
    /// Outer horizontal inset for own + public + self-preview profile containers.
    /// Standard phones use a tighter gutter; SE / mini keep the prior 16pt spacing.
    static let outerInset: CGFloat = 6
    /// Back-compat alias — prefer ``outerInset(screenWidth:)`` for adaptive SE spacing.
    static let ownHeroOuterInset: CGFloat = outerInset
    /// Shared hero card corner radius (own chrome + public redesign hero).
    static let heroCornerRadius: CGFloat = 26
    /// Internal horizontal padding inside the hero (identity / actions).
    static let heroContentHorizontalPadding: CGFloat = 14
    /// Horizontal inset for the two-row identity card container inside the hero.
    static let identityCardsHorizontalPadding: CGFloat = 10

    /// Adaptive outer inset from container/screen width (no negative offsets).
    /// - SE / mini (≤375): keep prior 16pt so the layout never feels cramped.
    /// - Standard + Pro Max: 6pt (~10pt wider usable width than the previous 16).
    /// - iPad-class (≥700): keep 16pt so the column does not go edge-to-edge.
    @MainActor
    static func outerInset(forWidth width: CGFloat) -> CGFloat {
        if width <= 375 { return 16 }
        if width >= 700 { return 16 }
        return outerInset
    }

    @MainActor
    static func outerInset(screenWidth: CGFloat? = nil) -> CGFloat {
        let resolved = screenWidth ?? currentWindowSceneScreenWidth()
        return outerInset(forWidth: resolved)
    }

    @MainActor
    private static func currentWindowSceneScreenWidth() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .screen
            .bounds
            .width
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }
                .first
            ?? 393
    }
}

extension View {
    /// Lifts the hero avatar up into the artwork band and reclaims the layout
    /// height that lift leaves behind (shared by own + public heroes).
    ///
    /// `offset(y:)` is a render-time translation only: on its own the identity
    /// row still reserves the avatar's full ``ProfileHeroMetrics/avatarDiameter``
    /// box, so the bottom ``ProfileHeroMetrics/avatarOverlapOffset`` points of
    /// that box are visually empty and push the action row down. The matching
    /// negative bottom padding makes the avatar's layout bottom equal its
    /// visual bottom, so the hero sizes to its identity content instead.
    func profileHeroAvatarOverlap() -> some View {
        offset(y: -ProfileHeroMetrics.avatarOverlapOffset)
            .padding(.bottom, -ProfileHeroMetrics.avatarOverlapOffset)
    }
}

/// Compact immutable model for one hero identity item (shared own/public).
struct ProfileHeroIdentityCardItem: Identifiable {
    enum Kind: String {
        case myTeam
        case nationalTeam
        case homeCrowd
        case location
        case fanSince
        case gender
    }

    let id: Kind
    /// Section label (e.g. "Favorite Team", "National Team", "Member Since").
    let title: String
    /// Primary detail under the label.
    let primaryLine: String
    /// Optional secondary detail (sport / neutral national subtitle).
    let secondaryLine: String?
    var nationalTeamFlag: String? = nil
    var favoriteTeam: FavoriteTeam? = nil
    var action: (() -> Void)? = nil
}

/// Builds the approved five identity items for the two-row hero container.
enum ProfileHeroIdentityCardsBuilder {
    static func cards(
        myTeam: FavoriteTeam?,
        homeCrowdName: String?,
        homeCrowdSubtitle: String?,
        locationPrimary: String?,
        locationSecondary: String?,
        fanSincePrimary: String?,
        fanSinceSecondary: String?,
        nationalTeam: NationalTeamIdentity?,
        nationalTeamSport: FavoriteTeamSport? = nil,
        gender: FanProfileGender? = nil,
        languageCode: String,
        onMyTeam: (() -> Void)? = nil,
        onHomeCrowd: (() -> Void)? = nil,
        onNationalTeam: (() -> Void)? = nil
    ) -> [ProfileHeroIdentityCardItem] {
        _ = homeCrowdSubtitle
        _ = fanSinceSecondary

        // Authoritative primary favorite club (e.g. Utah Jazz) — NOT FanGeo Team memberships.
        let myTeamItem: ProfileHeroIdentityCardItem = {
            if let myTeam {
                return ProfileHeroIdentityCardItem(
                    id: .myTeam,
                    title: L10n.t("my_team", languageCode: languageCode),
                    primaryLine: myTeam.name,
                    secondaryLine: myTeam.sport.chipTitle,
                    favoriteTeam: myTeam,
                    action: onMyTeam
                )
            }
            return ProfileHeroIdentityCardItem(
                id: .myTeam,
                title: L10n.t("my_team", languageCode: languageCode),
                primaryLine: L10n.t("no_team_selected", languageCode: languageCode),
                secondaryLine: nil,
                action: onMyTeam
            )
        }()

        let nationalItem: ProfileHeroIdentityCardItem = {
            if let nationalTeam {
                let country = nationalTeam.countryName.trimmingCharacters(in: .whitespacesAndNewlines)
                return ProfileHeroIdentityCardItem(
                    id: .nationalTeam,
                    title: L10n.t("national_team", languageCode: languageCode),
                    primaryLine: country.isEmpty
                        ? nationalTeam.resolvedSupporterLabel(languageCode: languageCode)
                        : country,
                    secondaryLine: NationalFanIdentityDisplay.stripSubtitle(
                        nationalTeamSport: nationalTeamSport,
                        languageCode: languageCode
                    ),
                    nationalTeamFlag: nationalTeam.flag,
                    favoriteTeam: FavoriteTeamCatalog.nationalTeam(
                        matchingCountryName: country.isEmpty ? nationalTeam.countryName : country
                    ),
                    action: onNationalTeam
                )
            }
            return ProfileHeroIdentityCardItem(
                id: .nationalTeam,
                title: L10n.t("national_team", languageCode: languageCode),
                primaryLine: L10n.t("profile_hero_national_team_empty", languageCode: languageCode),
                secondaryLine: nil,
                action: onNationalTeam
            )
        }()

        let crowdName = homeCrowdName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let homeCrowdItem = ProfileHeroIdentityCardItem(
            id: .homeCrowd,
            title: L10n.t("home_crowd", languageCode: languageCode),
            primaryLine: crowdName.isEmpty
                ? L10n.t("profile_hero_home_crowd_empty", languageCode: languageCode)
                : crowdName,
            // Bottom-row cells stay single-value to avoid clipping at larger Dynamic Type.
            secondaryLine: nil,
            action: onHomeCrowd
        )

        let locationLine = joinedLocation(primary: locationPrimary, secondary: locationSecondary)
        let locationItem = ProfileHeroIdentityCardItem(
            id: .location,
            title: L10n.t("location", languageCode: languageCode),
            primaryLine: locationLine.isEmpty
                ? L10n.t("profile_hero_location_empty", languageCode: languageCode)
                : locationLine,
            secondaryLine: nil
        )

        let sincePrimary = fanSincePrimary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fanSinceItem = ProfileHeroIdentityCardItem(
            id: .fanSince,
            title: L10n.t("member_since", languageCode: languageCode),
            primaryLine: sincePrimary.isEmpty
                ? L10n.t("profile_hero_fan_since_empty", languageCode: languageCode)
                : sincePrimary,
            secondaryLine: nil
        )

        // Order matches approved two-row layout lookups (not a single carousel order).
        var items = [myTeamItem, nationalItem, homeCrowdItem, locationItem, fanSinceItem]
        if let gender, gender.isDisplayableOnRoster {
            items.append(
                ProfileHeroIdentityCardItem(
                    id: .gender,
                    title: L10n.t("profile_gender", languageCode: languageCode),
                    primaryLine: L10n.t(gender.localizedKey, languageCode: languageCode),
                    secondaryLine: nil
                )
            )
        }
        return items
    }

    static func cards(from data: PublicUserProfileData, languageCode: String) -> [ProfileHeroIdentityCardItem] {
        let location = data.homeCityDisplayLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let crowd = data.homeCrowd?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cards(
            myTeam: data.explicitPrimaryFavoriteTeam,
            homeCrowdName: crowd,
            homeCrowdSubtitle: nil,
            locationPrimary: location,
            locationSecondary: nil,
            fanSincePrimary: FanGeoHandleRules.fanSinceMonthYear(from: data.profileCreatedAt),
            fanSinceSecondary: nil,
            nationalTeam: data.nationalTeam,
            gender: FanProfileGender.rosterDisplayValue(from: data.genderRaw),
            languageCode: languageCode
        )
    }

    private static func joinedLocation(primary: String?, secondary: String?) -> String {
        let p = primary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let s = secondary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.isEmpty { return s }
        if s.isEmpty { return p }
        return "\(p), \(s)"
    }
}

enum ProfileHeroIdentityCardsLayout {
    static func rows(from cards: [ProfileHeroIdentityCardItem]) -> [[ProfileHeroIdentityCardItem]] {
        func item(_ kind: ProfileHeroIdentityCardItem.Kind) -> ProfileHeroIdentityCardItem? {
            cards.first { $0.id == kind }
        }
        if item(.gender) != nil {
            return [
                [item(.myTeam), item(.nationalTeam)].compactMap { $0 },
                [item(.homeCrowd), item(.location)].compactMap { $0 },
                [item(.fanSince), item(.gender)].compactMap { $0 }
            ].filter { !$0.isEmpty }
        }
        return [
            [item(.myTeam), item(.nationalTeam)].compactMap { $0 },
            [item(.homeCrowd), item(.location), item(.fanSince)].compactMap { $0 }
        ].filter { !$0.isEmpty }
    }
}

/// Identity information container — shared by own + public profile heroes.
///
/// With Gender: My Team | National Team / Home Crowd | Location / Member Since | Gender
/// Without Gender: My Team | National Team / Home Crowd | Location | Member Since
struct ProfileHeroIdentityCardsRow: View {
    let cards: [ProfileHeroIdentityCardItem]
    @Environment(\.colorScheme) private var colorScheme

    private var rows: [[ProfileHeroIdentityCardItem]] {
        ProfileHeroIdentityCardsLayout.rows(from: cards)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    horizontalDivider
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { cellIndex, card in
                        if cellIndex > 0 {
                            verticalDivider
                        }
                        ProfileHeroIdentityCellView(
                            card: card,
                            prominence: index == 0 ? .top : .bottom
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(containerFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(containerBorder, lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private var containerFill: Color {
        FGColor.cardBackground(colorScheme)
    }

    private var containerBorder: Color {
        FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.55)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.65))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.55))
            .frame(width: 1)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

private enum ProfileHeroIdentityCellProminence {
    case top
    case bottom
}

private struct ProfileHeroIdentityCellView: View {
    let card: ProfileHeroIdentityCardItem
    let prominence: ProfileHeroIdentityCellProminence

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        Group {
            if let action = card.action {
                Button(action: action) { cellContent }
                    .buttonStyle(.plain)
            } else {
                cellContent
            }
        }
    }

    private var cellContent: some View {
        VStack(alignment: .leading, spacing: prominence == .top ? 7 : 6) {
            icon
            Text(card.title)
                .font(.system(size: prominence == .top ? 12 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)

            Text(card.primaryLine)
                .font(.system(size: prominence == .top ? 12.5 : 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.92))
                .multilineTextAlignment(.leading)
                .lineLimit(prominence == .top ? 2 : 2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)

            if let secondary = card.secondaryLine?.trimmingCharacters(in: .whitespacesAndNewlines),
               !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }

    @ViewBuilder
    private var icon: some View {
        switch card.id {
        case .myTeam:
            if let team = card.favoriteTeam {
                SportsIdentityArtworkView(
                    favoriteTeam: team,
                    diameter: SportsIdentityArtworkMetrics.profileHeroIdentitySlot,
                    opticalInset: .profileHero
                )
            } else {
                symbolBadge("trophy.fill", tint: FGColor.accentYellow)
            }
        case .nationalTeam:
            if let team = card.favoriteTeam {
                SportsIdentityArtworkView(
                    favoriteTeam: team,
                    diameter: SportsIdentityArtworkMetrics.profileHeroIdentitySlot,
                    opticalInset: .profileHero
                )
            } else {
                SportsIdentityArtworkView(
                    countryName: card.primaryLine,
                    flag: card.nationalTeamFlag,
                    diameter: SportsIdentityArtworkMetrics.profileHeroIdentitySlot,
                    opticalInset: .profileHero
                )
            }
        case .homeCrowd:
            symbolBadge("sportscourt.fill", tint: Color(red: 0.58, green: 0.42, blue: 0.92))
        case .location:
            symbolBadge("mappin.and.ellipse", tint: Color(red: 0.22, green: 0.48, blue: 0.96))
        case .fanSince:
            symbolBadge("calendar", tint: Color(red: 0.22, green: 0.48, blue: 0.96))
        case .gender:
            symbolBadge("person.fill", tint: Color(red: 0.42, green: 0.45, blue: 0.52))
        }
    }

    private func symbolBadge(_ name: String, tint: Color) -> some View {
        let side: CGFloat = prominence == .top
            ? SportsIdentityArtworkMetrics.profileHeroIdentitySlot
            : 28
        return Image(systemName: name)
            .font(.system(size: prominence == .top ? 22 : 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background {
                RoundedRectangle(cornerRadius: prominence == .top ? 16 : 8, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.20 : 0.12))
            }
            .accessibilityHidden(true)
    }

    private var accessibilityLabelText: String {
        var parts = [card.title, card.primaryLine]
        if let secondary = card.secondaryLine, !secondary.isEmpty {
            parts.append(secondary)
        }
        switch card.id {
        case .myTeam:
            return "\(L10n.t("my_team", languageCode: appLanguageRaw)), " + parts.dropFirst().joined(separator: ", ")
        case .nationalTeam:
            return "\(L10n.t("national_team", languageCode: appLanguageRaw)), " + parts.dropFirst().joined(separator: ", ")
        case .gender:
            return "\(L10n.t("profile_gender", languageCode: appLanguageRaw)), \(card.primaryLine)"
        default:
            return parts.joined(separator: ", ")
        }
    }
}

#if DEBUG
enum ProfileHeroIdentityCardsSelfTests {
    static func runAll() {
        testGenderTileRequiresDisplayableValue()
        testGenderHiddenRemovesTile()
        testPreferredThreeByTwoLayoutWhenGenderVisible()
        testExistingLayoutWhenGenderHidden()
        testGenderCopyResolves()
        testGenderAccessibilityCopy()
        testProfileHeroIdentityMarkSize()
        testNationalTeamPrefersCatalogCrestIdentity()
        testLongPrimaryLineRemainsTwoLineSafe()
        testSurroundingInfoCellsUnchanged()
        print("[ProfileHeroIdentityCardsSelfTests] all passed")
    }

    private static func sampleCards(gender: FanProfileGender?) -> [ProfileHeroIdentityCardItem] {
        ProfileHeroIdentityCardsBuilder.cards(
            myTeam: nil,
            homeCrowdName: "Delta Center",
            homeCrowdSubtitle: nil,
            locationPrimary: "Lehi",
            locationSecondary: "UT",
            fanSincePrimary: "Jan 2024",
            fanSinceSecondary: nil,
            nationalTeam: nil,
            gender: gender,
            languageCode: "en"
        )
    }

    private static func testGenderTileRequiresDisplayableValue() {
        let shown = sampleCards(gender: .male)
        precondition(shown.contains(where: { $0.id == .gender }))
        precondition(shown.first(where: { $0.id == .gender })?.primaryLine == "Male")
        precondition(shown.first(where: { $0.id == .gender })?.title == "Gender")
    }

    private static func testGenderHiddenRemovesTile() {
        precondition(!sampleCards(gender: nil).contains(where: { $0.id == .gender }))
        precondition(!sampleCards(gender: .preferNotToSay).contains(where: { $0.id == .gender }))
        precondition(FanProfileGender.rosterDisplayValue(from: nil) == nil)
        precondition(FanProfileGender.rosterDisplayValue(from: "prefer_not_to_say") == nil)
        precondition(FanProfileGender.rosterDisplayValue(from: "female") == .female)
    }

    private static func testPreferredThreeByTwoLayoutWhenGenderVisible() {
        let rows = ProfileHeroIdentityCardsLayout.rows(from: sampleCards(gender: .nonBinary))
        precondition(rows.count == 3)
        precondition(rows[0].map(\.id) == [.myTeam, .nationalTeam])
        precondition(rows[1].map(\.id) == [.homeCrowd, .location])
        precondition(rows[2].map(\.id) == [.fanSince, .gender])
        precondition(rows.allSatisfy { !$0.isEmpty })
    }

    private static func testExistingLayoutWhenGenderHidden() {
        let rows = ProfileHeroIdentityCardsLayout.rows(from: sampleCards(gender: nil))
        precondition(rows.count == 2)
        precondition(rows[0].map(\.id) == [.myTeam, .nationalTeam])
        precondition(rows[1].map(\.id) == [.homeCrowd, .location, .fanSince])
        precondition(!rows.flatMap { $0 }.contains(where: { $0.id == .gender }))
    }

    private static func testGenderCopyResolves() {
        for key in [
            "profile_gender",
            "profile_gender_male",
            "profile_gender_female",
            "profile_gender_non_binary",
            "profile_gender_prefer_not_to_say"
        ] {
            let value = L10n.t(key, languageCode: "en")
            precondition(value != key)
            precondition(!value.isEmpty)
        }
        precondition(L10n.t("profile_gender", languageCode: "en") == "Gender")
        precondition(L10n.t("profile_gender_male", languageCode: "en") == "Male")
        precondition(L10n.t("profile_gender_female", languageCode: "en") == "Female")
        precondition(L10n.t("profile_gender_non_binary", languageCode: "en") == "Non-binary")
        precondition(L10n.t("profile_gender_prefer_not_to_say", languageCode: "en") == "Prefer not to say")
    }

    private static func testGenderAccessibilityCopy() {
        let card = sampleCards(gender: .male).first { $0.id == .gender }!
        let label = "\(card.title), \(card.primaryLine)"
        precondition(label == "Gender, Male")
        precondition(!label.localizedCaseInsensitiveContains("person"))
        precondition(!label.contains("♂"))
        precondition(!label.contains("♀"))
    }

    private static func testProfileHeroIdentityMarkSize() {
        let slot = SportsIdentityArtworkMetrics.profileHeroIdentitySlot
        let visible = SportsIdentityArtworkMetrics.visibleArtworkSize(
            container: slot,
            optical: .profileHero
        )
        precondition(slot >= 52 && slot <= 60)
        precondition(visible >= 44 && visible <= 52)
        precondition(slot == 56)
        precondition(visible == 48)
        precondition(DiscoverMapImageCache.Bucket.forPointSize(slot) == .avatar)
        precondition(DiscoverMapImageCache.Bucket.forPointSize(slot) != .venue)
        let small = SportsArtworkURLStore.displayURL(
            from: "https://www.thesportsdb.com/images/media/team/badge/inter.png",
            diameter: slot
        )
        precondition(small?.absoluteString.hasSuffix("/small") == true)
        precondition(small?.absoluteString.hasSuffix("/tiny") != true)
    }

    private static func testNationalTeamPrefersCatalogCrestIdentity() {
        let italy = NationalTeamIdentity(
            countryCode: "IT",
            countryName: "Italy",
            flag: "🇮🇹",
            supporterLabel: "Italy Fan"
        )
        let cards = ProfileHeroIdentityCardsBuilder.cards(
            myTeam: nil,
            homeCrowdName: "Delta Center",
            homeCrowdSubtitle: nil,
            locationPrimary: "Lehi",
            locationSecondary: "UT",
            fanSincePrimary: "Jan 2024",
            fanSinceSecondary: nil,
            nationalTeam: italy,
            languageCode: "en"
        )
        let national = cards.first { $0.id == .nationalTeam }
        precondition(national?.favoriteTeam?.id == "soccer-italy")
        precondition(national?.favoriteTeam?.kind == .nationalTeam)
        precondition(national?.nationalTeamFlag == "🇮🇹")
        precondition(national?.primaryLine == "Italy")

        let flagOnly = SportsIdentityArtworkResolver.resolveNationalTeam(
            countryName: "Unknownlandia",
            flag: "🏳️"
        )
        if case .countryFlag(let flag) = flagOnly.kind {
            precondition(flag == "🏳️")
        } else {
            precondition(false, "flag fallback still works when no crest is cached")
        }
    }

    private static func testLongPrimaryLineRemainsTwoLineSafe() {
        let longName = FavoriteTeam(
            id: "test-long-club",
            name: "Royal Sporting Club of the Northern United Athletic Association",
            sport: .soccer,
            league: "Serie A",
            region: "Europe",
            kind: .team,
            shortCode: "RSC",
            searchAliases: [],
            fallbackSymbol: "soccerball",
            badgeRed: 0.1,
            badgeGreen: 0.2,
            badgeBlue: 0.7
        )
        let cards = ProfileHeroIdentityCardsBuilder.cards(
            myTeam: longName,
            homeCrowdName: nil,
            homeCrowdSubtitle: nil,
            locationPrimary: nil,
            locationSecondary: nil,
            fanSincePrimary: nil,
            fanSinceSecondary: nil,
            nationalTeam: nil,
            languageCode: "en"
        )
        let myTeam = cards.first { $0.id == .myTeam }
        precondition(myTeam?.primaryLine == longName.name)
        precondition(myTeam?.favoriteTeam?.id == longName.id)
    }

    private static func testSurroundingInfoCellsUnchanged() {
        let rows = ProfileHeroIdentityCardsLayout.rows(from: sampleCards(gender: nil))
        precondition(rows[0].map(\.id) == [.myTeam, .nationalTeam])
        precondition(rows[1].map(\.id) == [.homeCrowd, .location, .fanSince])
        precondition(rows[1].allSatisfy { $0.favoriteTeam == nil })
    }
}
#endif

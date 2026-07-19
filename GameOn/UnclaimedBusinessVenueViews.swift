import SwiftUI

/// Aggregated, privacy-safe counts already available on the client. No identities.
struct UnclaimedVenueSocialProofMetrics: Equatable {
    var favoritedByFans: Int
    var fansGoingUpcoming: Int
    var eventsHosted: Int
    var fanInteractions: Int

    init(
        favoritedByFans: Int = 0,
        fansGoingUpcoming: Int = 0,
        eventsHosted: Int = 0,
        fanInteractions: Int = 0
    ) {
        self.favoritedByFans = max(0, favoritedByFans)
        self.fansGoingUpcoming = max(0, fansGoingUpcoming)
        self.eventsHosted = max(0, eventsHosted)
        self.fanInteractions = max(0, fanInteractions)
    }

    var strongestSignal: UnclaimedVenueSocialProofSignal? {
        UnclaimedVenueSocialProofSignal.strongest(from: self)
    }
}

enum UnclaimedVenueSocialProofSignal: Equatable {
    case favorited(Int)
    case goingUpcoming(Int)
    case eventsHosted(Int)
    case interactions(Int)

    static func strongest(from metrics: UnclaimedVenueSocialProofMetrics) -> UnclaimedVenueSocialProofSignal? {
        if metrics.favoritedByFans > 0 { return .favorited(metrics.favoritedByFans) }
        if metrics.fansGoingUpcoming > 0 { return .goingUpcoming(metrics.fansGoingUpcoming) }
        if metrics.eventsHosted > 0 { return .eventsHosted(metrics.eventsHosted) }
        if metrics.fanInteractions > 0 { return .interactions(metrics.fanInteractions) }
        return nil
    }

    var count: Int {
        switch self {
        case .favorited(let n), .goingUpcoming(let n), .eventsHosted(let n), .interactions(let n):
            return n
        }
    }

    var systemImage: String {
        switch self {
        case .favorited: return "heart.fill"
        case .goingUpcoming: return "party.popper.fill"
        case .eventsHosted: return "sportscourt.fill"
        case .interactions: return "person.2.fill"
        }
    }

    private var localizationKey: String {
        switch self {
        case .favorited: return "venue_unclaimed_proof_favorited_format"
        case .goingUpcoming: return "venue_unclaimed_proof_going_format"
        case .eventsHosted: return "venue_unclaimed_proof_events_format"
        case .interactions: return "venue_unclaimed_proof_interactions_format"
        }
    }

    func localizedText(languageCode: String) -> String {
        String(
            format: L10n.t(localizationKey, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            "\(count)"
        )
    }
}

enum UnclaimedVenueSocialProofBuilder {
    /// Builds counts from already-loaded venue/event caches. No network, no identities.
    static func metrics(
        bar: BarVenue,
        favoritedByFans: Int,
        venueEventRows: [VenueEventRow],
        extraEventIDs: [UUID] = [],
        gamesTodayCount: Int = 0,
        interestCount: (UUID) -> Int,
        commentCount: (UUID) -> Int,
        vibeCounts: (UUID) -> [String: Int],
        previewVibeTotal: Int = 0
    ) -> UnclaimedVenueSocialProofMetrics {
        let venueRows = venueEventRows.filter { $0.venue_id == bar.id }
        var eventIDs = Set(venueRows.compactMap(\.id))
        eventIDs.formUnion(extraEventIDs)

        let goingFromInterest = eventIDs.reduce(0) { $0 + max(0, interestCount($1)) }
        let goingFromEmbedded = bar.goingCounts.values.reduce(0, +)
        let fansGoingUpcoming = max(goingFromInterest, goingFromEmbedded)

        let eventsHosted = max(venueRows.count, bar.games.count, gamesTodayCount)

        let vibeInteractions = eventIDs.reduce(0) { partial, id in
            partial + vibeCounts(id).values.reduce(0, +)
        }
        let commentInteractions = eventIDs.reduce(0) { $0 + max(0, commentCount($1)) }
        let fanInteractions = max(vibeInteractions + commentInteractions, max(0, previewVibeTotal))

        return UnclaimedVenueSocialProofMetrics(
            favoritedByFans: favoritedByFans,
            fansGoingUpcoming: fansGoingUpcoming,
            eventsHosted: eventsHosted,
            fanInteractions: fanInteractions
        )
    }
}

/// Subtle social-proof line for unclaimed venues only. Matches Community Verified metadata typography.
struct UnclaimedVenueSocialProofRow: View {
    let metrics: UnclaimedVenueSocialProofMetrics

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        if let signal = metrics.strongestSignal {
            HStack(spacing: 6) {
                Image(systemName: signal.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .accessibilityHidden(true)

                Text(signal.localizedText(languageCode: languageCode))
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(signal.localizedText(languageCode: languageCode))
        }
    }
}

/// Compact ownership status for Discover preview / venue detail (unclaimed listings only).
struct UnclaimedBusinessStatusCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var showsSourceNote: Bool = true

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("venue_unclaimed_business", languageCode: languageCode))
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(L10n.t("venue_unclaimed_description", languageCode: languageCode))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                if showsSourceNote {
                    Text(L10n.t("venue_unclaimed_source_note", languageCode: languageCode))
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(L10n.t("venue_unclaimed_business", languageCode: languageCode)). \(L10n.t("venue_unclaimed_description", languageCode: languageCode))"
        )
    }
}

/// Owner/authorized-representative claim callout. Does not submit claims itself.
struct UnclaimedBusinessClaimCallout: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var showsLearnMoreLink: Bool = true
    let onClaim: () -> Void

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("venue_own_this_business", languageCode: languageCode))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text(L10n.t("venue_business_account_required_message", languageCode: languageCode))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.t("venue_claim_benefits", languageCode: languageCode))
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onClaim) {
                Text(L10n.t("venue_claim_this_venue", languageCode: languageCode))
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(FGColor.accentBlue)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("venue_claim_this_venue_a11y", languageCode: languageCode))
            .padding(.top, 2)

            if showsLearnMoreLink {
                Button {
                    if let url = URL(string: "https://www.fangeosports.com/") {
                        openURL(url)
                    }
                } label: {
                    Text(L10n.t("venue_learn_about_business", languageCode: languageCode))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
    }
}

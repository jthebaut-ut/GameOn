import SwiftUI

// MARK: - Compact status pill

struct LiveCanonicalStatusPill: View {
    let status: LiveCanonicalMatchStatus
    var languageCode: String = L10n.defaultLanguageCode

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let key = status.badgeLocalizationKey {
            let text: String = {
                switch status {
                case .live(let minute):
                    if let minute {
                        return "LIVE \(minute)'"
                    }
                    return L10n.t("LIVE", languageCode: languageCode)
                case .startingSoon(let minutes):
                    return String(format: L10n.t("Starts in %lld min", languageCode: languageCode), minutes)
                default:
                    return L10n.t(key, languageCode: languageCode)
                }
            }()
            let tint = status.isLive ? FGColor.dangerRed : (status.isFinal ? FGColor.mutedText(colorScheme) : FGColor.accentGreen)
            HStack(spacing: 5) {
                Circle()
                    .fill(status.isLive ? FGColor.dangerRed : tint.opacity(0.75))
                    .frame(width: 5, height: 5)
                Text(text)
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.11)))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.26), lineWidth: 1)
            }
            .accessibilityLabel(text)
        }
    }
}

struct LiveVenueActivityPill: View {
    let kind: LiveVenueActivityKind
    var languageCode: String = L10n.defaultLanguageCode

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint: Color = {
            switch kind {
            case .postGameActivity: return FGColor.accentBlue
            case .crowdBuilding: return FGColor.accentGreen
            case .activeFanZone: return Color(red: 0.12, green: 0.62, blue: 0.42)
            }
        }()
        Text(L10n.t(kind.localizationKey, languageCode: languageCode))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.10)))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.24), lineWidth: 1)
            }
    }
}

// MARK: - Compact matchup row

struct LiveCompactMatchupRow: View {
    let awayTeam: String
    let homeTeam: String
    let awayScore: Int?
    let homeScore: Int?
    let scoresAvailable: Bool
    let awayBadgeURL: String?
    let homeBadgeURL: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            teamCluster(
                name: awayTeam,
                badgeURL: awayBadgeURL,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            centerScore
                .layoutPriority(1)

            teamCluster(
                name: homeTeam,
                badgeURL: homeBadgeURL,
                alignment: .trailing
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityMatchupLabel)
    }

    private var centerScore: some View {
        Group {
            if scoresAvailable, let awayScore, let homeScore {
                Text("\(awayScore) – \(homeScore)")
                    .font(.system(size: 18, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            } else {
                Text("vs")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .fixedSize()
    }

    private func teamCluster(name: String, badgeURL: String?, alignment: HorizontalAlignment) -> some View {
        let identity = ProGameTeamScoreIdentity.resolve(teamName: name, badgeURL: badgeURL, source: "Live")
        return HStack(spacing: 5) {
            if alignment == .trailing { Spacer(minLength: 0) }
            emblem(identity)
            Text(identity.displayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if alignment == .leading { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private func emblem(_ identity: ProGameTeamScoreIdentity) -> some View {
        switch identity.leading {
        case let .flag(flag):
            Text(flag)
                .font(.system(size: 14))
                .accessibilityHidden(true)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                initialsFallback(identity.displayName)
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
        case .none:
            initialsFallback(identity.displayName)
        }
    }

    private func initialsFallback(_ name: String) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
        return Text(initials.isEmpty ? String(name.prefix(2)) : initials)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .frame(width: 18, height: 18)
            .background(Circle().fill(FGColor.divider(colorScheme).opacity(0.35)))
            .accessibilityHidden(true)
    }

    private var accessibilityMatchupLabel: String {
        if scoresAvailable, let awayScore, let homeScore {
            return "\(awayTeam) \(awayScore) to \(homeScore) \(homeTeam)"
        }
        return "\(awayTeam) versus \(homeTeam)"
    }
}

// MARK: - Venue event rich card

struct LiveVenueEventRichCard: View {
    let model: LiveVenueEventCardModel
    var compact: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LiveCanonicalStatusPill(status: model.matchStatus, languageCode: languageCode)
                    Spacer(minLength: 0)
                }

                if let away = model.awayTeam, let home = model.homeTeam, !away.isEmpty, !home.isEmpty {
                    LiveCompactMatchupRow(
                        awayTeam: away,
                        homeTeam: home,
                        awayScore: model.awayScore,
                        homeScore: model.homeScore,
                        scoresAvailable: model.scoresAvailable,
                        awayBadgeURL: model.awayBadgeURL,
                        homeBadgeURL: model.homeBadgeURL
                    )
                } else {
                    Text(model.matchupTitle)
                        .font(compact ? .system(size: 15, weight: .bold, design: .rounded) : FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                }

                Text(model.venueName)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(model.metadataLine)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.showGoingCount {
                        Text(model.goingCount == 1 ? "1 going" : "\(model.goingCount) going")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                }

                if let activity = model.venueActivity {
                    LiveVenueActivityPill(kind: activity, languageCode: languageCode)
                }
            }
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 18 : 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 18 : 20, style: .continuous)
                        .strokeBorder(
                            model.matchStatus.isLive
                                ? FGColor.dangerRed.opacity(colorScheme == .dark ? 0.34 : 0.22)
                                : FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1 : 0.75),
                            lineWidth: 1
                        )
                }
        )
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
            if let urlString = model.thumbnailURLString, let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    SportArtworkIconView(sport: model.sport, diameter: 28)
                }
            } else {
                SportArtworkIconView(sport: model.sport, diameter: 28)
            }
        }
        .frame(width: compact ? 56 : 64, height: compact ? 56 : 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Pickup rich card

struct LivePickupRichCard: View {
    let model: LivePickupCardModel
    var compact: Bool = false
    var relevanceLabel: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SportArtworkIconView(sport: model.sport, diameter: compact ? 36 : 42)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    pickupStatusPill
                    if let relevanceLabel {
                        Text(relevanceLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    Spacer(minLength: 0)
                }
                Text(model.title)
                    .font(compact ? .system(size: 15, weight: .bold, design: .rounded) : FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                if let locationLine = model.locationLine {
                    Text(locationLine)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Text("\(AppSportCatalog.displayLabel(forSportToken: model.sport)) · \(statusDisplayText)")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                if let joinLine = model.joinLine {
                    Text(joinLine)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 18 : 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 18 : 20, style: .continuous)
                        .strokeBorder(
                            model.isInProgress
                                ? FGColor.dangerRed.opacity(colorScheme == .dark ? 0.34 : 0.22)
                                : FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1 : 0.75),
                            lineWidth: 1
                        )
                }
        )
        .accessibilityElement(children: .combine)
    }

    private var statusDisplayText: String {
        switch model.statusLabelKey {
        case "pickup_status_in_progress":
            return L10n.t("In progress", languageCode: languageCode)
        case "Starting soon":
            if let detail = model.statusDetail, let minutes = Int(detail) {
                return String(format: L10n.t("Starts in %lld min", languageCode: languageCode), minutes)
            }
            return L10n.t("Starting soon", languageCode: languageCode)
        case "Completed":
            return L10n.t("Completed", languageCode: languageCode)
        case "Canceled":
            return L10n.t("Canceled", languageCode: languageCode)
        default:
            return L10n.t(model.statusLabelKey, languageCode: languageCode)
        }
    }

    @ViewBuilder
    private var pickupStatusPill: some View {
        let tint: Color = {
            if model.isInProgress { return FGColor.accentGreen }
            if model.statusLabelKey == "Canceled" { return FGColor.dangerRed }
            if model.statusLabelKey == "Completed" { return FGColor.mutedText(colorScheme) }
            return FGColor.accentBlue
        }()
        let label = statusDisplayText
        if model.isInProgress
            || model.statusLabelKey == "Canceled"
            || model.statusLabelKey == "Completed"
            || (model.statusLabelKey == "Starting soon" && model.statusDetail != nil) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isInProgress ? FGColor.accentGreen : tint.opacity(0.75))
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.11)))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.26), lineWidth: 1)
            }
            .accessibilityLabel(label)
        }
    }
}

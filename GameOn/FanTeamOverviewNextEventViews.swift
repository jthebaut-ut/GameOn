import SwiftUI

// MARK: - Crash bisect breadcrumbs (print-only)

/// Narrow bisect for Overview Next Event regression (post-tabPicker / pre-overviewTab).
enum TeamOverviewCrashBisect {
    static func mark(_ stage: String, details: String? = nil) {
#if DEBUG
        var parts: [String] = ["[TeamOverviewCrashBisect]", stage]
        if let details {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        print(parts.joined(separator: " "))
#endif
    }
}

// MARK: - Immutable presentation (built outside SwiftUI body when practical)

/// Pre-formatted Overview Next Event card inputs. No network. No @State.
struct FanTeamOverviewNextEventPresentation: Equatable, Sendable {
    let eventID: UUID
    let gameType: FanTeamGameType
    let typeTitle: String
    let title: String
    let whenText: String
    let timeText: String
    let locationText: String?
    let isPrivate: Bool

    static func make(
        event: FanTeamGame,
        teamShowsPrivateBadge: Bool,
        pickupIsVisible: Bool?,
        languageCode: String
    ) -> FanTeamOverviewNextEventPresentation {
        TeamOverviewCrashBisect.mark("presentationBuildStart", details: "eventID=\(event.id.uuidString.lowercased())")
        let location = event.locationLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPrivate = teamShowsPrivateBadge || pickupIsVisible == false
        let presentation = FanTeamOverviewNextEventPresentation(
            eventID: event.id,
            gameType: event.gameType,
            typeTitle: L10n.t(event.gameType.localizedKey, languageCode: languageCode)
                .uppercased(with: Locale(identifier: languageCode)),
            title: event.displayTitle,
            whenText: FanTeamDateFormatting.gameWhen(event.startsAt, languageCode: languageCode),
            timeText: FanTeamDateFormatting.scheduleTime(event.startsAt, languageCode: languageCode),
            locationText: location.isEmpty ? nil : location,
            isPrivate: isPrivate
        )
        TeamOverviewCrashBisect.mark("presentationBuildEnd", details: "eventID=\(event.id.uuidString.lowercased())")
        return presentation
    }
}

// MARK: - Concrete Overview Next Event section (isolates AttributeGraph from FanTeamDetailSheet)

/// Dumb Overview dashboard section. Receives immutable values only — does not touch
/// `FanTeamDetailSheet` `@State`, `detail`, or network services.
struct FanTeamOverviewNextEventSectionView: View {
    /// `nil` → empty / no-upcoming card. Parent must only instantiate this when detail is loaded.
    let event: FanTeamOverviewNextEventPresentation?
    let canOrganize: Bool
    let languageCode: String
    let onOpenEvent: (UUID) -> Void
    let onScheduleEvent: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = TeamOverviewCrashBisect.mark(
            "nextEventViewBody",
            details: "hasEvent=\(event != nil) canOrganize=\(canOrganize)"
        )
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("fan_teams_next_event", languageCode: languageCode))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(L10n.t("fan_teams_next_event", languageCode: languageCode))

            if let event {
                eventCard(event)
            } else {
                emptyCard
            }
        }
    }

    private func eventCard(_ event: FanTeamOverviewNextEventPresentation) -> some View {
        let typeColor = event.gameType.scheduleDateBlockColor
        return Button {
            onOpenEvent(event.eventID)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: event.gameType.filterSystemImage)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(typeColor)
                            .accessibilityHidden(true)
                        Text(event.typeTitle)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(typeColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if event.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .accessibilityLabel(
                                    L10n.t("fan_teams_private_team", languageCode: languageCode)
                                )
                        }
                        Spacer(minLength: 0)
                    }

                    Text(event.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(event.whenText) · \(event.timeText)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if let locationText = event.locationText {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                            Text(locationText)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(typeColor.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(L10n.t("fan_teams_next_event", languageCode: languageCode)). \(event.title). \(event.whenText). \(event.timeText)"
        )
        .accessibilityHint(L10n.t("fan_teams_tab_schedule", languageCode: languageCode))
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("fan_teams_no_upcoming_events", languageCode: languageCode))
                .font(.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Text(
                L10n.t(
                    canOrganize
                        ? "fan_teams_no_upcoming_events_organizer_body"
                        : "fan_teams_no_upcoming_events_member_body",
                    languageCode: languageCode
                )
            )
            .font(.subheadline)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)

            if canOrganize {
                Button(action: onScheduleEvent) {
                    Label {
                        Text(L10n.t("fan_teams_schedule_event", languageCode: languageCode))
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    } icon: {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(FGColor.intentTeams, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("fan_teams_schedule_event", languageCode: languageCode))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.7), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("fan_teams_no_upcoming_events", languageCode: languageCode))
    }
}

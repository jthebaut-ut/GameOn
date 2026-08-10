import SwiftUI

/// Authoritative pickup-organizer aggregates for own + public profiles.
/// Source: `pickup_organizer_profile_summary` / `get_public_fan_identity_profile`.
/// Data construction is `nonisolated` so MapViewModel fetch paths can build values off the main actor;
/// localized formatting stays on the main actor (calls ``L10n``).
struct PickupOrganizerSummary: Equatable, Sendable {
    var hostedCount: Int
    /// `nil` when there are no ratings — never an artificial 0.0 average.
    var averageRating: Double?
    var ratingCount: Int
    /// Latest eligible `pickup_games.created_at`; `nil` when hosted count is 0.
    var lastPickupGameCreatedAt: Date?

    nonisolated static let empty = PickupOrganizerSummary(
        hostedCount: 0,
        averageRating: nil,
        ratingCount: 0,
        lastPickupGameCreatedAt: nil
    )

    var hasRatings: Bool { ratingCount > 0 }

    var shouldShowCard: Bool {
        hostedCount > 0 || ratingCount > 0
    }

    nonisolated init(
        hostedCount: Int,
        averageRating: Double?,
        ratingCount: Int,
        lastPickupGameCreatedAt: Date? = nil
    ) {
        let count = max(0, ratingCount)
        let hosted = max(0, hostedCount)
        self.hostedCount = hosted
        self.ratingCount = count
        if count > 0, let averageRating, averageRating > 0 {
            self.averageRating = averageRating
        } else if count > 0 {
            self.averageRating = averageRating
        } else {
            self.averageRating = nil
        }
        if hosted > 0 {
            self.lastPickupGameCreatedAt = lastPickupGameCreatedAt
        } else {
            self.lastPickupGameCreatedAt = nil
        }
    }

    nonisolated init(hostedCount: Int, stats: PickupCreatorPublicRatingStats?, lastPickupGameCreatedAt: Date? = nil) {
        let count = max(0, stats?.ratingCount ?? 0)
        let avg: Double? = {
            guard count > 0, let stats else { return nil }
            return stats.avgRating
        }()
        self.init(
            hostedCount: hostedCount,
            averageRating: avg,
            ratingCount: count,
            lastPickupGameCreatedAt: lastPickupGameCreatedAt
        )
    }

    /// Compact summary for the profile card (localized).
    func summaryLine(languageCode: String) -> String {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let hosted = max(0, hostedCount)
        let ratings = max(0, ratingCount)

        if hosted == 0, ratings == 0 {
            return L10n.t("pickup_organizer_none_hosted", languageCode: lang)
        }

        if hosted == 0, ratings > 0 {
#if DEBUG
            print("[PickupOrganizerSummary] legacyInconsistency hosted=0 ratingCount=\(ratings) avg=\(averageRating.map { String(format: "%.1f", $0) } ?? "nil")")
#endif
            return ratingPortion(languageCode: lang, includeAverage: true)
        }

        let hostedText = hostedPhrase(count: hosted, languageCode: lang)
        if ratings == 0 {
            return "\(hostedText) · \(L10n.t("pickup_organizer_no_ratings_yet", languageCode: lang))"
        }
        return "\(hostedText) · \(ratingPortion(languageCode: lang, includeAverage: true))"
    }

    /// Secondary recency line; `nil` when there are no hosted games or timestamp is missing.
    func recencyLine(languageCode: String, now: Date = Date()) -> String? {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let hosted = max(0, hostedCount)
        guard hosted > 0 else { return nil }
        guard let created = lastPickupGameCreatedAt else {
#if DEBUG
            print("[PickupOrganizerSummary] missingLastCreated hosted=\(hosted) ratings=\(ratingCount)")
#endif
            return nil
        }
        return Self.formatRecencyDisplay(createdAt: created, languageCode: lang, now: now)
    }

    func accessibilityLabel(languageCode: String, now: Date = Date()) -> String {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let title = L10n.t("pickup_organizer_title", languageCode: lang)
        let hosted = max(0, hostedCount)
        let ratings = max(0, ratingCount)

        if hosted == 0, ratings == 0 {
            return "\(title). \(L10n.t("pickup_organizer_none_hosted", languageCode: lang))"
        }

        var parts: [String] = [title]
        if hosted > 0 {
            parts.append(hostedPhrase(count: hosted, languageCode: lang))
        }
        if ratings > 0, let avg = averageRating {
            let avgText = formatAverage(avg)
            parts.append(
                String(
                    format: L10n.t("pickup_organizer_a11y_average_from_ratings_format", languageCode: lang),
                    avgText,
                    ratingsPhrase(count: ratings, languageCode: lang)
                )
            )
        } else if ratings == 0, hosted > 0 {
            parts.append(L10n.t("pickup_organizer_no_ratings_yet", languageCode: lang))
        } else if ratings > 0 {
            parts.append(ratingsPhrase(count: ratings, languageCode: lang))
        }
        if let created = lastPickupGameCreatedAt, hosted > 0 {
            parts.append(Self.formatRecencyAccessibility(createdAt: created, languageCode: lang))
        }
        return parts.joined(separator: ". ") + "."
    }

    // MARK: - Recency formatting

    static func formatRecencyDisplay(createdAt: Date, languageCode: String, now: Date = Date()) -> String {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let interval = now.timeIntervalSince(createdAt)
        if interval < 60 {
            return L10n.t("pickup_organizer_created_just_now", languageCode: lang)
        }

        let calendar = Calendar.current
        let monthComponents = calendar.dateComponents([.year, .month], from: createdAt, to: now)
        let totalMonths = ((monthComponents.year ?? 0) * 12) + (monthComponents.month ?? 0)
        let totalDays = calendar.dateComponents([.day], from: createdAt, to: now).day ?? 0

        if totalMonths >= 12 {
            let monthYear = monthYearFormatter(languageCode: lang).string(from: createdAt)
            return String(format: L10n.t("pickup_organizer_last_created_format", languageCode: lang), monthYear)
        }

        let relative: String
        if interval < 24 * 60 * 60 || totalDays < 1 {
            relative = relativeFormatter(languageCode: lang).localizedString(for: createdAt, relativeTo: now)
        } else if totalDays < 30 {
            relative = relativeFormatter(languageCode: lang).localizedString(for: createdAt, relativeTo: now)
        } else {
            relative = relativeFormatter(languageCode: lang).localizedString(for: createdAt, relativeTo: now)
        }
        return String(format: L10n.t("pickup_organizer_last_created_format", languageCode: lang), relative)
    }

    static func formatRecencyAccessibility(createdAt: Date, languageCode: String) -> String {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let exact = exactDateFormatter(languageCode: lang).string(from: createdAt)
        return String(format: L10n.t("pickup_organizer_last_created_a11y_format", languageCode: lang), exact)
    }

    private static func relativeFormatter(languageCode: String) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale(for: languageCode)
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .middleOfSentence
        return formatter
    }

    private static func monthYearFormatter(languageCode: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale(for: languageCode)
        formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
        return formatter
    }

    private static func exactDateFormatter(languageCode: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale(for: languageCode)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }

    private static func locale(for languageCode: String) -> Locale {
        Locale(identifier: L10n.normalizedLanguageCode(languageCode))
    }

    private func hostedPhrase(count: Int, languageCode: String) -> String {
        if count == 1 {
            return L10n.t("pickup_organizer_one_game_hosted", languageCode: languageCode)
        }
        let formatted = count.formatted(.number.grouping(.automatic))
        return String(
            format: L10n.t("pickup_organizer_many_games_hosted_format", languageCode: languageCode),
            formatted
        )
    }

    private func ratingsPhrase(count: Int, languageCode: String) -> String {
        if count == 1 {
            return L10n.t("pickup_organizer_one_rating", languageCode: languageCode)
        }
        let formatted = count.formatted(.number.grouping(.automatic))
        return String(
            format: L10n.t("pickup_organizer_many_ratings_format", languageCode: languageCode),
            formatted
        )
    }

    private func ratingPortion(languageCode: String, includeAverage: Bool) -> String {
        let ratingsText = ratingsPhrase(count: max(0, ratingCount), languageCode: languageCode)
        guard includeAverage, let avg = averageRating else {
            return ratingsText
        }
        return "\(formatAverage(avg)) ★ · \(ratingsText)"
    }

    private func formatAverage(_ value: Double) -> String {
        FanGeoFixedFloatFormat.string(value, decimals: 1)
    }

    // MARK: - Discover map compact trust line

    /// Compact second line for Discover pickup preview. Never invents `0.0 ★ (0)`.
    /// Returns `nil` when hosted/rating data is not yet available (caller must not show “New organizer”).
    func discoverMapTrustLine(languageCode: String) -> String? {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let hosted = max(0, hostedCount)
        let ratings = max(0, ratingCount)

        if hosted == 0, ratings == 0 {
            return nil
        }

        if ratings > 0, let avg = averageRating {
            let avgText = formatAverage(avg)
            if hosted == 1 {
                return String(
                    format: L10n.t("pickup_discover_trust_rated_one_hosted_format", languageCode: lang),
                    locale: Locale(identifier: lang),
                    avgText,
                    Int64(ratings)
                )
            }
            if hosted > 1 {
                return String(
                    format: L10n.t("pickup_discover_trust_rated_many_hosted_format", languageCode: lang),
                    locale: Locale(identifier: lang),
                    avgText,
                    Int64(ratings),
                    Int64(hosted)
                )
            }
            // Ratings without hosted count (legacy inconsistency) — still show rating portion.
            return String(
                format: L10n.t("pickup_discover_trust_rated_one_hosted_format", languageCode: lang),
                locale: Locale(identifier: lang),
                avgText,
                Int64(ratings)
            )
        }

        if hosted == 1 {
            return L10n.t("pickup_discover_trust_new_organizer_one_hosted", languageCode: lang)
        }
        if hosted > 1 {
            return String(
                format: L10n.t("pickup_discover_trust_no_ratings_many_hosted_format", languageCode: lang),
                locale: Locale(identifier: lang),
                Int64(hosted)
            )
        }
        return nil
    }

    /// VoiceOver expansion for the Discover map trust line.
    func discoverMapTrustAccessibilityLabel(organizerDisplayName: String, languageCode: String) -> String {
        let lang = L10n.normalizedLanguageCode(languageCode)
        let name = organizerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let organizerPart: String = {
            if name.isEmpty {
                return L10n.t("pickup_discover_organizer_label", languageCode: lang)
            }
            return String(
                format: L10n.t("pickup_discover_trust_a11y_organizer_format", languageCode: lang),
                locale: Locale(identifier: lang),
                name
            )
        }()

        let hosted = max(0, hostedCount)
        let ratings = max(0, ratingCount)

        let trustPart: String
        if ratings > 0, let avg = averageRating {
            let avgText = formatAverage(avg)
            if hosted == 1 {
                trustPart = String(
                    format: L10n.t("pickup_discover_trust_a11y_rated_one_hosted_format", languageCode: lang),
                    locale: Locale(identifier: lang),
                    avgText,
                    Int64(ratings)
                )
            } else {
                trustPart = String(
                    format: L10n.t("pickup_discover_trust_a11y_rated_many_hosted_format", languageCode: lang),
                    locale: Locale(identifier: lang),
                    avgText,
                    Int64(ratings),
                    Int64(max(hosted, 1))
                )
            }
        } else if hosted == 1 {
            trustPart = L10n.t("pickup_discover_trust_a11y_new_organizer", languageCode: lang)
        } else if hosted > 1 {
            trustPart = String(
                format: L10n.t("pickup_discover_trust_a11y_no_ratings_format", languageCode: lang),
                locale: Locale(identifier: lang),
                Int64(hosted)
            )
        } else {
            return organizerPart
        }

        return "\(organizerPart) \(trustPart)"
    }
}

/// Shared own + public profile card for pickup organizer hosted/rating/recency summary.
struct PickupOrganizerSummaryCard: View {
    let userId: UUID
    let summary: PickupOrganizerSummary
    var compact: Bool = true
    /// When true, omit local card chrome so a parent section surface is the only border.
    var usesExternalChrome: Bool = false
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var line: String {
        summary.summaryLine(languageCode: languageCode)
    }

    private var recency: String? {
        summary.recencyLine(languageCode: languageCode)
    }

    private var ratingAccent: Color {
        guard summary.hasRatings, let avg = summary.averageRating else {
            return FGColor.secondaryText(colorScheme)
        }
        if avg >= 4.5 { return Color(red: 0.85, green: 0.62, blue: 0.12) }
        if avg >= 4.0 { return Color(red: 0.85, green: 0.62, blue: 0.12).opacity(0.92) }
        return FGColor.secondaryText(colorScheme)
    }

    var body: some View {
        let content = HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                .background {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [FGColor.accentBlue, FGColor.accentGreen.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(L10n.t("pickup_organizer_title", languageCode: languageCode))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .textCase(.uppercase)

                summaryContent
                    .fixedSize(horizontal: false, vertical: true)

                if let recency {
                    Text(recency)
                        .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(usesExternalChrome ? (compact ? 2 : 4) : (compact ? 10 : 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.accessibilityLabel(languageCode: languageCode))
        .onAppear {
#if DEBUG
            print(
                "[PickupOrganizerSummaryCard] userId=\(userId.uuidString.lowercased()) hosted=\(summary.hostedCount) ratings=\(summary.ratingCount) lastCreated=\(summary.lastPickupGameCreatedAt?.description ?? "nil")"
            )
#endif
        }

        if usesExternalChrome {
            content
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: compact ? 16 : 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.08),
                                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.94),
                                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.08 : 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 16 : 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.82),
                                    summary.hasRatings
                                        ? Color(red: 0.85, green: 0.62, blue: 0.12).opacity(0.22)
                                        : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
                .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 12, y: 7)
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        let hosted = summary.hostedCount
        let ratings = summary.ratingCount

        if hosted == 0, ratings == 0 {
            Text(L10n.t("pickup_organizer_none_hosted", languageCode: languageCode))
                .font(.system(size: compact ? 13 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        } else if ratings > 0, summary.averageRating != nil {
            Text(line)
                .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                .foregroundStyle(ratingAccent)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        } else {
            Text(line)
                .font(.system(size: compact ? 13 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }
}

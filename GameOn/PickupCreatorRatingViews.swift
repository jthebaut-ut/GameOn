import SwiftUI

struct PickupCreatorTrustLineView: View {
    let stats: PickupCreatorPublicRatingStats?
    /// When true (pickup **detail** sheet), show a loading row until RPC stats arrive; lists keep empty space until loaded.
    var detailAlwaysVisible: Bool = false
    /// Stronger typography on the pickup detail **Organizer** tile so the rating line is easy to scan.
    var organizerCardRatingEmphasis: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        Group {
            if let stats {
                let line = detailAlwaysVisible ? stats.pickupOrganizerDetailRatingLine : stats.organizerTrustSummaryLine
                Text(line)
                    .font(
                        organizerCardRatingEmphasis
                            ? .caption.weight(.semibold)
                            : FGTypography.metadata.weight(.medium)
                    )
                    .foregroundStyle(
                        organizerCardRatingEmphasis
                            ? FGColor.primaryText(colorScheme)
                            : FGColor.secondaryText(colorScheme)
                    )
                    .lineLimit(organizerCardRatingEmphasis ? 1 : nil)
                    .minimumScaleFactor(organizerCardRatingEmphasis ? 0.72 : 1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        stats.ratingCount > 0
                            ? "Organizer rating \(line)"
                            : L10n.t("pickup_rating_a11y_new_organizer", languageCode: languageCode)
                    )
            } else if detailAlwaysVisible {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.t("pickup_rating_loading_trust", languageCode: languageCode))
                        .font(FGTypography.metadata.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.t("pickup_rating_loading_trust", languageCode: languageCode))
            }
        }
    }
}

struct PickupOrganizerPreviewIdentityRow: View {
    enum Style: Equatable {
        /// Standard Discover pickup emphasis.
        case standard
        /// Secondary hierarchy under Team identity on Team-linked preview cards.
        case secondaryUnderTeam
    }

    @ObservedObject var viewModel: MapViewModel
    let organizerUserId: UUID
    let colorScheme: ColorScheme
    /// Optional explicit summary; defaults to the shared Discover/profile cache.
    var summary: PickupOrganizerSummary? = nil
    var style: Style = .standard

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var displayName: String {
        viewModel.pickupCreatorDisplayLabel(for: organizerUserId) ?? ""
    }

    private var emailLine: String {
        viewModel.pickupOrganizerEmailForDetail(userId: organizerUserId)
    }

    private var resolvedSummary: PickupOrganizerSummary? {
        summary ?? viewModel.pickupOrganizerSummary(for: organizerUserId)
    }

    private var trustLine: String? {
        resolvedSummary?.discoverMapTrustLine(languageCode: languageCode)
    }

    private var ratingAccent: Color {
        guard let summary = resolvedSummary, summary.hasRatings else {
            return FGColor.secondaryText(colorScheme)
        }
        // Play/pickup orange — higher contrast than accentYellow on translucent Discover cards.
        return FGColor.intentPlay
    }

    private var isSecondary: Bool { style == .secondaryUnderTeam }

    private var avatarSize: CGFloat { isSecondary ? 32 : 40 }
    private var avatarFrame: CGFloat { isSecondary ? 36 : 44 }

    private var nameLine: String {
        guard !displayName.isEmpty else {
            return L10n.t("pickup_discover_organizer_label", languageCode: languageCode)
        }
        if isSecondary {
            return String(
                format: L10n.t("pickup_preview_organized_by_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                displayName
            )
        }
        return "\(displayName) · \(L10n.t("pickup_discover_organizer_label", languageCode: languageCode))"
    }

    var body: some View {
        PublicProfileAvatarTap(userId: organizerUserId, context: "discover_pickup_organizer") {
            HStack(alignment: .center, spacing: isSecondary ? 10 : 8) {
                UserAvatarView(
                    avatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: organizerUserId),
                    avatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: organizerUserId),
                    avatarDisplayRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: organizerUserId),
                    displayName: displayName,
                    email: emailLine,
                    size: avatarSize,
                    fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome,
                    imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.72) : nil
                )
                .frame(width: avatarFrame, height: avatarFrame)
                .background {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color(white: 0.88))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.28 : 0.58), lineWidth: 1)
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    radius: isSecondary ? 3 : 5,
                    x: 0,
                    y: isSecondary ? 1 : 2
                )

                VStack(alignment: .leading, spacing: isSecondary ? 2 : 1) {
                    Text(nameLine)
                        .font(
                            isSecondary
                                ? FGTypography.caption.weight(.medium)
                                : FGTypography.metadata.weight(.semibold)
                        )
                        .foregroundStyle(
                            isSecondary
                                ? FGColor.secondaryText(colorScheme)
                                : FGColor.primaryText(colorScheme)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let trustLine {
                        Text(trustLine)
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(
                                (resolvedSummary?.hasRatings == true && !isSecondary)
                                    ? ratingAccent
                                    : FGColor.mutedText(colorScheme)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .opacity(isSecondary ? 0.92 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let resolvedSummary {
            return resolvedSummary.discoverMapTrustAccessibilityLabel(
                organizerDisplayName: displayName,
                languageCode: languageCode
            )
        }
        let organizer = displayName.isEmpty
            ? L10n.t("pickup_discover_organizer_label", languageCode: languageCode)
            : String(
                format: L10n.t("pickup_discover_trust_a11y_organizer_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                displayName
            )
        return organizer
    }
}

/// Public profile organizer reputation — shared ``PickupOrganizerSummaryCard``.
struct PublicProfilePickupOrganizerCard: View {
    let creatorUserId: UUID
    let hostedCount: Int
    let stats: PickupCreatorPublicRatingStats?
    var lastPickupGameCreatedAt: Date? = nil
    var compact: Bool = false
    var usesExternalChrome: Bool = false

    private var summary: PickupOrganizerSummary {
        PickupOrganizerSummary(
            hostedCount: hostedCount,
            stats: stats,
            lastPickupGameCreatedAt: lastPickupGameCreatedAt
        )
    }

    var body: some View {
        PickupOrganizerSummaryCard(
            userId: creatorUserId,
            summary: summary,
            compact: compact,
            usesExternalChrome: usesExternalChrome
        )
        .onAppear {
            PickupOrganizerReputationDebug.log(creatorUserId: creatorUserId, stats: stats)
        }
    }
}

/// Compact post-game organizer rating (approved joiners only; parent gates visibility).
struct PickupCreatorRatingPromptCard: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow
    var onNotNow: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var selectedRating: Int = 0
    @State private var thanks = false
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var expandPrompt = true

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var organizerName: String {
        let raw = viewModel.pickupCreatorDisplayLabel(for: game.creator_user_id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty
            ? L10n.t("pickup_rating_organizer_fallback", languageCode: languageCode)
            : raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            if thanks {
                HStack(alignment: .center, spacing: FGSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(FGColor.accentGreen)
                        .accessibilityHidden(true)
                    Text(L10n.t("pickup_rating_submitted", languageCode: languageCode))
                        .font(FGTypography.cardTitle.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else if expandPrompt {
                promptContent
            }
        }
        .padding(FGSpacing.md)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .onAppear {
            PickupCreatorRatingDebug.lifecycle("prompt presented")
            Task {
                await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: game.creator_user_id)
            }
        }
    }

    @ViewBuilder
    private var promptContent: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: game.creator_user_id),
                avatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: game.creator_user_id),
                avatarDisplayRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: game.creator_user_id),
                displayName: organizerName,
                email: viewModel.pickupOrganizerEmailForDetail(userId: game.creator_user_id),
                size: 40,
                fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("pickup_rating_prompt_title", languageCode: languageCode))
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    String(
                        format: L10n.t("pickup_rating_prompt_subtitle_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        organizerName
                    )
                )
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(L10n.t("pickup_rating_prompt_title", languageCode: languageCode)). \(String(format: L10n.t("pickup_rating_prompt_subtitle_format", languageCode: languageCode), locale: Locale(identifier: languageCode), organizerName))"
        )

        HStack(spacing: 4) {
            ForEach(1 ... 5, id: \.self) { n in
                Button {
                    selectedRating = n
                } label: {
                    Image(systemName: n <= selectedRating ? "star.fill" : "star")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(n <= selectedRating ? FGColor.accentYellow : FGColor.mutedText(colorScheme))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        format: L10n.t("pickup_rating_star_a11y_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        n
                    )
                )
                .accessibilityAddTraits(n <= selectedRating ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            selectedRating > 0
                ? String(
                    format: L10n.t("pickup_rating_selected_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    selectedRating
                )
                : L10n.t("pickup_rating_stars_a11y", languageCode: languageCode)
        )

        if let submitError, !submitError.isEmpty {
            Text(submitError)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.dangerRed)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: FGSpacing.sm) {
            Button {
                viewModel.deferPickupCreatorRatingPrompt(pickupGameId: game.id)
                onNotNow?()
            } label: {
                Text(L10n.t("pickup_rating_not_now", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isSubmitting)

            Button {
                Task { await submit() }
            } label: {
                Text(
                    isSubmitting
                        ? L10n.t("pickup_rating_submitting", languageCode: languageCode)
                        : L10n.t("pickup_rating_submit", languageCode: languageCode)
                )
                .font(FGTypography.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentBlue)
            .disabled(selectedRating < 1 || selectedRating > 5 || isSubmitting)
        }
    }

    private func submit() async {
        guard selectedRating >= 1, selectedRating <= 5 else { return }
        isSubmitting = true
        submitError = nil
        let ok = await viewModel.submitPickupCreatorRating(
            pickupGameId: game.id,
            creatorUserId: game.creator_user_id,
            rating: selectedRating,
            feedback: nil
        )
        isSubmitting = false
        if ok {
            thanks = true
        } else {
            submitError = L10n.t("pickup_rating_submit_error", languageCode: languageCode)
        }
    }
}

/// Persistent history action for completed / unrated (or already rated) games.
struct PickupCreatorRateOrganizerHistoryRow: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow
    let joinStatus: String?
    var onRateTapped: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var showPrompt = false

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var ratedValue: Int? {
        viewModel.myPickupCreatorRatingValue(for: game.id)
    }

    private var canRate: Bool {
        viewModel.shouldShowPickupCreatorRateOrganizerAction(game: game, joinStatus: joinStatus)
    }

    var body: some View {
        Group {
            if let stars = ratedValue, viewModel.hasSubmittedPickupCreatorRating(for: game.id) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                    Text(L10n.t("pickup_rating_rated", languageCode: languageCode))
                        .font(FGTypography.metadata.weight(.semibold))
                    Text(String(repeating: "★", count: min(5, max(1, stars))))
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(FGColor.accentYellow)
                }
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(
                        format: L10n.t("pickup_rating_rated_a11y_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        stars
                    )
                )
            } else if canRate {
                if showPrompt {
                    PickupCreatorRatingPromptCard(viewModel: viewModel, game: game) {
                        showPrompt = false
                    }
                } else {
                    Button {
                        viewModel.undefferPickupCreatorRatingPrompt(pickupGameId: game.id)
                        showPrompt = true
                        onRateTapped?()
                    } label: {
                        Text(L10n.t("pickup_rating_rate_organizer", languageCode: languageCode))
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(FGColor.accentYellow)
                    .accessibilityLabel(L10n.t("pickup_rating_rate_organizer", languageCode: languageCode))
                }
            }
        }
    }
}

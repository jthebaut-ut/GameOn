import CoreLocation
import SwiftUI

// MARK: - Join request withdraw (Calendar / Following / detail)

struct PickupJoinWithdrawConfirmState: Identifiable {
    let id = UUID()
    let requestId: UUID
    let pickupGameId: UUID
    let intent: PickupJoinWithdrawIntent

    enum PickupJoinWithdrawIntent {
        case pending
        case approved
        case declined

        var alertTitle: String {
            switch self {
            case .pending: return "Withdraw your request to join this game?"
            case .approved: return "Tell the organizer you can’t make it?"
            case .declined: return "Remove this game from your list?"
            }
        }

        var alertMessage: String {
            switch self {
            case .pending:
                return "You can request to join again later if the game still has openings."
            case .approved:
                return "Your spot will be freed for another player."
            case .declined:
                return "This hides the declined request from your Playing and Calendar pickup lists."
            }
        }
    }
}

/// Confirmation for per-user “Clear from Going” on completed Playing pickup cards.
struct PickupPlayingClearConfirmState: Identifiable {
    let id = UUID()
    let pickupGameId: UUID
    /// True when the participant has not submitted an organizer rating yet.
    let warnUnrated: Bool
}

// MARK: - Pickup “started” visuals (shared)

/// Wraps a sport glyph with a small, neutral “Started” tag (not alarming).
struct PickupGameStartedSportGlyphFrame<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let showStarted: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
            if showStarted {
                Text("Started")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.07))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
                    )
                    .offset(x: 5, y: -4)
                    .accessibilityLabel("Game already started")
            }
        }
    }
}

/// One-line caption for list / detail headers.
struct PickupGameStartedLineCaption: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text("Game already started")
            .font(FGTypography.caption.weight(.medium))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .accessibilityLabel("Game already started")
    }
}

/// Stable token for presenting pickup detail from Discover (`Identifiable` for `.sheet(item:)`).
struct PickupDetailNavigationToken: Identifiable, Equatable, Hashable {
    let id: UUID
}

/// Discover → Pickup mode: full detail + join request entry (Phase 2).
struct DiscoverPickupGameDetailSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let gameId: UUID

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var showJoinComposer = false
    @State private var showInviteComposer = false
    @State private var showPickupChat = false
    @State private var pickupChatConversationId: UUID?
    @State private var pickupChatContext: PickupGameChatContext?
    @State private var isOpeningPickupChat = false
    @State private var pickupChatError: String?
    @State private var showPlayerRoster = false
    @State private var joinError: String?
    @State private var isCancellingRequest = false
    @State private var withdrawConfirm: PickupJoinWithdrawConfirmState?
    @State private var isRequestingDiscoverMapFocus = false
    @State private var mapFocusUnavailableMessage: String?

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var game: PickupGameRow? {
        viewModel.resolvedPickupGameRow(for: gameId)
    }

    private var isCreator: Bool {
        guard let uid = viewModel.currentUserAuthId, let g = game else { return false }
        return g.creator_user_id == uid
    }

    private var myRequest: PickupGameRequestRow? {
        viewModel.pickupMyLatestJoinRequestByGameId[gameId]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let g = game {
                    if viewModel.isGuestDiscoverMode {
                        guestDiscoverPickupDetail(for: g)
                    } else {
                        detailContent(for: g)
                    }
                } else {
                    ContentUnavailableView(
                        "Pickup unavailable",
                        systemImage: "person.3.fill",
                        description: Text("This game may be full or no longer listed.")
                    )
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                }
            }
            .navigationTitle("Pickup game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let g = game, !viewModel.isGuestDiscoverMode {
                        Menu {
                            ShareLink(item: pickupShareText(for: g)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More options")
                    }
                }
            }
            .sheet(isPresented: $showJoinComposer) {
                if let g = game {
                    PickupGameJoinRequestComposerSheet(viewModel: viewModel, pickupGame: g) {
                        showJoinComposer = false
                    }
                }
            }
            .sheet(isPresented: $showInviteComposer) {
                if let g = game {
                    PickupGameInviteFriendsSheet(viewModel: viewModel, game: g)
                }
            }
            .sheet(isPresented: $showPickupChat, onDismiss: {
                pickupChatConversationId = nil
                pickupChatContext = nil
            }) {
                if let conversationId = pickupChatConversationId {
                    NavigationStack {
                        GroupChatView(
                            conversationId: conversationId,
                            chatViewModel: chatViewModel,
                            pickupContext: pickupChatContext
                        )
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Back to game") {
                                    showPickupChat = false
                                }
                            }
                        }
                    }
                    .environmentObject(viewModel)
                }
            }
            .sheet(isPresented: $showPlayerRoster) {
                PickupGameRosterSheet(viewModel: viewModel, pickupGameId: gameId)
                    .environmentObject(viewModel)
            }
            .task(id: gameId) {
                if viewModel.isGuestDiscoverMode {
                    if let g = viewModel.resolvedPickupGameRow(for: gameId) {
                        await viewModel.loadPickupOrganizerTrustStatsForPickupDetail(creatorUserId: g.creator_user_id)
                    }
                    return
                }
                if let cid = game?.creator_user_id {
                    await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: cid)
                }
                await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId)
                await viewModel.loadPickupGameRoster(pickupGameId: gameId, force: true)
                if let g = viewModel.resolvedPickupGameRow(for: gameId) {
                    viewModel.ensurePickupCreatorRatingSessionScoped()
                    await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: g.creator_user_id)
                    await viewModel.refreshPickupCreatorRatingUIContext(
                        pickupGameId: g.id,
                        creatorUserId: g.creator_user_id
                    )
                    let now = Date()
                    let creator = viewModel.currentUserAuthId == g.creator_user_id
                    let actions: String
                    if creator {
                        actions = g.hasPickupGameStarted(now: now)
                            ? "manage_requests,roster_capacity"
                            : "full_edit_before_start"
                    } else {
                        actions = g.hasPickupGameStarted(now: now) ? "view_join_state" : "join_request"
                    }
                    PickupGameStartedStateDebug.log(row: g, now: now, allowedActions: actions)
                }
            }
            .onChange(of: viewModel.pickupGamesForDiscoverMap.count) { _, _ in
                guard !viewModel.isGuestDiscoverMode else { return }
                Task { await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId) }
            }
            .onChange(of: viewModel.pickupJoinRequestUiRevision) { _, _ in
                guard !viewModel.isGuestDiscoverMode else { return }
                Task { await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId) }
            }
            .alert(item: $withdrawConfirm) { state in
                Alert(
                    title: Text(state.intent.alertTitle),
                    message: Text(state.intent.alertMessage),
                    primaryButton: .destructive(Text("Yes, withdraw")) {
                        Task { await performPickupJoinWithdraw(state) }
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert(
                "Map location unavailable",
                isPresented: Binding(
                    get: { mapFocusUnavailableMessage != nil },
                    set: { if !$0 { mapFocusUnavailableMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { mapFocusUnavailableMessage = nil }
            } message: {
                Text(mapFocusUnavailableMessage ?? "This game does not have a map location yet.")
            }
        }
    }

    /// Discover guest session (``MapViewModel/isGuestDiscoverMode``): hides address, time, counts, join, and organizer identity; still shows **public** organizer trust (RPC aggregates only).
    @ViewBuilder
    private func guestDiscoverPickupDetail(for g: PickupGameRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    GameFormatBadgeView(format: g.gameFormat, colorScheme: colorScheme)
                    Text(g.title)
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(pickupDetailMainInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(AppSportCatalog.displayLabel(forSportToken: g.sport)) · \(g.playEnvironmentEnum.shortLabel)")
                        .font(FGTypography.metadata.weight(.medium))
                        .foregroundStyle(pickupDetailSubInk)
                }
                .padding(FGSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }

                PickupCreatorTrustLineView(
                    stats: viewModel.pickupCreatorTrustStats(for: g.creator_user_id),
                    detailAlwaysVisible: true
                )
                .padding(.top, FGSpacing.xs)

                DiscoverGuestGameLockCard {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FGSpacing.lg)
        }
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
    }

    @ViewBuilder
    private func detailContent(for g: PickupGameRow) -> some View {
        let addressPrimary: String? = {
            let trimmed = g.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }()
        let cityStateLine = [g.city, g.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let creatorLabel = viewModel.pickupCreatorDisplayLabel(for: g.creator_user_id)
        let metadataLine = "\(AppSportCatalog.displayLabel(forSportToken: g.sport)) • \(g.playEnvironmentEnum.shortLabel) • \(g.skillLevelEnum.displayTitle)"
        let showStarted = g.hasPickupGameStarted()

        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                pickupHeroCard(
                    g: g,
                    addressPrimary: addressPrimary,
                    cityStateLine: cityStateLine,
                    metadataLine: metadataLine,
                    showStarted: showStarted
                )

                if isCreator, g.isPickupGameInvitable() {
                    pickupInviteActionRow(for: g)
                }

                pickupChatEntrySection(for: g)

                pickupCapacityCard(for: g)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: FGSpacing.sm), GridItem(.flexible(), spacing: FGSpacing.sm)],
                    alignment: .leading,
                    spacing: FGSpacing.sm
                ) {
                    pickupDetailTile(
                        title: "Who’s welcome",
                        value: g.participantAudienceDisplayTitle,
                        systemImage: "person.2.fill"
                    )
                    pickupDetailTile(
                        title: "Cost",
                        value: g.entryFeeDisplayLine,
                        systemImage: "dollarsign.circle.fill"
                    )
                    pickupOrganizerDetailTile(g: g, creatorLabel: creatorLabel)
                    pickupDetailTile(
                        title: "Play",
                        value: g.playEnvironmentEnum.displayTitle,
                        systemImage: "sportscourt.fill"
                    )
                }

                let desc = g.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !desc.isEmpty {
                    Text(desc)
                        .font(FGTypography.body)
                        .foregroundStyle(pickupDetailMainInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(FGSpacing.md)
                        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
                        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.5 : 0.35), lineWidth: 1)
                        }
                }

                if isCreator {
                    pickupInfoBanner(text: "You’re organizing this game.")
                }

                if !isCreator {
                    pickupDetailCreatorRatingSection(for: g)
                }

                joinSection(for: g)

                if let joinError, !joinError.isEmpty {
                    Text(joinError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FGSpacing.lg)
        }
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
    }

    private var pickupDisplayLocale: Locale {
        Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_"))
    }

    /// Localized "Mon D, YYYY" for the hero date row (empty when unparsable).
    private func pickupDateText(for g: PickupGameRow) -> String {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(g.game_start_at) else { return "" }
        return start.formatted(
            Date.FormatStyle.dateTime.month(.abbreviated).day().year().locale(pickupDisplayLocale)
        )
    }

    /// Localized start–end time range (or single start time) for the hero date row.
    private func pickupTimeRangeText(for g: PickupGameRow) -> String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(g.game_start_at) else { return nil }
        let timeStyle = Date.FormatStyle.dateTime.hour().minute().locale(pickupDisplayLocale)
        if let end = PickupGameModels.endDate(for: g), end > start {
            return "\(start.formatted(timeStyle)) – \(end.formatted(timeStyle))"
        }
        return start.formatted(timeStyle)
    }

    /// Compact duration derived from existing start/end (e.g. "2h", "1h 30m", "45m").
    private func pickupDurationText(for g: PickupGameRow) -> String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(g.game_start_at),
              let end = PickupGameModels.endDate(for: g), end > start else { return nil }
        let totalMinutes = Int((end.timeIntervalSince(start) / 60).rounded())
        guard totalMinutes > 0 else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 && minutes == 0 { return "\(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var pickupDetailMainInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
    }

    private var pickupDetailSubInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : FGColor.secondaryText(colorScheme)
    }

    @ViewBuilder
    private func pickupGlassBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.38 : 0.07),
                    Color.black.opacity(colorScheme == .dark ? 0.18 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private func pickupGlassStroke(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
    }

    /// One cohesive three-column capacity card (Spots · Players · Playing) with thin separators.
    /// Spots/Players remain joiner-capacity math; Playing = organizer + approved joiners.
    private func pickupCapacityCard(for g: PickupGameRow) -> some View {
        let roster = viewModel.pickupGameRosterByGameId[g.id]
        let playingCount = roster?.playingTotal
            ?? PickupGameRosterPresentation.playingDisplayCount(approvedJoinCount: g.approvedJoinCount)
        let stackMembers = roster?.stackMembers ?? fallbackOrganizerStack(for: g)

        return HStack(alignment: .top, spacing: 0) {
            pickupCapacityColumn(
                title: "Spots",
                value: "\(g.pickupOpenSlotsRemaining) left",
                secondary: "of \(g.playersNeededClamped)",
                systemImage: "person.3.sequence",
                tint: FGColor.accentBlue
            )
            pickupCapacityDivider
            pickupCapacityColumn(
                title: "Players",
                value: "\(g.playersNeededClamped) needed",
                secondary: "to start",
                systemImage: "person.badge.plus",
                tint: FGColor.accentGreen
            )
            pickupCapacityDivider
            Button {
                showPlayerRoster = true
            } label: {
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FGColor.accentYellow)
                        Text("Playing")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(pickupDetailSubInk)
                    }
                    Text("\(playingCount)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(pickupDetailMainInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !stackMembers.isEmpty {
                        PickupPlayingAvatarStack(members: stackMembers, diameter: 20)
                            .padding(.top, 1)
                    } else {
                        Text(playingCount == 1 ? "player" : "players")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, FGSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Playing, \(playingCount) \(playingCount == 1 ? "player" : "players")")
            .accessibilityHint("Shows who is playing in this pickup game")
            .accessibilityAddTraits(.isButton)
        }
        .padding(.vertical, FGSpacing.md)
        .padding(.horizontal, FGSpacing.sm)
        .frame(maxWidth: .infinity)
        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
    }

    /// Before the roster RPC returns, show at least the organizer avatar from cached creator fields.
    private func fallbackOrganizerStack(for g: PickupGameRow) -> [PickupGameRosterMember] {
        let uid = g.creator_user_id
        let name = viewModel.pickupCreatorDisplayLabel(for: uid)
        return [
            PickupGameRosterMember(
                user_id: uid,
                request_id: nil,
                display_name: name,
                username: nil,
                avatar_url: viewModel.pickupOrganizerAvatarFullForDetail(userId: uid),
                avatar_thumbnail_url: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: uid),
                role: "organizer",
                status: nil
            )
        ]
    }

    private func pickupCapacityColumn(
        title: String,
        value: String,
        secondary: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(pickupDetailSubInk)
            }
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(pickupDetailMainInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(secondary)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, FGSpacing.xs)
    }

    private var pickupCapacityDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.5 : 0.4))
            .frame(width: 1)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    private func pickupDetailTile(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.95 : 0.88))
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(pickupDetailSubInk)
            }
            Text(value)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(pickupDetailMainInk)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.sm + 2)
        .background { pickupGlassBackground(cornerRadius: FGRadius.medium) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.medium) }
    }

    private func pickupOrganizerDetailTile(g: PickupGameRow, creatorLabel: String?) -> some View {
        let uid = g.creator_user_id
        let displayName = (creatorLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shownName = displayName.isEmpty ? "—" : displayName
        let thumb = viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: uid)
        let full = viewModel.pickupOrganizerAvatarFullForDetail(userId: uid)
        let token = viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: uid)
        let avatarFallback: UserAvatarView.FallbackStyle = colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
        let summary = viewModel.pickupOrganizerSummary(for: uid)
        let summaryInFlight = viewModel.pickupOrganizerSummaryInFlightUserIds.contains(uid)

        return Button {
            viewModel.presentPublicProfile(
                userId: uid,
                context: "pickup_detail_organizer",
                isSelfPreview: uid == viewModel.currentUserAuthId
            )
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    UserAvatarView(
                        avatarThumbnailURL: thumb,
                        avatarURL: full,
                        avatarDisplayRefreshToken: token,
                        displayName: displayName.isEmpty ? shownName : displayName,
                        email: "",
                        size: 40,
                        fallbackStyle: avatarFallback,
                        imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                    )
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Organizer", languageCode: languageCode))
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(pickupDetailSubInk)
                        Text(shownName)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(pickupDetailMainInk)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())

                if let summary {
                    pickupOrganizerSummaryLines(summary)
                } else if summaryInFlight {
                    // Keep identity visible; omit counts until authoritative summary arrives (no “New organizer” flash).
                    Color.clear.frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, FGSpacing.sm + 2)
            .padding(.top, FGSpacing.sm + 2)
            .padding(.bottom, FGSpacing.md)
            .background { pickupGlassBackground(cornerRadius: FGRadius.medium) }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            .overlay { pickupGlassStroke(cornerRadius: FGRadius.medium) }
            .contentShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pickupOrganizerDetailAccessibilityLabel(displayName: shownName, summary: summary))
        .accessibilityHint(L10n.t("live_pickup_organizer_a11y_hint", languageCode: languageCode))
    }

    @ViewBuilder
    private func pickupOrganizerSummaryLines(_ summary: PickupOrganizerSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.summaryLine(languageCode: languageCode))
                .font(FGTypography.caption.weight(.medium))
                .foregroundStyle(pickupDetailSubInk)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            if let recency = summary.recencyLine(languageCode: languageCode) {
                Text(recency)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func pickupOrganizerDetailAccessibilityLabel(
        displayName: String,
        summary: PickupOrganizerSummary?
    ) -> String {
        let organizerWord = L10n.t("Organizer", languageCode: languageCode)
        let identity = "\(organizerWord) \(displayName)"
        guard let summary else { return identity }
        let summaryA11y = summary.accessibilityLabel(languageCode: languageCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if summaryA11y.isEmpty { return identity }
        // Drop the leading “Organizer.” title from the summary a11y string when present.
        let title = L10n.t("pickup_organizer_title", languageCode: languageCode)
        let trimmedSummary: String = {
            if summaryA11y.lowercased().hasPrefix(title.lowercased()) {
                let rest = summaryA11y.dropFirst(title.count).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                return rest
            }
            return summaryA11y
        }()
        return trimmedSummary.isEmpty ? identity : "\(identity). \(trimmedSummary)"
    }

    @ViewBuilder
    private func pickupDetailCreatorRatingSection(for g: PickupGameRow) -> some View {
        let joinStatus = myRequest?.status
            ?? viewModel.pickupJoinRequestLatestByPickupGameIdForFan[g.id]?.status
        if viewModel.hasSubmittedPickupCreatorRating(for: g.id) {
            PickupCreatorRateOrganizerHistoryRow(
                viewModel: viewModel,
                game: g,
                joinStatus: joinStatus ?? "approved"
            )
        } else if viewModel.shouldPresentPickupCreatorRatingPrompt(game: g, joinStatus: joinStatus) {
            PickupCreatorRatingPromptCard(viewModel: viewModel, game: g)
        } else if viewModel.shouldShowPickupCreatorRateOrganizerAction(game: g, joinStatus: joinStatus) {
            PickupCreatorRateOrganizerHistoryRow(
                viewModel: viewModel,
                game: g,
                joinStatus: joinStatus
            )
        }
    }

    private func pickupInfoBanner(text: String) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundStyle(FGColor.accentBlue)
            Text(text)
                .font(FGTypography.metadata.weight(.medium))
                .foregroundStyle(pickupDetailMainInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(FGSpacing.md)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.35 : 0.28), lineWidth: 1)
        }
    }

    private func pickupHeroCard(
        g: PickupGameRow,
        addressPrimary: String?,
        cityStateLine: String,
        metadataLine: String,
        showStarted: Bool
    ) -> some View {
        let hasUsableMapCoordinate = Self.pickupHasUsableMapCoordinate(g)
        let dateText = pickupDateText(for: g)
        let timeRange = pickupTimeRangeText(for: g)
        let duration = pickupDurationText(for: g)
        let timeSecondary: String? = {
            guard let timeRange, !timeRange.isEmpty else { return nil }
            if let duration, !duration.isEmpty { return "\(timeRange) (\(duration))" }
            return timeRange
        }()
        let locationPrimary = addressPrimary ?? (cityStateLine.isEmpty ? nil : cityStateLine)
        let locationSecondary = addressPrimary == nil ? nil : (cityStateLine.isEmpty ? nil : cityStateLine)
        let hasDateRow = !dateText.isEmpty || (timeSecondary != nil)
        let hasLocationRow = locationPrimary != nil

        return VStack(alignment: .leading, spacing: FGSpacing.md) {
            Button {
                showPickupOnDiscoverMap(g)
            } label: {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    PickupGameStartedSportGlyphFrame(showStarted: showStarted) {
                        SportArtworkIconView(sport: g.sport, diameter: 52)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        GameFormatBadgeView(format: g.gameFormat, colorScheme: colorScheme)
                            .accessibilityHidden(true)

                        Text(g.title)
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(pickupDetailMainInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(metadataLine)
                            .font(FGTypography.metadata.weight(.medium))
                            .foregroundStyle(pickupDetailSubInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if showStarted {
                            PickupGameStartedLineCaption()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRequestingDiscoverMapFocus)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                String(
                    format: L10n.t("discover_pickup_show_on_map_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    g.title
                )
            )
            .accessibilityHint(L10n.t("discover_pickup_show_on_map_a11y_hint", languageCode: languageCode))
            .accessibilityAddTraits(.isButton)

            if hasDateRow || hasLocationRow {
                VStack(spacing: 0) {
                    if hasDateRow {
                        pickupHeroInfoRow(
                            systemImage: "calendar",
                            tint: FGColor.accentBlue,
                            primary: dateText.isEmpty ? (timeSecondary ?? "") : dateText,
                            secondary: dateText.isEmpty ? nil : timeSecondary
                        )
                    }
                    if hasDateRow && hasLocationRow {
                        Rectangle()
                            .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.35))
                            .frame(height: 1)
                            .padding(.leading, 48 + FGSpacing.md)
                            .accessibilityHidden(true)
                    }
                    if hasLocationRow, let locationPrimary {
                        pickupHeroInfoRow(
                            systemImage: "mappin.and.ellipse",
                            tint: FGColor.accentGreen,
                            primary: locationPrimary,
                            secondary: locationSecondary
                        )
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.3), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            }

            if hasUsableMapCoordinate, let lat = g.latitude, let lon = g.longitude {
                Button {
                    if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                        openURL(url)
                    }
                } label: {
                    Label("Directions", systemImage: "map")
                        .font(FGTypography.metadata.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(FGColor.accentBlue)
                .controlSize(.large)
            }
        }
        .padding(FGSpacing.lg)
        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
    }

    /// Icon-in-tinted-circle info row for the hero date/time and location surfaces.
    private func pickupHeroInfoRow(
        systemImage: String,
        tint: Color,
        primary: String,
        secondary: String?
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                Circle()
                    .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, alignment: .center)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(pickupDetailMainInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(FGTypography.caption)
                        .foregroundStyle(pickupDetailSubInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .accessibilityElement(children: .combine)
    }

    private static func pickupHasUsableMapCoordinate(_ g: PickupGameRow) -> Bool {
        guard let lat = g.latitude, let lon = g.longitude else { return false }
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else {
            return false
        }
        if abs(lat) < 1e-5 && abs(lon) < 1e-5 { return false }
        return abs(lat) <= 90 && abs(lon) <= 180
    }

    /// Dismiss detail → Discover tab → focus existing pickup annotation (no nested map, no sheet reopen loop).
    private func showPickupOnDiscoverMap(_ g: PickupGameRow) {
        guard !isRequestingDiscoverMapFocus else { return }
        guard Self.pickupHasUsableMapCoordinate(g) else {
            mapFocusUnavailableMessage = "This game does not have a map location yet."
            viewModel.followingMapNavigationMessage = mapFocusUnavailableMessage
            return
        }

        isRequestingDiscoverMapFocus = true
        dismiss()

        Task { @MainActor in
            // Let the detail sheet finish dismissing before focusing Discover (avoids reopen loops).
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)

            if viewModel.discoverMapContentMode != .pickupGames {
                viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .pickupGames)
                viewModel.discoverMapContentMode = .pickupGames
            }
            if viewModel.discoverPickupSubMode != .games {
                viewModel.discoverPickupSubMode = .games
            }

            // Clear any prior pending id so onChange always fires for this explicit user action.
            if viewModel.pendingFollowingMapPickupGameID != nil {
                viewModel.pendingFollowingMapPickupGameID = nil
                viewModel.pendingFollowingMapPickupGameSnapshot = nil
                await Task.yield()
            }

            viewModel.requestDiscoverFocusForPickupGame(id: g.id, snapshot: g)
            isRequestingDiscoverMapFocus = false
        }
    }

    private var canAccessPickupGameChat: Bool {
        PickupGameChatAccessPolicy.canAccess(
            isAuthenticated: viewModel.isAuthenticatedForSocialFeatures,
            isCreator: isCreator,
            joinRequestStatus: myRequest?.status
        )
    }

    private var showsPickupChatLockedHint: Bool {
        PickupGameChatAccessPolicy.showsLockedHint(
            isAuthenticated: viewModel.isAuthenticatedForSocialFeatures,
            isCreator: isCreator,
            joinRequestStatus: myRequest?.status
        )
    }

    @ViewBuilder
    private func pickupChatEntrySection(for g: PickupGameRow) -> some View {
        if canAccessPickupGameChat {
            Button {
                Task { await openPickupGameChat(for: g) }
            } label: {
                pickupTintedActionLabel(
                    title: isOpeningPickupChat ? "Opening chat…" : "Chat",
                    systemImage: "bubble.left.and.bubble.right.fill",
                    tint: FGColor.accentGreen
                )
            }
            .buttonStyle(.plain)
            .disabled(isOpeningPickupChat)
            .accessibilityLabel("Open pickup game chat")
            .accessibilityHint("Opens the private chat for approved players of this pickup game")

            if let pickupChatError, !pickupChatError.isEmpty {
                Text(pickupChatError)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.dangerRed)
            }
        } else if showsPickupChatLockedHint {
            HStack(spacing: FGSpacing.sm) {
                Image(systemName: "lock.fill")
                    .font(.caption.weight(.semibold))
                Text("Chat available to approved players")
                    .font(FGTypography.caption.weight(.medium))
            }
            .foregroundStyle(pickupDetailSubInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FGSpacing.xs)
            .accessibilityLabel("Chat available to approved players")
        }
    }

    @MainActor
    private func openPickupGameChat(for g: PickupGameRow) async {
        guard canAccessPickupGameChat else { return }
        // Client gate only — server RLS/RPC re-checks authorization.
        isOpeningPickupChat = true
        pickupChatError = nil
        defer { isOpeningPickupChat = false }
        do {
            let conversationId = try await GroupChatService().ensurePickupGameConversation(pickupGameId: g.id)
            pickupChatConversationId = conversationId
            pickupChatContext = makePickupGameChatContext(for: g)
            showPickupChat = true
#if DEBUG
            print("[PickupGameChat] opened gameId=\(g.id.uuidString.lowercased()) conversationId=\(conversationId.uuidString.lowercased())")
#endif
        } catch {
            pickupChatError = Self.userFacingPickupChatOpenError(error)
#if DEBUG
            print("[PickupGameChat] openFailed gameId=\(g.id.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
        }
    }

    private func makePickupGameChatContext(for g: PickupGameRow) -> PickupGameChatContext {
        let title = {
            let raw = g.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
            return AppSportCatalog.displayLabel(forSportToken: g.sport)
        }()
        let when: String = {
            let date = pickupDateText(for: g)
            let time = pickupTimeRangeText(for: g) ?? ""
            if date.isEmpty { return time }
            if time.isEmpty { return date }
            return "\(date) · \(time)"
        }()
        let location: String? = {
            let parts = [g.address, g.city, g.state]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }()
        // Organizer + approved joiners (approved_join_count is joiners only).
        let approvedCount = max(0, g.approved_join_count ?? 0) + 1
        return PickupGameChatContext(
            pickupGameId: g.id,
            title: title,
            sportLabel: AppSportCatalog.displayLabel(forSportToken: g.sport),
            whenLabel: when,
            locationLabel: location,
            approvedParticipantCount: approvedCount
        )
    }

    private static func userFacingPickupChatOpenError(_ error: Error) -> String {
        let raw = String(describing: error).lowercased()
        if raw.contains("not authorized") || raw.contains("42501") {
            return "Chat is only available to the organizer and approved players."
        }
        if raw.contains("age") {
            return "Chat is unavailable for this account right now."
        }
        return "Couldn't open pickup chat. Try again."
    }

    private func pickupInviteActionRow(for g: PickupGameRow) -> some View {
        HStack(spacing: FGSpacing.md) {
            ShareLink(item: pickupShareText(for: g)) {
                pickupTintedActionLabel(title: "Share", systemImage: "square.and.arrow.up", tint: FGColor.accentBlue)
            }
            .buttonStyle(.plain)

            Button {
                showInviteComposer = true
            } label: {
                pickupTintedActionLabel(title: "Invite friends", systemImage: "person.badge.plus", tint: Color.orange)
            }
            .buttonStyle(.plain)
        }
    }

    /// Large equal-width rounded action button used for Share (blue) / Invite friends (orange).
    private func pickupTintedActionLabel(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(FGTypography.metadata.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.20 : 0.11))
            }
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.42 : 0.26), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    }

    private func pickupShareText(for g: PickupGameRow) -> String {
        var lines = ["Join \(g.title) on FanGeo."]
        if let date = g.pickupDateWithCompactTimeRange(languageCode: languageCode) {
            lines.append(date)
        }
        let location = [g.address, g.city, g.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !location.isEmpty {
            lines.append(location)
        }
        return lines.joined(separator: "\n")
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text(title)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.68) : FGColor.mutedText(colorScheme))
            Text(value)
                .font(FGTypography.body)
                .foregroundStyle(pickupDetailMainInk)
        }
    }

    @ViewBuilder
    private func joinSection(for g: PickupGameRow) -> some View {
        if !viewModel.isAuthenticatedForSocialFeatures {
            Text("Sign in to request to join this pickup game.")
                .font(FGTypography.caption)
                .foregroundStyle(pickupDetailSubInk)
                .padding(.top, FGSpacing.xs)
        } else if !viewModel.canJoinPickupGames {
            Text(BusinessFanGateCopy.pickupFanOnly)
                .font(FGTypography.caption)
                .foregroundStyle(pickupDetailSubInk)
                .padding(.top, FGSpacing.xs)
        } else if isCreator {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                if let req = myRequest {
                    labeledRow(
                        "Your request",
                        req.statusDisplayTitle(languageCode: appLanguageRaw)
                    )
                    let st = req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if st == "pending" {
                        Button(role: .destructive) {
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(gameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(req.id.uuidString.lowercased())")
#endif
                            withdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: req.id,
                                pickupGameId: gameId,
                                intent: .pending
                            )
                        } label: {
                            if isCancellingRequest {
                                ProgressView()
                            } else {
                                Text("Withdraw request")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(isCancellingRequest)
                    } else if st == "approved" {
                        Button(role: .destructive) {
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(gameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(req.id.uuidString.lowercased())")
#endif
                            withdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: req.id,
                                pickupGameId: gameId,
                                intent: .approved
                            )
                        } label: {
                            if isCancellingRequest {
                                ProgressView()
                            } else {
                                Text("Can’t make it")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(isCancellingRequest)
                    } else if st == "rejected" {
                        Button(role: .destructive) {
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(gameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(req.id.uuidString.lowercased())")
#endif
                            withdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: req.id,
                                pickupGameId: gameId,
                                intent: .declined
                            )
                        } label: {
                            if isCancellingRequest {
                                ProgressView()
                            } else {
                                Text("Remove from list")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(isCancellingRequest)
                    }
                }
                if shouldShowRequestToJoin(for: g) {
                    Button {
                        joinError = nil
                        showJoinComposer = true
                    } label: {
                        Text("Request to Join")
                            .font(FGTypography.cardTitle.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentBlue)
                    .controlSize(.large)

                    Label("You’ll be visible to other players once you join.", systemImage: "lock.fill")
                        .font(FGTypography.caption)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                } else if myRequest == nil, g.isPickupFullForDiscover {
                    Text("No more players needed.")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(pickupDetailSubInk)
                }
            }
            .padding(.top, FGSpacing.sm)
        }
    }

    private func performPickupJoinWithdraw(_ state: PickupJoinWithdrawConfirmState) async {
        isCancellingRequest = true
        joinError = nil
        defer {
            isCancellingRequest = false
            withdrawConfirm = nil
        }
        do {
            try await viewModel.withdrawMyPickupJoinRequest(requestId: state.requestId, pickupGameId: state.pickupGameId)
        } catch {
            joinError = error.localizedDescription
        }
    }

    private func shouldShowRequestToJoin(for g: PickupGameRow) -> Bool {
        guard !g.isPickupFullForDiscover else { return false }
        guard let req = myRequest else { return true }
        let s = req.status.lowercased()
        return s == "rejected" || s == "cancelled" || s == "withdrawn"
    }
}

struct PickupGameInviteFriendsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    /// Selected invitee profile/auth user IDs only (`UserPreview.id` / search `user_id`). Never conversation IDs.
    @State private var selectedInviteeUserIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var searchResults: [PickupInvitableFanSearchResult] = []
    @State private var inviteStatusByUserId: [UUID: String] = [:]
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var isSending = false
    @State private var errorText: String?

    private var eligibleFriends: [ChatViewModel.FriendDisplay] {
        var seenProfileIds = Set<UUID>()
        let sorted = chatViewModel.friends.sorted {
            $0.preview.displayName.localizedCaseInsensitiveCompare($1.preview.displayName) == .orderedAscending
        }
        var result: [ChatViewModel.FriendDisplay] = []
        result.reserveCapacity(sorted.count)
        for friend in sorted {
            let profileId = friend.preview.id
            guard profileId != viewModel.currentUserAuthId else { continue }
            guard !chatViewModel.isEitherDirectionBlocked(with: profileId) else { continue }
            guard seenProfileIds.insert(profileId).inserted else { continue }
            result.append(friend)
        }
        return result
    }

    private var canSend: Bool {
        !selectedInviteeUserIds.isEmpty && !isSending && game.isPickupGameInvitable()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inviteHeader

                List {
                    Section {
                        if eligibleFriends.isEmpty {
                            Text("No friends to invite yet")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(eligibleFriends) { friend in
                                pickupInviteFriendRow(friend)
                            }
                        }
                    } header: {
                        Text("Friends")
                    } footer: {
                        Text("\(selectedInviteeUserIds.count)/20 selected")
                    }

                    Section {
                        TextField("Search fans by @handle or name", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Invite non-friends")
                    } footer: {
                        Text("Optional. Search FanGeo users by handle or display name.")
                    }

                    Section {
                        if isSearching {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching fans...")
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                        } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                            Text("Type at least 2 characters to search FanGeo users.")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else if searchResults.isEmpty {
                            Text("No fans found")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(searchResults) { result in
                                pickupInviteSearchResultRow(result)
                            }
                        }
                    } header: {
                        Text("Search Results")
                    }
                }
                .scrollContentBackground(.hidden)

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FGSpacing.lg)
                        .padding(.vertical, FGSpacing.sm)
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle("Invite friends to play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await sendInvites() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .task {
                if chatViewModel.friends.isEmpty {
                    await chatViewModel.refresh()
                }
                inviteStatusByUserId = await viewModel.loadPickupInviteStatusesByInviteeUserId(gameId: game.id)
            }
            .onChange(of: searchText) { _, newValue in
                scheduleFanSearch(newValue)
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    private var inviteHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SportArtworkIconView(sport: game.sport, diameter: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text("\(AppSportCatalog.displayLabel(forSportToken: game.sport)) · \(game.gameFormat.displayTitle)")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    if let dateLine = game.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw) {
                        Text(dateLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
            }
            if !game.isPickupGameInvitable() {
                Text("This game is no longer accepting invites.")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.lg)
        .background(.ultraThinMaterial)
    }

    private func pickupInviteFriendRow(_ friend: ChatViewModel.FriendDisplay) -> some View {
        let profileId = friend.preview.id
        let inviteStatus = inviteStatusByUserId[profileId]
        let disabled = inviteStatus != nil
        let isSelected = selectedInviteeUserIds.contains(profileId)
        return Button {
            toggleInviteeUserId(profileId)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(preview: friend.preview, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.preview.displayName)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    if let username = friend.preview.username, !username.isEmpty {
                        Text("@\(username)")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if let inviteStatus {
                        pickupInviteStatusBadge(status: inviteStatus)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: disabled ? "checkmark.seal.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(disabled ? Color.orange : (isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
    }

    private func pickupInviteSearchResultRow(_ result: PickupInvitableFanSearchResult) -> some View {
        let profileId = result.user_id
        let inviteStatus = inviteStatusByUserId[profileId]
        let disabled = inviteStatus != nil
        let isSelected = selectedInviteeUserIds.contains(profileId)
        return Button {
            toggleSearchResult(result)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(preview: result.userPreview, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.display_name)
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        if result.is_friend {
                            Text("Friend")
                                .font(FGTypography.caption.weight(.bold))
                                .foregroundStyle(FGColor.accentGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FGColor.accentGreen.opacity(0.12), in: Capsule())
                        }
                    }
                    if !result.displayHandle.isEmpty {
                        Text(result.displayHandle)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if let inviteStatus {
                        pickupInviteStatusBadge(status: inviteStatus)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: disabled ? "checkmark.seal.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(disabled ? Color.orange : (isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
    }

    private func toggleInviteeUserId(_ profileUserId: UUID) {
        guard inviteStatusByUserId[profileUserId] == nil else { return }
        if selectedInviteeUserIds.contains(profileUserId) {
            selectedInviteeUserIds.remove(profileUserId)
        } else if selectedInviteeUserIds.count < 20 {
            selectedInviteeUserIds.insert(profileUserId)
        } else {
            errorText = "You can invite up to 20 people per game."
        }
    }

    private func toggleSearchResult(_ result: PickupInvitableFanSearchResult) {
        let profileId = result.user_id
        guard inviteStatusByUserId[profileId] == nil else { return }
        let wasSelected = selectedInviteeUserIds.contains(profileId)
        toggleInviteeUserId(profileId)
#if DEBUG
        if !result.is_friend, !wasSelected, selectedInviteeUserIds.contains(profileId) {
            print("[PickupInviteDebug] nonFriendInviteSelected=\(profileId.uuidString.lowercased()) idSource=preview")
        }
#endif
    }

    private func pickupInviteStatusBadge(status: String) -> some View {
        let display = pickupInviteStatusDisplay(status)
        return Text(display.title)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(display.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(display.tint.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(display.tint.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 0.8)
            }
    }

    private func pickupInviteStatusDisplay(_ status: String) -> (title: String, tint: Color) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending":
            return ("Pending invite", FGColor.secondaryText(colorScheme))
        case "accepted":
            return ("Accepted", FGColor.accentGreen)
        case "maybe":
            return ("Maybe", Color.orange)
        case "declined":
            return ("Declined", colorScheme == .dark ? Color.red.opacity(0.74) : Color.red.opacity(0.68))
        default:
            return ("Already invited", Color.orange)
        }
    }

    private func scheduleFanSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            isSearching = false
            searchResults = []
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let results = await viewModel.searchPickupInvitableFans(query: trimmed, limit: 20)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }

    private func sendInvites() async {
        guard canSend else { return }
        isSending = true
        errorText = nil
        defer { isSending = false }

        // Profile/auth user IDs only — never FriendDisplay.id / conversation IDs.
        let recipientIds = Array(selectedInviteeUserIds)
#if DEBUG
        print("[PickupInviteDebug] sendTapped gameId=\(game.id.uuidString.lowercased())")
        print("[PickupInviteDebug] senderId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil")")
        print("[PickupInviteDebug] recipientCount=\(recipientIds.count)")
        print("[PickupInviteDebug] recipientIds=\(recipientIds.map { $0.uuidString.lowercased() }.joined(separator: ","))")
        print("[PickupInviteDebug] idSource=preview")
        for friend in eligibleFriends where selectedInviteeUserIds.contains(friend.preview.id) {
            print(
                "[PickupInviteDebug] selectedFriendRow previewId=\(friend.preview.id.uuidString.lowercased()) friendDisplayId=\(friend.id.uuidString.lowercased()) idSource=preview"
            )
        }
        for result in searchResults where selectedInviteeUserIds.contains(result.user_id) {
            print(
                "[PickupInviteDebug] selectedSearchRow userId=\(result.user_id.uuidString.lowercased()) isFriend=\(result.is_friend) idSource=preview"
            )
        }
#endif

        let results = await viewModel.createPickupGameInvites(
            game: game,
            inviteeUserIds: recipientIds,
            message: nil
        )
        let created = results.filter { $0.outcome == "created" }.count
        let duplicates = results.filter { $0.outcome == "duplicate" }.count
        let skipped = results.filter { $0.outcome == "skipped" }.count
        let maxReached = results.filter { $0.outcome == "max_reached" }.count
#if DEBUG
        print("[PickupInviteDebug] sendUI created=\(created) duplicates=\(duplicates) skipped=\(skipped) maxReached=\(maxReached)")
#endif
        if created > 0 || duplicates > 0 {
            dismiss()
        } else {
            // Soft outcomes (skipped/max_reached/empty) keep the existing generic failure copy.
            errorText = "No invites were sent. Try again."
#if DEBUG
            print("[PickupInviteDebug] uiSwallowedDetail showingGenericNoInvites=true")
#endif
        }
    }
}

/// Skill + optional message before creating `pickup_game_requests`.
struct PickupGameJoinRequestComposerSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let pickupGame: PickupGameRow
    var onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage("pickup_chat_privacy_tip_dismissed.v1") private var privacyTipDismissed = false

    @State private var skill: PickupGameSkillLevel = .casual
    @State private var message: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Your skill level for this game") {
                    Picker("Skill", selection: $skill) {
                        ForEach(PickupGameSkillLevel.allCases) { level in
                            Text(level.displayTitle).tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section("Safety") {
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(FGColor.accentYellow)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        Text("Pickup games and meetups involve physical activity and real-world interaction. Participate at your own risk and use good judgment.")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Optional message") {
                    TextField("Short intro (optional)", text: $message, axis: .vertical)
                        .lineLimit(3...6)

                    if !privacyTipDismissed {
                        pickupChatPrivacyTip
                    }
                }
                if let errorText, !errorText.isEmpty {
                    Section {
                        Text(errorText)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.dangerRed)
                    }
                }
            }
            .navigationTitle("Request to join")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onFinished()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || !viewModel.canJoinPickupGames)
                }
            }
        }
    }

    private var pickupChatPrivacyTip: some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        return HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(L10n.t("pickup_chat_privacy_note", languageCode: languageCode))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                privacyTipDismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("pickup_chat_privacy_tip_dismiss_a11y", languageCode: languageCode))
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("pickup_chat_privacy_note", languageCode: languageCode))
    }

    private func submit() async {
        guard viewModel.canJoinPickupGames else {
            viewModel.logBusinessUserGateBlocked(action: "joinPickupGame")
            errorText = BusinessFanGateCopy.pickupFanOnly
            return
        }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            try await viewModel.createPickupJoinRequest(
                pickupGameId: pickupGame.id,
                requesterSkillLevel: skill.rawValue,
                message: message
            )
            onFinished()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Settings → My pickup games → manage join requests for one game.
struct PickupOrganizerRequestsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [PickupGameRequestRow] = []
    @State private var loadError: String?
    @State private var busyRequestId: UUID?

    private var useCompactRequestCopy: Bool {
        horizontalSizeClass == .compact
    }

    private var pendingRows: [PickupGameRequestRow] {
        rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending" }
            .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    private var approvedRows: [PickupGameRequestRow] {
        rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "approved" }
            .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    private var rejectedRows: [PickupGameRequestRow] {
        rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rejected" }
            .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    private var withdrawnRows: [PickupGameRequestRow] {
        rows.filter {
            let s = $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return s == "cancelled" || s == "withdrawn"
        }
        .sorted { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
    }

    var body: some View {
        NavigationStack {
            List {
                if let loadError, !loadError.isEmpty {
                    Text(loadError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .listRowBackground(Color.clear)
                }
                if rows.isEmpty && loadError == nil {
                    Text("No requests yet.")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(Color.clear)
                }
                if !pendingRows.isEmpty {
                    Section {
                        ForEach(pendingRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Pending")
                            .textCase(nil)
                    }
                }
                if !approvedRows.isEmpty {
                    Section {
                        ForEach(approvedRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Approved")
                            .textCase(nil)
                    }
                }
                if !rejectedRows.isEmpty {
                    Section {
                        ForEach(rejectedRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Rejected")
                            .textCase(nil)
                    }
                }
                if !withdrawnRows.isEmpty {
                    Section {
                        ForEach(withdrawnRows) { req in
                            organizerRequestCard(req)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Can’t make it")
                            .textCase(nil)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
            .onChange(of: viewModel.pickupOrganizerRequestsSyncGeneration) { _, _ in
                Task { await reload() }
            }
            .onAppear {
                PickupGameStartedStateDebug.log(
                    row: game,
                    now: Date(),
                    allowedActions: "approve,reject,remove_players"
                )
            }
        }
    }

    @ViewBuilder
    private func pickupJoinRequestStatusPill(_ status: String) -> some View {
        switch status.lowercased() {
        case "pending":
            FGStatusPill(title: "Pending", kind: .custom(tint: Color.orange))
        case "approved":
            FGStatusPill(title: "Approved", kind: .approved)
        case "rejected":
            FGStatusPill(title: "Rejected", kind: .rejected)
        case "cancelled":
            FGStatusPill(title: "Withdrawn", kind: .custom(tint: FGColor.mutedText(colorScheme)))
        case "withdrawn":
            FGStatusPill(title: "Withdrawn", kind: .custom(tint: FGColor.mutedText(colorScheme)))
        default:
            FGStatusPill(title: status.capitalized, kind: .custom(tint: FGColor.mutedText(colorScheme)))
        }
    }

    @ViewBuilder
    private func organizerRequestCard(_ req: PickupGameRequestRow) -> some View {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[req.requester_user_id]
        let profileName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = profileName.isEmpty ? req.requesterNameForUI : profileName
        let emailLine = (profile?.email ?? req.requester_email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let fullRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb: String? = thumbRaw.isEmpty ? nil : thumbRaw
        let full = fullRaw.isEmpty ? "" : fullRaw
        let token = viewModel.pickupJoinRequesterAvatarTokenByUserId[req.requester_user_id] ?? UUID()
        let isPending = req.status.lowercased() == "pending"
        let isTerminal = !isPending

        VStack(alignment: .leading, spacing: FGSpacing.md) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                PublicProfileAvatarTap(
                    userId: req.requester_user_id,
                    context: "pickup_join_request",
                    activeSheet: "manage_requests"
                ) {
                    UserAvatarView(
                        avatarThumbnailURL: thumb,
                        avatarURL: full,
                        avatarDisplayRefreshToken: token,
                        displayName: displayName,
                        email: emailLine,
                        size: 56,
                        fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome,
                        imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: FGSpacing.sm) {
                        Text(displayName)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        pickupJoinRequestStatusPill(req.status)
                    }

                    Text(req.organizerRequestedCaption(compactWidth: useCompactRequestCopy))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    Text(req.organizerDecisionStatusCaption(compactWidth: useCompactRequestCopy))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(isTerminal ? FGColor.secondaryText(colorScheme) : Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.88))

                    Text(req.requesterSkillLevelEnum.displayTitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    if let m = req.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                        Text(m)
                            .font(FGTypography.body)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .padding(FGSpacing.sm + 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.55))
                            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                    }
                }
            }

            if isPending {
                HStack(spacing: FGSpacing.sm) {
                    Button {
                        Task { await decide(req, approve: true) }
                    } label: {
                        if busyRequestId == req.id {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Approve")
                                .font(FGTypography.metadata.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentGreen)
                    .disabled(busyRequestId != nil)

                    Button(role: .destructive) {
                        Task { await decide(req, approve: false) }
                    } label: {
                        Text("Reject")
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busyRequestId != nil)
                }
            }
        }
        .padding(FGSpacing.lg)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
            }
        }
        .opacity(isTerminal ? 0.92 : 1)
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        loadError = nil
        do {
            let next = try await viewModel.fetchOrganizerPickupRequests(pickupGameId: game.id)
            rows = next
            await viewModel.loadPickupJoinRequesterProfilesForOrganizerSheet(
                requesterIds: Set(next.map(\.requester_user_id))
            )
        } catch {
            loadError = error.localizedDescription
            rows = []
        }
        await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
    }

    private func decide(_ req: PickupGameRequestRow, approve: Bool) async {
        busyRequestId = req.id
        loadError = nil
        defer { busyRequestId = nil }
        do {
            if approve {
                try await viewModel.approvePickupJoinRequest(requestId: req.id, pickupGameId: game.id)
            } else {
                try await viewModel.rejectPickupJoinRequest(requestId: req.id, pickupGameId: game.id)
            }
            await reload()
            await viewModel.loadMyPickupGamesForSettings()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

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
    @State private var showTeamAttendanceRoster = false
    @State private var joinError: String?
    @State private var isCancellingRequest = false
    @State private var withdrawConfirm: PickupJoinWithdrawConfirmState?
    @State private var isRequestingDiscoverMapFocus = false
    @State private var mapFocusUnavailableMessage: String?
    @State private var isLoadingSharedPickupDetail = false
    @State private var didAttemptSharedPickupLoad = false
    @State private var showInAppShareSheet = false
    @State private var editFormMode: PickupGameFormMode?
    @State private var isPreparingEdit = false
    @State private var showCancelGameConfirm = false
    @State private var isCancellingGame = false
    @State private var isTeamLinkedGame = false
    @State private var linkedTeamContext: PickupGameTeamCreationContext?
    @State private var myTeamRSVP: FanTeamGameRSVPStatus?
    @State private var canUseTeamRSVP = false
    @State private var isSettingTeamRSVP = false
    @State private var showDirectionsChooser = false

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var isOutsideRecruitingEnabled: Bool {
        guard isTeamLinkedGame, let g = game else { return false }
        return PickupTeamOutsideRecruiting.isEnabled(
            playersNeeded: g.playersNeededClamped,
            maxPlayers: g.max_players
        )
    }

    private var showsOutsideRecruitmentMetadata: Bool {
        PickupDetailGameDetailsPresentation.showsOutsideRecruitmentMetadata(
            isTeamLinked: isTeamLinkedGame,
            isOutsideRecruitingEnabled: isOutsideRecruitingEnabled
        )
    }

    private var game: PickupGameRow? {
        viewModel.resolvedPickupGameRow(for: gameId)
    }

    private var isCreator: Bool {
        guard let uid = viewModel.currentUserAuthId, let g = game else { return false }
        return g.creator_user_id == uid
    }

    private var showsOrganizerOverflowMenu: Bool {
        guard let g = game, !viewModel.isGuestDiscoverMode else { return false }
        if isCreator { return true }
        return g.isEligibleForInAppShare()
    }

    /// Soft-cancel is organizer-only and only while the game is still active.
    private var canCancelPickupGame: Bool {
        game?.canOrganizerCancelPickupGame(viewerUserId: viewModel.currentUserAuthId) ?? false
    }

    private var isPickupGameCancelled: Bool {
        game?.isPickupGameSoftCancelled ?? false
    }

    private var cancelConfirmTitle: String {
        let title = game?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            return L10n.t("Cancel this pickup game?", languageCode: languageCode)
        }
        return String(
            format: L10n.t("pickup_cancel_confirm_title_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            title
        )
    }

    private var myRequest: PickupGameRequestRow? {
        viewModel.pickupMyLatestJoinRequestByGameId[gameId]
    }

    var body: some View {
        let _ = PickupDetailCrashTrace.log(
            "detailBodyEntered",
            gameId: gameId,
            title: game?.title
        )
        NavigationStack {
            Group {
                if let g = game {
                    if viewModel.isGuestDiscoverMode {
                        guestDiscoverPickupDetail(for: g)
                    } else {
                        detailContent(for: g)
                    }
                } else if isLoadingSharedPickupDetail {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        L10n.t("pickup_share_unavailable_title", languageCode: languageCode),
                        systemImage: "person.3.fill",
                        description: Text(L10n.t("pickup_share_unavailable_message", languageCode: languageCode))
                    )
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                }
            }
            .navigationTitle(L10n.t("share_pickup_card_badge", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let g = game, showsOrganizerOverflowMenu {
                        Menu {
                            if isCreator {
                                Button {
                                    Task { await openEditGame(for: g) }
                                } label: {
                                    Label(
                                        g.hasPickupGameStarted()
                                            ? L10n.t("Manage", languageCode: languageCode)
                                            : L10n.t("pickup_form_nav_edit", languageCode: languageCode),
                                        systemImage: "pencil"
                                    )
                                }
                                .disabled(isPreparingEdit || isCancellingGame)
                                if g.isPickupGameInvitable() {
                                    Button {
                                        showInviteComposer = true
                                    } label: {
                                        Label(
                                            L10n.t("Invite friends", languageCode: languageCode),
                                            systemImage: "person.badge.plus"
                                        )
                                    }
                                }
                            }
                            if g.isEligibleForInAppShare() {
                                Button {
                                    showInAppShareSheet = true
                                } label: {
                                    Label(L10n.t("Share", languageCode: languageCode), systemImage: "square.and.arrow.up")
                                }
                                ShareLink(item: pickupShareText(for: g)) {
                                    Label(L10n.t("share_pickup_os_share", languageCode: languageCode), systemImage: "square.and.arrow.up.on.square")
                                }
                            }
                            if canCancelPickupGame {
                                Divider()
                                Button(role: .destructive) {
                                    showCancelGameConfirm = true
                                } label: {
                                    Label(
                                        L10n.t("Cancel game", languageCode: languageCode),
                                        systemImage: "trash"
                                    )
                                }
                                .disabled(isCancellingGame)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(L10n.t("share_pickup_more_options_a11y", languageCode: languageCode))
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
            .sheet(item: $editFormMode) { mode in
                NavigationStack {
                    SettingsPickupGameFormView(
                        viewModel: viewModel,
                        mode: mode
                    ) {
                        editFormMode = nil
                        Task {
                            // Form save already merges the updated row; force refresh keeps Description in sync.
                            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                            await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId)
                            await viewModel.loadPickupGameRoster(pickupGameId: gameId, force: true)
                        }
                    }
                }
            }
            .sheet(isPresented: $showInAppShareSheet) {
                if let g = game {
                    SharePickupGameSheet(game: g, mapViewModel: viewModel)
                        .environmentObject(chatViewModel)
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
            .sheet(isPresented: $showTeamAttendanceRoster) {
                PickupTeamAttendanceRosterSheet(viewModel: viewModel, pickupGameId: gameId)
                    .environmentObject(viewModel)
            }
            .task(id: gameId) {
                if viewModel.resolvedPickupGameRow(for: gameId) == nil, !didAttemptSharedPickupLoad {
                    didAttemptSharedPickupLoad = true
                    isLoadingSharedPickupDetail = true
                    _ = await viewModel.loadPickupGameRowForDetailIfNeeded(id: gameId)
                    isLoadingSharedPickupDetail = false
                }
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
                PickupDetailCrashTrace.log("rosterRequestStarted", gameId: gameId, title: game?.title)
                await viewModel.loadPickupGameRoster(pickupGameId: gameId, force: true)
                PickupDetailCrashTrace.log("rosterRequestCompleted", gameId: gameId, title: game?.title)
                await resolveTeamLinkedParticipation()
                PickupDetailCrashTrace.log(
                    "teamContextResolved linked=\(isTeamLinkedGame)",
                    gameId: gameId,
                    title: game?.title
                )
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
            .confirmationDialog(
                cancelConfirmTitle,
                isPresented: $showCancelGameConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Cancel game", languageCode: languageCode), role: .destructive) {
                    Task { await cancelPickupGameAsOrganizer() }
                }
                Button(L10n.t("Keep game", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(L10n.t("pickup_cancel_confirm_message", languageCode: languageCode))
            }
        }
    }

    @MainActor
    private func openEditGame(for g: PickupGameRow) async {
        guard isCreator, !isPreparingEdit else { return }
        isPreparingEdit = true
        defer { isPreparingEdit = false }
        // Prefer the freshest cached row (Discover / settings / following / selected).
        let row = viewModel.resolvedPickupGameRow(for: g.id) ?? g
        editFormMode = .edit(row)
#if DEBUG
        print(
            "[PickupDetailEdit] open id=\(row.id.uuidString.lowercased()) " +
            "isVisible=\(row.is_visible) started=\(row.hasPickupGameStarted())"
        )
#endif
    }

    @MainActor
    private func cancelPickupGameAsOrganizer() async {
        guard isCreator, !isCancellingGame else { return }
        isCancellingGame = true
        defer { isCancellingGame = false }
        do {
            try await viewModel.deletePickupGame(id: gameId)
            dismiss()
        } catch {
            joinError = error.localizedDescription
        }
    }

    /// Discover guest session (``MapViewModel/isGuestDiscoverMode``): hides address, time, counts, join, and organizer identity; still shows **public** organizer trust (RPC aggregates only).
    @ViewBuilder
    private func guestDiscoverPickupDetail(for g: PickupGameRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    HStack(spacing: FGSpacing.sm) {
                        GameFormatBadgeView(format: g.gameFormat, colorScheme: colorScheme)
                        PickupGameVisibilityBadge(
                            isVisible: g.is_visible,
                            languageCode: languageCode,
                            colorScheme: colorScheme
                        )
                    }
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
        let _ = PickupDetailCrashTrace.log("detailContentEntered", gameId: g.id, title: g.title)
        let location = PickupDetailLocationPresentation.lines(
            address: g.address,
            city: g.city,
            state: g.state
        )
        let creatorLabel = viewModel.pickupCreatorDisplayLabel(for: g.creator_user_id)
        let sportMeta = AppSportCatalog.displayLabel(forSportToken: g.sport)
        let showStarted = g.hasPickupGameStarted()

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    if isPickupGameCancelled {
                        pickupInfoBanner(
                            text: L10n.t("pickup_detail_cancelled_banner", languageCode: languageCode)
                        )
                    }

                    let _ = PickupDetailCrashTrace.log("organizerRender", gameId: g.id, title: g.title)
                    pickupHeroCard(
                        g: g,
                        sportMeta: sportMeta,
                        showStarted: showStarted
                    )

                    pickupWhenWhereCard(for: g, locationPrimary: location.primary, locationSecondary: location.secondary)

                    pickupPrimarySocialActionsRow(for: g)

                    let _ = PickupDetailCrashTrace.log("attendanceRender", gameId: g.id, title: g.title)
                    pickupWhosGoingCard(for: g) {
                        if isTeamLinkedGame {
                            showTeamAttendanceRoster = true
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo("pickupDetailResponses", anchor: .top)
                            }
                        }
                    }

                    pickupGameDetailsCard(for: g, creatorLabel: creatorLabel)

                    let _ = PickupDetailCrashTrace.log("descriptionRender", gameId: g.id, title: g.title)
                    pickupDescriptionCard(for: g)

                    // Team-linked attendance lives in the Who's Going sheet — do not duplicate
                    // Going/Maybe/No Response/Can't Go as an on-page Responses section.
                    if !isTeamLinkedGame {
                        pickupResponsesSection(for: g)
                            .id("pickupDetailResponses")
                    }

                    if isCreator {
                        pickupCompactStatusFooter(
                            text: L10n.t("pickup_detail_organizing_status", languageCode: languageCode)
                        )
                    }

                    if !isCreator {
                        pickupDetailCreatorRatingSection(for: g)
                    }

                    let _ = PickupDetailCrashTrace.log("footerRender", gameId: g.id, title: g.title)
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
        .confirmationDialog(
            L10n.t("Directions", languageCode: languageCode),
            isPresented: $showDirectionsChooser,
            titleVisibility: .visible
        ) {
            if Self.pickupHasUsableMapCoordinate(g),
               let lat = g.latitude,
               let lon = g.longitude {
                Button(L10n.t("Apple Maps", languageCode: languageCode)) {
                    FanGeoDirectionsActions.openAppleMapsDirections(
                        latitude: lat,
                        longitude: lon,
                        name: g.title
                    )
                }
                if FanGeoDirectionsActions.isGoogleMapsInstalled {
                    Button(L10n.t("Google Maps", languageCode: languageCode)) {
                        FanGeoDirectionsActions.openGoogleMapsDirections(
                            latitude: lat,
                            longitude: lon,
                            name: g.title
                        )
                    }
                }
                let addressLine = [location.primary, location.secondary]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                if !addressLine.isEmpty {
                    Button(L10n.t("Copy Address", languageCode: languageCode)) {
                        FanGeoDirectionsActions.copyAddress(addressLine)
                    }
                }
            }
            Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
        }
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
        g.pickupCompactDurationLabel(languageCode: languageCode)
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

    @MainActor
    private func resolveTeamLinkedParticipation() async {
        let discoverIdentity = viewModel.pickupDiscoverTeamIdentityByGameId[gameId]
        let linked: Bool
        if discoverIdentity != nil {
            linked = true
        } else {
            linked = await viewModel.isPickupGameLinkedToFanTeam(pickupGameId: gameId)
        }
        isTeamLinkedGame = linked
        if linked {
            if let loaded = try? await FanTeamsService().loadTeamCreationContext(forPickupGameId: gameId) {
                linkedTeamContext = loaded
            } else if let discoverIdentity {
                // Public-safe Discover hydrate: enough for Team identity UI; RSVP still auth-gated below.
                linkedTeamContext = PickupGameTeamCreationContext(
                    teamId: discoverIdentity.teamId,
                    teamName: discoverIdentity.teamName,
                    teamSport: discoverIdentity.teamSport.isEmpty
                        ? (game?.sport ?? "")
                        : discoverIdentity.teamSport,
                    logoURL: discoverIdentity.logoURL,
                    logoThumbnailURL: discoverIdentity.logoThumbnailURL,
                    colorHex: discoverIdentity.colorHex
                )
            } else {
                linkedTeamContext = nil
            }
        } else {
            linkedTeamContext = nil
        }
        guard linked, !isCreator, !viewModel.isGuestDiscoverMode else {
            canUseTeamRSVP = false
            myTeamRSVP = nil
            return
        }
        // Probe Team RSVP authorization: participant check is SECURITY DEFINER inside get/set.
        // Non-members get nil from get; members get nil or a status. Distinguish by attempting
        // only after link is confirmed — invite-only outsiders keep Request to Join.
        do {
            myTeamRSVP = try await FanTeamsService().getRSVP(gameId: gameId)
            if myTeamRSVP != nil {
                canUseTeamRSVP = true
            } else if let req = myRequest {
                canUseTeamRSVP = true
                switch req.status.lowercased() {
                case "approved": myTeamRSVP = .going
                case "pending": myTeamRSVP = .maybe
                case "withdrawn", "cancelled", "rejected": myTeamRSVP = .cant_go
                default: break
                }
            } else {
                // Optimistic for Team-linked viewers: active members pass RLS without a row yet.
                // Invited outsiders who are not Team members get an error on set and fall back.
                canUseTeamRSVP = true
            }
        } catch {
            canUseTeamRSVP = false
            myTeamRSVP = nil
        }
    }

    @MainActor
    private func setTeamRSVP(_ status: FanTeamGameRSVPStatus) async {
        guard canUseTeamRSVP, !isSettingTeamRSVP else { return }
        isSettingTeamRSVP = true
        defer { isSettingTeamRSVP = false }
        do {
            try await FanTeamsService().setRSVP(gameId: gameId, status: status)
            myTeamRSVP = status
            await viewModel.loadMyLatestJoinRequestForPickupGame(pickupGameId: gameId)
            await viewModel.loadPickupGameRoster(pickupGameId: gameId, force: true)
            await viewModel.syncPickupGamesToAppleCalendarIfNeeded(
                reason: "teamRSVPChanged",
                forceBypassFreshness: true
            )
            joinError = nil
        } catch {
            canUseTeamRSVP = false
            joinError = error.localizedDescription
        }
    }

    private func pickupWhosGoingCard(for g: PickupGameRow, onViewAll: @escaping () -> Void) -> some View {
        let roster = viewModel.pickupGameRosterByGameId[g.id]
        let goingCount: Int
        let maybeCount: Int
        let noResponseCount: Int
        let cantGoCount: Int
        if isTeamLinkedGame, let roster {
            let counts = PickupTeamAttendancePresentation.counts(from: roster)
            goingCount = counts.going
            maybeCount = counts.maybe
            noResponseCount = counts.noResponse
            cantGoCount = counts.cantGo
        } else {
            goingCount = roster?.playingTotal
                ?? PickupGameRosterPresentation.playingDisplayCount(approvedJoinCount: g.approvedJoinCount)
            maybeCount = roster?.pending.count ?? 0
            noResponseCount = 0
            cantGoCount = 0
        }
        let stackMembers = roster?.stackMembers ?? fallbackOrganizerStack(for: g)
        let showOutside = isTeamLinkedGame && isOutsideRecruitingEnabled
        let yourResponse: String? = {
            if let myTeamRSVP {
                return L10n.t(myTeamRSVP.localizedKey, languageCode: languageCode)
            }
            if let status = myRequest?.status.lowercased() {
                switch status {
                case "approved": return L10n.t("fan_team_rsvp_going", languageCode: languageCode)
                case "pending": return L10n.t("fan_team_rsvp_maybe", languageCode: languageCode)
                case "withdrawn", "cancelled", "rejected":
                    return L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode)
                default: break
                }
            }
            return nil
        }()
        let summaryLine = pickupAttendanceSummaryLine(
            going: goingCount,
            maybe: maybeCount,
            noResponse: isTeamLinkedGame ? noResponseCount : nil,
            cantGo: isTeamLinkedGame && cantGoCount > 0 ? cantGoCount : nil
        )

        return VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text(L10n.t("pickup_detail_whos_going", languageCode: languageCode))
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(pickupDetailSubInk)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            Button(action: onViewAll) {
                HStack(alignment: .center, spacing: FGSpacing.md) {
                    if !stackMembers.isEmpty {
                        PickupPlayingAvatarStack(members: stackMembers, diameter: 28)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(summaryLine)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(pickupDetailMainInk)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)

                        if let yourResponse, !isCreator {
                            Text(
                                String(
                                    format: L10n.t(
                                        "pickup_detail_your_response_format",
                                        languageCode: languageCode
                                    ),
                                    locale: Locale(identifier: languageCode),
                                    yourResponse
                                )
                            )
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(FGColor.accentGreen)
                        }

                        if !isTeamLinkedGame {
                            Text(
                                String(
                                    format: L10n.t(
                                        "pickup_detail_spots_needed_format",
                                        languageCode: languageCode
                                    ),
                                    locale: Locale(identifier: languageCode),
                                    g.pickupOpenSlotsRemaining,
                                    g.playersNeededClamped
                                )
                            )
                            .font(FGTypography.caption)
                            .foregroundStyle(pickupDetailSubInk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .accessibilityHidden(true)
                }
                .padding(FGSpacing.md)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(L10n.t("pickup_detail_whos_going", languageCode: languageCode)). \(summaryLine)"
            )
            .accessibilityHint(
                isTeamLinkedGame
                    ? L10n.t("pickup_detail_view_team_attendance_a11y_hint", languageCode: languageCode)
                    : L10n.t("pickup_detail_view_responses_a11y_hint", languageCode: languageCode)
            )
            .accessibilityAddTraits(.isButton)

            if showOutside {
                HStack(spacing: FGSpacing.md) {
                    Label {
                        Text(
                            String(
                                format: L10n.t(
                                    "pickup_detail_additional_players_needed_format",
                                    languageCode: languageCode
                                ),
                                locale: Locale(identifier: languageCode),
                                g.playersNeededClamped
                            )
                        )
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(pickupDetailMainInk)
                    } icon: {
                        Image(systemName: "person.badge.plus")
                            .foregroundStyle(FGColor.intentPlay)
                    }
                    Spacer(minLength: 0)
                    Text(
                        String(
                            format: L10n.t("pickup_detail_open_spots_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            g.pickupOpenSlotsRemaining
                        )
                    )
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(pickupDetailSubInk)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func pickupAttendanceSummaryLine(
        going: Int,
        maybe: Int,
        noResponse: Int?,
        cantGo: Int? = nil
    ) -> String {
        var parts = [
            "\(going) \(L10n.t("Going", languageCode: languageCode))",
            "\(maybe) \(L10n.t("Maybe", languageCode: languageCode))",
        ]
        if let noResponse {
            parts.append("\(noResponse) \(L10n.t("pickup_detail_no_response", languageCode: languageCode))")
        }
        if let cantGo, cantGo > 0 {
            parts.append("\(cantGo) \(L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode))")
        }
        return parts.joined(separator: " · ")
    }

    /// Legacy capacity column retained for any residual callers; prefer `pickupWhosGoingCard`.
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
        sportMeta: String,
        showStarted: Bool
    ) -> some View {
        let hasUsableMapCoordinate = Self.pickupHasUsableMapCoordinate(g)
        let team = linkedTeamContext
        let teamAccent = linkedTeamContext.flatMap { Color(fanTeamHex: $0.colorHex ?? "") }

        return VStack(alignment: .leading, spacing: FGSpacing.md) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                Button {
                    showPickupOnDiscoverMap(g)
                } label: {
                    HStack(alignment: .top, spacing: FGSpacing.md) {
                        if let team {
                            FanTeamMarkView(
                                sport: team.teamSport,
                                logoURL: team.logoURL,
                                logoThumbnailURL: team.logoThumbnailURL,
                                colorHex: team.colorHex,
                                size: 52,
                                preferDetailURL: false
                            )
                            .accessibilityHidden(true)
                        } else {
                            PickupGameStartedSportGlyphFrame(showStarted: showStarted) {
                                SportArtworkIconView(sport: g.sport, diameter: 52)
                            }
                            .accessibilityHidden(true)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: FGSpacing.sm) {
                                GameFormatBadgeView(format: g.gameFormat, colorScheme: colorScheme)
                                PickupGameVisibilityBadge(
                                    isVisible: g.is_visible,
                                    languageCode: languageCode,
                                    colorScheme: colorScheme
                                )
                            }

                            if let team {
                                Text(team.teamName)
                                    .font(FGTypography.caption.weight(.bold))
                                    .foregroundStyle(teamAccent ?? FGColor.intentPlay)
                                    .lineLimit(1)
                            }

                            Text(g.title)
                                .font(FGTypography.sectionTitle)
                                .foregroundStyle(pickupDetailMainInk)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(sportMeta)
                                .font(FGTypography.metadata.weight(.medium))
                                .foregroundStyle(pickupDetailSubInk)
                                .multilineTextAlignment(.leading)

                            if showStarted {
                                PickupGameStartedLineCaption()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

                if hasUsableMapCoordinate {
                    Button {
                        showDirectionsChooser = true
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.12))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(FGColor.accentBlue)
                            }
                            Text(L10n.t("Directions", languageCode: languageCode))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(FGColor.accentBlue)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(minWidth: 56)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("Directions", languageCode: languageCode))
                    .accessibilityHint(
                        L10n.t("pickup_detail_directions_a11y_hint", languageCode: languageCode)
                    )
                }
            }
        }
        .padding(FGSpacing.lg)
        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
    }

    @ViewBuilder
    private func pickupWhenWhereCard(
        for g: PickupGameRow,
        locationPrimary: String?,
        locationSecondary: String?
    ) -> some View {
        let dateText = pickupDateText(for: g)
        let timeRange = pickupTimeRangeText(for: g)
        let duration = pickupDurationText(for: g)
        let timeSecondary: String? = {
            guard let timeRange, !timeRange.isEmpty else { return nil }
            if let duration, !duration.isEmpty { return "\(timeRange) · \(duration)" }
            return timeRange
        }()
        let hasDateRow = !dateText.isEmpty || (timeSecondary != nil)
        let hasLocationRow = locationPrimary != nil

        if hasDateRow || hasLocationRow {
            VStack(spacing: 0) {
                if hasDateRow {
                    pickupHeroInfoRow(
                        systemImage: "calendar",
                        tint: FGColor.accentBlue,
                        primary: dateText.isEmpty ? (timeSecondary ?? "") : dateText,
                        secondary: dateText.isEmpty ? nil : timeSecondary
                    )
                    .accessibilityLabel(
                        g.pickupDateTimeDurationAccessibilityLabel(languageCode: languageCode)
                            ?? [dateText, timeSecondary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
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
            .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
        }
    }

    @ViewBuilder
    private func pickupPrimarySocialActionsRow(for g: PickupGameRow) -> some View {
        let canInvite = isCreator && g.isPickupGameInvitable()
        let canShare = g.isEligibleForInAppShare()
        let showChat = canAccessPickupGameChat
        let showChatLocked = showsPickupChatLockedHint && !showChat

        if canInvite || canShare || showChat || showChatLocked {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(spacing: FGSpacing.md) {
                    if canInvite {
                        Button {
                            showInviteComposer = true
                        } label: {
                            pickupTintedActionLabel(
                                title: L10n.t("Invite friends", languageCode: languageCode),
                                systemImage: "person.badge.plus",
                                tint: Color.orange
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                    } else if canShare {
                        PickupGameShareActionButton(game: g, mapViewModel: viewModel) {
                            pickupTintedActionLabel(
                                title: L10n.t("Share", languageCode: languageCode),
                                systemImage: "square.and.arrow.up",
                                tint: FGColor.accentBlue
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                    }

                    if showChat {
                        Button {
                            Task { await openPickupGameChat(for: g) }
                        } label: {
                            pickupTintedActionLabel(
                                title: isOpeningPickupChat
                                    ? L10n.t("pickup_detail_opening_chat", languageCode: languageCode)
                                    : L10n.t("Chat", languageCode: languageCode),
                                systemImage: "bubble.left.and.bubble.right.fill",
                                tint: FGColor.accentGreen
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpeningPickupChat)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .accessibilityLabel(L10n.t("pickup_detail_open_chat_a11y", languageCode: languageCode))
                    } else if showChatLocked, canInvite || canShare {
                        HStack(spacing: FGSpacing.sm) {
                            Image(systemName: "lock.fill")
                                .font(.caption.weight(.semibold))
                            Text(L10n.t("pickup_detail_chat_locked", languageCode: languageCode))
                                .font(FGTypography.caption.weight(.medium))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(pickupDetailSubInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, FGSpacing.sm)
                    }
                }

                if showChatLocked, !canInvite, !canShare {
                    HStack(spacing: FGSpacing.sm) {
                        Image(systemName: "lock.fill")
                            .font(.caption.weight(.semibold))
                        Text(L10n.t("pickup_detail_chat_locked", languageCode: languageCode))
                            .font(FGTypography.caption.weight(.medium))
                    }
                    .foregroundStyle(pickupDetailSubInk)
                }

                if let pickupChatError, !pickupChatError.isEmpty {
                    Text(pickupChatError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                }
            }
        }
    }

    private var pickupDescriptionAccent: Color {
        if isTeamLinkedGame,
           let hex = linkedTeamContext?.colorHex,
           let color = Color(fanTeamHex: hex) {
            return color
        }
        return FGColor.accentBlue
    }

    private func pickupDescriptionCard(for g: PickupGameRow) -> some View {
        let raw = g.description ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDescription = !trimmed.isEmpty
        // Preserve internal line breaks; only trim leading/trailing whitespace for empty detection.
        let bodyText = hasDescription ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        return VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pickupDescriptionAccent)
                    .accessibilityHidden(true)
                Text(L10n.t("pickup_form_description", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(pickupDescriptionAccent)
                    .textCase(.uppercase)
            }
            .accessibilityAddTraits(.isHeader)

            if let bodyText {
                Text(bodyText)
                    .font(FGTypography.body)
                    .foregroundStyle(pickupDetailMainInk)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(L10n.t("pickup_detail_no_description", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hasDescription
                ? "\(L10n.t("pickup_form_description", languageCode: languageCode)). \(bodyText ?? "")"
                : "\(L10n.t("pickup_form_description", languageCode: languageCode)). \(L10n.t("pickup_detail_no_description", languageCode: languageCode))"
        )
    }

    private func pickupGameDetailsCard(for g: PickupGameRow, creatorLabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("pickup_detail_game_details", languageCode: languageCode))
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(pickupDetailSubInk)
                .textCase(.uppercase)
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.sm)
                .accessibilityAddTraits(.isHeader)

            if showsOutsideRecruitmentMetadata {
                pickupGameDetailsRow(
                    systemImage: "person.2.fill",
                    title: L10n.t("pickup_form_whos_welcome", languageCode: languageCode),
                    value: g.participantAudienceDisplayTitle
                )
                pickupGameDetailsDivider
            }

            pickupGameDetailsRow(
                systemImage: "sportscourt.fill",
                title: L10n.t("pickup_detail_play_label", languageCode: languageCode),
                value: g.playEnvironmentEnum.displayTitle(languageCode: languageCode)
            )

            if showsOutsideRecruitmentMetadata {
                pickupGameDetailsDivider
                pickupGameDetailsRow(
                    systemImage: "chart.bar.fill",
                    title: L10n.t("pickup_form_skill_level", languageCode: languageCode),
                    value: g.skillLevelEnum.displayTitle(languageCode: languageCode)
                )
            }

            if let level = g.competitionLevel {
                pickupGameDetailsDivider
                pickupGameDetailsRow(
                    systemImage: "trophy",
                    title: L10n.t("pickup_form_competition_level", languageCode: languageCode),
                    value: level.displayTitle(languageCode: languageCode)
                )
            }

            pickupGameDetailsDivider
            pickupGameDetailsRow(
                systemImage: "dollarsign.circle.fill",
                title: L10n.t("pickup_form_cost", languageCode: languageCode),
                value: g.entryFeeDisplayLine
            )

            pickupGameDetailsDivider
            pickupOrganizerDetailsRow(g: g, creatorLabel: creatorLabel)
        }
        .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
    }

    private var pickupGameDetailsDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.32))
            .frame(height: 1)
            .padding(.leading, 52)
            .accessibilityHidden(true)
    }

    private func pickupGameDetailsRow(systemImage: String, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(pickupDetailSubInk)
                Text(value)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(pickupDetailMainInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func pickupOrganizerDetailsRow(g: PickupGameRow, creatorLabel: String?) -> some View {
        let uid = g.creator_user_id
        let displayName = (creatorLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shownName = displayName.isEmpty ? "—" : displayName
        let thumb = viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: uid)
        let full = viewModel.pickupOrganizerAvatarFullForDetail(userId: uid)
        let token = viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: uid)
        let avatarFallback: UserAvatarView.FallbackStyle =
            colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
        let summary = viewModel.pickupOrganizerSummary(for: uid)

        return Button {
            viewModel.presentPublicProfile(
                userId: uid,
                context: "pickup_detail_organizer",
                isSelfPreview: uid == viewModel.currentUserAuthId
            )
        } label: {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                UserAvatarView(
                    avatarThumbnailURL: thumb,
                    avatarURL: full,
                    avatarDisplayRefreshToken: token,
                    displayName: displayName.isEmpty ? shownName : displayName,
                    email: "",
                    size: 36,
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
                    if let summary {
                        Text(summary.summaryLine(languageCode: languageCode))
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pickupOrganizerDetailAccessibilityLabel(displayName: shownName, summary: summary))
        .accessibilityHint(L10n.t("live_pickup_organizer_a11y_hint", languageCode: languageCode))
    }

    private func pickupResponsesSection(for g: PickupGameRow) -> some View {
        let roster = viewModel.pickupGameRosterByGameId[g.id]
        // Dedupe again at the UI boundary: Team detail gates show declined/no_response
        // ForEachs that standalone never renders; IDs must stay unique per group.
        let going = PickupGameRosterPresentation.uniqueMembersByUserId(
            roster?.stackMembers ?? fallbackOrganizerStack(for: g)
        )
        let maybe = PickupGameRosterPresentation.uniqueMembersByUserId(roster?.pending ?? [])
        let declined = PickupGameRosterPresentation.uniqueMembersByUserId(roster?.declinedMembers ?? [])
        let noResponse = PickupGameRosterPresentation.uniqueMembersByUserId(roster?.noResponseMembers ?? [])
        let showMaybe = isTeamLinkedGame || isCreator || !maybe.isEmpty
        let showDeclined = isTeamLinkedGame && !declined.isEmpty
        let showNoResponse = isTeamLinkedGame && !noResponse.isEmpty

        return VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text(L10n.t("pickup_detail_responses", languageCode: languageCode))
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(pickupDetailSubInk)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                pickupResponseGroup(
                    title: L10n.t("Going", languageCode: languageCode),
                    count: going.count,
                    members: going,
                    statusLabel: L10n.t("Going", languageCode: languageCode)
                )

                if showMaybe {
                    pickupGameDetailsDivider
                    pickupResponseGroup(
                        title: L10n.t("Maybe", languageCode: languageCode),
                        count: maybe.count,
                        members: maybe,
                        statusLabel: L10n.t("Maybe", languageCode: languageCode)
                    )
                }

                if showNoResponse {
                    pickupGameDetailsDivider
                    pickupResponseGroup(
                        title: L10n.t("pickup_detail_no_response", languageCode: languageCode),
                        count: noResponse.count,
                        members: noResponse,
                        statusLabel: L10n.t("pickup_detail_no_response", languageCode: languageCode)
                    )
                }

                if showDeclined {
                    pickupGameDetailsDivider
                    pickupResponseGroup(
                        title: L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode),
                        count: declined.count,
                        members: declined,
                        statusLabel: L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode)
                    )
                }
            }
            .background { pickupGlassBackground(cornerRadius: FGRadius.large) }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay { pickupGlassStroke(cornerRadius: FGRadius.large) }
        }
    }

    private func pickupResponseGroup(
        title: String,
        count: Int,
        members: [PickupGameRosterMember],
        statusLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text("\(title) (\(count))")
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(pickupDetailSubInk)
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)

            if members.isEmpty {
                Text(L10n.t("pickup_detail_nobody_in_group", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, FGSpacing.md)
            } else {
                // `id` is `user_id`; never feed duplicate identities into ForEach.
                ForEach(PickupGameRosterPresentation.uniqueMembersByUserId(members)) { member in
                    pickupResponseMemberRow(member: member, statusLabel: statusLabel)
                }
                .padding(.bottom, FGSpacing.sm)
            }
        }
    }

    private func pickupResponseMemberRow(member: PickupGameRosterMember, statusLabel: String) -> some View {
        let handle = FanTeamRosterRowPresentation.parentheticalHandle(username: member.username)
        let avatarFallback: UserAvatarView.FallbackStyle =
            colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
        return Button {
            viewModel.presentPublicProfile(
                userId: member.user_id,
                context: "pickup_detail_response",
                isSelfPreview: member.user_id == viewModel.currentUserAuthId
            )
        } label: {
            HStack(spacing: 12) {
                UserAvatarView(
                    avatarThumbnailURL: member.avatar_thumbnail_url,
                    avatarURL: member.avatar_url ?? "",
                    avatarDisplayRefreshToken: .init(),
                    displayName: member.resolvedDisplayName,
                    email: "",
                    size: 36,
                    fallbackStyle: avatarFallback,
                    imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(member.resolvedDisplayName)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(pickupDetailMainInk)
                            .lineLimit(1)
                        if let handle {
                            Text("(\(handle))")
                                .font(FGTypography.caption.weight(.medium))
                                .foregroundStyle(pickupDetailSubInk)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(statusLabel)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(pickupDetailSubInk)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(member.resolvedDisplayName), \(statusLabel)"
        )
    }

    private func pickupCompactStatusFooter(text: String) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(pickupDetailSubInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08))
        }
        .accessibilityElement(children: .combine)
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
        let coordsUsable = FanGeoDirectionsActions.hasUsableCoordinate(
            latitude: g.latitude,
            longitude: g.longitude
        )
        return PickupGameChatContext(
            pickupGameId: g.id,
            title: title,
            sportLabel: AppSportCatalog.displayLabel(forSportToken: g.sport),
            whenLabel: when,
            locationLabel: location,
            approvedParticipantCount: approvedCount,
            latitude: coordsUsable ? g.latitude : nil,
            longitude: coordsUsable ? g.longitude : nil
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
            PickupGameShareActionButton(game: g, mapViewModel: viewModel) {
                pickupTintedActionLabel(
                    title: L10n.t("Share", languageCode: languageCode),
                    systemImage: "square.and.arrow.up",
                    tint: FGColor.accentBlue
                )
            }

            Button {
                showInviteComposer = true
            } label: {
                pickupTintedActionLabel(
                    title: L10n.t("Invite friends", languageCode: languageCode),
                    systemImage: "person.badge.plus",
                    tint: Color.orange
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func pickupShareOnlyActionRow(for g: PickupGameRow) -> some View {
        PickupGameShareActionButton(game: g, mapViewModel: viewModel) {
            pickupTintedActionLabel(
                title: L10n.t("Share", languageCode: languageCode),
                systemImage: "square.and.arrow.up",
                tint: FGColor.accentBlue
            )
        }
    }

    /// Share + Chat side-by-side (50/50) under the hero Directions button.
    private func pickupShareAndChatActionRow(for g: PickupGameRow) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(spacing: FGSpacing.md) {
                PickupGameShareActionButton(game: g, mapViewModel: viewModel) {
                    pickupTintedActionLabel(
                        title: L10n.t("Share", languageCode: languageCode),
                        systemImage: "square.and.arrow.up",
                        tint: FGColor.accentBlue
                    )
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

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
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
                .accessibilityLabel("Open pickup game chat")
                .accessibilityHint("Opens the private chat for approved players of this pickup game")
            }

            if let pickupChatError, !pickupChatError.isEmpty {
                Text(pickupChatError)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.dangerRed)
            }
        }
    }

    /// Large equal-width rounded action button used for Share (blue) / Invite friends (orange).
    private func pickupTintedActionLabel(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(FGTypography.metadata.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .pickupCardTintedActionChrome(tint: tint, colorScheme: colorScheme)
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
                if canUseTeamRSVP, isTeamLinkedGame {
                    Text(L10n.t("pickup_detail_team_rsvp_prompt", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(pickupDetailSubInk)
                    HStack(spacing: 8) {
                        ForEach(FanTeamGameRSVPStatus.allCases, id: \.self) { status in
                            Button {
                                Task { await setTeamRSVP(status) }
                            } label: {
                                Text(L10n.t(status.localizedKey, languageCode: languageCode))
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(myTeamRSVP == status ? FGColor.accentGreen : FGColor.secondaryText(colorScheme).opacity(0.35))
                            .disabled(isSettingTeamRSVP)
                            .accessibilityAddTraits(myTeamRSVP == status ? .isSelected : [])
                        }
                    }
                } else if let req = myRequest {
                    labeledRow(
                        "Your request",
                        req.statusDisplayTitle(languageCode: appLanguageRaw)
                    )
                    let st = req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if st == "pending" {
                        Button(role: .destructive) {
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
                } else if myRequest == nil, !canUseTeamRSVP, g.isPickupFullForDiscover {
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
        // Team-linked + recruiting OFF: never offer classic join (Discover identity or RLS link).
        if !PickupDiscoverTeamPresentation.shouldOfferOutsideJoinCTA(
            isTeamLinked: isTeamLinkedGame,
            isOutsideRecruiting: isOutsideRecruitingEnabled
        ) {
            return false
        }
        // Team members already have RSVP; don't also show Request to Join for them.
        if isTeamLinkedGame, canUseTeamRSVP {
            return false
        }
        guard !g.isPickupFullForDiscover else { return false }
        guard let req = myRequest else { return true }
        let s = req.status.lowercased()
        return s == "rejected" || s == "cancelled" || s == "withdrawn"
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

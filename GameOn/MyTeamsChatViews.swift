import Combine
import PhotosUI
import Supabase
import SwiftUI
import UIKit

// MARK: - Chat section: My Teams list

struct MyTeamsChatSectionView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    var onOpenTeamChat: (FanTeamChatContext) -> Void
    /// When false (preserved off-screen), alerts must not cover Profile / other tabs.
    var isTeamsTabSelected: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @StateObject private var store = MyTeamsStore()
    @State private var searchText = ""
    @State private var showingCreate = false
    @State private var selectedTeam: FanTeamSummary?
    @State private var selectedTeamInitialTab: FanTeamDetailTab = .overview
    @State private var errorText: String?
    @State private var teamMarkRefreshTokens: [UUID: UUID] = [:]
    @State private var highlightedInvitationId: UUID?
    @State private var deletedTeamBanner: String?
    @State private var createTeamInfoBanner: String?
    @State private var showingMyPlayers = false
    /// Managed players the viewer guards. Empty for almost everyone.
    @State private var myManagedPlayers: [FanManagedPlayer] = []
    @State private var invitationPendingPlayerChoice: FanTeamInvitation?
    /// Nested Add Player from invitation join sheet (keeps invite sheet alive).
    @State private var showingInviteAddPlayer = false
    @State private var invitePreselectManagedPlayerId: UUID?
    @State private var homeSegment: TeamsHomeSegment = .myTeams
    /// Session-local My Teams relationship filter (not persisted to backend).
    @State private var relationshipFilter: FanTeamHomeFilter = .all

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    /// Teams home chrome accent (mockup purple) — cards still use per-team color.
    private var teamsChromeAccent: Color {
        FGColor.intentTeams
    }

    private var filteredHomeItems: [FanTeamHomeItem] {
        FanTeamHomeCatalog.displayItems(
            from: store.homeItems,
            filter: relationshipFilter,
            searchText: searchText
        )
    }

    /// Teams home My Teams feed after relationship filter + search, with native ads inserted last.
    /// Invites segment never uses this (ad-free). Empty filtered lists yield no ads.
    private var myTeamsFeedListItems: [ChatMyTeamsListItem] {
        ChatMyTeamsAdPlacement.listItems(for: filteredHomeItems.map(\.team))
    }

    private var homeFilterCounts: FanTeamHomeFilterCounts {
        store.homeFilterCounts
    }

    /// Authoritative Teams gate — same social session used by MainTab / Going / Chat.
    private var isSignedInForTeams: Bool {
        mapViewModel.isAuthenticatedForSocialFeatures
    }

    private var inviteBadgeText: String? {
        guard isSignedInForTeams else { return nil }
        let count = store.invitations.count
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    var body: some View {
        applyTeamsHomeAlerts(
            to: applyTeamsHomeSheets(
                to: applyTeamsHomeLifecycle(to: teamsHomeStack)
            )
        )
    }

    private var teamsHomeStack: some View {
        VStack(spacing: 0) {
            header
                .onChange(of: mapViewModel.pendingTeamScheduleJoinApproval) { _, pending in
                    guard isSignedInForTeams, pending != nil else { return }
                    Task { await fulfillPendingTeamScheduleJoinApprovalIfNeeded() }
                }
                .onChange(of: mapViewModel.pendingTeamScheduleEventDeepLink) { _, pending in
                    guard isSignedInForTeams, pending != nil else { return }
                    Task { await fulfillPendingTeamScheduleEventDeepLinkIfNeeded() }
                }
            if !isSignedInForTeams {
                signedOutLanding
            } else if store.isLoading && store.homeItems.isEmpty && store.invitations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                authenticatedTeamsScroll
            }
        }
        .background(colorScheme == .dark ? Color.black : Color(.systemBackground))
    }

    private var authenticatedTeamsScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                homeSegmentControl
                    .padding(.bottom, 2)

                switch homeSegment {
                case .myTeams:
                    myTeamsSegmentContent
                case .invites:
                    invitesSegmentContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            guard isSignedInForTeams else { return }
            await store.refresh(source: "section.refreshable", surfaceError: false)
            syncMyTeamsInvitationBadge()
        }
    }

    private func applyTeamsHomeLifecycle<V: View>(to view: V) -> some View {
        view
            .task(id: mapViewModel.currentUserAuthId) {
                guard isTeamsTabSelected else { return }
                await handleTeamsAuthSessionChanged(source: "section.task")
            }
        .onChange(of: isTeamsTabSelected) { _, selected in
            if selected {
                Task { await handleTeamsAuthSessionChanged(source: "section.tabSelected") }
            } else {
                errorText = nil
                store.errorText = nil
            }
        }
        .onChange(of: mapViewModel.isAuthenticatedForSocialFeatures) { _, signedIn in
            if signedIn {
                guard isTeamsTabSelected else { return }
                Task { await handleTeamsAuthSessionChanged(source: "section.authBecameAvailable") }
            } else {
                applySignedOutTeamsState()
            }
        }
        .onChange(of: mapViewModel.currentUserAuthId) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if newValue == nil {
                applySignedOutTeamsState()
            } else if oldValue != nil {
                store.resetAccountScopedState()
                store.prepareForAuthenticatedRefresh()
                selectedTeam = nil
                errorText = nil
                myManagedPlayers = []
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isSignedInForTeams, isTeamsTabSelected else { return }
            FanTeamIdentityRealtimeCoordinator.shared.handleSceneBecameActive()
            Task {
                await store.refresh(source: "section.sceneActive", surfaceError: false)
                syncMyTeamsInvitationBadge()
            }
        }
        .onAppear {
            guard isSignedInForTeams else { return }
            store.prepareForAuthenticatedRefresh()
            guard isTeamsTabSelected else { return }
            // Invitation-only soft refresh; full list refresh is owned by `.task` / scene / pull.
            Task {
                await store.refreshInvitations(source: "section.onAppear")
                syncMyTeamsInvitationBadge()
                await applyPendingInvitationHighlightIfNeeded()
                await applyPendingOpenFanTeamRosterIfNeeded()
                await fulfillPendingTeamScheduleJoinApprovalIfNeeded()
                await fulfillPendingTeamScheduleEventDeepLinkIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fanTeamInvitationPushArrivedInForeground)) { _ in
            guard isSignedInForTeams else { return }
            Task {
                await store.refreshInvitations(source: "push.invitationForeground")
                syncMyTeamsInvitationBadge()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fanTeamDeletedPushArrivedInForeground)) { note in
            guard isSignedInForTeams else { return }
            let teamIdRaw = (note.userInfo?[FanTeamDeletedNotificationDeepLinkPayload.teamIDKey] as? String) ?? ""
            let teamId = UUID(uuidString: teamIdRaw)
            let teamName = (note.userInfo?[FanTeamDeletedNotificationDeepLinkPayload.teamNameKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                await store.refresh(source: "push.teamDeletedForeground")
                syncMyTeamsInvitationBadge()
                if let teamId, selectedTeam?.id == teamId {
                    selectedTeam = nil
                }
                if let teamName, !teamName.isEmpty {
                    deletedTeamBanner = String(
                        format: L10n.t("fan_teams_deleted_info_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        teamName
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fanTeamMemberLeftPushArrivedInForeground)) { _ in
            guard isSignedInForTeams else { return }
            Task {
                await store.refresh(source: "push.memberLeftForeground")
                mapViewModel.clearPickupGameRosterCaches()
                syncMyTeamsInvitationBadge()
            }
        }
        .onChange(of: chatViewModel.pendingHighlightFanTeamInvitationId) { _, _ in
            guard isSignedInForTeams else { return }
            Task { await applyPendingInvitationHighlightIfNeeded() }
        }
        .onChange(of: chatViewModel.pendingOpenMyTeamsInvitations) { _, open in
            guard isSignedInForTeams, open else { return }
            // Invitation taps highlight an invite. Removal / role / deleted-Team
            // reuse this flag only to select the Teams tab — stay on the list.
            if chatViewModel.pendingHighlightFanTeamInvitationId != nil {
                homeSegment = .invites
            }
        }
            .onChange(of: chatViewModel.pendingOpenFanTeamRosterTeamId) { _, _ in
                guard isSignedInForTeams else { return }
                Task { await applyPendingOpenFanTeamRosterIfNeeded() }
            }
    }

    private func applyTeamsHomeSheets<V: View>(to view: V) -> some View {
        view
            .sheet(isPresented: $showingMyPlayers) {
            NavigationStack {
                MyPlayersView(
                    languageCode: languageCode,
                    mapViewModel: mapViewModel,
                    chatViewModel: chatViewModel,
                    knownTeams: store.homeItems.map(\.team),
                    onOpenTeamChat: { context in
                        showingMyPlayers = false
                        onOpenTeamChat(context)
                    },
                    onTeamsChanged: {
                        Task { await store.refresh(source: "myPlayers.teamsChanged") }
                    }
                )
            }
            .onDisappear { Task { await refreshMyManagedPlayers() } }
        }
        .sheet(item: $invitationPendingPlayerChoice) { invitation in
            NavigationStack {
                TeamInvitationJoinSheet(
                    teamName: invitation.teamName,
                    selfDisplayName: mapViewModel.currentUserDisplayName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    selfAvatarURL: mapViewModel.currentUserAvatarURL,
                    selfAvatarThumbnailURL: mapViewModel.currentUserAvatarThumbnailURL,
                    managedPlayers: myManagedPlayers,
                    languageCode: languageCode,
                    initiallySelectedManagedPlayerId: invitePreselectManagedPlayerId,
                    onJoin: { includeSelf, managedIds in
                        Task {
                            await acceptInvitation(
                                invitation,
                                includeSelf: includeSelf,
                                managedPlayerIds: managedIds
                            )
                        }
                    },
                    onAddPlayer: {
                        showingInviteAddPlayer = true
                    }
                )
                .sheet(isPresented: $showingInviteAddPlayer) {
                    NavigationStack {
                        ManagedPlayerEditorSheet(
                            existing: nil,
                            languageCode: languageCode,
                            onSaved: { newId in
                                invitePreselectManagedPlayerId = newId
                                await refreshMyManagedPlayers()
                            }
                        )
                    }
                }
                .onDisappear {
                    invitePreselectManagedPlayerId = nil
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateFanTeamSheet(mapViewModel: mapViewModel, chatViewModel: chatViewModel) { teamId, logoWarning in
                Task {
                    await store.refresh(source: "createTeam.completed")
                    if let team = store.teams.first(where: { $0.id == teamId }) {
                        selectedTeamInitialTab = .overview
                        selectedTeam = team
                        TeamDetailCrashTrace.teamOpen(teamID: team.id, teamName: team.name)
                    }
                    if let logoWarning, !logoWarning.isEmpty {
                        createTeamInfoBanner = logoWarning
                    }
                }
            }
        }
        .sheet(item: $selectedTeam) { team in
            FanTeamDetailSheet(
                summary: team,
                mapViewModel: mapViewModel,
                chatViewModel: chatViewModel,
                initialTab: selectedTeamInitialTab,
                onOpenChat: { context in
                    selectedTeam = nil
                    onOpenTeamChat(context)
                },
                onTeamsChanged: {
                    Task { await store.refresh(source: "detail.teamsChanged") }
                },
                onTeamDeleted: {
                    selectedTeam = nil
                    Task { await store.refresh(source: "detail.teamDeleted") }
                },
                onQuietTeamsRefresh: {
                    Task { await store.refresh(source: "detail.playerMembership", surfaceError: false) }
                }
            )
        }
    }

    private func applyTeamsHomeAlerts<V: View>(to view: V) -> some View {
        view
            .alert(
                L10n.t("fan_teams_error_title", languageCode: languageCode),
                isPresented: Binding(
                    get: {
                        guard isTeamsTabSelected else { return false }
                        if let errorText, !errorText.isEmpty { return true }
                        // Automatic list_my_fan_teams failures never cover Profile / Teams with a modal.
                        return false
                    },
                    set: { if !$0 { errorText = nil; store.errorText = nil } }
                )
            ) {
            Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
        } message: {
            Text(errorText ?? store.errorText ?? "")
        }
        .alert(
            L10n.t("fan_teams_deleted_title", languageCode: languageCode),
            isPresented: Binding(
                get: { deletedTeamBanner != nil },
                set: { if !$0 { deletedTeamBanner = nil } }
            )
        ) {
            Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
        } message: {
            Text(deletedTeamBanner ?? "")
        }
        .alert(
            L10n.t("fan_teams_create", languageCode: languageCode),
            isPresented: Binding(
                get: { createTeamInfoBanner != nil },
                set: { if !$0 { createTeamInfoBanner = nil } }
            )
        ) {
            Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
        } message: {
            Text(createTeamInfoBanner ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: FanTeamIdentityChangeCenter.identityDidChangeNotification)) { note in
            guard let change = FanTeamIdentityChangeCenter.identityChange(from: note) else { return }
            store.applyIdentityChange(change)
            teamMarkRefreshTokens[change.teamId] = change.displayRefreshToken
            // Do not replace `selectedTeam` while the detail sheet is presented.
            // Mutating the `.sheet(item:)` value mid-presentation recreates FanTeamDetailSheet
            // (detailSheetInit again) and has caused AttributeGraph / render termination.
            // FanTeamDetailSheet already applies identity changes via its own onReceive.
        }
        .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.avatarDidChangeNotification)) { note in
            guard let change = FanManagedPlayerChangeCenter.avatarChange(from: note) else { return }
            // Local patch first — avoid immediate full list_my_fan_teams refresh storm.
            store.applyManagedPlayerAvatarChange(change)
        }
        .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.teamMembershipDidChangeNotification)) { _ in
            guard isSignedInForTeams else { return }
            Task { await store.refresh(source: "managedPlayer.teamMembershipChanged") }
        }
    }

    /// Accepts an invitation for Myself and/or one-or-more managed players in one RPC.
    @MainActor
    private func acceptInvitation(
        _ invitation: FanTeamInvitation,
        includeSelf: Bool,
        managedPlayerIds: [UUID]
    ) async {
        do {
#if DEBUG
            print(
                "[ManagedPlayerTeamAccess] inviteAcceptanceStart " +
                "invitation_id=\(invitation.invitationId.uuidString.lowercased()) " +
                "team_id=\(invitation.teamId.uuidString.lowercased()) " +
                "directUserSelected=\(includeSelf) " +
                "selectedJoiningPlayerIDs=\(managedPlayerIds.map { $0.uuidString.lowercased() }.joined(separator: ","))"
            )
#endif
            _ = try await FanManagedPlayerService().acceptInvitationForParticipants(
                invitationId: invitation.invitationId,
                includeSelf: includeSelf,
                managedPlayerIds: managedPlayerIds
            )
            for managedId in managedPlayerIds {
                FanManagedPlayerChangeCenter.postTeamMembershipChange(
                    FanManagedPlayerTeamMembershipChange(
                        managedPlayerId: managedId,
                        teamId: invitation.teamId,
                        membershipId: nil,
                        added: true
                    )
                )
#if DEBUG
                print(
                    "[ManagedPlayerTeamAccess] managedPlayerMembershipCreated " +
                    "managed_player_id=\(managedId.uuidString.lowercased()) " +
                    "team_id=\(invitation.teamId.uuidString.lowercased())"
                )
#endif
            }
            invitationPendingPlayerChoice = nil
            await store.refresh(source: "invitation.acceptedForParticipants")
            syncMyTeamsInvitationBadge()
            await refreshMyManagedPlayers()
#if DEBUG
            print(
                "[ManagedPlayerTeamAccess] myTeamsRefresh " +
                "team_id=\(invitation.teamId.uuidString.lowercased()) " +
                "homeItems=\(store.homeItems.count) " +
                "containsTeam=\(store.homeItems.contains(where: { $0.id == invitation.teamId })) " +
                "managed_added=\(managedPlayerIds.count)"
            )
#endif
        } catch {
#if DEBUG
            print(
                "[ManagedPlayerTeamDebug] invite_accept_failed " +
                "team_id=\(invitation.teamId.uuidString.lowercased()) " +
                "error=\(error.localizedDescription)"
            )
#endif
            if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
        }
    }

    /// Silent on failure: a missing RPC (pre-20260960 backend) must not surface
    /// an error to a user who has never heard of managed players.
    @MainActor
    private func refreshMyManagedPlayers() async {
        guard isSignedInForTeams else {
            myManagedPlayers = []
            return
        }
        myManagedPlayers = (try? await FanManagedPlayerService().listMyManagedPlayers()) ?? []
    }

    /// Keep root Teams tab invitation badge aligned with invitee pending list (not manager-sent counts).
    @MainActor
    private func syncMyTeamsInvitationBadge() {
        guard isSignedInForTeams else {
            chatViewModel.applyPendingFanTeamInvitations([])
            return
        }
        chatViewModel.applyPendingFanTeamInvitations(store.invitations)
    }

    @MainActor
    private func applySignedOutTeamsState() {
        store.resetAccountScopedState()
        selectedTeam = nil
        errorText = nil
        searchText = ""
        homeSegment = .myTeams
        relationshipFilter = .all
        myManagedPlayers = []
        showingCreate = false
        showingMyPlayers = false
        highlightedInvitationId = nil
        invitationPendingPlayerChoice = nil
        chatViewModel.applyPendingFanTeamInvitations([])
    }

    @MainActor
    private func handleTeamsAuthSessionChanged(source: String) async {
        guard TeamsHomeAuthPresentation.shouldFetchAuthenticatedTeamData(
            isSignedIn: isSignedInForTeams
        ) else {
            applySignedOutTeamsState()
            return
        }
        store.prepareForAuthenticatedRefresh()
        await store.refresh(source: source, surfaceError: false)
        syncMyTeamsInvitationBadge()
        await applyPendingInvitationHighlightIfNeeded()
        await applyPendingOpenFanTeamRosterIfNeeded()
        await refreshMyManagedPlayers()
    }

    /// Deep-link highlight: fail soft when the invitation was cancelled/accepted elsewhere.
    @MainActor
    private func applyPendingInvitationHighlightIfNeeded() async {
        guard isSignedInForTeams else { return }
        guard let targetId = chatViewModel.pendingHighlightFanTeamInvitationId else { return }

        if store.invitations.isEmpty {
            await store.refreshInvitations(source: "highlight.pendingInvitation")
        }

        _ = chatViewModel.consumePendingHighlightFanTeamInvitationId()

        guard store.invitations.contains(where: { $0.id == targetId }) else {
            // Stale push (cancelled / already acted) — My Teams opens; no actionable card.
            highlightedInvitationId = nil
            return
        }

        highlightedInvitationId = targetId
        homeSegment = .invites
        // Clear the emphasis after a short beat so the list settles.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if highlightedInvitationId == targetId {
            highlightedInvitationId = nil
        }
    }

    /// member_left_team push: open Team Detail → Roster (fail soft if Team gone).
    @MainActor
    private func applyPendingOpenFanTeamRosterIfNeeded() async {
        guard isSignedInForTeams else { return }
        guard let teamId = chatViewModel.pendingOpenFanTeamRosterTeamId else { return }
        if store.homeItems.isEmpty {
            await store.refresh(source: "deepLink.memberLeftRoster")
        }
        _ = chatViewModel.consumePendingOpenFanTeamRosterTeamId()
        guard let team = store.homeItems.first(where: { $0.id == teamId })?.team
            ?? store.teams.first(where: { $0.id == teamId }) else {
#if DEBUG
            print("[FanTeamMemberLeaveDebug] roster_deep_link_miss team_id=\(teamId.uuidString.lowercased())")
#endif
            return
        }
        mapViewModel.clearPickupGameRosterCaches()
        selectedTeamInitialTab = .roster
        selectedTeam = team
    }

    /// Action Center join approval → Team Detail Schedule → game + pending requests.
    @MainActor
    private func fulfillPendingTeamScheduleJoinApprovalIfNeeded() async {
        guard isSignedInForTeams else { return }
        guard let pending = mapViewModel.pendingTeamScheduleJoinApproval else { return }
        if store.homeItems.isEmpty {
            await store.refresh(source: "deepLink.joinApprovalSchedule")
        }
        guard let team = store.homeItems.first(where: { $0.id == pending.teamId })?.team
            ?? store.teams.first(where: { $0.id == pending.teamId }) else {
            // Team not in list — fall back to organizer requests sheet only.
            mapViewModel.pendingOrganizerJoinRequestsGameToken =
                PickupDetailNavigationToken.standalone(pending.pickupGameId)
            mapViewModel.clearPendingTeamScheduleJoinApproval()
            return
        }
        homeSegment = .myTeams
        selectedTeamInitialTab = .schedule
        if selectedTeam?.id != team.id {
            selectedTeam = team
        }
        // FanTeamDetailSheet consumes pendingTeamScheduleJoinApproval for game + requests.
    }

    /// Team Schedule create/update APNs → Team Detail Schedule → event detail.
    @MainActor
    private func fulfillPendingTeamScheduleEventDeepLinkIfNeeded() async {
        guard isSignedInForTeams else { return }
        guard let pending = mapViewModel.pendingTeamScheduleEventDeepLink else { return }
        if store.homeItems.isEmpty {
            await store.refresh(source: "deepLink.teamScheduleEvent")
        }
        guard let team = store.homeItems.first(where: { $0.id == pending.teamId })?.team
            ?? store.teams.first(where: { $0.id == pending.teamId }) else {
#if DEBUG
            print(
                "[TeamScheduleNotification] deepLinkResolved miss team_id=\(pending.teamId.uuidString.lowercased()) " +
                "fallback=sharedPickupDetail"
            )
#endif
            mapViewModel.presentSharedPickupGameDetail(
                gameId: pending.pickupGameId,
                presentationMode: .teamEvent,
                seededTeamContext: PickupGameTeamCreationContext(
                    teamId: pending.teamId,
                    teamName: "",
                    teamSport: ""
                )
            )
            mapViewModel.clearPendingTeamScheduleEventDeepLink()
            return
        }
        homeSegment = .myTeams
        selectedTeamInitialTab = .schedule
        if selectedTeam?.id != team.id {
            selectedTeam = team
        }
        // FanTeamDetailSheet consumes pendingTeamScheduleEventDeepLink for game detail.
    }

    @ViewBuilder
    private var myTeamsSegmentContent: some View {
        relationshipFilterChips
            .padding(.bottom, 2)

        if store.homeItems.isEmpty {
            if let retryMessage = store.sectionRetryMessage {
                myTeamsSectionRetry(retryMessage)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
            } else {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
            }
        } else {
            Text(L10n.t("fan_teams_your_teams", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)

            if filteredHomeItems.isEmpty {
                filterEmptyState
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                let listItems = myTeamsFeedListItems
#if DEBUG
                let _ = {
                    let listTeams = filteredHomeItems.map(\.team)
                    guard ChatMyTeamsAdPlacement.shouldLogDiagnostics(for: listTeams) else { return }
                    let positions = ChatMyTeamsAdPlacement.insertionPositions(for: listTeams.count)
                    print(
                        "[NativeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) " +
                        "filter=\(relationshipFilter.rawValue) teamCount=\(listTeams.count)"
                    )
                    print("[NativeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) insertedAfter=\(positions.map(String.init).joined(separator: ","))")
                    if let reason = ChatMyTeamsAdPlacement.skippedReason(teamCount: listTeams.count) {
                        print("[NativeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) skippedReason=\(reason)")
                    }
                    if FanGeoAdPolicy.adsSuppressed {
                        print("[NativeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) adsSuppressed=true")
                    }
                }()
#endif
                ForEach(listItems) { item in
                    switch item {
                    case .team(let team):
                        let relationship = filteredHomeItems.first(where: { $0.id == team.id })?.relationship
                            ?? FanTeamHomeCatalog.relationship(forAccountRole: team.myRole)
                        MyTeamCardView(
                            team: team,
                            relationship: relationship,
                            languageCode: languageCode,
                            displayRefreshToken: teamMarkRefreshTokens[team.id],
                            chromeAccent: teamsChromeAccent,
                            onOpenDetail: {
                                TeamDetailCrashTrace.log(
                                    "teamCardTapped",
                                    details: "teamID=\(team.id.uuidString.lowercased()) teamName=\(team.name)"
                                )
                                // One presentation per Team id — ignore rapid re-taps while opening.
                                if selectedTeam?.id == team.id { return }
                                TeamDetailCrashTrace.teamOpen(teamID: team.id, teamName: team.name)
                                selectedTeamInitialTab = .overview
                                selectedTeam = team
                            }
                        )
                    case .nativeAd(let slot):
                        TeamsHomeNativeAdCard(slot: slot)
                    }
                }
                // Keep filter switches from animating ad/team row remounts into janky jumps.
                .animation(nil, value: relationshipFilter)
                .animation(nil, value: searchText)
            }
        }
    }

    private var relationshipFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FanTeamHomeFilter.allCases) { filter in
                    relationshipFilterChip(filter)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
    }

    private func relationshipFilterChip(_ filter: FanTeamHomeFilter) -> some View {
        let selected = relationshipFilter == filter
        let count = homeFilterCounts.count(for: filter)
        let title = L10n.t(filter.localizationKey, languageCode: languageCode)
        return Button {
            relationshipFilter = filter
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(
                selected
                    ? teamsChromeAccent
                    : FGColor.secondaryText(colorScheme)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? teamsChromeAccent.opacity(colorScheme == .dark ? 0.28 : 0.14)
                            : FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 1)
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected
                            ? teamsChromeAccent.opacity(0.55)
                            : FGColor.divider(colorScheme).opacity(0.45),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            filterChipAccessibilityLabel(title: title, count: count, selected: selected)
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func filterChipAccessibilityLabel(
        title: String,
        count: Int,
        selected: Bool
    ) -> String {
        let key = selected
            ? "fan_teams_filter_a11y_selected"
            : "fan_teams_filter_a11y"
        return String(
            format: L10n.t(key, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            title,
            count
        )
    }

    @ViewBuilder
    private var filterEmptyState: some View {
        let hasSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasSearch {
            Text(L10n.t("fan_teams_empty_body", languageCode: languageCode))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            switch relationshipFilter {
            case .all:
                emptyState
            case .managing:
                filterBucketEmptyState(
                    messageKey: FanTeamHomeFilter.managing.emptyTitleKey,
                    showsCreate: true
                )
            case .joined:
                filterBucketEmptyState(
                    messageKey: FanTeamHomeFilter.joined.emptyTitleKey,
                    showsCreate: false
                )
            }
        }
    }

    private func filterBucketEmptyState(messageKey: String, showsCreate: Bool) -> some View {
        VStack(spacing: 12) {
            Text(L10n.t(messageKey, languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            if showsCreate {
                Button {
                    showingCreate = true
                } label: {
                    Label(L10n.t("fan_teams_create", languageCode: languageCode), systemImage: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(teamsChromeAccent)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(teamsChromeAccent.opacity(0.85), lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("fan_teams_create", languageCode: languageCode))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var invitesSegmentContent: some View {
        if store.invitations.isEmpty {
            ContentUnavailableView(
                L10n.t("fan_teams_invitations_section", languageCode: languageCode),
                systemImage: "envelope.open"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
        } else {
            Text(L10n.t("fan_teams_invitations_section", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)

            ForEach(store.invitations) { invitation in
                FanTeamInvitationCardView(
                    invitation: invitation,
                    languageCode: languageCode,
                    isBusy: store.busyInvitationIds.contains(invitation.id),
                    isHighlighted: highlightedInvitationId == invitation.id,
                    onAccept: {
                        invitationPendingPlayerChoice = invitation
                    },
                    onDecline: {
                        Task {
                            do {
                                try await store.declineInvitation(invitation)
                                syncMyTeamsInvitationBadge()
                            } catch {
                                if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                                    errorText = message
                                }
                            }
                        }
                    }
                )
                .id(invitation.id)
            }
        }
    }

    private var homeSegmentControl: some View {
        GameOnSegmentedControl(
            tabs: [
                GameOnSegmentedTab(
                    id: TeamsHomeSegment.myTeams,
                    title: L10n.t("My Teams", languageCode: languageCode),
                    systemImage: "person.3.fill",
                    tint: teamsChromeAccent,
                    accessibilityLabel: L10n.t("My Teams", languageCode: languageCode)
                ),
                GameOnSegmentedTab(
                    id: TeamsHomeSegment.invites,
                    title: L10n.t("Invites", languageCode: languageCode),
                    systemImage: "envelope.fill",
                    badge: inviteBadgeText,
                    tint: teamsChromeAccent,
                    accessibilityLabel: L10n.t("Invites", languageCode: languageCode)
                )
            ],
            selection: $homeSegment,
            accent: teamsChromeAccent,
            animatesSelectionChanges: true
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 6) {
                FanGeoPagePurposeHeader(
                    title: L10n.t("teams", languageCode: languageCode),
                    subtitle: ""
                )
                // Keep "Teams" intrinsic so action buttons receive the leftover width
                // and ViewThatFits can collapse on very narrow layouts (e.g. SE).
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                if isSignedInForTeams {
                    // Prefer labeled actions; collapse only when the leftover width cannot fit.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            teamsHeaderMyPlayersButton(showsTitle: true)
                            teamsHeaderCreateTeamButton(showsTitle: true)
                        }
                        HStack(spacing: 6) {
                            teamsHeaderMyPlayersButton(showsTitle: false)
                            teamsHeaderCreateTeamButton(showsTitle: true)
                        }
                        HStack(spacing: 6) {
                            teamsHeaderMyPlayersButton(showsTitle: false)
                            teamsHeaderCreateTeamButton(showsTitle: false)
                        }
                    }
                }

                FanGeoActionCenterHeaderButton()
            }

            if isSignedInForTeams {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    TextField(L10n.t("fan_teams_search_placeholder", languageCode: languageCode), text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.78 : 1))
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06),
                            radius: 8,
                            x: 0,
                            y: 3
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var signedOutLanding: some View {
        SignedOutFeatureView(
            icon: "person.3.fill",
            title: L10n.t("teams_signed_out_title", languageCode: languageCode),
            description: L10n.t("teams_signed_out_body", languageCode: languageCode),
            accent: teamsChromeAccent,
            onSignIn: {
                mapViewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            },
            onCreateAccount: {
                mapViewModel.discoverPresentFanUserAuthSheet(openRegisterMode: true)
            }
        )
    }

    private func teamsHeaderMyPlayersButton(showsTitle: Bool) -> some View {
        Button {
            showingMyPlayers = true
        } label: {
            HStack(spacing: showsTitle ? 6 : 0) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 13, weight: .bold))
                if showsTitle {
                    Text(L10n.t("managed_players_title", languageCode: languageCode))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(teamsChromeAccent)
            .padding(.horizontal, showsTitle ? 10 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(teamsChromeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(teamsChromeAccent.opacity(0.28), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("managed_players_title", languageCode: languageCode))
    }

    private func teamsHeaderCreateTeamButton(showsTitle: Bool) -> some View {
        Button {
            showingCreate = true
        } label: {
            HStack(spacing: showsTitle ? 5 : 0) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                if showsTitle {
                    Text(L10n.t("fan_teams_create", languageCode: languageCode))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, showsTitle ? 10 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background(teamsChromeAccent, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("fan_teams_create", languageCode: languageCode))
    }

    private func myTeamsSectionRetry(_ message: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(teamsChromeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(teamsChromeAccent)
            }
            .accessibilityHidden(true)

            Text(L10n.t("fan_teams_error_title", languageCode: languageCode))
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Button {
                Task {
                    await store.refresh(source: "section.retry", surfaceError: false)
                    syncMyTeamsInvitationBadge()
                }
            } label: {
                Text(L10n.t("Try Again", languageCode: languageCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(teamsChromeAccent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(teamsChromeAccent.opacity(0.85), lineWidth: 1.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Try Again", languageCode: languageCode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(teamsChromeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "person.3.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(teamsChromeAccent)
            }
            .accessibilityHidden(true)

            Text(L10n.t("fan_teams_empty_title", languageCode: languageCode))
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)

            Text(L10n.t("fan_teams_empty_body", languageCode: languageCode))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Button {
                showingCreate = true
            } label: {
                Label(L10n.t("fan_teams_create", languageCode: languageCode), systemImage: "plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(teamsChromeAccent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(teamsChromeAccent.opacity(0.85), lineWidth: 1.5)
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel(L10n.t("fan_teams_create", languageCode: languageCode))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }
}

private enum TeamsHomeSegment: Hashable {
    case myTeams
    case invites
}

/// Classifies My Teams load/mutation failures for UI presentation.
/// Cancellation and missing auth are control flow — never user-facing.
enum FanTeamsLoadErrorPresentation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let layered = error as? FanTeamLayeredError {
            return isCancellation(layered.underlying)
        }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return message == "cancelled"
            || message == "canceled"
            || message.contains("cancellationerror")
            || message.contains("task was cancelled")
            || message.contains("task was canceled")
    }

    /// No session / JWT is not a Teams refresh failure.
    static func isMissingAuthSession(_ error: Error) -> Bool {
        if let layered = error as? FanTeamLayeredError {
            return isMissingAuthSession(layered.underlying)
        }
        let text = combinedErrorText(error)
        if text.contains("not authenticated") || text.contains("unauthenticated") {
            return true
        }
        if text.contains("session") && (
            text.contains("missing")
                || text.contains("not found")
                || text.contains("not exist")
                || text.contains("no current")
                || text.contains("expired")
        ) {
            return true
        }
        if text.contains("jwt") && (text.contains("expired") || text.contains("missing")) {
            return true
        }
        return false
    }

    private static func combinedErrorText(_ error: Error) -> String {
        var parts: [String] = [error.localizedDescription]
        if let pe = error as? PostgrestError {
            parts.append(pe.message)
            if let detail = pe.detail { parts.append(detail) }
            if let hint = pe.hint { parts.append(hint) }
            if let code = pe.code { parts.append(code) }
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// Specific managed-seat / invite messages when the backend surfaces a known code.
    static func managedPlayerSeatMessage(for error: Error, languageCode: String? = nil) -> String? {
        let text = combinedErrorText(error)
        if text.contains("managed_player_team_seats_disabled")
            || text.contains("managed_player_seats_disabled") {
            return L10n.t("managed_players_seats_disabled", languageCode: languageCode)
        }
        if text.contains("managed_player_already_on_team") {
            return L10n.t("managed_players_already_on_team", languageCode: languageCode)
        }
        if text.contains("managed_player_invite_selection_empty") {
            return L10n.t("managed_players_invite_selection_empty", languageCode: languageCode)
        }
        return nil
    }

    /// `nil` when the error must not be shown (cancellation / signed-out).
    static func userFacingMessage(for error: Error, languageCode: String? = nil) -> String? {
        userFacingMessage(for: error, layer: (error as? FanTeamLayeredError)?.layer, languageCode: languageCode)
    }

    /// Layer-aware copy: do not say "refresh" when the membership mutation itself failed.
    static func userFacingMessage(
        for error: Error,
        layer: FanTeamOperationLayer?,
        languageCode: String? = nil
    ) -> String? {
        if isCancellation(error) { return nil }
        if isMissingAuthSession(error) { return nil }
        if let specific = managedPlayerSeatMessage(for: error, languageCode: languageCode) {
            return specific
        }
        let resolved = layer ?? (error as? FanTeamLayeredError)?.layer
        switch resolved {
        case .membershipUpdate:
            return L10n.t("fan_teams_membership_update_failed", languageCode: languageCode)
        case .teamDetailMembers, .teamDetailGames:
            return L10n.t("fan_teams_detail_reload_failed", languageCode: languageCode)
        case .managedPlayerRefresh:
            return nil
        case .teamsReload, .decoding, .reconciliation, .none:
            return L10n.t("fan_teams_refresh_failed", languageCode: languageCode)
        }
    }

    /// DEBUG diagnostics for PostgREST / decoding failures (never shown in UI).
    static func debugDescription(_ error: Error) -> String {
        var parts: [String] = [String(describing: type(of: error)), error.localizedDescription]
        if let layered = error as? FanTeamLayeredError {
            parts.append("layer=\(layered.layer.rawValue)")
            parts.append("httpStatus=\(layered.httpStatus.map(String.init) ?? "nil")")
            parts.append("mutationCommitted=\(layered.mutationCommitted.map { $0 ? "YES" : "NO" } ?? "unknown")")
            if let body = layered.responseBody, !body.isEmpty {
                parts.append("body=\(body)")
            }
            parts.append("underlying=\(debugDescription(layered.underlying))")
            return parts.joined(separator: " | ")
        }
        if let pe = error as? PostgrestError {
            parts.append("message=\(pe.message)")
            if let code = pe.code { parts.append("code=\(code)") }
            if let detail = pe.detail { parts.append("detail=\(detail)") }
            if let hint = pe.hint { parts.append("hint=\(hint)") }
        }
        if let http = error as? HTTPError {
            parts.append("httpStatus=\(http.response.statusCode)")
            if let body = String(data: http.data, encoding: .utf8), !body.isEmpty {
                parts.append("httpBody=\(body)")
            }
        }
        if let decoding = error as? DecodingError {
            parts.append(String(describing: decoding))
        }
        let ns = error as NSError
        if ns.domain != NSCocoaErrorDomain || ns.code != 0 {
            parts.append("ns=\(ns.domain)#\(ns.code)")
        }
        return parts.joined(separator: " | ")
    }
}

/// Teams home chrome vs signed-out landing (pure; no network).
enum TeamsHomeAuthPresentation {
    static func shouldFetchAuthenticatedTeamData(isSignedIn: Bool) -> Bool {
        isSignedIn
    }

    static func showsSignedOutLanding(isSignedIn: Bool) -> Bool {
        !isSignedIn
    }

    static func showsAuthenticatedChrome(isSignedIn: Bool) -> Bool {
        isSignedIn
    }

    static func showsAuthenticatedEmptyState(isSignedIn: Bool, homeItemCount: Int) -> Bool {
        isSignedIn && homeItemCount == 0
    }
}

@MainActor
final class MyTeamsStore: ObservableObject {
    @Published var teams: [FanTeamSummary] = []
    /// Deduplicated My Teams home catalog (account seats + guardian-only access).
    @Published private(set) var homeItems: [FanTeamHomeItem] = []
    @Published var invitations: [FanTeamInvitation] = []
    @Published var isLoading = false
    @Published var errorText: String?
    /// Inline Teams-home retry copy when automatic refresh failed and there is no cache.
    @Published var sectionRetryMessage: String?
    @Published var busyInvitationIds: Set<UUID> = []

    private let service = FanTeamsService()
    private let managedPlayerService = FanManagedPlayerService()
    /// Owns loading-spinner / result application across overlapping refreshes.
    private var refreshGeneration = 0
    /// In-flight refresh task; concurrent callers await the same work.
    private var refreshInFlight: Task<Void, Never>?
    /// Identity of ``refreshInFlight`` so a finished/cancelled task cannot clear a newer one.
    private var refreshInFlightToken: UUID?
    /// When true, another refresh was requested while one was in flight — run once more.
    private var refreshNeededAgain = false
    /// False after logout until the next authenticated session is prepared.
    private var allowsAuthenticatedFetch = false

    /// Compact “Via …” labels keyed by Team id (from My Players memberships).
    private var managedViaNamesByTeamId: [UUID: [String]] = [:]
    /// Teams visible only through managed-player access (no account seat).
    private var guardianOnlyTeamsById: [UUID: FanTeamSummary] = [:]

    var homeFilterCounts: FanTeamHomeFilterCounts {
        FanTeamHomeCatalog.counts(for: homeItems)
    }

    func refresh(source: String = "unspecified", surfaceError: Bool = true) async {
        guard allowsAuthenticatedFetch else {
#if DEBUG
            print("[FanTeamsLoad] operation=refresh skippedUnauthenticated source=\(source)")
#endif
            return
        }
        if let existing = refreshInFlight {
            refreshNeededAgain = true
#if DEBUG
            print("[FanTeamsLoad] operation=refresh coalesced source=\(source)")
#endif
            await existing.value
            return
        }

        refreshNeededAgain = false
        let token = UUID()
        refreshInFlightToken = token
        let task = Task { @MainActor in
            repeat {
                self.refreshNeededAgain = false
                await self.performRefresh(source: source, surfaceError: surfaceError)
            } while self.refreshNeededAgain
            if self.refreshInFlightToken == token {
                self.refreshInFlight = nil
                self.refreshInFlightToken = nil
            }
        }
        refreshInFlight = task
        await task.value
    }

    /// Drops account-scoped Teams state and invalidates in-flight refresh generations.
    func resetAccountScopedState() {
        refreshGeneration += 1
        refreshNeededAgain = false
        allowsAuthenticatedFetch = false
        refreshInFlightToken = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        teams = []
        homeItems = []
        invitations = []
        isLoading = false
        errorText = nil
        sectionRetryMessage = nil
        busyInvitationIds = []
        managedViaNamesByTeamId = [:]
        guardianOnlyTeamsById = [:]
#if DEBUG
        print("[FanTeamsLoad] operation=resetAccountScopedState generation=\(refreshGeneration)")
#endif
    }

    /// Re-enables authenticated fetches after login / account switch (shows spinner if empty).
    func prepareForAuthenticatedRefresh() {
        allowsAuthenticatedFetch = true
        errorText = nil
        if homeItems.isEmpty && invitations.isEmpty && teams.isEmpty {
            isLoading = true
        }
    }

    @MainActor
    private func performRefresh(source: String, surfaceError: Bool = true) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        // Full-screen spinner only when we have nothing to show yet.
        let showBlockingSpinner = teams.isEmpty && homeItems.isEmpty && invitations.isEmpty
        if showBlockingSpinner {
            isLoading = true
        }
#if DEBUG
        print("[FanTeamsLoad] operation=refresh start source=\(source) generation=\(generation) blockingSpinner=\(showBlockingSpinner)")
#endif
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }
        do {
            async let teamsTask = service.listMyTeams()
            async let invitationsTask = service.listMyPendingInvitations()
            let (nextTeams, nextInvitations) = try await (teamsTask, invitationsTask)
            guard generation == refreshGeneration else {
#if DEBUG
                print("[FanTeamsLoad] operation=refresh staleDrop source=\(source) generation=\(generation) current=\(refreshGeneration)")
#endif
                return
            }
            let previous = teams
            if nextTeams != teams {
                teams = nextTeams
            }
            if nextInvitations != invitations {
                invitations = nextInvitations
            }
            errorText = nil
            sectionRetryMessage = nil
            recomputeHomeItems()
            if nextTeams != previous {
                FanTeamIdentityRealtimeCoordinator.shared.publishDiffs(previous: previous, next: nextTeams)
            }
            await refreshManagedAccessOverlay(
                accountTeamIds: Set(nextTeams.map(\.id)),
                generation: generation
            )
#if DEBUG
            print("[FanTeamsLoad] operation=refresh success source=\(source) generation=\(generation) teams=\(nextTeams.count) homeItems=\(homeItems.count)")
#endif
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) {
#if DEBUG
                print("[FanTeamsLoad] operation=refresh cancelled source=\(source) generation=\(generation)")
#endif
                return
            }
            if FanTeamsLoadErrorPresentation.isMissingAuthSession(error) {
#if DEBUG
                print("[FanTeamsLoad] operation=refresh skippedUnauthenticated source=\(source) generation=\(generation)")
#endif
                if generation == refreshGeneration {
                    errorText = nil
                }
                return
            }
            guard generation == refreshGeneration else { return }
            let hasCachedTeams = !teams.isEmpty || !homeItems.isEmpty
#if DEBUG
            print(
                "[FanTeamsLoad] operation=refresh failed source=\(source) generation=\(generation) " +
                "hasCachedTeams=\(hasCachedTeams) surfaceError=\(surfaceError) " +
                "error=\(FanTeamsLoadErrorPresentation.debugDescription(error))"
            )
#endif
            FanTeamRPCTrace.log(
                step: "B.store.refresh.failed",
                rpc: "list_my_fan_teams",
                error: error,
                extra: "source=\(source) surfaceError=\(surfaceError) hasCachedTeams=\(hasCachedTeams)"
            )
            if MyTeamsRefreshPresentation.shouldKeepCachedTeams(hasCachedTeams: hasCachedTeams) {
                errorText = nil
                sectionRetryMessage = nil
                return
            }
            let message = FanTeamsLoadErrorPresentation.userFacingMessage(
                for: error,
                layer: .teamsReload
            )
            if MyTeamsRefreshPresentation.shouldShowSectionRetry(
                hasCachedTeams: false,
                isCancellation: false,
                isMissingAuth: false,
                didFail: true
            ) {
                sectionRetryMessage = message ?? L10n.t("fan_teams_refresh_failed")
            }
            // Never assign blocking store.errorText for automatic hydration.
            errorText = nil
        }
    }

    /// Loads managed-player Team access and rebuilds `homeItems` (no extra list_my_fan_teams).
    @MainActor
    private func refreshManagedAccessOverlay(accountTeamIds: Set<UUID>, generation: Int) async {
        let players = (try? await managedPlayerService.listMyManagedPlayers()) ?? []
        var viaNames: [UUID: [String]] = [:]
        var membershipByTeamId: [UUID: FanManagedPlayerTeamMembership] = [:]

        let managedService = managedPlayerService
        await withTaskGroup(of: (String, [FanManagedPlayerTeamMembership])?.self) { group in
            for player in players {
                let label = FanTeamHomeCatalog.compactManagedPlayerLabel(player)
                let playerId = player.id
                group.addTask {
                    let memberships = (try? await managedService.listTeamMemberships(
                        managedPlayerId: playerId
                    )) ?? []
                    return (label, memberships)
                }
            }
            for await payload in group {
                guard let (label, memberships) = payload else { continue }
                for membership in memberships {
                    viaNames[membership.teamId, default: []].append(label)
                    if membershipByTeamId[membership.teamId] == nil {
                        membershipByTeamId[membership.teamId] = membership
                    }
                }
            }
        }

        guard generation == refreshGeneration else { return }

        for key in viaNames.keys {
            viaNames[key] = FanTeamHomeCatalog.uniquePreservingOrder(viaNames[key] ?? [])
        }

        let missingIds = membershipByTeamId.keys.filter { !accountTeamIds.contains($0) }
        let hydrated = await service.hydrateGuardianHomeTeams(teamIds: Array(missingIds))
        guard generation == refreshGeneration else { return }

        var guardianOnly: [UUID: FanTeamSummary] = [:]
        for teamId in missingIds {
            guard let membership = membershipByTeamId[teamId] else { continue }
            let names = viaNames[teamId] ?? []
            guardianOnly[teamId] = FanTeamHomeCatalog.guardianOnlySummary(
                from: membership,
                hydrated: hydrated[teamId],
                viaNames: names
            )
            ManagedPlayerTeamAccessDebug.log(
                "accessReason=managed_player",
                detail: "teamID=\(teamId.uuidString.lowercased()) via=\(names.joined(separator: ","))"
            )
        }

        managedViaNamesByTeamId = viaNames
        guardianOnlyTeamsById = guardianOnly
        ManagedPlayerTeamAccessDebug.log(
            "myTeamsRefresh",
            detail: "accountTeamIDs=\(accountTeamIds.count) managedPlayerTeamIDs=\(membershipByTeamId.count) mergedMissing=\(missingIds.count) managedPlayerIDs=\(players.count)"
        )
        recomputeHomeItems()
    }

    @MainActor
    private func recomputeHomeItems() {
        var viaNames = managedViaNamesByTeamId
        for team in teams {
            let rpcNames = FanTeamHomeCatalog.uniquePreservingOrder(team.viaManagedPlayerNames)
            guard !rpcNames.isEmpty else { continue }
            let merged = FanTeamHomeCatalog.uniquePreservingOrder(
                (viaNames[team.id] ?? []) + rpcNames
            )
            viaNames[team.id] = merged
        }
        let next = FanTeamHomeCatalog.build(
            accountTeams: teams,
            guardianOnlyTeams: Array(guardianOnlyTeamsById.values),
            viaNamesByTeamId: viaNames
        )
        if next != homeItems {
            homeItems = next
        }
        ManagedPlayerTeamAccessDebug.log(
            "dedupeResultCount",
            detail: "teams=\(teams.count) guardianOnly=\(guardianOnlyTeamsById.count) homeItems=\(homeItems.count) direct=\(teams.filter(\.hasAccountSeat).count) managed=\(teams.filter { !$0.hasAccountSeat }.count)"
        )
    }

    func refreshInvitations(source: String = "unspecified") async {
        guard allowsAuthenticatedFetch else {
#if DEBUG
            print("[FanTeamsLoad] operation=refreshInvitations skippedUnauthenticated source=\(source)")
#endif
            return
        }
        let generation = refreshGeneration
        do {
            let next = try await service.listMyPendingInvitations()
            guard generation == refreshGeneration else { return }
            invitations = next
#if DEBUG
            print("[FanTeamsLoad] operation=refreshInvitations success source=\(source) count=\(invitations.count)")
#endif
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) {
#if DEBUG
                print("[FanTeamsLoad] operation=refreshInvitations cancelled source=\(source)")
#endif
                return
            }
            if FanTeamsLoadErrorPresentation.isMissingAuthSession(error) {
#if DEBUG
                print("[FanTeamsLoad] operation=refreshInvitations skippedUnauthenticated source=\(source)")
#endif
                return
            }
            // Keep existing list; surface only on full refresh / mutations.
#if DEBUG
            print("[FanTeamsLoad] operation=refreshInvitations failed source=\(source) error=\(error.localizedDescription)")
#endif
        }
    }

    func acceptInvitation(_ invitation: FanTeamInvitation) async throws {
        guard !busyInvitationIds.contains(invitation.id) else { return }
        busyInvitationIds.insert(invitation.id)
        defer { busyInvitationIds.remove(invitation.id) }
        _ = try await service.acceptInvitation(invitationId: invitation.invitationId)
        invitations.removeAll { $0.id == invitation.id }
        teams = try await service.listMyTeams()
        await refreshManagedAccessOverlay(
            accountTeamIds: Set(teams.map(\.id)),
            generation: refreshGeneration
        )
    }

    func declineInvitation(_ invitation: FanTeamInvitation) async throws {
        guard !busyInvitationIds.contains(invitation.id) else { return }
        busyInvitationIds.insert(invitation.id)
        defer { busyInvitationIds.remove(invitation.id) }
        try await service.declineInvitation(invitationId: invitation.invitationId)
        invitations.removeAll { $0.id == invitation.id }
    }

    func applyIdentityChange(_ change: FanTeamIdentityChange) {
        if let idx = teams.firstIndex(where: { $0.id == change.teamId }) {
            teams[idx] = teams[idx].applying(change)
        }
        if var guardian = guardianOnlyTeamsById[change.teamId] {
            guardian = guardian.applying(change)
            guardianOnlyTeamsById[change.teamId] = guardian
        }
        recomputeHomeItems()
    }

    func applyManagedPlayerAvatarChange(_ change: FanManagedPlayerAvatarChange) {
        teams = teams.map { $0.applyingManagedPlayerAvatarChange(change) }
        guardianOnlyTeamsById = guardianOnlyTeamsById.mapValues {
            $0.applyingManagedPlayerAvatarChange(change)
        }
        recomputeHomeItems()
    }
}

struct FanTeamInvitationCardView: View {
    let invitation: FanTeamInvitation
    let languageCode: String
    var isBusy: Bool = false
    var isHighlighted: Bool = false
    var onAccept: () -> Void
    var onDecline: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                FanTeamMarkView(
                    sport: invitation.sport,
                    logoURL: invitation.logoURL,
                    logoThumbnailURL: invitation.logoThumbnailURL,
                    colorHex: invitation.colorHex,
                    size: 48,
                    preferDetailURL: false
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(invitation.teamName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(metaLine)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                    Text(
                        String(
                            format: L10n.t("fan_teams_invitation_invited_by_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            invitation.inviterDisplayName
                        )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onDecline) {
                    Text(L10n.t("fan_teams_decline", languageCode: languageCode))
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button(action: onAccept) {
                    Text(L10n.t("fan_teams_accept", languageCode: languageCode))
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(FGColor.accentGreen)
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .fanTeamIdentityCardChrome(
            colorHex: invitation.colorHex,
            colorScheme: colorScheme,
            highlightedBorder: isHighlighted
        )
        .softCardShadow()
        .accessibilityElement(children: .combine)
    }

    private var metaLine: String {
        FanTeamMetaLine.compose(
            competitionLevel: nil,
            sport: invitation.sport,
            memberCount: invitation.memberCount,
            languageCode: languageCode
        )
    }
}

/// FanGeo card chrome around the shared `CompactNativeAdCard` for Teams home.
/// Not a second native-ad implementation — same AdMob host as Chat / Going / venue comments.
private struct TeamsHomeNativeAdCard: View {
    let slot: ChatMyTeamsNativeAdSlot

    @Environment(\.colorScheme) private var colorScheme
    @State private var layoutWidth: CGFloat = 320
    @State private var adLoaded = false
    @State private var adFailed = false

    private var cardCornerRadius: CGFloat { 24 }
    private var borderOpacity: Double { colorScheme == .dark ? 0.28 : 0.12 }

    var body: some View {
        Group {
            if !adFailed {
                CompactNativeAdCard(
                    placement: ChatMyTeamsAdPlacement.placementID,
                    hostTabRaw: MainTabView.AppTab.teams.rawValue,
                    slotIndex: slot.slotIndex,
                    layoutWidth: max(CompactNativeAdLayout.minimumRequestDimension, layoutWidth),
                    prefersLightChrome: colorScheme == .light,
                    animatesLoadState: false,
                    onAdLoaded: {
                        adLoaded = true
                        adFailed = false
#if DEBUG
                        if AdDiagnostics.enabled {
                            print(
                                "[TeamsHomeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) adLoaded=true slotIndex=\(slot.slotIndex) afterTeam=\(slot.insertedAfterTeamPosition)"
                            )
                        }
#endif
                    },
                    onAdFailed: { error in
                        adFailed = true
                        adLoaded = false
#if DEBUG
                        if AdDiagnostics.enabled {
                            print(
                                "[TeamsHomeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) adFailed=true slotIndex=\(slot.slotIndex) error=\(error.localizedDescription)"
                            )
                        }
#endif
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: adLoaded ? CompactNativeAdLayout.preferredHeight : 0)
                .opacity(adLoaded ? 1 : 0)
                .allowsHitTesting(adLoaded)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: displayHeight)
        .padding(.vertical, 2)
        .background {
            if adLoaded {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
        }
        .overlay {
            if adLoaded {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(borderOpacity),
                        lineWidth: 1
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .shadow(
            color: Color.black.opacity(adLoaded ? (colorScheme == .dark ? 0.28 : 0.07) : 0),
            radius: adLoaded ? 12 : 0,
            x: 0,
            y: adLoaded ? 5 : 0
        )
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateLayoutWidth(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, newWidth in
                        updateLayoutWidth(newWidth)
                    }
            }
        }
        // Ordinal identity is stable across All/Managing/Joined so loaded ads reuse.
        .id(slot.id)
        .onChange(of: slot.insertedAfterTeamPosition) { _, _ in
            // Same ordinal reused under a different feed composition — keep loaded ads;
            // only clear a sticky failure so the next filter can request again if needed.
            if adFailed {
                adFailed = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sponsored advertisement")
        .accessibilityHidden(!adLoaded)
    }

    private var displayHeight: CGFloat {
        if adFailed { return 0 }
        return adLoaded ? CompactNativeAdLayout.preferredHeight : 0
    }

    private func updateLayoutWidth(_ width: CGFloat) {
        guard width > 0, abs(layoutWidth - width) > 0.5 else { return }
        layoutWidth = width
    }
}

struct MyTeamCardView: View {
    let team: FanTeamSummary
    var relationship: FanTeamHomeRelationship
    let languageCode: String
    var displayRefreshToken: UUID? = nil
    var chromeAccent: Color = Color(red: 0.52, green: 0.38, blue: 0.95)
    var onOpenDetail: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    init(
        team: FanTeamSummary,
        relationship: FanTeamHomeRelationship? = nil,
        languageCode: String,
        displayRefreshToken: UUID? = nil,
        chromeAccent: Color = Color(red: 0.52, green: 0.38, blue: 0.95),
        onOpenDetail: (() -> Void)? = nil
    ) {
        self.team = team
        self.relationship = relationship
            ?? FanTeamHomeCatalog.relationship(forAccountRole: team.myRole)
        self.languageCode = languageCode
        self.displayRefreshToken = displayRefreshToken
        self.chromeAccent = chromeAccent
        self.onOpenDetail = onOpenDetail
    }

    private var teamAccent: Color {
        if let hex = team.colorHex, let color = Color(fanTeamHex: hex) { return color }
        return chromeAccent
    }

    private var visibleMemberPreviews: [FanTeamMemberAvatarPreview] {
        FanTeamHomeMemberAvatarStack.visiblePreviews(
            from: team.memberAvatarPreviews,
            memberCount: team.memberCount
        )
    }

    private var avatarOverflowCount: Int {
        let visibleCount = visibleMemberPreviews.isEmpty
            ? min(
                FanTeamHomeMemberAvatarStack.maxVisibleAvatars,
                max(0, team.memberCount)
            )
            : visibleMemberPreviews.count
        return FanTeamHomeMemberAvatarStack.overflowCount(
            memberCount: team.memberCount,
            visiblePreviewCount: visibleCount
        )
    }

    var body: some View {
        Button {
            onOpenDetail?()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                topIdentityRow
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                Divider()
                    .opacity(colorScheme == .dark ? 0.35 : 0.45)
                    .padding(.horizontal, 14)

                memberPresenceRow
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(cardBackgroundGradient)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    teamAccent.opacity(colorScheme == .dark ? 0.28 : 0.16),
                    lineWidth: 1
                )
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.08),
            radius: 14,
            x: 0,
            y: 6
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var cardBackgroundGradient: LinearGradient {
        let top = teamAccent.opacity(colorScheme == .dark ? 0.18 : 0.10)
        let bottom = FGColor.cardBackground(colorScheme)
            .opacity(colorScheme == .dark ? 0.92 : 1)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private var topIdentityRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                FanTeamMarkView(
                    sport: team.sport,
                    logoURL: team.logoURL,
                    logoThumbnailURL: team.logoThumbnailURL,
                    colorHex: team.colorHex,
                    size: 52,
                    preferDetailURL: false,
                    displayRefreshToken: displayRefreshToken
                )
                if FanTeamHomeRelationshipPresentation.showsCrownAccessory(relationship) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(5)
                        .background(chromeAccent, in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 1.5)
                        }
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(team.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)

                Text(metaLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                metadataBadgesRow

                if let pendingLine {
                    Label {
                        Text(pendingLine)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    } icon: {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.9))
                    }
                    .labelStyle(.titleAndIcon)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.7))
                .accessibilityHidden(true)
        }
    }

    /// Avatar stack + member count only — no action controls.
    private var memberPresenceRow: some View {
        HStack(spacing: 10) {
            memberAvatarStack
                .accessibilityHidden(true)

            Text(membersCountLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
    }

    private var memberAvatarStack: some View {
        let size = FanTeamHomeMemberAvatarStack.avatarSize
        let visible = visibleMemberPreviews
        let overflow = avatarOverflowCount
        // Before 20260966 (or empty preview payload), keep a count-matched silhouette
        // fallback so layout doesn't collapse — never invent fake people photos.
        let fallbackCount = visible.isEmpty
            ? min(FanTeamHomeMemberAvatarStack.maxVisibleAvatars, max(0, team.memberCount))
            : 0

        return HStack(spacing: FanTeamHomeMemberAvatarStack.overlap) {
            if !visible.isEmpty {
                ForEach(visible) { preview in
                    realMemberAvatar(preview, size: size)
                }
            } else {
                ForEach(0..<fallbackCount, id: \.self) { index in
                    fallbackMemberAvatar(index: index, size: size)
                }
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(chromeAccent)
                    .frame(width: size, height: size)
                    .background(
                        chromeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        in: Circle()
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(
                                FGColor.cardBackground(colorScheme),
                                lineWidth: 1.5
                            )
                    }
                    .accessibilityHidden(true)
            }
        }
    }

    private func realMemberAvatar(_ preview: FanTeamMemberAvatarPreview, size: CGFloat) -> some View {
        ManagedPlayerAvatarView(
            managedPlayerId: preview.managedPlayerId,
            avatarURL: preview.avatarURL,
            avatarThumbnailURL: preview.avatarThumbnailURL,
            displayName: preview.displayName,
            size: size
        )
        .overlay {
            Circle()
                .strokeBorder(
                    FGColor.cardBackground(colorScheme),
                    lineWidth: 1.5
                )
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06),
            radius: 1.5,
            x: 0,
            y: 1
        )
        .accessibilityHidden(true)
    }

    private func fallbackMemberAvatar(index: Int, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(teamAccent.opacity(0.16 + Double(index) * 0.08))
            Image(systemName: "person.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(teamAccent.opacity(0.85))
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .strokeBorder(
                    FGColor.cardBackground(colorScheme),
                    lineWidth: 1.5
                )
        }
        .accessibilityHidden(true)
    }

    private var metaLine: String {
        let sport = AppSportCatalog.displayLabel(forSportToken: team.sport)
        let members = String(
            format: L10n.t("fan_teams_members_count_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(team.memberCount)
        )
        return "\(sport) • \(members)"
    }

    private var membersCountLine: String {
        String(
            format: L10n.t("fan_teams_members_count_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(team.memberCount)
        )
    }

    private var metadataBadgesRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                if FanTeamPrivacyPresentation.showsPrivateTeamBadge(for: team) {
                    privacyBadge
                }
                relationshipBadge
            }
            VStack(alignment: .leading, spacing: 4) {
                if FanTeamPrivacyPresentation.showsPrivateTeamBadge(for: team) {
                    privacyBadge
                }
                relationshipBadge
            }
        }
    }

    private var privacyBadge: some View {
        Text(L10n.t("fan_teams_private_team", languageCode: languageCode))
            .font(.caption2.weight(.bold))
            .foregroundStyle(chromeAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                chromeAccent.opacity(colorScheme == .dark ? 0.22 : 0.12),
                in: Capsule(style: .continuous)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var relationshipBadge: some View {
        let title = FanTeamHomeRelationshipPresentation.title(
            relationship,
            languageCode: languageCode
        )
        let isManaging = relationship.isManaging
        return HStack(spacing: 4) {
            if let symbol = FanTeamHomeRelationshipPresentation.systemImage(relationship) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(title)
                .font(.caption2.weight(isManaging ? .bold : .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(
            isManaging
                ? chromeAccent
                : FGColor.secondaryText(colorScheme)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isManaging ? chromeAccent : FGColor.secondaryText(colorScheme))
                .opacity(colorScheme == .dark ? 0.22 : 0.10),
            in: Capsule(style: .continuous)
        )
        .accessibilityLabel(
            FanTeamHomeRelationshipPresentation.accessibilityLabel(
                relationship,
                languageCode: languageCode
            )
        )
    }

    private var pendingLine: String? {
        FanTeamPendingInvitationCopy.line(
            count: team.pendingInvitationCount,
            canManage: team.canManage,
            languageCode: languageCode
        )
    }

    private var cardAccessibilityLabel: String {
        var parts = [team.name, metaLine]
        if FanTeamPrivacyPresentation.showsPrivateTeamBadge(for: team) {
            parts.append(L10n.t("fan_teams_private_team", languageCode: languageCode))
        }
        parts.append(
            FanTeamHomeRelationshipPresentation.accessibilityLabel(
                relationship,
                languageCode: languageCode
            )
        )
        if let pendingLine { parts.append(pendingLine) }
        parts.append(
            FanTeamHomeMemberAvatarStack.accessibilityLabel(
                memberCount: team.memberCount,
                visibleNames: visibleMemberPreviews.map(\.displayName),
                languageCode: languageCode
            )
        )
        return parts.joined(separator: ". ")
    }
}

// MARK: - Create Team

struct CreateFanTeamSheet: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    /// `(teamId, optionalLogoWarning)`. Logo upload failure does not roll back Team creation.
    var onCreated: (UUID, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var name = ""
    @State private var sport = "Soccer"
    @State private var colorHex = FanTeamColorPalette.defaultHex
    @State private var competitionLevel: PickupCompetitionLevel? = nil
    @State private var selectedIds: Set<UUID> = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var localPreviewImage: UIImage?
    @State private var isLoadingPhoto = false
    @State private var isSubmitting = false
    @State private var errorText: String?

    private let service = FanTeamsService()

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var sportOptions: [String] {
        AppSportCatalog.formPickerSportsOrdered.map {
            AppSportCatalog.displayLabel(forSportToken: $0)
        }
    }

    private var candidates: [ChatViewModel.FriendDisplay] {
        chatViewModel.friends.filter {
            !$0.isGroupConversation
                && !$0.preview.isBusinessAccount
                && !$0.preview.isBusinessVenueConversation
                && !$0.preview.isDeleted
                && chatViewModel.chipKind(forOtherUserId: $0.preview.id) == .friends
                && !chatViewModel.isEitherDirectionBlocked(with: $0.preview.id)
        }
    }

    private var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSubmitting
            && !isLoadingPhoto
            && trimmed.count >= 1
            && trimmed.count <= 60
            && selectedIds.count <= 49
    }

    private var hasPendingLocalPhoto: Bool {
        FanTeamCreateLogoPolicy.shouldUploadAfterCreate(pendingImageData: pendingImageData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    createPhotoSection
                } footer: {
                    Text(L10n.t("fan_teams_logo_optional_footer", languageCode: languageCode))
                }

                Section {
                    TextField(L10n.t("fan_teams_name_placeholder", languageCode: languageCode), text: $name)
                        .textInputAutocapitalization(.words)
                    Picker(L10n.t("fan_teams_sport", languageCode: languageCode), selection: $sport) {
                        ForEach(sportOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    ColorPicker(
                        L10n.t("fan_teams_color_optional", languageCode: languageCode),
                        selection: Binding(
                            get: { Color(fanTeamHex: colorHex) ?? FGColor.accentGreen },
                            set: {
                                colorHex = FanTeamColorPalette.normalized($0.fanTeamHexString)
                                    ?? FanTeamColorPalette.defaultHex
                            }
                        ),
                        supportsOpacity: false
                    )
                    HStack {
                        Text(L10n.t("pickup_form_competition_level", languageCode: languageCode))
                        Spacer(minLength: 12)
                        PickupCompetitionLevelMenuPicker(
                            selection: $competitionLevel,
                            languageCode: languageCode
                        )
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text(L10n.t("fan_teams_create_details_section", languageCode: languageCode))
                }

                Section {
                    ForEach(candidates) { friend in
                        Button {
                            toggle(friend.preview.id)
                        } label: {
                            HStack(spacing: 12) {
                                ProfileAvatarView(preview: friend.preview, size: 36)
                                Text(friend.preview.displayName)
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer()
                                Image(systemName: selectedIds.contains(friend.preview.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        selectedIds.contains(friend.preview.id)
                                            ? FGColor.accentGreen
                                            : FGColor.mutedText(colorScheme)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.t("fan_teams_invite_teammates", languageCode: languageCode))
                } footer: {
                    Text(L10n.t("fan_teams_invite_teammates_footer", languageCode: languageCode))
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(FGColor.dangerRed)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(L10n.t("fan_teams_create", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("fan_teams_create_action", languageCode: languageCode)) {
                        Task { await create() }
                    }
                    .disabled(!canCreate)
                    .fontWeight(.semibold)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .onAppear {
                if !sportOptions.contains(sport), let first = sportOptions.first {
                    sport = first
                }
            }
            .onChange(of: selectedPhotoItem) { _, item in
                Task { await loadPickedPhoto(item) }
            }
        }
    }

    private var createPhotoSection: some View {
        VStack(spacing: 10) {
            FanTeamMarkView(
                sport: sport,
                logoURL: nil,
                logoThumbnailURL: nil,
                colorHex: colorHex,
                size: 88,
                preferDetailURL: true,
                localPreviewImage: localPreviewImage
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("fan_teams_logo_a11y", languageCode: languageCode))

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text(
                    L10n.t(
                        FanTeamCreateLogoPolicy.photoActionTitleKey(hasPendingLocalPhoto: hasPendingLocalPhoto),
                        languageCode: languageCode
                    )
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.accentGreen)
            }
            .disabled(isSubmitting || isLoadingPhoto)
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.t(
                    FanTeamCreateLogoPolicy.photoActionAccessibilityKey(hasPendingLocalPhoto: hasPendingLocalPhoto),
                    languageCode: languageCode
                )
            )

            if hasPendingLocalPhoto {
                Button(role: .destructive) {
                    pendingImageData = nil
                    localPreviewImage = nil
                    selectedPhotoItem = nil
                } label: {
                    Text(L10n.t("fan_teams_remove_photo", languageCode: languageCode))
                        .font(.caption.weight(.semibold))
                }
                .disabled(isSubmitting || isLoadingPhoto)
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("fan_teams_remove_photo_a11y", languageCode: languageCode))
            }

            if isLoadingPhoto {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if selectedIds.count < 49 {
            selectedIds.insert(id)
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                errorText = L10n.t("fan_teams_photo_load_failed", languageCode: languageCode)
                return
            }
            // Local-only until Create succeeds — do not upload on every picker change.
            pendingImageData = data
            localPreviewImage = UIImage(data: data)
            errorText = nil
        } catch {
            errorText = L10n.t("fan_teams_photo_load_failed", languageCode: languageCode)
        }
    }

    private func create() async {
        guard canCreate else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if ModerationService.containsProfanity(trimmedName) {
            errorText = ModerationService.profanityRejectionUserMessage()
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        let normalizedColor = FanTeamColorPalette.normalized(colorHex) ?? FanTeamColorPalette.defaultHex
        let trimmedSport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPendingImage = pendingImageData

        do {
            // 1) Create Team (+ invitations / Team Chat via existing RPC). Logo URLs stay nil.
            let id = try await service.createTeam(
                name: trimmedName,
                sport: trimmedSport,
                memberIds: Array(selectedIds),
                colorHex: normalizedColor,
                competitionLevel: competitionLevel
            )
            await mapViewModel.awardFanXP(
                source: FanXPSource.teamCreated,
                sourceId: id
            )

            var logoWarning: String?
            // 2–4) Upload final local image into fan-team-logos/{team_id}/… then identity RPC.
            if FanTeamCreateLogoPolicy.shouldUploadAfterCreate(pendingImageData: finalPendingImage),
               let finalPendingImage {
                logoWarning = await attachLogoAfterCreate(
                    teamId: id,
                    trimmedName: trimmedName,
                    trimmedSport: trimmedSport,
                    normalizedColor: normalizedColor,
                    imageData: finalPendingImage
                )
            }

            onCreated(id, logoWarning)
            dismiss()
        } catch {
            if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
        }
    }

    /// Best-effort logo attach. Never deletes the Team on failure.
    private func attachLogoAfterCreate(
        teamId: UUID,
        trimmedName: String,
        trimmedSport: String,
        normalizedColor: String,
        imageData: Data
    ) async -> String? {
        let warning = L10n.t("fan_teams_created_photo_upload_failed", languageCode: languageCode)
        let uploaded: FanTeamsService.UploadedTeamLogoURLs
        do {
            uploaded = try await service.uploadTeamLogo(teamId: teamId, imageData: imageData)
        } catch {
            return warning
        }

        do {
            try await service.updateTeamIdentity(
                teamId: teamId,
                name: trimmedName,
                sport: trimmedSport,
                colorHex: normalizedColor,
                logoURL: uploaded.fullURL,
                logoThumbnailURL: uploaded.thumbnailURL,
                competitionLevel: competitionLevel,
                updateCompetitionLevel: false
            )
        } catch {
            await mapViewModel.deleteStorageFile(
                publicURL: uploaded.fullURL,
                bucketName: FanTeamsService.teamLogoStorageBucket
            )
            if uploaded.thumbnailURL != uploaded.fullURL {
                await mapViewModel.deleteStorageFile(
                    publicURL: uploaded.thumbnailURL,
                    bucketName: FanTeamsService.teamLogoStorageBucket
                )
            }
            return warning
        }

        let refreshToken = UUID()
        if let created = (try? await service.listMyTeams())?.first(where: { $0.id == teamId }) {
            let change = FanTeamIdentityChange(
                teamId: teamId,
                conversationId: created.groupConversationId,
                name: trimmedName,
                sport: trimmedSport,
                colorHex: normalizedColor,
                competitionLevel: competitionLevel,
                logoURL: uploaded.fullURL,
                logoThumbnailURL: uploaded.thumbnailURL,
                previousLogoURL: nil,
                previousLogoThumbnailURL: nil,
                displayRefreshToken: refreshToken,
                artworkReplaced: true
            )
            FanTeamIdentityChangeCenter.postIdentityChange(change)
        }

        if let preview = localPreviewImage {
            let warmURLs = ImageDisplayURL.displayURLs(
                thumbnail: uploaded.thumbnailURL,
                full: uploaded.fullURL,
                refreshToken: refreshToken
            )
            if !warmURLs.isEmpty {
                await DiscoverMapImageCache.shared.store(preview, for: warmURLs, bucket: .venue)
            }
        }
        return nil
    }
}

/// Create-time Team logo staging rules (local-only until Create succeeds).
enum FanTeamCreateLogoPolicy {
    static func shouldUploadAfterCreate(pendingImageData: Data?) -> Bool {
        guard let pendingImageData else { return false }
        return !pendingImageData.isEmpty
    }

    static func photoActionTitleKey(hasPendingLocalPhoto: Bool) -> String {
        hasPendingLocalPhoto ? "fan_teams_change_photo" : "fan_teams_add_photo"
    }

    static func photoActionAccessibilityKey(hasPendingLocalPhoto: Bool) -> String {
        hasPendingLocalPhoto ? "fan_teams_change_photo_a11y" : "fan_teams_add_photo_a11y"
    }
}

// MARK: - Team detail

struct FanTeamDetailSheet: View {
    let summary: FanTeamSummary
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    var initialTab: FanTeamDetailTab = .overview
    var onOpenChat: (FanTeamChatContext) -> Void
    var onTeamsChanged: () -> Void
    var onTeamDeleted: () -> Void = {}
    /// Home catalog refresh that must not surface "Couldn't refresh your Teams"
    /// after a membership mutation that already committed.
    var onQuietTeamsRefresh: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var detail: FanTeamDetail?
    @State private var selectedTab: FanTeamDetailTab
    /// Per-user Overview clears for Team announcements (server-backed).
    @State private var clearedAnnouncementIds: Set<UUID> = []
    @State private var isClearingAnnouncementId: UUID?

    init(
        summary: FanTeamSummary,
        mapViewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        initialTab: FanTeamDetailTab = .overview,
        onOpenChat: @escaping (FanTeamChatContext) -> Void,
        onTeamsChanged: @escaping () -> Void,
        onTeamDeleted: @escaping () -> Void = {},
        onQuietTeamsRefresh: @escaping () -> Void = {}
    ) {
        self.summary = summary
        self.mapViewModel = mapViewModel
        self.chatViewModel = chatViewModel
        self.initialTab = initialTab
        self.onOpenChat = onOpenChat
        self.onTeamsChanged = onTeamsChanged
        self.onTeamDeleted = onTeamDeleted
        self.onQuietTeamsRefresh = onQuietTeamsRefresh
        _selectedTab = State(initialValue: initialTab)
        TeamDetailCrashTrace.log(
            "detailSheetInit",
            details: "teamID=\(summary.id.uuidString.lowercased()) teamName=\(summary.name) tab=\(initialTab.rawValue)"
        )
    }
    @State private var isLoading = true
    @State private var errorText: String?
    /// Active seats on THIS Team held by players the viewer guards. Empty for
    /// every user without managed players, which hides the Overview card.
    @State private var managedPlayerSeats: [FanTeamManagedPlayerSeat] = []
    /// Authoritative in-session Player Info subject (`membership_id`); hydrated from durable store.
    @State private var selectedPlayerInfoMembershipId: UUID?
    @State private var showingPlayerInfoChangeSheet = false
    @State private var isCommittingPlayerInfoSelection = false
    /// True after at least one seats refresh attempt finished for this Team detail session.
    @State private var managedPlayerSeatsCatalogComplete = false
    @StateObject private var playerInfoSelectionGuard = FanTeamPlayerInfoSelectionGuard()
    @State private var showingMyPlayers = false
    @State private var pickupCreateFormMode: PickupGameFormMode?
    @State private var pickupDetailNav: PickupDetailNavigationToken?
    /// Set before dismissing Event detail so `sheet(onDismiss:)` can select Chat without asyncAfter.
    @State private var pendingSelectChatAfterEventDetailDismiss = false
    @State private var pendingSelectChatEventId: UUID?
    @State private var organizerJoinRequestsGame: PickupGameRow?
    @State private var showingAddMembers = false
    @State private var showingAddManagedPlayers = false
    @State private var showingManagePlayerMembership = false
    /// Global My Players count (any Team). Used for Overview manage visibility when none are on this Team.
    @State private var viewerManagedPlayerCount = 0
    /// Full managed-player catalog for Overview “Players from Your Account” (includes off-team).
    @State private var viewerManagedPlayers: [FanManagedPlayer] = []
    @State private var showingEditTeam = false
    @State private var showingReportTeam = false
    @State private var showingNotifications = false
    @State private var showLeaveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showReportSuccessAlert = false
    @State private var showDeleteSuccessAlert = false
    @State private var isLeaving = false
    @State private var isDeleting = false
    @State private var markRefreshToken: UUID?
    @State private var pendingInvitations: [FanTeamPendingInvitation] = []
    @State private var busyPendingInvitationIds: Set<UUID> = []
    @State private var showResendInviteSuccessAlert = false
    @State private var resendCooldownUntilByInvitationId: [UUID: Date] = [:]
    @State private var memberPendingRemoval: FanTeamMember?
    @State private var memberPendingPlayerInformation: FanTeamMember?
    @State private var memberPendingRoleEdit: FanTeamMember?
    @State private var isMessagingMember = false
    @State private var isRemovingMember = false
    @State private var isSavingPlayerNumber = false
    @State private var isSavingPreferredPosition = false
    @State private var isSavingTeamRole = false
    @State private var isSavingPermissions = false
    /// Local-only Team → Games presentation filters (does not refetch `list_fan_team_games`).
    @State private var gamesFilter = FanTeamGamesFilterState.default
    @State private var showGamesCustomDateSheet = false
    @State private var gamesFilterClockTick = Date()
    /// Embedded Team Chat composer focus — collapse identity header so the shared
    /// `safeAreaInset` composer can sit flush above the keyboard (iMessage-style).
    @State private var isEmbeddedChatComposerFocused = false

    private let service = FanTeamsService()
    private let gamesFilterMinuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var team: FanTeamSummary {
        detail?.summary ?? summary
    }

    private var chatContext: FanTeamChatContext {
        FanTeamChatContext(from: team)
    }

    /// Team accent for restrained Overview chrome; falls back to FanGeo green when unset.
    private var teamAccent: Color {
        FanTeamColorTheme.accentColor(colorHex: team.colorHex, colorScheme: colorScheme)
            ?? FGColor.accentGreen
    }

    /// Hide the large Team identity card while typing in embedded Chat.
    /// Collapse must not unmount `GroupChatView` or race the keyboard animation.
    private var showsTeamIdentityHeader: Bool {
        !(selectedTab == .chat && isEmbeddedChatComposerFocused)
    }

    var body: some View {
        let _ = TeamDetailCrashTrace.logOnceBody(teamID: summary.id, tab: selectedTab.rawValue, hasDetail: detail != nil)
        let _ = {
#if DEBUG
            TeamDetailRenderDiagnostic.logMode()
#endif
        }()
        NavigationStack {
            teamDetailBodyRoot
                .sheet(item: $pickupCreateFormMode) { mode in
                    NavigationStack {
                        SettingsPickupGameFormView(
                            viewModel: mapViewModel,
                            mode: mode,
                            creationContext: .team(PickupGameTeamCreationContext(from: team)),
                            onCreated: { created in
#if DEBUG
                                if created.gameFormat == .announcement {
                                    print(
                                        "[TeamAnnouncement] overviewRefresh " +
                                        "announcementID=\(created.id.uuidString.lowercased()) " +
                                        "teamID=\(team.id.uuidString.lowercased())"
                                    )
                                }
#endif
                            }
                        ) {
                            pickupCreateFormMode = nil
                            onTeamsChanged()
                            Task { await reload() }
                        }
                    }
                }
                .sheet(item: $pickupDetailNav, onDismiss: {
                    applyPendingTeamChatTabAfterEventDetailDismissIfNeeded()
                    Task { await reload() }
                }) { token in
                    DiscoverPickupGameDetailSheet(
                        viewModel: mapViewModel,
                        token: token,
                        onRequestTeamDetailChatTab: { requestedTeamId, eventId in
                            requestEmbeddedTeamChatTab(
                                requestedTeamId: requestedTeamId,
                                eventId: eventId
                            )
                        }
                    )
                        .environmentObject(chatViewModel)
                }
                .sheet(item: $organizerJoinRequestsGame, onDismiss: {
                    Task { await reload() }
                }) { game in
                    PickupOrganizerRequestsSheet(viewModel: mapViewModel, game: game)
                        .environmentObject(mapViewModel)
                }
                .sheet(isPresented: $showingAddMembers) {
                    AddFanTeamMembersSheet(teamId: team.id, chatViewModel: chatViewModel) {
                        onTeamsChanged()
                        Task { await reload() }
                    }
                }
                .sheet(isPresented: $showingAddManagedPlayers) {
                    NavigationStack {
                        AddManagedPlayersToTeamSheet(
                            teamId: team.id,
                            teamName: team.name,
                            languageCode: languageCode,
                            alreadyOnTeamManagedPlayerIds: Set(
                                (detail?.members ?? []).compactMap(\.managedPlayerId)
                                    + managedPlayerSeats.map(\.managedPlayerId)
                            ),
                            onAdded: { addedIds in
                                onTeamsChanged()
                                Task {
                                    await reload()
                                    await refreshManagedPlayerSeats()
#if DEBUG
                                    print(
                                        "[ManagedPlayerTeamDebug] owner_direct_add_refresh " +
                                        "team_id=\(team.id.uuidString.lowercased()) " +
                                        "added_count=\(addedIds.count) " +
                                        "list_my_managed_players_on_team_count=\(managedPlayerSeats.count) " +
                                        "eligibleSubjects=\(overviewPlayerInfoSubjects.count)"
                                    )
#endif
                                }
                            }
                        )
                    }
                    .onAppear {
                        logManagedPlayerTeamAttachmentDebug(source: "addManagedPlayersSheet.appear")
                    }
                }
                .sheet(isPresented: $showingManagePlayerMembership) {
                    FanTeamPlayerMembershipManageSheet(
                        teamId: team.id,
                        teamName: team.name,
                        languageCode: languageCode,
                        accent: teamAccent,
                        myselfDisplayName: viewerAccountSeatMember?.displayName
                            ?? mapViewModel.currentUserDisplayName,
                        myselfUserId: mapViewModel.currentUserAuthId
                            ?? viewerAccountSeatMember?.userId,
                        myselfAvatarURL: viewerAccountSeatMember?.avatarURL
                            ?? mapViewModel.currentUserAvatarURL.nilIfEmpty,
                        myselfAvatarThumbnailURL: viewerAccountSeatMember?.avatarThumbnailURL
                            ?? mapViewModel.currentUserAvatarThumbnailURL.nilIfEmpty,
                        myselfIsPlayer: viewerAccountSeatMember?.isPlayer ?? false,
                        onMembershipChanged: { appliedMyselfIsPlayer in
                            if appliedMyselfIsPlayer == true {
                                Task {
                                    await mapViewModel.awardFanXP(
                                        source: FanXPSource.teamJoinPlayer,
                                        sourceId: team.id
                                    )
                                }
                            }
                            refreshAfterPlayerMembershipChange(
                                appliedMyselfIsPlayer: appliedMyselfIsPlayer
                            )
                        },
                        onAddManagedPlayer: {
                            showingManagePlayerMembership = false
                            showingMyPlayers = true
                        }
                    )
                }
                .sheet(isPresented: $showingMyPlayers) {
                    NavigationStack {
                        MyPlayersView(
                            languageCode: languageCode,
                            mapViewModel: mapViewModel,
                            chatViewModel: chatViewModel,
                            knownTeams: [team],
                            currentTeamId: team.id,
                            onOpenTeamChat: { context in
                                showingMyPlayers = false
                                onOpenChat(context)
                            },
                            onTeamsChanged: {
                                onTeamsChanged()
                                Task { await reload() }
                            },
                            onRevealCurrentTeam: {
                                showingMyPlayers = false
                            }
                        )
                    }
                    .onDisappear { Task { await refreshManagedPlayerSeats() } }
                }
                .sheet(isPresented: $showingPlayerInfoChangeSheet) {
                    FanTeamPlayerInfoChangeSheet(
                        subjects: overviewPlayerInfoSubjects,
                        selectedMembershipId: selectedPlayerInfoMembershipId,
                        languageCode: languageCode,
                        isBusy: isCommittingPlayerInfoSelection
                    ) { membershipId in
                        commitPlayerInfoSelection(membershipId)
                    }
                }
                .sheet(isPresented: $showingEditTeam) {
                    EditFanTeamSheet(team: team, mapViewModel: mapViewModel) { updated in
                        if var detail {
                            detail.summary = updated
                            self.detail = detail
                        }
                        onTeamsChanged()
                    }
                }
                .sheet(isPresented: $showingReportTeam) {
                    ReportFanTeamSheet(teamId: team.id) {
                        showingReportTeam = false
                        showReportSuccessAlert = true
                    }
                }
                .sheet(isPresented: $showingNotifications) {
                    FanTeamNotificationsSheet(team: team) { muted in
                        if var detail {
                            detail.summary = detail.summary.applyingPushNotificationsMuted(muted)
                            self.detail = detail
                        }
                        onTeamsChanged()
                    }
                }
                .confirmationDialog(
                    leaveConfirmTitle,
                    isPresented: $showLeaveConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("fan_teams_leave", languageCode: languageCode), role: .destructive) {
                        Task { await leaveTeam() }
                    }
                    Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
                } message: {
                    Text(L10n.t("fan_teams_leave_confirm_message", languageCode: languageCode))
                }
                .confirmationDialog(
                    deleteConfirmTitle,
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("fan_teams_delete", languageCode: languageCode), role: .destructive) {
                        Task { await deleteTeam() }
                    }
                    Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
                } message: {
                    Text(L10n.t("fan_teams_delete_confirm_message", languageCode: languageCode))
                }
                .alert(
                    L10n.t("fan_teams_report_success_title", languageCode: languageCode),
                    isPresented: $showReportSuccessAlert
                ) {
                    Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
                } message: {
                    Text(L10n.t("fan_teams_report_success_body", languageCode: languageCode))
                }
                .alert(
                    L10n.t("fan_teams_deleted_title", languageCode: languageCode),
                    isPresented: $showDeleteSuccessAlert
                ) {
                    Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {
                        onTeamDeleted()
                        dismiss()
                    }
                } message: {
                    Text(L10n.t("fan_teams_deleted_success_body", languageCode: languageCode))
                }
                .onReceive(NotificationCenter.default.publisher(for: .fanTeamDeletedPushArrivedInForeground)) { note in
                    let teamIdRaw = (note.userInfo?[FanTeamDeletedNotificationDeepLinkPayload.teamIDKey] as? String) ?? ""
                    guard let teamId = UUID(uuidString: teamIdRaw), teamId == team.id else { return }
                    onTeamDeleted()
                    dismiss()
                }
                .alert(
                    L10n.t("fan_teams_error_title", languageCode: languageCode),
                    isPresented: Binding(
                        get: { errorText != nil },
                        set: { if !$0 { errorText = nil } }
                    )
                ) {
                    Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
                } message: {
                    Text(errorText ?? "")
                }
                .alert(
                    L10n.t("fan_teams_invitation_resent", languageCode: languageCode),
                    isPresented: $showResendInviteSuccessAlert
                ) {
                    Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
                }
                .alert(
                    removeMemberConfirmTitle,
                    isPresented: Binding(
                        get: { memberPendingRemoval != nil },
                        set: { if !$0 { memberPendingRemoval = nil } }
                    )
                ) {
                    Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {
                        memberPendingRemoval = nil
                    }
                    Button(L10n.t("fan_teams_remove_member_confirm_action", languageCode: languageCode), role: .destructive) {
                        guard let member = memberPendingRemoval else { return }
                        memberPendingRemoval = nil
                        Task { await removeRosterMember(member) }
                    }
                } message: {
                    Text(L10n.t("fan_teams_remove_member_confirm_body", languageCode: languageCode))
                }
        }
    }

    /// Confirmation / alert titles are evaluated during body construction even when closed.
    private var leaveConfirmTitle: String {
        let _ = TeamDetailRenderBisect.mark("confirmationDialogLeaveTitle")
        return TeamDetailLocalizedFormat.format(
            "fan_teams_leave_confirm_title_format",
            languageCode: languageCode,
            stringArgs: [team.name]
        )
    }

    private var deleteConfirmTitle: String {
        let _ = TeamDetailRenderBisect.mark("confirmationDialogDeleteTitle")
        return TeamDetailLocalizedFormat.format(
            "fan_teams_delete_confirm_title_format",
            languageCode: languageCode,
            stringArgs: [team.name]
        )
    }

    private var removeMemberConfirmTitle: String {
        let _ = TeamDetailRenderBisect.mark("alertRemoveMemberTitle")
        guard let member = memberPendingRemoval else {
            return L10n.t("fan_teams_remove_member", languageCode: languageCode)
        }
        return TeamDetailLocalizedFormat.format(
            "fan_teams_remove_member_confirm_title_format",
            languageCode: languageCode,
            stringArgs: [member.displayName, team.name]
        )
    }

    @ViewBuilder
    private var teamDetailBodyRoot: some View {
        switch TeamDetailRenderDiagnostic.mode {
        case .placeholder:
            let _ = TeamDetailRenderBisect.mark("teamDetailChromeAndLifecycle", details: "mode=placeholder")
            Text("Team Detail Diagnostic")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { teamDetailLeadingToolbar }
                .onAppear {
                    TeamDetailCrashTrace.log(
                        "detailSheetAppear",
                        details: "teamID=\(summary.id.uuidString.lowercased()) tab=\(selectedTab.rawValue) mode=placeholder"
                    )
                }
        case .full, .headerOnly, .headerAndTabs, .overviewInfo, .announcementOnly, .fullOverview, .overviewWithoutNextEvent, .overviewWithoutAnnouncement, .noToolbar, .noRoleBadge, .noMark:
            teamDetailChromeAndLifecycle
        }
    }

    private var teamDetailChromeAndLifecycle: some View {
        let _ = TeamDetailRenderBisect.mark(
            "teamDetailChromeAndLifecycle",
            details: "mode=\(TeamDetailRenderDiagnostic.mode.rawValue)"
        )
        return teamDetailPrimaryColumn
            .background(colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                teamDetailLeadingToolbar
                if TeamDetailRenderDiagnostic.mode != .noToolbar {
                    teamDetailTrailingToolbar
                }
            }
            .onPreferenceChange(ChatComposerFocusPreferenceKey.self, perform: handleEmbeddedComposerFocusPreference)
            .onChange(of: selectedTab) { oldTab, newTab in
                handleSelectedTabChange(oldTab, newTab)
            }
            .onAppear {
                TeamDetailCrashTrace.log(
                    "detailSheetAppear",
                    details: "teamID=\(summary.id.uuidString.lowercased()) tab=\(selectedTab.rawValue)"
                )
                if selectedTab == .chat, !summary.canAccessTeamChat {
                    selectedTab = .overview
                }
                TeamChatKeyboardDebug.log(
                    "teamDetail.appear",
                    detail: "tab=\(selectedTab.rawValue) canAccessTeamChat=\(summary.canAccessTeamChat) hasAccountSeat=\(summary.hasAccountSeat)"
                )
                hydratePlayerInfoSelectionFromStore(source: "teamDetail.appear")
                Task {
                    await consumePendingTeamScheduleJoinApprovalIfNeeded()
                    await consumePendingTeamScheduleEventDeepLinkIfNeeded()
                }
            }
            .onChange(of: mapViewModel.pendingTeamScheduleJoinApproval) { _, pending in
                guard pending?.teamId == team.id else { return }
                Task { await consumePendingTeamScheduleJoinApprovalIfNeeded() }
            }
            .onChange(of: mapViewModel.pendingTeamScheduleEventDeepLink) { _, pending in
                guard pending?.teamId == team.id else { return }
                Task { await consumePendingTeamScheduleEventDeepLinkIfNeeded() }
            }
            .onDisappear {
                if pendingSelectChatAfterEventDetailDismiss {
                    TeamEventChatNavigationDebug.log(
                        "navigationCancelled",
                        detail: "reason=teamDetailDisappear teamID=\(team.id.uuidString.lowercased())"
                    )
                }
                pendingSelectChatAfterEventDetailDismiss = false
                pendingSelectChatEventId = nil
                TeamChatKeyboardDebug.log("teamDetail.disappear")
            }
            .task {
                hydratePlayerInfoSelectionFromStore(source: "teamDetail.task")
                // Cache-friendly: avoid redundant full detail re-fetch when already loaded.
                if detail == nil {
                    await reload()
                } else if !managedPlayerSeatsCatalogComplete {
                    await refreshManagedPlayerSeats()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: FanTeamIdentityChangeCenter.identityDidChangeNotification)) { note in
                guard let change = FanTeamIdentityChangeCenter.identityChange(from: note),
                      change.teamId == team.id else { return }
                markRefreshToken = change.displayRefreshToken
                if var detail {
                    detail.summary = detail.summary.applying(change)
                    self.detail = detail
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: FanProfileChangeCenter.avatarDidChangeNotification)) { note in
                guard let change = FanProfileChangeCenter.avatarChange(from: note) else { return }
                applyRosterAvatarChange(change)
            }
            .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.avatarDidChangeNotification)) { note in
                guard let change = FanManagedPlayerChangeCenter.avatarChange(from: note) else { return }
                applyManagedPlayerAvatarChange(change)
            }
            .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.teamMembershipDidChangeNotification)) { note in
                guard let change = FanManagedPlayerChangeCenter.teamMembershipChange(from: note),
                      change.teamId == team.id else { return }
                Task {
                    await reload()
                    await refreshManagedPlayerSeats()
#if DEBUG
                    print(
                        "[ManagedPlayerTeamDebug] team_detail_membership_refresh " +
                        "team_id=\(team.id.uuidString.lowercased()) " +
                        "managed_player_id=\(change.managedPlayerId.uuidString.lowercased()) " +
                        "list_my_managed_players_on_team_count=\(managedPlayerSeats.count) " +
                        "eligibleSubjects=\(overviewPlayerInfoSubjects.count)"
                    )
#endif
                }
            }
    }

    /// Primary column.
    ///
    /// **Chat tab root-cause layout:** `GroupChatView` must be the NavigationStack column root
    /// (same as working DM/group destinations). Nesting it under a `VStack` sibling to the Team
    /// header prevents its `.safeAreaInset(edge: .bottom)` composer from receiving keyboard
    /// safe-area — composer stays behind the keyboard intermittently.
    /// Team chrome is applied as a **top** safe-area inset only.
    @ViewBuilder
    private var teamDetailPrimaryColumn: some View {
        let _ = TeamDetailRenderBisect.mark("teamDetailPrimaryColumn", details: "tab=\(selectedTab.rawValue)")
        switch selectedTab {
        case .chat:
            teamChatKeyboardHostColumn
        case .overview, .schedule, .roster:
            teamNonChatColumn
        }
    }

    /// Matches working Group/DM: chat fills the host; chrome sits above via top inset.
    private var teamChatKeyboardHostColumn: some View {
        embeddedTeamChat
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                teamChatTopChrome
            }
            // Never animate chrome height against the keyboard.
            .animation(nil, value: showsTeamIdentityHeader)
            .onAppear {
                TeamChatKeyboardDebug.log(
                    "chatHost.appear",
                    detail: "headerCollapsed=\(!showsTeamIdentityHeader)"
                )
            }
            .onChange(of: showsTeamIdentityHeader) { _, visible in
                TeamChatKeyboardDebug.log(
                    "header.collapsed",
                    detail: "\(!visible)"
                )
            }
    }

    private var teamChatTopChrome: some View {
        VStack(spacing: 0) {
            teamHeader
                .frame(maxHeight: showsTeamIdentityHeader ? nil : 0, alignment: .top)
                .clipped()
                .opacity(showsTeamIdentityHeader ? 1 : 0)
                .allowsHitTesting(showsTeamIdentityHeader)
                .accessibilityHidden(!showsTeamIdentityHeader)
            tabPicker
        }
        .background(colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var teamNonChatColumn: some View {
        let _ = TeamDetailRenderBisect.mark(
            "teamNonChatColumn",
            details: "begin tab=\(selectedTab.rawValue) mode=\(TeamDetailRenderDiagnostic.mode.rawValue)"
        )
        // Sheet-level chrome diagnostics (UserDefaults / forcedMode only — never default).
        // Product path always routes by selectedTab; Overview diagnostics live in overviewTab.
        switch TeamDetailRenderDiagnostic.mode {
        case .headerOnly:
            VStack(spacing: 0) {
                teamHeader
                Spacer(minLength: 0)
            }
        case .headerAndTabs:
            VStack(spacing: 0) {
                teamHeader
                tabPicker
                Text("Team Detail Tabs Diagnostic")
                    .font(.footnote)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        default:
            VStack(spacing: 0) {
                teamHeader
                tabPicker
                Group {
                    switch selectedTab {
                    case .overview:
                        overviewTab
                    case .schedule:
                        gamesTab
                    case .roster:
                        rosterTab
                    case .chat:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .sheet(isPresented: Binding(
                get: { memberPendingPlayerInformation != nil },
                set: { presented in
                    if !presented {
                        memberPendingPlayerInformation = nil
                        Task { await refreshManagedPlayerSeats() }
#if DEBUG
                        print("[PlayerInfoPresentation] playerInfoDismissed host=teamNonChatColumn")
#endif
                    }
                }
            )) {
                if memberPendingPlayerInformation != nil {
                    FanTeamPlayerInformationSheet(
                        member: Binding(
                            get: {
                                guard let pending = memberPendingPlayerInformation else {
                                    // Sheet is dismissing; return a harmless placeholder.
                                    return FanTeamMember(
                                        userId: nil,
                                        role: .member,
                                        joinedAt: nil,
                                        displayName: "",
                                        username: nil,
                                        avatarURL: nil,
                                        avatarThumbnailURL: nil,
                                        lastSeenAtRaw: nil
                                    )
                                }
                                return refreshedRosterMember(pending)
                            },
                            set: { updated in
                                memberPendingPlayerInformation = updated
                                replaceCanonicalRosterMember(updated)
                            }
                        ),
                        team: team,
                        teamAccent: teamAccent,
                        languageCode: languageCode,
                        currentUserId: mapViewModel.currentUserAuthId,
                        isSavingPlayerNumber: isSavingPlayerNumber,
                        isSavingPreferredPosition: isSavingPreferredPosition,
                        isSavingTeamRole: isSavingTeamRole,
                        isSavingPermissions: isSavingPermissions,
                        onSavePlayerNumber: { number in
                            guard let pending = memberPendingPlayerInformation else { return }
                            await saveMemberPlayerNumber(refreshedRosterMember(pending), number: number)
                        },
                        onClearPlayerNumber: {
                            guard let pending = memberPendingPlayerInformation else { return }
                            await clearMemberPlayerNumber(refreshedRosterMember(pending))
                        },
                        onSavePreferredPosition: { code in
                            guard let pending = memberPendingPlayerInformation else { return }
                            await saveMemberPreferredPosition(refreshedRosterMember(pending), code: code)
                        },
                        onSaveTeamRole: {
                            guard team.canAssignRoles else { return nil }
                            guard let pending = memberPendingPlayerInformation else { return nil }
                            let resolved = refreshedRosterMember(pending)
                            guard resolved.role != .owner else { return nil }
                            if let me = mapViewModel.currentUserAuthId, resolved.userId == me { return nil }
                            return { role in
                                try await saveMemberRole(refreshedRosterMember(pending), role: role)
                            }
                        }(),
                        onSavePermissions: {
                            guard team.myRole == .owner else { return nil }
                            guard let pending = memberPendingPlayerInformation else { return nil }
                            let resolved = refreshedRosterMember(pending)
                            guard FanTeamPermissions.canEditPermissions(
                                viewerRole: team.myRole,
                                targetRole: resolved.role,
                                targetIsManagedPlayer: resolved.isManagedPlayer,
                                viewerUserId: mapViewModel.currentUserAuthId,
                                targetUserId: resolved.userId
                            ) else { return nil }
                            return { permissions in
                                try await saveMemberPermissions(
                                    refreshedRosterMember(pending),
                                    permissions: permissions
                                )
                            }
                        }()
                    )
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var teamDetailLeadingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .accessibilityLabel(L10n.t("Close", languageCode: languageCode))
            .background {
                let _ = TeamDetailRenderBisect.mark("toolbarLeadingConstruction")
                Color.clear
            }
        }
    }

    @ToolbarContentBuilder
    private var teamDetailTrailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showingNotifications = true
                } label: {
                    Label(
                        L10n.t("fan_teams_notifications_menu", languageCode: languageCode),
                        systemImage: "bell"
                    )
                }
                if team.canEditIdentity {
                    Button(L10n.t("fan_teams_edit_title", languageCode: languageCode)) {
                        showingEditTeam = true
                    }
                }
                if team.canInviteMembers {
                    Button(L10n.t("fan_teams_invite_members", languageCode: languageCode)) {
                        showingAddMembers = true
                    }
                }
                if team.canManageManagedPlayersStaff {
                    Button(L10n.t("managed_players_add_to_team", languageCode: languageCode)) {
                        showingAddManagedPlayers = true
                    }
                }
                Divider()
                Button {
                    showingReportTeam = true
                } label: {
                    Label(
                        L10n.t("fan_teams_report", languageCode: languageCode),
                        systemImage: "flag"
                    )
                }
                if team.canLeaveTeam {
                    Button(L10n.t("fan_teams_leave", languageCode: languageCode), role: .destructive) {
                        showLeaveConfirm = true
                    }
                }
                if team.canDeleteTeam {
                    Button(L10n.t("fan_teams_delete", languageCode: languageCode), role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L10n.t("More", languageCode: languageCode))
            .disabled(isLeaving || isDeleting)
            .background {
                let _ = TeamDetailRenderBisect.mark("toolbarTrailingConstruction")
                Color.clear
            }
        }
    }

    private var teamHeader: some View {
        let _ = TeamDetailRenderBisect.mark("teamHeader", details: "begin")
        let showAnnounce = team.canPublishAnnouncements
        let showCreateEvent = team.canOrganizeActivities
        // Single shallow HStack: mark + identity (title/meta/badges) + optional Quick Actions.
        // No ViewThatFits, no duplicated action trees, no reserved blank column when absent.
        return HStack(alignment: .top, spacing: 12) {
            teamHeaderMark
            VStack(alignment: .leading, spacing: 5) {
                FanTeamDetailHeaderTitleBlock(
                    teamName: team.name,
                    metaLine: headerMetaLine
                )
                teamHeaderBadgesRow
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if showAnnounce || showCreateEvent {
                FanTeamDetailHeaderActionsView(
                    languageCode: languageCode,
                    showAnnounce: showAnnounce,
                    showCreateEvent: showCreateEvent,
                    onAnnounce: { openMakeAnnouncement() },
                    onCreateEvent: { openScheduleGame() }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fanTeamIdentityCardChrome(
            colorHex: team.colorHex,
            colorScheme: colorScheme,
            baseOpacityDark: 0.72,
            baseOpacityLight: 0.96
        )
        .softCardShadow()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var teamHeaderMark: some View {
        let _ = TeamDetailRenderBisect.mark("teamHeaderMark")
        if TeamDetailRenderDiagnostic.mode == .noMark {
            FanTeamDetailHeaderStaticMarkView(accent: teamAccent, size: 56)
        } else {
            FanTeamDetailHeaderMarkView(
                sport: team.sport,
                logoURL: team.logoURL,
                logoThumbnailURL: team.logoThumbnailURL,
                colorHex: team.colorHex,
                size: 56,
                displayRefreshToken: markRefreshToken
            )
        }
    }

    /// Privacy + role badges under metadata (Quick Actions are a separate trailing leaf).
    ///
    /// Uses shallow leaf views. Avoid nested `ViewThatFits` + press `ButtonStyle`
    /// (iOS AttributeGraph risk during sheet presentation with `detail == nil`).
    @ViewBuilder
    private var teamHeaderBadgesRow: some View {
        FanTeamDetailHeaderBadgesView(
            showsPrivateBadge: FanTeamPrivacyPresentation.showsPrivateTeamBadge(for: team),
            privateBadgeTitle: L10n.t("fan_teams_private_team", languageCode: languageCode),
            role: team.myRole,
            languageCode: languageCode,
            accent: teamAccent,
            showsRoleBadge: TeamDetailRenderDiagnostic.mode != .noRoleBadge
        )
    }

    private var headerMetaLine: String {
        FanTeamDetailHeaderPresentation.metaLine(
            competitionLevel: team.competitionLevel,
            sport: team.sport,
            memberCount: FanTeamDetailHeaderPresentation.safeMemberCount(team.memberCount),
            pendingInvitationCount: max(team.pendingInvitationCount, pendingInvitations.count),
            canManage: team.canManage,
            languageCode: languageCode
        )
    }

    private var visibleDetailTabs: [FanTeamDetailTab] {
        FanTeamDetailTabComposition.visibleTabs(canAccessTeamChat: summary.canAccessTeamChat)
    }

    private var tabPicker: some View {
        let _ = TeamDetailRenderBisect.mark("tabPicker", details: "begin")
        return HStack(spacing: 0) {
            ForEach(visibleDetailTabs) { tab in
                let isSelected = selectedTab == tab
                Button {
                    if reduceMotion {
                        selectedTab = tab
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selectedTab = tab
                        }
                    }
                } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .layoutPriority(1)
                            Text(L10n.t(tab.titleKey, languageCode: languageCode))
                                .font(.caption.weight(isSelected ? .bold : .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(isSelected ? teamAccent : FGColor.secondaryText(colorScheme))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 2)
                        .padding(.top, 8)
                        .padding(.bottom, 6)

                        Capsule()
                            .fill(isSelected ? teamAccent : Color.clear)
                            .frame(height: 2)
                            .padding(.horizontal, 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t(tab.titleKey, languageCode: languageCode))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .background(
            Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.35 : 0.7)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FGColor.divider(colorScheme).opacity(0.55))
                .frame(height: 0.5)
        }
        .background(alignment: .center) {
            let _ = TeamDetailRenderBisect.mark("tabPicker", details: "completed")
            Color.clear
        }
    }

    private func handleEmbeddedComposerFocusPreference(_ focused: Bool) {
        guard selectedTab == .chat else {
            if isEmbeddedChatComposerFocused {
                isEmbeddedChatComposerFocused = false
                TeamChatKeyboardDebug.log(
                    "focus.false",
                    detail: "reason=leftChatTab headerCollapsed=false"
                )
            }
            return
        }
        guard isEmbeddedChatComposerFocused != focused else { return }
        // No withAnimation: keyboard safe-area and header height must not fight.
        isEmbeddedChatComposerFocused = focused
        TeamChatKeyboardDebug.log(
            focused ? "focus.true" : "focus.false",
            detail: "headerCollapsed=\(!showsTeamIdentityHeader)"
        )
    }

    private func handleSelectedTabChange(_ oldTab: FanTeamDetailTab, _ tab: FanTeamDetailTab) {
        _ = oldTab
        if tab != .chat, isEmbeddedChatComposerFocused {
            isEmbeddedChatComposerFocused = false
        }
        TeamChatKeyboardDebug.log(
            "teamDetail.tab",
            detail: "tab=\(tab.rawValue) composerFocused=\(isEmbeddedChatComposerFocused)"
        )
        Task { await loadDetailForTabIfNeeded(tab) }
    }

    /// Conservative lazy load: Chat needs no members/games fetch; other tabs ensure detail once.
    private func loadDetailForTabIfNeeded(_ tab: FanTeamDetailTab) async {
        switch tab {
        case .chat:
            return
        case .overview, .roster, .schedule:
            if detail == nil {
                await reload()
            }
        }
    }

    @ViewBuilder
    private var overviewTab: some View {
        let mode = TeamDetailRenderDiagnostic.mode
        let _ = TeamDetailRenderBisect.mark(
            "overviewTab",
            details: "begin detailNil=\(detail == nil) mode=\(mode.rawValue)"
        )
        let _ = TeamOverviewCrashBisect.mark(
            "overviewGetterRequested",
            details: "detailNil=\(detail == nil) mode=\(mode.rawValue)"
        )

        // Overview-only diagnostic gates (never affect Schedule / Chat / Roster).
        if TeamDetailRenderDiagnostic.overviewInfoOnly {
            ScrollView {
                teamInfoCard
                    .padding(.vertical, 14)
            }
        } else if TeamDetailRenderDiagnostic.announcementOnly {
            announcementOnlyOverviewContent
        } else if let detail {
            // Crash-safe: loaded dashboard only after detail exists.
            loadedOverviewContent(detail)
        } else {
            FanTeamOverviewLoadingView()
                .task {
                    await refreshManagedPlayerSeats()
                    logManagedPlayerTeamAttachmentDebug(source: "overview.loading.task")
                }
        }
    }

    @ViewBuilder
    private var announcementOnlyOverviewContent: some View {
        if let detail {
            let presentations = FanTeamOverviewAnnouncementPresentation.makeAll(
                from: detail,
                clearedIds: clearedAnnouncementIds,
                viewerUserId: mapViewModel.currentUserAuthId,
                languageCode: languageCode
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if presentations.isEmpty {
                        Text(L10n.t("fan_teams_no_upcoming_events", languageCode: languageCode))
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 24)
                    } else {
                        FanTeamOverviewAnnouncementCarouselView(
                            announcements: presentations,
                            accent: teamAccent,
                            languageCode: languageCode,
                            onOpen: { openAnnouncementFromOverview($0) },
                            onClear: { clearOverviewAnnouncement($0) }
                        )
                    }
                }
                .padding(.vertical, 14)
            }
            .refreshable { await reload() }
        } else {
            FanTeamOverviewLoadingView()
        }
    }

    private func loadedOverviewContent(_ detail: FanTeamDetail) -> some View {
        let includesNextEvent = !TeamDetailRenderDiagnostic.omitsOverviewNextEvent
        let includesAnnouncement = !TeamDetailRenderDiagnostic.omitsOverviewAnnouncement
        let nextEvent = includesNextEvent ? overviewNextEventPresentation(from: detail) : nil
        let announcements = includesAnnouncement
            ? FanTeamOverviewAnnouncementPresentation.makeAll(
                from: detail,
                clearedIds: clearedAnnouncementIds,
                viewerUserId: mapViewModel.currentUserAuthId,
                languageCode: languageCode
            )
            : []

        return FanTeamLoadedOverviewView(
            nextEvent: nextEvent,
            includesNextEvent: includesNextEvent,
            canOrganize: team.canOrganizeActivities,
            announcements: announcements,
            includesAnnouncement: includesAnnouncement,
            languageCode: languageCode,
            accent: teamAccent,
            onOpenEvent: { openPickupGameDetail($0) },
            onScheduleEvent: { openScheduleGame() },
            onOpenAnnouncement: { openAnnouncementFromOverview($0) },
            onClearAnnouncement: { clearOverviewAnnouncement($0) },
            teamInfo: { teamInfoCard },
            extra: {
                recentResultsCard(from: detail)
                teamLeadershipCard
                myPlayerInfoCard
                myManagedPlayersCard
            }
        )
        .refreshable { await reload() }
        .task {
            await refreshManagedPlayerSeats()
            logManagedPlayerTeamAttachmentDebug(source: "overview.loaded.task")
        }
    }

    private func openAnnouncementFromOverview(_ announcementId: UUID) {
        Task {
            try? await FanTeamAnnouncementUserStateService.markRead(announcementId: announcementId)
        }
        openPickupGameDetail(announcementId)
    }

    private func clearOverviewAnnouncement(_ announcementId: UUID) {
        guard isClearingAnnouncementId == nil else { return }
        // Always allow Clear for the final remaining card (count == 1).
        isClearingAnnouncementId = announcementId
        var nextCleared = clearedAnnouncementIds
        nextCleared.insert(announcementId)
        withAnimation(.easeInOut(duration: 0.2)) {
            clearedAnnouncementIds = nextCleared
        }
        Task {
            do {
                try await FanTeamAnnouncementUserStateService.clearAnnouncement(announcementId: announcementId)
            } catch {
                await MainActor.run {
                    // RPC failed — restore so the final announcement reappears.
                    var restored = clearedAnnouncementIds
                    restored.remove(announcementId)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        clearedAnnouncementIds = restored
                    }
                    errorText = error.localizedDescription
                }
            }
            await MainActor.run {
                if isClearingAnnouncementId == announcementId {
                    isClearingAnnouncementId = nil
                }
            }
        }
    }

    private func refreshClearedAnnouncementIds() async {
        do {
            clearedAnnouncementIds = try await FanTeamAnnouncementUserStateService.listClearedAnnouncementIds(
                teamId: team.id
            )
        } catch {
            // Pre-migration / soft fail: keep existing local set; do not wipe clears mid-session.
#if DEBUG
            print("[TeamAnnouncementOverview] clearedIdsLoadFailed \(error.localizedDescription)")
#endif
        }
    }

    /// Builds Next Event presentation outside the child view. Returns `nil` for empty state.
    private func overviewNextEventPresentation(from detail: FanTeamDetail) -> FanTeamOverviewNextEventPresentation? {
        guard let event = FanTeamOverviewNextEvent.upcomingEvent(from: detail.games) else {
            return nil
        }
        return FanTeamOverviewNextEventPresentation.make(
            event: event,
            teamShowsPrivateBadge: FanTeamPrivacyPresentation.showsPrivateTeamBadge(for: team),
            pickupIsVisible: mapViewModel.resolvedPickupGameRow(for: event.id)?.is_visible,
            languageCode: languageCode
        )
    }

    /// Only rendered when the viewer guards a player with an active seat on THIS
    /// Team. Suppressed when those seats already appear under "Players from Your Account".
    @ViewBuilder
    private var myManagedPlayersCard: some View {
        // All on-team managed seats are listed in `myPlayerInfoCard` — avoid duplicate Overview rows.
        EmptyView()
    }

    /// Membership add/remove lives in Manage sheet (organizers only).
    @MainActor
    private func refreshAfterPlayerMembershipChange(appliedMyselfIsPlayer: Bool? = nil) {
        if let appliedMyselfIsPlayer {
            applyLocalMyselfIsPlayer(appliedMyselfIsPlayer)
        }
        FanTeamRPCTrace.log(
            step: "F.reconcile.start",
            rpc: "onMembershipChanged",
            extra: "appliedMyselfIsPlayer=\(appliedMyselfIsPlayer.map(String.init) ?? "nil") team=\(team.id.uuidString.lowercased())"
        )
        onQuietTeamsRefresh()
        Task {
            await reload(surfaceError: false)
            await refreshManagedPlayerSeats()
        }
    }

    /// Keep the account row visible after Myself OFF; only flip `is_player`.
    @MainActor
    private func applyLocalMyselfIsPlayer(_ isPlayer: Bool) {
        guard var loaded = detail else { return }
        let uid = mapViewModel.currentUserAuthId
        guard let uid, let idx = loaded.members.firstIndex(where: { $0.userId == uid }) else {
            FanTeamRPCTrace.log(
                step: "F.reconcile.noSeat",
                rpc: "local_detail",
                extra: "could not patch is_player locally"
            )
            return
        }
        let previous = loaded.members[idx]
        loaded.members[idx] = previous.replacingIsPlayer(isPlayer)
        let playerCount = FanTeamRosterPlayerPresentation.playerCount(from: loaded.members)
        loaded.summary = loaded.summary.applyingMyRole(
            previous.role,
            memberCount: playerCount,
            myPermissions: previous.effectivePermissions
        )
        detail = loaded
        FanTeamRPCTrace.log(
            step: "F.reconcile.patched",
            rpc: "local_detail",
            extra: "user_id=\(uid.uuidString.lowercased()) is_player=\(isPlayer) role=\(previous.role.rawValue) playerCount=\(playerCount) rowRemains=YES"
        )
    }

    /// Silent on empty: users without managed seats on this Team must not see an error.
    /// Decode/RPC failures are logged in DEBUG so Player Info Change never fails closed quietly.
    @MainActor
    private func refreshManagedPlayerSeats() async {
        let teamId = team.id
        let generation = playerInfoSelectionGuard.beginSeatsRefresh()
        let selectionEpochAtStart = playerInfoSelectionGuard.selectionEpoch
        logTeamPlayerInfo(
            "refresh start",
            teamId: teamId,
            extra: "generation=\(generation) selectionEpoch=\(selectionEpochAtStart)"
        )
        let allPlayers = (try? await FanManagedPlayerService().listMyManagedPlayers()) ?? []
        viewerManagedPlayers = allPlayers
        viewerManagedPlayerCount = allPlayers.count
        do {
            let seats = try await FanManagedPlayerService().listMyManagedPlayersOnTeam(teamId: teamId)
            guard playerInfoSelectionGuard.shouldApplySeatsRefresh(generation: generation) else {
                logTeamPlayerInfo(
                    "stale refresh ignored",
                    teamId: teamId,
                    extra: "generation=\(generation) current=\(playerInfoSelectionGuard.seatsRefreshGeneration)"
                )
                return
            }
            if playerInfoSelectionGuard.isSelectionStaleRelative(to: selectionEpochAtStart) {
                // Newer user selection won while this fetch was in flight — still apply seats,
                // but reconcile with the latest preferred (never clobber with a pre-selection snapshot).
                logTeamPlayerInfo(
                    "refresh completed after newer selection",
                    teamId: teamId,
                    extra: "generation=\(generation) selectionEpochNow=\(playerInfoSelectionGuard.selectionEpoch)"
                )
            }
            managedPlayerSeats = seats
            managedPlayerSeatsCatalogComplete = true
            reconcilePlayerInfoSelection(catalogComplete: true, source: "refreshManagedPlayerSeats.ok")
            logManagedPlayerTeamAttachmentDebug(source: "refreshManagedPlayerSeats.ok")
#if DEBUG
            print(
                "[ManagedPlayerTeamDebug] list_my_managed_players_on_team_count=\(seats.count) " +
                "team_id=\(teamId.uuidString.lowercased()) " +
                "eligibleSubjects=\(overviewPlayerInfoSubjects.count)"
            )
            for seat in seats {
                print(
                    "[ManagedPlayerTeamDebug] seat " +
                    "managed_player_id=\(seat.managedPlayerId.uuidString.lowercased()) " +
                    "membership_id=\(seat.id.uuidString.lowercased()) " +
                    "left_at=nil"
                )
            }
#endif
            logTeamPlayerInfo(
                "refresh completion",
                teamId: teamId,
                extra: "seats=\(seats.count) generation=\(generation)"
            )
        } catch {
            FanTeamRPCTrace.log(
                step: "D.managed_player_list.failed",
                rpc: "list_my_managed_players_on_team",
                error: error,
                extra: "team=\(teamId.uuidString.lowercased())"
            )
#if DEBUG
            print(
                "[PlayerInfoSelectorDebug] list_my_managed_players_on_team FAILED " +
                "team_id=\(teamId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
            print(
                "[ManagedPlayerTeamDebug] list_my_managed_players_on_team_error=" +
                "\(error.localizedDescription)"
            )
#endif
            guard playerInfoSelectionGuard.shouldApplySeatsRefresh(generation: generation) else {
                logTeamPlayerInfo(
                    "stale refresh ignored",
                    teamId: teamId,
                    extra: "generation=\(generation) errorPath=true"
                )
                return
            }
            // Keep prior seats on transient failure; only clear when we never loaded.
            if managedPlayerSeats.isEmpty {
                managedPlayerSeats = []
            }
            managedPlayerSeatsCatalogComplete = true
            reconcilePlayerInfoSelection(catalogComplete: true, source: "refreshManagedPlayerSeats.error")
            logManagedPlayerTeamAttachmentDebug(source: "refreshManagedPlayerSeats.error")
            logTeamPlayerInfo(
                "refresh completion",
                teamId: teamId,
                extra: "failed error=\(error.localizedDescription)"
            )
        }
    }

    /// User confirmed a Player Info subject in the Change sheet.
    @MainActor
    private func commitPlayerInfoSelection(_ membershipId: UUID) {
        guard !isCommittingPlayerInfoSelection else { return }
        guard let userId = mapViewModel.currentUserAuthId else {
            errorText = L10n.t("fan_teams_refresh_failed", languageCode: languageCode)
            return
        }
        let teamId = team.id
        let previous = selectedPlayerInfoMembershipId
            ?? FanTeamPlayerInfoSelectionStore.load(userId: userId, teamId: teamId)

        isCommittingPlayerInfoSelection = true
        defer { isCommittingPlayerInfoSelection = false }

        logTeamPlayerInfo(
            "save start",
            teamId: teamId,
            userId: userId,
            previousPlayerId: previous,
            requestedPlayerId: membershipId
        )

        let epoch = playerInfoSelectionGuard.noteUserSelectionCommitted()
        // Do not dismiss until durable write verifies — avoids “looked saved then reverted”.
        let saved = FanTeamPlayerInfoSelectionStore.save(
            userId: userId,
            teamId: teamId,
            membershipId: membershipId
        )
        let verified = FanTeamPlayerInfoSelectionStore.load(userId: userId, teamId: teamId)

        guard saved, verified == membershipId else {
            logTeamPlayerInfo(
                "backend failure",
                teamId: teamId,
                userId: userId,
                previousPlayerId: previous,
                requestedPlayerId: membershipId,
                extra: "verify=\(verified?.uuidString.lowercased() ?? "nil") epoch=\(epoch)"
            )
            selectedPlayerInfoMembershipId = previous
            if let previous {
                _ = FanTeamPlayerInfoSelectionStore.save(
                    userId: userId,
                    teamId: teamId,
                    membershipId: previous
                )
            } else {
                FanTeamPlayerInfoSelectionStore.clear(userId: userId, teamId: teamId)
            }
            errorText = L10n.t("fan_teams_refresh_failed", languageCode: languageCode)
            return
        }

        selectedPlayerInfoMembershipId = membershipId
        showingPlayerInfoChangeSheet = false

        logTeamPlayerInfo(
            "backend success",
            teamId: teamId,
            userId: userId,
            previousPlayerId: previous,
            requestedPlayerId: membershipId,
            extra: "affected_membership_id=\(membershipId.uuidString.lowercased()) epoch=\(epoch)"
        )
        reconcilePlayerInfoSelection(catalogComplete: managedPlayerSeatsCatalogComplete, source: "commit.success")
        logTeamPlayerInfo(
            "local-store reconciliation",
            teamId: teamId,
            userId: userId,
            previousPlayerId: previous,
            requestedPlayerId: selectedPlayerInfoMembershipId,
            extra: "final=\(selectedPlayerInfoMembershipId?.uuidString.lowercased() ?? "nil")"
        )
    }

    /// Hydrate selection from durable store when Team detail opens / identity is known.
    @MainActor
    private func hydratePlayerInfoSelectionFromStore(source: String) {
        guard let userId = mapViewModel.currentUserAuthId else { return }
        let teamId = team.id
        let stored = FanTeamPlayerInfoSelectionStore.load(userId: userId, teamId: teamId)
        if let stored {
            selectedPlayerInfoMembershipId = stored
        }
        logTeamPlayerInfo(
            "hydrate",
            teamId: teamId,
            userId: userId,
            requestedPlayerId: stored,
            extra: "source=\(source)"
        )
        reconcilePlayerInfoSelection(
            catalogComplete: managedPlayerSeatsCatalogComplete,
            source: "hydrate.\(source)"
        )
    }

#if DEBUG
    private func logTeamPlayerInfo(
        _ event: String,
        teamId: UUID,
        userId: UUID? = nil,
        previousPlayerId: UUID? = nil,
        requestedPlayerId: UUID? = nil,
        extra: String = ""
    ) {
        let auth = (userId ?? mapViewModel.currentUserAuthId)?.uuidString.lowercased() ?? "nil"
        print(
            "[TeamPlayerInfo] \(event) " +
            "teamID=\(teamId.uuidString.lowercased()) " +
            "authUserID=\(auth) " +
            "previousPlayerID=\(previousPlayerId?.uuidString.lowercased() ?? "nil") " +
            "requestedPlayerID=\(requestedPlayerId?.uuidString.lowercased() ?? "nil") " +
            "selectedPlayerID=\(selectedPlayerInfoMembershipId?.uuidString.lowercased() ?? "nil") " +
            "\(extra)"
        )
    }
#else
    private func logTeamPlayerInfo(
        _ event: String,
        teamId: UUID,
        userId: UUID? = nil,
        previousPlayerId: UUID? = nil,
        requestedPlayerId: UUID? = nil,
        extra: String = ""
    ) {}
#endif

#if DEBUG
    private func logManagedPlayerTeamAttachmentDebug(source: String) {
        print("[ManagedPlayerTeamDebug] source=\(source)")
        print("[ManagedPlayerTeamDebug] team_id=\(team.id.uuidString.lowercased())")
        print("[ManagedPlayerTeamDebug] viewer_role=\(team.myRole.rawValue)")
        print("[ManagedPlayerTeamDebug] canManage=\(team.canManage)")
        print(
            "[ManagedPlayerTeamDebug] managed_player_team_seats_enabled=" +
            "unknown_client_cannot_read_flag"
        )
        print("[ManagedPlayerTeamDebug] managed_players_count=\(viewerManagedPlayerCount)")
        print("[ManagedPlayerTeamDebug] already_on_team_count=\(managedPlayerSeats.count)")
        print(
            "[ManagedPlayerTeamDebug] add_my_players_ui_visible=\(team.canManage) " +
            "(menu+header; members never)"
        )
        print(
            "[ManagedPlayerTeamDebug] note=If add fails with managed_player_team_seats_disabled, " +
            "apply supabase/migrations/20260969_0001_enable_managed_player_team_seats.sql"
        )
    }
#else
    private func logManagedPlayerTeamAttachmentDebug(source: String) {}
#endif

    #if DEBUG
    private func logPlayerInfoSelectorDebug(source: String) {
        let members = detail?.members ?? []
        let subjects = FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: members,
            currentUserId: mapViewModel.currentUserAuthId,
            managedSeats: managedPlayerSeats
        )
        print("[PlayerInfoSelectorDebug] source=\(source)")
        print("[PlayerInfoSelectorDebug] team_id=\(team.id.uuidString.lowercased())")
        print(
            "[PlayerInfoSelectorDebug] current_user_id=" +
            (mapViewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil")
        )
        print("[PlayerInfoSelectorDebug] detail.members count=\(members.count)")
        print("[PlayerInfoSelectorDebug] managedPlayerSeats count=\(managedPlayerSeats.count)")
        print("[PlayerInfoSelectorDebug] eligibleSubjects count=\(subjects.count)")
        print(
            "[PlayerInfoSelectorDebug] showsChange=" +
            "\(FanTeamMyPlayerInfoPresentation.showsChangeControl(subjects: subjects)) " +
            "titleKey=\(FanTeamMyPlayerInfoPresentation.titleKey(subjects: subjects))"
        )
        for seat in managedPlayerSeats {
            print(
                "[PlayerInfoSelectorDebug] seat membership_id=\(seat.id.uuidString.lowercased()) " +
                "managed_player_id=\(seat.managedPlayerId.uuidString.lowercased()) " +
                "display_name=\(seat.displayName) " +
                "player_number=\(seat.playerNumber.map(String.init) ?? "nil")"
            )
        }
        for subject in subjects {
            let kind = subject.isViewerAccountSeat ? "account" : "managed"
            print(
                "[PlayerInfoSelectorDebug] eligible membership_id=\(subject.membershipId.uuidString.lowercased()) " +
                "kind=\(kind) " +
                "display_name=\(subject.member.displayName) " +
                "managed_player_id=\(subject.member.managedPlayerId?.uuidString.lowercased() ?? "nil") " +
                "is_active=true"
            )
        }
        logTeamPlayerInfo(
            "selector debug",
            teamId: team.id,
            requestedPlayerId: selectedPlayerInfoMembershipId,
            extra: "source=\(source)"
        )
    }
    #else
    private func logPlayerInfoSelectorDebug(source: String) {}
    #endif

    /// Reconcile Player Info selection against refreshed Team seats (no polling).
    private func reconcilePlayerInfoSelection(
        catalogComplete: Bool? = nil,
        source: String = "reconcile"
    ) {
        let complete = catalogComplete ?? managedPlayerSeatsCatalogComplete
        let userId = mapViewModel.currentUserAuthId
        let teamId = team.id
        let stored = userId.flatMap {
            FanTeamPlayerInfoSelectionStore.load(userId: $0, teamId: teamId)
        }
        let preferred = selectedPlayerInfoMembershipId ?? stored
        let subjects = overviewPlayerInfoSubjects
        let resolved = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: preferred,
            subjects: subjects,
            catalogComplete: complete
        )
        selectedPlayerInfoMembershipId = resolved

        if let userId,
           FanTeamPlayerInfoSelectionReconciliation.shouldRewriteDurableStore(
               previousPreferred: preferred,
               resolved: resolved,
               subjects: subjects,
               catalogComplete: complete
           ),
           let resolved {
            let ok = FanTeamPlayerInfoSelectionStore.save(
                userId: userId,
                teamId: teamId,
                membershipId: resolved
            )
            logTeamPlayerInfo(
                ok ? "durable rewrite" : "durable rewrite failed",
                teamId: teamId,
                userId: userId,
                previousPlayerId: preferred,
                requestedPlayerId: resolved,
                extra: "source=\(source)"
            )
        }

        logTeamPlayerInfo(
            "reconcile",
            teamId: teamId,
            userId: userId,
            previousPlayerId: preferred,
            requestedPlayerId: resolved,
            extra: "source=\(source) catalogComplete=\(complete) subjects=\(subjects.count)"
        )
        logPlayerInfoSelectorDebug(source: source)
    }

    private var overviewLeadershipMembers: [FanTeamMember] {
        FanTeamLeadership.leaders(from: detail?.members ?? [])
    }

    /// Team-scoped Player Info subjects the viewer may represent on this Team.
    private var overviewPlayerInfoSubjects: [FanTeamPlayerInfoSubject] {
        FanTeamMyPlayerInfoPresentation.eligibleSubjects(
            members: detail?.members ?? [],
            currentUserId: mapViewModel.currentUserAuthId,
            managedSeats: managedPlayerSeats
        )
    }

    /// Viewer's account seat on this Team (player or access-only). Nil when guardian-only.
    private var viewerAccountSeatMember: FanTeamMember? {
        guard let uid = mapViewModel.currentUserAuthId else { return nil }
        return (detail?.members ?? []).first { $0.userId == uid }
    }

    private var accountPlayerOverviewRows: [FanTeamAccountPlayerOverviewRow] {
        FanTeamAccountPlayerOverviewPresentation.rows(
            hasAccountSeat: team.hasAccountSeat,
            myselfDisplayName: viewerAccountSeatMember?.displayName
                ?? mapViewModel.currentUserDisplayName,
            myselfIsPlayer: viewerAccountSeatMember?.isPlayer ?? false,
            myselfMembershipId: viewerAccountSeatMember?.membershipId,
            managedPlayers: viewerManagedPlayers,
            managedSeats: managedPlayerSeats
        )
    }

    /// Selected Player Info seat from durable + in-session authoritative selection.
    private var overviewSelectedPlayerInfoSubject: FanTeamPlayerInfoSubject? {
        let subjects = overviewPlayerInfoSubjects
        let membershipId = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: selectedPlayerInfoMembershipId,
            subjects: subjects,
            catalogComplete: managedPlayerSeatsCatalogComplete
        )
        return FanTeamMyPlayerInfoPresentation.subject(membershipId: membershipId, in: subjects)
    }

    @ViewBuilder
    private var teamLeadershipCard: some View {
        let leaders = overviewLeadershipMembers
        // Avoid empty/misleading chrome while roster is still in flight.
        if !leaders.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(teamAccent)
                        .accessibilityHidden(true)
                    Text(L10n.t("fan_teams_team_leadership", languageCode: languageCode))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }

                VStack(spacing: 0) {
                    ForEach(Array(leaders.enumerated()), id: \.element.id) { index, member in
                        if index > 0 {
                            Divider()
                                .opacity(colorScheme == .dark ? 0.35 : 0.55)
                                .padding(.leading, 54)
                        }
                        teamLeadershipRow(member)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
            .softCardShadow()
            .padding(.horizontal, 16)
        }
    }

    private func teamLeadershipRow(_ member: FanTeamMember) -> some View {
        Button {
            openTeamMemberProfile(member, context: "fan_team_overview_leadership")
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    TeamMemberAvatarView(member: member, size: 42)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(FGColor.cardBackground(colorScheme)))
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                        }

                    Image(systemName: member.role.badgeSystemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3.5)
                        .background(Circle().fill(member.role.badgeTint.color(for: colorScheme)))
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    FGColor.cardBackground(colorScheme),
                                    lineWidth: 1.5
                                )
                        }
                        .offset(x: 2, y: 2)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(member.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    FanTeamRoleBadgeView(
                        role: member.role,
                        languageCode: languageCode,
                        showsTitle: true,
                        compact: true
                    )
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(FGPremiumPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: L10n.t("fan_teams_leadership_row_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                member.displayName,
                L10n.t(member.role.localizedKey, languageCode: languageCode)
            )
        )
        .accessibilityHint(L10n.t("Opens profile preview", languageCode: languageCode))
    }

    @ViewBuilder
    private var myPlayerInfoCard: some View {
        let rows = accountPlayerOverviewRows
        let canManageMembership = FanTeamPlayerMembershipManagePresentation.showsManageControl(
            hasActiveAccountMembership: team.hasAccountSeat
        )
        let showSection = FanTeamPlayerMembershipManagePresentation.shouldShowAccountPlayersSection(
            hasActiveAccountMembership: canManageMembership,
            globalManagedPlayerCount: viewerManagedPlayerCount,
            onTeamPlayerSubjectCount: overviewPlayerInfoSubjects.count
        )
        if showSection, !rows.isEmpty || canManageMembership {
            let accountSeatId = viewerAccountSeatMember?.membershipId
            let managedOnTeam = rows.filter {
                if case .managed = $0.kind { return $0.isOnTeam }
                return false
            }.count
            let _ = logTeamOverviewPlayers(
                "displayed",
                accountSeat: accountSeatId,
                managedSeats: managedOnTeam,
                displayed: rows.compactMap(\.membershipId)
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(teamAccent)
                        .accessibilityHidden(true)
                    Text(
                        L10n.t(
                            FanTeamMyPlayerInfoPresentation.overviewSectionTitleKey,
                            languageCode: languageCode
                        )
                    )
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: 0)
                    if canManageMembership {
                        Button {
                            showingManagePlayerMembership = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.t("team_player_membership_manage", languageCode: languageCode))
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(teamAccent)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            L10n.t("team_player_membership_manage_a11y", languageCode: languageCode)
                        )
                    }
                }

                Text(
                    L10n.t(
                        FanTeamMyPlayerInfoPresentation.overviewSectionHelperKey,
                        languageCode: languageCode
                    )
                )
                .font(.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

                if rows.isEmpty {
                    Text(L10n.t("team_player_membership_overview_none_on_team", languageCode: languageCode))
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                                .overlay(FGColor.divider(colorScheme).opacity(0.55))
                        }
                        overviewAccountPlayerRow(row)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
            .softCardShadow()
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                L10n.t(
                    FanTeamMyPlayerInfoPresentation.overviewSectionTitleKey,
                    languageCode: languageCode
                )
            )
        }
    }

    @ViewBuilder
    private func overviewAccountPlayerRow(_ row: FanTeamAccountPlayerOverviewRow) -> some View {
        let status = row.kind == .myself
            ? FanTeamPlayerMembershipManagePresentation.myselfStatusCaption(
                isPlayer: row.isOnTeam,
                languageCode: languageCode
            )
            : FanTeamPlayerMembershipManagePresentation.statusCaption(
                isOnTeam: row.isOnTeam,
                languageCode: languageCode
            )
        let identity = L10n.t(row.identityCaptionKey, languageCode: languageCode)

        Group {
            if row.isOnTeam, let membershipId = row.membershipId,
               let subject = overviewPlayerInfoSubjects.first(where: { $0.membershipId == membershipId }) {
                Button {
                    memberPendingPlayerInformation = subject.member
                } label: {
                    overviewAccountPlayerRowLabel(row: row, identity: identity, status: status)
                }
                .buttonStyle(FGPremiumPressButtonStyle())
            } else if canOpenMembershipManageFromOverview {
                Button {
                    showingManagePlayerMembership = true
                } label: {
                    overviewAccountPlayerRowLabel(row: row, identity: identity, status: status)
                }
                .buttonStyle(FGPremiumPressButtonStyle())
            } else {
                overviewAccountPlayerRowLabel(row: row, identity: identity, status: status)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.displayName), \(identity), \(status)")
        .accessibilityAddTraits(.isButton)
    }

    private var canOpenMembershipManageFromOverview: Bool {
        FanTeamPlayerMembershipManagePresentation.showsManageControl(
            hasActiveAccountMembership: team.hasAccountSeat
        )
    }

    private func overviewAccountPlayerRowLabel(
        row: FanTeamAccountPlayerOverviewRow,
        identity: String,
        status: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                switch row.kind {
                case .myself:
                    // Same circular UserAvatarView path as managed rows (not SocialAvatarRenderer,
                    // which leaves photo fills unclipped / square in this compact list).
                    if let member = viewerAccountSeatMember {
                        ManagedPlayerAvatarView(
                            managedPlayerId: member.userId,
                            avatarURL: member.avatarURL,
                            avatarThumbnailURL: member.avatarThumbnailURL,
                            displayName: member.displayName,
                            size: 48
                        )
                    } else {
                        ManagedPlayerAvatarView(
                            avatarURL: nil,
                            avatarThumbnailURL: nil,
                            displayName: row.displayName,
                            size: 48
                        )
                    }
                case .managed(let managedPlayerId):
                    ManagedPlayerAvatarView(
                        managedPlayerId: managedPlayerId,
                        avatarURL: row.avatarURL,
                        avatarThumbnailURL: row.avatarThumbnailURL,
                        displayName: row.displayName,
                        size: 48
                    )
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(identity)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        row.isOnTeam ? FGColor.accentGreen : FGColor.mutedText(colorScheme)
                    )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    private func logTeamOverviewPlayers(
        _ event: String,
        accountSeat: UUID?,
        managedSeats: Int?,
        displayed: [UUID]?,
        tapped: UUID? = nil
    ) {
#if DEBUG
        var parts = [
            "[TeamOverviewPlayers]",
            event,
            "teamId=\(team.id.uuidString.lowercased())"
        ]
        if let accountSeat {
            parts.append("accountSeat=\(accountSeat.uuidString.lowercased())")
        } else if event == "displayed" {
            parts.append("accountSeat=none")
        }
        if let managedSeats {
            parts.append("managedSeats=\(managedSeats)")
        }
        if let displayed {
            let ids = displayed.map { $0.uuidString.lowercased() }.joined(separator: ",")
            parts.append("displayedMembershipIds=[\(ids)]")
        }
        if let tapped {
            parts.append("playerTapped=\(tapped.uuidString.lowercased())")
            if event == "editorOpened" {
                parts.append("editorOpened=\(tapped.uuidString.lowercased())")
            }
        }
        print(parts.joined(separator: " "))
#endif
    }

    private var teamInfoCard: some View {
        let _ = TeamDetailRenderBisect.mark("teamInfoCard", details: "begin")
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("fan_teams_team_info", languageCode: languageCode))
                .font(.headline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            overviewInfoRow(
                systemImage: "sportscourt",
                title: L10n.t("fan_teams_sport", languageCode: languageCode),
                value: team.sport.isEmpty
                    ? L10n.t("fan_teams_sport_unspecified", languageCode: languageCode)
                    : team.sport
            )
            overviewInfoRow(
                systemImage: "person.2.fill",
                title: L10n.t("fan_teams_members_label", languageCode: languageCode),
                value: TeamDetailLocalizedFormat.format(
                    "fan_teams_members_count_format",
                    languageCode: languageCode,
                    int64Args: [Int64(team.memberCount)]
                )
            )
            if let detail, detail.record.totalFinals > 0 || detail.games.contains(where: { $0.isScoringFinal }) {
                overviewInfoRow(
                    systemImage: "chart.bar.fill",
                    title: L10n.t("fan_team_record_label", languageCode: languageCode),
                    value: detail.record.displayLine
                )
            }
            if let createdAt = team.createdAt {
                overviewInfoRow(
                    systemImage: "calendar",
                    title: L10n.t("fan_teams_created_label", languageCode: languageCode),
                    value: FanTeamDateFormatting.shortDay(createdAt, languageCode: languageCode)
                )
            }
            overviewInfoRow(
                systemImage: "shield.lefthalf.filled",
                title: L10n.t("fan_teams_your_role", languageCode: languageCode),
                value: L10n.t(team.myRole.localizedKey, languageCode: languageCode)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .softCardShadow()
        .padding(.horizontal, 16)
        .background(alignment: .center) {
            let _ = TeamDetailRenderBisect.mark("teamInfoCard", details: "completed")
            Color.clear
        }
    }

    @ViewBuilder
    private func recentResultsCard(from detail: FanTeamDetail) -> some View {
        let finals = FanTeamEventScoring.recentFinals(from: detail.games, limit: 5)
        if !finals.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("fan_team_recent_results", languageCode: languageCode))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                ForEach(finals) { game in
                    Button {
                        openPickupGameDetail(game.id)
                    } label: {
                        FanTeamEventResultScoreLine(
                            teamName: team.name,
                            opponentName: game.opponentName ?? "",
                            teamScore: game.teamScoreValue,
                            opponentScore: game.opponentScoreValue,
                            languageCode: languageCode
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
            .softCardShadow()
            .padding(.horizontal, 16)
        }
    }

    private func overviewInfoRow(systemImage: String, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(teamAccent.opacity(0.9))
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    /// Same authoritative Team group conversation as the main Chat inbox (`team.groupConversationId`).
    /// Mounted only while the Chat tab is selected so realtime lifecycle matches open/close of that conversation.
    private var embeddedTeamChat: some View {
        GroupChatView(
            conversationId: team.groupConversationId,
            chatViewModel: chatViewModel,
            fanTeamContext: chatContext,
            presentationStyle: .embeddedInTeamDetail
        )
        .environmentObject(mapViewModel)
        .id(team.groupConversationId)
        .onAppear {
            TeamChatKeyboardDebug.log(
                "GroupChatView.mounted",
                detail: "conversation=\(team.groupConversationId.uuidString)"
            )
            TeamEventChatNavigationDebug.log(
                "chatViewAppeared",
                detail: "teamID=\(team.id.uuidString.lowercased()) conversationID=\(team.groupConversationId.uuidString.lowercased())"
            )
        }
        .onDisappear {
            TeamChatKeyboardDebug.log(
                "GroupChatView.unmounted",
                detail: "conversation=\(team.groupConversationId.uuidString)"
            )
        }
    }

    private var gamesTab: some View {
        let allGames = detail?.games ?? []
        let presentation = FanTeamGamesFilterEngine.present(
            allGames,
            state: gamesFilter,
            now: gamesFilterClockTick
        )
        let summary = FanTeamGamesFilterEngine.summaryLine(
            result: presentation,
            state: gamesFilter,
            languageCode: languageCode
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Schedule is a pure list surface — Create Event / Announce live in the Team header.

                if !allGames.isEmpty {
                    gamesStatusSegment
                    gamesTypeFilterChipRow
                    if let summary {
                        Text(summary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(.horizontal, 16)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }

                if allGames.isEmpty {
                    emptyCard(
                        title: L10n.t("fan_teams_no_events_title", languageCode: languageCode),
                        body: L10n.t("fan_teams_no_events_body", languageCode: languageCode)
                    )
                } else if presentation.filteredCount == 0 {
                    gamesStatusOrFilteredEmptyCard
                } else {
                    ForEach(presentation.sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            gamesSectionHeader(section)
                            ForEach(section.games) { game in
                                gameListRow(game)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }

                if !allGames.isEmpty {
                    gamesSchedulePrivacyNote
                }
            }
            .padding(.vertical, 14)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: gamesFilter)
        }
        .onReceive(gamesFilterMinuteTicker) { gamesFilterClockTick = $0 }
        .task(id: scheduleAttendanceBatchKey) {
            let ids = allGames
                .filter { $0.gameType != .announcement }
                .map(\.id)
            guard !ids.isEmpty else { return }
            await mapViewModel.loadTeamScheduleAttendanceBatch(
                teamId: team.id,
                pickupGameIds: ids
            )
        }
        .sheet(isPresented: $showGamesCustomDateSheet) {
            gamesCustomDateSheet
        }
    }

    private var scheduleAttendanceBatchKey: String {
        let ids = (detail?.games ?? []).map { $0.id.uuidString.lowercased() }.sorted().joined(separator: ",")
        return "\(team.id.uuidString.lowercased())|\(ids)"
    }

    private var gamesFilterAccent: Color {
        if let hex = team.colorHex, let c = Color(fanTeamHex: hex) { return c }
        return FGColor.accentBlueStrong
    }

    /// Upcoming / Past — full-width segment on the Schedule list.
    private var gamesStatusSegment: some View {
        Picker(
            "",
            selection: Binding(
                get: { gamesFilter.status },
                set: { next in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        gamesFilter.selectStatus(next)
                    }
                }
            )
        ) {
            ForEach(FanTeamGamesStatusFilter.allCases) { status in
                Text(L10n.t(status.localizedKey, languageCode: languageCode))
                    .tag(status)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(L10n.t("fan_teams_games_status_segment_a11y", languageCode: languageCode))
        .padding(.horizontal, 16)
    }

    /// Horizontally scrollable chips for every stored FanGeo event type (not collapsed groups).
    private var gamesTypeFilterChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                gamesTypeFilterChip(
                    title: L10n.t("fan_teams_games_type_all", languageCode: languageCode),
                    systemImage: "square.grid.2x2.fill",
                    isSelected: gamesFilter.gameType == nil
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        gamesFilter.gameType = nil
                    }
                }
                ForEach(FanTeamGamesFilterEngine.supportedTypeFilters, id: \.self) { type in
                    gamesTypeFilterChip(
                        title: L10n.t(type.localizedKey, languageCode: languageCode),
                        systemImage: type.filterSystemImage,
                        isSelected: gamesFilter.gameType == type
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            gamesFilter.gameType = gamesFilter.gameType == type ? nil : type
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("fan_teams_games_type_section", languageCode: languageCode))
    }

    private func gamesTypeFilterChip(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? gamesFilterAccent : FGColor.cardBackground(colorScheme))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? gamesFilterAccent : FGColor.divider(colorScheme),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func gamesSectionHeader(_ section: FanTeamGamesSection) -> some View {
        HStack(spacing: 8) {
            Text(L10n.t(section.kind.localizedKey, languageCode: languageCode).uppercased(with: Locale(identifier: languageCode)))
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            gamesSortMenu
            gamesSecondaryFilterMenu
        }
        .padding(.horizontal, 16)
    }

    private var gamesSchedulePrivacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gamesFilterAccent)
                .accessibilityHidden(true)
            Text(L10n.t("fan_teams_schedule_rsvp_privacy_note", languageCode: languageCode))
                .font(.caption.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(gamesFilterAccent.opacity(colorScheme == .dark ? 0.18 : 0.10))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private var gamesSortMenu: some View {
        Menu {
            Section(L10n.t("fan_teams_games_sort_section", languageCode: languageCode)) {
                ForEach(FanTeamGamesSort.options(for: gamesFilter.status)) { sort in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            let statusDefault = FanTeamGamesSort.defaultSort(for: gamesFilter.status)
                            gamesFilter.sortOverride = (sort == statusDefault) ? nil : sort
                        }
                    } label: {
                        let selected = gamesFilter.resolvedSort() == sort
                        if selected {
                            Label(
                                L10n.t(sort.localizedKey, languageCode: languageCode),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(L10n.t(sort.localizedKey, languageCode: languageCode))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(gamesFilterAccent)
                .frame(minWidth: 40, minHeight: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.t("fan_teams_games_sort_a11y", languageCode: languageCode))
        .accessibilityValue(L10n.t(gamesFilter.resolvedSort().localizedKey, languageCode: languageCode))
    }

    private var gamesSecondaryFilterMenu: some View {
        Menu {
            Section(L10n.t("fan_teams_games_date_section", languageCode: languageCode)) {
                ForEach(FanTeamGamesDatePreset.allCases) { preset in
                    Button {
                        if preset == .custom {
                            if gamesFilter.customStart == nil {
                                gamesFilter.customStart = Calendar.current.startOfDay(for: Date())
                            }
                            if gamesFilter.customEnd == nil {
                                gamesFilter.customEnd = gamesFilter.customStart
                            }
                            showGamesCustomDateSheet = true
                        } else {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                gamesFilter.datePreset = preset
                                if preset != .custom {
                                    gamesFilter.customStart = nil
                                    gamesFilter.customEnd = nil
                                }
                            }
                        }
                    } label: {
                        if gamesFilter.datePreset == preset {
                            Label(
                                L10n.t(preset.localizedKey, languageCode: languageCode),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(L10n.t(preset.localizedKey, languageCode: languageCode))
                        }
                    }
                }
            }

            Section(L10n.t("pickup_form_competition_level", languageCode: languageCode)) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        gamesFilter.competitionLevel = nil
                    }
                } label: {
                    if gamesFilter.competitionLevel == nil {
                        Label(
                            L10n.t("pickup_competition_level_not_specified", languageCode: languageCode),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(L10n.t("pickup_competition_level_not_specified", languageCode: languageCode))
                    }
                }
                ForEach(PickupCompetitionLevel.allCases) { level in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            gamesFilter.competitionLevel = gamesFilter.competitionLevel == level ? nil : level
                        }
                    } label: {
                        if gamesFilter.competitionLevel == level {
                            Label(level.displayTitle(languageCode: languageCode), systemImage: "checkmark")
                        } else {
                            Text(level.displayTitle(languageCode: languageCode))
                        }
                    }
                }
            }

            if gamesFilter.hasActiveSecondaryFilters {
                Button(L10n.t("fan_teams_games_clear_filters", languageCode: languageCode), role: .destructive) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        gamesFilter.clearSecondaryFilters()
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: gamesFilter.hasActiveMenuFilters
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 18, weight: .semibold))
                if gamesFilter.activeSecondaryFilterCount > 0 {
                    Text("\(gamesFilter.activeSecondaryFilterCount)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(gamesFilterAccent)
            .frame(minWidth: 40, minHeight: 40)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.t("fan_teams_games_filter_menu_a11y", languageCode: languageCode))
        .accessibilityValue(
            gamesFilter.activeSecondaryFilterCount > 0
                ? String(
                    format: L10n.t("fan_teams_games_filter_active_count_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(gamesFilter.activeSecondaryFilterCount)
                )
                : L10n.t("fan_teams_games_filter_inactive_a11y", languageCode: languageCode)
        )
    }

    private var gamesCustomDateSheet: some View {
        NavigationStack {
            Form {
                DatePicker(
                    L10n.t("fan_teams_games_custom_start", languageCode: languageCode),
                    selection: Binding(
                        get: { gamesFilter.customStart ?? Date() },
                        set: { gamesFilter.customStart = Calendar.current.startOfDay(for: $0) }
                    ),
                    displayedComponents: .date
                )
                DatePicker(
                    L10n.t("fan_teams_games_custom_end", languageCode: languageCode),
                    selection: Binding(
                        get: { gamesFilter.customEnd ?? gamesFilter.customStart ?? Date() },
                        set: { gamesFilter.customEnd = Calendar.current.startOfDay(for: $0) }
                    ),
                    displayedComponents: .date
                )
            }
            .navigationTitle(L10n.t("fan_teams_games_date_custom", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) {
                        showGamesCustomDateSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            gamesFilter.datePreset = .custom
                        }
                        showGamesCustomDateSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var gamesStatusOrFilteredEmptyCard: some View {
        if gamesFilter.hasActiveSecondaryFilters {
            gamesFilteredEmptyCard
        } else if gamesFilter.status == .upcoming {
            emptyCard(
                title: L10n.t("fan_teams_events_no_upcoming_title", languageCode: languageCode),
                body: L10n.t("fan_teams_events_no_upcoming_body", languageCode: languageCode)
            )
        } else {
            emptyCard(
                title: L10n.t("fan_teams_events_no_past_title", languageCode: languageCode),
                body: L10n.t("fan_teams_events_no_past_body", languageCode: languageCode)
            )
        }
    }

    private var gamesFilteredEmptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("fan_teams_games_filtered_empty_title", languageCode: languageCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(L10n.t("fan_teams_games_filtered_empty_body", languageCode: languageCode))
                .font(.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    gamesFilter.clearSecondaryFilters()
                }
            } label: {
                Text(L10n.t("fan_teams_games_clear_filters", languageCode: languageCode))
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.bordered)
            .tint(gamesFilterAccent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .padding(.horizontal, 16)
    }

    private var rosterTab: some View {
        List {
            if team.canManage {
                Section {
                    Button {
                        showingAddMembers = true
                    } label: {
                        Label(
                            L10n.t("fan_teams_invite", languageCode: languageCode),
                            systemImage: "person.badge.plus"
                        )
                    }
                    .accessibilityLabel(L10n.t("fan_teams_invite", languageCode: languageCode))

                    Button {
                        showingAddManagedPlayers = true
                    } label: {
                        Label(
                            L10n.t("managed_players_add_to_team", languageCode: languageCode),
                            systemImage: "figure.and.child.holdinghands"
                        )
                    }
                    .accessibilityLabel(L10n.t("managed_players_add_to_team", languageCode: languageCode))
                }
            }

            if team.canManage, !pendingInvitations.isEmpty {
                Section {
                    ForEach(pendingInvitations) { invitation in
                        HStack(spacing: 12) {
                            ProfileAvatarView(preview: invitation.inviteePreview, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(invitation.inviteeDisplayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                if let handle = invitation.inviteePreview.publicHandleLine.nilIfEmpty {
                                    Text(handle)
                                        .font(.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                            }
                            Spacer(minLength: 0)
                            Menu {
                                Button {
                                    Task { @MainActor in
                                        openPendingInviteeProfile(invitation)
                                    }
                                } label: {
                                    Label(
                                        L10n.t("View Profile", languageCode: languageCode),
                                        systemImage: "person.crop.circle"
                                    )
                                }

                                Button {
                                    Task { await resendPendingInvitation(invitation) }
                                } label: {
                                    Label(
                                        L10n.t("fan_teams_resend_invitation", languageCode: languageCode),
                                        systemImage: "paperplane"
                                    )
                                }
                                .disabled(isPendingInvitationResendCoolingDown(invitation.id))

                                Button(role: .destructive) {
                                    Task { await cancelPendingInvitation(invitation) }
                                } label: {
                                    Label(
                                        L10n.t("fan_teams_cancel_invitation", languageCode: languageCode),
                                        systemImage: "xmark.circle"
                                    )
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .frame(minWidth: 36, minHeight: 36)
                                    .contentShape(Rectangle())
                            }
                            .disabled(busyPendingInvitationIds.contains(invitation.id))
                            .accessibilityLabel(L10n.t("More", languageCode: languageCode))
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L10n.t("fan_teams_pending_invitations", languageCode: languageCode))
                }
            }

            Section {
                ForEach(
                    FanTeamRosterOrdering.sorted(
                        FanTeamRosterPlayerPresentation.playerSeats(from: detail?.members ?? [])
                    )
                ) { member in
                    rosterMemberRow(member)
                }
            } header: {
                Text(rosterActiveMembersHeader)
            }
        }
        .listStyle(.insetGrouped)
        // Roster menu can still open Team Role directly (not nested under Player Information).
        .sheet(item: $memberPendingRoleEdit, onDismiss: {
            memberPendingRoleEdit = nil
        }) { member in
            FanTeamMemberRolePickerSheet(
                member: refreshedRosterMember(member),
                languageCode: languageCode,
                isSaving: isSavingTeamRole,
                onSelect: { role in
                    do {
                        try await saveMemberRole(refreshedRosterMember(member), role: role)
                        memberPendingRoleEdit = nil
                    } catch {
                        // Error already surfaced via errorText inside saveMemberRole.
                    }
                }
            )
        }
    }

    /// Roster seat identity, never `userId`: managed seats all have a nil `userId`,
    /// so matching on it would resolve every child to the first one.
    private func refreshedRosterMember(_ member: FanTeamMember) -> FanTeamMember {
        detail?.members.first(where: { $0.membershipId == member.membershipId }) ?? member
    }

    /// Canonical local roster mutation — Player Information Binding, Roster, and Team Leadership
    /// all read from `detail.members`.
    @MainActor
    private func replaceCanonicalRosterMember(_ updated: FanTeamMember) {
        if var detail {
            detail.members = detail.members.map { row in
                row.membershipId == updated.membershipId ? updated : row
            }
            self.detail = detail
        }
        if memberPendingPlayerInformation?.membershipId == updated.membershipId {
            memberPendingPlayerInformation = updated
        }
        if memberPendingRoleEdit?.membershipId == updated.membershipId {
            memberPendingRoleEdit = updated
        }
    }

    private func rosterMemberRow(_ member: FanTeamMember) -> some View {
        let avatarSize = FanTeamRosterRowPresentation.avatarSize
        let leadingWidth = FanTeamRosterRowPresentation.leadingColumnWidth

        return HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 5) {
                    if let metadata = FanTeamMemberPositionPresentation.compactMetadata(
                        playerNumber: member.playerNumber,
                        preferredPositionCode: member.preferredPositionCode
                    ) {
                        Text(metadata)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(teamAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                teamAccent.opacity(colorScheme == .dark ? 0.22 : 0.12),
                                in: Capsule(style: .continuous)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    TeamMemberAvatarView(member: member, size: avatarSize)
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                }
                .frame(width: leadingWidth, alignment: .center)

                VStack(alignment: .leading, spacing: 4) {
                    rosterIdentityLine(member)

                    Text(rosterRoleGenderLine(member))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(member.role.badgeTint.color(for: colorScheme))
                        .lineLimit(1)

                    if let joinedLine = FanTeamRosterJoinedCaption.line(
                        teamName: team.name,
                        joinedAt: member.joinedAt,
                        languageCode: languageCode
                    ) {
                        Text(joinedLine)
                            .font(.caption)
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rosterMemberAccessibilityLabel(member))

            Menu {
                Button {
                    Task { @MainActor in
                        openRosterMemberProfile(member)
                    }
                } label: {
                    Label(
                        L10n.t("View Profile", languageCode: languageCode),
                        systemImage: "person.crop.circle"
                    )
                }

                if FanTeamRosterMemberActions.canMessage(
                    member: member,
                    currentUserId: mapViewModel.currentUserAuthId
                ) {
                    Button {
                        Task { await messageRosterMember(member) }
                    } label: {
                        Label(
                            L10n.t("Message", languageCode: languageCode),
                            systemImage: "bubble.left"
                        )
                    }
                    .disabled(isMessagingMember)
                }

                Divider()

                Button {
                    memberPendingPlayerInformation = member
                } label: {
                    Label(
                        L10n.t("fan_teams_player_information", languageCode: languageCode),
                        systemImage: "person.text.rectangle"
                    )
                }
                .accessibilityLabel(
                    L10n.t("fan_teams_player_information", languageCode: languageCode)
                )

                if team.canAssignRoles,
                   member.role != .owner,
                   !FanTeamRosterMemberActions.isSelf(
                       member: member,
                       currentUserId: mapViewModel.currentUserAuthId
                   ) {
                    Button {
                        memberPendingRoleEdit = member
                    } label: {
                        Label(
                            L10n.t("fan_teams_team_role", languageCode: languageCode),
                            systemImage: "person.badge.shield.checkmark"
                        )
                    }
                    .accessibilityLabel(
                        L10n.t("fan_teams_team_role", languageCode: languageCode)
                    )
                }

                if FanTeamRosterMemberActions.canRemove(
                    member: member,
                    viewerCanManage: team.canManage,
                    currentUserId: mapViewModel.currentUserAuthId
                ) {
                    Divider()
                    Button(role: .destructive) {
                        memberPendingRemoval = member
                    } label: {
                        Label(
                            L10n.t("fan_teams_remove_member", languageCode: languageCode),
                            systemImage: "person.badge.minus"
                        )
                    }
                    .disabled(isRemovingMember)
                    .accessibilityLabel(
                        L10n.t("fan_teams_remove_member", languageCode: languageCode)
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.t("More", languageCode: languageCode))
        }
        .padding(.vertical, 10)
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            leadingWidth + 14
        }
    }

    @ViewBuilder
    private func rosterIdentityLine(_ member: FanTeamMember) -> some View {
        let handle = FanTeamRosterRowPresentation.parentheticalHandle(username: member.username)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(member.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .layoutPriority(1)
                if let handle {
                    Text("(\(handle))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(3)
                if let handle {
                    Text("(\(handle))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
            }
        }
    }

    private func rosterRoleGenderLine(_ member: FanTeamMember) -> String {
        let role = L10n.t(member.role.localizedKey, languageCode: languageCode)
        guard let gender = member.rosterGender else { return role }
        return "\(role) · \(L10n.t(gender.localizedKey, languageCode: languageCode))"
    }

    private func rosterMemberAccessibilityLabel(_ member: FanTeamMember) -> String {
        var parts: [String] = [
            FanTeamRosterRowPresentation.identityLine(
                displayName: member.displayName,
                username: member.username
            )
        ]
        if let number = member.playerNumber {
            parts.append(
                String(
                    format: L10n.t("fan_teams_player_number_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    number
                )
            )
        }
        if let position = FanTeamSportPositions.position(
            code: member.preferredPositionCode,
            sportToken: team.sport
        ) {
            parts.append(position.accessibilityLabel(languageCode: languageCode))
        } else if let code = member.preferredPositionCode {
            parts.append(code)
        }
        parts.append(L10n.t(member.role.localizedKey, languageCode: languageCode))
        if let gender = member.rosterGender {
            parts.append(L10n.t(gender.localizedKey, languageCode: languageCode))
        }
        if let joinedLine = FanTeamRosterJoinedCaption.line(
            teamName: team.name,
            joinedAt: member.joinedAt,
            languageCode: languageCode
        ) {
            parts.append(joinedLine)
        }
        return parts.joined(separator: ", ")
    }

    @MainActor
    private func saveMemberPlayerNumber(_ member: FanTeamMember, number: Int?) async {
        guard !isSavingPlayerNumber else { return }
        isSavingPlayerNumber = true
        defer { isSavingPlayerNumber = false }
        do {
            // Seat-scoped RPC: one path for account seats and managed players.
            try await service.setMemberPlayerNumber(
                teamId: team.id,
                membershipId: member.membershipId,
                playerNumber: number
            )
            if var detail {
                detail.members = detail.members.map { row in
                    row.membershipId == member.membershipId
                        ? row.replacingPlayerNumber(number)
                        : row
                }
                self.detail = detail
            }
            if memberPendingPlayerInformation?.membershipId == member.membershipId {
                memberPendingPlayerInformation = refreshedRosterMember(member)
            }
        } catch {
            if !FanTeamsLoadErrorPresentation.isCancellation(error) {
                errorText = L10n.t("fan_teams_set_player_number_failed", languageCode: languageCode)
            }
        }
    }

    @MainActor
    private func clearMemberPlayerNumber(_ member: FanTeamMember) async {
        await saveMemberPlayerNumber(member, number: nil)
    }

    @MainActor
    private func saveMemberPreferredPosition(_ member: FanTeamMember, code: String?) async {
        guard !isSavingPreferredPosition else { return }
        isSavingPreferredPosition = true
        defer { isSavingPreferredPosition = false }
        do {
            try await service.setMemberPreferredPosition(
                teamId: team.id,
                membershipId: member.membershipId,
                positionCode: code
            )
            if var detail {
                detail.members = detail.members.map { row in
                    row.membershipId == member.membershipId
                        ? row.replacingPreferredPositionCode(code)
                        : row
                }
                self.detail = detail
            }
            if memberPendingPlayerInformation?.membershipId == member.membershipId {
                memberPendingPlayerInformation = refreshedRosterMember(member)
            }
        } catch {
            if !FanTeamsLoadErrorPresentation.isCancellation(error) {
                errorText = L10n.t("fan_teams_set_player_position_failed", languageCode: languageCode)
            }
        }
    }

    @MainActor
    private func saveMemberPermissions(
        _ member: FanTeamMember,
        permissions: FanTeamPermissionSet
    ) async throws {
        guard !isSavingPermissions else { return }
        isSavingPermissions = true
        defer { isSavingPermissions = false }

        let previous = refreshedRosterMember(member)
        let updated = previous.replacingPermissions(useCustom: true, granted: permissions)
        replaceCanonicalRosterMember(updated)
        if memberPendingPlayerInformation?.membershipId == member.membershipId {
            memberPendingPlayerInformation = updated
        }

        do {
            let saved = try await service.setMemberPermissions(
                teamId: team.id,
                membershipId: member.membershipId,
                permissions: permissions
            )
            let reconciled = previous.replacingPermissions(useCustom: true, granted: saved)
            replaceCanonicalRosterMember(reconciled)
            if memberPendingPlayerInformation?.membershipId == member.membershipId {
                memberPendingPlayerInformation = reconciled
            }
        } catch {
            replaceCanonicalRosterMember(previous)
            if memberPendingPlayerInformation?.membershipId == member.membershipId {
                memberPendingPlayerInformation = previous
            }
            throw error
        }
    }

    @MainActor
    private func saveMemberRole(_ member: FanTeamMember, role: FanTeamMemberRole) async throws {
        guard member.role != role else { return }
        guard role.isAssignableViaRolePicker else {
            throw FanTeamsServiceError.invalidMemberRole
        }
        guard !isSavingTeamRole else { return }
        isSavingTeamRole = true
        defer { isSavingTeamRole = false }

        let previous = refreshedRosterMember(member)
        let updated = previous.replacingRole(role)
        FanTeamRPCTrace.log(
            step: "role.save.start",
            rpc: "set_fan_team_membership_role",
            extra: "membership=\(previous.membershipId.uuidString.lowercased()) " +
                "managed_player_id=\(previous.managedPlayerId?.uuidString.lowercased() ?? "nil") " +
                "user_id=\(previous.userId?.uuidString.lowercased() ?? "nil") " +
                "roleBefore=\(previous.role.rawValue) roleAfter=\(role.rawValue)"
        )
        // Deterministic local update — do not wait for reload/realtime to refresh UI.
        replaceCanonicalRosterMember(updated)

        do {
            try await service.setMemberRole(
                teamId: team.id,
                membershipId: previous.membershipId,
                role: role
            )
            memberPendingRoleEdit = nil
            // Soft reconcile in background; local state already shows the new role.
            Task { await softReloadRosterAfterRoleChange() }
        } catch {
            FanTeamRPCTrace.log(
                step: "role.save.failed",
                rpc: "set_fan_team_membership_role",
                error: error,
                extra: "membership=\(previous.membershipId.uuidString.lowercased()) " +
                    "revertedRole=\(previous.role.rawValue)"
            )
            replaceCanonicalRosterMember(previous)
            if !FanTeamsLoadErrorPresentation.isCancellation(error) {
                errorText = L10n.t("fan_teams_set_role_failed", languageCode: languageCode)
            }
            throw error
        }
    }

    @MainActor
    private func softReloadRosterAfterRoleChange() async {
        do {
            let members = try await service.listMembers(teamId: team.id)
            if var detail {
                detail.members = members
                detail.summary = detail.summary.applyingMemberCount(members.count)
                if let me = mapViewModel.currentUserAuthId,
                   let selfSeat = members.first(where: { $0.userId == me }) {
                    detail.summary = detail.summary.applyingMyRole(
                        selfSeat.role,
                        memberCount: members.count
                    )
                }
                self.detail = detail
            }
            if let pending = memberPendingPlayerInformation {
                memberPendingPlayerInformation = refreshedRosterMember(pending)
            }
        } catch {
#if DEBUG
            print("[TeamRole] softReloadFailed \(error.localizedDescription)")
#endif
        }
    }

    private func preferredPositionMenuAccessibilityLabel(for member: FanTeamMember) -> String {
        let actionKey = member.preferredPositionCode == nil
            ? "fan_teams_set_player_position"
            : "fan_teams_change_player_position"
        var parts = [L10n.t(actionKey, languageCode: languageCode)]
        if let position = FanTeamSportPositions.position(
            code: member.preferredPositionCode,
            sportToken: team.sport
        ) {
            parts.append(
                String(
                    format: L10n.t(
                        "fan_teams_player_position_current_a11y_format",
                        languageCode: languageCode
                    ),
                    locale: Locale(identifier: languageCode),
                    position.accessibilityLabel(languageCode: languageCode)
                )
            )
        }
        return parts.joined(separator: ", ")
    }

    private var rosterActiveMembersHeader: String {
        let playerCount = FanTeamRosterPlayerPresentation.playerCount(from: detail?.members ?? [])
        let displayCount = detail == nil ? team.memberCount : playerCount
        let members = String(
            format: L10n.t("fan_teams_members_count_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(displayCount)
        )
        let pendingCount = max(team.pendingInvitationCount, pendingInvitations.count)
        if team.canManage, pendingCount > 0 {
            let pending = String(
                format: L10n.t("fan_teams_pending_count_compact_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(pendingCount)
            )
            return "\(members) · \(pending)"
        }
        return members
    }

    private func openScheduleGame() {
        guard team.canOrganizeActivities else { return }
        pickupCreateFormMode = .add
    }

    private func openMakeAnnouncement() {
        guard team.canPublishAnnouncements else { return }
        pickupCreateFormMode = .addTeamAnnouncement
    }

    private func openPickupGameDetail(_ pickupGameId: UUID) {
        // Drop any stale Chat intent when opening a different event.
        pendingSelectChatAfterEventDetailDismiss = false
        pendingSelectChatEventId = nil
        // Team Schedule / Overview already know this is a Team Event — lock mode before first frame.
        let token = PickupDetailNavigationToken.teamEvent(gameId: pickupGameId, teamSummary: team)
        mapViewModel.seedPickupDiscoverTeamIdentityIfNeeded(
            gameId: pickupGameId,
            from: PickupGameTeamCreationContext(from: team)
        )
        pickupDetailNav = token
    }

    /// Event detail Chat → same Team's Chat tab. Returns whether the intent was accepted.
    @MainActor
    private func requestEmbeddedTeamChatTab(requestedTeamId: UUID, eventId: UUID) -> Bool {
        TeamEventChatNavigationDebug.log(
            "teamTabRequested=chat",
            detail: "teamID=\(requestedTeamId.uuidString.lowercased()) eventID=\(eventId.uuidString.lowercased()) hostTeamID=\(team.id.uuidString.lowercased())"
        )
        guard requestedTeamId == team.id else {
            TeamEventChatNavigationDebug.log(
                "routeMismatch",
                detail: "requested=\(requestedTeamId.uuidString.lowercased()) host=\(team.id.uuidString.lowercased())"
            )
            return false
        }
        guard summary.canAccessTeamChat else {
            TeamEventChatNavigationDebug.log(
                "navigationCancelled",
                detail: "reason=noTeamAccountAccess teamID=\(team.id.uuidString.lowercased())"
            )
            return false
        }
        pendingSelectChatAfterEventDetailDismiss = true
        pendingSelectChatEventId = eventId
        return true
    }

    @MainActor
    private func applyPendingTeamChatTabAfterEventDetailDismissIfNeeded() {
        guard pendingSelectChatAfterEventDetailDismiss else { return }
        let eventId = pendingSelectChatEventId
        pendingSelectChatAfterEventDetailDismiss = false
        pendingSelectChatEventId = nil

        guard summary.canAccessTeamChat else {
            TeamEventChatNavigationDebug.log(
                "navigationCancelled",
                detail: "reason=noTeamAccountAccessOnDismiss teamID=\(team.id.uuidString.lowercased())"
            )
            return
        }

        if reduceMotion {
            selectedTab = .chat
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selectedTab = .chat
            }
        }
        TeamEventChatNavigationDebug.log(
            "teamTabApplied=chat",
            detail: "teamID=\(team.id.uuidString.lowercased()) eventID=\(eventId?.uuidString.lowercased() ?? "nil")"
        )
    }

    /// Action Center Review → Schedule tab + game detail + pending join requests for this Team event.
    @MainActor
    private func consumePendingTeamScheduleJoinApprovalIfNeeded() async {
        guard let pending = mapViewModel.pendingTeamScheduleJoinApproval,
              pending.teamId == team.id else { return }
        selectedTab = .schedule
        let gameId = pending.pickupGameId
        mapViewModel.seedPickupDiscoverTeamIdentityIfNeeded(
            gameId: gameId,
            from: PickupGameTeamCreationContext(from: team)
        )
        pickupDetailNav = .teamEvent(gameId: gameId, teamSummary: team)
        let game = await mapViewModel.loadPickupGameRowForDetailIfNeeded(id: gameId)
            ?? mapViewModel.resolvedPickupGameRow(for: gameId)
        if let game {
            organizerJoinRequestsGame = game
        } else {
            // Detail may still load; keep requests presentation pending via token fallback.
            mapViewModel.pendingOrganizerJoinRequestsGameToken =
                PickupDetailNavigationToken.standalone(gameId)
        }
        mapViewModel.clearPendingTeamScheduleJoinApproval()
    }

    /// Schedule APNs → Schedule tab + game detail only (no organizer requests).
    @MainActor
    private func consumePendingTeamScheduleEventDeepLinkIfNeeded() async {
        guard let pending = mapViewModel.pendingTeamScheduleEventDeepLink,
              pending.teamId == team.id else { return }
        selectedTab = .schedule
        let gameId = pending.pickupGameId
        mapViewModel.seedPickupDiscoverTeamIdentityIfNeeded(
            gameId: gameId,
            from: PickupGameTeamCreationContext(from: team)
        )
        pickupDetailNav = .teamEvent(gameId: gameId, teamSummary: team)
        _ = await mapViewModel.loadPickupGameRowForDetailIfNeeded(id: gameId)
        await mapViewModel.loadTeamScheduleAttendance(pickupGameId: gameId, force: true)
        mapViewModel.clearPendingTeamScheduleEventDeepLink()
#if DEBUG
        print(
            "[TeamScheduleNotification] deepLinkResolved teamScheduleEvent " +
            "team_id=\(team.id.uuidString.lowercased()) event_id=\(gameId.uuidString.lowercased())"
        )
#endif
    }

    private func gameListRow(_ game: FanTeamGame) -> some View {
        let policy = FanTeamEventPresentation.policy(for: game.gameType)
        let matchup = FanTeamScheduleMatchup.matchupLine(
            homeTeamName: team.name,
            opponentName: game.opponentName,
            languageCode: languageCode
        ) ?? {
            guard policy.requiresOpponent, game.opponentTeamId != nil else { return nil }
            let vs = L10n.t("fan_team_schedule_vs", languageCode: languageCode)
            let opp = L10n.t("fan_teams_opponent_team", languageCode: languageCode)
            return "\(team.name) \(vs) \(opp)"
        }()
        let usesMatchupPrimary = policy.requiresOpponent && matchup != nil
        return FanTeamGameRichCard(
            game: game,
            teamName: team.name,
            teamSport: team.sport,
            teamColorHex: team.colorHex,
            languageCode: languageCode,
            mapViewModel: mapViewModel,
            headline: matchup ?? game.displayTitle,
            emphasizeTitle: usesMatchupPrimary,
            rsvpSubject: game.gameType == .announcement
                ? nil
                : FanTeamRSVPSubject.currentViewer(
                from: detail?.members ?? [],
                currentUserId: mapViewModel.currentUserAuthId
            ),
            onOpenDetail: { openPickupGameDetail(game.id) }
        )
    }

    private func emptyCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.bold))
            Text(body).font(.caption).foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .padding(.horizontal, 16)
    }

    private func reload(surfaceError: Bool = true) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var loaded = try await service.loadDetail(for: team)
            let playerCount = FanTeamRosterPlayerPresentation.playerCount(from: loaded.members)
            // Server-authoritative role + effective permissions + player-seat count.
            if let me = mapViewModel.currentUserAuthId,
               let selfSeat = loaded.members.first(where: { $0.userId == me }) {
                let effective = selfSeat.effectivePermissions
                loaded.summary = loaded.summary.applyingMyRole(
                    selfSeat.role,
                    memberCount: playerCount,
                    myPermissions: effective
                )
            } else {
                loaded.summary = loaded.summary.applyingMemberCount(playerCount)
            }
            detail = loaded
            let announcementCount = loaded.games.filter { $0.gameType == .announcement }.count
            TeamDetailCrashTrace.detailLoadSuccess(
                teamID: loaded.summary.id,
                gameCount: loaded.games.count,
                announcementCount: announcementCount
            )
            await refreshClearedAnnouncementIds()
            if loaded.summary.canManage {
                pendingInvitations = (try? await service.listPendingInvitations(teamId: loaded.summary.id)) ?? []
            } else {
                pendingInvitations = []
            }
            errorText = nil
            hydratePlayerInfoSelectionFromStore(source: "reload.beforeSeats")
            await refreshManagedPlayerSeats()
        } catch {
            TeamDetailCrashTrace.detailLoadFailure(teamID: team.id, error: error)
            FanTeamRPCTrace.log(
                step: "C.reload.failed",
                rpc: "loadDetail",
                error: error,
                extra: "surfaceError=\(surfaceError) team=\(team.id.uuidString.lowercased())"
            )
            if surfaceError, let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
            reconcilePlayerInfoSelection(
                catalogComplete: managedPlayerSeatsCatalogComplete,
                source: "reload.error"
            )
        }
    }

    private func cancelPendingInvitation(_ invitation: FanTeamPendingInvitation) async {
        guard !busyPendingInvitationIds.contains(invitation.id) else { return }
        busyPendingInvitationIds.insert(invitation.id)
        defer { busyPendingInvitationIds.remove(invitation.id) }
        do {
            try await service.cancelInvitation(invitationId: invitation.invitationId)
            pendingInvitations.removeAll { $0.id == invitation.id }
            if var detail {
                detail.summary = detail.summary.applyingPendingInvitationCount(pendingInvitations.count)
                self.detail = detail
            }
            onTeamsChanged()
        } catch {
            if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
        }
    }

    private func isPendingInvitationResendCoolingDown(_ invitationId: UUID) -> Bool {
        guard let until = resendCooldownUntilByInvitationId[invitationId] else { return false }
        return until > Date()
    }

    private func resendPendingInvitation(_ invitation: FanTeamPendingInvitation) async {
        guard !busyPendingInvitationIds.contains(invitation.id) else { return }
        if isPendingInvitationResendCoolingDown(invitation.id) {
            errorText = L10n.t("fan_teams_invitation_resend_rate_limited", languageCode: languageCode)
            return
        }
        busyPendingInvitationIds.insert(invitation.id)
        defer { busyPendingInvitationIds.remove(invitation.id) }
        do {
            let outcome = try await service.resendInvitation(invitationId: invitation.invitationId)
            switch outcome {
            case .sent:
                resendCooldownUntilByInvitationId[invitation.id] = Date().addingTimeInterval(60)
                showResendInviteSuccessAlert = true
            case .rateLimited(let serverMessage):
                let trimmed = serverMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                errorText = trimmed.isEmpty
                    ? L10n.t("fan_teams_invitation_resend_rate_limited", languageCode: languageCode)
                    : trimmed
                resendCooldownUntilByInvitationId[invitation.id] = Date().addingTimeInterval(60)
            }
        } catch {
            errorText = L10n.t("fan_teams_invitation_resend_failed", languageCode: languageCode)
        }
    }

    @MainActor
    private func openRosterMemberProfile(_ member: FanTeamMember) {
        openTeamMemberProfile(member, context: "fan_team_roster")
    }

    /// Shared Overview leadership + Roster profile open (self → own preview; others → public profile).
    @MainActor
    private func openTeamMemberProfile(_ member: FanTeamMember, context: String) {
        // Managed players have no public profile to open.
        guard let memberUserId = member.userId else { return }
        if FanTeamLeadership.usesOwnPublicProfilePreview(
            memberUserId: memberUserId,
            currentUserId: mapViewModel.currentUserAuthId
        ) {
            mapViewModel.presentOwnPublicProfilePreview()
            return
        }
        mapViewModel.presentPublicProfile(
            userId: memberUserId,
            context: context
        )
    }

    /// Patch in-memory roster identity when a fan avatar updates (no extra fetch).
    private func applyRosterAvatarChange(_ change: FanProfileAvatarChange) {
        guard var detail else { return }
        var didChange = false
        let nextMembers = detail.members.map { member -> FanTeamMember in
            guard member.userId == change.userId else { return member }
            didChange = true
            return member.replacingAvatars(
                avatarURL: change.avatarURL.isEmpty ? member.avatarURL : change.avatarURL,
                avatarThumbnailURL: change.avatarThumbnailURL ?? member.avatarThumbnailURL
            )
        }
        guard didChange else { return }
        detail.members = nextMembers
        self.detail = detail
    }

    private func applyManagedPlayerAvatarChange(_ change: FanManagedPlayerAvatarChange) {
        managedPlayerSeats = managedPlayerSeats.map { seat in
            guard seat.managedPlayerId == change.managedPlayerId else { return seat }
            return seat.applyingAvatar(
                avatarURL: change.avatarURL,
                avatarThumbnailURL: change.avatarThumbnailURL
            )
        }
        if var detail {
            detail.members = detail.members.map {
                $0.applyingManagedPlayerAvatar(
                    managedPlayerId: change.managedPlayerId,
                    avatarURL: change.avatarURL,
                    avatarThumbnailURL: change.avatarThumbnailURL
                )
            }
            detail.summary = detail.summary.applyingManagedPlayerAvatarChange(change)
            self.detail = detail
        }
        if let pending = memberPendingPlayerInformation,
           pending.managedPlayerId == change.managedPlayerId {
            memberPendingPlayerInformation = pending.applyingManagedPlayerAvatar(
                managedPlayerId: change.managedPlayerId,
                avatarURL: change.avatarURL,
                avatarThumbnailURL: change.avatarThumbnailURL
            )
        }
        reconcilePlayerInfoSelection(
            catalogComplete: managedPlayerSeatsCatalogComplete,
            source: "managedPlayerAvatarChange"
        )
#if DEBUG
        ManagedPlayerAvatarDebug.log(
            "team_detail_local_replaced",
            managedPlayerId: change.managedPlayerId,
            newAvatarURL: change.avatarURL,
            newThumbnailURL: change.avatarThumbnailURL,
            localArrayReplaced: true,
            refreshTriggered: false
        )
#endif
    }

    @MainActor
    private func openPendingInviteeProfile(_ invitation: FanTeamPendingInvitation) {
        if invitation.inviteeUserId == mapViewModel.currentUserAuthId {
            mapViewModel.presentOwnPublicProfilePreview()
            return
        }
        mapViewModel.presentPublicProfile(
            userId: invitation.inviteeUserId,
            context: "fan_team_roster_pending"
        )
    }

    @MainActor
    private func messageRosterMember(_ member: FanTeamMember) async {
        guard let memberUserId = member.userId else { return }
        guard FanTeamRosterMemberActions.canMessage(
            member: member,
            currentUserId: mapViewModel.currentUserAuthId
        ) else { return }
        guard !isMessagingMember else { return }

        if chatViewModel.isEitherDirectionBlocked(with: memberUserId) {
            errorText = L10n.t("fan_teams_message_blocked", languageCode: languageCode)
            return
        }

        isMessagingMember = true
        defer { isMessagingMember = false }
        do {
            let conversationId = try await chatViewModel.startDirectConversationWithFriend(
                friendUserId: memberUserId
            )
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            chatViewModel.pendingDmOpenPreview = member.previewForDirectMessage(
                conversationId: conversationId
            )
            dismiss()
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) { return }
            errorText = L10n.t("fan_teams_message_failed", languageCode: languageCode)
        }
    }

    @MainActor
    private func removeRosterMember(_ member: FanTeamMember) async {
        guard FanTeamRosterMemberActions.canRemove(
            member: member,
            viewerCanManage: team.canManage,
            currentUserId: mapViewModel.currentUserAuthId
        ) else { return }
        guard !isRemovingMember else { return }
        isRemovingMember = true
        defer { isRemovingMember = false }
        do {
            if member.isManagedPlayer {
                try await service.removeMembership(membershipId: member.membershipId)
            } else if let memberUserId = member.userId {
                try await service.removeMember(teamId: team.id, userId: memberUserId)
            } else {
                return
            }
            onTeamsChanged()
            await reload()
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) { return }
            errorText = L10n.t("fan_teams_remove_member_failed", languageCode: languageCode)
        }
    }

    @MainActor
    private func leaveTeam() async {
        guard team.canLeaveTeam, !isLeaving else { return }
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await service.leaveTeam(teamId: team.id)
            onTeamsChanged()
            dismiss()
        } catch {
            if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
        }
    }

    @MainActor
    private func deleteTeam() async {
        guard team.canDeleteTeam, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await service.deleteTeam(teamId: team.id)
            onTeamsChanged()
            showDeleteSuccessAlert = true
        } catch {
            // Admin-deactivated (or otherwise inactive) Team with no owner deletion event:
            // refresh My Teams and leave Detail — do not treat team_id as an event id.
            if FanTeamsService.isTeamAlreadyInactiveDeleteError(error) {
                onTeamsChanged()
                onTeamDeleted()
                dismiss()
                return
            }
            if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
        }
    }
}

// MARK: - Report Team

struct ReportFanTeamSheet: View {
    let teamId: UUID
    var onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var reportCategory: FanTeamReportCategory?
    @State private var reportDetails = ""
    @State private var reportSheetError: String?
    @State private var isSubmittingReport = false

    private let service = FanTeamsService()
    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        L10n.t("fan_teams_report_why", languageCode: languageCode),
                        selection: $reportCategory
                    ) {
                        Text(L10n.t("fan_teams_report_select_category", languageCode: languageCode))
                            .tag(Optional<FanTeamReportCategory>.none)
                        ForEach(FanTeamReportCategory.allCases) { category in
                            Text(category.localizedTitle(languageCode: languageCode))
                                .tag(Optional(category))
                                .accessibilityLabel(category.localizedTitle(languageCode: languageCode))
                        }
                    }
                    .disabled(isSubmittingReport)
                } footer: {
                    if reportCategory == nil {
                        Text(L10n.t("fan_teams_report_choose_category", languageCode: languageCode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField(
                        L10n.t("fan_teams_report_details", languageCode: languageCode),
                        text: $reportDetails,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .disabled(isSubmittingReport)
                    .onChange(of: reportDetails) { _, newValue in
                        if newValue.count > FanTeamsService.teamReportDetailsMaxCharacters {
                            reportDetails = String(newValue.prefix(FanTeamsService.teamReportDetailsMaxCharacters))
                        }
                    }
                }

                if isSubmittingReport {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L10n.t("fan_teams_report_reporting", languageCode: languageCode))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let reportSheetError, !reportSheetError.isEmpty {
                    Section {
                        Text(reportSheetError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle(L10n.t("fan_teams_report", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) {
                        dismiss()
                    }
                    .disabled(isSubmittingReport)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("fan_teams_report_submit", languageCode: languageCode)) {
                        Task { await submit() }
                    }
                    .disabled(isSubmittingReport || reportCategory == nil)
                }
            }
            .interactiveDismissDisabled(isSubmittingReport)
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func submit() async {
        guard !isSubmittingReport else { return }
        guard let category = reportCategory else {
            reportSheetError = L10n.t("fan_teams_report_choose_category", languageCode: languageCode)
            return
        }

        isSubmittingReport = true
        reportSheetError = nil
        defer { isSubmittingReport = false }

        let trimmedDetails = reportDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsPayload = trimmedDetails.isEmpty ? nil : trimmedDetails

        do {
            _ = try await service.reportTeam(
                teamId: teamId,
                category: category,
                details: detailsPayload
            )
            onSubmitted()
            dismiss()
        } catch let reportError as FanTeamReportError {
            switch reportError {
            case .duplicateOpenReport:
                reportSheetError = L10n.t("fan_teams_report_already_reported", languageCode: languageCode)
            case .notActiveMember:
                reportSheetError = L10n.t("fan_teams_report_not_member", languageCode: languageCode)
            }
        } catch {
            ModerationService.logReportSubmitFailure(error, context: "fan_team_report")
            let mapped = ModerationService.userFacingReportSubmitError(error)
            reportSheetError = mapped.isEmpty
                ? L10n.t("fan_teams_report_failed", languageCode: languageCode)
                : mapped
        }
    }
}

enum FanTeamPendingInvitationCopy {
    /// Manager-only pending line for My Teams cards. Nil when not manageable or count is 0.
    static func line(count: Int, canManage: Bool, languageCode: String) -> String? {
        guard canManage, count > 0 else { return nil }
        if count == 1 {
            return L10n.t("fan_teams_invitations_pending_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("fan_teams_invitations_pending_other_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            count
        )
    }
}

/// Team Detail tab strip. Chat is included whenever the account can access the Team.
enum FanTeamDetailTabComposition {
    static func visibleTabs(canAccessTeamChat: Bool) -> [FanTeamDetailTab] {
        FanTeamDetailTab.allCases.filter { tab in
            if tab == .chat { return canAccessTeamChat }
            return true
        }
    }

    static func showsChatTab(for summary: FanTeamSummary) -> Bool {
        summary.canAccessTeamChat
    }
}

enum FanTeamDetailTab: String, CaseIterable, Identifiable {
    case overview, chat, schedule, roster
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .overview: return "fan_teams_tab_overview"
        case .chat: return "fan_teams_tab_chat"
        case .schedule: return "fan_teams_tab_schedule"
        case .roster: return "fan_teams_tab_roster"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "info.circle.fill"
        case .chat: return "bubble.left.and.bubble.right"
        case .schedule: return "calendar"
        case .roster: return "person.2"
        }
    }
}

/// Compact owner/manager editor for Team-specific jersey numbers (0–99 / clear).
struct FanTeamPlayerNumberEditorSheet: View {
    let memberName: String
    let initialNumber: Int?
    let teamAccent: Color
    let languageCode: String
    let isSaving: Bool
    let onSave: (Int?) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: String = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.t("fan_teams_player_number", languageCode: languageCode),
                        text: $draft
                    )
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isSaving)
                    Text(
                        String(
                            format: L10n.t(
                                "fan_teams_player_number_range_help",
                                languageCode: languageCode
                            ),
                            locale: Locale(identifier: languageCode),
                            FanTeamPlayerNumber.min,
                            FanTeamPlayerNumber.max
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    if let validationError {
                        Text(validationError)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.dangerRed)
                    }
                } header: {
                    Text(memberName)
                }

                if initialNumber != nil {
                    Section {
                        Button(role: .destructive) {
                            onClear()
                        } label: {
                            Text(L10n.t("fan_teams_remove_number", languageCode: languageCode))
                        }
                        .disabled(isSaving)
                        .accessibilityLabel(
                            L10n.t("fan_teams_remove_number", languageCode: languageCode)
                        )
                    }
                }
            }
            .navigationTitle(
                L10n.t(
                    initialNumber == nil
                        ? "fan_teams_set_player_number"
                        : "fan_teams_change_player_number",
                    languageCode: languageCode
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) {
                        onCancel()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save", languageCode: languageCode)) {
                        commit()
                    }
                    .disabled(isSaving)
                    .tint(teamAccent)
                }
            }
            .onAppear {
                if let initialNumber {
                    draft = "\(initialNumber)"
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onSave(nil)
            return
        }
        guard let value = FanTeamPlayerNumber.parse(trimmed) else {
            validationError = L10n.t("fan_teams_player_number_invalid", languageCode: languageCode)
            return
        }
        validationError = nil
        onSave(value)
    }
}

// MARK: - Add members

/// Invite accepted friends onto a Fan Team.
/// Future: add a Friends/Groups segmented control and reuse
/// ``FriendGroupsBrowseAndSelectView`` / ``FriendGroupSelectionStore``
/// (see ``FriendGroupInviteIntegrationPoints``). Do not treat Friend Groups as Team membership.
struct AddFanTeamMembersSheet: View {
    let teamId: UUID
    @ObservedObject var chatViewModel: ChatViewModel
    var onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var selectedIds: Set<UUID> = []
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var successText: String?

    private let service = FanTeamsService()
    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    private var candidates: [ChatViewModel.FriendDisplay] {
        chatViewModel.friends.filter {
            !$0.isGroupConversation
                && chatViewModel.chipKind(forOtherUserId: $0.preview.id) == .friends
                && !chatViewModel.isEitherDirectionBlocked(with: $0.preview.id)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { friend in
                        Button {
                            if selectedIds.contains(friend.preview.id) {
                                selectedIds.remove(friend.preview.id)
                            } else {
                                selectedIds.insert(friend.preview.id)
                            }
                        } label: {
                            HStack {
                                ProfileAvatarView(preview: friend.preview, size: 36)
                                Text(friend.preview.displayName)
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer()
                                Image(systemName: selectedIds.contains(friend.preview.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        selectedIds.contains(friend.preview.id)
                                            ? FGColor.accentGreen
                                            : FGColor.mutedText(colorScheme)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(L10n.t("fan_teams_invite_teammates_footer", languageCode: languageCode))
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(FGColor.dangerRed)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(L10n.t("fan_teams_invite_teammates", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("fan_teams_invite_teammates", languageCode: languageCode)) {
                        Task { await invite() }
                    }
                    .disabled(selectedIds.isEmpty || isSubmitting)
                }
            }
            .alert(
                L10n.t("fan_teams_invite_teammates", languageCode: languageCode),
                isPresented: Binding(
                    get: { successText != nil },
                    set: { if !$0 { successText = nil } }
                )
            ) {
                Button(L10n.t("OK", languageCode: languageCode)) {
                    successText = nil
                    onAdded()
                    dismiss()
                }
            } message: {
                Text(successText ?? "")
            }
        }
    }

    private func invite() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let sent = try await service.addMembers(teamId: teamId, memberIds: Array(selectedIds))
            successText = String(
                format: L10n.t("fan_teams_invitations_sent_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                sent
            )
        } catch {
            if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
        }
    }
}

// MARK: - Formatting helpers

enum FanTeamDateFormatting {
    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEE, MMM d · h:mm a")
        return f
    }()

    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    private static let monthOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }()

    private static let weekdayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    static func gameWhen(_ date: Date, languageCode: String) -> String {
        dayTime.locale = Locale(identifier: languageCode)
        return dayTime.string(from: date)
    }

    static func shortDay(_ date: Date, languageCode: String) -> String {
        short.locale = Locale(identifier: languageCode)
        return short.string(from: date)
    }

    static func scheduleMonth(_ date: Date, languageCode: String) -> String {
        monthOnly.locale = Locale(identifier: languageCode)
        return monthOnly.string(from: date).uppercased(with: Locale(identifier: languageCode))
    }

    static func scheduleDayNumber(_ date: Date, languageCode: String) -> String {
        dayOnly.locale = Locale(identifier: languageCode)
        return dayOnly.string(from: date)
    }

    static func scheduleWeekday(_ date: Date, languageCode: String) -> String {
        weekdayOnly.locale = Locale(identifier: languageCode)
        return weekdayOnly.string(from: date).uppercased(with: Locale(identifier: languageCode))
    }

    static func scheduleTime(_ date: Date, languageCode: String) -> String {
        timeOnly.locale = Locale(identifier: languageCode)
        return timeOnly.string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Team Schedule Option C card — date rail left, event details + RSVP right.
private struct FanTeamGameRichCard: View {
    let game: FanTeamGame
    let teamName: String
    let teamSport: String
    let teamColorHex: String?
    let languageCode: String
    @ObservedObject var mapViewModel: MapViewModel
    let headline: String
    var emphasizeTitle: Bool = false
    var showsCardChrome: Bool = true
    /// When non-nil and eligible, show Schedule quick RSVP for this subject.
    var rsvpSubject: FanTeamRSVPSubject? = nil
    var onOpenDetail: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var dateBadgeWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var dateTypeIconSize: CGFloat = 26

    private var sportToken: String {
        let s = game.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? teamSport : s
    }

    /// Team accent for RSVP / directions chrome.
    private var accent: Color {
        if let teamColorHex, let c = Color(fanTeamHex: teamColorHex) { return c }
        return SportFilterCatalog.resolve(sportToken).accent
    }

    /// Event-type accent for labels, sport ring, and date-badge icon circle.
    private var dateBlockColor: Color {
        game.gameType.scheduleDateBlockColor
    }

    private var dateBlockGradient: LinearGradient {
        let stops = game.gameType.scheduleDateBlockGradientColors
        return LinearGradient(colors: [stops.top, stops.bottom], startPoint: .top, endPoint: .bottom)
    }

    private var roster: PickupGameRosterPayload? {
        mapViewModel.pickupGameRosterByGameId[game.id]
    }

    private var goingCount: Int {
        roster?.playingTotal ?? 0
    }

    private var pendingCount: Int {
        PickupGameRosterPresentation.pendingVisibleToViewer(
            isOrganizer: roster?.viewer_is_organizer == true,
            pendingCount: roster?.pending.count ?? 0
        )
    }

    private var showsQuickRSVP: Bool {
        guard rsvpSubject != nil else { return false }
        guard FanTeamScheduleQuickRSVPEligibility.showsQuickRSVPControls(game: game) else {
            return false
        }
        return true
    }

    private var isExcludedFromEvent: Bool {
        guard let rsvpSubject else { return false }
        return FanTeamScheduleQuickRSVPEligibility.isExcludedFromEvent(
            subjectUserId: rsvpSubject.userId,
            gameId: game.id,
            roster: roster
        )
    }

    private var isPrivateEvent: Bool {
        mapViewModel.resolvedPickupGameRow(for: game.id)?.is_visible == false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            dateBlock
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        onOpenDetail?()
                    } label: {
                        eventDetails
                    }
                    .buttonStyle(.plain)
                    .disabled(onOpenDetail == nil)

                    VStack(spacing: 8) {
                        SportArtworkIconView(sport: sportToken, diameter: 44)
                            .overlay {
                                Circle()
                                    .strokeBorder(dateBlockColor.opacity(0.45), lineWidth: 1.5)
                            }
                            .accessibilityHidden(true)
                        if game.hasUsableDirectionsCoordinate {
                            FanTeamScheduleDirectionsButton(
                                game: game,
                                languageCode: languageCode,
                                accent: accent
                            )
                        }
                    }
                    .padding(.trailing, 10)
                    .padding(.top, 10)
                }

                if let roster, !roster.stackMembers.isEmpty {
                    HStack(spacing: 8) {
                        PickupPlayingAvatarStack(members: roster.stackMembers, diameter: 20)
                        Text(socialProofLine)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                if showsQuickRSVP, let rsvpSubject {
                    Divider()
                        .opacity(colorScheme == .dark ? 0.35 : 0.55)
                        .padding(.horizontal, 12)
                    FanTeamScheduleQuickRSVPView(
                        gameId: game.id,
                        subject: rsvpSubject,
                        accent: accent,
                        languageCode: languageCode,
                        isExcluded: isExcludedFromEvent,
                        mapViewModel: mapViewModel
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .id(game.id)
                } else if FanTeamScheduleQuickRSVPEligibility.isCancelled(game) {
                    Divider()
                        .opacity(colorScheme == .dark ? 0.35 : 0.55)
                        .padding(.horizontal, 12)
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.dangerRed)
                            .accessibilityHidden(true)
                        Text(L10n.t("fan_team_schedule_event_cancelled", languageCode: languageCode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.dangerRed)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsCardChrome {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if showsCardChrome {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(dateBlockColor.opacity(0.28), lineWidth: 1)
            }
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06),
            radius: showsCardChrome ? 8 : 0,
            x: 0,
            y: showsCardChrome ? 3 : 0
        )
        .task(id: game.id) {
            guard game.gameType != .announcement else { return }
            // Prefer batched Schedule prefetch; fall back only for cache misses.
            await mapViewModel.loadTeamScheduleAttendanceIfMissing(pickupGameId: game.id)
        }
    }

    /// Premium floating date badge (mockup): weekday / day / month + overlapping type icon.
    private var dateBlock: some View {
        VStack(spacing: -(dateTypeIconSize * 0.42)) {
            dateBadgeFace
            dateTypeIconBadge
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            FanTeamDateFormatting.gameWhen(game.startsAt, languageCode: languageCode)
        )
    }

    private var dateBadgeFace: some View {
        VStack(spacing: 3) {
            Text(FanTeamDateFormatting.scheduleWeekday(game.startsAt, languageCode: languageCode))
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .tracking(0.5)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Text(FanTeamDateFormatting.scheduleDayNumber(game.startsAt, languageCode: languageCode))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(FanTeamDateFormatting.scheduleMonth(game.startsAt, languageCode: languageCode))
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .tracking(0.5)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .multilineTextAlignment(.center)
        .frame(width: dateBadgeWidth)
        .padding(.top, 11)
        .padding(.bottom, 13)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(dateBlockGradient)
                .overlay {
                    // Soft top highlight for a premium Apple-style finish.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.30),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.55)
                            )
                        )
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.38),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.12),
                    radius: 5,
                    x: 0,
                    y: 3
                )
        }
    }

    private var dateTypeIconBadge: some View {
        ZStack {
            Circle()
                .fill(dateBlockColor)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.16),
                    radius: 2.5,
                    x: 0,
                    y: 1.5
                )
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
            Image(systemName: game.gameType.filterSystemImage)
                .font(.system(size: max(9, dateTypeIconSize * 0.40), weight: .bold))
                .foregroundStyle(Color.white)
                .minimumScaleFactor(0.7)
        }
        .frame(width: dateTypeIconSize, height: dateTypeIconSize)
        .accessibilityHidden(true)
    }

    private var eventDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: game.gameType.filterSystemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(dateBlockColor)
                    .accessibilityHidden(true)
                Text(L10n.t(game.gameType.localizedKey, languageCode: languageCode).uppercased(with: Locale(identifier: languageCode)))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(dateBlockColor)
                    .lineLimit(1)
                if game.isScoringLive {
                    Text(L10n.t("fan_team_score_live", languageCode: languageCode))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(FGColor.dangerRed))
                } else if game.isScoringFinal {
                    Text(L10n.t("fan_team_score_final", languageCode: languageCode))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(dateBlockColor)
                }
                if isPrivateEvent {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .accessibilityLabel(
                            L10n.t("pickup_form_visibility_private", languageCode: languageCode)
                        )
                }
                Spacer(minLength: 0)
            }

            Text(emphasizeTitle ? headline : game.displayTitle)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !emphasizeTitle, headline != game.displayTitle {
                Text(headline)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }

            if game.isScoringFinal || game.isScoringLive, game.isScoreCapable,
               FanTeamEventScoring.hasOpponent(opponentName: game.opponentName, opponentTeamId: game.opponentTeamId) {
                FanTeamEventResultScoreLine(
                    teamName: teamName,
                    opponentName: game.opponentName ?? "",
                    teamScore: game.teamScoreValue,
                    opponentScore: game.opponentScoreValue,
                    languageCode: languageCode,
                    showsFinalBadge: game.isScoringFinal
                )
            }

            if FanTeamEventPresentation.policy(for: game.gameType).showsCompetitionLevel,
               let level = game.competitionLevel
                ?? mapViewModel.resolvedPickupGameRow(for: game.id)?.competitionLevel {
                Text(level.displayTitle(languageCode: languageCode))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(FanTeamDateFormatting.scheduleTime(game.startsAt, languageCode: languageCode))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(FGColor.secondaryText(colorScheme))

            if !game.locationLine.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(game.locationLine)
                        .font(.caption2.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(.leading, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var socialProofLine: String {
        var parts: [String] = []
        if goingCount > 0 {
            parts.append("\(goingCount) \(L10n.t("Going", languageCode: languageCode))")
        }
        if pendingCount > 0 {
            parts.append("\(pendingCount) \(L10n.t("Maybe", languageCode: languageCode))")
        }
        if parts.isEmpty {
            return L10n.t("pickup_detail_team_awaiting_response", languageCode: languageCode)
        }
        return parts.joined(separator: " · ")
    }
}


private extension Color {
    var fanTeamHexString: String {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", UInt(r * 255), UInt(g * 255), UInt(b * 255))
        #else
        return "#22C25A"
        #endif
    }
}

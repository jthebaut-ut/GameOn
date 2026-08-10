import Combine
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Chat section: My Teams list

struct MyTeamsChatSectionView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    var onOpenTeamChat: (FanTeamChatContext) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @StateObject private var store = MyTeamsStore()
    @State private var searchText = ""
    @State private var showingCreate = false
    @State private var selectedTeam: FanTeamSummary?
    @State private var errorText: String?
    @State private var teamMarkRefreshTokens: [UUID: UUID] = [:]
    @State private var highlightedInvitationId: UUID?
    @State private var deletedTeamBanner: String?
    @State private var createTeamInfoBanner: String?
    @State private var myTeamsAdLayoutWidth: CGFloat = 320

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var filteredTeams: [FanTeamSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.teams }
        return store.teams.filter {
            $0.name.lowercased().contains(q)
                || $0.sport.lowercased().contains(q)
        }
    }

    private var myTeamsFeedItems: [ChatMyTeamsListItem] {
        ChatMyTeamsAdPlacement.listItems(for: filteredTeams)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.isLoading && store.teams.isEmpty && store.invitations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTeams.isEmpty && store.invitations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !store.invitations.isEmpty {
                            Text(L10n.t("fan_teams_invitations_section", languageCode: languageCode))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .padding(.horizontal, 2)

                            ForEach(store.invitations) { invitation in
                                FanTeamInvitationCardView(
                                    invitation: invitation,
                                    languageCode: languageCode,
                                    isBusy: store.busyInvitationIds.contains(invitation.id),
                                    isHighlighted: highlightedInvitationId == invitation.id,
                                    onAccept: {
                                        Task {
                                            do {
                                                _ = try await store.acceptInvitation(invitation)
                                                syncMyTeamsInvitationBadge()
                                            } catch {
                                                if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                                                    errorText = message
                                                }
                                            }
                                        }
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

                        if !filteredTeams.isEmpty || !store.invitations.isEmpty {
                            Text(L10n.t("fan_teams_your_teams", languageCode: languageCode))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .padding(.horizontal, 2)
                                .padding(.top, store.invitations.isEmpty ? 0 : 8)
                        }

                        if filteredTeams.isEmpty {
                            Text(L10n.t("fan_teams_empty_body", languageCode: languageCode))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .padding(.vertical, 8)
                        } else {
                            ForEach(myTeamsFeedItems) { item in
                                myTeamsFeedRow(item)
                            }
                            .onAppear {
                                logMyTeamsAdPlacementIfNeeded()
                            }
                            .onChange(of: filteredTeams.map(\.id)) { _, _ in
                                logMyTeamsAdPlacementIfNeeded()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear {
                                    updateMyTeamsAdLayoutWidth(geometry.size.width)
                                }
                                .onChange(of: geometry.size.width) { _, newWidth in
                                    updateMyTeamsAdLayoutWidth(newWidth)
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(colorScheme == .dark ? Color.black : Color(.systemBackground))
        .task {
            await store.refresh(source: "section.task")
            syncMyTeamsInvitationBadge()
            await applyPendingInvitationHighlightIfNeeded()
        }
        .refreshable {
            await store.refresh(source: "section.refreshable")
            syncMyTeamsInvitationBadge()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            FanTeamIdentityRealtimeCoordinator.shared.handleSceneBecameActive()
            Task {
                await store.refresh(source: "section.sceneActive")
                syncMyTeamsInvitationBadge()
            }
        }
        .onAppear {
            // Invitation-only soft refresh; full list refresh is owned by `.task` / scene / pull.
            Task {
                await store.refreshInvitations(source: "section.onAppear")
                syncMyTeamsInvitationBadge()
                await applyPendingInvitationHighlightIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fanTeamInvitationPushArrivedInForeground)) { _ in
            Task {
                await store.refreshInvitations(source: "push.invitationForeground")
                syncMyTeamsInvitationBadge()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fanTeamDeletedPushArrivedInForeground)) { note in
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
        .onChange(of: chatViewModel.pendingHighlightFanTeamInvitationId) { _, _ in
            Task { await applyPendingInvitationHighlightIfNeeded() }
        }
        .sheet(isPresented: $showingCreate) {
            CreateFanTeamSheet(mapViewModel: mapViewModel, chatViewModel: chatViewModel) { teamId, logoWarning in
                Task {
                    await store.refresh(source: "createTeam.completed")
                    if let team = store.teams.first(where: { $0.id == teamId }) {
                        selectedTeam = team
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
                }
            )
        }
        .alert(
            L10n.t("fan_teams_error_title", languageCode: languageCode),
            isPresented: Binding(
                get: { errorText != nil || store.errorText != nil },
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
            if selectedTeam?.id == change.teamId {
                selectedTeam = selectedTeam?.applying(change)
            }
        }
    }

    /// Keep Chat → My Teams segment badge aligned with invitee pending list (not manager-sent counts).
    @MainActor
    private func syncMyTeamsInvitationBadge() {
        chatViewModel.applyPendingFanTeamInvitationCount(store.invitations.count)
    }

    /// Deep-link highlight: fail soft when the invitation was cancelled/accepted elsewhere.
    @MainActor
    private func applyPendingInvitationHighlightIfNeeded() async {
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
        // Clear the emphasis after a short beat so the list settles.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if highlightedInvitationId == targetId {
            highlightedInvitationId = nil
        }
    }

    @ViewBuilder
    private func myTeamsFeedRow(_ item: ChatMyTeamsListItem) -> some View {
        switch item {
        case .team(let team):
            Button {
                selectedTeam = team
            } label: {
                MyTeamCardView(
                    team: team,
                    languageCode: languageCode,
                    displayRefreshToken: teamMarkRefreshTokens[team.id]
                )
            }
            .buttonStyle(FGPremiumPressButtonStyle())
        case .nativeAd(let slot):
            CompactNativeAdCard(
                placement: ChatMyTeamsAdPlacement.placementID,
                hostTabRaw: "chat",
                slotIndex: slot.slotIndex,
                layoutWidth: max(280, myTeamsAdLayoutWidth),
                onAdLoaded: {
#if DEBUG
                    logMyTeamsAdLifecycle(slot: slot, phase: "adLoaded")
#endif
                },
                onAdFailed: { error in
#if DEBUG
                    logMyTeamsAdLifecycle(
                        slot: slot,
                        phase: "adFailed error=\(error.localizedDescription)"
                    )
#endif
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: CompactNativeAdLayout.preferredHeight)
        }
    }

    private func updateMyTeamsAdLayoutWidth(_ width: CGFloat) {
        guard width > 0, abs(myTeamsAdLayoutWidth - width) > 0.5 else { return }
        myTeamsAdLayoutWidth = width
    }

    private func logMyTeamsAdPlacementIfNeeded() {
#if DEBUG
        guard AdDiagnostics.enabled else { return }
        guard ChatMyTeamsAdPlacement.shouldLogDiagnostics(for: filteredTeams) else { return }
        let teamCount = filteredTeams.count
        let positions = ChatMyTeamsAdPlacement.insertionPositions(for: teamCount)
        let rendered = positions.map(String.init).joined(separator: ",")
        print("[NativeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) teamCount=\(teamCount)")
        print("[NativeAdDebug] placement=\(ChatMyTeamsAdPlacement.placementID) insertionIndexes=[\(rendered)]")
        print("[ChatMyTeamsAdDebug] teamCount=\(teamCount)")
        print("[ChatMyTeamsAdDebug] insertionIndexes=[\(rendered)]")
        print("[ChatMyTeamsAdDebug] adsInsertedCount=\(positions.count)")
        print("[ChatMyTeamsAdDebug] policyInsert=\(FanGeoAdPolicy.shouldInsertAdsInFeeds())")
        if let reason = ChatMyTeamsAdPlacement.skippedReason(teamCount: teamCount) {
            print("[ChatMyTeamsAdDebug] skippedReason=\(reason)")
        }
#endif
    }

#if DEBUG
    private func logMyTeamsAdLifecycle(slot: ChatMyTeamsNativeAdSlot, phase: String) {
        guard AdDiagnostics.enabled else { return }
        print(
            "[ChatMyTeamsAdDebug] \(phase) slot=\(slot.slotIndex) afterTeam=\(slot.insertedAfterTeamPosition)"
        )
    }
#endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("fan_teams_title", languageCode: languageCode))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer()
                Button {
                    showingCreate = true
                } label: {
                    Label(L10n.t("fan_teams_create", languageCode: languageCode), systemImage: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(FGColor.accentGreen, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("fan_teams_create", languageCode: languageCode))
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                TextField(L10n.t("fan_teams_search_placeholder", languageCode: languageCode), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.7 : 0.95))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.5), lineWidth: 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.t("fan_teams_empty_title", languageCode: languageCode), systemImage: "person.3.fill")
        } description: {
            Text(L10n.t("fan_teams_empty_body", languageCode: languageCode))
        } actions: {
            Button(L10n.t("fan_teams_create", languageCode: languageCode)) {
                showingCreate = true
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentGreen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Classifies My Teams load/mutation failures for UI presentation.
/// Cancellation is control flow — never user-facing.
enum FanTeamsLoadErrorPresentation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return message == "cancelled"
            || message == "canceled"
            || message.contains("cancellationerror")
            || message.contains("task was cancelled")
            || message.contains("task was canceled")
    }

    /// `nil` when the error must not be shown (cancellation).
    static func userFacingMessage(for error: Error, languageCode: String? = nil) -> String? {
        if isCancellation(error) { return nil }
        return L10n.t("fan_teams_refresh_failed", languageCode: languageCode)
    }
}

@MainActor
final class MyTeamsStore: ObservableObject {
    @Published var teams: [FanTeamSummary] = []
    @Published var invitations: [FanTeamInvitation] = []
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var busyInvitationIds: Set<UUID> = []

    private let service = FanTeamsService()
    /// Owns loading-spinner / result application across overlapping refreshes.
    private var refreshGeneration = 0

    func refresh(source: String = "unspecified") async {
        refreshGeneration += 1
        let generation = refreshGeneration
        // Full-screen spinner only when we have nothing to show yet.
        let showBlockingSpinner = teams.isEmpty && invitations.isEmpty
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
            teams = nextTeams
            invitations = nextInvitations
            errorText = nil
            FanTeamIdentityRealtimeCoordinator.shared.publishDiffs(previous: previous, next: nextTeams)
#if DEBUG
            print("[FanTeamsLoad] operation=refresh success source=\(source) generation=\(generation) teams=\(nextTeams.count)")
#endif
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) {
#if DEBUG
                print("[FanTeamsLoad] operation=refresh cancelled source=\(source) generation=\(generation)")
#endif
                return
            }
            guard generation == refreshGeneration else { return }
#if DEBUG
            print("[FanTeamsLoad] operation=refresh failed source=\(source) generation=\(generation) error=\(error)")
#endif
            errorText = FanTeamsLoadErrorPresentation.userFacingMessage(for: error)
        }
    }

    func refreshInvitations(source: String = "unspecified") async {
        do {
            invitations = try await service.listMyPendingInvitations()
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
    }

    func declineInvitation(_ invitation: FanTeamInvitation) async throws {
        guard !busyInvitationIds.contains(invitation.id) else { return }
        busyInvitationIds.insert(invitation.id)
        defer { busyInvitationIds.remove(invitation.id) }
        try await service.declineInvitation(invitationId: invitation.invitationId)
        invitations.removeAll { $0.id == invitation.id }
    }

    func applyIdentityChange(_ change: FanTeamIdentityChange) {
        guard let idx = teams.firstIndex(where: { $0.id == change.teamId }) else { return }
        teams[idx] = teams[idx].applying(change)
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

struct MyTeamCardView: View {
    let team: FanTeamSummary
    let languageCode: String
    var displayRefreshToken: UUID? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            FanTeamMarkView(
                sport: team.sport,
                logoURL: team.logoURL,
                logoThumbnailURL: team.logoThumbnailURL,
                colorHex: team.colorHex,
                size: 48,
                preferDetailURL: false,
                displayRefreshToken: displayRefreshToken
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(team.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(metaLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
                if let next = nextGameLine {
                    Text(next)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentGreen)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .fanTeamIdentityCardChrome(colorHex: team.colorHex, colorScheme: colorScheme)
        .softCardShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var metaLine: String {
        FanTeamMetaLine.compose(
            competitionLevel: team.competitionLevel,
            sport: team.sport,
            memberCount: team.memberCount,
            languageCode: languageCode
        )
    }

    private var pendingLine: String? {
        FanTeamPendingInvitationCopy.line(
            count: team.pendingInvitationCount,
            canManage: team.canManage,
            languageCode: languageCode
        )
    }

    private var nextGameLine: String? {
        guard let date = team.nextGameStartsAt else { return nil }
        let when = FanTeamDateFormatting.gameWhen(date, languageCode: languageCode)
        return String(
            format: L10n.t("fan_teams_next_game_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            when
        )
    }

    private var accessibilityLabel: String {
        var parts = [team.name, metaLine]
        if let pendingLine { parts.append(pendingLine) }
        if let nextGameLine { parts.append(nextGameLine) }
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
                displayRefreshToken: refreshToken
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
    var onOpenChat: (FanTeamChatContext) -> Void
    var onTeamsChanged: () -> Void
    var onTeamDeleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var detail: FanTeamDetail?
    @State private var selectedTab: FanTeamDetailTab = .overview
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var pickupCreateFormMode: PickupGameFormMode?
    @State private var pickupDetailNav: PickupDetailNavigationToken?
    @State private var showingAddMembers = false
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
    @State private var memberPendingPlayerNumberEdit: FanTeamMember?
    @State private var isMessagingMember = false
    @State private var isRemovingMember = false
    @State private var isSavingPlayerNumber = false
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
        NavigationStack {
            teamDetailChromeAndLifecycle
                .sheet(item: $pickupCreateFormMode) { mode in
                    NavigationStack {
                        SettingsPickupGameFormView(
                            viewModel: mapViewModel,
                            mode: mode,
                            creationContext: .team(PickupGameTeamCreationContext(from: team)),
                            onCreated: { _ in }
                        ) {
                            pickupCreateFormMode = nil
                            onTeamsChanged()
                            Task { await reload() }
                        }
                    }
                }
                .sheet(item: $pickupDetailNav, onDismiss: {
                    Task { await reload() }
                }) { token in
                    DiscoverPickupGameDetailSheet(viewModel: mapViewModel, gameId: token.id)
                        .environmentObject(chatViewModel)
                }
                .sheet(isPresented: $showingAddMembers) {
                    AddFanTeamMembersSheet(teamId: team.id, chatViewModel: chatViewModel) {
                        onTeamsChanged()
                        Task { await reload() }
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
                    String(
                        format: L10n.t("fan_teams_leave_confirm_title_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        team.name
                    ),
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
                    String(
                        format: L10n.t("fan_teams_delete_confirm_title_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        team.name
                    ),
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
                    memberPendingRemoval.map { member in
                        String(
                            format: L10n.t("fan_teams_remove_member_confirm_title_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            member.displayName,
                            team.name
                        )
                    } ?? L10n.t("fan_teams_remove_member", languageCode: languageCode),
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

    private var teamDetailChromeAndLifecycle: some View {
        teamDetailPrimaryColumn
            .background(colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                teamDetailLeadingToolbar
                teamDetailTrailingToolbar
            }
            .onPreferenceChange(ChatComposerFocusPreferenceKey.self, perform: handleEmbeddedComposerFocusPreference)
            .onChange(of: selectedTab) { oldTab, newTab in
                handleSelectedTabChange(oldTab, newTab)
            }
            .onAppear {
                TeamChatKeyboardDebug.log(
                    "teamDetail.appear",
                    detail: "tab=\(selectedTab.rawValue)"
                )
            }
            .onDisappear {
                TeamChatKeyboardDebug.log("teamDetail.disappear")
            }
            .task { await reload() }
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
        switch selectedTab {
        case .chat:
            teamChatKeyboardHostColumn
        case .overview, .games, .roster:
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

    private var teamNonChatColumn: some View {
        VStack(spacing: 0) {
            teamHeader
            tabPicker
            Group {
                switch selectedTab {
                case .overview:
                    overviewTab
                case .games:
                    gamesTab
                case .roster:
                    rosterTab
                case .chat:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Do not label this "Done" — iOS may mirror nav items into the keyboard bar.
            .accessibilityLabel(L10n.t("Close", languageCode: languageCode))
        }
    }

    @ToolbarContentBuilder
    private var teamDetailTrailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(L10n.t("fan_teams_open_chat", languageCode: languageCode)) {
                    onOpenChat(chatContext)
                }
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
                if team.canManage {
                    Button(L10n.t("fan_teams_invite_members", languageCode: languageCode)) {
                        showingAddMembers = true
                    }
                    Button(L10n.t("fan_teams_schedule_game", languageCode: languageCode)) {
                        openScheduleGame()
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
    }

    private var teamHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            FanTeamMarkView(
                sport: team.sport,
                logoURL: team.logoURL,
                logoThumbnailURL: team.logoThumbnailURL,
                colorHex: team.colorHex,
                size: 56,
                preferDetailURL: true,
                displayRefreshToken: markRefreshToken
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(team.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(headerMetaLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    if FanTeamPrivacyPresentation.showsPrivateTeamBadge(for: team) {
                        Text(L10n.t("fan_teams_private_team", languageCode: languageCode))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(teamAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                teamAccent.opacity(colorScheme == .dark ? 0.22 : 0.14),
                                in: Capsule()
                            )
                            .accessibilityAddTraits(.isStaticText)
                    }
                    if let roleBadgeText {
                        Text(roleBadgeText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.10),
                                in: Capsule()
                            )
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
            Spacer(minLength: 8)
            if team.canManage {
                Button {
                    showingAddMembers = true
                } label: {
                    Label(L10n.t("fan_teams_invite", languageCode: languageCode), systemImage: "person.badge.plus")
                        .font(.caption.weight(.bold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(FGColor.accentGreen, in: Capsule())
                }
                .buttonStyle(FGPremiumPressButtonStyle())
                .accessibilityLabel(L10n.t("fan_teams_invite", languageCode: languageCode))
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
        .accessibilityElement(children: .combine)
    }

    private var roleBadgeText: String? {
        switch team.myRole {
        case .owner, .manager, .captain:
            return L10n.t(team.myRole.localizedKey, languageCode: languageCode)
        case .member:
            return nil
        }
    }

    private var headerMetaLine: String {
        let base = FanTeamMetaLine.compose(
            competitionLevel: team.competitionLevel,
            sport: team.sport,
            memberCount: team.memberCount,
            languageCode: languageCode
        )
        let pendingCount = max(team.pendingInvitationCount, pendingInvitations.count)
        if team.canManage, pendingCount > 0 {
            let pending = String(
                format: L10n.t("fan_teams_pending_count_compact_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                pendingCount
            )
            return "\(base) · \(pending)"
        }
        return base
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(FanTeamDetailTab.allCases) { tab in
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
                            Text(L10n.t(tab.titleKey, languageCode: languageCode))
                                .font(.caption.weight(isSelected ? .bold : .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(isSelected ? teamAccent : FGColor.secondaryText(colorScheme))
                        .frame(maxWidth: .infinity)
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
    }

    @ViewBuilder
    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                teamInfoCard

                // Shared `detail.members` from `loadDetail` — no extra leadership fetch.
                if detail != nil {
                    teamLeadershipCard
                }
            }
            .padding(.vertical, 14)
        }
        .refreshable {
            await reload()
        }
    }

    private var overviewLeadershipMembers: [FanTeamMember] {
        FanTeamLeadership.leaders(from: detail?.members ?? [])
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
                    SocialAvatarRenderer.socialAvatarView(for: member.preview, size: 42)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(FGColor.cardBackground(colorScheme)))
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                        }

                    if member.role == .owner {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3.5)
                            .background(Circle().fill(teamAccent))
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        FGColor.cardBackground(colorScheme),
                                        lineWidth: 1.5
                                    )
                            }
                            .offset(x: 2, y: 2)
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(L10n.t(member.role.localizedKey, languageCode: languageCode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(teamAccent)
                        .lineLimit(1)
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

    private var teamInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                value: String(
                    format: L10n.t("fan_teams_members_count_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    team.memberCount
                )
            )
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
                if team.canManage {
                    Button {
                        openScheduleGame()
                    } label: {
                        Label(L10n.t("fan_teams_schedule_game", languageCode: languageCode), systemImage: "plus")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentGreen)
                    .padding(.horizontal, 16)
                }

                if !allGames.isEmpty {
                    gamesFilterChrome
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
                        title: L10n.t("fan_teams_no_games_title", languageCode: languageCode),
                        body: L10n.t("fan_teams_no_games_body", languageCode: languageCode)
                    )
                } else if presentation.filteredCount == 0 {
                    gamesStatusOrFilteredEmptyCard
                } else {
                    ForEach(presentation.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.t(section.kind.localizedKey, languageCode: languageCode).uppercased(with: Locale(identifier: languageCode)))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .padding(.horizontal, 16)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.games) { game in
                                Button {
                                    openPickupGameDetail(game.id)
                                } label: {
                                    gameListRow(game)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 14)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: gamesFilter)
        }
        .onReceive(gamesFilterMinuteTicker) { gamesFilterClockTick = $0 }
        .sheet(isPresented: $showGamesCustomDateSheet) {
            gamesCustomDateSheet
        }
    }

    private var gamesFilterAccent: Color {
        if let hex = team.colorHex, let c = Color(fanTeamHex: hex) { return c }
        return FGColor.accentGreen
    }

    /// Primary Upcoming/Past segment + compact Sort / Filter (no type chips).
    private var gamesFilterChrome: some View {
        HStack(alignment: .center, spacing: 8) {
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
            .frame(maxWidth: .infinity)

            gamesSortMenu
            gamesSecondaryFilterMenu
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
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
            Section(L10n.t("fan_teams_games_type_section", languageCode: languageCode)) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        gamesFilter.gameType = nil
                    }
                } label: {
                    if gamesFilter.gameType == nil {
                        Label(L10n.t("fan_teams_games_type_all", languageCode: languageCode), systemImage: "checkmark")
                    } else {
                        Text(L10n.t("fan_teams_games_type_all", languageCode: languageCode))
                    }
                }
                ForEach(FanTeamGamesFilterEngine.supportedTypeFilters, id: \.self) { type in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            gamesFilter.gameType = gamesFilter.gameType == type ? nil : type
                        }
                    } label: {
                        if gamesFilter.gameType == type {
                            Label(L10n.t(type.localizedKey, languageCode: languageCode), systemImage: "checkmark")
                        } else {
                            Text(L10n.t(type.localizedKey, languageCode: languageCode))
                        }
                    }
                }
            }

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
                Image(systemName: gamesFilter.hasActiveSecondaryFilters
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
                title: L10n.t("fan_teams_games_no_upcoming_title", languageCode: languageCode),
                body: L10n.t("fan_teams_games_no_upcoming_body", languageCode: languageCode)
            )
        } else {
            emptyCard(
                title: L10n.t("fan_teams_games_no_past_title", languageCode: languageCode),
                body: L10n.t("fan_teams_games_no_past_body", languageCode: languageCode)
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
                ForEach(detail?.members ?? []) { member in
                    rosterMemberRow(member)
                }
            } header: {
                Text(rosterActiveMembersHeader)
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $memberPendingPlayerNumberEdit) { member in
            FanTeamPlayerNumberEditorSheet(
                memberName: member.displayName,
                initialNumber: member.playerNumber,
                teamAccent: teamAccent,
                languageCode: languageCode,
                isSaving: isSavingPlayerNumber,
                onSave: { number in
                    Task { await saveMemberPlayerNumber(member, number: number) }
                },
                onClear: {
                    Task { await clearMemberPlayerNumber(member) }
                },
                onCancel: {
                    memberPendingPlayerNumberEdit = nil
                }
            )
        }
    }

    private func rosterMemberRow(_ member: FanTeamMember) -> some View {
        let avatarSize = FanTeamRosterRowPresentation.avatarSize
        let leadingWidth = FanTeamRosterRowPresentation.leadingColumnWidth

        return HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 5) {
                    if let number = member.playerNumber {
                        Text(FanTeamPlayerNumber.displayLabel(number))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(teamAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                teamAccent.opacity(colorScheme == .dark ? 0.22 : 0.12),
                                in: Capsule(style: .continuous)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    ProfileAvatarView(preview: member.preview, size: avatarSize)
                }
                .frame(width: leadingWidth, alignment: .center)

                VStack(alignment: .leading, spacing: 4) {
                    rosterIdentityLine(member)

                    Text(rosterRoleGenderLine(member))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentGreen)
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
                            systemImage: "message"
                        )
                    }
                    .disabled(isMessagingMember)
                }

                if team.canManage {
                    Divider()
                    Button {
                        memberPendingPlayerNumberEdit = member
                    } label: {
                        Label(
                            L10n.t(
                                member.playerNumber == nil
                                    ? "fan_teams_set_player_number"
                                    : "fan_teams_change_player_number",
                                languageCode: languageCode
                            ),
                            systemImage: "number"
                        )
                    }
                    .disabled(isSavingPlayerNumber)
                    if member.playerNumber != nil {
                        Button(role: .destructive) {
                            Task { await clearMemberPlayerNumber(member) }
                        } label: {
                            Label(
                                L10n.t(
                                    "fan_teams_remove_player_number",
                                    languageCode: languageCode
                                ),
                                systemImage: "minus.circle"
                            )
                        }
                        .disabled(isSavingPlayerNumber)
                    }
                }

                if team.canManage,
                   member.role != .owner,
                   !FanTeamRosterMemberActions.isSelf(
                       member: member,
                       currentUserId: mapViewModel.currentUserAuthId
                   ) {
                    if team.myRole == .owner {
                        Divider()
                        ForEach([FanTeamMemberRole.manager, .captain, .member], id: \.self) { role in
                            Button {
                                guard member.role != role else { return }
                                Task {
                                    do {
                                        try await service.setMemberRole(
                                            teamId: team.id,
                                            userId: member.userId,
                                            role: role
                                        )
                                        await reload()
                                    } catch {
                                        if !FanTeamsLoadErrorPresentation.isCancellation(error) {
                                            errorText = L10n.t(
                                                "fan_teams_set_role_failed",
                                                languageCode: languageCode
                                            )
                                        }
                                    }
                                }
                            } label: {
                                if member.role == role {
                                    Label(
                                        L10n.t(role.localizedKey, languageCode: languageCode),
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text(L10n.t(role.localizedKey, languageCode: languageCode))
                                }
                            }
                        }
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
                                systemImage: "person.fill.xmark"
                            )
                        }
                        .disabled(isRemovingMember)
                    }
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
            try await service.setMemberPlayerNumber(
                teamId: team.id,
                userId: member.userId,
                playerNumber: number
            )
            if var detail {
                detail.members = detail.members.map { row in
                    row.userId == member.userId ? row.replacingPlayerNumber(number) : row
                }
                self.detail = detail
            }
            memberPendingPlayerNumberEdit = nil
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

    private var rosterActiveMembersHeader: String {
        let members = String(
            format: L10n.t("fan_teams_members_count_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            team.memberCount
        )
        let pendingCount = max(team.pendingInvitationCount, pendingInvitations.count)
        if team.canManage, pendingCount > 0 {
            let pending = String(
                format: L10n.t("fan_teams_pending_count_compact_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                pendingCount
            )
            return "\(members) · \(pending)"
        }
        return members
    }

    private func openScheduleGame() {
        guard team.canManage else { return }
        pickupCreateFormMode = .add
    }

    private func openPickupGameDetail(_ pickupGameId: UUID) {
        pickupDetailNav = PickupDetailNavigationToken(id: pickupGameId)
    }

    private func gameListRow(_ game: FanTeamGame) -> some View {
        FanTeamGameRichCard(
            game: game,
            teamName: team.name,
            teamSport: team.sport,
            teamColorHex: team.colorHex,
            languageCode: languageCode,
            mapViewModel: mapViewModel,
            headline: opponentHeadline(for: game)
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

    private func opponentHeadline(for game: FanTeamGame) -> String {
        let home = team.name
        if game.gameType == .practice {
            return "\(home) · \(L10n.t("fan_team_game_type_practice", languageCode: languageCode))"
        }
        if let opp = game.opponentName?.trimmingCharacters(in: .whitespacesAndNewlines), !opp.isEmpty {
            return "\(home) vs \(opp)"
        }
        if game.opponentTeamId != nil {
            return "\(home) vs \(L10n.t("fan_teams_opponent_team", languageCode: languageCode))"
        }
        return home
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await service.loadDetail(for: team)
            detail = loaded
            if loaded.summary.canManage {
                pendingInvitations = (try? await service.listPendingInvitations(teamId: loaded.summary.id)) ?? []
            } else {
                pendingInvitations = []
            }
            errorText = nil
        } catch {
            if let message = FanTeamsLoadErrorPresentation.userFacingMessage(for: error) {
                errorText = message
            }
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
        if FanTeamLeadership.usesOwnPublicProfilePreview(
            memberUserId: member.userId,
            currentUserId: mapViewModel.currentUserAuthId
        ) {
            mapViewModel.presentOwnPublicProfilePreview()
            return
        }
        mapViewModel.presentPublicProfile(
            userId: member.userId,
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
        guard FanTeamRosterMemberActions.canMessage(
            member: member,
            currentUserId: mapViewModel.currentUserAuthId
        ) else { return }
        guard !isMessagingMember else { return }

        if chatViewModel.isEitherDirectionBlocked(with: member.userId) {
            errorText = L10n.t("fan_teams_message_blocked", languageCode: languageCode)
            return
        }

        isMessagingMember = true
        defer { isMessagingMember = false }
        do {
            let conversationId = try await chatViewModel.startDirectConversationWithFriend(
                friendUserId: member.userId
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
            try await service.removeMember(teamId: team.id, userId: member.userId)
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

enum FanTeamDetailTab: String, CaseIterable, Identifiable {
    case overview, chat, games, roster
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .overview: return "fan_teams_tab_overview"
        case .chat: return "fan_teams_tab_chat"
        case .games: return "fan_teams_tab_games"
        case .roster: return "fan_teams_tab_roster"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "info.circle.fill"
        case .chat: return "bubble.left.and.bubble.right"
        case .games: return "sportscourt"
        case .roster: return "person.2"
        }
    }
}

/// Compact owner/manager editor for Team-specific jersey numbers (0–99 / clear).
private struct FanTeamPlayerNumberEditorSheet: View {
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
                            Text(L10n.t("fan_teams_remove_player_number", languageCode: languageCode))
                        }
                        .disabled(isSaving)
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

    static func gameWhen(_ date: Date, languageCode: String) -> String {
        dayTime.locale = Locale(identifier: languageCode)
        return dayTime.string(from: date)
    }

    static func shortDay(_ date: Date, languageCode: String) -> String {
        short.locale = Locale(identifier: languageCode)
        return short.string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Richer Team Games card — still one pickup_games row + existing roster social proof.
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

    @Environment(\.colorScheme) private var colorScheme

    private var sportToken: String {
        let s = game.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? teamSport : s
    }

    private var accent: Color {
        if let teamColorHex, let c = Color(fanTeamHex: teamColorHex) { return c }
        return SportFilterCatalog.resolve(sportToken).accent
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SportArtworkIconView(sport: sportToken, diameter: 42)
                    .overlay {
                        Circle()
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1.5)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: game.gameType.filterSystemImage)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accent)
                        Text(L10n.t(game.gameType.localizedKey, languageCode: languageCode))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accent)
                        if mapViewModel.resolvedPickupGameRow(for: game.id)?.is_visible == false {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .accessibilityLabel(
                                    L10n.t("pickup_form_visibility_private", languageCode: languageCode)
                                )
                        }
                    }
                    Text(emphasizeTitle ? headline : game.displayTitle)
                        .font(emphasizeTitle ? .title3.weight(.bold) : .subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    if !emphasizeTitle, headline != game.displayTitle {
                        Text(headline)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                    if let level = game.competitionLevel
                        ?? mapViewModel.resolvedPickupGameRow(for: game.id)?.competitionLevel {
                        Text(level.displayTitle(languageCode: languageCode))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                    Text(FanTeamDateFormatting.gameWhen(game.startsAt, languageCode: languageCode))
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    if !game.locationLine.isEmpty {
                        Text(game.locationLine)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            if let roster, !roster.stackMembers.isEmpty {
                HStack(spacing: 10) {
                    PickupPlayingAvatarStack(members: roster.stackMembers, diameter: 22)
                    Text(socialProofLine)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(showsCardChrome ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsCardChrome {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
        }
        .overlay {
            if showsCardChrome {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accent.opacity(0.28), lineWidth: 1)
            }
        }
        .task(id: game.id) {
            await mapViewModel.loadPickupGameRoster(pickupGameId: game.id)
        }
    }

    private var socialProofLine: String {
        var parts: [String] = []
        if goingCount > 0 {
            parts.append("\(goingCount) \(L10n.t("Going", languageCode: languageCode))")
        }
        if pendingCount > 0 {
            parts.append("\(pendingCount) \(L10n.t("Maybe", languageCode: languageCode))")
        }
        // Do not treat full roster as Playing — only RSVP-backed Going / Maybe.
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
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
        return "#22C25A"
        #endif
    }
}

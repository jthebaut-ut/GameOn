import SwiftUI
import Combine
import CoreLocation
import MapKit

enum PickupGameFormMode: Identifiable, Equatable {
    case add
    /// Team Schedule → Make Announcement (dedicated create path; `game_format = announcement`).
    case addTeamAnnouncement
    case edit(PickupGameRow)

    var id: String {
        switch self {
        case .add: return "pickup-form-add"
        case .addTeamAnnouncement: return "pickup-form-add-team-announcement"
        case .edit(let row): return "pickup-form-\(row.id.uuidString)"
        }
    }

    var isCreate: Bool {
        switch self {
        case .add, .addTeamAnnouncement: return true
        case .edit: return false
        }
    }

    var forcesTeamAnnouncement: Bool {
        if case .addTeamAnnouncement = self { return true }
        return false
    }
}

/// Settings → list of the signed-in fan’s pickup games (nested sheet for add / edit).
struct SettingsPickupGamesListSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var formMode: PickupGameFormMode?
    @State private var deleteTarget: PickupGameRow?
    @State private var banner: String?
    @State private var organizerRequestsGame: PickupGameRow?
    /// Drives local countdown label refresh every minute without refetching Supabase.
    @State private var listClockTick: Date = Date()
    /// At most one delayed refresh per sheet visit when any row passes its cleanup deadline.
    @State private var didScheduleExpiryListRefresh = false

    private let listMinuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if viewModel.myPickupGamesForSettings.isEmpty, viewModel.myRemovedPickupGamesForSettings.isEmpty {
                SettingsPickupGamesEmptyStateCard(colorScheme: colorScheme) {
                    formMode = .add
                }
                .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 28, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                if !viewModel.myPickupGamesForSettings.isEmpty {
                    Section {
                        ForEach(viewModel.myPickupGamesForSettings) { row in
                            let pendingHere = viewModel.organizerPendingPickupJoinRequests(for: row.id)
                            SettingsPickupMyGameListCard(
                                viewModel: viewModel,
                                row: row,
                                pendingJoinCount: pendingHere,
                                withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
                                now: listClockTick,
                                colorScheme: colorScheme,
                                onEdit: {
                                    viewModel.logPickupGamesEditRequested(id: row.id)
                                    formMode = .edit(row)
                                },
                                onDelete: { deleteTarget = row },
                                onManageRequests: { organizerRequestsGame = row }
                            )
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }

                if !viewModel.myRemovedPickupGamesForSettings.isEmpty {
                    Section {
                        ForEach(viewModel.myRemovedPickupGamesForSettings) { row in
                            SettingsPickupRemovedHistoryCard(
                                viewModel: viewModel,
                                row: row,
                                withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
                                now: listClockTick,
                                colorScheme: colorScheme,
                                useCompactCopy: horizontalSizeClass == .compact
                            )
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("History")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle("My pickup games")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    formMode = .add
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Create Game")
            }
        }
        .task {
            await viewModel.loadMyPickupGamesForSettings()
            if let uid = viewModel.currentUserAuthId {
                await viewModel.refreshPickupCreatorPublicRatingStats(creatorUserIds: [uid])
            }
        }
        .onAppear {
            listClockTick = Date()
            didScheduleExpiryListRefresh = false
            scheduleOneShotListRefreshIfAnyRowPastCleanup(now: Date())
            if !viewModel.canFanUsePickupGamesUI {
                dismiss()
            }
        }
        .onReceive(listMinuteTicker) { date in
            listClockTick = date
            scheduleOneShotListRefreshIfAnyRowPastCleanup(now: date)
        }
        .sheet(item: $formMode) { mode in
            NavigationStack {
                SettingsPickupGameFormView(viewModel: viewModel, mode: mode) {
                    formMode = nil
                    Task { await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "settingsFormDismiss") }
                }
            }
        }
        .sheet(item: $organizerRequestsGame, onDismiss: {
            Task { await viewModel.loadMyPickupGamesForSettings() }
        }) { game in
            PickupOrganizerRequestsSheet(viewModel: viewModel, game: game)
                .environmentObject(viewModel)
        }
        .alert("Cancel this pickup game?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Keep game", role: .cancel) { deleteTarget = nil }
            Button("Cancel game", role: .destructive) {
                guard let row = deleteTarget else { return }
                deleteTarget = nil
                Task { await performDelete(row) }
            }
        } message: {
            Text("Players who requested or joined will be notified.")
        }
        .overlay(alignment: .bottom) {
            if let banner, !banner.isEmpty {
                Text(banner)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding()
            }
        }
    }

    private func scheduleOneShotListRefreshIfAnyRowPastCleanup(now: Date) {
        guard !didScheduleExpiryListRefresh else { return }
        let rows = viewModel.myPickupGamesForSettings + viewModel.myRemovedPickupGamesForSettings
        let anyPast = rows.contains { row in
            guard let deadline = row.pickupHistoryClientCleanupDeadline() else { return false }
            return now >= deadline
        }
        guard anyPast else { return }
        didScheduleExpiryListRefresh = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "settingsPostCleanupDeadline")
        }
    }

    private func performDelete(_ row: PickupGameRow) async {
        do {
            try await viewModel.deletePickupGame(id: row.id)
            banner = nil
            await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "settingsDeleteSuccess")
            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
        } catch {
            banner = error.localizedDescription
        }
    }
}

// MARK: - My pickup games list (Settings) — card UI only

private struct SettingsPickupGamesEmptyStateCard: View {
    let colorScheme: ColorScheme
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 44, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FGColor.accentBlue.opacity(0.85))

            Text("No pickup games yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)

            Text("Create one and invite nearby players.")
                .font(FGTypography.body)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onAdd) {
                Text("Create Game")
                    .font(FGTypography.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentBlue)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.08), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }
}

enum SettingsPickupMyGameListCardDisplayStyle: Equatable {
    case settingsFull
    /// Going → Hosting list cards.
    case followingCompact
    /// Going → Hosting pickup detail sheet (organizer).
    case hostingDetail
}

struct GameFormatBadgeView: View {
    let format: GameType
    let colorScheme: ColorScheme
    /// Optional accent for Team-linked surfaces. Nil keeps the classic green format badge.
    var accent: Color? = nil

    private var tint: Color { accent ?? FGColor.accentGreen }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: format.systemImage)
                .font(.caption2.weight(.semibold))
            Text(format.badgeTitle)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.35 : 0.22), lineWidth: 1)
        )
        .accessibilityLabel("Game format: \(format.displayTitle)")
    }
}

/// Subtle Public / Private chip for Pickup detail (and similar surfaces).
struct PickupGameVisibilityBadge: View {
    let isVisible: Bool
    let languageCode: String
    let colorScheme: ColorScheme

    private var title: String {
        isVisible
            ? L10n.t("pickup_form_visibility_public", languageCode: languageCode)
            : L10n.t("pickup_form_visibility_private", languageCode: languageCode)
    }

    private var symbol: String {
        isVisible ? "globe" : "lock.fill"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(FGColor.secondaryText(colorScheme))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.14 : 0.08),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(L10n.t("pickup_form_visibility", languageCode: languageCode)), \(title)"
        )
    }
}

private enum SettingsPickupGameListCardStatus: Equatable {
    case open
    case full
    case pendingRequests
    case clearingSoon
    case expiredClearing

    func pillTitle(languageCode: String) -> String {
        switch self {
        case .open: return L10n.t("pickup_status_open", languageCode: languageCode)
        case .full: return L10n.t("pickup_status_full", languageCode: languageCode)
        case .pendingRequests: return L10n.t("pickup_status_pending_requests", languageCode: languageCode)
        case .clearingSoon: return L10n.t("pickup_status_clearing_soon", languageCode: languageCode)
        case .expiredClearing: return L10n.t("pickup_status_expired", languageCode: languageCode)
        }
    }

    func pillForeground(colorScheme: ColorScheme) -> Color {
        switch self {
        case .open:
            return FGColor.secondaryText(colorScheme)
        case .full:
            return FGColor.accentYellow
        case .pendingRequests:
            return Color.orange
        case .clearingSoon:
            return Color.orange
        case .expiredClearing:
            return FGColor.dangerRed
        }
    }

    func pillBackground(colorScheme: ColorScheme) -> Color {
        switch self {
        case .open:
            return Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06)
        case .full:
            return FGColor.accentYellow.opacity(colorScheme == .dark ? 0.22 : 0.14)
        case .pendingRequests:
            return Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.14)
        case .clearingSoon:
            return Color.orange.opacity(colorScheme == .dark ? 0.2 : 0.12)
        case .expiredClearing:
            return FGColor.dangerRed.opacity(colorScheme == .dark ? 0.22 : 0.12)
        }
    }
}

// MARK: - Organizer pickup roster (Settings → My pickup games / Going Hosting)

/// Compact named participant rows for approved joiners already loaded on the host card.
/// Status comes from `pickup_game_requests.status == approved` (not inferred from avatars).
private struct PickupOrganizerParticipantSummaryView: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow
    let colorScheme: ColorScheme
    let approvedUserIds: [UUID]
    var pendingJoinCount: Int = 0
    var languageCode: String = L10n.defaultLanguageCode
    var onParticipantTapped: (UUID) -> Void
    var onViewAllPlayers: (() -> Void)? = nil
    /// When false, omit the per-row Approved badge (e.g. Going → Hosting shows it in the card header).
    var showsParticipantStatusBadge: Bool = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var avatarDiameter: CGFloat = 34

    private let maxVisibleRows = 3

    private var organizerStatsApproved: Int {
        viewModel.pickupOrganizerJoinStatsByGameId[game.id]?.approved ?? 0
    }

    private var totalApproved: Int {
        max(approvedUserIds.count, game.approvedJoinCount, organizerStatsApproved)
    }

    private var visibleUserIds: [UUID] {
        Array(approvedUserIds.prefix(maxVisibleRows))
    }

    private var showsViewAll: Bool {
        approvedUserIds.count > maxVisibleRows
    }

    private var stackStatusUnderName: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if totalApproved > 0, approvedUserIds.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.85)
                    Text(L10n.t("pickup_host_participants_loading", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            } else if approvedUserIds.isEmpty {
                // Pending waiters already have a dedicated callout on the card — avoid duplicate empty copy.
                if pendingJoinCount == 0 {
                    Text(L10n.t("pickup_host_no_players_joined", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(visibleUserIds, id: \.self) { userId in
                    participantRow(for: userId)
                }
                if showsViewAll, let onViewAllPlayers {
                    Button(action: onViewAllPlayers) {
                        Text(
                            String(
                                format: L10n.t("pickup_host_view_all_players_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                totalApproved
                            )
                        )
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .onAppear { logPickupRosterUI(reason: "appear") }
        .onChange(of: approvedUserIds.count) { _, _ in logPickupRosterUI(reason: "idsCount") }
        .onChange(of: game.approved_join_count ?? -1) { _, _ in logPickupRosterUI(reason: "approvedJoinCount") }
    }

    @ViewBuilder
    private func participantRow(for userId: UUID) -> some View {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[userId]
        let profileName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = profileName.isEmpty ? L10n.t("pickup_host_participant_fallback_name", languageCode: languageCode) : profileName
        let emailLine = (profile?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let fullRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb: String? = thumbRaw.isEmpty ? nil : thumbRaw
        let full = fullRaw.isEmpty ? "" : fullRaw
        let token = viewModel.pickupJoinRequesterAvatarTokenByUserId[userId] ?? UserAvatarView.stableRefreshToken(
            userId: userId,
            thumbnailURL: thumb,
            avatarURL: full
        )
        let fallback: UserAvatarView.FallbackStyle = colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
        let statusTitle = L10n.t("pickup_host_participant_status_approved", languageCode: languageCode)
        let a11yLabel = String(
            format: L10n.t("pickup_host_participant_a11y_approved_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            displayName
        )

        Button {
            onParticipantTapped(userId)
        } label: {
            Group {
                if showsParticipantStatusBadge, stackStatusUnderName {
                    HStack(alignment: .center, spacing: 10) {
                        avatarView(
                            thumb: thumb,
                            full: full,
                            token: token,
                            displayName: displayName,
                            emailLine: emailLine,
                            fallback: fallback
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                            statusBadge(title: statusTitle)
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        avatarView(
                            thumb: thumb,
                            full: full,
                            token: token,
                            displayName: displayName,
                            emailLine: emailLine,
                            fallback: fallback
                        )
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        if showsParticipantStatusBadge {
                            statusBadge(title: statusTitle)
                                .layoutPriority(0)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
    }

    private func avatarView(
        thumb: String?,
        full: String,
        token: UUID,
        displayName: String,
        emailLine: String,
        fallback: UserAvatarView.FallbackStyle
    ) -> some View {
        UserAvatarView(
            avatarThumbnailURL: thumb,
            avatarURL: full,
            avatarDisplayRefreshToken: token,
            displayName: displayName,
            email: emailLine,
            size: avatarDiameter,
            fallbackStyle: fallback,
            imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
        )
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.35 : 0.72), lineWidth: 1.5)
        )
        .accessibilityHidden(true)
    }

    private func statusBadge(title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.2 : 0.12),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.35 : 0.22), lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private func logPickupRosterUI(reason: String) {
#if DEBUG
        print("[PickupRosterUI] gameId=\(game.id.uuidString.lowercased()) reason=\(reason)")
        print("[PickupRosterUI] approvedCount=\(totalApproved)")
        print("[PickupRosterUI] visibleNamedRows=\(visibleUserIds.count)")
#endif
    }
}

struct SettingsPickupMyGameListCard: View {
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    let row: PickupGameRow
    let pendingJoinCount: Int
    let withdrawnJoinRows: [PickupGameRequestRow]
    let now: Date
    let colorScheme: ColorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onManageRequests: () -> Void
    var displayStyle: SettingsPickupMyGameListCardDisplayStyle = .settingsFull
    var onOpenDetails: (() -> Void)? = nil
    var onInvite: (() -> Void)? = nil
    var onOpenMap: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil

    @State private var rosterActionUserId: UUID?
    @State private var showRosterPlayerActions: Bool = false

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var approvedJoinerUserIds: [UUID] {
        viewModel.pickupOrganizerApprovedJoinerUserIdsByGameId[row.id] ?? []
    }

    private var isFollowingCompact: Bool {
        displayStyle == .followingCompact
    }

    private var isHostingDetail: Bool {
        displayStyle == .hostingDetail
    }

    private var status: SettingsPickupGameListCardStatus {
        Self.computeStatus(row: row, pendingJoinCount: pendingJoinCount, now: now)
    }

    private var isExpiredClearing: Bool {
        status == .expiredClearing
    }

    private var usesExpiredArchivedStyle: Bool {
        isFollowingCompact && isExpiredClearing
    }

    private var hostingAutoClearInFlight: Bool {
        (isFollowingCompact || isHostingDetail) && viewModel.pickupHostingAutoClearInFlightIds.contains(row.id)
    }

    private var hostingAutoClearFailed: Bool {
        (isFollowingCompact || isHostingDetail) && viewModel.pickupHostingAutoClearFailedIds.contains(row.id)
    }

    /// Going Hosting: treat past-deadline as clearing until removed or failure fallback.
    private var hostingAutoClearStatusActive: Bool {
        (isFollowingCompact || isHostingDetail)
            && isExpiredClearing
            && !hostingAutoClearFailed
    }

    /// Header Approved chip for Going Hosting list + organizer detail sheet.
    private var showsHeaderApprovedBadge: Bool {
        (isFollowingCompact || isHostingDetail) && !usesExpiredArchivedStyle && displayedJoinedPlayerCount > 0
    }

    private var metaSectionSpacing: CGFloat {
        if isFollowingCompact { return 8 }
        if isHostingDetail { return 14 }
        return 10
    }

    private var cardTextOpacity: Double {
        usesExpiredArchivedStyle ? 0.62 : 1
    }

    private var cardPrimaryTextColor: Color {
        usesExpiredArchivedStyle
            ? FGColor.secondaryText(colorScheme)
            : FGColor.primaryText(colorScheme)
    }

    private var cardBackgroundStyle: AnyShapeStyle {
        if usesExpiredArchivedStyle {
            let fill = colorScheme == .dark
                ? Color.white.opacity(0.035)
                : Color(.systemGray6).opacity(0.98)
            return AnyShapeStyle(fill)
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    private var cardStrokeColor: Color {
        if usesExpiredArchivedStyle {
            return colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.055)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)
    }

    private var gameStarted: Bool {
        row.hasPickupGameStarted(now: now)
    }

    private static func computeStatus(row: PickupGameRow, pendingJoinCount: Int, now: Date) -> SettingsPickupGameListCardStatus {
        guard let deadline = SettingsPickupCleanupDisplay.cleanupDeadline(for: row) else {
            if pendingJoinCount > 0 { return .pendingRequests }
            return row.isPickupFullForDiscover ? .full : .open
        }
        if now >= deadline { return .expiredClearing }
        let remaining = deadline.timeIntervalSince(now)
        if remaining < 3600 { return .clearingSoon }
        if pendingJoinCount > 0 { return .pendingRequests }
        if row.isPickupFullForDiscover { return .full }
        return .open
    }

    private var locationLine: String? {
        let parts = [row.address, row.city, row.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    private var dateTimeLine: String? {
        row.pickupDateWithCompactTimeRange(languageCode: languageCode)
    }

    private var organizerStatsApproved: Int {
        viewModel.pickupOrganizerJoinStatsByGameId[row.id]?.approved ?? 0
    }

    private var displayedJoinedPlayerCount: Int {
        max(organizerStatsApproved, row.approvedJoinCount, approvedJoinerUserIds.count)
    }

    private var displayedOpenSlots: Int {
        max(0, row.playersNeededClamped - displayedJoinedPlayerCount)
    }

    private var displayedRosterIsFull: Bool {
        displayedJoinedPlayerCount >= row.playersNeededClamped
    }

    private var playersSummaryLine: String {
        let need = row.playersNeededClamped
        let joined = displayedJoinedPlayerCount
        let open = displayedOpenSlots
        if displayedRosterIsFull {
            return L10n.t("pickup_roster_full", languageCode: languageCode)
        }
        if joined == 0 {
            return pickupLocalizedSpotsOpen(open, languageCode: languageCode)
        }
        let base = String(
            format: L10n.t("pickup_players_joined_format", languageCode: languageCode),
            joined,
            need
        )
        if open <= 0 { return base }
        let spotPhrase = pickupLocalizedSpotsOpen(open, languageCode: languageCode)
        return "\(base) · \(spotPhrase)"
    }

    private var showsFollowingCompactHeaderShare: Bool {
        isFollowingCompact && !usesExpiredArchivedStyle && row.isEligibleForInAppShare()
    }

    private var followingCompactShareIconColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.78) : Color.secondary
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isFollowingCompact ? 16 : 24, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: isFollowingCompact ? 10 : 14) {
                PickupGameStartedSportGlyphFrame(showStarted: gameStarted && !usesExpiredArchivedStyle) {
                    SportArtworkIconView(sport: row.sport, diameter: isFollowingCompact ? 44 : 50)
                }
                .saturation(usesExpiredArchivedStyle ? 0 : 1)
                .opacity(usesExpiredArchivedStyle ? 0.48 : 1)

                VStack(alignment: .leading, spacing: isFollowingCompact ? 4 : 6) {
                    Text(row.title)
                        .font(isFollowingCompact ? .headline.weight(.bold) : .title3.weight(.bold))
                        .foregroundStyle(cardPrimaryTextColor)
                        .lineLimit(isFollowingCompact ? 2 : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(cardTextOpacity)
                        .contentShape(Rectangle())
                        .onTapGesture { handleCardMapTap() }

                    HStack(alignment: .center, spacing: 7) {
                        GameFormatBadgeView(format: row.gameFormat, colorScheme: colorScheme)
                            .opacity(cardTextOpacity)

                        Text(status.pillTitle(languageCode: languageCode))
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .foregroundStyle(status.pillForeground(colorScheme: colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(status.pillBackground(colorScheme: colorScheme), in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel(status.pillTitle(languageCode: languageCode))

                        if showsHeaderApprovedBadge {
                            followingCompactHeaderApprovedBadge
                        }
                    }

                    if !isFollowingCompact {
                        PickupCreatorTrustLineView(stats: viewModel.pickupCreatorTrustStats(for: row.creator_user_id))
                    }

                    if pendingJoinCount > 0, !usesExpiredArchivedStyle {
                        Button(action: onManageRequests) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.clock")
                                    .font(.system(size: isFollowingCompact ? 14 : 15, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                                Text(pendingJoinCount == 1 ? "1 player waiting" : "\(pendingJoinCount) players waiting")
                                    .font(isFollowingCompact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                                    .foregroundStyle(Color.orange)
                                    .opacity(cardTextOpacity)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.orange.opacity(0.85))
                            }
                            .padding(.horizontal, isFollowingCompact ? 10 : 12)
                            .padding(.vertical, isFollowingCompact ? 6 : 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pendingJoinCount) players waiting. Tap to review.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsFollowingCompactHeaderShare {
                    followingCompactHeaderShareControl
                }
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: metaSectionSpacing) {
                if let dateTimeLine {
                    SettingsPickupCardMetaRow(
                        systemImage: "calendar",
                        title: L10n.t("pickup_form_section_when", languageCode: languageCode),
                        value: dateTimeLine
                    )
                        .opacity(cardTextOpacity)
                    if gameStarted && !usesExpiredArchivedStyle {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(FGColor.accentGreen.opacity(0.65))
                                .frame(width: 22, alignment: .center)
                            PickupGameStartedLineCaption()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let locationLine {
                    SettingsPickupCardMetaRow(
                        systemImage: "mappin.and.ellipse",
                        title: L10n.t("pickup_form_location_label", languageCode: languageCode),
                        value: locationLine
                    )
                        .opacity(cardTextOpacity)
                }
                SettingsPickupCardMetaRow(
                    systemImage: "person.3",
                    title: L10n.t("pickup_form_section_players", languageCode: languageCode),
                    value: playersSummaryLine
                )
                    .opacity(cardTextOpacity)
                if !usesExpiredArchivedStyle {
                    PickupOrganizerParticipantSummaryView(
                        viewModel: viewModel,
                        game: row,
                        colorScheme: colorScheme,
                        approvedUserIds: approvedJoinerUserIds,
                        pendingJoinCount: pendingJoinCount,
                        languageCode: languageCode,
                        onParticipantTapped: { uid in
                            viewModel.presentPublicProfile(
                                userId: uid,
                                context: "pickup_roster_avatar",
                                activeSheet: "settings_pickup_games"
                            )
                        },
                        onViewAllPlayers: {
                            if let onOpenDetails {
                                onOpenDetails()
                            } else {
                                onManageRequests()
                            }
                        },
                        showsParticipantStatusBadge: !(isFollowingCompact || isHostingDetail)
                    )
                    .opacity(cardTextOpacity)
                }
                SettingsPickupCardMetaRow(
                    systemImage: "person.2.fill",
                    title: L10n.t("pickup_meta_welcome", languageCode: languageCode),
                    value: row.participantAudienceDisplayTitle
                )
                    .opacity(cardTextOpacity)
                if !isFollowingCompact {
                    SettingsPickupCardMetaRow(systemImage: "chart.bar", title: "Skill", value: row.skillLevelEnum.displayTitle)
                        .opacity(cardTextOpacity)
                    SettingsPickupCardMetaRow(
                        systemImage: row.playEnvironmentEnum == .indoor ? "house.fill" : (row.playEnvironmentEnum == .outdoor ? "sun.max.fill" : "arrow.left.arrow.right"),
                        title: "Play",
                        value: row.playEnvironmentEnum.shortLabel
                    )
                    .opacity(cardTextOpacity)
                    SettingsPickupCardMetaRow(systemImage: row.is_free ? "gift.fill" : "dollarsign.circle", title: "Cost", value: row.entryFeeDisplayLine)
                        .opacity(cardTextOpacity)
                }
            }
            .padding(.top, isHostingDetail ? 10 : 6)
            .contentShape(Rectangle())
            .onTapGesture { handleCardMapTap() }

            if !row.is_visible {
                Text("Private")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: isFollowingCompact ? 8 : 10) {
                if pendingJoinCount > 0, !isFollowingCompact {
                    Button(action: onManageRequests) {
                        Label("Manage requests", systemImage: "person.badge.clock")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.orange)
                    .accessibilityHint("Review pending join requests")

                    Text("Tap above to review who asked to join.")
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                if !withdrawnJoinRows.isEmpty, !usesExpiredArchivedStyle {
                    VStack(alignment: .leading, spacing: isFollowingCompact ? 6 : 10) {
                        Text("Can’t make it")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        ForEach(withdrawnJoinRows) { wr in
                            SettingsPickupWithdrawnJoinRow(
                                viewModel: viewModel,
                                request: wr,
                                organizerCanceledJoinCopy: false,
                                useCompact: horizontalSizeClass == .compact || isFollowingCompact
                            )
                        }
                    }
                    .padding(.top, pendingJoinCount > 0 && !isFollowingCompact ? 8 : 0)
                }

                if isFollowingCompact {
                    followingCompactHostingActionRows
                } else if isHostingDetail {
                    hostingDetailActionRows
                } else {
                    // Settings list: keep existing single-row management actions.
                    HStack(spacing: 10) {
                        if !usesExpiredArchivedStyle, row.isEligibleForInAppShare() {
                            if let onShare {
                                Button(action: onShare) {
                                    Label(L10n.t("Share", languageCode: languageCode), systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .pickupCardActionButtonFrame()
                                }
                                .buttonStyle(.bordered)
                                .tint(FGColor.accentBlue)
                                .accessibilityLabel(L10n.t("share_pickup_a11y_label", languageCode: languageCode))
                                .accessibilityHint(L10n.t("share_pickup_a11y_hint", languageCode: languageCode))
                            } else {
                                PickupGameShareActionButton(game: row, mapViewModel: viewModel) {
                                    Label(L10n.t("Share", languageCode: languageCode), systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(FGColor.accentBlue)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .multilineTextAlignment(.center)
                                        .pickupCardOutlinedActionChrome(tint: FGColor.accentBlue)
                                }
                            }
                        }

                        if !usesExpiredArchivedStyle, let onInvite {
                            Button(action: onInvite) {
                                Label("Invite", systemImage: "person.badge.plus")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .pickupCardActionButtonFrame()
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.orange)
                        }

                        Button(action: onEdit) {
                            Label(gameStarted ? "Manage" : "Edit", systemImage: "pencil")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .pickupCardActionButtonFrame()
                        }
                        .buttonStyle(.bordered)
                        .tint(FGColor.accentBlue)

                        Button(role: .destructive, action: onDelete) {
                            Label("Cancel game", systemImage: "trash")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .pickupCardActionButtonFrame()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.top, isFollowingCompact ? 8 : (isHostingDetail ? 16 : 14))

            if !isFollowingCompact {
                Divider()
                    .opacity(colorScheme == .dark ? 0.35 : 0.5)
                    .padding(.vertical, 10)

                SettingsPickupCleanupCountdownRow(
                    row: row,
                    now: now,
                    languageCode: languageCode,
                    isFooterStyle: true,
                    isClearing: hostingAutoClearInFlight || hostingAutoClearStatusActive,
                    clearFailed: hostingAutoClearFailed
                )
            } else {
                let snap = SettingsPickupCleanupDisplay.snapshot(
                    row: row,
                    now: now,
                    languageCode: languageCode,
                    isClearing: hostingAutoClearInFlight || hostingAutoClearStatusActive,
                    clearFailed: hostingAutoClearFailed
                )
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: snap.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            hostingAutoClearFailed
                                ? Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.9)
                                : FGColor.secondaryText(colorScheme)
                        )
                    Text(snap.label)
                        .font(FGTypography.metadata)
                        .foregroundStyle(
                            hostingAutoClearFailed
                                ? Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.9)
                                : FGColor.secondaryText(colorScheme)
                        )
                }
                .padding(.top, 4)
            }
        }
        .padding(isFollowingCompact ? 14 : 18)
        .background(cardBackgroundStyle, in: shape)
        .overlay(
            shape.strokeBorder(cardStrokeColor, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(usesExpiredArchivedStyle ? (colorScheme == .dark ? 0.18 : 0.035) : (colorScheme == .dark ? 0.42 : 0.1)),
            radius: isFollowingCompact ? (usesExpiredArchivedStyle ? 4 : 8) : 14,
            x: 0,
            y: isFollowingCompact ? (usesExpiredArchivedStyle ? 1 : 3) : 6
        )
        .accessibilityElement(children: .contain)
        .onAppear {
            let actions = gameStarted ? "manage_players,roster_capacity_only" : "full_edit,delete,manage_requests"
            PickupGameStartedStateDebug.log(row: row, now: now, allowedActions: actions)
        }
        .confirmationDialog("Player", isPresented: $showRosterPlayerActions, titleVisibility: .visible) {
            if let uid = rosterActionUserId,
               viewModel.isAuthenticatedForSocialFeatures,
               viewModel.currentUserAuthId != uid {
                rosterPlayerAvatarSocialActions(for: uid)
            }
            Button("Cancel", role: .cancel) {
                rosterActionUserId = nil
            }
        } message: {
            if let u = rosterActionUserId {
                Text(Self.rosterActionMessage(userId: u, viewModel: viewModel))
            }
        }
    }

    private func handleCardMapTap() {
        guard isFollowingCompact, !usesExpiredArchivedStyle else { return }
        onOpenMap?()
    }

    /// Organizer detail sheet actions (Share is in the navigation toolbar):
    /// Row 1: Invite | Edit (equal width)
    /// Row 2: Cancel game (full width, destructive)
    @ViewBuilder
    private var hostingDetailActionRows: some View {
        let rowSpacing: CGFloat = 8
        VStack(spacing: rowSpacing) {
            HStack(spacing: rowSpacing) {
                if let onInvite {
                    Button(action: onInvite) {
                        followingCompactHostingActionLabel(
                            title: "Invite",
                            systemImage: "person.badge.plus",
                            foreground: Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.90)
                        )
                        .pickupCardTintedActionChrome(tint: Color.orange, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                Button(action: onEdit) {
                    followingCompactHostingActionLabel(
                        title: gameStarted ? "Manage" : "Edit",
                        systemImage: "pencil",
                        foreground: FGColor.accentBlue
                    )
                    .pickupCardTintedActionChrome(tint: FGColor.accentBlue, colorScheme: colorScheme)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }

            Button(role: .destructive, action: onDelete) {
                followingCompactHostingActionLabel(
                    title: "Cancel game",
                    systemImage: "trash",
                    foreground: Color.red.opacity(colorScheme == .dark ? 0.95 : 0.88)
                )
                .pickupCardTintedActionChrome(tint: Color.red, colorScheme: colorScheme)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    /// Going → Hosting compact actions:
    /// Row 1: Invite | Edit | Cancel game (equal width)
    /// Row 2: Details & cleanup (full width)
    /// Past deadline: auto-clear in progress, or Clear expired only after failure.
    /// Share lives in the card header (icon only).
    @ViewBuilder
    private var followingCompactHostingActionRows: some View {
        let rowSpacing: CGFloat = 8
        VStack(spacing: rowSpacing) {
            if isExpiredClearing {
                if hostingAutoClearFailed {
                    Button(role: .destructive, action: onDelete) {
                        followingCompactHostingActionLabel(
                            title: "Clear expired",
                            systemImage: "trash",
                            foreground: Color.red.opacity(colorScheme == .dark ? 0.95 : 0.88)
                        )
                        .pickupCardTintedActionChrome(tint: Color.red, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .disabled(hostingAutoClearInFlight)
                } else {
                    followingCompactHostingActionLabel(
                        title: L10n.t("pickup_auto_clearing_now", languageCode: languageCode),
                        systemImage: "arrow.triangle.2.circlepath",
                        foreground: FGColor.secondaryText(colorScheme)
                    )
                    .pickupCardTintedActionChrome(tint: FGColor.mutedText(colorScheme), colorScheme: colorScheme)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(L10n.t("pickup_auto_clearing_now", languageCode: languageCode))
                }
            } else {
                HStack(spacing: rowSpacing) {
                    if let onInvite {
                        Button(action: onInvite) {
                            followingCompactHostingActionLabel(
                                title: "Invite",
                                systemImage: "person.badge.plus",
                                foreground: Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.90)
                            )
                            .pickupCardTintedActionChrome(tint: Color.orange, colorScheme: colorScheme)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)
                    }

                    Button(action: onEdit) {
                        followingCompactHostingActionLabel(
                            title: gameStarted ? "Manage" : "Edit",
                            systemImage: "pencil",
                            foreground: FGColor.accentBlue
                        )
                        .pickupCardTintedActionChrome(tint: FGColor.accentBlue, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                    Button(role: .destructive, action: onDelete) {
                        followingCompactHostingActionLabel(
                            title: "Cancel game",
                            systemImage: "trash",
                            foreground: Color.red.opacity(colorScheme == .dark ? 0.95 : 0.88)
                        )
                        .pickupCardTintedActionChrome(tint: Color.red, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                }

                if let onOpenDetails {
                    Button(action: onOpenDetails) {
                        followingCompactHostingActionLabel(
                            title: L10n.t("pickup_details_cleanup", languageCode: languageCode),
                            systemImage: "ellipsis.circle",
                            foreground: FGColor.accentBlue
                        )
                        .pickupCardTintedActionChrome(tint: FGColor.accentBlue, colorScheme: colorScheme)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var followingCompactHeaderApprovedBadge: some View {
        let title = L10n.t("pickup_host_participant_status_approved", languageCode: languageCode)
        return Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.2 : 0.12),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.35 : 0.22), lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(title)
    }

    /// Compact icon Share — matches Discover pickup preview trailing control (38pt material, 44pt hit).
    @ViewBuilder
    private var followingCompactHeaderShareControl: some View {
        Group {
            if let onShare {
                Button(action: onShare) {
                    followingCompactHeaderShareIcon
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("share_pickup_a11y_label", languageCode: languageCode))
                .accessibilityHint(L10n.t("share_pickup_a11y_hint", languageCode: languageCode))
            } else {
                PickupGameShareActionButton(game: row, mapViewModel: viewModel) {
                    followingCompactHeaderShareIcon
                }
                .fixedSize()
            }
        }
    }

    private var followingCompactHeaderShareIcon: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 38, height: 38)
                .overlay {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12),
                            lineWidth: 1
                        )
                }
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(followingCompactShareIconColor)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    /// Compact single-line action label that scales before truncating (avoids "Cancel g…").
    private func followingCompactHostingActionLabel(
        title: String,
        systemImage: String,
        foreground: Color
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .imageScale(.medium)
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rosterPlayerAvatarSocialActions(for uid: UUID) -> some View {
        switch chatViewModel.chipKind(forOtherUserId: uid) {
        case .friends:
            Button("Message friend") {
                rosterActionUserId = nil
                showRosterPlayerActions = false
                guard let p = userPreviewForRoster(userId: uid) else {
                    print("[PickupRosterAvatarFriendship] error=missing_user_preview userId=\(uid.uuidString.lowercased())")
                    viewModel.showSocialActionToast("Couldn’t open chat. Try again.", isError: true)
                    return
                }
                Task { await openMessageFriendFromRoster(preview: p, peerUserId: uid) }
            }
        case .addFriend, .declinedOutgoing:
            Button("Request friendship") {
                rosterActionUserId = nil
                Task { await sendRosterFriendRequest(to: uid) }
            }
        case .pendingOutgoing, .pendingIncoming:
            Button("Friendship requested") {}
                .disabled(true)
        }
    }

    private func userPreviewForRoster(userId: UUID) -> UserPreview? {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[userId]
        let name = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = name.isEmpty ? "Player" : name
        let email = profile?.email
        let full = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let handle = profile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UserPreview(
            id: userId,
            displayName: display,
            username: handle.isEmpty ? nil : FanGeoHandleRules.normalizeForStorage(handle),
            email: email,
            avatarURL: full.isEmpty ? nil : full,
            avatarThumbnailURL: thumb.isEmpty ? nil : thumb
        )
    }

    private static func rosterActionMessage(userId: UUID, viewModel: MapViewModel) -> String {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[userId]
        let name = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Joined player" : name
    }

    private static func tappedPlayerEmailLine(userId: UUID, viewModel: MapViewModel) -> String {
        let raw = (viewModel.pickupJoinRequesterProfileByUserId[userId]?.email ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "(none)" : raw
    }

    private static func friendshipStatusLog(chip: ChatViewModel.FriendshipChipKind) -> String {
        switch chip {
        case .addFriend: return "addFriend"
        case .friends: return "friends"
        case .pendingOutgoing: return "pendingOutgoing"
        case .pendingIncoming: return "pendingIncoming"
        case .declinedOutgoing: return "declinedOutgoing"
        }
    }

    private static func pickupRosterFriendshipActionShown(chip: ChatViewModel.FriendshipChipKind) -> String {
        switch chip {
        case .friends:
            return "Message friend"
        case .addFriend, .declinedOutgoing:
            return "Request friendship"
        case .pendingOutgoing, .pendingIncoming:
            return "Friendship requested(disabled)"
        }
    }

    private static func logPickupRosterAvatarFriendship(
        tappedPlayerId: UUID,
        tappedPlayerEmail: String,
        friendshipStatus: String,
        actionShown: String,
        requestCreated: Bool,
        existingRequestFound: Bool,
        openedDM: Bool
    ) {
#if DEBUG
        print("[PickupRosterAvatarFriendship] tappedPlayerId=\(tappedPlayerId.uuidString.lowercased())")
        print("[PickupRosterAvatarFriendship] tappedPlayerEmail=\(tappedPlayerEmail)")
        print("[PickupRosterAvatarFriendship] friendshipStatus=\(friendshipStatus)")
        print("[PickupRosterAvatarFriendship] actionShown=\(actionShown)")
        print("[PickupRosterAvatarFriendship] requestCreated=\(requestCreated)")
        print("[PickupRosterAvatarFriendship] existingRequestFound=\(existingRequestFound)")
        print("[PickupRosterAvatarFriendship] openedDM=\(openedDM)")
#endif
    }

    private static func logPickupRosterMessageFriendOpen(
        messageFriendTapped: Bool,
        tappedPlayerId: UUID,
        tappedPlayerEmail: String,
        friendshipStatus: String,
        conversationId: UUID?,
        openedDM: Bool,
        error: String
    ) {
#if DEBUG
        print("[PickupRosterAvatarFriendship] messageFriendTapped=\(messageFriendTapped)")
        print("[PickupRosterAvatarFriendship] tappedPlayerId=\(tappedPlayerId.uuidString.lowercased())")
        print("[PickupRosterAvatarFriendship] tappedPlayerEmail=\(tappedPlayerEmail)")
        print("[PickupRosterAvatarFriendship] friendshipStatus=\(friendshipStatus)")
        if let conversationId {
            print("[PickupRosterAvatarFriendship] conversationId=\(conversationId.uuidString.lowercased())")
        } else {
            print("[PickupRosterAvatarFriendship] conversationId=")
        }
        print("[PickupRosterAvatarFriendship] openedDM=\(openedDM)")
        print("[PickupRosterAvatarFriendship] error=\(error)")
#endif
    }

    private func openMessageFriendFromRoster(preview: UserPreview, peerUserId: UUID) async {
        let emailLine = Self.tappedPlayerEmailLine(userId: peerUserId, viewModel: viewModel)
        let friendshipStatus = Self.friendshipStatusLog(chip: .friends)
        do {
            let cid = try await chatViewModel.startDirectConversationWithFriend(friendUserId: peerUserId)
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            await MainActor.run {
                chatViewModel.pendingDmOpenPreview = preview
            }
            Self.logPickupRosterMessageFriendOpen(
                messageFriendTapped: true,
                tappedPlayerId: peerUserId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: friendshipStatus,
                conversationId: cid,
                openedDM: true,
                error: ""
            )
        } catch {
            print("[PickupRosterAvatarFriendship] error=\(error.localizedDescription)")
            Self.logPickupRosterMessageFriendOpen(
                messageFriendTapped: true,
                tappedPlayerId: peerUserId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: friendshipStatus,
                conversationId: nil,
                openedDM: false,
                error: error.localizedDescription
            )
            await MainActor.run {
                viewModel.showSocialActionToast("Couldn’t open chat. Try again.", isError: true)
            }
        }
    }

    private func sendRosterFriendRequest(to userId: UUID) async {
        let emailLine = Self.tappedPlayerEmailLine(userId: userId, viewModel: viewModel)
        let chipBefore = chatViewModel.chipKind(forOtherUserId: userId)
        if chipBefore == .pendingOutgoing || chipBefore == .pendingIncoming {
            Self.logPickupRosterAvatarFriendship(
                tappedPlayerId: userId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: Self.friendshipStatusLog(chip: chipBefore),
                actionShown: Self.pickupRosterFriendshipActionShown(chip: chipBefore),
                requestCreated: false,
                existingRequestFound: true,
                openedDM: false
            )
            return
        }
        await chatViewModel.sendFriendRequestFromComments(to: userId)
        if let err = chatViewModel.errorMessage, !err.isEmpty {
            let duplicate = err.localizedCaseInsensitiveContains("already exists")
            Self.logPickupRosterAvatarFriendship(
                tappedPlayerId: userId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: Self.friendshipStatusLog(chip: chatViewModel.chipKind(forOtherUserId: userId)),
                actionShown: "Request friendship",
                requestCreated: false,
                existingRequestFound: duplicate,
                openedDM: false
            )
            if duplicate {
                await chatViewModel.refreshFriendRequestListsOnly()
                await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
                viewModel.showSocialActionToast("Friend request already pending.", isError: false)
            } else {
                viewModel.showSocialActionToast(err, isError: true)
            }
            return
        }
        Self.logPickupRosterAvatarFriendship(
            tappedPlayerId: userId,
            tappedPlayerEmail: emailLine,
            friendshipStatus: Self.friendshipStatusLog(chip: chatViewModel.chipKind(forOtherUserId: userId)),
            actionShown: Self.pickupRosterFriendshipActionShown(chip: chatViewModel.chipKind(forOtherUserId: userId)),
            requestCreated: true,
            existingRequestFound: false,
            openedDM: false
        )
        viewModel.showSocialActionToast("Friend request sent", isError: false)
        await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
    }
}

/// Soft-removed pickup (`status = removed`) shown under History.
struct SettingsPickupRemovedHistoryCard: View {
    @ObservedObject var viewModel: MapViewModel
    let row: PickupGameRow
    let withdrawnJoinRows: [PickupGameRequestRow]
    let now: Date
    let colorScheme: ColorScheme
    var useCompactCopy: Bool
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var dateTimeLine: String? {
        row.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SportArtworkIconView(sport: row.sport, diameter: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(3)
                    if let dateTimeLine {
                        Text(dateTimeLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                Spacer(minLength: 0)
                Text("Removed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), in: Capsule(style: .continuous))
            }

            Text("This pickup was canceled and is hidden from Discover and player lists.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if !withdrawnJoinRows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Players affected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    ForEach(withdrawnJoinRows) { wr in
                        SettingsPickupWithdrawnJoinRow(
                            viewModel: viewModel,
                            request: wr,
                            organizerCanceledJoinCopy: true,
                            useCompact: useCompactCopy
                        )
                    }
                }
            }

            SettingsPickupRemovedHistoryCleanupFooter(
                viewModel: viewModel,
                row: row,
                now: now,
                colorScheme: colorScheme
            )
        }
        .padding(18)
        .background(.ultraThinMaterial, in: shape)
        .overlay(
            shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
        )
    }
}

/// Footer for removed games: explicit clear action + auto-clear hint (no “in progress” copy unless something is actually running).
private struct SettingsPickupRemovedHistoryCleanupFooter: View {
    @ObservedObject var viewModel: MapViewModel
    let row: PickupGameRow
    let now: Date
    let colorScheme: ColorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var cleanupDeadline: Date? {
        row.pickupHistoryClientCleanupDeadline()
    }

    private var autoClearCaption: String {
        guard let deadline = cleanupDeadline else {
            return String(
                format: L10n.t("pickup_auto_clears_after_start_format", languageCode: languageCode),
                12
            )
        }
        if now >= deadline {
            return String(
                format: L10n.t("pickup_auto_clears_after_start_format", languageCode: languageCode),
                12
            )
        }
        let stamp = deadline.formatted(
            Date.FormatStyle.dateTime
                .month(.abbreviated)
                .day()
                .year()
                .hour()
                .minute()
                .locale(Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_")))
        )
        return String(
            format: L10n.t("pickup_auto_clears_on_format", languageCode: languageCode),
            stamp
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(autoClearCaption)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                viewModel.markPickupOrganizerSettingsHistoryUserCleared(pickupGameId: row.id)
            } label: {
                Text("Clear now")
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Color.red.opacity(0.88))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One withdrawn / cancelled joiner row on the organizer’s Settings pickup card.
private struct SettingsPickupWithdrawnJoinRow: View {
    @ObservedObject var viewModel: MapViewModel
    let request: PickupGameRequestRow
    var organizerCanceledJoinCopy: Bool
    var useCompact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[request.requester_user_id]
        let profileName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = profileName.isEmpty ? request.requesterNameForUI : profileName
        let emailLine = (profile?.email ?? request.requester_email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let fullRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb: String? = thumbRaw.isEmpty ? nil : thumbRaw
        let full = fullRaw.isEmpty ? "" : fullRaw
        let token = viewModel.pickupJoinRequesterAvatarTokenByUserId[request.requester_user_id] ?? UserAvatarView.stableRefreshToken(
            userId: request.requester_user_id,
            thumbnailURL: thumb,
            avatarURL: full
        )

        HStack(alignment: .top, spacing: 12) {
            PublicProfileAvatarTap(
                userId: request.requester_user_id,
                context: "pickup_withdrawn_joiner",
                activeSheet: "settings_pickup_games"
            ) {
                UserAvatarView(
                    avatarThumbnailURL: thumb,
                    avatarURL: full,
                    avatarDisplayRefreshToken: token,
                    displayName: displayName,
                    email: emailLine,
                    size: 40,
                    fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(organizerCanceledJoinCopy ? "Canceled by organizer" : request.organizerFanWithdrawnSubtitle())
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                if let stamp = request.organizerFanWithdrawnTimestampLine(compactWidth: useCompact) {
                    Text(stamp)
                        .font(.caption2)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: request.requester_user_id) {
            await viewModel.loadPickupJoinRequesterProfilesForOrganizerSheet(requesterIds: [request.requester_user_id])
        }
    }
}

private struct SettingsPickupCardMetaRow: View {
    let systemImage: String
    let title: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue.opacity(0.85))
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Local-only cleanup countdown copy for organizer Settings list rows.
private enum SettingsPickupCleanupDisplay {
    enum Tone {
        case normal
        case amber
        case danger
    }

    struct Snapshot {
        let label: String
        let symbolName: String
        let tone: Tone
    }

    static func cleanupDeadline(for row: PickupGameRow) -> Date? {
        PickupHostingAutoClear.deadline(for: row)
    }

    static func snapshot(
        row: PickupGameRow,
        now: Date,
        languageCode: String,
        isClearing: Bool = false,
        clearFailed: Bool = false
    ) -> Snapshot {
        let label = PickupHostingAutoClear.statusLabel(
            row: row,
            now: now,
            languageCode: languageCode,
            isClearing: isClearing,
            clearFailed: clearFailed
        )
        if clearFailed {
            return Snapshot(label: label, symbolName: "exclamationmark.triangle", tone: .amber)
        }
        if isClearing {
            return Snapshot(label: label, symbolName: "arrow.triangle.2.circlepath", tone: .amber)
        }
        guard let deadline = cleanupDeadline(for: row) else {
            return Snapshot(label: label, symbolName: "clock.arrow.circlepath", tone: .normal)
        }
        if let gameStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at), now < gameStart {
            return Snapshot(label: label, symbolName: "clock.arrow.circlepath", tone: .normal)
        }
        let remaining = deadline.timeIntervalSince(now)
        if remaining < 3600 {
            return Snapshot(label: label, symbolName: "timer", tone: .amber)
        }
        return Snapshot(label: label, symbolName: "timer", tone: .normal)
    }
}

private struct SettingsPickupCleanupCountdownRow: View {
    let row: PickupGameRow
    let now: Date
    let languageCode: String
    /// Footer uses smaller type and neutral gray until amber/red.
    var isFooterStyle: Bool = false
    var isClearing: Bool = false
    var clearFailed: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let snap = SettingsPickupCleanupDisplay.snapshot(
            row: row,
            now: now,
            languageCode: languageCode,
            isClearing: isClearing,
            clearFailed: clearFailed
        )
        let iconSize: CGFloat = isFooterStyle ? 11 : 13
        let spacing: CGFloat = isFooterStyle ? 5 : 6
        HStack(alignment: .center, spacing: spacing) {
            Image(systemName: snap.symbolName)
                .font(.system(size: iconSize, weight: .semibold))
                .symbolRenderingMode(isFooterStyle && snap.tone == .normal ? .monochrome : .hierarchical)
                .foregroundStyle(labelColor(for: snap.tone))
            Text(snap.label)
                .font(isFooterStyle ? .footnote : FGTypography.caption)
                .foregroundStyle(labelColor(for: snap.tone))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snap.label)
    }

    private func labelColor(for tone: SettingsPickupCleanupDisplay.Tone) -> Color {
        if isFooterStyle {
            switch tone {
            case .normal:
                return Color.secondary
            case .amber:
                return Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.92)
            case .danger:
                return FGColor.dangerRed
            }
        }
        return ink(for: tone)
    }

    private func ink(for tone: SettingsPickupCleanupDisplay.Tone) -> Color {
        switch tone {
        case .normal:
            return FGColor.secondaryText(colorScheme)
        case .amber:
            return Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.92)
        case .danger:
            return FGColor.dangerRed
        }
    }
}

private enum PickupCostKind: String, CaseIterable, Identifiable {
    case free
    case paid

    var id: String { rawValue }

    var title: String {
        title(languageCode: nil)
    }

    func title(languageCode: String?) -> String {
        switch self {
        case .free: return L10n.t("pickup_cost_free", languageCode: languageCode)
        case .paid: return L10n.t("pickup_cost_paid", languageCode: languageCode)
        }
    }
}

private enum PickupGameCreationTab: String, CaseIterable, Identifiable {
    case manual
    case csvImport

    var id: String { rawValue }

    func title(languageCode: String) -> String {
        switch self {
        case .manual:
            return L10n.t("pickup_form_tab_manual", languageCode: languageCode)
        case .csvImport:
            return L10n.t("pickup_form_tab_csv_import", languageCode: languageCode)
        }
    }
}

// MARK: - Create / Edit pickup form chrome (presentation only)

private struct PickupFormSectionCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(FGAdaptiveSurface.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.4), lineWidth: 0.5)
            }
            .softCardShadow()
        }
    }
}

private struct PickupFormRowDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Divider()
            .opacity(colorScheme == .dark ? 0.35 : 0.55)
            .padding(.leading, 52)
    }
}

struct PickupFormIconBadge: View {
    let systemImage: String
    var accent: Color = FGColor.intentPlay

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: 28, height: 28)
            .background(accent.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct PickupFormFieldRow<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    var accent: Color = FGColor.intentPlay
    let label: String
    var showsChevron: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            PickupFormIconBadge(systemImage: systemImage, accent: accent)
            Text(label)
                .font(.system(size: 16, weight: .regular, design: .default))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: FGSpacing.sm)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 44, alignment: .center)
        .contentShape(Rectangle())
    }
}

/// Trailing selected-value + chevron for menu-style pickup form rows.
/// Keeps a shared right edge across sibling rows; scales down long values on one line.
private struct PickupFormTrailingSelectionValue: View {
    @Environment(\.colorScheme) private var colorScheme
    let value: String
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 16, weight: emphasized ? .semibold : .medium, design: .rounded))
                .foregroundStyle(emphasized ? FGColor.intentPlay : FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .accessibilityHidden(true)
        }
        .frame(minWidth: 108, maxWidth: 168, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

/// How-You-Play style selection row: shared trailing alignment + accessibility stack fallback.
private struct PickupFormSelectionFieldRow<MenuContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let systemImage: String
    var accent: Color = FGColor.intentPlay
    let label: String
    let valueText: String
    @ViewBuilder var menuContent: () -> MenuContent

    private var prefersStackedLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        Menu {
            menuContent()
        } label: {
            Group {
                if prefersStackedLayout {
                    stackedLabel
                } else {
                    compactLabel
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 10)
            .frame(minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(FGColor.intentPlay)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
    }

    private var compactLabel: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            PickupFormIconBadge(systemImage: systemImage, accent: accent)
            Text(label)
                .font(.system(size: 16, weight: .regular, design: .default))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: FGSpacing.sm)
            PickupFormTrailingSelectionValue(value: valueText)
                .layoutPriority(0)
        }
    }

    private var stackedLabel: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            PickupFormIconBadge(systemImage: systemImage, accent: accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(valueText)
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Add or edit a pickup game (fan accounts only; caller gates).
struct SettingsPickupGameFormView: View {
    @ObservedObject var viewModel: MapViewModel
    let mode: PickupGameFormMode
    var pickupPlacePrefill: PickupPlaceRow? = nil
    /// When set from My Teams → Schedule Game, reuses this same form with Team prefill + link.
    var creationContext: PickupGameCreationContext = .standard
    var onCreated: ((PickupGameRow) -> Void)? = nil
    var onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    @State private var title: String = ""
    @State private var sport: String = "Soccer"
    @State private var sportSubtype: String? = nil
    @State private var gameDate: Date = Date()
    @State private var gameTime: Date = Date()
    @State private var endTime: Date = Date().addingTimeInterval(2 * 3600)
    @State private var didManuallyEditEndTime = false
    @State private var address: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    /// ISO country from Team location / map pin when known (not persisted on pickup_games).
    @State private var appliedLocationCountryCode: String = ""
    @State private var description: String = ""
    @State private var playEnvironment: PickupPlayEnvironment = .either
    @State private var skillLevel: PickupGameSkillLevel = .casual
    /// Nil = Not specified (nullable DB column).
    @State private var competitionLevel: PickupCompetitionLevel? = nil
    /// Team Schedule Game: false while showing "Team default" chrome; true after Override (or non-Team).
    @State private var competitionLevelOverrideActive = false
    @State private var participantPreference: PickupParticipantPreference = .everyone
    @State private var specifyAgeRange = false
    @State private var minimumAge = 18
    @State private var maximumAge = 35
    @State private var noMaximumAge = true
    @State private var costKind: PickupCostKind = .free
    @State private var entryFeeText: String = ""
    @State private var playersNeeded: Int = 1
    @State private var useMaxPlayers: Bool = false
    @State private var maxPlayers: Int = 10
    /// Team create / Team-linked edit: optional outside recruiting (maps to `players_needed` / `max_players`).
    @State private var needsAdditionalPlayers: Bool = false
    /// Public = Discover for everyone; Private = authorized viewers only (`is_visible=false`).
    /// Standalone pickup always persists public; this flag is only user-editable for Team events.
    @State private var isPublicDiscover: Bool = true
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var showPickupMapLocationPicker = false
    @State private var showTeamChooseLocationPicker = false
    @State private var showManualAddressEntry = false
    @State private var showSportPicker = false
    @State private var showGameDatePopover = false
    @State private var suppressGameDatePickerChangeLog = false
    @FocusState private var isTitleFieldFocused: Bool
    @State private var coordinatesLockedFromMap = false
    @State private var mapPinnedCoordinate: CLLocationCoordinate2D?
    @State private var addressPreviewCoordinate: CLLocationCoordinate2D?
    @State private var addressPreviewAddressLine = ""
    @State private var addressPreviewGeocodeTask: Task<Void, Never>?
    @State private var appliedPickupPlacePrefill: PickupPlaceRow?
    @State private var pickupSafetyAcknowledged = false
    @State private var didInitializeForm = false
    @State private var showPickupTimeConflictConfirmation = false
    @State private var creationTab: PickupGameCreationTab = .manual
    @State private var gameFormat: GameType = .pickup
    @State private var pollCreatePermission: PickupPollCreatePermission = .organizerOnly
    /// Free-text opponent for Team competitive formats. Kept across format switches in-session.
    @State private var opponentName: String = ""
    @State private var hasArrivalTime: Bool = false
    @State private var arrivalTime: Date = Date()
    @State private var showTeamMoreOptions = false
    @State private var showTeamTimeEditor = false
    @State private var lastAutoSuggestedTitle: String = ""
    @State private var titleManuallyCustomized = false
    @State private var teamScheduleValidationAnchor: String?
    @State private var showOpponentEditor = false
    @State private var opponentEditorDraft: String = ""
    /// Edit path: Team context resolved from `fan_team_game_links` when `creationContext` is `.standard`.
    @State private var linkedTeamFormContext: PickupGameTeamCreationContext?

    private var organizerPostStartLockedRow: PickupGameRow? {
        guard case .edit(let row) = mode, row.hasPickupGameStarted() else { return nil }
        // Pickup creators keep the post-start Manage Game lock.
        if isCurrentUserCreator(of: row) { return row }
        // Team-linked started events use the same intentional lock for Team managers
        // (Owner/Manager editing via Team permissions, not creator_user_id).
        if creationContext.isTeamSourced || linkedTeamFormContext != nil {
            return row
        }
        return nil
    }

    private var isOrganizerPostStartManage: Bool { organizerPostStartLockedRow != nil }

    private func isCurrentUserCreator(of row: PickupGameRow) -> Bool {
        guard let uid = viewModel.currentUserAuthId else { return false }
        return row.creator_user_id == uid
    }

    private var lockedGameStartDisplay: String {
        guard case .edit(let row) = mode,
              let d = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private var lockedGameEndDisplay: String {
        guard case .edit(let row) = mode,
              let d = PickupGameModels.endDate(for: row) else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCity: String {
        city.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedState: String {
        state.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedZipCode: String {
        zipCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCompleteTypedAddress: Bool {
        // International: street + locality are enough. Region/postal optional (not every country uses them).
        !trimmedAddress.isEmpty && !trimmedCity.isEmpty
    }

    private var typedAddressLine: String {
        [trimmedAddress, trimmedCity, trimmedState, trimmedZipCode]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var hasPrefilledPickupPlaceLocation: Bool {
        appliedPickupPlacePrefill != nil && hasValidMapPinLocation
    }

    private var hasValidMapPinLocation: Bool {
        guard coordinatesLockedFromMap, let coordinate = mapPinnedCoordinate else { return false }
        return Self.isValidPickupCoordinate(coordinate)
    }

    private var hasValidAddressPreviewLocation: Bool {
        guard let coordinate = addressPreviewCoordinate else { return false }
        return addressPreviewAddressLine == typedAddressLine && Self.isValidPickupCoordinate(coordinate)
    }

    private var pickupLocationPreview: (coordinate: CLLocationCoordinate2D, helperText: String)? {
        if hasValidMapPinLocation, let coordinate = mapPinnedCoordinate {
            return (coordinate, "Using exact map pin location.")
        }
        if hasValidAddressPreviewLocation, let coordinate = addressPreviewCoordinate {
            return (coordinate, "Preview based on address.")
        }
        return nil
    }

    /// Post/Save stays tappable once a map pin or the major address fields are present so validation can show a clear error.
    private var hasPlacedLocationForPostButton: Bool {
        hasValidMapPinLocation || (!trimmedAddress.isEmpty && !trimmedCity.isEmpty && !trimmedState.isEmpty)
    }

    /// Compact Team-only note when Team-linked and not recruiting outside players.
    private var usesTeamOnlySafetyNote: Bool {
        PickupTeamSafetyPresentation.usesTeamOnlyInformationalNote(
            isTeamLinked: isTeamLinkedForm,
            needsAdditionalPlayers: needsAdditionalPlayers
        )
    }

    /// Create-only. Team-only games skip acknowledgement; Team recruiting + standalone require it.
    private var requiresPickupSafetyAcknowledgment: Bool {
        PickupTeamSafetyPresentation.requiresAcknowledgment(
            isCreate: mode.isCreate && !mode.forcesTeamAnnouncement && !isAnnouncementForm,
            isTeamLinked: isTeamLinkedForm,
            needsAdditionalPlayers: needsAdditionalPlayers
        )
    }

    private var pickMapSeedCoordinate: CLLocationCoordinate2D {
        if let pin = mapPinnedCoordinate {
            return pin
        }
        if case .edit(let row) = mode,
           let la = row.latitude,
           let lo = row.longitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        if let r = viewModel.cameraPosition.region {
            return r.center
        }
        return CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.00902)
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { address },
            set: { newValue in
                address = newValue
                detachPickupPlacePrefillForLocationTextEdit()
                scheduleAddressLocationPreviewGeocode()
            }
        )
    }

    private var cityBinding: Binding<String> {
        Binding(
            get: { city },
            set: { newValue in
                city = newValue
                detachPickupPlacePrefillForLocationTextEdit()
                scheduleAddressLocationPreviewGeocode()
            }
        )
    }

    private var stateBinding: Binding<String> {
        Binding(
            get: { state },
            set: { newValue in
                state = newValue
                detachPickupPlacePrefillForLocationTextEdit()
                scheduleAddressLocationPreviewGeocode()
            }
        )
    }

    private var zipCodeBinding: Binding<String> {
        Binding(
            get: { zipCode },
            set: { newValue in
                zipCode = newValue
                detachPickupPlacePrefillForLocationTextEdit()
                scheduleAddressLocationPreviewGeocode()
            }
        )
    }

    private func detachPickupPlacePrefillForLocationTextEdit() {
        appliedPickupPlacePrefill = nil
        guard !hasValidMapPinLocation else { return }
        coordinatesLockedFromMap = false
        mapPinnedCoordinate = nil
    }

    private func scheduleAddressLocationPreviewGeocode() {
        addressPreviewGeocodeTask?.cancel()
        guard !hasValidMapPinLocation, hasCompleteTypedAddress else {
            addressPreviewCoordinate = nil
            addressPreviewAddressLine = ""
            return
        }

        let addressLine = typedAddressLine
        if addressPreviewAddressLine != addressLine {
            addressPreviewCoordinate = nil
            addressPreviewAddressLine = ""
        }

        addressPreviewGeocodeTask = Task { @MainActor in
            defer {
                if typedAddressLine == addressLine {
                    addressPreviewGeocodeTask = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !hasValidMapPinLocation, typedAddressLine == addressLine else { return }
            let coordinate = await viewModel.geocodeAddress(addressLine)
            guard !Task.isCancelled, !hasValidMapPinLocation, typedAddressLine == addressLine else { return }
            if let coordinate, Self.isValidPickupCoordinate(coordinate) {
                addressPreviewCoordinate = coordinate
                addressPreviewAddressLine = addressLine
            } else {
                addressPreviewCoordinate = nil
                addressPreviewAddressLine = ""
            }
        }
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: { gameTime },
            set: { newValue in
                gameTime = newValue
                if !didManuallyEditEndTime {
                    endTime = Self.defaultPickupEndTime(forStartTimePickerDate: newValue)
                }
            }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding(
            get: { endTime },
            set: { newValue in
                endTime = newValue
                didManuallyEditEndTime = true
            }
        )
    }

    private var locationGuidanceFootnote: String? {
        if hasValidMapPinLocation {
            if !hasCompleteTypedAddress {
                return "Map pin will be used as the game location."
            }
            return nil
        }
        if hasCompleteTypedAddress {
            if !hasValidAddressPreviewLocation, addressPreviewGeocodeTask == nil {
                return "Address may be incomplete. Pick a location from the map to confirm."
            }
            return nil
        }
        if !typedAddressLine.isEmpty {
            return "Address may be incomplete. Pick a location from the map to confirm."
        }
        return "Enter an address or pick a location from the map."
    }

    private var shouldShowCreationTabs: Bool {
        // Same Manual | CSV Import shell for normal Pickup and Team → Schedule Game.
        // Dedicated Announcement composer never shows CSV / format switching.
        if case .add = mode { return true }
        return false
    }

    private var shouldShowGameFormatPicker: Bool {
        // Create Schedule Event / Create Pickup show Event Type; Announcement composer hides it.
        if mode.forcesTeamAnnouncement { return false }
        // Post-start Manage Game keeps core scheduling fields locked (including Event Type).
        if isOrganizerPostStartManage { return false }
        if case .add = mode { return true }
        // Future Team + standalone edits: Event Type stays editable before start.
        if case .edit = mode { return true }
        return false
    }

    private var showsTeamIdentityHeader: Bool {
        creationContext.isTeamSourced && creationContext.team != nil
            && (shouldShowCreationTabs || mode.forcesTeamAnnouncement || isAnnouncementForm)
    }

    /// Team Schedule create, or edit of a game linked via `fan_team_game_links`.
    private var isTeamLinkedForm: Bool {
        creationContext.isTeamSourced || linkedTeamFormContext != nil
    }

    /// Progressive creation layout shared by Team Schedule and standalone Pickup.
    /// Post-start organizer manage keeps the classic locked form.
    private var usesTeamScheduleProgressiveLayout: Bool {
        !isOrganizerPostStartManage
    }

    /// Team purple vs Pickup orange — scoped to this form's chrome only.
    private var formAccent: Color {
        isTeamLinkedForm ? FGColor.intentTeams : FGColor.intentPlay
    }

    /// Prefer explicit Schedule Game context; otherwise use link-resolved Team identity for edit.
    private var effectiveTeamCreationContext: PickupGameTeamCreationContext? {
        creationContext.team ?? linkedTeamFormContext
    }

    private var showsTeamOutsideRecruitmentHowYouPlayFields: Bool {
        guard teamEventPolicy.showsHowYouPlay else { return false }
        return PickupTeamHowYouPlayPresentation.showsOutsideRecruitmentFields(
            isTeamLinked: isTeamLinkedForm,
            needsAdditionalPlayers: needsAdditionalPlayers
        )
    }

    /// Team-linked format policy (sport-aware opponent / scoring); standalone Pickup uses gameplay.
    private var teamEventPolicy: FanTeamEventFormatPolicy {
        guard isTeamLinkedForm else {
            return FanTeamEventPresentation.policy(for: GameType.pickup, sport: sport)
        }
        return FanTeamEventPresentation.policy(for: gameFormat, sport: sport)
    }

    private var availableGameFormats: [GameType] {
        if isTeamLinkedForm {
            let canAnnounce = effectiveTeamCreationContext?.canPublishAnnouncements == true
                || (creationContext.team?.canPublishAnnouncements == true)
            return FanTeamEventTypeCatalog.menuTypes(
                for: sport,
                current: gameFormat,
                canPublishAnnouncements: canAnnounce
            )
        }
        return PickupEventTypeCatalog.menuTypes(for: sport, current: gameFormat)
    }

    /// Event Type label shown in create menus (sport-aware for Team + Pickup).
    private func eventTypeDisplayTitle(for format: GameType) -> String {
        if isTeamLinkedForm {
            return FanTeamEventTypeCatalog.displayTitle(
                for: format,
                sport: sport,
                languageCode: languageCode
            )
        }
        return PickupEventTypeCatalog.displayTitle(
            for: format,
            sport: sport,
            languageCode: languageCode
        )
    }

    private var usesParticipantAudienceWording: Bool {
        !isTeamLinkedForm && PickupEventTypeCatalog.usesParticipantTerminology(for: sport)
    }

    private var progressiveDetailsSectionTitle: String {
        if isTeamLinkedForm {
            return L10n.t("team_schedule_event_details", languageCode: languageCode)
        }
        return L10n.t("pickup_form_section_pickup_details", languageCode: languageCode)
    }

    private var progressivePlayersSectionTitle: String {
        if usesParticipantAudienceWording {
            return L10n.t("pickup_form_section_participants", languageCode: languageCode)
        }
        return L10n.t("pickup_form_section_players", languageCode: languageCode)
    }

    private var playersNeededFieldLabel: String {
        if usesParticipantAudienceWording {
            return L10n.t("pickup_form_participants_needed", languageCode: languageCode)
        }
        return L10n.t("pickup_form_players_needed", languageCode: languageCode)
    }

    private var maxPlayersFieldLabel: String {
        if usesParticipantAudienceWording {
            return L10n.t("pickup_form_max_participants", languageCode: languageCode)
        }
        return L10n.t("pickup_form_max_players", languageCode: languageCode)
    }

    private var playersNeededCountDisplayText: String {
        if usesParticipantAudienceWording {
            if playersNeeded == 1 {
                return L10n.t("pickup_form_participant_count_one", languageCode: languageCode)
            }
            return String(
                format: L10n.t("pickup_form_participant_count_other_format", languageCode: languageCode),
                playersNeeded
            )
        }
        return playersNeededCountText
    }

    private var isAnnouncementForm: Bool {
        isTeamLinkedForm && gameFormat == .announcement
    }

    /// Rich summary card replaces the old generic intro banner for create + edit.
    private var showsCreateIntro: Bool { false }

    private var showsLiveSummary: Bool {
        !isOrganizerPostStartManage && !usesTeamScheduleProgressiveLayout
    }

    private var canSubmitPickupForm: Bool {
        let titleOK = isOrganizerPostStartManage
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let locationOK = isOrganizerPostStartManage
            || isAnnouncementForm
            || hasPlacedLocationForPostButton
        let descriptionOK = !isAnnouncementForm
            || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isSaving
            && titleOK
            && locationOK
            && descriptionOK
            && (!requiresPickupSafetyAcknowledgment || pickupSafetyAcknowledged)
            && (isOrganizerPostStartManage || !requiresOpponentForSubmit || hasOpponentForSubmit)
    }

    private var requiresOpponentForSubmit: Bool {
        isTeamLinkedForm && teamEventPolicy.requiresOpponent
    }

    private var hasOpponentForSubmit: Bool {
        FanTeamScheduleMatchup.trimmedOpponent(opponentName) != nil
    }

    private var postReadinessMessage: String? {
        guard !canSubmitPickupForm, !isSaving, !isOrganizerPostStartManage else { return nil }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.t("pickup_form_ready_add_title", languageCode: languageCode)
        }
        if isAnnouncementForm, description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.t("team_announcement_ready_add_message", languageCode: languageCode)
        }
        if !isAnnouncementForm, !hasPlacedLocationForPostButton {
            return L10n.t("pickup_form_ready_choose_location", languageCode: languageCode)
        }
        if requiresOpponentForSubmit && !hasOpponentForSubmit {
            return L10n.t("pickup_form_ready_add_opponent", languageCode: languageCode)
        }
        if requiresPickupSafetyAcknowledgment && !pickupSafetyAcknowledged {
            return L10n.t("pickup_form_ready_acknowledge_safety", languageCode: languageCode)
        }
        return nil
    }

    private var navigationTitleText: String {
        if mode.forcesTeamAnnouncement || (isAnnouncementForm && mode.isCreate == false) {
            return L10n.t("fan_teams_make_announcement_nav_title", languageCode: languageCode)
        }
        switch mode {
        case .add, .addTeamAnnouncement:
            if creationContext.isTeamSourced {
                return L10n.t("fan_teams_schedule_game", languageCode: languageCode)
            }
            return L10n.t("pickup_form_nav_create", languageCode: languageCode)
        case .edit:
            if isOrganizerPostStartManage {
                return L10n.t("pickup_form_nav_manage", languageCode: languageCode)
            }
            if isTeamLinkedForm {
                return L10n.t("fan_teams_schedule_game", languageCode: languageCode)
            }
            return L10n.t("pickup_form_nav_edit", languageCode: languageCode)
        }
    }

    private var confirmationActionTitle: String {
        if mode.isCreate, isTeamLinkedForm {
            return teamSchedulePostActionTitle
        }
        return mode.isCreate
            ? L10n.t("pickup_form_post", languageCode: languageCode)
            : L10n.t("pickup_form_save", languageCode: languageCode)
    }

    private var teamSchedulePostActionTitle: String {
        if isAnnouncementForm {
            return L10n.t("team_announcement_post_action", languageCode: languageCode)
        }
        if teamEventPolicy.usesGenericDetailLabels {
            return L10n.t("team_schedule_post_event", languageCode: languageCode)
        }
        switch gameFormat {
        case .practice:
            return L10n.t("team_schedule_post_practice", languageCode: languageCode)
        case .tryout:
            return L10n.t("team_schedule_post_tryout", languageCode: languageCode)
        default:
            return L10n.t("team_schedule_post_game", languageCode: languageCode)
        }
    }

    private var moreOptionsSummaryLine: String {
        if isTeamLinkedForm {
            return L10n.t("team_schedule_more_options_subtitle", languageCode: languageCode)
        }
        return L10n.t("pickup_form_more_options_subtitle", languageCode: languageCode)
    }

    private var arrivalTimePayload: Date? {
        guard hasArrivalTime else { return nil }
        return VenueOwnerGameScheduleValidation.combinedLocalStart(
            gameDate: gameDate,
            gameStartTime: arrivalTime
        )
    }

    private var summarySportLabel: String {
        SportSubtypeCatalog.identityLine(
            sport: sport,
            subtype: sportSubtype,
            languageCode: languageCode
        )
    }

    private var availableSportSubtypes: [SportSubtypeCatalog.Subtype] {
        SportSubtypeCatalog.subtypes(forSport: sport)
    }

    private var showsSportSubtypePicker: Bool {
        !availableSportSubtypes.isEmpty && !isOrganizerPostStartManage
    }

    private var summarySportEmoji: String {
        SportFilterCatalog.resolve(sport).emoji
    }

    private var summaryFormatLabel: String {
        if isTeamLinkedForm {
            return FanTeamEventTypeCatalog.displayTitle(
                for: gameFormat,
                sport: sport,
                languageCode: languageCode
            )
        }
        return PickupEventTypeCatalog.displayTitle(
            for: gameFormat,
            sport: sport,
            languageCode: languageCode
        )
    }

    private var summaryFormatEmoji: String {
        gameFormat.scheduleFormSummaryEmoji
    }

    private var summaryVisibilityLabel: String {
        isPublicDiscover
            ? L10n.t("pickup_form_visibility_public", languageCode: languageCode)
            : L10n.t("pickup_form_visibility_private", languageCode: languageCode)
    }

    private var summaryVisibilitySystemImage: String {
        isPublicDiscover ? "globe" : "lock.fill"
    }

    private var hasAnyLocationInput: Bool {
        appliedPickupPlacePrefill != nil
            || hasValidMapPinLocation
            || !trimmedAddress.isEmpty
            || !trimmedCity.isEmpty
            || !trimmedState.isEmpty
    }

    private var summaryDateText: String {
        let cal = Calendar.current
        if cal.isDateInToday(gameDate) {
            return L10n.t("pickup_form_date_today", languageCode: languageCode)
        }
        if cal.isDateInTomorrow(gameDate) {
            return L10n.t("pickup_form_date_tomorrow", languageCode: languageCode)
        }
        return gameDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year(.defaultDigits))
    }

    private var summaryTimeRangeText: String {
        let start = gameTime.formatted(date: .omitted, time: .shortened)
        let end = endTime.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    private var summaryPlayersPrimary: String {
        if useMaxPlayers {
            return "\(playersNeeded) / \(maxPlayers)"
        }
        return "\(playersNeeded)"
    }

    private var summaryPlayersSecondary: String {
        L10n.t("pickup_form_summary_players", languageCode: languageCode)
    }

    private var summaryLocationPrimary: String {
        if let place = appliedPickupPlacePrefill {
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if !trimmedAddress.isEmpty {
            return trimmedAddress
        }
        return L10n.t("pickup_form_location_label", languageCode: languageCode)
    }

    private var summaryLocationSecondary: String {
        if appliedPickupPlacePrefill != nil || hasValidMapPinLocation || hasCompleteTypedAddress {
            let cityState = [trimmedCity, trimmedState].filter { !$0.isEmpty }.joined(separator: ", ")
            if !cityState.isEmpty { return cityState }
            if hasValidMapPinLocation {
                return L10n.t("pickup_form_location_pinned", languageCode: languageCode)
            }
            return L10n.t("pickup_form_location_set", languageCode: languageCode)
        }
        return L10n.t("pickup_form_location_tbd", languageCode: languageCode)
    }

    private var playersNeededCountText: String {
        if playersNeeded == 1 {
            return L10n.t("pickup_form_player_count_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("pickup_form_player_count_other_format", languageCode: languageCode),
            playersNeeded
        )
    }

    private var locationRowPrimaryLabel: String {
        if appliedPickupPlacePrefill != nil || hasValidMapPinLocation || !trimmedAddress.isEmpty {
            return summaryLocationPrimary
        }
        return L10n.t("pickup_form_choose_location", languageCode: languageCode)
    }

    private var locationRowTrailingText: String {
        if appliedPickupPlacePrefill != nil || hasValidMapPinLocation || !trimmedAddress.isEmpty {
            return L10n.t("pickup_form_change_location", languageCode: languageCode)
        }
        return L10n.t("pickup_form_select_location", languageCode: languageCode)
    }

    private var gameFormatFormSection: some View {
        PickupFormFieldRow(systemImage: gameFormat.systemImage, label: L10n.t("pickup_form_event_type", languageCode: languageCode)) {
            Menu {
                Picker(selection: $gameFormat) {
                    ForEach(availableGameFormats, id: \.self) { type in
                        Label(eventTypeDisplayTitle(for: type), systemImage: type.systemImage)
                            .tag(type)
                    }
                } label: {
                    EmptyView()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: gameFormat.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(formAccent)
                        .accessibilityHidden(true)
                    Text(eventTypeDisplayTitle(for: gameFormat))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(formAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(L10n.t("pickup_form_event_type", languageCode: languageCode))
            .accessibilityValue(eventTypeDisplayTitle(for: gameFormat))
        }
    }

    private var matchupHomeTeamName: String {
        let name = effectiveTeamCreationContext?.teamName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "—" : name
    }

    private var matchupOpponentDisplayValue: String {
        if let opp = FanTeamScheduleMatchup.trimmedOpponent(opponentName) {
            return opp
        }
        return L10n.t("pickup_form_add_opponent", languageCode: languageCode)
    }

    private var matchupOpponentFormSection: some View {
        Button {
            opponentEditorDraft = opponentName
            showOpponentEditor = true
        } label: {
            HStack(alignment: .center, spacing: FGSpacing.sm) {
                PickupFormIconBadge(systemImage: "shield.lefthalf.filled", accent: formAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("pickup_form_matchup", languageCode: languageCode))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(matchupHomeTeamName)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(L10n.t("fan_team_schedule_vs", languageCode: languageCode))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                        Text(matchupOpponentDisplayValue)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                FanTeamScheduleMatchup.trimmedOpponent(opponentName) == nil
                                    ? formAccent
                                    : FGColor.primaryText(colorScheme)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                Spacer(minLength: FGSpacing.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 10)
            .frame(minHeight: 44, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("pickup_form_opponent", languageCode: languageCode))
        .accessibilityValue(matchupOpponentDisplayValue)
        .accessibilityHint(L10n.t("pickup_form_add_opponent", languageCode: languageCode))
    }

    private var opponentEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.t("pickup_form_opponent", languageCode: languageCode),
                        text: $opponentEditorDraft
                    )
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                    .submitLabel(.done)
                } footer: {
                    Text(L10n.t("pickup_form_opponent_footer", languageCode: languageCode))
                        .font(.footnote)
                }
            }
            .navigationTitle(L10n.t("pickup_form_opponent", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("pickup_form_cancel", languageCode: languageCode)) {
                        showOpponentEditor = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        opponentName = opponentEditorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        showOpponentEditor = false
                        refreshTeamScheduleSuggestedTitleIfNeeded()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var ageRangeSummary: String {
        PickupGameAgeRangeFormatter.ageRangeText(
            min: specifyAgeRange ? minimumAge : nil,
            max: specifyAgeRange && !noMaximumAge ? maximumAge : nil
        ) ?? "No age restriction"
    }

    private func applySuggestedAgeRange(for preference: PickupParticipantPreference) {
        guard specifyAgeRange else { return }
        switch preference {
        case .kids_only:
            minimumAge = 8
            maximumAge = 12
            noMaximumAge = false
        case .teens_welcome:
            minimumAge = 13
            maximumAge = 17
            noMaximumAge = false
        case .adults_only:
            minimumAge = 18
            noMaximumAge = true
        case .seniors_welcome:
            minimumAge = 55
            noMaximumAge = true
        case .everyone, .women_only, .men_only:
            minimumAge = 18
            noMaximumAge = true
        }
    }

    private func normalizedAgeRangePayload() -> (min: Int?, max: Int?) {
        guard specifyAgeRange else { return (nil, nil) }
        return PickupGameAgeRangeFormatter.normalized(
            min: minimumAge,
            max: noMaximumAge ? nil : maximumAge
        )
    }

    private var ageRangeControls: some View {
        Group {
            Toggle(L10n.t("pickup_specify_age_range", languageCode: languageCode), isOn: $specifyAgeRange)
                .onChange(of: specifyAgeRange) { _, isEnabled in
                    if isEnabled {
                        applySuggestedAgeRange(for: participantPreference)
                    }
                }

            if specifyAgeRange {
                Stepper(value: $minimumAge, in: PickupGameAgeRangeFormatter.minimumAllowedAge...PickupGameAgeRangeFormatter.maximumAllowedAge) {
                    LabeledContent("Minimum age", value: "\(minimumAge)")
                }
                Toggle("No maximum age", isOn: $noMaximumAge)
                    .onChange(of: noMaximumAge) { _, isOpenEnded in
                        if !isOpenEnded, maximumAge < minimumAge {
                            maximumAge = minimumAge
                        }
                    }
                if !noMaximumAge {
                    Stepper(value: $maximumAge, in: PickupGameAgeRangeFormatter.minimumAllowedAge...PickupGameAgeRangeFormatter.maximumAllowedAge) {
                        LabeledContent("Maximum age", value: "\(maximumAge)")
                    }
                    .onChange(of: minimumAge) { _, newValue in
                        if maximumAge < newValue {
                            maximumAge = newValue
                        }
                    }
                    .onChange(of: maximumAge) { _, newValue in
                        if newValue < minimumAge {
                            maximumAge = minimumAge
                        }
                    }
                }
                Text(ageRangeSummary)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
    }

    private var manualPickupGameForm: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let errorText, !errorText.isEmpty {
                        Text(errorText)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.dangerRed)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(FGSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FGColor.dangerRed.opacity(0.10), in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                            .id("teamScheduleValidationBanner")
                    }

                    if isOrganizerPostStartManage {
                        Text(
                            L10n.t("pickup_form_post_start_locked_notice", languageCode: languageCode)
                        )
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(FGSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                    }

                    if showsCreateIntro {
                        pickupFormIntroRow
                    }
                    if showsLiveSummary {
                        pickupFormLiveSummaryCard
                    }

                    if usesTeamScheduleProgressiveLayout {
                        teamScheduleProgressiveManualContent
                    } else {
                        // Natural order: What → When → Where → Who → How → Extra.
                        pickupFormGameSection
                        pickupFormWhenSection

                        if !isOrganizerPostStartManage {
                            pickupFormWhereSection
                        } else {
                            pickupFormWhereLockedSection
                        }

                        if isTeamLinkedForm {
                            pickupFormTeamPlayersSection
                        } else {
                            pickupFormPlayersSection
                        }

                        if !isOrganizerPostStartManage {
                            if teamEventPolicy.showsHowYouPlay {
                                pickupFormHowYouPlaySection
                            }
                            if teamEventPolicy.isGameplayEvent {
                                pickupFormPollPermissionsSection
                            }
                            pickupFormDescriptionSection
                            if teamEventPolicy.isGameplayEvent {
                                pickupFormSafetySection
                                pickupFormCostSection
                            }
                        } else {
                            pickupFormDetailsLockedSection
                        }

                        if let postReadinessMessage {
                            Text(postReadinessMessage)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(formAccent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(postReadinessMessage)
                        }
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.sm)
                .padding(.bottom, FGSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isTitleFieldFocused) { _, focused in
                guard focused else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("pickupFormTitleField", anchor: .center)
                }
            }
            .onChange(of: teamScheduleValidationAnchor) { _, anchor in
                guard let anchor else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(anchor, anchor: .center)
                }
                teamScheduleValidationAnchor = nil
            }
        }
        .fanGeoScreenBackground()
        .sheet(isPresented: $showSportPicker) {
            GroupedSportPickerSheet(
                selectedSportToken: sport.trimmingCharacters(in: .whitespacesAndNewlines),
                navigationTitle: L10n.t("pickup_form_sport_label", languageCode: languageCode),
                showsSearch: true,
                showsToolbarDone: true,
                onSelectSport: { sport = $0 }
            )
        }
        .sheet(isPresented: $showOpponentEditor) {
            opponentEditorSheet
        }
        .sheet(isPresented: $showTeamMoreOptions) {
            teamScheduleMoreOptionsSheet
        }
        .sheet(isPresented: $showTeamTimeEditor) {
            teamScheduleTimeEditorSheet
        }
        .onChange(of: sport) { _, newSport in
            sportSubtype = SportSubtypeCatalog.ensuringValidSelection(sportSubtype, sport: newSport)
            refreshPickupSuggestedTitleIfNeeded()
            guard usesTeamScheduleProgressiveLayout else { return }
            if isTeamLinkedForm {
                let canAnnounce = effectiveTeamCreationContext?.canPublishAnnouncements == true
                    || (creationContext.team?.canPublishAnnouncements == true)
                let next = FanTeamEventTypeCatalog.ensuringValidSelection(
                    gameFormat,
                    sport: newSport,
                    canPublishAnnouncements: canAnnounce
                )
                if next != gameFormat {
                    gameFormat = next
                }
            } else {
                let next = PickupEventTypeCatalog.ensuringValidSelection(gameFormat, sport: newSport)
                if next != gameFormat {
                    gameFormat = next
                }
            }
        }
        .onChange(of: opponentName) { _, _ in
            refreshTeamScheduleSuggestedTitleIfNeeded()
        }
        .onChange(of: gameFormat) { _, _ in
            refreshTeamScheduleSuggestedTitleIfNeeded()
            if usesTeamScheduleProgressiveLayout, isTeamLinkedForm {
                let policy = FanTeamEventPresentation.policy(for: gameFormat, sport: sport)
                if !policy.allowsTeamOutsideRecruitment {
                    // Recruiting is format-gated; Public/Private stays independent.
                    needsAdditionalPlayers = false
                    let inactive = PickupTeamOutsideRecruiting.inactivePersistence()
                    playersNeeded = inactive.playersNeeded
                    useMaxPlayers = false
                    maxPlayers = inactive.maxPlayers ?? maxPlayers
                }
                if !policy.requiresOpponent {
                    opponentName = ""
                }
            }
        }
        .onChange(of: title) { _, newValue in
            guard usesTeamScheduleProgressiveLayout, isTeamLinkedForm else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let auto = lastAutoSuggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == auto {
                titleManuallyCustomized = false
            } else {
                titleManuallyCustomized = true
            }
        }
    }

    @ViewBuilder
    private var teamScheduleProgressiveManualContent: some View {
        if isAnnouncementForm {
            teamScheduleAnnouncementProgressiveContent
        } else {
            teamScheduleGameDetailsSection
                .id("teamScheduleGameDetails")

            teamScheduleWhenSection
                .id("teamScheduleWhen")

            teamScheduleWhereSection
                .id("teamScheduleWhere")

            if !isTeamLinkedForm {
                pickupProgressivePlayersSection
                    .id("pickupProgressivePlayers")
            }

            teamScheduleMoreOptionsRow
                .id("teamScheduleMoreOptions")

            if requiresPickupSafetyAcknowledgment {
                pickupFormSafetySection
            } else if usesTeamOnlySafetyNote {
                teamSchedulePrivacyFooter
            }

            teamSchedulePostButton

            if let postReadinessMessage {
                Text(postReadinessMessage)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(formAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(postReadinessMessage)
                    .id("teamScheduleReadiness")
            }
        }
    }

    private var pickupProgressivePlayersSection: some View {
        TeamScheduleFormSectionCard(title: progressivePlayersSectionTitle) {
            playersNeededStepperRows
            PickupFormRowDivider()
            maxPlayersToggleRows
        }
        .animation(.easeInOut(duration: 0.2), value: useMaxPlayers)
        .animation(.easeInOut(duration: 0.2), value: usesParticipantAudienceWording)
    }

    /// Announcement create/edit: title + message only (date defaults to now; no game fields).
    @ViewBuilder
    private var teamScheduleAnnouncementProgressiveContent: some View {
        TeamScheduleFormSectionCard(title: L10n.t("team_announcement_form_section", languageCode: languageCode)) {
            if shouldShowGameFormatPicker {
                teamScheduleFormatRow
                PickupFormRowDivider()
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: FGSpacing.sm) {
                    PickupFormIconBadge(systemImage: "megaphone.fill", accent: formAccent)
                    Text(L10n.t("team_announcement_title_label", languageCode: languageCode))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: FGSpacing.sm)
                    TextField(
                        L10n.t("team_announcement_title_placeholder", languageCode: languageCode),
                        text: $title
                    )
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(formAccent)
                    .focused($isTitleFieldFocused)
                    .id("pickupFormTitleField")
                    .accessibilityLabel(L10n.t("team_announcement_title_label", languageCode: languageCode))
                    .accessibilityHint(L10n.t("team_announcement_title_placeholder", languageCode: languageCode))
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
            }
            .id("teamScheduleTitle")

            PickupFormRowDivider()

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(spacing: FGSpacing.sm) {
                    PickupFormIconBadge(systemImage: "text.alignleft", accent: formAccent)
                    Text(L10n.t("team_announcement_message_label", languageCode: languageCode))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: 0)
                }
                TextField(
                    L10n.t("team_announcement_message_placeholder", languageCode: languageCode),
                    text: $description,
                    axis: .vertical
                )
                .lineLimit(4...12)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .accessibilityLabel(L10n.t("team_announcement_message_label", languageCode: languageCode))
                .accessibilityHint(L10n.t("team_announcement_message_placeholder", languageCode: languageCode))
            }
            .padding(FGSpacing.md)
            .id("teamScheduleAnnouncementMessage")
        }

        teamSchedulePostButton

        if let postReadinessMessage {
            Text(postReadinessMessage)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(formAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(postReadinessMessage)
                .id("teamScheduleReadiness")
        }
    }

    private var teamScheduleGameDetailsSection: some View {
        TeamScheduleFormSectionCard(title: progressiveDetailsSectionTitle) {
            // Title
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: FGSpacing.sm) {
                    PickupFormIconBadge(systemImage: "pencil", accent: formAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("pickup_form_title_label", languageCode: languageCode))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(L10n.t("team_schedule_title_subtitle", languageCode: languageCode))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    Spacer(minLength: FGSpacing.sm)
                    TextField(
                        L10n.t("pickup_form_title_placeholder", languageCode: languageCode),
                        text: $title
                    )
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(formAccent)
                    .focused($isTitleFieldFocused)
                    .id("pickupFormTitleField")
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
            }
            .id("teamScheduleTitle")

            if PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: isTeamLinkedForm) {
                PickupFormRowDivider()
                teamScheduleVisibilityRow
                    .id("teamScheduleVisibility")
            }

            PickupFormRowDivider()

            // Sport
            Button {
                showSportPicker = true
            } label: {
                TeamScheduleSubtitleRow(
                    systemImage: "sportscourt.fill",
                    accent: formAccent,
                    label: L10n.t("pickup_form_sport_label", languageCode: languageCode),
                    subtitle: L10n.t("team_schedule_sport_subtitle", languageCode: languageCode),
                    value: {
                        let emoji = summarySportEmoji
                        return emoji.isEmpty ? summarySportLabel : "\(emoji) \(summarySportLabel)"
                    }(),
                    valueIsPlaceholder: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(L10n.t("pickup_form_sport_label", languageCode: languageCode)), \(summarySportLabel)"
            )

            if showsSportSubtypePicker {
                PickupFormRowDivider()
                sportSubtypeFormRow
                    .id("teamScheduleSportSubtype")
            }

            if shouldShowGameFormatPicker {
                PickupFormRowDivider()
                teamScheduleFormatRow
            }

            if teamEventPolicy.showsOpponentField {
                PickupFormRowDivider()
                matchupOpponentFormSection
                    .id("teamScheduleMatchup")
            }
        }
    }

    private var teamScheduleFormatRow: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            PickupFormIconBadge(systemImage: "trophy.fill", accent: formAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("pickup_form_event_type", languageCode: languageCode))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t("pickup_form_event_type_subtitle", languageCode: languageCode))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            Spacer(minLength: FGSpacing.sm)
            Menu {
                ForEach(availableGameFormats, id: \.self) { format in
                    Button {
                        gameFormat = format
                    } label: {
                        Label(
                            eventTypeDisplayTitle(for: format),
                            systemImage: format.systemImage
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(eventTypeDisplayTitle(for: gameFormat))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(formAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            .accessibilityLabel(L10n.t("pickup_form_event_type", languageCode: languageCode))
            .accessibilityValue(eventTypeDisplayTitle(for: gameFormat))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .id("teamScheduleFormat")
    }

    /// Compact settings-style Visibility row for Team Schedule only.
    private var teamScheduleVisibilityRow: some View {
        let segmented = GameOnSegmentedControl(
            tabs: [
                GameOnSegmentedTab(
                    id: true,
                    title: L10n.t("pickup_form_visibility_public", languageCode: languageCode),
                    systemImage: "globe",
                    tint: formAccent,
                    accessibilityLabel: L10n.t("pickup_form_visibility_public", languageCode: languageCode)
                ),
                GameOnSegmentedTab(
                    id: false,
                    title: L10n.t("pickup_form_visibility_private", languageCode: languageCode),
                    systemImage: "lock.fill",
                    tint: formAccent,
                    accessibilityLabel: L10n.t("pickup_form_visibility_private", languageCode: languageCode)
                ),
            ],
            selection: $isPublicDiscover,
            accent: formAccent,
            fillsWidth: false,
            titleMinimumScaleFactor: 0.72,
            tabHorizontalPadding: 6,
            isCompact: true
        )
        .layoutPriority(1)
        .accessibilityLabel(L10n.t("pickup_form_visibility", languageCode: languageCode))
        .accessibilityValue(
            isPublicDiscover
                ? L10n.t("pickup_form_visibility_public", languageCode: languageCode)
                : L10n.t("pickup_form_visibility_private", languageCode: languageCode)
        )

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: FGSpacing.sm) {
                teamScheduleVisibilityLabel
                Spacer(minLength: FGSpacing.sm)
                segmented
                    .frame(maxWidth: 220)
            }

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                teamScheduleVisibilityLabel
                segmented
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 44, alignment: .center)
    }

    private var teamScheduleVisibilityLabel: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            PickupFormIconBadge(
                systemImage: isPublicDiscover ? "globe" : "lock.fill",
                accent: formAccent
            )
            Text(L10n.t("pickup_form_visibility", languageCode: languageCode))
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
        }
        .accessibilityHidden(true)
    }

    private var teamScheduleWhenSection: some View {
        TeamScheduleFormSectionCard(title: L10n.t("pickup_form_section_when", languageCode: languageCode)) {
            Button {
                showGameDatePopover = true
            } label: {
                TeamScheduleSubtitleRow(
                    systemImage: "calendar",
                    accent: formAccent,
                    label: L10n.t("pickup_form_date_label", languageCode: languageCode),
                    subtitle: L10n.t(
                        isTeamLinkedForm
                            ? "team_schedule_date_subtitle_event"
                            : "team_schedule_date_subtitle",
                        languageCode: languageCode
                    ),
                    value: summaryDateText
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showGameDatePopover) {
                pickupGameDatePopover
            }
            .accessibilityLabel(
                "\(L10n.t("pickup_form_date_label", languageCode: languageCode)), \(summaryDateText)"
            )

            PickupFormRowDivider()

            Button {
                showTeamTimeEditor = true
            } label: {
                TeamScheduleSubtitleRow(
                    systemImage: "clock.fill",
                    accent: formAccent,
                    label: L10n.t("team_schedule_time_label", languageCode: languageCode),
                    subtitle: L10n.t("team_schedule_time_subtitle", languageCode: languageCode),
                    value: summaryTimeRangeText.replacingOccurrences(of: "–", with: " – ")
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(L10n.t("team_schedule_time_label", languageCode: languageCode)), \(summaryTimeRangeText)"
            )
            .id("teamScheduleTime")
        }
    }

    private var teamScheduleWhereSection: some View {
        TeamScheduleFormSectionCard(title: L10n.t("pickup_form_section_where", languageCode: languageCode)) {
            Button {
                openTeamScheduleLocationPicker()
            } label: {
                TeamScheduleSubtitleRow(
                    systemImage: "mappin.and.ellipse",
                    accent: formAccent,
                    label: L10n.t("pickup_form_location_label", languageCode: languageCode),
                    subtitle: L10n.t(
                        isTeamLinkedForm
                            ? "team_schedule_location_subtitle_event"
                            : "team_schedule_location_subtitle",
                        languageCode: languageCode
                    ),
                    value: hasAnyLocationInput
                        ? summaryLocationPrimary
                        : L10n.t("pickup_form_choose_location", languageCode: languageCode),
                    valueIsPlaceholder: !hasAnyLocationInput
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(L10n.t("pickup_form_location_label", languageCode: languageCode)), \(hasAnyLocationInput ? summaryLocationPrimary : L10n.t("pickup_form_choose_location", languageCode: languageCode))"
            )
            .id("teamScheduleLocation")

            if let coordinate = teamScheduleMapPreviewCoordinate {
                teamScheduleLocationMapPreview(coordinate: coordinate)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, FGSpacing.sm)
            }

            if hasAnyLocationInput, let foot = locationGuidanceFootnote {
                Text(foot)
                    .font(FGTypography.caption)
                    .foregroundStyle(hasValidMapPinLocation ? FGColor.accentBlue : FGColor.accentYellow)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, FGSpacing.sm)
            }
        }
    }

    /// Compact preview under Location — Team Schedule progressive layout only.
    /// Reuses draft coordinates already on the form (map pin / address preview). No geocode.
    private var teamScheduleMapPreviewCoordinate: CLLocationCoordinate2D? {
        guard usesTeamScheduleProgressiveLayout else { return nil }
        guard let preview = pickupLocationPreview else { return nil }
        let coordinate = preview.coordinate
        guard Self.isValidTeamScheduleMapPreviewCoordinate(coordinate) else { return nil }
        return coordinate
    }

    private static func isValidTeamScheduleMapPreviewCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard isValidPickupCoordinate(coordinate) else { return false }
        // Match FanGeo Team location policy: Null Island is not a real pin.
        if coordinate.latitude == 0, coordinate.longitude == 0 { return false }
        return coordinate.latitude.isFinite && coordinate.longitude.isFinite
    }

    private func openTeamScheduleLocationPicker() {
        if effectiveTeamCreationContext != nil {
            showTeamChooseLocationPicker = true
        } else {
            showPickupMapLocationPicker = true
        }
    }

    private func teamScheduleLocationMapPreview(coordinate: CLLocationCoordinate2D) -> some View {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
        let addressLabel = summaryLocationPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
        let a11yLabel: String = {
            if addressLabel.isEmpty {
                return L10n.t("team_schedule_map_preview_a11y_fallback", languageCode: languageCode)
            }
            return String(
                format: L10n.t("team_schedule_map_preview_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                addressLabel
            )
        }()

        return Button {
            openTeamScheduleLocationPicker()
        } label: {
            Map(initialPosition: .region(region), interactionModes: []) {
                Marker(addressLabel.isEmpty ? " " : addressLabel, coordinate: coordinate)
                    .tint(formAccent)
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 136)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(formAccent.opacity(0.28), lineWidth: 1)
            }
            // Remount when the draft pin moves so the camera/pin stay in sync.
            .id("teamScheduleMapPreview-\(coordinate.latitude)-\(coordinate.longitude)")
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint(L10n.t("team_schedule_map_preview_a11y_hint", languageCode: languageCode))
        .accessibilityAddTraits(.isButton)
    }

    private var teamScheduleMoreOptionsRow: some View {
        Button {
            showTeamMoreOptions = true
        } label: {
            TeamScheduleSubtitleRow(
                systemImage: "gearshape.fill",
                accent: formAccent,
                label: L10n.t("team_schedule_more_options", languageCode: languageCode),
                subtitle: moreOptionsSummaryLine,
                value: "",
                valueIsPlaceholder: true
            )
        }
        .buttonStyle(.plain)
        .background(
            FGAdaptiveSurface.cardElevated,
            in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.4), lineWidth: 0.5)
        }
        .softCardShadow()
        .accessibilityHint(moreOptionsSummaryLine)
    }

    private var teamSchedulePostButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 10) {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: isAnnouncementForm ? "megaphone.fill" : "calendar.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(mode.isCreate ? confirmationActionTitle : L10n.t("pickup_form_save", languageCode: languageCode))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(formAccent.opacity(canSubmitPickupForm ? 1 : 0.45), in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmitPickupForm)
        .accessibilityLabel(mode.isCreate ? confirmationActionTitle : L10n.t("pickup_form_save", languageCode: languageCode))
    }

    private var teamSchedulePrivacyFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(visibilityHelpText)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var teamScheduleTimeEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        L10n.t("pickup_form_starts_label", languageCode: languageCode),
                        selection: startTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .tint(formAccent)
                    DatePicker(
                        L10n.t("pickup_form_ends_label", languageCode: languageCode),
                        selection: endTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .tint(formAccent)
                } footer: {
                    Text(L10n.t("team_schedule_time_editor_footer", languageCode: languageCode))
                }
            }
            .navigationTitle(L10n.t("team_schedule_time_label", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        showTeamTimeEditor = false
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(formAccent)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var teamScheduleMoreOptionsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TeamScheduleFormSectionCard(title: L10n.t("team_schedule_more_options", languageCode: languageCode)) {
                        // Description
                        NavigationLink {
                            Form {
                                Section {
                                    TextField(
                                        L10n.t("pickup_form_description_placeholder", languageCode: languageCode),
                                        text: $description,
                                        axis: .vertical
                                    )
                                    .lineLimit(5...16)
                                } footer: {
                                    Text(L10n.t("pickup_form_description_helper", languageCode: languageCode))
                                }
                            }
                            .navigationTitle(L10n.t("pickup_form_description", languageCode: languageCode))
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            TeamScheduleSubtitleRow(
                                systemImage: "list.clipboard",
                                accent: formAccent,
                                label: L10n.t("pickup_form_description", languageCode: languageCode),
                                subtitle: L10n.t("team_schedule_description_subtitle", languageCode: languageCode),
                                value: {
                                    let t = description.trimmingCharacters(in: .whitespacesAndNewlines)
                                    return t.isEmpty
                                        ? L10n.t("team_schedule_add", languageCode: languageCode)
                                        : t
                                }(),
                                valueIsPlaceholder: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                        .buttonStyle(.plain)

                        PickupFormRowDivider()

                        // Arrival time (optional metadata; Team + Pickup)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .center, spacing: FGSpacing.sm) {
                                PickupFormIconBadge(systemImage: "alarm", accent: formAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.t("team_schedule_arrival_time", languageCode: languageCode))
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                    Text(L10n.t("team_schedule_arrival_time_subtitle", languageCode: languageCode))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                                Spacer(minLength: FGSpacing.sm)
                                Toggle("", isOn: $hasArrivalTime)
                                    .labelsHidden()
                                    .tint(formAccent)
                                Text(
                                    hasArrivalTime
                                        ? arrivalTime.formatted(date: .omitted, time: .shortened)
                                        : L10n.t("team_schedule_arrival_none", languageCode: languageCode)
                                )
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(hasArrivalTime ? FGColor.secondaryText(colorScheme) : formAccent)
                            }
                            .padding(.horizontal, FGSpacing.md)
                            .padding(.vertical, 10)
                            .frame(minHeight: 44)

                            if hasArrivalTime {
                                DatePicker(
                                    "",
                                    selection: $arrivalTime,
                                    displayedComponents: .hourAndMinute
                                )
                                .labelsHidden()
                                .tint(formAccent)
                                .padding(.horizontal, FGSpacing.md)
                                .padding(.bottom, FGSpacing.sm)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: hasArrivalTime)

                        if teamEventPolicy.showsHowYouPlay {
                            PickupFormRowDivider()
                            PickupFormSelectionFieldRow(
                                systemImage: "building.2.fill",
                                accent: formAccent,
                                label: L10n.t("pickup_form_indoor_outdoor", languageCode: languageCode),
                                valueText: playEnvironment.displayTitle(languageCode: languageCode)
                            ) {
                                Picker(selection: $playEnvironment) {
                                    ForEach(PickupPlayEnvironment.allCases) { env in
                                        Text(env.displayTitle(languageCode: languageCode)).tag(env)
                                    }
                                } label: {
                                    EmptyView()
                                }
                            }
                        }

                        if !isTeamLinkedForm, teamEventPolicy.showsHowYouPlay {
                            // Standalone Pickup: skill / welcome / age always under More Options.
                            PickupFormRowDivider()
                            PickupFormSelectionFieldRow(
                                systemImage: "chart.bar.fill",
                                accent: formAccent,
                                label: L10n.t("pickup_form_skill_level", languageCode: languageCode),
                                valueText: skillLevel.displayTitle(languageCode: languageCode)
                            ) {
                                Picker(selection: $skillLevel) {
                                    ForEach(PickupGameSkillLevel.allCases) { level in
                                        Text(level.displayTitle(languageCode: languageCode)).tag(level)
                                    }
                                } label: {
                                    EmptyView()
                                }
                            }
                            PickupFormRowDivider()
                            PickupFormSelectionFieldRow(
                                systemImage: "person.2.fill",
                                accent: formAccent,
                                label: L10n.t("pickup_form_whos_welcome", languageCode: languageCode),
                                valueText: participantPreference.displayTitle(languageCode: languageCode)
                            ) {
                                Picker(selection: $participantPreference) {
                                    ForEach(PickupParticipantPreference.allCases) { pref in
                                        Text(pref.displayTitle(languageCode: languageCode)).tag(pref)
                                    }
                                } label: {
                                    EmptyView()
                                }
                            }
                            PickupFormRowDivider()
                            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                                ageRangeControls
                            }
                            .padding(FGSpacing.md)
                        } else if teamEventPolicy.allowsTeamOutsideRecruitment {
                            PickupFormRowDivider()
                            PickupFormFieldRow(
                                systemImage: "person.badge.plus",
                                accent: formAccent,
                                label: L10n.t("pickup_form_need_additional_players", languageCode: languageCode)
                            ) {
                                Toggle("", isOn: $needsAdditionalPlayers)
                                    .labelsHidden()
                                    .tint(formAccent)
                                    .accessibilityLabel(L10n.t("pickup_form_need_additional_players", languageCode: languageCode))
                            }

                            if needsAdditionalPlayers {
                                PickupFormRowDivider()
                                playersNeededStepperRows
                                PickupFormRowDivider()
                                maxPlayersToggleRows
                                PickupFormRowDivider()
                                PickupFormSelectionFieldRow(
                                    systemImage: "chart.bar.fill",
                                    accent: formAccent,
                                    label: L10n.t("pickup_form_skill_level", languageCode: languageCode),
                                    valueText: skillLevel.displayTitle(languageCode: languageCode)
                                ) {
                                    Picker(selection: $skillLevel) {
                                        ForEach(PickupGameSkillLevel.allCases) { level in
                                            Text(level.displayTitle(languageCode: languageCode)).tag(level)
                                        }
                                    } label: {
                                        EmptyView()
                                    }
                                }
                                PickupFormRowDivider()
                                PickupFormSelectionFieldRow(
                                    systemImage: "person.2.fill",
                                    accent: formAccent,
                                    label: L10n.t("pickup_form_whos_welcome", languageCode: languageCode),
                                    valueText: participantPreference.displayTitle(languageCode: languageCode)
                                ) {
                                    Picker(selection: $participantPreference) {
                                        ForEach(PickupParticipantPreference.allCases) { pref in
                                            Text(pref.displayTitle(languageCode: languageCode)).tag(pref)
                                        }
                                    } label: {
                                        EmptyView()
                                    }
                                }
                                PickupFormRowDivider()
                                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                                    ageRangeControls
                                }
                                .padding(FGSpacing.md)
                            }
                        }

                        if teamEventPolicy.showsCompetitionLevel {
                            PickupFormRowDivider()
                            pickupFormCompetitionLevelRow
                        }

                        if !isTeamLinkedForm, teamEventPolicy.isGameplayEvent {
                            PickupFormRowDivider()
                            pickupProgressivePollPermissionsRows
                        }

                        if teamEventPolicy.isGameplayEvent {
                            PickupFormRowDivider()
                            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                                Text(L10n.t("pickup_form_cost", languageCode: languageCode))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                GameOnSegmentedControl(
                                    tabs: PickupCostKind.allCases.map { kind in
                                        GameOnSegmentedTab(
                                            id: kind,
                                            title: kind.title(languageCode: languageCode),
                                            tint: formAccent
                                        )
                                    },
                                    selection: $costKind,
                                    accent: formAccent,
                                    titleMinimumScaleFactor: 0.85
                                )
                                if costKind == .paid {
                                    TextField(L10n.t("pickup_form_amount_usd", languageCode: languageCode), text: $entryFeeText)
                                        .keyboardType(.decimalPad)
                                    Text(L10n.t("pickup_form_paid_fee_hint", languageCode: languageCode))
                                        .font(FGTypography.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                            }
                            .padding(FGSpacing.md)
                        }
                    }

                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(formAccent)
                            .accessibilityHidden(true)
                        Text(L10n.t("pickup_form_auto_delete_notice", languageCode: languageCode))
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(FGSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        formAccent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                        in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    )
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.sm)
                .padding(.bottom, FGSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("team_schedule_more_options", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showTeamMoreOptions = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(formAccent)
                    }
                    .accessibilityLabel(L10n.t("pickup_form_cancel", languageCode: languageCode))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        showTeamMoreOptions = false
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(formAccent)
                }
            }
            .onChange(of: needsAdditionalPlayers) { _, enabled in
                if enabled, playersNeeded <= PickupTeamOutsideRecruiting.inactivePlayersNeededFloor {
                    playersNeeded = 2
                }
                // Recruiting is independent of Public/Private — do not snap visibility.
            }
        }
    }

    private func refreshPickupSuggestedTitleIfNeeded() {
        guard !isTeamLinkedForm else { return }
        guard SportSubtypeCatalog.hasSubtypes(forSport: sport) else { return }
        guard let suggested = SportSubtypeCatalog.suggestedTitle(
            sport: sport,
            subtype: sportSubtype,
            languageCode: languageCode
        ) else { return }
        guard TeamScheduleTitleSuggestion.shouldReplaceTitle(
            currentTitle: title,
            lastAutoSuggested: lastAutoSuggestedTitle
        ) else { return }
        title = suggested
        lastAutoSuggestedTitle = suggested
    }

    @ViewBuilder
    private var sportSubtypeFormRow: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            PickupFormIconBadge(systemImage: "slider.horizontal.3", accent: formAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(SportSubtypeCatalog.pickerTitle(forSport: sport, languageCode: languageCode))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            Spacer(minLength: FGSpacing.sm)
            Menu {
                ForEach(availableSportSubtypes) { option in
                    Button {
                        sportSubtype = option.id
                        refreshPickupSuggestedTitleIfNeeded()
                    } label: {
                        Label(
                            L10n.t(option.labelKey, languageCode: languageCode),
                            systemImage: option.systemImage
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(
                        SportSubtypeCatalog.displayLabel(
                            forSubtype: sportSubtype ?? "",
                            sport: sport,
                            languageCode: languageCode
                        )
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(formAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            .accessibilityLabel(SportSubtypeCatalog.pickerTitle(forSport: sport, languageCode: languageCode))
            .accessibilityValue(
                SportSubtypeCatalog.displayLabel(
                    forSubtype: sportSubtype ?? "",
                    sport: sport,
                    languageCode: languageCode
                )
            )
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    private func refreshTeamScheduleSuggestedTitleIfNeeded() {
        guard usesTeamScheduleProgressiveLayout, isTeamLinkedForm else { return }
        guard let suggested = TeamScheduleTitleSuggestion.suggestedTitle(
            homeTeamName: matchupHomeTeamName == "—" ? (effectiveTeamCreationContext?.teamName ?? "") : matchupHomeTeamName,
            opponentName: opponentName,
            format: gameFormat,
            languageCode: languageCode
        ) else { return }
        guard TeamScheduleTitleSuggestion.shouldReplaceTitle(
            currentTitle: title,
            lastAutoSuggested: lastAutoSuggestedTitle
        ) || (!titleManuallyCustomized && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (!titleManuallyCustomized && title == effectiveTeamCreationContext?.teamName)
        else { return }
        title = suggested
        lastAutoSuggestedTitle = suggested
        titleManuallyCustomized = false
    }

    private var pickupFormIntroRow: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            Image(systemName: gameFormat.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(FGColor.intentPlay, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(gameFormat.scheduleFormIntroTitle(languageCode: languageCode))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t("pickup_form_intro_subtitle", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(gameFormat.scheduleFormIntroTitle(languageCode: languageCode)). \(L10n.t("pickup_form_intro_subtitle", languageCode: languageCode))"
        )
    }

    /// Team → Schedule Game only: compact identity before Manual | CSV.
    @ViewBuilder
    private var pickupFormTeamIdentityCard: some View {
        if let team = creationContext.team {
            let meta = team.scheduleHeaderMetaLine(languageCode: languageCode)
            HStack(alignment: .center, spacing: 12) {
                FanTeamMarkView(
                    sport: team.teamSport,
                    logoURL: team.logoURL,
                    logoThumbnailURL: team.logoThumbnailURL,
                    colorHex: team.colorHex,
                    size: 44,
                    preferDetailURL: false
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(team.teamName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)

                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(formAccent.opacity(colorScheme == .dark ? 0.95 : 0.9))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                FGAdaptiveSurface.cardElevated,
                in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(formAccent.opacity(colorScheme == .dark ? 0.35 : 0.22), lineWidth: 1)
            }
            .softCardShadow()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(team.scheduleHeaderAccessibilityLabel(languageCode: languageCode))
        }
    }

    private var pickupFormLiveSummaryCard: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(FGColor.intentPlay)
                .frame(width: 4)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: gameFormat.systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(FGColor.intentPlay)
                        .accessibilityHidden(true)
                    Text(summaryFormatLabel)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.intentPlay)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        pickupSummaryMetric(
                            emoji: summarySportEmoji.isEmpty ? nil : summarySportEmoji,
                            systemImage: summarySportEmoji.isEmpty ? "sportscourt.fill" : nil,
                            text: summarySportLabel
                        )
                        pickupSummaryMetric(systemImage: "calendar", text: summaryDateText)
                        pickupSummaryMetric(systemImage: "clock.fill", text: summaryTimeRangeText)
                        pickupSummaryMetric(systemImage: summaryVisibilitySystemImage, text: summaryVisibilityLabel)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            pickupSummaryMetric(
                                emoji: summarySportEmoji.isEmpty ? nil : summarySportEmoji,
                                systemImage: summarySportEmoji.isEmpty ? "sportscourt.fill" : nil,
                                text: summarySportLabel
                            )
                            pickupSummaryMetric(systemImage: "calendar", text: summaryDateText)
                        }
                        HStack(alignment: .top, spacing: 10) {
                            pickupSummaryMetric(systemImage: "clock.fill", text: summaryTimeRangeText)
                            pickupSummaryMetric(systemImage: summaryVisibilitySystemImage, text: summaryVisibilityLabel)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FGColor.intentPlay)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summaryLocationPrimary)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                        if summaryLocationSecondary != L10n.t("pickup_form_location_tbd", languageCode: languageCode) {
                            Text(summaryLocationSecondary)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.35), lineWidth: 0.5)
        }
        .softCardShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(summaryFormatLabel), \(summarySportLabel), \(summaryDateText), \(summaryTimeRangeText), \(summaryVisibilityLabel), \(summaryLocationPrimary), \(summaryLocationSecondary)"
        )
    }

    private func pickupSummaryMetric(
        emoji: String? = nil,
        systemImage: String? = nil,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 16))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FGColor.intentPlay)
                }
            }
            .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pickupFormGameSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_game", languageCode: languageCode)) {
            if isOrganizerPostStartManage {
                PickupFormFieldRow(systemImage: "pencil", label: L10n.t("pickup_form_title_label", languageCode: languageCode)) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                PickupFormRowDivider()
                PickupFormFieldRow(systemImage: "sportscourt.fill", label: L10n.t("pickup_form_sport_label", languageCode: languageCode)) {
                    SportSelectionValueView(sport: sport)
                }
            } else {
                PickupFormFieldRow(systemImage: "pencil", label: L10n.t("pickup_form_title_label", languageCode: languageCode)) {
                    TextField(
                        L10n.t("pickup_form_title_placeholder", languageCode: languageCode),
                        text: $title
                    )
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .focused($isTitleFieldFocused)
                    .id("pickupFormTitleField")
                }
                PickupFormRowDivider()
                Button {
                    showSportPicker = true
                } label: {
                    PickupFormFieldRow(
                        systemImage: "sportscourt.fill",
                        label: L10n.t("pickup_form_sport_label", languageCode: languageCode),
                        showsChevron: true
                    ) {
                        HStack(spacing: 6) {
                            if !summarySportEmoji.isEmpty {
                                Text(summarySportEmoji)
                                    .font(.system(size: 14))
                                    .accessibilityHidden(true)
                            }
                            Text(summarySportLabel)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(L10n.t("pickup_form_sport_label", languageCode: languageCode)), \(summarySportLabel)"
                )
                .accessibilityAddTraits(.isButton)
            }

            if showsSportSubtypePicker {
                PickupFormRowDivider()
                sportSubtypeFormRow
            }

            if PickupGameEditPrivacyPolicy.showsVisibilityControl(isTeamLinked: isTeamLinkedForm) {
                PickupFormRowDivider()
                pickupFormVisibilityRows
            }

            if shouldShowGameFormatPicker {
                PickupFormRowDivider()
                gameFormatFormSection
            }

            if isTeamLinkedForm,
               teamEventPolicy.showsOpponentField,
               !isOrganizerPostStartManage {
                PickupFormRowDivider()
                matchupOpponentFormSection
            }

            if !isOrganizerPostStartManage, teamEventPolicy.showsCompetitionLevel {
                PickupFormRowDivider()
                pickupFormCompetitionLevelRow
            }
        }
    }

    private var pickupFormWhenSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_when", languageCode: languageCode)) {
            if isOrganizerPostStartManage {
                PickupFormFieldRow(systemImage: "calendar", label: L10n.t("pickup_form_starts_label", languageCode: languageCode)) {
                    Text(lockedGameStartDisplay)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                PickupFormRowDivider()
                PickupFormFieldRow(systemImage: "clock", label: L10n.t("pickup_form_ends_label", languageCode: languageCode)) {
                    Text(lockedGameEndDisplay)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            } else {
                Button {
                    showGameDatePopover = true
                } label: {
                    PickupFormFieldRow(
                        systemImage: "calendar",
                        label: L10n.t("pickup_form_date_label", languageCode: languageCode),
                        showsChevron: true
                    ) {
                        Text(summaryDateText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showGameDatePopover) {
                    pickupGameDatePopover
                }
                .accessibilityLabel(
                    "\(L10n.t("pickup_form_date_label", languageCode: languageCode)), \(summaryDateText)"
                )

                PickupFormRowDivider()

                PickupFormFieldRow(systemImage: "clock", label: L10n.t("pickup_form_starts_label", languageCode: languageCode)) {
                    DatePicker(
                        "",
                        selection: startTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .tint(FGColor.intentPlay)
                }

                PickupFormRowDivider()

                PickupFormFieldRow(systemImage: "clock.fill", label: L10n.t("pickup_form_ends_label", languageCode: languageCode)) {
                    DatePicker(
                        "",
                        selection: endTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .tint(FGColor.intentPlay)
                }
            }
        }
    }

    private var pickupFormPlayersSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_players", languageCode: languageCode)) {
            playersNeededStepperRows
            PickupFormRowDivider()
            maxPlayersToggleRows
        }
        .animation(.easeInOut(duration: 0.2), value: useMaxPlayers)
    }

    /// Team Schedule Game / Team-linked edit: roster is the audience; optional outside recruiting via existing fields.
    private var pickupFormTeamPlayersSection: some View {
        let team = effectiveTeamCreationContext
        let memberCount = team?.activeMemberCount ?? 0
        let memberLine = String(
            format: L10n.t("pickup_form_team_active_members_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            memberCount
        )

        return PickupFormSectionCard(title: L10n.t("pickup_form_section_team_players", languageCode: languageCode)) {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(alignment: .center, spacing: 12) {
                    if let team {
                        FanTeamMarkView(
                            sport: team.teamSport,
                            logoURL: team.logoURL,
                            logoThumbnailURL: team.logoThumbnailURL,
                            colorHex: team.colorHex,
                            size: 40,
                            preferDetailURL: false
                        )
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team?.teamName ?? "")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                        Text(memberLine)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.intentPlay)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                Text(L10n.t("pickup_form_team_players_rsvp_help", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(FGSpacing.md)

            if teamEventPolicy.allowsTeamOutsideRecruitment {
                PickupFormRowDivider()

                PickupFormFieldRow(
                    systemImage: "person.badge.plus",
                    label: L10n.t("pickup_form_need_additional_players", languageCode: languageCode)
                ) {
                    Toggle("", isOn: $needsAdditionalPlayers)
                        .labelsHidden()
                        .tint(FGColor.intentPlay)
                        .accessibilityLabel(L10n.t("pickup_form_need_additional_players", languageCode: languageCode))
                }

                if needsAdditionalPlayers {
                    PickupFormRowDivider()
                    VStack(alignment: .leading, spacing: FGSpacing.sm) {
                        Text(L10n.t("pickup_form_section_additional_players", languageCode: languageCode))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(.horizontal, FGSpacing.md)
                            .padding(.top, FGSpacing.sm)
                        playersNeededStepperRows
                        PickupFormRowDivider()
                        maxPlayersToggleRows
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Text(L10n.t("pickup_form_team_event_rsvp_only_help", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, FGSpacing.md)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: needsAdditionalPlayers)
        .animation(.easeInOut(duration: 0.2), value: useMaxPlayers)
        .animation(.easeInOut(duration: 0.2), value: gameFormat)
        .onChange(of: needsAdditionalPlayers) { _, enabled in
            if enabled, playersNeeded <= PickupTeamOutsideRecruiting.inactivePlayersNeededFloor {
                playersNeeded = 2
            }
            // Recruiting is independent of Public/Private — do not snap visibility.
        }
        .onChange(of: gameFormat) { _, newFormat in
            let policy = FanTeamEventPresentation.policy(for: newFormat, sport: sport)
            if isTeamLinkedForm, !policy.allowsTeamOutsideRecruitment {
                needsAdditionalPlayers = false
                let inactive = PickupTeamOutsideRecruiting.inactivePersistence()
                playersNeeded = inactive.playersNeeded
                useMaxPlayers = false
                maxPlayers = inactive.maxPlayers ?? maxPlayers
            }
        }
    }

    @ViewBuilder
    private var playersNeededStepperRows: some View {
        PickupFormFieldRow(
            systemImage: "person.2.fill",
            accent: formAccent,
            label: playersNeededFieldLabel
        ) {
            HStack(spacing: 10) {
                Button {
                    playersNeeded = max(1, playersNeeded - 1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(playersNeeded <= 1 ? FGColor.mutedText(colorScheme) : FGColor.primaryText(colorScheme))
                        .frame(width: 32, height: 32)
                        .background(FGAdaptiveSurface.controlFill, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(playersNeeded <= 1)
                .accessibilityLabel(L10n.t("pickup_form_decrease_players", languageCode: languageCode))

                Text(playersNeededCountDisplayText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(minWidth: 72)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(playersNeededCountDisplayText)

                Button {
                    playersNeeded = min(20, playersNeeded + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(playersNeeded >= 20 ? FGColor.mutedText(colorScheme) : FGColor.primaryText(colorScheme))
                        .frame(width: 32, height: 32)
                        .background(FGAdaptiveSurface.controlFill, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(playersNeeded >= 20)
                .accessibilityLabel(L10n.t("pickup_form_increase_players", languageCode: languageCode))
            }
        }
    }

    @ViewBuilder
    private var maxPlayersToggleRows: some View {
        PickupFormFieldRow(
            systemImage: "person.3.fill",
            accent: formAccent,
            label: L10n.t("pickup_form_set_max_capacity", languageCode: languageCode)
        ) {
            Toggle("", isOn: $useMaxPlayers)
                .labelsHidden()
                .tint(formAccent)
                .accessibilityLabel(L10n.t("pickup_form_set_max_capacity", languageCode: languageCode))
        }

        if useMaxPlayers {
            PickupFormRowDivider()
            PickupFormFieldRow(
                systemImage: "number",
                accent: formAccent,
                label: maxPlayersFieldLabel
            ) {
                HStack(spacing: 8) {
                    Text("\(maxPlayers)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .monospacedDigit()
                    Stepper("", value: $maxPlayers, in: 1...100)
                        .labelsHidden()
                        .accessibilityLabel(maxPlayersFieldLabel)
                        .accessibilityValue("\(maxPlayers)")
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var pickupFormHowYouPlaySection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_how_you_play", languageCode: languageCode)) {
            PickupFormSelectionFieldRow(
                systemImage: "building.2.fill",
                label: L10n.t("pickup_form_indoor_outdoor", languageCode: languageCode),
                valueText: playEnvironment.displayTitle(languageCode: languageCode)
            ) {
                Picker(selection: $playEnvironment) {
                    ForEach(PickupPlayEnvironment.allCases) { env in
                        Text(env.displayTitle(languageCode: languageCode)).tag(env)
                    }
                } label: {
                    EmptyView()
                }
            }

            if showsTeamOutsideRecruitmentHowYouPlayFields {
                PickupFormRowDivider()

                PickupFormSelectionFieldRow(
                    systemImage: "chart.bar.fill",
                    label: L10n.t("pickup_form_skill_level", languageCode: languageCode),
                    valueText: skillLevel.displayTitle(languageCode: languageCode)
                ) {
                    Picker(selection: $skillLevel) {
                        ForEach(PickupGameSkillLevel.allCases) { level in
                            Text(level.displayTitle(languageCode: languageCode)).tag(level)
                        }
                    } label: {
                        EmptyView()
                    }
                }

                PickupFormRowDivider()

                PickupFormSelectionFieldRow(
                    systemImage: "person.2.fill",
                    label: L10n.t("pickup_form_whos_welcome", languageCode: languageCode),
                    valueText: participantPreference.displayTitle(languageCode: languageCode)
                ) {
                    Picker(selection: $participantPreference) {
                        ForEach(PickupParticipantPreference.allCases) { pref in
                            Text(pref.displayTitle(languageCode: languageCode)).tag(pref)
                        }
                    } label: {
                        EmptyView()
                    }
                }

                PickupFormRowDivider()

                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    ageRangeControls
                }
                .padding(FGSpacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: needsAdditionalPlayers)
        .animation(.easeInOut(duration: 0.2), value: isTeamLinkedForm)
        .onChange(of: participantPreference) { _, newValue in
            guard showsTeamOutsideRecruitmentHowYouPlayFields else { return }
            applySuggestedAgeRange(for: newValue)
        }
    }

    private var pickupFormVisibilityRows: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text(L10n.t("pickup_form_visibility", languageCode: languageCode))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            GameOnSegmentedControl(
                tabs: [
                    GameOnSegmentedTab(
                        id: true,
                        title: L10n.t("pickup_form_visibility_public", languageCode: languageCode),
                        systemImage: "globe",
                        tint: FGColor.intentPlay,
                        accessibilityLabel: L10n.t("pickup_form_visibility_public", languageCode: languageCode)
                    ),
                    GameOnSegmentedTab(
                        id: false,
                        title: L10n.t("pickup_form_visibility_private", languageCode: languageCode),
                        systemImage: "lock.fill",
                        tint: FGColor.intentPlay,
                        accessibilityLabel: L10n.t("pickup_form_visibility_private", languageCode: languageCode)
                    ),
                ],
                selection: $isPublicDiscover,
                accent: FGColor.intentPlay,
                titleMinimumScaleFactor: 0.78
            )
            .accessibilityLabel(L10n.t("pickup_form_visibility", languageCode: languageCode))

            Text(visibilityHelpText)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(visibilityHelpText)
        }
        .padding(FGSpacing.md)
        .animation(.easeInOut(duration: 0.2), value: isPublicDiscover)
    }

    /// Team create/edit with a Team default: compact inherited chrome until Override.
    private var showsTeamCompetitionInheritedChrome: Bool {
        guard isTeamLinkedForm,
              !competitionLevelOverrideActive,
              !isOrganizerPostStartManage,
              let teamDefault = effectiveTeamCreationContext?.competitionLevel
        else { return false }
        return competitionLevel == teamDefault
    }

    /// Create: "Inherited from Team". Edit (matching current Team default): "Team default".
    private var teamCompetitionInheritedCaptionKey: String {
        if case .edit = mode { return "pickup_form_competition_team_default" }
        return "pickup_form_competition_inherited_from_team"
    }

    private var pickupFormCompetitionLevelRow: some View {
        Group {
            if showsTeamCompetitionInheritedChrome {
                HStack(alignment: .center, spacing: FGSpacing.sm) {
                    PickupFormIconBadge(systemImage: "trophy")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("pickup_form_competition_level", languageCode: languageCode))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(
                            competitionLevel?.displayTitle(languageCode: languageCode)
                                ?? L10n.t("pickup_competition_level_not_specified", languageCode: languageCode)
                        )
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(L10n.t(teamCompetitionInheritedCaptionKey, languageCode: languageCode))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.accentGreen)
                    }
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            competitionLevelOverrideActive = true
                        }
                    } label: {
                        Text(L10n.t("pickup_form_competition_override", languageCode: languageCode))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.intentPlay)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(FGColor.intentPlay.opacity(0.85), lineWidth: 1.25)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("pickup_form_competition_override", languageCode: languageCode))
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    PickupFormSelectionFieldRow(
                        systemImage: "trophy",
                        label: L10n.t("pickup_form_competition_level", languageCode: languageCode),
                        valueText: competitionLevel?.displayTitle(languageCode: languageCode)
                            ?? L10n.t("pickup_competition_level_not_specified", languageCode: languageCode)
                    ) {
                        PickupCompetitionLevelMenuPicker(
                            selection: $competitionLevel,
                            languageCode: languageCode
                        )
                    }
                    if isTeamLinkedForm,
                       competitionLevelOverrideActive,
                       let teamDefault = effectiveTeamCreationContext?.competitionLevel {
                        HStack(spacing: 10) {
                            if competitionLevel != teamDefault {
                                Text(L10n.t("pickup_form_competition_game_specific", languageCode: languageCode))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                            Spacer(minLength: 0)
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    competitionLevel = teamDefault
                                    competitionLevelOverrideActive = false
                                }
                            } label: {
                                Text(L10n.t("pickup_form_competition_use_team_default", languageCode: languageCode))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.intentPlay)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                L10n.t("pickup_form_competition_use_team_default", languageCode: languageCode)
                            )
                        }
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.bottom, FGSpacing.sm)
                    }
                }
            }
        }
    }

    private var visibilityHelpText: String {
        if isTeamLinkedForm {
            return isPublicDiscover
                ? L10n.t("pickup_form_visibility_public_help_team", languageCode: languageCode)
                : L10n.t("pickup_form_visibility_private_help_team", languageCode: languageCode)
        }
        return isPublicDiscover
            ? L10n.t("pickup_form_visibility_public_help", languageCode: languageCode)
            : L10n.t("pickup_form_visibility_private_help", languageCode: languageCode)
    }

    private var pickupFormPollPermissionsSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_poll_permissions_section", languageCode: languageCode)) {
            pickupProgressivePollPermissionsRows
        }
    }

    /// Shared poll-permission controls (classic section card or progressive More Options).
    private var pickupProgressivePollPermissionsRows: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text(L10n.t("pickup_poll_permissions_who_can_create", languageCode: languageCode))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            GameOnSegmentedControl(
                tabs: PickupPollCreatePermission.allCases.map { option in
                    GameOnSegmentedTab(
                        id: option,
                        title: option.title(languageCode: languageCode),
                        tint: formAccent
                    )
                },
                selection: $pollCreatePermission,
                accent: formAccent,
                titleMinimumScaleFactor: 0.78
            )
            .accessibilityLabel(L10n.t("pickup_poll_permissions_who_can_create", languageCode: languageCode))

            Text(L10n.t("pickup_poll_permissions_footer", languageCode: languageCode))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(FGSpacing.md)
    }

    private var pickupFormWhereSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_where", languageCode: languageCode)) {
            if let appliedPickupPlacePrefill {
                pickupPlacePrefillCard(appliedPickupPlacePrefill)
                    .padding(FGSpacing.sm)
            } else if hasAnyLocationInput {
                if let preview = pickupLocationPreview {
                    pickupLocationMapPreview(
                        coordinate: preview.coordinate,
                        helperText: preview.helperText,
                        canOpenPicker: true
                    )
                    .padding(.horizontal, FGSpacing.sm)
                    .padding(.top, FGSpacing.sm)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FGColor.intentPlay)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summaryLocationPrimary)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                        if !summaryLocationSecondary.isEmpty,
                           summaryLocationSecondary != L10n.t("pickup_form_location_tbd", languageCode: languageCode) {
                            Text(summaryLocationSecondary)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        showPickupMapLocationPicker = true
                    } label: {
                        Text(L10n.t("pickup_form_change_location", languageCode: languageCode))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.intentPlay)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(FGColor.intentPlay.opacity(0.85), lineWidth: 1.25)
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.md)

                if let foot = locationGuidanceFootnote {
                    Text(foot)
                        .font(FGTypography.caption)
                        .foregroundStyle(hasValidMapPinLocation ? FGColor.accentBlue : FGColor.accentYellow)
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.bottom, FGSpacing.sm)
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.t("pickup_form_street_address", languageCode: languageCode), text: addressBinding, axis: .vertical)
                            .lineLimit(1...3)
                        TextField(L10n.t("pickup_form_city", languageCode: languageCode), text: cityBinding)
                        HStack(spacing: FGSpacing.sm) {
                            TextField(L10n.t("team_location_region", languageCode: languageCode), text: stateBinding)
                            TextField(L10n.t("team_location_postal", languageCode: languageCode), text: zipCodeBinding)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.default)
                        }
                    }
                    .font(.system(size: 15))
                    .padding(.top, 6)
                } label: {
                    Text(L10n.t("pickup_form_address_details", languageCode: languageCode))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .tint(FGColor.intentPlay)
                .padding(.horizontal, FGSpacing.md)
                .padding(.bottom, FGSpacing.md)
            } else {
                Button {
                    showPickupMapLocationPicker = true
                } label: {
                    PickupFormFieldRow(
                        systemImage: "mappin.and.ellipse",
                        label: L10n.t("pickup_form_choose_location", languageCode: languageCode),
                        showsChevron: true
                    ) {
                        Text(L10n.t("pickup_form_select_location", languageCode: languageCode))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.intentPlay)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(L10n.t("pickup_form_choose_location", languageCode: languageCode)), \(L10n.t("pickup_form_select_location", languageCode: languageCode))"
                )

                if showManualAddressEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.t("pickup_form_street_address", languageCode: languageCode), text: addressBinding, axis: .vertical)
                            .lineLimit(1...3)
                        TextField(L10n.t("pickup_form_city", languageCode: languageCode), text: cityBinding)
                        HStack(spacing: FGSpacing.sm) {
                            TextField(L10n.t("team_location_region", languageCode: languageCode), text: stateBinding)
                            TextField(L10n.t("team_location_postal", languageCode: languageCode), text: zipCodeBinding)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.default)
                        }
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, FGSpacing.md)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showManualAddressEntry = true
                        }
                    } label: {
                        Text(L10n.t("pickup_form_enter_address_manually", languageCode: languageCode))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.intentPlay)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, FGSpacing.md)
                            .padding(.bottom, FGSpacing.md)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pickupFormWhereLockedSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_where", languageCode: languageCode)) {
            PickupFormFieldRow(systemImage: "mappin", label: L10n.t("pickup_form_street_address", languageCode: languageCode)) {
                Text(trimmedAddress.isEmpty ? "—" : trimmedAddress)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.trailing)
            }
            PickupFormRowDivider()
            PickupFormFieldRow(systemImage: "building.2", label: L10n.t("pickup_form_city", languageCode: languageCode)) {
                Text(trimmedCity.isEmpty ? "—" : trimmedCity)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            PickupFormRowDivider()
            PickupFormFieldRow(systemImage: "map", label: L10n.t("team_location_region", languageCode: languageCode)) {
                Text(trimmedState.isEmpty ? "—" : trimmedState)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            PickupFormRowDivider()
            PickupFormFieldRow(systemImage: "number", label: L10n.t("team_location_postal", languageCode: languageCode)) {
                Text(trimmedZipCode.isEmpty ? "—" : trimmedZipCode)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            if let preview = pickupLocationPreview {
                pickupLocationMapPreview(
                    coordinate: preview.coordinate,
                    helperText: preview.helperText,
                    canOpenPicker: false
                )
                .padding(FGSpacing.sm)
            }
        }
    }

    private var pickupFormDescriptionSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_description", languageCode: languageCode)) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    L10n.t("pickup_form_description_placeholder", languageCode: languageCode),
                    text: $description,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .font(.system(size: 15))

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FGColor.intentPlay.opacity(0.85))
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    Text(L10n.t("pickup_form_description_helper", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, FGSpacing.md)

            PickupFormRowDivider()

            HStack(alignment: .top, spacing: FGSpacing.sm) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FGColor.intentPlay.opacity(0.9))
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(L10n.t("pickup_form_auto_delete_notice", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(FGSpacing.md)
        }
    }

    private var pickupFormSafetySection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_safety_section", languageCode: languageCode)) {
            Group {
                if usesTeamOnlySafetyNote {
                    pickupTeamOnlySafetyNotice
                } else {
                    VStack(alignment: .leading, spacing: FGSpacing.sm) {
                        pickupSafetyNotice
                        if requiresPickupSafetyAcknowledgment {
                            Toggle(
                                L10n.t("pickup_form_safety_acknowledge", languageCode: languageCode),
                                isOn: $pickupSafetyAcknowledged
                            )
                            .tint(FGColor.intentPlay)
                        }
                    }
                }
            }
            .padding(FGSpacing.md)
            .animation(.easeInOut(duration: 0.2), value: usesTeamOnlySafetyNote)
            .animation(.easeInOut(duration: 0.2), value: requiresPickupSafetyAcknowledgment)
        }
    }

    private var pickupFormCostSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_cost", languageCode: languageCode)) {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                GameOnSegmentedControl(
                    tabs: PickupCostKind.allCases.map { kind in
                        GameOnSegmentedTab(
                            id: kind,
                            title: kind.title(languageCode: languageCode),
                            tint: FGColor.intentPlay
                        )
                    },
                    selection: $costKind,
                    accent: FGColor.intentPlay,
                    titleMinimumScaleFactor: 0.85
                )
                .accessibilityLabel(L10n.t("pickup_form_cost", languageCode: languageCode))

                if costKind == .paid {
                    TextField(L10n.t("pickup_form_amount_usd", languageCode: languageCode), text: $entryFeeText)
                        .keyboardType(.decimalPad)
                    Text(L10n.t("pickup_form_paid_fee_hint", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            .padding(FGSpacing.md)
        }
        .animation(.easeInOut(duration: 0.2), value: costKind)
    }

    private var pickupFormDetailsLockedSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_details", languageCode: languageCode)) {
            PickupFormFieldRow(systemImage: "text.alignleft", label: L10n.t("pickup_form_description", languageCode: languageCode)) {
                Text(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : description)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(4)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsTeamIdentityHeader {
                pickupFormTeamIdentityCard
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.md)
                    .padding(.bottom, FGSpacing.sm)
            }

            if shouldShowCreationTabs {
                GameOnSegmentedControl(
                    tabs: PickupGameCreationTab.allCases.map { tab in
                        GameOnSegmentedTab(
                            id: tab,
                            title: tab.title(languageCode: languageCode),
                            tint: formAccent
                        )
                    },
                    selection: $creationTab,
                    accent: formAccent,
                    titleMinimumScaleFactor: 0.85
                )
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, showsTeamIdentityHeader ? FGSpacing.xs : FGSpacing.md)
                .padding(.bottom, FGSpacing.sm)
            }

            if shouldShowCreationTabs && creationTab == .csvImport {
                PickupBulkImportPreviewView(
                    viewModel: viewModel,
                    creationContext: creationContext,
                    showsNavigationChrome: false,
                    onImported: {
                        // Import service already refreshes Discover once at the end.
                        // Team sheet `onFinished` reloads Team → Games once on dismiss.
                        if !creationContext.isTeamSourced {
                            Task {
                                await viewModel.loadMyPickupGamesForSettings(
                                    forceRefresh: true,
                                    reason: "pickupImportInserted"
                                )
                            }
                        }
                    },
                    onDoneAfterSuccess: {
                        onFinished()
                    }
                )
            } else {
                manualPickupGameForm
            }
        }
        .fanGeoScreenBackground()
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("pickup_form_cancel", languageCode: languageCode)) { onFinished(); dismiss() }
                    .foregroundStyle(formAccent)
            }
            if !shouldShowCreationTabs || creationTab == .manual {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text(confirmationActionTitle)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(canSubmitPickupForm ? Color.white : FGColor.mutedText(colorScheme))
                            .padding(.horizontal, canSubmitPickupForm ? 14 : 0)
                            .padding(.vertical, canSubmitPickupForm ? 7 : 0)
                            .background {
                                if canSubmitPickupForm {
                                    Capsule(style: .continuous)
                                        .fill(formAccent)
                                }
                            }
                    }
                    .disabled(!canSubmitPickupForm)
                }
            }
        }
        .onAppear {
            if !didInitializeForm {
                applyModeToFields()
                didInitializeForm = true
                scheduleAddressLocationPreviewGeocode()
            }
            if case .edit(let row) = mode {
                let now = Date()
                let actions: String
                if isOrganizerPostStartManage {
                    actions = "roster_capacity_only,manage_requests_sheet"
                } else {
                    actions = "full_edit_before_start"
                }
                PickupGameStartedStateDebug.log(row: row, now: now, allowedActions: actions)
            }
            if !viewModel.canFanUsePickupGamesUI {
                onFinished()
                dismiss()
            }
            if !shouldShowCreationTabs {
                creationTab = .manual
            }
        }
        .task(id: editModePickupGameId) {
            await resolveLinkedTeamFormContextIfNeeded()
        }
        .onDisappear {
            addressPreviewGeocodeTask?.cancel()
        }
        .fullScreenCover(isPresented: $showPickupMapLocationPicker) {
            PickupGameMapLocationPickerSheet(
                viewModel: viewModel,
                initialCoordinate: pickMapSeedCoordinate,
                onCancel: { showPickupMapLocationPicker = false },
                onConfirm: { coord, street, cityName, stateAbbr, postalCode, country in
                    appliedPickupPlacePrefill = nil
                    if let s = street, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        address = s
                    }
                    if let c = cityName, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        city = c
                    }
                    if let st = stateAbbr, !st.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        state = st
                    }
                    if let zip = postalCode, !zip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        zipCode = zip
                    }
                    if let country, !country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        appliedLocationCountryCode = BusinessLocationCountryPolicy.normalizedStoredCountryCode(country)
                    }
                    mapPinnedCoordinate = coord
                    coordinatesLockedFromMap = true
                    addressPreviewCoordinate = nil
                    addressPreviewAddressLine = ""
                    showPickupMapLocationPicker = false
                }
            )
        }
        .sheet(isPresented: $showTeamChooseLocationPicker) {
            if let team = effectiveTeamCreationContext {
                FanTeamChooseLocationSheet(
                    viewModel: viewModel,
                    teamId: team.teamId,
                    canManageLocations: team.canManageTeamLocations,
                    initialCoordinate: pickMapSeedCoordinate,
                    onCancel: { showTeamChooseLocationPicker = false },
                    onSelect: { selection in
                        applyTeamLocationSelection(selection)
                        showTeamChooseLocationPicker = false
                    }
                )
            }
        }
        .confirmationDialog(
            "Another pickup game is already scheduled at this location during a similar time. Do you still want to post yours?",
            isPresented: $showPickupTimeConflictConfirmation,
            titleVisibility: .visible
        ) {
            Button("Post Anyway") {
                Task { await save(skipConflictCheck: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func pickupPlacePrefillCard(_ place: PickupPlaceRow) -> some View {
        let city = place.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = place.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                SportArtworkIconView(sport: sport, diameter: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    if !city.isEmpty && !state.isEmpty {
                        Text("\(city), \(state)")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Label("Exact map location saved", systemImage: "location.fill")
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)

            pickupLocationMapPreview(
                coordinate: place.coordinate,
                helperText: "Using exact map pin location.",
                canOpenPicker: false
            )

            Button {
                clearPickupPlacePrefill()
            } label: {
                Label("Clear or change location", systemImage: "xmark.circle")
                    .font(FGTypography.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(FGSpacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
        )
    }

    private func pickupLocationMapPreview(
        coordinate: CLLocationCoordinate2D,
        helperText: String,
        canOpenPicker: Bool
    ) -> some View {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.014, longitudeDelta: 0.014)
        )
        let preview = VStack(alignment: .leading, spacing: 8) {
            Map(initialPosition: .region(region)) {
                Annotation("Pickup game location", coordinate: coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(FGColor.accentBlue, Color.white)
                        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
                }
                .annotationTitles(.hidden)
            }
            .allowsHitTesting(false)
            .frame(height: 152)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
            )

            Label(helperText, systemImage: "location.fill")
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
        )

        return Group {
            if canOpenPicker {
                Button {
                    showPickupMapLocationPicker = true
                } label: {
                    preview
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the map picker")
            } else {
                preview
            }
        }
        .onAppear {
#if DEBUG
            print("[PickupLocationDebug] miniMapShown=true latitude=\(coordinate.latitude) longitude=\(coordinate.longitude) source=\(helperText)")
#endif
        }
    }

    private func applyModeToFields() {
        switch mode {
        case .add, .addTeamAnnouncement:
            title = ""
            sport = AppSportCatalog.formPickerSportsOrdered.first ?? "Soccer"
            let now = Date()
            gameDate = now
            gameTime = now
            endTime = Self.defaultPickupEndTime(forStartTimePickerDate: now)
            didManuallyEditEndTime = false
            address = ""
            city = ""
            state = ""
            zipCode = ""
            description = ""
            if mode.forcesTeamAnnouncement {
                gameFormat = .announcement
            } else {
                gameFormat = creationContext.isTeamSourced
                    ? GameType.defaultForTeamCreate
                    : GameType.defaultForNormalCreate
            }
            playEnvironment = .either
            skillLevel = .casual
            competitionLevel = nil
            competitionLevelOverrideActive = !creationContext.isTeamSourced
            participantPreference = .everyone
            specifyAgeRange = false
            minimumAge = 18
            maximumAge = 35
            noMaximumAge = true
            costKind = .free
            entryFeeText = ""
            playersNeeded = 1
            useMaxPlayers = false
            maxPlayers = 10
            needsAdditionalPlayers = false
            isPublicDiscover = PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(
                isTeamSourcedCreate: creationContext.isTeamSourced
            )
            pollCreatePermission = .organizerOnly
            opponentName = ""
            hasArrivalTime = false
            arrivalTime = Date()
            lastAutoSuggestedTitle = ""
            titleManuallyCustomized = false
            coordinatesLockedFromMap = false
            mapPinnedCoordinate = nil
            addressPreviewCoordinate = nil
            addressPreviewAddressLine = ""
            pickupSafetyAcknowledged = false
            showManualAddressEntry = false
            if let pickupPlacePrefill, !mode.forcesTeamAnnouncement {
                applyPickupPlacePrefill(pickupPlacePrefill)
            }
            applyTeamCreationContextPrefillIfNeeded()
#if DEBUG
            if mode.forcesTeamAnnouncement {
                print(
                    "[TeamScheduleActionDebug] announcementComposerPresented " +
                    "teamID=\(creationContext.team?.teamId.uuidString.lowercased() ?? "nil")"
                )
            }
#endif
        case .edit(let row):
            title = row.title
            sport = row.sport
            sportSubtype = SportSubtypeCatalog.ensuringValidSelection(row.sport_subtype, sport: row.sport)
            if let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
                gameDate = start
                gameTime = start
                endTime = PickupGameModels.endDate(for: row) ?? PickupGameModels.defaultPickupEndTime(forStart: start)
                didManuallyEditEndTime = row.end_time != nil
            }
            address = row.address ?? ""
            city = row.city ?? ""
            let splitState = Self.splitStoredStateAndZip(row.state)
            state = splitState.state
            zipCode = splitState.zipCode
            showManualAddressEntry = !(row.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(row.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            description = row.description ?? ""
            gameFormat = row.gameFormat
            playEnvironment = row.playEnvironmentEnum
            skillLevel = row.skillLevelEnum
            competitionLevel = row.competitionLevel
            if creationContext.isTeamSourced {
                competitionLevelOverrideActive = !PickupTeamCompetitionInheritance.startsInInheritedMode(
                    gameLevel: row.competitionLevel,
                    teamDefault: creationContext.team?.competitionLevel
                )
            } else {
                competitionLevelOverrideActive = true
            }
            participantPreference = row.participantPreferenceEnum
            if let ageMin = row.age_min {
                let normalized = PickupGameAgeRangeFormatter.normalized(min: ageMin, max: row.age_max)
                specifyAgeRange = true
                minimumAge = normalized.min ?? 18
                maximumAge = normalized.max ?? max(minimumAge, 35)
                noMaximumAge = normalized.max == nil
            } else {
                specifyAgeRange = false
                minimumAge = 18
                maximumAge = 35
                noMaximumAge = true
            }
            if row.is_free {
                costKind = .free
                entryFeeText = ""
            } else {
                costKind = .paid
                if let amt = row.entry_fee_amount {
                    entryFeeText = Self.feeTextFieldString(from: amt)
                } else {
                    entryFeeText = ""
                }
            }
            playersNeeded = row.playersNeededClamped
            if let cap = row.max_players {
                useMaxPlayers = true
                maxPlayers = min(100, Swift.max(1, cap))
            } else {
                useMaxPlayers = false
                maxPlayers = Swift.max(row.playersNeededClamped, 2)
            }
            // Seed Team recruiting toggle from persisted capacity (authoritative OFF = floor + no max).
            needsAdditionalPlayers = PickupTeamOutsideRecruiting.isEnabled(
                playersNeeded: row.playersNeededClamped,
                maxPlayers: row.max_players
            )
            pollCreatePermission = row.pollCreatePermission
            opponentName = FanTeamScheduleMatchup.trimmedOpponent(row.opponent_name) ?? ""
            if let arrival = row.arrival_time.flatMap({ PickupGameModels.parseSupabaseTimestamptz($0) }) {
                hasArrivalTime = true
                arrivalTime = arrival
            } else {
                hasArrivalTime = false
                arrivalTime = Date()
            }
            lastAutoSuggestedTitle = ""
            titleManuallyCustomized = true
            isPublicDiscover = row.is_visible
            if let latitude = row.latitude,
               let longitude = row.longitude {
                let savedCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                if Self.isValidPickupCoordinate(savedCoordinate) {
                    coordinatesLockedFromMap = true
                    mapPinnedCoordinate = savedCoordinate
                } else {
                    coordinatesLockedFromMap = false
                    mapPinnedCoordinate = nil
                }
            } else {
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
            addressPreviewCoordinate = nil
            addressPreviewAddressLine = ""
            pickupSafetyAcknowledged = true
        }
    }

    private var editModePickupGameId: UUID? {
        if case .edit(let row) = mode { return row.id }
        return nil
    }

    @MainActor
    private func resolveLinkedTeamFormContextIfNeeded() async {
        guard case .edit(let row) = mode, !creationContext.isTeamSourced else { return }
        do {
            linkedTeamFormContext = try await FanTeamsService().loadTeamCreationContext(
                forPickupGameId: row.id
            )
            if let teamDefault = linkedTeamFormContext?.competitionLevel {
                competitionLevelOverrideActive = !PickupTeamCompetitionInheritance.startsInInheritedMode(
                    gameLevel: competitionLevel,
                    teamDefault: teamDefault
                )
            }
        } catch {
            linkedTeamFormContext = nil
#if DEBUG
            print(
                "[PickupTeamForm] link context failed id=\(row.id.uuidString.lowercased()) " +
                "error=\(error.localizedDescription)"
            )
#endif
        }
    }

    private func applyTeamCreationContextPrefillIfNeeded() {
        guard let team = creationContext.team, creationContext.isTeamSourced else { return }
        let teamSport = team.teamSport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !teamSport.isEmpty {
            sport = teamSport
            sportSubtype = SportSubtypeCatalog.ensuringValidSelection(sportSubtype, sport: teamSport)
        }
        // Announcement composer starts blank; Schedule Event still prefills Practice title.
        if !mode.forcesTeamAnnouncement {
            let teamName = team.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !teamName.isEmpty {
                title = teamName
                lastAutoSuggestedTitle = teamName
                titleManuallyCustomized = false
            }
        }
        // Initialize once from Team default (resolved value persisted on save).
        competitionLevel = PickupTeamCompetitionInheritance.initialGameLevel(
            teamDefault: team.competitionLevel
        )
        // Inherited chrome only when Team has a concrete default.
        competitionLevelOverrideActive = team.competitionLevel == nil
        if !mode.forcesTeamAnnouncement {
            refreshTeamScheduleSuggestedTitleIfNeeded()
        }
    }

    private func applyPickupPlacePrefill(_ place: PickupPlaceRow) {
        let placeSport = place.primarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !placeSport.isEmpty && placeSport != "Pickup" {
            sport = placeSport
        } else if viewModel.selectedSport != "All" {
            sport = viewModel.selectedSport
        }
        sportSubtype = SportSubtypeCatalog.ensuringValidSelection(sportSubtype, sport: sport)
        refreshPickupSuggestedTitleIfNeeded()

        let trimmedName = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            address = trimmedName
            title = "\(sport) at \(trimmedName)"
        }
        city = place.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        state = place.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placeZip = place.zip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
#if DEBUG
        print("[PickupHostPrefillDebug] zipFromPlace=\(placeZip.isEmpty ? "nil" : placeZip)")
#endif
        zipCode = placeZip
        mapPinnedCoordinate = place.coordinate
        coordinatesLockedFromMap = true
        addressPreviewCoordinate = nil
        addressPreviewAddressLine = ""
        appliedPickupPlacePrefill = place
#if DEBUG
        print("[PickupHostPrefillDebug] zipPrefillApplied=\(!placeZip.isEmpty)")
        if placeZip.isEmpty || city.isEmpty {
            print("[PickupLocationDebug] zipMissingAllowed=true cityMissing=\(city.isEmpty)")
        }
        print("[PickupHostPrefillDebug] prefillApplied=true placeId=\(place.id.uuidString.lowercased()) sport=\(sport) city=\(city) state=\(state) zip=\(zipCode) latitude=\(place.latitude) longitude=\(place.longitude)")
#endif
    }

    private func clearPickupPlacePrefill() {
        appliedPickupPlacePrefill = nil
        address = ""
        city = ""
        state = ""
        zipCode = ""
        addressPreviewCoordinate = nil
        addressPreviewAddressLine = ""
        coordinatesLockedFromMap = false
        mapPinnedCoordinate = nil
    }

    private var pickupSafetyNotice: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FGColor.intentPlay)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("pickup_form_safety_title", languageCode: languageCode))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t("pickup_form_safety_body", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Team roster-only: lightweight informational reminder (no acknowledgement toggle).
    private var pickupTeamOnlySafetyNotice: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("pickup_form_safety_title", languageCode: languageCode))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t("fan_team_game_safety_team_only_body", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private static func feeTextFieldString(from amount: Double) -> String {
        let n = NSNumber(value: amount)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? String(format: "%.2f", amount)
    }

    private static func isValidPickupCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate)
            && (-90.0...90.0).contains(coordinate.latitude)
            && (-180.0...180.0).contains(coordinate.longitude)
    }

    private static func splitStoredStateAndZip(_ raw: String?) -> (state: String, zipCode: String) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return ("", "") }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard parts.count > 1,
              let last = parts.last,
              last.rangeOfCharacter(from: .decimalDigits) != nil else {
            return (trimmed, "")
        }
        return (parts.dropLast().joined(separator: " "), last)
    }

    private static func storedStateWithZip(state: String, zipCode: String) -> String {
        [state, zipCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func logPickupDatePicker(todayTapped: Bool, doneTapped: Bool, selectedDate: Date) {
#if DEBUG
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        print("[PickupDatePicker] todayTapped=\(todayTapped)")
        print("[PickupDatePicker] doneTapped=\(doneTapped)")
        print("[PickupDatePicker] selectedDate=\(f.string(from: selectedDate))")
#endif
    }

    /// Sets the game calendar day to today; if the combined start is still in the past, advances clock time using shared venue rules.
    private func applyPickupDatePickerJumpToToday() {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        suppressGameDatePickerChangeLog = true
        gameDate = todayStart
        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameTime, now: now) {
            gameTime = VenueOwnerGameScheduleValidation.recommendedStartTimeAfterGameDateChange(newGameDate: todayStart, now: now)
            if !didManuallyEditEndTime {
                endTime = Self.defaultPickupEndTime(forStartTimePickerDate: gameTime)
            }
        }
        suppressGameDatePickerChangeLog = false
        logPickupDatePicker(todayTapped: true, doneTapped: false, selectedDate: gameDate)
    }

    private var pickupGameDatePopover: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Button("Today") {
                    applyPickupDatePickerJumpToToday()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)

                Spacer(minLength: 0)

                Button("Done") {
                    logPickupDatePicker(todayTapped: false, doneTapped: true, selectedDate: gameDate)
                    showGameDatePopover = false
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            Divider()
                .opacity(colorScheme == .dark ? 0.35 : 0.45)

            DatePicker("", selection: $gameDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .onChange(of: gameDate) { _, newValue in
                    guard !suppressGameDatePickerChangeLog else { return }
                    logPickupDatePicker(todayTapped: false, doneTapped: false, selectedDate: newValue)
                }
        }
        .frame(minWidth: 320)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.1), lineWidth: 1)
        }
    }

    private func combinedStartDate() -> Date {
        VenueOwnerGameScheduleValidation.combinedLocalStart(gameDate: gameDate, gameStartTime: gameTime)
    }

    private func combinedEndDate(start: Date) -> Date {
        let cal = Calendar.current
        let rawEnd = VenueOwnerGameScheduleValidation.combinedLocalStart(gameDate: gameDate, gameStartTime: endTime)
        if rawEnd > start { return rawEnd }
        return cal.date(byAdding: .day, value: 1, to: rawEnd) ?? PickupGameModels.defaultPickupEndTime(forStart: start)
    }

    private static func defaultPickupEndTime(forStartTimePickerDate startTime: Date) -> Date {
        PickupGameModels.defaultPickupEndTime(forStart: startTime)
    }

    private func parsedEntryFeeAmount() -> Double? {
        let t = entryFeeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let normalized = t.replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    private func save(skipConflictCheck: Bool = false) async {
        errorText = nil

        if let postStartRow = organizerPostStartLockedRow {
            let playersN: Int
            let maxP: Int?
            if isTeamLinkedForm, !needsAdditionalPlayers {
                // Turning recruitment OFF must not silently remove approved outside players;
                // only stop new outside recruiting via capacity sentinel.
                let inactive = PickupTeamOutsideRecruiting.inactivePersistence()
                playersN = inactive.playersNeeded
                maxP = inactive.maxPlayers
            } else {
                playersN = min(20, max(1, playersNeeded))
                let approved = postStartRow.approvedJoinCount
                guard playersN >= approved else {
                    errorText = "Players needed can’t be fewer than the number already approved (\(approved))."
                    return
                }
                if useMaxPlayers {
                    let capped = min(100, max(1, maxPlayers))
                    guard capped >= playersN else {
                        errorText = "Max players must be at least the number of players needed."
                        return
                    }
                    maxP = capped
                } else {
                    maxP = nil
                }
            }

            isSaving = true
            defer { isSaving = false }

            do {
                try await viewModel.updatePickupGameRosterCapacity(
                    id: postStartRow.id,
                    playersNeeded: playersN,
                    maxPlayers: maxP
                )
                await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                onFinished()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            return
        }

        let trimmedTitle: String = {
            let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
            return SportSubtypeCatalog.suggestedTitle(
                sport: sport,
                subtype: sportSubtype,
                languageCode: languageCode
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }()
        guard !trimmedTitle.isEmpty else {
            errorText = L10n.t("pickup_form_ready_add_title", languageCode: languageCode)
            teamScheduleValidationAnchor = usesTeamScheduleProgressiveLayout ? "teamScheduleTitle" : "pickupFormTitleField"
            return
        }
        if requiresOpponentForSubmit,
           FanTeamScheduleMatchup.persistableOpponent(
            format: gameFormat,
            opponentName: opponentName,
            sport: sport
           ) == nil {
            errorText = L10n.t("pickup_form_ready_add_opponent", languageCode: languageCode)
            teamScheduleValidationAnchor = "teamScheduleMatchup"
            return
        }
        if requiresPickupSafetyAcknowledgment && !pickupSafetyAcknowledged {
            errorText = "Acknowledge the pickup safety notice before posting."
            return
        }
        if isAnnouncementForm {
            let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                errorText = L10n.t("team_announcement_ready_add_message", languageCode: languageCode)
                teamScheduleValidationAnchor = "teamScheduleAnnouncementMessage"
                return
            }
            if body.count > 2000 {
                errorText = L10n.t("team_announcement_message_too_long", languageCode: languageCode)
                return
            }
        }
        if !isAnnouncementForm,
           VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameTime) {
            errorText = VenueOwnerGameScheduleValidation.futureDateTimeMessage
            teamScheduleValidationAnchor = "teamScheduleWhen"
            return
        }
        if !isAnnouncementForm, !hasPlacedLocationForPostButton {
            errorText = L10n.t("pickup_form_ready_choose_location", languageCode: languageCode)
            teamScheduleValidationAnchor = "teamScheduleLocation"
            return
        }
        let startProbe = VenueOwnerGameScheduleValidation.combinedLocalStart(gameDate: gameDate, gameStartTime: gameTime)
        let endProbe = isAnnouncementForm
            ? startProbe.addingTimeInterval(60)
            : combinedEndDate(start: startProbe)
        if !isAnnouncementForm, endProbe <= startProbe {
            errorText = L10n.t("team_schedule_end_after_start", languageCode: languageCode)
            teamScheduleValidationAnchor = "teamScheduleTime"
            return
        }

        // Team + recruiting OFF: hide outside eligibility fields; don't require/persist age gates.
        // Form @State is preserved for toggle-back in this session.
        let ageRange: (min: Int?, max: Int?)
        if isTeamLinkedForm, !needsAdditionalPlayers {
            ageRange = (nil, nil)
        } else {
            ageRange = normalizedAgeRangePayload()
            if specifyAgeRange {
                guard let minAge = ageRange.min else {
                    errorText = "Choose a minimum age for this pickup game."
                    return
                }
                if let maxAge = ageRange.max, minAge > maxAge {
                    errorText = "Minimum age can’t be greater than maximum age."
                    return
                }
            }
        }

        let isFree = costKind == .free
        var feeParsed: Double?
        if !isFree {
            guard let amt = parsedEntryFeeAmount(), amt > 0, amt <= 999_999 else {
                errorText = "Enter a valid entry fee (USD)."
                return
            }
            feeParsed = (amt * 100.0).rounded() / 100.0
        }

        let playersN: Int
        let maxP: Int?
        if isTeamLinkedForm, !needsAdditionalPlayers {
            // Authoritative OFF: Team roster audience only; stops outside recruiting detection.
            let inactive = PickupTeamOutsideRecruiting.inactivePersistence()
            playersN = inactive.playersNeeded
            maxP = inactive.maxPlayers
        } else {
            playersN = min(20, max(1, playersNeeded))
            if useMaxPlayers {
                let capped = min(100, max(1, maxPlayers))
                guard capped >= playersN else {
                    errorText = "Max players must be at least the number of players needed."
                    return
                }
                maxP = capped
            } else {
                maxP = nil
            }
        }

        // Outside recruitment preference metadata: keep session values when ON; when Team OFF,
        // persist Everyone so hidden "Who’s welcome" cannot imply outside eligibility filters.
        let preferencePayload: String
        if isTeamLinkedForm, !needsAdditionalPlayers {
            preferencePayload = PickupParticipantPreference.everyone.rawValue
        } else {
            preferencePayload = participantPreference.rawValue
        }

        isSaving = true
        defer { isSaving = false }

        let start = isAnnouncementForm ? Date() : combinedStartDate()
        let end = isAnnouncementForm
            ? start.addingTimeInterval(60)
            : combinedEndDate(start: start)

        let missingZip = trimmedZipCode.isEmpty
#if DEBUG
        print("[PickupLocationDebug] postValidationMissingZip=\(missingZip)")
        if hasValidMapPinLocation, missingZip || trimmedCity.isEmpty {
            print("[PickupLocationDebug] zipMissingAllowed=true cityMissing=\(trimmedCity.isEmpty)")
        }
#endif
        let latFinal: Double?
        let lonFinal: Double?
        let addr: String
        let c: String
        let st: String
        if isAnnouncementForm {
            // Announcements are not venue events — persist without inventing a location.
            // Never write (0,0): that is Null Island and must not look like a real pin.
            latFinal = nil
            lonFinal = nil
            addr = ""
            c = ""
            st = ""
        } else {
            guard hasCompleteTypedAddress || hasValidMapPinLocation else {
                errorText = "Enter an address or pick a location from the map."
                teamScheduleValidationAnchor = "teamScheduleLocation"
                return
            }

            let addressLine = [trimmedAddress, trimmedCity, trimmedState, trimmedZipCode]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")

            if hasValidMapPinLocation, let pin = mapPinnedCoordinate {
                latFinal = pin.latitude
                lonFinal = pin.longitude
            } else {
                guard let coord = await viewModel.geocodeAddress(addressLine) else {
                    errorText = "Could not find that address. Please check the street address, city, and state."
                    return
                }
                latFinal = coord.latitude
                lonFinal = coord.longitude
            }

            addr = trimmedAddress
            c = trimmedCity
            st = Self.storedStateWithZip(state: trimmedState, zipCode: trimmedZipCode)
        }

        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var createdFromPickupPlace: PickupGameRow?
            switch mode {
            case .add, .addTeamAnnouncement:
#if DEBUG
                print(
                    "[PickupLocationDebug] coordinatesSaved=true latitude=\(latFinal?.description ?? "nil") " +
                    "longitude=\(lonFinal?.description ?? "nil") source=\(appliedPickupPlacePrefill == nil ? "manual" : "pickup_place")"
                )
                if let appliedPickupPlacePrefill {
                    print(
                        "[PickupHostPrefillDebug] savedPickupPlaceLocation=true " +
                        "placeId=\(appliedPickupPlacePrefill.id.uuidString.lowercased()) address=\(addr) city=\(c) " +
                        "state=\(st) zip=\(trimmedZipCode) latitude=\(latFinal?.description ?? "nil") " +
                        "longitude=\(lonFinal?.description ?? "nil")"
                    )
                }
#endif
                let isTeamCreate = creationContext.isTeamSourced
                if isTeamCreate, !GameType.fanTeamLinkableCases.contains(gameFormat) {
                    errorText = L10n.t("pickup_form_team_format_error", languageCode: languageCode)
                    return
                }
                if isAnnouncementForm, creationContext.team?.canPublishAnnouncements != true {
                    errorText = L10n.t("team_announcement_permission_denied", languageCode: languageCode)
#if DEBUG
                    print(
                        "[TeamAnnouncement] permissionResult=denied clientGate " +
                        "teamID=\(creationContext.team?.teamId.uuidString.lowercased() ?? "nil")"
                    )
#endif
                    return
                }
#if DEBUG
                if isAnnouncementForm {
                    print(
                        "[TeamAnnouncement] publishStart " +
                        "teamID=\(creationContext.team?.teamId.uuidString.lowercased() ?? "nil") " +
                        "authorID=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil")"
                    )
                    print(
                        "[TeamScheduleActionDebug] announcementPostStarted " +
                        "teamID=\(creationContext.team?.teamId.uuidString.lowercased() ?? "nil")"
                    )
                }
#endif
                if !isAnnouncementForm, !skipConflictCheck {
                    if try await viewModel.findOverlappingPickupGameAtLocation(
                        newStart: start,
                        newEnd: end,
                        latitude: latFinal,
                        longitude: lonFinal,
                        address: addr,
                        city: c,
                        state: st
                    ) != nil {
                        showPickupTimeConflictConfirmation = true
                        return
                    }
                }
                let createdVisibility = isAnnouncementForm
                    // Announcement composer has no Public/Private control — privacy-safe Private.
                    ? false
                    : PickupGameEditPrivacyPolicy.resolvedIsVisible(
                        formIsPublic: isPublicDiscover,
                        isStandalonePickup: !isTeamLinkedForm
                    )
                let created = try await viewModel.insertPickupGame(
                    title: trimmedTitle,
                    sport: sport,
                    description: desc.isEmpty ? nil : desc,
                    skillLevel: skillLevel.rawValue,
                    gameStartAt: start,
                    endTime: end,
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    playersNeeded: playersN,
                    playEnvironment: playEnvironment.rawValue,
                    participantPreference: preferencePayload,
                    ageMin: ageRange.min,
                    ageMax: ageRange.max,
                    isFree: isFree,
                    entryFeeAmount: feeParsed,
                    maxPlayers: maxP,
                    gameFormat: gameFormat,
                    competitionLevel: competitionLevel,
                    pollCreatePermission: pollCreatePermission,
                    isVisible: createdVisibility,
                    opponentName: FanTeamScheduleMatchup.persistableOpponent(
                        format: gameFormat,
                        opponentName: opponentName,
                        sport: sport
                    ),
                    arrivalTime: arrivalTimePayload,
                    sportSubtype: sportSubtype,
                    claimsPickupCreateXP: !isTeamCreate
                )
                if let team = creationContext.team, isTeamCreate {
                    do {
                        _ = try await FanTeamsService().linkPickupGameToFanTeam(
                            teamId: team.teamId,
                            pickupGameId: created.id
                        )
                        if gameFormat != .announcement {
                            await viewModel.awardFanXP(
                                source: FanXPSource.teamEventCreated,
                                sourceId: created.id
                            )
                        }
                        await recordTeamLocationUsageAfterSuccessfulPersist(
                            teamId: team.teamId,
                            address: addr,
                            city: c,
                            state: st,
                            latitude: latFinal,
                            longitude: lonFinal
                        )
#if DEBUG
                        if isAnnouncementForm {
                            print(
                                "[TeamAnnouncement] persistSuccess " +
                                "announcementID=\(created.id.uuidString.lowercased()) " +
                                "teamID=\(team.teamId.uuidString.lowercased())"
                            )
                            print(
                                "[TeamScheduleActionDebug] announcementPostSucceeded " +
                                "teamID=\(team.teamId.uuidString.lowercased()) " +
                                "announcementID=\(created.id.uuidString.lowercased())"
                            )
                        }
#endif
                    } catch {
#if DEBUG
                        if isAnnouncementForm {
                            print(
                                "[TeamAnnouncement] persistFailure " +
                                "announcementID=\(created.id.uuidString.lowercased()) " +
                                "teamID=\(team.teamId.uuidString.lowercased()) " +
                                "error=\(error.localizedDescription)"
                            )
                            print(
                                "[TeamScheduleActionDebug] announcementPostFailed " +
                                "teamID=\(team.teamId.uuidString.lowercased()) " +
                                "error=\(error.localizedDescription)"
                            )
                        }
#endif
                        try? await viewModel.deletePickupGame(id: created.id)
                        throw error
                    }
                }
                onCreated?(created)
                if appliedPickupPlacePrefill != nil {
                    createdFromPickupPlace = created
                }
            case .edit(let row):
                if isAnnouncementForm {
                    let canPublish = creationContext.team?.canPublishAnnouncements == true
                        || effectiveTeamCreationContext?.canPublishAnnouncements == true
                    guard canPublish else {
                        errorText = L10n.t("team_announcement_permission_denied", languageCode: languageCode)
#if DEBUG
                        print(
                            "[TeamAnnouncement] permissionResult=denied_edit clientGate " +
                            "announcementID=\(row.id.uuidString.lowercased())"
                        )
#endif
                        return
                    }
                }
                let gameStartISO = PickupGameModels.encodeSupabaseTimestamptz(start)
                let endISO = PickupGameModels.encodeSupabaseTimestamptz(end)
                let removeISO = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: gameStartISO)
                let resolvedVisibility = isAnnouncementForm
                    // Announcement composer has no Public/Private control — keep Private.
                    ? false
                    : PickupGameEditPrivacyPolicy.resolvedIsVisible(
                        formIsPublic: isPublicDiscover,
                        isStandalonePickup: !isTeamLinkedForm
                    )
                let patch = PickupGameFullUpdate(
                    title: trimmedTitle,
                    sport: sport,
                    sport_subtype: SportSubtypeCatalog.normalizedSubtype(
                        sport: sport,
                        subtype: sportSubtype
                    ),
                    description: desc.isEmpty ? nil : desc,
                    game_format: gameFormat.rawValue,
                    competition_level: competitionLevel?.rawValue,
                    skill_level: skillLevel.rawValue,
                    game_start_at: gameStartISO,
                    end_time: endISO,
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    is_visible: resolvedVisibility,
                    players_needed: playersN,
                    play_environment: playEnvironment.rawValue,
                    participant_preference: preferencePayload,
                    age_min: ageRange.min,
                    age_max: ageRange.max,
                    is_free: isFree,
                    entry_fee_amount: feeParsed,
                    max_players: maxP,
                    cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
                    remove_after_at: removeISO,
                    poll_create_permission: pollCreatePermission.rawValue,
                    opponent_name: FanTeamScheduleMatchup.persistableOpponent(
                        format: gameFormat,
                        opponentName: opponentName,
                        sport: sport
                    ),
                    arrival_time: PickupNullableTimestamptz(date: arrivalTimePayload)
                )
                try await viewModel.updatePickupGame(id: row.id, full: patch)
                if let teamId = effectiveTeamCreationContext?.teamId {
                    await recordTeamLocationUsageAfterSuccessfulPersist(
                        teamId: teamId,
                        address: addr,
                        city: c,
                        state: st,
                        latitude: latFinal,
                        longitude: lonFinal
                    )
                }
            }
            if let createdFromPickupPlace {
                await viewModel.refreshPickupGameAfterDiscoverPickupPlaceCreate(createdFromPickupPlace)
            } else {
                await viewModel.refreshPickupGamesForDiscoverMap(force: true)
            }
            onFinished()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func applyTeamLocationSelection(_ selection: FanTeamLocationSelection) {
        appliedPickupPlacePrefill = nil
        let street = selection.persistableAddress
        if !street.isEmpty {
            address = street
        }
        if !selection.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            city = selection.city
        }
        if !selection.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = selection.state
        }
        if !selection.zipCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            zipCode = selection.zipCode
        }
        appliedLocationCountryCode = selection.countryCode
        mapPinnedCoordinate = selection.coordinate
        coordinatesLockedFromMap = true
        addressPreviewCoordinate = nil
        addressPreviewAddressLine = ""
    }

    /// Recent usage is recorded only after the event row (and Team link, on create) succeeds.
    private func recordTeamLocationUsageAfterSuccessfulPersist(
        teamId: UUID,
        address: String,
        city: String,
        state: String,
        latitude: Double?,
        longitude: Double?
    ) async {
        guard !isAnnouncementForm else { return }
        guard let latitude, let longitude else { return }
        do {
            _ = try await FanTeamLocationService().upsertUsageFromFormFields(
                teamId: teamId,
                placeName: nil,
                address: address.isEmpty ? nil : address,
                city: city.isEmpty ? nil : city,
                state: state.isEmpty ? nil : state,
                latitude: latitude,
                longitude: longitude,
                providerPlaceId: nil,
                postalCode: trimmedZipCode.isEmpty ? nil : trimmedZipCode,
                countryCode: appliedLocationCountryCode.isEmpty ? nil : appliedLocationCountryCode
            )
        } catch {
            TeamLocationDebug.log(
                "recentUsageUpsert",
                detail: "teamID=\(teamId.uuidString.lowercased()) softFail=\(error.localizedDescription)"
            )
        }
    }
}

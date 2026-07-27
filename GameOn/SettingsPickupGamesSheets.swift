import SwiftUI
import Combine
import CoreLocation
import MapKit

enum PickupGameFormMode: Identifiable, Equatable {
    case add
    case edit(PickupGameRow)

    var id: String {
        switch self {
        case .add: return "pickup-form-add"
        case .edit(let row): return "pickup-form-\(row.id.uuidString)"
        }
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
                    } header: {
                        if viewModel.pendingPickupGameJoinRequestCount > 0 {
                            HStack(alignment: .center, spacing: FGSpacing.sm) {
                                Image(systemName: "person.crop.circle.badge.clock")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                                Text(
                                    viewModel.pendingPickupGameJoinRequestCount == 1
                                        ? "1 player asked to join a game you host — review below."
                                        : "\(viewModel.pendingPickupGameJoinRequestCount) players asked to join games you host — review below."
                                )
                                .font(FGTypography.caption.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 6)
                            .textCase(nil)
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
    case followingCompact
}

struct GameFormatBadgeView: View {
    let format: GameType
    let colorScheme: ColorScheme

    var body: some View {
        Text(format.badgeTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.35 : 0.22), lineWidth: 1)
            )
            .accessibilityLabel("Game format: \(format.displayTitle)")
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
                if stackStatusUnderName {
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
                        statusBadge(title: statusTitle)
                            .layoutPriority(0)
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

    private var status: SettingsPickupGameListCardStatus {
        Self.computeStatus(row: row, pendingJoinCount: pendingJoinCount, now: now)
    }

    private var isExpiredClearing: Bool {
        status == .expiredClearing
    }

    private var usesExpiredArchivedStyle: Bool {
        isFollowingCompact && isExpiredClearing
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
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: isFollowingCompact ? 8 : 10) {
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
                        }
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
            .padding(.top, 6)
            .contentShape(Rectangle())
            .onTapGesture { handleCardMapTap() }

            if !row.is_visible {
                Text("Hidden from map")
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

                HStack(spacing: 10) {
                    if !usesExpiredArchivedStyle, let onInvite {
                        Button(action: onInvite) {
                            Label("Invite", systemImage: "person.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.orange)
                    }

                    if !(isFollowingCompact && isExpiredClearing) {
                        Button(action: onEdit) {
                            Label(gameStarted ? "Manage" : "Edit", systemImage: "pencil")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(FGColor.accentBlue)
                    }

                    Button(role: .destructive, action: onDelete) {
                        Label(isFollowingCompact && isExpiredClearing ? "Clear expired" : "Cancel game", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if isFollowingCompact, !isExpiredClearing, let onOpenDetails {
                    Button(action: onOpenDetails) {
                        Label(
                            L10n.t("pickup_details_cleanup", languageCode: languageCode),
                            systemImage: "ellipsis.circle"
                        )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, isFollowingCompact ? 10 : 14)

            if !isFollowingCompact {
                Divider()
                    .opacity(colorScheme == .dark ? 0.35 : 0.5)
                    .padding(.vertical, 10)

                SettingsPickupCleanupCountdownRow(
                    row: row,
                    now: now,
                    languageCode: languageCode,
                    isFooterStyle: true
                )
            } else {
                let snap = SettingsPickupCleanupDisplay.snapshot(
                    row: row,
                    now: now,
                    languageCode: languageCode
                )
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: snap.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(snap.label)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
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
        row.pickupHistoryClientCleanupDeadline()
    }

    static func snapshot(row: PickupGameRow, now: Date, languageCode: String) -> Snapshot {
        guard let deadline = cleanupDeadline(for: row) else {
            return Snapshot(
                label: String(
                    format: L10n.t("pickup_auto_clears_after_start_format", languageCode: languageCode),
                    12
                ),
                symbolName: "clock.arrow.circlepath",
                tone: .normal
            )
        }
        guard let gameStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
            if now >= deadline {
                return Snapshot(label: "Past auto-clear time", symbolName: "clock", tone: .normal)
            }
            let remaining = deadline.timeIntervalSince(now)
            if remaining < 3600 {
                let minutes = max(1, Int(ceil(remaining / 60)))
                return Snapshot(label: "Clears in \(minutes)m", symbolName: "timer", tone: .amber)
            }
            let totalSeconds = Int(remaining)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            return Snapshot(label: "Clears in \(hours)h \(minutes)m", symbolName: "timer", tone: .normal)
        }

        if now >= deadline {
            return Snapshot(label: "Past auto-clear time", symbolName: "clock", tone: .normal)
        }

        if now < gameStart {
            return Snapshot(
                label: String(
                    format: L10n.t("pickup_auto_clears_after_start_format", languageCode: languageCode),
                    12
                ),
                symbolName: "clock.arrow.circlepath",
                tone: .normal
            )
        }

        let remaining = deadline.timeIntervalSince(now)
        if remaining < 3600 {
            let minutes = max(1, Int(ceil(remaining / 60)))
            return Snapshot(label: "Clears in \(minutes)m", symbolName: "timer", tone: .amber)
        }

        let totalSeconds = Int(remaining)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return Snapshot(label: "Clears in \(hours)h \(minutes)m", symbolName: "timer", tone: .normal)
    }
}

private struct SettingsPickupCleanupCountdownRow: View {
    let row: PickupGameRow
    let now: Date
    let languageCode: String
    /// Footer uses smaller type and neutral gray until amber/red.
    var isFooterStyle: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let snap = SettingsPickupCleanupDisplay.snapshot(
            row: row,
            now: now,
            languageCode: languageCode
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(nil)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(FGAdaptiveSurface.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.55), lineWidth: 0.5)
            }
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

private struct PickupFormIconBadge: View {
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

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 16, weight: .regular, design: .default))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
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
    @State private var gameDate: Date = Date()
    @State private var gameTime: Date = Date()
    @State private var endTime: Date = Date().addingTimeInterval(2 * 3600)
    @State private var didManuallyEditEndTime = false
    @State private var address: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    @State private var description: String = ""
    @State private var playEnvironment: PickupPlayEnvironment = .either
    @State private var skillLevel: PickupGameSkillLevel = .casual
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
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var showPickupMapLocationPicker = false
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

    private var organizerPostStartLockedRow: PickupGameRow? {
        if case .edit(let row) = mode, row.hasPickupGameStarted(), isCurrentUserCreator(of: row) {
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
        !trimmedAddress.isEmpty && !trimmedCity.isEmpty && !trimmedState.isEmpty && !trimmedZipCode.isEmpty
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

    private var requiresPickupSafetyAcknowledgment: Bool {
        if case .add = mode { return true }
        return false
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
        if case .add = mode { return true }
        return false
    }

    private var showsCreateIntro: Bool {
        if case .add = mode { return true }
        return false
    }

    private var showsLiveSummary: Bool {
        true
    }

    private var canSubmitPickupForm: Bool {
        !isSaving
            && (isOrganizerPostStartManage || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (isOrganizerPostStartManage || hasPlacedLocationForPostButton)
            && (!requiresPickupSafetyAcknowledgment || pickupSafetyAcknowledged)
    }

    private var postReadinessMessage: String? {
        guard !canSubmitPickupForm, !isSaving, !isOrganizerPostStartManage else { return nil }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.t("pickup_form_ready_add_title", languageCode: languageCode)
        }
        if !hasPlacedLocationForPostButton {
            return L10n.t("pickup_form_ready_choose_location", languageCode: languageCode)
        }
        if requiresPickupSafetyAcknowledgment && !pickupSafetyAcknowledged {
            return L10n.t("pickup_form_ready_acknowledge_safety", languageCode: languageCode)
        }
        return nil
    }

    private var navigationTitleText: String {
        switch mode {
        case .add:
            return L10n.t("pickup_form_nav_create", languageCode: languageCode)
        case .edit:
            if isOrganizerPostStartManage {
                return L10n.t("pickup_form_nav_manage", languageCode: languageCode)
            }
            return L10n.t("pickup_form_nav_edit", languageCode: languageCode)
        }
    }

    private var confirmationActionTitle: String {
        mode == .add
            ? L10n.t("pickup_form_post", languageCode: languageCode)
            : L10n.t("pickup_form_save", languageCode: languageCode)
    }

    private var summarySportLabel: String {
        AppSportCatalog.displayLabel(forSportToken: sport)
    }

    private var summarySportEmoji: String {
        SportFilterCatalog.resolve(sport).emoji
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
        PickupFormFieldRow(systemImage: "flag.fill", label: L10n.t("pickup_form_game_format", languageCode: languageCode)) {
            Picker("", selection: $gameFormat) {
                ForEach(GameType.allCases, id: \.self) { type in
                    Text(type.displayTitle(languageCode: languageCode)).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(FGColor.intentPlay)
        }
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
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    if let errorText, !errorText.isEmpty {
                        Text(errorText)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.dangerRed)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(FGSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FGColor.dangerRed.opacity(0.10), in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
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

                    pickupFormGameSection
                    pickupFormWhenSection
                    pickupFormPlayersSection

                    if !isOrganizerPostStartManage {
                        pickupFormHowYouPlaySection
                        pickupFormWhereSection
                        pickupFormDetailsSection
                    } else {
                        pickupFormWhereLockedSection
                        pickupFormDetailsLockedSection
                    }

                    if let postReadinessMessage {
                        Text(postReadinessMessage)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.intentPlay)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(postReadinessMessage)
                    }
                }
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
    }

    private var pickupFormIntroRow: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            Image(systemName: "sportscourt.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(FGColor.intentPlay, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("pickup_form_intro_title", languageCode: languageCode))
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
    }

    private var pickupFormLiveSummaryCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                pickupSummaryColumn(
                    emoji: summarySportEmoji.isEmpty ? nil : summarySportEmoji,
                    systemImage: summarySportEmoji.isEmpty ? SportFilterCatalog.resolve(sport).systemImage : nil,
                    primary: summarySportLabel,
                    secondary: nil
                )
                pickupSummaryDivider
                pickupSummaryColumn(primary: summaryDateText, secondary: summaryTimeRangeText)
                pickupSummaryDivider
                pickupSummaryColumn(primary: summaryPlayersPrimary, secondary: summaryPlayersSecondary)
                pickupSummaryDivider
                pickupSummaryColumn(primary: summaryLocationPrimary, secondary: summaryLocationSecondary)
            }

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    pickupSummaryColumn(
                        emoji: summarySportEmoji.isEmpty ? nil : summarySportEmoji,
                        systemImage: summarySportEmoji.isEmpty ? SportFilterCatalog.resolve(sport).systemImage : nil,
                        primary: summarySportLabel,
                        secondary: nil
                    )
                    pickupSummaryColumn(primary: summaryDateText, secondary: summaryTimeRangeText)
                }
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    pickupSummaryColumn(primary: summaryPlayersPrimary, secondary: summaryPlayersSecondary)
                    pickupSummaryColumn(primary: summaryLocationPrimary, secondary: summaryLocationSecondary)
                }
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(summarySportLabel), \(summaryDateText), \(summaryTimeRangeText), \(summaryPlayersPrimary) \(summaryPlayersSecondary), \(summaryLocationPrimary), \(summaryLocationSecondary)"
        )
    }

    private var pickupSummaryDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme).opacity(0.7))
            .frame(width: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }

    private func pickupSummaryColumn(
        emoji: String? = nil,
        systemImage: String? = nil,
        primary: String,
        secondary: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 14))
                        .accessibilityHidden(true)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FGColor.intentPlay)
                        .accessibilityHidden(true)
                }
                Text(primary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
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
            PickupFormFieldRow(
                systemImage: "person.2.fill",
                label: L10n.t("pickup_form_players_needed", languageCode: languageCode)
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

                    Text(playersNeededCountText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(minWidth: 72)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(playersNeededCountText)

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

            PickupFormRowDivider()

            PickupFormFieldRow(
                systemImage: "person.3.fill",
                label: L10n.t("pickup_form_set_max_capacity", languageCode: languageCode)
            ) {
                Toggle("", isOn: $useMaxPlayers)
                    .labelsHidden()
                    .tint(FGColor.intentPlay)
                    .accessibilityLabel(L10n.t("pickup_form_set_max_capacity", languageCode: languageCode))
            }

            if useMaxPlayers {
                PickupFormRowDivider()
                PickupFormFieldRow(
                    systemImage: "number",
                    label: L10n.t("pickup_form_max_players", languageCode: languageCode)
                ) {
                    HStack(spacing: 8) {
                        Text("\(maxPlayers)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .monospacedDigit()
                        Stepper("", value: $maxPlayers, in: 1...100)
                            .labelsHidden()
                            .accessibilityLabel(L10n.t("pickup_form_max_players", languageCode: languageCode))
                            .accessibilityValue("\(maxPlayers)")
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: useMaxPlayers)
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
        }
        .onChange(of: participantPreference) { _, newValue in
            applySuggestedAgeRange(for: newValue)
        }
    }

    private var pickupFormWhereSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_where", languageCode: languageCode)) {
            if let appliedPickupPlacePrefill {
                pickupPlacePrefillCard(appliedPickupPlacePrefill)
                    .padding(FGSpacing.sm)
            } else {
                Button {
                    showPickupMapLocationPicker = true
                } label: {
                    PickupFormFieldRow(
                        systemImage: "mappin.and.ellipse",
                        label: locationRowPrimaryLabel,
                        showsChevron: true
                    ) {
                        Text(locationRowTrailingText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(FGColor.intentPlay)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(L10n.t("pickup_form_location_label", languageCode: languageCode)), \(locationRowPrimaryLabel), \(locationRowTrailingText)"
                )

                PickupFormRowDivider()

                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.t("pickup_form_street_address", languageCode: languageCode), text: addressBinding, axis: .vertical)
                        .lineLimit(1...3)
                    TextField(L10n.t("pickup_form_city", languageCode: languageCode), text: cityBinding)
                    HStack(spacing: FGSpacing.sm) {
                        TextField(L10n.t("pickup_form_state", languageCode: languageCode), text: stateBinding)
                        TextField(L10n.t("pickup_form_zip", languageCode: languageCode), text: zipCodeBinding)
                            .textInputAutocapitalization(.characters)
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
                .font(.system(size: 15))
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.sm)

                if let foot = locationGuidanceFootnote {
                    Text(foot)
                        .font(FGTypography.caption)
                        .foregroundStyle(hasValidMapPinLocation ? FGColor.accentBlue : FGColor.accentYellow)
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.bottom, FGSpacing.sm)
                }

                if let preview = pickupLocationPreview {
                    pickupLocationMapPreview(
                        coordinate: preview.coordinate,
                        helperText: preview.helperText,
                        canOpenPicker: true
                    )
                    .padding(.horizontal, FGSpacing.sm)
                    .padding(.bottom, FGSpacing.sm)
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
            PickupFormFieldRow(systemImage: "map", label: L10n.t("pickup_form_state", languageCode: languageCode)) {
                Text(trimmedState.isEmpty ? "—" : trimmedState)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            PickupFormRowDivider()
            PickupFormFieldRow(systemImage: "number", label: L10n.t("pickup_form_zip", languageCode: languageCode)) {
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

    private var pickupFormDetailsSection: some View {
        PickupFormSectionCard(title: L10n.t("pickup_form_section_details", languageCode: languageCode)) {
            if shouldShowCreationTabs {
                gameFormatFormSection
                PickupFormRowDivider()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("pickup_form_description_optional", languageCode: languageCode))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                TextField("", text: $description, axis: .vertical)
                    .lineLimit(2...6)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, FGSpacing.sm)

            PickupFormRowDivider()

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
            .padding(FGSpacing.md)

            PickupFormRowDivider()

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                Text(L10n.t("pickup_form_cost", languageCode: languageCode))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Picker(L10n.t("pickup_form_entry", languageCode: languageCode), selection: $costKind) {
                    ForEach(PickupCostKind.allCases) { k in
                        Text(k.title(languageCode: languageCode)).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                if costKind == .paid {
                    TextField(L10n.t("pickup_form_amount_usd", languageCode: languageCode), text: $entryFeeText)
                        .keyboardType(.decimalPad)
                    Text(L10n.t("pickup_form_paid_fee_hint", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            .padding(FGSpacing.md)

            PickupFormRowDivider()

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                ageRangeControls
            }
            .padding(FGSpacing.md)

            PickupFormRowDivider()

            HStack(alignment: .top, spacing: FGSpacing.sm) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
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
            if shouldShowCreationTabs {
                GameOnSegmentedControl(
                    tabs: PickupGameCreationTab.allCases.map { tab in
                        GameOnSegmentedTab(
                            id: tab,
                            title: tab.title(languageCode: languageCode),
                            tint: FGColor.intentPlay
                        )
                    },
                    selection: $creationTab,
                    accent: FGColor.intentPlay,
                    titleMinimumScaleFactor: 0.85
                )
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.sm)
            }

            if shouldShowCreationTabs && creationTab == .csvImport {
                PickupBulkImportPreviewView(
                    viewModel: viewModel,
                    showsNavigationChrome: false,
                    onImported: {
                        Task { await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "pickupImportInserted") }
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
            }
            if !shouldShowCreationTabs || creationTab == .manual {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmationActionTitle) {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(canSubmitPickupForm ? FGColor.intentPlay : FGColor.mutedText(colorScheme))
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
        .onDisappear {
            addressPreviewGeocodeTask?.cancel()
        }
        .fullScreenCover(isPresented: $showPickupMapLocationPicker) {
            PickupGameMapLocationPickerSheet(
                viewModel: viewModel,
                initialCoordinate: pickMapSeedCoordinate,
                onCancel: { showPickupMapLocationPicker = false },
                onConfirm: { coord, street, cityName, stateAbbr, postalCode in
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
                    mapPinnedCoordinate = coord
                    coordinatesLockedFromMap = true
                    addressPreviewCoordinate = nil
                    addressPreviewAddressLine = ""
                    showPickupMapLocationPicker = false
                }
            )
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
        case .add:
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
            gameFormat = .pickup
            playEnvironment = .either
            skillLevel = .casual
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
            coordinatesLockedFromMap = false
            mapPinnedCoordinate = nil
            addressPreviewCoordinate = nil
            addressPreviewAddressLine = ""
            pickupSafetyAcknowledged = false
            if let pickupPlacePrefill {
                applyPickupPlacePrefill(pickupPlacePrefill)
            }
        case .edit(let row):
            title = row.title
            sport = row.sport
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
            description = row.description ?? ""
            gameFormat = row.gameFormat
            playEnvironment = row.playEnvironmentEnum
            skillLevel = row.skillLevelEnum
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

    private func applyPickupPlacePrefill(_ place: PickupPlaceRow) {
        let placeSport = place.primarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !placeSport.isEmpty && placeSport != "Pickup" {
            sport = placeSport
        } else if viewModel.selectedSport != "All" {
            sport = viewModel.selectedSport
        }

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
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FGColor.accentYellow)
                .padding(.top, 1)
            Text("Pickup games and meetups involve physical activity and real-world interaction. Participate at your own risk and use good judgment.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
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
            let playersN = min(20, max(1, playersNeeded))
            let approved = postStartRow.approvedJoinCount
            guard playersN >= approved else {
                errorText = "Players needed can’t be fewer than the number already approved (\(approved))."
                return
            }
            var maxP: Int?
            if useMaxPlayers {
                let capped = min(100, max(1, maxPlayers))
                guard capped >= playersN else {
                    errorText = "Max players must be at least the number of players needed."
                    return
                }
                maxP = capped
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

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorText = "Title is required."
            return
        }
        if requiresPickupSafetyAcknowledgment && !pickupSafetyAcknowledged {
            errorText = "Acknowledge the pickup safety notice before posting."
            return
        }
        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameTime) {
            errorText = VenueOwnerGameScheduleValidation.futureDateTimeMessage
            return
        }

        let ageRange = normalizedAgeRangePayload()
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

        let isFree = costKind == .free
        var feeParsed: Double?
        if !isFree {
            guard let amt = parsedEntryFeeAmount(), amt > 0, amt <= 999_999 else {
                errorText = "Enter a valid entry fee (USD)."
                return
            }
            feeParsed = (amt * 100.0).rounded() / 100.0
        }

        let playersN = min(20, max(1, playersNeeded))
        var maxP: Int?
        if useMaxPlayers {
            let capped = min(100, max(1, maxPlayers))
            guard capped >= playersN else {
                errorText = "Max players must be at least the number of players needed."
                return
            }
            maxP = capped
        }

        isSaving = true
        defer { isSaving = false }

        let start = combinedStartDate()
        let end = combinedEndDate(start: start)

        let missingZip = trimmedZipCode.isEmpty
#if DEBUG
        print("[PickupLocationDebug] postValidationMissingZip=\(missingZip)")
        if hasValidMapPinLocation, missingZip || trimmedCity.isEmpty {
            print("[PickupLocationDebug] zipMissingAllowed=true cityMissing=\(trimmedCity.isEmpty)")
        }
#endif
        guard hasCompleteTypedAddress || hasValidMapPinLocation else {
            errorText = "Enter an address or pick a location from the map."
            return
        }

        let addressLine = [trimmedAddress, trimmedCity, trimmedState, trimmedZipCode]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let latFinal: Double
        let lonFinal: Double
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

        let addr = trimmedAddress
        let c = trimmedCity
        let st = Self.storedStateWithZip(state: trimmedState, zipCode: trimmedZipCode)

        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var createdFromPickupPlace: PickupGameRow?
            switch mode {
            case .add:
                if !skipConflictCheck {
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
#if DEBUG
                print("[PickupLocationDebug] coordinatesSaved=true latitude=\(latFinal) longitude=\(lonFinal) source=\(appliedPickupPlacePrefill == nil ? "manual" : "pickup_place")")
                if let appliedPickupPlacePrefill {
                    print("[PickupHostPrefillDebug] savedPickupPlaceLocation=true placeId=\(appliedPickupPlacePrefill.id.uuidString.lowercased()) address=\(addr) city=\(c) state=\(st) zip=\(trimmedZipCode) latitude=\(latFinal) longitude=\(lonFinal)")
                }
#endif
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
                    participantPreference: participantPreference.rawValue,
                    ageMin: ageRange.min,
                    ageMax: ageRange.max,
                    isFree: isFree,
                    entryFeeAmount: feeParsed,
                    maxPlayers: maxP,
                    gameFormat: gameFormat
                )
                onCreated?(created)
                if appliedPickupPlacePrefill != nil {
                    createdFromPickupPlace = created
                }
            case .edit(let row):
                let gameStartISO = PickupGameModels.encodeSupabaseTimestamptz(start)
                let endISO = PickupGameModels.encodeSupabaseTimestamptz(end)
                let removeISO = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: gameStartISO)
                let patch = PickupGameFullUpdate(
                    title: trimmedTitle,
                    sport: sport,
                    description: desc.isEmpty ? nil : desc,
                    game_format: gameFormat.rawValue,
                    skill_level: skillLevel.rawValue,
                    game_start_at: gameStartISO,
                    end_time: endISO,
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    is_visible: true,
                    players_needed: playersN,
                    play_environment: playEnvironment.rawValue,
                    participant_preference: participantPreference.rawValue,
                    age_min: ageRange.min,
                    age_max: ageRange.max,
                    is_free: isFree,
                    entry_fee_amount: feeParsed,
                    max_players: maxP,
                    cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
                    remove_after_at: removeISO
                )
                try await viewModel.updatePickupGame(id: row.id, full: patch)
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
}

import SwiftUI

/// Polished read-only profile preview for another fan (no email, no UUID in UI). Shown full-screen via ``PublicProfileOverlayWindowPresenter``.
/// When ``isSelfPreview`` is true, the same public rendering path is used for the signed-in fan with a lightweight preview banner.
struct PublicUserProfilePreviewView: View {
    let userId: UUID
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    /// Own-profile WYSIWYG mode: same public data path, no owner-only controls.
    var isSelfPreview: Bool = false
    var onDismiss: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @AppStorage(FavoriteTeamsStore.primaryTeamIDAppStorageKey) private var primaryFavoriteTeamIDRaw: String = ""

    @State private var profile: PublicUserProfileData?
    @State private var isLoading = true
    @State private var identityLoadWarning: String?
    @State private var friendButtonState: PublicProfileFriendButtonState = .hidden
    @State private var isFriendActionInFlight = false
    @State private var friendActionError: String?
    @State private var pokeSummary: ProfilePokeSummary?
    @State private var isPokeInFlight = false
    @State private var pokeActionError: String?
    @State private var pokeJustSucceeded = false
    @State private var showShareFanProfileSheet = false
    @State private var showBlockFanConfirmation = false
    @State private var showReportFanSheet = false
    @State private var showCancelFriendRequestConfirmation = false
    @State private var showRemoveFriendConfirmation = false
    @State private var isBlockActionInFlight = false
    @State private var safetyActionBanner: String?

    private let profilePokesService = ProfilePokesService()
    private static let reportSubmittedBannerText = "Report submitted. FanGeo moderation will review it."

    private var viewingAsSelfPreview: Bool {
        isSelfPreview || userId == viewModel.currentUserAuthId && viewModel.publicProfileIsSelfPreview
    }

    /// Live My Team overlay for self-preview so national-fan sport labels never go stale.
    private var presentationProfile: PublicUserProfileData? {
        guard let profile else { return nil }
        guard viewingAsSelfPreview else { return profile }
        let localTeams = FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
        return profile.seededForSelfPreview(
            homeCrowd: viewModel.currentUserHomeCrowdVenue,
            openToPreferences: viewModel.currentUserFanIdentityPreferences,
            primaryFavoriteTeamID: primaryFavoriteTeamIDRaw,
            favoriteTeams: localTeams,
            profileBackgroundKey: viewModel.currentUserProfileBackgroundKey
        )
    }

    private var profileContentHorizontalPadding: CGFloat {
        ProfileHeroMetrics.outerInset(screenWidth: nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PublicProfileSheetLayout.sectionSpacing) {
                    if viewingAsSelfPreview {
                        selfPreviewBanner
                    }
                    if isLoading, presentationProfile == nil {
                        loadingSkeleton
                    } else if let profile = presentationProfile {
                        // Self-preview loader sets isPubliclyVisible; keep banner+content when projection loaded.
                        if !profile.isPubliclyVisible {
                            profileUnavailableState
                        } else {
                            if let identityLoadWarning {
                                identityWarningBanner(identityLoadWarning)
                            }
                            profileContent(profile)
                        }
                    } else {
                        loadingSkeleton
                    }
                }
                .padding(.horizontal, profileContentHorizontalPadding)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .profileReadableContentWidth()
            }
            .background(sheetBackground.ignoresSafeArea())
            .toolbarBackground(sheetBackgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .navigationTitle("Fan Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("done", languageCode: appLanguageRaw)) { onDismiss() }
                        .accessibilityHint(
                            viewingAsSelfPreview
                                ? L10n.t("public_profile_preview_done_hint", languageCode: appLanguageRaw)
                                : ""
                        )
                }
                if profile?.isPubliclyVisible == true,
                   !viewingAsSelfPreview,
                   (profile?.isDiscoverableByFans == true
                    || canShowSafetyActions
                    || friendButtonState == .messageFriend
                    || friendButtonState == .friendshipRequested) {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if profile?.isDiscoverableByFans == true {
                                Button {
                                    showShareFanProfileSheet = true
                                } label: {
                                    Label(L10n.t("share_profile", languageCode: appLanguageRaw), systemImage: "square.and.arrow.up")
                                }
                            }

                            if friendButtonState == .messageFriend {
                                Button(role: .destructive) {
                                    showRemoveFriendConfirmation = true
                                } label: {
                                    Label("Remove Friend", systemImage: "person.badge.minus")
                                }
                                .disabled(isFriendActionInFlight)
                            }

                            if friendButtonState == .friendshipRequested {
                                Button(role: .destructive) {
                                    showCancelFriendRequestConfirmation = true
                                } label: {
                                    Label(L10n.t("cancel_friend_request", languageCode: appLanguageRaw), systemImage: "person.badge.minus")
                                }
                                .disabled(isFriendActionInFlight)
                            }

                            if canShowSafetyActions {
                                Button {
                                    showReportFanSheet = true
                                } label: {
                                    Label(L10n.t("report_fan", languageCode: appLanguageRaw), systemImage: "flag.fill")
                                }

                                Button(role: .destructive) {
                                    showBlockFanConfirmation = true
                                } label: {
                                    Label(L10n.t("block_fan", languageCode: appLanguageRaw), systemImage: "nosign")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(L10n.t("public_profile_more_options_a11y", languageCode: appLanguageRaw))
                    }
                }
            }
            .sheet(isPresented: $showShareFanProfileSheet) {
                if let profile, profile.isPubliclyVisible, profile.isDiscoverableByFans {
                    ShareFanProfileSheet(profile: profile, mapViewModel: viewModel)
                        .environmentObject(chatViewModel)
                }
            }
            .sheet(isPresented: $showReportFanSheet) {
                FanProfileUserReportSheet(
                    reportedUserId: userId,
                    onDismiss: { showReportFanSheet = false },
                    onSubmitted: {
                        showReportFanSheet = false
                        safetyActionBanner = Self.reportSubmittedBannerText
                    }
                )
            }
            .confirmationDialog(
                "Cancel friend request?",
                isPresented: $showCancelFriendRequestConfirmation,
                titleVisibility: .visible
            ) {
                Button("Cancel Request", role: .destructive) {
                    Task { await cancelOutgoingFriendRequest() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove your pending request.")
            }
            .confirmationDialog(
                removeFriendConfirmationTitle,
                isPresented: $showRemoveFriendConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Friend", role: .destructive) {
                    Task { await removeFriend() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(L10n.t("dm_unfriend_confirm_body", languageCode: appLanguageRaw))
            }
            .confirmationDialog(
                "Block \(profile?.displayName ?? "this fan")?",
                isPresented: $showBlockFanConfirmation,
                titleVisibility: .visible
            ) {
                Button("Block Fan", role: .destructive) {
                    Task { await blockFan() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They won't be able to message you or send friend requests. You won't see each other in chat lists while the block is active.")
            }
        }
        .task(id: userId) {
            // Prefer a process-cache snapshot immediately; never flash another user's data.
            if let cached = PublicUserProfileProcessCache.lookup(for: userId) {
                profile = cached.data
                pokeSummary = nil
                pokeActionError = nil
                pokeJustSucceeded = false
                friendActionError = nil
                isLoading = false
#if DEBUG
                print(
                    "[PublicProfileCache] reopenHit userId=\(userId.uuidString.lowercased()) fresh=\(cached.isFresh)"
                )
#endif
            } else {
                profile = nil
                pokeSummary = nil
                pokeActionError = nil
                pokeJustSucceeded = false
                friendActionError = nil
            }
            await loadProfile()
            await loadPokeSummary(for: userId)
        }
        .onReceive(NotificationCenter.default.publisher(for: FanProfileChangeCenter.avatarDidChangeNotification)) { notification in
            guard let change = FanProfileChangeCenter.avatarChange(from: notification),
                  change.userId == userId else { return }
            PublicUserProfileProcessCache.invalidate(userId: userId, reason: "avatarChange")
            guard let current = profile else { return }
            let nextFull = change.avatarURL.isEmpty ? current.avatarURL : change.avatarURL
            let nextThumb = change.avatarThumbnailURL ?? current.avatarThumbnailURL
            let curFull = ImageDisplayURL.canonicalStorageURLString(current.avatarURL)
            let curThumb = ImageDisplayURL.canonicalStorageURLString(current.avatarThumbnailURL)
            let newFull = ImageDisplayURL.canonicalStorageURLString(nextFull)
            let newThumb = ImageDisplayURL.canonicalStorageURLString(nextThumb)
            guard curFull != newFull || curThumb != newThumb else { return }
            let updated = current.replacingAvatars(avatarURL: nextFull, avatarThumbnailURL: nextThumb)
            profile = updated
            PublicUserProfileProcessCache.store(updated)
        }
        .onChange(of: viewModel.publicProfileOpenToRevision) { _, _ in
            guard userId == viewModel.currentUserAuthId else { return }
            PublicUserProfileProcessCache.invalidate(userId: userId, reason: "openToRevision")
            Task { await loadProfile() }
        }
        .onChange(of: viewModel.publicProfileHomeCrowdRevision) { _, _ in
            guard userId == viewModel.currentUserAuthId else { return }
            PublicUserProfileProcessCache.invalidate(userId: userId, reason: "homeCrowdRevision")
            Task { await loadProfile() }
        }
        .onChange(of: viewModel.publicProfileBioRevision) { _, _ in
            guard userId == viewModel.currentUserAuthId else { return }
            PublicUserProfileProcessCache.invalidate(userId: userId, reason: "bioRevision")
            Task { await loadProfile() }
        }
        .onChange(of: chatViewModel.friendshipChipByOtherUserId) { _, _ in
            refreshFriendButtonState()
        }
    }

    // MARK: - Redesigned layout

    @ViewBuilder
    private func profileContent(_ data: PublicUserProfileData) -> some View {
        VStack(spacing: PublicProfileSheetLayout.sectionSpacing) {
            PublicProfileRedesignHero(
                data: data,
                isSelfPreview: viewingAsSelfPreview,
                friendState: friendButtonState,
                isFriendActionInFlight: isFriendActionInFlight,
                canPoke: canShowPokeControls(for: data.userId),
                pokeTitle: pokeButtonTitle,
                isPokeDisabled: isPokeActionDisabled,
                isPokeInFlight: isPokeInFlight,
                onAddFriend: {
                    guard !viewingAsSelfPreview else { return }
                    Task { await requestFriendship(userId: data.userId) }
                },
                onCancelRequest: {
                    guard !viewingAsSelfPreview else { return }
                    showCancelFriendRequestConfirmation = true
                },
                onMessage: {
                    guard !viewingAsSelfPreview else { return }
                    Task { await messageFriend(data) }
                },
                onPoke: {
                    guard !viewingAsSelfPreview else { return }
                    Task { await sendPoke(to: data.userId) }
                }
            )
            .onAppear {
#if DEBUG
                print("[PublicProfileRedesign] rendered user_id=\(data.userId.uuidString.lowercased()) mutual=\(data.mutualFansCount) avatars=\(data.mutualFanAvatars.count) selfPreview=\(viewingAsSelfPreview) openTo=\(data.openToItems.count) homeCrowd=\(data.homeCrowd?.venueId.uuidString.lowercased() ?? "nil")")
#endif
            }

            PublicProfileBelowHeroStack(
                data: data,
                isSelfPreview: viewingAsSelfPreview,
                onSelectMutualFan: viewingAsSelfPreview
                    ? nil
                    : { fanId in
                        viewModel.presentPublicProfile(
                            userId: fanId,
                            context: "mutual_friends"
                        )
                    },
                onChooseTeam: viewingAsSelfPreview ? { onDismiss() } : nil,
                onAddSports: viewingAsSelfPreview ? { onDismiss() } : nil,
                onViewHomeWatchSpot: {
                    guard let venueId = data.homeCrowd?.venueId else { return }
                    onDismiss()
                    viewModel.focusDiscoverOnVenue(venueId)
                },
                onChooseHomeWatchSpot: viewingAsSelfPreview ? { onDismiss() } : nil
            )

            if let friendActionError, !friendActionError.isEmpty {
                inlineError(friendActionError)
            }
            if let pokeActionError, !pokeActionError.isEmpty {
                inlineError(pokeActionError)
            }

            if let safetyActionBanner, !safetyActionBanner.isEmpty {
                safetyActionBannerView(safetyActionBanner)
            }
        }
    }

    private var selfPreviewBanner: some View {
        PublicProfileOwnerPreviewNotice()
    }

    private var canShowSafetyActions: Bool {
        guard !viewingAsSelfPreview else { return false }
        guard let profile, profile.isPubliclyVisible, !profile.isBusinessAccount else { return false }
        guard viewModel.currentUserAuthId != nil else { return false }
        return userId != viewModel.currentUserAuthId
    }

    private func safetyActionBannerView(_ text: String) -> some View {
        let isPositive = text == Self.reportSubmittedBannerText || text.contains("blocked")
        return HStack(spacing: 8) {
            Image(systemName: isPositive ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isPositive ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    (isPositive ? FGColor.accentGreen : FGColor.accentBlue)
                        .opacity(colorScheme == .dark ? 0.16 : 0.10)
                )
        }
    }

    @MainActor
    private func blockFan() async {
        guard !isBlockActionInFlight else { return }
        isBlockActionInFlight = true
        safetyActionBanner = nil

        let moderation = ModerationService()
        do {
            try await moderation.block(userId: userId)
            await chatViewModel.refreshBlockedUsers()
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.refresh()
            refreshFriendButtonState()
            safetyActionBanner = "Fan blocked. They can't message you or send friend requests."
        } catch {
            safetyActionBanner = error.localizedDescription
        }
        isBlockActionInFlight = false
    }

    @MainActor
    private func performFriendAction(_ data: PublicUserProfileData) async {
        switch friendButtonState {
        case .messageFriend:
            showRemoveFriendConfirmation = true
        case .requestFriendship:
            await requestFriendship(userId: data.userId)
        case .friendshipRequested:
            showCancelFriendRequestConfirmation = true
        case .hidden:
            break
        }
    }

    private var removeFriendConfirmationTitle: String {
        let name = profile?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return "Remove Friend?"
        }
        return "Remove \(name)?"
    }

    private var profileUnavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("This profile isn't available")
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text("The fan may have turned off discoverability or this profile can't be shown.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .publicProfileEditorialCard()
    }

    // MARK: - Poke UI helpers

    private var pokeButtonTitle: String {
        if pokeJustSucceeded { return "Poked!" }
        if let pokeSummary, pokeSummary.viewerCanPokeNow { return L10n.t("poke", languageCode: appLanguageRaw) }
        if pokeSummary != nil { return "Soon" }
        return L10n.t("poke", languageCode: appLanguageRaw)
    }

    private var pokeButtonIcon: String {
        pokeJustSucceeded ? "checkmark" : "hand.wave.fill"
    }

    private var pokeButtonForeground: Color {
        if pokeJustSucceeded { return FGColor.accentGreen }
        if pokeSummary?.viewerCanPokeNow == true { return .white }
        return FGColor.accentBlue
    }

    private var pokeButtonBackground: Color {
        if pokeJustSucceeded {
            return FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11)
        }
        if pokeSummary?.viewerCanPokeNow == true {
            return FGColor.accentBlue
        }
        return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10)
    }

    private var pokeButtonBorder: Color {
        if pokeJustSucceeded { return FGColor.accentGreen.opacity(0.28) }
        return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.18)
    }

    private var isPokeActionDisabled: Bool {
        isPokeInFlight || pokeSummary == nil || (pokeJustSucceeded == false && pokeSummary?.viewerCanPokeNow == false)
    }

    // MARK: - Shared chrome

    private func inlineError(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
                .frame(height: 168)
                .redacted(reason: .placeholder)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
                .frame(height: 44)
                .redacted(reason: .placeholder)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
                    .frame(height: 176)
                    .redacted(reason: .placeholder)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
                    .frame(height: 176)
                    .redacted(reason: .placeholder)
            }
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
                .frame(height: 120)
                .redacted(reason: .placeholder)
            ProgressView().tint(FGColor.accentGreen).padding(.top, 4)
        }
    }

    private func identityWarningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
            Spacer(minLength: 0)
            Button("Retry") { Task { await loadProfile() } }
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(FGColor.secondaryText(colorScheme))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.14))
        )
    }

    private var sheetBackgroundColor: Color {
        FGColor.background(colorScheme)
    }

    private var sheetBackground: some View {
        sheetBackgroundColor
    }

    // MARK: - Actions

    private func loadProfile() async {
        SuggestedFanProfileOpenDebug.serviceRequestStarted()
        let processLookup = PublicUserProfileProcessCache.lookup(for: userId)
        await MainActor.run {
            let isSilentRefresh = profile != nil || processLookup != nil
            if isSilentRefresh {
                friendActionError = nil
                if profile == nil, let processLookup {
                    profile = processLookup.data
                    isLoading = false
#if DEBUG
                    print(
                        "[PublicProfileCache] appliedBeforeNetwork userId=\(userId.uuidString.lowercased()) fresh=\(processLookup.isFresh)"
                    )
#endif
                }
            } else {
                isLoading = true
                friendActionError = nil
                pokeSummary = nil
                pokeActionError = nil
                pokeJustSucceeded = false
            }
        }

        await chatViewModel.loadIfNeeded()

        // Fresh process cache: paint immediately and skip the network round-trip.
        if let processLookup, processLookup.isFresh, !viewingAsSelfPreview {
            let chip = chatViewModel.chipKind(forOtherUserId: userId)
            let blocked = chatViewModel.isEitherDirectionBlocked(with: userId)
            let isSelf = viewModel.currentUserAuthId == userId
            let friendState = PublicUserProfileService.friendButtonState(
                for: userId,
                chipKind: chip,
                isBlocked: blocked,
                isSelf: isSelf,
                isBusiness: processLookup.data.isBusinessAccount
            )
            await MainActor.run {
                SuggestedFanProfileOpenDebug.rendererConstructionStarted()
                profile = processLookup.data
                isLoading = false
                identityLoadWarning = processLookup.data.hasResolvedIdentity || !processLookup.data.isPubliclyVisible
                    ? nil
                    : "Limited profile — identity still loading. Tap Retry."
                friendButtonState = friendState
                if processLookup.data.isPubliclyVisible {
                    SuggestedFanProfileOpenDebug.sheetPresented()
                }
#if DEBUG
                print("[PublicProfileCache] networkSkippedFreshTTL userId=\(userId.uuidString.lowercased())")
#endif
            }
            return
        }

        var cached = viewModel.cachedUserProfileRowForPublicProfile(userId: userId)
        if cached == nil,
           let friend = chatViewModel.friends.first(where: { $0.preview.id == userId }) {
            // Seed identity/name from chat, but do not freeze chat avatar snapshots as authoritative.
            // Fresh RPC / profile fetch must supply the current avatar URL.
            cached = PublicUserProfileService.userProfileRow(from: friend.preview, includeAvatars: false)
        }
        if userId == viewModel.currentUserAuthId {
            cached = viewModel.currentUserProfileRowForPublicProfileCache()
        }

        var loaded = await PublicUserProfileService.load(
            userId: userId,
            cachedProfile: cached,
            isSelfPreview: viewingAsSelfPreview
        )

        // If chat inbox already merged a newer avatar URL (realtime / shared event), prefer it over
        // an older cached row — but never overwrite a successful network identity with a blank chat seed.
        if let friend = chatViewModel.friends.first(where: { $0.preview.id == userId }) {
            let chatFull = ImageDisplayURL.canonicalStorageURLString(friend.preview.avatarURL)
            let chatThumb = ImageDisplayURL.canonicalStorageURLString(friend.preview.avatarThumbnailURL)
            let loadedFull = ImageDisplayURL.canonicalStorageURLString(loaded.avatarURL)
            let loadedThumb = ImageDisplayURL.canonicalStorageURLString(loaded.avatarThumbnailURL)
            if !chatFull.isEmpty, chatFull != loadedFull || (!chatThumb.isEmpty && chatThumb != loadedThumb) {
                // Prefer the URL that looks versioned/newer by string inequality only when chat was
                // updated after inbox merge; if load returned empty avatars, fill from chat.
                if loadedFull.isEmpty && loadedThumb.isEmpty {
                    loaded = loaded.replacingAvatars(
                        avatarURL: chatFull.isEmpty ? nil : chatFull,
                        avatarThumbnailURL: chatThumb.isEmpty ? nil : chatThumb
                    )
                }
            }
        }

        if viewingAsSelfPreview {
            // Prefer freshly loaded public projection; only fill gaps from owner state so
            // self-preview never shows owner empty-states for already-configured data.
            // Seed live My Team so national-fan sport subtitle matches the Account strip.
            loaded = loaded.seededForSelfPreview(
                homeCrowd: viewModel.currentUserHomeCrowdVenue,
                openToPreferences: viewModel.currentUserFanIdentityPreferences,
                primaryFavoriteTeamID: UserDefaults.standard.string(
                    forKey: FavoriteTeamsStore.primaryTeamIDAppStorageKey
                ),
                favoriteTeams: FavoriteTeamsStore.resolvedTeams(
                    from: UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
                ),
                profileBackgroundKey: viewModel.currentUserProfileBackgroundKey
            )
        }

        let chip = chatViewModel.chipKind(forOtherUserId: userId)
        let blocked = chatViewModel.isEitherDirectionBlocked(with: userId)
        let isSelf = viewModel.currentUserAuthId == userId
        let friendState = PublicUserProfileService.friendButtonState(
            for: userId,
            chipKind: chip,
            isBlocked: blocked,
            isSelf: isSelf,
            isBusiness: loaded.isBusinessAccount
        )

        await MainActor.run {
            SuggestedFanProfileOpenDebug.rendererConstructionStarted()
            profile = loaded
            isLoading = false
            identityLoadWarning = loaded.hasResolvedIdentity || !loaded.isPubliclyVisible
                ? nil
                : "Limited profile — identity still loading. Tap Retry."
            friendButtonState = friendState
            if loaded.isPubliclyVisible {
                SuggestedFanProfileOpenDebug.sheetPresented()
            } else {
                SuggestedFanProfileOpenDebug.failure("profile_unavailable_state")
            }
        }
    }

    private func canShowPokeControls(for targetUserId: UUID) -> Bool {
        guard let currentUserId = viewModel.currentUserAuthId else { return false }
        return currentUserId != targetUserId
    }

    private func loadPokeSummary(for targetUserId: UUID) async {
        guard canShowPokeControls(for: targetUserId) else {
            await MainActor.run {
                pokeSummary = nil
                pokeActionError = nil
                pokeJustSucceeded = false
            }
            return
        }

        do {
            let summary = try await profilePokesService.fetchPokeSummary(targetUserId: targetUserId)
            await MainActor.run {
                pokeSummary = summary
                pokeActionError = nil
            }
        } catch {
            await MainActor.run {
                pokeSummary = nil
                pokeActionError = "Couldn't load Pokes. Try again later."
            }
        }
    }

    private func sendPoke(to targetUserId: UUID) async {
        guard canShowPokeControls(for: targetUserId), !isPokeInFlight else { return }

        await MainActor.run {
            isPokeInFlight = true
            pokeActionError = nil
            pokeJustSucceeded = false
        }

        do {
            _ = try await profilePokesService.pokeProfile(targetUserId: targetUserId)
            PublicUserProfileProcessCache.invalidate(userId: targetUserId, reason: "poke")
            await loadPokeSummary(for: targetUserId)
            await MainActor.run {
                pokeJustSucceeded = true
                isPokeInFlight = false
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { pokeJustSucceeded = false }
            await loadPokeSummary(for: targetUserId)
        } catch let error as ProfilePokesServiceError {
            await MainActor.run {
                if case .onCooldown(let until) = error {
                    pokeActionError = Self.cooldownMessage(until: until)
                } else {
                    pokeActionError = error.localizedDescription
                }
                isPokeInFlight = false
            }
            await loadPokeSummary(for: targetUserId)
        } catch {
            await MainActor.run {
                _ = AgeAccessBackendDenial.handle(error, requestUserId: nil)
                pokeActionError = "Couldn't send poke. Try again."
                isPokeInFlight = false
            }
            await loadPokeSummary(for: targetUserId)
        }
    }

    private static func cooldownMessage(until raw: String?) -> String {
        guard let raw,
              let end = SupabaseTimestampParsing.parseTimestamptz(raw),
              end > Date() else {
            return "You can poke again soon"
        }
        let minutes = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
        return minutes < 60 ? "You can poke again in \(minutes)m" : "You can poke again soon"
    }

    private func refreshFriendButtonState() {
        guard let profile else {
            friendButtonState = .hidden
            return
        }
        let chip = chatViewModel.chipKind(forOtherUserId: userId)
        let blocked = chatViewModel.isEitherDirectionBlocked(with: userId)
        let isSelf = viewModel.currentUserAuthId == userId
        friendButtonState = PublicUserProfileService.friendButtonState(
            for: userId,
            chipKind: chip,
            isBlocked: blocked,
            isSelf: isSelf,
            isBusiness: profile.isBusinessAccount
        )
    }

    private func cancelOutgoingFriendRequest() async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
        }
        await chatViewModel.cancelOutgoingFriendRequest(to: userId)
        PublicUserProfileProcessCache.invalidate(userId: userId, reason: "cancelFriendRequest")
        await MainActor.run {
            isFriendActionInFlight = false
            refreshFriendButtonState()
        }
    }

    private func removeFriend() async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
            chatViewModel.unfriendError = nil
        }
        let preview = profile?.userPreviewForMessaging
        await chatViewModel.unfriend(peerUserId: userId, displayPreview: preview)

        let removalFailed = await MainActor.run { () -> Bool in
            if let error = chatViewModel.unfriendError, !error.isEmpty {
                friendActionError = error
                chatViewModel.unfriendError = nil
                isFriendActionInFlight = false
                refreshFriendButtonState()
                return true
            }
            return false
        }
        guard !removalFailed else { return }

        PublicUserProfileProcessCache.invalidate(userId: userId, reason: "removeFriend")
        if let viewerId = viewModel.currentUserAuthId {
            PublicUserProfileProcessCache.invalidate(userId: viewerId, reason: "removeFriend")
        }
        await MainActor.run {
            isFriendActionInFlight = false
            refreshFriendButtonState()
        }
        // Reload viewed profile so mutual/social chips stay consistent after friendship ends.
        await loadProfile()
        await MainActor.run {
            refreshFriendButtonState()
        }
    }

    private func requestFriendship(userId: UUID) async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
        }
        await chatViewModel.sendFriendRequest(to: userId)
        await chatViewModel.refresh()
        PublicUserProfileProcessCache.invalidate(userId: userId, reason: "friendRequest")
        await MainActor.run {
            isFriendActionInFlight = false
            refreshFriendButtonState()
        }
    }

    private func messageFriend(_ data: PublicUserProfileData) async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
        }
        let preview = data.userPreviewForMessaging
        do {
            _ = try await chatViewModel.startDirectConversationWithFriend(friendUserId: data.userId)
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            await MainActor.run {
                chatViewModel.pendingDmOpenPreview = preview
                onDismiss()
            }
        } catch {
            await MainActor.run {
                friendActionError = "Couldn't open chat. Try again."
                isFriendActionInFlight = false
            }
        }
    }
}

private extension PublicUserProfileData {
    var userPreviewForMessaging: UserPreview {
        let handleStored = publicHandleLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
            .lowercased()
        return UserPreview(
            id: userId,
            displayName: displayName,
            username: handleStored.isEmpty ? nil : handleStored,
            email: nil,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            isBusinessAccount: isBusinessAccount
        )
    }
}

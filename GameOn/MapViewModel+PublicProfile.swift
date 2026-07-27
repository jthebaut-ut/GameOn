import Foundation

extension MapViewModel {
    /// Cached `user_profiles` hints for public profile (pickup roster, comments-by-email map, etc.).
    func cachedUserProfileRowForPublicProfile(userId: UUID) -> UserProfileRow? {
        if userId == currentUserAuthId {
            return currentUserProfileRowForPublicProfileCache()
        }
        if let row = pickupJoinRequesterProfileByUserId[userId] {
            return row
        }
        return userProfilesByEmail.values.first { $0.id == userId }
    }

    /// Fresh signed-in fan row for public-profile loads (bio must match `user_profiles.bio`).
    func currentUserProfileRowForPublicProfileCache() -> UserProfileRow? {
        guard let authId = currentUserAuthId else { return nil }
        let email = OwnerBusinessEmail.normalized(currentUserEmail)
        guard OwnerBusinessEmail.isValidStrict(email) else { return nil }
        let trimmedBio = currentUserBio.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserProfileRow(
            id: authId,
            email: email,
            display_name: currentUserDisplayName,
            username: currentUserUsername.isEmpty ? nil : currentUserUsername,
            bio: trimmedBio.isEmpty ? nil : trimmedBio,
            avatar_url: currentUserAvatarURL,
            avatar_thumbnail_url: currentUserAvatarThumbnailURL,
            is_business_account: false,
            admin_status: "active",
            live_visibility_enabled: currentUserLiveVisibilityEnabled,
            live_visibility_mode: currentUserLiveVisibilityMode.rawValue,
            selected_live_visibility_friend_ids: Array(currentUserSelectedLiveVisibilityFriendIDs),
            discoverable_by_fans: currentUserDiscoverableByFans,
            created_at: currentUserProfileCreatedAt.isEmpty ? nil : currentUserProfileCreatedAt,
            national_team_country_code: currentUserNationalTeam?.countryCode,
            national_team_country_name: currentUserNationalTeam?.countryName,
            national_team_flag: currentUserNationalTeam?.flag,
            national_team_supporter_label: currentUserNationalTeam?.supporterLabel,
            profile_background_key: currentUserProfileBackgroundKey.rawValue
        )
    }

    /// Opens the root-level public profile presenter.
    /// - Parameters:
    ///   - userId: Profile to show.
    ///   - context: Debug / sheet-hint context.
    ///   - activeSheet: Optional active sheet name for debug.
    ///   - isSelfPreview: When `true`, allows opening the signed-in user's own public profile for WYSIWYG preview.
    func presentPublicProfile(
        userId: UUID,
        context: String = "",
        activeSheet: String? = nil,
        isSelfPreview: Bool = false
    ) {
        if userId == currentUserAuthId {
            guard isSelfPreview else {
                SuggestedFanProfileOpenDebug.failure("self_without_preview_context")
                return
            }
        } else if isSelfPreview {
            SuggestedFanProfileOpenDebug.failure("self_preview_id_mismatch")
            return
        }

        let sheetHint = activeSheet ?? context
        let alreadyPresented = publicProfileSheetUserId == userId

        if context.contains("suggested_fan") {
            SuggestedFanProfileOpenDebug.presentationStarted(alreadyPresented: alreadyPresented)
        }

        publicProfileIsSelfPreview = isSelfPreview && userId == currentUserAuthId
        publicProfilePresentationContext = context
        publicProfileSheetUserId = userId

#if DEBUG
        print("[PublicProfileTapDebug] userId=\(userId.uuidString.lowercased()) context=\(context) authenticated=\(isAuthenticatedForSocialFeatures) selfPreview=\(publicProfileIsSelfPreview)")
        print("[PublicProfilePresentationDebug] tapContext=\(context)")
        print("[PublicProfilePresentationDebug] presenter=custom_overlay")
        print("[PublicProfilePresentationDebug] swiftUIModalUsed=false")
        print("[PublicProfilePresentationDebug] activeSheet=\(sheetHint)")
        print("[PublicProfilePresentationDebug] presentedImmediately=true")
        print("[PublicProfilePresentationDebug] queued=false")
        print("[PublicProfilePresentationDebug] selfPreview=\(publicProfileIsSelfPreview)")
#endif
    }

    /// Opens the public-profile overlay for the signed-in fan (same path as viewing another fan).
    func presentOwnPublicProfilePreview() {
        guard let authId = currentUserAuthId else { return }
        presentPublicProfile(
            userId: authId,
            context: "own_public_profile_preview",
            activeSheet: "Account",
            isSelfPreview: true
        )
    }

    func dismissPublicProfile() {
        publicProfileSheetUserId = nil
        publicProfilePresentationContext = nil
        publicProfileIsSelfPreview = false
        SuggestedFanProfileOpenDebug.sheetDismissed()
#if DEBUG
        print("[PublicProfilePresentationDebug] presenter=custom_overlay")
        print("[PublicProfilePresentationDebug] swiftUIModalUsed=false")
        print("[PublicProfilePresentationDebug] overlayWindowUsed=false")
        print("[PublicProfilePresentationDebug] selfPreview=false")
#endif
    }
}

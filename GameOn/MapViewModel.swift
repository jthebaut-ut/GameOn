import Foundation
import SwiftUI
import UIKit
import MapKit
import Combine
import CoreLocation
import EventKit
import Supabase

enum FanGeoAuthSessionState: String {
    case loadingSession
    case signedOut
    case signedIn
    case deletedAccountConfirmed
    case deletedBusinessAccountConfirmed
    case authRefreshFailed
}

enum PasswordResetSheetMode: String {
    case requestLink
    case createPassword
}

enum EmailVerificationAccountKind: String {
    case fan
    case business
}

/// One-time post-signup UI intents that survive email-confirm / root remount transitions.
enum PostSignupPresentation: String, Equatable {
    case discoverWelcomeGuide
}

enum AppleAuthAccountMode: String {
    case fan
    case business
}

enum AppleAuthEntryPoint: String {
    case signIn
    case fanSignup
    case businessSignup
}

/// Central `@MainActor` observable object: map camera and selection, venue and schedule data, Supabase auth, venue-owner tools, favorites, and social (interests, comments, vibes).
///
/// Feature code is split across `MapViewModel+*.swift` extensions. This declaration holds `@Published` state, `EventKit` store, and static sample references.
@MainActor
final class MapViewModel: ObservableObject {
    
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard !Calendar.current.isDate(oldValue, inSameDayAs: selectedDate) else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "selectedDate")
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=selectedDate")
#endif
            scheduleInitialVenueGameCardGoingRefresh(reason: "selectedDate")
        }
    }
    /// Bottom-tab Calendar only (never drives Discover map date).
    @Published var calendarTabSelectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var calendarTabGameFilter: CalendarTabGameFilter = .venueGames
    /// Guest Discover: set when the user confirms a date from the map calendar (`Done`); blocks automatic “jump to next day with games” for that cold start / session.
    var discoverCalendarGuestUserPinnedDateThisSession: Bool = false
    @Published var selectedSport: String = "All" {
        didSet {
            guard oldValue != selectedSport else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "selectedSport")
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=selectedSport")
#endif
            scheduleInitialVenueGameCardGoingRefresh(reason: "selectedSport")
        }
    }
    @Published var selectedEvent: SportsEvent?
    @Published var selectedBar: BarVenue? {
        didSet {
            guard oldValue?.id != selectedBar?.id else { return }
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=selectedBar")
#endif
            scheduleInitialVenueGameCardGoingRefresh(
                reason: selectedBar == nil ? "selectedBarCleared" : "selectedBar"
            )
        }
    }
    @Published var searchText: String = ""
    var pendingCitySearchVenueDebugContext: CitySearchVenueDebugContext?
    /// Debounced copy of ``searchText`` for Discover map/event filtering and live venue suggestions (see ``MapViewModel+DiscoverSearch``).
    @Published var debouncedDiscoverSearchText: String = "" {
        didSet {
            guard oldValue != debouncedDiscoverSearchText else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "debouncedDiscoverSearchText")
        }
    }
    /// Optional venue-ID allowlist applied after selecting a Discover game/sport/league search result.
    @Published var discoverSearchVenueIDFilter: Set<UUID>? = nil {
        didSet {
            guard oldValue != discoverSearchVenueIDFilter else { return }
            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "discoverSearchVenueIDFilter")
        }
    }
    /// Compact status shown after applying a Discover venue-event search selection.
    @Published var discoverSearchFilterStatusText: String? = nil
    @Published var favoriteVenueIDs: Set<UUID> = []
    @Published var interestedVenueEventKeys: Set<String> = []
    /// Prevents overlapping save/remove writes for the same venue while keeping the UI on the optimistic state.
    var favoriteVenueWriteInFlightIDs: Set<UUID> = []
    /// Prevents overlapping going/interested writes for the same event while keeping the UI on the optimistic state.
    @Published var venueEventInterestWriteInFlightIDs: Set<UUID> = []
    /// Target Going state for in-flight venue-event interest writes. Distinguishes add vs remove so optimistic un-going can hide immediately.
    var venueEventInterestPendingTargets: [UUID: Bool] = [:]
    /// Short-lived local Going confirmations so Supabase reloads cannot flash the UI back to not-going.
    var recentlyConfirmedVenueEventGoingAt: [UUID: Date] = [:]
    /// Short-lived local not-going confirmations so reloads cannot re-add a deleted row before read replicas catch up.
    var recentlyConfirmedVenueEventNotGoingAt: [UUID: Date] = [:]
    let venueEventInterestLocalReconcileTTL: TimeInterval = 15
    @Published var selectedTimeZone: FanGeoTimeZonePreference = FanGeoTimeZoneStore.load() {
        didSet {
            guard oldValue != selectedTimeZone else { return }
            FanGeoTimeZoneStore.save(selectedTimeZone)
        }
    }
    /// Bumped when the device time zone may have changed while Automatic is selected.
    @Published private(set) var automaticTimeZonePresentationToken = UUID()
    var automaticTimeZoneChangeObserver: AutomaticTimeZoneChangeObserver?
    @Published var isLoggedIn: Bool = false
    @Published var authSessionState: FanGeoAuthSessionState = .signedOut
    /// Session-owned logout UI phase. Progress overlay must not live in Settings `@State`.
    @Published var safeLogoutPhase: SafeLogoutPhase = .idle
    @Published var safeLogoutFailureMessage: String = ""
    /// MainTabView observes this to force Discover after a successful safe logout (without mounting Account).
    @Published var safeLogoutNeedsDiscoverReset = false
    /// Source string for the in-flight safe logout (DEBUG / dedupe).
    var safeLogoutSource: String = ""
    var safeLogoutTask: Task<Void, Never>?
    var safeLogoutStartedAt: Date?
    /// Network-independent watchdog that clears the logout overlay if MainTabView's
    /// `safeLogoutNeedsDiscoverReset` acknowledgement is missed (e.g. the root remounted).
    var safeLogoutWatchdogTask: Task<Void, Never>?
    /// True once the local Supabase session has been provably invalidated for the in-flight
    /// logout. The watchdog refuses to finalize the overlay unless this is set.
    var safeLogoutLocalSessionInvalidated = false
    /// Session-owned login UI phase. Progress overlay must not live in auth-sheet `@State`.
    @Published var safeLoginPhase: SafeLoginPhase = .idle
    /// MainTabView observes this to force Discover after a successful safe login (account-switch safety).
    @Published var safeLoginNeedsDiscoverReset = false
    var safeLoginMethod: SafeLoginMethod?
    var safeLoginSource: String = ""
    var safeLoginGeneration: UInt64 = 0
    var safeLoginTask: Task<Void, Never>?
    var safeLoginStartedAt: Date?
    var safeLoginAuthCompletedAt: Date?
    /// Last fan login email used when a deleted tombstone profile blocked entry (support contact UI).
    @Published var blockedDeletedAccountAttemptEmail: String = ""
    /// Last business login email used when a deleted business tombstone blocked entry (support contact UI).
    @Published var blockedDeletedBusinessAttemptEmail: String = ""
    /// Last deleted business id captured when login was blocked (support contact UI).
    @Published var blockedDeletedBusinessAttemptBusinessId: UUID? = nil
    /// Last resolved business lifecycle snapshot (support prefill + deleted-business gate).
    var lastResolvedBusinessLifecycleSnapshot: BusinessLifecycleSnapshot?
    @Published var currentUserEmail: String = ""
    /// Supabase Auth user id; mirrors ``supabase.auth.session.user.id`` when signed in (fan session).
    @Published var currentUserAuthId: UUID? {
        didSet {
            guard oldValue != currentUserAuthId else { return }
            clearSavedProGamesForSessionBoundary()
            guard let userID = currentUserAuthId else {
                return
            }
            reloadSavedProGamesFromStorage(for: userID)
            Task { await fetchSavedProGames(reason: "currentUserAuthIdChanged") }
            Task {
                await PushNotificationRegistrationService.shared.refreshPushTokenRegistration(reason: "currentUserAuthIdChanged")
                await loadProGameNotificationPreferencesFromBackend(reason: "currentUserAuthIdChanged")
            }
        }
    }
    @Published var activeAccountBan: FanGeoAccountBan?
    @Published var isCheckingActiveBan = false
    @Published var activeBusinessAccountBan: FanGeoAccountBan?
    @Published var isCheckingActiveBusinessBan = false
    @Published var isBusinessBanGatePresented = false
    @Published var isBusinessOwnerSessionRestorePending = false
    /// Single-flight deferred business hydration after launch (auth restore + warm preload share this).
    var deferredBusinessOwnerHydrationTask: Task<Void, Never>?
    /// Single-flight + short freshness gate for `ensureBusinessOwnerSessionFlagsIfPossible`, so
    /// near-simultaneous triggers (Discover `.task` and `onAppear`) share one round of RPCs.
    var businessOwnerSessionFlagsEnsureTask: Task<Bool, Never>?
    var businessOwnerSessionFlagsEnsureIdentity: String?
    var businessOwnerSessionFlagsLastValidation: (identity: String, result: Bool, at: Date)?
    var authSessionRestoreID: UUID?
    /// Bumped whenever private authenticated state is explicitly cleared so sibling view models can synchronously wipe their own caches.
    @Published var privateSessionClearNonce: UUID = UUID()
    /// Shared social/chat auth gate: regular fan auth, business-owner auth, or an already-restored Supabase session id.
    var isAuthenticatedForSocialFeatures: Bool {
        isLoggedIn || isVenueOwnerLoggedIn || currentUserAuthId != nil
    }
    @Published var favoriteTeamProGames: [FavoriteTeamProGame] = []
    @Published var favoriteTeamProGameAlertOverrides: [String: FavoriteTeamProGameAlertOverride] = [:]
    @Published var businessFavoriteTeamIDs: Set<String> = []
    @Published var businessFavoriteTeamProGames: [FavoriteTeamProGame] = []
    var businessFavoriteTeamsLoadedBusinessId: UUID?
    /// Discover map and public pickup rows: no fan session and no venue-owner session (same as ``!isAuthenticatedForSocialFeatures``).
    var isGuestDiscoverMode: Bool {
        !isAuthenticatedForSocialFeatures
    }
    /// True only when the active authenticated session is currently operating as a venue-owner/business account.
    var hasAuthenticatedVenueOwnerSession: Bool {
        isVenueOwnerLoggedIn
            && venueOwnerMode
            && currentUserAuthId != nil
            && OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(venueOwnerEmail))
    }
    /// Back-compat alias for older Following/favorites call sites.
    var hasSupabaseSessionForFollowingTab: Bool {
        isAuthenticatedForSocialFeatures
    }
    @Published var venueOwnerMode: Bool = false
    /// `public.venues.id` for the signed-in venue owner’s active profile row, when loaded (used for ``venue_events.venue_id`` on insert).
    @Published var ownerVenueDatabaseId: UUID?
    /// `public.businesses` rows for the signed-in venue owner (`owner_email` + active); see ``refreshOwnedBusinessesAndVenuesAfterOwnerLogin()``.
    @Published var ownedBusinesses: [BusinessRow] = []
    /// UI-only archived `public.businesses` rows for the signed-in venue owner. Never used to unlock tools or resolve active business ids.
    @Published var archivedOwnedBusinesses: [BusinessRow] = []
    /// `public.venues` rows linked via `business_id` to ``ownedBusinesses``.
    @Published var ownedBusinessVenues: [VenueProfileRow] = []
    /// Latest effective business entitlement used for venue plan-lock UI and gates.
    @Published var effectiveBusinessMembershipStatus: BusinessVenueGamePostingStatus?
    var businessVenuePlanLockSyncInFlight = false
    var lastBusinessVenuePlanLockSyncAt: Date?
    /// Last successful lightweight Business Dashboard preload, kept in memory for fast first paint.
    @Published var businessDashboardPreloadSnapshot: BusinessDashboardPreloadSnapshot?
    var businessDashboardPreloadInFlightKey: String?
    var businessDashboardPreloadTask: Task<BusinessDashboardPreloadSnapshot?, Never>?
    /// Unapproved ``venue_claims`` rows for the signed-in owner / their businesses (Settings “Pending locations”; Phase C1).
    @Published var pendingVenueClaimsForSettings: [VenueClaimPendingSettingsRow] = []
    /// Rejected, not-yet-dismissed ``venue_claims`` for Settings (“Rejected locations”). Rows with ``rejection_acknowledged_at`` set are excluded at fetch time.
    @Published var rejectedVenueClaimsForSettings: [VenueClaimPendingSettingsRow] = []
#if DEBUG
    @Published var businessLocationRPCDebugDetails: String = ""
#endif
    /// From ``refreshVenueClaimStatusLineFromDatabase()`` scan of recent ``venue_claims`` by owner email: any row is rejected and ``rejection_acknowledged_at`` is unset.
    @Published var hasUnackedRejectedVenueClaimForOwnerEmail: Bool = false
    @Published var approvedVenueClaimMetadataByVenueID: [UUID: BusinessApprovedVenueClaimMetadata] = [:]
    /// Per-venue upcoming active game counts for the Managed Venues selector (batched `venue_events` fetch).
    @Published var managedVenueUpcomingGamesByVenueId: [UUID: ManagedVenueUpcomingGamesSummary] = [:]
    /// Per-venue approved ownership resolved from `venue_claims.venue_id` for Venue Detail claim visibility.
    @Published var approvedVenueOwnershipByVenueID: [UUID: ApprovedVenueOwnershipSummary] = [:]

    /// Red rejection chrome / modals: unacked rejections from email-scoped status refresh and/or business-scoped Settings list.
    var hasActiveVenueClaimRejectionForBusinessUI: Bool {
        hasUnackedRejectedVenueClaimForOwnerEmail || !rejectedVenueClaimsForSettings.isEmpty
    }
    /// When ``ownedBusinessVenues`` is empty, venues matched by ``venueOwnerEmail`` only (pre-backfill); used by ``primaryOwnedVenueForLegacyCompatibility()``.
    /// Pre-backfill venues keyed only by email; written only from ``MapViewModel+VenueOwnerAndClaims``.
    var legacyOwnerVenuesForEmailFallback: [VenueProfileRow] = []
    @Published var ownerVenueName: String = ""
    @Published var ownerVenueAddress: String = ""
    @Published var ownerVenueAddressLine2: String = ""
    @Published var ownerVenueCity: String = ""
    @Published var ownerVenueState: String = ""
    @Published var ownerVenueZipCode: String = ""
    @Published var ownerVenueCountry: String = BusinessLocationCountryPolicy.defaultCountryCode
    @Published var ownerVenueSupporterCountry: String = ""
    /// ITU dial country (ISO 3166-1 alpha-2) for ``ownerVenuePhone`` national portion; combined with local digits on save.
    @Published var ownerVenuePhoneDialISO: String = BusinessPhoneFields.defaultISO
    @Published var ownerVenuePhone: String = ""
    @Published var ownerVenueWebsite: String = ""
    @Published var ownerVenueDescription: String = ""
    @Published var ownerVenueFeatures: String = ""
    @Published var ownerVenuePrimarySport: String = "Soccer"
    @Published var isVenueOwnerLoggedIn: Bool = false
    @Published var venueOwnerEmail: String = ""
    @Published var venueClaimSubmitted: Bool = false
    @Published var venueClaimStatus: String = "Not submitted"
    @Published var venueBusinessEmail: String = ""
    @Published var venueProofNote: String = ""
    @Published var isAdminLoggedIn: Bool = false
    @Published var adminEmail: String = ""
    @Published var venueClaims: [VenueClaim] = []
    @Published var adminBusinessVenueOverrideSummaries: [AdminBusinessVenueOverrideSummary] = []
    @Published var isLoadingAdminBusinessVenueOverrides = false
    @Published var adminBusinessVenueOverrideMessage = ""
    @Published var liveOperationsPresenceMetrics: LiveOperationsPresenceMetrics = .empty
    @Published var venueIsApproved: Bool = false
    @Published var authErrorMessage = ""
    @Published var venueAuthErrorMessage = ""
    @Published var appleAuthFanMessage = ""
    @Published var appleAuthFanMessageIsError = false
    @Published var appleAuthBusinessMessage = ""
    @Published var appleAuthBusinessMessageIsError = false
    @Published var applePendingFanSignupEmail = ""
    @Published var applePendingFanSignupDisplayName = ""
    /// True after Sign in with Apple when fan profile onboarding should skip password creation.
    @Published var appleFanOnboardingPasswordBypassActive = false
    @Published var applePendingBusinessSignupEmail = ""
    @Published var applePendingBusinessSignupDisplayName = ""
    var appleAuthFanMessageAutoClearTask: Task<Void, Never>?
    var appleAuthBusinessMessageAutoClearTask: Task<Void, Never>?
    /// Set after a fan/user password-reset email is requested (`MapViewModel+AuthAndProfile`).
    @Published var userPasswordResetMessage = ""
    @Published var userPasswordResetError = ""
    @Published var isShowingPasswordResetCreateSheet = false
    @Published var passwordResetSheetMode: PasswordResetSheetMode = .requestLink
    @Published var isPasswordResetRequestSheetPresented = false
    @Published var isPasswordResetRecoverySessionActive = false
    @Published var passwordResetUpdateMessage = ""
    @Published var passwordResetUpdateError = ""
    @Published var pendingEmailVerificationEmail = ""
    @Published var pendingEmailVerificationKind: EmailVerificationAccountKind?
    @Published var emailVerificationMessage = ""
    @Published var emailVerificationError = ""
    /// True while an email-confirmation deep link is being exchanged / routed.
    @Published var resolvingEmailConfirmation = false
    /// Non-blocking success notice after verification when the user must sign in manually.
    @Published var emailVerifiedSignInNotice = ""
    var pendingFanEmailSignupDraft: PendingFanEmailSignupDraft?
    @Published var pendingBusinessEmailSignupDraft: PendingBusinessEmailSignupDraft?
    /// User explicitly chose to resume setup for the persisted draft email (Settings → Business auth sheet).
    @Published var resumePendingBusinessSetupForDraftEmail = false
    /// True only after signup sent verification, failed unconfirmed login, or explicit resume — not when the login email field merely matches the draft.
    @Published var businessEmailVerificationUIFlowActive = false

    var hasPendingBusinessEmailSignupDraft: Bool {
        pendingBusinessEmailSignupDraft != nil
    }

    var normalizedPendingBusinessDraftEmail: String? {
        guard let draft = pendingBusinessEmailSignupDraft else { return nil }
        let normalized = OwnerBusinessEmail.normalized(draft.email)
        guard OwnerBusinessEmail.isValidStrict(normalized) else { return nil }
        return normalized
    }

    func pendingBusinessDraftMatchesBusinessAuthEmail(_ email: String) -> Bool {
        guard let draftEmail = normalizedPendingBusinessDraftEmail else { return false }
        return OwnerBusinessEmail.normalized(email) == draftEmail
    }

    var pendingBusinessDraftMatchesTypedLoginEmail: Bool {
        pendingBusinessDraftMatchesBusinessAuthEmail(venueOwnerEmail)
    }

    /// Full verification waiting UI — never driven by typing a matching email alone.
    var shouldShowPendingBusinessEmailVerificationUI: Bool {
        guard pendingEmailVerificationKind == .business else { return false }
        if let draft = pendingBusinessEmailSignupDraft, draft.emailVerified { return false }
        if hasPendingVerifiedBusinessVenueSetup { return false }
        if businessEmailVerifiedNeedsVenueSetup { return false }
        if resumePendingBusinessSetupForDraftEmail { return true }
        return businessEmailVerificationUIFlowActive
    }

    /// Small sign-in banner when the typed email matches an unverified pending business draft.
    var shouldShowPendingBusinessSignupMatchingEmailBanner: Bool {
        guard !shouldShowPendingBusinessEmailVerificationUI else { return false }
        guard !shouldShowFullPendingVerifiedVenueSetupUI else { return false }
        guard !isVenueOwnerLoggedIn else { return false }
        guard pendingBusinessEmailSignupDraft != nil else { return false }
        guard pendingBusinessDraftMatchesTypedLoginEmail else { return false }
        return !hasPendingVerifiedBusinessVenueSetup
    }

    /// Post-verification venue wizard only when the signed-in session matches the draft email.
    var shouldShowFullPendingVerifiedVenueSetupUI: Bool {
        businessEmailVerifiedNeedsVenueSetup
    }

    /// Verified draft + matching typed login email, but not signed in yet.
    var shouldShowVerifiedPendingBusinessSignInPrompt: Bool {
        guard hasPendingVerifiedBusinessVenueSetup else { return false }
        guard !businessEmailVerifiedNeedsVenueSetup else { return false }
        return pendingBusinessDraftMatchesTypedLoginEmail || resumePendingBusinessSetupForDraftEmail
    }

    /// Optional resume chip for a different typed login email.
    var hasPendingBusinessSetupDraftForOtherEmail: Bool {
        guard pendingBusinessEmailSignupDraft != nil else { return false }
        if shouldShowPendingBusinessEmailVerificationUI { return false }
        if shouldShowFullPendingVerifiedVenueSetupUI { return false }
        if shouldShowVerifiedPendingBusinessSignInPrompt { return false }
        guard let draftEmail = normalizedPendingBusinessDraftEmail else { return false }
        let typed = OwnerBusinessEmail.normalized(venueOwnerEmail)
        if OwnerBusinessEmail.isValidStrict(typed) {
            return typed != draftEmail
        }
        return true
    }

    var pendingBusinessSetupResumeBannerMessage: String {
        guard let email = normalizedPendingBusinessDraftEmail else { return "" }
        if hasPendingVerifiedBusinessVenueSetup {
            return "Finish setup for \(email)"
        }
        return "Resume signup for \(email)"
    }

    @MainActor
    func activateResumePendingBusinessSetupForDraft() {
        guard let draftEmail = normalizedPendingBusinessDraftEmail else { return }
        resumePendingBusinessSetupForDraftEmail = true
        venueOwnerEmail = draftEmail
        if let draft = pendingBusinessEmailSignupDraft, !draft.emailVerified {
            pendingEmailVerificationEmail = draftEmail
            pendingEmailVerificationKind = .business
            businessEmailVerificationUIFlowActive = true
        }
    }

    @MainActor
    func clearResumePendingBusinessSetupIfLoginEmailChanged() {
        guard resumePendingBusinessSetupForDraftEmail,
              let draftEmail = normalizedPendingBusinessDraftEmail else { return }
        let typed = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(typed) else { return }
        if typed != draftEmail {
            resumePendingBusinessSetupForDraftEmail = false
        }
    }

    /// Verified business email with a preserved draft but no business row yet (venue wizard not submitted).
    var hasPendingVerifiedBusinessVenueSetup: Bool {
        guard let draft = pendingBusinessEmailSignupDraft,
              draft.emailVerified,
              !hasBusinessAccountForOwner() else {
            return false
        }
        guard pendingEmailVerificationKind != .business else { return false }
        return !draft.isVenueSubmissionReady
    }

    /// Same as ``hasPendingVerifiedBusinessVenueSetup`` and the signed-in auth session matches the draft email.
    var businessEmailVerifiedNeedsVenueSetup: Bool {
        guard hasPendingVerifiedBusinessVenueSetup else { return false }
        return pendingVerifiedBusinessVenueSetupSessionMatchesDraft
    }

    /// Verified draft preserved while the user is signed out and should sign in to continue venue setup.
    var hasPendingVerifiedBusinessVenueSetupAwaitingSignIn: Bool {
        guard hasPendingVerifiedBusinessVenueSetup else { return false }
        return !pendingVerifiedBusinessVenueSetupSessionMatchesDraft
    }

    var pendingVerifiedBusinessVenueSetupSessionMatchesDraft: Bool {
        guard let draft = pendingBusinessEmailSignupDraft,
              let _ = currentUserAuthId else {
            return false
        }
        let draftEmail = OwnerBusinessEmail.normalized(draft.email)
        let sessionEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else { return false }
        return sessionEmail == draftEmail
    }

    var businessVerifiedVenueSetupBannerMessage: String {
        if let draft = pendingBusinessEmailSignupDraft {
            let normalized = OwnerBusinessEmail.normalized(draft.email)
            if OwnerBusinessEmail.isValidStrict(normalized) {
                return "\(normalized) is verified. Add your first venue when you're ready."
            }
        }
        return "Your business email is verified. Add your first venue when you're ready."
    }
    var venueClaimAdminEmailQueuedClaimIDs: Set<String> = []
    /// Set after a venue-owner password-reset email is requested (same Auth API, separate UI feedback).
    @Published var venuePasswordResetMessage = ""
    @Published var venuePasswordResetError = ""
    @Published var venueClaimSubmittedDate = ""
    /// True while ``refreshOwnedBusinessesAndVenuesAfterOwnerLogin()`` is fetching businesses/venues (venue owner sheet loading indicator).
    @Published var isVenueOwnerBusinessDataLoading = false
    /// After successful business-owner signup (auth + business + first claim); drives a one-shot success card in the Business auth sheet until dismissed.
    @Published var venueOwnerJustCompletedRegistration: Bool = false
    /// When non-nil, the fan started a “Claim this business” flow from Discover for this public venue id (Phase A; not yet sent to `venue_claims` as `venue_id`).
    @Published var pendingClaimVenueID: UUID?
    @Published var pendingClaimVenueName: String = ""
    @Published var pendingClaimVenueAddress: String = ""
    @Published var pendingClaimVenueCity: String = ""
    @Published var pendingClaimVenueState: String = ""
    @Published var pendingClaimVenuePhone: String = ""
    @Published var pendingClaimVenueWebsite: String = ""
    @Published var pendingClaimPrimarySport: String = ""
    /// Switched to Account tab + venue auth sheet from Discover claim intent (consumed by ``MainTabView`` / ``SettingsScreen``).
    @Published var switchToAccountForVenueClaim: Bool = false
    /// One-shot post-signup Discover welcome-guide intent (account-scoped; consumed when the existing guide is presented).
    @Published var postSignupPresentation: PostSignupPresentation?
    var postSignupPresentationUserId: UUID?
    /// Bumps when a newly created account should see the language selector (UserDefaults-backed pending id).
    @Published var postAccountCreationLanguageSelectorRevision: Int = 0
    @Published var openVenueOwnerAuthSheetFromClaimFlow: Bool = false
    @Published var venueCoverPhotoURL = ""
    @Published var venueCoverPhotoThumbnailURL = ""
    var pendingVenueCoverPhotoVenueID: UUID?
    var pendingVenueCoverPhotoURL: String?
    var pendingVenueCoverPhotoThumbnailURL: String?
    @Published var venueCrowdPhotoURL = ""
    @Published var venueTVWallPhotoURL = ""
    @Published var venueMenuPhotoURL = ""
    @Published var venueMenuPhotoThumbnailURL = ""
    var pendingVenueMenuPhotoVenueID: UUID?
    var pendingVenueMenuPhotoURL: String?
    var pendingVenueMenuPhotoThumbnailURL: String?
    @Published var venueSpecialsPhotoURL = ""
    @Published var ownerVenueScreenCount: Int = 1
    @Published var ownerVenueServesFood: Bool = false
    @Published var ownerVenueHasWifi: Bool = false
    @Published var ownerVenueHasGarden: Bool = false
    @Published var ownerVenueHasProjector: Bool = false
    @Published var ownerVenuePetFriendly: Bool = false
    @Published var venueEventInterestIDs: Set<UUID> = []
    @Published var venueEventInterestCounts: [UUID: Int] = [:] {
        didSet {
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "venueEventInterestCounts")
            if discoverFocusedProGame != nil {
                scheduleDiscoverTopVenuesForFocusedGameRefresh(reason: "interestCounts")
            }
        }
    }
    let venueGameCardSnapshotStore = VenueGameCardSnapshotStore()
    var venueGameCardInitialGoingRefreshTask: Task<Void, Never>?
    var venueGameCardInitialGoingRefreshLastIDs: [UUID] = []
    let venueGameCardGoingSnapshotTTL: TimeInterval = 25
    @Published var venueEventPredictionSummaries: [UUID: VenueEventPredictionSummary] = [:]
    @Published var proGamePredictionSummaries: [String: ProGamePredictionSummary] = [:]
    var venueEventPredictionRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    var venueEventPredictionRealtimeChannels: [UUID: RealtimeChannelV2] = [:]
    var venueEventPredictionRealtimeRefreshTasks: [UUID: Task<Void, Never>] = [:]
    var proGamePredictionRealtimeTasks: [String: Task<Void, Never>] = [:]
    var proGamePredictionRealtimeChannels: [String: RealtimeChannelV2] = [:]
    var proGamePredictionRealtimeRefreshTasks: [String: Task<Void, Never>] = [:]
    let fanUpdatesStore = FanUpdatesRealtimeStore()

    var venueEventComments: [UUID: [VenueEventCommentRow]] {
        get { fanUpdatesStore.venueEventComments }
        set { fanUpdatesStore.venueEventComments = newValue }
    }
    /// Comment ids the signed-in fan has already reported (from successful submit, duplicate constraint, or REST sync).
    var commentIDsReportedByCurrentUser: Set<UUID> {
        get { fanUpdatesStore.commentIDsReportedByCurrentUser }
        set { fanUpdatesStore.commentIDsReportedByCurrentUser = newValue }
    }
    /// Per-thread realtime listener tasks for venue-event fan updates.
    var venueEventCommentsRealtimeTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentsRealtimeTasks }
        set { fanUpdatesStore.venueEventCommentsRealtimeTasks = newValue }
    }
    var venueEventCommentsRealtimeChannels: [UUID: RealtimeChannelV2] {
        get { fanUpdatesStore.venueEventCommentsRealtimeChannels }
        set { fanUpdatesStore.venueEventCommentsRealtimeChannels = newValue }
    }
    var venueEventCommentsRealtimeListenerTokens: [UUID: UUID] {
        get { fanUpdatesStore.venueEventCommentsRealtimeListenerTokens }
        set { fanUpdatesStore.venueEventCommentsRealtimeListenerTokens = newValue }
    }
    var venueEventCommentsRealtimeReadyIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentsRealtimeReadyIDs }
        set { fanUpdatesStore.venueEventCommentsRealtimeReadyIDs = newValue }
    }
    var venueEventCommentsRealtimeSubscribeStartedAt: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentsRealtimeSubscribeStartedAt }
        set { fanUpdatesStore.venueEventCommentsRealtimeSubscribeStartedAt = newValue }
    }
    var venueEventCommentsRealtimeLastEventAt: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentsRealtimeLastEventAt }
        set { fanUpdatesStore.venueEventCommentsRealtimeLastEventAt = newValue }
    }
    var venueEventCommentRealtimeReceivedServerIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentRealtimeReceivedServerIDs }
        set { fanUpdatesStore.venueEventCommentRealtimeReceivedServerIDs = newValue }
    }
    var venueEventCommentInsertSuccessTimesByServerID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentInsertSuccessTimesByServerID }
        set { fanUpdatesStore.venueEventCommentInsertSuccessTimesByServerID = newValue }
    }
    var venueEventCommentRealtimeFallbackTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentRealtimeFallbackTasks }
        set { fanUpdatesStore.venueEventCommentRealtimeFallbackTasks = newValue }
    }
    var fanChatReceiverRefreshBurstTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanChatReceiverRefreshBurstTasks }
        set { fanUpdatesStore.fanChatReceiverRefreshBurstTasks = newValue }
    }
    var fanChatAutoRefreshInFlightIDs: Set<UUID> {
        get { fanUpdatesStore.fanChatAutoRefreshInFlightIDs }
        set { fanUpdatesStore.fanChatAutoRefreshInFlightIDs = newValue }
    }
    var venueEventCommentReactionRealtimeTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeTasks }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeTasks = newValue }
    }
    var venueEventCommentReactionRealtimeChannels: [UUID: RealtimeChannelV2] {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeChannels }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeChannels = newValue }
    }
    var venueEventCommentReactionRealtimeReadyIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeReadyIDs }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeReadyIDs = newValue }
    }
    var venueEventCommentReactionRealtimeTrackedCommentIDs: [UUID: [UUID]] {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeTrackedCommentIDs }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeTrackedCommentIDs = newValue }
    }
    var venueEventCommentReactionDebounceTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentReactionDebounceTasks }
        set { fanUpdatesStore.venueEventCommentReactionDebounceTasks = newValue }
    }
    var venueEventCommentReactionFallbackPollTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentReactionFallbackPollTasks }
        set { fanUpdatesStore.venueEventCommentReactionFallbackPollTasks = newValue }
    }
    var venueEventCommentDebugSendTapDatesByLocalID: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentDebugSendTapDatesByLocalID }
        set { fanUpdatesStore.venueEventCommentDebugSendTapDatesByLocalID = newValue }
    }
    var venueEventCommentDebugSendTapTimesByServerID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentDebugSendTapTimesByServerID }
        set { fanUpdatesStore.venueEventCommentDebugSendTapTimesByServerID = newValue }
    }
    var venueEventCommentDebugReceivedDatesByServerID: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentDebugReceivedDatesByServerID }
        set { fanUpdatesStore.venueEventCommentDebugReceivedDatesByServerID = newValue }
    }
    var venueEventCommentDebugFallbackCommentIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentDebugFallbackCommentIDs }
        set { fanUpdatesStore.venueEventCommentDebugFallbackCommentIDs = newValue }
    }
    var venueEventCommentLatencySendTimesByLocalID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencySendTimesByLocalID }
        set { fanUpdatesStore.venueEventCommentLatencySendTimesByLocalID = newValue }
    }
    var venueEventCommentLatencySendTimesByServerID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencySendTimesByServerID }
        set { fanUpdatesStore.venueEventCommentLatencySendTimesByServerID = newValue }
    }
    var venueEventCommentLatencyLastSendTimeByEventID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencyLastSendTimeByEventID }
        set { fanUpdatesStore.venueEventCommentLatencyLastSendTimeByEventID = newValue }
    }
    var venueEventCommentLatencyInsertStartTimesByLocalID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencyInsertStartTimesByLocalID }
        set { fanUpdatesStore.venueEventCommentLatencyInsertStartTimesByLocalID = newValue }
    }
    @Published var venueEventIDsByKey: [String: UUID] = [:]
    @Published var visibleLatitudeDelta: Double = DiscoverMapRegionDefaults.worldSpan.latitudeDelta
    @Published var userProfilesByEmail: [String: UserProfileRow] = [:]
    @Published var reportedComments: [CommentReportRow] = []
    @Published var reportedCommentDisplays: [ReportedCommentDisplay] = []
    var venueEventVibeCounts: [UUID: [String: Int]] {
        get { fanUpdatesStore.venueEventVibeCounts }
        set {
            let previous = fanUpdatesStore.venueEventVibeCounts
            fanUpdatesStore.venueEventVibeCounts = newValue
            if previous != newValue {
                scheduleDiscoverMapRenderSnapshotRebuild(reason: "venueEventVibeCounts")
                if discoverFocusedProGame != nil {
                    scheduleDiscoverTopVenuesForFocusedGameRefresh(reason: "vibeCounts")
                }
            }
        }
    }
    var venueEventUniqueCommenterCounts: [UUID: Int] {
        get { fanUpdatesStore.venueEventUniqueCommenterCounts }
        set {
            let previous = fanUpdatesStore.venueEventUniqueCommenterCounts
            fanUpdatesStore.venueEventUniqueCommenterCounts = newValue
            if previous != newValue {
                scheduleDiscoverMapRenderSnapshotRebuild(reason: "venueEventUniqueCommenterCounts")
                if discoverFocusedProGame != nil {
                    scheduleDiscoverTopVenuesForFocusedGameRefresh(reason: "commenterCounts")
                }
            }
        }
    }
    var myVenueEventVibes: [UUID: Set<String>] {
        get { fanUpdatesStore.myVenueEventVibes }
        set { fanUpdatesStore.myVenueEventVibes = newValue }
    }
    var venueEventVibeWriteInFlightKeys: Set<String> {
        get { fanUpdatesStore.venueEventVibeWriteInFlightKeys }
        set { fanUpdatesStore.venueEventVibeWriteInFlightKeys = newValue }
    }
    var venueEventCommentLikeCountsByID: [UUID: Int] {
        get { fanUpdatesStore.venueEventCommentLikeCountsByID }
        set { fanUpdatesStore.venueEventCommentLikeCountsByID = newValue }
    }
    var venueEventCommentDownReactionCountsByID: [UUID: Int] {
        get { fanUpdatesStore.venueEventCommentDownReactionCountsByID }
        set { fanUpdatesStore.venueEventCommentDownReactionCountsByID = newValue }
    }
    var venueEventCommentIDsLikedByCurrentUser: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentIDsLikedByCurrentUser }
        set { fanUpdatesStore.venueEventCommentIDsLikedByCurrentUser = newValue }
    }
    var venueEventCommentViewerReactionsByID: [UUID: FanChatCommentReactionType] {
        get { fanUpdatesStore.venueEventCommentViewerReactionsByID }
        set { fanUpdatesStore.venueEventCommentViewerReactionsByID = newValue }
    }
    var venueEventCommentLikeWriteInFlightIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentLikeWriteInFlightIDs }
        set { fanUpdatesStore.venueEventCommentLikeWriteInFlightIDs = newValue }
    }
    
    let notificationSettingsStore = NotificationSettingsStore()

    var notifyBeforeGame: Bool {
        get { notificationSettingsStore.notifyBeforeGame }
        set { notificationSettingsStore.notifyBeforeGame = newValue }
    }

    var reminderMinutesBefore: Int {
        get { notificationSettingsStore.reminderMinutesBefore }
        set { notificationSettingsStore.reminderMinutesBefore = newValue }
    }

    var repeatGameReminder: Bool {
        get { notificationSettingsStore.repeatGameReminder }
        set { notificationSettingsStore.repeatGameReminder = newValue }
    }

    var repeatEveryMinutes: Int {
        get { notificationSettingsStore.repeatEveryMinutes }
        set { notificationSettingsStore.repeatEveryMinutes = newValue }
    }

    var syncGoingGamesToAppleCalendar: Bool {
        get { notificationSettingsStore.syncGoingGamesToAppleCalendar }
        set { notificationSettingsStore.syncGoingGamesToAppleCalendar = newValue }
    }

    var proGameKickoffAlertEnabled: Bool {
        get { notificationSettingsStore.proGameKickoffAlertEnabled }
        set { notificationSettingsStore.proGameKickoffAlertEnabled = newValue }
    }

    var proGameGameReminderEnabled: Bool {
        notificationSettingsStore.proGameGameReminderEnabled
    }

    var proGameReminderTiming: ProGameReminderTiming {
        get { notificationSettingsStore.proGameReminderTiming }
        set { notificationSettingsStore.proGameReminderTiming = newValue }
    }

    var favoriteTeamProGameReminderTiming: ProGameReminderTiming {
        get { notificationSettingsStore.favoriteTeamProGameReminderTiming }
        set { notificationSettingsStore.favoriteTeamProGameReminderTiming = newValue }
    }

    var favoriteTeamProGameReminderEnabled: Bool {
        notificationSettingsStore.favoriteTeamProGameReminderEnabled
    }

    var fanGeoAnnouncementNotificationsEnabled: Bool {
        get { notificationSettingsStore.fanGeoAnnouncementNotificationsEnabled }
        set { notificationSettingsStore.fanGeoAnnouncementNotificationsEnabled = newValue }
    }
    
    @Published var events: [SportsEvent] = SampleData.events
    @Published var isLoadingEvents: Bool = false
    /// True while schedule data is re-fetched but existing ``events``/UI should stay visible (Phase 1 perf).
    @Published var isRefreshingDiscoverEvents: Bool = false
    @Published var liveMatches: [LiveMatch] = []
    /// Bumped when ``liveMatches`` content changes (scores/status/minute/membership), not only count.
    /// Schedule Pro Games display cache + rebuild observe this so live updates publish without relying on count churn.
    @Published var scheduleLiveMatchesContentRevision: UInt64 = 0
    @Published var activeFeaturedEvents: [FeaturedEvent] = FeaturedEvent.fallbackEvents
    @Published var savedProGames: [SavedProGame] = []
    /// Lookup tables for saved-game hydration against ``liveMatches``; rebuilt when the snapshot changes.
    var liveMatchHydrationIndexCache: LiveMatchHydrationIndex?
    var savedProGamesFetchTask: Task<Void, Never>?
    var lastSavedProGamesFetchAt: Date?
    var lastSavedProGamesFetchUserId: UUID?
    var favoriteTeamProGamesRefreshTask: Task<Void, Never>?
    var lastFavoriteTeamProGamesRefreshAt: Date?
    var lastFavoriteTeamProGamesRefreshKey: String?
    var businessFavoriteTeamProGamesRefreshTask: Task<Void, Never>?
    var lastBusinessFavoriteTeamProGamesRefreshAt: Date?
    var lastBusinessFavoriteTeamProGamesRefreshKey: String?
    @Published var isLoadingLiveMatches: Bool = false
    @Published var sportsDataUpdateIndicatorVisible = false
    @Published var liveMatchesLoadError: String?
    /// DEBUG-only hint when Live Games is empty (provider/cache diagnostics).
    @Published var liveMatchesEmptyDebugHint: String?
    @Published var isUpdatingMapGames: Bool = false
    @Published var mapStatusText: String?
    /// When true, ``mapStatusText`` is a failure/unavailable state (not success).
    @Published var mapStatusIsError: Bool = false
    @Published var socialActionToastText: String?
    @Published var socialActionToastIsError: Bool = false
    var notificationPermissionMessage: String {
        get { notificationSettingsStore.notificationPermissionMessage }
        set { notificationSettingsStore.notificationPermissionMessage = newValue }
    }
    @Published var currentUserFanXP: FanXPState = .rookie
    @Published var currentUserFanIdentityPreferences: FanIdentityPreferences = .empty
    /// Bumped after Open To save so an open public profile sheet can reload fresh RPC data.
    @Published var publicProfileOpenToRevision: Int = 0
    /// Bumped after Home Crowd set/clear so an open public profile sheet can reload fresh RPC data.
    @Published var publicProfileHomeCrowdRevision: Int = 0
    /// Bumped after bio save so an open public profile sheet can reload fresh identity data.
    @Published var publicProfileBioRevision: Int = 0
    @Published var currentUserHomeCrowdVenueId: UUID?
    @Published var currentUserHomeCrowdVenue: HomeCrowdVenueSummary?
    @Published var fanXPRewardOverlay = FanXPRewardOverlayManager()
    @Published var wowMomentOverlay = WowMomentOverlayManager()
    /// When set, ``PublicProfileOverlayWindowPresenter`` shows ``PublicUserProfilePreviewView`` in a top-level UIWindow (not a SwiftUI sheet).
    @Published var publicProfileSheetUserId: UUID?
    /// True when the open public profile is the signed-in fan previewing their own public surface.
    @Published var publicProfileIsSelfPreview: Bool = false
    /// Latest avatar-tap context for presentation debug (not shown in UI).
    @Published var publicProfilePresentationContext: String?
    @Published var eventLoadError: String?
    @Published var bars: [BarVenue] = [] {
        didSet {
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "bars")
        }
    }
    @Published var isLoadingMapVenues: Bool = false
    /// True while map venues are re-fetched but existing ``bars`` should stay visible (Phase 1 perf).
    @Published var isRefreshingMapVenues: Bool = false
    /// Region-jump hint shown when the current viewport has no venue pins while Phase 1 is in flight or just completed empty.
    @Published var discoverRegionVenueLoadMessage: String?
    @Published var calendarUsesVisibleMapRegionOnly: Bool = false
    @Published var mapDisplayMode: DiscoverMapDisplayMode = .allSpots {
        didSet {
            guard oldValue != mapDisplayMode else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "mapDisplayMode")
        }
    }
    @Published var cameraPosition: MapCameraPosition = .region(DiscoverMapRegionDefaults.worldRegion)
    /// Last known GPS fix for the signed-in user (Discover weather, “my location”, startup centering).
    @Published var currentUserLocation: CLLocationCoordinate2D?
    @Published var calendarSyncMessage: String = ""
    /// Settings → Notifications manual "Sync Calendar" — survives leaving/returning to the card.
    @Published var appleCalendarSettingsManualSyncInFlight: Bool = false
    /// Settings → disable Apple Calendar sync with event removal (session overlay phase).
    @Published var appleCalendarRemovalPhase: AppleCalendarRemovalPhase = .idle
    @Published var venueEventRows: [VenueEventRow] = [] {
        didSet {
            scheduleFanChatAppLevelRealtimeForLoadedVenueEvents()
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "venueEventRows")
            if discoverFocusedProGame != nil {
                scheduleDiscoverTopVenuesForFocusedGameRefresh(reason: "venueEventRows")
            }
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=venueEventRows")
#endif
            scheduleInitialVenueGameCardGoingRefresh(reason: "venueEventRows")
        }
    }
    @Published private(set) var discoverMapRenderSnapshot = DiscoverMapRenderSnapshot.empty
    /// Monotonic fence for detached Discover map snapshot builds; only the latest request may publish.
    var discoverMapRenderSnapshotGeneration: UInt64 = 0
    /// Settled reverse-geocode / pin-derived locality for the current Discover viewport (never profile home).
    @Published var discoverSettledViewedLocalityLabel: String? = nil
    /// Coarse center bucket for ``discoverSettledViewedLocalityLabel`` (~0.05°).
    var discoverViewedLocalityCenterBucket: (lat: Int, lng: Int)?
    var discoverViewedLocalityResolveTask: Task<Void, Never>?
    /// Hysteresis latch for Nearby vs Viewing (nil until first distance sample).
    var discoverActivityPanelNearUserLatched: Bool?
    /// Bottom-tab Calendar selected (updated by ``MainTabView``); gates calendar-only preload/enrichment while tab is preserved off-screen.
    var isCalendarTabSelected = false
    var isLiveTabSelected = false
    /// Bottom-tab Discover selected (updated by ``MainTabView``); used only for Phase 3 off-tab perf instrumentation.
    var isDiscoverTabSelectedForEnrichment = true
    var scheduleTabInteractionProtected = false
    var liveSportsDataRefreshDepth = 0
    var pendingDeferredLiveMatches: [LiveMatch]?
    var deferredLiveMatchesApplyTask: Task<Void, Never>?
    var sportsDataUpdateIndicatorShowTask: Task<Void, Never>?
    var sportsDataUpdateIndicatorMaxVisibleHideTask: Task<Void, Never>?
    var pendingCalendarTabEventsListCacheInvalidation = false
    var userPreferencesWarmCacheTask: Task<Void, Never>?
    var lastUserPreferencesWarmCacheAt: Date?
    var lastUserPreferencesWarmCacheUserId: UUID?
    var lastProGameNotificationPreferencesLoadAt: Date?

    @MainActor
    var isLiveMatchesNetworkRefreshInFlight: Bool {
        liveMatchesRefreshTask != nil
    }
    /// When true, ``scheduleDiscoverMapRenderSnapshotRebuild(reason:)`` is a no-op until a single ``flushDiscoverMapRenderSnapshotRebuild(reason:)``.
    var suppressDiscoverSnapshotRebuilds = false
    /// Currently running detached Discover map snapshot build; cancelled when a newer rebuild supersedes it.
    var activeDiscoverSnapshotTask: Task<DiscoverMapSnapshotDetachedOutput?, Never>?
    var discoverSnapshotRebuildCoalesceTask: Task<Void, Never>?
    var discoverSnapshotPendingRebuildReason: String?
    let discoverSnapshotRebuildCoalesceNanoseconds: UInt64 = 100_000_000
    /// Start-of-day keys for calendar green dots (region + sport aware via ``eventsForCalendarDots``).
    @Published var calendarDotDates: Set<Date> = []
    /// Discover calendar overlay: venue ``venue_events`` days from RPC (green dots; Venues map mode only).
    @Published var venueGameCalendarDotDates: Set<Date> = []
    /// Discover calendar overlay: pickup ``game_start_at`` days with at least one map-eligible game in the current viewport (orange dots; Pickup games map mode).
    @Published var pickupGameCalendarDotDates: Set<Date> = []
    /// Bottom-tab Calendar Pro Games days loaded with a lightweight `live_matches.start_time` query.
    @Published var proGameCalendarDotDates: Set<Date> = []
    /// Discover map calendar: venue-game dot RPC in flight (see ``loadVenueGameCalendarDotsForDiscover``).
    @Published var isLoadingVenueCalendarDots: Bool = false
    /// Discover map calendar: pickup-game dot fetch in flight (see ``loadPickupGameCalendarDotsForDiscover``).
    @Published var isLoadingPickupCalendarDots: Bool = false
    @Published var isLoadingProGameCalendarDots: Bool = false
    @Published var calendarDotStatusText: String?
    @Published var currentUserDisplayName: String = ""
    /// Stored without `@`, lowercase — public FanGeo handle.
    @Published var currentUserUsername: String = ""
    @Published var currentUserBio: String = ""
    @Published var currentUserProfileCreatedAt: String = ""
    @Published var currentUserIsBusinessAccount: Bool = false
    @Published var currentUserAvatarURL: String = ""
    @Published var currentUserAvatarThumbnailURL: String = ""
    @Published var currentUserNationalTeam: NationalTeamIdentity?
    @Published var currentUserHomeCity: String = ""
    @Published var currentUserHomeRegion: String = ""
    @Published var currentUserHomeCountry: String = ""
    @Published var currentUserShowHomeCity: Bool = false
    /// `user_profiles.gender` raw token (`male` / `female` / …). Empty = unset.
    @Published var currentUserGenderRaw: String = ""
    /// Curated profile background catalog key (default FanGeo).
    @Published var currentUserProfileBackgroundKey: ProfileBackgroundKey = .fangeo
    @Published var isAuthSessionRestoringForProfilePresentation: Bool = false
    @Published var isUserProfileLoadingForPresentation: Bool = false
    @Published var hasLoadedUserProfileForPresentation: Bool = false
    @Published var userProfileExistsForPresentation: Bool = false
    @Published var currentUserLiveVisibilityEnabled: Bool = true
    @Published var currentUserLiveVisibilityMode: LiveVisibilityMode = .allFriends
    @Published var currentUserSelectedLiveVisibilityFriendIDs: Set<UUID> = []
    @Published var currentUserDiscoverableByFans: Bool = true
    @Published var currentUserActivityStatusVisible: Bool = true
    @Published var isUpdatingLiveVisibilitySetting: Bool = false
    @Published var isUpdatingProfileDiscoverabilitySetting: Bool = false
    @Published var isUpdatingActivityStatusVisibilitySetting: Bool = false
    /// Bumped after avatar profile save (and related clears) so UI uses a new `?v=` display URL while stored URLs stay canonical.
    @Published var currentUserAvatarDisplayRefreshToken: UUID = UUID()
    var authenticatedBusinessDisplayNameForSocialFeatures: String {
        if isVenueOwnerLoggedIn {
            if let firstNamed = ownedBusinesses
                .map(\.display_name)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return firstNamed
            }
            let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
            if !ownerEmail.isEmpty {
                return ownerEmail
            }
        }
        return ""
    }
    var authenticatedSocialDisplayName: String {
        if !authenticatedBusinessDisplayNameForSocialFeatures.isEmpty {
            return authenticatedBusinessDisplayNameForSocialFeatures
        }
        let current = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = authenticatedSocialEmailForUI
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? "" : local
    }

    /// Blocks app entry until a new fan sets display name + @handle (empty profile row after signup).
    var needsBlockingFanIdentitySetup: Bool {
        guard isLoggedIn, !isVenueOwnerLoggedIn else { return false }
        guard !isAuthSessionRestoringForProfilePresentation,
              !isUserProfileLoadingForPresentation,
              hasLoadedUserProfileForPresentation,
              userProfileExistsForPresentation else { return false }
        let name = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty && handle.isEmpty
    }

    var profileEditPresentationEvaluationKey: String {
        [
            isLoggedIn ? "loggedIn" : "loggedOut",
            isVenueOwnerLoggedIn ? "venueOwner" : "fan",
            isAuthSessionRestoringForProfilePresentation ? "restoring" : "restored",
            isUserProfileLoadingForPresentation ? "loading" : "notLoading",
            hasLoadedUserProfileForPresentation ? "loaded" : "notLoaded",
            userProfileExistsForPresentation ? "profileExists" : "profileMissing",
            currentUserAuthId?.uuidString.lowercased() ?? "noAuthId",
            currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "noName" : "hasName",
            currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "noHandle" : "hasHandle"
        ].joined(separator: "|")
    }

    /// True when no persisted @handle — existing users may still have a display name.
    var needsFanHandleSelection: Bool {
        guard isLoggedIn, !isVenueOwnerLoggedIn else { return false }
        return currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var currentUserPublicHandleLine: String {
        let base = FanGeoHandleRules.publicHandleLine(
            storedUsername: currentUserUsername,
            email: currentUserEmail
        )
        return FanGeoHandleRules.handleDisplayLine(
            base: base,
            profileCreatedAt: currentUserProfileCreatedAt,
            showFanSince: !currentUserIsBusinessAccount
        )
    }

    var currentUserVisibleHomeCityDisplayLine: String? {
        guard currentUserShowHomeCity else { return nil }
        return ProfileHomeCityIdentity.displayLine(
            city: currentUserHomeCity,
            region: currentUserHomeRegion,
            country: currentUserHomeCountry,
            languageCode: UserDefaults.standard.string(forKey: L10n.appLanguageKey)
        )
    }

    /// Best-effort current auth email for social UI decisions (comment ownership, friend chips, etc.).
    var authenticatedSocialEmailForUI: String {
        let fan = OwnerBusinessEmail.normalized(currentUserEmail)
        if OwnerBusinessEmail.isValidStrict(fan) { return fan }
        let business = OwnerBusinessEmail.normalized(venueOwnerEmail)
        if OwnerBusinessEmail.isValidStrict(business) { return business }
        return ""
    }
    @Published var goingUserProfiles: [UserProfileRow] = []
    @Published var venueSearchResults: [BarVenue] = []
    /// True while a debounced Discover query is fetching `venues` from Supabase (see ``MapViewModel+DiscoverSearch``).
    @Published var isDiscoverVenueSearchLoading: Bool = false
    /// Discover login gate: set to `true` to switch ``MainTabView`` to Account so the user can sign in (cleared by MainTabView).
    @Published var discoverNavigateToAccountForUserAuth: Bool = false
    /// Account / profile → Discover: focus a venue on the map and open its detail sheet.
    @Published var discoverFocusVenueId: UUID?
    /// Profile empty Home Crowd CTA → switch to Discover tab (cleared by MainTabView).
    @Published var requestDiscoverTabForHomeCrowd = false
    /// Announcement CTA → switch main tab (cleared by MainTabView).
    @Published var requestedMainTabRaw: String?
    /// Pro game reminder notification tap → Going tab / Pro Games / match detail.
    @Published var pendingProGameNotificationDeepLink: ProGameNotificationDeepLinkRequest?
    /// Deep link from a pickup end-of-game rating local notification → Going → Play → Playing.
    @Published var pendingPickupCreatorRatingNotificationDeepLink: PickupCreatorRatingNotificationDeepLinkRequest?
    /// Briefly highlights the Playing card targeted by a pickup rating notification deep link.
    @Published var pendingPickupPlayingHighlightGameID: UUID?
    /// Opens canonical pickup detail from an in-app chat share card (any tab).
    @Published var pendingSharedPickupGameDetailToken: PickupDetailNavigationToken?
    /// Chat → open shared professional game detail (`LiveMatchDetailSheet`).
    @Published var pendingSharedProGameDetailMatch: LiveMatch?
    @Published var pendingSupportReplyNotificationDeepLink: SupportReplyNotificationDeepLinkRequest?
    /// Remote poke APNs tap → open sender Fan Profile after auth/bootstrap.
    @Published var pendingPokeNotificationDeepLink: PokeNotificationDeepLinkRequest?
    /// Gate so cold-start taps wait for splash/bootstrap before presenting a profile.
    var pokeNotificationDeepLinkDeliveryAllowed = false
    /// Discover Activity Panel → Going / Account focus (consumed once by destination screens).
    @Published var pendingDiscoverTodayDashboardNav: DiscoverTodayDashboardNavIntent?
    /// Discover match-detail → Schedule Pro Games handoff (consumed once by CalendarScreen).
    @Published var pendingScheduleProGameNav: ScheduleProGameNavIntent?
    /// Brief Schedule Pro Games card highlight after Discover handoff.
    @Published var scheduleProGameHighlightStableKey: String?
    /// Focused professional game on Discover (`LiveMatch.id` == `VenueEventRow.external_game_id`).
    /// When set: map energy / Top venues are game-specific; when nil: selected-day venue energy.
    @Published var discoverFocusedProGame: DiscoverFocusedProGame? = nil {
        didSet {
            guard oldValue != discoverFocusedProGame else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "discoverFocusedProGame")
            scheduleDiscoverTopVenuesForFocusedGameRefresh(reason: "focusChanged")
        }
    }
    /// Ranked Top venues for ``discoverFocusedProGame`` in the current map region (energy DESC).
    @Published var discoverTopVenuesForFocusedGame: [DiscoverProGameWatchSpot] = []
    @Published var discoverTopVenuesForFocusedGameState: DiscoverProGameWatchSpotsLoadState = .idle
    var discoverTopVenuesRefreshTask: Task<Void, Never>?
    /// Eligible Discover banner announcements for carousel presentation (sorted).
    @Published var discoverBannerAnnouncements: [FanGeoAnnouncement] = []
    /// Resolved promoted venues for sponsored announcement cards (outside current map bounds).
    @Published var sponsoredPromotedVenueBarsByID: [UUID: BarVenue] = [:]
    @Published var sponsoredPromotedVenueLocationByID: [UUID: DiscoverSponsoredVenueLocationFields] = [:]
    var sponsoredPromotedVenuePrefetchTask: Task<Void, Never>?
    /// When set, ``SettingsScreen`` presents ``SettingsUserAuthSheet`` (same fan sheet as Account tab). Cleared when handled.
    @Published var presentFanUserAuthSheetFromDiscover: Bool = false
    /// Initial mode for ``SettingsUserAuthSheet`` when opened from Discover guest prompts.
    @Published var fanUserAuthSheetOpenInRegisterMode: Bool = false
    /// Guest heart-tap on a pro game: present the save-games sign-in prompt sheet.
    @Published var presentSaveProGameSignInPrompt: Bool = false
    /// Match the guest intended to favorite; completed once after successful fan login.
    var pendingSaveProGameMatch: LiveMatch?
    /// Tab to restore after login (`live` / `calendar` / `following`).
    var pendingSaveProGameReturnTabRaw: String?
    /// Dedupes automatic pending-favorite completion across auth change observers.
    var pendingSaveProGameCompletionToken: UUID?
    /// Following → Saved Venues: Discover tab consumes this to focus the map (see ``MapViewModel+FollowingMapNavigation``).
    @Published var pendingFollowingMapVenueID: UUID?
    /// Venue snapshot from Following so navigation works when ``bars`` does not yet include this id (map region elsewhere).
    @Published var pendingFollowingMapVenueSnapshot: BarVenue?
    /// Following → Hosting pickup game: Discover consumes this to focus the pickup map on the hosted game.
    @Published var pendingFollowingMapPickupGameID: UUID?
    /// Pickup row snapshot from Following so navigation works before the Discover pickup map has refreshed.
    @Published var pendingFollowingMapPickupGameSnapshot: PickupGameRow?
    /// Gates rapid “View Pickup Game” taps from Group Info (non-published; navigation-only).
    var isRoutingPickupGameFromChatGroupInfo = false
    /// Brief user-visible hint when opening a saved venue on the map fails (geocode / missing row).
    @Published var followingMapNavigationMessage: String?
    /// Per-venue-event interest avatars (Discover game rows). See ``loadGoingUserProfiles(for:)``.
    @Published var goingProfilesByVenueEventID: [UUID: [UserProfileRow]] = [:]
    var venueEventCommentPreviewCounts: [UUID: Int] {
        get { fanUpdatesStore.venueEventCommentPreviewCounts }
        set { fanUpdatesStore.venueEventCommentPreviewCounts = newValue }
    }
    var venueEventCommentPreviews: [UUID: [VenueEventCommentRow]] {
        get { fanUpdatesStore.venueEventCommentPreviews }
        set { fanUpdatesStore.venueEventCommentPreviews = newValue }
    }
    var fanChatAppLevelRealtimeTask: Task<Void, Never>? {
        get { fanUpdatesStore.fanChatAppLevelRealtimeTask }
        set { fanUpdatesStore.fanChatAppLevelRealtimeTask = newValue }
    }
    var fanChatAppLevelRealtimeChannel: RealtimeChannelV2? {
        get { fanUpdatesStore.fanChatAppLevelRealtimeChannel }
        set { fanUpdatesStore.fanChatAppLevelRealtimeChannel = newValue }
    }
    var fanChatAppLevelRealtimeTrackedEventIDs: [UUID] {
        get { fanUpdatesStore.fanChatAppLevelRealtimeTrackedEventIDs }
        set { fanUpdatesStore.fanChatAppLevelRealtimeTrackedEventIDs = newValue }
    }
    var fanChatAppLevelLastScheduleRequestedEventIDs: [UUID] {
        get { fanUpdatesStore.fanChatAppLevelLastScheduleRequestedEventIDs }
        set { fanUpdatesStore.fanChatAppLevelLastScheduleRequestedEventIDs = newValue }
    }
    var fanChatAppLevelRealtimeResubscribeTask: Task<Void, Never>? {
        get { fanUpdatesStore.fanChatAppLevelRealtimeResubscribeTask }
        set { fanUpdatesStore.fanChatAppLevelRealtimeResubscribeTask = newValue }
    }
    var fanChatAppLevelSeenCommentIDs: Set<UUID> {
        get { fanUpdatesStore.fanChatAppLevelSeenCommentIDs }
        set { fanUpdatesStore.fanChatAppLevelSeenCommentIDs = newValue }
    }
    var fanChatCommentCountReconcileTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanChatCommentCountReconcileTasks }
        set { fanUpdatesStore.fanChatCommentCountReconcileTasks = newValue }
    }
    var fanUpdatesCommentPrefetchTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanUpdatesCommentPrefetchTasks }
        set { fanUpdatesStore.fanUpdatesCommentPrefetchTasks = newValue }
    }
    var fanUpdatesVibePrefetchTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanUpdatesVibePrefetchTasks }
        set { fanUpdatesStore.fanUpdatesVibePrefetchTasks = newValue }
    }
    var discoverVisibleSocialPrefetchTasksByKey: [String: Task<Void, Never>] = [:]
    var fanUpdatesGoingProfilePrefetchTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesCommentPrefetchedAt: [UUID: Date] {
        get { fanUpdatesStore.fanUpdatesCommentPrefetchedAt }
        set { fanUpdatesStore.fanUpdatesCommentPrefetchedAt = newValue }
    }
    var fanUpdatesVibePrefetchedAt: [UUID: Date] {
        get { fanUpdatesStore.fanUpdatesVibePrefetchedAt }
        set { fanUpdatesStore.fanUpdatesVibePrefetchedAt = newValue }
    }
    var venueEventCommentReactionLastRefreshAt: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentReactionLastRefreshAt }
        set { fanUpdatesStore.venueEventCommentReactionLastRefreshAt = newValue }
    }
    var fanUpdatesGoingProfilePrefetchedAt: [UUID: Date] = [:]

    // MARK: - Pickup games (fan-created; see ``MapViewModel+PickupGames``)

    @Published var pickupGamesForDiscoverMap: [PickupGameRow] = []
    @Published var selectedPickupGameForMap: PickupGameRow?
    @Published var pickupPlacesForDiscoverMap: [PickupPlaceRow] = []
    @Published var selectedPickupPlaceForMap: PickupPlaceRow?
    @Published var isLoadingPickupPlacesForMap: Bool = false
    @Published var myPickupGamesForSettings: [PickupGameRow] = []
    /// Organizer soft-deleted games (`status = removed`), shown under History in Settings.
    @Published var myRemovedPickupGamesForSettings: [PickupGameRow] = []
    /// Going → Hosting: soft-delete in flight for past auto-clear deadline (idempotent).
    @Published var pickupHostingAutoClearInFlightIds: Set<UUID> = []
    /// Going → Hosting: auto-clear failed; show manual Clear expired fallback.
    @Published var pickupHostingAutoClearFailedIds: Set<UUID> = []
    @Published var isLoadingPickupGamesForMap: Bool = false
    /// Phase 2: pending / approved join request counts per game (organizer only; keyed by `pickup_games.id`).
    @Published var pickupOrganizerJoinStatsByGameId: [UUID: PickupOrganizerJoinStats] = [:]
    /// Join requests in `cancelled` / `withdrawn` state for games the user hosts (Settings → My pickup games).
    @Published var pickupOrganizerWithdrawnRequestsByGameId: [UUID: [PickupGameRequestRow]] = [:]
    /// Approved joiner user ids per hosted game (Settings roster strip); ordered from `pickup_game_requests` without extra joins.
    @Published var pickupOrganizerApprovedJoinerUserIdsByGameId: [UUID: [UUID]] = [:]
    /// Fan pickup creators: total `pending` join requests across their active games (Account tab avatar badge).
    @Published var pendingPickupGameJoinRequestCount: Int = 0
    /// Phase 2: latest join request from the current user per game (Discover detail / button state).
    @Published var pickupMyLatestJoinRequestByGameId: [UUID: PickupGameRequestRow] = [:]
    /// Privacy-safe public roster from `get_pickup_game_roster` (organizer + approved; pending only for organizer).
    @Published var pickupGameRosterByGameId: [UUID: PickupGameRosterPayload] = [:]
    /// Discover accent for Team-linked pickups the viewer can see (hex). Derived from `pickupDiscoverTeamIdentityByGameId`.
    @Published var pickupDiscoverTeamAccentHexByGameId: [UUID: String] = [:]
    /// Discover Team identity (name/logo/color) for Team-linked pickups the viewer can already see.
    @Published var pickupDiscoverTeamIdentityByGameId: [UUID: PickupDiscoverTeamIdentity] = [:]
    /// Play → Games membership scope (`all` vs `myTeams`). Session-only; orthogonal to sport/date.
    @Published var discoverPickupTeamScope: DiscoverPickupTeamScope = .all
    /// Active Fan Team ids for My Teams map scope (synced from `FanTeamIdentityRealtimeCoordinator`).
    @Published var discoverMyActiveFanTeamIds: Set<UUID> = []
    /// In-flight roster fetches (dedupe concurrent detail + sheet loads).
    @Published var pickupGameRosterInFlightGameIds: Set<UUID> = []
    /// Last roster load error per game (debug / sheet banner).
    @Published var pickupGameRosterErrorByGameId: [UUID: String] = [:]
    /// Phase 2: resolved creator display names for pickup detail (never stores email in UI).
    @Published var pickupCreatorDisplayNameByUserId: [UUID: String] = [:]
    /// Creator profile fields from `user_profiles` for pickup detail avatar (no schema change).
    @Published var pickupCreatorAvatarThumbnailURLByUserId: [UUID: String] = [:]
    @Published var pickupCreatorAvatarURLByUserId: [UUID: String] = [:]
    @Published var pickupCreatorEmailByUserId: [UUID: String] = [:]
    @Published var pickupCreatorAvatarTokenByUserId: [UUID: UUID] = [:]
    /// Join-request requester rows from `user_profiles` (Settings → My pickup games → Manage Requests).
    @Published var pickupJoinRequesterProfileByUserId: [UUID: UserProfileRow] = [:]
    /// Bumped when a join-requester profile loads so ``UserAvatarView`` refreshes thumbnails.
    @Published var pickupJoinRequesterAvatarTokenByUserId: [UUID: UUID] = [:]
    /// Discover map segmented control: venue clusters vs pickup pins only.
    @Published var discoverMapContentMode: DiscoverMapContentMode = .venues
    /// Pickup-only sub-toggle: physical places to play vs user-created games.
    /// Defaults to Places (broad browse), matching Watch’s All Spots default.
    @Published var discoverPickupSubMode: DiscoverPickupSubMode = .places {
        didSet {
            guard oldValue != discoverPickupSubMode else { return }
            selectedBar = nil
            selectedPickupGameForMap = nil
            selectedPickupPlaceForMap = nil
            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "discoverPickupSubMode")
        }
    }
    /// When `true`, entering pickup map mode should run ``refreshPickupGamesForDiscoverMap()`` (cleared after a successful refresh).
    var pickupDiscoverCoordinatorDirty: Bool = true
    /// Last visible-bounds window loaded from `public.pickup_places`.
    var lastPickupPlacesFetchKey: String?
    var pickupPlacesRegionalCache: [String: (rows: [PickupPlaceRow], fetchedAt: Date)] = [:]
    var pickupPlacesDiscoverRequestID: UUID?
    var pickupGamesDiscoverCache: [String: (rows: [PickupGameRow], fetchedAt: Date)] = [:]
    var pickupGamesDiscoverRequestID: UUID?

    // MARK: - Following tab (global; independent of Discover map region)

    /// Saved venues resolved from `favorite_venues` + `venues` by id (not filtered through ``bars``).
    @Published var followingTabSavedVenues: [BarVenue] = []
    /// Last successful ``refreshFollowingTabDataGlobally()`` completion (not published — avoids tab body churn).
    var lastFollowingTabGlobalRefreshAt: Date?
    /// Debounced Following Going-list reconcile after Discover card toggles (not published).
    var followingTabGoingReconcileTask: Task<Void, Never>?
    /// Games the user is going / interested in, loaded from Supabase + venue rows, independent of ``venueEventRows``.
    @Published var followingTabGoingItems: [FollowingGoingDisplayItem] = []
    /// Going / interest counts for ``followingTabGoingItems`` ids only (does not depend on map-visible interest fetch).
    @Published var followingTabGoingInterestCounts: [UUID: Int] = [:]
    /// All `venue_event_interests` rows for the current user (global), for Following attendance UI.
    @Published var followingTabUserVenueEventInterestIDs: Set<UUID> = []
    /// Following → Games to Play: pickup join requests for the current user (see ``loadMyPickupGameJoinRequestsForFollowing()``).
    @Published var myPickupGameJoinRequestCards: [PickupGameJoinRequestCardDisplay] = []
    /// Incoming friend invites for pickup/practice/scrimmage games.
    @Published var incomingPickupGameInvites: [PickupGameInviteDisplay] = []
    /// Latest join request row per pickup game for the signed-in fan (includes declined/rejected; excludes nothing except empty fetch). Following / pickup detail surfaces.
    @Published var pickupJoinRequestLatestByPickupGameIdForFan: [UUID: PickupGameRequestRow] = [:]
    var lightweightStartupPrefetchTask: Task<Void, Never>?
    var lastLightweightStartupPrefetchAt: Date?
    /// Monotonic auth/profile lifecycle token; bumped at logout/login start so stale async cleanup cannot affect a newer session.
    var accountProfileGeneration: UInt64 = 0
    /// Single owned profile load task for the active generation (cancelled/replaced on auth change).
    var profileLoadTask: Task<Void, Never>?
    var profileLoadOwnerUserId: UUID?
    var profileLoadOwnerGeneration: UInt64 = 0
    /// Identity token for the active owned profile-load task; stale completions cannot clear a newer task.
    var profileLoadTaskToken: UUID?
    var favoriteVenueIDsLoadTask: Task<Void, Never>?
    var lastFavoriteVenueIDsLoadAt: Date?
    var favoriteTeamsLoadTask: Task<Void, Never>?
    var lastFavoriteTeamsLoadAt: Date?
    /// Bumped when favorite teams are written into AppStorage so Profile/@AppStorage views refresh after login hydration.
    @Published var favoriteTeamsHydrationGeneration: Int = 0
    var followingTodayPlansLoadTask: Task<Void, Never>?
    var lastFollowingTodayPlansLoadAt: Date?
    var followingTabGlobalRefreshTask: Task<Void, Never>?
    var businessFanGeoPlusRefreshTask: Task<Void, Never>?
    var lastBusinessFanGeoPlusRefreshAt: Date?
    var myPickupGamesLightweightLoadTask: Task<Void, Never>?
    var lastMyPickupGamesLightweightLoadAt: Date?
    var incomingPickupInvitesLoadTask: Task<Void, Never>?
    var lastIncomingPickupInvitesLoadAt: Date?
    var calendarTabPickupSourcesRefreshTask: Task<Void, Never>?
    var lastCalendarTabPickupSourcesRefreshAt: Date?
    var lastCalendarTabPickupSourcesRefreshKey: String?
    var discoverAnnouncementFetchTask: Task<Void, Never>?
    var lastDiscoverAnnouncementFetchAt: Date?
    /// Debounces Discover-tab-visible network refreshes (Push Again / dismiss_version checks).
    var lastDiscoverTabVisibleAnnouncementRefreshAt: Date?
    var cachedDiscoverBannerCandidates: [FanGeoAnnouncement] = []
    /// Push-open focus: when set, Discover carousel shows only this announcement (if eligible).
    var focusedDiscoverAnnouncementId: UUID?
    /// True after the focused announcement has been shown in the Discover carousel.
    var focusedDiscoverAnnouncementDisplayed = false
    /// Set when the app leaves the foreground; cleared after a forced announcement refresh.
    var announcementsAppWasBackgrounded = false

    /// MainTabView tab-intent preload coordination (not published — avoids tab body churn).
    private(set) var tabIntentPreloadInFlight: Set<String> = []
    var lastTabIntentPreloadCompletedAt: [String: Date] = [:]

    func markTabIntentPreloadBegan(_ tabKey: String) {
        tabIntentPreloadInFlight.insert(tabKey)
    }

    func markTabIntentPreloadEnded(_ tabKey: String) {
        tabIntentPreloadInFlight.remove(tabKey)
        lastTabIntentPreloadCompletedAt[tabKey] = Date()
    }

    func isTabIntentPreloadInFlight(_ tabKey: String) -> Bool {
        tabIntentPreloadInFlight.contains(tabKey)
    }

    func didCompleteTabIntentPreloadRecently(_ tabKey: String, within interval: TimeInterval = 12) -> Bool {
        guard let last = lastTabIntentPreloadCompletedAt[tabKey] else { return false }
        return Date().timeIntervalSince(last) < interval
    }
    /// Bumped when join-request rows affecting organizer summaries may have changed (realtime / withdraw); drives ``PickupOrganizerRequestsSheet`` reload.
    @Published var pickupOrganizerRequestsSyncGeneration: UInt64 = 0
    /// Bumped after join-request mutations so pickup detail sheets reload request + counts.
    @Published var pickupJoinRequestUiRevision: UInt64 = 0
    /// Orange Following-tab / Games-to-Play activity: join/game field changed since last viewed Games to Play.
    @Published var hasUnreadPickupActivity: Bool = false
    /// Count of pickup games with unread activity (segment badge + tab hint).
    @Published var pickupActivityCount: Int = 0
    /// Account-tab badge when incoming pokes are newer than last acknowledgment.
    @Published var hasUnseenPokes: Bool = false
    @Published var unseenPokesCount: Int = 0
    /// Latest incoming poke timestamp from the most recent fetch (badge + acknowledgment).
    var latestTrackedIncomingPokeAt: Date?
    var unseenPokesBadgeRefreshTask: Task<Void, Never>?
    var lastUnseenPokesBadgeRefreshAt: Date?
    var lastUnseenPokesBadgeRefreshUserId: UUID?
    var pendingPickupJoinRequestCountLoadTask: Task<Void, Never>?
    var lastPendingPickupJoinRequestCountLoadAt: Date?
    var lastPendingPickupJoinRequestCountUserId: UUID?
    var lastPickupInviteForegroundRefreshAt: Date?
    /// Last successful Following pickup join-card reload; non-published so tab freshness checks do not redraw roots.
    var lastSuccessfulFollowingJoinRequestsRefreshAt: Date?
    var lastSuccessfulFollowingJoinRequestsRefreshUserId: UUID?
    /// In-flight Following join-list reload; coalesces concurrent activation/foreground callers.
    var followingJoinRequestsLoadTask: Task<Void, Never>?
    /// Last successful Following pickup join-list reload (Games to Play).
    @Published var lastJoinStatusRefreshAt: Date?
    /// Latest join request status string per pickup game id after the last reload (`pending`, `approved`, …).
    @Published var lastKnownJoinStatus: [UUID: String] = [:]
    /// Global pull-to-refresh / timer in progress for Games to Play list.
    @Published var isPickupFollowingJoinListRefreshing: Bool = false
    /// Per-game unread activity (card dot) until user opens Games to Play or refreshes that card.
    @Published var pickupFollowingUnreadActivityGameIds: Set<UUID> = []
    /// Manual per-card refresh spinner.
    @Published var pickupFollowingCardRefreshSpinGameId: UUID?
    /// Ensures ``resolvedPickupGameRow(for:)`` can open detail from Following when the game is not on the Discover map cache.
    var pickupGamesFollowingTabCache: [UUID: PickupGameRow] = [:]
    /// Organizer pickup trust line (avg stars + count); from ``pickup_creator_public_rating_stats`` RPC.
    @Published var pickupCreatorPublicRatingStatsByUserId: [UUID: PickupCreatorPublicRatingStats] = [:]
    /// Own-profile pickup organizer aggregates (`pickup_organizer_profile_summary`).
    @Published var myPickupOrganizerSummary: PickupOrganizerSummary = .empty
    var myPickupOrganizerSummaryLoadedForUserId: UUID?
    /// Last successful own-organizer-summary load; gates the Account-appear refresh so repeated
    /// visits within the window reuse cached aggregates (explicit force still bypasses it).
    var lastMyPickupOrganizerSummaryRefreshAt: Date?
    /// Fan identity preferences (`fan_identity_preferences`) load freshness + in-flight dedup.
    var fanIdentityPreferencesLoadTask: Task<Void, Never>?
    var lastFanIdentityPreferencesLoadAt: Date?
    var lastFanIdentityPreferencesLoadUserId: UUID?
    /// Discover / map card organizer aggregates (`pickup_organizer_profile_summary`), keyed by organizer.
    @Published var pickupOrganizerSummaryByUserId: [UUID: PickupOrganizerSummary] = [:]
    /// Last successful fetch time for ``pickupOrganizerSummaryByUserId`` freshness gating.
    var pickupOrganizerSummaryFetchedAtByUserId: [UUID: Date] = [:]
    /// In-flight organizer IDs for summary batching (dedupe concurrent card opens).
    var pickupOrganizerSummaryInFlightUserIds: Set<UUID> = []
    /// Per-organizer fetch generation so older in-flight responses cannot overwrite a newer forced refresh.
    var pickupOrganizerSummaryFetchGenerationByUserId: [UUID: UInt64] = [:]
    /// Pickup games the current user has already submitted an organizer rating for.
    @Published var pickupGameIdsWithMyCreatorRating: Set<UUID> = []
    /// Submitted star values keyed by pickup game (for “Rated” history UI).
    @Published var pickupMyCreatorRatingValueByGameId: [UUID: Int] = [:]
    /// Authoritative rating timestamps (`pickup_game_creator_ratings.created_at`) for post-rating Going retention.
    @Published var pickupMyCreatorRatingCreatedAtByGameId: [UUID: Date] = [:]
    /// Session-only: show Clear Now / Keep for Later once immediately after a successful rating submit.
    @Published var pickupCreatorRatingPostSubmitPromptGameIds: Set<UUID> = []
    /// Session-scoped “Not now” deferrals — keyed by authenticated user, cleared on logout.
    @Published var pickupCreatorRatingDeferredGameIds: Set<UUID> = []
    /// User id that owns ``pickupCreatorRatingDeferredGameIds`` / rating caches.
    var pickupCreatorRatingSessionUserId: UUID?

    // MARK: - Venue owner analytics (realtime)

    /// Postgres changes listener for ``VenueOwnerDashboardView`` analytics tab.
    var venueOwnerAnalyticsRealtimeTask: Task<Void, Never>?
    var venueOwnerAnalyticsRealtimeChannel: RealtimeChannelV2?
    var venueOwnerAnalyticsDebounceTask: Task<Void, Never>?
    /// Realtime: ``pickup_game_requests`` for the signed-in fan creator’s game ids (tab-bar pending badge).
    var pickupJoinRequestBadgeRealtimeTask: Task<Void, Never>?
    var pickupJoinRequestBadgeRealtimeChannel: RealtimeChannelV2?
    var pickupJoinRequestBadgeDebounceTask: Task<Void, Never>?
    /// Owner + tracked-game-id signature of the *active* pickup join-request badge channel, so
    /// repeated Account visits reuse the live subscription instead of tearing it down + recreating it.
    var pickupJoinRequestBadgeRealtimeOwnerUserId: UUID?
    var pickupJoinRequestBadgeRealtimeTrackedGameIds: [UUID]?
    /// Realtime: requester’s join rows + followed pickup games (Following → Games to Play).
    var pickupFollowingRealtimeTask: Task<Void, Never>?
    var pickupFollowingRealtimeChannel: RealtimeChannelV2?
    /// Realtime: incoming pickup-game invites for the signed-in invitee (Going badges + invite bell).
    var pickupInviteRealtimeTask: Task<Void, Never>?
    var pickupInviteRealtimeChannel: RealtimeChannelV2?
    var pickupInviteRealtimeDebounceTask: Task<Void, Never>?
    var pickupInviteRealtimeBoundUserId: UUID?
    /// Fan single-device session enforcement (`user_profiles.active_session_id`).
    var fanSingleSessionRealtimeChannel: RealtimeChannelV2?
    var fanSingleSessionRealtimeTask: Task<Void, Never>?
    var fanSingleSessionRealtimeDebounceTask: Task<Void, Never>?
    var isPerformingSingleSessionLogout = false
    var singleSessionIgnoreRealtimeUntil: Date?
    var pendingSingleSessionMismatch: (remoteId: String, localId: String, source: String, detectedAt: Date)?
    var pickupFollowingRealtimeDebounceTask: Task<Void, Never>?
    /// First successful Games-to-Play load completed; suppresses marking everything unread on cold start.
    var pickupFollowingActivityPrimed: Bool = false
    /// Per-game signature last acknowledged by the user (Play → Playing visible, detail open, or per-card refresh).
    /// Backed by UserDefaults (`gameon.following.pickupSeenActivitySignatures.<userId>`).
    var pickupFollowingSeenActivitySignatureByGameId: [UUID: String] = [:]
    /// User’s 1–5 star rating per venue (local mirror of server `venue_ratings`).
    @Published var venueUserStarRatings: [UUID: Int] = [:]
    /// Legacy local save counters (no longer authoritative for community counts).
    @Published var venueRatingContributionCount: [UUID: Int] = [:]
    /// Server aggregates from `get_venue_rating_stats` / `upsert_my_venue_rating`.
    @Published var venueRatingStatsByVenueId: [UUID: VenueRatingStats] = [:]

    enum MapPinDisplayMode {
        case simple
        case compact
        case detailed
    }

    let eventStore = EKEventStore()
    
    let sports = SampleData.sports
    let venueEvents = SampleData.venueEvents
    let venueExperiences = SampleData.venueExperiences
    let reminderMinuteOptions = [15, 30, 60, 120, 180, 1440]
    let repeatMinuteOptions = [15, 30, 60, 120]

    private var fanProfileAvatarChangeObserver: NSObjectProtocol?
    private var fanTeamIdentityChangeObserver: NSObjectProtocol?
    private var fanTeamMembershipSnapshotsObserver: NSObjectProtocol?

    init() {
        #if DEBUG
        print("[FanUpdatesStoreMigrationDebug] RemovedMapViewModelBridge=true")
        #endif
        restorePendingBusinessEmailSignupDraftIfNeeded()
        clearSavedProGamesForSessionBoundary()
        fanProfileAvatarChangeObserver = NotificationCenter.default.addObserver(
            forName: FanProfileChangeCenter.avatarDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = FanProfileChangeCenter.avatarChange(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.applyFanProfileAvatarChangeToLocalCaches(change)
            }
        }
        fanTeamIdentityChangeObserver = NotificationCenter.default.addObserver(
            forName: FanTeamIdentityChangeCenter.identityDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = FanTeamIdentityChangeCenter.identityChange(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.applyFanTeamIdentityChangeToDiscoverCaches(change)
            }
        }
        fanTeamMembershipSnapshotsObserver = NotificationCenter.default.addObserver(
            forName: FanTeamIdentityRealtimeCoordinator.membershipSnapshotsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncDiscoverMyActiveFanTeamIdsFromCoordinator()
            }
        }
        syncDiscoverMyActiveFanTeamIdsFromCoordinator()
    }

    deinit {
        if let fanProfileAvatarChangeObserver {
            NotificationCenter.default.removeObserver(fanProfileAvatarChangeObserver)
        }
        if let fanTeamIdentityChangeObserver {
            NotificationCenter.default.removeObserver(fanTeamIdentityChangeObserver)
        }
        if let fanTeamMembershipSnapshotsObserver {
            NotificationCenter.default.removeObserver(fanTeamMembershipSnapshotsObserver)
        }
    }

    /// Publishes a freshly built Discover map snapshot, skipping the publication
    /// when the new snapshot has render-identical content to the current one.
    ///
    /// Skipping an identical publish is output-equivalent: the map, activity
    /// panel, and wow-moment consumers derive their state from the snapshot's
    /// render content (or from `discoverMapRenderSnapshotGeneration`, which is
    /// bumped independently in `performDiscoverMapRenderSnapshotRebuild`), so an
    /// identical snapshot would produce identical UI. Returns `true` when the
    /// snapshot was actually published.
    @discardableResult
    func applyDiscoverMapRenderSnapshot(_ snapshot: DiscoverMapRenderSnapshot) -> Bool {
        if snapshot.hasIdenticalRenderContent(to: discoverMapRenderSnapshot) {
            Perf.publishedWriteSkipped(name: "discoverMapRenderSnapshot", reason: "identicalRenderContent")
            return false
        }
        discoverMapRenderSnapshot = snapshot
        return true
    }

    // MARK: - Discover / map venue_events fetch cache (region + sport + date window)

    /// In-memory reuse for identical region/sport/window fetches (see ``MapViewModel+VenueAndGameData``).
    var discoverVenueEventsFetchCache: (key: String, rows: [VenueEventRow], fetchedAt: Date)?
    /// Short-lived viewport cache for lightweight Discover venue rows (Phase 1 pins).
    var discoverViewportVenueRowsCache: [String: DiscoverViewportVenueRowsCacheEntry] = [:]
    /// Short-lived selected-day cache for visible Discover venue events (date + sport + visible venue context).
    var discoverSelectedDayVenueEventsCache: [String: (rows: [VenueEventRow], fetchedAt: Date)] = [:]
    /// Latest visible Discover venue context so date changes can reuse current pins without reloading venues.
    var discoverCurrentVisibleVenueRows: [VenueRow] = []
    var discoverCurrentVisibleVenueIds: [UUID] = []
    var discoverCurrentVisibleOwnerEmails: [String] = []
    var discoverCurrentVisibleVenueNames: [String] = []

    /// Memo for ``clusteredBars()`` so SwiftUI map body does not rebuild clusters every frame.
    var discoverClusteredBarsCacheKey: String?
    var discoverClusteredBarsCache: [VenueCluster]?
    /// Memo for ``clusteredPickupGamesForDiscoverMap(rows:)`` (pickup map mode only).
    var discoverPickupClustersCacheKey: String?
    var discoverPickupClustersCache: [PickupGameCluster]?

    /// Cancels stale debounced Discover search updates when ``searchText`` changes quickly.
    var discoverSearchDebounceTask: Task<Void, Never>?
    /// Skips one empty-search filter clear so applying a game result can clear the query without wiping the venue filter.
    var suppressDiscoverSearchFilterClearOnce = false
    /// Cached selected-date venue-event search index (invalidated when day/events/venues change).
    var discoverVenueEventSearchIndexCache: DiscoverVenueEventSearch.Index?
    var discoverVenueEventSearchIndexCacheKey: String?

    /// Discover-only: when set, ``pruneSelectionIfNeededAfterFilterChange()`` keeps ``selectedBar`` even if this id is absent from ``bars`` (remote text search venue with no games — not a default map pin).
    var discoverRemotePreviewHoldVenueId: UUID?

    /// Set when ``renderCachedDiscoverCore()`` (async) applied a disk snapshot this launch; suppresses empty-state loading chrome until fresh fetches finish.
    var discoverSnapshotRestoredThisLaunch = false
    /// Decoded Discover disk snapshot awaiting geo-validation against the startup camera.
    var pendingDiscoverCoreSnapshot: DiscoverCoreDiskSnapshot?
    /// When true, offscreen Discover skipped a snapshot publish; republish when the tab becomes visible.
    var discoverMapRenderSnapshotNeedsPublishWhenVisible = false

    /// Startup Discover: one-shot location + local region; ``defer`` arms preload completion logging even if the task is cancelled mid-await.
    var didFinishStartupDiscoverPrepare = false
    /// When false, startup must not overwrite the camera (user already panned/searched).
    var discoverStartupCameraOverrideEnabled = true
    /// Why the startup camera currently points where it does (GPS / locale / world / user).
    var discoverStartupCameraBasis: DiscoverStartupCameraBasis = .world
    /// Startup location timed out while the system permission dialog was still unanswered.
    var startupAwaitingLateLocationAuthorization = false
    /// Retains the late-auth Core Location observer for the duration of a pending grant.
    var lateStartupLocationAuthObserver: AnyObject?
    /// Suppresses treating map camera callbacks as user intent after a programmatic write.
    var discoverProgrammaticCameraWritePending = true
    /// Bumps on each programmatic camera write so delayed pending-clears stay ordered.
    var discoverProgrammaticCameraWriteGeneration: UInt64 = 0
    /// When true, the next ``refreshDiscoverCoreInBackground()`` logs ``[StartupDiscover] preloadCompleted`` (DEBUG).
    var startupDiscoverPreloadCompletionLogPending = false

    /// After the first successful Supabase games load, prefer ``isRefreshingDiscoverEvents`` over blocking ``isLoadingEvents``.
    var didCompleteSuccessfulGamesFetch = false

    /// Coalesces overlapping ``loadGamesFromSupabase()`` / ``refreshDiscoverCoreInBackground`` schedule work onto one serial chain.
    var loadGamesCoalesceTask: Task<Void, Never>?
    var loadGamesCoalesceNeedsAnotherPass = false
    /// Coalesces Calendar Live refreshes; no continuous UI polling.
    var liveMatchesRefreshTask: Task<Void, Never>?
    var calendarProGamesRefreshAtByDay: [String: Date] = [:]
    /// Fire-and-forget phase-3 Discover enrichment after pins are visible.
    var discoverFullEnrichmentTask: Task<Void, Never>?
    /// One-shot pickup calendar + map-row warmup after enrichment (not triggered by map pan).
    var discoverPickupMetadataPreloadTask: Task<Void, Never>?
    var discoverPickupMetadataPreloadCompleted = false
    var lastDiscoverCoreRefreshAt: Date?
    var lastLiveMatchesRefreshAt: Date?
    var lastCalendarTabBecameActiveAt: Date?
    var loadVenuesRequestID: UUID?
    var loadVenuesPhase1AppliedRequestID: UUID?
    var discoverSelectedDayRefreshTask: Task<Void, Never>?
    var discoverSelectedDayRefreshRequestID: UUID?
    var venueCalendarDotLoadTask: Task<Void, Never>?
    var pickupCalendarDotLoadTask: Task<Void, Never>?
    var venueCalendarDotLoadRequestID: UUID?
    var pickupCalendarDotLoadRequestID: UUID?
    /// Serializes overlapping ``refreshPickupGamesForDiscoverMap`` calls so calendar open + dot preload do not stack duplicate Supabase fetches.
    var refreshPickupGamesForDiscoverMapCoalescingTask: Task<Void, Never>?
    var pickupDiscoverEnrichmentRequestID: UUID?
    var mapStatusDismissTask: Task<Void, Never>?
    var socialActionToastDismissTask: Task<Void, Never>?
    var appleCalendarPickupSyncTask: Task<Void, Never>?
    var lastAppleCalendarPickupSyncAt: Date?
    var lastAppleCalendarPickupSyncKey: String?
    var appleCalendarGlobalSyncTask: Task<Void, Never>?
    var deferredProGamesCalendarReconcileTask: Task<Void, Never>?
    var proGameReminderDeferredReconcileTask: Task<Void, Never>?
    var proGameReminderPendingReconcileReason: String?
    var proGameReminderLastBatchFingerprint: String = ""
    var proGameReminderLastScheduledFingerprintByGame: [String: String] = [:]
    var proGameReminderLastBatchAt: Date?
    var lastAppleCalendarGlobalSyncAt: Date?
    var lastAppleCalendarGlobalSyncKey: String?

    /// Bumped when schedule-related data changes so calendar caches and dot fingerprints invalidate cheaply.
    var scheduleDataGeneration: UInt64 = 0

    /// Last inputs used for ``calendarDotDates``; avoids rescanning ``events`` when nothing relevant changed.
    var lastCalendarDotRecomputeKey: String?

    /// Short-lived Calendar tab list cache (see ``calendarScreenDisplayedEvents``; key includes ``CalendarTabGameFilter``).
    var calendarEventsListCache: [String: (storedAt: Date, events: [SportsEvent])] = [:]
    var venueGameCalendarDotDatesCache: [String: (dates: Set<Date>, fetchedAt: Date)] = [:]
    var pickupGameCalendarDotDatesCache: [String: (dates: Set<Date>, fetchedAt: Date)] = [:]
    var proGameCalendarDotDatesCache: [String: (dates: Set<Date>, fetchedAt: Date)] = [:]
    /// Last Discover map bounds bucket used for venue calendar dots (see ``discoverBoundsBucketString()``).
    var lastVenueCalendarDotBoundsBucket: String?
    /// Last non-nil Discover map viewport (session). Used when the live camera briefly reports nil.
    var lastStableDiscoverMapBounds: PickupGameMapBounds?
    /// While the Discover date picker is open, month-dot loads use this frozen geographic snapshot.
    var discoverDatePickerGeographicFreezeActive: Bool = false
    var discoverDatePickerFrozenMapBounds: PickupGameMapBounds?
    /// One deferred month-dot retry after bounds become available (no polling).
    var pendingPickupMonthDotRetryAfterBounds: (
        monthStart: Date,
        reason: String,
        requestID: UUID
    )?
    /// Debounced refresh of Discover venue calendar dots after map viewport / bar set changes.
    var discoverVenueCalendarDotPreloadTask: Task<Void, Never>?

    func refreshAutomaticTimeZonePresentationIfNeeded() {
        guard selectedTimeZone.isAutomatic else { return }
        automaticTimeZonePresentationToken = UUID()
        let zone = TimeZone.autoupdatingCurrent
        TimeZoneDebug.automaticZone(zone.identifier)
        TimeZoneDebug.displayedOffset(utcOffsetLabel(for: zone, at: Date()))
    }

    func startAutomaticTimeZoneChangeMonitoringIfNeeded() {
        guard automaticTimeZoneChangeObserver == nil else { return }
        let center = NotificationCenter.default
        let systemTimeZone = center.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.refreshAutomaticTimeZonePresentationIfNeeded()
            }
        }
        let significantTimeChange = center.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.refreshAutomaticTimeZonePresentationIfNeeded()
            }
        }
        automaticTimeZoneChangeObserver = AutomaticTimeZoneChangeObserver(
            systemTimeZone: systemTimeZone,
            significantTimeChange: significantTimeChange
        )
    }
}

import Combine
import Foundation

// MARK: - Authoritative Player Info selection (viewer preference)

/// Durable selection of which Team-scoped Player Info subject the viewer is viewing.
///
/// Canonical key: `fan_team_members.membership_id` (same seat identity as RSVP / lineup).
///
/// There is **no** existing Supabase column/RPC for this Overview preference — it is a
/// viewer UI choice over seats the account already owns/guards. Persistence is therefore
/// local and durable (`UserDefaults`), scoped by authenticated user + Team, so:
/// - leaving/reopening Team Detail keeps the choice
/// - app relaunch keeps the choice
/// - a fresh roster/seats reload re-applies the same membership_id
///
/// Does **not** rewrite membership, guardianship, or account identity.
enum FanTeamPlayerInfoSelectionStore {
    private static let keyPrefix = "FanGeo.TeamPlayerInfoSelection.v1."

    static func storageKey(userId: UUID, teamId: UUID) -> String {
        keyPrefix
            + userId.uuidString.lowercased()
            + "."
            + teamId.uuidString.lowercased()
    }

    /// Loads the persisted membership_id, or `nil` when unset/corrupt.
    static func load(userId: UUID, teamId: UUID, defaults: UserDefaults = .standard) -> UUID? {
        let key = storageKey(userId: userId, teamId: teamId)
        guard let raw = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let id = UUID(uuidString: raw) else {
            return nil
        }
        return id
    }

    /// Persists `membershipId` and verifies read-back. Returns `false` when verification fails.
    @discardableResult
    static func save(
        userId: UUID,
        teamId: UUID,
        membershipId: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = storageKey(userId: userId, teamId: teamId)
        let value = membershipId.uuidString.lowercased()
        defaults.set(value, forKey: key)
        let verified = load(userId: userId, teamId: teamId, defaults: defaults)
        return verified == membershipId
    }

    static func clear(userId: UUID, teamId: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(userId: userId, teamId: teamId))
    }

    /// Removes every Player Info selection key for `userId` (logout hygiene).
    static func clearAll(forUserId userId: UUID, defaults: UserDefaults = .standard) {
        let needle = keyPrefix + userId.uuidString.lowercased() + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(needle) {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - In-session race / generation guard

/// Protects Player Info selection against stale seat-catalog fetches overwriting a newer choice.
@MainActor
final class FanTeamPlayerInfoSelectionGuard: ObservableObject {
    /// Bumped on every user-confirmed selection write.
    private(set) var selectionEpoch: UInt64 = 0
    /// Bumped when a seats refresh starts; only the latest may apply results.
    private(set) var seatsRefreshGeneration: UInt64 = 0

    @discardableResult
    func beginSeatsRefresh() -> UInt64 {
        seatsRefreshGeneration &+= 1
        return seatsRefreshGeneration
    }

    func shouldApplySeatsRefresh(generation: UInt64) -> Bool {
        generation == seatsRefreshGeneration
    }

    @discardableResult
    func noteUserSelectionCommitted() -> UInt64 {
        selectionEpoch &+= 1
        return selectionEpoch
    }

    /// True when a newer user selection landed after `epochAtStart`.
    func isSelectionStaleRelative(to epochAtStart: UInt64) -> Bool {
        selectionEpoch != epochAtStart
    }
}

// MARK: - Pure reconciliation (testable)

enum FanTeamPlayerInfoSelectionReconciliation {
    /// Resolves the membership_id that should be shown after a catalog change.
    ///
    /// - `catalogComplete == false`: keep `preferred` sticky even if not yet present
    ///   (prevents mid-refresh fallback to account-self).
    /// - `catalogComplete == true`: preferred must be in `subjects` or we fall back.
    static func resolve(
        preferred: UUID?,
        subjects: [FanTeamPlayerInfoSubject],
        catalogComplete: Bool
    ) -> UUID? {
        if let preferred, subjects.contains(where: { $0.membershipId == preferred }) {
            return preferred
        }
        if !catalogComplete {
            return preferred
        }
        return FanTeamMyPlayerInfoPresentation.resolveSelectedMembershipId(
            preferred: preferred,
            subjects: subjects
        )
    }

    /// Whether a completed catalog should rewrite durable storage to `resolved`
    /// (preferred missing/invalid → fallback won).
    static func shouldRewriteDurableStore(
        previousPreferred: UUID?,
        resolved: UUID?,
        subjects: [FanTeamPlayerInfoSubject],
        catalogComplete: Bool
    ) -> Bool {
        guard catalogComplete, let resolved else { return false }
        guard let previousPreferred else { return true }
        if subjects.contains(where: { $0.membershipId == previousPreferred }) {
            return previousPreferred != resolved
        }
        // Preferred was invalid on a complete catalog — persist the fallback.
        return previousPreferred != resolved
    }
}

#if DEBUG
enum FanTeamPlayerInfoSelectionSelfTests {
    static func runAll() {
        testDurableSaveLoadVerify()
        testFailedSaveDoesNotClaimSuccess()
        testSuccessfulChange()
        testStaleFetchAfterSuccessfulSave()
        testRapidConsecutiveChangesLatestWins()
        testIncompleteCatalogKeepsPreferred()
        testCompleteCatalogFallsBackWhenPreferredGone()
        print("[TeamPlayerInfo] SELF_TESTS_ALL_PASSED")
    }

    private static func testDurableSaveLoadVerify() {
        let suite = "FanGeo.TeamPlayerInfoSelectionSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = UUID()
        let team = UUID()
        let membership = UUID()
        assert(FanTeamPlayerInfoSelectionStore.save(
            userId: user, teamId: team, membershipId: membership, defaults: defaults
        ))
        assert(FanTeamPlayerInfoSelectionStore.load(userId: user, teamId: team, defaults: defaults) == membership)
    }

    private static func testFailedSaveDoesNotClaimSuccess() {
        let suite = "FanGeo.TeamPlayerInfoSelectionSelfTests.fail.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let user = UUID()
        let team = UUID()
        let membership = UUID()
        assert(FanTeamPlayerInfoSelectionStore.save(
            userId: user, teamId: team, membershipId: membership, defaults: defaults
        ))
        FanTeamPlayerInfoSelectionStore.clear(userId: user, teamId: team, defaults: defaults)
        assert(FanTeamPlayerInfoSelectionStore.load(userId: user, teamId: team, defaults: defaults) == nil)
    }

    private static func makeSubject(membershipId: UUID, isSelf: Bool) -> FanTeamPlayerInfoSubject {
        let member = FanTeamMember(
            membershipId: membershipId,
            userId: isSelf ? UUID() : nil,
            managedPlayerId: isSelf ? nil : UUID(),
            role: .member,
            joinedAt: nil,
            displayName: isSelf ? "FanGeo" : "Emma",
            username: isSelf ? "fangeo" : nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            lastSeenAtRaw: nil,
            playerNumber: nil,
            preferredPositionCode: nil
        )
        return FanTeamPlayerInfoSubject(
            membershipId: membershipId,
            member: member,
            isViewerAccountSeat: isSelf
        )
    }

    private static func testSuccessfulChange() {
        let selfId = UUID()
        let emmaId = UUID()
        let subjects = [
            makeSubject(membershipId: selfId, isSelf: true),
            makeSubject(membershipId: emmaId, isSelf: false)
        ]
        let resolved = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: emmaId,
            subjects: subjects,
            catalogComplete: true
        )
        assert(resolved == emmaId)
    }

    private static func testStaleFetchAfterSuccessfulSave() {
        let selfId = UUID()
        let emmaId = UUID()
        let subjectsSelfOnly = [makeSubject(membershipId: selfId, isSelf: true)]
        let subjectsBoth = [
            makeSubject(membershipId: selfId, isSelf: true),
            makeSubject(membershipId: emmaId, isSelf: false)
        ]

        // User saved Emma; an incomplete/stale catalog must NOT wipe Emma → self.
        let duringStale = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: emmaId,
            subjects: subjectsSelfOnly,
            catalogComplete: false
        )
        assert(duringStale == emmaId)

        // Completed catalog still containing Emma keeps Emma.
        let afterFresh = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: emmaId,
            subjects: subjectsBoth,
            catalogComplete: true
        )
        assert(afterFresh == emmaId)
    }

    private static func testRapidConsecutiveChangesLatestWins() {
        let a = UUID()
        let b = UUID()
        let subjects = [
            makeSubject(membershipId: a, isSelf: true),
            makeSubject(membershipId: b, isSelf: false)
        ]
        let first = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: a, subjects: subjects, catalogComplete: true
        )
        let second = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: b, subjects: subjects, catalogComplete: true
        )
        assert(first == a)
        assert(second == b)
        assert(
            FanTeamPlayerInfoSelectionReconciliation.shouldRewriteDurableStore(
                previousPreferred: a,
                resolved: b,
                subjects: subjects,
                catalogComplete: true
            )
        )
    }

    private static func testIncompleteCatalogKeepsPreferred() {
        let emmaId = UUID()
        let resolved = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: emmaId,
            subjects: [],
            catalogComplete: false
        )
        assert(resolved == emmaId)
    }

    private static func testCompleteCatalogFallsBackWhenPreferredGone() {
        let selfId = UUID()
        let goneId = UUID()
        let subjects = [makeSubject(membershipId: selfId, isSelf: true)]
        let resolved = FanTeamPlayerInfoSelectionReconciliation.resolve(
            preferred: goneId,
            subjects: subjects,
            catalogComplete: true
        )
        assert(resolved == selfId)
        assert(
            FanTeamPlayerInfoSelectionReconciliation.shouldRewriteDurableStore(
                previousPreferred: goneId,
                resolved: resolved,
                subjects: subjects,
                catalogComplete: true
            )
        )
    }
}
#endif

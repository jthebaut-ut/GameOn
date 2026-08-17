import Combine
import Foundation
import SwiftUI

// MARK: - Scroll-phase relay (does not invalidate Settings / Profile)

/// Shared by Account Profile. Mutating `isActive` does **not** rebuild SettingsScreen.
/// Pokes emphasis modifiers subscribe via `publisher` so only those leaves update.
final class ProfileScrollInteractionRelay: @unchecked Sendable {
    private let subject: CurrentValueSubject<Bool, Never>

    var isActive: Bool { subject.value }
    var publisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }

    init(isActive: Bool = false) {
        subject = CurrentValueSubject(isActive)
    }

    func setActive(_ active: Bool) {
        guard subject.value != active else { return }
        subject.send(active)
    }
}

private enum ProfileScrollInteractionRelayKey: EnvironmentKey {
    static let defaultValue = ProfileScrollInteractionRelay()
}

extension EnvironmentValues {
    var profileScrollInteractionRelay: ProfileScrollInteractionRelay {
        get { self[ProfileScrollInteractionRelayKey.self] }
        set { self[ProfileScrollInteractionRelayKey.self] = newValue }
    }
}

// MARK: - Equatable section tree

/// Cheap identity of what Profile actually paints. Map camera / Chat presence / GPS
/// ticks that do not change this token must not re-run section bodies.
struct ProfileIdentityScrollSnapshot: Equatable {
    let token: String
}

// MARK: - My Teams process cache

extension ProfilePhase1PersonalizationCache {
    static let myTeamsTTLSeconds: TimeInterval = 45

    static var myTeamsLoadedAtByAuthId: [UUID: Date] = [:]
    static var myTeamsByAuthId: [UUID: [FanTeamSummary]] = [:]
    static var myTeamsInFlight: Task<[FanTeamSummary], Error>?

    static func cachedMyTeamsIfFresh(for authId: UUID) -> [FanTeamSummary]? {
        guard let loadedAt = myTeamsLoadedAtByAuthId[authId],
              Date().timeIntervalSince(loadedAt) < myTeamsTTLSeconds else {
            return nil
        }
        return myTeamsByAuthId[authId]
    }

    static func cachedMyTeamsRegardlessOfAge(for authId: UUID) -> [FanTeamSummary]? {
        myTeamsByAuthId[authId]
    }

    static func storeMyTeams(_ teams: [FanTeamSummary], for authId: UUID) {
        myTeamsByAuthId[authId] = teams
        myTeamsLoadedAtByAuthId[authId] = Date()
    }

    static func applyFanTeamIdentityChange(_ change: FanTeamIdentityChange) {
        for authId in myTeamsByAuthId.keys {
            guard var teams = myTeamsByAuthId[authId] else { continue }
            var changed = false
            teams = teams.map { team in
                guard team.id == change.teamId else { return team }
                let next = team.applying(change)
                if next != team { changed = true }
                return next
            }
            if changed {
                myTeamsByAuthId[authId] = teams
            }
        }
    }

    static func invalidateMyTeams(for authId: UUID?) {
        guard let authId else {
            myTeamsLoadedAtByAuthId.removeAll()
            myTeamsByAuthId.removeAll()
            myTeamsInFlight?.cancel()
            myTeamsInFlight = nil
            return
        }
        myTeamsLoadedAtByAuthId.removeValue(forKey: authId)
        myTeamsByAuthId.removeValue(forKey: authId)
    }
}

// MARK: - Snapshot builder (testable)

enum ProfileIdentityScrollSnapshotBuilder {
    static func token(
        authId: String,
        displayName: String,
        handleLine: String,
        bioLine: String,
        avatarIdentity: String,
        xp: Int,
        backgroundKey: String,
        identityCardsFingerprint: String,
        handlePrompt: Bool,
        belowFold: Bool,
        myTeamsFingerprint: String,
        favoriteTeamsFingerprint: String,
        homeCrowdFingerprint: String,
        openToFingerprint: String,
        pickupFingerprint: String,
        suggestedFansFingerprint: String,
        suggestedFanChipsFingerprint: String,
        pokesFingerprint: String,
        sponsoredIdentity: String,
        uploadingAvatar: Bool,
        savingIdentity: Bool,
        languageCode: String,
        colorSchemeName: String = "l",
        paintFingerprint: String = ""
    ) -> ProfileIdentityScrollSnapshot {
        ProfileIdentityScrollSnapshot(
            token: [
                authId,
                displayName,
                handleLine,
                bioLine,
                avatarIdentity,
                "xp=\(xp)",
                backgroundKey,
                identityCardsFingerprint,
                handlePrompt ? "1" : "0",
                belowFold ? "1" : "0",
                myTeamsFingerprint,
                favoriteTeamsFingerprint,
                homeCrowdFingerprint,
                openToFingerprint,
                pickupFingerprint,
                suggestedFansFingerprint,
                suggestedFanChipsFingerprint,
                pokesFingerprint,
                sponsoredIdentity,
                uploadingAvatar ? "1" : "0",
                savingIdentity ? "1" : "0",
                languageCode,
                colorSchemeName,
                paintFingerprint
            ].joined(separator: "§")
        )
    }
}

/// Skips descendant `body` evaluation when Profile paint identity is unchanged.
/// Map camera / GPS / Chat / live-score ticks that do not change `snapshot` must not
/// re-run Favorite Team artwork, My Teams cards, or Suggested Fans rows.
struct ProfileIdentityScrollGate<Content: View>: View, Equatable {
    let snapshot: ProfileIdentityScrollSnapshot
    let content: Content

    init(snapshot: ProfileIdentityScrollSnapshot, @ViewBuilder content: () -> Content) {
        self.snapshot = snapshot
        self.content = content()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let equal = lhs.snapshot == rhs.snapshot
#if DEBUG
        ProfileIdentityScrollPerf.gateCompared(equal: equal)
#endif
        return equal
    }

    var body: some View {
        let _ = SwiftUIRecompPerf.sectionBodyEvaluated(screen: "ProfileIdentity", section: "scrollGate")
        content
    }
}

#if DEBUG
enum ProfileIdentityScrollPerf {
    private static let lock = NSLock()
    private static var compareCount = 0
    private static var skipCount = 0
    private static var missCount = 0
    private static var lastSummaryAt: CFAbsoluteTime = 0

    static func gateCompared(equal: Bool) {
        lock.lock()
        compareCount += 1
        if equal {
            skipCount += 1
        } else {
            missCount += 1
        }
        let now = CFAbsoluteTimeGetCurrent()
        let shouldLog = now - lastSummaryAt >= 1.0
        let compares = compareCount
        let skips = skipCount
        let misses = missCount
        if shouldLog {
            lastSummaryAt = now
        }
        lock.unlock()
        guard shouldLog else { return }
        SwiftUIRecompPerf.log(
            "profileScrollGate compares=\(compares) skips=\(skips) misses=\(misses)",
            key: "profile.scrollGate"
        )
    }
}
#endif

#if DEBUG
enum ProfileIdentityScrollIsolationSelfTests {
    static func runAll() {
        var failures = 0

        let a = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: true,
            myTeamsFingerprint: "t1",
            favoriteTeamsFingerprint: "f1",
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "ad",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en"
        )
        let b = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: true,
            myTeamsFingerprint: "t1",
            favoriteTeamsFingerprint: "f1",
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "ad",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en"
        )
        if a != b {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL identical tokens compared unequal")
            failures += 1
        }

        let c = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: true,
            myTeamsFingerprint: "t1-changed",
            favoriteTeamsFingerprint: "f1",
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "ad",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en"
        )
        if a == c {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL my-teams change did not bust snapshot")
            failures += 1
        }

        let paintA = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: true,
            myTeamsFingerprint: "t1",
            favoriteTeamsFingerprint: "f1",
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "ad",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en",
            colorSchemeName: "l",
            paintFingerprint: "art=jazz.png"
        )
        let paintB = ProfileIdentityScrollSnapshotBuilder.token(
            authId: "u1",
            displayName: "Ada",
            handleLine: "@ada",
            bioLine: "hi",
            avatarIdentity: "av",
            xp: 10,
            backgroundKey: "fangeo",
            identityCardsFingerprint: "cards",
            handlePrompt: false,
            belowFold: true,
            myTeamsFingerprint: "t1",
            favoriteTeamsFingerprint: "f1",
            homeCrowdFingerprint: "h1",
            openToFingerprint: "o1",
            pickupFingerprint: "p1",
            suggestedFansFingerprint: "s1",
            suggestedFanChipsFingerprint: "c1",
            pokesFingerprint: "k1",
            sponsoredIdentity: "ad",
            uploadingAvatar: false,
            savingIdentity: false,
            languageCode: "en",
            colorSchemeName: "l",
            paintFingerprint: "art=bulls.png"
        )
        if paintA == paintB {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL artwork paint fingerprint did not bust snapshot")
            failures += 1
        }

        let gateA = ProfileIdentityScrollGate(snapshot: a) { Color.clear }
        let gateB = ProfileIdentityScrollGate(snapshot: b) { Color.red }
        if gateA != gateB {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL identical snapshots compared unequal on gate")
            failures += 1
        }

        let relay = ProfileScrollInteractionRelay()
        if relay.isActive {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL relay defaulted active")
            failures += 1
        }
        relay.setActive(true)
        relay.setActive(true)
        if !relay.isActive {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL relay setActive(true) ignored")
            failures += 1
        }
        relay.setActive(false)
        if relay.isActive {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL relay setActive(false) ignored")
            failures += 1
        }

        let compactA = ProfileIdentityScrollSnapshotBuilder.compactArtworkFingerprint(
            teamIDs: ["nba-jazz", "nba-bulls"],
            paintRevision: 3
        )
        let compactB = ProfileIdentityScrollSnapshotBuilder.compactArtworkFingerprint(
            teamIDs: ["nba-jazz", "nba-bulls"],
            paintRevision: 3
        )
        let compactC = ProfileIdentityScrollSnapshotBuilder.compactArtworkFingerprint(
            teamIDs: ["nba-jazz", "nba-bulls"],
            paintRevision: 4
        )
        if compactA != compactB {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL compact artwork fingerprint unstable")
            failures += 1
        }
        if compactA == compactC {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL compact artwork fingerprint ignored revision")
            failures += 1
        }
        if compactA.contains("http") {
            print("[ProfileIdentityScrollIsolationSelfTests] FAIL compact fingerprint resolved URLs")
            failures += 1
        }

        if failures == 0 {
            print("[ProfileIdentityScrollIsolationSelfTests] all passed")
        } else {
            print("[ProfileIdentityScrollIsolationSelfTests] failures=\(failures)")
        }
    }
}
#endif

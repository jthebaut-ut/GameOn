import Foundation

/// Automatic My Teams refresh must never cover Profile (or a hidden Teams tab) with a modal.
nonisolated enum MyTeamsRefreshTrigger: Equatable, Sendable {
    case automaticProfileHydration
    case automaticTeamsHome
    case pullToRefresh
    case userMutation
}

nonisolated enum MyTeamsRefreshPresentation {
    /// Blocking `"Couldn't refresh your Teams"` alerts are only for explicit mutations.
    static func shouldPresentBlockingAlert(
        trigger: MyTeamsRefreshTrigger,
        hasCachedTeams: Bool,
        isHostTabSelected: Bool,
        isCancellation: Bool,
        isMissingAuth: Bool
    ) -> Bool {
        if isCancellation || isMissingAuth { return false }
        if !isHostTabSelected { return false }
        if hasCachedTeams { return false }
        switch trigger {
        case .userMutation:
            return true
        case .automaticProfileHydration, .automaticTeamsHome, .pullToRefresh:
            return false
        }
    }

    static func shouldKeepCachedTeams(hasCachedTeams: Bool) -> Bool {
        hasCachedTeams
    }

    /// Empty My Teams + real failure → section Retry. Never a full-screen alert.
    static func shouldShowSectionRetry(
        hasCachedTeams: Bool,
        isCancellation: Bool,
        isMissingAuth: Bool,
        didFail: Bool
    ) -> Bool {
        didFail && !hasCachedTeams && !isCancellation && !isMissingAuth
    }

    static func shouldStartAutomaticFetch(
        hasAuthUser: Bool,
        isLoggedIn: Bool,
        isSessionRestoring: Bool,
        isSafeLogout: Bool
    ) -> Bool {
        hasAuthUser && isLoggedIn && !isSessionRestoring && !isSafeLogout
    }

    /// Pending background refresh never freezes Profile scrolling.
    static func blocksProfileScrolling(refreshPending: Bool, presentingBlockingAlert: Bool) -> Bool {
        _ = refreshPending
        return presentingBlockingAlert
    }

    static func shouldPublishSummaries(
        current: [FanTeamSummary],
        incoming: [FanTeamSummary]
    ) -> Bool {
        current != incoming
    }

    static func shouldRefetchDespiteCache(
        hasFreshCache: Bool,
        force: Bool
    ) -> Bool {
        force || !hasFreshCache
    }
}

/// One process-wide `list_my_fan_teams` at a time. Waiters that cancel do not cancel shared work.
actor MyTeamsRefreshCoordinator {
    static let shared = MyTeamsRefreshCoordinator()

    private var inFlight: Task<[FanTeamSummary], Error>?
    private var inFlightID: UInt64 = 0

    var hasInFlight: Bool { inFlight != nil }

    func run(
        _ work: @escaping @Sendable () async throws -> [FanTeamSummary]
    ) async throws -> (teams: [FanTeamSummary], coalesced: Bool) {
        if let existing = inFlight {
            MyTeamsRefreshDebug.log(
                phase: "coalesced.wait",
                coalesced: true,
                inFlightAlready: true
            )
            let teams = try await existing.value
            return (teams, true)
        }

        inFlightID += 1
        let id = inFlightID
        let coordinator = self
        let task = Task<[FanTeamSummary], Error> {
            do {
                let teams = try await work()
                await coordinator.clearInFlight(id: id)
                return teams
            } catch {
                await coordinator.clearInFlight(id: id)
                throw error
            }
        }
        inFlight = task
        MyTeamsRefreshDebug.log(
            phase: "coalesced.start",
            coalesced: false,
            inFlightAlready: false
        )
        let teams = try await task.value
        return (teams, false)
    }

    private func clearInFlight(id: UInt64) {
        guard inFlightID == id else { return }
        inFlight = nil
    }

#if DEBUG
    func resetForTests() {
        inFlight = nil
        inFlightID = 0
    }
#endif
}

/// Process-wide facade. State lives on ``MyTeamsRefreshCoordinator`` so callers never lock across `await`.
nonisolated enum MyTeamsInFlightCoalescer {
    static func hasInFlight() async -> Bool {
        await MyTeamsRefreshCoordinator.shared.hasInFlight
    }

    static func run(
        _ work: @escaping @Sendable () async throws -> [FanTeamSummary]
    ) async throws -> (teams: [FanTeamSummary], coalesced: Bool) {
        try await MyTeamsRefreshCoordinator.shared.run(work)
    }

#if DEBUG
    static func resetForTests() async {
        await MyTeamsRefreshCoordinator.shared.resetForTests()
    }
#endif
}

nonisolated enum MyTeamsRefreshDebug {
    static func log(
        phase: String,
        rpc: String = "list_my_fan_teams",
        hasAuthUser: Bool? = nil,
        hasSession: Bool? = nil,
        sessionState: String? = nil,
        httpStatus: Int? = nil,
        supabaseCode: String? = nil,
        message: String? = nil,
        isCancellation: Bool? = nil,
        elapsedMs: Int? = nil,
        hasCachedTeams: Bool? = nil,
        coalesced: Bool? = nil,
        inFlightAlready: Bool? = nil
    ) {
#if DEBUG
        var parts = [
            "[MyTeamsRefresh]",
            "phase=\(phase)",
            "rpc=\(rpc)",
        ]
        if let hasAuthUser { parts.append("hasAuthUser=\(hasAuthUser)") }
        if let hasSession { parts.append("hasSession=\(hasSession)") }
        if let sessionState { parts.append("sessionState=\(sessionState)") }
        if let httpStatus { parts.append("httpStatus=\(httpStatus)") }
        if let supabaseCode { parts.append("supabaseCode=\(supabaseCode)") }
        if let message {
            let clipped = message.count > 400 ? String(message.prefix(400)) + "…" : message
            parts.append("message=\(clipped)")
        }
        if let isCancellation { parts.append("isCancellation=\(isCancellation)") }
        if let elapsedMs { parts.append("elapsedMs=\(elapsedMs)") }
        if let hasCachedTeams { parts.append("hasCachedTeams=\(hasCachedTeams)") }
        if let coalesced { parts.append("coalesced=\(coalesced)") }
        if let inFlightAlready { parts.append("inFlightAlready=\(inFlightAlready)") }
        print(parts.joined(separator: " "))
#endif
    }
}

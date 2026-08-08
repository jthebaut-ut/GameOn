import Foundation
import os

/// Cross-isolation debug logging gate (safe from actors and background threads).
nonisolated enum DebugLogGate {
    /// Keep noisy non-realtime diagnostics hidden while investigating realtime latency.
    static let noisyRealtimeInvestigationLogs = false

    /// When true, enables hot-path perf/image tracing in Release builds (off by default).
    static let releaseHotPathPerfLogging = false

    /// Multi-line tab switch / preload / deferred-refresh tracing.
    static var verboseTabSwitchPerfLogging = false

    /// Going tab render/rebuild tracing beyond one-line ``goingTabPerfSummary`` logs.
    static var verboseGoingTabPerfLogging = false

    /// Discover tab-visible consistency / annotation tracing.
    static var verboseDiscoverTabPerfLogging = false

    /// Per-row Chat inbox rebuild diagnostics (counterpart mapping, row avatar source, activity badge).
    /// Aggregate ``ChatActivationPerf`` logs stay on regardless; this only gates row-by-row spam.
    static var verboseChatInboxRowLogging = false

    /// Per-evaluation root/shell body counters (``MainTabObservationPerf``).
    /// These fire on every SwiftUI body pass; unthrottled `print` from the main thread
    /// measurably stalls the first seconds after launch, so the per-pass lines are opt-in
    /// and a throttled aggregate is emitted instead.
    static var verboseRootBodyPerfLogging = false

    /// Calendar / national-team flag alias audits and per-team dumps (DEBUG, off by default).
    static var calendarFlagDiagnosticsEnabled = false
    /// Push notification team/flag dumps (DEBUG, off by default).
    static var pushFlagDiagnosticsEnabled = false
    /// Per-game reminder cancel / skip / reminderDate dumps (DEBUG, off by default).
    static var proGameReminderDiagnosticsEnabled = false

    /// Per-saved-game hydration/score traces (``SavedProGameHydrationDebug``, ``GoingProRefreshDebug``,
    /// ``ProScoreRefreshDebug``, ``ProGameFinalDebug``). One Live refresh emits several lines per saved
    /// game; the aggregate ``LiveApplyPerf`` summary stays on regardless.
    static var verboseProGameHydrationLogging = false

    /// Per-placement ad container hit-test traces (``AdHitTestDebug``), which fire on every layout pass.
    static var verboseAdHitTestLogging = false

    static var hotPathPerfLoggingEnabled: Bool {
#if DEBUG
        return true
#else
        return releaseHotPathPerfLogging
#endif
    }

#if DEBUG
    /// Enables opt-in diagnostic gates from Xcode scheme launch arguments.
    /// `-CalendarFlagDiagnostics`, `-PushFlagDiagnostics`, `-ProGameReminderDiagnostics`
    /// `-TabSwitchPerfDiagnostics`, `-UIPerfDiagnostics`, `-ChatInboxRowDiagnostics`
    /// `-RootBodyPerfDiagnostics`, `-VerboseProGameHydrationDiagnostics`,
    /// `-VerboseAdHitTestDiagnostics`
    static func applyLaunchArgumentOverridesIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-CalendarFlagDiagnostics") {
            calendarFlagDiagnosticsEnabled = true
        }
        if args.contains("-PushFlagDiagnostics") {
            pushFlagDiagnosticsEnabled = true
        }
        if args.contains("-ProGameReminderDiagnostics") {
            proGameReminderDiagnosticsEnabled = true
        }
        if args.contains("-TabSwitchPerfDiagnostics") {
            verboseTabSwitchPerfLogging = true
            verboseGoingTabPerfLogging = true
        }
        if args.contains("-ChatInboxRowDiagnostics") {
            verboseChatInboxRowLogging = true
        }
        if args.contains("-RootBodyPerfDiagnostics") {
            verboseRootBodyPerfLogging = true
        }
        if args.contains("-VerboseProGameHydrationDiagnostics") {
            verboseProGameHydrationLogging = true
        }
        if args.contains("-VerboseAdHitTestDiagnostics") {
            verboseAdHitTestLogging = true
        }
        if args.contains("-UIPerfDiagnostics") {
            DispatchQueue.main.async {
                UIPerformanceDiagnostics.uiPerformanceDiagnosticsEnabled = true
            }
        }
    }
#endif

    static func calendarFlagVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard calendarFlagDiagnosticsEnabled else { return }
        print(log())
#endif
    }

    static func pushFlagVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard pushFlagDiagnosticsEnabled else { return }
        print(log())
#endif
    }

    static func proGameHydrationVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard verboseProGameHydrationLogging else { return }
        print(log())
#endif
    }

    static func adHitTestVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard verboseAdHitTestLogging else { return }
        print(log())
#endif
    }

    static func proGameReminderVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard proGameReminderDiagnosticsEnabled else { return }
        print(log())
#endif
    }

    /// Always-visible DEBUG warning/error for notification & flag correctness.
    static func notificationWarning(_ log: @autoclosure () -> String) {
#if DEBUG
        print(log())
#endif
    }

    /// DEBUG by default; suppressed in Release unless ``releaseHotPathPerfLogging`` is enabled.
    static func hotPathPerf(_ log: @autoclosure () -> String) {
#if DEBUG
        print(log())
#else
        guard releaseHotPathPerfLogging else { return }
        print(log())
#endif
    }

    /// DEBUG-only diagnostic (stripped in Release); use for hot-path perf/realtime tracing.
    static func debug(_ log: @autoclosure () -> String) {
#if DEBUG
        print(log())
#endif
    }

    static func noisy(_ log: @autoclosure () -> String) {
#if DEBUG
        guard noisyRealtimeInvestigationLogs else { return }
        print(log())
#endif
    }

    /// One-line tab switch summary (DEBUG only).
    static func tabSwitchPerfSummary(_ log: @autoclosure () -> String) {
#if DEBUG
        print(log())
#endif
    }

    /// Verbose tab switch / preload / deferred refresh lines (DEBUG only).
    static func tabSwitchPerfVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard verboseTabSwitchPerfLogging else { return }
        print(log())
#endif
    }

    /// One-line Going tab perf summary (DEBUG only).
    static func goingTabPerfSummary(_ log: @autoclosure () -> String) {
#if DEBUG
        print(log())
#endif
    }

    /// Verbose Going tab render/rebuild tracing (DEBUG only).
    static func goingTabPerfVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard verboseGoingTabPerfLogging else { return }
        print(log())
#endif
    }

    /// Verbose Discover tab-visible tracing (DEBUG only).
    static func discoverTabPerfVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard verboseDiscoverTabPerfLogging else { return }
        print(log())
#endif
    }

    /// Per-row Chat inbox rebuild diagnostics (DEBUG only; off by default).
    static func chatInboxRowVerbose(_ log: @autoclosure () -> String) {
#if DEBUG
        guard verboseChatInboxRowLogging else { return }
        print(log())
#endif
    }
}

/// Hot-path tab tracing lines (`[TabPerfDebug]`); stripped in Release.
enum TabPerfDebug {
    static func log(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }
}

/// Sponsored placement investigation lines (`[SponsoredPlacementDebug]`); stripped in Release.
enum SponsoredPlacementDebugLog {
    static func log(_ message: @autoclosure () -> String) {
#if DEBUG
        print(message())
#endif
    }
}

/// Tab / screen performance tracing (`[AppPerfDebug]`); DEBUG only.
enum AppPerfDebug {
    private static let imageLoadLock = NSLock()
    private static var imageLoadCount = 0
    private static var imageCacheHitCount = 0

    static func tabSwitchStart(tab: String, from: String?, cacheHit: Bool, source: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] tabSwitchStart=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] cacheHit=\(cacheHit)")
        print("[AppPerfDebug] source=\(source)")
        if let from, !from.isEmpty {
            print("[AppPerfDebug] fromTab=\(from)")
        }
#endif
    }

    static func tabSwitchEnd(tab: String, durationMs: Int, cacheHit: Bool, source: String = "firstPaint") {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] tabSwitchEnd=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] durationMs=\(durationMs)")
        print("[AppPerfDebug] cacheHit=\(cacheHit)")
        print("[AppPerfDebug] source=\(source)")
#endif
    }

    static func screenLoadStart(tab: String, source: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] screenLoadStart=\(Date().timeIntervalSince1970)")
        print("[AppPerfDebug] tab=\(tab)")
        print("[AppPerfDebug] source=\(source)")
#endif
    }

    static func networkFetchStarted(tab: String? = nil, source: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if let tab {
            print("[AppPerfDebug] networkFetchStarted=true tab=\(tab) source=\(source)")
        } else {
            print("[AppPerfDebug] networkFetchStarted=true source=\(source)")
        }
#endif
    }

    static func networkFetchFinished(
        tab: String? = nil,
        source: String,
        durationMs: Int,
        cacheHit: Bool = false
    ) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if let tab {
            print("[AppPerfDebug] networkFetchFinished=true tab=\(tab) source=\(source) durationMs=\(durationMs) cacheHit=\(cacheHit)")
        } else {
            print("[AppPerfDebug] networkFetchFinished=true source=\(source) durationMs=\(durationMs) cacheHit=\(cacheHit)")
        }
#endif
    }

    static func mainActorBlocked(ms: Double, tab: String? = nil, source: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        let rounded = Int(ms.rounded())
        Perf.mainActorWork(name: source, durationMs: rounded)
        if let tab {
            print("[AppPerfDebug] mainActorBlockedMs=\(rounded) tab=\(tab) source=\(source)")
        } else {
            print("[AppPerfDebug] mainActorBlockedMs=\(rounded) source=\(source)")
        }
#endif
    }

    static func imageLoad(cacheHit: Bool, source: String = "DiscoverMapImageCache") {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        imageLoadLock.lock()
        imageLoadCount += 1
        if cacheHit { imageCacheHitCount += 1 }
        let total = imageLoadCount
        let hits = imageCacheHitCount
        imageLoadLock.unlock()
        print("[AppPerfDebug] imageLoadCount=\(total) cacheHit=\(cacheHit) source=\(source) cacheHits=\(hits)")
#endif
    }

    static func realtimeRestarted(_ restarted: Bool, source: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] realtimeRestarted=\(restarted) source=\(source)")
#endif
    }

    static func deferredWork(tab: String, work: String, source: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] deferredWork=true tab=\(tab) work=\(work) source=\(source)")
#endif
    }

    static func refreshSkipped(tab: String, source: String, reason: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[AppPerfDebug] refreshSkipped=true tab=\(tab) source=\(source) reason=\(reason)")
#endif
    }
}

/// Main-tab switch tracing (`[TabPerf]`); DEBUG unless ``DebugLogGate/releaseHotPathPerfLogging``.
enum TabPerf {
    static func selectedTab(_ tab: String) {
        DebugLogGate.tabSwitchPerfVerbose("[TabPerf] selectedTab=\(tab)")
    }

    static func tabSwitchStarted(from: String? = nil, to: String? = nil) {
        if let from, let to {
            DebugLogGate.tabSwitchPerfVerbose("[TabPerf] tabSwitchStarted from=\(from) to=\(to)")
        } else {
            DebugLogGate.tabSwitchPerfVerbose("[TabPerf] tabSwitchStarted")
        }
    }

    static func tabSwitchRendered(tab: String, durationMs: Int? = nil) {
        if let durationMs {
            DebugLogGate.tabSwitchPerfVerbose("[TabPerf] tabSwitchRendered tab=\(tab) durationMs=\(durationMs)")
        } else {
            DebugLogGate.tabSwitchPerfVerbose("[TabPerf] tabSwitchRendered tab=\(tab)")
        }
    }

    static func refreshSkipped(name: String, reason: String) {
        DebugLogGate.tabSwitchPerfVerbose("[TabPerf] refreshSkipped reason=\(reason) name=\(name)")
    }

    static func refreshStarted(name: String) {
        DebugLogGate.tabSwitchPerfVerbose("[TabPerf] refreshStarted name=\(name)")
    }

    static func refreshFinished(name: String, durationMs: Int) {
        DebugLogGate.tabSwitchPerfVerbose("[TabPerf] refreshFinished name=\(name) durationMs=\(durationMs)")
    }

    static func duplicateRefreshCoalesced(name: String) {
        DebugLogGate.tabSwitchPerfVerbose("[TabPerf] duplicateRefreshCoalesced name=\(name)")
    }
}

/// General performance tracing (`[Perf]`); DEBUG unless ``DebugLogGate/releaseHotPathPerfLogging``.
enum Perf {
    static func mainActorWork(name: String, durationMs: Int) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] mainActorWork name=\(name) durationMs=\(durationMs)")
    }

    static func backgroundWork(name: String, durationMs: Int) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] backgroundWork name=\(name) durationMs=\(durationMs)")
    }

    static func publishedWriteSkipped(name: String, reason: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] publishedWriteSkipped name=\(name) reason=\(reason)")
    }

    static func duplicateTaskCoalesced(name: String) {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        print("[Perf] duplicateTaskCoalesced name=\(name)")
    }

    static func cacheHit(name: String, detail: String = "") {
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        if detail.isEmpty {
            print("[Perf] cacheHit name=\(name)")
        } else {
            print("[Perf] cacheHit name=\(name) detail=\(detail)")
        }
    }
}

/// Image-cache performance tracing; callable from any isolation context (`[Perf]`).
nonisolated enum PerformanceLog {
#if DEBUG
    private static let imageHitLogLock = NSLock()
    private static var imageHitLogCounts: [String: Int] = [:]
    private static var imageHitLogsEmitted = 0
    private static let imageHitLogCap = 12
#endif

    static func imageCacheHit(urlHash: String) {
#if DEBUG
        guard DebugLogGate.hotPathPerfLoggingEnabled else { return }
        imageHitLogLock.lock()
        defer { imageHitLogLock.unlock() }
        let next = (imageHitLogCounts[urlHash] ?? 0) + 1
        imageHitLogCounts[urlHash] = next
        // Log first hit per urlHash, then aggregate every 25 thereafter — cap total lines.
        guard next == 1 || next.isMultiple(of: 25) else { return }
        guard imageHitLogsEmitted < imageHitLogCap else { return }
        imageHitLogsEmitted += 1
        if next == 1 {
            DebugLogGate.hotPathPerf("[Perf] imageCacheHit urlHash=\(urlHash)")
        } else {
            DebugLogGate.hotPathPerf("[Perf] imageCacheHit urlHash=\(urlHash) aggregateCount=\(next)")
        }
#else
        _ = urlHash
#endif
    }

    static func imageCacheMiss(urlHash: String) {
        DebugLogGate.hotPathPerf("[Perf] imageCacheMiss urlHash=\(urlHash)")
    }

    /// Short stable hash for log lines (not cryptographic).
    static func urlHash(for cacheKey: String) -> String {
        var hash: UInt64 = 5381
        for byte in cacheKey.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}

/// Going tab first-paint and background refresh tracing (`[GoingPerfDebug]`).
nonisolated enum GoingPerfDebug {
    static func screenAppear(source: String) {
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] screenAppear=\(Date().timeIntervalSince1970)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] source=\(source)")
    }

    static func firstPaint(
        ms: Int,
        usedCachedData: Bool,
        savedGamesCount: Int,
        favoriteTeamGamesCount: Int,
        source: String
    ) {
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] firstPaintMs=\(ms)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] usedCachedData=\(usedCachedData)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] savedGamesCount=\(savedGamesCount)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] favoriteTeamGamesCount=\(favoriteTeamGamesCount)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] source=\(source)")
    }

    static func refreshStarted(source: String) {
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] refreshStarted=\(Date().timeIntervalSince1970)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] source=\(source)")
    }

    static func refreshFinished(source: String, durationMs: Int) {
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] refreshFinished=\(Date().timeIntervalSince1970)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] refreshDurationMs=\(durationMs)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] source=\(source)")
    }

    static func duplicateRefreshSkipped(source: String, reason: String) {
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] duplicateRefreshSkipped=true")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] source=\(source)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] reason=\(reason)")
    }

    static func deferredWork(_ work: String, source: String) {
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] deferredWork=\(work)")
        DebugLogGate.goingTabPerfVerbose("[GoingPerfDebug] source=\(source)")
    }
}

enum SuggestedFansDebug {
    static func loadingStarted() {
#if DEBUG
        print("[SuggestedFansDebug] loadingStarted")
#endif
    }

    static func requestStarted(currentUserId: UUID?) {
#if DEBUG
        let user = currentUserId?.uuidString.lowercased() ?? "nil"
        print("[SuggestedFansDebug] currentUser=\(user) requestStarted=true")
#endif
    }

    static func profileReady(
        favoritesCount: Int,
        countryCode: String?,
        coordinatesAvailable: Bool
    ) {
#if DEBUG
        let country = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "nil"
        print(
            "[SuggestedFansDebug] profileReady=true favorites=\(favoritesCount) country=\(country) coordinatesAvailable=\(coordinatesAvailable)"
        )
#endif
    }

    static func filterSummary(_ summary: SuggestedFansEligibility.FilterSummary) {
#if DEBUG
        print(
            "[SuggestedFansDebug] backendRows=\(summary.backendRows) decodedRows=\(summary.decodedRows) clientVisibleRows=\(summary.clientVisibleRows)"
        )
        print(
            "[SuggestedFansDebug] excluded blocked=\(summary.blocked) alreadyFriends=\(summary.alreadyFriends) undiscoverable=\(summary.notDiscoverable) deleted=\(summary.deleted) banned=\(summary.banned + summary.inactiveAdmin) missingLocation=\(summary.missingLocation) outsideRadius=\(summary.outsideRadius) belowScore=\(summary.belowScore) identityHidden=\(summary.publicIdentityHidden) profileRowUnavailable=\(summary.profileRowUnavailable) self=\(summary.selfExcluded) business=\(summary.businessAccount)"
        )
        print("[SuggestedFansDebug] finalSuggestions=\(summary.clientVisibleRows)")
#endif
    }

    static func firstContentVisibleMs(_ milliseconds: Int) {
#if DEBUG
        print("[SuggestedFansDebug] firstContentVisibleMs=\(milliseconds)")
#endif
    }

    static func loadingFinished(count: Int) {
#if DEBUG
        print("[SuggestedFansDebug] loadingFinished count=\(count)")
#endif
    }
}

/// DEBUG-only tap → public-profile open tracing for Suggested Fans (and related profile opens).
enum SuggestedFanProfileOpenDebug {
    private static let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jt.fangio",
        category: "SuggestedFanProfileOpen"
    )
    private static var activeSignpostID: OSSignpostID?
    private static var activeGeneration: UInt64 = 0

    static var currentGeneration: UInt64 { activeGeneration }

    static func cardTapReceived(
        recommendationStableId: UUID,
        targetUserIdPresent: Bool,
        displayModelIdType: String,
        authenticatedUserPresent: Bool,
        context: String
    ) {
#if DEBUG
        activeGeneration &+= 1
        let generation = activeGeneration
        if let prior = activeSignpostID {
            os_signpost(.end, log: signpostLog, name: "SuggestedFanProfileOpen", signpostID: prior)
        }
        let signpostID = OSSignpostID(log: signpostLog)
        activeSignpostID = signpostID
        os_signpost(.begin, log: signpostLog, name: "SuggestedFanProfileOpen", signpostID: signpostID)
        print(
            "[SuggestedFanProfileOpen] cardTapReceived generation=\(generation) recommendationStableIdPresent=true targetUserIdPresent=\(targetUserIdPresent) displayModelIdType=\(displayModelIdType) authenticatedUserPresent=\(authenticatedUserPresent) context=\(context)"
        )
        // Keep exact UUIDs out of user-facing surfaces; DEBUG console only, hashed prefix.
        print(
            "[SuggestedFanProfileOpen] recommendationStableIdPrefix=\(recommendationStableId.uuidString.lowercased().prefix(8)) generation=\(generation)"
        )
#endif
    }

    static func eligibility(
        isSelf: Bool,
        isBlocked: Bool,
        generation: UInt64? = nil
    ) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print(
            "[SuggestedFanProfileOpen] eligibilityResult generation=\(gen) self=\(isSelf) blocked=\(isBlocked) deleted=unchecked_until_rpc"
        )
#endif
    }

    static func presentationStarted(
        alreadyPresented: Bool,
        generation: UInt64? = nil
    ) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print(
            "[SuggestedFanProfileOpen] presentationRequestStarted generation=\(gen) existingProfileSheetAlreadyPresented=\(alreadyPresented)"
        )
#endif
    }

    static func serviceRequestStarted(generation: UInt64? = nil) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print("[SuggestedFanProfileOpen] publicProfileServiceRequestStarted generation=\(gen)")
#endif
    }

    static func rpcReceived(visible: Bool, generation: UInt64? = nil) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print("[SuggestedFanProfileOpen] rpcResponseReceived visible=\(visible) generation=\(gen)")
#endif
    }

    static func decodingCompleted(
        mutualAvatarCount: Int,
        uniqueMutualAvatarCount: Int,
        teamCount: Int,
        uniqueTeamCount: Int,
        openToCount: Int,
        generation: UInt64? = nil
    ) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print(
            "[SuggestedFanProfileOpen] profileDecodingCompleted generation=\(gen) mutualAvatars=\(mutualAvatarCount) uniqueMutualAvatars=\(uniqueMutualAvatarCount) teams=\(teamCount) uniqueTeams=\(uniqueTeamCount) openTo=\(openToCount)"
        )
        if mutualAvatarCount != uniqueMutualAvatarCount || teamCount != uniqueTeamCount {
            print(
                "[SuggestedFanProfileOpen] duplicateIdentityKeysDetected mutualDelta=\(mutualAvatarCount - uniqueMutualAvatarCount) teamDelta=\(teamCount - uniqueTeamCount) generation=\(gen)"
            )
        }
#endif
    }

    static func rendererConstructionStarted(generation: UInt64? = nil) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print("[SuggestedFanProfileOpen] rendererConstructionStarted generation=\(gen)")
#endif
    }

    static func sheetPresented(generation: UInt64? = nil) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print("[SuggestedFanProfileOpen] sheetPresented generation=\(gen)")
        if let signpostID = activeSignpostID {
            os_signpost(.end, log: signpostLog, name: "SuggestedFanProfileOpen", signpostID: signpostID)
            activeSignpostID = nil
        }
#endif
    }

    static func sheetDismissed(generation: UInt64? = nil) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print("[SuggestedFanProfileOpen] sheetDismissed generation=\(gen)")
#endif
    }

    static func failure(_ reason: String, generation: UInt64? = nil) {
#if DEBUG
        let gen = generation ?? activeGeneration
        print("[SuggestedFanProfileOpen] failureOrCancellation reason=\(reason) generation=\(gen)")
        if let signpostID = activeSignpostID {
            os_signpost(.end, log: signpostLog, name: "SuggestedFanProfileOpen", signpostID: signpostID)
            activeSignpostID = nil
        }
#endif
    }
}

#if DEBUG
enum ProSchedulePerf {
    private static var loadStartedAt: CFAbsoluteTime?
    private static var firstContentLogged = false
    private static var visibleGamesRendered = 0

    static func loadStarted() {
        loadStartedAt = CFAbsoluteTimeGetCurrent()
        firstContentLogged = false
        visibleGamesRendered = 0
        print("[ProSchedulePerf] loadStarted")
    }

    static func totalGamesFetched(_ count: Int) {
        print("[ProSchedulePerf] totalGamesFetched=\(count)")
    }

    static func logHydrationDeferredCount(_ count: Int) {
        print("[ProSchedulePerf] hydrationDeferredCount=\(count)")
    }

    static func noteVisibleGameRendered() {
        visibleGamesRendered += 1
        if !firstContentLogged, let start = loadStartedAt {
            firstContentLogged = true
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            print("[ProSchedulePerf] firstContentVisibleMs=\(ms)")
        }
        print("[ProSchedulePerf] visibleGamesRendered=\(visibleGamesRendered)")
    }

    static func noteHydrationStarted() {
        // Reserved for per-card hydration tracing when needed.
    }
}

enum ChatLoadPerf {
    private static var loadStartedAt: CFAbsoluteTime?

    static func loadStarted() {
#if DEBUG
        loadStartedAt = CFAbsoluteTimeGetCurrent()
        print("[ChatLoadPerf] loadStarted")
#endif
    }

    static func cachedRowsShown(count: Int) {
#if DEBUG
        print("[ChatLoadPerf] cachedRowsShown count=\(count)")
#endif
    }

    static func recentChatsVisibleMs(_ ms: Int) {
#if DEBUG
        print("[ChatLoadPerf] recentChatsVisibleMs=\(ms)")
#endif
    }

    static func liveFansVisibleMs(_ ms: Int) {
#if DEBUG
        print("[ChatLoadPerf] liveFansVisibleMs=\(ms)")
#endif
    }

    static func totalInitialLoadMs(_ ms: Int) {
#if DEBUG
        print("[ChatLoadPerf] totalInitialLoadMs=\(ms)")
#endif
    }

    static func inboxFetchMs(_ ms: Int) {
#if DEBUG
        print("[ChatLoadPerf] inboxFetchMs=\(ms)")
#endif
    }

    static func presenceFetchDeferred(deferred: Bool) {
#if DEBUG
        print("[ChatLoadPerf] presenceFetchDeferred=\(deferred)")
#endif
    }

    static func elapsedMsSinceLoadStarted() -> Int? {
#if DEBUG
        guard let loadStartedAt else { return nil }
        return Int((CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000)
#else
        return nil
#endif
    }
}

enum ProfileDefaultsDebug {
    static func generatedDisplayName(_ value: String) {
#if DEBUG
        print("[ProfileDefaultsDebug] generated displayName=\(value)")
#endif
    }

    static func generatedUsername(_ value: String) {
#if DEBUG
        print("[ProfileDefaultsDebug] generated username=\(value)")
#endif
    }

    static func usernameCollisionResolved(base: String, resolved: String) {
#if DEBUG
        print("[ProfileDefaultsDebug] usernameCollisionResolved base=\(base) resolved=\(resolved)")
#endif
    }
}

enum ProfileAvatarDebug {
    static func uploadStarted(userId: UUID) {
#if DEBUG
        print("[ProfileAvatarDebug] uploadStarted userId=\(userId.uuidString.lowercased())")
#endif
    }

    static func uploadSucceeded(urlPresent: Bool) {
#if DEBUG
        print("[ProfileAvatarDebug] uploadSucceeded urlPresent=\(urlPresent)")
#endif
    }

    static func profileUpdateStarted(fields: String) {
#if DEBUG
        print("[ProfileAvatarDebug] profileUpdateStarted field=\(fields)")
#endif
    }

    static func profileUpdated(avatarURLPresent: Bool) {
#if DEBUG
        print("[ProfileAvatarDebug] profileUpdated avatarURLPresent=\(avatarURLPresent)")
#endif
    }

    static func profileReloaded(handlePresent: Bool, avatarURLPresent: Bool) {
#if DEBUG
        print("[ProfileAvatarDebug] profileReloaded handlePresent=\(handlePresent) avatarURLPresent=\(avatarURLPresent)")
#endif
    }

    static func avatarRenderSource(_ source: String) {
#if DEBUG
        print("[ProfileAvatarDebug] avatarRenderSource=\(source)")
#endif
    }

    static func profileFetchDecoded(
        userId: UUID,
        rawAvatarURL: String?,
        rawAvatarThumbnailURL: String?,
        profileFound: Bool
    ) {
#if DEBUG
        print("[ProfileAvatarDebug] profileFetch userId=\(userId.uuidString.lowercased()) found=\(profileFound)")
        print("[ProfileAvatarDebug] profileFetch raw_avatar_url=\(rawAvatarURL ?? "nil")")
        print("[ProfileAvatarDebug] profileFetch raw_avatar_thumbnail_url=\(rawAvatarThumbnailURL ?? "nil")")
#endif
    }

    static func profileAppliedToViewModel(
        canonicalAvatarURL: String,
        canonicalAvatarThumbnailURL: String,
        source: String
    ) {
#if DEBUG
        print("[ProfileAvatarDebug] profileApplied source=\(source)")
        print("[ProfileAvatarDebug] profileApplied canonical_avatar_url=\(canonicalAvatarURL.isEmpty ? "(empty)" : canonicalAvatarURL)")
        print("[ProfileAvatarDebug] profileApplied canonical_avatar_thumbnail_url=\(canonicalAvatarThumbnailURL.isEmpty ? "(empty)" : canonicalAvatarThumbnailURL)")
#endif
    }

    static func avatarViewResolved(
        context: String,
        thumbnailInput: String?,
        fullInput: String,
        displayURLString: String?,
        urlParseSucceeded: Bool,
        fallbackReason: String
    ) {
#if DEBUG
        print("[ProfileAvatarDebug] avatarView context=\(context)")
        print("[ProfileAvatarDebug] avatarView input_thumbnail=\(thumbnailInput ?? "nil")")
        print("[ProfileAvatarDebug] avatarView input_full=\(fullInput.isEmpty ? "(empty)" : fullInput)")
        print("[ProfileAvatarDebug] avatarView display_url=\(displayURLString ?? "nil")")
        print("[ProfileAvatarDebug] avatarView url_parse_ok=\(urlParseSucceeded)")
        print("[ProfileAvatarDebug] avatarView fallback_reason=\(fallbackReason)")
#endif
    }

    static func avatarImageLoadFinished(url: URL, succeeded: Bool, detail: String) {
#if DEBUG
        print("[ProfileAvatarDebug] avatarImageLoad url=\(url.absoluteString)")
        print("[ProfileAvatarDebug] avatarImageLoad succeeded=\(succeeded) detail=\(detail)")
#endif
    }
}
#endif

enum AccountSwitchDebug {
    static func generation(_ value: UInt64) {
#if DEBUG
        print("[AccountSwitchDebug] generation=\(value)")
#endif
    }

    static func logoutCleanup(accountId: UUID?, generation: UInt64) {
#if DEBUG
        let accountText = accountId?.uuidString.lowercased() ?? "nil"
        print("[AccountSwitchDebug] logoutCleanup accountId=\(accountText) generation=\(generation)")
#endif
    }

    static func loginStarted(accountId: UUID, generation: UInt64) {
#if DEBUG
        print("[AccountSwitchDebug] loginStarted accountId=\(accountId.uuidString.lowercased()) generation=\(generation)")
#endif
    }

    static func profileLoadStarted(accountId: UUID, generation: UInt64, reason: String) {
#if DEBUG
        print("[AccountSwitchDebug] profileLoadStarted accountId=\(accountId.uuidString.lowercased()) generation=\(generation) reason=\(reason)")
#endif
    }

    static func profileLoadCancelled(accountId: UUID, generation: UInt64, stale: Bool, reason: String) {
#if DEBUG
        print("[AccountSwitchDebug] profileLoadCancelled accountId=\(accountId.uuidString.lowercased()) generation=\(generation) stale=\(stale) reason=\(reason)")
#endif
    }

    static func profileResultApplied(accountId: UUID, generation: UInt64, profileExists: Bool) {
#if DEBUG
        print("[AccountSwitchDebug] profileResultApplied accountId=\(accountId.uuidString.lowercased()) generation=\(generation) profileExists=\(profileExists)")
#endif
    }

    static func staleCleanupIgnored(oldAccountId: UUID?, currentAccountId: UUID?, expectedGeneration: UInt64, currentGeneration: UInt64) {
#if DEBUG
        let oldText = oldAccountId?.uuidString.lowercased() ?? "nil"
        let currentText = currentAccountId?.uuidString.lowercased() ?? "nil"
        print("[AccountSwitchDebug] staleCleanupIgnored oldAccountId=\(oldText) currentAccountId=\(currentText) expectedGeneration=\(expectedGeneration) currentGeneration=\(currentGeneration)")
#endif
    }

    static func presentationLoadCancelledAndReset(accountId: UUID, generation: UInt64) {
#if DEBUG
        print("[AccountSwitchDebug] presentationLoadCancelledAndReset accountId=\(accountId.uuidString.lowercased()) generation=\(generation)")
#endif
    }

    static func profileTaskCompleted(accountId: UUID, generation: UInt64, taskToken: UUID) {
#if DEBUG
        print("[AccountSwitchDebug] profileTaskCompleted accountId=\(accountId.uuidString.lowercased()) generation=\(generation) taskToken=\(taskToken.uuidString.lowercased())")
#endif
    }

    static func profileTaskReferenceCleared(accountId: UUID, generation: UInt64, taskToken: UUID) {
#if DEBUG
        print("[AccountSwitchDebug] profileTaskReferenceCleared accountId=\(accountId.uuidString.lowercased()) generation=\(generation) taskToken=\(taskToken.uuidString.lowercased())")
#endif
    }

    static func staleTaskCompletionIgnored(accountId: UUID, generation: UInt64, taskToken: UUID) {
#if DEBUG
        print("[AccountSwitchDebug] staleTaskCompletionIgnored accountId=\(accountId.uuidString.lowercased()) generation=\(generation) taskToken=\(taskToken.uuidString.lowercased())")
#endif
    }
}

enum UIPerformanceDiagnostics {
    /// Profiling switch: temporarily set this to `true` to enable `[UIPerf]` logs and os_signpost events.
    static var uiPerformanceDiagnosticsEnabled = false

    private static let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fangeo.ios",
        category: "UIPerf"
    )

    static func timestamp() -> CFAbsoluteTime {
        guard uiPerformanceDiagnosticsEnabled else { return 0 }
        return CFAbsoluteTimeGetCurrent()
    }

    static func elapsedMs(since start: CFAbsoluteTime) -> Double {
        guard uiPerformanceDiagnosticsEnabled else { return 0 }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    static func formattedMs(_ ms: Double) -> String {
        String(format: "%.1f", ms)
    }

    static func log(_ message: @autoclosure () -> String) {
        guard uiPerformanceDiagnosticsEnabled else { return }
        print("[UIPerf] \(message())")
    }

    static func signpost(_ name: StaticString, _ message: @autoclosure () -> String = "") {
        guard uiPerformanceDiagnosticsEnabled else { return }
        let message = message()
        if message.isEmpty {
            os_signpost(.event, log: signpostLog, name: name)
        } else {
            os_signpost(.event, log: signpostLog, name: name, "%{public}@", message)
        }
    }

    static func logDiscoverScrollFrameDropIfNeeded(elapsedMs: Double, source: String, eventId: String? = nil) {
        guard uiPerformanceDiagnosticsEnabled else { return }
        guard elapsedMs >= 16.7 else { return }
        let eventText = eventId.map { " eventId=\($0)" } ?? ""
        log("discoverScrollFrameDrop suspected=true source=\(source)\(eventText) ms=\(formattedMs(elapsedMs))")
    }
}

/// DEBUG-only Account tab activation tracing (`===== ACCOUNT ACTIVATION PERFORMANCE =====`).
/// Never logs names, handles, emails, user ids, tokens, or payloads.
enum AccountActivationPerf {
    static func log(_ message: String) {
#if DEBUG
        print("===== ACCOUNT ACTIVATION PERFORMANCE ===== \(message)")
#endif
    }

    static func refreshSkippedFresh(name: String, ageMs: Int) {
#if DEBUG
        log("refreshSkipped=fresh name=\(name) ageMs=\(ageMs)")
#endif
    }

    static func refreshForced(name: String, reason: String) {
#if DEBUG
        log("refreshForced name=\(name) reason=\(reason)")
#endif
    }

    static func refreshDeduplicated(name: String) {
#if DEBUG
        log("refreshDeduplicated name=\(name)")
#endif
    }

    static func subscriptionReused(name: String) {
#if DEBUG
        log("subscriptionReused name=\(name)")
#endif
    }

    static func subscriptionResynced(name: String, reason: String) {
#if DEBUG
        log("subscriptionResynced name=\(name) reason=\(reason)")
#endif
    }
}

/// DEBUG-only Chat tab activation tracing (`===== CHAT ACTIVATION PERFORMANCE =====`).
/// Never logs names, handles, messages, emails, user ids, tokens, or payloads.
enum ChatActivationPerf {
    static func log(_ message: String) {
#if DEBUG
        print("===== CHAT ACTIVATION PERFORMANCE ===== \(message)")
#endif
    }

    static func snapshotPublished(rows: Int, source: String) {
#if DEBUG
        log("snapshotPublished rows=\(rows) source=\(source)")
#endif
    }

    static func snapshotReused(source: String) {
#if DEBUG
        log("snapshotReused source=\(source)")
#endif
    }

    static func staleResultIgnored(context: String) {
#if DEBUG
        log("staleResultIgnored context=\(context)")
#endif
    }

#if DEBUG
    private static var refreshCycle = 0
    private static var publishesInCycle = 0
    private static var reusesInCycle = 0
    private static var groupInboxRPCCountInCycle = 0
    private static var groupInboxRPCReuseCountInCycle = 0
    private static var avatarHydrationStartedInCycle = 0
    private static var avatarHydrationJoinedInCycle = 0
    private static var avatarHydrationSkippedInCycle = 0
#endif

    /// Starts a per-refresh publish tally so before/after publish counts are directly comparable.
    static func inboxRefreshRequested(source: String) {
#if DEBUG
        refreshCycle += 1
        publishesInCycle = 0
        reusesInCycle = 0
        groupInboxRPCCountInCycle = 0
        groupInboxRPCReuseCountInCycle = 0
        avatarHydrationStartedInCycle = 0
        avatarHydrationJoinedInCycle = 0
        avatarHydrationSkippedInCycle = 0
        log("inboxRefreshRequested cycle=\(refreshCycle) source=\(source)")
        log("rowDebugLoggingEnabled=\(DebugLogGate.verboseChatInboxRowLogging)")
#endif
    }

    static func inboxRefreshCoalesced(source: String) {
#if DEBUG
        log("inboxRefreshCoalesced source=\(source)")
#endif
    }

    static func inboxRPC(ms: Int, dmRows: Int, groupRows: Int) {
#if DEBUG
        log("inboxRPC ms=\(ms) dmRows=\(dmRows) groupRows=\(groupRows)")
#endif
    }

    static func groupInboxRPCStarted() {
#if DEBUG
        groupInboxRPCCountInCycle += 1
        log("groupInboxRPCStarted count=\(groupInboxRPCCountInCycle)")
#endif
    }

    static func groupInboxRPCReused() {
#if DEBUG
        groupInboxRPCReuseCountInCycle += 1
        log("groupInboxRPCReused count=\(groupInboxRPCReuseCountInCycle)")
#endif
    }

    static func avatarHydrationStarted(groupCount: Int) {
#if DEBUG
        avatarHydrationStartedInCycle += 1
        log("avatarHydrationStarted groups=\(groupCount) count=\(avatarHydrationStartedInCycle)")
#endif
    }

    static func avatarHydrationJoined(groupCount: Int) {
#if DEBUG
        avatarHydrationJoinedInCycle += 1
        log("avatarHydrationJoined groups=\(groupCount) count=\(avatarHydrationJoinedInCycle)")
#endif
    }

    static func avatarHydrationSkippedIdentical(groupCount: Int) {
#if DEBUG
        avatarHydrationSkippedInCycle += 1
        log("avatarHydrationSkippedIdentical groups=\(groupCount) count=\(avatarHydrationSkippedInCycle)")
#endif
    }

    static func fingerprintBuildMs(_ ms: Double, rows: Int) {
#if DEBUG
        log("fingerprintBuildMs=\(String(format: "%.2f", ms)) rows=\(rows)")
#endif
    }

    static func enrichmentStarted() {
#if DEBUG
        log("enrichmentStarted")
#endif
    }

    static func enrichmentFinished(ms: Int, applied: Bool) {
#if DEBUG
        log("enrichmentFinished ms=\(ms) applied=\(applied)")
#endif
    }

    static func snapshotBuildMs(_ ms: Double, source: String) {
#if DEBUG
        log("snapshotBuildMs=\(String(format: "%.2f", ms)) source=\(source)")
#endif
    }

    static func publishMs(_ ms: Double, rows: Int, source: String) {
#if DEBUG
        log("publishMs=\(String(format: "%.2f", ms)) rows=\(rows) source=\(source)")
#endif
    }

    static func offMainWorkMs(_ ms: Double, name: String) {
#if DEBUG
        log("offMainWorkMs=\(String(format: "%.2f", ms)) name=\(name)")
#endif
    }

    static func presencePeerSet(changed: Bool, count: Int) {
#if DEBUG
        log("presencePeerSetChanged=\(changed) peers=\(count)")
#endif
    }

    static func stableInboxReady(ms: Int, rows: Int) {
#if DEBUG
        log(
            "stableInboxReady ms=\(ms) rows=\(rows) publishes=\(publishesInCycle) skippedIdentical=\(reusesInCycle) "
            + "groupInboxRPCCount=\(groupInboxRPCCountInCycle) groupInboxRPCReused=\(groupInboxRPCReuseCountInCycle) "
            + "avatarHydrationStarted=\(avatarHydrationStartedInCycle) avatarHydrationJoined=\(avatarHydrationJoinedInCycle) "
            + "avatarHydrationSkippedIdentical=\(avatarHydrationSkippedInCycle)"
        )
#endif
    }

    static func notePublished() {
#if DEBUG
        publishesInCycle += 1
#endif
    }

    static func noteReused() {
#if DEBUG
        reusesInCycle += 1
#endif
    }
}

/// DEBUG-only membership tracing for Chat → Friends directory instability.
/// Logs only redacted id prefixes — never names, handles, message bodies, or emails.
enum ChatFriendsStability {
#if DEBUG
    private static var refreshToken = 0
    private static var lastPublishedDirectoryIds: Set<UUID> = []

    /// Pure transform (no actor-owned state); nonisolated so `map(redact)` compiles cleanly.
    nonisolated private static func redact(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private static func redactSet(_ ids: Set<UUID>) -> String {
        ids.map(redact).sorted().joined(separator: ",")
    }

    private static func log(_ message: String) {
        print("[ChatFriendsStability] \(message)")
    }
#endif

    /// Starts a membership-diff cycle for one inbox / friend-list publish.
    @discardableResult
    static func beginRefresh(source: String) -> Int {
#if DEBUG
        refreshToken += 1
        log("refreshToken=\(refreshToken) source=\(source)")
        return refreshToken
#else
        return 0
#endif
    }

    static func stage(
        _ name: String,
        refreshToken token: Int,
        ids: Set<UUID>
    ) {
#if DEBUG
        log("refreshToken=\(token) \(name)=[\(redactSet(ids))] count=\(ids.count)")
#endif
    }

    static func drop(
        reason: String,
        refreshToken token: Int,
        id: UUID
    ) {
#if DEBUG
        log("refreshToken=\(token) removedId=\(redact(id)) reason=\(reason)")
#endif
    }

    static func preserved(
        refreshToken token: Int,
        ids: Set<UUID>
    ) {
#if DEBUG
        guard !ids.isEmpty else { return }
        log(
            "refreshToken=\(token) preservedAcceptedWithoutThread=[\(redactSet(ids))] count=\(ids.count)"
        )
#endif
    }

    /// Diff against the last published Friends-directory membership and record the new set.
    static func publishedDirectory(
        refreshToken token: Int,
        ids: Set<UUID>
    ) {
#if DEBUG
        let removed = lastPublishedDirectoryIds.subtracting(ids)
        let added = ids.subtracting(lastPublishedDirectoryIds)
        lastPublishedDirectoryIds = ids
        log("refreshToken=\(token) publishedFriendIds=[\(redactSet(ids))] count=\(ids.count)")
        if !removed.isEmpty {
            log("refreshToken=\(token) removedIds=[\(redactSet(removed))]")
        }
        if !added.isEmpty {
            log("refreshToken=\(token) addedIds=[\(redactSet(added))]")
        }
#endif
    }

    static func resetForAccountChange() {
#if DEBUG
        lastPublishedDirectoryIds = []
        log("reset reason=accountChange")
#endif
    }
}

/// DEBUG-only counters for broad root invalidation caused by Chat publications.
/// Counts are process-local and intentionally contain no user or content data.
@MainActor
enum MainTabObservationPerf {
#if DEBUG
    private static var mainBodyCount = 0
    private static var shellCount = 0
    private static var floatingBarCount = 0
    private static var chatBadgeLeafCount = 0
    private static var contentBodyCount = 0
    private static var chatPublicationCounts: [String: Int] = [:]
    private static var lastAggregateLogAt: CFAbsoluteTime = 0
    private static let aggregateLogInterval: CFAbsoluteTime = 1.0

    /// Counters are always maintained; only the per-pass line is opt-in. Without the gate the
    /// aggregate is emitted at most once per second so the counts stay visible without
    /// putting a synchronous `print` on every body pass during launch.
    private static func notePass(_ verboseLine: @autoclosure () -> String) {
        if DebugLogGate.verboseRootBodyPerfLogging {
            print("===== MAIN TAB OBSERVATION PERFORMANCE ===== \(verboseLine())")
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAggregateLogAt >= aggregateLogInterval else { return }
        lastAggregateLogAt = now
        print(
            "===== MAIN TAB OBSERVATION PERFORMANCE ===== aggregate contentBody=\(contentBodyCount) "
            + "mainBody=\(mainBodyCount) rootShell=\(shellCount) floatingBar=\(floatingBarCount) "
            + "chatBadgeLeaf=\(chatBadgeLeafCount)"
        )
    }
#endif

    static func mainBodyEvaluated(selectedTab: String) {
#if DEBUG
        mainBodyCount += 1
        notePass("mainBody count=\(mainBodyCount) selectedTab=\(selectedTab)")
#endif
    }

    static func rootShellEvaluated(selectedTab: String) {
#if DEBUG
        shellCount += 1
        notePass("rootShell count=\(shellCount) selectedTab=\(selectedTab)")
#endif
    }

    static func floatingBarEvaluated(selectedTab: String) {
#if DEBUG
        floatingBarCount += 1
        notePass("floatingBar count=\(floatingBarCount) selectedTab=\(selectedTab)")
#endif
    }

    static func chatBadgeLeafEvaluated() {
#if DEBUG
        chatBadgeLeafCount += 1
        notePass("chatBadgeLeaf count=\(chatBadgeLeafCount)")
#endif
    }

    static func contentBodyEvaluated() {
#if DEBUG
        contentBodyCount += 1
        notePass("contentBody count=\(contentBodyCount)")
#endif
    }

    static func chatPublished(category: String) {
#if DEBUG
        chatPublicationCounts[category, default: 0] += 1
        let count = chatPublicationCounts[category, default: 0]
        DirectChatOpenPerf.notePrecedingPublisher(object: "ChatViewModel", property: category)
        notePass("chatPublication category=\(category) count=\(count)")
#endif
    }

    static func projectionPublished(scope: String, category: String) {
#if DEBUG
        DirectChatOpenPerf.notePrecedingPublisher(object: "ChatMainTabState", property: "\(scope).\(category)")
        notePass("projection scope=\(scope) category=\(category)")
#endif
    }
}

/// DEBUG-only tab-tap event tracing: touch → action → `selectedTab` → shell → first frame.
///
/// Answers "which phase swallowed the tap?" without any user or content data. Every value is a
/// tab name, a millisecond offset, or a boolean.
@MainActor
enum TabTapPerf {
#if DEBUG
    private struct PendingTap {
        let tab: String
        let tapAt: CFAbsoluteTime
        var selectedAt: CFAbsoluteTime?
        var shellVisibleAt: CFAbsoluteTime?
        var firstFrameAt: CFAbsoluteTime?
        var cachedContentUsable: Bool?
        var extraTapsBeforeSelection = 0
        var repeatTaps = 0
        var overwritten: String?
    }

    private static var pending: PendingTap?

    private static func ms(_ from: CFAbsoluteTime, _ to: CFAbsoluteTime) -> String {
        String(format: "%.1f", (to - from) * 1000)
    }

    private static func log(_ message: String) {
        print("===== TAB TAP PERFORMANCE ===== \(message)")
    }
#endif

    /// Called from the tab button action, before any other work in that action.
    /// - Parameters:
    ///   - alreadySelected: the destination was already the active tab (repeat tap).
    ///   - overlayHitTestable: a full-screen overlay above the tab bar was accepting touches.
    static func tapReceived(
        tab: String,
        reason: String,
        alreadySelected: Bool,
        overlayHitTestable: Bool
    ) {
#if DEBUG
        if var current = pending, current.selectedAt == nil {
            // The previous tap never reached a selection change before this one arrived.
            current.extraTapsBeforeSelection += 1
            pending = current
            log(
                "tapReceivedBeforeSelection tab=\(tab) pendingTab=\(current.tab) "
                + "extraTaps=\(current.extraTapsBeforeSelection) sinceFirstTapMs=\(ms(current.tapAt, CFAbsoluteTimeGetCurrent()))"
            )
            return
        }
        var tap = PendingTap(tab: tab, tapAt: CFAbsoluteTimeGetCurrent())
        if alreadySelected {
            tap.repeatTaps = 1
        }
        pending = tap
        log(
            "tapReceived tab=\(tab) reason=\(reason) repeatTap=\(alreadySelected) "
            + "overlayHitTestable=\(overlayHitTestable)"
        )
#endif
    }

    /// Called immediately after the `selectedTab` storage write returns.
    static func selectedTabChanged(tab: String) {
#if DEBUG
        guard var current = pending, current.tab == tab, current.selectedAt == nil else { return }
        current.selectedAt = CFAbsoluteTimeGetCurrent()
        pending = current
        log("selectedTabChanged tab=\(tab) tapToSelectionMs=\(ms(current.tapAt, current.selectedAt!))")
#endif
    }

    /// Called when the destination tab root reports that its shell mounted / became visible.
    static func shellVisible(tab: String) {
#if DEBUG
        guard var current = pending, current.tab == tab, current.shellVisibleAt == nil else { return }
        current.shellVisibleAt = CFAbsoluteTimeGetCurrent()
        pending = current
        log("shellVisible tab=\(tab) tapToShellMs=\(ms(current.tapAt, current.shellVisibleAt!))")
#endif
    }

    /// Called once the destination rendered its first content frame. Emits the summary line.
    static func firstFrame(tab: String, cachedContentUsable: Bool) {
#if DEBUG
        guard var current = pending, current.tab == tab, current.firstFrameAt == nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        current.firstFrameAt = now
        current.cachedContentUsable = cachedContentUsable
        pending = current
        let selection = current.selectedAt.map { ms(current.tapAt, $0) } ?? "n/a"
        let shell = current.shellVisibleAt.map { ms(current.tapAt, $0) } ?? "n/a"
        log(
            "[TabTapPerf] tab=\(tab) tapReceived=0.0 selectedTabChanged=\(selection) shellVisible=\(shell) "
            + "cachedContentUsable=\(cachedContentUsable) firstFrame=\(ms(current.tapAt, now)) "
            + "tapsBeforeSelection=\(current.extraTapsBeforeSelection) repeatTaps=\(current.repeatTaps) "
            + "overwrittenBy=\(current.overwritten ?? "none")"
        )
#endif
    }

    /// Chat only: the inbox settled after the tab was already usable.
    static func stableInboxReady(rows: Int) {
#if DEBUG
        guard let current = pending, current.tab == "chat" else { return }
        log("stableInboxReady tab=chat rows=\(rows) tapToStableMs=\(ms(current.tapAt, CFAbsoluteTimeGetCurrent()))")
#endif
    }

    /// A non-user code path changed the selection away from a tab the user just chose.
    static func selectionOverwritten(from: String, to: String, reason: String) {
#if DEBUG
        if var current = pending, current.tab == from, current.firstFrameAt == nil {
            current.overwritten = reason
            pending = current
        }
        log("selectedTabOverwritten from=\(from) to=\(to) reason=\(reason)")
#endif
    }

    /// Warm/background tasks running while the tap was handled.
    static func activeWarmTasks(_ names: [String]) {
#if DEBUG
        guard !names.isEmpty else { return }
        log("activeWarmTasks count=\(names.count) names=\(names.sorted().joined(separator: ","))")
#endif
    }

    /// Uninterrupted MainActor work long enough to delay touch delivery.
    static func mainActorBusy(ms milliseconds: Double, source: String) {
#if DEBUG
        guard milliseconds >= 50 else { return }
        log("mainActorBusy ms=\(String(format: "%.1f", milliseconds)) source=\(source)")
#endif
    }

    /// Two-phase first mount: the lightweight shell frame committed before heavy content.
    static func firstMountShellShown(tab: String, reason: String) {
#if DEBUG
        log("firstMountShellShown tab=\(tab) reason=\(reason)")
#endif
    }

    /// Two-phase first mount: the heavy subtree finished mounting after the shell frame.
    static func firstMountContentActivated(tab: String, msFromMount: Int, reason: String) {
#if DEBUG
        log("firstMountContentActivated tab=\(tab) msFromMount=\(msFromMount) reason=\(reason)")
#endif
    }

#if DEBUG
    private static var stallWatchdogRunning = false
    private static let stallWatchdogHeartbeat: TimeInterval = 0.1
    private static let stallWatchdogDuration: TimeInterval = 12
#endif

    /// Samples main-queue lateness for the first seconds after launch and reports every stall
    /// long enough to delay touch delivery. Ten wakeups per second, DEBUG only.
    static func startLaunchStallWatchdog() {
#if DEBUG
        guard !stallWatchdogRunning else { return }
        stallWatchdogRunning = true
        let startedAt = CFAbsoluteTimeGetCurrent()
        var expectedAt = startedAt + stallWatchdogHeartbeat

        func tick() {
            let now = CFAbsoluteTimeGetCurrent()
            let latenessMs = (now - expectedAt) * 1000
            if latenessMs >= 50 {
                log(
                    "mainActorBusy ms=\(String(format: "%.1f", latenessMs)) source=launchHeartbeat "
                    + "sinceLaunchMs=\(String(format: "%.0f", (now - startedAt) * 1000))"
                )
            }
            guard now - startedAt < stallWatchdogDuration else {
                stallWatchdogRunning = false
                log("launchStallWatchdogFinished windowSeconds=\(Int(stallWatchdogDuration))")
                return
            }
            expectedAt = now + stallWatchdogHeartbeat
            DispatchQueue.main.asyncAfter(deadline: .now() + stallWatchdogHeartbeat) { tick() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + stallWatchdogHeartbeat) { tick() }
#endif
    }
}

/// DEBUG-only Calendar / Schedule tab first-activation diagnostics.
/// Privacy: counts, timings, and boolean flags only — never titles, venues, or user IDs.
nonisolated enum CalendarActivationPerf {
#if DEBUG
    private static var firstOpenLogged = false
    private static var selectedAt: CFAbsoluteTime?
#endif

    static func log(_ message: String) {
#if DEBUG
        print("===== CALENDAR ACTIVATION PERFORMANCE ===== \(message)")
#endif
    }

    static func selected(source: String, firstOpen: Bool) {
#if DEBUG
        selectedAt = CFAbsoluteTimeGetCurrent()
        if firstOpen { firstOpenLogged = true }
        log("selected source=\(source) firstOpen=\(firstOpen)")
#endif
    }

    static func shellVisible(cachedDotsUsable: Bool, cachedEventsUsable: Bool) {
#if DEBUG
        let ms = selectedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
        log(
            "shellVisible msSinceSelected=\(ms) cachedDotsUsable=\(cachedDotsUsable) "
                + "cachedEventsUsable=\(cachedEventsUsable)"
        )
#endif
    }

    static func rootConstructed(firstOpen: Bool) {
#if DEBUG
        let ms = selectedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
        log("rootConstructed msSinceSelected=\(ms) firstOpen=\(firstOpen)")
#endif
    }

    static func stripInventoryBuilt(ms: Double, days: Int, cacheHit: Bool) {
#if DEBUG
        log(
            "snapshotBuildMs=\(String(format: "%.2f", ms)) stripDays=\(days) cacheHit=\(cacheHit) "
                + "label=dateStripInventory"
        )
#endif
    }

    static func publishMs(_ ms: Double, reason: String) {
#if DEBUG
        log("publishMs=\(String(format: "%.2f", ms)) reason=\(reason)")
#endif
    }

    static func stableReady(firstOpen: Bool) {
#if DEBUG
        let ms = selectedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
        log("stableReady msSinceSelected=\(ms) firstOpen=\(firstOpen)")
#endif
    }

    static func warmJoined(source: String) {
#if DEBUG
        log("refreshJoined source=\(source)")
#endif
    }

    static var hasLoggedFirstOpen: Bool {
#if DEBUG
        firstOpenLogged
#else
        false
#endif
    }
}

/// DEBUG-only aggregate metrics for bulk Live/Going apply work on the MainActor.
/// Row-level detail stays behind ``DebugLogGate/verboseProGameHydrationLogging``.
/// Never logs user identity, tokens, provider payloads, or private data.
nonisolated enum LiveApplyPerf {

    /// Totals for one saved-Pro-Game reconciliation pass against a Live snapshot.
    struct SavedGameBatchMetrics {
        var savedGamesConsidered = 0
        var savedGamesMatched = 0
        var savedGamesUnmatched = 0
        var savedGamesChanged = 0
        var indexBuildMs: Double = 0
        var reconcileMs: Double = 0
    }

    static func log(_ message: String) {
#if DEBUG
        print("===== LIVE APPLY PERFORMANCE ===== \(message)")
#endif
    }

    static func savedGameBatch(_ metrics: SavedGameBatchMetrics, reason: String) {
#if DEBUG
        log(
            "reason=\(reason) "
                + "savedGamesConsidered=\(metrics.savedGamesConsidered) "
                + "savedGamesMatched=\(metrics.savedGamesMatched) "
                + "savedGamesUnmatched=\(metrics.savedGamesUnmatched) "
                + "savedGamesChanged=\(metrics.savedGamesChanged) "
                + "indexBuildMs=\(String(format: "%.2f", metrics.indexBuildMs)) "
                + "batchReconcileMs=\(String(format: "%.2f", metrics.reconcileMs))"
        )
#endif
    }

    static func apply(
        rowsFetched: Int,
        mainActorApplyMs: Double,
        publishCount: Int,
        reason: String
    ) {
#if DEBUG
        log(
            "reason=\(reason) rowsFetched=\(rowsFetched) "
                + "mainActorApplyMs=\(String(format: "%.2f", mainActorApplyMs)) "
                + "publishCount=\(publishCount)"
        )
#endif
    }

    /// Cache-hit / timer tick where full Equatable equality short-circuited before hydration.
    static func identicalPayloadSkipped(
        rowsFetched: Int,
        mainActorApplyMs: Double,
        reason: String
    ) {
#if DEBUG
        log(
            "reason=\(reason) identicalPayload=true hydrationSkipped=true "
                + "rowsFetched=\(rowsFetched) "
                + "mainActorApplyMs=\(String(format: "%.2f", mainActorApplyMs)) "
                + "publishCount=0"
        )
#endif
    }

    static func favoriteIndexBuild(rows: Int, favorites: Int, buildMs: Double, reason: String) {
#if DEBUG
        log(
            "reason=\(reason) favoriteIndexBuild=true rows=\(rows) favorites=\(favorites) "
                + "buildMs=\(String(format: "%.2f", buildMs))"
        )
#endif
    }
}

/// DEBUG-only aggregate metrics for the Going global refresh apply phase.
nonisolated enum GoingApplyPerf {
    static func log(_ message: String) {
#if DEBUG
        print("===== GOING APPLY PERFORMANCE ===== \(message)")
#endif
    }

    static func apply(
        networkMs: Int,
        snapshotBuildMs: Double,
        mainActorApplyMs: Double,
        publishCount: Int,
        reason: String
    ) {
#if DEBUG
        log(
            "reason=\(reason) networkMs=\(networkMs) "
                + "snapshotBuildMs=\(String(format: "%.2f", snapshotBuildMs)) "
                + "mainActorApplyMs=\(String(format: "%.2f", mainActorApplyMs)) "
                + "publishCount=\(publishCount)"
        )
#endif
    }

    static func notificationDiff(desired: Int, scheduled: Int, applied: Int, ms: Double, reason: String) {
#if DEBUG
        log(
            "reason=\(reason) notificationDiffMs=\(String(format: "%.2f", ms)) "
                + "remindersDesired=\(desired) remindersAlreadyScheduled=\(scheduled) remindersApplied=\(applied)"
        )
#endif
    }
}

/// DEBUG-only instrumentation for Live tab activation and refresh performance.
/// Never logs user identity, tokens, full provider payloads, or private data.
enum LiveActivationPerf {
    static func log(_ message: String) {
#if DEBUG
        print("===== LIVE ACTIVATION PERFORMANCE ===== \(message)")
#endif
    }

    static func activation(cachedRows: Int, source: String) {
#if DEBUG
        log("activation cachedRows=\(cachedRows) source=\(source)")
#endif
    }

    static func refreshSkipped(reason: String) {
#if DEBUG
        log("refreshSkipped reason=\(reason)")
#endif
    }

    static func refreshStarted(force: Bool, source: String) {
#if DEBUG
        log("refreshStarted force=\(force) source=\(source)")
#endif
    }

    static func refreshCompleted(ms: Int, rows: Int) {
#if DEBUG
        log("refreshCompleted ms=\(ms) rows=\(rows)")
#endif
    }

    static func publishApplied(rows: Int, reason: String) {
#if DEBUG
        log("publishApplied rows=\(rows) reason=\(reason)")
#endif
    }

    static func publishSkippedIdentical(rows: Int) {
#if DEBUG
        log("publishSkipped reason=identicalContent rows=\(rows)")
#endif
    }

    static func timerTick() {
#if DEBUG
        log("timerTick")
#endif
    }
}

/// DEBUG-only instrumentation for Discover post-first-paint ("Phase 3") enrichment.
/// Never logs names, coordinates, user IDs, tokens, URLs, or payloads — only counts, revisions, and durations.
enum DiscoverPhase3Perf {
    static func log(_ message: String) {
#if DEBUG
        print("===== DISCOVER PHASE 3 PERFORMANCE ===== \(message)")
#endif
    }

    static func scheduled(revision: String) {
#if DEBUG
        log("scheduled revision=\(revision)")
#endif
    }

    static func started(revision: String, msSinceFirstUsable: Int) {
#if DEBUG
        log("started revision=\(revision) msSinceFirstUsable=\(msSinceFirstUsable)")
#endif
    }

    static func completed(revision: String, ms: Int) {
#if DEBUG
        log("completed revision=\(revision) ms=\(ms)")
#endif
    }

    static func staleCancelled(revision: String) {
#if DEBUG
        log("staleTaskCancelled revision=\(revision)")
#endif
    }

    static func staleResultIgnored(revision: String) {
#if DEBUG
        log("staleResultIgnored revision=\(revision)")
#endif
    }

    static func interestsLoaded(events: Int, rows: Int, changed: Bool, ms: Int) {
#if DEBUG
        log("interestsLoaded events=\(events) rows=\(rows) changed=\(changed) ms=\(ms)")
#endif
    }

    static func snapshotRebuildSkipped(reason: String) {
#if DEBUG
        log("snapshotRebuildSkipped reason=\(reason)")
#endif
    }

    static func imagePrefetch(requested: Int, unique: Int) {
#if DEBUG
        log("imagePrefetch requested=\(requested) unique=\(unique)")
#endif
    }

    static func leftDiscoverWhileRunning(revision: String) {
#if DEBUG
        log("taskStillRunningAfterLeavingDiscover revision=\(revision)")
#endif
    }
}

/// DEBUG-only Discover map render/clustering diagnostics.
///
/// Privacy: never logs coordinates, names, addresses, user IDs, tokens, or
/// private payloads — only counts, reasons, durations, and boolean flags.
enum MapRenderPerf {
    static func log(_ message: String) {
#if DEBUG
        print("===== MAP RENDER PERFORMANCE ===== \(message)")
#endif
    }

    static func rebuildRequested(reason: String) {
#if DEBUG
        log("rebuildRequested reason=\(reason)")
#endif
    }

    static func rebuildCoalesced(reason: String) {
#if DEBUG
        log("rebuildCoalesced reason=\(reason)")
#endif
    }

    static func rebuildSuppressed(reason: String) {
#if DEBUG
        log("rebuildSuppressed reason=\(reason)")
#endif
    }

    static func buildStarted(reason: String) {
#if DEBUG
        log("buildStarted reason=\(reason)")
#endif
    }

    static func staleBuildIgnored(reason: String) {
#if DEBUG
        log("staleBuildIgnored reason=\(reason)")
#endif
    }

    static func previousBuildCancelled() {
#if DEBUG
        log("previousBuildCancelled=true")
#endif
    }

    static func buildCompleted(reason: String, venues: Int, clusters: Int, buildMs: Int) {
#if DEBUG
        log("buildCompleted reason=\(reason) venues=\(venues) clusters=\(clusters) buildMs=\(buildMs)")
#endif
    }

    static func publishApplied(reason: String, venues: Int, clusters: Int, publishMs: Int) {
#if DEBUG
        log("publishApplied reason=\(reason) venues=\(venues) clusters=\(clusters) publishMs=\(publishMs)")
#endif
    }

    static func publishSkippedIdentical(reason: String, venues: Int, clusters: Int) {
#if DEBUG
        log("publishSkippedIdentical reason=\(reason) venues=\(venues) clusters=\(clusters)")
#endif
    }
}

/// DEBUG-only cold-start / launch pipeline instrumentation.
/// Privacy: never logs emails, user IDs, tokens, URLs, or payloads —
/// only phases, durations, counts, and skip reasons.
nonisolated enum StartupPerf {
    static func log(_ message: String) {
#if DEBUG
        print("===== STARTUP PERFORMANCE ===== \(message)")
#endif
    }

    static func phase(_ name: String, ms: Int? = nil, details: String = "") {
#if DEBUG
        var parts = ["phase=\(name)"]
        if let ms { parts.append("ms=\(ms)") }
        if !details.isEmpty { parts.append(details) }
        log(parts.joined(separator: " "))
#endif
    }

    static func duplicateSkipped(reason: String) {
#if DEBUG
        log("duplicateSkipped reason=\(reason)")
#endif
    }

    static func taskCoalesced(name: String) {
#if DEBUG
        log("taskCoalesced name=\(name)")
#endif
    }

    static func staleRejected(name: String) {
#if DEBUG
        log("staleRejected name=\(name)")
#endif
    }

    static func publishSkippedIdentical(name: String) {
#if DEBUG
        log("publishSkippedIdentical name=\(name)")
#endif
    }

    static func concurrentTasks(peak: Int) {
#if DEBUG
        log("peakConcurrentStartupTasks=\(peak)")
#endif
    }

    static func mainActorStall(ms: Double, label: String) {
#if DEBUG
        if ms >= 8 {
            log("mainActorStall ms=\(String(format: "%.2f", ms)) label=\(label)")
        }
#endif
    }
}

/// Tracks concurrent startup-labeled tasks for DEBUG peak reporting only.
nonisolated enum StartupTaskTracker {
    private static let lock = NSLock()
    private static var active = 0
    private static var peak = 0

    static func enter(_ name: String) {
#if DEBUG
        lock.lock()
        active += 1
        peak = max(peak, active)
        let current = active
        let peakNow = peak
        lock.unlock()
        StartupPerf.log("taskEnter name=\(name) active=\(current) peak=\(peakNow)")
#endif
    }

    static func exit(_ name: String) {
#if DEBUG
        lock.lock()
        active = max(0, active - 1)
        let current = active
        let peakNow = peak
        lock.unlock()
        StartupPerf.log("taskExit name=\(name) active=\(current) peak=\(peakNow)")
#endif
    }

    static func reportPeak() {
#if DEBUG
        lock.lock()
        let peakNow = peak
        lock.unlock()
        StartupPerf.concurrentTasks(peak: peakNow)
#endif
    }
}

/// DEBUG-only Schedule (Calendar) tab performance tracing.
/// Privacy: never logs user IDs, emails, names, tokens, URLs, or private payloads —
/// only counts, durations, reasons, and cache hit/miss flags.
/// DEBUG-only SwiftUI body / observation recomputation diagnostics.
///
/// Privacy: never logs user IDs, names, emails, tokens, messages, locations, or payloads —
/// only screen/section labels, counts, durations, and boolean flags. Rate-limited per key.
nonisolated enum SwiftUIRecompPerf {
#if DEBUG
    private static let lock = NSLock()
    private static var lastLogAtByKey: [String: CFAbsoluteTime] = [:]
    private static let minInterval: CFAbsoluteTime = 0.35
#endif

    static func log(_ message: String, key: String = "default") {
#if DEBUG
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastLogAtByKey[key], now - last < minInterval {
            lock.unlock()
            return
        }
        lastLogAtByKey[key] = now
        lock.unlock()
        print("===== SWIFTUI RECOMPUTATION ===== \(message)")
#endif
    }

    static func rootBodyEvaluated(screen: String) {
#if DEBUG
        log("rootBody evaluated screen=\(screen)", key: "root.\(screen)")
#endif
    }

    static func sectionBodyEvaluated(screen: String, section: String) {
#if DEBUG
        log("sectionBody evaluated screen=\(screen) section=\(section)", key: "section.\(screen).\(section)")
#endif
    }

    static func rowBodyEvaluated(screen: String, rowKind: String) {
#if DEBUG
        log("rowBody evaluated screen=\(screen) rowKind=\(rowKind)", key: "row.\(screen).\(rowKind)")
#endif
    }

    static func immutableSnapshotPublished(source: String, rows: Int) {
#if DEBUG
        log("immutableSnapshot published source=\(source) rows=\(rows)", key: "snapPub.\(source)")
#endif
    }

    static func identicalSnapshotSkipped(source: String, rows: Int = 0) {
#if DEBUG
        log("identicalSnapshot skipped source=\(source) rows=\(rows)", key: "snapSkip.\(source)")
#endif
    }

    static func rootInvalidated(screen: String, source: String) {
#if DEBUG
        log("rootInvalidated screen=\(screen) source=\(source)", key: "inv.\(screen).\(source)")
#endif
    }

    static func leafInvalidated(leaf: String, source: String) {
#if DEBUG
        log("leafInvalidated leaf=\(leaf) source=\(source)", key: "leaf.\(leaf).\(source)")
#endif
    }

    static func longestMainActorMs(_ ms: Double, label: String) {
#if DEBUG
        log("longestMainActor ms=\(String(format: "%.2f", ms)) label=\(label)", key: "main.\(label)")
#endif
    }
}

nonisolated enum SchedulePerf {
    static func log(_ message: String) {
#if DEBUG
        print("===== SCHEDULE PERFORMANCE ===== \(message)")
#endif
    }

    static func activation(source: String, cachedProRows: Int, inventoryRows: Int) {
#if DEBUG
        log("activation source=\(source) cachedProRows=\(cachedProRows) inventoryRows=\(inventoryRows)")
#endif
    }

    static func preload(action: String, source: String) {
#if DEBUG
        log("preload \(action) source=\(source)")
#endif
    }

    static func refreshRequested(source: String, force: Bool) {
#if DEBUG
        log("refreshRequested source=\(source) force=\(force)")
#endif
    }

    static func refreshStarted(source: String, force: Bool) {
#if DEBUG
        log("refreshStarted source=\(source) force=\(force)")
#endif
    }

    static func refreshCompleted(source: String, ms: Int, rows: Int) {
#if DEBUG
        log("refreshCompleted source=\(source) ms=\(ms) rows=\(rows)")
#endif
    }

    static func refreshCoalesced(source: String) {
#if DEBUG
        log("refreshCoalesced source=\(source)")
#endif
    }

    static func refreshSkippedFresh(source: String, ageSec: Double) {
#if DEBUG
        log("refreshSkipped reason=fresh source=\(source) ageSec=\(String(format: "%.1f", ageSec))")
#endif
    }

    static func staleResultRejected(source: String) {
#if DEBUG
        log("staleResultRejected source=\(source)")
#endif
    }

    static func dateCache(hit: Bool, filtered: Int, revision: UInt64) {
#if DEBUG
        log("selectedDateCache hit=\(hit) filtered=\(filtered) revision=\(revision)")
#endif
    }

    static func snapshotBuild(ms: Double, filtered: Int, inventory: Int, reason: String) {
#if DEBUG
        log(
            "snapshotBuild ms=\(String(format: "%.2f", ms)) filtered=\(filtered) inventory=\(inventory) reason=\(reason)"
        )
#endif
    }

    static func publishApplied(rows: Int, reason: String) {
#if DEBUG
        log("publishApplied rows=\(rows) reason=\(reason)")
#endif
    }

    static func publishSkippedIdentical(rows: Int, reason: String) {
#if DEBUG
        log("publishSkipped reason=identicalContent rows=\(rows) context=\(reason)")
#endif
    }

    static func inventoryPublishSkippedIdentical(rows: Int) {
#if DEBUG
        log("inventoryPublishSkipped reason=identicalContent rows=\(rows)")
#endif
    }

    static func contentRevisionBumped(revision: UInt64, rows: Int, reason: String) {
#if DEBUG
        log("contentRevision revision=\(revision) rows=\(rows) reason=\(reason)")
#endif
    }

    static func longestMainActorMs(_ ms: Double, label: String) {
#if DEBUG
        log("mainActorInterval ms=\(String(format: "%.2f", ms)) label=\(label)")
#endif
    }
}

/// DEBUG-only Going (Following) tab activation / refresh diagnostics.
///
/// Privacy: never logs event titles, venue names, emails, user IDs, tokens, or
/// payloads — only counts, reasons, durations, and boolean flags.
nonisolated enum GoingActivationPerf {
#if DEBUG
    private static var firstOpenLogged = false
    private static var selectedAt: CFAbsoluteTime?
#endif

    static func log(_ message: String) {
#if DEBUG
        print("===== GOING PERFORMANCE ===== \(message)")
#endif
    }

    static func selected(source: String, firstOpen: Bool) {
#if DEBUG
        selectedAt = CFAbsoluteTimeGetCurrent()
        if firstOpen { firstOpenLogged = true }
        log("selected source=\(source) firstOpen=\(firstOpen)")
#endif
    }

    static func shellVisible(cachedContentUsable: Bool) {
#if DEBUG
        let ms = selectedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
        log("shellVisible msSinceSelected=\(ms) cachedContentUsable=\(cachedContentUsable)")
#endif
    }

    static func activation(cachedRows: Int, source: String) {
#if DEBUG
        let firstOpen = !firstOpenLogged
        if firstOpen { firstOpenLogged = true }
        log("activation cachedRows=\(cachedRows) source=\(source) firstOpen=\(firstOpen)")
#endif
    }

    static func refreshSkipped(reason: String, source: String) {
#if DEBUG
        log("refreshSkipped reason=\(reason) source=\(source)")
#endif
    }

    static func refreshStarted(source: String) {
#if DEBUG
        log("refreshStarted source=\(source)")
#endif
    }

    static func refreshJoined(source: String) {
#if DEBUG
        log("refreshJoined source=\(source)")
#endif
    }

    static func refreshCompleted(source: String, ms: Int) {
#if DEBUG
        log("refreshCompleted source=\(source) ms=\(ms)")
#endif
    }

    static func refreshCoalesced(source: String) {
#if DEBUG
        log("refreshCoalesced source=\(source)")
#endif
    }

    static func snapshotBuildMs(_ ms: Double, reason: String) {
#if DEBUG
        log("snapshotBuildMs=\(String(format: "%.2f", ms)) reason=\(reason)")
#endif
    }

    static func publishMs(_ ms: Double, reason: String) {
#if DEBUG
        log("publishMs=\(String(format: "%.2f", ms)) reason=\(reason)")
#endif
    }

    static func publishApplied(name: String, rows: Int) {
#if DEBUG
        log("publishApplied name=\(name) rows=\(rows)")
#endif
    }

    static func publishSkippedIdentical(name: String, rows: Int) {
#if DEBUG
        log("publishSkippedIdentical name=\(name) rows=\(rows)")
#endif
    }

    static func stableReady(cachedContentUsable: Bool) {
#if DEBUG
        let ms = selectedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
        log("stableReady msSinceSelected=\(ms) cachedContentUsable=\(cachedContentUsable)")
#endif
    }
}

/// DEBUG-only image-pipeline diagnostics for `DiscoverMapImageCache` and callers.
///
/// Privacy: never logs URLs, user IDs, names, tokens, or payloads — only counts
/// and timings. Counters are aggregated behind a lock; call `summary()` to emit a
/// single line (e.g. on tab switch) rather than spamming per-request logs.
///
/// `nonisolated` so it is callable from the `DiscoverMapImageCache` actor and from
/// detached decode tasks without hopping to the MainActor.
nonisolated enum ImagePerf {
#if DEBUG
    private static let lock = NSLock()
    private static var downloadsStarted = 0
    private static var downloadsCompleted = 0
    private static var memoryCacheHits = 0
    private static var duplicateRequestsAvoided = 0
    private static var decodes = 0
    private static var decodeTotalMs = 0
    private static var decodeMaxMs = 0
    private static var requestsCancelled = 0
    private static var waitersCancelled = 0
    private static var staleRejected = 0
    private static var imagesReused = 0
    private static var evictions = 0
    private static var memoryWarnings = 0
    private static var downsamples = 0
    private static var downsampleTotalMs = 0
    private static var fullDecodeFallbacks = 0

    private static func bump(_ apply: () -> Void) {
        lock.lock(); apply(); lock.unlock()
    }
#endif

    static func log(_ message: String) {
#if DEBUG
        print("===== IMAGE PERFORMANCE ===== \(message)")
#endif
    }

    static func memoryCacheHit() {
#if DEBUG
        bump { memoryCacheHits += 1 }
#endif
    }

    static func duplicateRequestAvoided() {
#if DEBUG
        bump { duplicateRequestsAvoided += 1 }
#endif
    }

    static func downloadStarted() {
#if DEBUG
        bump { downloadsStarted += 1 }
#endif
    }

    static func downloadCompleted() {
#if DEBUG
        bump { downloadsCompleted += 1 }
#endif
    }

    static func decodeCompleted(ms: Int) {
#if DEBUG
        bump {
            decodes += 1
            decodeTotalMs += ms
            if ms > decodeMaxMs { decodeMaxMs = ms }
        }
#endif
    }

    /// Per-decode downsample trace (no URLs / tokens). Aggregate counters updated too.
    static func downsampleCompleted(
        bucket: String,
        sourceWidth: Int,
        sourceHeight: Int,
        decodedWidth: Int,
        decodedHeight: Int,
        usedDownsample: Bool,
        ms: Double
    ) {
#if DEBUG
        let before = ImageDecodeDownsampler.estimatedBitmapBytes(width: sourceWidth, height: sourceHeight)
        let after = ImageDecodeDownsampler.estimatedBitmapBytes(width: decodedWidth, height: decodedHeight)
        bump {
            downsamples += 1
            downsampleTotalMs += Int(ms)
            decodes += 1
            decodeTotalMs += Int(ms)
            if Int(ms) > decodeMaxMs { decodeMaxMs = Int(ms) }
        }
        log(
            "bucket=\(bucket) source=\(sourceWidth)x\(sourceHeight) decoded=\(decodedWidth)x\(decodedHeight) "
            + "usedDownsample=\(usedDownsample) estimatedMemoryBefore≈\(before) estimatedMemoryAfter≈\(after) "
            + "downsampleMs=\(String(format: "%.2f", ms))"
        )
#endif
    }

    static func downsampleFallbackFullDecode(
        bucket: String,
        sourceWidth: Int,
        sourceHeight: Int,
        decodedWidth: Int,
        decodedHeight: Int,
        ms: Double
    ) {
#if DEBUG
        bump {
            fullDecodeFallbacks += 1
            decodes += 1
            decodeTotalMs += Int(ms)
            if Int(ms) > decodeMaxMs { decodeMaxMs = Int(ms) }
        }
        log(
            "bucket=\(bucket) fullDecodeFallback=true source=\(sourceWidth)x\(sourceHeight) "
            + "decoded=\(decodedWidth)x\(decodedHeight) ms=\(String(format: "%.2f", ms))"
        )
#endif
    }

    static func requestCancelled() {
#if DEBUG
        bump { requestsCancelled += 1 }
#endif
    }

    static func imageReused() {
#if DEBUG
        bump { imagesReused += 1 }
#endif
    }

    static func eviction(count: Int = 1) {
#if DEBUG
        bump { evictions += count }
#endif
    }

    static func memoryWarningPurged(venues: Int, avatars: Int) {
#if DEBUG
        bump { memoryWarnings += 1 }
        log("memoryWarningPurged venues=\(venues) avatars=\(avatars)")
#endif
    }

    static func staleResultRejected() {
#if DEBUG
        bump { staleRejected += 1 }
#endif
    }

    static func waiterCancelled() {
#if DEBUG
        bump { waitersCancelled += 1 }
#endif
    }

    /// Emits one aggregate line and resets counters (safe to call on tab switch).
    static func summary(context: String) {
#if DEBUG
        lock.lock()
        let avgDecode = decodes > 0 ? decodeTotalMs / decodes : 0
        let message = "summary ctx=\(context) downloadsStarted=\(downloadsStarted) downloadsCompleted=\(downloadsCompleted) memHits=\(memoryCacheHits) dupAvoided=\(duplicateRequestsAvoided) decodes=\(decodes) decodeAvgMs=\(avgDecode) decodeMaxMs=\(decodeMaxMs) downsamples=\(downsamples) downsampleTotalMs=\(downsampleTotalMs) fullDecodeFallbacks=\(fullDecodeFallbacks) cancelled=\(requestsCancelled) waiterCancelled=\(waitersCancelled) staleRejected=\(staleRejected) reused=\(imagesReused) evictions=\(evictions) memWarnings=\(memoryWarnings)"
        downloadsStarted = 0
        downloadsCompleted = 0
        memoryCacheHits = 0
        duplicateRequestsAvoided = 0
        decodes = 0
        decodeTotalMs = 0
        decodeMaxMs = 0
        downsamples = 0
        downsampleTotalMs = 0
        fullDecodeFallbacks = 0
        requestsCancelled = 0
        waitersCancelled = 0
        staleRejected = 0
        imagesReused = 0
        evictions = 0
        memoryWarnings = 0
        lock.unlock()
        log(message)
#endif
    }
}

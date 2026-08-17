import Foundation
import os

/// DEBUG-only FanGeo Inbox open + scroll timeline.
///
/// Always prints in Debug (not gated by UIPerf tracing) so an Inbox session
/// produces one concise timeline even when general tracing is off.
enum FanGeoInboxOpenPerf {
#if DEBUG
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fangeo.ios",
        category: "InboxOpen"
    )
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fangeo.ios",
        category: "InboxOpen"
    )
    private static let lock = NSLock()
    private static var openGeneration: UInt64 = 0
    private static var t0: CFAbsoluteTime = 0
    private static var marks: [String: Int] = [:]
    private static var inboxRootBody = 0
    private static var notificationListBody = 0
    private static var notificationCardBody = 0
    private static var actionCenterCardBodyCount = 0
    private static var proGameCardBodyCount = 0
    private static var practiceCardBodyCount = 0
    private static var teamIdentityMarkBodyCount = 0
    private static var playerAvatarBodyCount = 0
    private static var artworkResolverCalls = 0
    private static var inboxReconcileCount = 0
    private static var inboxPublishCount = 0
    private static var duplicatePublishSkippedCount = 0
    private static var cardProjectionCount = 0
    private static var slow16 = 0
    private static var slow33 = 0
    private static var slow100 = 0
    private static var timelineTask: Task<Void, Never>?
    private static var imageStart: ImagePerf.Counters = .zero
    private static var didPrintTimeline = false
    private static var visibleAsyncTasks = 0
#endif

    enum Milestone: String {
        case t0Opened = "T0"
        case t1NotificationsVisible = "T1"
        case t2FirstCardsPainted = "T2"
        case t3FirstSmoothScroll = "T3"
        case t4ArtworkHydration = "T4"
        case t5ReconcileStarts = "T5"
        case t6ReconcileCompletes = "T6"
        case t7AsyncSettled = "T7"
    }

    static func beginOpen(source: String = "sheet") {
#if DEBUG
        lock.lock()
        openGeneration &+= 1
        let generation = openGeneration
        t0 = CFAbsoluteTimeGetCurrent()
        marks = [Milestone.t0Opened.rawValue: 0]
        inboxRootBody = 0
        notificationListBody = 0
        notificationCardBody = 0
        actionCenterCardBodyCount = 0
        proGameCardBodyCount = 0
        practiceCardBodyCount = 0
        teamIdentityMarkBodyCount = 0
        playerAvatarBodyCount = 0
        artworkResolverCalls = 0
        inboxReconcileCount = 0
        inboxPublishCount = 0
        duplicatePublishSkippedCount = 0
        cardProjectionCount = 0
        slow16 = 0
        slow33 = 0
        slow100 = 0
        visibleAsyncTasks = 0
        didPrintTimeline = false
        imageStart = ImagePerf.currentCounters()
        lock.unlock()
        timelineTask?.cancel()
        os_signpost(.event, log: log, name: "InboxOpen T0", "%{public}@", source)
        print("[InboxOpenPerf] T0=0ms source=\(source)")
        timelineTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            printTimelineIfNeeded(generation: generation, reason: "5s")
        }
#endif
    }

    static func mark(_ milestone: Milestone, detail: String = "") {
#if DEBUG
        lock.lock()
        let started = t0
        let already = marks[milestone.rawValue]
        if already == nil, started > 0 {
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            marks[milestone.rawValue] = ms
            lock.unlock()
            os_signpost(.event, log: log, name: "InboxOpen mark", "%{public}@ %{public}@", milestone.rawValue, detail)
            if detail.isEmpty {
                print("[InboxOpenPerf] \(milestone.rawValue)=\(ms)ms")
            } else {
                print("[InboxOpenPerf] \(milestone.rawValue)=\(ms)ms \(detail)")
            }
        } else {
            lock.unlock()
        }
#endif
    }

    static func rootBody() {
#if DEBUG
        lock.lock()
        inboxRootBody += 1
        let count = inboxRootBody
        lock.unlock()
        if count == 1 {
            mark(.t1NotificationsVisible)
        }
#endif
    }

    static func listBody() {
#if DEBUG
        lock.lock()
        notificationListBody += 1
        lock.unlock()
#endif
    }

    static func actionCenterCardBody(isNotification: Bool, isProGame: Bool, isPractice: Bool) {
#if DEBUG
        lock.lock()
        actionCenterCardBodyCount += 1
        if isNotification { notificationCardBody += 1 }
        if isProGame { proGameCardBodyCount += 1 }
        if isPractice { practiceCardBodyCount += 1 }
        let painted = notificationCardBody
        lock.unlock()
        if painted == 1 {
            mark(.t2FirstCardsPainted)
        }
#endif
    }

    static func proGameCardBody() {
#if DEBUG
        lock.lock()
        proGameCardBodyCount += 1
        lock.unlock()
#endif
    }

    static func teamIdentityMarkBody() {
#if DEBUG
        lock.lock()
        teamIdentityMarkBodyCount += 1
        lock.unlock()
#endif
    }

    static func playerAvatarBody() {
#if DEBUG
        lock.lock()
        playerAvatarBodyCount += 1
        lock.unlock()
#endif
    }

    static func artworkResolverCall() {
#if DEBUG
        lock.lock()
        artworkResolverCalls += 1
        if artworkResolverCalls == 1 {
            lock.unlock()
            mark(.t4ArtworkHydration)
        } else {
            lock.unlock()
        }
#endif
    }

    static func cardProjection() {
#if DEBUG
        lock.lock()
        cardProjectionCount += 1
        lock.unlock()
#endif
    }

    static func reconcileStarted() {
#if DEBUG
        lock.lock()
        inboxReconcileCount += 1
        lock.unlock()
        mark(.t5ReconcileStarts)
#endif
    }

    static func reconcileCompleted(didChange: Bool) {
#if DEBUG
        mark(.t6ReconcileCompletes, detail: didChange ? "changed" : "unchanged")
        if !didChange {
            duplicatePublishSkipped(name: "reconcile")
        }
#endif
    }

    static func inboxPublished(name: String) {
#if DEBUG
        lock.lock()
        inboxPublishCount += 1
        lock.unlock()
        logger.debug("inboxPublish \(name, privacy: .public)")
#endif
    }

    static func duplicatePublishSkipped(name: String) {
#if DEBUG
        lock.lock()
        duplicatePublishSkippedCount += 1
        lock.unlock()
        logger.debug("duplicatePublishSkipped \(name, privacy: .public)")
#endif
    }

    static func firstScroll() {
        mark(.t3FirstSmoothScroll)
    }

    static func noteAsyncTaskStarted() {
#if DEBUG
        lock.lock()
        visibleAsyncTasks += 1
        lock.unlock()
#endif
    }

    static func noteAsyncTaskFinished() {
#if DEBUG
        lock.lock()
        visibleAsyncTasks = max(0, visibleAsyncTasks - 1)
        let remaining = visibleAsyncTasks
        let generation = openGeneration
        lock.unlock()
        if remaining == 0 {
            mark(.t7AsyncSettled)
            printTimelineIfNeeded(generation: generation, reason: "asyncSettled")
        }
#endif
    }

    static func mainActorSlowSpan(name: String, durationSeconds: CFAbsoluteTime) {
#if DEBUG
        let ms = durationSeconds * 1000
        guard ms > 16 else { return }
        lock.lock()
        if ms > 100 {
            slow100 += 1
        } else if ms > 33 {
            slow33 += 1
        } else {
            slow16 += 1
        }
        lock.unlock()
        os_signpost(.event, log: log, name: "InboxOpen MainActorSlow", "%{public}@ ms=%{public}@", name, String(format: "%.1f", ms))
        print("[InboxOpenPerf] MainActorSlowSpan name=\(name) ms=\(String(format: "%.1f", ms))")
#endif
    }

    static func measureMainActor<T>(_ name: String, _ work: () -> T) -> T {
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        let value = work()
        mainActorSlowSpan(name: name, durationSeconds: CFAbsoluteTimeGetCurrent() - started)
        return value
#else
        return work()
#endif
    }

#if DEBUG
    private static func printTimelineIfNeeded(generation: UInt64, reason: String) {
        lock.lock()
        guard generation == openGeneration, !didPrintTimeline, t0 > 0 else {
            lock.unlock()
            return
        }
        didPrintTimeline = true
        let marksCopy = marks
        let root = inboxRootBody
        let list = notificationListBody
        let notifCards = notificationCardBody
        let cards = actionCenterCardBodyCount
        let pro = proGameCardBodyCount
        let practice = practiceCardBodyCount
        let teamMark = teamIdentityMarkBodyCount
        let player = playerAvatarBodyCount
        let resolver = artworkResolverCalls
        let reconcile = inboxReconcileCount
        let publish = inboxPublishCount
        let skipped = duplicatePublishSkippedCount
        let projections = cardProjectionCount
        let s16 = slow16
        let s33 = slow33
        let s100 = slow100
        let imageDelta = ImagePerf.currentCounters().subtracting(imageStart)
        lock.unlock()

        func ms(_ key: String) -> String {
            if let value = marksCopy[key] { return "\(value)ms" }
            return "pending"
        }

        let line = [
            "[InboxOpenPerf] timeline reason=\(reason)",
            "T0=0ms",
            "T1=\(ms("T1"))",
            "T2=\(ms("T2"))",
            "T3=\(ms("T3"))",
            "T4=\(ms("T4"))",
            "T5=\(ms("T5"))",
            "T6=\(ms("T6"))",
            "T7=\(ms("T7"))",
            "inboxRootBody=\(root)",
            "notificationListBody=\(list)",
            "notificationCardBody=\(notifCards)",
            "actionCenterCardBody=\(cards)",
            "proGameCardBody=\(pro)",
            "practiceCardBody=\(practice)",
            "teamIdentityMarkBody=\(teamMark)",
            "playerAvatarBody=\(player)",
            "artworkResolverCalls=\(resolver)",
            "imageRequestCount=\(imageDelta.downloadsStarted)",
            "imageMemHit=\(imageDelta.memoryCacheHits)",
            "imageDecodeCount=\(imageDelta.decodes)",
            "inboxReconcileCount=\(reconcile)",
            "inboxPublishCount=\(publish)",
            "duplicatePublishSkipped=\(skipped)",
            "cardProjectionCount=\(projections)",
            "MainActorSlowSpan>16ms=\(s16)",
            "MainActorSlowSpan>33ms=\(s33)",
            "MainActorSlowSpan>100ms=\(s100)"
        ].joined(separator: " ")
        print(line)
        os_signpost(.event, log: log, name: "InboxOpen timeline", "%{public}@", line)
    }
#endif
}

/// Cheap cache key so live-map publishes do not rebuild Inbox.
struct FanGeoActionCenterSnapshotCacheKey: Equatable {
    var epoch: UInt64
    var languageCode: String
    var teamInvitationIds: [UUID]
    var friendRequestIds: [UUID]
    var pickupInviteIds: [UUID]
    var joinApprovalIds: [UUID]
    var pendingRatingGameIds: [UUID]
    var scheduleUnreadIds: [UUID]
    var pokeCount: Int
    var unseenPokesCount: Int
    var showsBusinessClaim: Bool
    var chatUnreadCount: Int
    var dismissedCount: Int
    var snoozeCount: Int
    var clearAllHiddenCount: Int
    var isSignedIn: Bool
}

#if DEBUG
enum FanGeoInboxPerformanceDebug {
    static var injectHundredRowFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("-FANGEO_INBOX_PERF_FIXTURE")
            || ProcessInfo.processInfo.environment["FANGEO_INBOX_PERF_FIXTURE"] == "1"
    }
}
#endif

import Foundation
import os

/// DEBUG-only first-open Profile timeline (T0–T12).
///
/// Always prints in Debug — not gated by `UIPerformanceDiagnostics.uiPerformanceDiagnosticsEnabled` —
/// so a Profile tap produces one concise timeline even when general UIPerf tracing is off.
enum ProfileOpenPerf {
#if DEBUG
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fangeo.ios",
        category: "ProfileOpen"
    )
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fangeo.ios",
        category: "ProfileOpen"
    )
    private static let lock = NSLock()
    private static var openGeneration: UInt64 = 0
    private static var t0: CFAbsoluteTime = 0
    private static var marks: [String: Int] = [:]
    private static var rootBodyCount = 0
    private static var identityCardBodyCount = 0
    private static var snapshotBuildCount = 0
    private static var snapshotBuildTotalUs: Int = 0
    private static var snapshotBuildMaxUs: Int = 0
    private static var statePublishCount = 0
    private static var duplicatePublishSkipped = 0
    private static var cacheHits = 0
    private static var cacheMisses = 0
    private static var mainActorSlowSpans = 0
    private static var timelineTask: Task<Void, Never>?
    private static var imageStart: ImagePerf.Counters = .zero
    private static var didPrintTimeline = false
#endif

    enum Milestone: String {
        case t0TabSelected = "T0"
        case t1SettingsBody = "T1"
        case t2IdentityCardAppear = "T2"
        case t3FirstVisibleContent = "T3"
        case t4ScrollInteractive = "T4"
        case t5MyTeams = "T5"
        case t6FavoriteTeams = "T6"
        case t7HomeCrowd = "T7"
        case t8SuggestedFans = "T8"
        case t9SecondarySections = "T9"
        case t10ArtworkSeed = "T10"
        case t11Sponsored = "T11"
        case t12Settled = "T12"
    }

    static func beginOpen(source: String) {
#if DEBUG
        lock.lock()
        openGeneration &+= 1
        let generation = openGeneration
        t0 = CFAbsoluteTimeGetCurrent()
        marks = [Milestone.t0TabSelected.rawValue: 0]
        rootBodyCount = 0
        identityCardBodyCount = 0
        snapshotBuildCount = 0
        snapshotBuildTotalUs = 0
        snapshotBuildMaxUs = 0
        statePublishCount = 0
        duplicatePublishSkipped = 0
        cacheHits = 0
        cacheMisses = 0
        mainActorSlowSpans = 0
        didPrintTimeline = false
        imageStart = ImagePerf.currentCounters()
        lock.unlock()
        timelineTask?.cancel()
        os_signpost(.event, log: log, name: "ProfileOpen T0", "%{public}@", source)
        logger.debug("T0 Profile tab selected source=\(source, privacy: .public)")
        print("[ProfileOpenPerf] T0=0ms source=\(source)")
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
            os_signpost(.event, log: log, name: "ProfileOpen mark", "%{public}@ %{public}@", milestone.rawValue, detail)
            if detail.isEmpty {
                print("[ProfileOpenPerf] \(milestone.rawValue)=\(ms)ms")
            } else {
                print("[ProfileOpenPerf] \(milestone.rawValue)=\(ms)ms \(detail)")
            }
        } else {
            lock.unlock()
        }
#endif
    }

    static func rootBody() {
#if DEBUG
        lock.lock()
        rootBodyCount += 1
        let count = rootBodyCount
        lock.unlock()
        if count == 1 {
            mark(.t1SettingsBody)
        }
#endif
    }

    static func identityCardBody() {
#if DEBUG
        lock.lock()
        identityCardBodyCount += 1
        let count = identityCardBodyCount
        lock.unlock()
        if count == 1 {
            mark(.t3FirstVisibleContent)
        }
#endif
    }

    static func snapshotBuild(durationSeconds: CFAbsoluteTime) {
#if DEBUG
        let us = Int(durationSeconds * 1_000_000)
        lock.lock()
        snapshotBuildCount += 1
        snapshotBuildTotalUs += us
        if us > snapshotBuildMaxUs { snapshotBuildMaxUs = us }
        lock.unlock()
        if durationSeconds * 1000 >= 16 {
            mainActorSlowSpan(name: "makeScrollSnapshot", durationSeconds: durationSeconds)
        }
#endif
    }

    static func statePublished(name: String) {
#if DEBUG
        lock.lock()
        statePublishCount += 1
        lock.unlock()
        logger.debug("statePublish \(name, privacy: .public)")
#endif
    }

    static func duplicatePublishSkipped(name: String) {
#if DEBUG
        lock.lock()
        duplicatePublishSkipped += 1
        lock.unlock()
        logger.debug("duplicatePublishSkipped \(name, privacy: .public)")
#endif
    }

    static func cacheHit(name: String) {
#if DEBUG
        lock.lock()
        cacheHits += 1
        lock.unlock()
        logger.debug("cacheHit \(name, privacy: .public)")
#endif
    }

    static func cacheMiss(name: String) {
#if DEBUG
        lock.lock()
        cacheMisses += 1
        lock.unlock()
        logger.debug("cacheMiss \(name, privacy: .public)")
#endif
    }

    static func mainActorSlowSpan(name: String, durationSeconds: CFAbsoluteTime) {
#if DEBUG
        let ms = durationSeconds * 1000
        guard ms > 16 else { return }
        lock.lock()
        mainActorSlowSpans += 1
        lock.unlock()
        os_signpost(.event, log: log, name: "ProfileOpen MainActorSlow", "%{public}@ ms=%{public}@", name, String(format: "%.1f", ms))
        print("[ProfileOpenPerf] MainActorSlowSpan name=\(name) ms=\(String(format: "%.1f", ms))")
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

    static func noteSettled(reason: String) {
#if DEBUG
        mark(.t12Settled, detail: reason)
        lock.lock()
        let generation = openGeneration
        lock.unlock()
        printTimelineIfNeeded(generation: generation, reason: reason)
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
        let root = rootBodyCount
        let identity = identityCardBodyCount
        let snapCount = snapshotBuildCount
        let snapAvg = snapshotBuildCount > 0 ? snapshotBuildTotalUs / snapshotBuildCount : 0
        let snapMax = snapshotBuildMaxUs
        let publishes = statePublishCount
        let skipped = duplicatePublishSkipped
        let hits = cacheHits
        let misses = cacheMisses
        let slow = mainActorSlowSpans
        let imageDelta = ImagePerf.currentCounters().subtracting(imageStart)
        lock.unlock()

        func ms(_ key: String) -> String {
            if let value = marksCopy[key] { return "\(value)ms" }
            return "pending"
        }

        let line = [
            "[ProfileOpenPerf] timeline reason=\(reason)",
            "T0=0ms",
            "T1=\(ms("T1"))",
            "T2=\(ms("T2"))",
            "T3=\(ms("T3"))",
            "T4=\(ms("T4"))",
            "T5=\(ms("T5"))",
            "T6=\(ms("T6"))",
            "T7=\(ms("T7"))",
            "T8=\(ms("T8"))",
            "T9=\(ms("T9"))",
            "T10=\(ms("T10"))",
            "T11=\(ms("T11"))",
            "T12=\(ms("T12"))",
            "profileRootBody=\(root)",
            "identityCardBody=\(identity)",
            "scrollGateSnapshotBuilds=\(snapCount) avgUs=\(snapAvg) maxUs=\(snapMax)",
            "statePublishCount=\(publishes)",
            "duplicatePublishSkipped=\(skipped)",
            "cacheHit=\(hits) cacheMiss=\(misses)",
            "MainActorSlowSpan=\(slow)",
            "image downloads=\(imageDelta.downloadsStarted) memHits=\(imageDelta.memoryCacheHits) decodes=\(imageDelta.decodes)"
        ].joined(separator: " ")
        print(line)
        os_signpost(.event, log: log, name: "ProfileOpen timeline", "%{public}@", line)
    }
#endif
}

import Foundation

#if DEBUG
/// Direct Chat publish-during-update investigation harness (DEBUG only).
///
/// Body-stage bisection is opt-in via launch argument `-DirectChatBodyBisect=<stage>`.
/// Default and production path is always ``.full``.
enum DirectChatInvestigation {
    /// When true: suppress unrelated DEBUG self-tests / chat-root body spam so the
    /// ~2s around a DM tap stays readable.
    static let quietConsole = true

    /// Default ``.full``. Override only with `-DirectChatBodyBisect=hRealComposer` (etc.).
    static var bodyStage: BodyStage = {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-DirectChatBodyBisect"),
              args.index(after: idx) < args.endIndex,
              let raw = Int(args[args.index(after: idx)]),
              let stage = BodyStage(rawValue: raw) else {
            return .full
        }
        return stage
    }()

    enum BodyStage: Int, CaseIterable, CustomStringConvertible {
        case aProofText = 0
        case bNavTitle = 1
        case cStaticLayout = 2
        case dHeader = 3
        case eTimelineEmpty = 4
        case fComposerShell = 5
        case gRealMessageRows = 6
        case hRealComposer = 7
        case iToolbarMenus = 8
        case jLifecycle = 9
        case full = 100

        var description: String {
            switch self {
            case .aProofText: return "A_proofText"
            case .bNavTitle: return "B_navTitle"
            case .cStaticLayout: return "C_staticLayout"
            case .dHeader: return "D_header"
            case .eTimelineEmpty: return "E_timelineEmpty"
            case .fComposerShell: return "F_composerShell"
            case .gRealMessageRows: return "G_realRows"
            case .hRealComposer: return "H_realComposer"
            case .iToolbarMenus: return "I_toolbarMenus"
            case .jLifecycle: return "J_lifecycle"
            case .full: return "full"
            }
        }

        var includesLifecycle: Bool {
            self == .jLifecycle || self == .full
        }

        var includesRealComposer: Bool {
            rawValue >= BodyStage.hRealComposer.rawValue || self == .full
        }

        var includesToolbar: Bool {
            rawValue >= BodyStage.iToolbarMenus.rawValue || self == .full
        }
    }

    enum Phase: String {
        case initPhase = "init"
        case body
        case task
        case appear
        case disappear
        case other
    }

    private(set) static var phase: Phase = .other
    private static var traceCount = 0
    private static let traceCap = 80

    static func setPhase(_ next: Phase) {
        phase = next
    }

    /// Log BEFORE a DirectChat-related mutation. No message text / full UUIDs / coords / emails.
    static func trace(source: String, property: String) {
        traceCount += 1
        guard traceCount <= traceCap else { return }
        print(
            "[DirectChatPublishTrace] source=\(source) property=\(property) phase=\(phase.rawValue) #\(traceCount)"
        )
        if traceCount == traceCap {
            print("[DirectChatPublishTrace] capped at \(traceCap)")
        }
    }

    fileprivate static func resetTraceCount() {
        traceCount = 0
    }
}

/// Minimal open-path timing + destination-identity correlation (measure only).
enum DirectChatOpenPerf {
    private static var routePublishedAt: CFAbsoluteTime?
    private static var destinationInitAt: CFAbsoluteTime?
    private static var firstBodyAt: CFAbsoluteTime?
    private static var composerMountedAt: CFAbsoluteTime?
    private static var firstFrameAt: CFAbsoluteTime?
    private static var messageFetchStartAt: CFAbsoluteTime?
    private static var messageFetchEndAt: CFAbsoluteTime?
    private static var realtimeStartAt: CFAbsoluteTime?
    private static var destinationInitCount = 0
    private static var bodyEvalCount = 0
    private static var bodyWindowStart: CFAbsoluteTime?
    private static var didLogBodyWindowSummary = false
    private static var lastPublisher: String = "none"
    private static var activePresenterId: ObjectIdentifier?
    private static var presenterCreateCount = 0
    private static var onAppearCount = 0
    private static var onDisappearCount = 0
    private static var taskBeginCount = 0
    private static var activeRouteKey: String?

    /// Record the most recent Chat/MainTab publication for destination.init correlation.
    static func notePrecedingPublisher(object: String, property: String) {
        lastPublisher = "\(object).\(property)"
    }

    static func resetForNewOpen() {
        routePublishedAt = nil
        destinationInitAt = nil
        firstBodyAt = nil
        composerMountedAt = nil
        firstFrameAt = nil
        messageFetchStartAt = nil
        messageFetchEndAt = nil
        realtimeStartAt = nil
        destinationInitCount = 0
        bodyEvalCount = 0
        bodyWindowStart = nil
        didLogBodyWindowSummary = false
        lastPublisher = "none"
        activePresenterId = nil
        presenterCreateCount = 0
        onAppearCount = 0
        onDisappearCount = 0
        taskBeginCount = 0
        activeRouteKey = nil
        DirectChatInvestigation.resetTraceCount()
    }

    static func routePublished(routeKey: String) {
        resetForNewOpen()
        activeRouteKey = routeKey
        let now = CFAbsoluteTimeGetCurrent()
        routePublishedAt = now
        print("[DirectChatOpenPerf] routePublished t=0.0ms routeKey=\(shortKey(routeKey))")
    }

    static func destinationInitialized(routeKey: String? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        destinationInitCount += 1
        if destinationInitAt == nil {
            destinationInitAt = now
        }
        let sinceRoute = ms(since: routePublishedAt, to: now)
        let samePresenter: String = {
            guard let activePresenterId else { return "presenter=nil" }
            return "presenter=\(shortOID(activePresenterId))"
        }()
        print(
            "[DirectChatOpenPerf] destination.init #\(destinationInitCount) "
            + "tapToDestinationMs=\(sinceRoute) precedingPublisher=\(lastPublisher) "
            + "\(samePresenter) note=viewValueInit"
        )
        if let routeKey {
            print("[DirectChatOpenPerf] destination.routeKey=\(shortKey(routeKey))")
        }
    }

    static func presenterCreated(_ id: ObjectIdentifier) {
        presenterCreateCount += 1
        let reused = (activePresenterId == id)
        activePresenterId = id
        print(
            "[DirectChatOpenPerf] presenter.create #\(presenterCreateCount) "
            + "id=\(shortOID(id)) reusedStorage=\(reused) "
            + "note=\(presenterCreateCount == 1 ? "firstStateObject" : "unexpectedNewPresenter")"
        )
    }

    static func presenterDeinit(_ id: ObjectIdentifier) {
        print("[DirectChatOpenPerf] presenter.deinit id=\(shortOID(id))")
        if activePresenterId == id {
            activePresenterId = nil
        }
    }

    static func bodyEvaluated() {
        let now = CFAbsoluteTimeGetCurrent()
        bodyEvalCount += 1
        if bodyWindowStart == nil {
            bodyWindowStart = now
        }
        if firstBodyAt == nil {
            firstBodyAt = now
            let sinceDest = ms(since: destinationInitAt, to: now)
            let sinceRoute = ms(since: routePublishedAt, to: now)
            print(
                "[DirectChatOpenPerf] firstBody destinationToBodyMs=\(sinceDest) tapToBodyMs=\(sinceRoute)"
            )
        }
        if !didLogBodyWindowSummary,
           let start = bodyWindowStart,
           now - start >= 2.0 {
            didLogBodyWindowSummary = true
            print(
                "[DirectChatOpenPerf] bodyEvalsInFirst2s count=\(bodyEvalCount) "
                + "destinationInits=\(destinationInitCount) presenterCreates=\(presenterCreateCount) "
                + "onAppear=\(onAppearCount) onDisappear=\(onDisappearCount) taskBegin=\(taskBeginCount)"
            )
        }
    }

    static func composerMounted() {
        guard composerMountedAt == nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        composerMountedAt = now
        print(
            "[DirectChatOpenPerf] composerMounted destinationToComposerMs=\(ms(since: destinationInitAt, to: now))"
        )
    }

    static func firstVisibleFrame() {
        guard firstFrameAt == nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        firstFrameAt = now
        print(
            "[DirectChatOpenPerf] firstVisibleFrame destinationToFirstFrameMs=\(ms(since: destinationInitAt, to: now)) tapToFirstFrameMs=\(ms(since: routePublishedAt, to: now))"
        )
    }

    static func onAppear(presenterId: ObjectIdentifier, generation: Int) {
        onAppearCount += 1
        print(
            "[DirectChatOpenPerf] directChat.onAppear #\(onAppearCount) "
            + "presenter=\(shortOID(presenterId)) gen=\(generation)"
        )
    }

    static func onDisappear(presenterId: ObjectIdentifier, generation: Int) {
        onDisappearCount += 1
        print(
            "[DirectChatOpenPerf] directChat.onDisappear #\(onDisappearCount) "
            + "presenter=\(shortOID(presenterId)) gen=\(generation)"
        )
    }

    static func taskBegin(presenterId: ObjectIdentifier, generation: Int) {
        taskBeginCount += 1
        print(
            "[DirectChatOpenPerf] destination.taskBegin #\(taskBeginCount) "
            + "presenter=\(shortOID(presenterId)) gen=\(generation)"
        )
    }

    static func messageFetchStart() {
        guard messageFetchStartAt == nil else { return }
        messageFetchStartAt = CFAbsoluteTimeGetCurrent()
        print("[DirectChatOpenPerf] messageFetchStart")
    }

    static func messageFetchEnd(publishedCount: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        messageFetchEndAt = now
        print(
            "[DirectChatOpenPerf] messageFetchEnd durationMs=\(ms(since: messageFetchStartAt, to: now)) publishedCount=\(publishedCount)"
        )
        print("[DirectChatOpenPerf] messagesPublished count=\(publishedCount)")
    }

    static func realtimeSubscribeStart() {
        guard realtimeStartAt == nil else { return }
        realtimeStartAt = CFAbsoluteTimeGetCurrent()
        print("[DirectChatOpenPerf] realtimeSubscribeStart")
    }

    static func realtimeSubscribeReady() {
        print(
            "[DirectChatOpenPerf] realtimeSubscribeReady durationMs=\(ms(since: realtimeStartAt, to: CFAbsoluteTimeGetCurrent()))"
        )
    }

    private static func ms(since start: CFAbsoluteTime?, to end: CFAbsoluteTime) -> String {
        guard let start else { return "nil" }
        return String(format: "%.1f", (end - start) * 1000)
    }

    private static func shortOID(_ id: ObjectIdentifier) -> String {
        String(UInt(bitPattern: id), radix: 16, uppercase: false).suffix(6).description
    }

    private static func shortKey(_ key: String) -> String {
        if key.count <= 20 { return key }
        return String(key.prefix(12)) + "…"
    }
}
#endif

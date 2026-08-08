import Foundation

#if DEBUG
enum SettingsNavigationDebug {
    static func log(_ message: String) {
        print("[SettingsNavigationDebug] \(message)")
    }
}

/// Sequential Settings navigation validator — manual validation / UI testing only.
///
/// Never runs during a normal launch: it requires the explicit, non-persistent
/// launch argument ``launchArgument`` (a process argument, never a stored
/// UserDefaults value, so it cannot accidentally remain enabled on a device).
/// The entire type is compiled out of Release builds.
@MainActor
enum ProfileSettingsSequentialNavValidation {
    /// Explicit opt-in launch argument. Intentionally different from the legacy
    /// `-SettingsNavSequentialValidation` argument so a stale scheme entry from
    /// an old validation session can no longer auto-run the validator.
    static let launchArgument = "-FanGeoRunProfileSettingsSequentialNavValidation"
    static let fullRunLaunchArgument = "-FanGeoRunProfileSettingsSequentialNavValidationFull"

    private static let banner = "===== PROFILE SETTINGS NAV VALIDATION ====="

    static var isExplicitlyEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private static var currentRunTask: Task<Void, Never>?
    private static var currentRunNavigatorId: UUID?
    private static var didLogSkipThisProcess = false

    private static func log(_ message: String) {
        print("\(banner) \(message)")
    }

    /// One concise skip entry per process at most; silent on later Settings opens.
    static func logSkippedIfNeeded(source: String) {
        guard !didLogSkipThisProcess else { return }
        didLogSkipThisProcess = true
        log("skipped reason=explicitFlagAbsent source=\(source)")
    }

    /// Schedules a validation run owned by `navigator`.
    /// Rejects a duplicate for the same navigator; a request from a newer host
    /// cancels the stale run before starting.
    static func scheduleIfExplicitlyEnabled(navigator: ProfileSettingsNavigator, source: String) {
        guard isExplicitlyEnabled else {
            logSkippedIfNeeded(source: source)
            return
        }
        if let task = currentRunTask, !task.isCancelled {
            if currentRunNavigatorId == navigator.instanceId {
                log("duplicate run rejected navigatorId=\(navigator.instanceId.uuidString) source=\(source)")
                return
            }
            log("cancelling stale run oldNavigatorId=\(currentRunNavigatorId?.uuidString ?? "nil") source=\(source)")
            task.cancel()
        }
        log("scheduling requested source=\(source) navigatorId=\(navigator.instanceId.uuidString)")
        currentRunNavigatorId = navigator.instanceId
        currentRunTask = Task { @MainActor [weak navigator] in
            // Wait for sheet settle / privacy token.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else {
                log("run aborted safely reason=cancelledBeforeStart")
                return
            }
            guard let navigator else {
                log("run aborted safely reason=navigatorDeallocatedBeforeStart")
                return
            }
            await run(navigator: navigator)
        }
    }

    /// Cancels the active run if it is owned by `navigatorId` (or any run when nil).
    static func cancelRun(navigatorId: UUID?, reason: String) {
        guard let task = currentRunTask, !task.isCancelled else { return }
        if let navigatorId, let owner = currentRunNavigatorId, owner != navigatorId { return }
        log("cancellation observed reason=\(reason)")
        task.cancel()
        currentRunTask = nil
    }

    private static func run(navigator: ProfileSettingsNavigator) async {
        weak let weakNavigator = navigator
        let runNavigatorId = navigator.instanceId
        let full = ProcessInfo.processInfo.arguments.contains(fullRunLaunchArgument)
        let appearanceHoldNs: UInt64 = full ? 15_000_000_000 : 2_000_000_000
        let supportHoldNs: UInt64 = full ? 30_000_000_000 : 3_000_000_000
        let shortHoldNs: UInt64 = full ? 1_000_000_000 : 400_000_000

        log("run started full=\(full) navigatorId=\(runNavigatorId.uuidString)")

        var failed = false

        /// Re-acquires the owning navigator; nil means the run must stop (cancelled, host gone, or ownership changed).
        func liveNavigator(step: String) -> ProfileSettingsNavigator? {
            if Task.isCancelled {
                log("cancellation observed step=\(step)")
                return nil
            }
            guard let nav = weakNavigator else {
                log("host disappeared step=\(step) (navigator deallocated)")
                return nil
            }
            guard nav.instanceId == runNavigatorId, currentRunNavigatorId == runNavigatorId else {
                log("run aborted safely step=\(step) reason=ownershipChanged")
                return nil
            }
            return nav
        }

        func expectRoot(_ label: String) {
            guard let nav = liveNavigator(step: label) else { return }
            if nav.path.count != 0 {
                failed = true
                log("FAIL step=\(label) expectedPathCount=0 actual=\(nav.path.count) path=\(nav.pathSummary())")
            } else {
                log("OK step=\(label) pathCount=0")
            }
        }

        /// Pushes `route`, holds, then pops only the route this step owns.
        /// Returns false when the run must stop (cancelled / host gone / expected route absent).
        func openAndHold(_ route: ProfileSettingsRoute, holdNs: UInt64, label: String) async -> Bool {
            guard let nav = liveNavigator(step: "\(label)Open") else { return false }
            log("route push requested route=\(route.debugName) step=\(label)")
            nav.openRootDestination(route, source: "sequentialValidation:\(label)")
            if nav.path != [route] {
                failed = true
                log("FAIL step=\(label)Open expected=[\(route.debugName)] actual=\(nav.pathSummary())")
            } else {
                log("route push completed route=\(route.debugName) step=\(label)")
            }

            try? await Task.sleep(nanoseconds: holdNs)

            guard let heldNav = liveNavigator(step: "\(label)Hold") else { return false }
            if heldNav.path != [route] {
                failed = true
                log("FAIL step=\(label)Hold path drifted to \(heldNav.pathSummary())")
                SettingsNavigationDebug.log(
                    "pathDesyncDetected route=\(route.debugName) pathCount=\(heldNav.path.count) source=sequentialValidationHold:\(label) path=\(heldNav.pathSummary())"
                )
            } else {
                log("OK step=\(label)Hold path=\(heldNav.pathSummary())")
            }

            // Safe pop: only remove the route this step pushed, verified as current top.
            if heldNav.path.last == route {
                heldNav.path.removeLast()
                log("safe pop completed route=\(route.debugName) step=\(label)")
            } else {
                failed = true
                log("expected route missing at pop step=\(label) top=\(heldNav.topRoute?.debugName ?? "nil") path=\(heldNav.pathSummary()) — stopping validation")
                return false
            }
            expectRoot("\(label)Back")
            return true
        }

        func finish(aborted: Bool) {
            if currentRunNavigatorId == runNavigatorId {
                currentRunTask = nil
                currentRunNavigatorId = nil
            }
            if aborted {
                log("run aborted safely result=\(failed ? "FAIL" : "INCOMPLETE")")
            } else {
                log("run completed result=\(failed ? "FAIL" : "PASS")")
            }
        }

        expectRoot("start")

        var steps: [(ProfileSettingsRoute, UInt64, String)] = [
            (.appearance, appearanceHoldNs, "appearance"),
            (.support, supportHoldNs, "support"),
            (.helpAndTutorial, shortHoldNs, "help"),
            (.privacyPolicy, shortHoldNs, "privacy"),
            (.termsOfService, shortHoldNs, "terms"),
            (.notifications, shortHoldNs, "notifications"),
            (.support, shortHoldNs, "supportReopen")
        ]
        steps.append(contentsOf: [
            ProfileSettingsRoute.language,
            .timeZone,
            .chatSecurity,
            .reportingModeration,
            .blockingUsersInfo,
            .privacyLocationSharing,
            .communityGuidelines,
            .trustSafety,
            .liveActivitySharing,
            .resetPassword
        ].map { ($0, shortHoldNs, $0.debugName) })

        for (route, holdNs, label) in steps {
            guard await openAndHold(route, holdNs: holdNs, label: label) else {
                finish(aborted: true)
                return
            }
        }

        finish(aborted: false)
    }
}

enum SettingsPerf {
    static func log(_ event: String) {
        print("[SettingsPerf] \(event)")
    }
}
#endif

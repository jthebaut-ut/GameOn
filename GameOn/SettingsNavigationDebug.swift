import Foundation

#if DEBUG
enum SettingsNavigationDebug {
    static func log(_ message: String) {
        print("[SettingsNavigationDebug] \(message)")
    }
}

@MainActor
enum ProfileSettingsSequentialNavValidation {
    static var didStartPathOnlyRun = false

    static func run(navigator: ProfileSettingsNavigator) async {
        let full = ProcessInfo.processInfo.arguments.contains("-SettingsNavSequentialValidationFull")
        let appearanceHoldNs: UInt64 = full ? 15_000_000_000 : 2_000_000_000
        let supportHoldNs: UInt64 = full ? 30_000_000_000 : 3_000_000_000
        let shortHoldNs: UInt64 = full ? 1_000_000_000 : 400_000_000

        SettingsNavigationDebug.log("sequentialValidationBegin full=\(full)")

        var failed = false
        func expectRoot(_ label: String) {
            if navigator.path.count != 0 {
                failed = true
                SettingsNavigationDebug.log(
                    "sequentialValidationFAIL step=\(label) expectedPathCount=0 actual=\(navigator.path.count) path=\(navigator.pathSummary())"
                )
            } else {
                SettingsNavigationDebug.log("sequentialValidationOK step=\(label) pathCount=0")
            }
        }
        func openAndHold(_ route: ProfileSettingsRoute, holdNs: UInt64, label: String) async {
            navigator.openRootDestination(route, source: "sequentialValidation:\(label)")
            if navigator.path != [route] {
                failed = true
                SettingsNavigationDebug.log(
                    "sequentialValidationFAIL step=\(label)Open expected=[\(route.debugName)] actual=\(navigator.pathSummary())"
                )
            }
            try? await Task.sleep(nanoseconds: holdNs)
            if navigator.path != [route] {
                failed = true
                SettingsNavigationDebug.log(
                    "pathDesyncDetected route=\(route.debugName) pathCount=\(navigator.path.count) source=sequentialValidationHold:\(label) path=\(navigator.pathSummary())"
                )
                SettingsNavigationDebug.log(
                    "sequentialValidationFAIL step=\(label)Hold path drifted to \(navigator.pathSummary())"
                )
            } else {
                SettingsNavigationDebug.log("sequentialValidationOK step=\(label)Hold path=\(navigator.pathSummary())")
            }
            navigator.path.removeLast()
            expectRoot("\(label)Back")
        }

        expectRoot("start")
        await openAndHold(.appearance, holdNs: appearanceHoldNs, label: "appearance")
        await openAndHold(.support, holdNs: supportHoldNs, label: "support")
        await openAndHold(.helpAndTutorial, holdNs: shortHoldNs, label: "help")
        await openAndHold(.privacyPolicy, holdNs: shortHoldNs, label: "privacy")
        await openAndHold(.termsOfService, holdNs: shortHoldNs, label: "terms")
        await openAndHold(.notifications, holdNs: shortHoldNs, label: "notifications")
        await openAndHold(.support, holdNs: shortHoldNs, label: "supportReopen")

        // Additional routes (shorter hold)
        for route in [
            ProfileSettingsRoute.language,
            .timeZone,
            .communityGuidelines,
            .trustSafety,
            .liveActivitySharing,
            .resetPassword
        ] {
            await openAndHold(route, holdNs: shortHoldNs, label: route.debugName)
        }

        SettingsNavigationDebug.log(
            failed
                ? "sequentialValidationRESULT=FAIL"
                : "sequentialValidationRESULT=PASS"
        )
    }
}

enum SettingsPerf {
    static func log(_ event: String) {
        print("[SettingsPerf] \(event)")
    }
}
#endif

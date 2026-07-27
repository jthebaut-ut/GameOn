import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// DEBUG-only memory/retention sampling for the FanGeo memory audit.
/// Enabled only when process environment contains `FANGEO_MEMORY_AUDIT=1`.
/// Does not alter product behavior when disabled (Release / normal Debug runs).
enum MemoryAuditProbe {
    static var isEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["FANGEO_MEMORY_AUDIT"] == "1"
#else
        false
#endif
    }

#if DEBUG
    static let tabSelectNotification = Notification.Name("MemoryAuditProbe.tabSelect")
    static let logoutNotification = Notification.Name("MemoryAuditProbe.logout")
#endif

    /// Resident footprint in bytes (phys_footprint), or nil if unavailable.
    static func physicalFootprintBytes() -> UInt64? {
#if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
#else
        return nil
#endif
    }

    static func log(_ phase: String, details: String = "") {
#if DEBUG
        guard isEnabled else { return }
        let mb: String
        if let bytes = physicalFootprintBytes() {
            mb = String(format: "%.1f", Double(bytes) / 1_048_576.0)
        } else {
            mb = "n/a"
        }
        let extra = details.isEmpty ? "" : " \(details)"
        print("[MemoryAudit] phase=\(phase) footprintMB=\(mb)\(extra)")
#endif
    }

#if DEBUG
    private static var periodicTask: Task<Void, Never>?
    private static var didInstallHooks = false

    /// Starts optional periodic samples + remote Darwin hooks. No-op unless audit env is set.
    static func installIfNeeded() {
        guard isEnabled, !didInstallHooks else { return }
        didInstallHooks = true
        log("cold_or_attach", details: "hooks=installed")
        startPeriodicSampling(intervalSeconds: 20)
        installDarwinRemoteHooks()
    }

    private static func installDarwinRemoteHooks() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let tabs = ["discover", "live", "calendar", "following", "chat", "account"]
        for tab in tabs {
            let name = "com.jt.fangio.memoryaudit.tab.\(tab)" as CFString
            CFNotificationCenterAddObserver(
                center,
                nil,
                { _, _, cfName, _, _ in
                    let raw = (cfName?.rawValue as String?) ?? ""
                    let tab = raw.split(separator: ".").last.map(String.init) ?? ""
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: MemoryAuditProbe.tabSelectNotification,
                            object: tab
                        )
                    }
                },
                name,
                nil,
                .deliverImmediately
            )
        }
        let logoutName = "com.jt.fangio.memoryaudit.logout" as CFString
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: MemoryAuditProbe.logoutNotification, object: nil)
                }
            },
            logoutName,
            nil,
            .deliverImmediately
        )
        let sampleName = "com.jt.fangio.memoryaudit.sample" as CFString
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    MemoryAuditProbe.log("remote_sample")
                }
            },
            sampleName,
            nil,
            .deliverImmediately
        )
    }

    static func startPeriodicSampling(intervalSeconds: UInt64) {
        guard isEnabled else { return }
        periodicTask?.cancel()
        periodicTask = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                tick += 1
                log("periodic", details: "tick=\(tick)")
            }
        }
    }

    static func stopPeriodicSampling() {
        periodicTask?.cancel()
        periodicTask = nil
    }
#endif
}

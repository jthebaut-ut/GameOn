import Foundation

/// Wall-clock + monotonic timestamps for correlating DM latency logs across phases.
///
/// **Interpretation**
/// - ``wall``: ISO8601 device wall clock (fractional seconds). Useful for rough cross-device ordering; clocks may skew.
/// - ``monoBootSec``: `ProcessInfo.processInfo.systemUptime` — reliable **same-device** deltas between log lines.
enum DMRealtimeDiagnostics {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// DM realtime trace (DEBUG only — avoids Release hot-path console I/O).
    static func debug(_ fields: String) {
#if DEBUG
        let wall = isoFormatter.string(from: Date())
        print("[DMRealtimeDebug] \(fields) wall=\(wall)")
#endif
    }

    /// Extra key=value fields only; prefix and timestamps are added automatically.
    static func log(_ fields: String) {
#if DEBUG
        let wall = isoFormatter.string(from: Date())
        let mono = ProcessInfo.processInfo.systemUptime
        print("[DMRealtimeDiag] \(fields) wall=\(wall) monoBootSec=\(String(format: "%.3f", mono))")
#endif
    }
}

enum RealtimeHealthDiagnostics {
    static func log(_ fields: String) {
#if DEBUG
        print("[RealtimeHealthDebug] \(fields)")
#endif
    }
}

/// Focused reopen/dismiss race tracing for composer Connecting/Reconnecting audits.
/// No message bodies, tokens, or location data.
enum ChatRealtimeAudit {
    static func log(
        conversationId: UUID?,
        generation: Int,
        event: String,
        status: String? = nil,
        extra: String? = nil
    ) {
#if DEBUG
        let conv = conversationId.map { String($0.uuidString.prefix(8)).lowercased() } ?? "nil"
        var line = "[ChatRealtimeAudit] conv=\(conv) gen=\(generation) event=\(event)"
        if let status { line += " status=\(status)" }
        if let extra, !extra.isEmpty { line += " \(extra)" }
        print(line)
#endif
    }

    static func statusTransition(
        conversationId: UUID?,
        generation: Int,
        from old: ChatRealtimeConnectionStatus,
        to new: ChatRealtimeConnectionStatus,
        reason: String
    ) {
#if DEBUG
        log(
            conversationId: conversationId,
            generation: generation,
            event: "status",
            status: String(describing: new),
            extra: "old=\(String(describing: old)) new=\(String(describing: new)) reason=\(reason)"
        )
#endif
    }
}

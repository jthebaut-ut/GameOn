import Foundation
import Supabase

/// Serializes remove/create work per stable Supabase realtime topic so a late
/// `removeChannel` cannot race a newer subscribe on the same topic.
///
/// Critical: awaits are **bounded**. An indefinite hang on `removeChannel` /
/// a prior serializer task was a production root cause of Direct Chat stuck on
/// “Connecting…” (watchdog treated the hung subscribe task as healthy forever).
actor ChatRealtimeChannelSerializer {
    static let shared = ChatRealtimeChannelSerializer()

    /// Default budget for waiting on a prior topic op or `removeChannel`.
    static let defaultTimeoutNs: UInt64 = 8_000_000_000

    private var topicTails: [String: Task<Void, Never>] = [:]

    /// Waits for any in-flight remove/create work on `topic` to finish (or times out).
    func waitForTopicIdle(
        _ topic: String,
        timeoutNs: UInt64 = ChatRealtimeChannelSerializer.defaultTimeoutNs
    ) async {
#if DEBUG
        print("[ChatRealtime] event=serializerEnter op=wait topic=\(topic.prefix(48))")
#endif
        guard let prior = topicTails[topic] else {
#if DEBUG
            print("[ChatRealtime] event=serializerExit op=wait topic=\(topic.prefix(48)) idle=true")
#endif
            return
        }

        let finished = await Self.awaitTaskOrTimeout(prior, timeoutNs: timeoutNs)
        if !finished {
#if DEBUG
            print("[ChatRealtime] event=serializerTimeout op=wait topic=\(topic.prefix(48)) action=abandonStuckPrior")
#endif
            // Detach from the stuck prior so a fresh subscribe can proceed.
            if topicTails[topic] == prior {
                topicTails[topic] = nil
            }
#if DEBUG
            print("[ChatRealtime] event=serializerExit op=wait topic=\(topic.prefix(48)) idle=timeoutAbandoned")
#endif
            return
        }

        if topicTails[topic] == prior {
            topicTails[topic] = nil
        }
#if DEBUG
        print("[ChatRealtime] event=serializerExit op=wait topic=\(topic.prefix(48)) idle=afterPrior")
#endif
    }

    /// Enqueues an exclusive remove for `topic` (awaits prior work first, both bounded).
    func removeExclusive(
        topic: String,
        channel: RealtimeChannelV2,
        timeoutNs: UInt64 = ChatRealtimeChannelSerializer.defaultTimeoutNs,
        remove: @escaping @Sendable (RealtimeChannelV2) async -> Void
    ) async {
#if DEBUG
        print("[ChatRealtime] event=serializerEnter op=remove topic=\(topic.prefix(48))")
#endif
        let prior = topicTails[topic]
        let task = Task {
            if let prior {
                let priorFinished = await Self.awaitTaskOrTimeout(prior, timeoutNs: timeoutNs)
                if !priorFinished {
#if DEBUG
                    print("[ChatRealtime] event=serializerTimeout op=removePrior topic=\(topic.prefix(48))")
#endif
                }
            }
            let removeFinished = await Self.awaitOperationOrTimeout(timeoutNs: timeoutNs) {
                await remove(channel)
            }
            if !removeFinished {
#if DEBUG
                print("[ChatRealtime] event=serializerTimeout op=removeChannel topic=\(topic.prefix(48))")
#endif
            }
        }
        topicTails[topic] = task

        let joined = await Self.awaitTaskOrTimeout(task, timeoutNs: timeoutNs + 2_000_000_000)
        if !joined {
#if DEBUG
            print("[ChatRealtime] event=serializerTimeout op=removeJoin topic=\(topic.prefix(48)) action=detachTail")
#endif
            // Leave the remove Task running in the background, but do not block callers.
            // Clear the tail so subsequent subscribe/wait is not chained to this hang.
            if topicTails[topic] == task {
                topicTails[topic] = nil
            }
#if DEBUG
            print("[ChatRealtime] event=serializerExit op=remove topic=\(topic.prefix(48)) result=timeoutDetached")
#endif
            return
        }

        if topicTails[topic] == task {
            topicTails[topic] = nil
        }
#if DEBUG
        print("[ChatRealtime] event=serializerExit op=remove topic=\(topic.prefix(48))")
#endif
    }

    // MARK: - Timeout helpers

    private static func awaitTaskOrTimeout(
        _ task: Task<Void, Never>,
        timeoutNs: UInt64
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func awaitOperationOrTimeout(
        timeoutNs: UInt64,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

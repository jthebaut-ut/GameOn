import Foundation
import Supabase

/// Serializes remove/create work per stable Supabase realtime topic so a late
/// `removeChannel` cannot race a newer subscribe on the same topic.
actor ChatRealtimeChannelSerializer {
    static let shared = ChatRealtimeChannelSerializer()

    private var topicTails: [String: Task<Void, Never>] = [:]

    /// Waits for any in-flight remove/create work on `topic` to finish.
    func waitForTopicIdle(_ topic: String) async {
#if DEBUG
        print("[ChatRealtimeAudit] event=serializerEnter op=wait topic=\(topic.prefix(40))")
#endif
        guard let prior = topicTails[topic] else {
#if DEBUG
            print("[ChatRealtimeAudit] event=serializerExit op=wait topic=\(topic.prefix(40)) idle=true")
#endif
            return
        }
        await prior.value
        if topicTails[topic] == prior {
            topicTails[topic] = nil
        }
#if DEBUG
        print("[ChatRealtimeAudit] event=serializerExit op=wait topic=\(topic.prefix(40)) idle=afterPrior")
#endif
    }

    /// Enqueues an exclusive remove for `topic` (awaits prior work first).
    func removeExclusive(
        topic: String,
        channel: RealtimeChannelV2,
        remove: @escaping @Sendable (RealtimeChannelV2) async -> Void
    ) async {
#if DEBUG
        print("[ChatRealtimeAudit] event=serializerEnter op=remove topic=\(topic.prefix(40))")
#endif
        let prior = topicTails[topic]
        let task = Task {
            await prior?.value
            await remove(channel)
        }
        topicTails[topic] = task
        await task.value
        if topicTails[topic] == task {
            topicTails[topic] = nil
        }
#if DEBUG
        print("[ChatRealtimeAudit] event=serializerExit op=remove topic=\(topic.prefix(40))")
#endif
    }
}

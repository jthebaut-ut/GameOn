import Combine
import Foundation
import Supabase

@MainActor
final class FanUpdatesRealtimeStore: ObservableObject {
    @Published var venueEventComments: [UUID: [VenueEventCommentRow]] = [:]
    @Published var commentIDsReportedByCurrentUser: Set<UUID> = []
    @Published var venueEventVibeCounts: [UUID: [String: Int]] = [:]
    @Published var myVenueEventVibes: [UUID: Set<String>] = [:]
    @Published var venueEventCommentPreviewCounts: [UUID: Int] = [:]
    /// Unique visible commenters per venue event (normalized email). Used by Discover map energy.
    @Published var venueEventUniqueCommenterCounts: [UUID: Int] = [:]
    @Published var venueEventCommentPreviews: [UUID: [VenueEventCommentRow]] = [:]
    @Published var venueEventCommentLikeCountsByID: [UUID: Int] = [:]
    @Published var venueEventCommentDownReactionCountsByID: [UUID: Int] = [:]
    @Published var venueEventCommentIDsLikedByCurrentUser: Set<UUID> = []
    @Published var venueEventCommentViewerReactionsByID: [UUID: FanChatCommentReactionType] = [:]

    var venueEventCommentsRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    var venueEventCommentsRealtimeChannels: [UUID: RealtimeChannelV2] = [:]
    var venueEventCommentsRealtimeListenerTokens: [UUID: UUID] = [:]
    var venueEventCommentsRealtimeReadyIDs: Set<UUID> = []
    var venueEventCommentsRealtimeSubscribeStartedAt: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentsRealtimeLastEventAt: [UUID: Date] = [:]
    var venueEventCommentRealtimeReceivedServerIDs: Set<UUID> = []
    var venueEventCommentRealtimeFallbackTasks: [UUID: Task<Void, Never>] = [:]
    var fanChatReceiverRefreshBurstTasks: [UUID: Task<Void, Never>] = [:]
    var fanChatAutoRefreshInFlightIDs: Set<UUID> = []
    var venueEventCommentReactionRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    var venueEventCommentReactionRealtimeChannels: [UUID: RealtimeChannelV2] = [:]
    var venueEventCommentReactionRealtimeReadyIDs: Set<UUID> = []
    var venueEventCommentReactionRealtimeTrackedCommentIDs: [UUID: [UUID]] = [:]
    var venueEventCommentReactionDebounceTasks: [UUID: Task<Void, Never>] = [:]
    var venueEventCommentReactionFallbackPollTasks: [UUID: Task<Void, Never>] = [:]
    var fanChatAppLevelRealtimeTask: Task<Void, Never>?
    var fanChatAppLevelRealtimeChannel: RealtimeChannelV2?
    var fanChatAppLevelRealtimeTrackedEventIDs: [UUID] = []
    var fanChatAppLevelLastScheduleRequestedEventIDs: [UUID] = []
    var fanChatAppLevelRealtimeResubscribeTask: Task<Void, Never>?
    var fanChatAppLevelSeenCommentIDs: Set<UUID> = []
    var crowdReactionVibeRealtimeRefreshTask: Task<Void, Never>?
    var fanChatCommentCountReconcileTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesCommentPrefetchTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesVibePrefetchTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesCommentPrefetchedAt: [UUID: Date] = [:]
    var fanUpdatesVibePrefetchedAt: [UUID: Date] = [:]
    var venueEventCommentReactionLastRefreshAt: [UUID: Date] = [:]
    var venueEventVibeWriteInFlightKeys: Set<String> = []
    var venueEventCommentLikeWriteInFlightIDs: Set<UUID> = []

    var venueEventCommentInsertSuccessTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentDebugSendTapDatesByLocalID: [UUID: Date] = [:]
    var venueEventCommentDebugSendTapTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentDebugReceivedDatesByServerID: [UUID: Date] = [:]
    var venueEventCommentDebugFallbackCommentIDs: Set<UUID> = []
    var venueEventCommentLatencySendTimesByLocalID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentLatencySendTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentLatencyLastSendTimeByEventID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentLatencyInsertStartTimesByLocalID: [UUID: CFAbsoluteTime] = [:]

    init() {
        DebugLogGate.debug("[FanUpdatesRealtimeStoreDebug] initialized")
    }

    /// Drops session-scoped Fan Updates maps and cancels in-flight store Tasks (logout / account switch).
    /// Does not touch Discover public map inventory.
    func clearSessionScopedStateForLogout() {
        for task in venueEventCommentsRealtimeTasks.values { task.cancel() }
        venueEventCommentsRealtimeTasks.removeAll(keepingCapacity: false)
        venueEventCommentsRealtimeChannels.removeAll(keepingCapacity: false)
        venueEventCommentsRealtimeListenerTokens.removeAll(keepingCapacity: false)
        venueEventCommentsRealtimeReadyIDs.removeAll(keepingCapacity: false)
        venueEventCommentsRealtimeSubscribeStartedAt.removeAll(keepingCapacity: false)
        venueEventCommentsRealtimeLastEventAt.removeAll(keepingCapacity: false)
        venueEventCommentRealtimeReceivedServerIDs.removeAll(keepingCapacity: false)
        for task in venueEventCommentRealtimeFallbackTasks.values { task.cancel() }
        venueEventCommentRealtimeFallbackTasks.removeAll(keepingCapacity: false)
        for task in fanChatReceiverRefreshBurstTasks.values { task.cancel() }
        fanChatReceiverRefreshBurstTasks.removeAll(keepingCapacity: false)
        fanChatAutoRefreshInFlightIDs.removeAll(keepingCapacity: false)
        for task in venueEventCommentReactionRealtimeTasks.values { task.cancel() }
        venueEventCommentReactionRealtimeTasks.removeAll(keepingCapacity: false)
        venueEventCommentReactionRealtimeChannels.removeAll(keepingCapacity: false)
        venueEventCommentReactionRealtimeReadyIDs.removeAll(keepingCapacity: false)
        venueEventCommentReactionRealtimeTrackedCommentIDs.removeAll(keepingCapacity: false)
        for task in venueEventCommentReactionDebounceTasks.values { task.cancel() }
        venueEventCommentReactionDebounceTasks.removeAll(keepingCapacity: false)
        for task in venueEventCommentReactionFallbackPollTasks.values { task.cancel() }
        venueEventCommentReactionFallbackPollTasks.removeAll(keepingCapacity: false)
        fanChatAppLevelRealtimeTask?.cancel()
        fanChatAppLevelRealtimeTask = nil
        fanChatAppLevelRealtimeChannel = nil
        fanChatAppLevelRealtimeTrackedEventIDs.removeAll(keepingCapacity: false)
        fanChatAppLevelLastScheduleRequestedEventIDs.removeAll(keepingCapacity: false)
        fanChatAppLevelRealtimeResubscribeTask?.cancel()
        fanChatAppLevelRealtimeResubscribeTask = nil
        fanChatAppLevelSeenCommentIDs.removeAll(keepingCapacity: false)
        crowdReactionVibeRealtimeRefreshTask?.cancel()
        crowdReactionVibeRealtimeRefreshTask = nil
        for task in fanChatCommentCountReconcileTasks.values { task.cancel() }
        fanChatCommentCountReconcileTasks.removeAll(keepingCapacity: false)
        for task in fanUpdatesCommentPrefetchTasks.values { task.cancel() }
        fanUpdatesCommentPrefetchTasks.removeAll(keepingCapacity: false)
        for task in fanUpdatesVibePrefetchTasks.values { task.cancel() }
        fanUpdatesVibePrefetchTasks.removeAll(keepingCapacity: false)
        fanUpdatesCommentPrefetchedAt.removeAll(keepingCapacity: false)
        fanUpdatesVibePrefetchedAt.removeAll(keepingCapacity: false)
        venueEventCommentReactionLastRefreshAt.removeAll(keepingCapacity: false)
        venueEventVibeWriteInFlightKeys.removeAll(keepingCapacity: false)
        venueEventCommentLikeWriteInFlightIDs.removeAll(keepingCapacity: false)

        venueEventComments.removeAll(keepingCapacity: false)
        commentIDsReportedByCurrentUser.removeAll(keepingCapacity: false)
        venueEventVibeCounts.removeAll(keepingCapacity: false)
        myVenueEventVibes.removeAll(keepingCapacity: false)
        venueEventCommentPreviewCounts.removeAll(keepingCapacity: false)
        venueEventUniqueCommenterCounts.removeAll(keepingCapacity: false)
        venueEventCommentPreviews.removeAll(keepingCapacity: false)
        venueEventCommentLikeCountsByID.removeAll(keepingCapacity: false)
        venueEventCommentDownReactionCountsByID.removeAll(keepingCapacity: false)
        venueEventCommentIDsLikedByCurrentUser.removeAll(keepingCapacity: false)
        venueEventCommentViewerReactionsByID.removeAll(keepingCapacity: false)

        venueEventCommentInsertSuccessTimesByServerID.removeAll(keepingCapacity: false)
        venueEventCommentDebugSendTapDatesByLocalID.removeAll(keepingCapacity: false)
        venueEventCommentDebugSendTapTimesByServerID.removeAll(keepingCapacity: false)
        venueEventCommentDebugReceivedDatesByServerID.removeAll(keepingCapacity: false)
        venueEventCommentDebugFallbackCommentIDs.removeAll(keepingCapacity: false)
        venueEventCommentLatencySendTimesByLocalID.removeAll(keepingCapacity: false)
        venueEventCommentLatencySendTimesByServerID.removeAll(keepingCapacity: false)
        venueEventCommentLatencyLastSendTimeByEventID.removeAll(keepingCapacity: false)
        venueEventCommentLatencyInsertStartTimesByLocalID.removeAll(keepingCapacity: false)
    }
}

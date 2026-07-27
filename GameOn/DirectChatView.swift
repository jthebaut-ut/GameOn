import Combine
import Supabase
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Timeline (day grouping + formatting)

private enum DirectChatTimelineEntry: Identifiable, Hashable {
    case daySeparator(dayStart: TimeInterval, label: String)
    case message(DirectMessageRow)

    var id: String {
        switch self {
        case .daySeparator(let dayStart, _):
            return "day-\(dayStart)"
        case .message(let m):
            return m.id.uuidString
        }
    }
}

private enum DirectChatTimeGrouping {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = isoWithFractional.date(from: raw) { return d }
        return isoPlain.date(from: raw)
    }

    static func dayLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return df.string(from: date)
    }

    /// e.g. 11:05 PM in US locale
    static func shortTime(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: date)
    }

    static func shortTimeString(forCreatedAt raw: String?) -> String? {
        guard let date = parseDate(raw) else { return nil }
        return shortTime(from: date)
    }

    static func buildTimeline(from rows: [DirectMessageRow]) -> [DirectChatTimelineEntry] {
        let cal = Calendar.current
        var out: [DirectChatTimelineEntry] = []
        var lastDayStart: TimeInterval?

        for row in rows {
            guard let date = parseDate(row.created_at) else {
                out.append(.message(row))
                continue
            }
            let start = cal.startOfDay(for: date)
            let key = start.timeIntervalSince1970
            if lastDayStart == nil || key != lastDayStart {
                out.append(.daySeparator(dayStart: key, label: dayLabel(for: start)))
                lastDayStart = key
            }
            out.append(.message(row))
        }
        return out
    }
}

// MARK: - Toolbar overflow anchor (global frame for iMessage-style menu placement)

private struct ChatOverflowAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

@MainActor
private final class DirectChatPresenter: ObservableObject {

#if DEBUG
    private enum DMRealtimePerfLog {
        static let formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        static func stamp(_ d: Date = Date()) -> String {
            formatter.string(from: d)
        }

        static func elapsedMs(since start: CFAbsoluteTime?) -> String {
            guard let start else { return "nil" }
            return String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
    }
#endif

    let friend: UserPreview
    private let service = DirectChatService()

    @Published private(set) var messages: [DirectMessageRow] = []
    /// Kept in lockstep with ``messages`` so the chat list body never calls ``DirectChatTimeGrouping/buildTimeline(from:)``.
    private var displayTimeline: [DirectChatTimelineEntry] = []
    @Published private(set) var conversationId: UUID?
    @Published private(set) var isLoadingInitial = true
    /// More history may exist before the oldest loaded row (keyset pagination).
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var isLoadingOlderMessages = false
    @Published private(set) var loadError: String?
    @Published var sendError: String?
    @Published var draft: String = ""
    @Published var menuBanner: String?
    @Published private(set) var isManuallyRefreshingMessages = false
    @Published private(set) var peerIsDeleted: Bool
    @Published private(set) var headerConnectionStatusText: String = "Syncing messages"
    @Published private(set) var realtimeConnectionStatus: ChatRealtimeConnectionStatus = .reconnecting

    private(set) var currentUserId: UUID?

    private let maxBodyLength = 1000

    /// One Realtime channel per open thread: Postgres INSERT on `direct_messages` only (typing disabled).
    private var messagesRealtimeChannel: RealtimeChannelV2?
    /// Channel allocated while subscribe is in-flight; must not be treated as an active listener until ``messagesRealtimeChannel`` is set.
    private var establishingRealtimeChannel: RealtimeChannelV2?

    private struct DMThreadRealtimeSubscribeTimeoutError: Error {}

    private static func realtimeErrorIndicatesGlobalRetryExhausted(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("maximum retry attempts")
            || message.contains("max retry")
            || message.contains("retry attempts reached")
    }

    private struct PendingOptimisticSend {
        let body: String
        let senderId: UUID
        let correlationId: UUID
    }

    /// Client-generated message ids until the server row arrives (dedupe with realtime).
    private var pendingOptimisticMessages: [UUID: PendingOptimisticSend] = [:]
    private var dmLatencySendTimesByLocalID: [UUID: CFAbsoluteTime] = [:]
    private var dmLatencySendTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    private var dmLatencyInsertStartTimesByLocalID: [UUID: CFAbsoluteTime] = [:]
    private var dmInsertSuccessTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    private var dmRealtimeReceivedServerIDs: Set<UUID> = []
    private var dmRealtimeFallbackTasks: [UUID: Task<Void, Never>] = [:]
    private var dmDebugSendTapTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    private var dmDebugReceivedDatesByServerID: [UUID: Date] = [:]
    private var dmDebugFallbackMessageIDs: Set<UUID> = []

    /// Serializes ``sendDraft()`` while the optimistic pipeline starts (Return / Send double-fire).
    private var sendDraftInFlight = false

    private static let optimisticCreatedAtFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private enum RealtimeFallback {
        static let delayNs: UInt64 = 1_500_000_000
    }

    /// Last INSERT delivered on the Realtime stream for this thread (poll fallback uses this).
    private var lastRealtimeStreamInsertAt: Date = .distantPast
    private var activeRealtimeThreadConversationId: UUID?
    /// True while ``runRealtimeSubscription()`` from the view `.task` is running (prevents duplicate foreground loops).
    private var threadRealtimeSubscriptionLoopActive = false
    private var forceThreadRealtimeReconnectRequested = false
    private var realtimeWatchdogTask: Task<Void, Never>?
    private var threadRealtimeChannelName: String?
    private var threadRealtimeChannelStatus: String = "none"
    private var lastThreadRealtimeSubscribeAt: Date?
    private var lastThreadRealtimeInsertReceivedAt: Date?
    private var isThreadRealtimeSubscribing = false
    private var isThreadRealtimeSubscribed = false
    private var threadRealtimeWatchdogCheckInProgress = false
    private var threadRealtimeSubscriptionTask: Task<Void, Never>?
    private var threadRealtimeSubscriptionTaskId: UUID?
    private var threadRealtimeSubscriptionStartReason: String?
    private var threadRealtimeActiveChannelObjectIds: Set<String> = []
    private var threadFallbackPollingTask: Task<Void, Never>?
    private var threadFallbackPollingTaskId: UUID?
    private var isThreadFallbackPollingActive = false
    private var lastThreadFallbackPollSucceeded: Bool?
    private static let realtimeWatchdogIntervalNs: UInt64 = 5_000_000_000
    private static let fallbackPollingStartDelayNs: UInt64 = 4_000_000_000
    private static let fallbackPollingIntervalNs: UInt64 = 2_500_000_000
    private let directMessageReconnectDelaysNs: [UInt64] = [
        0,
        1_000_000_000,
        3_000_000_000,
        5_000_000_000
    ]

    /// Set from the view layer so sends can respect bidirectional blocks + refresh social state.
    weak var chatViewModel: ChatViewModel?

    init(friend: UserPreview) {
        self.friend = friend
        self.peerIsDeleted = friend.isBusinessVenueConversation ? false : friend.isDeleted
    }

    private func dmDebugMilliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime? = nil) -> String {
        guard let start else { return "nil" }
        let finish = end ?? CFAbsoluteTimeGetCurrent()
        return String(format: "%.1f", (finish - start) * 1000)
    }

    private func logDMEndToEnd(
        row: DirectMessageRow,
        conversationId: UUID,
        fallbackUsed: Bool,
        receivedAt: Date = Date()
    ) {
#if DEBUG
        let insertSuccess = dmInsertSuccessTimesByServerID[row.id]
        let sendTapStart = dmDebugSendTapTimesByServerID[row.id]
        let serverCreatedAt = DirectChatTimeGrouping.parseDate(row.created_at)
        let insertToRealtimeMs = dmDebugMilliseconds(from: insertSuccess)
        let insertToVisibleMs = serverCreatedAt.map {
            String(format: "%.1f", receivedAt.timeIntervalSince($0) * 1000)
        } ?? "nil"
        let channelName = "direct-messages-\(conversationId.uuidString.lowercased())"
        DebugLogGate.debug("[DMEndToEndDebug] conversationId=\(conversationId.uuidString.lowercased()) senderUserId=\(row.sender_id.uuidString.lowercased()) messageId=\(row.id.uuidString.lowercased()) sendTapToInsertMs=\(dmDebugMilliseconds(from: sendTapStart, to: insertSuccess)) insertToRealtimeMs=\(insertToRealtimeMs) insertToOtherDeviceVisibleMs=\(insertToVisibleMs) fallbackUsed=\(fallbackUsed) subscriptionReady=\(messagesRealtimeChannel != nil && activeRealtimeThreadConversationId == conversationId) channelName=\(channelName)")
#endif
    }

    /// Read-only timeline for ``messages``; updated only alongside ``messages`` mutations.
    var timelineForDisplay: [DirectChatTimelineEntry] { displayTimeline }

    private func rebuildDisplayTimelineFromMessages() {
        displayTimeline = DirectChatTimeGrouping.buildTimeline(from: messages)
    }

    private func appendDisplayTimelineTail(for row: DirectMessageRow) {
        guard let date = DirectChatTimeGrouping.parseDate(row.created_at) else {
            displayTimeline.append(.message(row))
            return
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let key = start.timeIntervalSince1970
        var lastMessageDayKey: TimeInterval?
        for entry in displayTimeline.reversed() {
            if case .message(let m) = entry {
                if let md = DirectChatTimeGrouping.parseDate(m.created_at) {
                    lastMessageDayKey = cal.startOfDay(for: md).timeIntervalSince1970
                }
                break
            }
        }
        if lastMessageDayKey == nil {
            displayTimeline.append(.daySeparator(dayStart: key, label: DirectChatTimeGrouping.dayLabel(for: start)))
        } else if lastMessageDayKey != key {
            displayTimeline.append(.daySeparator(dayStart: key, label: DirectChatTimeGrouping.dayLabel(for: start)))
        }
        displayTimeline.append(.message(row))
    }

    private func removeDisplayTimelineMessage(id: UUID) {
        guard let idx = displayTimeline.firstIndex(where: { entry in
            if case .message(let m) = entry { return m.id == id }
            return false
        }) else { return }
        displayTimeline.remove(at: idx)
    }

    func bindChatViewModel(_ vm: ChatViewModel) {
        chatViewModel = vm
#if DEBUG
        print("[ChatViewModelInstanceDebug] DirectChatPresenter bound ChatViewModel id=\(ObjectIdentifier(vm))")
        print("[MainActorDebug] DirectChatPresenter.bindChatViewModel actor=MainActor")
#endif
    }

    func logRealtimeReadiness(reason: String, chatAppear: Bool = false) {
        let authReady = currentUserId != nil
        let conversationReady = conversationId != nil
        DMRealtimeDiagnostics.debug("chatAppear=\(chatAppear) reason=\(reason)")
        DMRealtimeDiagnostics.debug("authReady=\(authReady) authUserId=\(currentUserId?.uuidString.lowercased() ?? "nil")")
        DMRealtimeDiagnostics.debug("conversationReady=\(conversationReady) conversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
        DMRealtimeDiagnostics.debug("channelStatus=\(threadRealtimeChannelStatusDescription()) reason=\(reason)")
    }

    func updatePeerDeletedState(_ isDeleted: Bool) {
        peerIsDeleted = isDeleted
    }

    private func isMessagingBlocked() -> Bool {
        guard let chatViewModel else { return false }
        return chatViewModel.isEitherDirectionBlocked(with: friend.id)
    }

    /// Friendship-backed threads require an accepted chip; venue threads do not.
    private func friendshipAllowsSending() -> Bool {
        if friend.isBusinessVenueConversation { return true }
        guard let chatViewModel else { return true }
        return chatViewModel.chipKind(forOtherUserId: friend.id) == .friends
    }

    private func validateDMText(_ trimmed: String) -> String? {
        if ModerationService.containsProfanity(trimmed) {
            return ModerationService.profanityRejectionUserMessage()
        }
        return nil
    }

    func onAppear() async {
        sendError = nil
        loadError = nil
        do {
            let me = try await service.currentUserId()
            currentUserId = me

            if conversationId == nil {
                if friend.isBusinessVenueConversation {
                    if let presetConversationId = friend.dmConversationId {
                        conversationId = presetConversationId
                    } else if let businessId = friend.businessVenueBusinessId,
                              let venueId = friend.businessVenueId {
                        conversationId = try await service.startBusinessVenueConversation(
                            businessId: businessId,
                            venueId: venueId
                        )
                    } else {
                        throw NSError(
                            domain: "DirectChatPresenter",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Couldn't open venue chat."]
                        )
                    }
                } else if let presetConversationId = friend.dmConversationId {
                    conversationId = presetConversationId
                } else if let existingId = try await service.fetchExistingConversationId(peerUserId: friend.id) {
                    conversationId = existingId
                } else {
                    conversationId = try await service.startDirectConversation(friendUserId: friend.id)
                }
            }

            guard let conversationId else { return }

            let rows = try await service.fetchLatestMessages(conversationId: conversationId, limit: 50)
            messages = rows
            rebuildDisplayTimelineFromMessages()
            hasOlderMessages = rows.count >= 50
        } catch {
            loadError = error.localizedDescription
            messages = []
            displayTimeline = []
            hasOlderMessages = false
        }
        isLoadingInitial = false
    }

    func clearForSessionLoss() {
        messages = []
        displayTimeline = []
        conversationId = nil
        isLoadingInitial = false
        hasOlderMessages = false
        isLoadingOlderMessages = false
        loadError = "Sign in to view this conversation."
        sendError = nil
        currentUserId = nil
        draft = ""
        menuBanner = nil
        pendingOptimisticMessages.removeAll()
        dmRealtimeFallbackTasks.values.forEach { $0.cancel() }
        dmRealtimeFallbackTasks.removeAll()
        dmDebugSendTapTimesByServerID.removeAll()
        dmDebugReceivedDatesByServerID.removeAll()
        dmDebugFallbackMessageIDs.removeAll()
        lastRealtimeStreamInsertAt = .distantPast
        lastThreadRealtimeSubscribeAt = nil
        lastThreadRealtimeInsertReceivedAt = nil
        activeRealtimeThreadConversationId = nil
        threadRealtimeChannelName = nil
        threadRealtimeChannelStatus = "none"
        isThreadRealtimeSubscribing = false
        isThreadRealtimeSubscribed = false
        realtimeWatchdogTask?.cancel()
        realtimeWatchdogTask = nil
        threadRealtimeSubscriptionTask?.cancel()
        threadRealtimeSubscriptionTask = nil
        threadRealtimeSubscriptionTaskId = nil
        threadRealtimeSubscriptionStartReason = nil
        threadRealtimeActiveChannelObjectIds.removeAll()
        stopThreadFallbackPolling(reason: "sessionLoss")
        lastThreadFallbackPollSucceeded = nil
        refreshHeaderConnectionStatus()
        realtimeConnectionStatus = .offline
        Task { await self.tearDownRealtimeChannelIfNeeded() }
    }

    /// Removes this thread’s Postgres INSERT listener only (does not touch inbox / friendship listeners).
    private func tearDownRealtimeChannelIfNeeded() async {
        activeRealtimeThreadConversationId = nil
        threadRealtimeChannelStatus = "none"
        threadRealtimeChannelName = nil
        isThreadRealtimeSubscribing = false
        isThreadRealtimeSubscribed = false
        realtimeConnectionStatus = .reconnecting
        if let pending = establishingRealtimeChannel {
            establishingRealtimeChannel = nil
            let tid = conversationId?.uuidString.lowercased() ?? "?"
            unregisterThreadRealtimeChannelRemoved(
                pending,
                reason: "removeEstablishing",
                status: String(describing: pending.status)
            )
#if DEBUG
            print("[DirectChatRealtime] remove establishing channel thread=\(tid)")
#endif
            await service.removeRealtimeChannel(pending)
        }
        guard let ch = messagesRealtimeChannel else { return }
        let tid = conversationId?.uuidString.lowercased() ?? "?"
        unregisterThreadRealtimeChannelRemoved(
            ch,
            reason: "tearDownRealtimeChannelIfNeeded",
            status: String(describing: ch.status)
        )
#if DEBUG
        print("[DirectChatRealtime] unsubscribe thread=\(tid)")
#endif
        messagesRealtimeChannel = nil
        await service.removeRealtimeChannel(ch)
    }

    private func threadRealtimeChannelObjectId(_ channel: RealtimeChannelV2) -> String {
        String(describing: ObjectIdentifier(channel))
    }

    private func registerThreadRealtimeChannelCreated(_ channel: RealtimeChannelV2, conversationId cid: UUID) {
        let objectId = threadRealtimeChannelObjectId(channel)
        threadRealtimeActiveChannelObjectIds.insert(objectId)
        DMRealtimeDiagnostics.debug("channelCreated=true channelObjectId=\(objectId) channelName=\(channel.topic)")
        DMRealtimeDiagnostics.debug("channelObjectId=\(objectId)")
        DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(cid.uuidString.lowercased())")
        DMRealtimeDiagnostics.debug("channelCount=\(threadRealtimeActiveChannelObjectIds.count) context=created")
    }

    private func unregisterThreadRealtimeChannelRemoved(
        _ channel: RealtimeChannelV2,
        reason: String,
        status: String
    ) {
        let objectId = threadRealtimeChannelObjectId(channel)
        threadRealtimeActiveChannelObjectIds.remove(objectId)
        DMRealtimeDiagnostics.debug("channelRemoved=true channelObjectId=\(objectId) channelName=\(channel.topic) reason=\(reason) status=\(status)")
        DMRealtimeDiagnostics.debug("channelObjectId=\(objectId)")
        DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
        DMRealtimeDiagnostics.debug("channelCount=\(threadRealtimeActiveChannelObjectIds.count) context=removed")
    }

    private func clearThreadRealtimeChannelAfterSubscribeFailure(
        _ channel: RealtimeChannelV2,
        status: String,
        reason: String
    ) async {
        unregisterThreadRealtimeChannelRemoved(channel, reason: reason, status: status)
        messagesRealtimeChannel = nil
        establishingRealtimeChannel = nil
        isThreadRealtimeSubscribing = false
        isThreadRealtimeSubscribed = false
        threadRealtimeChannelName = nil
        threadRealtimeChannelStatus = status
        refreshHeaderConnectionStatus()
        if let cid = conversationId {
            activeRealtimeThreadConversationId = cid
        }
        threadRealtimeActiveChannelObjectIds.removeAll()
        DMRealtimeDiagnostics.debug("staleChannelReferenceCleared=true reason=\(reason)")
        DMRealtimeDiagnostics.debug("channelCount=\(threadRealtimeActiveChannelObjectIds.count) context=\(reason)")
        DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
        await service.removeRealtimeChannel(channel)
    }

    private func logThreadRealtimeHeartbeat(reason: String, status: String) {
        let formattedLastInsert = lastThreadRealtimeInsertReceivedAt.map {
            Self.optimisticCreatedAtFormatter.string(from: $0)
        } ?? "nil"
        DMRealtimeDiagnostics.debug(
            "realtimeHeartbeat=true reason=\(reason) channelStatus=\(status) channelCount=\(threadRealtimeActiveChannelObjectIds.count) activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(conversationId?.uuidString.lowercased() ?? "nil") lastInsertReceivedAt=\(formattedLastInsert)"
        )
        DMRealtimeDiagnostics.debug("lastInsertReceivedAt=\(formattedLastInsert)")
    }

    private func threadRealtimeChannelStatusDescription() -> String {
        if let channel = messagesRealtimeChannel {
            let status = String(describing: channel.status)
            threadRealtimeChannelStatus = status
            threadRealtimeChannelName = channel.topic
            return status
        }
        if let channel = establishingRealtimeChannel {
            let status = "establishing:\(String(describing: channel.status))"
            threadRealtimeChannelStatus = status
            threadRealtimeChannelName = channel.topic
            return status
        }
        if threadRealtimeSubscriptionLoopActive {
            threadRealtimeChannelStatus = "loopActiveNoChannel"
            return "loopActiveNoChannel"
        }
        threadRealtimeChannelStatus = "none"
        threadRealtimeChannelName = nil
        return "none"
    }

    private func threadRealtimeChannelStatusIsUnhealthy(_ status: String) -> Bool {
        let lowered = status.lowercased()
        guard lowered != "none", lowered != "loopactivenochannel" else { return true }
        return lowered.contains("closed")
            || lowered.contains("error")
            || lowered.contains("timedout")
            || lowered.contains("timed_out")
            || lowered.contains("timeout")
            || lowered.contains("unsubscribed")
    }

    private func refreshHeaderConnectionStatus() {
        let next: String
        if isThreadRealtimeSubscribed {
            next = "Live"
        } else if lastThreadFallbackPollSucceeded == false {
            next = "Connection issue"
        } else {
            next = "Syncing messages"
        }
        if headerConnectionStatusText != next {
            headerConnectionStatusText = next
        }
    }

    private func startRealtimeWatchdogIfNeeded() {
        guard realtimeWatchdogTask == nil else { return }
        realtimeWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.realtimeWatchdogIntervalNs)
                } catch {
                    return
                }
                await self?.runRealtimeWatchdogCheck(reason: "timer")
            }
        }
    }

    private func startRealtimeSubscriptionLoopIfNeeded(reason: String) {
        guard threadRealtimeSubscriptionTask == nil else {
            DMRealtimeDiagnostics.debug("channelCount=\(threadRealtimeActiveChannelObjectIds.count) context=subscriptionTaskAlreadyExists reason=\(reason)")
            DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
            return
        }
        threadRealtimeSubscriptionStartReason = reason
        DMRealtimeDiagnostics.debug("resubscribeStarted=true reason=\(reason)")
        let taskId = UUID()
        threadRealtimeSubscriptionTaskId = taskId
        threadRealtimeSubscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRealtimeSubscription(subscriptionReason: reason)
            if self.threadRealtimeSubscriptionTaskId == taskId {
                self.threadRealtimeSubscriptionTask = nil
                self.threadRealtimeSubscriptionTaskId = nil
                self.threadRealtimeSubscriptionStartReason = nil
            }
        }
    }

    private func shouldRunThreadFallbackPolling() -> Bool {
        loadError == nil
            && conversationId != nil
            && currentUserId != nil
            && !isThreadRealtimeSubscribed
    }

    private func startThreadFallbackPollingIfNeeded(reason: String) {
        guard threadFallbackPollingTask == nil else { return }
        let taskId = UUID()
        threadFallbackPollingTaskId = taskId
        DMRealtimeDiagnostics.debug("fallbackPollingScheduled=true reason=\(reason)")
        threadFallbackPollingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.fallbackPollingStartDelayNs)
            } catch {
                return
            }

            while !Task.isCancelled {
                guard let self else { return }
                guard self.threadFallbackPollingTaskId == taskId else { return }
                guard self.shouldRunThreadFallbackPolling() else { break }

                if !self.isThreadFallbackPollingActive {
                    self.isThreadFallbackPollingActive = true
                    self.lastThreadFallbackPollSucceeded = nil
                    self.refreshHeaderConnectionStatus()
                    DMRealtimeDiagnostics.debug("fallbackPollingActive=true reason=\(reason)")
                    self.realtimeConnectionStatus = .connecting
                }

                let result = await self.refreshMessagesForCurrentThreadResult(reason: "thread_fallback_poll")
                self.lastThreadFallbackPollSucceeded = result.didFetch
                self.refreshHeaderConnectionStatus()
                DMRealtimeDiagnostics.debug("fallbackPollingMergedCount=\(result.mergedCount)")
                if result.didFetch {
                    self.realtimeConnectionStatus = .connecting
                }

                guard !self.isThreadRealtimeSubscribed else { break }
                do {
                    try await Task.sleep(nanoseconds: Self.fallbackPollingIntervalNs)
                } catch {
                    break
                }
            }

            guard let self, self.threadFallbackPollingTaskId == taskId else { return }
            self.threadFallbackPollingTask = nil
            self.threadFallbackPollingTaskId = nil
            self.isThreadFallbackPollingActive = false
            self.lastThreadFallbackPollSucceeded = nil
            self.refreshHeaderConnectionStatus()
            DMRealtimeDiagnostics.debug("fallbackPollingActive=false reason=\(self.isThreadRealtimeSubscribed ? "realtimeSubscribed" : "notNeeded")")
        }
    }

    private func stopThreadFallbackPolling(reason: String) {
        let wasActive = threadFallbackPollingTask != nil || isThreadFallbackPollingActive
        threadFallbackPollingTask?.cancel()
        threadFallbackPollingTask = nil
        threadFallbackPollingTaskId = nil
        isThreadFallbackPollingActive = false
        lastThreadFallbackPollSucceeded = nil
        refreshHeaderConnectionStatus()
        if wasActive {
            DMRealtimeDiagnostics.debug("fallbackPollingActive=false reason=\(reason)")
        }
    }

    private func realtimeWatchdogDecision(reason: String) -> (needsReconnect: Bool, reconnectReason: String) {
        guard loadError == nil else { return (false, "loadError") }
        guard currentUserId != nil else { return (false, "authNotReady") }
        guard let cid = conversationId else { return (false, "conversationNotReady") }
        if activeRealtimeThreadConversationId != nil,
           activeRealtimeThreadConversationId != cid {
            return (true, "activeConversationChanged")
        }
        if messagesRealtimeChannel == nil, establishingRealtimeChannel == nil {
            return (true, "noActiveChannel")
        }
        let status = threadRealtimeChannelStatusDescription()
        if threadRealtimeChannelStatusIsUnhealthy(status) {
            return (true, "channelStatus.\(status)")
        }
        if threadRealtimeSubscriptionTask == nil, !threadRealtimeSubscriptionLoopActive {
            return (true, "subscriptionLoopMissing")
        }
        return (false, "healthy")
    }

    @discardableResult
    func runRealtimeWatchdogCheck(reason: String) async -> Bool {
        guard !threadRealtimeWatchdogCheckInProgress else {
            DMRealtimeDiagnostics.debug("watchdogCheck=skipped reason=\(reason) skippedReason=inProgress")
            return false
        }
        threadRealtimeWatchdogCheckInProgress = true
        defer { threadRealtimeWatchdogCheckInProgress = false }

        let status = threadRealtimeChannelStatusDescription()
        let decision = realtimeWatchdogDecision(reason: reason)
        logThreadRealtimeHeartbeat(reason: reason, status: status)
        DMRealtimeDiagnostics.debug(
            "watchdogCheck=true reason=\(reason) activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(conversationId?.uuidString.lowercased() ?? "nil") channelName=\(threadRealtimeChannelName ?? "nil") lastSubscribeAt=\(lastThreadRealtimeSubscribeAt.map { Self.optimisticCreatedAtFormatter.string(from: $0) } ?? "nil") lastInsertReceivedAt=\(lastThreadRealtimeInsertReceivedAt.map { Self.optimisticCreatedAtFormatter.string(from: $0) } ?? "nil") isSubscribing=\(isThreadRealtimeSubscribing) isSubscribed=\(isThreadRealtimeSubscribed)"
        )
        DMRealtimeDiagnostics.debug("channelStatus=\(status)")
        DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
        DMRealtimeDiagnostics.debug("channelCount=\(threadRealtimeActiveChannelObjectIds.count) context=watchdog")
        DMRealtimeDiagnostics.debug("needsReconnect=\(decision.needsReconnect)")
        if decision.needsReconnect {
            await reconnectRealtimeFromWatchdog(reason: decision.reconnectReason)
        }
        return decision.needsReconnect
    }

    private func reconnectRealtimeFromWatchdog(reason: String) async {
        DMRealtimeDiagnostics.debug("reconnectReason=\(reason)")
        forceThreadRealtimeReconnectRequested = true
        await tearDownRealtimeChannelIfNeeded()
        startThreadFallbackPollingIfNeeded(reason: reason)
        startRealtimeSubscriptionLoopIfNeeded(reason: reason)
    }

    private func backfillAfterRealtimeResubscribe(conversationId cid: UUID, reason: String) async {
        DMRealtimeDiagnostics.debug("backfillStarted=true conversationId=\(cid.uuidString.lowercased()) reason=\(reason)")
        let result = await refreshMessagesForCurrentThreadResult(reason: reason)
        DMRealtimeDiagnostics.debug("backfillMergedCount=\(result.mergedCount) conversationId=\(cid.uuidString.lowercased()) reason=\(reason)")
        if result.didFetch {
            realtimeConnectionStatus = .connected
        }
    }

    func forceRebuildRealtimeAfterForeground() async {
        guard loadError == nil, let cid = conversationId, currentUserId != nil else { return }
        startRealtimeWatchdogIfNeeded()
        DMRealtimeDiagnostics.debug("foregroundForceRebuild=true conversationId=\(cid.uuidString.lowercased())")
        DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(cid.uuidString.lowercased())")

        guard chatViewModel?.canMarkActiveDirectThreadRead(
            conversationId: cid,
            reason: "foreground_force_rebuild"
        ) == true else {
            DebugLogGate.debug("[DMRealtimeStability] skipped foreground force rebuild offscreen")
            return
        }

        let hadSubscriptionTask = threadRealtimeSubscriptionTask != nil || threadRealtimeSubscriptionLoopActive
        threadRealtimeSubscriptionTask?.cancel()
        threadRealtimeSubscriptionTask = nil
        threadRealtimeSubscriptionTaskId = nil
        threadRealtimeSubscriptionStartReason = nil
        threadRealtimeSubscriptionLoopActive = false
        DMRealtimeDiagnostics.debug("subscriptionTaskCleared=\(hadSubscriptionTask)")

        let hadOldChannel = messagesRealtimeChannel != nil || establishingRealtimeChannel != nil
        await tearDownRealtimeChannelIfNeeded()
        DMRealtimeDiagnostics.debug("oldChannelRemoved=\(hadOldChannel)")

        messagesRealtimeChannel = nil
        establishingRealtimeChannel = nil
        activeRealtimeThreadConversationId = nil
        threadRealtimeChannelName = nil
        threadRealtimeChannelStatus = "none"
        isThreadRealtimeSubscribing = false
        isThreadRealtimeSubscribed = false
        DMRealtimeDiagnostics.debug("staleChannelReferenceCleared=\(messagesRealtimeChannel == nil && establishingRealtimeChannel == nil)")

        startThreadFallbackPollingIfNeeded(reason: "foregroundForceRebuild")
        startRealtimeSubscriptionLoopIfNeeded(reason: "foregroundForceRebuild")
        await Task.yield()

        let result = await refreshMessagesForCurrentThreadResult(reason: "foreground_force_rebuild")
        DMRealtimeDiagnostics.debug("backfillAfterForegroundMergedCount=\(result.mergedCount)")
        if result.didFetch {
            realtimeConnectionStatus = isThreadRealtimeSubscribed ? .connected : .connecting
        }
        DMRealtimeDiagnostics.debug("reconnectBannerHidden=\(result.didFetch)")
    }

    /// Called from the view when the thread UI disappears so Realtime unsubscribes exactly once.
    func stopDirectMessageRealtime() async {
        realtimeWatchdogTask?.cancel()
        realtimeWatchdogTask = nil
        threadRealtimeSubscriptionTask?.cancel()
        threadRealtimeSubscriptionTask = nil
        threadRealtimeSubscriptionTaskId = nil
        threadRealtimeSubscriptionStartReason = nil
        stopThreadFallbackPolling(reason: "threadClosed")
        activeRealtimeThreadConversationId = nil
        await tearDownRealtimeChannelIfNeeded()
    }

    /// Prepends older pages (keyset on `created_at` + `id`); keeps realtime/new sends unchanged.
    func loadOlderMessages() async {
        guard !isLoadingOlderMessages, hasOlderMessages else { return }
        guard let oldest = messages.first,
              let oldestDate = DirectChatTimeGrouping.parseDate(oldest.created_at),
              let cid = conversationId else {
            hasOlderMessages = false
            return
        }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        do {
            let page = try await service.fetchOlderMessages(
                conversationId: cid,
                beforeCreatedAt: oldestDate,
                beforeMessageId: oldest.id,
                limit: 50
            )
            if page.isEmpty {
                hasOlderMessages = false
                return
            }
            let existing = Set(messages.map(\.id))
            let mergedPrefix = page.filter { !existing.contains($0.id) }
            if mergedPrefix.isEmpty {
                hasOlderMessages = false
                return
            }
            messages = mergedPrefix + messages
            rebuildDisplayTimelineFromMessages()
            if page.count < 50 {
                hasOlderMessages = false
            }
        } catch {
            // Non-fatal: user can retry “Load older”.
        }
    }

    /// Upserts read cursor with `Date()` so `last_read_at` is never behind DB `created_at` microsecond precision.
    @discardableResult
    func flushMarkReadNow(reason: String, requireActiveVisibleThread: Bool = true) async -> Bool {
        guard loadError == nil, let cid = conversationId, currentUserId != nil else { return false }
        return await chatViewModel?.markDirectThreadRead(
            conversationId: cid,
            peerUserId: friend.id,
            reason: reason,
            requireActiveVisibleThread: requireActiveVisibleThread
        ) ?? false
    }

    private func subscribeThreadChannelWithTimeout(_ channel: RealtimeChannelV2, timeoutNs: UInt64 = 15_000_000_000) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Avoid coupling Phoenix join ↔ MainActor; inbox listener runs from an unstructured Task as well.
                try await Task.detached(priority: .userInitiated) {
                    try await channel.subscribeWithError()
                }.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw DMThreadRealtimeSubscribeTimeoutError()
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    private func runRealtimeSubscriptionAttempt(
        conversationId cid: UUID,
        currentUserId me: UUID,
        subscriptionReason: String?
    ) async throws {
        guard loadError == nil, conversationId == cid, currentUserId == me else { return }
        activeRealtimeThreadConversationId = cid
        if messagesRealtimeChannel != nil || establishingRealtimeChannel != nil {
            DMRealtimeDiagnostics.debug(
                "channelCount=\(threadRealtimeActiveChannelObjectIds.count) context=subscriptionBlockedByExistingRef channelStatus=\(threadRealtimeChannelStatusDescription())"
            )
            DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(cid.uuidString.lowercased())")
            return
        }

        let tid = cid.uuidString.lowercased()
        let identity = chatViewModel?.dmRealtimeIdentitySnapshot(fallbackAuthUserId: me)
        realtimeConnectionStatus = .reconnecting
#if DEBUG
        print("[DirectChatRealtime] subscribe start thread=\(tid)")
        print("[DirectChatRealtime] subscribing conversationId=\(tid)")
        print("[DirectChatRealtime] pending subscribe conversationId=\(tid)")
#endif
        let healthSubscribeStartedAt = CFAbsoluteTimeGetCurrent()
#if DEBUG
        DMRealtimeDiagnostics.log("phase=thread_realtime_subscribe_attempt conversation=\(tid)")
        RealtimeHealthDiagnostics.log("channelName=dm-thread-\(tid)")
        RealtimeHealthDiagnostics.log("subscribeStart=true channelName=dm-thread-\(tid)")
#endif
        DMRealtimeDiagnostics.debug("subscribeStarted=true accountType=\(identity?.accountType ?? "user")")
        DMRealtimeDiagnostics.debug("authUserId=\(identity?.authUserIdLogValue ?? me.uuidString.lowercased())")
        DMRealtimeDiagnostics.debug("businessId=\(identity?.businessIdLogValue ?? "nil")")
        DMRealtimeDiagnostics.debug("channelName=dm-thread-\(tid)")
        DMRealtimeDiagnostics.debug("listeningForSender=\(identity?.listeningLogValue ?? me.uuidString.lowercased())")
        DMRealtimeDiagnostics.debug("listeningForRecipient=\(identity?.listeningLogValue ?? me.uuidString.lowercased())")

        let (channel, stream) = service.directMessagesInsertChannel(conversationId: cid)
        registerThreadRealtimeChannelCreated(channel, conversationId: cid)
        establishingRealtimeChannel = channel
        threadRealtimeChannelName = channel.topic
        threadRealtimeChannelStatus = "subscribing"
        isThreadRealtimeSubscribing = true
        isThreadRealtimeSubscribed = false
        if subscriptionReason == "foregroundForceRebuild" {
            DMRealtimeDiagnostics.debug("freshChannelCreated=true channelObjectId=\(threadRealtimeChannelObjectId(channel)) channelName=\(channel.topic)")
        }
        DMRealtimeDiagnostics.debug("resubscribeStarted=true reconnectReason=subscribeAttempt channelName=\(channel.topic)")

#if DEBUG
        let filterDesc = DirectChatService.directMessagesThreadRealtimeFilterDescription(conversationId: cid)
        DMRealtimeDiagnostics.log(
            "phase=thread_realtime_channel_created topic=\(channel.topic) conversation=\(tid) table=direct_messages event=INSERT"
        )
        DMRealtimeDiagnostics.log(
            "phase=thread_realtime_filter_used filter=\(filterDesc)"
        )
#endif

        do {
#if DEBUG
            DMRealtimeDiagnostics.log(
                "phase=thread_realtime_subscribe_call_started topic=\(channel.topic) conversation=\(tid)"
            )
#endif
            try await subscribeThreadChannelWithTimeout(channel)
            threadRealtimeChannelStatus = String(describing: channel.status)
            DMRealtimeDiagnostics.debug("subscribeCallbackStatus=\(threadRealtimeChannelStatus) channelObjectId=\(threadRealtimeChannelObjectId(channel)) authReady=\(currentUserId == me) conversationReady=\(conversationId == cid)")
            DMRealtimeDiagnostics.debug("channelStatus=\(threadRealtimeChannelStatus) channelName=\(channel.topic)")
#if DEBUG
            DMRealtimeDiagnostics.log(
                "phase=thread_realtime_subscribe_call_returned topic=\(channel.topic) conversation=\(tid)"
            )
            DMRealtimeDiagnostics.log(
                "phase=thread_realtime_subscription_status topic=\(channel.topic) status=\(String(describing: channel.status))"
            )
            RealtimeHealthDiagnostics.log("subscribeReady elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - healthSubscribeStartedAt) * 1000)) channelName=\(channel.topic)")
#endif
        } catch {
            establishingRealtimeChannel = nil
            isThreadRealtimeSubscribing = false
            isThreadRealtimeSubscribed = false
            threadRealtimeChannelStatus = (error is DMThreadRealtimeSubscribeTimeoutError) ? "timedOut" : "error"
            DMRealtimeDiagnostics.debug("subscribeCallbackStatus=\(threadRealtimeChannelStatus) channelObjectId=\(threadRealtimeChannelObjectId(channel))")
            await clearThreadRealtimeChannelAfterSubscribeFailure(
                channel,
                status: threadRealtimeChannelStatus,
                reason: "subscribeFailed"
            )
            if error is CancellationError {
#if DEBUG
                print("[DirectChatRealtime] subscribe cancelled thread=\(tid)")
#endif
                throw error
            }
            let errLabel = (error is DMThreadRealtimeSubscribeTimeoutError) ? "subscribe_timeout_15s" : error.localizedDescription
            DMRealtimeDiagnostics.debug("channelError=\(errLabel) channelName=\(channel.topic)")
#if DEBUG
            print("[DirectChatRealtime] subscribe failed thread=\(tid) error=\(errLabel)")
#endif
            realtimeConnectionStatus = .reconnecting
#if DEBUG
            DMRealtimeDiagnostics.log("phase=thread_realtime_subscribe_failed conversation=\(tid) error=\(errLabel)")
            RealtimeHealthDiagnostics.log("subscribeError=\(errLabel) channelName=\(channel.topic)")
#endif
            throw error
        }

        establishingRealtimeChannel = nil
        isThreadRealtimeSubscribing = false
        isThreadRealtimeSubscribed = true
        lastThreadFallbackPollSucceeded = nil
        refreshHeaderConnectionStatus()
#if DEBUG
        print("[DirectChatRealtime] subscribe success thread=\(tid)")
#endif
#if DEBUG
        DMRealtimeDiagnostics.log("phase=thread_realtime_subscribe_ready conversation=\(tid)")
        print("[DMRealtimeLatencyDebug] realtimeSubscribed conversationId=\(tid) channel=\(channel.topic)")
#endif
        messagesRealtimeChannel = channel
        activeRealtimeThreadConversationId = cid
        lastRealtimeStreamInsertAt = Date()
        lastThreadRealtimeSubscribeAt = Date()
        threadRealtimeChannelName = channel.topic
        threadRealtimeChannelStatus = String(describing: channel.status)
        DMRealtimeDiagnostics.debug("resubscribeCompleted=true conversationId=\(tid) channelName=\(channel.topic) channelStatus=\(threadRealtimeChannelStatus)")
        DMRealtimeDiagnostics.debug("activeConversationId=\(activeRealtimeThreadConversationId?.uuidString.lowercased() ?? "nil") expectedConversationId=\(tid)")
        DMRealtimeDiagnostics.debug("channelCount=\(threadRealtimeActiveChannelObjectIds.count) context=subscribed")
        stopThreadFallbackPolling(reason: "realtimeSubscribed")
        realtimeConnectionStatus = .connected
        await backfillAfterRealtimeResubscribe(conversationId: cid, reason: "realtime_resubscribe")

        let decoder = JSONDecoder()
        for await insertion in stream {
            if Task.isCancelled { break }
            do {
                try Task.checkCancellation()
            } catch {
                break
            }
            let row: DirectMessageRow
            do {
                row = try insertion.decodeRecord(as: DirectMessageRow.self, decoder: decoder)
            } catch {
                continue
            }
            dmRealtimeReceivedServerIDs.insert(row.id)
            lastThreadRealtimeInsertReceivedAt = Date()
            DMRealtimeDiagnostics.debug("lastInsertReceivedAt=\(Self.optimisticCreatedAtFormatter.string(from: lastThreadRealtimeInsertReceivedAt ?? Date()))")
#if DEBUG
            RealtimeHealthDiagnostics.log("eventReceived table=direct_messages id=\(row.id.uuidString.lowercased()) elapsedSinceInsertMs=\(DMRealtimePerfLog.elapsedMs(since: dmInsertSuccessTimesByServerID[row.id]))")
#endif
            applyIncomingDirectMessageRow(row, threadConversationId: cid, me: me)
        }

        activeRealtimeThreadConversationId = nil
        isThreadRealtimeSubscribed = false
        refreshHeaderConnectionStatus()
        startThreadFallbackPollingIfNeeded(reason: "streamEnded")
        if messagesRealtimeChannel != nil {
            unregisterThreadRealtimeChannelRemoved(
                channel,
                reason: "streamEnded",
                status: String(describing: channel.status)
            )
#if DEBUG
            print("[DirectChatRealtime] unsubscribe thread=\(tid)")
#endif
            messagesRealtimeChannel = nil
            threadRealtimeChannelStatus = "streamEnded"
            realtimeConnectionStatus = .reconnecting
            await service.removeRealtimeChannel(channel)
        }
    }

    /// Single Postgres INSERT listener for this thread; recovers timed-out/ended subscriptions with bounded backoff.
    /// Typing indicator / broadcast is intentionally disabled until DM realtime is proven stable.
    func ensureRealtimeSubscriptionIfReady(reason: String) async {
        startRealtimeWatchdogIfNeeded()
        logRealtimeReadiness(reason: reason)
        guard loadError == nil else {
            DMRealtimeDiagnostics.debug("ignoredReason=loadError reason=\(reason)")
            return
        }
        guard currentUserId != nil else {
            DMRealtimeDiagnostics.debug("ignoredReason=authNotReady reason=\(reason)")
            return
        }
        guard conversationId != nil else {
            DMRealtimeDiagnostics.debug("ignoredReason=conversationNotReady reason=\(reason)")
            return
        }
        startThreadFallbackPollingIfNeeded(reason: reason)
        await runRealtimeWatchdogCheck(reason: reason)
    }

    private func forceRealtimeReconnect(reason: String) async {
        DMRealtimeDiagnostics.debug("foregroundReconnectCheck=true reason=\(reason) channelStatus=\(threadRealtimeChannelStatusDescription())")
        await reconnectRealtimeFromWatchdog(reason: reason)
    }

    func runRealtimeSubscription(subscriptionReason: String? = nil) async {
        guard loadError == nil, let cid = conversationId, let me = currentUserId else { return }
        startRealtimeWatchdogIfNeeded()
        threadRealtimeSubscriptionLoopActive = true
        defer { threadRealtimeSubscriptionLoopActive = false }
        var attempt = 0

        while !Task.isCancelled, conversationId == cid {
            let delayNs = directMessageReconnectDelaysNs[min(attempt, directMessageReconnectDelaysNs.count - 1)]
            if delayNs > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNs)
                } catch {
                    break
                }
            }

            if messagesRealtimeChannel != nil || establishingRealtimeChannel != nil {
                await tearDownRealtimeChannelIfNeeded()
            }
            if forceThreadRealtimeReconnectRequested {
                forceThreadRealtimeReconnectRequested = false
            }

            realtimeConnectionStatus = .reconnecting
#if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=direct_thread attempt=\(attempt + 1) channelName=dm-thread-\(cid.uuidString.lowercased())")
#endif

            do {
                try await runRealtimeSubscriptionAttempt(
                    conversationId: cid,
                    currentUserId: me,
                    subscriptionReason: subscriptionReason
                )
                attempt = 0
                if Task.isCancelled || conversationId != cid { break }
                attempt += 1
            } catch is CancellationError {
                break
            } catch is DMThreadRealtimeSubscribeTimeoutError {
                threadRealtimeSubscriptionTask = nil
                threadRealtimeSubscriptionTaskId = nil
                threadRealtimeSubscriptionStartReason = nil
                threadRealtimeSubscriptionLoopActive = false
                DMRealtimeDiagnostics.debug("subscriptionTaskCleared=true reason=subscribeTimeout")
                await chatViewModel?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "threadSubscribeTimeout")
                let result = await refreshMessagesForCurrentThreadResult(reason: "thread_subscribe_timeout")
                DMRealtimeDiagnostics.debug("backfillMergedCount=\(result.mergedCount) conversationId=\(cid.uuidString.lowercased()) reason=threadSubscribeTimeout")
                if result.didFetch {
                    realtimeConnectionStatus = isThreadRealtimeSubscribed ? .connected : .connecting
                }
                if !Task.isCancelled, conversationId == cid, currentUserId == me {
                    startThreadFallbackPollingIfNeeded(reason: "subscribeTimeoutRetry")
                    startRealtimeSubscriptionLoopIfNeeded(reason: "subscribeTimeoutRetry")
                }
                break
            } catch {
                if Self.realtimeErrorIndicatesGlobalRetryExhausted(error) {
                    threadRealtimeSubscriptionTask = nil
                    threadRealtimeSubscriptionTaskId = nil
                    threadRealtimeSubscriptionStartReason = nil
                    threadRealtimeSubscriptionLoopActive = false
                    DMRealtimeDiagnostics.debug("subscriptionTaskCleared=true reason=globalRetryExhausted")
                    await chatViewModel?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "threadGlobalRetryExhausted")
                    let result = await refreshMessagesForCurrentThreadResult(reason: "thread_global_retry_exhausted")
                    DMRealtimeDiagnostics.debug("backfillMergedCount=\(result.mergedCount) conversationId=\(cid.uuidString.lowercased()) reason=threadGlobalRetryExhausted")
                    if result.didFetch {
                        realtimeConnectionStatus = isThreadRealtimeSubscribed ? .connected : .connecting
                    }
                    if !Task.isCancelled, conversationId == cid, currentUserId == me {
                        startThreadFallbackPollingIfNeeded(reason: "globalRetryExhaustedRetry")
                        startRealtimeSubscriptionLoopIfNeeded(reason: "globalRetryExhaustedRetry")
                    }
                    break
                }
                attempt += 1
                if attempt >= directMessageReconnectDelaysNs.count {
                    realtimeConnectionStatus = .offline
                    break
                }
            }
        }
    }

    /// Recovery-only: REST merge when Realtime has been silent. Network work runs off `.utility` so it does not block UI/realtime.
    @discardableResult
    func refreshMessagesForCurrentThread(reason: String) async -> Int {
        let result = await refreshMessagesForCurrentThreadResult(reason: reason)
        return result.mergedCount
    }

    private func refreshMessagesForCurrentThreadResult(reason: String) async -> (mergedCount: Int, didFetch: Bool) {
        guard loadError == nil, let cid = conversationId, let me = currentUserId else { return (0, false) }
        let tid = cid.uuidString.lowercased()
        let svc = service
        do {
            let rows = try await Task.detached(priority: .utility) {
                try await svc.fetchLatestMessages(conversationId: cid, limit: 50)
            }.value
            let existing = Set(messages.map(\.id))
            let tailNew = rows.filter { !existing.contains($0.id) }.sorted(by: Self.messageTimelineSort)
            guard !tailNew.isEmpty else { return (0, true) }
            let fallbackReceivedAt = Date()
            tailNew.forEach {
                dmDebugFallbackMessageIDs.insert($0.id)
                dmDebugReceivedDatesByServerID[$0.id] = fallbackReceivedAt
                logDMEndToEnd(row: $0, conversationId: cid, fallbackUsed: true, receivedAt: fallbackReceivedAt)
            }
            realtimeConnectionStatus = .connecting
#if DEBUG
            print("[DirectChatRealtime] refresh merged newCount=\(tailNew.count) thread=\(tid) reason=\(reason)")
#endif
#if DEBUG
            let ids = tailNew.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
            DMRealtimeDiagnostics.log(
                "phase=receiver_rest_refresh_found_message reason=\(reason) thread=\(tid) newMessageIds=\(ids)"
            )
#endif
            for row in tailNew {
                if let removedLocalId = absorbPendingOptimistic(forConfirmedRow: row, me: me) {
                    removeDisplayTimelineMessage(id: removedLocalId)
                }
                if !messages.contains(where: { $0.id == row.id }) {
                    messages.append(row)
                }
            }
            if messages.count >= 2 {
                let prev = messages[messages.count - 2]
                let last = messages[messages.count - 1]
                if !Self.messageTimelineSort(prev, last) {
                    messages.sort(by: Self.messageTimelineSort)
                }
            }
            rebuildDisplayTimelineFromMessages()
            return (tailNew.count, true)
        } catch {
#if DEBUG
            print("[DirectChatRealtime] refresh failed thread=\(tid) reason=\(reason) err=\(error.localizedDescription)")
#endif
            return (0, false)
        }
    }

    func manualRefreshCurrentThread() async {
        guard !isManuallyRefreshingMessages else { return }
        guard let cid = conversationId else { return }
        let tid = cid.uuidString.lowercased()
#if DEBUG
        print("[DMManualRefreshDebug] tapped conversationId=\(tid)")
        print("[DMManualRefreshDebug] started conversationId=\(tid)")
#endif
        isManuallyRefreshingMessages = true
        defer {
            isManuallyRefreshingMessages = false
#if DEBUG
            print("[DMManualRefreshDebug] finished conversationId=\(tid)")
#endif
        }

        let merged = await refreshMessagesForCurrentThread(reason: "manual_refresh")
        _ = await flushMarkReadNow(reason: "manual_refresh")
#if DEBUG
        print("[DMManualRefreshDebug] merged count=\(merged)")
#endif
    }

    func pullRefreshCurrentThread() async {
        guard !isManuallyRefreshingMessages else {
#if DEBUG
            print("[DMChatPullRefreshDebug] skipped reason=refreshInFlight")
#endif
            return
        }
        guard let cid = conversationId else { return }
        let tid = cid.uuidString.lowercased()
#if DEBUG
        print("[DMChatPullRefreshDebug] nativeSpinnerStarted conversationId=\(tid)")
#endif
        defer {
#if DEBUG
            print("[DMChatPullRefreshDebug] nativeSpinnerFinished conversationId=\(tid)")
#endif
        }

        await manualRefreshCurrentThread()
    }

    private static func messageTimelineSort(_ a: DirectMessageRow, _ b: DirectMessageRow) -> Bool {
        let da = DirectChatTimeGrouping.parseDate(a.created_at) ?? .distantPast
        let db = DirectChatTimeGrouping.parseDate(b.created_at) ?? .distantPast
        if da != db { return da < db }
        return a.id.uuidString.lowercased() < b.id.uuidString.lowercased()
    }

    func verifyRealtimeAfterForeground() async {
        guard loadError == nil, let cid = conversationId else { return }
        startRealtimeWatchdogIfNeeded()
        DebugLogGate.debug("[DMRealtimeStability] foreground verify start")
        let identity = chatViewModel?.dmRealtimeIdentitySnapshot(fallbackAuthUserId: currentUserId)
        DMRealtimeDiagnostics.debug(
            "foregroundReconnectCheck=true accountType=\(identity?.accountType ?? "user") authUserId=\(identity?.authUserIdLogValue ?? currentUserId?.uuidString.lowercased() ?? "nil") businessId=\(identity?.businessIdLogValue ?? "nil") channelName=dm-thread-\(cid.uuidString.lowercased()) channelStatus=\(threadRealtimeChannelStatusDescription())"
        )

        guard chatViewModel?.canMarkActiveDirectThreadRead(
            conversationId: cid,
            reason: "foreground_verify"
        ) == true else {
            DebugLogGate.debug("[DMRealtimeStability] skipped offscreen")
            return
        }

        DebugLogGate.debug("[DMRealtimeStability] foreground reconnect")
        let watchdogReconnected = await runRealtimeWatchdogCheck(reason: "foreground")
        if !watchdogReconnected {
            await forceRealtimeReconnect(reason: "foreground")
        }
    }

    @discardableResult
    private func absorbPendingOptimistic(forConfirmedRow row: DirectMessageRow, me: UUID) -> UUID? {
        guard row.sender_id == me else { return nil }
        guard let idx = messages.firstIndex(where: { m in
            pendingOptimisticMessages[m.id] != nil && m.body == row.body && m.sender_id == me
        }) else { return nil }
        let localId = messages[idx].id
        pendingOptimisticMessages.removeValue(forKey: localId)
        messages.remove(at: idx)
        return localId
    }

    private func applyIncomingDirectMessageRow(
        _ row: DirectMessageRow,
        threadConversationId: UUID,
        me: UUID
    ) {
        let realtimeReceivedWall = Date()
        let rowIdLow = row.id.uuidString.lowercased()
        let isOwnSender = chatViewModel?.isCurrentDMRealtimeIdentity(row.sender_id, fallbackAuthUserId: me) ?? (row.sender_id == me)
        DMRealtimeDiagnostics.debug(
            "insertReceived messageId=\(rowIdLow) senderId=\(row.sender_id.uuidString.lowercased()) conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")"
        )
        DMRealtimeDiagnostics.debug("insertConversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")")
        DMRealtimeDiagnostics.debug("activeConversationId=\(threadConversationId.uuidString.lowercased())")
#if DEBUG
        let convLow = row.conversation_id?.uuidString.lowercased() ?? "nil"
        let sndLow = row.sender_id.uuidString.lowercased()
        if isOwnSender {
            let echoCorrelation = self.messages.lazy.compactMap { m -> UUID? in
                guard let pending = self.pendingOptimisticMessages[m.id],
                      pending.body == row.body,
                      pending.senderId == me else { return nil }
                return pending.correlationId
            }.first
            DMRealtimeDiagnostics.log(
                "phase=sender_realtime_echo_received messageId=\(rowIdLow) correlation=\(echoCorrelation?.uuidString.lowercased() ?? "nil") conversation=\(convLow)"
            )
        } else {
            DMRealtimeDiagnostics.log(
                "phase=receiver_thread_realtime_callback_fired messageId=\(rowIdLow) senderId=\(sndLow) conversation=\(convLow)"
            )
        }
#endif
#if DEBUG
        print("[DMRealtimePerf] sentAt=\(row.created_at ?? "nil")")
        print("[DMRealtimePerf] realtimeReceivedAt=\(DMRealtimePerfLog.stamp(realtimeReceivedWall))")
        print("[DMRealtimeLatencyDebug] realtimeInsertReceived conversationId=\(threadConversationId.uuidString.lowercased()) messageId=\(rowIdLow) elapsedSinceSendMs=\(DMRealtimePerfLog.elapsedMs(since: dmLatencySendTimesByServerID[row.id]))")
#endif
        let tInsert = CFAbsoluteTimeGetCurrent()
#if DEBUG
        print("[DirectChatLatency] insert_callback_received id=\(rowIdLow) t=\(tInsert)")
#endif
#if DEBUG
        print("[DirectChatRealtime] INSERT callback fired id=\(rowIdLow)")
#endif
        guard let msgCid = row.conversation_id, msgCid == threadConversationId else {
            let got = row.conversation_id?.uuidString.lowercased() ?? "nil"
            let want = threadConversationId.uuidString.lowercased()
            DMRealtimeDiagnostics.debug(
                "insertMatchedThread=false messageId=\(rowIdLow) ignoredReason=wrongConversation got=\(got) expected=\(want)"
            )
            DMRealtimeDiagnostics.debug("appendDecision=ignored messageId=\(rowIdLow)")
#if DEBUG
            print("[DirectChatRealtime] skipped insert wrong conversation_id=\(got) expected=\(want)")
#endif
            return
        }
        if row.deleted_at != nil {
            DMRealtimeDiagnostics.debug("insertMatchedThread=true messageId=\(rowIdLow) ignoredReason=deleted")
            DMRealtimeDiagnostics.debug("appendDecision=ignored messageId=\(rowIdLow)")
            return
        }
        if row.is_deleted == true {
            DMRealtimeDiagnostics.debug("insertMatchedThread=true messageId=\(rowIdLow) ignoredReason=deleted")
            DMRealtimeDiagnostics.debug("appendDecision=ignored messageId=\(rowIdLow)")
            return
        }
        dmDebugReceivedDatesByServerID[row.id] = realtimeReceivedWall
#if DEBUG
        let mainActorApplyStartedAt = CFAbsoluteTimeGetCurrent()
        RealtimeHealthDiagnostics.log("mainActorApplyStart=direct_messages id=\(rowIdLow)")
#endif
        if let removedLocalId = absorbPendingOptimistic(forConfirmedRow: row, me: me) {
            removeDisplayTimelineMessage(id: removedLocalId)
            DMRealtimeDiagnostics.debug("dedupedMessageId=\(removedLocalId.uuidString.lowercased()) confirmedMessageId=\(rowIdLow)")
#if DEBUG
            print("[DMRealtimeLatencyDebug] dedupeApplied conversationId=\(threadConversationId.uuidString.lowercased()) messageId=\(rowIdLow)")
#endif
        }
        guard !messages.contains(where: { $0.id == row.id }) else {
            DMRealtimeDiagnostics.debug("insertMatchedThread=true messageId=\(rowIdLow) ignoredReason=duplicate")
            DMRealtimeDiagnostics.debug("dedupedMessageId=\(rowIdLow)")
            DMRealtimeDiagnostics.debug("appendDecision=deduped messageId=\(rowIdLow)")
#if DEBUG
            print("[DirectChatRealtime] skipped duplicate id=\(row.id.uuidString.lowercased())")
#endif
#if DEBUG
            print("[DMRealtimeLatencyDebug] dedupeApplied conversationId=\(threadConversationId.uuidString.lowercased()) messageId=\(rowIdLow)")
#endif
            logDMEndToEnd(row: row, conversationId: threadConversationId, fallbackUsed: false, receivedAt: realtimeReceivedWall)
            return
        }
        DMRealtimeDiagnostics.debug("appendDecision=append messageId=\(rowIdLow)")
        DMRealtimeDiagnostics.debug("appendedMessageId=\(rowIdLow)")
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            messages.append(row)
            if messages.count >= 2 {
                let prev = messages[messages.count - 2]
                let last = messages[messages.count - 1]
                if !Self.messageTimelineSort(prev, last) {
                    messages.sort(by: Self.messageTimelineSort)
                    rebuildDisplayTimelineFromMessages()
                } else {
                    appendDisplayTimelineTail(for: row)
                }
            } else {
                appendDisplayTimelineTail(for: row)
            }
            lastRealtimeStreamInsertAt = Date()
        }
        let tAfter = CFAbsoluteTimeGetCurrent()
#if DEBUG
        if !isOwnSender {
            DMRealtimeDiagnostics.log(
                "phase=receiver_ui_append_completed messageId=\(rowIdLow) conversation=\(threadConversationId.uuidString.lowercased())"
            )
        }
        print("[DMRealtimeLatencyDebug] uiMessageListUpdated conversationId=\(threadConversationId.uuidString.lowercased()) count=\(messages.count) elapsedMs=\(DMRealtimePerfLog.elapsedMs(since: dmLatencySendTimesByServerID[row.id]))")
#endif
#if DEBUG
        let uiWall = Date()
        print("[DMRealtimePerf] uiAppliedAt=\(DMRealtimePerfLog.stamp(uiWall))")
        print("[DMRealtimePerf] totalReceiveLatencyMs=\(String(format: "%.1f", uiWall.timeIntervalSince(realtimeReceivedWall) * 1000))")
        if let raw = row.created_at, let serverDate = DirectChatTimeGrouping.parseDate(raw) {
            let serverMs = uiWall.timeIntervalSince(serverDate) * 1000
            print("[DMRealtimePerf] serverToUiLatencyMs=\(String(format: "%.1f", serverMs))")
        }
#endif
#if DEBUG
        print("[DirectChatRealtime] appended live message id=\(rowIdLow)")
#endif
#if DEBUG
        RealtimeHealthDiagnostics.log("mainActorApplyEnd elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - mainActorApplyStartedAt) * 1000)) table=direct_messages id=\(rowIdLow)")
#endif
        logDMEndToEnd(row: row, conversationId: threadConversationId, fallbackUsed: false, receivedAt: realtimeReceivedWall)
        DispatchQueue.main.async {
#if DEBUG
            let tVisible = CFAbsoluteTimeGetCurrent()
            print("[DirectChatLatency] swiftui_next_runloop id=\(rowIdLow) Δ_since_append_ms=\((tVisible - tAfter) * 1000)")
#endif
        }
        if !isOwnSender {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.flushMarkReadNow(reason: "thread_realtime_peer_message")
            }
        }
        DMRealtimeDiagnostics.debug("insertMatchedThread=true messageId=\(rowIdLow) ignoredReason=none")
    }

    private func completeOptimisticSend(
        localId: UUID,
        conversationId: UUID,
        me: UUID,
        trimmed: String,
        correlationId: UUID
    ) async {
        do {
#if DEBUG
            dmLatencyInsertStartTimesByLocalID[localId] = CFAbsoluteTimeGetCurrent()
            print("[DMRealtimeLatencyDebug] insertStart conversationId=\(conversationId.uuidString.lowercased()) localTime=\(DMRealtimePerfLog.stamp())")
#endif
            let row = try await service.sendMessage(
                conversationId: conversationId,
                senderId: me,
                body: trimmed,
                diagnosticCorrelationId: correlationId
            )
            RateLimitService.recordDirectChatSend(conversationId: conversationId, body: trimmed)
            FanGeoAnalyticsService.recordDMSent(conversationId: conversationId)
#if DEBUG
            if let sendStartedAt = dmLatencySendTimesByLocalID[localId] {
                dmLatencySendTimesByServerID[row.id] = sendStartedAt
                dmDebugSendTapTimesByServerID[row.id] = sendStartedAt
            }
            dmInsertSuccessTimesByServerID[row.id] = CFAbsoluteTimeGetCurrent()
            dmDebugReceivedDatesByServerID[row.id] = Date()
#endif
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                _ = absorbPendingOptimistic(forConfirmedRow: row, me: me)
                if !messages.contains(where: { $0.id == row.id }) {
                    messages.append(row)
                    if messages.count >= 2 {
                        let prev = messages[messages.count - 2]
                        let last = messages[messages.count - 1]
                        if !Self.messageTimelineSort(prev, last) {
                            messages.sort(by: Self.messageTimelineSort)
                        }
                    }
                }
                rebuildDisplayTimelineFromMessages()
                lastRealtimeStreamInsertAt = Date()
            }
            let insCid = row.conversation_id?.uuidString.lowercased() ?? conversationId.uuidString.lowercased()
#if DEBUG
            print("[DirectChatSend] inserted conversationId=\(insCid)")
            print("[DirectChatSend] insert success serverId=\(row.id.uuidString.lowercased())")
#endif
            chatViewModel?.requestBadgeRecalculation(reason: "messageSent", includeInboxSummaries: true)
            scheduleDirectMessageRealtimeFallback(conversationId: conversationId, expectedMessageID: row.id)
#if DEBUG
            print("[DMRealtimeLatencyDebug] insertSuccess conversationId=\(insCid) serverId=\(row.id.uuidString.lowercased()) elapsedMs=\(DMRealtimePerfLog.elapsedMs(since: dmLatencyInsertStartTimesByLocalID[localId]))")
            print("[DMRealtimeLatencyDebug] dedupeApplied conversationId=\(insCid) messageId=\(row.id.uuidString.lowercased())")
            print("[DMRealtimeLatencyDebug] uiMessageListUpdated conversationId=\(insCid) count=\(messages.count) elapsedMs=\(DMRealtimePerfLog.elapsedMs(since: dmLatencySendTimesByLocalID[localId]))")
            print("[DMRealtimePerf] sentAt=\(row.created_at ?? "nil")")
            print("[DMRealtimePerf] insertAckAt=\(DMRealtimePerfLog.stamp())")
#endif
            logDMEndToEnd(row: row, conversationId: conversationId, fallbackUsed: false)
        } catch {
#if DEBUG
            print("[DirectChatSend] insert failed localId=\(localId.uuidString.lowercased()) err=\(error.localizedDescription)")
#endif
#if DEBUG
            print("[DMRealtimeLatencyDebug] insertFailure conversationId=\(conversationId.uuidString.lowercased()) elapsedMs=\(DMRealtimePerfLog.elapsedMs(since: dmLatencyInsertStartTimesByLocalID[localId])) error=\(error.localizedDescription)")
#endif
            pendingOptimisticMessages.removeValue(forKey: localId)
            messages.removeAll { $0.id == localId }
            removeDisplayTimelineMessage(id: localId)
            draft = trimmed
            // Backend age denial opens the shared age gate; banner copy stays neutral.
            AgeAccessBackendDenial.handle(error, requestUserId: currentUserId)
            sendError = Self.userFacingSendFailureMessage(for: error)
        }
    }

    private static func userFacingSendFailureMessage(for error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("row-level security")
            || raw.contains("violates row-level security")
            || raw.contains("42501")
            || raw.contains("permission denied")
            || raw.contains("not allowed") {
            // Neutral: could be unfriend or block — never disclose which.
            return "You can’t send messages in this conversation."
        }
        return error.localizedDescription
    }

    private func scheduleDirectMessageRealtimeFallback(
        conversationId: UUID,
        expectedMessageID: UUID
    ) {
        dmRealtimeFallbackTasks[expectedMessageID]?.cancel()
        dmRealtimeFallbackTasks[expectedMessageID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: RealtimeFallback.delayNs)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard self.messagesRealtimeChannel != nil else {
                self.dmRealtimeFallbackTasks[expectedMessageID] = nil
                return
            }
            guard !self.dmRealtimeReceivedServerIDs.contains(expectedMessageID) else {
                self.dmRealtimeFallbackTasks[expectedMessageID] = nil
                return
            }
            await self.refreshMessagesForCurrentThread(reason: "send_realtime_fallback")
            self.dmRealtimeFallbackTasks[expectedMessageID] = nil
        }
    }

    func sendDraft() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= maxBodyLength else { return }
        guard let conversationId, let me = currentUserId else { return }

        if peerIsDeleted, !friend.isBusinessVenueConversation {
            sendError = DirectChatView.deletedPeerNoticeText
            return
        }
        if isMessagingBlocked() {
            sendError = "You can’t message this user."
            return
        }
        if !friendshipAllowsSending() {
            sendError = "You’re no longer friends. Add them again to continue messaging."
            return
        }
        if let blocked = validateDMText(trimmed) {
            sendError = blocked
            return
        }

        if let limited = RateLimitService.checkDirectChatSend(conversationId: conversationId, body: trimmed) {
            if limited == RateLimitService.duplicateBlockedMessage {
#if DEBUG
                print("[DirectChatSend] duplicate blocked without user toast conversationId=\(conversationId.uuidString.lowercased())")
#endif
                return
            }
            sendError = limited
            return
        }

        guard !sendDraftInFlight else { return }
        sendDraftInFlight = true
        defer { sendDraftInFlight = false }

        sendError = nil

        let correlationId = UUID()
        let localId = UUID()
#if DEBUG
        let sendStartedAt = CFAbsoluteTimeGetCurrent()
        dmLatencySendTimesByLocalID[localId] = sendStartedAt
        DMRealtimeDiagnostics.log(
            "phase=sender_tap_send correlation=\(correlationId.uuidString.lowercased()) conversation=\(conversationId.uuidString.lowercased()) peer=\(friend.id.uuidString.lowercased())"
        )
        print("[DMRealtimeLatencyDebug] sendTapped conversationId=\(conversationId.uuidString.lowercased()) localTime=\(DMRealtimePerfLog.stamp())")
        print("[DMRealtimeLatencyDebug] currentFlow conversationId=\(conversationId.uuidString.lowercased()) optimisticUI=yes realtime=yes polling=no manualReloadAfterInsert=no foregroundRecovery=yes")
#endif

        let created = Self.optimisticCreatedAtFormatter.string(from: Date())
        let optimistic = DirectMessageRow(
            id: localId,
            conversation_id: conversationId,
            sender_id: me,
            body: trimmed,
            created_at: created,
            deleted_at: nil,
            report_count: nil,
            is_deleted: false
        )
        pendingOptimisticMessages[localId] = PendingOptimisticSend(body: trimmed, senderId: me, correlationId: correlationId)
        var appendTxn = Transaction()
        appendTxn.disablesAnimations = true
        withTransaction(appendTxn) {
            messages.append(optimistic)
            appendDisplayTimelineTail(for: optimistic)
        }
#if DEBUG
        print("[DirectChatSend] optimistic append localId=\(localId.uuidString.lowercased())")
#endif
#if DEBUG
        print("[DMRealtimeLatencyDebug] optimisticAppend conversationId=\(conversationId.uuidString.lowercased()) tempId=\(localId.uuidString.lowercased()) localTime=\(DMRealtimePerfLog.stamp())")
        print("[DMRealtimeLatencyDebug] uiMessageListUpdated conversationId=\(conversationId.uuidString.lowercased()) count=\(messages.count) elapsedMs=\(DMRealtimePerfLog.elapsedMs(since: dmLatencySendTimesByLocalID[localId]))")
#endif
        draft = ""

        Task { [weak self] in
            guard let self else { return }
            await self.completeOptimisticSend(
                localId: localId,
                conversationId: conversationId,
                me: me,
                trimmed: trimmed,
                correlationId: correlationId
            )
        }
    }

    /// Sends a single emoji (or short reaction) without using the draft field; same server path as `sendDraft`.
    func sendQuickReaction(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxBodyLength else { return }
        guard let conversationId, let me = currentUserId else { return }

        if peerIsDeleted, !friend.isBusinessVenueConversation {
            sendError = DirectChatView.deletedPeerNoticeText
            return
        }
        if isMessagingBlocked() {
            sendError = "You can’t message this user."
            return
        }
        if !friendshipAllowsSending() {
            sendError = "You’re no longer friends. Add them again to continue messaging."
            return
        }
        if let blocked = validateDMText(trimmed) {
            sendError = blocked
            return
        }

        if let limited = RateLimitService.checkDirectChatSend(conversationId: conversationId, body: trimmed) {
            if limited == RateLimitService.duplicateBlockedMessage {
#if DEBUG
                print("[DirectChatSend] duplicate quick reaction blocked without user toast conversationId=\(conversationId.uuidString.lowercased())")
#endif
                return
            }
            sendError = limited
            return
        }

        sendError = nil

        let correlationId = UUID()
        let localId = UUID()
#if DEBUG
        let sendStartedAt = CFAbsoluteTimeGetCurrent()
        dmLatencySendTimesByLocalID[localId] = sendStartedAt
        DMRealtimeDiagnostics.log(
            "phase=sender_tap_send correlation=\(correlationId.uuidString.lowercased()) conversation=\(conversationId.uuidString.lowercased()) peer=\(friend.id.uuidString.lowercased()) source=quickReaction"
        )
        print("[DMRealtimeLatencyDebug] sendTapped conversationId=\(conversationId.uuidString.lowercased()) localTime=\(DMRealtimePerfLog.stamp())")
        print("[DMRealtimeLatencyDebug] currentFlow conversationId=\(conversationId.uuidString.lowercased()) optimisticUI=yes realtime=yes polling=no manualReloadAfterInsert=no foregroundRecovery=yes")
#endif

        let created = Self.optimisticCreatedAtFormatter.string(from: Date())
        let optimistic = DirectMessageRow(
            id: localId,
            conversation_id: conversationId,
            sender_id: me,
            body: trimmed,
            created_at: created,
            deleted_at: nil,
            report_count: nil,
            is_deleted: false
        )
        pendingOptimisticMessages[localId] = PendingOptimisticSend(body: trimmed, senderId: me, correlationId: correlationId)
        var appendTxn = Transaction()
        appendTxn.disablesAnimations = true
        withTransaction(appendTxn) {
            messages.append(optimistic)
            appendDisplayTimelineTail(for: optimistic)
        }
#if DEBUG
        print("[DirectChatSend] optimistic append localId=\(localId.uuidString.lowercased())")
#endif
#if DEBUG
        print("[DMRealtimeLatencyDebug] optimisticAppend conversationId=\(conversationId.uuidString.lowercased()) tempId=\(localId.uuidString.lowercased()) localTime=\(DMRealtimePerfLog.stamp())")
        print("[DMRealtimeLatencyDebug] uiMessageListUpdated conversationId=\(conversationId.uuidString.lowercased()) count=\(messages.count) elapsedMs=\(DMRealtimePerfLog.elapsedMs(since: dmLatencySendTimesByLocalID[localId]))")
#endif

        Task { [weak self] in
            guard let self else { return }
            await self.completeOptimisticSend(
                localId: localId,
                conversationId: conversationId,
                me: me,
                trimmed: trimmed,
                correlationId: correlationId
            )
        }
    }

    func trimDraftIfNeeded() {
        if draft.count > maxBodyLength {
            draft = String(draft.prefix(maxBodyLength))
        }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).count <= maxBodyLength
    }

    var lastMessageId: UUID? {
        messages.last?.id
    }

    /// Clears visible history locally and requests server-side clear when the `clear_direct_conversation` RPC is deployed.
    func clearChatHistory() async {
        menuBanner = nil
        guard let conversationId else {
            menuBanner = "Conversation isn’t ready yet."
            return
        }
        do {
            struct Params: Encodable {
                let p_conversation_id: UUID
            }
            try await supabase
                .rpc("clear_direct_conversation", params: Params(p_conversation_id: conversationId))
                .execute()
            pendingOptimisticMessages.removeAll()
            messages = []
            displayTimeline = []
            hasOlderMessages = false
        } catch {
            menuBanner = "Couldn’t clear chat on the server. Nothing was removed.\n\(error.localizedDescription)"
        }
    }

    /// Ends friendship without clearing DM history (`remove_friend` / Option B).
    func removeFriend() async throws {
        menuBanner = nil
        struct ParamsFriend: Encodable {
            let p_friend_user_id: UUID
        }
        try await supabase
            .rpc("remove_friend", params: ParamsFriend(p_friend_user_id: friend.id))
            .execute()
    }
}

private enum DirectChatQuickReactions {
    static let emojis: [String] = ChatQuickReactions.emojis
}

struct DirectChatView: View {

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var mapViewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @ObservedObject private var activityClock = ActivityStatusMinuteClock.shared
    @StateObject private var presenter: DirectChatPresenter
    @FocusState private var composerFocused: Bool

    @State private var overflowAnchorGlobal: CGRect = .zero
    @State private var scrollToBottomCoalesceTask: Task<Void, Never>?
    /// One-shot initial pin to newest content after the first usable message snapshot exists.
    @State private var didCompleteInitialScrollToBottom = false
    @State private var initialScrollTargetId: UUID?
    /// True when the viewport is near the newest messages (auto-stick incoming).
    @State private var isNearBottom = true
    /// Captured before keyboard lift so transient geometry spikes do not cancel stick-to-bottom.
    @State private var stickToBottomThroughKeyboardLift = true
    /// Bumped on conversation change so deferred scrolls cannot affect a newly opened thread.
    @State private var dmScrollSessionToken = UUID()
    /// True while the system keyboard is visibly lifting/resizing the chat chrome.
    @State private var isKeyboardLiftActive = false
    /// Last observed scroll content height — used to re-pin after variable-height rows settle.
    @State private var lastScrollContentHeight: CGFloat = 0
    /// Near-bottom enter / leave thresholds (asymmetric) so keyboard inset jitter does not flip stick state.
    private static let dmNearBottomEnterDistance: CGFloat = 96
    private static let dmNearBottomLeaveDistance: CGFloat = 180
    /// Custom overlay only (no `confirmationDialog` / `Menu` / `contextMenu`).
    @State private var chatOverflowPhase: ChatOverflowPhase = .hidden
    /// Quick emoji strip above composer; off by default, toggled by smiley (does not use the system emoji keyboard).
    @State private var showEmojiQuickTray = false
    @State private var reportSheet: DirectChatReportSheetKind?
    /// `nil` until the reporter picks a category (required before submit).
    @State private var reportCategory: ModerationReportCategory?
    @State private var reportDetails: String = ""
    @State private var isSubmittingReport = false
    @State private var reportSheetError: String?
    @State private var reportReviewWindowStart: Date = Date().addingTimeInterval(-86_400)
    @State private var reportReviewWindowEnd: Date = Date()
    @State private var reportReviewConsentChecked = false
    @State private var resolvedFriendOverride: UserPreview?
    @State private var directChatPresenceLoaded = false
    @State private var directChatPresenceRefreshTask: Task<Void, Never>?

    private static let reportSubmittedBannerText = "Report submitted. FanGeo moderation will review it."
    private static let duplicateConversationReportBannerText =
        "You already reported this conversation. FanGeo moderation will review it."
    fileprivate static let deletedPeerNoticeText =
        "This account has been deleted. You can still view past messages."
    private static let conversationReportMaxReviewWindow: TimeInterval = 7 * 24 * 60 * 60

    private static func isPositiveReportBanner(_ text: String) -> Bool {
        text == reportSubmittedBannerText || text == duplicateConversationReportBannerText
    }

    private enum ChatOverflowPhase: Equatable {
        case hidden
        case actions
        case confirmClearHistory
        case confirmRemoveFriend
        case confirmBlockUser
    }

    private enum DirectChatReportSheetKind: Identifiable, Equatable {
        case user
        case conversation
        case message(DirectMessageRow)

        var id: String {
            switch self {
            case .user: return "report-user"
            case .conversation: return "report-conversation"
            case .message(let m): return "report-message-\(m.id.uuidString)"
            }
        }

        static func == (lhs: DirectChatReportSheetKind, rhs: DirectChatReportSheetKind) -> Bool {
            switch (lhs, rhs) {
            case (.user, .user): return true
            case (.conversation, .conversation): return true
            case (.message(let a), .message(let b)): return a.id == b.id
            default: return false
            }
        }
    }

    private var messagingBlocked: Bool {
        chatViewModel.isEitherDirectionBlocked(with: presenter.friend.id)
    }

    private var isBusinessVenueThread: Bool {
        resolvedFriendPreview.isBusinessVenueConversation
    }

    /// Venue-scoped DM for either participant (fan↔business venue thread).
    private var isVenueScopedThread: Bool {
        resolvedFriendPreview.isVenueScopedDirectMessage
    }

    private var isDeletedPeer: Bool {
        !isBusinessVenueThread && (resolvedFriendPreview.isDeleted || presenter.peerIsDeleted)
    }

    /// Friendship-backed DMs only: venue threads do not require friendship.
    private var requiresAcceptedFriendshipToSend: Bool {
        !isVenueScopedThread
    }

    private var friendshipChip: ChatViewModel.FriendshipChipKind {
        chatViewModel.chipKind(forOtherUserId: presenter.friend.id)
    }

    private var friendshipAllowsSending: Bool {
        !requiresAcceptedFriendshipToSend || friendshipChip == .friends
    }

    private var sendingDisabled: Bool {
        messagingBlocked || isDeletedPeer || !friendshipAllowsSending
    }

    private var resolvedFriendPreview: UserPreview {
        chatViewModel.previewForLoadedDmParticipant(
            userId: presenter.friend.id,
            conversationId: presenter.conversationId ?? presenter.friend.dmConversationId
        )
            ?? resolvedFriendOverride
            ?? presenter.friend
    }

    private var directChatPresenceText: String {
        guard !presenter.friend.isBusinessVenueConversation,
              !resolvedFriendPreview.isBusinessAccount,
              resolvedFriendPreview.activityStatusVisible else {
            return ""
        }
        let lang = L10n.normalizedLanguageCode(appLanguageRaw)
        _ = activityClock.tickMinute
        let kind = ActivityStatus.resolve(lastSeenAtRaw: resolvedFriendPreview.lastSeenAtRaw)
        if directChatPresenceLoaded {
            return ActivityStatus.chatHeaderSubtitle(kind: kind, languageCode: lang) ?? ""
        }
        if case .online = kind {
            return L10n.t("activity_status_online", languageCode: lang)
        }
        return L10n.t("activity_status_checking", languageCode: lang)
    }

    init(friend: UserPreview) {
        _presenter = StateObject(wrappedValue: DirectChatPresenter(friend: friend))
    }

    var body: some View {
        directChatInteractiveRoot
            // Composer must attach to the topmost interactive chat container so SwiftUI's
            // keyboard safe area can lift it. Do not ignore keyboard anywhere above this.
            .safeAreaInset(edge: .bottom, spacing: 8) {
                composer
            }
            .onChange(of: composerFocused) { _, focused in
                if focused {
                    dismissChatOverflow()
                }
            }
            .task(id: directChatThreadTaskIdentity) {
            presenter.bindChatViewModel(chatViewModel)
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            resolvedFriendOverride = await chatViewModel.resolveDmParticipantPreview(
                userId: presenter.friend.id,
                fallback: presenter.friend,
                surface: "dm_thread_header",
                conversationId: presenter.friend.dmConversationId
            )
            directChatPresenceLoaded = true
            if !presenter.friend.isBusinessVenueConversation {
                presenter.updatePeerDeletedState(resolvedFriendOverride?.isDeleted == true)
            }
            await presenter.onAppear()

            if presenter.loadError == nil {
                chatViewModel.setActiveVisibleConversationIdIfAllowed(
                    presenter.conversationId,
                    reason: "thread_task_loaded"
                )
                if let conversationId = presenter.conversationId {
                    await chatViewModel.markDirectThreadRead(
                        conversationId: conversationId,
                        peerUserId: presenter.friend.id,
                        reason: "thread_open"
                    )
                }
                await presenter.ensureRealtimeSubscriptionIfReady(reason: "thread_task_loaded")
            } else {
                await chatViewModel.refreshInboxSummariesIfNeeded()
            }
        }
        .onAppear {
#if DEBUG
            print("[DirectChatNav] directChatAppear")
            print(
                "[DirectChatNav] setActive peerPresent=true conversationPresent=\(presenter.conversationId != nil || presenter.friend.dmConversationId != nil)"
            )
#endif
            chatViewModel.hidesFloatingTabBarForDirectChat = true
            DMRealtimeDiagnostics.debug("scenePhase=directChatAppear")
            DMRealtimeDiagnostics.debug("activeConversationId=\(presenter.conversationId?.uuidString.lowercased() ?? "nil") scenePhase=directChatAppear")
            startDirectChatPresenceRefreshLoop(reason: "directChatAppear")
            presenter.logRealtimeReadiness(reason: "direct_chat_appear", chatAppear: true)
            chatViewModel.setActiveVisibleConversationIdIfAllowed(
                presenter.conversationId,
                reason: "direct_chat_appear"
            )
            Task {
                await presenter.ensureRealtimeSubscriptionIfReady(reason: "direct_chat_appear")
                if let conversationId = presenter.conversationId {
                    await chatViewModel.markDirectThreadRead(
                        conversationId: conversationId,
                        peerUserId: presenter.friend.id,
                        reason: "direct_chat_appear"
                    )
                }
            }
        }
        .onChange(of: presenter.conversationId) { _, cid in
            chatViewModel.setActiveVisibleConversationIdIfAllowed(cid, reason: "conversation_id_changed")
            Task {
                await presenter.ensureRealtimeSubscriptionIfReady(reason: "conversation_id_changed")
            }
        }
        .onChange(of: chatViewModel.directChatReadVisibilityVersion) { _, _ in
            Task {
                guard chatViewModel.setActiveVisibleConversationIdIfAllowed(
                    presenter.conversationId,
                    reason: "became_visible"
                ), let conversationId = presenter.conversationId else { return }
                await chatViewModel.markDirectThreadRead(
                    conversationId: conversationId,
                    peerUserId: presenter.friend.id,
                    reason: "became_visible"
                )
            }
        }
        .onDisappear {
#if DEBUG
            print("[DirectChatNav] directChatDisappear reason=viewOnDisappear")
#endif
            chatViewModel.hidesFloatingTabBarForDirectChat = false
            chatOverflowPhase = .hidden
            DMRealtimeDiagnostics.debug("scenePhase=directChatDisappear")
            DMRealtimeDiagnostics.debug("activeConversationId=\(presenter.conversationId?.uuidString.lowercased() ?? "nil") scenePhase=directChatDisappear")
            stopDirectChatPresenceRefreshLoop()
            let conversationId = presenter.conversationId
            let peerUserId = presenter.friend.id
            Task {
                if let conversationId {
                    await chatViewModel.markDirectThreadRead(
                        conversationId: conversationId,
                        peerUserId: peerUserId,
                        reason: "thread_disappear",
                        requireActiveVisibleThread: false
                    )
                }
                await presenter.stopDirectMessageRealtime()
                chatViewModel.clearActiveVisibleConversationId(reason: "direct_chat_disappear")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            DMRealtimeDiagnostics.debug("scenePhase=\(String(describing: phase))")
            DMRealtimeDiagnostics.debug("activeConversationId=\(presenter.conversationId?.uuidString.lowercased() ?? "nil") scenePhase=\(String(describing: phase))")
            guard phase == .active else { return }
            Task {
                await refreshDirectChatPresence(source: "foreground")
                await presenter.forceRebuildRealtimeAfterForeground()
            }
        }
        .onChange(of: chatViewModel.requiresSignIn) { _, needsSignIn in
            guard needsSignIn else { return }
            composerFocused = false
            presenter.clearForSessionLoss()
            dismiss()
        }
        .onChange(of: chatViewModel.currentUserAuthId) { _, authId in
            guard authId == nil else {
                Task {
                    await presenter.ensureRealtimeSubscriptionIfReady(reason: "auth_user_id_changed")
                }
                return
            }
            composerFocused = false
            presenter.clearForSessionLoss()
            dismiss()
        }
        .onChange(of: resolvedFriendPreview.isDeleted) { _, isDeleted in
            presenter.updatePeerDeletedState(isDeleted)
            if isDeleted {
                composerFocused = false
                showEmojiQuickTray = false
            }
        }
        .sheet(item: $reportSheet) { kind in
            directChatReportSheet(kind: kind)
        }
        .onChange(of: reportSheet) { _, newValue in
            if newValue != nil {
                reportCategory = nil
                reportDetails = ""
                reportSheetError = nil
                isSubmittingReport = false
                reportReviewConsentChecked = false
                if case .conversation? = newValue {
                    resetConversationReportConsentWindow()
                    #if DEBUG
                    print("[PrivateReportConsent] opened conversation_id=\(presenter.conversationId?.uuidString ?? "nil")")
                    print("[PrivateReportConsent] window_start=\(Self.reportDebugISO.string(from: reportReviewWindowStart))")
                    print("[PrivateReportConsent] window_end=\(Self.reportDebugISO.string(from: reportReviewWindowEnd))")
                    #endif
                }
            } else {
                reportSheetError = nil
                isSubmittingReport = false
                reportReviewConsentChecked = false
            }
        }
        .onChange(of: reportCategory) { _, _ in
            if reportSheet != nil {
                reportSheetError = nil
            }
        }
        .onChange(of: reportReviewWindowStart) { _, _ in
            logConversationReportWindowChangeIfNeeded()
        }
        .onChange(of: reportReviewWindowEnd) { _, _ in
            logConversationReportWindowChangeIfNeeded()
        }
        .onChange(of: reportReviewConsentChecked) { _, checked in
            #if DEBUG
            print("[PrivateReportConsent] consent_checked=\(checked)")
            #endif
        }
    }

    /// Interactive Direct Chat chrome (messages + nav). Decorative background may ignore all
    /// safe areas as a leaf; keyboard region stays active on this interactive container for
    /// the outer ``safeAreaInset`` composer lift.
    private var directChatInteractiveRoot: some View {
        VStack(spacing: 0) {
            chatPrimaryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hasVisibleThreadBanner {
                chatThreadStatusStack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Decorative leaf only — full edge-to-edge. Interactive content above keeps keyboard safe area.
            FGColor.screenGradient(colorScheme)
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.thinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: FGSpacing.sm) {
                    ProfileAvatarView(preview: resolvedFriendPreview, size: 34)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(resolvedFriendPreview.displayName)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)

                        Text(chatHeaderSubtitle)
                            .font(FGTypography.metadata)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    resignComposerFirstResponder()
                    composerFocused = false
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                        if chatOverflowPhase == .hidden {
                            chatOverflowPhase = .actions
                        } else {
                            chatOverflowPhase = .hidden
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: 34, height: 34)
                        .background(FGColor.cardBackground(colorScheme))
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                        }
                        .accessibilityLabel("Chat options")
                }
                .buttonStyle(.plain)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ChatOverflowAnchorKey.self,
                            value: geo.frame(in: .global)
                        )
                    }
                )
            }
        }
        .onPreferenceChange(ChatOverflowAnchorKey.self) { rect in
            overflowAnchorGlobal = rect
        }
        .overlay(alignment: .topTrailing) {
            if chatOverflowPhase != .hidden {
                chatOverflowChromeOverlay
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .zIndex(chatOverflowPhase != .hidden ? 50 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: chatOverflowPhase)
    }

    @ViewBuilder
    private var chatPrimaryContent: some View {
        if presenter.isLoadingInitial {
            VStack(spacing: FGSpacing.lg) {
                ProfileAvatarView(preview: resolvedFriendPreview, size: 64)
                ProgressView()
                    .controlSize(.regular)
                Text("Opening conversation…")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.22), value: presenter.isLoadingInitial)
        } else if let err = presenter.loadError {
            FGEmptyState(
                title: "Couldn’t load chat",
                subtitle: err,
                systemImage: "wifi.exclamationmark"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, FGSpacing.lg)
            .animation(.easeInOut(duration: 0.22), value: presenter.loadError)
        } else {
            messagesScroll
                .transaction { $0.disablesAnimations = true }
        }
    }

    private var hasVisibleThreadBanner: Bool {
        (presenter.sendError?.isEmpty == false)
            || (presenter.menuBanner?.isEmpty == false)
            || showVenueChatIntroBanner
    }

    private var directChatThreadTaskIdentity: String {
        if let conversationId = presenter.friend.dmConversationId {
            return "conversation-\(conversationId.uuidString.lowercased())"
        }
        if let venueId = presenter.friend.businessVenueId {
            return "venue-\(venueId.uuidString.lowercased())"
        }
        return presenter.friend.id.uuidString.lowercased()
    }

    private var resolvedVenueChatConversationId: UUID? {
        presenter.conversationId ?? presenter.friend.dmConversationId
    }

    private var showVenueChatIntroBanner: Bool {
        guard isVenueScopedThread,
              let conversationId = resolvedVenueChatConversationId else {
            return false
        }
        return chatViewModel.shouldShowVenueChatIntroBanner(conversationId: conversationId)
    }

    private var chatHeaderSubtitle: String {
        if isDeletedPeer {
            return "Deleted account"
        }
        if messagingBlocked {
            return "Messaging unavailable"
        }
        if requiresAcceptedFriendshipToSend, !friendshipAllowsSending {
            return L10n.t("dm_not_friends_header", languageCode: appLanguageRaw)
        }
        if let businessName = resolvedFriendPreview.businessVenueBusinessName,
           !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return businessName
        }
        if isBusinessVenueThread {
            return "Business"
        }
        let handle = resolvedFriendPreview.publicHandleLine
        let presence = directChatPresenceText
        if !handle.isEmpty {
            return presence.isEmpty ? handle : "\(handle) · \(presence)"
        }
        let chatType = resolvedFriendPreview.isBusinessAccount ? "Business chat" : "Direct chat"
        return presence.isEmpty ? chatType : "\(chatType) · \(presence)"
    }

    private func refreshDirectChatPresence(source: String) async {
        guard !resolvedFriendPreview.isBusinessVenueConversation else { return }
        let friendId = presenter.friend.id
        let cachedRaw = resolvedFriendPreview.lastSeenAtRaw
        print("[PresenceDebug] directChatPresenceRefresh=true")
        print("[PresenceDebug] friendId=\(friendId.uuidString.lowercased())")
        print("[PresenceDebug] presenceSource=\(source)")

        let refreshed = await chatViewModel.refreshDirectChatPresencePreview(
            userId: friendId,
            fallback: resolvedFriendPreview,
            source: source
        )

        guard !Task.isCancelled else { return }
        if let refreshed {
            resolvedFriendOverride = refreshed
            directChatPresenceLoaded = true
            print("[PresenceDebug] lastSeenAt=\(refreshed.lastSeenAtRaw ?? "nil")")
            print("[PresenceDebug] isOnlineNow=\(refreshed.isOnlineNow)")
            print("[PresenceDebug] stalePresenceCacheUsed=false")
        } else {
            print("[PresenceDebug] lastSeenAt=\(cachedRaw ?? "nil")")
            print("[PresenceDebug] isOnlineNow=\(resolvedFriendPreview.isOnlineNow)")
            print("[PresenceDebug] stalePresenceCacheUsed=true")
        }
    }

    private func startDirectChatPresenceRefreshLoop(reason: String) {
        directChatPresenceRefreshTask?.cancel()
        directChatPresenceRefreshTask = Task { @MainActor in
            await refreshDirectChatPresence(source: reason)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                await refreshDirectChatPresence(source: "directChatOpenTimer")
            }
        }
    }

    private func stopDirectChatPresenceRefreshLoop() {
        directChatPresenceRefreshTask?.cancel()
        directChatPresenceRefreshTask = nil
        directChatPresenceLoaded = false
    }

    private var chatThreadStatusStack: some View {
        VStack(spacing: FGSpacing.sm) {
            if let sendErr = presenter.sendError, !sendErr.isEmpty {
                threadStatusBanner(
                    text: sendErr,
                    systemImage: "exclamationmark.circle.fill",
                    tint: FGColor.dangerRed
                )
            }

            if let banner = presenter.menuBanner, !banner.isEmpty {
                threadStatusBanner(
                    text: banner,
                    systemImage: Self.isPositiveReportBanner(banner) ? "checkmark.circle.fill" : "info.circle.fill",
                    tint: Self.isPositiveReportBanner(banner) ? FGColor.accentGreen : FGColor.accentBlue
                )
            }

            if showVenueChatIntroBanner {
                threadStatusBanner(
                    text: "You're messaging this venue. Messages are received by the venue's management team.",
                    systemImage: "info.circle.fill",
                    tint: FGColor.accentBlue
                )
                .onAppear {
                    if let conversationId = resolvedVenueChatConversationId {
                        chatViewModel.markVenueChatIntroBannerConsumed(conversationId: conversationId)
                    }
                }
            }
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.bottom, FGSpacing.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func threadStatusBanner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)

            Text(text)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .fanGeoFloatingStyle()
    }

    private func dismissChatOverflow() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            chatOverflowPhase = .hidden
        }
    }

    private func resignComposerFirstResponder() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func runClearHistoryConfirmed() async {
        await presenter.clearChatHistory()
        await chatViewModel.refreshInboxSummaries()
    }

    private func runRemoveFriendConfirmed() async {
        do {
            try await presenter.removeFriend()
            // Stay on the thread so history remains visible; composer becomes read-only.
            await chatViewModel.refresh()
            await chatViewModel.refreshInboxSummaries()
            dismissChatOverflow()
        } catch {
            presenter.menuBanner = error.localizedDescription
        }
    }

    private func runBlockUserConfirmed() async {
        let moderation = ModerationService()
        do {
            try await moderation.block(userId: presenter.friend.id)
            // TODO: Optional server RPC to end friendship + archive DM when product policy requires it.
            await chatViewModel.refreshBlockedUsers()
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.refresh()
            await MainActor.run {
                dismissChatOverflow()
                dismiss()
            }
        } catch {
            await MainActor.run {
                presenter.menuBanner = error.localizedDescription
            }
        }
    }

    private func sendDraftIfBusinessAllowed() {
        Task {
            guard await directChatBusinessBanGuardAllows(action: "sendDraft") else { return }
            await presenter.sendDraft()
        }
    }

    private func sendQuickReactionIfBusinessAllowed(_ reaction: String) {
        Task {
            guard await directChatBusinessBanGuardAllows(action: "sendQuickReaction") else { return }
            await presenter.sendQuickReaction(reaction)
        }
    }

    private func directChatBusinessBanGuardAllows(action: String) async -> Bool {
        guard mapViewModel.hasAuthenticatedVenueOwnerSession
            || mapViewModel.currentUserIsBusinessAccount
            || mapViewModel.venueOwnerMode else {
            return true
        }

        let blocked = await mapViewModel.businessBanGuardBlocks(path: "businessChat", action: action)
        if blocked {
            await MainActor.run {
                composerFocused = false
                presenter.sendError = "Your account is suspended."
            }
            return false
        }

        return true
    }

    @ViewBuilder
    private func directChatReportSheet(kind: DirectChatReportSheetKind) -> some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $reportCategory) {
                        Text("Select category").tag(Optional<ModerationReportCategory>.none)
                        ForEach(ModerationReportCategory.allCases) { c in
                            Text(c.displayTitle).tag(Optional(c))
                        }
                    }
                    .disabled(isSubmittingReport)
                } footer: {
                    if reportCategory == nil {
                        Text("Choose a category to submit this report.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Details (optional)", text: $reportDetails, axis: .vertical)
                        .lineLimit(3...6)
                        .disabled(isSubmittingReport)
                } footer: {
                    if case .conversation = kind {
                        Text(
                            "Optional. Up to \(ModerationService.conversationReportDetailsMaxCharacters) characters for conversation reports."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: reportDetails) { _, newValue in
                    if newValue.count > ModerationService.conversationReportDetailsMaxCharacters {
                        reportDetails = String(newValue.prefix(ModerationService.conversationReportDetailsMaxCharacters))
                    }
                }

                if case .conversation = kind {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Report this private conversation?")
                                .font(.headline)
                            Text("Private messages are only shared with FanGeo safety admins when you report them. By continuing, you allow admins to review the selected portion of this conversation so they can investigate your report.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        DatePicker(
                            "From",
                            selection: $reportReviewWindowStart,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .disabled(isSubmittingReport)
                        DatePicker(
                            "To",
                            selection: $reportReviewWindowEnd,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .disabled(isSubmittingReport)
                        Toggle(
                            "I understand that FanGeo safety admins may review messages in this selected time window.",
                            isOn: $reportReviewConsentChecked
                        )
                        .disabled(isSubmittingReport)
                    } footer: {
                        if let validationError = conversationReportWindowValidationError() {
                            Text(validationError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("Admins will receive only messages in this selected time window.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isSubmittingReport {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Submitting…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let reportSheetError, !reportSheetError.isEmpty {
                    Section {
                        Text(reportSheetError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(reportNavigationTitle(for: kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        reportSheet = nil
                    }
                    .disabled(isSubmittingReport)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmittingReport {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Button("Submit") {
                            Task { await submitDirectChatReport(kind: kind) }
                        }
                        .disabled(isReportSubmitDisabled(for: kind))
                    }
                }
            }
            .interactiveDismissDisabled(isSubmittingReport)
        }
    }

    private static let reportDebugISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func reportNavigationTitle(for kind: DirectChatReportSheetKind) -> String {
        switch kind {
        case .user: return "Report User"
        case .conversation: return "Report Conversation"
        case .message: return "Report Message"
        }
    }

    private func resetConversationReportConsentWindow() {
        let now = Date()
        let latestMessage = presenter.messages
            .compactMap { row -> (DirectMessageRow, Date)? in
                guard let date = DirectChatTimeGrouping.parseDate(row.created_at) else { return nil }
                return (row, date)
            }
            .max { $0.1 < $1.1 }
        let anchor = min(latestMessage?.1 ?? now, now)
        reportReviewWindowEnd = anchor
        reportReviewWindowStart = anchor.addingTimeInterval(-24 * 60 * 60)
    }

    private func reportedMessageIdForConversationReport(
        from snapshotRows: [DirectMessageRow],
        reportedUserId: UUID
    ) -> UUID? {
        snapshotRows
            .compactMap { row -> (UUID, Date)? in
                guard row.sender_id == reportedUserId,
                      let date = DirectChatTimeGrouping.parseDate(row.created_at) else { return nil }
                return (row.id, date)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func conversationReportWindowValidationError() -> String? {
        if reportReviewWindowStart > reportReviewWindowEnd {
            return "Choose a start time before the end time."
        }
        if reportReviewWindowEnd > Date() {
            return "The review window can’t end in the future."
        }
        if reportReviewWindowEnd.timeIntervalSince(reportReviewWindowStart) > Self.conversationReportMaxReviewWindow {
            return "Choose a review window of 7 days or less."
        }
        return nil
    }

    private func isReportSubmitDisabled(for kind: DirectChatReportSheetKind) -> Bool {
        guard reportCategory != nil else { return true }
        guard case .conversation = kind else { return false }
        return !reportReviewConsentChecked || conversationReportWindowValidationError() != nil
    }

    private func logConversationReportWindowChangeIfNeeded() {
        guard case .conversation? = reportSheet else { return }
        #if DEBUG
        print("[PrivateReportConsent] window_start=\(Self.reportDebugISO.string(from: reportReviewWindowStart))")
        print("[PrivateReportConsent] window_end=\(Self.reportDebugISO.string(from: reportReviewWindowEnd))")
        if let reason = conversationReportWindowValidationError() {
            print("[PrivateReportConsent] invalid_window reason=\(reason)")
        }
        #endif
    }

    private func submitDirectChatReport(kind: DirectChatReportSheetKind) async {
        guard let category = reportCategory else {
            await MainActor.run {
                reportSheetError = "Please choose a category."
            }
            return
        }

        let moderation = ModerationService()
        let trimmedDetails = reportDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsOpt = trimmedDetails.isEmpty ? nil : trimmedDetails
        let contextLabel: String = {
            switch kind {
            case .user: return "report_user"
            case .conversation: return "report_conversation"
            case .message: return "report_message"
            }
        }()

        await MainActor.run {
            isSubmittingReport = true
            reportSheetError = nil
        }

        do {
            switch kind {
            case .user:
                try await moderation.reportUser(reportedUserId: presenter.friend.id, category: category, details: detailsOpt)
            case .conversation:
                guard let cid = presenter.conversationId else {
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = "Conversation isn’t ready yet. Try again in a moment."
                    }
                    return
                }
                guard let reporterId = chatViewModel.currentUserAuthId else {
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = "Sign in to submit a report."
                    }
                    return
                }
                if let validationError = conversationReportWindowValidationError() {
#if DEBUG
                    print("[PrivateReportConsent] invalid_window reason=\(validationError)")
#endif
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = validationError
                    }
                    return
                }
                guard reportReviewConsentChecked else {
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = "Please confirm admin review consent before submitting."
                    }
                    return
                }
                if let cooldownMessage = RateLimitService.checkConversationReportSubmit(
                    reporterId: reporterId,
                    conversationId: cid
                ) {
                    await MainActor.run {
                        isSubmittingReport = false
                        reportSheetError = cooldownMessage
                    }
                    return
                }

                let snapshotRows = try await DirectChatService().fetchMessagesForReportSnapshot(
                    conversationId: cid,
                    from: reportReviewWindowStart,
                    to: reportReviewWindowEnd
                )
                let messageSnapshot = snapshotRows.map {
                    PrivateConversationReportMessageSnapshot(
                        id: $0.id,
                        conversation_id: $0.conversation_id,
                        sender_id: $0.sender_id,
                        body: $0.body,
                        created_at: $0.created_at
                    )
                }
                let reportedMessageId = reportedMessageIdForConversationReport(
                    from: snapshotRows,
                    reportedUserId: presenter.friend.id
                )
#if DEBUG
                print("[PrivateReportConsent] window_start=\(Self.reportDebugISO.string(from: reportReviewWindowStart))")
                print("[PrivateReportConsent] window_end=\(Self.reportDebugISO.string(from: reportReviewWindowEnd))")
                print("[DMReport] review snapshot count=\(messageSnapshot.count)")
                print("[DMReport] selected reported_message_id=\(reportedMessageId?.uuidString ?? "nil") reported_user_id=\(presenter.friend.id.uuidString)")
#endif

                _ = try await moderation.reportConversation(
                    conversationId: cid,
                    otherUserId: presenter.friend.id,
                    category: category,
                    details: detailsOpt,
                    reviewWindowStart: reportReviewWindowStart,
                    reviewWindowEnd: reportReviewWindowEnd,
                    reportedMessageId: reportedMessageId,
                    messageSnapshot: messageSnapshot
                )
                RateLimitService.recordConversationReportSubmit(reporterId: reporterId, conversationId: cid)
            case .message(let row):
                try await moderation.reportMessage(
                    messageId: row.id,
                    reportedUserId: row.sender_id,
                    messageTextSnapshot: row.body,
                    category: category,
                    details: detailsOpt,
                    conversationId: presenter.conversationId
                )
            }
            await MainActor.run {
                isSubmittingReport = false
                reportSheet = nil
                presenter.menuBanner = Self.reportSubmittedBannerText
            }
        } catch let convErr as ModerationConversationReportError {
            switch convErr {
            case .duplicateOpenReport:
                if let reporterId = chatViewModel.currentUserAuthId, let cid = presenter.conversationId {
                    RateLimitService.recordConversationReportSubmit(reporterId: reporterId, conversationId: cid)
                }
#if DEBUG
                print(
                    "[DMReport] duplicate conversation report ignored conversation=\(presenter.conversationId?.uuidString ?? "nil")"
                )
#endif
                await MainActor.run {
                    isSubmittingReport = false
                    reportSheet = nil
                    presenter.menuBanner = Self.duplicateConversationReportBannerText
                }
            case .detailsTooLong, .detailsProhibitedContent:
                await MainActor.run {
                    isSubmittingReport = false
                    reportSheetError = convErr.errorDescription ?? "Invalid report details."
                }
            }
        } catch {
            ModerationService.logReportSubmitFailure(error, context: contextLabel)
            let message = ModerationService.userFacingReportSubmitError(error)
            await MainActor.run {
                isSubmittingReport = false
                reportSheetError = message
            }
        }
    }

    // Tuned to match Screenshot 2 (pre-recovery target).
    private static let overflowMenuWidth: CGFloat = 244
    /// Five primary rows (block / report / clear / remove) at ~56pt each.
    private static let overflowMenuHeight: CGFloat = 292
    private static let overflowMenuCornerRadius: CGFloat = 30
    private static let overflowMenuTopPadding: CGFloat = 54
    private static let overflowMenuTrailingPadding: CGFloat = 16
    private static let overflowMenuTextHorizontalPadding: CGFloat = 16
    private static let overflowMenuRowHeight: CGFloat = 56
    private static let overflowMenuFontSize: CGFloat = 20

    /// Adds specular highlights + subtle color refraction to create a "liquid glass" look.
    private func liquidGlassBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(.thinMaterial)
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.08),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)
                .opacity(0.32)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            FGColor.divider(colorScheme),
                            Color.black.opacity(0.04),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
    }

    /// Fixed top-trailing placement (no centering, no full-width card). Light dim only; chat stays visible.
    private var chatOverflowChromeOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(Color.clear)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                dismissChatOverflow()
            }

            Group {
                switch chatOverflowPhase {
                case .hidden:
                    EmptyView()
                case .actions:
                    chatOverflowActionsCard()
                case .confirmClearHistory:
                    chatOverflowConfirmCard(
                        title: "Clear chat history?",
                        message: "This clears the conversation history for both of you.",
                        confirmTitle: "Clear chat history",
                        onConfirm: {
                            Task {
                                await runClearHistoryConfirmed()
                                await MainActor.run { dismissChatOverflow() }
                            }
                        }
                    )
                case .confirmRemoveFriend:
                    chatOverflowConfirmCard(
                        title: "Remove friend?",
                        message: L10n.t("dm_unfriend_confirm_body", languageCode: appLanguageRaw),
                        confirmTitle: "Remove friend",
                        onConfirm: {
                            Task {
                                await runRemoveFriendConfirmed()
                                await MainActor.run { dismissChatOverflow() }
                            }
                        }
                    )
                case .confirmBlockUser:
                    chatOverflowConfirmCard(
                        title: "Block \(resolvedFriendPreview.displayName)?",
                        message: "They won’t be able to message you or send friend requests. You won’t see each other in chat lists while the block is active.",
                        confirmTitle: "Block",
                        onConfirm: {
                            Task {
                                await runBlockUserConfirmed()
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, Self.overflowMenuTopPadding)
            .padding(.trailing, Self.overflowMenuTrailingPadding)
        }
    }

    private func chatOverflowActionsCard() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            overflowMenuActionRow(title: "Block user", systemImage: "hand.raised.fill") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    chatOverflowPhase = .confirmBlockUser
                }
            }
            overflowMenuActionRow(title: "Report user", systemImage: "flag.fill") {
                dismissChatOverflow()
                reportSheet = .user
            }
            overflowMenuActionRow(title: "Report conversation", systemImage: "exclamationmark.bubble.fill") {
                dismissChatOverflow()
                reportSheet = .conversation
            }
            overflowMenuActionRow(title: "Clear chat history", systemImage: "trash.fill") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    chatOverflowPhase = .confirmClearHistory
                }
            }
            overflowMenuActionRow(title: "Remove friend", systemImage: "person.badge.minus") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    chatOverflowPhase = .confirmRemoveFriend
                }
            }
        }
        .padding(.vertical, 0)
        .frame(width: Self.overflowMenuWidth, height: Self.overflowMenuHeight, alignment: .top)
        .background {
            liquidGlassBackground(cornerRadius: Self.overflowMenuCornerRadius)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
    }

    private func chatOverflowConfirmCard(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
            Text(message)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismissChatOverflow()
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.red)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: Self.overflowMenuWidth, alignment: .leading)
        .background {
            liquidGlassBackground(cornerRadius: Self.overflowMenuCornerRadius)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 18, x: 0, y: 10)
    }

    private func overflowMenuActionRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FGSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
                .foregroundStyle(Color.red.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.overflowMenuRowHeight)
                .padding(.horizontal, Self.overflowMenuTextHorizontalPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Stable sentinel for pinning the viewport to newest content (not a message UUID).
    private static let dmScrollBottomAnchorId = "dm-scroll-bottom-anchor"

    private var dmInitialScrollReadyKey: String {
        let cid = presenter.conversationId?.uuidString.lowercased() ?? "nil"
        let last = presenter.lastMessageId?.uuidString.lowercased() ?? "nil"
        return "\(cid)|\(last)|\(presenter.isLoadingInitial)|\(presenter.messages.count)"
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager VStack: DM pages are capped (~50). LazyVStack estimated heights for
                // off-screen text rows from tall shared-profile cards, so defaultScrollAnchor /
                // scrollTo landed past real content (blank viewport until the user scrolled up).
                VStack(spacing: FGSpacing.md) {
                    if presenter.messages.isEmpty {
                        FGEmptyState(
                            title: "No messages yet",
                            subtitle: "Start the conversation and bring the game-day energy.",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                        .padding(.bottom, FGSpacing.sm)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.dmScrollBottomAnchorId)
                            .accessibilityHidden(true)
                    } else {
                        if presenter.hasOlderMessages || presenter.isLoadingOlderMessages {
                            HStack(spacing: FGSpacing.sm) {
                                if presenter.isLoadingOlderMessages {
                                    ProgressView()
                                        .scaleEffect(0.85)
                                }
                                if presenter.hasOlderMessages {
                                    Button {
                                        Task { await presenter.loadOlderMessages() }
                                    } label: {
                                        Label("Load older messages", systemImage: "arrow.up.message")
                                            .font(FGTypography.metadata)
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(presenter.isLoadingOlderMessages)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, FGSpacing.md)
                            .padding(.vertical, FGSpacing.sm)
                            .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.86 : 0.96))
                            .clipShape(Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                            }
                            .padding(.bottom, 4)
                        }
                        ForEach(presenter.timelineForDisplay) { entry in
                            switch entry {
                            case .daySeparator(_, let label):
                                daySeparatorPill(label)
                                    .padding(.vertical, 8)
                            case .message(let row):
                                messageRow(for: row)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.dmScrollBottomAnchorId)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, 28)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // Only pin on size changes while the user is already at the newest end so
            // load-older pagination (content grows above) does not jump to the bottom.
            .defaultScrollAnchor(shouldStickToNewestMessages ? .bottom : nil, for: .sizeChanges)
            // Hide until the first bottom pin completes so users never see a jump from top → bottom.
            .opacity(didCompleteInitialScrollToBottom ? 1 : 0)
            .accessibilityHidden(!didCompleteInitialScrollToBottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await presenter.pullRefreshCurrentThread()
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let maxY = max(geometry.contentSize.height - geometry.containerSize.height, 0)
                return maxY - geometry.contentOffset.y
            } action: { _, distanceFromBottom in
                updateNearBottomFromScrollDistance(distanceFromBottom)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { oldHeight, newHeight in
                guard didCompleteInitialScrollToBottom else {
                    lastScrollContentHeight = newHeight
                    return
                }
                guard shouldStickToNewestMessages, newHeight > oldHeight + 1 else {
                    lastScrollContentHeight = newHeight
                    return
                }
                // Shared-profile cards / images can expand after first layout; keep newest pinned.
                lastScrollContentHeight = newHeight
                scrollChatToBottom(proxy: proxy, animated: false)
#if DEBUG
                print("[DMScrollDebug] contentSizeGrewWhileNearBottom old=\(Int(oldHeight)) new=\(Int(newHeight))")
#endif
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height
            } action: { oldHeight, newHeight in
                guard didCompleteInitialScrollToBottom else { return }
                guard shouldStickToNewestMessages else { return }
                // Composer / keyboard / tray changes shrink or grow the viewport.
                guard abs(newHeight - oldHeight) > 1 else { return }
                scrollChatToBottomAfterLayout(proxy: proxy, force: true)
#if DEBUG
                print("[DMScrollDebug] containerHeightChanged old=\(Int(oldHeight)) new=\(Int(newHeight))")
#endif
            }
            .task(id: dmInitialScrollReadyKey) {
                await performInitialScrollToNewestIfNeeded(proxy: proxy)
            }
            .onChange(of: presenter.conversationId) { _, _ in
                resetDirectChatScrollSession(reason: "conversationIdChanged")
            }
            .onChange(of: presenter.lastMessageId) { oldId, newId in
                guard let newId, newId != oldId else { return }
                let isMine = presenter.messages.last?.sender_id == presenter.currentUserId
                if isMine {
                    isNearBottom = true
                    stickToBottomThroughKeyboardLift = true
                } else {
                    guard shouldStickToNewestMessages else { return }
                }
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    scrollChatToBottom(proxy: proxy, animated: false)
                }
            }
            .directChatOnKeyboardLift { phase in
                handleKeyboardLift(phase: phase, proxy: proxy)
            }
            .onChange(of: composerFocused) { _, focused in
                if focused, shouldStickToNewestMessages {
                    stickToBottomThroughKeyboardLift = true
                    scrollChatToBottomAfterLayout(proxy: proxy, force: true)
                }
            }
            .onChange(of: showEmojiQuickTray) { _, _ in
                guard shouldStickToNewestMessages else { return }
                scrollChatToBottomAfterLayout(proxy: proxy, force: true)
            }
        }
    }

    private var shouldStickToNewestMessages: Bool {
        isNearBottom || (isKeyboardLiftActive && stickToBottomThroughKeyboardLift)
    }

    private func resetDirectChatScrollSession(reason: String) {
        scrollToBottomCoalesceTask?.cancel()
        scrollToBottomCoalesceTask = nil
        dmScrollSessionToken = UUID()
        didCompleteInitialScrollToBottom = false
        initialScrollTargetId = nil
        isNearBottom = true
        stickToBottomThroughKeyboardLift = true
        isKeyboardLiftActive = false
        lastScrollContentHeight = 0
#if DEBUG
        print("[DMScrollDebug] scrollSessionReset reason=\(reason) token=\(dmScrollSessionToken.uuidString.lowercased())")
#endif
    }

    private func updateNearBottomFromScrollDistance(_ distanceFromBottom: CGFloat) {
        if distanceFromBottom <= Self.dmNearBottomEnterDistance {
            isNearBottom = true
            stickToBottomThroughKeyboardLift = true
            return
        }
        if distanceFromBottom > Self.dmNearBottomLeaveDistance {
            isNearBottom = false
            // During keyboard lift, inset thrash can briefly report a large distance even
            // when the user is still at the newest end. Keep the pre-lift stick preference
            // unless they clearly scrolled far upward.
            if !isKeyboardLiftActive || distanceFromBottom > Self.dmNearBottomLeaveDistance * 2 {
                stickToBottomThroughKeyboardLift = false
            }
        }
    }

    private func handleKeyboardLift(phase: DirectChatKeyboardLiftPhase, proxy: ScrollViewProxy) {
        switch phase {
        case .willChange:
            if !isKeyboardLiftActive {
                // Capture pre-lift stick preference only — do not promote "reading history"
                // into stick-to-bottom just because the composer gained focus.
                stickToBottomThroughKeyboardLift = isNearBottom
            }
            isKeyboardLiftActive = true
            guard stickToBottomThroughKeyboardLift else { return }
            scrollChatToBottomAfterLayout(proxy: proxy, force: true)
        case .didShow:
            isKeyboardLiftActive = true
            guard stickToBottomThroughKeyboardLift || isNearBottom else { return }
            isNearBottom = true
            stickToBottomThroughKeyboardLift = true
            scrollChatToBottomAfterLayout(proxy: proxy, force: true)
        case .didHide:
            isKeyboardLiftActive = false
            // Re-evaluate from the next geometry callback; keep sticky if we were pinned.
            if stickToBottomThroughKeyboardLift {
                isNearBottom = true
            }
        }
    }

    @MainActor
    private func performInitialScrollToNewestIfNeeded(proxy: ScrollViewProxy) async {
        guard !didCompleteInitialScrollToBottom else { return }
        guard !presenter.isLoadingInitial else { return }

        let sessionToken = dmScrollSessionToken
        let expectedConversationId = presenter.conversationId

        if presenter.messages.isEmpty {
            guard !Task.isCancelled else { return }
            guard sessionToken == dmScrollSessionToken else { return }
            guard presenter.conversationId == expectedConversationId else { return }
            didCompleteInitialScrollToBottom = true
            isNearBottom = true
            stickToBottomThroughKeyboardLift = true
#if DEBUG
            print("[DMScrollDebug] initialScrollCompletedEmpty conversationId=\(expectedConversationId?.uuidString.lowercased() ?? "nil")")
#endif
            return
        }

        guard let lastId = presenter.lastMessageId else { return }
        let targetExisted = presenter.messages.contains(where: { $0.id == lastId })
        initialScrollTargetId = lastId

#if DEBUG
        print(
            "[DMScrollDebug] initialScrollReady conversationId=\(presenter.conversationId?.uuidString.lowercased() ?? "nil") messageCount=\(presenter.messages.count) newestMessageId=\(lastId.uuidString.lowercased()) targetExisted=\(targetExisted) visibleBottom=\(isNearBottom) session=\(sessionToken.uuidString.lowercased())"
        )
#endif

        // Smallest reliable deferral: yield for the current turn, then wait one main-queue
        // turn so the eager VStack commits real row heights before the first pin.
        await Task.yield()
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        guard !Task.isCancelled else { return }
        guard sessionToken == dmScrollSessionToken else { return }
        guard presenter.conversationId == expectedConversationId else { return }

        scrollChatToBottom(proxy: proxy, animated: false)
        didCompleteInitialScrollToBottom = true
        isNearBottom = true
        stickToBottomThroughKeyboardLift = true

#if DEBUG
        print("[DMScrollDebug] initialScrollCompleted targetId=\(lastId.uuidString.lowercased())")
#endif
    }

    private func daySeparatorPill(_ title: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Text(title)
                .font(FGTypography.metadata)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.xs + 2)
                .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.94))
                .clipShape(Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func messageRow(for row: DirectMessageRow) -> some View {
        let isMine = row.sender_id == presenter.currentUserId
        let time = DirectChatTimeGrouping.shortTimeString(forCreatedAt: row.created_at)
        if let payload = FanProfileShareMessage.decode(from: row.body) {
            FanProfileShareChatCardView(
                payload: payload,
                isFromCurrentUser: isMine,
                showFriendAvatar: !isMine,
                friendPreview: resolvedFriendPreview,
                timestamp: time,
                mapViewModel: mapViewModel
            )
            .contextMenu {
                if !isMine {
                    Button("Report message") {
                        reportSheet = .message(row)
                    }
                }
            }
            .id(row.id)
        } else {
            DirectMessageBubbleView(
                text: row.body,
                isFromCurrentUser: isMine,
                showFriendAvatar: !isMine,
                friendPreview: resolvedFriendPreview,
                timestamp: time
            )
            .contextMenu {
                if !isMine {
                    Button("Report message") {
                        reportSheet = .message(row)
                    }
                }
            }
            .id(row.id)
        }
    }

    private func scrollChatToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        // Prefer the stable bottom sentinel so variable-height newest rows (profile cards)
        // stay fully visible even when their measured height changes after first paint.
        let target = AnyHashable(Self.dmScrollBottomAnchorId)
        if animated {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    /// Coalesces keyboard / focus / viewport scroll requests after the next layout turn.
    private func scrollChatToBottomAfterLayout(proxy: ScrollViewProxy, force: Bool = false) {
        guard force || shouldStickToNewestMessages else { return }
        let sessionToken = dmScrollSessionToken
        let expectedConversationId = presenter.conversationId
        scrollToBottomCoalesceTask?.cancel()
        scrollToBottomCoalesceTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
            guard !Task.isCancelled else { return }
            guard sessionToken == dmScrollSessionToken else { return }
            guard presenter.conversationId == expectedConversationId else { return }
            guard force || shouldStickToNewestMessages else { return }
            scrollChatToBottom(proxy: proxy, animated: false)
        }
    }

    /// Bottom input: optional slim emoji strip above composer; moves with keyboard via `safeAreaInset`.
    private var composer: some View {
        VStack(spacing: showEmojiQuickTray ? FGSpacing.sm : 0) {
            if messagingBlocked {
                threadStatusBanner(
                    text: L10n.t("dm_messaging_unavailable", languageCode: appLanguageRaw),
                    systemImage: "lock.fill",
                    tint: FGColor.accentYellow
                )
            } else if isDeletedPeer {
                threadStatusBanner(
                    text: Self.deletedPeerNoticeText,
                    systemImage: "person.crop.circle.badge.xmark",
                    tint: FGColor.secondaryText(colorScheme)
                )
            } else if requiresAcceptedFriendshipToSend, !friendshipAllowsSending {
                threadStatusBanner(
                    text: L10n.t("dm_no_longer_friends_notice", languageCode: appLanguageRaw),
                    systemImage: "person.2.slash",
                    tint: FGColor.secondaryText(colorScheme)
                )
                dmFriendshipActionRow
            }
            if presenter.loadError == nil, presenter.conversationId != nil {
                ChatRealtimeConnectionStatusView(status: presenter.realtimeConnectionStatus)
                    .padding(.top, showEmojiQuickTray ? 0 : FGSpacing.xs)
                    .padding(.bottom, FGSpacing.xs)
                    .transition(.opacity)
            }
            if !sendingDisabled {
                ChatMessageComposer(
                    draft: $presenter.draft,
                    showEmojiQuickTray: $showEmojiQuickTray,
                    composerFocused: $composerFocused,
                    canSend: presenter.canSend,
                    sendingDisabled: sendingDisabled,
                    isRefreshing: presenter.isManuallyRefreshingMessages,
                    showsRefreshButton: true,
                    refreshEnabled: presenter.conversationId != nil,
                    placeholder: "Message",
                    maxBodyLength: 1000,
                    colorScheme: colorScheme,
                    emojis: DirectChatQuickReactions.emojis,
                    refreshAccessibilityLabel: "Refresh private chat",
                    emojiToggleAccessibilityLabel: "Toggle emoji reactions",
                    sendAccessibilityLabel: "Send",
                    emojiReactionAccessibilityFormat: "Send %@ reaction",
                    onSend: { sendDraftIfBusinessAllowed() },
                    onQuickEmoji: { sendQuickReactionIfBusinessAllowed($0) },
                    onRefresh: {
                        Task { await presenter.manualRefreshCurrentThread() }
                    },
                    onTrimDraft: { presenter.trimDraftIfNeeded() }
                )
            } else if messagingBlocked || isDeletedPeer || (requiresAcceptedFriendshipToSend && !friendshipAllowsSending) {
                // Refresh-only strip so history can still be reloaded while send is disabled.
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        Task { await presenter.manualRefreshCurrentThread() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(presenter.isManuallyRefreshingMessages || presenter.conversationId == nil)
                    .accessibilityLabel("Refresh private chat")
                }
            }
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.top, FGSpacing.sm)
        .padding(.bottom, 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: showEmojiQuickTray)
#if DEBUG
        .animation(.easeInOut(duration: 0.18), value: presenter.realtimeConnectionStatus)
#endif
    }

    @ViewBuilder
    private var dmFriendshipActionRow: some View {
        HStack(spacing: 10) {
            switch friendshipChip {
            case .friends:
                EmptyView()
            case .pendingOutgoing:
                Text(L10n.t("dm_friend_request_pending", languageCode: appLanguageRaw))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            case .declinedOutgoing, .addFriend:
                Button(L10n.t("dm_friend_request_add", languageCode: appLanguageRaw)) {
                    Task {
                        await chatViewModel.sendFriendRequest(to: presenter.friend.id)
                    }
                }
                .buttonStyle(.borderedProminent)
            case .pendingIncoming:
                Button(L10n.t("dm_friend_request_accept", languageCode: appLanguageRaw)) {
                    Task { await acceptIncomingFriendRequestFromThread() }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private func acceptIncomingFriendRequestFromThread() async {
        guard let incoming = chatViewModel.incomingRequests.first(where: {
            $0.requester.id == presenter.friend.id && $0.friendship.isPendingStatus
        }) else {
            await chatViewModel.refresh()
            return
        }
        await chatViewModel.accept(incoming)
    }
}

private enum DirectChatKeyboardLiftPhase: Equatable {
    case willChange
    case didShow
    case didHide
}

#if canImport(UIKit)
private extension View {
    /// Keyboard lift lifecycle for DM stick-to-bottom (frame changes + didShow/didHide).
    func directChatOnKeyboardLift(_ action: @escaping (DirectChatKeyboardLiftPhase) -> Void) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { _ in
                action(.willChange)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                action(.didShow)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                action(.didHide)
            }
    }
}
#else
private extension View {
    func directChatOnKeyboardLift(_ action: @escaping (DirectChatKeyboardLiftPhase) -> Void) -> some View {
        self
    }
}
#endif

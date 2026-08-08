import Combine
import Foundation
import Supabase

/// In-memory poll snapshots with Realtime-driven refresh (no REST polling loop).
@MainActor
final class PickupGamePollStore: ObservableObject {
    static let shared = PickupGamePollStore()

    @Published private(set) var snapshots: [UUID: PickupGamePollSnapshot] = [:]
    @Published private(set) var loadingPollIds: Set<UUID> = []

    private let service = PickupGamePollService()
    private var conversationId: UUID?
    private var pollChannel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var trackedPollIds: Set<UUID> = []
    private var refreshGeneration = 0

    private init() {}

    func bind(conversationId: UUID) {
        if self.conversationId == conversationId { return }
        let previous = self.conversationId
        self.conversationId = conversationId
        if previous != nil {
            Task { await tearDownRealtime() }
        }
    }

    func stop() async {
        conversationId = nil
        trackedPollIds.removeAll()
        await tearDownRealtime()
    }

    func snapshot(for pollId: UUID) -> PickupGamePollSnapshot? {
        snapshots[pollId]
    }

    func ensureLoaded(_ pollId: UUID) {
        trackedPollIds.insert(pollId)
        if snapshots[pollId] == nil, !loadingPollIds.contains(pollId) {
            Task { await refresh(pollId) }
        }
        Task { await ensureRealtime() }
    }

    func refresh(_ pollId: UUID) async {
        loadingPollIds.insert(pollId)
        defer { loadingPollIds.remove(pollId) }
        do {
            let snap = try await service.fetchSnapshot(pollId: pollId)
            snapshots[pollId] = snap
            trackedPollIds.insert(pollId)
        } catch {
#if DEBUG
            print("[PickupPollStore] refresh failed poll=\(pollId.uuidString.lowercased()) err=\(error)")
#endif
        }
    }

    func applyOptimisticVote(pollId: UUID, optionIds: [UUID], voterUserId: UUID) {
        guard let snap = snapshots[pollId], !snap.isClosed else { return }
        let previous = Set(snap.myOptionIds)
        let next = Set(optionIds)

        var optionCounts: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: snap.options.map { ($0.id, $0.voteCount) }
        )
        for removed in previous.subtracting(next) {
            optionCounts[removed] = max(0, (optionCounts[removed] ?? 0) - 1)
        }
        for added in next.subtracting(previous) {
            optionCounts[added] = (optionCounts[added] ?? 0) + 1
        }

        let wasVoter = !previous.isEmpty
        let isVoter = !next.isEmpty
        var total = snap.totalVoters
        if !wasVoter && isVoter { total += 1 }
        if wasVoter && !isVoter { total = max(0, total - 1) }

        let newOptions = snap.options.map { opt in
            PickupGamePollOptionSnapshot(
                id: opt.id,
                text: opt.text,
                sortOrder: opt.sortOrder,
                voteCount: optionCounts[opt.id] ?? opt.voteCount
            )
        }

        var voters = snap.voters.filter { $0.voterUserId != voterUserId }
        if !snap.isAnonymous {
            for oid in next {
                voters.append(PickupGamePollVoterRow(optionId: oid, voterUserId: voterUserId))
            }
        }

        snapshots[pollId] = snap.replacing(
            options: newOptions,
            totalVoters: total,
            myOptionIds: optionIds,
            voters: snap.isAnonymous ? snap.voters : voters
        )
    }

    func setVote(pollId: UUID, optionIds: [UUID]) async throws {
        let voterId = try await service.currentUserId()
        applyOptimisticVote(pollId: pollId, optionIds: optionIds, voterUserId: voterId)
        do {
            try await service.setVote(pollId: pollId, optionIds: optionIds)
        } catch {
            await refresh(pollId)
            throw error
        }
        await refresh(pollId)
    }

    func closePoll(_ pollId: UUID) async throws {
        try await service.closePoll(pollId: pollId)
        await refresh(pollId)
    }

    func deletePoll(_ pollId: UUID) async throws {
        try await service.deletePoll(pollId: pollId)
        await refresh(pollId)
    }

    func setPinned(_ pollId: UUID, pinned: Bool) async throws {
        try await service.setPinned(pollId: pollId, pinned: pinned)
        await refresh(pollId)
    }

    // MARK: - Realtime

    private func tearDownRealtime() async {
        refreshGeneration &+= 1
        listenTask?.cancel()
        listenTask = nil
        let channel = pollChannel
        pollChannel = nil
        if let channel {
            await ChatRealtimeChannelSerializer.shared.removeExclusive(
                topic: channel.topic,
                channel: channel
            ) { [service] ch in
                await service.removeRealtimeChannel(ch)
            }
        }
    }

    private func ensureRealtime() async {
        guard let conversationId else { return }
        if pollChannel != nil { return }

        let gen = refreshGeneration
        let topic = "pickup-polls-\(conversationId.uuidString.lowercased())"
        await ChatRealtimeChannelSerializer.shared.waitForTopicIdle(topic)

        guard refreshGeneration == gen, self.conversationId == conversationId else { return }

        let (channel, updates) = service.pollUpdatesChannel(conversationId: conversationId)
        pollChannel = channel
        listenTask = Task { [weak self] in
            for await action in updates {
                guard let self, self.refreshGeneration == gen else { break }
                if let pollId = Self.uuid(from: action.record["id"]) {
                    guard self.trackedPollIds.contains(pollId) || self.snapshots[pollId] != nil else {
                        continue
                    }
                    await self.refresh(pollId)
                }
            }
        }

        do {
            try await channel.subscribeWithError()
        } catch {
#if DEBUG
            print("[PickupPollStore] poll channel subscribe failed: \(error)")
#endif
            pollChannel = nil
        }
    }

    private static func uuid(from value: AnyJSON?) -> UUID? {
        guard let value else { return nil }
        if case .string(let s) = value {
            return UUID(uuidString: s)
        }
        return nil
    }
}

extension PickupGamePollSnapshot {
    func replacing(
        options: [PickupGamePollOptionSnapshot]? = nil,
        totalVoters: Int? = nil,
        myOptionIds: [UUID]? = nil,
        voters: [PickupGamePollVoterRow]? = nil,
        status: String? = nil
    ) -> PickupGamePollSnapshot {
        PickupGamePollSnapshot(
            id: id,
            pickupGameId: pickupGameId,
            conversationId: conversationId,
            messageId: messageId,
            createdBy: createdBy,
            question: question,
            allowMultiple: allowMultiple,
            isAnonymous: isAnonymous,
            autoCloseAtGameStart: autoCloseAtGameStart,
            closesAt: closesAt,
            status: status ?? self.status,
            closedAt: closedAt,
            pinnedAt: pinnedAt,
            deletedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            totalVoters: totalVoters ?? self.totalVoters,
            options: options ?? self.options,
            myOptionIds: myOptionIds ?? self.myOptionIds,
            voters: voters ?? self.voters,
            viewerIsOrganizer: viewerIsOrganizer
        )
    }
}

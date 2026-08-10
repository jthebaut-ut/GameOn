import Foundation

/// In-feed native ad slot for Chat → My Teams list (not DM threads / inbox Chats).
enum ChatMyTeamsListItem: Identifiable {
    case team(FanTeamSummary)
    case nativeAd(ChatMyTeamsNativeAdSlot)

    var id: String {
        switch self {
        case .team(let team):
            return "my-team-\(team.id.uuidString.lowercased())"
        case .nativeAd(let slot):
            return slot.id
        }
    }
}

struct ChatMyTeamsNativeAdSlot: Hashable {
    let ordinal: Int
    let insertedAfterTeamPosition: Int

    var id: String {
        "chat-my-teams-native-ad-\(insertedAfterTeamPosition)"
    }

    var slotIndex: Int {
        ChatMyTeamsAdPlacement.nativeAdSlotIndexBase + ordinal
    }
}

enum ChatMyTeamsAdPlacement {
    /// Dedicated AdMob slot base (venue comments 0–1, chat inbox 2, Going Pro 3+).
    static let nativeAdSlotIndexBase = 10
    /// Ad after first team, then every additional 5 teams (1, 6, 11, …).
    static let firstAdAfterTeamPosition = 1
    static let recurringInterval = 5
    static let placementID = "chat.myTeamsFeed"

    /// Cached insertion positions for an identical team-id fingerprint (avoids ad remount churn).
    private static var cachedFingerprint: String?
    private static var cachedPositions: [Int]?
#if DEBUG
    private static var lastLoggedFingerprint: String?
#endif

    static func shouldInsertNativeAd(teamCount: Int) -> Bool {
        !insertionPositions(for: teamCount).isEmpty
    }

    static func skippedReason(teamCount: Int) -> String? {
        shouldInsertNativeAd(teamCount: teamCount) ? nil : "noTeams"
    }

    /// 1-based team positions after which an ad is inserted.
    static func insertionPositions(for teamCount: Int) -> [Int] {
        guard teamCount > 0 else { return [] }
        return Array(stride(
            from: firstAdAfterTeamPosition,
            through: teamCount,
            by: recurringInterval
        ))
    }

    static func nativeAdSlots(for teamCount: Int) -> [ChatMyTeamsNativeAdSlot] {
        insertionPositions(for: teamCount).enumerated().map { index, position in
            ChatMyTeamsNativeAdSlot(ordinal: index, insertedAfterTeamPosition: position)
        }
    }

    /// Team-id fingerprint — ignores name/sport/member-count churn that shouldn't remount ads.
    static func fingerprint(for teams: [FanTeamSummary]) -> String {
        teams.map { $0.id.uuidString.lowercased() }.joined(separator: "|")
    }

    static func listItems(for teams: [FanTeamSummary]) -> [ChatMyTeamsListItem] {
        guard FanGeoAdPolicy.shouldInsertAdsInFeeds() else {
            return teams.map { .team($0) }
        }
        let fp = fingerprint(for: teams)
        let positions: [Int]
        if fp == cachedFingerprint, let cachedPositions {
            positions = cachedPositions
        } else {
            positions = insertionPositions(for: teams.count)
            cachedFingerprint = fp
            cachedPositions = positions
        }

        guard !positions.isEmpty else {
            return teams.map { .team($0) }
        }

        let slots = positions.enumerated().map { index, position in
            ChatMyTeamsNativeAdSlot(ordinal: index, insertedAfterTeamPosition: position)
        }
        let slotsByPosition = Dictionary(uniqueKeysWithValues: slots.map {
            ($0.insertedAfterTeamPosition, $0)
        })

        // Always rebuild team rows from current summaries so identity updates stay live;
        // stable ad slot ids prevent unnecessary CompactNativeAdCard remounts.
        var items: [ChatMyTeamsListItem] = []
        items.reserveCapacity(teams.count + slots.count)

        for (index, team) in teams.enumerated() {
            items.append(.team(team))
            if let slot = slotsByPosition[index + 1] {
                items.append(.nativeAd(slot))
            }
        }
        return items
    }

#if DEBUG
    /// Returns true once per meaningful fingerprint change (for ad diagnostics).
    static func shouldLogDiagnostics(for teams: [FanTeamSummary]) -> Bool {
        let fp = fingerprint(for: teams)
        guard fp != lastLoggedFingerprint else { return false }
        lastLoggedFingerprint = fp
        return true
    }

    /// Clears placement cache (self-tests only).
    static func resetCacheForTesting() {
        cachedFingerprint = nil
        cachedPositions = nil
        lastLoggedFingerprint = nil
    }
#endif
}

import Foundation
import Supabase

/// Fan XP source identifiers. Amounts are authoritative on the server (`fan_xp_amount_for_source` / `claim_fan_xp`).
enum FanXPSource {
    static let favoriteVenue = "favorite_venue"
    static let venueEventInterest = "venue_event_interest"
    static let pickupCreate = "pickup_create"
    static let pickupJoinApproved = "pickup_join_approved"
    static let pickupComplete = "pickup_complete"
    static let friendConnected = "friend_connected"
    static let teamCreated = "team_created"
    static let teamJoinPlayer = "team_join_player"
    static let teamEventCreated = "team_event_created"
    static let teamEventCompletedPlayer = "team_event_completed_player"
    static let teamEventCompletedOrganizer = "team_event_completed_organizer"

    /// Server-authoritative amounts (must match `public.fan_xp_amount_for_source`).
    static func expectedAmount(for source: String) -> Int {
        switch source {
        case favoriteVenue: return 2
        case venueEventInterest: return 5
        case pickupCreate: return 20
        case pickupJoinApproved: return 10
        case pickupComplete: return 15
        case friendConnected: return 5
        case teamCreated: return 20
        case teamJoinPlayer: return 10
        case teamEventCreated: return 5
        case teamEventCompletedPlayer: return 10
        case teamEventCompletedOrganizer: return 15
        default: return 0
        }
    }

    static func rewardSubtitle(for source: String) -> String {
        switch source {
        case favoriteVenue: return "Venue Saved"
        case venueEventInterest: return "Game Plan Updated"
        case pickupCreate: return "Pickup Created"
        case pickupJoinApproved: return "Pickup Joined"
        case pickupComplete: return "Pickup Completed"
        case friendConnected: return "Friend Connected"
        case teamCreated: return "Team Created"
        case teamJoinPlayer: return "Joined Team"
        case teamEventCreated: return "Team Event Created"
        case teamEventCompletedPlayer: return "Team Event Played"
        case teamEventCompletedOrganizer: return "Team Event Organized"
        default: return "Fan Activity"
        }
    }

    /// Legacy plain string (social toast); prefer ``FanXPRewardOverlayManager``.
    static func toastLabel(for source: String, amount: Int) -> String {
        "Reputation noted · \(rewardSubtitle(for: source))"
    }
}

/// Server-mirrored anti-farming + join-transition policy (`20260996`).
enum FanXPTeamAwardPolicy {
    /// First N `team_created` awards per account. Further Teams can still be created.
    static let teamCreatedLifetimeCap = 5
    /// Max `team_event_created` awards per account per UTC day.
    static let teamEventCreatedDailyCap = 8
    /// No historical backfill for seats that were already active players.
    static let backfillsExistingPlayers = false

    static func shouldAwardJoinPlayer(
        isInsert: Bool,
        wasEligibleAccountPlayer: Bool,
        isEligibleAccountPlayer: Bool,
        isManagedPlayerSeat: Bool
    ) -> Bool {
        if isManagedPlayerSeat { return false }
        if !isEligibleAccountPlayer { return false }
        if isInsert { return true }
        return !wasEligibleAccountPlayer
    }
}

struct FanXPAwardResult: Decodable {
    let awarded: Bool?
    let duplicate: Bool?
    let total_xp: Int?
    let level: Int?
    let title: String?
    let xp_gained: Int?
    let reason: String?
}

struct FanXPService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func loadUserXP(userId: UUID) async -> FanXPState {
        struct Row: Decodable {
            let total_xp: Int
            let level: Int
            let title: String
        }

        do {
            let rows: [Row] = try await client
                .from("user_xp")
                .select("total_xp,level,title")
                .eq("user_id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let row = rows.first {
                return FanXPState(
                    totalXP: row.total_xp,
                    level: row.level,
                    title: row.title
                )
            }
        } catch {
#if DEBUG
            print("[FanXPDebug] loadUserXP failed userId=\(userId.uuidString) error=\(error.localizedDescription)")
#endif
        }

        _ = try? await client.rpc("ensure_user_xp_row", params: EnsureRowParams(p_user_id: userId)).execute()
        return .rookie
    }

    /// Claims XP for a verified action. Server validates evidence and determines the amount.
    /// Does not accept a client-chosen XP amount or arbitrary target user id.
    @discardableResult
    func claimXP(
        source: String,
        sourceId: UUID
    ) async -> FanXPAwardResult? {
#if DEBUG
        print("[FanXPDebug] claimRequested source=\(source) sourceId=\(sourceId.uuidString)")
#endif

        struct Params: Encodable {
            let p_source: String
            let p_source_id: UUID
        }

        do {
            let result: FanXPAwardResult = try await client
                .rpc(
                    "claim_fan_xp",
                    params: Params(
                        p_source: source,
                        p_source_id: sourceId
                    )
                )
                .execute()
                .value

            if result.duplicate == true || result.awarded == false {
#if DEBUG
                print("[FanXPDebug] claimSkipped source=\(source) reason=\(result.reason ?? "duplicate_or_rejected") totalXP=\(result.total_xp ?? -1)")
#endif
            } else if result.awarded == true {
#if DEBUG
                print("[FanXPDebug] xpAwarded source=\(source) gained=\(result.xp_gained ?? FanXPSource.expectedAmount(for: source))")
                print("[FanXPDebug] totalXP=\(result.total_xp ?? -1)")
                print("[FanXPDebug] level=\(result.level ?? -1)")
                print("[FanXPDebug] title=\(result.title ?? "")")
#endif
            }
            return result
        } catch {
#if DEBUG
            print("[FanXPDebug] claimFailed source=\(source) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private struct EnsureRowParams: Encodable {
        let p_user_id: UUID
    }
}

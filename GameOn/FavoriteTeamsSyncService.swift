import Foundation
import Supabase

/// Supabase sync for shareable favorite teams (`user_favorite_teams`).
enum FavoriteTeamsSyncService {
    private static let table = "user_favorite_teams"

    struct TeamRow: Decodable {
        let team_id: String
        let created_at: String?
        let is_primary: Bool?
    }

    struct TeamInsert: Encodable {
        let user_id: UUID
        let team_id: String
        let is_primary: Bool
    }

    struct FavoriteTeamSelection {
        let teamIDs: [String]
        let primaryTeamID: String?
    }

    enum FetchResult {
        case success(FavoriteTeamSelection)
        case failure(Error)
    }

    /// Loads catalog-valid team IDs for a user (any authenticated reader).
    static func fetchTeamIDs(userId: UUID) async -> [String] {
        switch await fetchTeamSelectionResult(userId: userId) {
        case .success(let selection):
            return selection.teamIDs
        case .failure:
            return []
        }
    }

    /// Loads catalog-valid team IDs plus the single primary Trophy Team if present.
    static func fetchTeamSelection(userId: UUID) async -> FavoriteTeamSelection {
        switch await fetchTeamSelectionResult(userId: userId) {
        case .success(let selection):
            return selection
        case .failure:
            return FavoriteTeamSelection(teamIDs: [], primaryTeamID: nil)
        }
    }

    /// Same as ``fetchTeamSelection`` but preserves fetch failures so callers do not treat errors as empty selections.
    static func fetchTeamSelectionResult(userId: UUID) async -> FetchResult {
        do {
            let rows: [TeamRow] = try await supabase
                .from(table)
                .select("team_id,created_at,is_primary")
                .eq("user_id", value: userId.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value

            let ids = FavoriteTeamsStore.uniquedIDs(
                rows
                    .map(\.team_id)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .filter { FavoriteTeamCatalog.team(id: $0) != nil }
            )
            let primary = rows
                .first { $0.is_primary == true && ids.contains($0.team_id) }?
                .team_id

#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] fetch userId=\(userId.uuidString.lowercased()) raw=\(rows.count) valid=\(ids.count)"
            )
            print("[FavoriteTeamsHydration] rows returned authUserId=\(userId.uuidString.lowercased()) raw=\(rows.count) valid=\(ids.count)")
#endif
            return .success(FavoriteTeamSelection(teamIDs: ids, primaryTeamID: primary))
        } catch {
#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] fetch_failed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
#endif
            switch await fetchLegacyTeamSelectionResult(userId: userId) {
            case .success(let selection):
                return .success(selection)
            case .failure(let legacyError):
                return .failure(legacyError)
            }
        }
    }

    /// Replaces the current user's favorite teams with the given catalog IDs.
    static func replaceTeamIDs(userId: UUID, teamIDs: [String]) async -> Bool {
        await replaceTeamSelection(userId: userId, teamIDs: teamIDs, primaryTeamID: nil)
    }

    /// Replaces favorite teams while marking one row as the primary Trophy Team.
    static func replaceTeamSelection(userId: UUID, teamIDs: [String], primaryTeamID: String?) async -> Bool {
        let valid = FavoriteTeamsStore.uniquedIDs(teamIDs)
            .filter { FavoriteTeamCatalog.team(id: $0) != nil }
        let primary = FavoriteTeamsStore.normalizedPrimaryTeamID(primaryTeamID, within: valid)

#if DEBUG
        print(
            "[FavoriteTeamsSyncDebug] replace_start userId=\(userId.uuidString.lowercased()) count=\(valid.count)"
        )
#endif

        do {
            try await supabase
                .from(table)
                .delete()
                .eq("user_id", value: userId.uuidString.lowercased())
                .execute()

            if !valid.isEmpty {
                let payload = valid.map { TeamInsert(user_id: userId, team_id: $0, is_primary: $0 == primary) }
                try await supabase
                    .from(table)
                    .insert(payload)
                    .execute()
            }

#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] replace_success userId=\(userId.uuidString.lowercased()) count=\(valid.count)"
            )
#endif
            return true
        } catch {
#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] replace_failed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
#endif
            return await replaceLegacyTeamIDs(userId: userId, teamIDs: valid)
        }
    }

    private static func fetchLegacyTeamSelectionResult(userId: UUID) async -> FetchResult {
        do {
            struct LegacyTeamRow: Decodable {
                let team_id: String
                let created_at: String?
            }
            let rows: [LegacyTeamRow] = try await supabase
                .from(table)
                .select("team_id,created_at")
                .eq("user_id", value: userId.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value
            let ids = FavoriteTeamsStore.uniquedIDs(
                rows
                    .map(\.team_id)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .filter { FavoriteTeamCatalog.team(id: $0) != nil }
            )
#if DEBUG
            print("[FavoriteTeamsHydration] rows returned authUserId=\(userId.uuidString.lowercased()) raw=\(rows.count) valid=\(ids.count) source=legacy")
#endif
            return .success(FavoriteTeamSelection(teamIDs: ids, primaryTeamID: nil))
        } catch {
            return .failure(error)
        }
    }

    private static func replaceLegacyTeamIDs(userId: UUID, teamIDs: [String]) async -> Bool {
        do {
            struct LegacyTeamInsert: Encodable {
                let user_id: UUID
                let team_id: String
            }
            try await supabase
                .from(table)
                .delete()
                .eq("user_id", value: userId.uuidString.lowercased())
                .execute()
            if !teamIDs.isEmpty {
                let payload = teamIDs.map { LegacyTeamInsert(user_id: userId, team_id: $0) }
                try await supabase
                    .from(table)
                    .insert(payload)
                    .execute()
            }
            return true
        } catch {
            return false
        }
    }
}

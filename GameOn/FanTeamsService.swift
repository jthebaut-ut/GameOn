import Foundation
import Supabase

final class FanTeamsService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    private static let isoFractional: ISO8601DateFormatter = {
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
        return isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    static func encodeDate(_ date: Date) -> String {
        isoFractional.string(from: date)
    }

    // MARK: - Rows

    private struct TeamListRow: Decodable {
        let team_id: UUID
        let name: String
        let sport: String?
        let logo_url: String?
        let logo_thumbnail_url: String?
        let color_hex: String?
        /// Present after 20260941; nil when older RPC is still deployed.
        let competition_level: String?
        let owner_user_id: UUID
        let group_conversation_id: UUID
        let my_role: String
        let member_count: Int
        /// Present after 20260930; nil when older RPC is still deployed.
        let pending_invitation_count: Int?
        /// Present after 20260943; nil/false when older RPC is still deployed.
        let push_notifications_muted: Bool?
        let next_game_starts_at: String?
        let next_game_title: String?
        let next_game_venue: String?
        let created_at: String?
        /// Present after 20260966; nil/empty when older RPC is still deployed.
        let member_avatar_previews: [MemberAvatarPreviewRow]?
        /// Present after 20260972; nil → treat as account seat (older RPC).
        let access_via: String?
        /// Present after 20260972; guardian's managed players on this Team.
        let via_managed_player_names: [String]?
        /// Present after 20260985; effective permission keys for the viewer.
        let my_permissions: [String]?

        private enum CodingKeys: String, CodingKey {
            case team_id, name, sport, logo_url, logo_thumbnail_url, color_hex
            case competition_level, owner_user_id, group_conversation_id, my_role
            case member_count, pending_invitation_count, push_notifications_muted
            case next_game_starts_at, next_game_title, next_game_venue, created_at
            case member_avatar_previews, access_via, via_managed_player_names, my_permissions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            team_id = try c.decode(UUID.self, forKey: .team_id)
            name = try c.decode(String.self, forKey: .name)
            sport = try c.decodeIfPresent(String.self, forKey: .sport)
            logo_url = try c.decodeIfPresent(String.self, forKey: .logo_url)
            logo_thumbnail_url = try c.decodeIfPresent(String.self, forKey: .logo_thumbnail_url)
            color_hex = try c.decodeIfPresent(String.self, forKey: .color_hex)
            competition_level = try c.decodeIfPresent(String.self, forKey: .competition_level)
            owner_user_id = try c.decode(UUID.self, forKey: .owner_user_id)
            group_conversation_id = try c.decode(UUID.self, forKey: .group_conversation_id)
            my_role = try c.decode(String.self, forKey: .my_role)
            if let intVal = try? c.decode(Int.self, forKey: .member_count) {
                member_count = intVal
            } else if let small = try? c.decode(Int16.self, forKey: .member_count) {
                member_count = Int(small)
            } else {
                member_count = try c.decode(Int.self, forKey: .member_count)
            }
            pending_invitation_count = try c.decodeIfPresent(Int.self, forKey: .pending_invitation_count)
            push_notifications_muted = try c.decodeIfPresent(Bool.self, forKey: .push_notifications_muted)
            next_game_starts_at = try c.decodeIfPresent(String.self, forKey: .next_game_starts_at)
            next_game_title = try c.decodeIfPresent(String.self, forKey: .next_game_title)
            next_game_venue = try c.decodeIfPresent(String.self, forKey: .next_game_venue)
            created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
            member_avatar_previews = try c.decodeIfPresent([MemberAvatarPreviewRow].self, forKey: .member_avatar_previews)
            access_via = try c.decodeIfPresent(String.self, forKey: .access_via)
            via_managed_player_names = Self.decodeStringArray(c, forKey: .via_managed_player_names)
            my_permissions = Self.decodeStringArray(c, forKey: .my_permissions)
        }

        /// PostgREST text[] normally arrives as a JSON array; tolerate empty/missing shapes.
        private static func decodeStringArray(
            _ c: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> [String]? {
            if let arr = try? c.decodeIfPresent([String].self, forKey: key) {
                return arr
            }
            if c.contains(key), (try? c.decodeNil(forKey: key)) == true {
                return nil
            }
            return nil
        }
    }

    private struct MemberAvatarPreviewRow: Decodable {
        let membership_id: UUID?
        let managed_player_id: UUID?
        let display_name: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let role: String?
        let is_managed_player: Bool?
    }

    private struct MemberRow: Decodable {
        /// Nil for guardian-managed players (they have no auth account).
        let user_id: UUID?
        let role: String
        let joined_at: String?
        let display_name: String?
        let username: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let last_seen_at: String?
        let player_number: Int?
        let gender: String?
        /// Present after 20260953; nil when older RPC is still deployed.
        let preferred_position_code: String?
        /// Present after 20260960; nil when older RPC is still deployed.
        let membership_id: UUID?
        let managed_player_id: UUID?
        let is_managed_player: Bool?
        /// Staff-only contact hint for a managed player.
        let guardian_display_name: String?
        /// Present after 20260984; nil → treat as player (backward compatible).
        let is_player: Bool?
        /// Present after 20260985.
        let use_custom_permissions: Bool?
        let granted_permissions: [String]?
        let effective_permissions: [String]?

        private enum CodingKeys: String, CodingKey {
            case user_id
            case role
            case joined_at
            case display_name
            case username
            case avatar_url
            case avatar_thumbnail_url
            case last_seen_at
            case player_number
            case gender
            case preferred_position_code
            case membership_id
            case managed_player_id
            case is_managed_player
            case guardian_display_name
            case is_player
            case use_custom_permissions
            case granted_permissions
            case effective_permissions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            user_id = try c.decodeIfPresent(UUID.self, forKey: .user_id)
            role = try c.decode(String.self, forKey: .role)
            joined_at = try c.decodeIfPresent(String.self, forKey: .joined_at)
            display_name = try c.decodeIfPresent(String.self, forKey: .display_name)
            username = try c.decodeIfPresent(String.self, forKey: .username)
            avatar_url = try c.decodeIfPresent(String.self, forKey: .avatar_url)
            avatar_thumbnail_url = try c.decodeIfPresent(String.self, forKey: .avatar_thumbnail_url)
            last_seen_at = try c.decodeIfPresent(String.self, forKey: .last_seen_at)
            if let intVal = try? c.decodeIfPresent(Int.self, forKey: .player_number) {
                player_number = intVal
            } else if let small = try? c.decodeIfPresent(Int16.self, forKey: .player_number) {
                player_number = Int(small)
            } else {
                player_number = nil
            }
            gender = try c.decodeIfPresent(String.self, forKey: .gender)
            preferred_position_code = try c.decodeIfPresent(String.self, forKey: .preferred_position_code)
            membership_id = try c.decodeIfPresent(UUID.self, forKey: .membership_id)
            managed_player_id = try c.decodeIfPresent(UUID.self, forKey: .managed_player_id)
            is_managed_player = try c.decodeIfPresent(Bool.self, forKey: .is_managed_player)
            guardian_display_name = try c.decodeIfPresent(String.self, forKey: .guardian_display_name)
            is_player = try c.decodeIfPresent(Bool.self, forKey: .is_player)
            use_custom_permissions = try c.decodeIfPresent(Bool.self, forKey: .use_custom_permissions)
            granted_permissions = Self.decodeStringArray(c, forKey: .granted_permissions)
            effective_permissions = Self.decodeStringArray(c, forKey: .effective_permissions)
        }

        private static func decodeStringArray(
            _ c: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> [String]? {
            if let arr = try? c.decodeIfPresent([String].self, forKey: key) {
                return arr
            }
            if c.contains(key), (try? c.decodeNil(forKey: key)) == true {
                return nil
            }
            return nil
        }
    }

    private struct GameRow: Decodable {
        let id: UUID
        let team_id: UUID
        let created_by: UUID
        let game_type: String
        let sport: String?
        let title: String?
        let starts_at: String
        let ends_at: String?
        let venue_name: String?
        let address: String?
        let city: String?
        let state: String?
        let latitude: Double?
        let longitude: Double?
        let opponent_team_id: UUID?
        let opponent_name: String?
        let status: String
        let home_score: Int?
        let away_score: Int?
        let pickup_game_id: UUID?
        let my_side: String?
        /// Present after `list_fan_team_games` includes `created_at` (optional for older RPCs).
        let created_at: String?
        /// Present after `list_fan_team_games` includes `competition_level`.
        let competition_level: String?
        /// Present after `list_fan_team_games` includes `description` (announcements).
        let description: String?
        let scoring_status: String?
        let scoring_finalized_at: String?

        private enum CodingKeys: String, CodingKey {
            case id, team_id, created_by, game_type, sport, title
            case starts_at, ends_at, venue_name, address, city, state
            case latitude, longitude, opponent_team_id, opponent_name, status
            case home_score, away_score, pickup_game_id, my_side
            case created_at, competition_level, description
            case scoring_status, scoring_finalized_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            team_id = try c.decode(UUID.self, forKey: .team_id)
            created_by = try c.decode(UUID.self, forKey: .created_by)
            game_type = try c.decode(String.self, forKey: .game_type)
            sport = try c.decodeIfPresent(String.self, forKey: .sport)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            // Required for mapping; skip-tolerant callers use per-row decode.
            starts_at = try c.decode(String.self, forKey: .starts_at)
            ends_at = try c.decodeIfPresent(String.self, forKey: .ends_at)
            venue_name = try c.decodeIfPresent(String.self, forKey: .venue_name)
            address = try c.decodeIfPresent(String.self, forKey: .address)
            city = try c.decodeIfPresent(String.self, forKey: .city)
            state = try c.decodeIfPresent(String.self, forKey: .state)
            latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
            opponent_team_id = try c.decodeIfPresent(UUID.self, forKey: .opponent_team_id)
            opponent_name = try c.decodeIfPresent(String.self, forKey: .opponent_name)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "scheduled"
            home_score = try c.decodeIfPresent(Int.self, forKey: .home_score)
            away_score = try c.decodeIfPresent(Int.self, forKey: .away_score)
            pickup_game_id = try c.decodeIfPresent(UUID.self, forKey: .pickup_game_id)
            my_side = try c.decodeIfPresent(String.self, forKey: .my_side)
            created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
            competition_level = try c.decodeIfPresent(String.self, forKey: .competition_level)
            // Additive field — older RPCs without `description` still decode.
            description = try c.decodeIfPresent(String.self, forKey: .description)
            scoring_status = try c.decodeIfPresent(String.self, forKey: .scoring_status)
            scoring_finalized_at = try c.decodeIfPresent(String.self, forKey: .scoring_finalized_at)
        }
    }

    private struct MyInvitationRow: Decodable {
        let invitation_id: UUID
        let team_id: UUID
        let team_name: String
        let sport: String?
        let logo_url: String?
        let logo_thumbnail_url: String?
        let color_hex: String?
        let member_count: Int
        let inviter_user_id: UUID
        let inviter_display_name: String?
        let inviter_username: String?
        let created_at: String?
        let expires_at: String?
    }

    private struct TeamPendingInvitationRow: Decodable {
        let invitation_id: UUID
        let invitee_user_id: UUID
        let invitee_display_name: String?
        let invitee_username: String?
        let invitee_avatar_url: String?
        let invitee_avatar_thumbnail_url: String?
        let inviter_user_id: UUID
        let created_at: String?
        let expires_at: String?
    }

    func listMyTeams() async throws -> [FanTeamSummary] {
        let client = self.client
        let result = try await MyTeamsInFlightCoalescer.run {
            try await FanTeamsService.listMyTeamsUncached(client: client)
        }
        return result.teams
    }

    private static func listMyTeamsUncached(client: SupabaseClient) async throws -> [FanTeamSummary] {
        let started = Date()
        var hasSession = false
        var hasAuthUser = false
        do {
            _ = try await client.auth.session
            hasSession = true
            hasAuthUser = true
        } catch {
            let cancelled = FanTeamsLoadErrorPresentation.isCancellation(error)
            MyTeamsRefreshDebug.log(
                phase: cancelled ? "auth.cancelled" : "auth.unavailable",
                hasAuthUser: false,
                hasSession: false,
                sessionState: cancelled ? "cancelled" : "missing",
                isCancellation: cancelled,
                elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
            )
            throw error
        }

        MyTeamsRefreshDebug.log(
            phase: "rpc.start",
            hasAuthUser: hasAuthUser,
            hasSession: hasSession,
            sessionState: "present",
            coalesced: false,
            inFlightAlready: await MyTeamsInFlightCoalescer.hasInFlight()
        )

        do {
            let response = try await client
                .rpc("list_my_fan_teams")
                .execute()
            FanTeamRPCTrace.log(
                step: "B.list_my_fan_teams.http",
                rpc: "list_my_fan_teams",
                status: response.status,
                body: response.data
            )
            let rows: [TeamListRow]
            do {
                rows = try JSONDecoder().decode([TeamListRow].self, from: response.data)
            } catch {
                FanTeamRPCTrace.log(
                    step: "E.decode",
                    rpc: "list_my_fan_teams",
                    status: response.status,
                    body: response.data,
                    error: error
                )
                throw FanTeamLayeredError(
                    layer: .decoding,
                    underlying: error,
                    httpStatus: response.status,
                    responseBody: Self.utf8Body(response.data),
                    mutationCommitted: nil
                )
            }
            let summaries = rows.map { row in
                let role = FanTeamMemberRole.parse(row.my_role)
                let accessVia = FanTeamListAccessVia.resolved(row.access_via)
                let viaNames = FanTeamHomeCatalog.uniquePreservingOrder(row.via_managed_player_names ?? [])
                let pendingCount = (accessVia == .account && role.canManageTeam)
                    ? max(0, row.pending_invitation_count ?? 0)
                    : 0
                let previews = (row.member_avatar_previews ?? []).compactMap { preview -> FanTeamMemberAvatarPreview? in
                    guard let membershipId = preview.membership_id else { return nil }
                    let name = (preview.display_name ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return FanTeamMemberAvatarPreview(
                        membershipId: membershipId,
                        managedPlayerId: preview.managed_player_id,
                        displayName: name.isEmpty
                            ? (preview.is_managed_player == true ? "Player" : "Fan")
                            : name,
                        avatarURL: ImageDisplayURL.canonicalStorageURLString(preview.avatar_url).nilIfEmpty,
                        avatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(preview.avatar_thumbnail_url).nilIfEmpty,
                        role: FanTeamMemberRole.parse(preview.role),
                        isManagedPlayer: preview.is_managed_player ?? false
                    )
                }
                let summary = FanTeamSummary(
                    id: row.team_id,
                    name: row.name,
                    sport: row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    logoURL: ImageDisplayURL.canonicalStorageURLString(row.logo_url).nilIfEmpty,
                    logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(row.logo_thumbnail_url).nilIfEmpty,
                    colorHex: row.color_hex,
                    competitionLevel: PickupCompetitionLevel.parse(row.competition_level),
                    ownerUserId: row.owner_user_id,
                    groupConversationId: row.group_conversation_id,
                    myRole: role,
                    memberCount: max(0, row.member_count),
                    pendingInvitationCount: pendingCount,
                    pushNotificationsMuted: accessVia == .account
                        ? (row.push_notifications_muted ?? false)
                        : false,
                    nextGameStartsAt: Self.parseDate(row.next_game_starts_at),
                    nextGameTitle: row.next_game_title,
                    nextGameVenue: row.next_game_venue,
                    createdAt: Self.parseDate(row.created_at),
                    memberAvatarPreviews: previews,
                    accessVia: accessVia,
                    viaManagedPlayerNames: viaNames,
                    myPermissions: accessVia == .account
                        ? row.my_permissions.map { FanTeamPermissionSet(rawValues: $0) }
                        : .empty
                )
#if DEBUG
                ManagedPlayerTeamAccessDebug.log(
                    "teamAccessDecision",
                    detail: "teamID=\(summary.id.uuidString.lowercased()) accessReason=\(accessVia == .account ? "direct_member" : "managed_player") viaNames=\(viaNames.joined(separator: ","))"
                )
#endif
                return summary
            }
            MyTeamsRefreshDebug.log(
                phase: "rpc.success",
                hasAuthUser: hasAuthUser,
                hasSession: hasSession,
                sessionState: "present",
                httpStatus: response.status,
                elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
            )
            return summaries
        } catch let layered as FanTeamLayeredError {
            MyTeamsRefreshDebug.log(
                phase: FanTeamsLoadErrorPresentation.isCancellation(layered) ? "rpc.cancelled" : "rpc.failed",
                hasAuthUser: hasAuthUser,
                hasSession: hasSession,
                httpStatus: layered.httpStatus,
                message: FanTeamsLoadErrorPresentation.debugDescription(layered),
                isCancellation: FanTeamsLoadErrorPresentation.isCancellation(layered),
                elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
            )
            throw layered
        } catch {
            let cancelled = FanTeamsLoadErrorPresentation.isCancellation(error)
            MyTeamsRefreshDebug.log(
                phase: cancelled ? "rpc.cancelled" : "rpc.failed",
                hasAuthUser: hasAuthUser,
                hasSession: hasSession,
                httpStatus: FanTeamRPCTrace.httpStatus(from: error),
                supabaseCode: (error as? PostgrestError)?.code,
                message: FanTeamsLoadErrorPresentation.debugDescription(error),
                isCancellation: cancelled,
                elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
            )
            FanTeamRPCTrace.log(
                step: "B.list_my_fan_teams.failed",
                rpc: "list_my_fan_teams",
                error: error,
                extra: "phase=afterMutationPossible cancelled=\(cancelled)"
            )
            if cancelled { throw error }
            throw FanTeamLayeredError(
                layer: .teamsReload,
                underlying: error,
                httpStatus: FanTeamRPCTrace.httpStatus(from: error),
                responseBody: FanTeamRPCTrace.responseBody(from: error),
                mutationCommitted: nil
            )
        }
    }

    /// Lightweight `fan_teams` hydration for guardian-only My Teams home cards.
    /// Fail-soft: missing/unauthorized rows are omitted (caller keeps membership fallback).
    func hydrateGuardianHomeTeams(teamIds: [UUID]) async -> [UUID: FanTeamGuardianHomeHydration] {
        let uniqueIds = Array(Set(teamIds))
        guard !uniqueIds.isEmpty else { return [:] }

        struct TeamRow: Decodable {
            let id: UUID
            let name: String
            let sport: String?
            let logo_url: String?
            let logo_thumbnail_url: String?
            let color_hex: String?
            let competition_level: String?
            let owner_user_id: UUID
            let group_conversation_id: UUID
            let created_at: String?
        }

        do {
            let rows: [TeamRow] = try await client
                .from("fan_teams")
                .select(
                    "id,name,sport,logo_url,logo_thumbnail_url,color_hex,competition_level,owner_user_id,group_conversation_id,created_at"
                )
                .in("id", values: uniqueIds.map { $0.uuidString.lowercased() })
                .eq("is_active", value: true)
                .execute()
                .value

            struct SeatRow: Decodable { let team_id: UUID }
            var memberCounts: [UUID: Int] = [:]
            if let seats: [SeatRow] = try? await client
                .from("fan_team_members")
                .select("team_id")
                .in("team_id", values: rows.map { $0.id.uuidString.lowercased() })
                .is("left_at", value: nil)
                .execute()
                .value {
                for seat in seats {
                    memberCounts[seat.team_id, default: 0] += 1
                }
            }

            var result: [UUID: FanTeamGuardianHomeHydration] = [:]
            for row in rows {
                result[row.id] = FanTeamGuardianHomeHydration(
                    name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    sport: row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    logoURL: ImageDisplayURL.canonicalStorageURLString(row.logo_url).nilIfEmpty,
                    logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(row.logo_thumbnail_url).nilIfEmpty,
                    colorHex: row.color_hex,
                    competitionLevel: PickupCompetitionLevel.parse(row.competition_level),
                    ownerUserId: row.owner_user_id,
                    groupConversationId: row.group_conversation_id,
                    memberCount: max(0, memberCounts[row.id] ?? 0),
                    nextGameStartsAt: nil,
                    nextGameTitle: nil,
                    nextGameVenue: nil,
                    createdAt: Self.parseDate(row.created_at),
                    memberAvatarPreviews: []
                )
            }
            return result
        } catch {
#if DEBUG
            print("[FanTeamsHome] guardian_hydrate_failed error=\(error.localizedDescription)")
#endif
            return [:]
        }
    }

    /// Sets the caller’s per-Team push mute (active membership required).
    @discardableResult
    func setNotificationMuted(teamId: UUID, muted: Bool) async throws -> Bool {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_muted: Bool
        }
        let result: Bool = try await client
            .rpc(
                "set_fan_team_notification_muted",
                params: Params(p_team_id: teamId, p_muted: muted)
            )
            .execute()
            .value
        return result
    }

    /// Creates a Team. Selected `memberIds` are invited (pending), not auto-joined.
    /// Logo URLs are always `nil` here: Storage paths require `team_id`. Callers that
    /// collect a photo at Create time must stage locally, then after this RPC returns:
    /// `uploadTeamLogo` → `updateTeamIdentity` (same Owner/Manager pipeline as Edit Team).
    func createTeam(
        name: String,
        sport: String,
        memberIds: [UUID],
        colorHex: String? = nil,
        competitionLevel: PickupCompetitionLevel? = nil
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_name: String
            let p_sport: String
            let p_member_ids: [UUID]
            let p_color_hex: String?
            let p_logo_url: String?
            let p_logo_thumbnail_url: String?
            let p_competition_level: String?
        }
        let params = Params(
            p_name: name,
            p_sport: sport,
            p_member_ids: memberIds,
            p_color_hex: colorHex,
            p_logo_url: nil,
            p_logo_thumbnail_url: nil,
            p_competition_level: competitionLevel?.rawValue
        )
        let id: UUID = try await client
            .rpc("create_fan_team", params: params)
            .execute()
            .value
        return id
    }

    func listMembers(teamId: UUID) async throws -> [FanTeamMember] {
        struct Params: Encodable { let p_team_id: UUID }
        do {
            let response = try await client
                .rpc("list_fan_team_members", params: Params(p_team_id: teamId))
                .execute()
            FanTeamRPCTrace.log(
                step: "C.list_fan_team_members.http",
                rpc: "list_fan_team_members",
                status: response.status,
                body: response.data,
                extra: "team=\(teamId.uuidString.lowercased())"
            )
            let rows: [MemberRow]
            do {
                rows = try JSONDecoder().decode([MemberRow].self, from: response.data)
            } catch {
                FanTeamRPCTrace.log(
                    step: "E.decode",
                    rpc: "list_fan_team_members",
                    status: response.status,
                    body: response.data,
                    error: error
                )
                throw FanTeamLayeredError(
                    layer: .teamDetailMembers,
                    underlying: error,
                    httpStatus: response.status,
                    responseBody: Self.utf8Body(response.data),
                    mutationCommitted: nil
                )
            }
            let mapped = rows.compactMap { row -> FanTeamMember? in
                // Pre-20260960 payloads have no membership_id; user_id was the row
                // identity then, and a row without either identity is unusable.
                guard let membershipId = row.membership_id ?? row.user_id else { return nil }
                return FanTeamMember(
                    membershipId: membershipId,
                    userId: row.user_id,
                    managedPlayerId: row.managed_player_id,
                    role: FanTeamMemberRole.parse(row.role),
                    joinedAt: Self.parseDate(row.joined_at),
                    displayName: (row.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Fan",
                    username: row.username,
                    avatarURL: ImageDisplayURL.canonicalStorageURLString(row.avatar_url).nilIfEmpty,
                    avatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(row.avatar_thumbnail_url).nilIfEmpty,
                    lastSeenAtRaw: row.last_seen_at,
                    playerNumber: FanTeamPlayerNumber.isValid(row.player_number) ? row.player_number : nil,
                    preferredPositionCode: row.preferred_position_code,
                    genderRaw: row.gender,
                    isPlayer: row.is_player ?? true,
                    useCustomPermissions: row.use_custom_permissions ?? false,
                    grantedPermissions: FanTeamPermissionSet(rawValues: row.granted_permissions),
                    effectivePermissions: row.effective_permissions.map { FanTeamPermissionSet(rawValues: $0) }
                )
            }
            FanTeamRosterSnapshotCache.store(mapped, for: teamId)
            return mapped
        } catch let layered as FanTeamLayeredError {
            throw layered
        } catch {
            FanTeamRPCTrace.log(
                step: "C.list_fan_team_members.failed",
                rpc: "list_fan_team_members",
                error: error,
                extra: "team=\(teamId.uuidString.lowercased())"
            )
            throw FanTeamLayeredError(
                layer: .teamDetailMembers,
                underlying: error,
                httpStatus: FanTeamRPCTrace.httpStatus(from: error),
                responseBody: FanTeamRPCTrace.responseBody(from: error),
                mutationCommitted: nil
            )
        }
    }

    /// Owner-only: set custom permissions for an account seat (20260985).
    @discardableResult
    func setMemberPermissions(
        teamId: UUID,
        membershipId: UUID,
        permissions: FanTeamPermissionSet
    ) async throws -> FanTeamPermissionSet {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_membership_id: UUID
            let p_permissions: [String]
        }
        let keys: [String] = try await client
            .rpc(
                "set_fan_team_member_permissions",
                params: Params(
                    p_team_id: teamId,
                    p_membership_id: membershipId,
                    p_permissions: permissions.rawValues
                )
            )
            .execute()
            .value
        return FanTeamPermissionSet(rawValues: keys)
    }

    /// Toggle whether the caller's account seat is a *player* without leaving the Team.
    /// Requires 20260984 (`set_my_fan_team_is_player`). Access/role/chat are preserved.
    ///
    /// Canonical client path (the only caller is Team Player Membership → Myself).
    /// Do **not** decode via `.value as Bool`. HTTP 2xx + JSON `false` / `[false]` /
    /// `"false"` / empty body is success (demotion). `false` is never mutation failure.
    @discardableResult
    func setMyPlayerParticipation(teamId: UUID, isPlayer: Bool) async throws -> Bool {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_is_player: Bool
        }
        FanTeamRPCTrace.log(
            step: "A.mutation.start",
            rpc: "set_my_fan_team_is_player",
            extra: "requestedIsPlayer=\(isPlayer) team=\(teamId.uuidString.lowercased()) phase=beforeMutation"
        )
        do {
            // Void execute: 2xx must not decode the body as Bool (false is success).
            let response = try await client
                .rpc(
                    "set_my_fan_team_is_player",
                    params: Params(p_team_id: teamId, p_is_player: isPlayer)
                )
                .execute()
            FanTeamRPCTrace.log(
                step: "A.mutation.http",
                rpc: "set_my_fan_team_is_player",
                status: response.status,
                body: response.data,
                extra: "requestedIsPlayer=\(isPlayer) mutationCommitted=YES phase=afterMutation"
            )
            let decoded: Bool
            do {
                decoded = try FanTeamRPCScalarBool.decode(
                    from: response.data,
                    fallbackIfEmpty: isPlayer
                )
            } catch {
                FanTeamRPCTrace.log(
                    step: "E.decode",
                    rpc: "set_my_fan_team_is_player",
                    status: response.status,
                    body: response.data,
                    error: error,
                    extra: "2xx decode miss → treat as requested value mutationCommitted=YES"
                )
                // Mutation already committed on 2xx; do not fail the sheet.
                if (200 ..< 300).contains(response.status) {
                    return isPlayer
                }
                throw FanTeamLayeredError(
                    layer: .decoding,
                    underlying: error,
                    httpStatus: response.status,
                    responseBody: Self.utf8Body(response.data),
                    mutationCommitted: false
                )
            }
            FanTeamRPCTrace.log(
                step: "A.mutation.decoded",
                rpc: "set_my_fan_team_is_player",
                status: response.status,
                extra: "decoded=\(decoded) requested=\(isPlayer) (false=access-only success, not failure)"
            )
            return decoded
        } catch let layered as FanTeamLayeredError {
            throw layered
        } catch {
            if let http = error as? HTTPError, (200 ..< 300).contains(http.response.statusCode) {
                let decoded = (try? FanTeamRPCScalarBool.decode(
                    from: http.data,
                    fallbackIfEmpty: isPlayer
                )) ?? isPlayer
                FanTeamRPCTrace.log(
                    step: "A.mutation.http2xxThrown",
                    rpc: "set_my_fan_team_is_player",
                    status: http.response.statusCode,
                    body: http.data,
                    extra: "treatedAsSuccess decoded=\(decoded) mutationCommitted=YES"
                )
                return decoded
            }
            let pe = error as? PostgrestError
            let isAllowlistReject = (pe?.code == "22023")
                || (pe?.message.lowercased().contains("rate limit rejected") == true)
                || error.localizedDescription.lowercased().contains("rate limit rejected")
            FanTeamRPCTrace.log(
                step: "A.mutation.failed",
                rpc: "set_my_fan_team_is_player",
                error: error,
                extra: "mutationCommitted=NO phase=duringMutation requestedIsPlayer=\(isPlayer) " +
                    "httpStatus=\(FanTeamRPCTrace.httpStatus(from: error).map(String.init) ?? "nil") " +
                    "postgrestCode=\(pe?.code ?? "nil") " +
                    "postgrestMessage=\(pe?.message ?? error.localizedDescription) " +
                    "postgrestDetail=\(pe?.detail ?? "nil") " +
                    "postgrestHint=\(pe?.hint ?? "nil") " +
                    (isAllowlistReject
                        ? "rootCause=assert_rpc_rate_limit_unknown_bucket_set_my_fan_team_is_player"
                        : "rootCause=see_postgrest")
            )
            throw FanTeamLayeredError(
                layer: .membershipUpdate,
                underlying: error,
                httpStatus: FanTeamRPCTrace.httpStatus(from: error),
                responseBody: FanTeamRPCTrace.responseBody(from: error),
                mutationCommitted: false
            )
        }
    }

    /// DEBUG/reconciliation helper: account seat after Myself toggle (does not throw to UI).
    func traceAccountSeatAfterMyselfToggle(teamId: UUID, expectedIsPlayer: Bool) async {
        do {
            let members = try await listMembers(teamId: teamId)
            guard let me = try? await client.auth.session.user.id else {
                FanTeamRPCTrace.log(
                    step: "A.verify.noAuth",
                    rpc: "list_fan_team_members",
                    extra: "cannot resolve auth.uid() after set_my_fan_team_is_player"
                )
                return
            }
            if let seat = members.first(where: { $0.userId == me }) {
                FanTeamRPCTrace.log(
                    step: "A.verify.row",
                    rpc: "list_fan_team_members",
                    extra: "rowExists=YES is_player=\(seat.isPlayer) role=\(seat.role.rawValue) " +
                        "left_at=NULL user_id=\(me.uuidString.lowercased()) " +
                        "expectedIsPlayer=\(expectedIsPlayer) " +
                        "matchesExpected=\(seat.isPlayer == expectedIsPlayer)"
                )
            } else {
                FanTeamRPCTrace.log(
                    step: "A.verify.row",
                    rpc: "list_fan_team_members",
                    extra: "rowExists=NO (missing account seat after toggle — unexpected)"
                )
            }
        } catch {
            FanTeamRPCTrace.log(
                step: "A.verify.failed",
                rpc: "list_fan_team_members",
                error: error,
                extra: "could not read fan_team_members after mutation"
            )
        }
    }

    fileprivate static func utf8Body(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
    }

#if DEBUG
    fileprivate static func logRPCPayload(_ rpc: String, data: Data, extra: String) {
        print("[FanTeamsLoad] \(rpc) \(extra) bytes=\(data.count) body=\(utf8Body(data))")
    }
#endif

    /// Sends pending invitations (same RPC signature; returns invitations created/resent).
    func addMembers(teamId: UUID, memberIds: [UUID]) async throws -> Int {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_member_ids: [UUID]
        }
        let count: Int = try await client
            .rpc("add_fan_team_members", params: Params(p_team_id: teamId, p_member_ids: memberIds))
            .execute()
            .value
        return count
    }

    func listMyPendingInvitations() async throws -> [FanTeamInvitation] {
        let rows: [MyInvitationRow] = try await client
            .rpc("list_my_pending_fan_team_invitations")
            .execute()
            .value
        return rows.map { row in
            FanTeamInvitation(
                invitationId: row.invitation_id,
                teamId: row.team_id,
                teamName: row.team_name,
                sport: row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                logoURL: ImageDisplayURL.canonicalStorageURLString(row.logo_url).nilIfEmpty,
                logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(row.logo_thumbnail_url).nilIfEmpty,
                colorHex: row.color_hex,
                memberCount: max(0, row.member_count),
                inviterUserId: row.inviter_user_id,
                inviterDisplayName: (row.inviter_display_name?.trimmingCharacters(in: .whitespacesAndNewlines))
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "Fan",
                inviterUsername: row.inviter_username,
                createdAt: Self.parseDate(row.created_at),
                expiresAt: Self.parseDate(row.expires_at)
            )
        }
    }

    func listPendingInvitations(teamId: UUID) async throws -> [FanTeamPendingInvitation] {
        struct Params: Encodable { let p_team_id: UUID }
        let rows: [TeamPendingInvitationRow] = try await client
            .rpc("list_fan_team_pending_invitations", params: Params(p_team_id: teamId))
            .execute()
            .value
        return rows.map { row in
            FanTeamPendingInvitation(
                invitationId: row.invitation_id,
                inviteeUserId: row.invitee_user_id,
                inviteeDisplayName: (row.invitee_display_name?.trimmingCharacters(in: .whitespacesAndNewlines))
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "Fan",
                inviteeUsername: row.invitee_username,
                inviteeAvatarURL: ImageDisplayURL.canonicalStorageURLString(row.invitee_avatar_url).nilIfEmpty,
                inviteeAvatarThumbnailURL: ImageDisplayURL
                    .canonicalStorageURLString(row.invitee_avatar_thumbnail_url)
                    .nilIfEmpty,
                inviterUserId: row.inviter_user_id,
                createdAt: Self.parseDate(row.created_at),
                expiresAt: Self.parseDate(row.expires_at)
            )
        }
    }

    /// Accepts a pending invitation; returns the team id.
    func acceptInvitation(invitationId: UUID) async throws -> UUID {
        struct Params: Encodable { let p_invitation_id: UUID }
        let teamId: UUID = try await client
            .rpc("accept_fan_team_invitation", params: Params(p_invitation_id: invitationId))
            .execute()
            .value
        return teamId
    }

    func declineInvitation(invitationId: UUID) async throws {
        struct Params: Encodable { let p_invitation_id: UUID }
        try await client
            .rpc("decline_fan_team_invitation", params: Params(p_invitation_id: invitationId))
            .execute()
    }

    func cancelInvitation(invitationId: UUID) async throws {
        struct Params: Encodable { let p_invitation_id: UUID }
        try await client
            .rpc("cancel_fan_team_invitation", params: Params(p_invitation_id: invitationId))
            .execute()
    }

    /// Queues another invitation push for the same still-pending invitation (no new row).
    func resendInvitation(invitationId: UUID) async throws -> FanTeamInvitationResendOutcome {
        struct Params: Encodable { let p_invitation_id: UUID }
        struct RPCRow: Decodable {
            let ok: Bool
            let rate_limited: Bool?
            let message: String?
            let invitation_id: UUID?
            let event_id: UUID?
        }
        do {
            let row: RPCRow = try await client
                .rpc("resend_fan_team_invitation", params: Params(p_invitation_id: invitationId))
                .execute()
                .value
            return FanTeamInvitationResendOutcome.parse(
                ok: row.ok,
                rateLimited: row.rate_limited,
                message: row.message
            )
        } catch {
            if Self.isRPCRateLimitExceeded(error) {
                return .rateLimited(nil)
            }
            throw error
        }
    }

    private static func isRPCRateLimitExceeded(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("rate_limit_exceeded")
            || s.contains("54000")
    }

    func removeMember(teamId: UUID, userId: UUID) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_user_id: UUID
        }
        try await client
            .rpc("remove_fan_team_member", params: Params(p_team_id: teamId, p_user_id: userId))
            .execute()
    }

    /// Soft-remove by membership id (managed seats + account seats). Additive RPC.
    func removeMembership(membershipId: UUID) async throws {
        struct Params: Encodable {
            let p_membership_id: UUID
        }
        try await client
            .rpc("remove_fan_team_membership", params: Params(p_membership_id: membershipId))
            .execute()
    }

    /// Staff exclude / restore an active Team member for one Team-linked event.
    func setEventMemberExcluded(
        teamId: UUID,
        pickupGameId: UUID,
        userId: UUID,
        excluded: Bool
    ) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_pickup_game_id: UUID
            let p_user_id: UUID
            let p_excluded: Bool
        }
#if DEBUG
        print(
            "[FanTeamMemberChangeDebug] set_event_excluded team_id=\(teamId.uuidString.lowercased()) " +
            "pickup_game_id=\(pickupGameId.uuidString.lowercased()) " +
            "user_id=\(userId.uuidString.lowercased()) excluded=\(excluded)"
        )
#endif
        try await client
            .rpc(
                "set_fan_team_event_member_excluded",
                params: Params(
                    p_team_id: teamId,
                    p_pickup_game_id: pickupGameId,
                    p_user_id: userId,
                    p_excluded: excluded
                )
            )
            .execute()
    }

    /// Seat-scoped exclude / restore (`20260961`): the only path that works for a
    /// guardian-managed roster seat, and identical to the `userId` variant for accounts.
    func setEventMembershipExcluded(
        teamId: UUID,
        pickupGameId: UUID,
        membershipId: UUID,
        excluded: Bool
    ) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_pickup_game_id: UUID
            let p_membership_id: UUID
            let p_excluded: Bool
        }
        try await client
            .rpc(
                "set_fan_team_event_membership_excluded",
                params: Params(
                    p_team_id: teamId,
                    p_pickup_game_id: pickupGameId,
                    p_membership_id: membershipId,
                    p_excluded: excluded
                )
            )
            .execute()
    }

    /// Canonical Team-role write. Owner-only. Targets the roster **seat**
    /// (`membership_id`), never the guardian `user_id`. Required for
    /// managed-player seats (Emma) whose `user_id` is NULL. Account seats
    /// use the same RPC. Manager / Team Administrator cannot assign titles.
    func setMemberRole(teamId: UUID, membershipId: UUID, role: FanTeamMemberRole) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_membership_id: UUID
            let p_role: String
        }
        guard role.isAssignableViaRolePicker else {
            throw FanTeamsServiceError.invalidMemberRole
        }
        FanTeamRPCTrace.log(
            step: "role.mutation.start",
            rpc: "set_fan_team_membership_role",
            extra: "team=\(teamId.uuidString.lowercased()) membership=\(membershipId.uuidString.lowercased()) role=\(role.rawValue)"
        )
        do {
            let response = try await client
                .rpc(
                    "set_fan_team_membership_role",
                    params: Params(
                        p_team_id: teamId,
                        p_membership_id: membershipId,
                        p_role: role.rawValue
                    )
                )
                .execute()
            FanTeamRPCTrace.log(
                step: "role.mutation.http",
                rpc: "set_fan_team_membership_role",
                status: response.status,
                body: response.data,
                extra: "membership=\(membershipId.uuidString.lowercased()) requestedRole=\(role.rawValue)"
            )
        } catch {
            FanTeamRPCTrace.log(
                step: "role.mutation.failed",
                rpc: "set_fan_team_membership_role",
                error: error,
                extra: "membership=\(membershipId.uuidString.lowercased()) role=\(role.rawValue)"
            )
            throw error
        }
    }

    /// Account-only adapter. Do not use for managed-player seats.
    func setMemberRole(teamId: UUID, userId: UUID, role: FanTeamMemberRole) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_user_id: UUID
            let p_role: String
        }
        guard role.isAssignableViaRolePicker else {
            throw FanTeamsServiceError.invalidMemberRole
        }
        try await client
            .rpc(
                "set_fan_team_member_role",
                params: Params(p_team_id: teamId, p_user_id: userId, p_role: role.rawValue)
            )
            .execute()
    }

    /// Owner/manager assigns or clears (`nil`) a Team-specific player number (0–99).
    func setMemberPlayerNumber(teamId: UUID, userId: UUID, playerNumber: Int?) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_user_id: UUID
            let p_player_number: Int?

            enum CodingKeys: String, CodingKey {
                case p_team_id
                case p_user_id
                case p_player_number
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_team_id, forKey: .p_team_id)
                try c.encode(p_user_id, forKey: .p_user_id)
                if let p_player_number {
                    try c.encode(p_player_number, forKey: .p_player_number)
                } else {
                    try c.encodeNil(forKey: .p_player_number)
                }
            }
        }
        guard FanTeamPlayerNumber.isValid(playerNumber) else {
            throw FanTeamsServiceError.invalidPlayerNumber
        }
        try await client
            .rpc(
                "set_fan_team_member_player_number",
                params: Params(
                    p_team_id: teamId,
                    p_user_id: userId,
                    p_player_number: playerNumber
                )
            )
            .execute()
    }

    /// Owner/Manager/Head Coach/Assistant Coach assigns or clears (`nil`) preferred position.
    func setMemberPreferredPosition(teamId: UUID, userId: UUID, positionCode: String?) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_user_id: UUID
            let p_position_code: String?

            enum CodingKeys: String, CodingKey {
                case p_team_id
                case p_user_id
                case p_position_code
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_team_id, forKey: .p_team_id)
                try c.encode(p_user_id, forKey: .p_user_id)
                if let p_position_code {
                    try c.encode(p_position_code, forKey: .p_position_code)
                } else {
                    try c.encodeNil(forKey: .p_position_code)
                }
            }
        }
        try await client
            .rpc(
                "set_fan_team_member_preferred_position",
                params: Params(
                    p_team_id: teamId,
                    p_user_id: userId,
                    p_position_code: positionCode
                )
            )
            .execute()
    }

    /// Seat-scoped jersey write (`20260961`). Works for both account and
    /// guardian-managed roster seats, which is why it is the preferred path — the
    /// `userId` variants above remain for callers that only know an account id.
    func setMemberPlayerNumber(teamId: UUID, membershipId: UUID, playerNumber: Int?) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_membership_id: UUID
            let p_player_number: Int?

            enum CodingKeys: String, CodingKey {
                case p_team_id
                case p_membership_id
                case p_player_number
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_team_id, forKey: .p_team_id)
                try c.encode(p_membership_id, forKey: .p_membership_id)
                if let p_player_number {
                    try c.encode(p_player_number, forKey: .p_player_number)
                } else {
                    try c.encodeNil(forKey: .p_player_number)
                }
            }
        }
        guard FanTeamPlayerNumber.isValid(playerNumber) else {
            throw FanTeamsServiceError.invalidPlayerNumber
        }
        try await client
            .rpc(
                "set_fan_team_member_player_number_for_membership",
                params: Params(
                    p_team_id: teamId,
                    p_membership_id: membershipId,
                    p_player_number: playerNumber
                )
            )
            .execute()
    }

    /// Seat-scoped preferred-position write (`20260961`).
    func setMemberPreferredPosition(
        teamId: UUID,
        membershipId: UUID,
        positionCode: String?
    ) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_membership_id: UUID
            let p_position_code: String?

            enum CodingKeys: String, CodingKey {
                case p_team_id
                case p_membership_id
                case p_position_code
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_team_id, forKey: .p_team_id)
                try c.encode(p_membership_id, forKey: .p_membership_id)
                if let p_position_code {
                    try c.encode(p_position_code, forKey: .p_position_code)
                } else {
                    try c.encodeNil(forKey: .p_position_code)
                }
            }
        }
        try await client
            .rpc(
                "set_fan_team_member_preferred_position_for_membership",
                params: Params(
                    p_team_id: teamId,
                    p_membership_id: membershipId,
                    p_position_code: positionCode
                )
            )
            .execute()
    }

    func listGames(teamId: UUID) async throws -> [FanTeamGame] {
        struct Params: Encodable { let p_team_id: UUID }
        let response: PostgrestResponse<Void>
        do {
            response = try await client
                .rpc("list_fan_team_games", params: Params(p_team_id: teamId))
                .execute()
        } catch {
            FanTeamRPCTrace.log(
                step: "C.list_fan_team_games.failed",
                rpc: "list_fan_team_games",
                error: error,
                extra: "team=\(teamId.uuidString.lowercased())"
            )
            throw FanTeamLayeredError(
                layer: .teamDetailGames,
                underlying: error,
                httpStatus: FanTeamRPCTrace.httpStatus(from: error),
                responseBody: FanTeamRPCTrace.responseBody(from: error),
                mutationCommitted: nil
            )
        }
        FanTeamRPCTrace.log(
            step: "C.list_fan_team_games.http",
            rpc: "list_fan_team_games",
            status: response.status,
            extra: "bytes=\(response.data.count) team=\(teamId.uuidString.lowercased())"
        )
#if DEBUG
        print("[TeamDetailCrashTrace] gamesRPCReturned teamID=\(teamId.uuidString.lowercased()) bytes=\(response.data.count)")
#endif

        // Prefer whole-array decode; fall back to per-row so one bad row cannot kill Team Detail.
        let rows: [GameRow]
        do {
            rows = try JSONDecoder().decode([GameRow].self, from: response.data)
        } catch {
#if DEBUG
            print("[TeamDetailCrashTrace] gamesArrayDecodeFailed fallingBackToPerRow error=\(error.localizedDescription)")
#endif
            rows = Self.decodeGameRowsIndividually(from: response.data)
        }

        let mapped = rows.compactMap { row -> FanTeamGame? in
            Self.mapGameRow(row)
        }
#if DEBUG
        let formats = mapped.map(\.gameType.rawValue).joined(separator: ",")
        print(
            "[TeamDetailCrashTrace] gamesDecodeSuccess count=\(mapped.count) " +
            "rawRows=\(rows.count) gameFormats=\(formats)"
        )
#endif
        return mapped
    }

    private static func decodeGameRowsIndividually(from data: Data) -> [GameRow] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [Any] else {
            return []
        }
        let decoder = JSONDecoder()
        var rows: [GameRow] = []
        rows.reserveCapacity(array.count)
        for (index, element) in array.enumerated() {
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let row = try? decoder.decode(GameRow.self, from: elementData) else {
#if DEBUG
                print("[TeamDetailCrashTrace] gameDecodeSkipped index=\(index)")
#endif
                continue
            }
            rows.append(row)
        }
        return rows
    }

    private static func mapGameRow(_ row: GameRow) -> FanTeamGame? {
        guard let starts = parseDate(row.starts_at) else {
#if DEBUG
            print(
                "[TeamDetailCrashTrace] gameDecodeSkipped badStartsAt " +
                "id=\(row.pickup_game_id?.uuidString.lowercased() ?? row.id.uuidString.lowercased()) " +
                "format=\(row.game_type)"
            )
#endif
            return nil
        }
        return FanTeamGame(
            id: row.pickup_game_id ?? row.id,
            teamId: row.team_id,
            createdBy: row.created_by,
            gameType: FanTeamGameType.parse(row.game_type)
                ?? FanTeamGameType(rawValue: row.game_type.lowercased())
                ?? .other,
            sport: (row.sport?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Soccer",
            title: row.title,
            startsAt: starts,
            endsAt: parseDate(row.ends_at),
            venueName: row.venue_name,
            address: row.address,
            city: row.city,
            state: row.state,
            latitude: row.latitude,
            longitude: row.longitude,
            opponentTeamId: row.opponent_team_id,
            opponentName: row.opponent_name,
            status: row.status,
            homeScore: row.home_score,
            awayScore: row.away_score,
            mySide: row.my_side,
            createdAt: parseDate(row.created_at),
            competitionLevel: PickupCompetitionLevel.parse(row.competition_level),
            messageBody: row.description,
            scoringStatus: FanTeamEventScoringStatus.parse(row.scoring_status).rawValue,
            scoringFinalizedAt: parseDate(row.scoring_finalized_at)
        )
    }

    /// Manager/owner Teams available for Pickup Invite Friends → Teams mode.
    func listManageableTeamsForPickupInvite() async throws -> [FanTeamSummary] {
        try await listMyTeams().filter(\.canManage)
    }

    /// Server-side eligibility summary for inviting a Team roster to a Pickup game.
    func previewPickupInvite(teamId: UUID, pickupGameId: UUID) async throws -> PickupFanTeamInvitePreview {
        struct Params: Encodable {
            let p_pickup_game_id: UUID
            let p_team_id: UUID
        }
        struct Row: Decodable {
            let team_id: UUID
            let member_count_excluding_organizer: Int
            let eligible_count: Int
            let already_invited_count: Int
            let already_playing_count: Int
            let already_pending_count: Int
            let ineligible_count: Int
        }
        let rows: [Row] = try await client
            .rpc(
                "preview_pickup_game_fan_team_invite",
                params: Params(p_pickup_game_id: pickupGameId, p_team_id: teamId)
            )
            .execute()
            .value
        guard let row = rows.first else {
            return PickupFanTeamInvitePreview(
                teamId: teamId,
                memberCountExcludingOrganizer: 0,
                eligibleCount: 0,
                alreadyInvitedCount: 0,
                alreadyPlayingCount: 0,
                alreadyPendingCount: 0,
                ineligibleCount: 0
            )
        }
        return PickupFanTeamInvitePreview(
            teamId: row.team_id,
            memberCountExcludingOrganizer: max(0, row.member_count_excluding_organizer),
            eligibleCount: max(0, row.eligible_count),
            alreadyInvitedCount: max(0, row.already_invited_count),
            alreadyPlayingCount: max(0, row.already_playing_count),
            alreadyPendingCount: max(0, row.already_pending_count),
            ineligibleCount: max(0, row.ineligible_count)
        )
    }

    /// Trusted bulk invite: resolves active Team roster server-side into normal `pickup_game_invites`.
    func createPickupInvitesFromFanTeam(
        teamId: UUID,
        pickupGameId: UUID,
        message: String? = nil
    ) async throws -> [PickupGameInviteCreateResult] {
        struct Params: Encodable {
            let p_pickup_game_id: UUID
            let p_team_id: UUID
            let p_message: String?
        }
        return try await client
            .rpc(
                "create_pickup_game_invites_from_fan_team",
                params: Params(
                    p_pickup_game_id: pickupGameId,
                    p_team_id: teamId,
                    p_message: message
                )
            )
            .execute()
            .value
    }

    /// Links a just-created classic `pickup_games` row to a Team (manager/owner only).
    func linkPickupGameToFanTeam(teamId: UUID, pickupGameId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_pickup_game_id: UUID
        }
        let id: UUID = try await client
            .rpc(
                "link_pickup_game_to_fan_team",
                params: Params(p_team_id: teamId, p_pickup_game_id: pickupGameId)
            )
            .execute()
            .value
        return id
    }

    /// Schedule Game / edit: resolve Team identity for a linked `pickup_games` row via `fan_team_game_links`.
    /// Prefers `list_my_fan_teams` so member count + role chrome stay accurate for organizers.
    func loadTeamCreationContext(forPickupGameId pickupGameId: UUID) async throws -> PickupGameTeamCreationContext? {
        struct LinkRow: Decodable {
            let team_id: UUID
        }
        let links: [LinkRow] = try await client
            .from("fan_team_game_links")
            .select("team_id")
            .eq("pickup_game_id", value: pickupGameId.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        guard let teamId = links.first?.team_id else { return nil }

        if let mine = try await listMyTeams().first(where: { $0.id == teamId }) {
            return PickupGameTeamCreationContext(from: mine)
        }

        struct TeamRow: Decodable {
            let id: UUID
            let name: String
            let sport: String?
            let logo_url: String?
            let logo_thumbnail_url: String?
            let color_hex: String?
            let competition_level: String?
            let group_conversation_id: UUID?
        }
        let teams: [TeamRow] = try await client
            .from("fan_teams")
            .select("id,name,sport,logo_url,logo_thumbnail_url,color_hex,competition_level,group_conversation_id")
            .eq("id", value: teamId.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        guard let team = teams.first else { return nil }
        return PickupGameTeamCreationContext(
            teamId: team.id,
            teamName: team.name,
            teamSport: team.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            activeMemberCount: 0,
            competitionLevel: PickupCompetitionLevel.parse(team.competition_level),
            logoURL: ImageDisplayURL.canonicalStorageURLString(team.logo_url).nilIfEmpty,
            logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(team.logo_thumbnail_url).nilIfEmpty,
            colorHex: team.color_hex,
            groupConversationId: team.group_conversation_id
        )
    }

    /// Resolves the durable Team Chat conversation for a Team-linked pickup game.
    func teamChatConversationId(forPickupGameId pickupGameId: UUID) async throws -> UUID? {
        if let context = try await loadTeamCreationContext(forPickupGameId: pickupGameId),
           let conversationId = context.groupConversationId {
            return conversationId
        }
        struct TeamRow: Decodable {
            let group_conversation_id: UUID
        }
        struct LinkRow: Decodable {
            let team_id: UUID
        }
        let links: [LinkRow] = try await client
            .from("fan_team_game_links")
            .select("team_id")
            .eq("pickup_game_id", value: pickupGameId.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        guard let teamId = links.first?.team_id else { return nil }
        let teams: [TeamRow] = try await client
            .from("fan_teams")
            .select("group_conversation_id")
            .eq("id", value: teamId.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        return teams.first?.group_conversation_id
    }

    func setRSVP(gameId: UUID, status: FanTeamGameRSVPStatus) async throws {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_status: String
        }
#if DEBUG
        let authId = (try? await client.auth.session.user.id.uuidString.lowercased()) ?? "nil"
        print(
            "[TeamRSVPDebug] rpc=set_fan_team_game_rsvp pickup_game_id=\(gameId.uuidString.lowercased()) " +
            "auth_user_id=\(authId) status=\(status.rawValue)"
        )
#endif
        do {
            try await client
                .rpc("set_fan_team_game_rsvp", params: Params(p_game_id: gameId, p_status: status.rawValue))
                .execute()
#if DEBUG
            print(
                "[TeamRSVPDebug] rpc_success pickup_game_id=\(gameId.uuidString.lowercased()) " +
                "status=\(status.rawValue)"
            )
#endif
        } catch {
#if DEBUG
            print(
                "[TeamRSVPDebug] rpc_failure pickup_game_id=\(gameId.uuidString.lowercased()) " +
                "status=\(status.rawValue) error=\(error.localizedDescription)"
            )
#endif
            throw error
        }
    }

    /// Roster-seat RSVP (20260960). Preferred write path whenever a `membershipId`
    /// is known: the backend routes authenticated seats to the unchanged
    /// `set_fan_team_game_rsvp` storage and managed players to `fan_team_event_rsvps`.
    ///
    /// Falls back to the legacy self-RSVP RPC when the deployed backend predates
    /// 20260960 (the function simply does not exist yet) and the subject is the
    /// viewer themselves — a managed subject has no legacy path and must surface
    /// the error.
    func setRSVP(
        gameId: UUID,
        membershipId: UUID,
        status: FanTeamGameRSVPStatus,
        isManagedPlayer: Bool
    ) async throws {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_membership_id: UUID
            let p_status: String
        }
#if DEBUG
        print(
            "[TeamRSVPDebug] rpc=set_fan_team_game_rsvp_for_membership " +
            "pickup_game_id=\(gameId.uuidString.lowercased()) " +
            "membership_id=\(membershipId.uuidString.lowercased()) " +
            "managed=\(isManagedPlayer) status=\(status.rawValue)"
        )
#endif
        do {
            try await client
                .rpc(
                    "set_fan_team_game_rsvp_for_membership",
                    params: Params(
                        p_game_id: gameId,
                        p_membership_id: membershipId,
                        p_status: status.rawValue
                    )
                )
                .execute()
#if DEBUG
            print(
                "[TeamRSVPDebug] membership_rpc_success pickup_game_id=\(gameId.uuidString.lowercased()) " +
                "membership_id=\(membershipId.uuidString.lowercased()) status=\(status.rawValue)"
            )
#endif
        } catch {
#if DEBUG
            print(
                "[TeamRSVPDebug] membership_rpc_failure pickup_game_id=\(gameId.uuidString.lowercased()) " +
                "membership_id=\(membershipId.uuidString.lowercased()) status=\(status.rawValue) " +
                "error=\(error.localizedDescription)"
            )
#endif
            guard !isManagedPlayer, Self.looksLikeMissingRPC(error) else { throw error }
#if DEBUG
            print("[TeamRSVPDebug] membership_rpc_missing fallback=set_fan_team_game_rsvp")
#endif
            try await setRSVP(gameId: gameId, status: status)
        }
    }

    private static func looksLikeMissingRPC(_ error: Error) -> Bool {
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("pgrst202")
            || lowered.contains("could not find the function")
            || lowered.contains("does not exist")
    }

    func getRSVP(gameId: UUID) async throws -> FanTeamGameRSVPStatus? {
        struct Params: Encodable { let p_game_id: UUID }
        let raw: String? = try await client
            .rpc("get_fan_team_game_rsvp", params: Params(p_game_id: gameId))
            .execute()
            .value
        let status = raw.flatMap { FanTeamGameRSVPStatus(rawValue: $0.lowercased()) }
#if DEBUG
        print(
            "[TeamRSVPDebug] rpc=get_fan_team_game_rsvp pickup_game_id=\(gameId.uuidString.lowercased()) " +
            "raw=\(raw ?? "NULL") mapped=\(status?.rawValue ?? "unanswered")"
        )
#endif
        return status
    }

    /// Batched Schedule attendance (roster + self RSVP) for visible Team events.
    func listScheduleAttendance(
        teamId: UUID,
        pickupGameIds: [UUID]
    ) async throws -> [FanTeamScheduleAttendanceRow] {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_pickup_game_ids: [UUID]
        }
        struct Row: Decodable {
            let pickup_game_id: UUID
            let roster: PickupGameRosterPayload
            let self_rsvp: String?
        }
        let rows: [Row] = try await client
            .rpc(
                "list_fan_team_schedule_attendance",
                params: Params(p_team_id: teamId, p_pickup_game_ids: pickupGameIds)
            )
            .execute()
            .value
        return rows.map { row in
            FanTeamScheduleAttendanceRow(
                pickupGameId: row.pickup_game_id,
                roster: row.roster,
                selfRSVP: row.self_rsvp.flatMap { FanTeamGameRSVPStatus(rawValue: $0.lowercased()) }
            )
        }
    }

    func loadDetail(for summary: FanTeamSummary) async throws -> FanTeamDetail {
        async let members = listMembers(teamId: summary.id)
        async let games = listGames(teamId: summary.id)
        async let record = loadTeamRecord(teamId: summary.id)
        async let scored = listScoredResults(teamId: summary.id)
        let (memberRows, gameRows, teamRecord, scoredRows) = try await (members, games, record, scored)
        let merged = Self.mergeGames(gameRows, scoredResults: scoredRows)
        return FanTeamDetail(
            summary: summary,
            members: memberRows,
            games: merged,
            record: teamRecord ?? FanTeamEventScoring.record(from: merged)
        )
    }

    private static func mergeGames(_ games: [FanTeamGame], scoredResults: [FanTeamGame]) -> [FanTeamGame] {
        guard !scoredResults.isEmpty else { return games }
        var byId: [UUID: FanTeamGame] = [:]
        for game in games { byId[game.id] = game }
        for game in scoredResults { byId[game.id] = game }
        return Array(byId.values)
    }

    func listScoredResults(teamId: UUID, beforeCompletedAt: Date? = nil) async -> [FanTeamGame] {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_before_completed_at: String?
            let p_limit: Int
        }
        do {
            let response = try await client
                .rpc(
                    "list_fan_team_scored_results",
                    params: Params(
                        p_team_id: teamId,
                        p_before_completed_at: beforeCompletedAt.map(Self.encodeDate),
                        p_limit: 20
                    )
                )
                .execute()
            let rows = Self.decodeGameRowsIndividually(from: response.data)
            return rows.compactMap(Self.mapGameRow)
        } catch {
            return []
        }
    }

    func loadTeamRecord(teamId: UUID) async -> FanTeamRecord? {
        struct Params: Encodable { let p_team_id: UUID }
        struct Row: Decodable {
            let wins: Int
            let losses: Int
            let ties: Int
        }
        do {
            let rows: [Row] = try await client
                .rpc("get_fan_team_record", params: Params(p_team_id: teamId))
                .execute()
                .value
            guard let row = rows.first else { return .empty }
            return FanTeamRecord(wins: max(0, row.wins), losses: max(0, row.losses), ties: max(0, row.ties))
        } catch {
            return nil
        }
    }

    struct FanTeamEventScoreMutation: Hashable, Sendable {
        let eventId: UUID
        let teamId: UUID
        let teamScore: Int
        let opponentScore: Int
        let scoringStatus: String
        let scoringFinalizedAt: Date?
        let opponentName: String?
        let replayed: Bool
    }

    private struct ScoreMutationRow: Decodable {
        let event_id: UUID
        let team_id: UUID
        let team_score: Int
        let opponent_score: Int
        let scoring_status: String
        let scoring_finalized_at: String?
        let opponent_name: String?
        let replayed: Bool?
    }

    private func mapScoreMutation(_ row: ScoreMutationRow) -> FanTeamEventScoreMutation {
        FanTeamEventScoreMutation(
            eventId: row.event_id,
            teamId: row.team_id,
            teamScore: max(0, row.team_score),
            opponentScore: max(0, row.opponent_score),
            scoringStatus: FanTeamEventScoringStatus.parse(row.scoring_status).rawValue,
            scoringFinalizedAt: Self.parseDate(row.scoring_finalized_at),
            opponentName: row.opponent_name,
            replayed: row.replayed ?? false
        )
    }

    func updateEventScore(
        eventId: UUID,
        teamId: UUID,
        teamDelta: Int,
        opponentDelta: Int,
        idempotencyKey: String,
        scorerMembershipId: UUID? = nil
    ) async throws -> FanTeamEventScoreMutation {
        struct Params: Encodable {
            let p_event_id: UUID
            let p_team_id: UUID
            let p_team_delta: Int
            let p_opponent_delta: Int
            let p_idempotency_key: String
        }
        struct ParamsWithScorer: Encodable {
            let p_event_id: UUID
            let p_team_id: UUID
            let p_team_delta: Int
            let p_opponent_delta: Int
            let p_idempotency_key: String
            let p_scorer_membership_id: UUID
        }
        if let scorerMembershipId {
            do {
                let rows: [ScoreMutationRow] = try await client
                    .rpc(
                        "update_fan_team_event_score",
                        params: ParamsWithScorer(
                            p_event_id: eventId,
                            p_team_id: teamId,
                            p_team_delta: teamDelta,
                            p_opponent_delta: opponentDelta,
                            p_idempotency_key: idempotencyKey,
                            p_scorer_membership_id: scorerMembershipId
                        )
                    )
                    .execute()
                    .value
                guard let row = rows.first else {
                    throw FanTeamsServiceError.scoringMutationFailed
                }
                return mapScoreMutation(row)
            } catch {
                if Self.looksLikeMissingRPC(error) {
                    return try await updateEventScore(
                        eventId: eventId,
                        teamId: teamId,
                        teamDelta: teamDelta,
                        opponentDelta: opponentDelta,
                        idempotencyKey: idempotencyKey,
                        scorerMembershipId: nil
                    )
                }
                throw error
            }
        }
        let rows: [ScoreMutationRow] = try await client
            .rpc(
                "update_fan_team_event_score",
                params: Params(
                    p_event_id: eventId,
                    p_team_id: teamId,
                    p_team_delta: teamDelta,
                    p_opponent_delta: opponentDelta,
                    p_idempotency_key: idempotencyKey
                )
            )
            .execute()
            .value
        guard let row = rows.first else {
            throw FanTeamsServiceError.scoringMutationFailed
        }
        return mapScoreMutation(row)
    }

    func setEventScoringStatus(
        eventId: UUID,
        teamId: UUID,
        status: FanTeamEventScoringStatus,
        idempotencyKey: String
    ) async throws -> FanTeamEventScoreMutation {
        struct Params: Encodable {
            let p_event_id: UUID
            let p_team_id: UUID
            let p_status: String
            let p_idempotency_key: String
        }
        let rows: [ScoreMutationRow] = try await client
            .rpc(
                "set_fan_team_event_scoring_status",
                params: Params(
                    p_event_id: eventId,
                    p_team_id: teamId,
                    p_status: status.rawValue,
                    p_idempotency_key: idempotencyKey
                )
            )
            .execute()
            .value
        guard let row = rows.first else {
            throw FanTeamsServiceError.scoringMutationFailed
        }
        return mapScoreMutation(row)
    }

    func correctEventFinalScore(
        eventId: UUID,
        teamId: UUID,
        teamScore: Int,
        opponentScore: Int,
        idempotencyKey: String
    ) async throws -> FanTeamEventScoreMutation {
        struct Params: Encodable {
            let p_event_id: UUID
            let p_team_id: UUID
            let p_team_score: Int
            let p_opponent_score: Int
            let p_idempotency_key: String
        }
        let rows: [ScoreMutationRow] = try await client
            .rpc(
                "correct_fan_team_event_final_score",
                params: Params(
                    p_event_id: eventId,
                    p_team_id: teamId,
                    p_team_score: teamScore,
                    p_opponent_score: opponentScore,
                    p_idempotency_key: idempotencyKey
                )
            )
            .execute()
            .value
        guard let row = rows.first else {
            throw FanTeamsServiceError.scoringMutationFailed
        }
        return mapScoreMutation(row)
    }

    // MARK: - Identity

    struct UploadedTeamLogoURLs: Sendable {
        let fullURL: String
        let thumbnailURL: String
    }

    static let teamLogoStorageBucket = "fan-team-logos"

    static func makeVersionedTeamLogoFileName() -> String {
        "logo-\(UUID().uuidString.lowercased()).jpg"
    }

    static func companionTeamLogoThumbnailFileName(for fullFileName: String) -> String {
        if let dot = fullFileName.lastIndex(of: "."), dot < fullFileName.endIndex {
            let base = String(fullFileName[..<dot])
            let ext = String(fullFileName[fullFileName.index(after: dot)...])
            return "\(base)_thumb.\(ext)"
        }
        return fullFileName + "_thumb.jpg"
    }

    /// Uploads full + thumbnail JPEGs to `fan-team-logos/{team_id}/` (RLS: Owner/Manager).
    func uploadTeamLogo(teamId: UUID, imageData: Data) async throws -> UploadedTeamLogoURLs {
        let folder = teamId.uuidString.lowercased()
        let fileName = Self.makeVersionedTeamLogoFileName()
        let thumbName = Self.companionTeamLogoThumbnailFileName(for: fileName)
        let pathFull = "\(folder)/\(fileName)"
        let pathThumb = "\(folder)/\(thumbName)"

        let uploadFull = ImageCompression.jpegDataForUpload(from: imageData, preset: .avatar)
        let uploadThumb = ImageCompression.jpegDataForUpload(from: imageData, preset: .avatarThumbnail)

        try await client.storage
            .from(Self.teamLogoStorageBucket)
            .upload(
                pathFull,
                data: uploadFull,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )

        try await client.storage
            .from(Self.teamLogoStorageBucket)
            .upload(
                pathThumb,
                data: uploadThumb,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )

        let publicFull = try client.storage
            .from(Self.teamLogoStorageBucket)
            .getPublicURL(path: pathFull)
        let publicThumb = try client.storage
            .from(Self.teamLogoStorageBucket)
            .getPublicURL(path: pathThumb)

        let fullStr = ImageDisplayURL.canonicalStorageURLString(publicFull.absoluteString)
        let thumbStr = ImageDisplayURL.canonicalStorageURLString(publicThumb.absoluteString)
        guard !fullStr.isEmpty else {
            throw FanTeamsServiceError.logoUploadFailed
        }
        return UploadedTeamLogoURLs(
            fullURL: fullStr,
            thumbnailURL: thumbStr.isEmpty ? fullStr : thumbStr
        )
    }

    func updateTeamIdentity(
        teamId: UUID,
        name: String,
        sport: String,
        colorHex: String?,
        logoURL: String?,
        logoThumbnailURL: String?,
        competitionLevel: PickupCompetitionLevel? = nil,
        /// Must be `true` only when the client intentionally updates the Team default.
        /// Default `false` preserves older callers / omitted args after migration 20260941.
        updateCompetitionLevel: Bool = false
    ) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_name: String
            let p_sport: String
            let p_color_hex: String?
            let p_logo_url: String?
            let p_logo_thumbnail_url: String?
            let p_competition_level: String?
            let p_update_competition_level: Bool
        }
        try await client
            .rpc(
                "update_fan_team_identity",
                params: Params(
                    p_team_id: teamId,
                    p_name: name,
                    p_sport: sport,
                    p_color_hex: colorHex,
                    p_logo_url: logoURL,
                    p_logo_thumbnail_url: logoThumbnailURL,
                    p_competition_level: competitionLevel?.rawValue,
                    p_update_competition_level: updateCompetitionLevel
                )
            )
            .execute()
    }

    // MARK: - Discoverability (Play → Places)

    func listDiscoverableFanTeamsInBounds(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double,
        sport: String?
    ) async throws -> [DiscoverableFanTeamMapRow] {
        struct Params: Encodable {
            let p_min_lat: Double
            let p_max_lat: Double
            let p_min_lon: Double
            let p_max_lon: Double
            let p_sport: String?
        }
        let rows: [FanTeamDiscoveryRPCRow] = try await client
            .rpc(
                "list_discoverable_fan_teams_in_bounds",
                params: Params(
                    p_min_lat: minLat,
                    p_max_lat: maxLat,
                    p_min_lon: minLon,
                    p_max_lon: maxLon,
                    p_sport: sport
                )
            )
            .execute()
            .value
        return rows.compactMap { $0.asMapRow() }
    }

    func getPublicFanTeamSummary(teamId: UUID) async throws -> DiscoverableFanTeamMapRow {
        struct Params: Encodable {
            let p_team_id: UUID
        }
        let rows: [FanTeamDiscoveryRPCRow] = try await client
            .rpc("get_public_fan_team_summary", params: Params(p_team_id: teamId))
            .execute()
            .value
        guard let row = rows.first?.asMapRow() else {
            throw FanTeamsServiceError.notFound
        }
        return row
    }

    func getMyFanTeamDiscovery(teamId: UUID) async throws -> FanTeamDiscoverySettings {
        struct Params: Encodable {
            let p_team_id: UUID
        }
        let rows: [FanTeamMyDiscoveryRPCRow] = try await client
            .rpc("get_my_fan_team_discovery", params: Params(p_team_id: teamId))
            .execute()
            .value
        return rows.first?.asSettings() ?? .hidden
    }

    func updateFanTeamDiscovery(_ settings: FanTeamDiscoverySettings, teamId: UUID) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_is_discoverable: Bool
            let p_looking_for_players: Bool
            let p_sport_subtype: String?
            let p_location_precision: String
            let p_place_name: String?
            let p_address: String?
            let p_city: String?
            let p_region: String?
            let p_postal_code: String?
            let p_country_code: String?
            let p_latitude: Double?
            let p_longitude: Double?
            let p_clear_location: Bool
        }
        let clearLocation = settings.shouldClearStoredDiscoveryLocation
        try await client
            .rpc(
                "update_fan_team_discovery",
                params: Params(
                    p_team_id: teamId,
                    p_is_discoverable: settings.isDiscoverable,
                    p_looking_for_players: settings.lookingForPlayers,
                    p_sport_subtype: settings.sportSubtype,
                    p_location_precision: settings.precision.rawValue,
                    p_place_name: settings.placeName,
                    p_address: settings.address,
                    p_city: settings.city,
                    p_region: settings.region,
                    p_postal_code: settings.postalCode,
                    p_country_code: settings.countryCode,
                    p_latitude: settings.latitude,
                    p_longitude: settings.longitude,
                    p_clear_location: clearLocation
                )
            )
            .execute()
    }

    // MARK: - Safety (report / leave)

    static let teamReportDetailsMaxCharacters = 1000

    /// Active members report Team identity/abuse. Does not leave or hide the Team.
    @discardableResult
    func reportTeam(
        teamId: UUID,
        category: FanTeamReportCategory,
        details: String? = nil
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_category: String
            let p_details: String?
        }
        let trimmed = details?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detailsPayload: String? = {
            guard let trimmed, !trimmed.isEmpty else { return nil }
            if trimmed.count > Self.teamReportDetailsMaxCharacters {
                return String(trimmed.prefix(Self.teamReportDetailsMaxCharacters))
            }
            return trimmed
        }()
        do {
            let id: UUID = try await client
                .rpc(
                    "report_fan_team",
                    params: Params(
                        p_team_id: teamId,
                        p_category: category.rawValue,
                        p_details: detailsPayload
                    )
                )
                .execute()
                .value
            return id
        } catch {
            if Self.isDuplicateFanTeamReport(error) {
                throw FanTeamReportError.duplicateOpenReport
            }
            if Self.isNotActiveFanTeamMember(error) {
                throw FanTeamReportError.notActiveMember
            }
            throw error
        }
    }

    /// Soft-leave for non-owners. Owners are rejected by the RPC.
    func leaveTeam(teamId: UUID) async throws {
        struct Params: Encodable { let p_team_id: UUID }
#if DEBUG
        let authId = try? await client.auth.session.user.id
        print(
            "[FanTeamMemberLeaveDebug] client_leave_begin team_id=\(teamId.uuidString.lowercased()) " +
            "leaving_user_id=\(authId?.uuidString.lowercased() ?? "nil") rpc=leave_fan_team"
        )
#endif
        do {
            try await client
                .rpc("leave_fan_team", params: Params(p_team_id: teamId))
                .execute()
#if DEBUG
            print(
                "[FanTeamMemberLeaveDebug] client_leave_ok team_id=\(teamId.uuidString.lowercased())"
            )
#endif
        } catch {
#if DEBUG
            print(
                "[FanTeamMemberLeaveDebug] client_leave_failed team_id=\(teamId.uuidString.lowercased()) " +
                "error=\(error.localizedDescription)"
            )
#endif
            throw error
        }
    }

    /// Owner-only soft-delete (`is_active=false` + soft-leave roster/chat). Returns deletion event id.
    @discardableResult
    func deleteTeam(teamId: UUID) async throws -> UUID {
        struct Params: Encodable { let p_team_id: UUID }
        let eventId: UUID = try await client
            .rpc("delete_fan_team", params: Params(p_team_id: teamId))
            .execute()
            .value
        return eventId
    }

    /// True when server rejects delete because the Team is inactive without an owner deletion event
    /// (e.g. admin moderation deactivate). Caller should refresh My Teams and leave Detail.
    static func isTeamAlreadyInactiveDeleteError(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("team is already inactive")
    }

    private static func isDuplicateFanTeamReport(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("23505")
            || s.contains("unique")
            || s.contains("already reported this team")
    }

    private static func isNotActiveFanTeamMember(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("not a team member")
    }
}

/// Distinguishes Remove-Myself failure layers so UI never maps them all to "refresh".
enum FanTeamOperationLayer: String, Sendable {
    case membershipUpdate = "A.set_my_fan_team_is_player"
    case teamsReload = "B.list_my_fan_teams"
    case teamDetailMembers = "C.list_fan_team_members"
    case teamDetailGames = "C.list_fan_team_games"
    case managedPlayerRefresh = "D.managed_player_list"
    case decoding = "E.client_decoding"
    case reconciliation = "F.local_reconciliation"
}

struct FanTeamLayeredError: Error, LocalizedError {
    let layer: FanTeamOperationLayer
    let underlying: Error
    let httpStatus: Int?
    let responseBody: String?
    let mutationCommitted: Bool?

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

enum FanTeamRPCTrace {
    static func log(
        step: String,
        rpc: String,
        status: Int? = nil,
        body: Data? = nil,
        error: Error? = nil,
        extra: String = ""
    ) {
#if DEBUG
        var parts: [String] = [
            "[FanTeamMembershipTrace]",
            "step=\(step)",
            "rpc=\(rpc)",
        ]
        if let status {
            parts.append("httpStatus=\(status)")
        }
        if let body {
            let raw = String(data: body, encoding: .utf8) ?? "<non-utf8 \(body.count) bytes>"
            let clipped = raw.count > 1200 ? String(raw.prefix(1200)) + "…" : raw
            parts.append("body=\(clipped)")
        }
        if let error {
            parts.append("error=\(FanTeamsLoadErrorPresentation.debugDescription(error))")
            if let pe = error as? PostgrestError {
                parts.append("postgrestCode=\(pe.code ?? "nil")")
                parts.append("postgrestMessage=\(pe.message)")
                parts.append("postgrestDetail=\(pe.detail ?? "nil")")
                parts.append("postgrestHint=\(pe.hint ?? "nil")")
            }
            if let http = error as? HTTPError {
                parts.append("httpStatus=\(http.response.statusCode)")
                let raw = String(data: http.data, encoding: .utf8) ?? "<non-utf8>"
                parts.append("httpBody=\(raw)")
            }
            if let layered = error as? FanTeamLayeredError {
                parts.append("layer=\(layered.layer.rawValue)")
                parts.append("mutationCommitted=\(layered.mutationCommitted.map { $0 ? "YES" : "NO" } ?? "unknown")")
            }
        }
        if !extra.isEmpty {
            parts.append(extra)
        }
        print(parts.joined(separator: " "))
#endif
    }

    static func httpStatus(from error: Error) -> Int? {
        if let http = error as? HTTPError {
            return http.response.statusCode
        }
        if let layered = error as? FanTeamLayeredError {
            return layered.httpStatus
        }
        return nil
    }

    static func responseBody(from error: Error) -> String? {
        if let http = error as? HTTPError {
            return String(data: http.data, encoding: .utf8)
        }
        if let layered = error as? FanTeamLayeredError {
            return layered.responseBody
        }
        return nil
    }
}

/// Scalar boolean RPC bodies (`true` / `false`). `false` is a valid success value.
enum FanTeamRPCScalarBool {
    static func decode(from data: Data, fallbackIfEmpty: Bool? = nil) throws -> Bool {
        if let value = try? JSONDecoder().decode(Bool.self, from: data) {
            return value
        }
        if let values = try? JSONDecoder().decode([Bool].self, from: data), let first = values.first {
            return first
        }
        if let number = try? JSONDecoder().decode(Int.self, from: data) {
            return number != 0
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["set_my_fan_team_is_player", "value", "is_player", "p_is_player"] {
                if let flag = bool(fromJSON: object[key]) {
                    return flag
                }
            }
            if object.isEmpty, let fallbackIfEmpty {
                return fallbackIfEmpty
            }
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .lowercased() ?? ""
        if raw == "true" || raw == "t" || raw == "1" { return true }
        if raw == "false" || raw == "f" || raw == "0" { return false }
        if raw.isEmpty, let fallbackIfEmpty {
            return fallbackIfEmpty
        }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: [],
                debugDescription: "Unreadable boolean RPC body: \(raw.isEmpty ? "<empty>" : raw)"
            )
        )
    }

    private static func bool(fromJSON value: Any?) -> Bool? {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "true" || lowered == "t" || lowered == "1" { return true }
            if lowered == "false" || lowered == "f" || lowered == "0" { return false }
            return nil
        default:
            return nil
        }
    }
}

enum FanTeamsServiceError: LocalizedError {
    case logoUploadFailed
    case invalidPlayerNumber
    case invalidMemberRole
    case notFound
    case scoringMutationFailed

    var errorDescription: String? {
        switch self {
        case .logoUploadFailed:
            return "Team logo upload failed."
        case .invalidPlayerNumber:
            return "Player number must be between 0 and 99."
        case .invalidMemberRole:
            return "That Team role cannot be assigned from the role menu."
        case .notFound:
            return "Team not found."
        case .scoringMutationFailed:
            return "Couldn’t update the score. Try again."
        }
    }
}

/// Result of `resend_fan_team_invitation` (push-only; same invitation_id).
enum FanTeamInvitationResendOutcome: Equatable, Sendable {
    case sent
    case rateLimited(String?)

    static func parse(ok: Bool, rateLimited: Bool?, message: String?) -> FanTeamInvitationResendOutcome {
        if rateLimited == true || ok == false {
            return .rateLimited(message)
        }
        return .sent
    }
}

extension FanTeamsService {
    /// Privacy-gated Fan Team memberships for a profile (batched; soft-fails if RPC missing).
    func listProfileFanTeamMemberships(targetUserId: UUID) async -> ProfileFanTeamMembershipsPayload {
        struct Params: Encodable {
            let p_target_user_id: UUID
        }
        struct RPCResponse: Decodable {
            let visible: Bool?
            let visibility: String?
            let memberships: [MembershipRow]?
        }
        struct MembershipRow: Decodable {
            let team_id: UUID
            let name: String?
            let sport: String?
            let logo_url: String?
            let logo_thumbnail_url: String?
            let color_hex: String?
            let role: String?
            let viewer_can_open: Bool?
        }

        do {
            let raw: RPCResponse = try await client
                .rpc(
                    "list_profile_fan_team_memberships",
                    params: Params(p_target_user_id: targetUserId)
                )
                .execute()
                .value
            let memberships = (raw.memberships ?? []).compactMap { row -> ProfileFanTeamMembership? in
                let name = (row.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return ProfileFanTeamMembership(
                    teamId: row.team_id,
                    name: name,
                    sport: (row.sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    logoURL: ImageDisplayURL.canonicalStorageURLString(row.logo_url).nilIfEmpty,
                    logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(row.logo_thumbnail_url).nilIfEmpty,
                    colorHex: row.color_hex,
                    role: FanTeamMemberRole.parse(row.role),
                    viewerCanOpen: row.viewer_can_open ?? false
                )
            }
            return ProfileFanTeamMembershipsPayload(
                visible: raw.visible ?? false,
                visibility: FanTeamProfileVisibility.parse(raw.visibility),
                memberships: memberships
            )
        } catch {
#if DEBUG
            print("[ProfileMyTeams] list_profile_fan_team_memberships soft-fail: \(error.localizedDescription)")
#endif
            return .empty
        }
    }

    /// Updates the caller's global My Teams profile visibility.
    @discardableResult
    func setMyTeamsProfileVisibility(_ visibility: FanTeamProfileVisibility) async throws -> FanTeamProfileVisibility {
        struct Params: Encodable {
            let p_visibility: String
        }
        let raw: String = try await client
            .rpc(
                "set_my_teams_profile_visibility",
                params: Params(p_visibility: visibility.rawValue)
            )
            .execute()
            .value
        return FanTeamProfileVisibility.parse(raw)
    }

    /// Maps an active membership from `list_my_fan_teams` into the profile-safe card model.
    static func profileMemberships(from summaries: [FanTeamSummary]) -> [ProfileFanTeamMembership] {
        summaries
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { team in
                ProfileFanTeamMembership(
                    teamId: team.id,
                    name: team.name,
                    sport: team.sport,
                    logoURL: team.logoURL,
                    logoThumbnailURL: team.logoThumbnailURL,
                    colorHex: team.colorHex,
                    role: team.myRole,
                    viewerCanOpen: true
                )
            }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

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
    }

    private struct MemberRow: Decodable {
        let user_id: UUID
        let role: String
        let joined_at: String?
        let display_name: String?
        let username: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let last_seen_at: String?
        let player_number: Int?
        let gender: String?

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
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            user_id = try c.decode(UUID.self, forKey: .user_id)
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
        let rows: [TeamListRow] = try await client
            .rpc("list_my_fan_teams")
            .execute()
            .value
        return rows.map { row in
            let role = FanTeamMemberRole(rawValue: row.my_role.lowercased()) ?? .member
            let pendingCount = role.canManageTeam ? max(0, row.pending_invitation_count ?? 0) : 0
            return FanTeamSummary(
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
                pushNotificationsMuted: row.push_notifications_muted ?? false,
                nextGameStartsAt: Self.parseDate(row.next_game_starts_at),
                nextGameTitle: row.next_game_title,
                nextGameVenue: row.next_game_venue,
                createdAt: Self.parseDate(row.created_at)
            )
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
        let rows: [MemberRow] = try await client
            .rpc("list_fan_team_members", params: Params(p_team_id: teamId))
            .execute()
            .value
        return rows.map { row in
            FanTeamMember(
                userId: row.user_id,
                role: FanTeamMemberRole(rawValue: row.role.lowercased()) ?? .member,
                joinedAt: Self.parseDate(row.joined_at),
                displayName: (row.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Fan",
                username: row.username,
                avatarURL: ImageDisplayURL.canonicalStorageURLString(row.avatar_url).nilIfEmpty,
                avatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(row.avatar_thumbnail_url).nilIfEmpty,
                lastSeenAtRaw: row.last_seen_at,
                playerNumber: FanTeamPlayerNumber.isValid(row.player_number) ? row.player_number : nil,
                genderRaw: row.gender
            )
        }
    }

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

    func setMemberRole(teamId: UUID, userId: UUID, role: FanTeamMemberRole) async throws {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_user_id: UUID
            let p_role: String
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

    func listGames(teamId: UUID) async throws -> [FanTeamGame] {
        struct Params: Encodable { let p_team_id: UUID }
        let rows: [GameRow] = try await client
            .rpc("list_fan_team_games", params: Params(p_team_id: teamId))
            .execute()
            .value
        return rows.compactMap { row in
            guard let starts = Self.parseDate(row.starts_at) else { return nil }
            return FanTeamGame(
                id: row.pickup_game_id ?? row.id,
                teamId: row.team_id,
                createdBy: row.created_by,
                gameType: FanTeamGameType.parse(row.game_type)
                    ?? FanTeamGameType(rawValue: row.game_type.lowercased())
                    ?? .match,
                sport: (row.sport?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Soccer",
                title: row.title,
                startsAt: starts,
                endsAt: Self.parseDate(row.ends_at),
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
                createdAt: Self.parseDate(row.created_at),
                competitionLevel: PickupCompetitionLevel.parse(row.competition_level)
            )
        }
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
        }
        let teams: [TeamRow] = try await client
            .from("fan_teams")
            .select("id,name,sport,logo_url,logo_thumbnail_url,color_hex,competition_level")
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
            colorHex: team.color_hex
        )
    }

    func setRSVP(gameId: UUID, status: FanTeamGameRSVPStatus) async throws {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_status: String
        }
        try await client
            .rpc("set_fan_team_game_rsvp", params: Params(p_game_id: gameId, p_status: status.rawValue))
            .execute()
    }

    func getRSVP(gameId: UUID) async throws -> FanTeamGameRSVPStatus? {
        struct Params: Encodable { let p_game_id: UUID }
        let raw: String? = try await client
            .rpc("get_fan_team_game_rsvp", params: Params(p_game_id: gameId))
            .execute()
            .value
        guard let raw, let status = FanTeamGameRSVPStatus(rawValue: raw.lowercased()) else { return nil }
        return status
    }

    func loadDetail(for summary: FanTeamSummary) async throws -> FanTeamDetail {
        async let members = listMembers(teamId: summary.id)
        async let games = listGames(teamId: summary.id)
        let (memberRows, gameRows) = try await (members, games)
        return FanTeamDetail(
            summary: summary,
            members: memberRows,
            games: gameRows
        )
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
        try await client
            .rpc("leave_fan_team", params: Params(p_team_id: teamId))
            .execute()
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

enum FanTeamsServiceError: LocalizedError {
    case logoUploadFailed
    case invalidPlayerNumber

    var errorDescription: String? {
        switch self {
        case .logoUploadFailed:
            return "Team logo upload failed."
        case .invalidPlayerNumber:
            return "Player number must be between 0 and 99."
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

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

import Foundation
import Supabase

/// RPC wrappers for parent/guardian managed players (20260960).
///
/// Every read returns an empty array for users with no managed players, so the
/// feature stays invisible unless a guardian opts in.
final class FanManagedPlayerService {
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

    private static func trimmedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Rows

    private struct PlayerRow: Decodable {
        let managed_player_id: UUID
        let first_name: String?
        let last_name: String?
        let display_name: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let birth_year: Int?
        let guardian_role: String?
        let team_count: Int?
        let created_at: String?

        func asModel() -> FanManagedPlayer {
            FanManagedPlayer(
                id: managed_player_id,
                firstName: first_name ?? "",
                lastName: last_name ?? "",
                displayName: FanManagedPlayerService.trimmedOrNil(display_name)
                    ?? FanManagedPlayerService.trimmedOrNil(first_name)
                    ?? "Player",
                avatarURL: FanManagedPlayerService.trimmedOrNil(
                    ImageDisplayURL.canonicalStorageURLString(avatar_url)
                ),
                avatarThumbnailURL: FanManagedPlayerService.trimmedOrNil(
                    ImageDisplayURL.canonicalStorageURLString(avatar_thumbnail_url)
                ),
                birthYear: birth_year,
                guardianRole: FanManagedPlayerGuardianRole.parse(guardian_role),
                teamCount: max(0, team_count ?? 0),
                createdAt: FanManagedPlayerService.parseDate(created_at)
            )
        }
    }

    private struct TeamMembershipRow: Decodable {
        let membership_id: UUID
        let team_id: UUID
        let team_name: String?
        let sport: String?
        let logo_url: String?
        let logo_thumbnail_url: String?
        let color_hex: String?
        let player_number: Int?
        let preferred_position_code: String?
        let joined_at: String?

        private enum CodingKeys: String, CodingKey {
            case membership_id
            case team_id
            case team_name
            case sport
            case logo_url
            case logo_thumbnail_url
            case color_hex
            case player_number
            case preferred_position_code
            case joined_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            membership_id = try c.decode(UUID.self, forKey: .membership_id)
            team_id = try c.decode(UUID.self, forKey: .team_id)
            team_name = try c.decodeIfPresent(String.self, forKey: .team_name)
            sport = try c.decodeIfPresent(String.self, forKey: .sport)
            logo_url = try c.decodeIfPresent(String.self, forKey: .logo_url)
            logo_thumbnail_url = try c.decodeIfPresent(String.self, forKey: .logo_thumbnail_url)
            color_hex = try c.decodeIfPresent(String.self, forKey: .color_hex)
            player_number = FanManagedPlayerService.decodeFlexibleInt(c, forKey: .player_number)
            preferred_position_code = try c.decodeIfPresent(String.self, forKey: .preferred_position_code)
            joined_at = FanManagedPlayerService.decodeFlexibleTimestampString(c, forKey: .joined_at)
        }
    }

    private struct TeamSeatRow: Decodable {
        let membership_id: UUID
        let managed_player_id: UUID
        let display_name: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let player_number: Int?
        let preferred_position_code: String?
        let joined_at: String?

        private enum CodingKeys: String, CodingKey {
            case membership_id
            case managed_player_id
            case display_name
            case avatar_url
            case avatar_thumbnail_url
            case player_number
            case preferred_position_code
            case joined_at
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            membership_id = try c.decode(UUID.self, forKey: .membership_id)
            managed_player_id = try c.decode(UUID.self, forKey: .managed_player_id)
            display_name = try c.decodeIfPresent(String.self, forKey: .display_name)
            avatar_url = try c.decodeIfPresent(String.self, forKey: .avatar_url)
            avatar_thumbnail_url = try c.decodeIfPresent(String.self, forKey: .avatar_thumbnail_url)
            // RPC returns smallint — Int-only decode fails the whole array (silent try? → []).
            player_number = FanManagedPlayerService.decodeFlexibleInt(c, forKey: .player_number)
            preferred_position_code = try c.decodeIfPresent(String.self, forKey: .preferred_position_code)
            joined_at = FanManagedPlayerService.decodeFlexibleTimestampString(c, forKey: .joined_at)
        }
    }

    fileprivate static func decodeFlexibleInt<K: CodingKey>(
        _ c: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Int? {
        if let intVal = try? c.decodeIfPresent(Int.self, forKey: key) {
            return intVal
        }
        if let small = try? c.decodeIfPresent(Int16.self, forKey: key) {
            return Int(small)
        }
        if let doubleVal = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Int(doubleVal)
        }
        if let raw = try? c.decodeIfPresent(String.self, forKey: key) {
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Accept string or date-encoded timestamps so seat list decode never fails the batch.
    fileprivate static func decodeFlexibleTimestampString<K: CodingKey>(
        _ c: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> String? {
        if let raw = try? c.decodeIfPresent(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let date = try? c.decodeIfPresent(Date.self, forKey: key) {
            return isoFractional.string(from: date)
        }
        return nil
    }

    private struct EventRSVPRow: Decodable {
        let membership_id: UUID
        let managed_player_id: UUID?
        let display_name: String?
        let status: String?
        let updated_at: String?
    }

    // MARK: - Players

    func listMyManagedPlayers() async throws -> [FanManagedPlayer] {
        let rows: [PlayerRow] = try await client
            .rpc("list_my_managed_players")
            .execute()
            .value
        return rows.map { $0.asModel() }
    }

    @discardableResult
    func createManagedPlayer(
        firstName: String,
        lastName: String,
        displayName: String? = nil,
        birthYear: Int? = nil,
        avatarURL: String? = nil,
        avatarThumbnailURL: String? = nil
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_first_name: String
            let p_last_name: String
            let p_display_name: String?
            let p_birth_year: Int?
            let p_avatar_url: String?
            let p_avatar_thumbnail_url: String?
        }
        let params = Params(
            p_first_name: FanManagedPlayerValidation.normalized(firstName),
            p_last_name: FanManagedPlayerValidation.normalized(lastName),
            p_display_name: Self.trimmedOrNil(displayName),
            p_birth_year: birthYear,
            p_avatar_url: avatarURL,
            p_avatar_thumbnail_url: avatarThumbnailURL
        )
        let id: UUID = try await client
            .rpc("create_managed_player", params: params)
            .execute()
            .value
        return id
    }

    func updateManagedPlayer(
        managedPlayerId: UUID,
        firstName: String? = nil,
        lastName: String? = nil,
        displayName: String? = nil,
        birthYear: Int? = nil,
        clearBirthYear: Bool = false,
        avatarURL: String? = nil,
        avatarThumbnailURL: String? = nil,
        clearAvatar: Bool = false
    ) async throws {
        struct Params: Encodable {
            let p_managed_player_id: UUID
            let p_first_name: String?
            let p_last_name: String?
            let p_display_name: String?
            let p_birth_year: Int?
            let p_avatar_url: String?
            let p_avatar_thumbnail_url: String?
            let p_clear_birth_year: Bool
            let p_clear_avatar: Bool
        }
        let params = Params(
            p_managed_player_id: managedPlayerId,
            p_first_name: Self.trimmedOrNil(firstName),
            p_last_name: lastName?.trimmingCharacters(in: .whitespacesAndNewlines),
            p_display_name: Self.trimmedOrNil(displayName),
            p_birth_year: birthYear,
            p_avatar_url: avatarURL,
            p_avatar_thumbnail_url: avatarThumbnailURL,
            p_clear_birth_year: clearBirthYear,
            p_clear_avatar: clearAvatar
        )
        try await client
            .rpc("update_managed_player", params: params)
            .execute()
    }

    // MARK: - Avatar storage

    /// Reuses the `user-avatars` bucket under `{auth.uid()}/managed-players/{playerId}/…`
    /// so existing Storage RLS (first path segment = auth.uid()) authorizes guardians only.
    struct UploadedManagedPlayerAvatarURLs: Sendable {
        let fullURL: String
        let thumbnailURL: String
    }

    private static let avatarStorageBucket = "user-avatars"

    private static func makeVersionedAvatarFileName() -> String {
        "avatar-\(UUID().uuidString.lowercased()).jpg"
    }

    private static func companionAvatarThumbnailFileName(for fullFileName: String) -> String {
        if let dot = fullFileName.lastIndex(of: "."), dot < fullFileName.endIndex {
            let base = String(fullFileName[..<dot])
            let ext = String(fullFileName[fullFileName.index(after: dot)...])
            return "\(base)_thumb.\(ext)"
        }
        return fullFileName + "_thumb.jpg"
    }

    private static func storagePath(fromPublicURL publicURL: String, bucket: String) -> String? {
        let trimmed = publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let marker = "/storage/v1/object/public/\(bucket)/"
        guard let range = trimmed.range(of: marker) else { return nil }
        let path = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func uploadManagedPlayerAvatar(
        managedPlayerId: UUID,
        imageData: Data
    ) async throws -> UploadedManagedPlayerAvatarURLs {
        let session = try await client.auth.session
        let folder = session.user.id.uuidString.lowercased()
        let playerFolder = managedPlayerId.uuidString.lowercased()
        let fileName = Self.makeVersionedAvatarFileName()
        let thumbName = Self.companionAvatarThumbnailFileName(for: fileName)
        let pathFull = "\(folder)/managed-players/\(playerFolder)/\(fileName)"
        let pathThumb = "\(folder)/managed-players/\(playerFolder)/\(thumbName)"

        let uploadFull = ImageCompression.jpegDataForUpload(from: imageData, preset: .avatar)
        let uploadThumb = ImageCompression.jpegDataForUpload(from: imageData, preset: .avatarThumbnail)

        try await client.storage
            .from(Self.avatarStorageBucket)
            .upload(
                pathFull,
                data: uploadFull,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )
        try await client.storage
            .from(Self.avatarStorageBucket)
            .upload(
                pathThumb,
                data: uploadThumb,
                options: FileOptions(contentType: "image/jpeg", upsert: false)
            )

        let publicFull = try client.storage
            .from(Self.avatarStorageBucket)
            .getPublicURL(path: pathFull)
        let publicThumb = try client.storage
            .from(Self.avatarStorageBucket)
            .getPublicURL(path: pathThumb)

        let fullStr = ImageDisplayURL.canonicalStorageURLString(publicFull.absoluteString)
        let thumbStr = ImageDisplayURL.canonicalStorageURLString(publicThumb.absoluteString)
        guard !fullStr.isEmpty else {
            throw FanManagedPlayerServiceError.avatarUploadFailed
        }
        return UploadedManagedPlayerAvatarURLs(
            fullURL: fullStr,
            thumbnailURL: thumbStr.isEmpty ? fullStr : thumbStr
        )
    }

    /// Best-effort cleanup after a successful DB update points at new URLs (or clears them).
    func deleteReplacedManagedPlayerAvatarIfNeeded(
        oldFullURL: String?,
        oldThumbnailURL: String?,
        newFullURL: String?,
        newThumbnailURL: String?
    ) async {
        let candidates = [
            (oldFullURL, newFullURL),
            (oldThumbnailURL, newThumbnailURL)
        ]
        for (oldRaw, newRaw) in candidates {
            let old = ImageDisplayURL.canonicalStorageURLString(oldRaw)
            let new = ImageDisplayURL.canonicalStorageURLString(newRaw)
            guard !old.isEmpty, old != new else { continue }
            guard let path = Self.storagePath(fromPublicURL: old, bucket: Self.avatarStorageBucket) else {
                continue
            }
            guard path.contains("/managed-players/") else { continue }
            _ = try? await client.storage
                .from(Self.avatarStorageBucket)
                .remove(paths: [path])
        }
    }

    /// Soft archive. Active Team seats are soft-left server-side so roster and
    /// lineup history survive.
    func archiveManagedPlayer(managedPlayerId: UUID) async throws {
        struct Params: Encodable { let p_managed_player_id: UUID }
        try await client
            .rpc("archive_managed_player", params: Params(p_managed_player_id: managedPlayerId))
            .execute()
    }

    // MARK: - Teams

    func listTeamMemberships(managedPlayerId: UUID) async throws -> [FanManagedPlayerTeamMembership] {
        struct Params: Encodable { let p_managed_player_id: UUID }
        let rows: [TeamMembershipRow] = try await client
            .rpc(
                "list_managed_player_team_memberships",
                params: Params(p_managed_player_id: managedPlayerId)
            )
            .execute()
            .value
        return rows.map { row in
            FanManagedPlayerTeamMembership(
                id: row.membership_id,
                teamId: row.team_id,
                teamName: Self.trimmedOrNil(row.team_name) ?? "Team",
                sport: row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                logoURL: Self.trimmedOrNil(
                    ImageDisplayURL.canonicalStorageURLString(row.logo_url)
                ),
                logoThumbnailURL: Self.trimmedOrNil(
                    ImageDisplayURL.canonicalStorageURLString(row.logo_thumbnail_url)
                ),
                colorHex: row.color_hex,
                playerNumber: row.player_number,
                preferredPositionCode: row.preferred_position_code,
                joinedAt: Self.parseDate(row.joined_at)
            )
        }
    }

    /// Drives the Team Overview "My Players" card. Empty for users without kids
    /// on this Team, which is how the card stays hidden.
    func listMyManagedPlayersOnTeam(teamId: UUID) async throws -> [FanTeamManagedPlayerSeat] {
        struct Params: Encodable { let p_team_id: UUID }
        let rows: [TeamSeatRow] = try await client
            .rpc("list_my_managed_players_on_team", params: Params(p_team_id: teamId))
            .execute()
            .value
        return rows.map { row in
            FanTeamManagedPlayerSeat(
                id: row.membership_id,
                managedPlayerId: row.managed_player_id,
                displayName: Self.trimmedOrNil(row.display_name) ?? "Player",
                avatarURL: Self.trimmedOrNil(
                    ImageDisplayURL.canonicalStorageURLString(row.avatar_url)
                ),
                avatarThumbnailURL: Self.trimmedOrNil(
                    ImageDisplayURL.canonicalStorageURLString(row.avatar_thumbnail_url)
                ),
                playerNumber: row.player_number,
                preferredPositionCode: row.preferred_position_code,
                joinedAt: Self.parseDate(row.joined_at)
            )
        }
    }

    @discardableResult
    func addManagedPlayerToTeam(teamId: UUID, managedPlayerId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_managed_player_id: UUID
        }
        let membershipId: UUID = try await client
            .rpc(
                "add_managed_player_to_fan_team",
                params: Params(p_team_id: teamId, p_managed_player_id: managedPlayerId)
            )
            .execute()
            .value
        return membershipId
    }

    /// Accepts a Team invitation on behalf of a managed player. The guardian does
    /// **not** join the Team themselves.
    @discardableResult
    func acceptInvitationAsManagedPlayer(
        invitationId: UUID,
        managedPlayerId: UUID
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_invitation_id: UUID
            let p_managed_player_id: UUID
        }
        let teamId: UUID = try await client
            .rpc(
                "accept_fan_team_invitation_as_managed_player",
                params: Params(p_invitation_id: invitationId, p_managed_player_id: managedPlayerId)
            )
            .execute()
            .value
        return teamId
    }

    /// Atomic multi-participant invite accept: Myself and/or one-or-more managed players.
    /// One backend transaction; invitation is consumed once.
    @discardableResult
    func acceptInvitationForParticipants(
        invitationId: UUID,
        includeSelf: Bool,
        managedPlayerIds: [UUID]
    ) async throws -> UUID {
        struct Params: Encodable {
            let p_invitation_id: UUID
            let p_include_self: Bool
            let p_managed_player_ids: [UUID]
        }
        let uniqueIds = Array(Set(managedPlayerIds))
        let teamId: UUID = try await client
            .rpc(
                "accept_fan_team_invitation_for_participants",
                params: Params(
                    p_invitation_id: invitationId,
                    p_include_self: includeSelf,
                    p_managed_player_ids: uniqueIds
                )
            )
            .execute()
            .value
        return teamId
    }

    // MARK: - RSVP

    /// Roster-seat RSVP. Authenticated seats are routed back to the legacy
    /// pickup-request write server-side; managed seats write `fan_team_event_rsvps`.
    func setRSVP(gameId: UUID, membershipId: UUID, status: FanTeamGameRSVPStatus) async throws {
        struct Params: Encodable {
            let p_game_id: UUID
            let p_membership_id: UUID
            let p_status: String
        }
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
    }

    /// Managed-player RSVPs for one Team event, keyed by roster seat.
    func listEventRSVPs(teamId: UUID, gameId: UUID) async throws -> [UUID: FanTeamGameRSVPStatus] {
        struct Params: Encodable {
            let p_team_id: UUID
            let p_pickup_game_id: UUID
        }
        let rows: [EventRSVPRow] = try await client
            .rpc(
                "list_fan_team_event_rsvps",
                params: Params(p_team_id: teamId, p_pickup_game_id: gameId)
            )
            .execute()
            .value
        var result: [UUID: FanTeamGameRSVPStatus] = [:]
        for row in rows {
            guard let raw = row.status,
                  let status = FanTeamGameRSVPStatus(rawValue: raw) else { continue }
            result[row.membership_id] = status
        }
        return result
    }
}

enum FanManagedPlayerServiceError: LocalizedError {
    case avatarUploadFailed

    var errorDescription: String? {
        switch self {
        case .avatarUploadFailed:
            return "Unable to upload player photo."
        }
    }
}
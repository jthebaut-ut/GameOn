import CoreLocation
import Foundation
import Supabase

struct ChatLiveLocationSessionRow: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sender_user_id: UUID
    let conversation_kind: String
    let conversation_id: UUID
    let message_id: UUID?
    let status: String
    let started_at: String
    let expires_at: String?
    let stopped_at: String?
    let latest_lat: Double
    let latest_lng: Double
    let latest_accuracy_m: Double?
    let latest_place_label: String?
    let latest_updated_at: String
    let created_at: String

    var isActive: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active"
            && !isPastExpiry
    }

    var isPastExpiry: Bool {
        guard let raw = expires_at,
              let date = ISO8601DateFormatter.chatLocation.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw) else {
            // Non-null expires_at is required server-side; treat missing as ended.
            return true
        }
        return date <= Date()
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latest_lat, longitude: latest_lng)
    }
}

enum ChatLiveLocationSessionServiceError: LocalizedError {
    case notAuthenticated
    case createFailed
    case updateFailed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .createFailed: return "Could not start live location session"
        case .updateFailed: return "Could not update live location"
        case .unavailable: return "Live location unavailable"
        }
    }
}

final class ChatLiveLocationSessionService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func createSession(
        senderUserId: UUID,
        conversationKind: String,
        conversationId: UUID,
        latitude: Double,
        longitude: Double,
        accuracyM: Double?,
        placeLabel: String?,
        expiresAt: Date
    ) async throws -> ChatLiveLocationSessionRow {
        struct Insert: Encodable {
            let sender_user_id: UUID
            let conversation_kind: String
            let conversation_id: UUID
            let status: String
            let expires_at: String
            let latest_lat: Double
            let latest_lng: Double
            let latest_accuracy_m: Double?
            let latest_place_label: String?
        }

        let insert = Insert(
            sender_user_id: senderUserId,
            conversation_kind: conversationKind,
            conversation_id: conversationId,
            status: "active",
            expires_at: ISO8601DateFormatter.chatLocation.string(from: expiresAt),
            latest_lat: latitude,
            latest_lng: longitude,
            latest_accuracy_m: accuracyM,
            latest_place_label: placeLabel
        )

        do {
            return try await client
                .from("chat_live_location_sessions")
                .insert(insert)
                .select()
                .single()
                .execute()
                .value
        } catch {
#if DEBUG
            print("[ChatLiveLocation] event=createFailed")
#endif
            throw ChatLiveLocationSessionServiceError.createFailed
        }
    }

    func updateSessionCoordinates(
        sessionId: UUID,
        latitude: Double,
        longitude: Double,
        accuracyM: Double?,
        placeLabel: String?
    ) async throws {
        struct RPCParams: Encodable {
            let p_session_id: String
            let p_lat: Double
            let p_lng: Double
            let p_accuracy: Double?
            let p_place_label: String?
        }
        do {
            try await client.rpc(
                "update_chat_live_location_coords",
                params: RPCParams(
                    p_session_id: sessionId.uuidString.lowercased(),
                    p_lat: latitude,
                    p_lng: longitude,
                    p_accuracy: accuracyM,
                    p_place_label: placeLabel
                )
            ).execute()
        } catch {
#if DEBUG
            print("[ChatLiveLocation] event=updateFailed sessionShort=\(String(sessionId.uuidString.prefix(8)).lowercased())")
#endif
            // Fallback for DBs that have table policies but not RPCs yet.
            do {
                struct Patch: Encodable {
                    let latest_lat: Double
                    let latest_lng: Double
                    let latest_accuracy_m: Double?
                    let latest_place_label: String?
                    let latest_updated_at: String
                }
                let patch = Patch(
                    latest_lat: latitude,
                    latest_lng: longitude,
                    latest_accuracy_m: accuracyM,
                    latest_place_label: placeLabel,
                    latest_updated_at: ISO8601DateFormatter.chatLocation.string(from: Date())
                )
                try await client
                    .from("chat_live_location_sessions")
                    .update(patch)
                    .eq("id", value: sessionId.uuidString.lowercased())
                    .eq("status", value: "active")
                    .eq("sender_user_id", value: (try await currentUserId()).uuidString.lowercased())
                    .execute()
            } catch {
                throw ChatLiveLocationSessionServiceError.updateFailed
            }
        }
    }

    func stopSession(sessionId: UUID) async throws {
        struct RPCParams: Encodable {
            let p_session_id: String
        }
        do {
            try await client.rpc(
                "stop_chat_live_location_session",
                params: RPCParams(p_session_id: sessionId.uuidString.lowercased())
            ).execute()
        } catch {
            // Fallback: status + stopped_at only (immutable trigger still required).
            struct Patch: Encodable {
                let status: String
                let stopped_at: String
            }
            let patch = Patch(
                status: "stopped",
                stopped_at: ISO8601DateFormatter.chatLocation.string(from: Date())
            )
            try await client
                .from("chat_live_location_sessions")
                .update(patch)
                .eq("id", value: sessionId.uuidString.lowercased())
                .eq("sender_user_id", value: (try await currentUserId()).uuidString.lowercased())
                .execute()
        }
    }

    func fetchSession(id: UUID) async throws -> ChatLiveLocationSessionRow? {
        let rows: [ChatLiveLocationSessionRow] = try await client
            .from("chat_live_location_sessions")
            .select()
            .eq("id", value: id.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func fetchActiveSession(
        senderUserId: UUID,
        conversationKind: String,
        conversationId: UUID
    ) async throws -> ChatLiveLocationSessionRow? {
        let rows: [ChatLiveLocationSessionRow] = try await client
            .from("chat_live_location_sessions")
            .select()
            .eq("sender_user_id", value: senderUserId.uuidString.lowercased())
            .eq("conversation_kind", value: conversationKind)
            .eq("conversation_id", value: conversationId.uuidString.lowercased())
            .eq("status", value: "active")
            .order("started_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Active sessions owned by the current user (for explicit relaunch restore).
    func fetchMyActiveSessions(senderUserId: UUID) async throws -> [ChatLiveLocationSessionRow] {
        try await client
            .from("chat_live_location_sessions")
            .select()
            .eq("sender_user_id", value: senderUserId.uuidString.lowercased())
            .eq("status", value: "active")
            .order("started_at", ascending: false)
            .limit(5)
            .execute()
            .value
    }

    private func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }
}

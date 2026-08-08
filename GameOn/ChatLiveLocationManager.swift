import Combine
import CoreLocation
import Foundation
import MapKit
import Supabase

/// Owns When-In-Use location capture for chat shares and active live-location sessions.
/// Discover location permission is never treated as chat-share consent.
@MainActor
final class ChatLiveLocationManager: NSObject, ObservableObject {
    static let shared = ChatLiveLocationManager()

    @Published private(set) var activeOutgoingSessionId: UUID?
    @Published private(set) var activeOutgoingConversationKey: String?
    @Published private(set) var lastKnownCoordinate: CLLocationCoordinate2D?
    @Published private(set) var lastKnownAccuracy: CLLocationAccuracy?
    @Published private(set) var lastPlaceLabel: String?
    @Published private(set) var authorizationDenied = false
    @Published var sessionCache: [UUID: ChatLiveLocationSessionRow] = [:]

    private let locationManager = CLLocationManager()
    private let sessionService = ChatLiveLocationSessionService()
    private var oneShotContinuation: CheckedContinuation<CLLocation?, Never>?
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var updateTask: Task<Void, Never>?
    private var lastUploadAt: Date?
    private var lastUploadedCoordinate: CLLocationCoordinate2D?
    private var sessionExpiresAt: Date?
    private var realtimeTask: Task<Void, Never>?
    private var watchedSessionIds: Set<UUID> = []

    private let minUploadInterval: TimeInterval = 25
    private let minMoveMeters: CLLocationDistance = 35
    private let persistedOutgoingSessionKey = "gameon.chat.liveLocation.activeOutgoingSessionId"
    private var didAttemptRestore = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 25
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.allowsBackgroundLocationUpdates = false
    }

    var hasActiveOutgoingSession: Bool { activeOutgoingSessionId != nil }

    /// After relaunch/login: resume GPS only for an explicitly active, unexpired server session.
    /// Never invents a new share; never resumes stopped/expired sessions.
    func restoreActiveOutgoingSessionsIfNeeded(userId: UUID) async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard activeOutgoingSessionId == nil else { return }

        do {
            let rows = try await sessionService.fetchMyActiveSessions(senderUserId: userId)
            guard let row = rows.first(where: { $0.isActive }) else {
                UserDefaults.standard.removeObject(forKey: persistedOutgoingSessionKey)
                return
            }
            sessionCache[row.id] = row
            beginTracking(session: row)
        } catch {
#if DEBUG
            print("[ChatLiveLocation] restore failed")
#endif
            // Allow a later retry if auth/table was not ready.
            didAttemptRestore = false
        }
    }

    // MARK: - One-shot capture (after explicit user confirmation)

    /// Captures When-In-Use location. Call only after the user confirms a chat share action.
    /// Never requests authorization from launch, chat open, or menu open alone.
    func captureCurrentLocation() async -> (location: CLLocation, placeLabel: String?)? {
        authorizationDenied = false
        let status = await ensureWhenInUseAuthorizationAfterExplicitShareIntent()
        switch status {
        case .denied, .restricted:
            authorizationDenied = true
            return nil
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined:
            // User dismissed the system prompt without granting.
            authorizationDenied = true
            return nil
        @unknown default:
            authorizationDenied = true
            return nil
        }

        let location = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            oneShotContinuation = cont
            locationManager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                await MainActor.run {
                    guard let self, let pending = self.oneShotContinuation else { return }
                    self.oneShotContinuation = nil
                    pending.resume(returning: nil)
                }
            }
        }
        guard let location else { return nil }
        lastKnownCoordinate = location.coordinate
        lastKnownAccuracy = location.horizontalAccuracy
        let label = await reverseGeocodeLabel(for: location.coordinate)
        lastPlaceLabel = label
        return (location, label)
    }

    /// Requests When-In-Use only when status is `.notDetermined`.
    /// Denied/restricted never re-triggers the system prompt.
    private func ensureWhenInUseAuthorizationAfterExplicitShareIntent() async -> CLAuthorizationStatus {
        let current = locationManager.authorizationStatus
        switch current {
        case .notDetermined:
            break
        default:
            return current
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
            authorizationContinuation = cont
            locationManager.requestWhenInUseAuthorization()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await MainActor.run {
                    guard let self, let pending = self.authorizationContinuation else { return }
                    self.authorizationContinuation = nil
                    pending.resume(returning: self.locationManager.authorizationStatus)
                }
            }
        }
    }

    // MARK: - Live session

    func startLiveSession(
        senderUserId: UUID,
        conversationKind: String,
        conversationId: UUID,
        duration: ChatLiveLocationDuration,
        location: CLLocation,
        placeLabel: String?
    ) async throws -> ChatLiveLocationSessionRow {
        let row = try await sessionService.createSession(
            senderUserId: senderUserId,
            conversationKind: conversationKind,
            conversationId: conversationId,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            placeLabel: placeLabel,
            expiresAt: duration.expiresAt
        )
        beginTracking(session: row)
        sessionCache[row.id] = row
        return row
    }

    func stopLiveSession(sessionId: UUID) async {
        do {
            try await sessionService.stopSession(sessionId: sessionId)
        } catch {
#if DEBUG
            print("[ChatLiveLocation] event=stopFailed sessionShort=\(String(sessionId.uuidString.prefix(8)).lowercased())")
#endif
        }
        if activeOutgoingSessionId == sessionId {
            endTracking()
        }
        markSessionStoppedLocally(sessionId: sessionId)
    }

    /// Stops local GPS immediately, then attempts server stop while auth is still valid.
    /// Must be awaited **before** local Supabase session invalidation / cache clearing.
    /// Bound so logout cannot hang indefinitely.
    func stopOutgoingSessionsBeforeAuthInvalidation(
        timeoutNanoseconds: UInt64 = 2_500_000_000
    ) async {
        var ids: [UUID] = []
        if let id = activeOutgoingSessionId {
            ids.append(id)
        }
        if let raw = UserDefaults.standard.string(forKey: persistedOutgoingSessionKey),
           let persisted = UUID(uuidString: raw),
           !ids.contains(persisted) {
            ids.append(persisted)
        }

        // Local GPS must stop even if the network stop fails or times out.
        endTracking()
#if DEBUG
        print("[ChatLiveLocation] event=logoutStopBegin count=\(ids.count)")
#endif

        guard !ids.isEmpty else {
            didAttemptRestore = false
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for id in ids {
                    do {
                        try await self.sessionService.stopSession(sessionId: id)
                        self.markSessionStoppedLocally(sessionId: id)
#if DEBUG
                        print("[ChatLiveLocation] event=logoutStopOk sessionShort=\(String(id.uuidString.prefix(8)).lowercased())")
#endif
                    } catch {
#if DEBUG
                        print("[ChatLiveLocation] event=logoutStopFailed sessionShort=\(String(id.uuidString.prefix(8)).lowercased())")
#endif
                        self.markSessionStoppedLocally(sessionId: id)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
        }

        // Never restart sharing after logout stop attempt.
        endTracking()
        didAttemptRestore = false
#if DEBUG
        print("[ChatLiveLocation] event=logoutStopFinished")
#endif
    }

    func stopAllOutgoingSessionsForLogout() async {
        await stopOutgoingSessionsBeforeAuthInvalidation()
        clearLocalLiveLocationStateAfterLogout()
    }

    /// Residual local wipe after auth is already cleared (no server calls).
    func clearLocalLiveLocationStateAfterLogout() {
        endTracking()
        sessionCache.removeAll()
        watchedSessionIds.removeAll()
        didAttemptRestore = false
    }

    private func markSessionStoppedLocally(sessionId: UUID) {
        if let cached = sessionCache[sessionId] {
            sessionCache[sessionId] = ChatLiveLocationSessionRow(
                id: cached.id,
                sender_user_id: cached.sender_user_id,
                conversation_kind: cached.conversation_kind,
                conversation_id: cached.conversation_id,
                message_id: cached.message_id,
                status: "stopped",
                started_at: cached.started_at,
                expires_at: cached.expires_at,
                stopped_at: ISO8601DateFormatter.chatLocation.string(from: Date()),
                latest_lat: cached.latest_lat,
                latest_lng: cached.latest_lng,
                latest_accuracy_m: cached.latest_accuracy_m,
                latest_place_label: cached.latest_place_label,
                latest_updated_at: cached.latest_updated_at,
                created_at: cached.created_at
            )
        }
    }

    enum SessionRefreshOutcome: Equatable {
        case updated
        case purgedUnauthorizedOrMissing
        case transientFailure
    }

    @discardableResult
    func refreshSession(id: UUID) async -> SessionRefreshOutcome {
        do {
            if let row = try await sessionService.fetchSession(id: id) {
                sessionCache[id] = row
                if activeOutgoingSessionId == id, !row.isActive {
                    endTracking()
                }
                return .updated
            }
            // Empty result under RLS: treat as inaccessible / missing — purge stale coords.
            purgeWatchedSession(id: id, reason: "missingOrDenied")
            return .purgedUnauthorizedOrMissing
        } catch {
            let message = error.localizedDescription.lowercased()
            let looksAuth =
                message.contains("permission")
                || message.contains("row-level")
                || message.contains("42501")
                || message.contains("not authorized")
                || message.contains("jwt")
            if looksAuth {
                purgeWatchedSession(id: id, reason: "authDenied")
                return .purgedUnauthorizedOrMissing
            }
#if DEBUG
            print("[ChatLiveLocation] event=refreshTransient sessionShort=\(String(id.uuidString.prefix(8)).lowercased())")
#endif
            return .transientFailure
        }
    }

    func purgeWatchedSession(id: UUID, reason: String) {
        sessionCache.removeValue(forKey: id)
        watchedSessionIds.remove(id)
        if activeOutgoingSessionId == id {
            endTracking()
        }
#if DEBUG
        print("[ChatLiveLocation] event=sessionPurged reason=\(reason) sessionShort=\(String(id.uuidString.prefix(8)).lowercased())")
#endif
    }

    func watchSession(id: UUID) {
        watchedSessionIds.insert(id)
        Task { await refreshSession(id: id) }
        ensureRealtimeLoop()
    }

    func unwatchSession(id: UUID) {
        watchedSessionIds.remove(id)
    }

    // MARK: - Private tracking

    private func beginTracking(session: ChatLiveLocationSessionRow) {
        activeOutgoingSessionId = session.id
        activeOutgoingConversationKey = "\(session.conversation_kind):\(session.conversation_id.uuidString.lowercased())"
        UserDefaults.standard.set(session.id.uuidString.lowercased(), forKey: persistedOutgoingSessionKey)
        sessionExpiresAt = session.expires_at.flatMap {
            ISO8601DateFormatter.chatLocation.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
        }
        lastUploadAt = Date()
        lastUploadedCoordinate = CLLocationCoordinate2D(latitude: session.latest_lat, longitude: session.latest_lng)
        locationManager.startUpdatingLocation()
        scheduleExpiryTimer()
    }

    private func endTracking() {
        activeOutgoingSessionId = nil
        activeOutgoingConversationKey = nil
        sessionExpiresAt = nil
        UserDefaults.standard.removeObject(forKey: persistedOutgoingSessionKey)
        updateTask?.cancel()
        updateTask = nil
        locationManager.stopUpdatingLocation()
    }

    private func scheduleExpiryTimer() {
        updateTask?.cancel()
        guard let expires = sessionExpiresAt else { return }
        let delay = expires.timeIntervalSinceNow
        guard delay > 0 else {
            if let id = activeOutgoingSessionId {
                Task { await stopLiveSession(sessionId: id) }
            }
            return
        }
        updateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if let id = self.activeOutgoingSessionId {
                await self.stopLiveSession(sessionId: id)
            }
        }
    }

    private func maybeUpload(location: CLLocation) {
        guard let sessionId = activeOutgoingSessionId else { return }
        if let expires = sessionExpiresAt, Date() >= expires {
            Task { await stopLiveSession(sessionId: sessionId) }
            return
        }
        let now = Date()
        if let lastUploadAt, now.timeIntervalSince(lastUploadAt) < minUploadInterval {
            if let lastUploadedCoordinate {
                let moved = CLLocation(latitude: lastUploadedCoordinate.latitude, longitude: lastUploadedCoordinate.longitude)
                    .distance(from: location)
                if moved < minMoveMeters { return }
            } else {
                return
            }
        }
        lastUploadAt = now
        lastUploadedCoordinate = location.coordinate
        Task {
            let label = await reverseGeocodeLabel(for: location.coordinate)
            do {
                try await sessionService.updateSessionCoordinates(
                    sessionId: sessionId,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    accuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                    placeLabel: label
                )
                await refreshSession(id: sessionId)
            } catch {
                // Access revoked, expiry, or auth failure: stop local GPS immediately.
                // Server stop uses the sender-only stop policy (works after chat access loss).
                await stopLiveSession(sessionId: sessionId)
            }
        }
    }

    /// Place/city label for chat cards — same format as the former CLPlacemark path:
    /// `"Locality, AdministrativeArea"` when available, otherwise place name.
    /// Uses MapKit reverse geocoding (`MKReverseGeocodingRequest`); CLGeocoder is deprecated on iOS 26.
    private func reverseGeocodeLabel(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else {
            return nil
        }

        let representations = item.addressRepresentations
        let locality = Self.trimmedNonEmpty(representations?.cityName)
        let administrativeArea = Self.administrativeArea(
            cityName: locality,
            cityWithContext: Self.trimmedNonEmpty(representations?.cityWithContext)
        )
        let parts = [locality, administrativeArea].compactMap { $0 }
        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }

        if let name = Self.trimmedNonEmpty(item.name) {
            return name
        }
        // Closest remaining fallbacks when structured locality/region are absent.
        return Self.trimmedNonEmpty(item.address?.shortAddress)
            ?? Self.trimmedNonEmpty(item.address?.fullAddress)
    }

    /// Extracts the administrative-area token from MapKit's `cityWithContext`
    /// (e.g. `"Denver, CO"` → `"CO"`), matching prior `CLPlacemark.administrativeArea` usage.
    private static func administrativeArea(cityName: String?, cityWithContext: String?) -> String? {
        guard
            let cityWithContext,
            let cityName,
            cityWithContext.localizedCaseInsensitiveContains(cityName),
            let commaIndex = cityWithContext.firstIndex(of: ",")
        else {
            return nil
        }
        let remainder = cityWithContext[cityWithContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.split(separator: ",").first.map(String.init).flatMap(trimmedNonEmpty)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ensureRealtimeLoop() {
        guard realtimeTask == nil else { return }
        realtimeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ids = Array(self.watchedSessionIds)
                for id in ids {
                    await self.refreshSession(id: id)
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }
}

extension ChatLiveLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if let pendingAuth = authorizationContinuation, status != .notDetermined {
                authorizationContinuation = nil
                pendingAuth.resume(returning: status)
            }
            switch status {
            case .denied, .restricted:
                authorizationDenied = true
                if let pending = oneShotContinuation {
                    oneShotContinuation = nil
                    pending.resume(returning: nil)
                }
                if let id = activeOutgoingSessionId {
                    await stopLiveSession(sessionId: id)
                }
            case .authorizedAlways, .authorizedWhenInUse:
                authorizationDenied = false
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            lastKnownCoordinate = location.coordinate
            lastKnownAccuracy = location.horizontalAccuracy
            if let pending = oneShotContinuation {
                oneShotContinuation = nil
                pending.resume(returning: location)
            }
            if activeOutgoingSessionId != nil {
                maybeUpload(location: location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
#if DEBUG
            print("[ChatLiveLocation] location error=\(error.localizedDescription)")
#endif
            if let pending = oneShotContinuation {
                oneShotContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }
}

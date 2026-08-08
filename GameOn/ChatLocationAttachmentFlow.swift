import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Conversation context for chat location / On My Way shares.
struct ChatLocationShareContext: Equatable {
    enum Kind: String {
        case direct
        case group
    }

    let kind: Kind
    let conversationId: UUID
    let audienceLabel: String
    let memberCount: Int
    let senderDisplayName: String
    let senderUserId: UUID
    /// Prefill destination for pickup chats.
    let pickupDestinationName: String?
    let pickupLatitude: Double?
    let pickupLongitude: Double?
    let pickupGameId: UUID?
}

enum ChatLocationAttachmentAction: Identifiable, Equatable {
    case shareCurrent
    case live15
    case live60
    case onMyWay

    var id: String {
        switch self {
        case .shareCurrent: return "current"
        case .live15: return "live15"
        case .live60: return "live60"
        case .onMyWay: return "onMyWay"
        }
    }
}

/// Composer attachment host: action sheet → consent → capture → send.
struct ChatLocationAttachmentModifier: ViewModifier {
    let context: ChatLocationShareContext?
    let languageCode: String
    let isEnabled: Bool
    let sendStructuredBody: (String) async -> String?
    /// Optional venue favorites for On My Way destination picker.
    var favoriteVenues: [BarVenue] = []
    var recentSharedCoordinate: (name: String, lat: Double, lon: Double)? = nil

    @ObservedObject private var liveManager = ChatLiveLocationManager.shared
    @State private var showActionSheet = false
    @State private var pendingAction: ChatLocationAttachmentAction?
    @State private var showConsent = false
    @State private var showSettingsAlert = false
    @State private var showError: String?
    @State private var isWorking = false
    @State private var showOnMyWaySheet = false
    @State private var pendingOnMyWayDestination: ChatOnMyWayDestination?
    @State private var lastSendAt: Date?
    /// Avoid re-showing the Settings shortcut alert in a tight retry loop after denial.
    @State private var didPresentDeniedSettingsHint = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsActiveSharingBanner {
                    activeSharingBanner
                }
            }
            .onAppear {
                guard let context else { return }
                Task {
                    await liveManager.restoreActiveOutgoingSessionsIfNeeded(userId: context.senderUserId)
                }
            }
            .confirmationDialog(
                L10n.t("chat_location_share_location", languageCode: languageCode),
                isPresented: $showActionSheet,
                titleVisibility: .visible
            ) {
                Button(L10n.t("chat_location_share_current", languageCode: languageCode)) {
                    begin(.shareCurrent)
                }
                Button(L10n.t("chat_location_live_15", languageCode: languageCode)) {
                    begin(.live15)
                }
                Button(L10n.t("chat_location_live_60", languageCode: languageCode)) {
                    begin(.live60)
                }
                Button(L10n.t("chat_on_my_way_title", languageCode: languageCode)) {
                    begin(.onMyWay)
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
            }
            .alert(
                L10n.t("chat_location_confirm_title", languageCode: languageCode),
                isPresented: $showConsent
            ) {
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {
                    pendingAction = nil
                    pendingOnMyWayDestination = nil
                }
                Button(L10n.t("chat_location_confirm_share", languageCode: languageCode)) {
                    Task { await confirmAndShare() }
                }
            } message: {
                Text(consentMessage)
            }
            .alert(
                L10n.t("chat_location_permission_required", languageCode: languageCode),
                isPresented: $showSettingsAlert
            ) {
                Button(L10n.t("chat_location_open_settings", languageCode: languageCode)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(L10n.t("chat_location_permission_explanation", languageCode: languageCode))
            }
            .alert(
                L10n.t("chat_location_unavailable", languageCode: languageCode),
                isPresented: Binding(
                    get: { showError != nil },
                    set: { if !$0 { showError = nil } }
                )
            ) {
                Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(showError ?? "")
            }
            .sheet(isPresented: $showOnMyWaySheet) {
                if let context {
                    ChatOnMyWayDestinationSheet(
                        context: context,
                        languageCode: languageCode,
                        favoriteVenues: favoriteVenues,
                        recentSharedCoordinate: recentSharedCoordinate,
                        onCancel: { showOnMyWaySheet = false },
                        onSend: { destination in
                            showOnMyWaySheet = false
                            pendingAction = .onMyWay
                            pendingOnMyWayDestination = destination
                            showConsent = true
                        }
                    )
                }
            }
            .environment(\.chatLocationAttachmentPresenter, ChatLocationAttachmentPresenter(
                isEnabled: isEnabled && context != nil && !isWorking,
                present: { showActionSheet = true }
            ))
    }

    private var showsActiveSharingBanner: Bool {
        guard let context,
              liveManager.hasActiveOutgoingSession,
              let key = liveManager.activeOutgoingConversationKey else { return false }
        return key == "\(context.kind.rawValue):\(context.conversationId.uuidString.lowercased())"
    }

    private var activeSharingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .foregroundStyle(FGColor.accentGreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("chat_location_sharing_active_banner", languageCode: languageCode))
                    .font(.caption.weight(.bold))
                Text(L10n.t("chat_location_sharing_active_hint", languageCode: languageCode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                if let id = liveManager.activeOutgoingSessionId {
                    Task { await liveManager.stopLiveSession(sessionId: id) }
                }
            } label: {
                Text(L10n.t("chat_location_stop_sharing", languageCode: languageCode))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("chat_location_sharing_active_banner", languageCode: languageCode))
        .accessibilityHint(L10n.t("chat_location_stop_sharing", languageCode: languageCode))
    }

    private var consentMessage: String {
        guard let context, let pendingAction else { return "" }
        let privacy = L10n.t("chat_location_consent_privacy_line", languageCode: languageCode)
        let audience: String = {
            if context.kind == .direct {
                return String(
                    format: L10n.t("chat_location_share_with_person_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    context.audienceLabel
                )
            }
            return String(
                format: L10n.t("chat_location_share_with_members_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(max(1, context.memberCount))
            )
        }()
        let detail: String = {
            switch pendingAction {
            case .shareCurrent:
                return L10n.t("chat_location_confirm_one_time", languageCode: languageCode)
            case .live15:
                return L10n.t("chat_location_confirm_live_15", languageCode: languageCode)
            case .live60:
                return L10n.t("chat_location_confirm_live_60", languageCode: languageCode)
            case .onMyWay:
                return L10n.t("chat_on_my_way_confirm", languageCode: languageCode)
            }
        }()
        return "\(privacy)\n\n\(audience)\n\n\(detail)"
    }

    private func begin(_ action: ChatLocationAttachmentAction) {
        guard context != nil else { return }
        if let lastSendAt, Date().timeIntervalSince(lastSendAt) < 1.2 { return }
        pendingAction = action
        pendingOnMyWayDestination = nil
        if action == .onMyWay {
            // Destination first; confirmation (then permission) happens after destination is chosen.
            showOnMyWaySheet = true
            return
        }
        // Confirmation always precedes any When-In-Use permission request.
        showConsent = true
    }

    private func presentPermissionDeniedHelpIfNeeded() {
        guard !didPresentDeniedSettingsHint else { return }
        didPresentDeniedSettingsHint = true
        showSettingsAlert = true
    }

    private func confirmAndShare() async {
        guard let context, let pendingAction else { return }
        isWorking = true
        defer {
            isWorking = false
            self.pendingAction = nil
            self.pendingOnMyWayDestination = nil
        }

        if pendingAction == .onMyWay {
            guard let destination = pendingOnMyWayDestination else { return }
            await sendOnMyWay(destination)
            return
        }

        // Permission is requested only inside capture, after this confirmation.
        guard let captured = await liveManager.captureCurrentLocation() else {
            if liveManager.authorizationDenied {
                presentPermissionDeniedHelpIfNeeded()
            } else {
                showError = L10n.t("chat_location_unavailable", languageCode: languageCode)
            }
            return
        }

        switch pendingAction {
        case .shareCurrent:
            let payload = ChatLocationSharePayload(
                latitude: captured.location.coordinate.latitude,
                longitude: captured.location.coordinate.longitude,
                capturedAt: Date(),
                placeLabel: captured.placeLabel,
                sharedByName: context.senderDisplayName,
                sharedByUserId: context.senderUserId,
                accuracyM: captured.location.horizontalAccuracy >= 0 ? captured.location.horizontalAccuracy : nil
            )
            let body = ChatLocationShareMessage.encodeBody(payload: payload)
            if let err = await sendStructuredBody(body) {
                showError = err
            } else {
                lastSendAt = Date()
            }

        case .live15, .live60:
            let duration: ChatLiveLocationDuration = (pendingAction == .live15) ? .minutes15 : .hour1
            do {
                let session = try await liveManager.startLiveSession(
                    senderUserId: context.senderUserId,
                    conversationKind: context.kind.rawValue,
                    conversationId: context.conversationId,
                    duration: duration,
                    location: captured.location,
                    placeLabel: captured.placeLabel
                )
                let payload = ChatLiveLocationSharePayload(
                    sessionId: session.id,
                    sharedByName: context.senderDisplayName,
                    sharedByUserId: context.senderUserId,
                    expiresAt: duration.expiresAt,
                    initialPlaceLabel: captured.placeLabel
                )
                let body = ChatLiveLocationShareMessage.encodeBody(payload: payload)
                if let err = await sendStructuredBody(body) {
                    await liveManager.stopLiveSession(sessionId: session.id)
                    showError = err
                } else {
                    lastSendAt = Date()
                }
            } catch {
                showError = L10n.t("chat_location_live_start_failed", languageCode: languageCode)
            }

        case .onMyWay:
            break
        }
    }

    private func sendOnMyWay(_ destination: ChatOnMyWayDestination) async {
        guard let context else { return }
        if let lastSendAt, Date().timeIntervalSince(lastSendAt) < 1.2 { return }

        var etaMinutes: Int?
        var distanceMeters: Double?
        var etaSource = destination.manualEtaMinutes != nil ? "manual" : "none"
        var estimatedArrival: Date?

        if let manual = destination.manualEtaMinutes {
            etaMinutes = manual
            estimatedArrival = Date().addingTimeInterval(TimeInterval(manual * 60))
            etaSource = "manual"
        } else if let route = await ChatOnMyWayRouteEstimator.estimate(
            to: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)
        ) {
            etaMinutes = route.etaMinutes
            distanceMeters = route.distanceMeters
            estimatedArrival = route.arrivalDate
            etaSource = "mapkit"
        }

        let payload = ChatOnMyWayPayload(
            v: 1,
            destinationName: destination.name,
            latitude: destination.latitude,
            longitude: destination.longitude,
            sharedByName: context.senderDisplayName,
            sharedByUserId: context.senderUserId,
            departedAt: ISO8601DateFormatter.chatLocation.string(from: Date()),
            estimatedArrivalAt: estimatedArrival.map { ISO8601DateFormatter.chatLocation.string(from: $0) },
            etaMinutes: etaMinutes,
            distanceMeters: distanceMeters,
            transportMode: "driving",
            etaSource: etaSource,
            pickupGameId: destination.pickupGameId ?? context.pickupGameId,
            venueId: destination.venueId,
            liveSessionId: liveManager.activeOutgoingSessionId,
            status: "en_route",
            arrivedAt: nil
        )
        let body = ChatOnMyWayMessage.encodeBody(payload: payload)
        if let err = await sendStructuredBody(body) {
            showError = err
        } else {
            lastSendAt = Date()
        }
    }
}

// MARK: - Environment presenter for composer button

struct ChatLocationAttachmentPresenter {
    var isEnabled: Bool
    var present: () -> Void
}

private enum ChatLocationAttachmentPresenterKey: EnvironmentKey {
    static let defaultValue = ChatLocationAttachmentPresenter(isEnabled: false, present: {})
}

extension EnvironmentValues {
    var chatLocationAttachmentPresenter: ChatLocationAttachmentPresenter {
        get { self[ChatLocationAttachmentPresenterKey.self] }
        set { self[ChatLocationAttachmentPresenterKey.self] = newValue }
    }
}

extension View {
    func chatLocationAttachment(
        context: ChatLocationShareContext?,
        languageCode: String,
        isEnabled: Bool,
        favoriteVenues: [BarVenue] = [],
        recentSharedCoordinate: (name: String, lat: Double, lon: Double)? = nil,
        sendStructuredBody: @escaping (String) async -> String?
    ) -> some View {
        modifier(
            ChatLocationAttachmentModifier(
                context: context,
                languageCode: languageCode,
                isEnabled: isEnabled,
                sendStructuredBody: sendStructuredBody,
                favoriteVenues: favoriteVenues,
                recentSharedCoordinate: recentSharedCoordinate
            )
        )
    }
}

// MARK: - On My Way destination

struct ChatOnMyWayDestination: Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    var venueId: UUID? = nil
    var pickupGameId: UUID? = nil
    var manualEtaMinutes: Int? = nil
}

enum ChatOnMyWayRouteEstimator {
    struct Result {
        let etaMinutes: Int
        let distanceMeters: Double
        let arrivalDate: Date
    }

    static func estimate(to destination: CLLocationCoordinate2D) async -> Result? {
        // Only use already-available / explicitly-confirmed chat location capture.
        // Do not silently treat Discover permission as On My Way consent.
        let origin: CLLocationCoordinate2D
        if let current = await MainActor.run(body: { ChatLiveLocationManager.shared.lastKnownCoordinate }) {
            origin = current
        } else if let captured = await ChatLiveLocationManager.shared.captureCurrentLocation() {
            // Called only after On My Way share confirmation.
            origin = captured.location.coordinate
        } else {
            return nil
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile
        let directions = MKDirections(request: request)
        guard let response = try? await directions.calculate(),
              let route = response.routes.first else {
            return nil
        }
        let minutes = max(1, Int(ceil(route.expectedTravelTime / 60)))
        return Result(
            etaMinutes: minutes,
            distanceMeters: route.distance,
            arrivalDate: Date().addingTimeInterval(route.expectedTravelTime)
        )
    }
}

private struct ChatOnMyWayDestinationSheet: View {
    let context: ChatLocationShareContext
    let languageCode: String
    let favoriteVenues: [BarVenue]
    let recentSharedCoordinate: (name: String, lat: Double, lon: Double)?
    let onCancel: () -> Void
    let onSend: (ChatOnMyWayDestination) -> Void

    @State private var manualEta: Int? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            List {
                if let name = context.pickupDestinationName,
                   let lat = context.pickupLatitude,
                   let lon = context.pickupLongitude,
                   FanGeoDirectionsActions.hasUsableCoordinate(latitude: lat, longitude: lon) {
                    Section(L10n.t("chat_on_my_way_pickup_destination", languageCode: languageCode)) {
                        destinationButton(
                            title: name,
                            subtitle: L10n.t("chat_on_my_way_pickup_game", languageCode: languageCode)
                        ) {
                            onSend(
                                ChatOnMyWayDestination(
                                    name: name,
                                    latitude: lat,
                                    longitude: lon,
                                    pickupGameId: context.pickupGameId,
                                    manualEtaMinutes: manualEta
                                )
                            )
                        }
                    }
                }

                if !favoriteVenues.isEmpty {
                    Section(L10n.t("chat_on_my_way_favorite_spots", languageCode: languageCode)) {
                        ForEach(favoriteVenues.prefix(12), id: \.id) { venue in
                            if FanGeoDirectionsActions.hasUsableCoordinate(
                                latitude: venue.coordinate.latitude,
                                longitude: venue.coordinate.longitude
                            ) {
                                destinationButton(title: venue.name, subtitle: venue.address) {
                                    onSend(
                                        ChatOnMyWayDestination(
                                            name: venue.name,
                                            latitude: venue.coordinate.latitude,
                                            longitude: venue.coordinate.longitude,
                                            venueId: venue.id,
                                            manualEtaMinutes: manualEta
                                        )
                                    )
                                }
                            }
                        }
                    }
                }

                if let recent = recentSharedCoordinate,
                   FanGeoDirectionsActions.hasUsableCoordinate(latitude: recent.lat, longitude: recent.lon) {
                    Section(L10n.t("chat_on_my_way_recent_in_chat", languageCode: languageCode)) {
                        destinationButton(title: recent.name, subtitle: nil) {
                            onSend(
                                ChatOnMyWayDestination(
                                    name: recent.name,
                                    latitude: recent.lat,
                                    longitude: recent.lon,
                                    manualEtaMinutes: manualEta
                                )
                            )
                        }
                    }
                }

                Section(L10n.t("chat_on_my_way_quick_eta", languageCode: languageCode)) {
                    ForEach([5, 10, 15, 20], id: \.self) { minutes in
                        Button {
                            manualEta = (manualEta == minutes) ? nil : minutes
                        } label: {
                            HStack {
                                Text(
                                    String(
                                        format: L10n.t("chat_on_my_way_eta_minutes_format", languageCode: languageCode),
                                        locale: Locale(identifier: languageCode),
                                        Int64(minutes)
                                    )
                                )
                                Spacer()
                                if manualEta == minutes {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(FGColor.accentGreen)
                                }
                            }
                        }
                    }
                    Text(L10n.t("chat_on_my_way_estimated_by_sender", languageCode: languageCode))
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            .navigationTitle(L10n.t("chat_on_my_way_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode), action: onCancel)
                }
            }
        }
    }

    private func destinationButton(title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

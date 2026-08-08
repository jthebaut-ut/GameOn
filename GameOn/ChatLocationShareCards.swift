import Combine
import CoreLocation
import MapKit
import SwiftUI

// MARK: - One-time location card

struct ChatLocationShareChatCardView: View {
    let payload: ChatLocationSharePayload
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    var languageCode: String = L10n.defaultLanguageCode

    @Environment(\.colorScheme) private var colorScheme
    @State private var showMapsMenu = false

    var body: some View {
        chatCardChrome(isFromCurrentUser: isFromCurrentUser, showFriendAvatar: showFriendAvatar, friendPreview: friendPreview, timestamp: timestamp) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    ChatLocationShareMessage.previewLine(for: payload, languageCode: languageCode),
                    systemImage: "location.fill"
                )
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)

                miniMap(coordinate: payload.coordinate, label: payload.placeLabel)

                if let place = payload.placeLabel, !place.isEmpty {
                    Text(place)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                mapsActionRow(
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    name: payload.placeLabel ?? L10n.t("chat_location_shared_location_title", languageCode: languageCode),
                    showMapsMenu: $showMapsMenu,
                    languageCode: languageCode
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ChatLocationShareMessage.previewLine(for: payload, languageCode: languageCode))
    }
}

// MARK: - Live location card

struct ChatLiveLocationShareChatCardView: View {
    let payload: ChatLiveLocationSharePayload
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    var languageCode: String = L10n.defaultLanguageCode
    var audienceMemberCount: Int? = nil
    /// When set, session must match this conversation or the card shows unavailable (no map).
    var expectedConversationKind: String? = nil
    var expectedConversationId: UUID? = nil
    var expectedSenderUserId: UUID? = nil
    /// Authoritative display name from chat `sender_id` roster (not forgeable payload fields).
    var authoritativeDisplayName: String? = nil
    var onStopSharing: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var liveManager = ChatLiveLocationManager.shared
    @State private var showMapsMenu = false
    @State private var tick = Date()
    @State private var bindingMismatch = false

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var session: ChatLiveLocationSessionRow? {
        liveManager.sessionCache[payload.sessionId]
    }

    private var sessionMatchesConversation: Bool {
        guard let session else { return true } // until hydrated; mismatch checked after load
        if let expectedConversationKind,
           session.conversation_kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            != expectedConversationKind.lowercased() {
            return false
        }
        if let expectedConversationId, session.conversation_id != expectedConversationId {
            return false
        }
        if let expectedSenderUserId, session.sender_user_id != expectedSenderUserId {
            return false
        }
        return true
    }

    /// Active when the session row says so, or (for the sender) this is the
    /// currently tracked outgoing session — so Stop is available before cache hydration.
    private var isActive: Bool {
        guard !bindingMismatch, sessionMatchesConversation else { return false }
        if let session {
            return session.isActive
        }
        return isFromCurrentUser && liveManager.activeOutgoingSessionId == payload.sessionId
    }

    private var showsStopSharing: Bool {
        isFromCurrentUser && isActive
    }

    private var displayName: String? {
        let roster = authoritativeDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !roster.isEmpty { return roster }
        let preview = friendPreview.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    var body: some View {
        chatCardChrome(isFromCurrentUser: isFromCurrentUser, showFriendAvatar: showFriendAvatar, friendPreview: friendPreview, timestamp: timestamp) {
            if bindingMismatch || (session != nil && !sessionMatchesConversation) {
                FanGeoStructuredUnavailableCard(
                    kind: .liveLocation,
                    languageCode: languageCode,
                    isFromCurrentUser: isFromCurrentUser
                )
            } else {
                liveCardContent
            }
        }
        .onAppear {
            liveManager.watchSession(id: payload.sessionId)
            Task { await validateBindingAfterRefresh() }
        }
        .onReceive(ticker) { date in
            tick = date
            Task { await validateBindingAfterRefresh() }
        }
        .onChange(of: liveManager.sessionCache[payload.sessionId]?.latest_updated_at) { _, _ in
            if !sessionMatchesConversation {
                bindingMismatch = true
                liveManager.purgeWatchedSession(id: payload.sessionId, reason: "conversationMismatch")
            }
        }
    }

    private var liveCardContent: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "location.fill" : "location.slash.fill")
                        .foregroundStyle(isActive ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                        .accessibilityHidden(true)
                    Text(L10n.t("chat_location_live_title", languageCode: languageCode))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: 0)
                    Text(statusLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isActive ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (isActive ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                                .opacity(colorScheme == .dark ? 0.22 : 0.12),
                            in: Capsule()
                        )
                        .accessibilityLabel(statusLabel)
                }

                if let name = displayName, !isFromCurrentUser {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                if let coordinate = displayCoordinate {
                    miniMap(coordinate: coordinate, label: placeLabel)
                }

                if let placeLabel, !placeLabel.isEmpty {
                    Text(placeLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                Text(updatedLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(FGColor.mutedText(colorScheme))

                Text(countdownLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                if let audienceMemberCount, audienceMemberCount > 0, isActive {
                    Text(
                        String(
                            format: L10n.t("chat_location_shared_with_members_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            Int64(audienceMemberCount)
                        )
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                }

                if let coordinate = displayCoordinate {
                    // Recipients: Open in Maps + Directions.
                    // Sender while active: those two plus Stop Sharing (destructive).
                    mapsActionRow(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        name: placeLabel ?? L10n.t("chat_location_live_title", languageCode: languageCode),
                        showMapsMenu: $showMapsMenu,
                        languageCode: languageCode
                    )
                }

                if showsStopSharing {
                    Button(role: .destructive) {
                        // Same termination path as the floating active-sharing banner.
                        if let onStopSharing {
                            onStopSharing()
                        } else {
                            Task {
                                await ChatLiveLocationManager.shared.stopLiveSession(sessionId: payload.sessionId)
                            }
                        }
                    } label: {
                        Text(L10n.t("chat_location_stop_sharing", languageCode: languageCode))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(FGColor.dangerRed.opacity(0.14), in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                            .foregroundStyle(FGColor.dangerRed)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityLabel(L10n.t("chat_location_stop_sharing", languageCode: languageCode))
                    .accessibilityHint(L10n.t("chat_location_sharing_ended", languageCode: languageCode))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(L10n.t("chat_location_live_title", languageCode: languageCode)), \(statusLabel)")
    }

    private func validateBindingAfterRefresh() async {
        let outcome = await liveManager.refreshSession(id: payload.sessionId)
        if outcome == .purgedUnauthorizedOrMissing {
            bindingMismatch = true
            return
        }
        if !sessionMatchesConversation {
            bindingMismatch = true
            liveManager.purgeWatchedSession(id: payload.sessionId, reason: "conversationMismatch")
        }
    }

    private var displayCoordinate: CLLocationCoordinate2D? {
        guard !bindingMismatch, sessionMatchesConversation else { return nil }
        if let session {
            return session.coordinate
        }
        if isActive, let coordinate = liveManager.lastKnownCoordinate {
            return coordinate
        }
        return nil
    }

    private var placeLabel: String? {
        session?.latest_place_label ?? payload.initialPlaceLabel ?? liveManager.lastPlaceLabel
    }

    private var statusLabel: String {
        if let session {
            switch session.status.lowercased() {
            case "stopped":
                return L10n.t("chat_location_sharing_ended", languageCode: languageCode)
            case "expired":
                return L10n.t("chat_location_expired", languageCode: languageCode)
            default:
                if session.isPastExpiry {
                    return L10n.t("chat_location_sharing_ended", languageCode: languageCode)
                }
                return L10n.t("chat_location_active", languageCode: languageCode)
            }
        }
        if isActive {
            return L10n.t("chat_location_active", languageCode: languageCode)
        }
        if isFromCurrentUser {
            return L10n.t("chat_location_sharing_ended", languageCode: languageCode)
        }
        return L10n.t("chat_location_unavailable", languageCode: languageCode)
    }

    private var updatedLabel: String {
        guard let raw = session?.latest_updated_at,
              let date = ISO8601DateFormatter.chatLocation.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw) else {
            return L10n.t("chat_location_unavailable", languageCode: languageCode)
        }
        let seconds = max(0, Int(tick.timeIntervalSince(date)))
        if seconds < 45 {
            return L10n.t("chat_location_updated_just_now", languageCode: languageCode)
        }
        let minutes = max(1, seconds / 60)
        return String(
            format: L10n.t("chat_location_updated_minutes_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(minutes)
        )
    }

    private var countdownLabel: String {
        guard isActive else {
            return L10n.t("chat_location_sharing_ended", languageCode: languageCode)
        }
        guard let raw = payload.expiresAt ?? session?.expires_at else {
            return L10n.t("chat_location_sharing_until_stopped", languageCode: languageCode)
        }
        guard let expires = ISO8601DateFormatter.chatLocation.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw) else {
            return L10n.t("chat_location_sharing_until_stopped", languageCode: languageCode)
        }
        let remaining = expires.timeIntervalSince(tick)
        if remaining <= 0 {
            return L10n.t("chat_location_sharing_ended", languageCode: languageCode)
        }
        let minutes = max(1, Int(ceil(remaining / 60)))
        return String(
            format: L10n.t("chat_location_ends_in_minutes_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(minutes)
        )
    }
}

// MARK: - On My Way card

struct ChatOnMyWayChatCardView: View {
    let payload: ChatOnMyWayPayload
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    var languageCode: String = L10n.defaultLanguageCode
    /// Authoritative display name from chat `sender_id` roster (not forgeable payload fields).
    var authoritativeDisplayName: String? = nil
    var onImHere: (() -> Void)? = nil
    var onShareLiveLocation: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatLocationAttachmentPresenter) private var locationAttachmentPresenter
    @State private var showMapsMenu = false

    private var trustedDisplayName: String {
        let roster = authoritativeDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !roster.isEmpty { return roster }
        let preview = friendPreview.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty { return preview }
        return L10n.t("chat_on_my_way_someone", languageCode: languageCode)
    }

    var body: some View {
        chatCardChrome(isFromCurrentUser: isFromCurrentUser, showFriendAvatar: showFriendAvatar, friendPreview: friendPreview, timestamp: timestamp) {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(headerText)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                } icon: {
                    Image(systemName: payload.isArrived ? "checkmark.circle.fill" : "car.fill")
                }
                .foregroundStyle(payload.isArrived ? FGColor.accentGreen : FGColor.primaryText(colorScheme))

                Text(payload.destinationName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                miniMap(coordinate: payload.coordinate, label: payload.destinationName)

                if !payload.isArrived {
                    if let eta = etaLine {
                        Text(eta)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if let distance = distanceLine {
                        Text(distance)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if payload.etaSource == "manual" {
                        Text(L10n.t("chat_on_my_way_estimated_by_sender", languageCode: languageCode))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                    }
                }

                mapsActionRow(
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    name: payload.destinationName,
                    showMapsMenu: $showMapsMenu,
                    languageCode: languageCode
                )

                if isFromCurrentUser, !payload.isArrived {
                    HStack(spacing: 8) {
                        if onShareLiveLocation != nil || locationAttachmentPresenter.isEnabled {
                            Button {
                                if let onShareLiveLocation {
                                    onShareLiveLocation()
                                } else {
                                    locationAttachmentPresenter.present()
                                }
                            } label: {
                                Text(L10n.t("chat_location_share_live", languageCode: languageCode))
                                    .font(.caption.weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(FGColor.accentGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .accessibilityLabel(L10n.t("chat_location_share_live", languageCode: languageCode))
                        }
                        Button {
                            onImHere?()
                        } label: {
                            Text(L10n.t("chat_on_my_way_im_here", languageCode: languageCode))
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(FGColor.accentBlue, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityLabel(L10n.t("chat_on_my_way_im_here", languageCode: languageCode))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerText)
    }

    private var headerText: String {
        let name = trustedDisplayName
        if payload.isArrived {
            return String(
                format: L10n.t("chat_on_my_way_arrived_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                name
            )
        }
        return String(
            format: L10n.t("chat_on_my_way_is_on_the_way_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            name
        )
    }

    private var etaLine: String? {
        if let minutes = payload.etaMinutes, minutes > 0 {
            return String(
                format: L10n.t("chat_on_my_way_eta_minutes_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(minutes)
            )
        }
        return nil
    }

    private var distanceLine: String? {
        guard let meters = payload.distanceMeters, meters > 0 else { return nil }
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .medium
        formatter.locale = Locale(identifier: languageCode)
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return "\(L10n.t("chat_on_my_way_distance_remaining", languageCode: languageCode)): \(formatter.string(from: measurement))"
    }
}

// MARK: - Shared chrome / map helpers

private struct ChatLocationCardChrome<Content: View>: View {
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            if !isFromCurrentUser, showFriendAvatar {
                ProfileAvatarView(preview: friendPreview, size: 30)
                    .frame(width: 34, alignment: .center)
            } else if !isFromCurrentUser {
                Color.clear.frame(width: 34, height: 1)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: FGSpacing.xs + 1) {
                content
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm + 2)
                    .background {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .fill(FGColor.cardBackground(colorScheme))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
                    .softCardShadow()

                if let timestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.horizontal, FGSpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            .padding(.leading, isFromCurrentUser ? 52 : 0)
            .padding(.trailing, isFromCurrentUser ? 0 : 52)

            if isFromCurrentUser {
                Color.clear.frame(width: 34, height: 1)
            }
        }
    }
}

@ViewBuilder
private func chatCardChrome<Content: View>(
    isFromCurrentUser: Bool,
    showFriendAvatar: Bool,
    friendPreview: UserPreview,
    timestamp: String?,
    @ViewBuilder content: () -> Content
) -> some View {
    ChatLocationCardChrome(
        isFromCurrentUser: isFromCurrentUser,
        showFriendAvatar: showFriendAvatar,
        friendPreview: friendPreview,
        timestamp: timestamp,
        content: content()
    )
}

private func miniMap(coordinate: CLLocationCoordinate2D, label: String?) -> some View {
    let region = MKCoordinateRegion(
        center: coordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    return Map(initialPosition: .region(region)) {
        Marker(label?.isEmpty == false ? label! : " ", coordinate: coordinate)
    }
    .frame(height: 120)
    .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
}

private func mapsActionRow(
    latitude: Double,
    longitude: Double,
    name: String,
    showMapsMenu: Binding<Bool>,
    languageCode: String
) -> some View {
    HStack(spacing: 8) {
        Button {
            FanGeoDirectionsActions.openAppleMapsDirections(
                latitude: latitude,
                longitude: longitude,
                name: name
            )
        } label: {
            Text(L10n.t("chat_location_open_in_maps", languageCode: languageCode))
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(FGColor.accentBlue, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(L10n.t("chat_location_open_in_maps", languageCode: languageCode))

        Button {
            showMapsMenu.wrappedValue = true
        } label: {
            Text(L10n.t("chat_location_directions", languageCode: languageCode))
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(FGColor.accentGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                .foregroundStyle(FGColor.accentGreen)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(L10n.t("chat_location_directions", languageCode: languageCode))
        .confirmationDialog(
            L10n.t("chat_location_directions", languageCode: languageCode),
            isPresented: showMapsMenu,
            titleVisibility: .visible
        ) {
            Button(L10n.t("chat_location_apple_maps", languageCode: languageCode)) {
                FanGeoDirectionsActions.openAppleMapsDirections(
                    latitude: latitude,
                    longitude: longitude,
                    name: name
                )
            }
            if FanGeoDirectionsActions.isGoogleMapsInstalled {
                Button(L10n.t("chat_location_google_maps", languageCode: languageCode)) {
                    FanGeoDirectionsActions.openGoogleMapsDirections(
                        latitude: latitude,
                        longitude: longitude,
                        name: name
                    )
                }
            }
            Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
        }
    }
}

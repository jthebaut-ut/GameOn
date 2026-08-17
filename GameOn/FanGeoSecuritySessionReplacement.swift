import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Server-aligned policy + Inbox presentation for single-session takeover alerts.
enum FanGeoSecuritySessionReplacement {
    static let source = "security_session_replaced"
    static let securityEvent = "new_sign_in"
    static let notificationType = "security_session_replaced"
    static let kindRaw = "securitySession"
    static let destinationRaw = "accountSecurity"

    enum Decision: String, Equatable, Sendable {
        case notify
        case noPreviousSession = "no_previous_session"
        case sameDevice = "same_device"
        case sameClaim = "same_claim"
        case missingNewSession = "missing_new_session"
        case missingNewInstallation = "missing_new_installation"
    }

    static func decision(
        oldSessionId: String?,
        newSessionId: String?,
        oldInstallationId: UUID?,
        newInstallationId: UUID?
    ) -> Decision {
        let newSession = newSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !newSession.isEmpty else { return .missingNewSession }
        guard let newInstallationId else { return .missingNewInstallation }
        let oldSession = oldSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if oldSession.isEmpty, oldInstallationId == nil {
            return .noPreviousSession
        }
        if let oldInstallationId, oldInstallationId == newInstallationId {
            return .sameDevice
        }
        if !oldSession.isEmpty,
           oldSession.caseInsensitiveCompare(newSession) == .orderedSame,
           oldInstallationId == nil || oldInstallationId == newInstallationId {
            return .sameClaim
        }
        return .notify
    }

    static func dedupeKey(
        oldInstallationId: UUID?,
        oldSessionId: String?,
        newSessionId: String?
    ) -> String {
        let old = oldInstallationId?.uuidString.lowercased()
            ?? (oldSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? "none"
        let new = newSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "none"
        let raw = "security_session_replaced:\(old):\(new)"
        return FanGeoActionCenterActionKey.sanitize(raw)
    }

    static func sanitizedDeviceFamily(_ raw: String?) -> String? {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ipad": return "iPad"
        case "iphone", "ipod": return "iPhone"
        default: return nil
        }
    }

    static var currentDeviceFamily: String {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
#else
        "iPhone"
#endif
    }

    /// APNs customData allow-list. Rejects tokens, IPs, user-agents, geo.
    static func sanitizedCustomData(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        let allowed: Set<String> = [
            "source", "type", "security_event", "new_device_type",
            "event_id", "dedupe_key", "inbox_dedupe_key"
        ]
        let blockedSubstrings = [
            "access_token", "refresh_token", "id_token", "session_token",
            "authorization", "ip_address", "ipaddress", "user_agent",
            "useragent", "latitude", "longitude", "password"
        ]
        var out: [String: String] = [:]
        for (rawKey, rawValue) in userInfo {
            let key = String(describing: rawKey)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard allowed.contains(key) else { continue }
            if blockedSubstrings.contains(where: { key.contains($0) }) { continue }
            let value: String
            if let string = rawValue as? String {
                value = string
            } else {
                value = String(describing: rawValue)
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 180 else { continue }
            if blockedSubstrings.contains(where: { trimmed.lowercased().contains($0) }) {
                continue
            }
            out[key] = trimmed
        }
        return out
    }

    static func isSecurityEvent(notificationType: String?, sourceType: String? = nil) -> Bool {
        let type = (notificationType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = (sourceType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == Self.notificationType
            || type == Self.securityEvent
            || source == Self.source
    }

    static func isSecurityItem(_ item: FanGeoActionItem) -> Bool {
        item.kind == .securitySession
            || isSecurityEvent(
                notificationType: item.context.notificationType,
                sourceType: nil
            )
    }
}

enum FanGeoSecuritySessionNotificationPresentation {
    static func headerBadgeText(languageCode: String) -> String {
        L10n.t("security_session_replaced_badge", languageCode: languageCode)
    }

    static func title(languageCode: String) -> String {
        L10n.t("security_session_replaced_title", languageCode: languageCode)
    }

    static func body(languageCode: String) -> String {
        L10n.t("security_session_replaced_body", languageCode: languageCode)
    }

    static func deviceLine(for item: FanGeoActionItem, languageCode: String) -> String? {
        guard let family = FanGeoSecuritySessionReplacement.sanitizedDeviceFamily(
            item.context.eventTypeLabel
        ) else { return nil }
        return String(
            format: L10n.t("security_session_replaced_device_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            family
        )
    }

    static func timestampLine(for item: FanGeoActionItem, languageCode: String) -> String? {
        let date = item.timestamp ?? item.context.relativeTimestamp
        guard let date else { return nil }
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        )
    }
}

import Foundation

/// Default fan identity fields derived from signup email when the user has not chosen a name/handle yet.
enum FanProfileDefaults {

    private static let deletedEmailSuffix = "@deleted.fangeo.local"

    /// Canonical stored default bio (English). Display is localized via ``displayBio(_:languageCode:)``.
    static let canonicalDefaultBio = "I am a FanGeo Fan."

    static func isAnonymizedOrDeletedEmail(_ email: String) -> Bool {
        let normalized = OwnerBusinessEmail.normalized(email).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.hasSuffix(deletedEmailSuffix)
    }

    /// True when `raw` is FanGeo’s untouched system default bio (any supported language wording).
    static func isSystemDefaultBio(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let folded = normalizedBioFingerprint(trimmed)
        return systemDefaultBioFingerprints.contains(folded)
    }

    /// Localized text for editing/display. Custom user bios are returned unchanged.
    static func displayBio(_ stored: String, languageCode: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSystemDefaultBio(trimmed) else { return stored }
        return L10n.t(canonicalDefaultBio, languageCode: languageCode)
    }

    /// Persist form: map localized default variants back to the canonical English default.
    /// Custom bios are stored exactly as written.
    static func bioForStorage(_ displayed: String) -> String {
        let trimmed = displayed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if isSystemDefaultBio(trimmed) {
            return canonicalDefaultBio
        }
        return displayed
    }

    private static var systemDefaultBioFingerprints: Set<String> {
        var values: Set<String> = [normalizedBioFingerprint(canonicalDefaultBio)]
        for language in L10n.supportedLanguages {
            let localized = L10n.t(canonicalDefaultBio, languageCode: language.code)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !localized.isEmpty {
                values.insert(normalizedBioFingerprint(localized))
            }
        }
        return values
    }

    private static func normalizedBioFingerprint(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Email local-part for display; capitalizes first character. Falls back to `"Fan"`.
    static func defaultDisplayName(email: String, provided: String? = nil) -> String {
        let existing = provided?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existing.isEmpty { return existing }

        let local = emailLocalPart(email)
        guard !local.isEmpty else { return "Fan" }
        return local
    }

    /// Sanitized handle base from email local-part; falls back to `fan` + short auth id suffix.
    static func defaultUsernameBase(email: String, authUserId: UUID, provided: String? = nil) -> String {
        let existing = FanGeoHandleRules.normalizeForStorage(provided ?? "")
        if !existing.isEmpty { return existing }

        let local = emailLocalPart(email).lowercased()
        var sanitized = sanitizeUsernameSeed(local)

        if sanitized.isEmpty {
            sanitized = "fan" + shortAuthSuffix(authUserId, length: 6)
        }

        sanitized = normalizeForHandleRules(sanitized, authUserId: authUserId)
        return FanGeoHandleRules.normalizeForStorage(sanitized)
    }

    private static func emailLocalPart(_ email: String) -> String {
        OwnerBusinessEmail.normalized(email)
            .split(separator: "@")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func sanitizeUsernameSeed(_ raw: String) -> String {
        var s = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        s = String(s.unicodeScalars.filter { allowed.contains($0) })
        while s.contains("__") {
            s = s.replacingOccurrences(of: "__", with: "_")
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func normalizeForHandleRules(_ seed: String, authUserId: UUID) -> String {
        var s = seed
        if s.count > FanGeoHandleRules.maxLength {
            s = String(s.prefix(FanGeoHandleRules.maxLength))
        }
        if s.count < FanGeoHandleRules.minLength {
            s = "fan" + shortAuthSuffix(authUserId, length: max(3, FanGeoHandleRules.minLength - s.count))
        }
        if s.count > FanGeoHandleRules.maxLength {
            s = String(s.prefix(FanGeoHandleRules.maxLength))
        }
        if FanGeoHandleRules.validate(s) != nil {
            s = "fan" + shortAuthSuffix(authUserId, length: 6)
            if s.count > FanGeoHandleRules.maxLength {
                s = String(s.prefix(FanGeoHandleRules.maxLength))
            }
        }
        return s
    }

    static func usernameByAppendingSuffix(_ base: String, suffix: String) -> String {
        let normalizedBase = FanGeoHandleRules.normalizeForStorage(base)
        let trimmedSuffix = suffix.lowercased()
        let maxBaseLength = max(1, FanGeoHandleRules.maxLength - trimmedSuffix.count)
        let head = String(normalizedBase.prefix(maxBaseLength))
        let candidate = head + trimmedSuffix
        if FanGeoHandleRules.validate(candidate) == nil {
            return candidate
        }
        let fallback = "fan" + trimmedSuffix
        return String(fallback.prefix(FanGeoHandleRules.maxLength))
    }

    static func shortAuthSuffix(_ authUserId: UUID, length: Int) -> String {
        let hex = authUserId.uuidString.lowercased().filter { $0.isHexDigit }
        return String(hex.suffix(max(1, length)))
    }
}

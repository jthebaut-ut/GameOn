import Foundation

/// Default business identity fields derived from signup email when the owner has not chosen values yet.
enum BusinessProfileDefaults {

    /// Email local-part with first character uppercased, e.g. `venue30` → `Venue30`.
    static func defaultDisplayName(email: String) -> String {
        let local = emailLocalPart(email)
        guard !local.isEmpty else { return "Business" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Sanitized lowercase handle base from email local-part, e.g. `venue30@venue30.com` → `venue30`.
    static func defaultHandle(email: String) -> String {
        let local = emailLocalPart(email).lowercased()
        var sanitized = sanitizeHandleSeed(local)
        if sanitized.isEmpty {
            sanitized = "biz"
        }
        sanitized = normalizeForHandleRules(sanitized)
        return FanGeoHandleRules.normalizeForStorage(sanitized)
    }

    private static func emailLocalPart(_ email: String) -> String {
        OwnerBusinessEmail.normalized(email)
            .split(separator: "@")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func sanitizeHandleSeed(_ raw: String) -> String {
        var s = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        s = String(s.unicodeScalars.filter { allowed.contains($0) })
        while s.contains("__") {
            s = s.replacingOccurrences(of: "__", with: "_")
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func normalizeForHandleRules(_ seed: String) -> String {
        var s = seed
        if s.count > FanGeoHandleRules.maxLength {
            s = String(s.prefix(FanGeoHandleRules.maxLength))
        }
        if s.count < FanGeoHandleRules.minLength {
            s += String(repeating: "0", count: FanGeoHandleRules.minLength - s.count)
        }
        if s.count > FanGeoHandleRules.maxLength {
            s = String(s.prefix(FanGeoHandleRules.maxLength))
        }
        if FanGeoHandleRules.validate(s) != nil {
            s = "biz" + String(s.prefix(max(0, FanGeoHandleRules.maxLength - 3)))
            if s.count < FanGeoHandleRules.minLength {
                s = (s + "000").prefix(FanGeoHandleRules.minLength).description
            }
        }
        return s
    }
}

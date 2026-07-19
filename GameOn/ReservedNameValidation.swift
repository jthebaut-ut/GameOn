import Foundation

nonisolated private func reservedNameNormalizeForComparison(_ raw: String) -> String {
    raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .components(separatedBy: CharacterSet(charactersIn: " _-"))
        .joined()
}

/// Shared reserved display-name and @handle protection (client-side validation only).
enum ReservedNameValidation {
    nonisolated static let rejectionMessage = "This name is reserved. Please choose another display name or handle."

    private nonisolated static let rawReservedTerms: [String] = [
        // FanGeo
        "fangeo",
        "fangio",
        "fan geo",
        "fan gio",
        "fan-geo",
        "fan-gio",
        "fan_geo",
        "fan_gio",
        "fangeosports",
        "fangeosport",
        "fangiosports",
        "fangiosport",
        "fangeosupport",
        "fangiosupport",
        "fangeoadmin",
        "fangioadmin",
        "fangeomod",
        "fangiomod",
        "officialfangeo",
        "officialfangio",
        // Staff / system
        "admin",
        "administrator",
        "moderator",
        "mod",
        "support",
        "helpdesk",
        "help",
        "official",
        "verified",
        "system",
        "owner",
        "developer",
        "staff",
        "team",
        // Platform / company
        "apple",
        "appstore",
        "app store",
        "openai",
        "chatgpt",
        "google",
        "alphabet",
        "microsoft",
        "meta",
        "facebook",
        "instagram",
        "whatsapp",
        "x",
        "twitter",
        "amazon",
        "aws",
        "github",
        "supabase",
        "resend",
    ]

    nonisolated static let normalizedReservedTerms: [String] = {
        Array(Set(rawReservedTerms.map(reservedNameNormalizeForComparison).filter { !$0.isEmpty }))
            .sorted()
    }()

    /// Lowercases, trims, removes spaces/underscores/hyphens (repeated separators collapse via join).
    nonisolated static func normalizeForComparison(_ raw: String) -> String {
        reservedNameNormalizeForComparison(raw)
    }

    nonisolated static func containsReservedTerm(_ raw: String) -> Bool {
        !matchedReservedTerms(in: raw).isEmpty
    }

    /// Reserved/protected tokens present in `raw` after normalization (substring match).
    nonisolated static func matchedReservedTerms(in raw: String) -> Set<String> {
        let normalized = reservedNameNormalizeForComparison(raw)
        guard !normalized.isEmpty else { return [] }
        return Set(normalizedReservedTerms.filter { normalized.contains($0) })
    }

    /// True when `edited` introduces reserved tokens that were not already present in `original`.
    /// Used for edit flows so approved baselines that already contain tokens like "FanGeo" can evolve.
    nonisolated static func introducesNewReservedTerms(edited: String, original: String) -> Bool {
        let newlyIntroduced = matchedReservedTerms(in: edited)
            .subtracting(matchedReservedTerms(in: original))
        return !newlyIntroduced.isEmpty
    }

    /// Edit-flow reserved rejection, or `nil` when only baseline tokens (or none) remain.
    nonisolated static func editReservedRejectionMessage(edited: String, original: String) -> String? {
        introducesNewReservedTerms(edited: edited, original: original) ? rejectionMessage : nil
    }
}

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
        let normalized = reservedNameNormalizeForComparison(raw)
        guard !normalized.isEmpty else { return false }
        return normalizedReservedTerms.contains { normalized.contains($0) }
    }
}

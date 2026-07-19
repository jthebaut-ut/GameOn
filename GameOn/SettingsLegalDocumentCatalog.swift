import Foundation

/// Bundled, offline legal/policy copy for the four in-app policy sheets.
/// Selected via FanGeo app language (`L10n.appLanguageKey`); English is the fallback.
enum SettingsLegalDocumentCatalog {
    private struct Payload: Decodable {
        let lastUpdatedLabel: String
        let documents: [String: [SectionDTO]]
    }

    private struct SectionDTO: Decodable {
        let heading: String
        let body: String
    }

    private static var cache: [String: Payload] = [:]
    private static let lock = NSLock()

    static func lastUpdatedLabel(languageCode: String?) -> String {
        payload(for: languageCode).lastUpdatedLabel
    }

    static func sections(
        for kind: SettingsLegalDocumentKind,
        languageCode: String?
    ) -> [SettingsLegalContentSection] {
        let key = kind.rawValue
        let rows = payload(for: languageCode).documents[key] ?? []
        if rows.isEmpty, L10n.normalizedLanguageCode(languageCode) != L10n.defaultLanguageCode {
            return sections(for: kind, languageCode: L10n.defaultLanguageCode)
        }
        return rows.map { SettingsLegalContentSection(heading: $0.heading, body: $0.body) }
    }

    private static func payload(for languageCode: String?) -> Payload {
        let code = L10n.normalizedLanguageCode(languageCode)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[code] {
            return cached
        }
        if let loaded = loadPayload(languageCode: code) {
            cache[code] = loaded
            return loaded
        }
        if code != L10n.defaultLanguageCode, let english = loadPayload(languageCode: L10n.defaultLanguageCode) {
            cache[code] = english
            cache[L10n.defaultLanguageCode] = english
            return english
        }
        let empty = Payload(lastUpdatedLabel: "Last updated: June 18, 2026", documents: [:])
        cache[code] = empty
        return empty
    }

    private static func loadPayload(languageCode: String) -> Payload? {
        let name = "legal_\(languageCode)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
#if DEBUG
            print("[LegalDocs] missingOrInvalid resource=\(name).json")
#endif
            return nil
        }
        return decoded
    }
}

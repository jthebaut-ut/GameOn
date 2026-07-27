import Foundation

/// Stable database key for a curated profile background.
enum ProfileBackgroundKey: String, CaseIterable, Codable, Sendable, Hashable {
    case baseball
    case basketball
    case boxing
    case cycling
    case fangeo
    case football
    case formulaOne = "formula_one"
    case golf
    case hockey
    case rugby
    case skiing
    case soccer
    case swimming
    case tennis

    static let `default`: ProfileBackgroundKey = .fangeo
}

/// One curated profile-background option (catalog + assets + localization).
struct ProfileBackgroundOption: Equatable, Sendable, Identifiable {
    let key: ProfileBackgroundKey
    /// Asset catalog imageset name for the full 1600×900 artwork.
    let fullAssetName: String
    /// Asset catalog imageset name for the 400×225 picker thumbnail.
    let thumbnailAssetName: String
    /// `L10n.t` key for the display name.
    let displayNameKey: String
    /// Deterministic catalog sort order (ascending).
    let sortOrder: Int

    var id: String { key.rawValue }

    func displayName(languageCode: String) -> String {
        L10n.t(displayNameKey, languageCode: languageCode)
    }
}

/// Typed source of truth for curated profile backgrounds.
enum ProfileBackgroundCatalog {
    /// Canonical options in deterministic display order.
    static let all: [ProfileBackgroundOption] = [
        .init(key: .fangeo, fullAssetName: "profile_bg_fangeo", thumbnailAssetName: "profile_bg_fangeo_thumb", displayNameKey: "profile_background_fangeo", sortOrder: 0),
        .init(key: .baseball, fullAssetName: "profile_bg_baseball", thumbnailAssetName: "profile_bg_baseball_thumb", displayNameKey: "profile_background_baseball", sortOrder: 1),
        .init(key: .basketball, fullAssetName: "profile_bg_basketball", thumbnailAssetName: "profile_bg_basketball_thumb", displayNameKey: "profile_background_basketball", sortOrder: 2),
        .init(key: .boxing, fullAssetName: "profile_bg_boxing", thumbnailAssetName: "profile_bg_boxing_thumb", displayNameKey: "profile_background_boxing", sortOrder: 3),
        .init(key: .cycling, fullAssetName: "profile_bg_cycling", thumbnailAssetName: "profile_bg_cycling_thumb", displayNameKey: "profile_background_cycling", sortOrder: 4),
        .init(key: .football, fullAssetName: "profile_bg_football", thumbnailAssetName: "profile_bg_football_thumb", displayNameKey: "profile_background_football", sortOrder: 5),
        // Asset catalog uses French spelling `formule1` — do not rename imagesets.
        .init(key: .formulaOne, fullAssetName: "profile_bg_formule1", thumbnailAssetName: "profile_bg_formule1_thumb", displayNameKey: "profile_background_formula_one", sortOrder: 6),
        .init(key: .golf, fullAssetName: "profile_bg_golf", thumbnailAssetName: "profile_bg_golf_thumb", displayNameKey: "profile_background_golf", sortOrder: 7),
        .init(key: .hockey, fullAssetName: "profile_bg_hockey", thumbnailAssetName: "profile_bg_hockey_thumb", displayNameKey: "profile_background_hockey", sortOrder: 8),
        .init(key: .rugby, fullAssetName: "profile_bg_rugby", thumbnailAssetName: "profile_bg_rugby_thumb", displayNameKey: "profile_background_rugby", sortOrder: 9),
        .init(key: .skiing, fullAssetName: "profile_bg_skiing", thumbnailAssetName: "profile_bg_skiing_thumb", displayNameKey: "profile_background_skiing", sortOrder: 10),
        .init(key: .soccer, fullAssetName: "profile_bg_soccer", thumbnailAssetName: "profile_bg_soccer_thumb", displayNameKey: "profile_background_soccer", sortOrder: 11),
        .init(key: .swimming, fullAssetName: "profile_bg_swimming", thumbnailAssetName: "profile_bg_swimming_thumb", displayNameKey: "profile_background_swimming", sortOrder: 12),
        .init(key: .tennis, fullAssetName: "profile_bg_tennis", thumbnailAssetName: "profile_bg_tennis_thumb", displayNameKey: "profile_background_tennis", sortOrder: 13),
    ]

    private static let byKey: [ProfileBackgroundKey: ProfileBackgroundOption] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    }()

    static var sorted: [ProfileBackgroundOption] {
        all.sorted { $0.sortOrder < $1.sortOrder }
    }

    static func option(for key: ProfileBackgroundKey) -> ProfileBackgroundOption {
        byKey[key] ?? byKey[.fangeo]!
    }

    /// Resolves nil / unknown / alias keys to a safe catalog option (default FanGeo).
    static func resolve(_ raw: String?) -> ProfileBackgroundOption {
        option(for: resolveKey(raw))
    }

    static func resolveKey(_ raw: String?) -> ProfileBackgroundKey {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return .fangeo }
        switch trimmed {
        case "formula1", "formule1", "formule_one", "formula_one":
            return .formulaOne
        default:
            return ProfileBackgroundKey(rawValue: trimmed) ?? .fangeo
        }
    }

    /// Approved database keys for CHECK constraints / validation docs.
    static var approvedDatabaseKeys: [String] {
        ProfileBackgroundKey.allCases.map(\.rawValue).sorted()
    }
}

import SwiftUI

// MARK: - Artwork model

/// Compact Friend Group visual identity (accent icon only — member avatars stay primary).
struct FriendGroupArtwork: Equatable, Sendable {
    let category: FriendGroupArtworkResolver.Category
    let systemImage: String
    /// Soft accent for the icon (pair with `softFill` for the badge surface).
    let accent: Color
    let accessibilityCategoryKey: String
}

// MARK: - Resolver

/// Deterministic, offline category → SF Symbol + tint from the group name.
enum FriendGroupArtworkResolver {
    enum Category: String, Equatable, Sendable, CaseIterable {
        case family
        case soccer
        case baseball
        case basketball
        case hockey
        case golf
        case tennis
        case pickleball
        case running
        case cycling
        case ski
        case snowboard
        case swim
        case volleyball
        case work
        case school
        case church
        case travel
        case food
        case outdoors
        case friends
    }

    static func resolve(groupName: String) -> FriendGroupArtwork {
        let normalized = normalize(groupName)
        let category = detectCategory(in: normalized) ?? .friends
        return artwork(for: category)
    }

    // MARK: Normalization

    /// Case-insensitive, diacritic-insensitive; punctuation → spaces; collapsed whitespace.
    static func normalize(_ groupName: String) -> String {
        let folded = groupName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        var scalars: [Character] = []
        scalars.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(Character(scalar))
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: Detection (priority order — first match wins)

    private static func detectCategory(in normalized: String) -> Category? {
        // Sports before work/outdoors so “Basketball Team” / “Utah Soccer” resolve correctly.
        let rules: [(Category, [String])] = [
            (.soccer, ["soccer", "football"]),
            (.basketball, ["basketball"]),
            (.baseball, ["baseball"]),
            (.hockey, ["hockey"]),
            (.golf, ["golf"]),
            (.tennis, ["tennis"]),
            (.pickleball, ["pickleball"]),
            (.running, ["running"]),
            (.cycling, ["cycling"]),
            (.ski, ["ski", "skiing"]),
            (.snowboard, ["snowboard", "snowboarding"]),
            (.swim, ["swim", "swimming"]),
            (.volleyball, ["volleyball"]),
            (.work, ["work", "office", "coworkers", "colleagues", "team", "business"]),
            (.school, ["school", "class", "students", "college", "teachers"]),
            (.church, ["church", "parish", "ward", "bible", "ministry", "faith"]),
            (.travel, ["travel", "trip", "vacation", "holiday"]),
            (.food, ["food", "restaurant", "bbq", "dinner", "lunch"]),
            (
                .family,
                [
                    "family", "parents", "mom", "mother", "dad", "father", "kids", "children",
                    "brother", "sister", "grandma", "grandpa", "cousin", "relatives",
                ]
            ),
            (.outdoors, ["utah", "mountains", "mountain", "camping", "hiking"]),
        ]

        for (category, keywords) in rules {
            if keywords.contains(where: { containsKeyword($0, in: normalized) }) {
                return category
            }
        }
        return nil
    }

    private static func containsKeyword(_ keyword: String, in normalized: String) -> Bool {
        let padded = " \(normalized) "
        return padded.contains(" \(keyword) ")
    }

    // MARK: Artwork table

    private static func artwork(for category: Category) -> FriendGroupArtwork {
        switch category {
        case .family:
            return FriendGroupArtwork(
                category: category,
                systemImage: "figure.2.and.child.holdinghands",
                accent: Color(red: 0.62, green: 0.48, blue: 0.92),
                accessibilityCategoryKey: "friend_groups_artwork_family_a11y"
            )
        case .soccer:
            return FriendGroupArtwork(
                category: category,
                systemImage: "soccerball",
                accent: Color(red: 0.22, green: 0.70, blue: 0.48),
                accessibilityCategoryKey: "friend_groups_artwork_soccer_a11y"
            )
        case .basketball:
            return FriendGroupArtwork(
                category: category,
                systemImage: "basketball",
                accent: Color(red: 0.92, green: 0.52, blue: 0.22),
                accessibilityCategoryKey: "friend_groups_artwork_basketball_a11y"
            )
        case .baseball:
            return FriendGroupArtwork(
                category: category,
                systemImage: "baseball",
                accent: Color(red: 0.35, green: 0.58, blue: 0.92),
                accessibilityCategoryKey: "friend_groups_artwork_baseball_a11y"
            )
        case .hockey:
            return FriendGroupArtwork(
                category: category,
                systemImage: "hockey.puck",
                accent: Color(red: 0.40, green: 0.58, blue: 0.86),
                accessibilityCategoryKey: "friend_groups_artwork_hockey_a11y"
            )
        case .golf:
            return FriendGroupArtwork(
                category: category,
                systemImage: "flag.fill",
                accent: Color(red: 0.28, green: 0.68, blue: 0.46),
                accessibilityCategoryKey: "friend_groups_artwork_golf_a11y"
            )
        case .tennis:
            return FriendGroupArtwork(
                category: category,
                systemImage: "tennis.racket",
                accent: Color(red: 0.55, green: 0.78, blue: 0.28),
                accessibilityCategoryKey: "friend_groups_artwork_tennis_a11y"
            )
        case .pickleball:
            return FriendGroupArtwork(
                category: category,
                systemImage: "sportscourt.fill",
                accent: Color(red: 0.30, green: 0.72, blue: 0.62),
                accessibilityCategoryKey: "friend_groups_artwork_pickleball_a11y"
            )
        case .running:
            return FriendGroupArtwork(
                category: category,
                systemImage: "figure.run",
                accent: Color(red: 0.95, green: 0.42, blue: 0.38),
                accessibilityCategoryKey: "friend_groups_artwork_running_a11y"
            )
        case .cycling:
            return FriendGroupArtwork(
                category: category,
                systemImage: "bicycle",
                accent: Color(red: 0.28, green: 0.62, blue: 0.88),
                accessibilityCategoryKey: "friend_groups_artwork_cycling_a11y"
            )
        case .ski:
            return FriendGroupArtwork(
                category: category,
                systemImage: "figure.skiing.downhill",
                accent: Color(red: 0.45, green: 0.68, blue: 0.92),
                accessibilityCategoryKey: "friend_groups_artwork_ski_a11y"
            )
        case .snowboard:
            return FriendGroupArtwork(
                category: category,
                systemImage: "figure.snowboarding",
                accent: Color(red: 0.42, green: 0.55, blue: 0.88),
                accessibilityCategoryKey: "friend_groups_artwork_snowboard_a11y"
            )
        case .swim:
            return FriendGroupArtwork(
                category: category,
                systemImage: "figure.pool.swim",
                accent: Color(red: 0.22, green: 0.62, blue: 0.86),
                accessibilityCategoryKey: "friend_groups_artwork_swim_a11y"
            )
        case .volleyball:
            return FriendGroupArtwork(
                category: category,
                systemImage: "volleyball",
                accent: Color(red: 0.95, green: 0.62, blue: 0.28),
                accessibilityCategoryKey: "friend_groups_artwork_volleyball_a11y"
            )
        case .work:
            return FriendGroupArtwork(
                category: category,
                systemImage: "briefcase.fill",
                accent: Color(red: 0.48, green: 0.56, blue: 0.68),
                accessibilityCategoryKey: "friend_groups_artwork_work_a11y"
            )
        case .school:
            return FriendGroupArtwork(
                category: category,
                systemImage: "graduationcap.fill",
                accent: Color(red: 0.52, green: 0.48, blue: 0.90),
                accessibilityCategoryKey: "friend_groups_artwork_school_a11y"
            )
        case .church:
            return FriendGroupArtwork(
                category: category,
                systemImage: "building.columns.fill",
                accent: Color(red: 0.58, green: 0.52, blue: 0.78),
                accessibilityCategoryKey: "friend_groups_artwork_church_a11y"
            )
        case .travel:
            return FriendGroupArtwork(
                category: category,
                systemImage: "airplane",
                accent: Color(red: 0.30, green: 0.58, blue: 0.90),
                accessibilityCategoryKey: "friend_groups_artwork_travel_a11y"
            )
        case .food:
            return FriendGroupArtwork(
                category: category,
                systemImage: "fork.knife",
                accent: Color(red: 0.90, green: 0.48, blue: 0.38),
                accessibilityCategoryKey: "friend_groups_artwork_food_a11y"
            )
        case .outdoors:
            return FriendGroupArtwork(
                category: category,
                systemImage: "mountain.2.fill",
                accent: Color(red: 0.38, green: 0.62, blue: 0.78),
                accessibilityCategoryKey: "friend_groups_artwork_outdoors_a11y"
            )
        case .friends:
            return FriendGroupArtwork(
                category: category,
                systemImage: "person.3.fill",
                accent: FGColor.accentBlue,
                accessibilityCategoryKey: "friend_groups_artwork_friends_a11y"
            )
        }
    }

    static func softFill(for artwork: FriendGroupArtwork, colorScheme: ColorScheme) -> Color {
        artwork.accent.opacity(colorScheme == .dark ? 0.22 : 0.14)
    }

    static func accessibilityCategoryLabel(
        for artwork: FriendGroupArtwork,
        languageCode: String
    ) -> String {
        L10n.t(artwork.accessibilityCategoryKey, languageCode: languageCode)
    }
}

// MARK: - Compact badge

/// Soft rounded badge (48–56pt) — accent only; never a full-card banner.
struct FriendGroupArtworkBadge: View {
    let artwork: FriendGroupArtwork
    var size: CGFloat = 52
    var cornerStyle: CornerStyle = .circle

    enum CornerStyle: Sendable {
        case circle
        case roundedSquare
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Group {
                switch cornerStyle {
                case .circle:
                    Circle()
                        .fill(FriendGroupArtworkResolver.softFill(for: artwork, colorScheme: colorScheme))
                case .roundedSquare:
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(FriendGroupArtworkResolver.softFill(for: artwork, colorScheme: colorScheme))
                }
            }
            Image(systemName: artwork.systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(artwork.accent)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

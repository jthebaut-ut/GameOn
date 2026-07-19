import SwiftUI

/// Compact curated emoji picker for the fan Edit Profile bio draft (local insert only).
struct ProfileBioEmojiPickerSheet: View {
    let languageCode: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    private static let categories: [(titleKey: String, emojis: [String])] = [
        (
            "Sports",
            ["⚽️", "🏀", "🏈", "⚾️", "🏒", "🎾", "🏐", "🏆", "🥇"]
        ),
        (
            "Reactions",
            ["🔥", "💪", "🙌", "🎉", "❤️", "💙", "💚", "⭐️", "😎", "🥳"]
        ),
        (
            "Flags",
            ["🇺🇸", "🇲🇽", "🇧🇷", "🇨🇦", "🇬🇧", "🇫🇷", "🇩🇪", "🇪🇸", "🇮🇹", "🇯🇵"]
        ),
        (
            "General",
            ["📍", "🌍", "🍻", "🎬", "🕐", "📣", "✨", "🤝", "💬", "🎯"]
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.categories, id: \.titleKey) { category in
                        section(titleKey: category.titleKey, emojis: uniqueEmojis(category.emojis))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .navigationTitle(L10n.t("Choose an emoji", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                }
            }
        }
    }

    private func uniqueEmojis(_ emojis: [String]) -> [String] {
        var seen = Set<String>()
        return emojis.filter { seen.insert($0).inserted }
    }

    private func section(titleKey: String, emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(titleKey, languageCode: languageCode))
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        FGInteractionHaptics.selection()
                        onSelect(emoji)
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(FGAdaptiveSurface.controlFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.6), lineWidth: 1)
                            }
                    }
                    .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.92, hapticOnPress: false))
                    .accessibilityLabel("\(L10n.t("Add emoji", languageCode: languageCode)): \(emoji)")
                }
            }
        }
    }
}

enum ProfileBioEmojiInsertion {
    /// Appends `emoji` to the bio draft with light spacing rules and character-limit respect.
    /// TextEditor does not safely expose cursor selection, so append is used.
    @discardableResult
    static func append(
        emoji: String,
        to bio: inout String,
        limit: Int
    ) -> Bool {
        let glyph = emoji
        guard !glyph.isEmpty else { return false }

        let needsLeadingSpace: Bool = {
            guard let last = bio.last else { return false }
            return !last.isWhitespace && !last.isNewline
        }()

        let candidate = needsLeadingSpace ? " \(glyph)" : glyph
        if bio.count + candidate.count <= limit {
            bio += candidate
            return true
        }
        if needsLeadingSpace, bio.count + glyph.count <= limit {
            bio += glyph
            return true
        }
        return false
    }
}

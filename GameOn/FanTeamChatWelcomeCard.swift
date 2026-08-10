import SwiftUI

/// Presentation-only welcome surface for new Team chats (no persisted message).
struct FanTeamChatWelcomeCard: View {
    let teamName: String
    let sport: String
    let languageCode: String
    let colorScheme: ColorScheme

    private var sportEmoji: String {
        let emoji = SportFilterCatalog.resolve(sport).emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return emoji.isEmpty ? "🏆" : emoji
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                String(
                    format: L10n.t("fan_teams_welcome_title_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    teamName,
                    sportEmoji
                )
            )
            .font(.headline.weight(.bold))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)

            Text(L10n.t("fan_teams_welcome_intro", languageCode: languageCode))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            VStack(alignment: .leading, spacing: 6) {
                welcomeBullet(L10n.t("fan_teams_welcome_bullet_practices", languageCode: languageCode))
                welcomeBullet(L10n.t("fan_teams_welcome_bullet_matches", languageCode: languageCode))
                welcomeBullet(L10n.t("fan_teams_welcome_bullet_locations", languageCode: languageCode))
                welcomeBullet(L10n.t("fan_teams_welcome_bullet_polls", languageCode: languageCode))
                welcomeBullet(L10n.t("fan_teams_welcome_bullet_connected", languageCode: languageCode))
            }

            Text(L10n.t("fan_teams_welcome_members_only", languageCode: languageCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.85 : 0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.35 : 0.22), lineWidth: 1)
        }
        .softCardShadow()
        .accessibilityElement(children: .combine)
    }

    private func welcomeBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.accentGreen)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

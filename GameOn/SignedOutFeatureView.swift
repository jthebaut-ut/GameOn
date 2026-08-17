import SwiftUI

/// Canonical signed-out landing for authentication-required FanGeo features.
/// Visual standard is the Teams signed-out screen: icon in accent circle, title,
/// description, Sign In (primary capsule), Create Account (secondary stroke).
struct SignedOutFeatureView: View {
    let icon: String
    let title: String
    let description: String
    var accent: Color = FGColor.intentTeams
    let onSignIn: () -> Void
    let onCreateAccount: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(description)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button(action: onSignIn) {
                    Text(L10n.t("Sign In", languageCode: languageCode))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("Sign In", languageCode: languageCode))
                .accessibilityHint(L10n.t("signed_out_sign_in_hint", languageCode: languageCode))

                Button(action: onCreateAccount) {
                    Text(L10n.t("Create Account", languageCode: languageCode))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(accent.opacity(0.85), lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("Create Account", languageCode: languageCode))
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }
}

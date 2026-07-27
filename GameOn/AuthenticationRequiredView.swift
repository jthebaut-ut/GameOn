import SwiftUI

/// Centered sign-in prompt for tabs and sheets that require a fan session.
struct AuthenticationRequiredView: View {
    let icon: String
    let title: String
    let subtitle: String
    var primaryTitle: String? = nil
    var secondaryTitle: String? = nil
    var onPrimary: (() -> Void)? = nil
    var onSecondary: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 51, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if onPrimary != nil || onSecondary != nil {
                    VStack(spacing: 12) {
                        if let onPrimary {
                            FGPrimaryButton(
                                title: primaryTitle ?? "Sign In",
                                systemImage: "person.fill",
                                action: onPrimary
                            )
                            .accessibilityLabel(primaryTitle ?? "Sign In")
                            .accessibilityHint("Opens the Account tab so you can sign in and save this game.")
                        }
                        if let onSecondary {
                            FGSecondaryButton(
                                title: secondaryTitle ?? "Not Now",
                                action: onSecondary
                            )
                            .accessibilityLabel(secondaryTitle ?? "Not Now")
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: onPrimary == nil && onSecondary == nil ? .combine : .contain)
        .accessibilityLabel(onPrimary == nil ? "\(title). \(subtitle)" : title)
    }
}

extension AuthenticationRequiredView {
    /// Going tab / save-games gate. Prefer the interactive factory so Sign In opens Account login.
    static var going: AuthenticationRequiredView {
        AuthenticationRequiredView(
            icon: "bookmark.circle",
            title: "Sign in to save games",
            subtitle: "Save your favorite games, receive updates, and access them anytime."
        )
    }

    static func going(
        onSignIn: @escaping () -> Void,
        onNotNow: @escaping () -> Void
    ) -> AuthenticationRequiredView {
        AuthenticationRequiredView(
            icon: "bookmark.circle",
            title: "Sign in to save games",
            subtitle: "Save your favorite games, receive updates, and access them anytime.",
            primaryTitle: "Sign In",
            secondaryTitle: "Not Now",
            onPrimary: onSignIn,
            onSecondary: onNotNow
        )
    }

    static var favorites: AuthenticationRequiredView {
        AuthenticationRequiredView(
            icon: "heart.fill",
            title: "Sign in to save favorites",
            subtitle: "Use your Account tab to sign in, then open Saved again."
        )
    }

    static var friends: AuthenticationRequiredView {
        AuthenticationRequiredView(
            icon: "person.2.fill",
            title: "Sign in to connect",
            subtitle: "Use your Account tab to sign in, then open Friends again."
        )
    }
}

/// Sheet wrapper for the guest heart-tap save-games prompt.
struct SaveProGameSignInPromptSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AuthenticationRequiredView.going(
            onSignIn: {
                viewModel.continueSaveProGameSignInFromPrompt()
                dismiss()
            },
            onNotNow: {
                viewModel.cancelSaveProGameSignInPrompt()
                dismiss()
            }
        )
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

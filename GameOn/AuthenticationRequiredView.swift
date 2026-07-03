import SwiftUI

/// Centered sign-in prompt for tabs and screens that require a fan session.
/// Matches the Chat tab empty-state layout without promotional artwork or auth CTAs.
struct AuthenticationRequiredView: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

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
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension AuthenticationRequiredView {
    static var going: AuthenticationRequiredView {
        AuthenticationRequiredView(
            icon: "bookmark.circle",
            title: "Sign in to save games",
            subtitle: "Use your Account tab to sign in, then open Going again."
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

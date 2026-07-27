import SwiftUI
import UIKit

/// Full-screen blockers for FanGeo 13+ age access policy.
struct AgeAccessGateOverlay: View {
    @ObservedObject var gate: AgeAccessGateService
    var onUnder13Close: (() -> Void)?
    var onNeedsConfirmationCancel: (() -> Void)?

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        Group {
            switch gate.presentation {
            case .under13:
                AgeAccessBlockingScreen(
                    title: L10n.t("age_gate_under13_title", languageCode: appLanguageRaw),
                    bodyText: L10n.t("age_gate_under13_body", languageCode: appLanguageRaw),
                    primaryTitle: L10n.t("age_gate_close", languageCode: appLanguageRaw),
                    secondaryTitle: L10n.t("age_gate_learn_more", languageCode: appLanguageRaw),
                    onPrimary: {
                        gate.dismissUnder13()
                        onUnder13Close?()
                    },
                    onSecondary: openLearnMore
                )
            case .needsConfirmation:
                AgeAccessBlockingScreen(
                    title: L10n.t("age_gate_confirmation_title", languageCode: appLanguageRaw),
                    bodyText: L10n.t("age_gate_confirmation_body", languageCode: appLanguageRaw),
                    primaryTitle: L10n.t("age_gate_try_again", languageCode: appLanguageRaw),
                    secondaryTitle: L10n.t("age_gate_cancel", languageCode: appLanguageRaw),
                    onPrimary: {
                        Task { await gate.retryConfirmation() }
                    },
                    onSecondary: {
                        gate.dismissNeedsConfirmation()
                        onNeedsConfirmationCancel?()
                    }
                )
            case .none:
                // Resolving / fail-closed pending UI is owned by ContentView's branded
                // FanGeoSplashView — never show a blank system-background spinner here.
                if gate.blocksSocialSession, !gate.isResolvingSocialSession {
                    AgeAccessBlockingScreen(
                        title: L10n.t("age_gate_confirmation_title", languageCode: appLanguageRaw),
                        bodyText: L10n.t("age_gate_confirmation_body", languageCode: appLanguageRaw),
                        primaryTitle: L10n.t("age_gate_try_again", languageCode: appLanguageRaw),
                        secondaryTitle: L10n.t("age_gate_cancel", languageCode: appLanguageRaw),
                        onPrimary: {
                            Task { await gate.retryConfirmation() }
                        },
                        onSecondary: {
                            gate.dismissNeedsConfirmation()
                            onNeedsConfirmationCancel?()
                        }
                    )
                } else {
                    EmptyView()
                }
            }
        }
    }

    private func openLearnMore() {
        guard let url = URL(string: "https://support.apple.com/102650") else { return }
        UIApplication.shared.open(url)
    }
}

private struct AgeAccessBlockingScreen: View {
    let title: String
    let bodyText: String
    let primaryTitle: String
    let secondaryTitle: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)

                    Text(bodyText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(bodyText)

                    VStack(spacing: 12) {
                        Button(action: onPrimary) {
                            Text(primaryTitle)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(primaryTitle)

                        Button(action: onSecondary) {
                            Text(secondaryTitle)
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(secondaryTitle)
                    }
                    .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: 420)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .padding(.horizontal, 24)

                Spacer(minLength: 24)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            titleFocused = true
        }
    }
}

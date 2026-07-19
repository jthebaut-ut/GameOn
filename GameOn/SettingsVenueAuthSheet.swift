import SwiftUI

/// Signed-in body for ``SettingsVenueAuthSheet`` only.
/// Intentionally excludes verification rows, claim forms, password reset, logout, and deletion UI.
struct SettingsVenueAuthSheetSignedInBody: View {
    @ObservedObject var viewModel: MapViewModel
    var onRequestVenueProfileDashboard: () -> Void
    var dismissAuthSheet: () -> Void

    /// Claim workflow approved (not venue-linked fallback).
    private var claimLineShowsApprovedMessage: Bool {
        if viewModel.venueIsApproved { return true }
        let s = viewModel.venueClaimStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "approved"
    }

    private var claimShowsRejected: Bool {
        viewModel.hasActiveVenueClaimRejectionForBusinessUI
    }

    private var venueToolsUnlocked: Bool {
        viewModel.venueOwnerToolsUnlockedForUI()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            if viewModel.isVenueOwnerBusinessDataLoading {
                SettingsSheetStatusBanner(
                    title: "Loading business account",
                    message: "Loading your venues…",
                    tint: FGColor.accentBlue,
                    systemImage: "building.2.crop.circle"
                )
            } else if viewModel.venueOwnerJustCompletedRegistration {
                FGCard {
                    FGSectionHeader(
                        "Business account created",
                        subtitle: "Your first location request has been submitted for review."
                    ) {
                        FGStatusPill(title: "Pending review", kind: .pending)
                    }

                    SettingsSheetStatusBanner(
                        title: nil,
                        message: "FanGeo reviews new business location submissions before owner tools are unlocked.",
                        tint: FGColor.accentYellow,
                        systemImage: "clock.badge.checkmark"
                    )

                    FGPrimaryButton(title: "Close") {
                        viewModel.venueOwnerJustCompletedRegistration = false
                        dismissAuthSheet()
                    }
                }
#if DEBUG
                .onAppear {
                    print("[BusinessSignup] final success modal shown (Business account created card)")
                }
#endif
            } else {
                // After business-owner sign-in, close this auth sheet instead of showing
                // any claim-status card. Settings remains the single source of truth.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                    .task {
#if DEBUG
                        let status = viewModel.venueClaimStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("[BusinessLogin] signed-in sheet auto-dismissed status=\(status) submitted=\(viewModel.venueClaimSubmitted) unlocked=\(venueToolsUnlocked) hasBusiness=\(viewModel.hasBusinessAccountForOwner()) rejected=\(claimShowsRejected)")
#endif
                        dismissAuthSheet()
                    }
            }
        }
        .onAppear {
            viewModel.checkVenueApprovalStatus()
#if DEBUG
            print("[VenueOwnerLoginDebug] sheet state=appear unlocked=\(viewModel.venueOwnerToolsUnlockedForUI()) loading=\(viewModel.isVenueOwnerBusinessDataLoading) claimSubmitted=\(viewModel.venueClaimSubmitted)")
#endif
        }
    }

}

/// Entry modes for signed-out business auth before Sign In / Create Account forms.
enum BusinessAuthEntryMode: Equatable {
    case choice
    case signIn
    case register
}

struct SettingsVenueAuthSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var venuePassword: String
    @Binding var showVenueRegisterMode: Bool
    var onRequestVenueProfileDashboard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var authTermsAccepted = false
    @State private var businessAuthEntryMode: BusinessAuthEntryMode = .choice

    private var showsBusinessAuthTermsAcceptance: Bool {
        !viewModel.shouldShowPendingBusinessEmailVerificationUI && !viewModel.isVenueOwnerLoggedIn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    Text("Business")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)

                    Text("Sign in as a business owner to manage your locations and listings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)

                if showsBusinessAuthTermsAcceptance {
                    FanGeoAuthTermsAcceptanceView(isAccepted: $authTermsAccepted)
                }

                if !viewModel.isVenueOwnerLoggedIn {
                    SettingsSheetStatusBanner(
                        title: L10n.t("business_review_banner_title", languageCode: appLanguageRaw),
                        message: L10n.t("business_review_banner_message", languageCode: appLanguageRaw),
                        tint: FGColor.accentYellow,
                        systemImage: "clock.badge.exclamationmark"
                    )
                }

                if viewModel.shouldShowPendingBusinessEmailVerificationUI {
                    EmailVerificationPendingView(
                        viewModel: viewModel,
                        kind: .business,
                        email: viewModel.pendingEmailVerificationEmail,
                        onBackToSignIn: {
                            showVenueRegisterMode = false
                            businessAuthEntryMode = .signIn
                            viewModel.venueAuthErrorMessage = ""
                        }
                    )
                } else if viewModel.shouldShowFullPendingVerifiedVenueSetupUI {
                    SettingsSheetStatusBanner(
                        title: "Email verified",
                        message: viewModel.businessVerifiedVenueSetupBannerMessage,
                        tint: FGColor.accentGreen,
                        systemImage: "checkmark.seal.fill"
                    )
                    SettingsVenueOwnerCard(
                        viewModel: viewModel,
                        venuePassword: $venuePassword,
                        showVenueRegisterMode: $showVenueRegisterMode,
                        businessAuthEntryMode: $businessAuthEntryMode,
                        authTermsAccepted: $authTermsAccepted
                    )
                } else if viewModel.isVenueOwnerLoggedIn {
                    SettingsVenueAuthSheetSignedInBody(
                        viewModel: viewModel,
                        onRequestVenueProfileDashboard: onRequestVenueProfileDashboard,
                        dismissAuthSheet: { dismiss() }
                    )
                } else {
                    if viewModel.shouldShowVerifiedPendingBusinessSignInPrompt {
                        SettingsSheetStatusBanner(
                            title: "Email verified",
                            message: viewModel.businessVerifiedVenueSetupBannerMessage,
                            tint: FGColor.accentGreen,
                            systemImage: "checkmark.seal.fill"
                        )
                    }

                    if viewModel.shouldShowPendingBusinessSignupMatchingEmailBanner {
                        SettingsSheetStatusBanner(
                            title: nil,
                            message: viewModel.pendingBusinessSetupResumeBannerMessage,
                            tint: FGColor.accentBlue,
                            systemImage: "arrow.uturn.forward.circle"
                        )
                    }

                    SettingsVenueOwnerCard(
                        viewModel: viewModel,
                        venuePassword: $venuePassword,
                        showVenueRegisterMode: $showVenueRegisterMode,
                        businessAuthEntryMode: $businessAuthEntryMode,
                        authTermsAccepted: $authTermsAccepted
                    )

                    if viewModel.hasPendingBusinessSetupDraftForOtherEmail {
                        Button {
                            viewModel.activateResumePendingBusinessSetupForDraft()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.uturn.forward.circle")
                                    .font(.caption.weight(.bold))
                                Text(viewModel.pendingBusinessSetupResumeBannerMessage)
                                    .font(FGTypography.caption.weight(.bold))
                                    .multilineTextAlignment(.leading)
                            }
                            .foregroundStyle(FGColor.accentBlue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 11)
                            .padding(.horizontal, FGSpacing.md)
                            .background(FGAdaptiveSurface.controlFill)
                            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.bottom, FGSpacing.md)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            resolveInitialBusinessAuthEntryMode()
        }
        .onChange(of: viewModel.shouldShowVerifiedPendingBusinessSignInPrompt) { _, show in
            guard show, !viewModel.isVenueOwnerLoggedIn else { return }
            businessAuthEntryMode = .signIn
            showVenueRegisterMode = false
        }
        .onChange(of: viewModel.shouldShowPendingBusinessSignupMatchingEmailBanner) { _, show in
            guard show, !viewModel.isVenueOwnerLoggedIn else { return }
            businessAuthEntryMode = .register
            showVenueRegisterMode = true
        }
        .onChange(of: viewModel.applePendingBusinessSignupEmail) { _, email in
            guard !OwnerBusinessEmail.normalized(email).isEmpty else { return }
            businessAuthEntryMode = .register
            showVenueRegisterMode = true
        }
        .onDisappear {
            viewModel.venueOwnerJustCompletedRegistration = false
            authTermsAccepted = false
            businessAuthEntryMode = .choice
        }
    }

    /// Manual sheet open → `.choice`. Exceptions resume Sign In / Register directly.
    private func resolveInitialBusinessAuthEntryMode() {
        guard !viewModel.isVenueOwnerLoggedIn else { return }
        if viewModel.shouldShowFullPendingVerifiedVenueSetupUI {
            businessAuthEntryMode = .register
            showVenueRegisterMode = true
            return
        }
        if !OwnerBusinessEmail.normalized(viewModel.applePendingBusinessSignupEmail).isEmpty {
            businessAuthEntryMode = .register
            showVenueRegisterMode = true
            return
        }
        if viewModel.shouldShowVerifiedPendingBusinessSignInPrompt {
            businessAuthEntryMode = .signIn
            showVenueRegisterMode = false
            return
        }
        if viewModel.shouldShowPendingBusinessSignupMatchingEmailBanner {
            businessAuthEntryMode = .register
            showVenueRegisterMode = true
            return
        }
        if showVenueRegisterMode {
            businessAuthEntryMode = .register
        } else {
            businessAuthEntryMode = .choice
        }
    }
}

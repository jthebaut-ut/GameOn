import SwiftUI

struct SettingsUserAuthSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var authTermsAccepted = false

    var body: some View {
        Group {
            if viewModel.pendingEmailVerificationKind == .fan {
                ScrollView {
                    EmailVerificationPendingView(
                        viewModel: viewModel,
                        kind: .fan,
                        email: viewModel.pendingEmailVerificationEmail,
                        onBackToSignIn: {
                            showRegisterMode = false
                            viewModel.authErrorMessage = ""
                        }
                    )
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
                }
                .scrollIndicators(.hidden)
            } else if viewModel.isLoggedIn, !viewModel.isAppleFanSignupOnboardingActive {
                // After email confirmation (or other signup success), avoid remounting the create-account form.
                VStack(spacing: 14) {
                    ProgressView()
                    Text(L10n.t("opening_fangeo"))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    showRegisterMode = false
                    dismiss()
                }
            } else if showRegisterMode, !viewModel.isDeletedAccountLoginBlocked {
                FanSignupView(
                    viewModel: viewModel,
                    prefilledEmail: email,
                    termsAccepted: $authTermsAccepted,
                    onSwitchToSignIn: {
                        showRegisterMode = false
                        viewModel.authErrorMessage = ""
                    },
                    onDismissAfterSuccess: { dismiss() }
                )
            } else {
                fanSignInScrollContent
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .overlay {
            if viewModel.isSafeLoginBlockingUI {
                SafeLoginProgressOverlay(viewModel: viewModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .disabled(viewModel.isSafeLoginInFlight)
            }
        }
        .interactiveDismissDisabled(viewModel.isSafeLoginInFlight)
        .onChange(of: viewModel.isLoggedIn) { wasLoggedIn, isLoggedIn in
            // Dismiss after successful fan auth while the sheet is open.
            if !wasLoggedIn && isLoggedIn, !viewModel.isAppleFanSignupOnboardingActive {
                showRegisterMode = false
                dismiss()
            }
        }
        .onChange(of: viewModel.pendingEmailVerificationKind) { previous, kind in
            if previous == .fan, kind == nil, viewModel.isLoggedIn, !viewModel.isAppleFanSignupOnboardingActive {
                showRegisterMode = false
                dismiss()
            }
        }
        .onAppear {
            Task {
                if viewModel.isDeletedAccountLoginBlocked {
                    await MainActor.run {
                        showRegisterMode = false
                    }
                    return
                }
                await viewModel.syncAppleFanSignupOnboardingFromActiveSession()
                await MainActor.run {
                    if viewModel.isDeletedAccountLoginBlocked {
                        showRegisterMode = false
                    } else if viewModel.isAppleFanSignupOnboardingActive {
                        showRegisterMode = true
                    }
                }
            }
        }
        .onChange(of: viewModel.applePendingFanSignupEmail) { _, newEmail in
            guard !viewModel.isDeletedAccountLoginBlocked else {
                showRegisterMode = false
                return
            }
            if !OwnerBusinessEmail.normalized(newEmail).isEmpty {
                showRegisterMode = true
            }
        }
        .onChange(of: viewModel.appleFanOnboardingPasswordBypassActive) { _, isActive in
            guard !viewModel.isDeletedAccountLoginBlocked else {
                showRegisterMode = false
                return
            }
            if isActive {
                showRegisterMode = true
            }
        }
        .onChange(of: viewModel.authSessionState) { _, newState in
            if newState == .deletedAccountConfirmed {
                showRegisterMode = false
            }
        }
    }

    private var fanSignInScrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    Text("Account")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Sign in to sync your profile and activity.")
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .padding(.top, 2)

                SettingsFanLoginCard(
                    viewModel: viewModel,
                    email: $email,
                    password: $password,
                    termsAccepted: $authTermsAccepted,
                    onCreateAccount: { showRegisterMode = true }
                )
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.bottom, FGSpacing.md)
        }
        .scrollIndicators(.hidden)
    }
}

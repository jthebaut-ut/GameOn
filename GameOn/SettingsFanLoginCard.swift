import SwiftUI

/// Fan sign-in only (registration uses ``FanSignupView``).
struct SettingsFanLoginCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    var termsAccepted: Binding<Bool>? = nil
    var onCreateAccount: () -> Void
    @State private var localTermsAccepted = false
    @State private var showFanPasswordResetSheet = false
    @State private var showFanLoginPassword = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var resolvedTermsAccepted: Binding<Bool> {
        termsAccepted ?? $localTermsAccepted
    }

    private var isApplePendingFanProfileSetup: Bool {
        viewModel.isAppleFanSignupOnboardingActive
    }

    var body: some View {
        FGCard {
            FGSectionHeader(
                "Fan account access",
                subtitle: "Sign in to sync your profile and activity."
            )

            if viewModel.isLoggedIn {
                HStack(spacing: FGSpacing.md) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(FGColor.accentBlue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in")
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(viewModel.currentUserEmail)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    Spacer(minLength: 0)
                }
                .padding(FGSpacing.md)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.97))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }

                FGSecondaryButton(title: "Log Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task {
                        await viewModel.logoutUser()
                        email = ""
                        password = ""
                    }
                }
            } else {
                FanGeoAuthTermsAcceptanceView(isAccepted: resolvedTermsAccepted)

                FanGeoAppleSignInButton(
                    viewModel: viewModel,
                    accountMode: .fan,
                    isEnabled: resolvedTermsAccepted.wrappedValue
                )

                if !viewModel.appleAuthFanMessage.isEmpty {
                    SettingsSheetStatusBanner(
                        title: viewModel.appleAuthFanMessageIsError ? "Apple Sign In" : nil,
                        message: viewModel.appleAuthFanMessage,
                        tint: viewModel.appleAuthFanMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                        systemImage: viewModel.appleAuthFanMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                    )
                }

                if !isApplePendingFanProfileSetup {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .fanGeoInputFieldStyle()

                    fanLoginPasswordField(
                        placeholder: "Password",
                        text: $password,
                        isVisible: $showFanLoginPassword
                    )
                }

                if !isApplePendingFanProfileSetup {
                    Button {
#if DEBUG
                        print("[FanPasswordResetDebug] forgotPasswordTapped=true")
#endif
                        guard viewModel.canPresentPasswordResetRequestSheet() else {
                            showFanPasswordResetSheet = false
                            return
                        }
                        viewModel.userPasswordResetMessage = ""
                        viewModel.userPasswordResetError = ""
                        showFanPasswordResetSheet = true
                    } label: {
                        Text("Forgot password?")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    FGPrimaryButton(
                        title: "Login",
                        isDisabled: !resolvedTermsAccepted.wrappedValue
                    ) {
                        Task {
                            await MainActor.run {
                                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailPasswordSignIn")
                            }
                            await viewModel.loginUser(email: email, password: password)
                            await MainActor.run {
                                password = ""
                            }
                        }
                    }
                }

                if !viewModel.emailVerifiedSignInNotice.isEmpty {
                    SettingsSheetStatusBanner(
                        title: L10n.t("Email verified", languageCode: appLanguageRaw),
                        message: viewModel.emailVerifiedSignInNotice,
                        tint: FGColor.accentGreen,
                        systemImage: "checkmark.circle.fill"
                    )
                }

                if !viewModel.passwordResetUpdateMessage.isEmpty {
                    SettingsSheetStatusBanner(
                        title: "Password updated",
                        message: viewModel.passwordResetUpdateMessage,
                        tint: FGColor.accentGreen,
                        systemImage: "checkmark.circle.fill"
                    )
                }

                if !viewModel.authErrorMessage.isEmpty {
                    if DeletedAccountSupportContact.isDeletedAccountBlockMessage(viewModel.authErrorMessage) {
                        DeletedAccountSupportStatusBanner(
                            title: "Couldn’t sign in",
                            message: viewModel.authErrorMessage,
                            attemptedLoginEmail: email
                        )
                    } else {
                        SettingsSheetStatusBanner(
                            title: "Couldn’t sign in",
                            message: viewModel.authErrorMessage,
                            tint: FGColor.dangerRed,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }

                Button(action: onCreateAccount) {
                    Text("New user? Create account")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
                .disabled(!resolvedTermsAccepted.wrappedValue)
                .opacity(resolvedTermsAccepted.wrappedValue ? 1 : 0.55)
            }
        }
        .onChange(of: email) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailEdited")
        }
        .onChange(of: password) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "passwordEdited")
        }
        .onDisappear {
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "sheetClosed")
        }
        .sheet(isPresented: $showFanPasswordResetSheet) {
            SettingsFanPasswordResetSheet(
                viewModel: viewModel,
                loginEmail: email,
                isPresented: $showFanPasswordResetSheet
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
    }

    private func fanLoginPasswordField(
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            if isVisible.wrappedValue {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(FGTypography.body)
            } else {
                SecureField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(FGTypography.body)
            }

            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible.wrappedValue ? "Hide password" : "Show password")
        }
        .fanGeoInputFieldStyle()
    }
}

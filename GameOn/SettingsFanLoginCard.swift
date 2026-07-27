import SwiftUI

/// Fan sign-in only (registration uses ``FanSignupView``).
struct SettingsFanLoginCard: View {
    private enum FanLoginFocusField: Hashable {
        case email
        case password
    }

    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    var termsAccepted: Binding<Bool>? = nil
    var onCreateAccount: () -> Void
    @State private var localTermsAccepted = false
    @State private var showFanPasswordResetSheet = false
    @State private var showFanLoginPassword = false
    @FocusState private var focusedField: FanLoginFocusField?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var resolvedTermsAccepted: Binding<Bool> {
        termsAccepted ?? $localTermsAccepted
    }

    private var isApplePendingFanProfileSetup: Bool {
        viewModel.isAppleFanSignupOnboardingActive
    }

    private var isLoginBusy: Bool {
        viewModel.isSafeLoginInFlight
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
                    email = ""
                    password = ""
                    viewModel.beginSafeUserLogout(source: "SettingsFanLoginCard")
                }
            } else {
                FanGeoAuthTermsAcceptanceView(isAccepted: resolvedTermsAccepted)
                    .disabled(isLoginBusy)

                FanGeoAppleSignInButton(
                    viewModel: viewModel,
                    accountMode: .fan,
                    isEnabled: resolvedTermsAccepted.wrappedValue && !isLoginBusy
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
                        .textContentType(.username)
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .disabled(isLoginBusy)
                        .fanGeoInputFieldStyle()

                    fanLoginPasswordField(
                        placeholder: "Password",
                        text: $password,
                        isVisible: $showFanLoginPassword
                    )
                    .disabled(isLoginBusy)
                }

                if !isApplePendingFanProfileSetup {
                    Button {
#if DEBUG
                        print("[FanPasswordResetDebug] forgotPasswordTapped=true")
#endif
                        guard !isLoginBusy else { return }
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
                    .disabled(isLoginBusy)

                    FGPrimaryButton(
                        title: isLoginBusy
                            ? L10n.t("login_logging_you_in", languageCode: appLanguageRaw)
                            : "Login",
                        isDisabled: !resolvedTermsAccepted.wrappedValue || isLoginBusy
                    ) {
                        submitFanLogin()
                    }
                    .accessibilityLabel("Login")
                    .accessibilityValue(isLoginBusy
                        ? L10n.t("login_logging_you_in", languageCode: appLanguageRaw)
                        : "")
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
                .disabled(!resolvedTermsAccepted.wrappedValue || isLoginBusy)
                .opacity(resolvedTermsAccepted.wrappedValue && !isLoginBusy ? 1 : 0.55)
            }
        }
        .onChange(of: email) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailEdited")
        }
        .onChange(of: password) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "passwordEdited")
        }
        .onChange(of: viewModel.isLoggedIn) { _, loggedIn in
            if loggedIn {
                password = ""
            }
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

    private func submitFanLogin() {
        // Dismiss keyboard so the first Login tap is never consumed by focus dismissal alone.
        focusedField = nil
        viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailPasswordSignIn")
        viewModel.submitFanEmailLogin(
            email: email,
            password: password,
            source: "SettingsFanLoginCard"
        )
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
                    .textContentType(.password)
                    .font(FGTypography.body)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submitFanLogin() }
            } else {
                SecureField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .font(FGTypography.body)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submitFanLogin() }
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
            .disabled(isLoginBusy)
            .accessibilityLabel(isVisible.wrappedValue ? "Hide password" : "Show password")
        }
        .fanGeoInputFieldStyle()
    }
}

import PhotosUI
import SwiftUI
import UIKit

/// Unified fan account creation: auth credentials + profile on one screen before submit.
struct FanSignupView: View {
    private enum FanSignupAuthMode {
        case apple
        case emailPassword
    }

    private enum SignupStep: Int, CaseIterable {
        case profile = 1
        case fanIdentity = 2
        case bio = 3

        var next: SignupStep? {
            SignupStep(rawValue: rawValue + 1)
        }

        var previous: SignupStep? {
            SignupStep(rawValue: rawValue - 1)
        }
    }

    @ObservedObject var viewModel: MapViewModel
    var prefilledEmail: String = ""
    @Binding var termsAccepted: Bool
    var onSwitchToSignIn: () -> Void
    var onDismissAfterSuccess: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @StateObject private var onboardingWowOverlay = WowMomentOverlayManager()

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @State private var displayNameDraft = ""
    @State private var handleDraft = ""
    @State private var bioDraft = ""
    @State private var favoriteTeamIDs: Set<String> = []
    @State private var showFavoriteTeamsPicker = false
    @State private var selectedNationalTeam: NationalTeamIdentity?
    @State private var showNationalTeamPicker = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var pendingAvatarData: Data?

    @State private var currentStep: SignupStep = .profile
    @State private var isSubmitting = false
    @State private var profileRetryMode = false
    @State private var errorMessage = ""
    @State private var displayNameError = ""
    @State private var emailError = ""
    @State private var passwordError = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var handleIsConfirmedAvailable = false
    @State private var availabilityTask: Task<Void, Never>?
    @FocusState private var isBioFieldFocused: Bool

    private static let displayNameMaxLength = 40
    private static let bioCharacterLimit = 160
    private static let bioFieldLabelKey = "onboarding_tell_fans_about_you"
    private static let bioOptionalHelperKey = "onboarding_about_you_optional_helper"
    private static let bioExamplePlaceholderKey = "onboarding_about_you_example_placeholder"
    private static let bioEmptyAccessibilityKey = "onboarding_about_you_field_a11y_empty"

    var body: some View {
        signupBodyCore
            .onChange(of: favoriteTeamIDs) { oldValue, newValue in
                let added = newValue.subtracting(oldValue)
                guard let addedID = added.first,
                      let team = FavoriteTeamCatalog.team(id: addedID) else { return }
                presentOnboardingFavoriteAddedConfirmation(for: team)
            }
            .onDisappear {
                onboardingWowOverlay.dismiss()
                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "sheetClosed")
            }
            .overlay {
                WowMomentToastHost(manager: onboardingWowOverlay, bottomInset: 28)
            }
    }

    private var signupBodyCore: some View {
        Group {
            if viewModel.pendingEmailVerificationKind == .fan {
                ScrollView {
                    EmailVerificationPendingView(
                        viewModel: viewModel,
                        kind: .fan,
                        email: viewModel.pendingEmailVerificationEmail.isEmpty ? email : viewModel.pendingEmailVerificationEmail,
                        onBackToSignIn: onSwitchToSignIn
                    )
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.vertical, FGSpacing.lg)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        onboardingTopBar

                        if currentStep == .profile {
                            profileStepValueProposition

                            FanGeoAuthTermsAcceptanceView(isAccepted: $termsAccepted)

                            FanGeoAppleSignInButton(
                                viewModel: viewModel,
                                accountMode: .fan,
                                entryPoint: .fanSignup,
                                isEnabled: termsAccepted
                            )
                            .padding(.top, 2)

                            if !viewModel.appleAuthFanMessage.isEmpty {
                                SettingsSheetStatusBanner(
                                    title: viewModel.appleAuthFanMessageIsError ? "Apple Sign In" : nil,
                                    message: viewModel.appleAuthFanMessage,
                                    tint: viewModel.appleAuthFanMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                                    systemImage: viewModel.appleAuthFanMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                                )
                            }

                            profileStepAuthAndIdentityContent
                        } else {
                            if termsAccepted {
                                FanGeoAuthTermsAcceptedStatusRow()
                            }

                            if !viewModel.appleAuthFanMessage.isEmpty {
                                SettingsSheetStatusBanner(
                                    title: viewModel.appleAuthFanMessageIsError ? "Apple Sign In" : nil,
                                    message: viewModel.appleAuthFanMessage,
                                    tint: viewModel.appleAuthFanMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                                    systemImage: viewModel.appleAuthFanMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                                )
                            }

                            onboardingStepContent
                        }

                        if !errorMessage.isEmpty {
                            SettingsSheetStatusBanner(
                                title: profileRetryMode ? "Profile not saved yet" : "Couldn’t create account",
                                message: errorMessage,
                                tint: FGColor.dangerRed,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                        }

                        onboardingBottomControls

                        if currentStep == .profile {
                            Button(action: onSwitchToSignIn) {
                                Text(L10n.t("Already have an account? Sign in", languageCode: appLanguageRaw))
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.accentBlue)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmitting)
                        }
                    }
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, 12)
                    .padding(.bottom, FGSpacing.lg)
                }
            }
        }
        .scrollIndicators(.hidden)
        .fanGeoScreenBackground()
        .onAppear {
            print("[SignupUX] render mode=create")
            if viewModel.isDeletedAccountLoginBlocked {
                onSwitchToSignIn()
                return
            }
            Task {
                if await MainActor.run(body: { viewModel.isDeletedAccountLoginBlocked }) {
                    await MainActor.run { onSwitchToSignIn() }
                    return
                }
                await viewModel.syncAppleFanSignupOnboardingFromActiveSession()
                await MainActor.run {
                    guard !viewModel.isDeletedAccountLoginBlocked else {
                        onSwitchToSignIn()
                        return
                    }
                    applyApplePendingSignupState()
                }
            }
            if !usesAppleSignupAuth, email.isEmpty, !prefilledEmail.isEmpty {
                email = prefilledEmail
            }
#if DEBUG
            print("[FanSignupDebug] authMode=\(fanSignupAuthMode == .apple ? "apple" : "emailPassword") passwordFieldsHidden=\(usesAppleSignupAuth)")
#endif
        }
        .onChange(of: viewModel.appleFanOnboardingPasswordBypassActive) { _, _ in
            guard !viewModel.isDeletedAccountLoginBlocked else {
                onSwitchToSignIn()
                return
            }
            applyApplePendingSignupState()
        }
        .onChange(of: handleDraft) { _, newValue in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "signupEdited")
            handleDraft = FanGeoHandleRules.normalizeForStorage(newValue)
            scheduleHandleAvailabilityCheck()
        }
        .onChange(of: email) { _, _ in
            if !usesAppleSignupAuth {
                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailEdited")
            }
        }
        .onChange(of: password) { _, _ in
            if !usesAppleSignupAuth {
                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "passwordEdited")
                passwordError = ""
            }
        }
        .onChange(of: confirmPassword) { _, _ in
            if !usesAppleSignupAuth {
                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "passwordEdited")
                passwordError = ""
            }
        }
        .onChange(of: displayNameDraft) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "signupEdited")
            refreshDisplayNameValidation(markTouched: false)
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task { await loadPendingAvatar(from: item) }
        }
        .sheet(isPresented: $showFavoriteTeamsPicker) {
            FavoriteTeamsPickerSheet(selectedIDs: $favoriteTeamIDs)
        }
        .sheet(isPresented: $showNationalTeamPicker) {
            NationalTeamPickerSheet(currentIdentity: selectedNationalTeam) { identity in
                selectedNationalTeam = identity
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: viewModel.isLoggedIn) { wasLoggedIn, isLoggedIn in
            if !wasLoggedIn && isLoggedIn && !profileRetryMode && errorMessage.isEmpty {
                onDismissAfterSuccess()
            }
        }
        .onChange(of: viewModel.applePendingFanSignupEmail) { _, _ in
            applyApplePendingSignupState()
        }
        .onChange(of: viewModel.applePendingFanSignupDisplayName) { _, _ in
            applyApplePendingSignupState()
        }
    }

    private var onboardingTopBar: some View {
        VStack(spacing: 18) {
            HStack {
                Button {
                    if let previous = currentStep.previous {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            currentStep = previous
                            errorMessage = ""
                        }
                    } else {
                        onSwitchToSignIn()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)

                Spacer()

                Text(
                    String(
                        format: L10n.t("onboarding_step_of_format", languageCode: appLanguageRaw),
                        locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
                        currentStep.rawValue,
                        SignupStep.allCases.count
                    )
                )
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
                    .accessibilityLabel(
                        String(
                            format: L10n.t("onboarding_step_of_format", languageCode: appLanguageRaw),
                            locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
                            currentStep.rawValue,
                            SignupStep.allCases.count
                        )
                    )

                Spacer()

                Color.clear
                    .frame(width: 36, height: 36)
            }

            HStack(spacing: 7) {
                ForEach(SignupStep.allCases, id: \.rawValue) { step in
                    Capsule(style: .continuous)
                        .fill(step.rawValue <= currentStep.rawValue ? FGColor.brandGradient : LinearGradient(colors: [FGColor.divider(colorScheme), FGColor.divider(colorScheme)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 54)
        }
    }

    private var profileStepValueProposition: some View {
        VStack(spacing: 8) {
            Text(L10n.t("onboarding_step1_title", languageCode: appLanguageRaw))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .accessibilityAddTraits(.isHeader)

            Text(L10n.t("onboarding_step1_subtitle", languageCode: appLanguageRaw))
                .font(FGTypography.caption.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var profileStepAuthAndIdentityContent: some View {
        VStack(spacing: 16) {
            if usesAppleSignupAuth {
                appleSignedInBanner
            } else {
                orContinueWithEmailDivider
                profileAccountDetailsGroup
            }

            profileFanIdentityGroup
        }
    }

    private var orContinueWithEmailDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(FGColor.divider(colorScheme).opacity(0.85))
                .frame(height: 1)
            Text(L10n.t("onboarding_or_continue_with_email", languageCode: appLanguageRaw))
                .font(FGTypography.metadata.weight(.bold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Rectangle()
                .fill(FGColor.divider(colorScheme).opacity(0.85))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private var profileAccountDetailsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            profileSectionHeader(
                systemImage: "envelope.fill",
                title: L10n.t("onboarding_account_details_title", languageCode: appLanguageRaw),
                helper: L10n.t("onboarding_account_details_helper", languageCode: appLanguageRaw)
            )

            VStack(spacing: 13) {
                onboardingField(systemImage: "envelope", placeholder: "you@email.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !emailError.isEmpty { fieldError(emailError) }

                passwordEntryField(
                    placeholder: "Create a password",
                    text: $password,
                    isVisible: $showPassword
                )
                passwordEntryField(
                    placeholder: "Confirm password",
                    text: $confirmPassword,
                    isVisible: $showConfirmPassword
                )
                if !passwordError.isEmpty { fieldError(passwordError) }
            }
        }
        .fanGeoGlassCard()
    }

    private var profileFanIdentityGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            profileSectionHeader(
                systemImage: "person.fill",
                title: L10n.t("onboarding_fan_identity_title", languageCode: appLanguageRaw),
                helper: L10n.t("onboarding_fan_identity_helper", languageCode: appLanguageRaw)
            )

            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    onboardingAvatarPreview
                        .frame(width: 112, height: 112)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 3)
                                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 8, y: 3)
                        }

                    PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(FGColor.brandGradient)
                            .clipShape(Circle())
                            .shadow(color: FGColor.accentBlue.opacity(0.28), radius: 8, y: 4)
                    }
                    .disabled(isSubmitting)
                    .accessibilityLabel(L10n.t("onboarding_avatar_optional_label", languageCode: appLanguageRaw))
                    .offset(x: -2, y: -2)
                }
                .frame(maxWidth: .infinity)

                Text(L10n.t("onboarding_avatar_optional_label", languageCode: appLanguageRaw))
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 13) {
                if !usesAppleProvidedDisplayName {
                    onboardingField(systemImage: "person", placeholder: "Display name", text: $displayNameDraft)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onChange(of: displayNameDraft) { _, newValue in
                            if newValue.count > Self.displayNameMaxLength {
                                displayNameDraft = String(newValue.prefix(Self.displayNameMaxLength))
                            }
                        }
                    if !displayNameError.isEmpty { fieldError(displayNameError) }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("@")
                            .font(FGTypography.body.weight(.heavy))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        TextField("handle", text: $handleDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(FGTypography.body)
                        if handleIsConfirmedAvailable {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(FGColor.accentGreen)
                        }
                    }
                    .fanGeoInputFieldStyle()

                    if !handleStatusMessage.isEmpty {
                        HandleAvailabilityStatusLabel(
                            message: handleStatusMessage,
                            isPositive: handleStatusIsPositive
                        )
                    }
                }
            }
        }
        .fanGeoGlassCard()
    }

    private func profileSectionHeader(systemImage: String, title: String, helper: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FGColor.accentBlue)
                    .accessibilityHidden(true)
                Text(title)
                    .font(FGTypography.caption.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            Text(helper)
                .font(FGTypography.metadata.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var onboardingStepContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(currentStepTitle)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .accessibilityAddTraits(.isHeader)
                Text(currentStepSubtitle)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)

            switch currentStep {
            case .profile:
                EmptyView()
            case .fanIdentity:
                fanIdentityStepCard
            case .bio:
                bioStepCard
            }
        }
    }

    private var currentStepTitle: String {
        switch currentStep {
        case .profile:
            return L10n.t("onboarding_step1_title", languageCode: appLanguageRaw)
        case .fanIdentity:
            return L10n.t("onboarding_build_fan_identity_title", languageCode: appLanguageRaw)
        case .bio:
            return L10n.t("onboarding_tell_fans_about_yourself_title", languageCode: appLanguageRaw)
        }
    }

    private var currentStepSubtitle: String {
        switch currentStep {
        case .profile:
            return L10n.t("onboarding_step1_subtitle", languageCode: appLanguageRaw)
        case .fanIdentity:
            return L10n.t("onboarding_build_fan_identity_subtitle", languageCode: appLanguageRaw)
        case .bio:
            return L10n.t("onboarding_bio_subtitle", languageCode: appLanguageRaw)
        }
    }

    private var fanIdentityStepCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                fanIdentitySectionHeader(
                    title: L10n.t("Favorite Teams", languageCode: appLanguageRaw),
                    helper: L10n.t("onboarding_favorite_teams_helper", languageCode: appLanguageRaw)
                )

                LazyVGrid(columns: onboardingGridColumns, spacing: 8) {
                    ForEach(onboardingTeamSuggestions) { team in
                        onboardingFavoriteTeamCard(team)
                    }

                    Button {
                        showFavoriteTeamsPicker = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            Text(L10n.t("Add more", languageCode: appLanguageRaw))
                                .font(FGTypography.caption.weight(.bold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92)
                        .background(FGColor.cardBackground(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(FGColor.divider(colorScheme).opacity(0.7), lineWidth: 1)
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.05), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("Add more", languageCode: appLanguageRaw))
                }
            }

            Rectangle()
                .fill(FGColor.divider(colorScheme).opacity(0.55))
                .frame(height: 1)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                fanIdentitySectionHeader(
                    title: L10n.t("onboarding_country_section", languageCode: appLanguageRaw),
                    helper: L10n.t("onboarding_country_question", languageCode: appLanguageRaw)
                )

                HStack(spacing: 8) {
                    ForEach(onboardingCountryOptions) { option in
                        onboardingCountryChip(option)
                    }

                    Button {
                        showNationalTeamPicker = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .frame(width: 48, height: 48)
                                .background(FGColor.cardBackground(colorScheme))
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                                }
                            Text(L10n.t("More", languageCode: appLanguageRaw))
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("More", languageCode: appLanguageRaw))
                }
                .frame(maxWidth: .infinity)

                if let selectedNationalTeam {
                    NationalTeamIdentityCard(
                        identity: selectedNationalTeam,
                        showsEditAffordance: true,
                        compact: true,
                        presentationStyle: .joiningTeam
                    ) {
                        showNationalTeamPicker = true
                    }
                }
            }

            if let summary = fanIdentitySelectionSummaryVisibleText {
                Text(summary)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fanIdentitySelectionSummaryAccessibilityText)
            }
        }
    }

    private func fanIdentitySectionHeader(title: String, helper: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .accessibilityAddTraits(.isHeader)
            Text(helper)
                .font(FGTypography.metadata.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bioStepCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t(Self.bioOptionalHelperKey, languageCode: appLanguageRaw))
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.t(Self.bioFieldLabelKey, languageCode: appLanguageRaw))
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.8)

            ZStack(alignment: .topLeading) {
                // TextField + chrome first so the placeholder can sit *above* the input
                // background. Previously the placeholder was under
                // `FGInputFieldStyleModifier`'s ~0.97-opaque fill and looked invisible.
                TextField("", text: $bioDraft, axis: .vertical)
                    .lineLimit(4...6)
                    .font(FGTypography.body)
                    .fanGeoInputFieldStyle()
                    .focused($isBioFieldFocused)
                    .accessibilityLabel(bioFieldAccessibilityLabel)
                    .accessibilityHint(
                        shouldShowBioPlaceholder
                            ? ""
                            : L10n.t("onboarding_bio_subtitle", languageCode: appLanguageRaw)
                    )
                    .onChange(of: bioDraft) { _, newValue in
                        if newValue.count > Self.bioCharacterLimit {
                            bioDraft = String(newValue.prefix(Self.bioCharacterLimit))
                        }
                    }

                if shouldShowBioPlaceholder {
                    Text(bioExamplePlaceholderText)
                        .font(FGTypography.body)
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.top, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(1)
                }
            }

            HStack {
                Spacer()
                Text("\(bioDraft.count)/\(Self.bioCharacterLimit)")
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .fanGeoGlassCard()
    }

    private var onboardingBottomControls: some View {
        let isContinueDisabled = isPrimaryOnboardingActionDisabled
        return VStack(spacing: 12) {
            Button {
                Task { await advanceOnboarding() }
            } label: {
                HStack {
                    Spacer()
                    Text(primaryOnboardingButtonTitle)
                        .font(FGTypography.cardTitle.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Image(systemName: currentStep == .bio ? "checkmark" : "arrow.right")
                        .font(.subheadline.weight(.heavy))
                    Spacer()
                }
                .foregroundStyle(isContinueDisabled ? Color.gray : Color.white)
                .padding(.vertical, 15)
                .padding(.horizontal, 12)
                .background(
                    isContinueDisabled
                        ? AnyShapeStyle(Color.gray.opacity(0.35))
                        : AnyShapeStyle(FGColor.brandGradient)
                )
                .clipShape(Capsule(style: .continuous))
                .shadow(
                    color: isContinueDisabled ? .clear : FGColor.accentBlue.opacity(0.28),
                    radius: 12,
                    y: 6
                )
            }
            .buttonStyle(.plain)
            .disabled(isContinueDisabled)
            .opacity(isContinueDisabled ? 0.7 : 1)
            .accessibilityLabel(primaryOnboardingButtonTitle)
            .accessibilityAddTraits(.isButton)

            if currentStep == .fanIdentity {
                Button(L10n.t("Skip for now", languageCode: appLanguageRaw)) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        // Preserve any in-progress selections; Skip only advances.
                        currentStep = currentStep.next ?? currentStep
                    }
                }
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(FGColor.accentBlue)
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
        }
    }

    /// Gates Step 1 Continue and final submit using the same field/Terms rules as `canSubmit`.
    private var isPrimaryOnboardingActionDisabled: Bool {
        if isSubmitting { return true }
        switch currentStep {
        case .profile, .bio:
            return !canSubmit
        case .fanIdentity:
            return false
        }
    }

    private var primaryOnboardingButtonTitle: String {
        if currentStep == .bio { return submitButtonTitle }
        return L10n.t("Continue", languageCode: appLanguageRaw)
    }

    private var onboardingGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    }

    private var onboardingTeamSuggestions: [FavoriteTeam] {
        // Quick-pick chips only — full Sport/Region/Country browsing uses FavoriteTeamsPickerSheet → allEntities.
        let preferredNames = [
            "France", "Real Madrid", "Juventus", "Los Angeles Lakers", "Utah Jazz",
            "Dallas Cowboys", "Manchester United", "Miami Heat",
            "Flamengo", "Yomiuri Giants", "Real Madrid Basketball"
        ]
        var selected = preferredNames.compactMap { preferred in
            FavoriteTeamCatalog.allEntities.first { team in
                team.name.localizedCaseInsensitiveCompare(preferred) == .orderedSame
                    || team.name.localizedCaseInsensitiveContains(preferred)
            }
        }
        var seen = Set(selected.map(\.id))
        selected.append(contentsOf: selectedFavoriteTeams.filter { seen.insert($0.id).inserted })
        return Array(selected.prefix(8))
    }

    private var onboardingCountryOptions: [NationalTeamCountryOption] {
        ["United States", "France", "Brazil", "Mexico"]
            .compactMap { NationalTeamCountryCatalog.option(named: $0, popular: true) }
    }

    private func onboardingFavoriteTeamCard(_ team: FavoriteTeam) -> some View {
        let isSelected = favoriteTeamIDs.contains(team.id)
        return Button {
            if isSelected {
                favoriteTeamIDs.remove(team.id)
            } else {
                favoriteTeamIDs.insert(team.id)
            }
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    SportsIdentityArtworkView(favoriteTeam: team, diameter: 44)
                        .accessibilityHidden(true)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white, FGColor.accentBlue)
                            .offset(x: 6, y: -6)
                            .accessibilityHidden(true)
                    }
                }

                Text(team.name)
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? FGColor.brandGradient : LinearGradient(colors: [FGColor.cardBackground(colorScheme), FGColor.cardBackground(colorScheme)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.22) : FGColor.divider(colorScheme).opacity(0.6), lineWidth: 1)
            }
            .shadow(color: (isSelected ? FGColor.accentBlue : Color.black).opacity(isSelected ? 0.22 : (colorScheme == .dark ? 0.14 : 0.05)), radius: isSelected ? 12 : 8, y: isSelected ? 6 : 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(team.name)
        .accessibilityValue(
            isSelected
                ? L10n.t("onboarding_favorite_team_selected_a11y", languageCode: appLanguageRaw)
                : L10n.t("onboarding_favorite_team_unselected_a11y", languageCode: appLanguageRaw)
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func onboardingCountryChip(_ option: NationalTeamCountryOption) -> some View {
        let identity = NationalTeamIdentity(
            countryCode: option.code,
            countryName: option.name,
            flag: option.flag,
            supporterLabel: NationalTeamCopy.defaultSupporterLabelKey
        )
        let isSelected = selectedNationalTeam?.countryCode == option.code
        let chipTitle = option.code == "US"
            ? L10n.t("onboarding_country_chip_usa", languageCode: appLanguageRaw)
            : option.name
        return Button {
            selectedNationalTeam = identity
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Text(option.flag)
                        .font(.system(size: 32))
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.92))
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(isSelected ? FGColor.accentBlue : FGColor.divider(colorScheme), lineWidth: isSelected ? 3 : 1)
                        }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white, FGColor.accentBlue)
                    }
                }
                Text(chipTitle)
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
        .accessibilityValue(
            isSelected
                ? L10n.t("onboarding_country_selected_a11y", languageCode: appLanguageRaw)
                : L10n.t("onboarding_country_unselected_a11y", languageCode: appLanguageRaw)
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func onboardingField(systemImage: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 18)
            TextField(placeholder, text: text)
                .font(FGTypography.body)
        }
        .fanGeoInputFieldStyle()
    }

    private func passwordEntryField(
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

    @ViewBuilder
    private var onboardingAvatarPreview: some View {
        if let pendingAvatarData, let image = UIImage(data: pendingAvatarData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            UserAvatarView(
                avatarThumbnailURL: nil,
                avatarURL: "",
                avatarDisplayRefreshToken: UserAvatarView.placeholderRefreshToken,
                displayName: displayNameDraft,
                email: email,
                size: 112,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
        }
    }

    @MainActor
    private func advanceOnboarding() async {
        switch currentStep {
        case .profile:
            guard await validateProfileStepBeforeContinue() else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                currentStep = .fanIdentity
                errorMessage = ""
            }
        case .fanIdentity:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                currentStep = .bio
                errorMessage = ""
            }
        case .bio:
            await submitSignup()
        }
    }

    @MainActor
    private func validateProfileStepBeforeContinue() async -> Bool {
        errorMessage = ""
        emailError = ""
        passwordError = ""
        refreshDisplayNameValidation(markTouched: true)

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty {
            emailError = usesAppleSignupAuth ? "Apple did not return a usable email address." : "Email is required."
            return false
        }
        if !OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(trimmedEmail)) {
            emailError = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            return false
        }
        if !usesAppleSignupAuth, password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Password is required."
            return false
        }
        if !usesAppleSignupAuth, confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Confirm password is required."
            return false
        }
        if !usesAppleSignupAuth, password != confirmPassword {
            passwordError = "Passwords do not match."
            return false
        }
        if !displayNameError.isEmpty, !usesAppleProvidedDisplayName {
            return false
        }
        if ReservedNameValidation.containsReservedTerm(effectiveDisplayNameForSignup) {
            if usesAppleProvidedDisplayName {
                errorMessage = ReservedNameValidation.rejectionMessage
            } else {
                displayNameError = ReservedNameValidation.rejectionMessage
            }
            return false
        }
        if let issue = FanGeoHandleRules.validate(handleDraft) {
            // Keep ordinary handle format failures inline — do not surface the account-creation banner.
            handleStatusMessage = FanGeoHandleRules.validationMessage(for: issue)
            handleStatusIsPositive = false
            return false
        }

        if !handleIsConfirmedAvailable {
            let stored = FanGeoHandleRules.normalizeForStorage(handleDraft)
            handleStatusMessage = "Checking availability..."
            guard let available = await viewModel.checkUsernameAvailableForSignup(handleDraft) else {
                errorMessage = "Could not verify whether this handle is available. Please try again."
                handleStatusMessage = errorMessage
                handleStatusIsPositive = false
                return false
            }
            print("[SignupUX] handleCheck username=\(stored) available=\(available)")
            print("[HandleValidationDebug] handleAvailable=\(available)")
            guard available else {
                handleStatusMessage = "Already taken"
                handleStatusIsPositive = false
                handleIsConfirmedAvailable = false
                print("[HandleValidationDebug] handleRejected reason=already_taken")
                return false
            }
            handleStatusMessage = "Available"
            handleStatusIsPositive = true
            handleIsConfirmedAvailable = true
        }

        if !termsAccepted {
            errorMessage = "Accept the Terms of Use and Community Guidelines to continue."
            return false
        }

        return true
    }

    private var signupGlassCard: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            avatarPickerRow

            if usesAppleSignupAuth {
                appleSignedInBanner
            } else {
                labeledField(title: "Email", required: true) {
                    TextField("you@email.com", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .font(FGTypography.body)
                        .fanGeoInputFieldStyle()
                        .disabled(profileRetryMode)
                }
                if !emailError.isEmpty {
                    fieldError(emailError)
                }

                labeledField(title: "Password", required: true) {
                    VStack(spacing: 10) {
                        passwordEntryField(
                            placeholder: "Create a password",
                            text: $password,
                            isVisible: $showPassword
                        )
                        .disabled(profileRetryMode)
                        passwordEntryField(
                            placeholder: "Confirm password",
                            text: $confirmPassword,
                            isVisible: $showConfirmPassword
                        )
                        .disabled(profileRetryMode)
                    }
                }
                if !passwordError.isEmpty {
                    fieldError(passwordError)
                }
            }

            if !usesAppleProvidedDisplayName {
                labeledField(title: "Display name", required: true) {
                    TextField("Your name", text: $displayNameDraft)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .font(FGTypography.body)
                        .fanGeoInputFieldStyle()
                        .onChange(of: displayNameDraft) { _, newValue in
                            if newValue.count > Self.displayNameMaxLength {
                                displayNameDraft = String(newValue.prefix(Self.displayNameMaxLength))
                            }
                        }
                }
                if !displayNameError.isEmpty {
                    fieldError(displayNameError)
                }
            }

            labeledField(title: "@handle", required: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("@")
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        TextField("handle", text: $handleDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(FGTypography.body)
                    }
                    .fanGeoInputFieldStyle()

                    Text(handlePreview)
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.mutedText(colorScheme))

                    if !handleStatusMessage.isEmpty {
                        HandleAvailabilityStatusLabel(
                            message: handleStatusMessage,
                            isPositive: handleStatusIsPositive
                        )
                    }
                }
            }

            labeledField(title: "Bio", required: false) {
                TextField("Optional", text: $bioDraft, axis: .vertical)
                    .lineLimit(2...4)
                    .font(FGTypography.body)
                    .fanGeoInputFieldStyle()
                    .onChange(of: bioDraft) { _, newValue in
                        if newValue.count > Self.bioCharacterLimit {
                            bioDraft = String(newValue.prefix(Self.bioCharacterLimit))
                        }
                    }
            }

            favoriteTeamsRow
        }
        .fanGeoGlassCard()
    }

    private var signupLegalFooter: some View {
        Text(signupLegalFooterText)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .multilineTextAlignment(.center)
            .tint(FGColor.accentBlue)
            .environment(\.openURL, OpenURLAction { url in
                openURL(url)
                return .handled
            })
            .padding(.horizontal, FGSpacing.sm)
    }

    private var signupLegalFooterText: AttributedString {
        var text = AttributedString("By creating an account, you agree to FanGeo's Terms of Service and Privacy Policy.")
        if let range = text.range(of: "Terms of Service") {
            text[range].link = FanGeoLegalLinks.termsOfService
            text[range].foregroundColor = FGColor.accentBlue
            text[range].underlineStyle = .single
        }
        if let range = text.range(of: "Privacy Policy") {
            text[range].link = FanGeoLegalLinks.privacyPolicy
            text[range].foregroundColor = FGColor.accentBlue
            text[range].underlineStyle = .single
        }
        return text
    }

    private var handlePreview: String {
        let slug = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty { return "@yourname" }
        return "@\(slug)"
    }

    private var avatarPickerRow: some View {
        HStack(spacing: FGSpacing.md) {
            signupAvatarPreview
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add profile photo")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Optional")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            .disabled(isSubmitting)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var signupAvatarPreview: some View {
        if let pendingAvatarData, let image = UIImage(data: pendingAvatarData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
        } else {
            UserAvatarView(
                avatarThumbnailURL: nil,
                avatarURL: "",
                avatarDisplayRefreshToken: UserAvatarView.placeholderRefreshToken,
                displayName: displayNameDraft,
                email: email,
                size: 64,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
        }
    }

    private var favoriteTeamsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick your teams")
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.5)

            HStack {
                if selectedFavoriteTeams.isEmpty {
                    Text("Optional — add teams you follow")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                } else {
                    Text(selectedFavoriteTeams.map(\.name).joined(separator: ", "))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Choose") {
                    showFavoriteTeamsPicker = true
                }
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
            }
        }
    }

    private var selectedFavoriteTeams: [FavoriteTeam] {
        favoriteTeamIDs
            .compactMap { FavoriteTeamCatalog.team(id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var fanIdentitySelectionSummaryVisibleText: String? {
        let teamCount = selectedFavoriteTeams.count
        let countryName = selectedNationalTeam?.countryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCountry = !(countryName?.isEmpty ?? true)
        let locale = Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw))

        switch (teamCount, hasCountry) {
        case (0, false):
            return nil
        case (0, true):
            return String(
                format: L10n.t("onboarding_fan_identity_summary_country_only_format", languageCode: appLanguageRaw),
                locale: locale,
                countryName ?? ""
            )
        case (1, false):
            return L10n.t("onboarding_fan_identity_summary_one_team", languageCode: appLanguageRaw)
        case (_, false):
            return String(
                format: L10n.t("onboarding_fan_identity_summary_teams_only_format", languageCode: appLanguageRaw),
                locale: locale,
                teamCount
            )
        case (1, true):
            return String(
                format: L10n.t("onboarding_fan_identity_summary_one_team_and_country_format", languageCode: appLanguageRaw),
                locale: locale,
                countryName ?? ""
            )
        default:
            return String(
                format: L10n.t("onboarding_fan_identity_summary_teams_and_country_format", languageCode: appLanguageRaw),
                locale: locale,
                teamCount,
                countryName ?? ""
            )
        }
    }

    private var fanIdentitySelectionSummaryAccessibilityText: String {
        fanIdentitySelectionSummaryVisibleText ?? ""
    }

    private var shouldShowBioPlaceholder: Bool {
        bioDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bioExamplePlaceholderText: String {
        L10n.t(Self.bioExamplePlaceholderKey, languageCode: appLanguageRaw)
    }

    private var bioFieldAccessibilityLabel: String {
        if shouldShowBioPlaceholder {
            return L10n.t(Self.bioEmptyAccessibilityKey, languageCode: appLanguageRaw)
        }
        return L10n.t(Self.bioFieldLabelKey, languageCode: appLanguageRaw)
    }

    private func presentOnboardingFavoriteAddedConfirmation(for team: FavoriteTeam) {
        let moment = WowMomentCopy.onboardingFavoriteAdded(
            teamName: team.name,
            sport: team.sport,
            languageCode: appLanguageRaw,
            dedupeKey: "onboarding-favorite:\(team.id)"
        )
        onboardingWowOverlay.presentFavoriteCoalesced(
            moment,
            recordAnalytics: false,
            visibleDurationNanoseconds: WowMomentOverlayManager.onboardingFavoriteVisibleDurationNanoseconds
        )
    }

    private var submitButton: some View {
        FGPrimaryButton(
            title: submitButtonTitle,
            isDisabled: !canSubmit || isSubmitting
        ) {
            Task { await submitSignup() }
        }
    }

    private var submitButtonTitle: String {
        if isSubmitting {
            if usesAppleSignupAuth {
                return "Creating profile…"
            }
            return profileRetryMode ? "Saving profile…" : "Creating account…"
        }
        if profileRetryMode {
            return "Retry saving profile"
        }
        if usesAppleSignupAuth {
            return "Create profile"
        }
        return "Create FanGeo account"
    }

    private var canSubmit: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailIsValid = !trimmedEmail.isEmpty
            && OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(trimmedEmail))

        if profileRetryMode {
            return profileFieldsValid && emailIsValid && termsAccepted
        }
        if usesAppleSignupAuth {
            return profileFieldsValid
                && emailIsValid
                && termsAccepted
        }
        return profileFieldsValid
            && emailIsValid
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && password == confirmPassword
            && termsAccepted
    }

    private var fanSignupAuthMode: FanSignupAuthMode {
        viewModel.isAppleFanSignupOnboardingActive ? .apple : .emailPassword
    }

    private var usesAppleSignupAuth: Bool {
        fanSignupAuthMode == .apple
    }

    private var appleProvidedDisplayName: String {
        viewModel.applePendingFanSignupDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var usesAppleProvidedDisplayName: Bool {
        usesAppleSignupAuth && !appleProvidedDisplayName.isEmpty
    }

    private var effectiveDisplayNameForSignup: String {
        let draft = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { return draft }
        if usesAppleProvidedDisplayName { return appleProvidedDisplayName }
        return ""
    }

    private var appleSignedInBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo")
                .font(.body.weight(.bold))
            Text("Signed in with Apple")
                .font(FGTypography.body.weight(.semibold))
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FGColor.accentGreen)
        }
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @MainActor
    private func applyApplePendingSignupState() {
        guard usesAppleSignupAuth else { return }
        let normalizedEmail = OwnerBusinessEmail.normalized(viewModel.applePendingFanSignupEmail)
        if !normalizedEmail.isEmpty {
            email = normalizedEmail
        }
        password = ""
        confirmPassword = ""
        errorMessage = ""
        emailError = ""
        passwordError = ""
        if usesAppleProvidedDisplayName {
            displayNameDraft = appleProvidedDisplayName
            displayNameError = ""
        }
    }

    private var profileFieldsValid: Bool {
        let trimmedName = effectiveDisplayNameForSignup
        return !trimmedName.isEmpty
            && trimmedName.count <= Self.displayNameMaxLength
            && !ReservedNameValidation.containsReservedTerm(trimmedName)
            && FanGeoHandleRules.validate(handleDraft) == nil
            && handleIsConfirmedAvailable
    }

    private func labeledField<Content: View>(
        title: String,
        required: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .textCase(.uppercase)
                    .tracking(0.5)
                if !required {
                    Text("Optional")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.8))
                }
            }
            content()
        }
    }

    private func fieldError(_ text: String) -> some View {
        Text(text)
            .font(FGTypography.caption)
            .foregroundStyle(.red)
    }

    @MainActor
    private func refreshDisplayNameValidation(markTouched: Bool) {
        if usesAppleProvidedDisplayName {
            displayNameError = ""
            return
        }
        let trimmed = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if markTouched || !displayNameError.isEmpty {
                displayNameError = "Display name is required."
            }
            return
        }
        if trimmed.count > Self.displayNameMaxLength {
            displayNameError = "Display name is too long."
            return
        }
        if ReservedNameValidation.containsReservedTerm(trimmed) {
            displayNameError = ReservedNameValidation.rejectionMessage
            return
        }
        displayNameError = ""
    }

    @MainActor
    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false
        handleIsConfirmedAvailable = false

        let stored = FanGeoHandleRules.normalizeForStorage(handleDraft)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")

        if let issue = FanGeoHandleRules.validate(handleDraft) {
            handleStatusMessage = "Invalid handle: \(FanGeoHandleRules.validationMessage(for: issue))"
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }

        handleStatusMessage = "Checking availability..."
        availabilityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            guard let available = await viewModel.checkUsernameAvailableForSignup(handleDraft) else { return }
            guard !Task.isCancelled else { return }
            print("[SignupUX] handleCheck username=\(stored) available=\(available)")
            print("[HandleValidationDebug] handleAvailable=\(available)")
            if available {
                handleStatusMessage = "Available"
                handleStatusIsPositive = true
                handleIsConfirmedAvailable = true
            } else {
                handleStatusMessage = "Already taken"
                handleIsConfirmedAvailable = false
                print("[HandleValidationDebug] handleRejected reason=already_taken")
            }
        }
    }

    @MainActor
    private func validateBeforeSubmit() -> Bool {
        errorMessage = ""
        emailError = ""
        passwordError = ""
        refreshDisplayNameValidation(markTouched: true)

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty {
            emailError = "Email is required."
            print("[SignupUX] submitFailed step=validation error=email")
            print("[EmailConfirmDebug] formValidationFailed reason=email_required")
            return false
        }
        if !OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(trimmedEmail)) {
            emailError = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            print("[SignupUX] submitFailed step=validation error=email")
            print("[EmailConfirmDebug] formValidationFailed reason=invalid_email")
            return false
        }

        if !usesAppleSignupAuth, password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Password is required."
            print("[SignupUX] submitFailed step=validation error=password")
            print("[EmailConfirmDebug] formValidationFailed reason=password_required")
            return false
        }
        if !usesAppleSignupAuth, confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Confirm password is required."
            print("[SignupUX] submitFailed step=validation error=confirm_password")
            print("[EmailConfirmDebug] formValidationFailed reason=confirm_password_required")
            return false
        }
        if !usesAppleSignupAuth, password != confirmPassword {
            passwordError = "Passwords do not match."
            print("[SignupUX] submitFailed step=validation error=password_mismatch")
            print("[EmailConfirmDebug] formValidationFailed reason=password_mismatch")
            return false
        }

        if !displayNameError.isEmpty, !usesAppleProvidedDisplayName {
            print("[SignupUX] submitFailed step=validation error=displayName")
            print("[EmailConfirmDebug] formValidationFailed reason=display_name_invalid")
            return false
        }

        if effectiveDisplayNameForSignup.isEmpty {
            print("[SignupUX] submitFailed step=validation error=displayName")
            print("[EmailConfirmDebug] formValidationFailed reason=display_name_required")
            return false
        }

        if ReservedNameValidation.containsReservedTerm(effectiveDisplayNameForSignup) {
            if usesAppleProvidedDisplayName {
                errorMessage = ReservedNameValidation.rejectionMessage
            } else {
                displayNameError = ReservedNameValidation.rejectionMessage
            }
            print("[SignupUX] submitFailed step=validation error=displayNameReserved")
            print("[EmailConfirmDebug] formValidationFailed reason=display_name_reserved")
            return false
        }

        if let issue = FanGeoHandleRules.validate(handleDraft) {
            // Keep ordinary handle format failures inline — do not surface the account-creation banner.
            handleStatusMessage = FanGeoHandleRules.validationMessage(for: issue)
            handleStatusIsPositive = false
            print("[SignupUX] submitFailed step=validation error=handle")
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            print("[EmailConfirmDebug] formValidationFailed reason=invalid_handle")
            return false
        }

        if !profileRetryMode, !termsAccepted {
            errorMessage = "Accept the Terms of Use and Community Guidelines to continue."
            print("[SignupUX] submitFailed step=validation error=policies")
            print("[EmailConfirmDebug] formValidationFailed reason=policies_required")
            return false
        }

        return true
    }

    private func buildProfileInput() -> FanSignupProfileInput {
        let bioTrimmed = bioDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return FanSignupProfileInput(
            displayName: effectiveDisplayNameForSignup,
            handle: handleDraft,
            bio: bioTrimmed.isEmpty ? MapViewModel.defaultFanSignupBio : bioTrimmed,
            avatarData: pendingAvatarData,
            favoriteTeamIDs: favoriteTeamIDs.sorted(),
            nationalTeamIdentity: selectedNationalTeam
        )
    }

    @MainActor
    private func submitSignup() async {
        if !usesAppleSignupAuth {
            print("[EmailConfirmDebug] signupButtonTapped=true")
        }
        guard validateBeforeSubmit() else { return }

        viewModel.clearAppleAuthMessage(
            accountMode: .fan,
            reason: usesAppleSignupAuth ? "appleProfileSubmit" : "emailPasswordSignUp"
        )
        print("[SignupUX] submitStarted")
        isSubmitting = true
        defer { isSubmitting = false }

        let profile = buildProfileInput()

        if profileRetryMode {
            let outcome = await viewModel.retryFanSignupProfileSave(profile: profile)
            if outcome.succeeded {
                errorMessage = ""
                profileRetryMode = false
                onDismissAfterSuccess()
            } else {
                errorMessage = outcome.errorMessage ?? "Couldn’t save your profile. Please try again."
            }
            return
        }

        if usesAppleSignupAuth {
            print("[FanSignupDebug] submitApplePendingProfile=true email=\(email)")
            let outcome = await viewModel.completeAppleFanSignupProfile(
                profile: profile,
                recordFanGuidelinesAcceptance: termsAccepted
            )
            if outcome.succeeded {
                errorMessage = ""
                profileRetryMode = false
                onDismissAfterSuccess()
                return
            }
            if outcome.authSucceeded {
                profileRetryMode = true
            }
            errorMessage = outcome.errorMessage ?? "Couldn’t save your profile. Please try again."
            return
        }

        let outcome = await viewModel.registerFanAccountWithProfile(
            email: email,
            password: password,
            profile: profile,
            recordFanGuidelinesAcceptance: termsAccepted
        )

        if outcome.succeeded, !outcome.authSucceeded {
            errorMessage = ""
            profileRetryMode = false
            password = ""
            confirmPassword = ""
            return
        }

        if outcome.succeeded {
            errorMessage = ""
            profileRetryMode = false
            onDismissAfterSuccess()
            return
        }

        if outcome.authSucceeded {
            profileRetryMode = true
            password = ""
        }

        errorMessage = outcome.errorMessage ?? "Something went wrong. Please try again."
    }

    @MainActor
    private func loadPendingAvatar(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        pendingAvatarData = data
    }
}

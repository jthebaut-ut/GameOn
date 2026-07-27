import PhotosUI
import CoreLocation
import SwiftUI

// MARK: - Venue tab

/// Venue owner sign-in or combined business + first-location signup (inside ``SettingsVenueAuthSheet`` while logged out).
struct SettingsVenueOwnerCard: View {
    private enum BusinessSignupStep: Int, CaseIterable {
        case account = 1
        case venue = 2
        case experience = 3
        case review = 4

        var title: String {
            switch self {
            case .account: return "Create your business account"
            case .venue: return "Add your first venue"
            case .experience: return "What makes your venue special?"
            case .review: return "Show fans your venue"
            }
        }

        var subtitle: String {
            switch self {
            case .account:
                return "Manage your venues, watch parties, and sports events on FanGeo."
            case .venue:
                return "Now add your first venue for FanGeo review."
            case .experience:
                return "Help fans understand the match-day experience before they arrive."
            case .review:
                return "Add photos and proof so FanGeo can review your first location."
            }
        }

        var previous: BusinessSignupStep? {
            BusinessSignupStep(rawValue: rawValue - 1)
        }

        var next: BusinessSignupStep? {
            BusinessSignupStep(rawValue: rawValue + 1)
        }
    }

    @ObservedObject var viewModel: MapViewModel
    @Binding var venuePassword: String
    @Binding var showVenueRegisterMode: Bool
    @Binding var businessAuthEntryMode: BusinessAuthEntryMode
    @Binding var authTermsAccepted: Bool
    @State private var venueSignupPoliciesAccepted = false
    @State private var venueSignupLegalDocument: SettingsLegalDocumentKind?
    @State private var isSignupSubmitting = false
    @State private var showBusinessPasswordResetSheet = false
    @State private var businessSignupStep: BusinessSignupStep = .account
    @State private var businessSignupStepMessage: String?
    @State private var isCheckingBusinessSignupEmail = false
    @State private var businessSignupEmailInlineError: String?
    @State private var confirmVenuePassword = ""
    @State private var businessSignupPasswordInlineError: String?
    @State private var showBusinessSignupPassword = false
    @State private var showBusinessSignupConfirmPassword = false
    @State private var showBusinessLoginPassword = false
    /// Local sign-in email draft — typing must not republish ``MapViewModel.venueOwnerEmail``.
    @State private var businessLoginEmailDraft = ""
    @State private var didInitializeBusinessLoginEmailDraft = false
    @FocusState private var businessLoginFocusedField: BusinessLoginFocusField?
#if DEBUG
    @State private var businessLoginFormInstanceId = UUID()
#endif

    private enum BusinessLoginFocusField: Hashable {
        case email
        case password
    }

    @State private var signupBusinessName = ""
    @State private var signupBusinessHandle = ""
    @State private var signupBusinessHandleInlineError: String?
    @State private var isCheckingBusinessSignupHandle = false
    @State private var signupLocationName = ""
    @State private var signupStreet = ""
    @State private var signupAddressLine2 = ""
    @State private var signupCity = ""
    @State private var signupState = ""
    @State private var signupCountry = BusinessLocationCountryPolicy.defaultCountryCode
    @State private var signupZip = ""
    @State private var signupLatitude: Double?
    @State private var signupLongitude: Double?
    @State private var signupFormattedAddress = ""
    @State private var signupLocationUpdateSource: BusinessVenueLocationUpdateSource = .manualAddress
    @State private var signupLocationRevision: UInt64 = 0
    @State private var signupAddressNeedsConfirmation = false
    @State private var signupPhoneDialISO = BusinessPhoneFields.defaultISO
    @State private var signupPhoneLocal = ""
    @State private var signupWebsite = ""
    @State private var signupDescription = ""
    @State private var signupProof = ""
    @State private var signupScreenCount = 1
    @State private var signupServesFood = false
    @State private var signupHasWifi = false
    @State private var signupHasGarden = false
    @State private var signupHasProjector = false
    @State private var signupPetFriendly = false
    @State private var signupFamilyFriendly = false
    @State private var signupParking = false
    @State private var signupEasyParking = false
    @State private var signupHandicapParking = false
    @State private var signupLiveMusic = false
    @State private var signupPoolTables = false
    @State private var signupRooftop = false
    @State private var signupDJNights = false
    @State private var signupKaraoke = false
    @State private var signupCocktails = false
    @State private var signupCraftBeer = false
    @State private var signupCoverPicker: PhotosPickerItem?
    @State private var signupMenuPicker: PhotosPickerItem?
    @State private var signupCoverData: Data?
    @State private var signupMenuData: Data?
    @State private var showSignupPinPicker = false
    @State private var isApplyingSignupLocationDraft = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var isApplePendingBusinessSignup: Bool {
        !OwnerBusinessEmail.normalized(viewModel.applePendingBusinessSignupEmail).isEmpty
    }

    private var isPostVerificationVenueSetup: Bool {
        viewModel.businessEmailVerifiedNeedsVenueSetup
    }

    private var businessSignupVisibleSteps: [BusinessSignupStep] {
        if isPostVerificationVenueSetup {
            return [.venue, .experience, .review]
        }
        if isApplePendingBusinessSignup {
            return [.account, .venue, .experience, .review]
        }
        if showVenueRegisterMode {
            return [.account]
        }
        return []
    }

    private var businessSignupAccountOnlyMissingRequirementMessage: String? {
        BusinessCreationFormValidation.businessAccountOnlyMissingRequirementMessage(
            venueOwnerEmail: viewModel.venueOwnerEmail,
            venuePassword: venuePassword,
            authTermsAccepted: authTermsAccepted,
            businessName: signupBusinessName,
            businessHandle: signupBusinessHandle,
            skipEmailPasswordAuthFields: isApplePendingBusinessSignup
        )
    }

    private var businessSignupVenueReviewFields: (
        locationName: String,
        streetAddress: String,
        country: String,
        city: String,
        state: String,
        phoneDialISO: String,
        phoneLocal: String,
        description: String,
        proofNote: String,
        coverPhotoData: Data?
    ) {
        (
            locationName: signupLocationName,
            streetAddress: signupStreet,
            country: signupCountry,
            city: signupCity,
            state: signupState,
            phoneDialISO: signupPhoneDialISO,
            phoneLocal: signupPhoneLocal,
            description: signupDescription,
            proofNote: signupProof,
            coverPhotoData: signupCoverData
        )
    }

    private var businessSignupMissingRequirementMessage: String? {
        let venueFields = businessSignupVenueReviewFields
        if isPostVerificationVenueSetup {
            return BusinessCreationFormValidation.venueReviewSubmissionMissingRequirementMessage(
                locationName: venueFields.locationName,
                streetAddress: venueFields.streetAddress,
                country: venueFields.country,
                city: venueFields.city,
                state: venueFields.state,
                phoneDialISO: venueFields.phoneDialISO,
                phoneLocal: venueFields.phoneLocal,
                description: venueFields.description,
                proofNote: venueFields.proofNote,
                coverPhotoData: venueFields.coverPhotoData,
                policiesAccepted: venueSignupPoliciesAccepted
            )
        }
        if showVenueRegisterMode, businessSignupStep == .review {
            return BusinessCreationFormValidation.businessCreationMissingRequirementMessage(
                isRegisterMode: true,
                venueOwnerEmail: viewModel.venueOwnerEmail,
                venuePassword: venuePassword,
                policiesAccepted: venueSignupPoliciesAccepted,
                businessName: signupBusinessName,
                businessHandle: signupBusinessHandle,
                locationName: venueFields.locationName,
                streetAddress: venueFields.streetAddress,
                country: venueFields.country,
                city: venueFields.city,
                state: venueFields.state,
                zip: signupZip,
                phoneDialISO: venueFields.phoneDialISO,
                phoneLocal: venueFields.phoneLocal,
                description: venueFields.description,
                proofNote: venueFields.proofNote,
                coverPhotoData: venueFields.coverPhotoData,
                skipEmailPasswordAuthFields: isApplePendingBusinessSignup
            )
        }
        return BusinessCreationFormValidation.businessCreationMissingRequirementMessage(
            isRegisterMode: showVenueRegisterMode,
            venueOwnerEmail: viewModel.venueOwnerEmail,
            venuePassword: venuePassword,
            policiesAccepted: venueSignupPoliciesAccepted,
            businessName: signupBusinessName,
            businessHandle: signupBusinessHandle,
            locationName: venueFields.locationName,
            streetAddress: venueFields.streetAddress,
            country: venueFields.country,
            city: venueFields.city,
            state: venueFields.state,
            zip: signupZip,
            phoneDialISO: venueFields.phoneDialISO,
            phoneLocal: venueFields.phoneLocal,
            description: venueFields.description,
            proofNote: venueFields.proofNote,
            coverPhotoData: venueFields.coverPhotoData,
            skipEmailPasswordAuthFields: isApplePendingBusinessSignup
        )
    }

    /// Same gate as ``businessSignupMissingRequirementMessage`` == nil (registration mode only).
    private var registrationFormComplete: Bool {
        businessSignupMissingRequirementMessage == nil
    }

    private var signupPrimarySubmitDisabled: Bool {
        if isSignupSubmitting || isCheckingBusinessSignupHandle { return true }
        if isPostVerificationVenueSetup || isApplePendingBusinessSignup {
            if businessSignupStep == .review {
                return businessSignupMissingRequirementMessage != nil
            }
            return false
        }
        if showVenueRegisterMode {
            if businessSignupStep == .account {
                if !authTermsAccepted { return true }
                return businessSignupAccountOnlyMissingRequirementMessage != nil
            }
            if businessSignupStep == .review {
                return businessSignupMissingRequirementMessage != nil
            }
            return false
        }
        return false
    }

    private var businessSignupPrimaryTitle: String {
        if isSignupSubmitting { return "Submitting..." }
        if businessSignupStep == .account, isCheckingBusinessSignupEmail { return "Checking email..." }
        if businessSignupStep == .account, isCheckingBusinessSignupHandle { return "Checking handle..." }
        if businessSignupStep == .account, !isApplePendingBusinessSignup, !isPostVerificationVenueSetup {
            return "Create business account"
        }
        return businessSignupStep == .review ? "Submit venue for review" : "Continue"
    }

    private var signupAddressLabels: BusinessLocationAddressLabels {
        BusinessLocationCountryPolicy.labels(for: signupCountry)
    }

    private var signupLocationDraft: BusinessVenueLocationDraft {
        BusinessVenueLocationDraft(
            addressLine1: signupStreet,
            addressLine2: signupAddressLine2,
            locality: signupCity,
            region: signupState,
            postalCode: signupZip,
            countryCode: signupCountry,
            latitude: signupLatitude,
            longitude: signupLongitude,
            formattedAddress: signupFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : signupFormattedAddress,
            updateSource: signupLocationUpdateSource,
            locationRevision: signupLocationRevision,
            addressNeedsConfirmation: signupAddressNeedsConfirmation
        )
    }

#if DEBUG
    /// Why `registrationFormComplete` is false (does not duplicate password-in-email checks beyond `emailOk`).
    private func signupFormIncompleteReasons() -> [String] {
        if let m = businessSignupMissingRequirementMessage { return [m] }
        return []
    }

    private func logSignupSubmitGates(reason: String) {
        print(
            "[BusinessSignup] gateCheck reason=\(reason) registerMode=\(showVenueRegisterMode) submitDisabled=\(signupPrimarySubmitDisabled) isSignupSubmitting=\(isSignupSubmitting) policiesAccepted=\(venueSignupPoliciesAccepted) registrationFormComplete=\(registrationFormComplete) incomplete=[\(signupFormIncompleteReasons().joined(separator: ","))] coverPhotoBytes=\(signupCoverData?.count ?? 0) menuPhotoBytes=\(signupMenuData?.count ?? 0)"
        )
    }
#endif

    private var showsBackToBusinessOptions: Bool {
        !isPostVerificationVenueSetup
            && !isApplePendingBusinessSignup
            && (businessAuthEntryMode == .signIn || businessAuthEntryMode == .register)
    }

    var body: some View {
        FGCard {
            if isPostVerificationVenueSetup || isApplePendingBusinessSignup {
                businessSignupWizard
            } else {
                switch businessAuthEntryMode {
                case .choice:
                    businessAuthEntryChoiceContent
                case .signIn:
                    businessOwnerSignInContent
                case .register:
                    businessSignupWizard
                }
            }

            if showsBackToBusinessOptions {
                Button {
                    returnToBusinessAuthChoice()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left")
                            .font(.caption.weight(.bold))
                            .accessibilityHidden(true)
                        Text(L10n.t("business_auth_back_to_options", languageCode: appLanguageRaw))
                            .font(FGTypography.caption.weight(.bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityAddTraits(.isButton)
            }

#if DEBUG
            Group { EmptyView() }
                .onAppear {
                logSignupSubmitGates(reason: "submit_button_onAppear")
            }
            .onChange(of: venueSignupPoliciesAccepted) { _, _ in
                logSignupSubmitGates(reason: "policies_changed")
            }
            .onChange(of: signupCoverData?.count) { _, _ in
                logSignupSubmitGates(reason: "cover_data_changed")
            }
            .onChange(of: isSignupSubmitting) { _, v in
                print("[BusinessSignup] isSignupSubmitting -> \(v)")
            }
            .onChange(of: businessSignupMissingRequirementMessage) { _, new in
                if showVenueRegisterMode, !isSignupSubmitting {
                    if let m = new {
                        print("[BusinessValidation] missing requirement=\(m)")
                    } else {
                        print("[BusinessValidation] submit enabled")
                    }
                }
            }
#endif

            if !viewModel.venueAuthErrorMessage.isEmpty {
                SettingsSheetStatusBanner(
                    title: "Couldn’t continue",
                    message: viewModel.venueAuthErrorMessage,
                    tint: FGColor.dangerRed,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
        }
        .onChange(of: showVenueRegisterMode) { _, isRegister in
            venuePassword = ""
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "accountModeChanged")
            viewModel.venueAuthErrorMessage = ""
            viewModel.venuePasswordResetMessage = ""
            viewModel.venuePasswordResetError = ""
            businessSignupStepMessage = nil
            businessSignupEmailInlineError = nil
            businessSignupPasswordInlineError = nil
            isCheckingBusinessSignupEmail = false
            confirmVenuePassword = ""
            showBusinessSignupPassword = false
            showBusinessSignupConfirmPassword = false
            // Post-verification / Apple-pending flows skip the account step. Never leave
            // `businessSignupStep` on `.account` when that step is not visible — that caused
            // Continue to fall through into venue submission and surface "Location name missing".
            syncBusinessSignupStepToVisibleFlow(reason: "showVenueRegisterModeChanged")
            if isRegister {
                // Registration owns shared email; allow sign-in draft to re-init afterward.
                didInitializeBusinessLoginEmailDraft = false
                businessLoginFocusedField = nil
            }
            if !isRegister {
                venueSignupPoliciesAccepted = false
                signupBusinessName = ""
                signupBusinessHandle = ""
                signupBusinessHandleInlineError = nil
                signupLocationName = ""
                signupStreet = ""
                signupAddressLine2 = ""
                signupCity = ""
                signupState = ""
                signupCountry = BusinessLocationCountryPolicy.defaultCountryCode
                signupZip = ""
                signupLatitude = nil
                signupLongitude = nil
                signupFormattedAddress = ""
                signupPhoneDialISO = BusinessPhoneFields.defaultISO
                signupPhoneLocal = ""
                signupWebsite = ""
                signupDescription = ""
                signupProof = ""
                signupScreenCount = 1
                signupServesFood = false
                signupHasWifi = false
                signupHasGarden = false
                signupHasProjector = false
                signupPetFriendly = false
                signupFamilyFriendly = false
                signupParking = false
                signupEasyParking = false
                signupHandicapParking = false
                signupLiveMusic = false
                signupPoolTables = false
                signupRooftop = false
                signupDJNights = false
                signupKaraoke = false
                signupCocktails = false
                signupCraftBeer = false
                signupCoverPicker = nil
                signupMenuPicker = nil
                signupCoverData = nil
                signupMenuData = nil
            }
        }
        .onAppear {
            applyApplePendingBusinessSignupState()
            if isApplePendingBusinessSignup || isPostVerificationVenueSetup {
                showVenueRegisterMode = true
                businessAuthEntryMode = .register
            }
            syncBusinessSignupStepToVisibleFlow(reason: "cardOnAppear")
#if DEBUG
            logBusinessSignupFlowSnapshot(source: "cardOnAppear")
#endif
        }
        .onChange(of: viewModel.businessEmailVerifiedNeedsVenueSetup) { _, needsSetup in
            if needsSetup {
                showVenueRegisterMode = true
                businessAuthEntryMode = .register
                businessSignupStepMessage = nil
                syncBusinessSignupStepToVisibleFlow(reason: "postVerificationBecameActive")
            }
#if DEBUG
            logBusinessSignupFlowSnapshot(source: "postVerificationChanged")
#endif
        }
        .onChange(of: viewModel.applePendingBusinessSignupEmail) { _, _ in
            applyApplePendingBusinessSignupState()
            if isApplePendingBusinessSignup {
                showVenueRegisterMode = true
                businessAuthEntryMode = .register
            }
        }
        .onChange(of: viewModel.applePendingBusinessSignupDisplayName) { _, _ in
            applyApplePendingBusinessSignupState()
        }
        .onChange(of: viewModel.venueOwnerEmail) { _, _ in
            // Registration still binds shared email. Sign-in typing uses local draft and
            // only publishes on commit (submit / forgot password / intentional preserve).
            viewModel.clearResumePendingBusinessSetupIfLoginEmailChanged()
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailEdited")
        }
        .onChange(of: businessLoginEmailDraft) { _, _ in
            guard businessAuthEntryMode == .signIn else { return }
            // Local-only: clear Apple banner without publishing venueOwnerEmail.
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailEdited")
        }
        .onChange(of: venuePassword) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "passwordEdited")
            if businessSignupStep == .account {
                businessSignupPasswordInlineError = nil
                businessSignupStepMessage = nil
            }
        }
        .onChange(of: confirmVenuePassword) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "passwordEdited")
            if businessSignupStep == .account {
                businessSignupPasswordInlineError = nil
                businessSignupStepMessage = nil
            }
        }
        .onDisappear {
            // Real sheet teardown (or card removal). Preserve typed email into the model once.
            commitBusinessLoginEmailDraftIfNeeded()
            businessLoginFocusedField = nil
            didInitializeBusinessLoginEmailDraft = false
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "sheetClosed")
#if DEBUG
            print("[BusinessLoginFocusDebug] cardDisappear formId=\(businessLoginFormInstanceId.uuidString)")
#endif
        }
#if DEBUG
        .onAppear {
            print("[BusinessLoginFocusDebug] cardAppear formId=\(businessLoginFormInstanceId.uuidString)")
        }
        .onChange(of: businessLoginFocusedField) { _, newValue in
            print("[BusinessLoginFocusDebug] focusChanged field=\(String(describing: newValue)) formId=\(businessLoginFormInstanceId.uuidString)")
        }
#endif
        .onChange(of: signupCountry) { _, newCountry in
            BusinessLocationCountryPolicy.clearDefaultRegionIfNeeded(&signupState, whenCountryChangesTo: newCountry)
#if DEBUG
            print("[InternationalAddressDebug] selectedCountry=\(BusinessLocationCountryPolicy.normalizedStoredCountryCode(newCountry))")
#endif
        }
        .sheet(isPresented: $showSignupPinPicker) {
            BusinessVenueLocationPinPickerView(
                viewModel: viewModel,
                initialDraft: signupLocationDraft,
                fallbackCoordinate: viewModel.currentUserLocation ?? CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
                onCancel: {},
                onConfirm: applySignupLocationDraft
            )
        }
        .onChange(of: signupCoverPicker) { _, item in
            Task {
                guard let item else { return }
                if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
                    await MainActor.run {
                        signupCoverData = data
                        signupCoverPicker = nil
                    }
                }
            }
        }
        .onChange(of: signupMenuPicker) { _, item in
            Task {
                guard let item else { return }
                if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
                    await MainActor.run {
                        signupMenuData = data
                        signupMenuPicker = nil
                    }
                } else {
                    await MainActor.run { signupMenuPicker = nil }
                }
            }
        }
        .sheet(item: $venueSignupLegalDocument) { document in
            SettingsLegalDocumentSheet(document: document)
        }
        .sheet(isPresented: $showBusinessPasswordResetSheet) {
            SettingsBusinessPasswordResetSheet(
                viewModel: viewModel,
                isPresented: $showBusinessPasswordResetSheet
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
    }

    private var businessAuthEntryChoiceContent: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("business_auth_choose_how_to_continue", languageCode: appLanguageRaw))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(L10n.t("business_auth_choose_how_to_continue_subtitle", languageCode: appLanguageRaw))
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            FGPrimaryButton(
                title: L10n.t("business_auth_sign_in", languageCode: appLanguageRaw),
                systemImage: "person.fill",
                isDisabled: !authTermsAccepted
            ) {
                businessAuthEntryMode = .signIn
                showVenueRegisterMode = false
            }

            FGSecondaryButton(
                title: L10n.t("business_auth_create_business_account", languageCode: appLanguageRaw),
                systemImage: "building.2.crop.circle",
                isDisabled: !authTermsAccepted
            ) {
                businessAuthEntryMode = .register
                showVenueRegisterMode = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func returnToBusinessAuthChoice() {
        businessLoginFocusedField = nil
        commitBusinessLoginEmailDraftIfNeeded()
        businessAuthEntryMode = .choice
        showVenueRegisterMode = false
        viewModel.venueAuthErrorMessage = ""
        viewModel.clearAppleAuthMessage(accountMode: .business, reason: "accountModeChanged")
#if DEBUG
        print("[BusinessLoginFocusDebug] returnToOptions formId=\(businessLoginFormInstanceId.uuidString)")
#endif
    }

    private func initializeBusinessLoginEmailDraftIfNeeded() {
        guard !didInitializeBusinessLoginEmailDraft else { return }
        businessLoginEmailDraft = viewModel.venueOwnerEmail
        didInitializeBusinessLoginEmailDraft = true
#if DEBUG
        print(
            "[BusinessLoginFocusDebug] loginDraftInitialized formId=\(businessLoginFormInstanceId.uuidString) hasPrefill=\(!viewModel.venueOwnerEmail.isEmpty)"
        )
#endif
    }

    private func commitBusinessLoginEmailDraftIfNeeded() {
        guard didInitializeBusinessLoginEmailDraft || !businessLoginEmailDraft.isEmpty else { return }
        let next = businessLoginEmailDraft
        guard next != viewModel.venueOwnerEmail else { return }
        viewModel.venueOwnerEmail = next
    }

    private func toggleBusinessLoginPasswordVisibilitySafely() {
        let wasPasswordFocused = businessLoginFocusedField == .password
#if DEBUG
        print(
            "[BusinessLoginFocusDebug] passwordVisibilityToggle begin wasFocused=\(wasPasswordFocused) visible=\(showBusinessLoginPassword) formId=\(businessLoginFormInstanceId.uuidString)"
        )
#endif
        businessLoginFocusedField = nil
        DispatchQueue.main.async {
            showBusinessLoginPassword.toggle()
#if DEBUG
            print(
                "[BusinessLoginFocusDebug] passwordVisibilityToggle swapped visible=\(showBusinessLoginPassword)"
            )
#endif
            DispatchQueue.main.async {
                if wasPasswordFocused {
                    businessLoginFocusedField = .password
                }
#if DEBUG
                print(
                    "[BusinessLoginFocusDebug] passwordVisibilityToggle restoreFocus=\(wasPasswordFocused)"
                )
#endif
            }
        }
    }

    private var businessOwnerSignInContent: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            FGSectionHeader(
                "Grow your sports crowd",
                subtitle: "Manage your venues, host watch parties, and bring local fans to your business."
            ) {
                FGStatusPill(title: "Owner tools", kind: .custom(tint: FGColor.accentBlue))
            }

            FanGeoAppleSignInButton(
                viewModel: viewModel,
                accountMode: .business,
                isEnabled: authTermsAccepted
            )
            appleBusinessMessageBanner

            if !isApplePendingBusinessSignup {
                TextField("Business email", text: $businessLoginEmailDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .focused($businessLoginFocusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { businessLoginFocusedField = .password }
                    .fanGeoInputFieldStyle()

                businessLoginPasswordField

                Button {
#if DEBUG
                    print("[BusinessPasswordResetDebug] forgotPasswordTapped=true")
                    print("[BusinessLoginFocusDebug] forgotPassword formId=\(businessLoginFormInstanceId.uuidString)")
#endif
                    businessLoginFocusedField = nil
                    commitBusinessLoginEmailDraftIfNeeded()
                    guard viewModel.canPresentPasswordResetRequestSheet() else {
                        showBusinessPasswordResetSheet = false
                        return
                    }
                    viewModel.venuePasswordResetMessage = ""
                    viewModel.venuePasswordResetError = ""
                    showBusinessPasswordResetSheet = true
                } label: {
                    Text("Forgot password?")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)

                FGPrimaryButton(
                    title: viewModel.isSafeLoginInFlight
                        ? L10n.t("login_logging_you_in", languageCode: appLanguageRaw)
                        : "Sign In as Business Owner",
                    isDisabled: !authTermsAccepted || viewModel.isSafeLoginInFlight
                ) {
                    submitBusinessLogin()
                }
            }
        }
        .onAppear {
            initializeBusinessLoginEmailDraftIfNeeded()
#if DEBUG
            print("[BusinessLoginFocusDebug] signInContentAppear formId=\(businessLoginFormInstanceId.uuidString)")
#endif
        }
        .onDisappear {
            // Mode switch (choice/register) — clear focus only; do not treat as sheet dismissal.
            businessLoginFocusedField = nil
#if DEBUG
            print("[BusinessLoginFocusDebug] signInContentDisappear formId=\(businessLoginFormInstanceId.uuidString)")
#endif
        }
    }

    private func submitBusinessLogin() {
#if DEBUG
        print("[BusinessLoginFocusDebug] signInSubmit formId=\(businessLoginFormInstanceId.uuidString)")
#endif
        guard !viewModel.isSafeLoginInFlight else {
            SafeLoginDebug.log("duplicate login ignored source=SettingsVenueOwnerCard")
            return
        }
        businessLoginFocusedField = nil
        commitBusinessLoginEmailDraftIfNeeded()
        viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailPasswordSignIn")
        viewModel.submitBusinessEmailLogin(
            email: viewModel.venueOwnerEmail,
            password: venuePassword,
            source: "SettingsVenueOwnerCard"
        )
    }

    private var businessLoginPasswordField: some View {
        HStack(spacing: 10) {
            Group {
                if showBusinessLoginPassword {
                    TextField("Business owner password", text: $venuePassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .font(FGTypography.body)
                } else {
                    SecureField("Business owner password", text: $venuePassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .font(FGTypography.body)
                }
            }
            .focused($businessLoginFocusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { submitBusinessLogin() }
            // Stable container identity — do not key on visibility or credentials.
            .id("businessLoginPasswordInput")

            Button {
                toggleBusinessLoginPasswordVisibilitySafely()
            } label: {
                Image(systemName: showBusinessLoginPassword ? "eye.slash" : "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showBusinessLoginPassword ? "Hide password" : "Show password")
        }
        .fanGeoInputFieldStyle()
    }

    private var businessSignupWizard: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            businessSignupProgressHeader

            wizardStepCard {
                switch businessSignupStep {
                case .account:
                    businessSignupAccountStep
                case .venue:
                    businessSignupVenueStep
                case .experience:
                    businessSignupExperienceStep
                case .review:
                    businessSignupReviewStep
                }
            }

            if let businessSignupStepMessage {
                SettingsSheetStatusBanner(
                    title: nil,
                    message: businessSignupStepMessage,
                    tint: FGColor.accentYellow,
                    systemImage: "info.circle"
                )
            }

            businessSignupNavigation
        }
        .onAppear {
            applyBusinessSignupDefaultsFromEmail()
            restorePendingBusinessSignupDraftIntoFormIfNeeded()
            syncBusinessSignupStepToVisibleFlow(reason: "wizardOnAppear")
#if DEBUG
            logBusinessSignupFlowSnapshot(source: "wizardOnAppear")
#endif
        }
    }

    private var businessSignupProgressHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let stepIndex = businessSignupVisibleSteps.firstIndex(of: businessSignupStep) {
                    Text("Step \(stepIndex + 1) of \(businessSignupVisibleSteps.count)")
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                Spacer(minLength: 0)
                FGStatusPill(title: "Review required", kind: .custom(tint: FGColor.accentYellow))
            }

            HStack(spacing: 7) {
                ForEach(Array(businessSignupVisibleSteps.enumerated()), id: \.offset) { index, step in
                    Capsule(style: .continuous)
                        .fill(
                            (businessSignupVisibleSteps.firstIndex(of: businessSignupStep) ?? 0) >= index
                                ? AnyShapeStyle(FGColor.brandGradient)
                                : AnyShapeStyle(FGColor.divider(colorScheme).opacity(0.9))
                        )
                        .frame(height: 4)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(businessSignupHeaderTitle)
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(businessSignupHeaderSubtitle)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var businessSignupHeaderTitle: String {
        switch businessSignupStep {
        case .account:
            return L10n.t("business_create_account_title", languageCode: appLanguageRaw)
        case .venue, .experience, .review:
            return businessSignupStep.title
        }
    }

    private var businessSignupHeaderSubtitle: String {
        switch businessSignupStep {
        case .account:
            return L10n.t("business_create_account_subtitle", languageCode: appLanguageRaw)
        case .venue, .experience, .review:
            return businessSignupStep.subtitle
        }
    }

    private func wizardStepCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            content()
        }
        .padding(FGSpacing.md)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.97))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var businessSignupAccountStep: some View {
        FanGeoAppleSignInButton(
            viewModel: viewModel,
            accountMode: .business,
            entryPoint: .businessSignup,
            isEnabled: authTermsAccepted
        )
        appleBusinessMessageBanner

        if isApplePendingBusinessSignup {
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
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        } else {
            businessSignupOrContinueWithEmailDivider

            businessSignupAccountDetailsGroup
        }

        businessSignupBusinessIdentityGroup

        // TODO: Optional business logo may be added here after storage/persistence support exists.
    }

    private var businessSignupOrContinueWithEmailDivider: some View {
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

    private var businessSignupAccountDetailsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            businessSignupSectionHeader(
                systemImage: "envelope.fill",
                title: L10n.t("business_signup_account_details_title", languageCode: appLanguageRaw)
            )

            VStack(spacing: 13) {
                TextField("Business email", text: $viewModel.venueOwnerEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .fanGeoInputFieldStyle()
                    .onChange(of: viewModel.venueOwnerEmail) { _, _ in
                        businessSignupEmailInlineError = nil
                        if businessSignupStep == .account {
                            businessSignupStepMessage = nil
                        }
                    }

                if let businessSignupEmailInlineError {
                    Text(businessSignupEmailInlineError)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.dangerRed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                businessSignupPasswordField(
                    placeholder: "Business owner password",
                    text: $venuePassword,
                    isVisible: $showBusinessSignupPassword
                )
                businessSignupPasswordField(
                    placeholder: "Confirm business owner password",
                    text: $confirmVenuePassword,
                    isVisible: $showBusinessSignupConfirmPassword
                )
                if let businessSignupPasswordInlineError {
                    Text(businessSignupPasswordInlineError)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.dangerRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var businessSignupBusinessIdentityGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            businessSignupSectionHeader(
                systemImage: "building.2.fill",
                title: L10n.t("business_signup_business_identity_title", languageCode: appLanguageRaw)
            )

            VStack(spacing: 13) {
                TextField("Business / brand name", text: $signupBusinessName)
                    .textInputAutocapitalization(.words)
                    .fanGeoInputFieldStyle()
                    .onChange(of: viewModel.venueOwnerEmail) { _, _ in
                        applyBusinessSignupDefaultsFromEmail()
                    }

                businessSignupHandleField
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func businessSignupSectionHeader(systemImage: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(FGColor.accentBlue)
                .accessibilityHidden(true)
            Text(title)
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var businessSignupHandleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Business @handle")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            HStack(spacing: 6) {
                Text("@")
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                TextField("pizzahut", text: $signupBusinessHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .fanGeoInputFieldStyle()
                    .onChange(of: signupBusinessHandle) { _, newValue in
                        let normalized = FanGeoHandleRules.normalizeForStorage(newValue)
                        if normalized != newValue {
                            signupBusinessHandle = normalized
                        }
                        signupBusinessHandleInlineError = nil
                    }
            }

            Text("Fans can find your business by this handle.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            if let signupBusinessHandleInlineError {
                Text(signupBusinessHandleInlineError)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var businessSignupVenueStep: some View {
        TextField("Location name", text: $signupLocationName)
            .textInputAutocapitalization(.words)
            .fanGeoInputFieldStyle()

        signupAddressFields

        BusinessPhoneNumberField(dialISO: $signupPhoneDialISO, localNumber: $signupPhoneLocal)

        TextField("Website (optional)", text: $signupWebsite)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .fanGeoInputFieldStyle()
    }

    private var businessSignupExperienceStep: some View {
        AddLocationVenueFeaturesGrid(
            screenCount: $signupScreenCount,
            servesFood: $signupServesFood,
            hasWifi: $signupHasWifi,
            hasGarden: $signupHasGarden,
            hasProjector: $signupHasProjector,
            petFriendly: $signupPetFriendly,
            parkingAvailable: $signupParking,
            easyParking: $signupEasyParking,
            familyFriendly: $signupFamilyFriendly,
            handicapParking: $signupHandicapParking,
            liveMusic: $signupLiveMusic,
            poolTables: $signupPoolTables,
            rooftop: $signupRooftop,
            djNights: $signupDJNights,
            karaoke: $signupKaraoke,
            cocktails: $signupCocktails,
            craftBeer: $signupCraftBeer,
            maxScreenCount: 40
        )
    }

    @ViewBuilder
    private var businessSignupReviewStep: some View {
        VenueOwnerListingPhotoPickerCard(
            title: "Business Photo",
            subtitle: "Main photo of your business",
            pickerSelection: $signupCoverPicker,
            remotePreviewURL: "",
            localPreviewData: signupCoverData,
            usesFanGeoSheetChrome: true
        )

        VenueOwnerListingPhotoPickerCard(
            title: "Others",
            subtitle: "Examples: menu, gym, patio, bar, seating, entrance",
            pickerSelection: $signupMenuPicker,
            remotePreviewURL: "",
            localPreviewData: signupMenuData,
            usesFanGeoSheetChrome: true
        )

        TextField("Description", text: $signupDescription, axis: .vertical)
            .lineLimit(3...8)
            .fanGeoInputFieldStyle()

        TextField("Proof note (how you operate this location)", text: $signupProof, axis: .vertical)
            .lineLimit(2...6)
            .fanGeoInputFieldStyle()

        signupPolicyAgreement
    }

    private var appleBusinessMessageBanner: some View {
        Group {
            if !viewModel.appleAuthBusinessMessage.isEmpty {
                SettingsSheetStatusBanner(
                    title: viewModel.appleAuthBusinessMessageIsError ? "Apple Sign In" : nil,
                    message: viewModel.appleAuthBusinessMessage,
                    tint: viewModel.appleAuthBusinessMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                    systemImage: viewModel.appleAuthBusinessMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                )
            }
        }
    }

    private func businessSignupPasswordField(
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

    private var businessSignupNavigation: some View {
        VStack(spacing: FGSpacing.sm) {
            HStack(spacing: FGSpacing.sm) {
                if businessSignupStep != businessSignupVisibleSteps.first {
                    Button {
                        guard let currentIndex = businessSignupVisibleSteps.firstIndex(of: businessSignupStep),
                              currentIndex > businessSignupVisibleSteps.startIndex else { return }
                        let previous = businessSignupVisibleSteps[businessSignupVisibleSteps.index(before: currentIndex)]
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            businessSignupStep = previous
                            businessSignupStepMessage = nil
                        }
                    } label: {
                        Text("Back")
                            .font(FGTypography.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(FGAdaptiveSurface.controlFill)
                            .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSignupSubmitting)
                }

                FGPrimaryButton(
                    title: businessSignupPrimaryTitle,
                    isDisabled: signupPrimarySubmitDisabled || isCheckingBusinessSignupEmail
                ) {
                    Task { await advanceBusinessSignupWizard() }
                }
            }

            if businessSignupStep == .review, !isSignupSubmitting, let hint = businessSignupMissingRequirementMessage {
                Text(hint)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isPostVerificationVenueSetup {
                Button {
                    Task {
                        await viewModel.deferBusinessVenueSetupUntilLater()
                        showVenueRegisterMode = false
                        businessAuthEntryMode = .signIn
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left")
                            .font(.caption.weight(.bold))
                        Text("Back to Sign In")
                            .font(FGTypography.caption.weight(.bold))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSignupSubmitting)
            }
        }
    }

    @MainActor
    private func applyBusinessSignupDefaultsFromEmail() {
        let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(email) else { return }
        if signupBusinessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signupBusinessName = BusinessProfileDefaults.defaultDisplayName(email: email)
        }
        if signupBusinessHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signupBusinessHandle = BusinessProfileDefaults.defaultHandle(email: email)
        }
    }

    @MainActor
    private func applyApplePendingBusinessSignupState() {
        guard isApplePendingBusinessSignup else { return }
        let normalizedEmail = OwnerBusinessEmail.normalized(viewModel.applePendingBusinessSignupEmail)
        if !normalizedEmail.isEmpty {
            viewModel.venueOwnerEmail = normalizedEmail
        }
        venuePassword = ""
        confirmVenuePassword = ""
        businessSignupEmailInlineError = nil
        businessSignupPasswordInlineError = nil
        let appleBusinessName = viewModel.applePendingBusinessSignupDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if signupBusinessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !appleBusinessName.isEmpty {
            signupBusinessName = appleBusinessName
        }
        applyBusinessSignupDefaultsFromEmail()
    }

    /// Keeps the wizard step inside the currently visible flow (account-only vs venue setup).
    @MainActor
    private func syncBusinessSignupStepToVisibleFlow(reason: String) {
        let visible = businessSignupVisibleSteps
        guard !visible.isEmpty else {
            if businessSignupStep != .account {
#if DEBUG
                print("[BusinessSignupFlow] stepSync reason=\(reason) visible=[] forcing=.account")
#endif
                businessSignupStep = .account
            }
            return
        }
        guard !visible.contains(businessSignupStep) else { return }
        let target = visible[0]
#if DEBUG
        print(
            "[BusinessSignupFlow] stepSync reason=\(reason) from=\(businessSignupStep.rawValue) to=\(target.rawValue) visible=\(visible.map(\.rawValue))"
        )
#endif
        businessSignupStep = target
        businessSignupStepMessage = nil
    }

#if DEBUG
    private func logBusinessSignupFlowSnapshot(source: String) {
        let draft = viewModel.pendingBusinessEmailSignupDraft
        let locName = draft?.signup.firstLocation.venueName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print(
            "[BusinessSignupFlow] source=\(source) step=\(businessSignupStep.rawValue) visible=\(businessSignupVisibleSteps.map(\.rawValue)) postVerification=\(isPostVerificationVenueSetup) applePending=\(isApplePendingBusinessSignup) registerMode=\(showVenueRegisterMode) entryMode=\(String(describing: businessAuthEntryMode)) authUserId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil") emailVerifiedDraft=\(draft?.emailVerified == true) businessName=\(signupBusinessName) handle=\(FanGeoHandleRules.normalizeForStorage(signupBusinessHandle)) venueDraftPresent=\(draft != nil) venueNameEmpty=\(locName.isEmpty) stepMessage=\(businessSignupStepMessage ?? "nil") authError=\(viewModel.venueAuthErrorMessage.isEmpty ? "nil" : "set")"
        )
    }
#endif

    @MainActor
    private func advanceBusinessSignupWizard() async {
        guard !isCheckingBusinessSignupEmail, !isCheckingBusinessSignupHandle else { return }
        businessSignupStepMessage = nil
        syncBusinessSignupStepToVisibleFlow(reason: "advanceBeforeValidate")
#if DEBUG
        logBusinessSignupFlowSnapshot(source: "advanceContinue")
#endif
        if businessSignupStep == .account {
            businessSignupEmailInlineError = nil
        }
        guard validateBusinessSignupStep(businessSignupStep) else {
#if DEBUG
            print(
                "[BusinessSignupFlow] validationRejected step=\(businessSignupStep.rawValue) message=\(businessSignupStepMessage ?? "nil")"
            )
#endif
            return
        }
        if businessSignupStep == .account {
            let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
            isCheckingBusinessSignupEmail = true
            let conflictMessage = await viewModel.businessSignupStep1EmailConflictMessage(for: email)
            isCheckingBusinessSignupEmail = false
            guard OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail) == email else {
                businessSignupEmailInlineError = nil
                businessSignupStepMessage = nil
                return
            }
            if let conflictMessage {
                businessSignupEmailInlineError = conflictMessage
                return
            }

            applyBusinessSignupDefaultsFromEmail()
            signupBusinessHandleInlineError = nil
            if let handleError = BusinessIdentityValidation.validateBusinessHandle(signupBusinessHandle) {
                signupBusinessHandleInlineError = handleError
                return
            }
            isCheckingBusinessSignupHandle = true
            let handle = FanGeoHandleRules.normalizeForStorage(signupBusinessHandle)
            let handleAvailable = await viewModel.checkBusinessHandleAvailableForSignup(handle)
            isCheckingBusinessSignupHandle = false
            guard let handleAvailable else {
                signupBusinessHandleInlineError = "Unable to verify handle availability. Try again."
                return
            }
            guard handleAvailable else {
                signupBusinessHandleInlineError = "This business handle is already taken."
                return
            }
        }
        if businessSignupVisibleSteps == [.account] {
#if DEBUG
            print("[BusinessSignupFlow] transitionAccepted next=submitBusinessAccountOnly")
#endif
            await submitBusinessAccountOnly()
            return
        }
        if let currentIndex = businessSignupVisibleSteps.firstIndex(of: businessSignupStep),
           businessSignupVisibleSteps.index(after: currentIndex) < businessSignupVisibleSteps.endIndex {
            let next = businessSignupVisibleSteps[businessSignupVisibleSteps.index(after: currentIndex)]
#if DEBUG
            print(
                "[BusinessSignupFlow] transitionAccepted from=\(businessSignupStep.rawValue) to=\(next.rawValue)"
            )
#endif
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                businessSignupStep = next
                businessSignupStepMessage = nil
            }
            return
        }
        // Only the final visible step may submit venue review. Never fall through from `.account`.
        guard businessSignupStep == .review || businessSignupStep == businessSignupVisibleSteps.last else {
#if DEBUG
            print(
                "[BusinessSignupFlow] transitionRejected submitBlocked step=\(businessSignupStep.rawValue) visible=\(businessSignupVisibleSteps.map(\.rawValue))"
            )
            assertionFailure("[BusinessSignupFlow] Continue reached submit without review/last visible step")
#endif
            syncBusinessSignupStepToVisibleFlow(reason: "submitBlockedResync")
            return
        }
#if DEBUG
        print("[BusinessSignupFlow] transitionAccepted next=submitBusinessSignup reviewStep=true")
#endif
        await submitBusinessSignup()
    }

    @MainActor
    private func submitBusinessAccountOnly() async {
        guard businessSignupAccountOnlyMissingRequirementMessage == nil else {
            businessSignupStepMessage = businessSignupAccountOnlyMissingRequirementMessage
            return
        }

        viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailPasswordSignUp")
        isSignupSubmitting = true
        defer { isSignupSubmitting = false }

        await viewModel.registerBusinessAccountOnly(
            email: viewModel.venueOwnerEmail,
            password: venuePassword,
            businessDisplayName: signupBusinessName,
            businessHandle: signupBusinessHandle
        )

        if viewModel.shouldShowPendingBusinessEmailVerificationUI {
            showVenueRegisterMode = false
            businessAuthEntryMode = .signIn
            return
        }
        if viewModel.businessEmailVerifiedNeedsVenueSetup {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                businessSignupStep = .venue
            }
        }
    }

    @MainActor
    private func restorePendingBusinessSignupDraftIntoFormIfNeeded() {
        guard let draft = viewModel.pendingBusinessEmailSignupDraft else { return }
        let shouldRestoreForm =
            viewModel.businessEmailVerifiedNeedsVenueSetup
            || viewModel.resumePendingBusinessSetupForDraftEmail
            || (viewModel.hasPendingVerifiedBusinessVenueSetup && viewModel.pendingBusinessDraftMatchesTypedLoginEmail)
        guard shouldRestoreForm else { return }

        if signupBusinessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signupBusinessName = draft.signup.businessDisplayName
        }
        if signupBusinessHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signupBusinessHandle = draft.signup.businessHandle
        }
        if viewModel.businessEmailVerifiedNeedsVenueSetup || viewModel.resumePendingBusinessSetupForDraftEmail,
           viewModel.venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.venueOwnerEmail = draft.email
        }

        let loc = draft.signup.firstLocation
        if signupLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !loc.venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signupLocationName = loc.venueName
            signupStreet = loc.address
            signupAddressLine2 = loc.addressLine2
            signupCity = loc.city
            signupState = loc.state
            signupCountry = loc.country
            signupZip = loc.zip
            signupPhoneDialISO = BusinessPhoneFields.defaultISO
            signupPhoneLocal = loc.phone
            signupWebsite = loc.website
            signupDescription = loc.description
            signupProof = loc.proofNote
            signupScreenCount = loc.screenCount
            signupServesFood = loc.servesFood
            signupHasWifi = loc.hasWifi
            signupHasGarden = loc.hasGarden
            signupHasProjector = loc.hasProjector
            signupPetFriendly = loc.petFriendly
            signupFamilyFriendly = loc.familyFriendly
            signupParking = loc.parkingAvailable
            signupEasyParking = loc.easyParking
            signupHandicapParking = loc.handicapParking
            signupLiveMusic = loc.liveMusic
            signupPoolTables = loc.poolTables
            signupRooftop = loc.rooftop
            signupDJNights = loc.djNights
            signupKaraoke = loc.karaoke
            signupCocktails = loc.cocktails
            signupCraftBeer = loc.craftBeer
            signupLatitude = loc.latitude
            signupLongitude = loc.longitude
            signupFormattedAddress = loc.formattedAddress ?? ""
        }
        if signupCoverData == nil {
            signupCoverData = draft.coverPhotoJPEGData
        }
        if signupMenuData == nil {
            signupMenuData = draft.menuPhotoJPEGData
        }
        if draft.recordVenueGuidelinesAcceptance {
            venueSignupPoliciesAccepted = true
        }
    }

    @MainActor
    private func validateBusinessSignupStep(_ step: BusinessSignupStep) -> Bool {
        func block(_ message: String) -> Bool {
            businessSignupStepMessage = message
#if DEBUG
            print("[BusinessSignupFlow] validationFailure step=\(step.rawValue) key=\(message)")
            if step == .account, message == "Location name missing" {
                assertionFailure("[BusinessSignupFlow] account step must not require location name")
            }
            if !businessSignupVisibleSteps.contains(step) {
                assertionFailure("[BusinessSignupFlow] validating step not in visible flow")
            }
#endif
            return false
        }

        switch step {
        case .account:
            guard authTermsAccepted else {
                return block("Accept the Terms of Use and Community Guidelines to continue.")
            }
            if !isApplePendingBusinessSignup {
                let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
                guard OwnerBusinessEmail.isValidStrict(email) else {
                    return block(email.isEmpty ? "Business email missing" : OwnerBusinessEmail.invalidOwnerEmailUserMessage)
                }
                businessSignupPasswordInlineError = nil
                guard !venuePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    businessSignupPasswordInlineError = "Password missing"
                    return block("Password missing")
                }
                guard !confirmVenuePassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    businessSignupPasswordInlineError = "Confirm password missing"
                    return block("Confirm password missing")
                }
                guard venuePassword == confirmVenuePassword else {
                    businessSignupPasswordInlineError = "Passwords do not match."
                    return block("Passwords do not match.")
                }
            }
            guard !signupBusinessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return block("Business name missing")
            }
            if let nameError = BusinessIdentityValidation.validateBusinessName(signupBusinessName) {
                return block(nameError)
            }
            guard !signupBusinessHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return block("Business handle missing")
            }
            if let handleError = BusinessIdentityValidation.validateBusinessHandle(signupBusinessHandle) {
                return block(handleError)
            }
            return true
        case .venue:
#if DEBUG
            if isPostVerificationVenueSetup || isApplePendingBusinessSignup {
                assert(businessSignupVisibleSteps.contains(.venue), "[BusinessSignupFlow] venue validation without visible venue step")
            }
#endif
            guard !signupLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return block("Location name missing")
            }
            if signupAddressNeedsConfirmation,
               signupLocationUpdateSource == .adjustedPin || signupLocationUpdateSource == .currentLocation {
                return block(L10n.t("Confirm the address for the selected venue pin", languageCode: appLanguageRaw))
            }
            guard !signupStreet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return block("Address line 1 missing")
            }
            if let lat = signupLatitude, let lon = signupLongitude,
               CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)),
               signupLocationUpdateSource == .adjustedPin,
               signupStreet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return block(L10n.t("Confirm the address for the selected venue pin", languageCode: appLanguageRaw))
            }
            let normalizedCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(signupCountry)
            let labels = BusinessLocationCountryPolicy.labels(for: normalizedCountry)
            guard BusinessLocationCountryPolicy.supportedCountryCodes.contains(normalizedCountry) else {
                return block("Country missing")
            }
            if labels.localityRequired, signupCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return block("\(labels.locality) missing")
            }
            if labels.regionRequired, signupState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return block("\(labels.region) missing")
            }
            let phone = BusinessPhoneFields.combinedStorage(iso: signupPhoneDialISO, local: signupPhoneLocal)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if BusinessPhoneFields.storageValidationError(combined: phone) != nil {
                return block(BusinessPhoneFields.storageValidationError(iso: signupPhoneDialISO, local: signupPhoneLocal) ?? "Phone number missing")
            }
            return true
        case .experience:
            return true
        case .review:
            guard !signupDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return block("Description missing")
            }
            guard !signupProof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return block("Proof note missing")
            }
            guard signupCoverData.map({ !$0.isEmpty }) == true else {
                return block("Business photo missing")
            }
            guard venueSignupPoliciesAccepted else {
                return block("Agree to the Terms of Service, Privacy Policy, and Community Guidelines")
            }
            return true
        }
    }

    @MainActor
    private func submitBusinessSignup() async {
#if DEBUG
        print("[BusinessSignup] button tapped primaryAction registerMode=true")
        logSignupSubmitGates(reason: "immediate_after_tap")
        logSignupSubmitGates(reason: "register_branch_before_flags")
#endif
        guard businessSignupMissingRequirementMessage == nil else {
#if DEBUG
            print(
                "[BusinessSignupFlow] submitBlocked missingRequirement=\(businessSignupMissingRequirementMessage ?? "nil") step=\(businessSignupStep.rawValue)"
            )
#endif
            businessSignupStepMessage = businessSignupMissingRequirementMessage
            return
        }

        viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailPasswordSignUp")
        isSignupSubmitting = true
#if DEBUG
        print("[BusinessSignup] set isSignupSubmitting=true")
#endif
        let form = AddLocationClaimForm(
            venueName: signupLocationName,
            address: signupStreet,
            addressLine2: signupAddressLine2,
            city: signupCity,
            state: signupState,
            country: signupCountry,
            zip: signupZip,
            phone: BusinessPhoneFields.combinedStorage(iso: signupPhoneDialISO, local: signupPhoneLocal)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            website: signupWebsite,
            description: signupDescription,
            proofNote: signupProof,
            screenCount: signupScreenCount,
            servesFood: signupServesFood,
            hasWifi: signupHasWifi,
            hasGarden: signupHasGarden,
            hasProjector: signupHasProjector,
            petFriendly: signupPetFriendly,
            familyFriendly: signupFamilyFriendly,
            parkingAvailable: signupParking,
            easyParking: signupEasyParking,
            handicapParking: signupHandicapParking,
            liveMusic: signupLiveMusic,
            poolTables: signupPoolTables,
            rooftop: signupRooftop,
            djNights: signupDJNights,
            karaoke: signupKaraoke,
            cocktails: signupCocktails,
            craftBeer: signupCraftBeer,
            coverPhotoURL: "",
            menuPhotoURL: "",
            latitude: signupLatitude,
            longitude: signupLongitude,
            formattedAddress: signupFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : signupFormattedAddress
        )
#if DEBUG
        print("[VenueFeatureDebug] selectedFeatures=\(form.mergedVenueFeaturesLine())")
#endif
        let payload = BusinessOwnerSignupPayload(
            businessDisplayName: signupBusinessName,
            businessHandle: signupBusinessHandle,
            firstLocation: form
        )
#if DEBUG
        print("[BusinessSignup] calling registerVenueOwner coverBytes=\(signupCoverData?.count ?? 0) menuBytes=\(signupMenuData?.count ?? 0)")
#endif
        if isApplePendingBusinessSignup {
            await viewModel.completeApplePendingBusinessRegistration(
                signup: payload,
                coverPhotoJPEGData: signupCoverData,
                menuPhotoJPEGData: signupMenuData,
                recordVenueGuidelinesAcceptance: venueSignupPoliciesAccepted
            )
        } else if viewModel.hasPendingBusinessEmailSignupDraft || viewModel.businessEmailVerifiedNeedsVenueSetup {
            await submitPendingBusinessVenueSetup(
                payload: payload,
                coverPhotoJPEGData: signupCoverData,
                menuPhotoJPEGData: signupMenuData,
                recordVenueGuidelinesAcceptance: venueSignupPoliciesAccepted
            )
        } else {
            await viewModel.registerVenueOwner(
                email: viewModel.venueOwnerEmail,
                password: venuePassword,
                signup: payload,
                coverPhotoJPEGData: signupCoverData,
                menuPhotoJPEGData: signupMenuData,
                recordVenueGuidelinesAcceptance: venueSignupPoliciesAccepted
            )
        }
#if DEBUG
        print("[BusinessSignup] registerVenueOwner returned isSignupSubmitting clearing")
#endif
        isSignupSubmitting = false
        venuePassword = ""
        confirmVenuePassword = ""
        businessSignupPasswordInlineError = nil
    }

    @MainActor
    private func submitPendingBusinessVenueSetup(
        payload: BusinessOwnerSignupPayload,
        coverPhotoJPEGData: Data?,
        menuPhotoJPEGData: Data?,
        recordVenueGuidelinesAcceptance: Bool
    ) async {
        let ownerEmail = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        let draft = PendingBusinessEmailSignupDraft(
            email: ownerEmail,
            signup: payload,
            coverPhotoJPEGData: coverPhotoJPEGData,
            menuPhotoJPEGData: menuPhotoJPEGData,
            recordVenueGuidelinesAcceptance: recordVenueGuidelinesAcceptance
        )
        if await viewModel.submitPendingBusinessVenueSetup(draft: draft) == false,
           viewModel.venueAuthErrorMessage.isEmpty {
            businessSignupStepMessage = "Sign in to submit your venue for FanGeo review."
        }
    }

    @ViewBuilder
    private var signupRegistrationFields: some View {
        SettingsSheetSectionLabel(title: "Business")
        TextField("Business / brand name", text: $signupBusinessName)
            .textInputAutocapitalization(.words)
            .fanGeoInputFieldStyle()

        businessSignupHandleField

        SettingsSheetSectionLabel(title: "First location")
        TextField("Location name", text: $signupLocationName)
            .textInputAutocapitalization(.words)
            .fanGeoInputFieldStyle()

        signupAddressFields

        BusinessPhoneNumberField(dialISO: $signupPhoneDialISO, localNumber: $signupPhoneLocal)

        TextField("Website (optional)", text: $signupWebsite)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .fanGeoInputFieldStyle()

        TextField("Description", text: $signupDescription, axis: .vertical)
            .lineLimit(3...8)
            .fanGeoInputFieldStyle()

        TextField("Proof note (how you operate this location)", text: $signupProof, axis: .vertical)
            .lineLimit(2...6)
            .fanGeoInputFieldStyle()

        AddLocationVenueFeaturesGrid(
            screenCount: $signupScreenCount,
            servesFood: $signupServesFood,
            hasWifi: $signupHasWifi,
            hasGarden: $signupHasGarden,
            hasProjector: $signupHasProjector,
            petFriendly: $signupPetFriendly,
            parkingAvailable: $signupParking,
            easyParking: $signupEasyParking,
            familyFriendly: $signupFamilyFriendly,
            handicapParking: $signupHandicapParking,
            liveMusic: $signupLiveMusic,
            poolTables: $signupPoolTables,
            rooftop: $signupRooftop,
            djNights: $signupDJNights,
            karaoke: $signupKaraoke,
            cocktails: $signupCocktails,
            craftBeer: $signupCraftBeer,
            maxScreenCount: 40
        )

        SettingsSheetSectionLabel(title: "Photos", subtitle: "A main business photo is required.")

        VenueOwnerListingPhotoPickerCard(
            title: "Business Photo",
            subtitle: "Main photo of your business",
            pickerSelection: $signupCoverPicker,
            remotePreviewURL: "",
            localPreviewData: signupCoverData,
            usesFanGeoSheetChrome: true
        )

        VenueOwnerListingPhotoPickerCard(
            title: "Others",
            subtitle: "Examples: menu, gym, patio, bar, seating, entrance",
            pickerSelection: $signupMenuPicker,
            remotePreviewURL: "",
            localPreviewData: signupMenuData,
            usesFanGeoSheetChrome: true
        )

        signupPolicyAgreement
    }

    @ViewBuilder
    private var signupAddressFields: some View {
        TextField("Street address", text: $signupStreet)
            .textContentType(.streetAddressLine1)
            .fanGeoInputFieldStyle()
            .onChange(of: signupStreet) { _, _ in noteManualSignupAddressEdit() }

        TextField("Address line 2 (optional)", text: $signupAddressLine2)
            .textContentType(.streetAddressLine2)
            .fanGeoInputFieldStyle()
            .onChange(of: signupAddressLine2) { _, _ in noteManualSignupAddressEdit() }

        TextField(signupAddressLabels.locality, text: $signupCity)
            .textInputAutocapitalization(.words)
            .fanGeoInputFieldStyle()
            .onChange(of: signupCity) { _, _ in noteManualSignupAddressEdit() }

        HStack(alignment: .center, spacing: FGSpacing.md) {
            BusinessLocationRegionField(countryCode: signupCountry, labels: signupAddressLabels, region: $signupState)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField(signupAddressLabels.postalCode, text: $signupZip)
                .textInputAutocapitalization(.never)
                .frame(minWidth: 88, maxWidth: 120, alignment: .leading)
                .onChange(of: signupZip) { _, _ in noteManualSignupAddressEdit() }
        }
        .fanGeoInputFieldStyle()
        .onChange(of: signupState) { _, _ in noteManualSignupAddressEdit() }

        BusinessLocationCountryField(countryCode: $signupCountry)
            .fanGeoInputFieldStyle()
            .onChange(of: signupCountry) { _, _ in noteManualSignupAddressEdit() }

        if signupAddressNeedsConfirmation {
            Text(L10n.t("Confirm the address for this pin", languageCode: appLanguageRaw))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentYellow)
                .fixedSize(horizontal: false, vertical: true)
        }

        BusinessVenueLocationPinPreview(
            draft: signupLocationDraft,
            isLocked: false,
            onAdjust: { showSignupPinPicker = true }
        )
    }

    private var signupPolicyAgreement: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                venueSignupPoliciesAccepted.toggle()
            } label: {
                Image(systemName: venueSignupPoliciesAccepted ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(venueSignupPoliciesAccepted ? FGColor.accentBlue : FGColor.mutedText(colorScheme))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("I agree to the Terms of Service, Privacy Policy, and Community Guidelines.")
            .accessibilityAddTraits(venueSignupPoliciesAccepted ? .isSelected : [])

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Text("I agree to the ")
                    Button {
                        venueSignupLegalDocument = .termsOfService
                    } label: {
                        Text("Terms of Service")
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Text(", ")
                    Button {
                        venueSignupLegalDocument = .privacyPolicy
                    } label: {
                        Text("Privacy Policy")
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Text(", and ")
                    Button {
                        venueSignupLegalDocument = .communityGuidelines
                    } label: {
                        Text("Community Guidelines")
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Text(".")
                }
                .font(.footnote)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .tint(FGColor.accentBlue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(FGSpacing.md)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.97))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func applySignupLocationDraft(_ draft: BusinessVenueLocationDraft) {
        isApplyingSignupLocationDraft = true
        defer { isApplyingSignupLocationDraft = false }
#if DEBUG
        print(
            "[BusinessVenuePinSync] parentApplyBefore street=\(signupStreet) city=\(signupCity) lat=\((signupLatitude.map { String($0) } ?? "nil")) lon=\((signupLongitude.map { String($0) } ?? "nil")) revision=\(signupLocationRevision)"
        )
#endif
        signupStreet = draft.addressLine1
        signupAddressLine2 = draft.addressLine2
        signupCity = draft.locality
        signupState = draft.region
        signupZip = draft.postalCode
        signupCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(draft.countryCode)
        signupLatitude = draft.latitude
        signupLongitude = draft.longitude
        signupFormattedAddress = draft.formattedAddress ?? draft.displayAddress
        signupLocationUpdateSource = draft.updateSource
        signupLocationRevision = draft.locationRevision
        signupAddressNeedsConfirmation = draft.addressNeedsConfirmation
        businessSignupStepMessage = nil
#if DEBUG
        print(
            "[BusinessVenuePinSync] parentApplyAfter street=\(signupStreet) city=\(signupCity) region=\(signupState) postal=\(signupZip) country=\(signupCountry) lat=\((signupLatitude.map { String($0) } ?? "nil")) lon=\((signupLongitude.map { String($0) } ?? "nil")) source=\(signupLocationUpdateSource.rawValue) revision=\(signupLocationRevision) needsConfirmation=\(signupAddressNeedsConfirmation) formatted=\(signupFormattedAddress)"
        )
#endif
    }

    private func noteManualSignupAddressEdit() {
        guard !isApplyingSignupLocationDraft else { return }
        signupLocationUpdateSource = .manualAddress
        signupLocationRevision &+= 1
        if !signupStreet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            signupAddressNeedsConfirmation = false
        }
        signupFormattedAddress = BusinessVenueAddressFormatter.formattedAddress(
            line1: signupStreet,
            line2: signupAddressLine2,
            locality: signupCity,
            region: signupState,
            postalCode: signupZip,
            countryCode: signupCountry
        )
    }
}

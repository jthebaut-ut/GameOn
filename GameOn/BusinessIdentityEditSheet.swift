import SwiftUI

struct BusinessIdentityEditSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let businessId: UUID?
    let initialDisplayName: String
    let initialBusinessHandle: String?
    let suggestedHandlePlaceholder: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var businessName: String
    @State private var businessHandle: String
    /// Baseline after hydration — used for dirty checks and reserved-name grandfathering.
    @State private var seededDisplayName: String
    @State private var seededHandle: String
    @State private var didHydrateIdentity = false
    @State private var nameInlineError: String?
    @State private var handleInlineError: String?
    @State private var banner: String?
    @State private var isSaving = false
    @State private var isCheckingHandleAvailability = false
    @State private var handleAvailabilitySatisfied = true
    /// DEBUG-only: avoid repeating missing-email fallback logs on every body refresh.
    @State private var didLogMissingAccountEmail = false

    init(
        viewModel: MapViewModel,
        businessId: UUID?,
        initialDisplayName: String,
        initialBusinessHandle: String?,
        suggestedHandlePlaceholder: String
    ) {
        self.viewModel = viewModel
        self.businessId = businessId
        self.initialDisplayName = initialDisplayName
        self.initialBusinessHandle = initialBusinessHandle
        self.suggestedHandlePlaceholder = suggestedHandlePlaceholder
        let name = initialDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = initialBusinessHandle.map { FanGeoHandleRules.normalizeForStorage($0) } ?? ""
        _businessName = State(initialValue: name)
        _businessHandle = State(initialValue: handle)
        _seededDisplayName = State(initialValue: name)
        _seededHandle = State(initialValue: handle)
    }

    private var resolvedBusinessId: UUID? {
        businessId ?? viewModel.currentBusinessIdForAddLocation()
    }

    private var normalizedCurrentHandle: String {
        FanGeoHandleRules.normalizeForStorage(businessHandle)
    }

    private var normalizedSeededHandle: String {
        FanGeoHandleRules.normalizeForStorage(seededHandle)
    }

    private var handleAvailabilityTaskKey: String {
        "\(normalizedCurrentHandle)|\(normalizedSeededHandle)|\(resolvedBusinessId?.uuidString ?? "nil")|\(didHydrateIdentity)"
    }

    private var trimmedCurrentName: String {
        businessName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSeededName: String {
        seededDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedCurrentName != trimmedSeededName
            || normalizedCurrentHandle != normalizedSeededHandle
    }

    private var liveNameValidationError: String? {
        guard didHydrateIdentity else { return nil }
        return BusinessIdentityValidation.validateBusinessNameForEdit(
            businessName,
            original: seededDisplayName
        )
    }

    private var liveHandleValidationError: String? {
        guard didHydrateIdentity else { return nil }
        return BusinessIdentityValidation.validateBusinessHandleForEdit(
            businessHandle,
            original: seededHandle
        )
    }

    private var handleUnchangedFromSeeded: Bool {
        normalizedCurrentHandle == normalizedSeededHandle
    }

    private var canSave: Bool {
        guard didHydrateIdentity else { return false }
        guard resolvedBusinessId != nil else { return false }
        guard hasChanges else { return false }
        guard !isSaving, !isCheckingHandleAvailability else { return false }
        guard liveNameValidationError == nil, liveHandleValidationError == nil else { return false }
        return handleAvailabilitySatisfied
    }

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    /// Authenticated business login email. Business sessions store it in `venueOwnerEmail`
    /// (and clear `currentUserEmail`); fan-style sessions keep it on `currentUserEmail`.
    /// Never use venue contact / display name / handle.
    private var authenticatedAccountEmail: String {
        let ownerSessionEmail = viewModel.venueOwnerEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !ownerSessionEmail.isEmpty {
            return ownerSessionEmail
        }
        return viewModel.currentUserEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var accountEmailDisplayValue: String {
        let email = authenticatedAccountEmail
        if email.isEmpty {
            return L10n.t("business_identity_email_unavailable", languageCode: languageCode)
        }
        return email
    }

    private var isAccountEmailUnavailable: Bool {
        authenticatedAccountEmail.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard

                    accountEmailCard
                        .onAppear { logAccountEmailPresentationIfNeeded() }

                    if let banner, !banner.isEmpty {
                        noticeCard(banner, isError: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Business name")
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))

                            TextField("Business / brand name", text: $businessName)
                                .textInputAutocapitalization(.words)
                                .fanGeoInputFieldStyle()
                                .onChange(of: businessName) { _, _ in
                                    guard didHydrateIdentity else { return }
                                    syncNameValidation()
                                    banner = nil
                                }

                            if let nameInlineError {
                                Text(nameInlineError)
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.dangerRed)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Business @handle")
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))

                            HStack(spacing: 6) {
                                Text("@")
                                    .font(FGTypography.body.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                TextField(suggestedHandlePlaceholder, text: $businessHandle)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.asciiCapable)
                                    .fanGeoInputFieldStyle()
                                    .onChange(of: businessHandle) { _, newValue in
                                        let normalized = FanGeoHandleRules.normalizeForStorage(newValue)
                                        if normalized != newValue {
                                            businessHandle = normalized
                                            return
                                        }
                                        guard didHydrateIdentity else { return }
                                        syncHandleValidation()
                                        banner = nil
                                    }
                            }

                            Text("Fans can find your business by this handle.")
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))

                            if isCheckingHandleAvailability {
                                Text("Checking handle availability...")
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }

                            if let handleInlineError {
                                Text(handleInlineError)
                                    .font(FGTypography.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.dangerRed)
                            }
                        }
                    }
                    .padding(14)
                    .background(FGColor.cardBackground(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.78), lineWidth: 1)
                    }

                    FGPrimaryButton(title: "Save", isDisabled: !canSave) {
                        Task { await saveIdentity() }
                    }
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, 32)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Business Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .task(id: resolvedBusinessId?.uuidString ?? "nil") {
                await hydrateIdentity()
            }
            .task(id: handleAvailabilityTaskKey) {
                await refreshHandleAvailability()
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 34, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentBlue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your public business identity")
                        .font(FGTypography.cardTitle.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("This name and @handle represent your business account. Venue names are edited separately.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.78), lineWidth: 1)
        }
    }

    /// Private account/login email — not part of public business identity; excluded from Save.
    private var accountEmailCard: some View {
        let title = L10n.t("business_identity_account_email", languageCode: languageCode)
        let helper = L10n.t("business_identity_account_email_helper", languageCode: languageCode)
        let display = accountEmailDisplayValue
        let a11yLabel = String(
            format: L10n.t("business_identity_account_email_a11y_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            display
        )
        let a11yHint = L10n.t("business_identity_account_email_a11y_hint", languageCode: languageCode)

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(width: 22, height: 22)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(display)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(
                            isAccountEmailUnavailable
                                ? FGColor.secondaryText(colorScheme)
                                : FGColor.primaryText(colorScheme)
                        )
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    Text(helper)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
            .accessibilityHint(a11yHint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.78), lineWidth: 1)
        }
    }

    private func logAccountEmailPresentationIfNeeded() {
#if DEBUG
        let emailPresent = !authenticatedAccountEmail.isEmpty
        if emailPresent {
            didLogMissingAccountEmail = false
            return
        }
        guard !didLogMissingAccountEmail else { return }
        didLogMissingAccountEmail = true
        let authIdPresent = viewModel.currentUserAuthId != nil
        let businessContext = viewModel.hasAuthenticatedVenueOwnerSession
            ? "venue_owner_session"
            : (viewModel.currentUserIsBusinessAccount ? "business_account_flag" : "other")
        print(
            "[BusinessIdentityEmail] authUserIdPresent=\(authIdPresent) sessionEmailPresent=false businessSessionContext=\(businessContext) venueOwnerEmailEmpty=\(viewModel.venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) currentUserEmailEmpty=\(viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) fallbackUsed=email_unavailable"
        )
#endif
    }

    private func noticeCard(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isError ? FGColor.dangerRed : FGColor.accentBlue)
            Text(message)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((isError ? FGColor.dangerRed : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.14 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor
    private func applyHydratedIdentity(displayName: String, handle: String) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHandle = FanGeoHandleRules.normalizeForStorage(handle)
        businessName = name
        businessHandle = normalizedHandle
        seededDisplayName = name
        seededHandle = normalizedHandle
        nameInlineError = nil
        handleInlineError = nil
        banner = nil
        handleAvailabilitySatisfied = true
        isCheckingHandleAvailability = false
        didHydrateIdentity = true
    }

    @MainActor
    private func hydrateIdentity() async {
        didHydrateIdentity = false
        nameInlineError = nil
        handleInlineError = nil

        let localRow: BusinessRow? = {
            if let id = resolvedBusinessId {
                return viewModel.ownedBusinesses.first(where: { $0.id == id })
                    ?? viewModel.ownedBusinesses.first
            }
            return viewModel.ownedBusinesses.first
        }()

        var name = (localRow?.display_name ?? initialDisplayName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var handle = FanGeoHandleRules.normalizeForStorage(
            localRow?.business_handle
                ?? initialBusinessHandle
                ?? ""
        )

        if let businessId = resolvedBusinessId ?? localRow?.id,
           let fetched = await viewModel.fetchBusinessIdentityFields(businessId: businessId) {
            let fetchedName = fetched.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fetchedHandle = FanGeoHandleRules.normalizeForStorage(fetched.handle ?? "")
            if !fetchedName.isEmpty {
                name = fetchedName
            }
            if !fetchedHandle.isEmpty {
                handle = fetchedHandle
            }
        }

        applyHydratedIdentity(displayName: name, handle: handle)
    }

    @MainActor
    private func syncNameValidation() {
        nameInlineError = liveNameValidationError
    }

    @MainActor
    private func syncHandleValidation() {
        handleInlineError = liveHandleValidationError
    }

    @MainActor
    private func refreshHandleAvailability() async {
        guard didHydrateIdentity else {
            handleAvailabilitySatisfied = true
            isCheckingHandleAvailability = false
            return
        }

        let handle = normalizedCurrentHandle

        if handleUnchangedFromSeeded {
            handleAvailabilitySatisfied = true
            isCheckingHandleAvailability = false
            if handleInlineError == "This business handle is already taken."
                || handleInlineError == "Unable to verify handle availability. Try again." {
                syncHandleValidation()
            }
            return
        }

        if let formatError = liveHandleValidationError {
            handleAvailabilitySatisfied = false
            isCheckingHandleAvailability = false
            handleInlineError = formatError
            return
        }

        guard let businessId = resolvedBusinessId else {
            handleAvailabilitySatisfied = false
            isCheckingHandleAvailability = false
            return
        }

        isCheckingHandleAvailability = true
        handleAvailabilitySatisfied = false

        let available = await viewModel.checkBusinessHandleAvailableForOwner(
            handle,
            excludeBusinessId: businessId
        )

        guard handle == normalizedCurrentHandle else { return }

        isCheckingHandleAvailability = false

        if available == nil {
            handleAvailabilitySatisfied = false
            handleInlineError = "Unable to verify handle availability. Try again."
        } else if available == false {
            handleAvailabilitySatisfied = false
            handleInlineError = "This business handle is already taken."
        } else {
            handleAvailabilitySatisfied = true
            syncHandleValidation()
        }
    }

    @MainActor
    private func saveIdentity() async {
        guard !isSaving else { return }

        syncNameValidation()
        syncHandleValidation()
        banner = nil

        guard let businessId = resolvedBusinessId else {
            banner = "Business account not ready. Try again."
            return
        }

        if !canSave {
            if isCheckingHandleAvailability {
                handleInlineError = "Checking handle availability. Try again in a moment."
            }
            return
        }

        isSaving = true
        let error = await viewModel.updateBusinessIdentity(
            businessId: businessId,
            displayName: businessName,
            businessHandle: normalizedCurrentHandle,
            previousDisplayName: seededDisplayName,
            previousHandle: seededHandle.isEmpty ? nil : seededHandle
        )
        isSaving = false

        if let error {
            if error.localizedCaseInsensitiveContains("handle") {
                handleInlineError = error
                handleAvailabilitySatisfied = false
            } else if error.localizedCaseInsensitiveContains("name") {
                nameInlineError = error
            } else {
                banner = error
            }
            return
        }

        dismiss()
    }
}

import SwiftUI

struct BusinessIdentityEditSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let businessId: UUID?
    let initialDisplayName: String
    let initialBusinessHandle: String?
    let suggestedHandlePlaceholder: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var businessName: String
    @State private var businessHandle: String
    @State private var nameInlineError: String?
    @State private var handleInlineError: String?
    @State private var banner: String?
    @State private var isSaving = false
    @State private var isCheckingHandleAvailability = false
    @State private var handleAvailabilitySatisfied = true

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
        _businessName = State(initialValue: initialDisplayName.trimmingCharacters(in: .whitespacesAndNewlines))
        _businessHandle = State(initialValue: initialBusinessHandle.map { FanGeoHandleRules.normalizeForStorage($0) } ?? "")
    }

    private var resolvedBusinessId: UUID? {
        businessId ?? viewModel.currentBusinessIdForAddLocation()
    }

    private var initialNormalizedHandle: String {
        initialBusinessHandle.map { FanGeoHandleRules.normalizeForStorage($0) } ?? ""
    }

    private var normalizedCurrentHandle: String {
        FanGeoHandleRules.normalizeForStorage(businessHandle)
    }

    private var handleAvailabilityTaskKey: String {
        "\(normalizedCurrentHandle)|\(initialNormalizedHandle)|\(resolvedBusinessId?.uuidString ?? "nil")"
    }

    private var liveNameValidationError: String? {
        BusinessIdentityValidation.validateBusinessName(businessName)
    }

    private var liveHandleValidationError: String? {
        let handle = normalizedCurrentHandle
        guard !handle.isEmpty else { return "Business @handle is required." }
        return BusinessIdentityValidation.validateBusinessHandle(handle)
    }

    private var handleUnchangedFromInitial: Bool {
        normalizedCurrentHandle == initialNormalizedHandle
    }

    private var canSave: Bool {
        guard resolvedBusinessId != nil else { return false }
        guard !isSaving, !isCheckingHandleAvailability else { return false }
        guard liveNameValidationError == nil, liveHandleValidationError == nil else { return false }
        return handleAvailabilitySatisfied
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard

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
            .onAppear {
                syncNameValidation()
                syncHandleValidation()
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
    private func syncNameValidation() {
        nameInlineError = liveNameValidationError
    }

    @MainActor
    private func syncHandleValidation() {
        handleInlineError = liveHandleValidationError
    }

    @MainActor
    private func refreshHandleAvailability() async {
        let handle = normalizedCurrentHandle

        if handleUnchangedFromInitial {
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
            previousHandle: initialBusinessHandle
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

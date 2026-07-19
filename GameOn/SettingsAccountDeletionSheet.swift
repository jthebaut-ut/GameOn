import SwiftUI

// MARK: - Phase 4: account deletion (Apple-compliant confirmation sheets)

struct SettingsAccountDeletionSheet: View {
    @ObservedObject var viewModel: MapViewModel
    var onCloseAfterSuccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmationText: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String = ""
    @State private var didSucceed: Bool = false
    @State private var showDeletionSuccessConfirmation: Bool = false
    @FocusState private var confirmationFieldFocused: Bool

    private var canDelete: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsPremiumChrome.profileSectionListSpacing) {
                    deletionHeader

                    deletionPersonalInfoSection
                    deletionActivitySection
                    deletionPreservedInfoSection
                    deletionPermanentWarningBanner
                    deletionConfirmSection

                    if !errorMessage.isEmpty {
                        deletionErrorBanner
                    }

                    deletionActionButtons
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.sm)
                .padding(.bottom, FGSpacing.lg)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if didSucceed {
                            completeSuccessClose()
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(isDeleting)
                }
            }
            .alert("Your account has been deleted.", isPresented: $showDeletionSuccessConfirmation) {
                Button("Close") {
                    completeSuccessClose()
                }
            } message: {
                Text("You have been signed out.")
            }
        }
    }

    private var deletionHeader: some View {
        VStack(spacing: FGSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(spacing: FGSpacing.xs) {
                Text("Delete Your FanGeo Account")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .multilineTextAlignment(.center)

                Text("Deleting your FanGeo account is permanent and cannot be undone.")
                    .font(.subheadline)
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FGSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var deletionPersonalInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileSettingsSectionHeader(title: "Your personal information will be removed")
            ProfileSettingsSectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    deletionCheckmarkRow("Your FanGeo profile will be anonymized and displayed as \"Deleted User\"")
                    deletionSectionDivider
                    deletionCheckmarkRow("Your profile photo and avatar will be permanently removed")
                    deletionSectionDivider
                    deletionCheckmarkRow("Your favorite teams and saved venues will be removed")
                    deletionSectionDivider
                    deletionCheckmarkRow("Your saved professional games and predictions will be removed")
                    deletionSectionDivider
                    deletionCheckmarkRow("Your notification preferences and device push notifications will be removed")
                    deletionSectionDivider
                    deletionCheckmarkRow("Your profile interactions (likes, props, pokes, blocks, etc.) will be removed")
                    deletionSectionDivider
                    deletionCheckmarkRow("Your personal FanGeo settings and preferences will be removed")
                }
                .padding(.vertical, FGSpacing.xs)
            }
        }
    }

    private var deletionActivitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileSettingsSectionHeader(title: "Your FanGeo activity will end")
            ProfileSettingsSectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    deletionNeutralRow(
                        systemImage: "sportscourt.fill",
                        tint: .orange,
                        text: "Pickup games you created will be cancelled or hidden"
                    )
                    deletionSectionDivider
                    deletionNeutralRow(
                        systemImage: "person.2.slash.fill",
                        tint: .orange,
                        text: "Outstanding pickup game requests and invitations will be cancelled"
                    )
                    deletionSectionDivider
                    deletionNeutralRow(
                        systemImage: "person.crop.circle.badge.minus",
                        tint: .orange,
                        text: "Active friendships will be archived and removed from active use"
                    )
                }
                .padding(.vertical, FGSpacing.xs)
            }
        }
    }

    private var deletionPreservedInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileSettingsSectionHeader(title: "Information that must remain")
            ProfileSettingsSectionCard {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.blue)
                            .padding(.top, 1)

                        Text("To protect conversations, moderation history, and community integrity, some shared information must remain. It will no longer identify you.")
                            .font(.subheadline)
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: FGSpacing.sm) {
                        deletionInfoBullet("Direct Messages (shown as \"Deleted User\")")
                        deletionInfoBullet("Public comments (shown as \"Deleted User\")")
                        deletionInfoBullet("Reports submitted or received")
                        deletionInfoBullet("Support conversations with FanGeo")
                        deletionInfoBullet("Administrative and moderation records")
                    }
                    .padding(.leading, FGSpacing.lg + FGSpacing.xs)
                }
                .padding(.vertical, FGSpacing.sm)
                .padding(.horizontal, FGSpacing.md)
            }
        }
    }

    private var deletionPermanentWarningBanner: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(deletionWarningTint)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                Text("Permanent deletion")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))

                Text("This account cannot be restored after deletion. Your profile and private FanGeo data will be removed or anonymized, while certain shared records may remain as “Deleted User.”")
                    .font(.subheadline)
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Your current email address will remain reserved and cannot be used to create another FanGeo account at this time.")
                    .font(.subheadline)
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .fill(deletionWarningTint.opacity(colorScheme == .dark ? 0.14 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(deletionWarningTint.opacity(colorScheme == .dark ? 0.38 : 0.30), lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Permanent deletion. This account cannot be restored after deletion. Your profile and private FanGeo data will be removed or anonymized, while certain shared records may remain as Deleted User. Your current email address will remain reserved and cannot be used to create another FanGeo account at this time."
        )
    }

    private var deletionWarningTint: Color {
        Color.orange
    }

    private var deletionConfirmSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProfileSettingsSectionHeader(title: "Confirm")
            ProfileSettingsSectionCard {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    TextField("Type DELETE to confirm", text: $confirmationText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($confirmationFieldFocused)
                        .disabled(isDeleting || didSucceed)
                        .font(.body)

                    Text("Type DELETE, then tap Delete My Account. You will be signed out after deletion succeeds.")
                        .font(.caption)
                        .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(FGSpacing.md)
            }
        }
    }

    private var deletionErrorBanner: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .fill(Color.red.opacity(colorScheme == .dark ? 0.16 : 0.08))
        }
    }

    private var deletionActionButtons: some View {
        VStack(spacing: FGSpacing.sm) {
            Button(role: .destructive) {
                Task { await runDelete() }
            } label: {
                HStack(spacing: FGSpacing.sm) {
                    if isDeleting {
                        ProgressView()
                    }
                    Text(isDeleting ? "Deleting..." : "Delete My Account")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, FGSpacing.md)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!canDelete || isDeleting || didSucceed)

            Button {
                if didSucceed {
                    completeSuccessClose()
                } else {
                    dismiss()
                }
            } label: {
                Text("Cancel")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FGSpacing.md)
            }
            .buttonStyle(.bordered)
            .disabled(isDeleting)
        }
        .padding(.top, FGSpacing.xs)
    }

    @ViewBuilder
    private var deletionSectionDivider: some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, 40)
            .padding(.trailing, FGSpacing.md)
    }

    @ViewBuilder
    private func deletionCheckmarkRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .padding(.top, 1)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func deletionNeutralRow(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: systemImage)
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 1)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func deletionInfoBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.xs) {
            Text("•")
                .font(.subheadline)
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runDelete() async {
        isDeleting = true
        defer { isDeleting = false }
        errorMessage = ""

        do {
            try await viewModel.requestPermanentAccountDeletion()
            await MainActor.run {
                didSucceed = true
                confirmationText = ""
                dismissKeyboard()
                showDeletionSuccessConfirmation = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func dismissKeyboard() {
        confirmationFieldFocused = false
#if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
#endif
    }

    @MainActor
    private func completeSuccessClose() {
        dismissKeyboard()
        onCloseAfterSuccess()
        dismiss()
    }
}

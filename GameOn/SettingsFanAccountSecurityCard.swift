import SwiftUI

// MARK: - Account security (fan)

struct SettingsFanAccountSecurityCard: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var isShowingDeleteSheet = false
    @State private var deleteConfirmationText = ""
    @State private var isDeleting = false
    @State private var deletionErrorMessage = ""
    @State private var deletionSuccessMessage = ""

    private var trimmedConfirmation: String {
        deleteConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deletionEnabled: Bool {
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return trimmedConfirmation.caseInsensitiveCompare("DELETE") == .orderedSame ||
            trimmedConfirmation.caseInsensitiveCompare(email) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account security")
                .font(.headline)
                .fontWeight(.bold)

                Text("Manage sensitive account actions. Deletion removes or anonymizes your profile and preferences, while chats, Fan Chat comments, reports, and moderation records may remain as Deleted User for safety and conversation integrity.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                deletionErrorMessage = ""
                deletionSuccessMessage = ""
                deleteConfirmationText = ""
                isShowingDeleteSheet = true
            } label: {
                Label("Delete account permanently", systemImage: "trash")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if !deletionSuccessMessage.isEmpty {
                Text(deletionSuccessMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !deletionErrorMessage.isEmpty {
                Text(deletionErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .sheet(isPresented: $isShowingDeleteSheet) {
            deleteAccountSheet
        }
    }

    private var deleteAccountSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Delete account permanently")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("This removes your profile, favorites, attendance, and preferences. Existing chats and Fan Chat comments stay readable for other users and show you as Deleted User. This cannot be undone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("To confirm, type your email or the word DELETE:")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    TextField("Type email or DELETE", text: $deleteConfirmationText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    HStack(spacing: 10) {
                        Button {
                            isShowingDeleteSheet = false
                        } label: {
                            Text("Cancel")
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.gray.opacity(0.14))
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(isDeleting)

                        Button {
                            Task {
                                isDeleting = true
                                deletionErrorMessage = ""
                                deletionSuccessMessage = ""

                                do {
                                    try await viewModel.requestPermanentAccountDeletion()
                                    deletionSuccessMessage = "Account deleted. You’ve been signed out."
                                    isShowingDeleteSheet = false
                                } catch {
                                    deletionErrorMessage = error.localizedDescription
                                }

                                isDeleting = false
                            }
                        } label: {
                            HStack {
                                if isDeleting {
                                    ProgressView()
                                        .tint(.red)
                                }
                                Text(isDeleting ? "Deleting..." : "Delete permanently")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.12))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(!deletionEnabled || isDeleting)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

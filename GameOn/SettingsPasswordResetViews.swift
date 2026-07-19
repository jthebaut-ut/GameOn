import SwiftUI

// MARK: - Fan password reset

/// Password recovery email for the fan account; reuses the login email field when signed out.
struct SettingsFanPasswordResetCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var loginEmail: String
    @State private var isSending = false
    @Environment(\.colorScheme) private var colorScheme

    private var emailForReset: String {
        if viewModel.isLoggedIn {
            return viewModel.currentUserEmail
        }
        return loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FGCard {
            FGSectionHeader(
                "Reset password",
                subtitle: "We’ll email you a secure link to choose a new password. Use the same email as your fan account."
            )

            if viewModel.isLoggedIn {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(viewModel.currentUserEmail)
                        .font(FGTypography.body.weight(.medium))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                .padding(FGSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.97))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
            } else {
                TextField("Email for password reset", text: $loginEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .fanGeoInputFieldStyle()
            }

            FGPrimaryButton(title: "Send reset link", isDisabled: isSending) {
                Task {
                    isSending = true
                    await viewModel.sendPasswordResetEmail(emailForReset, accountKind: .fan)
                    isSending = false
                }
            }

            if !viewModel.userPasswordResetMessage.isEmpty {
                SettingsSheetStatusBanner(
                    title: "Reset link sent",
                    message: viewModel.userPasswordResetMessage,
                    tint: FGColor.accentGreen,
                    systemImage: "checkmark.circle.fill"
                )
            }

            if !viewModel.userPasswordResetError.isEmpty {
                SettingsSheetStatusBanner(
                    title: "Reset unavailable",
                    message: viewModel.userPasswordResetError,
                    tint: FGColor.dangerRed,
                    systemImage: "xmark.circle.fill"
                )
            }
        }
    }
}

struct SettingsFanPasswordResetSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let loginEmail: String
    @Binding var isPresented: Bool
    @State private var resetEmail = ""
    @State private var isSending = false
    @State private var resetLinkAutoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if viewModel.passwordResetSheetMode == .createPassword || viewModel.isPasswordResetRecoverySessionActive {
                Color.clear.ignoresSafeArea()
            } else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: FGSpacing.md) {
                        FGSectionHeader(
                            "Reset password",
                            subtitle: "We’ll email a secure link to reset your FanGeo fan account password."
                        )

                        TextField("Email", text: $resetEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .fanGeoInputFieldStyle()

                        FGPrimaryButton(title: "Send reset link", isDisabled: isSending) {
                            Task {
                                isSending = true
                                await viewModel.sendPasswordResetEmail(resetEmail, accountKind: .fan)
                                isSending = false
                            }
                        }

                        if !viewModel.userPasswordResetMessage.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Reset link sent",
                                message: viewModel.userPasswordResetMessage,
                                tint: FGColor.accentGreen,
                                systemImage: "checkmark.circle.fill"
                            )
                        }

                        if !viewModel.userPasswordResetError.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Reset unavailable",
                                message: viewModel.userPasswordResetError,
                                tint: FGColor.dangerRed,
                                systemImage: "xmark.circle.fill"
                            )
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(FGSpacing.lg)
                    .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
                    .navigationTitle("Reset password")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(viewModel.userPasswordResetMessage.isEmpty ? "Cancel" : "Done") {
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            resetEmail = loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            viewModel.passwordResetRequestSheetDidAppear()
        }
        .onDisappear {
            cancelResetLinkAutoDismiss(log: true)
            viewModel.passwordResetRequestSheetDidDisappear()
        }
        .onChange(of: viewModel.userPasswordResetMessage) { _, message in
            scheduleResetLinkAutoDismissIfNeeded(message: message, error: viewModel.userPasswordResetError)
        }
        .onChange(of: viewModel.userPasswordResetError) { _, error in
            if !error.isEmpty {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
        .onChange(of: viewModel.passwordResetSheetMode) { _, mode in
            if mode != .requestLink {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
    }

    private func scheduleResetLinkAutoDismissIfNeeded(message: String, error: String) {
        guard !message.isEmpty,
              error.isEmpty,
              isPresented,
              viewModel.passwordResetSheetMode == .requestLink,
              !viewModel.isPasswordResetRecoverySessionActive
        else { return }

        cancelResetLinkAutoDismiss(log: false)
        print("[PasswordResetDebug] resetLinkSendSuccessAutoDismissScheduled=true")
        resetLinkAutoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PasswordResetRequestAutoDismiss.delayNanoseconds)
            } catch {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            guard isPresented,
                  viewModel.passwordResetSheetMode == .requestLink,
                  !viewModel.userPasswordResetMessage.isEmpty,
                  viewModel.userPasswordResetError.isEmpty
            else {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            resetLinkAutoDismissTask = nil
            isPresented = false
            print("[PasswordResetDebug] resetLinkRequestSheetAutoDismissed=true")
        }
    }

    private func cancelResetLinkAutoDismiss(log: Bool) {
        guard let task = resetLinkAutoDismissTask else { return }
        task.cancel()
        resetLinkAutoDismissTask = nil
        if log {
            print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
        }
    }
}

// MARK: - Venue owner password reset

enum PasswordResetRequestAutoDismiss {
    static let delayNanoseconds: UInt64 = 4_500_000_000
}

struct SettingsVenueOwnerPasswordResetSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var isPresented: Bool
    @State private var resetLinkAutoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if viewModel.passwordResetSheetMode == .createPassword || viewModel.isPasswordResetRecoverySessionActive {
                Color.clear.ignoresSafeArea()
            } else {
                NavigationStack {
                    Form { SettingsVenuePasswordResetCard(viewModel: viewModel) }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                        }
                        .navigationTitle("Reset venue password")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { isPresented = false }
                            }
                        }
                }
            }
        }
        .onAppear {
            viewModel.passwordResetRequestSheetDidAppear()
        }
        .onDisappear {
            cancelResetLinkAutoDismiss(log: true)
            viewModel.passwordResetRequestSheetDidDisappear()
        }
        .onChange(of: viewModel.venuePasswordResetMessage) { _, message in
            scheduleResetLinkAutoDismissIfNeeded(message: message, error: viewModel.venuePasswordResetError)
        }
        .onChange(of: viewModel.venuePasswordResetError) { _, error in
            if !error.isEmpty {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
        .onChange(of: viewModel.passwordResetSheetMode) { _, mode in
            if mode != .requestLink {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
    }

    private func scheduleResetLinkAutoDismissIfNeeded(message: String, error: String) {
        guard !message.isEmpty,
              error.isEmpty,
              isPresented,
              viewModel.passwordResetSheetMode == .requestLink,
              !viewModel.isPasswordResetRecoverySessionActive
        else { return }

        cancelResetLinkAutoDismiss(log: false)
        print("[PasswordResetDebug] resetLinkSendSuccessAutoDismissScheduled=true")
        resetLinkAutoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PasswordResetRequestAutoDismiss.delayNanoseconds)
            } catch {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            guard isPresented,
                  viewModel.passwordResetSheetMode == .requestLink,
                  !viewModel.venuePasswordResetMessage.isEmpty,
                  viewModel.venuePasswordResetError.isEmpty
            else {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            resetLinkAutoDismissTask = nil
            isPresented = false
            print("[PasswordResetDebug] resetLinkRequestSheetAutoDismissed=true")
        }
    }

    private func cancelResetLinkAutoDismiss(log: Bool) {
        guard let task = resetLinkAutoDismissTask else { return }
        task.cancel()
        resetLinkAutoDismissTask = nil
        if log {
            print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
        }
    }
}

/// Password recovery for the venue-owner Supabase account (same Auth table as fans; uses the venue business email field when present).
struct SettingsVenuePasswordResetCard: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var isSending = false
    @State private var emailIfMissing = ""

    private var emailForReset: String {
        let fromProfile = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        if !fromProfile.isEmpty { return fromProfile }
        return emailIfMissing.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset venue password")
                .font(.headline)
                .fontWeight(.bold)

            Text("We’ll email a link to reset the password for your venue owner login.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isVenueOwnerLoggedIn {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.secondary)
                    Text(viewModel.venueOwnerEmail)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail).isEmpty {
                TextField("Venue owner email for reset", text: $emailIfMissing)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Text("Uses the business email you entered above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    isSending = true
                    await viewModel.sendPasswordResetEmail(emailForReset, accountKind: .venueOwner)
                    isSending = false
                }
            } label: {
                HStack {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("Send reset link")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.black.opacity(isSending ? 0.45 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(isSending)

            if !viewModel.venuePasswordResetMessage.isEmpty {
                Text(viewModel.venuePasswordResetMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !viewModel.venuePasswordResetError.isEmpty {
                Text(viewModel.venuePasswordResetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

struct SettingsBusinessPasswordResetSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var isPresented: Bool
    @State private var resetEmail = ""
    @State private var isSending = false
    @State private var resetLinkAutoDismissTask: Task<Void, Never>?

    private var prefilledBusinessEmail: String {
        OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
    }

    var body: some View {
        Group {
            if viewModel.passwordResetSheetMode == .createPassword || viewModel.isPasswordResetRecoverySessionActive {
                Color.clear.ignoresSafeArea()
            } else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: FGSpacing.md) {
                        FGSectionHeader(
                            "Reset business password",
                            subtitle: "We’ll email a secure link to reset the password for your business owner account."
                        )

                        TextField("Business email", text: $resetEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .fanGeoInputFieldStyle()

                        FGPrimaryButton(title: "Send reset link", isDisabled: isSending) {
                            Task {
                                isSending = true
                                await viewModel.sendPasswordResetEmail(resetEmail, accountKind: .venueOwner)
                                isSending = false
                            }
                        }

                        if !viewModel.venuePasswordResetMessage.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Reset link sent",
                                message: viewModel.venuePasswordResetMessage,
                                tint: FGColor.accentGreen,
                                systemImage: "checkmark.circle.fill"
                            )
                        }

                        if !viewModel.venuePasswordResetError.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Reset unavailable",
                                message: viewModel.venuePasswordResetError,
                                tint: FGColor.dangerRed,
                                systemImage: "xmark.circle.fill"
                            )
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(FGSpacing.lg)
                    .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
                    .navigationTitle("Reset business password")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(viewModel.venuePasswordResetMessage.isEmpty ? "Cancel" : "Done") {
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            resetEmail = prefilledBusinessEmail
            viewModel.passwordResetRequestSheetDidAppear()
        }
        .onDisappear {
            cancelResetLinkAutoDismiss(log: true)
            viewModel.passwordResetRequestSheetDidDisappear()
        }
        .onChange(of: viewModel.venuePasswordResetMessage) { _, message in
            scheduleResetLinkAutoDismissIfNeeded(message: message, error: viewModel.venuePasswordResetError)
        }
        .onChange(of: viewModel.venuePasswordResetError) { _, error in
            if !error.isEmpty {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
        .onChange(of: viewModel.passwordResetSheetMode) { _, mode in
            if mode != .requestLink {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
    }

    private func scheduleResetLinkAutoDismissIfNeeded(message: String, error: String) {
        guard !message.isEmpty,
              error.isEmpty,
              isPresented,
              viewModel.passwordResetSheetMode == .requestLink,
              !viewModel.isPasswordResetRecoverySessionActive
        else { return }

        cancelResetLinkAutoDismiss(log: false)
        print("[PasswordResetDebug] resetLinkSendSuccessAutoDismissScheduled=true")
        resetLinkAutoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PasswordResetRequestAutoDismiss.delayNanoseconds)
            } catch {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            guard isPresented,
                  viewModel.passwordResetSheetMode == .requestLink,
                  !viewModel.venuePasswordResetMessage.isEmpty,
                  viewModel.venuePasswordResetError.isEmpty
            else {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            resetLinkAutoDismissTask = nil
            isPresented = false
            print("[PasswordResetDebug] resetLinkRequestSheetAutoDismissed=true")
        }
    }

    private func cancelResetLinkAutoDismiss(log: Bool) {
        guard let task = resetLinkAutoDismissTask else { return }
        task.cancel()
        resetLinkAutoDismissTask = nil
        if log {
            print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
        }
    }
}

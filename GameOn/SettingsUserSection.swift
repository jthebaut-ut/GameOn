import SwiftUI

// MARK: - User tab

struct SettingsUserSection: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if viewModel.isLoggedIn {
                SettingsGameNotificationsCard(viewModel: viewModel, notificationSettingsStore: viewModel.notificationSettingsStore)
                SettingsSavedGamesCard()
            }

            SettingsFanLoginCard(
                viewModel: viewModel,
                email: $email,
                password: $password,
                onCreateAccount: { showRegisterMode = true }
            )

            if viewModel.isLoggedIn {
                SettingsPrivateChatDeviceAuthCard()
                SettingsFanAccountSecurityCard(viewModel: viewModel)
            }
        }
    }
}

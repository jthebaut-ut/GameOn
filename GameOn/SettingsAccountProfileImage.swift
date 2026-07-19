import SwiftUI

struct SettingsAccountProfileImage: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        UserAvatarView(
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
            displayName: UserAvatarView.accountResolvedDisplayName(
                isLoggedIn: viewModel.isLoggedIn,
                currentUserDisplayName: viewModel.currentUserDisplayName,
                isVenueOwnerLoggedIn: viewModel.isVenueOwnerLoggedIn,
                ownerVenueName: viewModel.ownerVenueName,
                userEmail: viewModel.currentUserEmail,
                venueOwnerEmail: viewModel.venueOwnerEmail
            ),
            email: UserAvatarView.accountEmailLine(
                isLoggedIn: viewModel.isLoggedIn,
                userEmail: viewModel.currentUserEmail,
                venueOwnerEmail: viewModel.venueOwnerEmail
            ),
            size: 44,
            fallbackStyle: .lightOnWhiteChrome
        )
    }
}

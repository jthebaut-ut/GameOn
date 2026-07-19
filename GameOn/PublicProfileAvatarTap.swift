import SwiftUI

/// Wraps an avatar chip so tapping opens ``PublicUserProfilePreviewView`` for another user.
struct PublicProfileAvatarTap<Content: View>: View {
    let userId: UUID?
    let context: String
    /// Optional nested sheet name for ``[PublicProfilePresentationDebug] activeSheet=``.
    var activeSheet: String?
    @ViewBuilder let content: () -> Content

    @EnvironmentObject private var viewModel: MapViewModel

    var body: some View {
        if let userId, userId != viewModel.currentUserAuthId {
            Button {
                let isSuggestedFans = context.contains("suggested_fan")
                if isSuggestedFans {
                    SuggestedFanProfileOpenDebug.cardTapReceived(
                        recommendationStableId: userId,
                        targetUserIdPresent: true,
                        displayModelIdType: "UUID.userID",
                        authenticatedUserPresent: viewModel.currentUserAuthId != nil,
                        context: context
                    )
                    SuggestedFanProfileOpenDebug.eligibility(
                        isSelf: false,
                        isBlocked: false
                    )
                }
                viewModel.presentPublicProfile(
                    userId: userId,
                    context: context,
                    activeSheet: activeSheet
                )
            } label: {
                content()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens profile preview")
        } else {
            content()
        }
    }
}

import SwiftUI

/// Settings → Help & Support: ticket-first FanGeo Support workflow.
struct ContactGameOnSupportSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    var onRequestSignIn: () -> Void
    var embedsInNavigationStack = true
    var showsCloseButton = true
    var screenTitle: String = "Support Center"
    var initialTicketID: UUID? = nil

    var body: some View {
        FanGeoSupportHubView(
            mapViewModel: viewModel,
            chatViewModel: chatViewModel,
            onRequestSignIn: onRequestSignIn,
            embedsInNavigationStack: embedsInNavigationStack,
            showsCloseButton: showsCloseButton,
            screenTitle: screenTitle,
            initialTicketID: initialTicketID
        )
    }
}

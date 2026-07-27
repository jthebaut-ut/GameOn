import SwiftUI

/// Observes ``MapViewModel/publicProfileSheetUserId`` and drives full-screen ``PublicProfileOverlayWindowPresenter``.
struct PublicProfilePresentationHost<Content: View>: View {
    @ObservedObject var viewModel: MapViewModel
    /// Passed only to the imperative overlay presenter. Keeping this as a plain reference
    /// prevents Chat-only publications from rebuilding the complete root content closure.
    let chatViewModel: ChatViewModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onAppear(perform: syncOverlay)
            .onChange(of: viewModel.publicProfileSheetUserId) { _, _ in
                syncOverlay()
            }
    }

    private func syncOverlay() {
        PublicProfileOverlayWindowPresenter.syncPresentation(
            userId: viewModel.publicProfileSheetUserId,
            viewModel: viewModel,
            chatViewModel: chatViewModel,
            activeSheetHint: viewModel.publicProfilePresentationContext
        )
    }
}

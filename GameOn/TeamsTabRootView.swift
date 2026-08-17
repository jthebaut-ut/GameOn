import SwiftUI

/// Root Teams destination — reuses ``MyTeamsChatSectionView`` (same list/detail/create/invite
/// surface formerly embedded under Chat → My Teams). Owns its own navigation chrome and
/// bottom inset so Chat and Teams do not share a ``NavigationStack``.
struct TeamsTabRootView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    @Binding var selectedTab: MainTabView.AppTab
    var isTeamsTabSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            MyTeamsChatSectionView(
                mapViewModel: mapViewModel,
                chatViewModel: chatViewModel,
                onOpenTeamChat: { context in
                    // Team MESSAGE / Team Chat → global Chat conversation (not Team management).
                    chatViewModel.pendingGroupOpenConversationId = context.conversationId
                    selectedTab = .chat
                },
                isTeamsTabSelected: isTeamsTabSelected
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: MainTabView.floatingTabBarStackHeight)
                    .accessibilityHidden(true)
            }
        }
        .background(
            (colorScheme == .dark ? Color.black : Color(.systemBackground))
                .ignoresSafeArea()
        )
        .onChange(of: isTeamsTabSelected) { _, selected in
            guard selected else { return }
            consumePendingTeamsDeepLinkIfNeeded()
        }
        .onChange(of: chatViewModel.pendingOpenMyTeamsInvitations) { _, open in
            guard open, isTeamsTabSelected else { return }
            consumePendingTeamsDeepLinkIfNeeded()
        }
        .onAppear {
            if isTeamsTabSelected {
                consumePendingTeamsDeepLinkIfNeeded()
            }
        }
    }

    /// Invitation / team-management push landed on the Teams tab (no Chat → My Teams hop).
    private func consumePendingTeamsDeepLinkIfNeeded() {
        guard mapViewModel.isAuthenticatedForSocialFeatures else { return }
        guard chatViewModel.pendingOpenMyTeamsInvitations else { return }
#if DEBUG
        print("[FanTeamInvitationPushRoute] TeamsTab consume pendingOpenMyTeamsInvitations")
#endif
        chatViewModel.acknowledgeFanTeamInvitationPushDeepLinkOpened()
        // Highlight / roster open ids remain until MyTeamsChatSectionView consumes them.
    }
}

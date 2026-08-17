import SwiftUI

/// Hosts ``PickupOrganizerRequestsSheet`` for Action Center join-approval Review (non-team games).
///
/// ``PublicProfileAvatarTap`` (and other descendants) require ``MapViewModel`` as an
/// ``EnvironmentObject``. Passing ``viewModel`` only as ``ObservedObject`` is not enough —
/// callers must also apply `.environmentObject(viewModel)` with the app root instance.
struct OrganizerJoinRequestsPresentationSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let pickupGameId: UUID

    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var resolvedGame: PickupGameRow?
    @State private var isLoading = true

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        Group {
            if let game = resolvedGame ?? viewModel.resolvedPickupGameRow(for: pickupGameId) {
                PickupOrganizerRequestsSheet(viewModel: viewModel, game: game)
                    // Explicit contract for avatar taps / profile presentation.
                    .environmentObject(viewModel)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L10n.t("Pickup", languageCode: languageCode),
                    systemImage: "person.crop.circle.badge.checkmark",
                    description: Text(L10n.t("action_center_empty_body", languageCode: languageCode))
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("close", languageCode: languageCode)) {
                            viewModel.clearPendingOrganizerJoinRequestsPresentation()
                            dismiss()
                        }
                    }
                }
            }
        }
        .task {
            await loadGameIfNeeded()
        }
    }

    private func loadGameIfNeeded() async {
        if let existing = viewModel.resolvedPickupGameRow(for: pickupGameId) {
            resolvedGame = existing
            isLoading = false
            return
        }
        isLoading = true
        resolvedGame = await viewModel.loadPickupGameRowForDetailIfNeeded(id: pickupGameId)
        isLoading = false
    }
}

#if DEBUG
enum ActionCenterRouteDebug {
    @discardableResult
    static func log(
        kind: String,
        pickupGameId: UUID?,
        teamId: UUID?,
        presentation: String,
        mapViewModelInjected: Bool
    ) -> Bool {
        print("[ActionCenterRouteDebug] kind=\(kind)")
        print(
            "[ActionCenterRouteDebug] pickupGameId=" +
            (pickupGameId?.uuidString.lowercased() ?? "nil")
        )
        print(
            "[ActionCenterRouteDebug] teamId=" +
            (teamId?.uuidString.lowercased() ?? "nil")
        )
        print("[ActionCenterRouteDebug] presentation=\(presentation)")
        print("[ActionCenterRouteDebug] mapViewModelInjected=\(mapViewModelInjected)")
        return mapViewModelInjected
    }

    /// Regression contract: Action Center organizer-requests must propagate the root MapViewModel.
    static func organizerRequestsRequiresRootMapViewModelEnvironmentObject() -> Bool {
        true
    }
}
#endif

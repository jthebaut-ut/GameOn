import SwiftUI

/// Hosts the existing ``PickupCreatorRatingPromptCard`` for Action Center / Going “Rate Now”.
/// Does not invent a second rating flow — submit still goes through ``MapViewModel.submitPickupCreatorRating``.
struct PickupCreatorRatingPromptSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let pickupGameId: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var resolvedGame: PickupGameRow?
    @State private var isLoading = true

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let game = resolvedGame ?? viewModel.resolvedPickupGameRow(for: pickupGameId) {
                    ScrollView {
                        PickupCreatorRatingPromptCard(
                            viewModel: viewModel,
                            game: game,
                            onNotNow: {
                                viewModel.clearPendingPickupCreatorRatingPromptPresentation()
                                dismiss()
                            }
                        )
                        .environmentObject(viewModel)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(.systemGroupedBackground).ignoresSafeArea())
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        L10n.t("Pickup", languageCode: languageCode),
                        systemImage: "star",
                        description: Text(L10n.t("action_center_empty_body", languageCode: languageCode))
                    )
                }
            }
            .navigationTitle(L10n.t("action_center_rate_pickup_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close", languageCode: languageCode)) {
                        viewModel.clearPendingPickupCreatorRatingPromptPresentation()
                        dismiss()
                    }
                }
            }
            .task {
                await loadGameIfNeeded()
            }
            .onChange(of: viewModel.pickupGameIdsWithMyCreatorRating) { _, ids in
                if ids.contains(pickupGameId) {
                    // Brief thanks state, then dismiss so Action Center / Going refresh cleanly.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        viewModel.clearPendingPickupCreatorRatingPromptPresentation()
                        dismiss()
                    }
                }
            }
        }
    }

    private func loadGameIfNeeded() async {
        if let existing = viewModel.resolvedPickupGameRow(for: pickupGameId) {
            resolvedGame = existing
            isLoading = false
            return
        }
        isLoading = true
        let row = await viewModel.loadPickupGameRowForDetailIfNeeded(id: pickupGameId)
        resolvedGame = row
        isLoading = false
    }
}

import SwiftUI

/// Liquid Glass venue rating sheet: community social proof + “Your rating” stars.
struct VenueUserRatingSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let bar: BarVenue
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var selectedStars: Int = 4
    @State private var isSaving = false
    @State private var isLoadingStats = false

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var socialProof: String {
        viewModel.venueRatingSocialProof(for: bar.id, languageCode: languageCode)
    }

    private var socialProofAccessibility: String {
        (viewModel.venueRatingStatsByVenueId[bar.id] ?? .empty)
            .accessibilityLabel(languageCode: languageCode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(bar.name)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                Text(socialProof)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(socialProofAccessibility)
                    .redacted(reason: isLoadingStats && viewModel.venueRatingStatsByVenueId[bar.id] == nil ? .placeholder : [])

                Text(L10n.t("venue_rating_your_rating", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { n in
                        Button {
                            selectedStars = n
                        } label: {
                            Image(systemName: n <= selectedStars ? "star.fill" : "star")
                                .font(.system(size: 36, weight: .bold))
                                .foregroundStyle(n <= selectedStars ? Color.yellow : Color.gray.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(
                        format: L10n.t("venue_rating_stars_a11y_format", languageCode: languageCode),
                        selectedStars
                    )
                )

                Spacer(minLength: 0)

                Button {
                    Task { await save() }
                } label: {
                    Text(L10n.t("Save", languageCode: languageCode))
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .background(Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .opacity(isSaving ? 0.7 : 1)
                }
                .disabled(isSaving)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.vertical, 8)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) { dismiss() }
                        .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task(id: bar.id) {
            await loadInitialState()
        }
    }

    @MainActor
    private func loadInitialState() async {
        if let existing = viewModel.venueUserStarRatings[bar.id]
            ?? viewModel.venueRatingStatsByVenueId[bar.id]?.myRating {
            selectedStars = existing
        }
        isLoadingStats = true
        await viewModel.refreshVenueRatingStats(for: bar.id)
        isLoadingStats = false
        if let mine = viewModel.venueRatingStatsByVenueId[bar.id]?.myRating {
            selectedStars = mine
        }
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        await viewModel.saveUserVenueRating(venueID: bar.id, stars: selectedStars)
        isSaving = false
        dismiss()
    }
}

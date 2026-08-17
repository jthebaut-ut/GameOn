import SwiftUI

/// Compact one-tap scorer picker shown immediately after Team `+`.
struct FanTeamScorerPickerSheet: View {
    let mode: FanTeamScorerAttributionMode
    let scorers: [FanTeamEligibleScorer]
    let languageCode: String
    let accent: Color
    let onPick: (FanTeamScorerPick) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let subtitle = FanTeamScoreAttributionPresentation.pickerSubtitle(
                    mode: mode,
                    languageCode: languageCode
                ) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, 16)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(scorers) { scorer in
                            Button {
                                onPick(.player(scorer))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ManagedPlayerAvatarView(
                                        managedPlayerId: scorer.managedPlayerId ?? scorer.userId,
                                        avatarURL: scorer.avatarURL,
                                        avatarThumbnailURL: scorer.avatarThumbnailURL,
                                        displayName: scorer.displayName,
                                        size: 36
                                    )
                                    .accessibilityHidden(true)
                                    Text(scorer.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(scorer.displayName)
                            .padding(.horizontal, 16)
                        }

                        Button {
                            onPick(.skip)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "questionmark.circle")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .frame(width: 36, height: 36)
                                    .accessibilityHidden(true)
                                Text(FanTeamScoreAttributionPresentation.skipTitle(languageCode: languageCode))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer(minLength: 8)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            FanTeamScoreAttributionPresentation.skipAccessibilityLabel(languageCode: languageCode)
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, scorers.isEmpty ? 0 : 8)
                    }
                }
            }
            .padding(.top, 8)
            .navigationTitle(FanTeamScoreAttributionPresentation.pickerTitle(languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(scorers.count > 8 ? [.medium, .large] : [.height(320), .medium])
        .presentationDragIndicator(.visible)
    }
}

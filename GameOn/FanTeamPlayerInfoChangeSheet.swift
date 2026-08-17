import SwiftUI

/// Leaf sheet: pick which Team-scoped Player Info subject to view.
///
/// Selection key is `membership_id`. Persistence is owned by the Team Detail host
/// (`FanTeamPlayerInfoSelectionStore`) so the write is not cancelled when this sheet dismisses.
struct FanTeamPlayerInfoChangeSheet: View {
    let subjects: [FanTeamPlayerInfoSubject]
    let selectedMembershipId: UUID?
    let languageCode: String
    var isBusy: Bool = false
    let onSelect: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(subjects) { subject in
                        row(subject)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(
                L10n.t("fan_teams_player_info_who_viewing", languageCode: languageCode)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                        .disabled(isBusy)
                }
            }
            .interactiveDismissDisabled(isBusy)
        }
    }

    private func row(_ subject: FanTeamPlayerInfoSubject) -> some View {
        let isSelected = subject.membershipId == selectedMembershipId
        let subtitle = L10n.t(
            FanTeamMyPlayerInfoPresentation.selectorSubtitleKey(subject: subject),
            languageCode: languageCode
        )
        return Button {
            guard !isBusy else { return }
            onSelect(subject.membershipId)
        } label: {
            HStack(spacing: 12) {
                TeamMemberAvatarView(member: subject.member, size: 40)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.member.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isBusy && !isSelected {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(FGColor.accentGreen)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(displayName: subject.member.displayName, subtitle: subtitle, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowAccessibilityLabel(displayName: String, subtitle: String, isSelected: Bool) -> String {
        if isSelected {
            return String(
                format: L10n.t(
                    "fan_teams_player_info_subject_selected_a11y_format",
                    languageCode: languageCode
                ),
                locale: Locale(identifier: languageCode),
                displayName,
                subtitle
            )
        }
        return String(
            format: L10n.t(
                "fan_teams_player_info_subject_a11y_format",
                languageCode: languageCode
            ),
            locale: Locale(identifier: languageCode),
            displayName,
            subtitle
        )
    }
}

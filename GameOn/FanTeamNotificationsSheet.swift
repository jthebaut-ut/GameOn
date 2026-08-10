import SwiftUI

/// Compact per-Team push mute settings (Team Detail → Notifications).
struct FanTeamNotificationsSheet: View {
    let team: FanTeamSummary
    var onMuteChanged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var isMuted: Bool
    @State private var isSaving = false
    @State private var errorText: String?

    private let service = FanTeamsService()

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    init(team: FanTeamSummary, onMuteChanged: @escaping (Bool) -> Void) {
        self.team = team
        self.onMuteChanged = onMuteChanged
        _isMuted = State(initialValue: team.pushNotificationsMuted)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        FanTeamMarkView(
                            sport: team.sport,
                            logoURL: team.logoURL,
                            logoThumbnailURL: team.logoThumbnailURL,
                            colorHex: team.colorHex,
                            size: 52,
                            preferDetailURL: true
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(team.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if !team.sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(team.sport)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    Toggle(
                        L10n.t("fan_teams_mute_push_notifications", languageCode: languageCode),
                        isOn: Binding(
                            get: { isMuted },
                            set: { newValue in
                                guard newValue != isMuted, !isSaving else { return }
                                Task { await commitMuteChange(to: newValue) }
                            }
                        )
                    )
                    .disabled(isSaving)

                    Text(L10n.t("fan_teams_mute_push_helper", languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } footer: {
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.t("fan_teams_notifications_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                }
            }
            .background(colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @MainActor
    private func commitMuteChange(to muted: Bool) async {
        let previous = isMuted
        isMuted = muted
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            let saved = try await service.setNotificationMuted(teamId: team.id, muted: muted)
            isMuted = saved
            onMuteChanged(saved)
        } catch {
            isMuted = previous
            errorText = L10n.t("fan_teams_mute_save_failed", languageCode: languageCode)
        }
    }
}

import SwiftUI

// MARK: - Manager editor leafs (parent-friendly)
// Storage mapping (unchanged backend):
//   Playing Today ON  → FanTeamLineupPlayerStatus.starting
//   Playing Today OFF → FanTeamLineupPlayerStatus.bench
// Visual accent: FanTeamLineupAppearance (FanGeo blue) — never Team color.

/// Compact roster row for the simplified lineup manager list.
struct FanTeamEventLineupManagerRosterRow: View {
    let player: FanTeamLineupPlayerPresentation
    let sportToken: String
    let languageCode: String
    var accent: Color = FanTeamLineupAppearance.accent
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isPlayingToday: Bool {
        player.lineupStatus == .starting
    }

    private var positionBadge: String {
        FanTeamLineupPresentation.displayPositionCode(
            positionCode: player.positionCode,
            sportToken: sportToken
        ) ?? "—"
    }

    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                UserAvatarView(
                    avatarThumbnailURL: player.avatarThumbnailURL,
                    avatarURL: player.avatarURL ?? "",
                    avatarDisplayRefreshToken: .init(),
                    displayName: player.displayName,
                    email: "",
                    size: 44,
                    fallbackStyle: avatarFallback
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    if let number = player.numberLabel {
                        Text(number)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }

                Spacer(minLength: 8)

                Text(positionBadge)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        FanTeamLineupAppearance.softFill(colorScheme, accent: accent),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)

                Text(
                    L10n.t(
                        isPlayingToday
                            ? "fan_team_lineup_playing"
                            : "fan_team_lineup_not_playing",
                        languageCode: languageCode
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isPlayingToday ? accent : FGColor.secondaryText(colorScheme)
                )
                .lineLimit(1)
                .frame(minWidth: 72, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L10n.t("fan_team_lineup_edit_player_a11y", languageCode: languageCode))
    }

    private var accessibilityLabel: String {
        var parts = [player.displayName]
        if let number = player.playerNumber {
            parts.append(
                String(
                    format: L10n.t("fan_teams_player_number_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(number)
                )
            )
        }
        if let code = FanTeamLineupPresentation.displayPositionCode(
            positionCode: player.positionCode,
            sportToken: sportToken
        ) {
            parts.append(code)
        }
        parts.append(
            L10n.t(
                isPlayingToday ? "fan_team_lineup_playing" : "fan_team_lineup_not_playing",
                languageCode: languageCode
            )
        )
        return parts.joined(separator: ", ")
    }
}

/// Small native sheet: position + Playing Today toggle for one roster member.
struct FanTeamEventLineupPlayerQuickEditSheet: View {
    let player: FanTeamLineupPlayerPresentation
    let sportToken: String
    let languageCode: String
    var accent: Color = FanTeamLineupAppearance.accent
    let supportsPositions: Bool
    let teamDefaultPositionCode: String?
    let onSave: (_ playingToday: Bool, _ positionCode: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var playingToday: Bool
    @State private var positionCode: String?
    @State private var showPositionPicker = false

    init(
        player: FanTeamLineupPlayerPresentation,
        sportToken: String,
        languageCode: String,
        accent: Color = FanTeamLineupAppearance.accent,
        supportsPositions: Bool,
        teamDefaultPositionCode: String?,
        onSave: @escaping (_ playingToday: Bool, _ positionCode: String?) -> Void
    ) {
        self.player = player
        self.sportToken = sportToken
        self.languageCode = languageCode
        self.accent = accent
        self.supportsPositions = supportsPositions
        self.teamDefaultPositionCode = teamDefaultPositionCode
        self.onSave = onSave
        _playingToday = State(initialValue: player.lineupStatus == .starting)
        _positionCode = State(initialValue: player.positionCode)
    }

    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    private var positionDisplay: String {
        FanTeamLineupPresentation.displayPositionCode(
            positionCode: positionCode,
            sportToken: sportToken
        ) ?? L10n.t("fan_team_lineup_no_position", languageCode: languageCode)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        UserAvatarView(
                            avatarThumbnailURL: player.avatarThumbnailURL,
                            avatarURL: player.avatarURL ?? "",
                            avatarDisplayRefreshToken: .init(),
                            displayName: player.displayName,
                            email: "",
                            size: 56,
                            fallbackStyle: avatarFallback
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(player.displayName)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            if let number = player.numberLabel {
                                Text(number)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    if supportsPositions {
                        Button {
                            showPositionPicker = true
                        } label: {
                            HStack {
                                Text(L10n.t("fan_teams_position", languageCode: languageCode))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer()
                                Text(positionDisplay)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(FGColor.mutedText(colorScheme))
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(
                            "\(L10n.t("fan_teams_position", languageCode: languageCode)), \(positionDisplay)"
                        )
                    }

                    Toggle(
                        L10n.t("fan_team_lineup_playing_today", languageCode: languageCode),
                        isOn: $playingToday
                    )
                    .tint(accent)
                }
            }
            .listStyle(.insetGrouped)
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("fan_team_lineup_player", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save", languageCode: languageCode)) {
                        onSave(playingToday, positionCode)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .tint(accent)
                }
            }
            .sheet(isPresented: $showPositionPicker) {
                FanTeamSportPositionPickerSheet(
                    sportToken: sportToken,
                    selectedCode: positionCode,
                    onSelect: { code in
                        positionCode = code
                        showPositionPicker = false
                    },
                    teamDefaultCode: teamDefaultPositionCode,
                    clearTitleKey: "fan_team_lineup_clear_position",
                    showsTeamDefaultActions: true
                )
            }
        }
        .presentationDetents([.medium, .large])
    }
}

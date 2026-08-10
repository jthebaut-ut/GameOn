import SwiftUI

/// Team-linked Pickup attendance roster for **this game** (membership + RSVP).
/// Concrete leaf view — keep out of DiscoverScreen / giant detail `@ViewBuilder` chains.
struct PickupTeamAttendanceRosterSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let pickupGameId: UUID

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var roster: PickupGameRosterPayload? {
        viewModel.pickupGameRosterByGameId[pickupGameId]
    }

    private var rows: [PickupTeamAttendanceRow] {
        guard let roster else { return [] }
        return PickupTeamAttendancePresentation.rows(from: roster)
    }

    private var counts: (going: Int, maybe: Int, noResponse: Int, cantGo: Int)? {
        guard let roster else { return nil }
        return PickupTeamAttendancePresentation.counts(from: roster)
    }

    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    var body: some View {
        NavigationStack {
            Group {
                if let roster {
                    attendanceList(roster)
                } else if viewModel.pickupGameRosterInFlightGameIds.contains(pickupGameId) {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = viewModel.pickupGameRosterErrorByGameId[pickupGameId], !err.isEmpty {
                    ContentUnavailableView(
                        L10n.t("pickup_detail_whos_going", languageCode: languageCode),
                        systemImage: "person.3",
                        description: Text(err)
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task {
                            await viewModel.loadPickupGameRoster(pickupGameId: pickupGameId, force: true)
                        }
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("pickup_detail_whos_going", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                }
            }
            .task(id: pickupGameId) {
                await viewModel.loadPickupGameRoster(pickupGameId: pickupGameId, force: true)
            }
            .onChange(of: viewModel.pickupOrganizerRequestsSyncGeneration) { _, _ in
                Task { await viewModel.refreshPickupGameRoster(pickupGameId: pickupGameId) }
            }
        }
    }

    @ViewBuilder
    private func attendanceList(_ roster: PickupGameRosterPayload) -> some View {
        let attendanceRows = PickupTeamAttendancePresentation.rows(from: roster)
        let counts = PickupTeamAttendancePresentation.counts(from: roster)

        List {
            Section {
                Text(summaryLine(counts: counts))
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(summaryAccessibilityLabel(counts: counts))
            }

            Section {
                if attendanceRows.isEmpty {
                    Text(L10n.t("pickup_detail_nobody_in_group", languageCode: languageCode))
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(attendanceRows) { row in
                        attendanceRow(row)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private func attendanceRow(_ row: PickupTeamAttendanceRow) -> some View {
        let member = row.member
        let handle = FanTeamRosterRowPresentation.parentheticalHandle(username: member.username)
        let isYou = member.user_id == viewModel.currentUserAuthId
        let statusTitle = L10n.t(row.category.aggregateTitleKey(), languageCode: languageCode)
        let identity = FanTeamRosterRowPresentation.identityLine(
            displayName: member.resolvedDisplayName,
            username: member.username
        )

        return Button {
            viewModel.presentPublicProfile(
                userId: member.user_id,
                context: "pickup_team_attendance",
                isSelfPreview: isYou
            )
        } label: {
            HStack(spacing: 12) {
                UserAvatarView(
                    avatarThumbnailURL: member.avatar_thumbnail_url,
                    avatarURL: member.avatar_url ?? "",
                    avatarDisplayRefreshToken: .init(),
                    displayName: member.resolvedDisplayName,
                    email: "",
                    size: 40,
                    fallbackStyle: avatarFallback,
                    imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(member.resolvedDisplayName)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                        if let handle {
                            Text("(\(handle))")
                                .font(FGTypography.caption.weight(.medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                        }
                        if isYou {
                            Text(L10n.t("pickup_attendance_you", languageCode: languageCode))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(FGColor.accentGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.12),
                                    in: Capsule(style: .continuous)
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(statusTitle)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(statusForeground(row.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        statusForeground(row.category).opacity(colorScheme == .dark ? 0.20 : 0.12),
                        in: Capsule(style: .continuous)
                    )
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isYou
                ? "\(identity), \(L10n.t("pickup_attendance_you", languageCode: languageCode)), \(statusTitle)"
                : "\(identity), \(statusTitle)"
        )
    }

    private func statusForeground(_ category: PickupDetailAttendanceCategory) -> Color {
        switch category {
        case .going:
            return FGColor.accentGreen
        case .maybe:
            return FGColor.intentPlay
        case .noResponse:
            return FGColor.secondaryText(colorScheme)
        case .cantGo:
            return FGColor.dangerRed.opacity(colorScheme == .dark ? 0.85 : 0.78)
        }
    }

    private func summaryLine(counts: (going: Int, maybe: Int, noResponse: Int, cantGo: Int)) -> String {
        var parts = [
            "\(counts.going) \(L10n.t("Going", languageCode: languageCode))",
            "\(counts.maybe) \(L10n.t("Maybe", languageCode: languageCode))",
            "\(counts.noResponse) \(L10n.t("pickup_detail_no_response", languageCode: languageCode))"
        ]
        if counts.cantGo > 0 {
            parts.append(
                "\(counts.cantGo) \(L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode))"
            )
        }
        return parts.joined(separator: " · ")
    }

    private func summaryAccessibilityLabel(
        counts: (going: Int, maybe: Int, noResponse: Int, cantGo: Int)
    ) -> String {
        var parts: [String] = []
        if counts.going > 0 {
            parts.append("\(counts.going) \(L10n.t("Going", languageCode: languageCode))")
        }
        if counts.maybe > 0 {
            parts.append("\(counts.maybe) \(L10n.t("Maybe", languageCode: languageCode))")
        }
        if counts.noResponse > 0 {
            parts.append(
                "\(counts.noResponse) \(L10n.t("pickup_detail_no_response", languageCode: languageCode))"
            )
        }
        if counts.cantGo > 0 {
            parts.append(
                "\(counts.cantGo) \(L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode))"
            )
        }
        if parts.isEmpty {
            return L10n.t("pickup_detail_whos_going", languageCode: languageCode)
        }
        return "\(L10n.t("pickup_detail_whos_going", languageCode: languageCode)). \(parts.joined(separator: ", "))"
    }
}

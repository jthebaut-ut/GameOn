import SwiftUI

// MARK: - Compact overlapping avatar stack (capacity card)

/// Non-interactive avatar stack for the pickup capacity “Playing” column.
/// The entire Playing column is the hit target — individual avatars are not separately tappable here.
struct PickupPlayingAvatarStack: View {
    let members: [PickupGameRosterMember]
    var maxVisible: Int = PickupGameRosterPresentation.maxVisibleAvatars
    var diameter: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme

    private var uniqueMembers: [PickupGameRosterMember] {
        PickupGameRosterPresentation.uniqueMembersByUserId(members)
    }

    private var visible: [PickupGameRosterMember] {
        Array(uniqueMembers.prefix(maxVisible))
    }

    private var overflow: Int {
        PickupGameRosterPresentation.overflowCount(total: uniqueMembers.count, maxVisible: maxVisible)
    }

    var body: some View {
        if !uniqueMembers.isEmpty {
            HStack(spacing: -diameter * 0.36) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { _, member in
                    UserAvatarView(
                        avatarThumbnailURL: member.avatar_thumbnail_url,
                        avatarURL: member.avatar_url ?? "",
                        avatarDisplayRefreshToken: .init(),
                        displayName: member.resolvedDisplayName,
                        email: "",
                        size: diameter,
                        fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome,
                        imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.7) : nil
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                colorScheme == .dark ? Color.black.opacity(0.35) : Color.white,
                                lineWidth: 1.5
                            )
                    )
                    .accessibilityHidden(true)
                }

                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: max(9, diameter * 0.36), weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: diameter, height: diameter)
                        .background(
                            Circle().fill(FGAdaptiveSurface.controlFill(colorScheme))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    colorScheme == .dark ? Color.black.opacity(0.35) : Color.white,
                                    lineWidth: 1.5
                                )
                        )
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Roster sheet

struct PickupGameRosterSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let pickupGameId: UUID

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var mutatingRequestIds: Set<UUID> = []

    private var roster: PickupGameRosterPayload? {
        viewModel.pickupGameRosterByGameId[pickupGameId]
    }

    private var isOrganizer: Bool {
        roster?.viewer_is_organizer == true
            || (viewModel.currentUserAuthId != nil
                && viewModel.resolvedPickupGameRow(for: pickupGameId)?.creator_user_id == viewModel.currentUserAuthId)
    }

    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    var body: some View {
        NavigationStack {
            Group {
                if let roster {
                    rosterList(roster)
                } else if viewModel.pickupGameRosterInFlightGameIds.contains(pickupGameId) {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = viewModel.pickupGameRosterErrorByGameId[pickupGameId], !err.isEmpty {
                    ContentUnavailableView(
                        "Couldn’t load players",
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
            .navigationTitle("Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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
    private func rosterList(_ roster: PickupGameRosterPayload) -> some View {
        List {
            Section {
                EmptyView()
            } header: {
                Text("\(roster.playingTotal) playing")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .textCase(nil)
            }

            if let organizer = roster.organizer {
                Section {
                    playerRow(organizer, subtitle: "Organizer", showActions: false)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Organizer")
                        .textCase(nil)
                }
            }

            Section {
                if roster.playing.isEmpty {
                    Text("No other players yet")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(Color.clear)
                        .accessibilityLabel("No other players yet")
                } else {
                    ForEach(roster.playing) { member in
                        playerRow(member, subtitle: nil, showActions: false)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            } header: {
                Text("Playing")
                    .textCase(nil)
            }

            if isOrganizer {
                Section {
                    if roster.pending.isEmpty {
                        Text("No pending requests")
                            .font(FGTypography.body)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(roster.pending) { member in
                            playerRow(member, subtitle: nil, showActions: true)
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    Text("Pending")
                        .textCase(nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private func playerRow(
        _ member: PickupGameRosterMember,
        subtitle: String?,
        showActions: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                openProfile(member.user_id)
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
                        Text(member.resolvedDisplayName)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(member.resolvedDisplayName)\(subtitle.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens public profile")

            if showActions, let requestId = member.request_id {
                let busy = mutatingRequestIds.contains(requestId)
                HStack(spacing: 8) {
                    Button {
                        Task { await approve(requestId: requestId) }
                    } label: {
                        Text("Approve")
                            .font(FGTypography.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentGreen)
                    .disabled(busy)

                    Button {
                        Task { await decline(requestId: requestId) }
                    } label: {
                        Text("Decline")
                            .font(FGTypography.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func openProfile(_ userId: UUID) {
        viewModel.presentPublicProfile(
            userId: userId,
            context: "pickup_roster",
            isSelfPreview: userId == viewModel.currentUserAuthId
        )
    }

    @MainActor
    private func approve(requestId: UUID) async {
        guard !mutatingRequestIds.contains(requestId) else { return }
        mutatingRequestIds.insert(requestId)
        defer { mutatingRequestIds.remove(requestId) }
        do {
            try await viewModel.approvePickupJoinRequest(requestId: requestId, pickupGameId: pickupGameId)
            await viewModel.refreshPickupGameRoster(pickupGameId: pickupGameId)
        } catch {
            viewModel.showSocialActionToast(error.localizedDescription, isError: true)
        }
    }

    @MainActor
    private func decline(requestId: UUID) async {
        guard !mutatingRequestIds.contains(requestId) else { return }
        mutatingRequestIds.insert(requestId)
        defer { mutatingRequestIds.remove(requestId) }
        do {
            try await viewModel.rejectPickupJoinRequest(requestId: requestId, pickupGameId: pickupGameId)
            await viewModel.refreshPickupGameRoster(pickupGameId: pickupGameId)
        } catch {
            viewModel.showSocialActionToast(error.localizedDescription, isError: true)
        }
    }
}

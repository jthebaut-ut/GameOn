import SwiftUI

// MARK: - Loading placeholder (first frame when detail is nil)

/// Extremely simple Overview placeholder. No Team cards, formatters, or lookups.
struct FanTeamOverviewLoadingView: View {
    var body: some View {
        let _ = TeamOverviewCrashBisect.mark("loadingViewBody")
        ProgressView()
            .controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 48)
            .accessibilityLabel("Loading")
    }
}

// MARK: - Announcement presentation + carousel

/// Pre-formatted Overview Announcement inputs. No network. No @State. No detail access.
struct FanTeamOverviewAnnouncementPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let message: String?
    let postedText: String
    let postedAt: Date

    /// Newest-first uncleared announcements for Overview carousel.
    ///
    /// Membership rule: when the viewer’s `joinedAt` is known, only announcements
    /// posted at/after join are shown (plus a 60s clock-skew grace). Historical
    /// lifetime Team announcements are not dumped on brand-new members.
    /// Cap keeps Overview light if a Team has a large uncleared backlog.
    static let overviewCarouselLimit = 40

    static func makeAll(
        from detail: FanTeamDetail,
        clearedIds: Set<UUID>,
        viewerUserId: UUID?,
        languageCode: String,
        limit: Int = overviewCarouselLimit
    ) -> [FanTeamOverviewAnnouncementPresentation] {
        TeamOverviewCrashBisect.mark("announcementPresentationBuildStart")
        let viewerJoinedAt = detail.members
            .first(where: { $0.userId == viewerUserId })?
            .joinedAt
        let grace: TimeInterval = 60

        var rows = detail.games.filter {
            $0.gameType == .announcement && $0.status != "cancelled"
        }
        rows.sort { lhs, rhs in
            let l = lhs.createdAt ?? lhs.startsAt
            let r = rhs.createdAt ?? rhs.startsAt
            if l != r { return l > r }
            return lhs.id.uuidString > rhs.id.uuidString
        }

        var presentations: [FanTeamOverviewAnnouncementPresentation] = []
        presentations.reserveCapacity(min(limit, rows.count))

        for announcement in rows {
            if presentations.count >= limit { break }
            if clearedIds.contains(announcement.id) { continue }

            let postedAt = announcement.createdAt ?? announcement.startsAt
            if let viewerJoinedAt, postedAt < viewerJoinedAt.addingTimeInterval(-grace) {
                continue
            }

            let author = detail.members.first(where: { $0.userId == announcement.createdBy })
            let trimmedName = author?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name: String
            if trimmedName.isEmpty {
                let handle = author?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                name = handle.isEmpty
                    ? L10n.t("team_announcement_manager_fallback", languageCode: languageCode)
                    : handle
            } else {
                name = trimmedName
            }
            let when = postedAt.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(Locale(identifier: languageCode))
            )
            let message = announcement.messageBody?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            presentations.append(
                FanTeamOverviewAnnouncementPresentation(
                    id: announcement.id,
                    title: announcement.displayTitle,
                    message: (message?.isEmpty == false) ? message : nil,
                    postedText: "\(name) · \(when)",
                    postedAt: postedAt
                )
            )
        }

        TeamOverviewCrashBisect.mark(
            "announcementPresentationBuildEnd",
            details: "count=\(presentations.count)"
        )
        return presentations
    }

    /// Legacy single-latest helper (tests / diagnostic bisects).
    static func make(
        from detail: FanTeamDetail,
        languageCode: String
    ) -> FanTeamOverviewAnnouncementPresentation? {
        makeAll(
            from: detail,
            clearedIds: [],
            viewerUserId: nil,
            languageCode: languageCode,
            limit: 1
        ).first
    }
}

/// Dumb Overview Announcement card. Clear is separate from open.
struct FanTeamOverviewAnnouncementCardView: View {
    let presentation: FanTeamOverviewAnnouncementPresentation
    let accent: Color
    let languageCode: String
    let showsClear: Bool
    let onOpen: () -> Void
    let onClear: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = TeamOverviewCrashBisect.mark(
            "announcementCardBody",
            details: "id=\(presentation.id.uuidString.lowercased())"
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "megaphone.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(L10n.t("team_announcement_overview_badge", languageCode: languageCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 8)
                if showsClear {
                    Button(action: onClear) {
                        Text(L10n.t("team_announcement_overview_clear", languageCode: languageCode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(FGColor.secondaryText(colorScheme).opacity(0.12))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("team_announcement_overview_clear_a11y", languageCode: languageCode))
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)

                    if let message = presentation.message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(presentation.postedText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Horizontal paging carousel for uncleared Team Overview announcements.
struct FanTeamOverviewAnnouncementCarouselView: View {
    let announcements: [FanTeamOverviewAnnouncementPresentation]
    let accent: Color
    let languageCode: String
    let onOpen: (UUID) -> Void
    let onClear: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIndex: Int = 0
    @State private var pageHeights: [UUID: CGFloat] = [:]

    private var safeIndex: Int {
        FanTeamOverviewAnnouncementCarouselLogic.clampedIndex(
            selectedIndex,
            count: announcements.count
        )
    }

    private var currentHeight: CGFloat {
        guard announcements.indices.contains(safeIndex) else { return 120 }
        let id = announcements[safeIndex].id
        return max(pageHeights[id] ?? 120, 96)
    }

    var body: some View {
        Group {
            if announcements.isEmpty {
                EmptyView()
            } else if announcements.count == 1, let only = announcements.first {
                // Single item: do NOT use page TabView — paging chrome can retain a
                // ghost page / swallow Clear taps when count drops to one or zero.
                singleAnnouncementPage(only)
            } else {
                multiAnnouncementCarousel
            }
        }
        .onChange(of: announcements.map(\.id)) { _, newIds in
            selectedIndex = FanTeamOverviewAnnouncementCarouselLogic.clampedIndex(
                selectedIndex,
                count: newIds.count
            )
            // Drop height cache for removed pages so a reappearing id remeasures.
            let live = Set(newIds)
            pageHeights = pageHeights.filter { live.contains($0.key) }
        }
    }

    @ViewBuilder
    private func singleAnnouncementPage(
        _ item: FanTeamOverviewAnnouncementPresentation
    ) -> some View {
        FanTeamOverviewAnnouncementCardView(
            presentation: item,
            accent: accent,
            languageCode: languageCode,
            showsClear: true,
            onOpen: { onOpen(item.id) },
            onClear: { onClear(item.id) }
        )
        .padding(.horizontal, 16)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pageAccessibilityLabel(index: 0, item: item))
        .accessibilityHint(L10n.t("team_announcement_overview_a11y_hint", languageCode: languageCode))
    }

    private var multiAnnouncementCarousel: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabView(selection: $selectedIndex) {
                ForEach(Array(announcements.enumerated()), id: \.element.id) { index, item in
                    FanTeamOverviewAnnouncementCardView(
                        presentation: item,
                        accent: accent,
                        languageCode: languageCode,
                        showsClear: true,
                        onOpen: { onOpen(item.id) },
                        onClear: { onClear(item.id) }
                    )
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        guard height > 1 else { return }
                        if pageHeights[item.id] != height {
                            pageHeights[item.id] = height
                        }
                    }
                    .tag(index)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(pageAccessibilityLabel(index: index, item: item))
                    .accessibilityHint(
                        L10n.t("team_announcement_overview_swipe_a11y_hint", languageCode: languageCode)
                    )
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Force TabView to drop stale pages when the id set shrinks (incl. → 0 via parent).
            .id(announcements.map(\.id))
            .frame(height: currentHeight)
            .animation(.easeInOut(duration: 0.2), value: currentHeight)

            if announcements.count > 1 {
                positionFooter
                    .padding(.horizontal, 16)
            }
        }
    }

    private var positionFooter: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<announcements.count, id: \.self) { index in
                    Circle()
                        .fill(index == safeIndex ? accent : FGColor.mutedText(colorScheme).opacity(0.35))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
            Text(
                String(
                    format: L10n.t("team_announcement_overview_position_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(safeIndex + 1),
                    Int64(announcements.count)
                )
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .monospacedDigit()
            .accessibilityLabel(
                String(
                    format: L10n.t("team_announcement_overview_position_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(safeIndex + 1),
                    Int64(announcements.count)
                )
            )
        }
    }

    private func pageAccessibilityLabel(
        index: Int,
        item: FanTeamOverviewAnnouncementPresentation
    ) -> String {
        let badge = L10n.t("team_announcement_overview_badge", languageCode: languageCode)
        if announcements.count > 1 {
            let position = String(
                format: L10n.t("team_announcement_overview_position_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(index + 1),
                Int64(announcements.count)
            )
            return "\(badge), \(position), \(item.title)"
        }
        return "\(badge), \(item.title)"
    }
}

/// Pure helpers for carousel selection after clear (unit-tested).
enum FanTeamOverviewAnnouncementCarouselLogic {
    /// Safe TabView selection when the uncleared list shrinks or becomes empty.
    static func clampedIndex(_ selectedIndex: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, selectedIndex), count - 1)
    }

    /// Index to show after clearing `clearedId` from `ids` (newest-first order preserved).
    static func indexAfterClearing(
        clearedId: UUID,
        from ids: [UUID],
        selectedIndex: Int
    ) -> Int {
        guard let clearedAt = ids.firstIndex(of: clearedId) else {
            return clampedIndex(selectedIndex, count: ids.count)
        }
        var next = ids
        next.remove(at: clearedAt)
        if next.isEmpty { return 0 }
        if clearedAt < selectedIndex {
            return clampedIndex(selectedIndex - 1, count: next.count)
        }
        return clampedIndex(selectedIndex, count: next.count)
    }
}

// MARK: - Loaded Overview dashboard (detail already present)

/// Concrete Overview content after `detail` exists. Isolates dashboard AttributeGraph
/// from the fatal `detail == nil` first frame.
struct FanTeamLoadedOverviewView<TeamInfo: View, Extra: View>: View {
    let nextEvent: FanTeamOverviewNextEventPresentation?
    let includesNextEvent: Bool
    let canOrganize: Bool
    let announcements: [FanTeamOverviewAnnouncementPresentation]
    let includesAnnouncement: Bool
    let languageCode: String
    let accent: Color
    let onOpenEvent: (UUID) -> Void
    let onScheduleEvent: () -> Void
    let onOpenAnnouncement: (UUID) -> Void
    let onClearAnnouncement: (UUID) -> Void
    let teamInfo: TeamInfo
    let extra: Extra

    init(
        nextEvent: FanTeamOverviewNextEventPresentation?,
        includesNextEvent: Bool,
        canOrganize: Bool,
        announcements: [FanTeamOverviewAnnouncementPresentation],
        includesAnnouncement: Bool,
        languageCode: String,
        accent: Color,
        onOpenEvent: @escaping (UUID) -> Void,
        onScheduleEvent: @escaping () -> Void,
        onOpenAnnouncement: @escaping (UUID) -> Void,
        onClearAnnouncement: @escaping (UUID) -> Void,
        @ViewBuilder teamInfo: () -> TeamInfo,
        @ViewBuilder extra: () -> Extra
    ) {
        self.nextEvent = nextEvent
        self.includesNextEvent = includesNextEvent
        self.canOrganize = canOrganize
        self.announcements = announcements
        self.includesAnnouncement = includesAnnouncement
        self.languageCode = languageCode
        self.accent = accent
        self.onOpenEvent = onOpenEvent
        self.onScheduleEvent = onScheduleEvent
        self.onOpenAnnouncement = onOpenAnnouncement
        self.onClearAnnouncement = onClearAnnouncement
        self.teamInfo = teamInfo()
        self.extra = extra()
    }

    var body: some View {
        let _ = TeamOverviewCrashBisect.mark(
            "loadedOverviewBody",
            details: "next=\(includesNextEvent) announcement=\(includesAnnouncement) count=\(announcements.count)"
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if includesNextEvent {
                    let _ = TeamOverviewCrashBisect.mark("nextEventSectionRequested")
                    FanTeamOverviewNextEventSectionView(
                        event: nextEvent,
                        canOrganize: canOrganize,
                        languageCode: languageCode,
                        onOpenEvent: onOpenEvent,
                        onScheduleEvent: onScheduleEvent
                    )
                }

                if includesAnnouncement, !announcements.isEmpty {
                    let _ = TeamOverviewCrashBisect.mark("announcementViewRequested")
                    FanTeamOverviewAnnouncementCarouselView(
                        announcements: announcements,
                        accent: accent,
                        languageCode: languageCode,
                        onOpen: onOpenAnnouncement,
                        onClear: onClearAnnouncement
                    )
                }

                let _ = TeamOverviewCrashBisect.mark("teamInfoRequested")
                teamInfo

                extra
            }
            .padding(.vertical, 14)
        }
    }
}

import SwiftUI

/// Schedule root: Live / Watch / Play / Pro Games segments.
///
/// Reuses existing ``LiveScreen`` and ``CalendarScreen`` — no duplicate view models
/// or realtime listeners. Going is a separate root tab (`FollowingScreen`).
struct ScheduleHubView: View {
    @ObservedObject var viewModel: MapViewModel
    let chatViewModel: ChatViewModel
    @Binding var selectedTab: MainTabView.AppTab
    var isScheduleTabSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @SceneStorage("scheduleHubSurface") private var surfaceRaw: String = ScheduleHubSurface.watch.rawValue

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var surface: ScheduleHubSurface {
        ScheduleHubSurface.migrating(rawValue: surfaceRaw)
    }

    private var isBusinessScheduleAccess: Bool {
        viewModel.currentUserIsBusinessAccount
            || viewModel.isVenueOwnerLoggedIn
            || viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var visibleSegments: [ScheduleHubSurface] {
        ScheduleHubSurface.primarySegments(hidingPlay: isBusinessScheduleAccess)
    }

    var body: some View {
        scheduleActiveRoot
            .onAppear {
                migrateLegacyGoingSurfaceIfNeeded()
                reconcileSurfaceWithBusinessAccess()
                syncPublishedSurface()
                consumePendingSurfaceIfNeeded()
            }
            .onChange(of: isScheduleTabSelected) { _, active in
                if active {
                    migrateLegacyGoingSurfaceIfNeeded()
                    syncPublishedSurface()
                    consumePendingSurfaceIfNeeded()
                }
            }
            .onChange(of: viewModel.pendingScheduleHubSurface) { _, _ in
                consumePendingSurfaceIfNeeded()
            }
            .onChange(of: isBusinessScheduleAccess) { _, _ in
                reconcileSurfaceWithBusinessAccess()
            }
            .onChange(of: surfaceRaw) { _, _ in
                migrateLegacyGoingSurfaceIfNeeded()
                syncPublishedSurface()
                applyCalendarFilterIfNeeded()
            }
            .onChange(of: viewModel.calendarTabGameFilter) { _, filter in
                // External deep links / CTAs may set the calendar filter directly.
                guard surface == .watch || surface == .play || surface == .pro else { return }
                let mapped = ScheduleHubSurface.from(calendarFilter: filter)
                if mapped != surface {
                    selectSurface(mapped)
                }
            }
    }

    @ViewBuilder
    private var scheduleActiveRoot: some View {
        VStack(spacing: 0) {
            hubHeader
            hubSegments
                .padding(.top, 4)
                .padding(.bottom, 0)
            hubBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
    }

    private var hubHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            FanGeoPagePurposeHeader(
                title: L10n.t("Schedule", languageCode: languageCode),
                subtitle: ""
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            FanGeoActionCenterHeaderButton()
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 0)
    }

    private var hubSegments: some View {
        GameOnSegmentedControl(
            tabs: visibleSegments.map { segment in
                GameOnSegmentedTab(
                    id: segment,
                    title: L10n.t(segment.segmentTitleKey, languageCode: languageCode),
                    systemImage: segment.systemImage,
                    badge: nil,
                    tint: segment.intentTint,
                    accessibilityLabel: L10n.t(segment.accessibilityLabelKey, languageCode: languageCode)
                )
            },
            selection: Binding(
                get: {
                    if visibleSegments.contains(surface) { return surface }
                    return visibleSegments.first ?? .watch
                },
                set: { selectSurface($0) }
            ),
            animatesSelectionChanges: false,
            titleMinimumScaleFactor: 0.62,
            tabHorizontalPadding: 5
        )
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var hubBody: some View {
        switch surface {
        case .live:
            LiveScreen(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                selectedTab: $selectedTab,
                isLiveSurfaceActive: isScheduleTabSelected,
                suppressesLivePageChrome: true
            )
        case .watch, .play, .pro:
            CalendarScreen(
                viewModel: viewModel,
                selectedTab: $selectedTab,
                isCalendarTabSelected: isScheduleTabSelected,
                suppressesScheduleChrome: true
            )
            .environmentObject(chatViewModel)
        }
    }

    private func selectSurface(_ next: ScheduleHubSurface) {
        var resolved = next
        if isBusinessScheduleAccess, resolved == .play {
            resolved = .watch
        }
        surfaceRaw = resolved.rawValue
        viewModel.scheduleHubSurface = resolved
        applyCalendarFilterIfNeeded()
    }

    private func syncPublishedSurface() {
        viewModel.scheduleHubSurface = surface
        applyCalendarFilterIfNeeded()
    }

    private func applyCalendarFilterIfNeeded() {
        if let filter = surface.calendarFilter {
            if isBusinessScheduleAccess, filter == .pickupGames {
                viewModel.calendarTabGameFilter = .venueGames
            } else {
                viewModel.calendarTabGameFilter = filter
            }
        }
    }

    private func reconcileSurfaceWithBusinessAccess() {
        if isBusinessScheduleAccess, surface == .play {
            selectSurface(.watch)
        }
    }

    private func migrateLegacyGoingSurfaceIfNeeded() {
        guard surfaceRaw == ScheduleHubSurface.legacyGoingRawValue else { return }
        surfaceRaw = ScheduleHubSurface.watch.rawValue
        if viewModel.scheduleHubSurface.rawValue == ScheduleHubSurface.legacyGoingRawValue
            || viewModel.pendingScheduleHubSurface?.rawValue == ScheduleHubSurface.legacyGoingRawValue {
            viewModel.scheduleHubSurface = .watch
            viewModel.pendingScheduleHubSurface = nil
        }
    }

    private func consumePendingSurfaceIfNeeded() {
        guard isScheduleTabSelected, let pending = viewModel.pendingScheduleHubSurface else { return }
        viewModel.pendingScheduleHubSurface = nil
        selectSurface(pending)
    }
}

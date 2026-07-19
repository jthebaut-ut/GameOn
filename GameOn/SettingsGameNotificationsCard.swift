import SwiftUI

struct SettingsGameNotificationsCard: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var notificationSettingsStore: NotificationSettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage("venueFavoriteTeamNearbyNotifications") private var venueFavoriteTeamNearbyNotifications = true
    @AppStorage("pickupGameReminderNotifications") private var pickupGameReminderNotifications = true
    @AppStorage("pickupJoinRequestUpdateNotifications") private var pickupJoinRequestUpdateNotifications = true
    @AppStorage("pickupPlayerJoinedNotifications") private var pickupPlayerJoinedNotifications = true
    @AppStorage("pickupGameChangeNotifications") private var pickupGameChangeNotifications = true
    @AppStorage("gameon.appleCalendar.lastSuccessfulSyncAt.v1") private var calendarLastSyncedAtRaw: Double = 0
    @State private var calendarAccessEnabled = false
    @State private var calendarSyncInFlight = false
    @State private var calendarSyncResultMessage = ""
    @State private var showAppleCalendarSyncDisableConfirmation = false
    @State private var appleCalendarSyncDisableInFlight = false

    private static let fanOnlyNotificationsBusinessToastKey =
        "Watch Spot and pickup notifications are available for Fan accounts."

    private static let fanOnlyCalendarSyncBusinessToastKey =
        "Watch Spot and pickup calendar sync is available for Fan accounts."

    private var fanOnlyNotificationsBusinessToast: String {
        L10n.t(Self.fanOnlyNotificationsBusinessToastKey, languageCode: appLanguageRaw)
    }

    private var fanOnlyCalendarSyncBusinessToast: String {
        L10n.t(Self.fanOnlyCalendarSyncBusinessToastKey, languageCode: appLanguageRaw)
    }

    private var isFanOnlyNotificationsLockedForBusiness: Bool {
        viewModel.isAuthenticatedForSocialFeatures && !viewModel.canUseFanSocialFeatures
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.lg) {
            notificationIntro

            fanGatedNotificationSection(
                title: L10n.t("Watch Spots", languageCode: appLanguageRaw),
                subtitle: L10n.t("notifications_watch_spots_section_subtitle", languageCode: appLanguageRaw),
                systemImage: "sportscourt.fill",
                tint: FGColor.intentWatch
            ) {
                notificationToggle(
                    title: L10n.t("Watch Spot Reminders", languageCode: appLanguageRaw),
                    subtitle: L10n.t("notifications_watch_spot_reminders_subtitle", languageCode: appLanguageRaw),
                    isOn: gameNotificationsEnabledBinding
                )
                .disabled(isFanOnlyNotificationsLockedForBusiness)

                notificationToggle(
                    title: L10n.t("Favorite Team Nearby", languageCode: appLanguageRaw),
                    subtitle: L10n.t("notifications_favorite_team_nearby_subtitle", languageCode: appLanguageRaw),
                    isOn: loggingBinding(
                        key: "venueFavoriteTeamNearbyNotifications",
                        title: L10n.t("Favorite Team Nearby", languageCode: appLanguageRaw),
                        value: $venueFavoriteTeamNearbyNotifications,
                        fanGated: true
                    )
                )
                .disabled(isFanOnlyNotificationsLockedForBusiness)

                if !isFanOnlyNotificationsLockedForBusiness {
                    permissionMessage
                }

                if isFanOnlyNotificationsLockedForBusiness {
                    fanOnlyNotificationSectionHelperText
                }
            }

            fanGatedNotificationSection(
                title: L10n.t("Pickup Games", languageCode: appLanguageRaw),
                subtitle: L10n.t("Pickup games you host, join, or request to join.", languageCode: appLanguageRaw),
                systemImage: "figure.basketball",
                tint: FGColor.intentPlay
            ) {
                notificationToggle(
                    title: L10n.t("Pickup Game Reminders", languageCode: appLanguageRaw),
                    subtitle: L10n.t("FanGeo reminds you before pickup games you host or join.", languageCode: appLanguageRaw),
                    isOn: loggingBinding(
                        key: "pickupGameReminderNotifications",
                        title: L10n.t("Pickup Game Reminders", languageCode: appLanguageRaw),
                        value: $pickupGameReminderNotifications,
                        fanGated: true
                    )
                )
                .disabled(isFanOnlyNotificationsLockedForBusiness)

                notificationToggle(
                    title: L10n.t("Pickup Game Updates", languageCode: appLanguageRaw),
                    subtitle: L10n.t("FanGeo notifies you about join requests, player activity, and game changes.", languageCode: appLanguageRaw),
                    isOn: pickupGameUpdatesBinding
                )
                .disabled(isFanOnlyNotificationsLockedForBusiness)

                if isFanOnlyNotificationsLockedForBusiness {
                    fanOnlyNotificationSectionHelperText
                }
            }

            notificationSection(
                title: L10n.t("pro_sports_games", languageCode: appLanguageRaw),
                subtitle: L10n.t("going_pro_sports_subtitle", languageCode: appLanguageRaw),
                systemImage: "heart.text.square.fill",
                tint: FGColor.intentProGames
            ) {
                proGameNotificationsSettingsSection
            }

            fanGeoAnnouncementNotificationsSection

            calendarIntegrationModule
        }
        .tint(FGColor.accentGreen)
        .task {
            print("[NotificationSettingsDebug] removedSocialFanSection=true")
            print("[NotificationSettingsDebug] appear notifyBeforeGame=\(notificationSettingsStore.notifyBeforeGame) proGameKickoffAlertEnabled=\(notificationSettingsStore.proGameKickoffAlertEnabled) proGameReminderTiming=\(notificationSettingsStore.proGameReminderTiming.rawValue) calendarSync=\(notificationSettingsStore.syncGoingGamesToAppleCalendar)")
            await viewModel.refreshGameNotificationAuthorizationState()
            refreshCalendarAccessState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshCalendarAccessState()
        }
        .confirmationDialog(
            L10n.t("Stop syncing with Apple Calendar?", languageCode: appLanguageRaw),
            isPresented: $showAppleCalendarSyncDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("Keep Existing Events", languageCode: appLanguageRaw)) {
                notificationSettingsStore.syncGoingGamesToAppleCalendar = false
            }
            Button(L10n.t("Remove FanGeo Calendar Events", languageCode: appLanguageRaw), role: .destructive) {
                disableAppleCalendarSyncAndRemoveEvents()
            }
            Button(L10n.t("Cancel", languageCode: appLanguageRaw), role: .cancel) { }
        }
    }

    private var notificationIntro: some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text(L10n.t("FanGeo Notifications", languageCode: appLanguageRaw))
                .font(FGTypography.sectionTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(L10n.t("notifications_intro_body", languageCode: appLanguageRaw))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.xs)
    }

    private var fanGeoAnnouncementNotificationsSection: some View {
        notificationSection(
            title: L10n.t("FanGeo", languageCode: appLanguageRaw),
            subtitle: L10n.t("Important news and updates from FanGeo.", languageCode: appLanguageRaw),
            systemImage: "megaphone.fill",
            tint: FGColor.accentBlue
        ) {
            notificationToggle(
                title: L10n.t("FanGeo Announcements", languageCode: appLanguageRaw),
                subtitle: L10n.t("Show FanGeo announcements in the app and receive push notifications for important updates, major releases, and special events.", languageCode: appLanguageRaw),
                isOn: fanGeoAnnouncementNotificationsBinding
            )
        }
    }

    private var fanGeoAnnouncementNotificationsBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.fanGeoAnnouncementNotificationsEnabled },
            set: { enabled in
                print("[NotificationSettingsDebug] save key=\(FanGeoNotificationPreferenceKeys.announcementNotifications) title=\"FanGeo Announcements\" value=\(enabled)")
                notificationSettingsStore.fanGeoAnnouncementNotificationsEnabled = enabled
            }
        )
    }

    private var calendarIntegrationModule: some View {
        VStack(alignment: .leading, spacing: FGSpacing.lg) {
            calendarIntegrationIntro
            calendarSyncSettingsSection
        }
        .padding(.top, 28)
    }

    private var calendarIntegrationIntro: some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text(L10n.t("Apple Calendar Integration", languageCode: appLanguageRaw))
                .font(FGTypography.sectionTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(L10n.t("Automatically sync your FanGeo games and events with your Apple Calendar. Calendar reminders are managed by Apple Calendar, not FanGeo notifications.", languageCode: appLanguageRaw))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.xs)
    }

    private var calendarSyncSettingsSection: some View {
        FGCard {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 28, height: 28)
                    .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 12) {
                notificationToggle(
                    title: L10n.t("Sync to Apple Calendar", languageCode: appLanguageRaw),
                    subtitle: L10n.t("Automatically add FanGeo games and events to Apple Calendar.", languageCode: appLanguageRaw),
                    isOn: appleCalendarSyncEnabledBinding
                )

                notificationToggle(
                    title: L10n.t("pro_sports_games", languageCode: appLanguageRaw),
                    subtitle: L10n.t("going_pro_sports_subtitle", languageCode: appLanguageRaw),
                    isOn: loggingBinding(
                        key: "syncSavedProGamesToAppleCalendar",
                        title: L10n.t("pro_sports_games", languageCode: appLanguageRaw),
                        value: Binding(
                            get: { notificationSettingsStore.syncSavedProGamesToAppleCalendar },
                            set: { notificationSettingsStore.syncSavedProGamesToAppleCalendar = $0 }
                        )
                    )
                )
                .disabled(!notificationSettingsStore.syncGoingGamesToAppleCalendar)
                .opacity(notificationSettingsStore.syncGoingGamesToAppleCalendar ? 1 : 0.45)

                fanCalendarGatedInteractable {
                    notificationToggle(
                        title: L10n.t("Watch Spots", languageCode: appLanguageRaw),
                        subtitle: L10n.t("notifications_calendar_watch_spots_subtitle", languageCode: appLanguageRaw),
                        isOn: loggingBinding(
                            key: "syncVenueGamesToAppleCalendar",
                            title: L10n.t("Watch Spots", languageCode: appLanguageRaw),
                            value: Binding(
                                get: { notificationSettingsStore.syncVenueGamesToAppleCalendar },
                                set: { notificationSettingsStore.syncVenueGamesToAppleCalendar = $0 }
                            ),
                            fanGated: true
                        )
                    )
                    .disabled(fanCalendarRowDisabled(syncEnabled: notificationSettingsStore.syncGoingGamesToAppleCalendar))
                    .opacity(fanCalendarRowOpacity(syncEnabled: notificationSettingsStore.syncGoingGamesToAppleCalendar))
                }

                fanCalendarGatedInteractable {
                    notificationToggle(
                        title: L10n.t("Pickup Games", languageCode: appLanguageRaw),
                        subtitle: L10n.t("Pickup games you host or join.", languageCode: appLanguageRaw),
                        isOn: loggingBinding(
                            key: "syncPickupGamesToAppleCalendar",
                            title: L10n.t("Pickup Games", languageCode: appLanguageRaw),
                            value: Binding(
                                get: { notificationSettingsStore.syncPickupGamesToAppleCalendar },
                                set: { notificationSettingsStore.syncPickupGamesToAppleCalendar = $0 }
                            ),
                            fanGated: true
                        )
                    )
                    .disabled(fanCalendarRowDisabled(syncEnabled: notificationSettingsStore.syncGoingGamesToAppleCalendar))
                    .opacity(fanCalendarRowOpacity(syncEnabled: notificationSettingsStore.syncGoingGamesToAppleCalendar))
                }

                if isFanOnlyNotificationsLockedForBusiness {
                    fanOnlyNotificationSectionHelperText
                }

                Divider()
                    .padding(.leading, FGSpacing.md)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Calendar Reminder Timing", languageCode: appLanguageRaw))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                    Text(L10n.t("Apple Calendar event reminders, not FanGeo push notifications.", languageCode: appLanguageRaw))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, 2)

                calendarAlertPreferenceRow(
                    title: L10n.t("pro_sports_games", languageCode: appLanguageRaw),
                    selection: proCalendarAlertTimingBinding,
                    isEnabled: appleCalendarDependentControlsEnabled
                )

                Divider()
                    .padding(.leading, FGSpacing.md)

                fanCalendarGatedInteractable {
                    calendarAlertPreferenceRow(
                        title: L10n.t("Watch Spots", languageCode: appLanguageRaw),
                        selection: venueCalendarAlertTimingBinding,
                        isEnabled: appleCalendarDependentControlsEnabled,
                        fanGated: true
                    )
                }

                Divider()
                    .padding(.leading, FGSpacing.md)

                fanCalendarGatedInteractable {
                    calendarAlertPreferenceRow(
                        title: L10n.t("Pickup Games", languageCode: appLanguageRaw),
                        selection: pickupCalendarAlertTimingBinding,
                        isEnabled: appleCalendarDependentControlsEnabled,
                        fanGated: true
                    )
                }

                Divider()
                    .padding(.leading, FGSpacing.md)

                calendarSyncStatusRow(
                    title: calendarAccessEnabled
                        ? L10n.t("Calendar Access: Enabled", languageCode: appLanguageRaw)
                        : L10n.t("Calendar Access Required", languageCode: appLanguageRaw),
                    subtitle: calendarAccessEnabled
                        ? L10n.t("FanGeo can write events to Apple Calendar.", languageCode: appLanguageRaw)
                        : L10n.t("Allow calendar access to sync saved games and events.", languageCode: appLanguageRaw),
                    systemImage: calendarAccessEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: calendarAccessEnabled ? FGColor.accentGreen : Color.orange
                )

                Divider()
                    .padding(.leading, FGSpacing.md)

                calendarSyncStatusRow(
                    title: L10n.t("Last Synced", languageCode: appLanguageRaw),
                    subtitle: calendarLastSyncedText,
                    systemImage: "clock.arrow.circlepath",
                    tint: FGColor.accentBlue
                )

                if !calendarSyncResultMessage.isEmpty {
                    Text(localizedCalendarSyncResultMessage(calendarSyncResultMessage))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(calendarSyncResultMessageLooksSuccessful ? FGColor.accentGreen : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, FGSpacing.md)
                }

                Button {
                    if calendarSyncButtonShowsOpenSettings {
                        openAppSettingsForCalendarAccess()
                    } else {
                        runSettingsCalendarSync()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if calendarSyncInFlight {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: calendarSyncButtonIconName)
                                .font(.caption.weight(.black))
                        }
                        Text(calendarSyncButtonTitle)
                            .font(FGTypography.caption.weight(.black))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(calendarSyncButtonForegroundColor)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, 10)
                    .background(
                        calendarSyncButtonBackgroundColor,
                        in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!calendarSyncButtonIsInteractive)
                .opacity(calendarSyncButtonIsInteractive ? 1 : 0.45)
                .accessibilityLabel(calendarSyncButtonTitle)
                .padding(.horizontal, FGSpacing.md)
                .padding(.bottom, 10)
            }
            .padding(.top, 10)
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
        }
    }

    private func calendarSyncStatusRow(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
    }

    private var appleCalendarDependentControlsEnabled: Bool {
        notificationSettingsStore.syncGoingGamesToAppleCalendar
    }

    private var calendarSyncButtonShowsOpenSettings: Bool {
        appleCalendarDependentControlsEnabled && !calendarAccessEnabled
    }

    private var calendarSyncButtonIsInteractive: Bool {
        guard !calendarSyncInFlight, !appleCalendarSyncDisableInFlight else { return false }
        return appleCalendarDependentControlsEnabled
    }

    private var calendarSyncButtonTitle: String {
        if calendarSyncInFlight {
            return L10n.t("Syncing Calendar...", languageCode: appLanguageRaw)
        }
        if !appleCalendarDependentControlsEnabled {
            return L10n.t("Sync Calendar", languageCode: appLanguageRaw)
        }
        if calendarSyncButtonShowsOpenSettings {
            return L10n.t("Open Settings", languageCode: appLanguageRaw)
        }
        return L10n.t("Sync Calendar", languageCode: appLanguageRaw)
    }

    private var calendarSyncButtonIconName: String {
        if calendarSyncButtonShowsOpenSettings {
            return "gearshape.fill"
        }
        return "arrow.triangle.2.circlepath"
    }

    private var calendarSyncButtonBackgroundColor: Color {
        if !appleCalendarDependentControlsEnabled {
            return Color.gray.opacity(colorScheme == .dark ? 0.35 : 0.28)
        }
        if calendarSyncButtonShowsOpenSettings {
            return Color.orange
        }
        return FGColor.accentGreen
    }

    private var calendarSyncButtonForegroundColor: Color {
        if !appleCalendarDependentControlsEnabled {
            return FGColor.mutedText(colorScheme)
        }
        return Color.white
    }

    private var calendarLastSyncedText: String {
        guard calendarLastSyncedAtRaw > 0 else {
            return L10n.t("Not synced yet", languageCode: appLanguageRaw)
        }
        let date = Date(timeIntervalSince1970: calendarLastSyncedAtRaw)
        let locale = Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw))
        if Calendar.current.isDateInToday(date) {
            let timeText = calendarSyncTimeFormatter(locale: locale).string(from: date)
            return String(
                format: L10n.t("notifications_calendar_synced_today_at_format", languageCode: appLanguageRaw),
                timeText
            )
        }
        return calendarSyncDateTimeFormatter(locale: locale).string(from: date)
    }

    private func localizedCalendarSyncResultMessage(_ message: String) -> String {
        switch message {
        case "Calendar synced":
            return L10n.t("Calendar synced", languageCode: appLanguageRaw)
        case "Removed FanGeo calendar events":
            return L10n.t("Removed FanGeo calendar events", languageCode: appLanguageRaw)
        case "No FanGeo calendar events found":
            return L10n.t("No FanGeo calendar events found", languageCode: appLanguageRaw)
        case "Calendar permission needed":
            return L10n.t("Calendar permission needed", languageCode: appLanguageRaw)
        default:
            return message
        }
    }

    private var calendarSyncResultMessageLooksSuccessful: Bool {
        switch calendarSyncResultMessage {
        case "Calendar synced", "Removed FanGeo calendar events", "No FanGeo calendar events found":
            return true
        default:
            return false
        }
    }

    private var appleCalendarSyncEnabledBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.syncGoingGamesToAppleCalendar },
            set: { enabled in
                print("[NotificationSettingsDebug] save key=syncGoingGamesToAppleCalendar value=\(enabled)")
                if enabled {
                    enableAppleCalendarSync()
                } else if notificationSettingsStore.syncGoingGamesToAppleCalendar {
                    showAppleCalendarSyncDisableConfirmation = true
                }
            }
        )
    }

    private func enableAppleCalendarSync() {
        Task { @MainActor in
            let granted = await viewModel.requestCalendarAccess()
            refreshCalendarAccessState()
            if granted {
                notificationSettingsStore.syncGoingGamesToAppleCalendar = true
                calendarSyncResultMessage = ""
            } else {
                notificationSettingsStore.syncGoingGamesToAppleCalendar = false
                calendarSyncResultMessage = "Calendar permission needed"
            }
        }
    }

    private func disableAppleCalendarSyncAndRemoveEvents() {
        guard !appleCalendarSyncDisableInFlight else { return }
        appleCalendarSyncDisableInFlight = true
        notificationSettingsStore.syncGoingGamesToAppleCalendar = false
        calendarSyncResultMessage = ""
        Task { @MainActor in
            let message = await viewModel.removeAllFanGeoAppleCalendarEvents()
            calendarSyncResultMessage = message
            appleCalendarSyncDisableInFlight = false
        }
    }

    private func refreshCalendarAccessState() {
        calendarAccessEnabled = viewModel.appleCalendarAccessEnabledForSettings()
    }

    private func runSettingsCalendarSync() {
        guard !calendarSyncInFlight else { return }
        calendarSyncInFlight = true
        calendarSyncResultMessage = ""
        Task { @MainActor in
            let message = await viewModel.syncAppleCalendarFromSettings()
            calendarSyncResultMessage = message
            calendarAccessEnabled = viewModel.appleCalendarAccessEnabledForSettings()
            if message == "Calendar synced" {
                calendarLastSyncedAtRaw = Date().timeIntervalSince1970
            }
            calendarSyncInFlight = false
        }
    }

    private func openAppSettingsForCalendarAccess() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func calendarSyncTimeFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private func calendarSyncDateTimeFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private var gameNotificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.notifyBeforeGame },
            set: { enabled in
                guard !isFanOnlyNotificationsLockedForBusiness else { return }
                print("[NotificationSettingsDebug] save key=notifyBeforeGame value=\(enabled)")
                Task { await viewModel.setGameNotificationsEnabled(enabled) }
            }
        )
    }

    private var fanOnlyNotificationSectionHelperText: some View {
        Text(L10n.t("Available for Fan accounts.", languageCode: appLanguageRaw))
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FGSpacing.md)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private func fanGatedNotificationSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let section = notificationSection(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint,
            content: content
        )

        if isFanOnlyNotificationsLockedForBusiness {
            Button {
                viewModel.showSocialActionToast(fanOnlyNotificationsBusinessToast, isError: false)
            } label: {
                section
            }
            .buttonStyle(.plain)
            .opacity(0.48)
        } else {
            section
        }
    }

    private static let proGameLiveMatchCoverageLine =
        "⚽ Soccer • 🏀 Basketball • 🏈 Football • ⚾ Baseball • 🏒 Hockey"

    private var proGameNotificationsSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                proGameNotificationGroupHeader(L10n.t("pro_sports_games", languageCode: appLanguageRaw), isFirst: true)

                proGameMatchReminderTimingRow(
                    title: L10n.t("Pre-Game Reminder", languageCode: appLanguageRaw),
                    subtitle: L10n.t("FanGeo reminds you before your saved game begins.", languageCode: appLanguageRaw),
                    selection: proGameGameReminderTimingBinding
                )

                Divider()
                    .padding(.leading, FGSpacing.md)

                proGameLiveMatchAlertsToggle

                Divider()
                    .padding(.leading, FGSpacing.md)

                notificationToggle(
                    title: L10n.t("Final Score", languageCode: appLanguageRaw),
                    subtitle: L10n.t("FanGeo sends the final score when your saved game ends.", languageCode: appLanguageRaw),
                    isOn: proGameFinalScoreAlertsBinding
                )
            }

            Divider()
                .padding(.leading, FGSpacing.md)
                .padding(.vertical, FGSpacing.xs)

            VStack(alignment: .leading, spacing: 0) {
                proGameNotificationGroupHeader(L10n.t("Favorite Teams", languageCode: appLanguageRaw))

                proGameMatchReminderTimingRow(
                    title: L10n.t("Pre-Game Reminder", languageCode: appLanguageRaw),
                    subtitle: L10n.t("FanGeo reminds you before your favorite team plays.", languageCode: appLanguageRaw),
                    selection: favoriteTeamProGameReminderTimingBinding,
                    options: ProGameReminderTiming.favoriteTeamPickerOptions
                )

                Divider()
                    .padding(.leading, FGSpacing.md)

                notificationToggle(
                    title: L10n.t("Favorite Team Alerts", languageCode: appLanguageRaw),
                    subtitle: L10n.t("FanGeo sends match start, live score, and final score alerts for your favorite teams—even if you haven't saved the game.", languageCode: appLanguageRaw),
                    isOn: favoriteTeamProGameAlertsBinding
                )
            }

            permissionMessage
                .padding(.top, 4)
        }
    }

    private func proGameNotificationGroupHeader(_ title: String, isFirst: Bool = false) -> some View {
        Text(title)
            .font(FGTypography.caption.weight(.bold))
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FGSpacing.md)
            .padding(.top, isFirst ? FGSpacing.sm : FGSpacing.xs)
            .padding(.bottom, FGSpacing.xs)
    }

    // TODO(ProGameNotifications): Wire Live Match Alerts to a true master toggle (kickoff + per-game score_alerts)
    // once backend mapping supports goals, halftime, and cards from Settings.
    private var proGameLiveMatchAlertsToggle: some View {
        Toggle(isOn: proGameKickoffAlertBinding) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Live Match Alerts", languageCode: appLanguageRaw))
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t("FanGeo sends kickoff, live score, halftime/intermission, and other live match alerts for your saved games.", languageCode: appLanguageRaw))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Live coverage:", languageCode: appLanguageRaw))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                    Text(Self.proGameLiveMatchCoverageLine)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .accessibilityLabel(L10n.t("Live Match Alerts", languageCode: appLanguageRaw))
        .accessibilityValue(
            proGameKickoffAlertBinding.wrappedValue
                ? L10n.t("On", languageCode: appLanguageRaw)
                : L10n.t("Off", languageCode: appLanguageRaw)
        )
        .accessibilityHint(
            L10n.t("notifications_live_match_alerts_a11y_hint", languageCode: appLanguageRaw)
        )
    }

    private var proGameKickoffAlertBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.proGameKickoffAlertEnabled },
            set: { enabled in
                print("[NotificationSettingsDebug] save key=proGameKickoffAlertEnabled liveMatchAlerts=\(enabled)")
                Task { await viewModel.setProGameKickoffAlertEnabled(enabled) }
            }
        )
    }

    private var favoriteTeamProGameAlertsBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.favoriteTeamProGameAlertsEnabled },
            set: { enabled in
                print("[NotificationSettingsDebug] save key=favoriteTeamProGameAlertsEnabled value=\(enabled)")
                Task {
                    await viewModel.setFavoriteTeamProGameAlertsEnabled(
                        enabled,
                        games: viewModel.favoriteTeamProGames,
                        reason: "settingsProTeamAlertsToggle"
                    )
                }
            }
        )
    }

    private var favoriteTeamProGameReminderTimingBinding: Binding<ProGameReminderTiming> {
        Binding(
            get: { notificationSettingsStore.favoriteTeamProGameReminderTiming },
            set: { timing in
                print("[NotificationSettingsDebug] save key=favoriteTeamProGameReminderTiming value=\(timing.rawValue)")
                Task { await viewModel.setFavoriteTeamProGameReminderTiming(timing) }
            }
        )
    }

    private var proGameGameReminderTimingBinding: Binding<ProGameReminderTiming> {
        Binding(
            get: { notificationSettingsStore.proGameReminderTiming },
            set: { timing in
                print("[NotificationSettingsDebug] save key=proGameReminderTiming value=\(timing.rawValue)")
                Task { await viewModel.setProGameGameReminderTiming(timing) }
            }
        )
    }

    @ViewBuilder
    private func proGameMatchReminderTimingRow(
        title: String,
        subtitle: String,
        selection: Binding<ProGameReminderTiming>,
        options: [ProGameReminderTiming] = ProGameReminderTiming.pickerOptions
    ) -> some View {
        let timingColor = FGColor.accentYellow
        let chevronColor = FGColor.mutedText(colorScheme)

        Menu {
            ForEach(options) { timing in
                Button {
                    selection.wrappedValue = timing
                } label: {
                    let name = localizedReminderTimingName(timing)
                    if selection.wrappedValue == timing {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            proGameGameReminderTimingRowLabel(
                title: title,
                subtitle: subtitle,
                timingName: localizedReminderTimingName(selection.wrappedValue),
                timingColor: timingColor,
                chevronColor: chevronColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(localizedReminderTimingName(selection.wrappedValue))")
    }

    private func proGameGameReminderTimingRowLabel(
        title: String,
        subtitle: String,
        timingName: String,
        timingColor: Color,
        chevronColor: Color
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: FGSpacing.md)

            HStack(spacing: 6) {
                Text(timingName)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(timingColor)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(chevronColor)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var proGameFinalScoreAlertsBinding: Binding<Bool> {
        proGameNotificationPreferenceBinding(
            key: ProGameNotificationPreferenceKeys.finalScoreAlerts,
            title: L10n.t("Final Score", languageCode: appLanguageRaw),
            get: { notificationSettingsStore.proGameFinalScoreNotifications },
            set: { enabled in
                Task { await viewModel.setProGameFinalScoreNotificationsEnabled(enabled) }
            }
        )
    }

    private func proGameNotificationPreferenceBinding(
        key: String,
        title: String,
        get: @escaping () -> Bool,
        set: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: get,
            set: { enabled in
                print("[NotificationSettingsDebug] save key=\(key) title=\"\(title)\" value=\(enabled)")
                set(enabled)
            }
        )
    }

    private var venueCalendarAlertTimingBinding: Binding<FanGeoCalendarAlertTiming> {
        calendarAlertTimingBinding(
            key: "venue_calendar_alert_timing",
            get: { notificationSettingsStore.venueCalendarAlertTiming },
            set: { notificationSettingsStore.venueCalendarAlertTiming = $0 },
            fanGated: true
        )
    }

    private var pickupCalendarAlertTimingBinding: Binding<FanGeoCalendarAlertTiming> {
        calendarAlertTimingBinding(
            key: "pickup_calendar_alert_timing",
            get: { notificationSettingsStore.pickupCalendarAlertTiming },
            set: { notificationSettingsStore.pickupCalendarAlertTiming = $0 },
            fanGated: true
        )
    }

    private var proCalendarAlertTimingBinding: Binding<FanGeoCalendarAlertTiming> {
        calendarAlertTimingBinding(
            key: "pro_calendar_alert_timing",
            get: { notificationSettingsStore.proCalendarAlertTiming },
            set: { notificationSettingsStore.proCalendarAlertTiming = $0 }
        )
    }

    private func calendarAlertTimingBinding(
        key: String,
        get: @escaping () -> FanGeoCalendarAlertTiming,
        set: @escaping (FanGeoCalendarAlertTiming) -> Void,
        fanGated: Bool = false
    ) -> Binding<FanGeoCalendarAlertTiming> {
        Binding(
            get: get,
            set: { timing in
                guard !fanGated || !isFanOnlyNotificationsLockedForBusiness else { return }
                print("[NotificationSettingsDebug] save key=\(key) value=\(timing.rawValue)")
                set(timing)
                if notificationSettingsStore.syncGoingGamesToAppleCalendar {
                    Task { await viewModel.syncFanGeoAttendingEventsToAppleCalendar(reason: "calendarAlertTimingChanged", forceBypassFreshness: true) }
                }
            }
        )
    }

    private var pickupGameUpdatesBinding: Binding<Bool> {
        Binding(
            get: {
                pickupJoinRequestUpdateNotifications
                    || pickupPlayerJoinedNotifications
                    || pickupGameChangeNotifications
            },
            set: { enabled in
                guard !isFanOnlyNotificationsLockedForBusiness else { return }
                print("[NotificationSettingsDebug] save key=pickupGameUpdates value=\(enabled)")
                pickupJoinRequestUpdateNotifications = enabled
                pickupPlayerJoinedNotifications = enabled
                pickupGameChangeNotifications = enabled
            }
        )
    }

    @ViewBuilder
    private var permissionMessage: some View {
        if !notificationSettingsStore.notificationPermissionMessage.isEmpty {
            Text(notificationSettingsStore.notificationPermissionMessage)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, FGSpacing.md)
                .padding(.bottom, FGSpacing.xs)
        }
    }

    private func loggingBinding(
        key: String,
        title: String,
        value: Binding<Bool>,
        fanGated: Bool = false
    ) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue },
            set: { enabled in
                guard !fanGated || !isFanOnlyNotificationsLockedForBusiness else { return }
                print("[NotificationSettingsDebug] save key=\(key) title=\"\(title)\" value=\(enabled)")
                value.wrappedValue = enabled
            }
        )
    }

    private func fanCalendarRowOpacity(syncEnabled: Bool) -> Double {
        if isFanOnlyNotificationsLockedForBusiness { return 0.48 }
        return syncEnabled ? 1 : 0.45
    }

    private func fanCalendarRowDisabled(syncEnabled: Bool) -> Bool {
        isFanOnlyNotificationsLockedForBusiness || !syncEnabled
    }

    @ViewBuilder
    private func fanCalendarGatedInteractable<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isFanOnlyNotificationsLockedForBusiness {
            Button {
                viewModel.showSocialActionToast(fanOnlyCalendarSyncBusinessToast, isError: false)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private func notificationSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        FGCard {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                content()
            }
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
        }
    }

    private func notificationToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func calendarAlertPreferenceRow(
        title: String,
        selection: Binding<FanGeoCalendarAlertTiming>,
        isEnabled: Bool,
        fanGated: Bool = false
    ) -> some View {
        let businessLocked = fanGated && isFanOnlyNotificationsLockedForBusiness
        let rowEnabled = isEnabled && !businessLocked
        let timingColor = rowEnabled ? FGColor.accentGreen : FGColor.mutedText(colorScheme)
        let chevronColor = rowEnabled ? FGColor.mutedText(colorScheme) : FGColor.mutedText(colorScheme).opacity(0.45)
        let rowOpacity: Double = businessLocked ? 0.48 : (isEnabled ? 1 : 0.45)

        Group {
            if rowEnabled {
                Menu {
                    ForEach(FanGeoCalendarAlertTiming.allCases) { timing in
                        Button {
                            selection.wrappedValue = timing
                        } label: {
                            let name = localizedCalendarAlertTimingName(timing)
                            if selection.wrappedValue == timing {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    calendarAlertPreferenceRowLabel(
                        title: title,
                        timingName: localizedCalendarAlertTimingName(selection.wrappedValue),
                        timingColor: timingColor,
                        chevronColor: chevronColor,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            } else {
                calendarAlertPreferenceRowLabel(
                    title: title,
                    timingName: localizedCalendarAlertTimingName(selection.wrappedValue),
                    timingColor: timingColor,
                    chevronColor: chevronColor,
                    showsChevron: false
                )
            }
        }
        .disabled(!rowEnabled)
        .opacity(rowOpacity)
        .accessibilityLabel(
            "\(title) \(L10n.t("Apple Calendar reminder", languageCode: appLanguageRaw)) \(localizedCalendarAlertTimingName(selection.wrappedValue))"
        )
    }

    private func localizedReminderTimingName(_ timing: ProGameReminderTiming) -> String {
        L10n.t(timing.localizationKey, languageCode: appLanguageRaw)
    }

    private func localizedCalendarAlertTimingName(_ timing: FanGeoCalendarAlertTiming) -> String {
        L10n.t(timing.localizationKey, languageCode: appLanguageRaw)
    }

    private func calendarAlertPreferenceRowLabel(
        title: String,
        timingName: String,
        timingColor: Color,
        chevronColor: Color,
        showsChevron: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            Text(title)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Spacer(minLength: FGSpacing.md)

            HStack(spacing: 6) {
                Text(timingName)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(timingColor)
                    .lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(chevronColor)
                }
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

}

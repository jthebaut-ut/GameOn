import Foundation
import UserNotifications

extension MapViewModel {
    private static var proGameReminderVerboseLogging = false
    private static let proGameReminderBatchDeferDelayNs: UInt64 = 1_500_000_000
    private static let proGameReminderPreferenceBatchDeferDelayNs: UInt64 = 500_000_000
    private static let proGameReminderBatchCoalesceInterval: TimeInterval = 45

    private var gameReminderService: GameReminderNotificationService {
        GameReminderNotificationService.shared
    }

    func refreshGameNotificationAuthorizationState() async {
        await notificationSettingsStore.refreshGameNotificationAuthorizationState()
    }

    func setGameNotificationsEnabled(_ enabled: Bool) async {
        if await notificationSettingsStore.setGameNotificationsEnabled(enabled) {
            await rescheduleAvailableGameReminders(reason: "settingsEnabled")
        }
    }

    func setProGameKickoffAlertEnabled(_ enabled: Bool) async {
        await cancelAllProGameKickoffAlerts()
        if await notificationSettingsStore.setProGameKickoffAlertEnabled(enabled), enabled {
            await rescheduleAvailableProGameKickoffAlerts(reason: "kickoffAlertEnabled")
        }
        await syncProGameFinalScorePreferenceToBackend(reason: "proGameKickoffAlertToggle")
    }

    func setProGameFinalScoreNotificationsEnabled(_ enabled: Bool) async {
        guard await notificationSettingsStore.setProGameFinalScoreNotificationsEnabled(enabled) else { return }
        await syncProGameFinalScorePreferenceToBackend(reason: "settingsToggle")
    }

    func setProGameGameReminderTiming(_ timing: ProGameReminderTiming) async {
        guard proGameReminderTiming != timing else { return }

        await cancelAllProGamePreKickoffReminders()
        guard await notificationSettingsStore.setProGameGameReminderTiming(timing) else { return }

        if timing.schedulesKickoffReminder {
            await rescheduleAvailableProGamePreKickoffReminders(reason: "gameReminderTimingChanged")
        }
        await syncProGameFinalScorePreferenceToBackend(reason: "proGameGameReminderTimingChanged")
    }

    func setFavoriteTeamProGameReminderTiming(_ timing: ProGameReminderTiming) async {
        guard favoriteTeamProGameReminderTiming != timing else { return }

        await gameReminderService.cancelAllFavoriteTeamProGamePreKickoffReminders()
        guard await notificationSettingsStore.setFavoriteTeamProGameReminderTiming(timing) else { return }

        await reconcileFavoriteTeamProGameReminders(reason: "favoriteTeamGameReminderTimingChanged")
    }

    func gameReminderPreferenceDidChange() async {
        print("[NotificationSettingsDebug] save reminderPreference notifyBeforeGame=\(notifyBeforeGame) proGameKickoffAlertEnabled=\(proGameKickoffAlertEnabled) proGameReminderTiming=\(proGameReminderTiming.rawValue) reminderMinutesBefore=\(reminderMinutesBefore) repeatGameReminder=\(repeatGameReminder) repeatEveryMinutes=\(repeatEveryMinutes)")
        print("[NotificationDebug] reminderPreference=\(reminderMinutesBefore)")
        if notifyBeforeGame {
            await rescheduleAvailableGameReminders(reason: "preferenceChanged")
        }
    }

    func proGameReminderPreferenceDidChange() async {
        print("[NotificationSettingsDebug] save proGameKickoffAlertEnabled=\(proGameKickoffAlertEnabled) proGameReminderTiming=\(proGameReminderTiming.rawValue)")
        await cancelAllProGameKickoffAlerts()
        await cancelAllProGamePreKickoffReminders()
        proGameReminderLastScheduledFingerprintByGame.removeAll()
        proGameReminderLastBatchFingerprint = ""
        scheduleDeferredSavedProGameReminderReconcile(
            reason: "preferenceChanged",
            force: true,
            delayNanoseconds: Self.proGameReminderPreferenceBatchDeferDelayNs
        )
    }

    func scheduleGameReminderIfPossible(venueEventID: UUID) async {
        guard notifyBeforeGame else { return }
        guard let event = gameReminderNotificationEvent(for: venueEventID) else { return }
        await gameReminderService.scheduleReminder(
            for: event,
            reminderMinutesBefore: reminderMinutesBefore,
            repeatUntilStart: repeatGameReminder,
            repeatEveryMinutes: repeatEveryMinutes
        )
    }

    func cancelGameReminder(venueEventID: UUID) async {
        await gameReminderService.cancelReminder(eventId: venueEventID)
    }

    func rescheduleGameReminderIfPossible(venueEventID: UUID) async {
        print("[NotificationDebug] rescheduleReminder eventId=\(venueEventID.uuidString)")
        guard notifyBeforeGame else {
            await cancelGameReminder(venueEventID: venueEventID)
            return
        }
        await scheduleGameReminderIfPossible(venueEventID: venueEventID)
    }

    func reconcileGameRemindersAfterFollowingRefresh() async {
        guard notifyBeforeGame else { return }
        await rescheduleAvailableGameReminders(reason: "followingRefresh")
    }

    func reconcileGameRemindersForLoadedVenueEvents() async {
        guard notifyBeforeGame else { return }
        let visibleGoingIDs = venueEventRows.compactMap(\.id).filter { venueEventInterestIDs.contains($0) }
        for eventID in visibleGoingIDs {
            await rescheduleGameReminderIfPossible(venueEventID: eventID)
        }
    }

    func scheduleProGameNotificationsIfPossible(_ savedGame: SavedProGame) async {
        _ = await refreshSavedProGameReminderSchedulesIfNeeded(savedGame, force: true)
    }

    func scheduleProGameReminderIfPossible(_ savedGame: SavedProGame) async {
        await scheduleProGameNotificationsIfPossible(savedGame)
    }

    func cancelProGameNotificationSchedules(savedGameIdentifier: String) async {
        await gameReminderService.cancelProGameReminder(identifier: savedGameIdentifier)
    }

    func cancelProGameReminder(savedGameIdentifier: String) async {
        await cancelProGameNotificationSchedules(savedGameIdentifier: savedGameIdentifier)
    }

    func cancelAllProGameKickoffAlerts() async {
        await gameReminderService.cancelAllProGameKickoffAlerts()
    }

    func cancelAllProGamePreKickoffReminders() async {
        await gameReminderService.cancelAllProGamePreKickoffReminders()
    }

    func cancelAllProGameReminders() async {
        await gameReminderService.cancelAllProGameReminders()
    }

    func reconcileSavedProGameReminders(reason: String) async {
        scheduleDeferredSavedProGameReminderReconcile(reason: reason)
    }

    func scheduleDeferredSavedProGameReminderReconcile(
        reason: String,
        force: Bool = false,
        delayNanoseconds: UInt64 = 1_500_000_000
    ) {
        proGameReminderPendingReconcileReason = reason
        proGameReminderDeferredReconcileTask?.cancel()
        proGameReminderDeferredReconcileTask = Task { @MainActor [weak self] in
            await Task.yield()
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.performSavedProGameReminderBatchReconcile(
                reason: self.proGameReminderPendingReconcileReason ?? reason,
                force: force
            )
            self.proGameReminderDeferredReconcileTask = nil
        }
    }

    private func performSavedProGameReminderBatchReconcile(reason: String, force: Bool) async {
        let startedAt = Date()
        let games = savedProGames
        let batchFingerprint = proGameReminderBatchFingerprint(for: games)

        if !force,
           let lastBatchAt = proGameReminderLastBatchAt,
           Date().timeIntervalSince(lastBatchAt) < Self.proGameReminderBatchCoalesceInterval,
           batchFingerprint == proGameReminderLastBatchFingerprint {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[ProGameReminderPerf] batch games=\(games.count) skipped=\(games.count) scheduled=0 durationMs=\(ms) reason=coalescedUnchanged")
            return
        }

        guard await gameReminderService.beginBatchScheduling() else {
            gameReminderService.endBatchScheduling()
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[ProGameReminderPerf] batch games=\(games.count) skipped=\(games.count) scheduled=0 durationMs=\(ms) reason=permissionDenied")
            return
        }
        defer { gameReminderService.endBatchScheduling() }

        let currentKeys = Set(games.map(\.stableKey))
        for (gameKey, _) in proGameReminderLastScheduledFingerprintByGame where !currentKeys.contains(gameKey) {
            await cancelProGameNotificationSchedules(savedGameIdentifier: gameKey)
            proGameReminderLastScheduledFingerprintByGame.removeValue(forKey: gameKey)
        }

        var skipped = 0
        var scheduled = 0
        for savedGame in games {
            if await refreshSavedProGameReminderSchedulesIfNeeded(savedGame, force: force) {
                scheduled += 1
            } else {
                skipped += 1
            }
        }

        proGameReminderLastBatchFingerprint = batchFingerprint
        proGameReminderLastBatchAt = Date()
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[ProGameReminderPerf] batch games=\(games.count) skipped=\(skipped) scheduled=\(scheduled) durationMs=\(ms) reason=\(reason)")
    }

    private func proGameReminderGlobalSettingsFingerprint() -> String {
        [
            proGameKickoffAlertEnabled ? "kickoffOn" : "kickoffOff",
            proGameGameReminderEnabled ? "reminderOn" : "reminderOff",
            proGameReminderTiming.rawValue,
            proGameReminderTiming.reminderMinutesBefore.map(String.init) ?? "nil"
        ].joined(separator: "|")
    }

    private func proGameReminderScheduleFingerprint(for savedGame: SavedProGame) -> String {
        [
            savedGame.stableKey,
            String(Int(savedGame.startTime.timeIntervalSince1970)),
            proGameReminderGlobalSettingsFingerprint()
        ].joined(separator: "|")
    }

    private func proGameReminderBatchFingerprint(for games: [SavedProGame]) -> String {
        [
            proGameReminderGlobalSettingsFingerprint(),
            games.map { proGameReminderScheduleFingerprint(for: $0) }.sorted().joined(separator: ";")
        ].joined(separator: "||")
    }

    @discardableResult
    private func refreshSavedProGameReminderSchedulesIfNeeded(
        _ savedGame: SavedProGame,
        force: Bool
    ) async -> Bool {
        let fingerprint = proGameReminderScheduleFingerprint(for: savedGame)
        if !force, proGameReminderLastScheduledFingerprintByGame[savedGame.stableKey] == fingerprint {
            return false
        }

        guard savedProGames.contains(where: { $0.stableKey == savedGame.stableKey }) else {
            await cancelProGameNotificationSchedules(savedGameIdentifier: savedGame.stableKey)
            proGameReminderLastScheduledFingerprintByGame.removeValue(forKey: savedGame.stableKey)
            return true
        }

        guard let event = proGameReminderNotificationEvent(for: savedGame) else {
            await cancelProGameNotificationSchedules(savedGameIdentifier: savedGame.stableKey)
            proGameReminderLastScheduledFingerprintByGame[savedGame.stableKey] = fingerprint
            return true
        }

        if proGameKickoffAlertEnabled {
            await gameReminderService.scheduleProGameKickoffAlert(for: event)
        } else {
            await gameReminderService.cancelProGameKickoffAlert(identifier: savedGame.stableKey)
        }

        if proGameGameReminderEnabled, let reminderMinutesBefore = proGameReminderTiming.reminderMinutesBefore {
            await gameReminderService.scheduleProGamePreKickoffReminder(
                for: event,
                userPreference: proGameReminderTiming.rawValue,
                reminderMinutesBefore: reminderMinutesBefore
            )
        } else {
            await gameReminderService.cancelProGamePreKickoffReminder(identifier: savedGame.stableKey)
        }

        proGameReminderLastScheduledFingerprintByGame[savedGame.stableKey] = fingerprint
        return true
    }

    private func rescheduleAvailableGameReminders(reason: String) async {
        let eventIDs = availableGoingVenueEventIDs()
        for eventID in eventIDs {
            print("[NotificationDebug] rescheduleReminder eventId=\(eventID.uuidString) reason=\(reason)")
            await scheduleGameReminderIfPossible(venueEventID: eventID)
        }
    }

    private func rescheduleAvailableProGameKickoffAlerts(reason: String) async {
        await performSavedProGameReminderBatchReconcile(reason: reason, force: true)
    }

    private func rescheduleAvailableProGamePreKickoffReminders(reason: String) async {
        await performSavedProGameReminderBatchReconcile(reason: reason, force: true)
    }

    private func availableGoingVenueEventIDs() -> [UUID] {
        var ids: [UUID] = []
        var seen: Set<UUID> = []

        for item in followingTabGoingItems where item.isServerGoing {
            if seen.insert(item.id).inserted {
                ids.append(item.id)
            }
        }

        for id in venueEventInterestIDs {
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }

        return ids
    }

    private func gameReminderNotificationEvent(for venueEventID: UUID) -> GameReminderNotificationEvent? {
        if let item = followingTabGoingItems.first(where: { $0.id == venueEventID }),
           let startDate = gameReminderStartDate(for: item.venueEvent) {
            return GameReminderNotificationEvent(
                eventId: venueEventID,
                title: item.venueEvent.event_title,
                venueName: item.bar.name,
                startDate: startDate
            )
        }

        guard let row = venueEventRows.first(where: { $0.id == venueEventID }),
              let startDate = gameReminderStartDate(for: row)
        else {
            return nil
        }

        let venueName = row.venue_name ?? bars.first(where: { bar in
            if let venueID = row.venue_id, venueID == bar.id { return true }
            return false
        })?.name

        return GameReminderNotificationEvent(
            eventId: venueEventID,
            title: row.event_title,
            venueName: venueName,
            startDate: startDate
        )
    }

    private func proGameReminderNotificationEvent(for savedGame: SavedProGame) -> ProGameReminderNotificationEvent? {
        let now = Date()
        guard savedGame.startTime > now else {
#if DEBUG
            print("[ProGameReminderDebug] schedulingSkipped gameId=\(savedGame.stableKey) reason=kickoffInPast")
#endif
            return nil
        }

        return ProGameReminderNotificationEvent(
            identifier: savedGame.stableKey,
            awayTeam: savedGame.awayTeam,
            homeTeam: savedGame.homeTeam,
            sport: savedGame.sport,
            startDate: savedGame.startTime
        )
    }

    private func gameReminderStartDate(for row: VenueEventRow) -> Date? {
        if let scheduledStart = parseGameReminderISODate(row.scheduled_start_at) {
            return scheduledStart
        }

        guard let dateString = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dateString.isEmpty
        else {
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        guard let day = dateFormatter.date(from: dateString) else { return nil }

        guard let timeString = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines),
              !timeString.isEmpty,
              !timeString.localizedCaseInsensitiveContains("TBD")
        else {
            return day
        }

        let timeFormats = ["h:mm a", "hh:mm a", "H:mm", "HH:mm"]
        for format in timeFormats {
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = format
            timeFormatter.timeZone = TimeZone.current
            if let time = timeFormatter.date(from: timeString.uppercased()) {
                var dayComponents = Calendar.current.dateComponents([.year, .month, .day], from: day)
                let timeComponents = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
                dayComponents.hour = timeComponents.hour
                dayComponents.minute = timeComponents.minute
                dayComponents.second = timeComponents.second ?? 0
                return Calendar.current.date(from: dayComponents)
            }
        }

        return day
    }

    private func parseGameReminderISODate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    func reconcileFavoriteTeamProGameReminders(
        reason: String,
        previousGames: [FavoriteTeamProGame] = []
    ) async {
        let currentKeys = Set(favoriteTeamProGames.map(\.game.stableKey))

        for item in previousGames where !currentKeys.contains(item.game.stableKey) {
            await gameReminderService.cancelFavoriteTeamProGamePreKickoffReminder(identifier: item.game.stableKey)
#if DEBUG
            print("[FavoriteTeamReminder] skipped reason=removedFromFavoriteTeamWindow game=\(item.game.stableKey)")
#endif
        }

        for item in favoriteTeamProGames {
            await refreshFavoriteTeamProGamePreKickoffReminder(item, reason: reason)
        }
    }

    private func refreshFavoriteTeamProGamePreKickoffReminder(
        _ item: FavoriteTeamProGame,
        reason: String
    ) async {
        let game = item.game
        let gameId = game.stableKey

        if let skipReason = await favoriteTeamPreKickoffReminderSkipReason(for: item) {
#if DEBUG
            print("[FavoriteTeamReminder] skipped reason=\(skipReason) game=\(gameId) trigger=\(reason)")
#endif
            await gameReminderService.cancelFavoriteTeamProGamePreKickoffReminder(identifier: gameId)
            return
        }

#if DEBUG
        print("[FavoriteTeamReminder] eligible game=\(gameId) trigger=\(reason)")
#endif

        guard let event = proGameReminderNotificationEvent(for: game) else {
#if DEBUG
            print("[FavoriteTeamReminder] skipped reason=kickoffInPast game=\(gameId) trigger=\(reason)")
#endif
            await gameReminderService.cancelFavoriteTeamProGamePreKickoffReminder(identifier: gameId)
            return
        }

        guard let reminderMinutesBefore = favoriteTeamProGameReminderTiming.reminderMinutesBefore else { return }

        await gameReminderService.scheduleFavoriteTeamProGamePreKickoffReminder(
            for: event,
            userPreference: favoriteTeamProGameReminderTiming.rawValue,
            reminderMinutesBefore: reminderMinutesBefore
        )
#if DEBUG
        print("[FavoriteTeamReminder] scheduled game=\(gameId) trigger=\(reason)")
#endif
    }

    private func favoriteTeamPreKickoffReminderSkipReason(
        for item: FavoriteTeamProGame
    ) async -> String? {
        guard favoriteTeamProGameReminderEnabled else {
            return "teamMatchReminderNever"
        }
        guard await gameReminderService.canScheduleNotifications() else {
            return "permissionDenied"
        }
        if savedProGames.contains(where: { $0.stableKey == item.game.stableKey }) {
            return "savedGameOwnsReminder"
        }
        guard item.game.startTime > Date() else {
            return "notUpcoming"
        }
        return nil
    }
}

import Foundation
import UserNotifications

struct GameReminderNotificationEvent {
    let eventId: UUID
    let title: String?
    let venueName: String?
    let startDate: Date
}

struct ProGameReminderNotificationEvent {
    let identifier: String
    let awayTeam: String
    let homeTeam: String
    let sport: String
    let startDate: Date
}

struct ProGameFinalNotificationEvent {
    let identifier: String
    let body: String
    let awayTeam: String
    let homeTeam: String
    let snapshot: FanGeoProGameInboxSnapshot?
}

struct ProGameHalftimeNotificationEvent {
    let identifier: String
    let body: String
    let awayTeam: String
    let homeTeam: String
    let snapshot: FanGeoProGameInboxSnapshot?
}

struct ProGamePredictionResultNotificationEvent {
    let identifier: String
    let body: String
    let awayTeam: String
    let homeTeam: String
}

struct ProGameScoreUpdateNotificationEvent {
    let identifier: String
    let scoreToken: String
    let title: String
    let body: String
    let awayTeam: String
    let homeTeam: String
    let snapshot: FanGeoProGameInboxSnapshot?
}

struct ProGameScoreCorrectionNotificationEvent {
    let identifier: String
    let correctionToken: String
    let title: String
    let body: String
    let awayTeam: String
    let homeTeam: String
}

struct ProGameCardNotificationEvent {
    let identifier: String
    let eventKey: String
    let title: String
    let body: String
    let awayTeam: String
    let homeTeam: String
    let cardType: LiveCardEventType
}

final class GameReminderNotificationService {
    static let shared = GameReminderNotificationService()

    private let center: UNUserNotificationCenter
    private let identifierPrefix = "fangeo.gameReminder."
    private let proGameIdentifierPrefix = "fangeo.proGameReminder."
    private let favoriteTeamProGameReminderPrefix = "fangeo.favoriteTeamProGameReminder."
    private let proGameKickoffAlertPrefix = "fangeo.proGameKickoffAlert."
    private let pickupCreatorRatingIdentifierPrefix = "fangeo.pickupCreatorRating."
    private let proGameFinalIdentifierPrefix = "fangeo.proGameFinal."
    private let proGameHalftimeIdentifierPrefix = "fangeo.proGameHalftime."
    private let proGamePredictionResultIdentifierPrefix = "fangeo.proGamePredictionResult."
    private let proGameScoreUpdateIdentifierPrefix = "fangeo.proGameScoreUpdate."
    private let proGameScoreCorrectionIdentifierPrefix = "fangeo.proGameScoreCorrection."
    private let proGameCardNotificationIdentifierPrefix = "fangeo.proGameCard."

    private var batchSchedulingAuthorizationAllowed: Bool?

    private init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func beginBatchScheduling() async -> Bool {
        let allowed = await requestAuthorizationIfNeeded()
        batchSchedulingAuthorizationAllowed = allowed
        return allowed
    }

    func endBatchScheduling() {
        batchSchedulingAuthorizationAllowed = nil
    }

    private func authorizationForScheduling() async -> Bool {
        if let allowed = batchSchedulingAuthorizationAllowed {
            return allowed
        }
        return await requestAuthorizationIfNeeded()
    }

    private func logProGameScheduling(_ message: @autoclosure () -> String) {
#if DEBUG
        DebugLogGate.proGameReminderVerbose(message())
#endif
    }

    private func logProGameSchedulingFailure(_ message: @autoclosure () -> String) {
#if DEBUG
        DebugLogGate.notificationWarning(message())
#endif
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let status = await center.notificationSettings().authorizationStatus
#if DEBUG
        DebugLogGate.proGameReminderVerbose(
            "[NotificationDebug] authorizationStatus=\(Self.authorizationStatusDescription(status))"
        )
#endif
        return status
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let status = await authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            await PushNotificationRegistrationService.shared.registerForRemoteNotificationsIfAuthorized(reason: "alreadyAuthorized")
            return true
        case .denied:
            DebugLogGate.notificationWarning("[NotificationDebug] permissionDenied=true")
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let updatedStatus = await authorizationStatus()
                let allowed = granted && Self.isAllowedStatus(updatedStatus)
                if !allowed {
                    DebugLogGate.notificationWarning("[NotificationDebug] permissionDenied=true")
                } else {
                    await PushNotificationRegistrationService.shared.registerForRemoteNotificationsIfAuthorized(reason: "permissionGranted")
                }
                return allowed
            } catch {
                DebugLogGate.notificationWarning("[NotificationDebug] permissionDenied=\(error.localizedDescription)")
                return false
            }
        @unknown default:
            DebugLogGate.notificationWarning("[NotificationDebug] permissionDenied=unknownStatus")
            return false
        }
    }

    func canScheduleNotifications() async -> Bool {
        Self.isAllowedStatus(await authorizationStatus())
    }

    func scheduleReminder(
        for event: GameReminderNotificationEvent,
        reminderMinutesBefore: Int,
        repeatUntilStart: Bool = false,
        repeatEveryMinutes: Int = 30
    ) async {
        _ = await scheduleReminders(
            for: [event],
            reminderMinutesBefore: reminderMinutesBefore,
            repeatUntilStart: repeatUntilStart,
            repeatEveryMinutes: repeatEveryMinutes
        )
    }

    /// Outcome of one diffed reminder reconciliation pass (DEBUG metrics only).
    struct ReminderScheduleDiffResult {
        var desired = 0
        var alreadyScheduled = 0
        var applied = 0
        var removed = 0
    }

    /// Reconciles venue-game reminders for `events` against what is already pending.
    ///
    /// Identifiers, fire dates, titles, bodies, and sounds are computed exactly as before; the only
    /// change is that an unchanged reminder is left in place instead of being canceled and re-added.
    /// The pending-request snapshot is also read once per pass rather than once per event.
    @discardableResult
    func scheduleReminders(
        for events: [GameReminderNotificationEvent],
        reminderMinutesBefore: Int,
        repeatUntilStart: Bool,
        repeatEveryMinutes: Int
    ) async -> ReminderScheduleDiffResult {
        var result = ReminderScheduleDiffResult()
        guard !events.isEmpty else { return result }

        DebugLogGate.proGameReminderVerbose("[NotificationDebug] reminderPreference=\(reminderMinutesBefore)")

        guard await requestAuthorizationIfNeeded() else {
            DebugLogGate.notificationWarning("[NotificationDebug] permissionDenied=true")
            return result
        }

        let pending = await center.pendingNotificationRequests()
        var pendingByIdentifier: [String: UNNotificationRequest] = [:]
        pendingByIdentifier.reserveCapacity(pending.count)
        for request in pending {
            pendingByIdentifier[request.identifier] = request
        }
        let pendingIdentifiers = Set(pendingByIdentifier.keys)

        var identifiersToRemove: [String] = []
        var requestsToAdd: [UNNotificationRequest] = []

        for event in events {
            DebugLogGate.proGameReminderVerbose(
                "[NotificationDebug] schedulingReminder eventId=\(event.eventId.uuidString)"
            )

            let fireDate = event.startDate.addingTimeInterval(TimeInterval(-reminderMinutesBefore * 60))
            let fireDates = reminderFireDates(
                firstFireDate: fireDate,
                eventStartDate: event.startDate,
                repeatUntilStart: repeatUntilStart,
                repeatEveryMinutes: repeatEveryMinutes
            )

            let baseIdentifier = reminderIdentifier(for: event.eventId)
            var desiredIdentifiers = Set<String>()

            for (index, scheduledDate) in fireDates.enumerated() {
                let identifier = reminderIdentifier(for: event.eventId, repeatIndex: index)
                desiredIdentifiers.insert(identifier)
                result.desired += 1

                let minutesUntilStart = max(1, Int(event.startDate.timeIntervalSince(scheduledDate) / 60))
                let title = "Game starting soon"
                let body = Self.body(for: event, reminderMinutesBefore: minutesUntilStart)
                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: scheduledDate
                )

                if let existing = pendingByIdentifier[identifier],
                   Self.reminderRequestMatches(existing, title: title, body: body, components: components) {
                    result.alreadyScheduled += 1
                    continue
                }

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                requestsToAdd.append(
                    UNNotificationRequest(
                        identifier: identifier,
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    )
                )
            }

            // Drop reminders that are no longer part of the desired schedule for this event.
            for identifier in pendingIdentifiers
            where (identifier == baseIdentifier || identifier.hasPrefix("\(baseIdentifier)."))
                && !desiredIdentifiers.contains(identifier) {
                identifiersToRemove.append(identifier)
            }
        }

        if !identifiersToRemove.isEmpty {
            result.removed = identifiersToRemove.count
            DebugLogGate.proGameReminderVerbose(
                "[NotificationDebug] cancelReminder count=\(identifiersToRemove.count)"
            )
            center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
        }

        for request in requestsToAdd {
            do {
                try await center.add(request)
                result.applied += 1
            } catch {
                DebugLogGate.notificationWarning(
                    "[NotificationDebug] schedulingFailed identifier=\(request.identifier) error=\(error.localizedDescription)"
                )
            }
        }

        return result
    }

    private static func reminderRequestMatches(
        _ request: UNNotificationRequest,
        title: String,
        body: String,
        components: DateComponents
    ) -> Bool {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
              trigger.repeats == false,
              trigger.dateComponents == components else {
            return false
        }
        return request.content.title == title && request.content.body == body
    }

    func cancelReminder(eventId: UUID) async {
        DebugLogGate.proGameReminderVerbose("[NotificationDebug] cancelReminder eventId=\(eventId.uuidString)")
        let baseIdentifier = reminderIdentifier(for: eventId)
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0 == baseIdentifier || $0.hasPrefix("\(baseIdentifier).") }
        center.removePendingNotificationRequests(withIdentifiers: identifiers.isEmpty ? [baseIdentifier] : identifiers)
    }

    func cancelAllGameReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func scheduleProGameKickoffAlert(for event: ProGameReminderNotificationEvent) async {
        let matchupTitle = ProGameNotificationFormatting.matchupTitle(
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "kickoff",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        logProGameScheduling("[ProGameKickoffAlertDebug] gameId=\(event.identifier)")
        logProGameScheduling("[ProGameKickoffAlertDebug] gameStart=\(Self.debugDateString(event.startDate))")
        logProGameScheduling("[ProGameKickoffAlertDebug] title=\"\(matchupTitle)\"")

        guard await authorizationForScheduling() else {
            logProGameSchedulingFailure("[ProGameKickoffAlertDebug] schedulingFailure=permissionDenied")
            return
        }

        let now = Date()
        guard event.startDate > now else {
            logProGameScheduling("[ProGameKickoffAlertDebug] notificationCreated=false reason=kickoffInPast")
            return
        }

        await cancelProGameKickoffAlert(identifier: event.identifier)

        let content = UNMutableNotificationContent()
        content.title = ProGameNotificationFormatting.kickoffHeaderTitle(sport: event.sport)
        content.subtitle = matchupTitle
        content.body = ProGameNotificationFormatting.kickoffStartingBody
        content.sound = .default
        await applyProGameInboxSnapshot(
            FanGeoProGameInboxSnapshot(
                kind: .kickoff,
                matchID: event.identifier,
                homeTeam: event.homeTeam,
                awayTeam: event.awayTeam,
                homeScore: 0,
                awayScore: 0,
                scoringTeam: nil,
                league: nil,
                sport: event.sport,
                matchStatus: "SCHEDULED",
                clock: nil,
                homeBadgeURL: nil,
                awayBadgeURL: nil,
                homeProviderId: nil,
                awayProviderId: nil
            ),
            to: content
        )

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: event.startDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let scheduledIdentifier = proGameKickoffAlertIdentifier(for: event.identifier)
        let request = UNNotificationRequest(
            identifier: scheduledIdentifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            let pending = await center.pendingNotificationRequests()
            let isPending = pending.contains { $0.identifier == scheduledIdentifier }
            logProGameScheduling("[ProGameKickoffAlertDebug] scheduledTime=\(Self.debugDateString(event.startDate))")
            logProGameScheduling("[ProGameKickoffAlertDebug] scheduledIdentifier=\(scheduledIdentifier)")
            logProGameScheduling("[ProGameKickoffAlertDebug] notificationCreated=\(isPending)")
        } catch {
            logProGameSchedulingFailure("[ProGameKickoffAlertDebug] notificationCreated=false error=\(error.localizedDescription)")
        }
    }

    /// One local notification at pickup end time inviting an eligible joiner to rate the organizer.
    func schedulePickupCreatorRatingReminder(
        pickupGameId: UUID,
        fireDate: Date
    ) async {
        guard await authorizationForScheduling() else { return }

        let now = Date()
        guard fireDate > now else { return }

        await cancelPickupCreatorRatingReminder(pickupGameId: pickupGameId)

        let content = UNMutableNotificationContent()
        content.title = "How was your pickup game?"
        content.body = "Don't forget to rate your pickup game experience."
        content.sound = .default
        PickupCreatorRatingNotificationDeepLinkPayload.apply(to: content, pickupGameId: pickupGameId)

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let scheduledIdentifier = pickupCreatorRatingIdentifier(for: pickupGameId)
        let request = UNNotificationRequest(
            identifier: scheduledIdentifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
#if DEBUG
            print("[PickupCreatorRatingReminder] scheduled=true")
#endif
        } catch {
#if DEBUG
            print("[PickupCreatorRatingReminder] scheduled=false error=\(error.localizedDescription)")
#endif
        }
    }

    func cancelPickupCreatorRatingReminder(pickupGameId: UUID) async {
        center.removePendingNotificationRequests(
            withIdentifiers: [pickupCreatorRatingIdentifier(for: pickupGameId)]
        )
        center.removeDeliveredNotifications(
            withIdentifiers: [pickupCreatorRatingIdentifier(for: pickupGameId)]
        )
    }

    func cancelAllPickupCreatorRatingReminders() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(pickupCreatorRatingIdentifierPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        let delivered = await center.deliveredNotifications()
        let deliveredIds = delivered
            .map(\.request.identifier)
            .filter { $0.hasPrefix(pickupCreatorRatingIdentifierPrefix) }
        if !deliveredIds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
        }
    }

    private func pickupCreatorRatingIdentifier(for pickupGameId: UUID) -> String {
        "\(pickupCreatorRatingIdentifierPrefix)\(pickupGameId.uuidString.lowercased())"
    }

    func scheduleProGamePreKickoffReminder(
        for event: ProGameReminderNotificationEvent,
        userPreference: String,
        reminderMinutesBefore: Int,
        repeatUntilStart: Bool = false,
        repeatEveryMinutes: Int = 30
    ) async {
        await scheduleProGamePreKickoffReminder(
            for: event,
            userPreference: userPreference,
            reminderMinutesBefore: reminderMinutesBefore,
            identifierPrefix: proGameIdentifierPrefix,
            debugLabel: "ProGameReminderDebug",
            cancelBeforeSchedule: cancelProGamePreKickoffReminder,
            repeatUntilStart: repeatUntilStart,
            repeatEveryMinutes: repeatEveryMinutes
        )
    }

    func scheduleFavoriteTeamProGamePreKickoffReminder(
        for event: ProGameReminderNotificationEvent,
        userPreference: String,
        reminderMinutesBefore: Int
    ) async {
        await scheduleProGamePreKickoffReminder(
            for: event,
            userPreference: userPreference,
            reminderMinutesBefore: reminderMinutesBefore,
            identifierPrefix: favoriteTeamProGameReminderPrefix,
            debugLabel: "FavoriteTeamReminder",
            cancelBeforeSchedule: cancelFavoriteTeamProGamePreKickoffReminder
        )
    }

    private func scheduleProGamePreKickoffReminder(
        for event: ProGameReminderNotificationEvent,
        userPreference: String,
        reminderMinutesBefore: Int,
        identifierPrefix: String,
        debugLabel: String,
        cancelBeforeSchedule: (String) async -> Void,
        repeatUntilStart: Bool = false,
        repeatEveryMinutes: Int = 30
    ) async {
        let matchupTitle = ProGameNotificationFormatting.matchupTitle(
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "preKickoffReminder",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        logProGameScheduling("[\(debugLabel)] userPreference=\(userPreference)")
        logProGameScheduling("[\(debugLabel)] gameId=\(event.identifier)")
        logProGameScheduling("[\(debugLabel)] gameStart=\(Self.debugDateString(event.startDate))")
        logProGameScheduling("[\(debugLabel)] title=\"\(matchupTitle)\"")

        let permissionBefore = await authorizationStatus()
        logProGameScheduling("[\(debugLabel)] permissionStatus=\(Self.authorizationStatusDescription(permissionBefore))")
        guard await authorizationForScheduling() else {
#if DEBUG
            let permissionAfter = await authorizationStatus()
            logProGameSchedulingFailure("[\(debugLabel)] schedulingFailure=permissionDenied")
            DebugLogGate.proGameReminderVerbose("[\(debugLabel)] notificationCreated=false")
            DebugLogGate.proGameReminderVerbose("[\(debugLabel)] schedulingSuccess=false")
            DebugLogGate.proGameReminderVerbose(
                "[\(debugLabel)] permissionStatus=\(Self.authorizationStatusDescription(permissionAfter))"
            )
#endif
            return
        }

        let fireDate = event.startDate.addingTimeInterval(TimeInterval(-reminderMinutesBefore * 60))

        await cancelBeforeSchedule(event.identifier)

        let fireDates = proGamePreKickoffReminderFireDates(
            preferredFireDate: fireDate,
            eventStartDate: event.startDate
        )

        guard !fireDates.isEmpty else {
            logProGameSchedulingFailure("[\(debugLabel)] schedulingFailure=noFutureFireDate gameId=\(event.identifier)")
            logProGameScheduling("[\(debugLabel)] scheduledTime=none")
            logProGameScheduling("[\(debugLabel)] notificationCreated=false")
            logProGameScheduling("[\(debugLabel)] schedulingSuccess=false")
            return
        }

        for (index, scheduledDate) in fireDates.enumerated() {
            let minutesUntilStart = max(1, Int(event.startDate.timeIntervalSince(scheduledDate) / 60))
            let content = UNMutableNotificationContent()
            content.title = ProGameNotificationFormatting.kickoffHeaderTitle(sport: event.sport)
            content.subtitle = matchupTitle
            content.body = "\(ProGameNotificationFormatting.kickoffLeadBodyPrefix) \(Self.leadDescription(minutes: minutesUntilStart))."
            content.sound = .default
            ProGameNotificationDeepLinkPayload.apply(to: content, matchID: event.identifier)

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: scheduledDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let scheduledIdentifier = proGameReminderIdentifier(
                for: event.identifier,
                repeatIndex: index,
                prefix: identifierPrefix
            )
            let request = UNNotificationRequest(
                identifier: scheduledIdentifier,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
                let pending = await center.pendingNotificationRequests()
                let isPending = pending.contains { $0.identifier == scheduledIdentifier }
                logProGameScheduling("[\(debugLabel)] scheduledTime=\(Self.debugDateString(scheduledDate))")
                logProGameScheduling("[\(debugLabel)] scheduledIdentifier=\(scheduledIdentifier)")
                logProGameScheduling("[\(debugLabel)] notificationCreated=\(isPending)")
                logProGameScheduling("[\(debugLabel)] schedulingSuccess=\(isPending)")
            } catch {
                logProGameSchedulingFailure(
                    "[\(debugLabel)] schedulingFailure=\(error.localizedDescription) gameId=\(event.identifier)"
                )
                logProGameScheduling("[\(debugLabel)] scheduledTime=\(Self.debugDateString(scheduledDate))")
                logProGameScheduling("[\(debugLabel)] scheduledIdentifier=\(scheduledIdentifier)")
                logProGameScheduling("[\(debugLabel)] notificationCreated=false")
                logProGameScheduling("[\(debugLabel)] schedulingSuccess=false")
            }
        }
    }

    func cancelProGamePreKickoffReminder(identifier: String) async {
        await cancelProGamePreKickoffReminder(identifier: identifier, prefix: proGameIdentifierPrefix, debugLabel: "ProGameReminderDebug")
    }

    func cancelFavoriteTeamProGamePreKickoffReminder(identifier: String) async {
        await cancelProGamePreKickoffReminder(identifier: identifier, prefix: favoriteTeamProGameReminderPrefix, debugLabel: "FavoriteTeamReminder")
    }

    private func cancelProGamePreKickoffReminder(identifier: String, prefix: String, debugLabel: String) async {
#if DEBUG
        DebugLogGate.proGameReminderVerbose("[\(debugLabel)] cancelReminder gameId=\(identifier)")
#endif
        let baseIdentifier = proGameReminderIdentifier(for: identifier, prefix: prefix)
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0 == baseIdentifier || $0.hasPrefix("\(baseIdentifier).") }
        center.removePendingNotificationRequests(withIdentifiers: identifiers.isEmpty ? [baseIdentifier] : identifiers)
#if DEBUG
        DebugLogGate.proGameReminderVerbose(
            "[\(debugLabel)] canceledIdentifiers=\((identifiers.isEmpty ? [baseIdentifier] : identifiers).joined(separator: ","))"
        )
#endif
    }

    func cancelAllFavoriteTeamProGamePreKickoffReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(favoriteTeamProGameReminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelProGameKickoffAlert(identifier: String) async {
        DebugLogGate.proGameReminderVerbose("[ProGameKickoffAlertDebug] cancelAlert gameId=\(identifier)")
        let scheduledIdentifier = proGameKickoffAlertIdentifier(for: identifier)
        center.removePendingNotificationRequests(withIdentifiers: [scheduledIdentifier])
    }

    func cancelAllProGamePreKickoffReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(proGameIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelAllProGameKickoffAlerts() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(proGameKickoffAlertPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelProGameReminder(identifier: String) async {
        await cancelProGamePreKickoffReminder(identifier: identifier)
        await cancelProGameKickoffAlert(identifier: identifier)
    }

    func cancelAllProGameReminders() async {
        await cancelAllProGamePreKickoffReminders()
        await cancelAllProGameKickoffAlerts()
    }

    func scheduleProGameReminder(
        for event: ProGameReminderNotificationEvent,
        userPreference: String,
        reminderMinutesBefore: Int,
        repeatUntilStart: Bool = false,
        repeatEveryMinutes: Int = 30
    ) async {
        await scheduleProGamePreKickoffReminder(
            for: event,
            userPreference: userPreference,
            reminderMinutesBefore: reminderMinutesBefore,
            repeatUntilStart: repeatUntilStart,
            repeatEveryMinutes: repeatEveryMinutes
        )
    }

    func cancelProGameFinalNotification(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [proGameFinalIdentifier(for: identifier)])
    }

    func cancelProGameScoreUpdateNotifications(identifier: String) async {
        let baseIdentifier = proGameScoreUpdateIdentifierPrefix + identifier
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(baseIdentifier) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        await cancelProGameScoreCorrectionNotifications(identifier: identifier)
    }

    func cancelProGameScoreCorrectionNotifications(identifier: String) async {
        let baseIdentifier = proGameScoreCorrectionIdentifierPrefix + identifier
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(baseIdentifier) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func scheduleProGameFinalNotification(for event: ProGameFinalNotificationEvent) async {
        print("[ProGameNotificationDebug] schedulingFinal id=\(event.identifier)")
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "final",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )

        guard await requestAuthorizationIfNeeded() else {
            print("[ProGameNotificationDebug] finalPermissionDenied=true")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = ProGameNotificationFormatting.finalScoreTitle
        content.body = event.body
        content.sound = .default
        await applyProGameInboxSnapshot(event.snapshot, to: content)

        let identifier = proGameFinalIdentifier(for: event.identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] finalSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func scheduleProGameHalftimeNotification(for event: ProGameHalftimeNotificationEvent) async {
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "halftime",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = ProGameNotificationFormatting.halftimeTitle
        content.body = event.body
        content.sound = .default
        await applyProGameInboxSnapshot(event.snapshot, to: content)

        let identifier = proGameHalftimeIdentifier(for: event.identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] halftimeSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func scheduleProGamePredictionResultNotification(for event: ProGamePredictionResultNotificationEvent) async {
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "predictionResult",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = ProGameNotificationFormatting.predictionResultTitle
        content.body = event.body
        content.sound = .default

        let identifier = proGamePredictionResultIdentifier(for: event.identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] predictionResultSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func cancelProGameHalftimeNotification(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [proGameHalftimeIdentifier(for: identifier)])
    }

    func cancelProGamePredictionResultNotification(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [proGamePredictionResultIdentifier(for: identifier)])
    }

    func scheduleProGameScoreUpdateNotification(for event: ProGameScoreUpdateNotificationEvent) async {
        print("[ProGameNotificationDebug] schedulingScoreUpdate id=\(event.identifier) score=\(event.scoreToken)")
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "score",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )

        guard await requestAuthorizationIfNeeded() else {
            print("[ProGameNotificationDebug] scoreUpdatePermissionDenied=true")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        await applyProGameInboxSnapshot(event.snapshot, to: content)

        let request = UNNotificationRequest(
            identifier: proGameScoreUpdateIdentifier(for: event.identifier, scoreToken: event.scoreToken),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] scoreUpdateSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func scheduleProGameScoreCorrectionNotification(for event: ProGameScoreCorrectionNotificationEvent) async {
        print("[ProGameNotificationDebug] schedulingScoreCorrection id=\(event.identifier) score=\(event.correctionToken)")
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "scoreCorrection",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )

        guard await requestAuthorizationIfNeeded() else {
            print("[ProGameNotificationDebug] scoreCorrectionPermissionDenied=true")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        ProGameNotificationDeepLinkPayload.apply(to: content, matchID: event.identifier)

        let request = UNNotificationRequest(
            identifier: proGameScoreCorrectionIdentifier(for: event.identifier, correctionToken: event.correctionToken),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] scoreCorrectionSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func scheduleProGameCardNotification(for event: ProGameCardNotificationEvent) async {
        print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=pending dedupeHit=false")
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "card",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam,
            scoringTeam: nil
        )

        guard await requestAuthorizationIfNeeded() else {
            print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=false dedupeHit=false reason=permissionDenied")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: proGameCardNotificationIdentifier(for: event.identifier, eventKey: event.eventKey),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
            print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=true dedupeHit=false")
        } catch {
            print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=false dedupeHit=false error=\(error.localizedDescription)")
        }
    }

    private func applyProGameInboxSnapshot(
        _ snapshot: FanGeoProGameInboxSnapshot?,
        to content: UNMutableNotificationContent
    ) async {
        let matchID = snapshot?.matchID
        if let matchID, !matchID.isEmpty {
            ProGameNotificationDeepLinkPayload.apply(to: content, matchID: matchID)
        }
        guard let snapshot else { return }
        var merged = content.userInfo
        for (key, value) in snapshot.userInfoFields() {
            merged[key] = value
        }
        if let artwork = FanGeoPushArtworkSelection.from(snapshot: snapshot) {
            FanGeoPushArtwork.merge(
                FanGeoPushArtwork.fields(url: artwork.url, kind: artwork.kind),
                into: &merged
            )
        }
        content.userInfo = merged
        await FanGeoPushArtworkAttachment.apply(to: content, userInfo: content.userInfo)
    }

    private func reminderIdentifier(for eventId: UUID) -> String {
        "\(identifierPrefix)\(eventId.uuidString.lowercased())"
    }

    private func reminderIdentifier(for eventId: UUID, repeatIndex: Int) -> String {
        let base = reminderIdentifier(for: eventId)
        return repeatIndex == 0 ? base : "\(base).repeat\(repeatIndex)"
    }

    private func proGameReminderIdentifier(for identifier: String) -> String {
        proGameReminderIdentifier(for: identifier, prefix: proGameIdentifierPrefix)
    }

    private func proGameReminderIdentifier(for identifier: String, repeatIndex: Int) -> String {
        proGameReminderIdentifier(for: identifier, repeatIndex: repeatIndex, prefix: proGameIdentifierPrefix)
    }

    private func proGameReminderIdentifier(for identifier: String, prefix: String) -> String {
        "\(prefix)\(identifier)"
    }

    private func proGameReminderIdentifier(for identifier: String, repeatIndex: Int, prefix: String) -> String {
        let base = proGameReminderIdentifier(for: identifier, prefix: prefix)
        return repeatIndex == 0 ? base : "\(base).repeat\(repeatIndex)"
    }

    private func proGameFinalIdentifier(for identifier: String) -> String {
        "\(proGameFinalIdentifierPrefix)\(identifier)"
    }

    private func proGameHalftimeIdentifier(for identifier: String) -> String {
        "\(proGameHalftimeIdentifierPrefix)\(identifier)"
    }

    private func proGamePredictionResultIdentifier(for identifier: String) -> String {
        "\(proGamePredictionResultIdentifierPrefix)\(identifier)"
    }

    private func proGameScoreUpdateIdentifier(for identifier: String, scoreToken: String) -> String {
        "\(proGameScoreUpdateIdentifierPrefix)\(identifier).\(scoreToken)"
    }

    private func proGameScoreCorrectionIdentifier(for identifier: String, correctionToken: String) -> String {
        "\(proGameScoreCorrectionIdentifierPrefix)\(identifier).\(correctionToken)"
    }

    private func proGameCardNotificationIdentifier(for identifier: String, eventKey: String) -> String {
        let sanitizedKey = eventKey
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(proGameCardNotificationIdentifierPrefix)\(identifier).\(sanitizedKey)"
    }

    private func reminderFireDates(
        firstFireDate: Date,
        eventStartDate: Date,
        repeatUntilStart: Bool,
        repeatEveryMinutes: Int
    ) -> [Date] {
        let now = Date()
        guard firstFireDate < eventStartDate else { return [] }
        guard repeatUntilStart else {
            guard firstFireDate > now else { return [] }
            DebugLogGate.proGameReminderVerbose(
                "[NotificationDebug] scheduledFireDate=\(Self.debugDateString(firstFireDate))"
            )
            return [firstFireDate]
        }

        let step = max(1, repeatEveryMinutes)
        var dates: [Date] = []
        var next = firstFireDate
        while next < eventStartDate {
            if next > now {
                DebugLogGate.proGameReminderVerbose(
                    "[NotificationDebug] scheduledFireDate=\(Self.debugDateString(next))"
                )
                dates.append(next)
            }
            guard let advanced = Calendar.current.date(byAdding: .minute, value: step, to: next) else {
                break
            }
            next = advanced
        }
        return dates
    }

    private func proGameKickoffAlertIdentifier(for identifier: String) -> String {
        "\(proGameKickoffAlertPrefix)\(identifier)"
    }

    private func proGamePreKickoffReminderFireDates(
        preferredFireDate: Date,
        eventStartDate: Date
    ) -> [Date] {
        let now = Date()
        guard eventStartDate > now else { return [] }
        guard preferredFireDate < eventStartDate, preferredFireDate > now else { return [] }
#if DEBUG
        DebugLogGate.proGameReminderVerbose(
            "[ProGameReminderDebug] reminderDate=\(Self.debugDateString(preferredFireDate))"
        )
#endif
        return [preferredFireDate]
    }

    private func proGameReminderFireDates(
        preferredFireDate: Date,
        eventStartDate: Date,
        repeatUntilStart: Bool,
        repeatEveryMinutes: Int
    ) -> [Date] {
        let now = Date()
        guard eventStartDate > now else { return [] }

        guard repeatUntilStart else {
            let fireDate = preferredFireDate > now ? preferredFireDate : eventStartDate
#if DEBUG
            DebugLogGate.proGameReminderVerbose(
                "[ProGameReminderDebug] reminderDate=\(Self.debugDateString(fireDate))"
            )
#endif
            return [fireDate]
        }

        let step = max(1, repeatEveryMinutes)
        var dates: [Date] = []
        var next = preferredFireDate
        while next < eventStartDate {
            if next > now {
#if DEBUG
                DebugLogGate.proGameReminderVerbose(
                    "[ProGameReminderDebug] reminderDate=\(Self.debugDateString(next))"
                )
#endif
                dates.append(next)
            }
            guard let advanced = Calendar.current.date(byAdding: .minute, value: step, to: next) else {
                break
            }
            next = advanced
        }
        if dates.isEmpty || (dates.last ?? .distantPast) < eventStartDate {
#if DEBUG
            DebugLogGate.proGameReminderVerbose(
                "[ProGameReminderDebug] reminderDate=\(Self.debugDateString(eventStartDate))"
            )
#endif
            dates.append(eventStartDate)
        }
        return dates
    }

    private static func isAllowedStatus(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private static func authorizationStatusDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func body(
        for event: GameReminderNotificationEvent,
        reminderMinutesBefore: Int
    ) -> String {
        let lead = leadDescription(minutes: reminderMinutesBefore)
        if let title = cleaned(event.title) {
            let formattedTitle = ProGameNotificationFormatting.formatTextContainingTeamNames(title)
            return "\(formattedTitle) starts in \(lead)."
        }
        if let venueName = cleaned(event.venueName) {
            return "Your game at \(venueName) starts in \(lead)."
        }
        return "Your game starts in \(lead)."
    }

    private static func leadDescription(minutes: Int) -> String {
        if minutes == 1440 { return "1 day" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) days" }
        if minutes == 60 { return "1 hour" }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        if minutes == 1 { return "1 minute" }
        return "\(minutes) minutes"
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func debugDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }
}

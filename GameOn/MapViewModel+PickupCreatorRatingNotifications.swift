import Foundation
import UserNotifications

extension MapViewModel {
    /// Matches Settings `@AppStorage("pickupGameReminderNotifications")` default (`true`).
    private static let pickupGameReminderNotificationsDefaultsKey = "pickupGameReminderNotifications"

    var isPickupGameReminderNotificationsEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.pickupGameReminderNotificationsDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.pickupGameReminderNotificationsDefaultsKey)
    }

    @MainActor
    func enqueuePickupCreatorRatingNotificationDeepLink(pickupGameId: UUID) {
        pendingPickupCreatorRatingNotificationDeepLink = PickupCreatorRatingNotificationDeepLinkRequest(
            id: UUID(),
            pickupGameId: pickupGameId
        )
        pendingPickupPlayingHighlightGameID = pickupGameId
        requestedMainTabRaw = "following"
    }

    @MainActor
    func clearPendingPickupCreatorRatingNotificationDeepLink() {
        pendingPickupCreatorRatingNotificationDeepLink = nil
    }

    @MainActor
    func clearPendingPickupPlayingHighlightGameID() {
        pendingPickupPlayingHighlightGameID = nil
    }

    /// Schedules or cancels the end-of-game rating local notification for one Playing card.
    func reconcilePickupCreatorRatingReminder(
        game: PickupGameRow,
        joinStatus: String?
    ) async {
        let st = (joinStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard st == "approved" else {
            await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
                pickupGameId: game.id
            )
            return
        }

        guard isPickupGameReminderNotificationsEnabled else {
            await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
                pickupGameId: game.id
            )
            return
        }

        // Only schedule for users who will become eligible at end time (approved non-organizer, not yet rated).
        guard let uid = currentUserAuthId, game.creator_user_id != uid else {
            await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
                pickupGameId: game.id
            )
            return
        }
        if hasSubmittedPickupCreatorRating(for: game.id) {
            await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
                pickupGameId: game.id
            )
            return
        }

        let gameStatus = game.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if gameStatus == "cancelled" || gameStatus == "canceled" {
            await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
                pickupGameId: game.id
            )
            return
        }

        guard let endDate = PickupGameModels.endDate(for: game) else {
            await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
                pickupGameId: game.id
            )
            return
        }

        // Fire at scheduled end — the same instant rating becomes eligible.
        // If end already passed, the in-app rating card covers it; do not schedule a past/late local notif.
        if endDate <= Date() {
            await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
                pickupGameId: game.id
            )
            return
        }

        await GameReminderNotificationService.shared.schedulePickupCreatorRatingReminder(
            pickupGameId: game.id,
            fireDate: endDate
        )
    }

    /// Reconciles rating reminders for the current Playing join-card set after a successful list load.
    func reconcilePickupCreatorRatingRemindersForPlayingCards(
        cards: [PickupGameJoinRequestCardDisplay],
        gameById: [UUID: PickupGameRow]
    ) async {
        for card in cards {
            if card.pill == .approved, let game = gameById[card.pickupGameId] {
                await reconcilePickupCreatorRatingReminder(game: game, joinStatus: "approved")
            } else {
                await cancelPickupCreatorRatingReminder(pickupGameId: card.pickupGameId)
            }
        }
    }

    func cancelPickupCreatorRatingReminder(pickupGameId: UUID) async {
        await GameReminderNotificationService.shared.cancelPickupCreatorRatingReminder(
            pickupGameId: pickupGameId
        )
    }

    func cancelAllPickupCreatorRatingReminders() async {
        await GameReminderNotificationService.shared.cancelAllPickupCreatorRatingReminders()
    }
}

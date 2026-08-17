import UserNotifications

/// Downloads optional trusted artwork for remote APNs alerts with `mutable-content`.
/// Always delivers the original title/body if artwork is missing or slow.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: Task<Void, Never>?
    private let lock = NSLock()
    private var didDeliver = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let best = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = best
        downloadTask = Task { [weak self] in
            guard let self else { return }
            if !Task.isCancelled {
                _ = await FanGeoPushArtworkSupport.applyAttachment(
                    to: best,
                    userInfo: request.content.userInfo
                )
            }
            self.deliver(best)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        if let bestAttemptContent {
            deliver(bestAttemptContent)
        }
    }

    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        defer { lock.unlock() }
        guard !didDeliver else { return }
        didDeliver = true
        contentHandler?(content)
        contentHandler = nil
    }
}

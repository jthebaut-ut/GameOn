import MessageUI
import SwiftUI
import UIKit

enum DeletedAccountSupportContact {
    static let recipient = "support@fangeosports.com"
    static let subject = "Deleted account support request"

    static func body(attemptedLoginEmail: String) -> String {
        let normalized = OwnerBusinessEmail.normalized(attemptedLoginEmail)
        let emailLine = normalized.isEmpty ? "<enter your account email>" : normalized
        return """
        Email: \(emailLine)
        Reason: I believe my account was deleted by mistake.
        """
    }

    static func isDeletedAccountBlockMessage(_ message: String) -> Bool {
        MapViewModel.isDeletedAccountLoginBlockMessage(message)
    }
}

struct DeletedAccountSupportStatusBanner: View {
    let title: String
    let message: String
    let attemptedLoginEmail: String
    @State private var showMailComposer = false
    @State private var fallbackMessage = ""

    var body: some View {
        SettingsSheetStatusBanner(
            title: title,
            message: message,
            tint: FGColor.dangerRed,
            systemImage: "exclamationmark.triangle.fill",
            actionTitle: "Contact Support",
            actionSystemImage: "envelope.fill",
            action: contactSupport,
            footerMessage: fallbackMessage
        )
#if canImport(MessageUI)
        .sheet(isPresented: $showMailComposer) {
            DeletedAccountSupportMailComposer(attemptedLoginEmail: attemptedLoginEmail)
        }
#endif
    }

    private func contactSupport() {
        fallbackMessage = ""
#if canImport(MessageUI)
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
            return
        }
#endif
#if canImport(UIKit)
        UIPasteboard.general.string = DeletedAccountSupportContact.recipient
        fallbackMessage = "Support email copied: \(DeletedAccountSupportContact.recipient)"
#else
        fallbackMessage = "Contact support at \(DeletedAccountSupportContact.recipient)"
#endif
    }
}

#if canImport(MessageUI)
struct DeletedAccountSupportMailComposer: UIViewControllerRepresentable {
    let attemptedLoginEmail: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([DeletedAccountSupportContact.recipient])
        composer.setSubject(DeletedAccountSupportContact.subject)
        composer.setMessageBody(
            DeletedAccountSupportContact.body(attemptedLoginEmail: attemptedLoginEmail),
            isHTML: false
        )
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}
#endif

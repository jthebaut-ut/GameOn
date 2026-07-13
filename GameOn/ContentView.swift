import SwiftUI
import UIKit

/// Root view for the single-window app; delegates UI to ``MainTabView``.
struct ContentView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var bootstrapCoordinator = BootstrapLoadingCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var queuedSupportDeepLinkRequest: SupportReplyNotificationDeepLinkRequest?
    @State private var supportNotificationPresentation: SupportNotificationPresentation?
    @State private var lastPresentedSupportDeepLinkRequestID: UUID?
    @State private var lastPresentedSupportConversationID: UUID?
    #if DEBUG
    @State private var debugSplashMinimumElapsed = false
    #endif

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            if shouldShowSplash {
                FanGeoSplashView(statusMessage: bootstrapCoordinator.splashStatusMessage)
                    .zIndex(1)
            } else if viewModel.authSessionState == .deletedAccountConfirmed {
                DeletedAccountLoginGateView(viewModel: viewModel)
                    .zIndex(2)
                    .onAppear {
#if DEBUG
                        print("[DeletedAccountLoginDebug] contentRoute=deletedAccountBlock")
#endif
                    }
            } else if viewModel.isDeletedBusinessLoginBlocked {
                DeletedBusinessLoginGateView(viewModel: viewModel)
                    .zIndex(2)
                    .onAppear {
#if DEBUG
                        print("[DeletedBusinessLoginDebug] contentRoute=deletedBusinessBlock")
#endif
                    }
            } else if let ban = viewModel.activeAccountBan {
                AccountSuspensionGateView(viewModel: viewModel, ban: ban, kind: .user)
                    .zIndex(2)
            } else if let ban = viewModel.activeBusinessAccountBan,
                      viewModel.isBusinessBanGatePresented
                        || viewModel.hasAuthenticatedVenueOwnerSession
                        || viewModel.currentUserIsBusinessAccount
                        || viewModel.venueOwnerMode
                        || viewModel.isBusinessOwnerSessionRestorePending {
                AccountSuspensionGateView(viewModel: viewModel, ban: ban, kind: .business)
                    .zIndex(2)
            } else {
                PublicProfilePresentationHost(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel
                ) {
                    MainTabView(
                        viewModel: viewModel,
                        chatViewModel: chatViewModel,
                        performsInitialBootstrap: bootstrapCoordinator.shouldUseMainTabFallbackBootstrap
                    )
                }
                .zIndex(0)
            }
        }
        .onAppear {
            FanGeoAnalyticsService.recordAppOpen()
            ProGameNotificationDeepLinkBridge.shared.bind(viewModel: viewModel)
            SupportReplyNotificationDeepLinkBridge.shared.bind(viewModel: viewModel)
            FanGeoAnnouncementNotificationDeepLinkBridge.shared.bind(viewModel: viewModel)
            FanGeoPlusAwardNotificationDeepLinkBridge.shared.bind(viewModel: viewModel)
            BusinessProAwardNotificationDeepLinkBridge.shared.bind(viewModel: viewModel)
            #if DEBUG
            print("[LaunchPathDebug] ContentViewMounted=true")
            print("[LaunchPathDebug] isBootstrapping=\(bootstrapCoordinator.isBootstrapping)")
            print("[LaunchPathDebug] splashMinDurationActive=\(!debugSplashMinimumElapsed)")
            #endif
        }
        .onChange(of: viewModel.pendingSupportReplyNotificationDeepLink) { _, request in
            guard let request else { return }
            viewModel.clearPendingSupportReplyNotificationDeepLink()
            queueSupportDeepLinkRequest(request)
        }
        .onChange(of: shouldShowSplash) { _, isShowingSplash in
            guard !isShowingSplash else { return }
            presentQueuedSupportDeepLinkIfReady()
        }
        .onChange(of: bootstrapCoordinator.isBootstrapping) { _, isBootstrapping in
            guard !isBootstrapping else { return }
            presentQueuedSupportDeepLinkIfReady()
        }
        .sheet(item: $supportNotificationPresentation, onDismiss: {
#if DEBUG
            print("[SupportNotificationRoute] support center sheet dismissed")
#endif
            // Allow a later push for the same conversation after the sheet is closed.
            lastPresentedSupportDeepLinkRequestID = nil
            lastPresentedSupportConversationID = nil
        }) { presentation in
            // Hub owns its NavigationStack — do not wrap another stack here.
            ContactGameOnSupportSheet(
                viewModel: viewModel,
                onRequestSignIn: {},
                embedsInNavigationStack: true,
                showsCloseButton: true,
                initialTicketID: presentation.initialTicketID
            )
            .environmentObject(chatViewModel)
        }
        .onChange(of: bootstrapCoordinator.isBootstrapping) {
            #if DEBUG
            print("[LaunchPathDebug] isBootstrapping=\(bootstrapCoordinator.isBootstrapping)")
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            FanGeoAnalyticsService.touchLastActive()
            Task {
                if viewModel.hasAuthenticatedVenueOwnerSession
                    || viewModel.currentUserIsBusinessAccount
                    || viewModel.venueOwnerMode {
                    if viewModel.activeAccountBan != nil {
                        let blocked = await viewModel.businessBanGuardBlocks(path: "foreground", action: "sceneActiveRestore")
                        if !blocked {
                            await viewModel.bootstrapAuthSessionOnly()
                            await viewModel.refreshUserPersonalizationInBackground()
                        }
                    } else if viewModel.activeBusinessAccountBan != nil {
                        await viewModel.refreshActiveBusinessBanGateAndRestoreBusinessSessionIfAllowed(reason: "foregroundBusiness")
                    } else {
                        await viewModel.businessBanGuardBlocks(path: "foreground", action: "sceneActive")
                    }
                } else if viewModel.activeAccountBan != nil {
                    await viewModel.refreshActiveBanGateAndRestoreSessionIfAllowed(reason: "foreground")
                } else {
                    await viewModel.refreshActiveBanGate(reason: "foreground")
                }
            }
        }
        .onOpenURL { url in
            Task {
                await viewModel.handleEmailVerificationDeepLink(url)
                await viewModel.handlePasswordResetDeepLink(url)
            }
        }
        .background(PasswordResetRecoveryOverlayWindowPresenter(viewModel: viewModel))
        .task {
#if DEBUG
            print("[ChatViewModelInstanceDebug] ContentView root ChatViewModel id=\(ObjectIdentifier(chatViewModel))")
            print("[MainActorDebug] ContentView bootstrap task actor=MainActor")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                debugSplashMinimumElapsed = true
                print("[LaunchPathDebug] splashMinDurationActive=false")
            }
#endif
            await bootstrapCoordinator.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel
            )
        }
    }

    private var shouldShowSplash: Bool {
        #if DEBUG
        return bootstrapCoordinator.isBootstrapping || !debugSplashMinimumElapsed
        #else
        return bootstrapCoordinator.isBootstrapping
        #endif
    }

    private func queueSupportDeepLinkRequest(_ request: SupportReplyNotificationDeepLinkRequest) {
#if DEBUG
        print("[SupportNotificationRoute] current route state sheetPresented=\(supportNotificationPresentation != nil) queued=\(queuedSupportDeepLinkRequest != nil) lastRequest=\(lastPresentedSupportDeepLinkRequestID?.uuidString.lowercased() ?? "nil")")
#endif
        if lastPresentedSupportDeepLinkRequestID == request.id {
#if DEBUG
            print("[SupportNotificationRoute] duplicate presentation prevented requestId=\(request.id.uuidString.lowercased())")
            print("[SupportDeepLink] ignored duplicate requestId=\(request.id.uuidString.lowercased())")
#endif
            return
        }
        if supportNotificationPresentation != nil,
           lastPresentedSupportConversationID == request.conversationID {
#if DEBUG
            print("[SupportNotificationRoute] duplicate presentation prevented conversationId=\(request.conversationID.uuidString.lowercased()) support center already open")
#endif
            // Consume without stacking another sheet.
            lastPresentedSupportDeepLinkRequestID = request.id
            queuedSupportDeepLinkRequest = nil
#if DEBUG
            print("[SupportNotificationRoute] pending route consumed/cleared conversationId=\(request.conversationID.uuidString.lowercased())")
#endif
            return
        }
        queuedSupportDeepLinkRequest = request
#if DEBUG
        print("[SupportNotificationRoute] pending route queued conversationId=\(request.conversationID.uuidString.lowercased())")
        print("[SupportDeepLink] queued conversationId=\(request.conversationID.uuidString.lowercased())")
#endif
        presentQueuedSupportDeepLinkIfReady()
    }

    private func presentQueuedSupportDeepLinkIfReady() {
        guard let request = queuedSupportDeepLinkRequest else { return }
        guard !shouldShowSplash else {
#if DEBUG
            print("[SupportNotificationRoute] pending route waiting for splash conversationId=\(request.conversationID.uuidString.lowercased())")
            print("[SupportDeepLink] queued waitingForSplash conversationId=\(request.conversationID.uuidString.lowercased())")
#endif
            return
        }
        guard supportNotificationPresentation == nil else {
#if DEBUG
            print("[SupportNotificationRoute] pending route waiting for sheet dismiss conversationId=\(request.conversationID.uuidString.lowercased())")
            print("[SupportDeepLink] queued waitingForDismissedSheet conversationId=\(request.conversationID.uuidString.lowercased())")
#endif
            return
        }

        // Consume exactly once.
        queuedSupportDeepLinkRequest = nil
        lastPresentedSupportDeepLinkRequestID = request.id
        lastPresentedSupportConversationID = request.conversationID

        let opensTicket = SupportReplyNotificationDeepLinkConfiguration.opensTicketDirectly
            && (viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn)
        let initialTicketID = opensTicket ? request.conversationID : nil

#if DEBUG
        print("[SupportNotificationRoute] support center opened opensTicketDirectly=\(opensTicket) conversationId=\(request.conversationID.uuidString.lowercased())")
        print("[SupportNotificationRoute] pending route consumed/cleared conversationId=\(request.conversationID.uuidString.lowercased())")
        print("[SupportDeepLink] presenting Support Center opensTicketDirectly=\(opensTicket) conversationId=\(request.conversationID.uuidString.lowercased())")
#endif

        supportNotificationPresentation = SupportNotificationPresentation(
            requestID: request.id,
            initialTicketID: initialTicketID
        )
    }
}

private struct DeletedAccountLoginGateView: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var showMailComposer = false
    @State private var fallbackMessage = ""

    @Environment(\.colorScheme) private var colorScheme

    private var attemptedLoginEmail: String {
        let blocked = viewModel.blockedDeletedAccountAttemptEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !blocked.isEmpty { return blocked }
        return viewModel.currentUserEmail
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 32)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(FGColor.dangerRed)

            VStack(spacing: 10) {
                Text(MapViewModel.deletedAccountLoginBlockedTitle)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)

                Text(MapViewModel.deletedAccountLoginBlockedMessage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(FGAdaptiveSurface.cardElevated, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
            }

            VStack(spacing: 12) {
                Button(action: contactSupport) {
                    Text("Contact Support")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: 260)
                        .padding(.vertical, 14)
                        .background(FGColor.accentBlue, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.acknowledgeDeletedAccountLoginBlock()
                } label: {
                    Text("Close")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: 260)
                        .padding(.vertical, 14)
                        .background(FGColor.divider(colorScheme).opacity(0.18), in: Capsule())
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                .buttonStyle(.plain)
            }

            if !fallbackMessage.isEmpty {
                Text(fallbackMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanGeoScreenBackground()
#if canImport(MessageUI)
        .sheet(isPresented: $showMailComposer) {
            DeletedAccountLoginMailComposer(attemptedLoginEmail: attemptedLoginEmail)
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
        UIPasteboard.general.string = "support@fangeosports.com"
        fallbackMessage = "Support email copied: support@fangeosports.com"
#else
        fallbackMessage = "Contact support at support@fangeosports.com"
#endif
    }
}

private struct DeletedBusinessLoginGateView: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var showMailComposer = false
    @State private var fallbackMessage = ""

    @Environment(\.colorScheme) private var colorScheme

    private var attemptedLoginEmail: String {
        let blocked = viewModel.blockedDeletedBusinessAttemptEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !blocked.isEmpty { return blocked }
        return OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
    }

    private var attemptedBusinessId: UUID? {
        viewModel.blockedDeletedBusinessAttemptBusinessId
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 32)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(FGColor.dangerRed)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(MapViewModel.deletedBusinessLoginBlockedTitle)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(MapViewModel.deletedBusinessLoginBlockedMessage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(FGAdaptiveSurface.cardElevated, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(MapViewModel.deletedBusinessLoginBlockedTitle). \(MapViewModel.deletedBusinessLoginBlockedMessage)")

            VStack(spacing: 12) {
                Button(action: contactSupport) {
                    Text("Contact Support")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: 260)
                        .padding(.vertical, 14)
                        .background(FGColor.accentBlue, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Contact Support")
                .accessibilityHint("Opens support contact for deleted business account reactivation")

                Button {
                    viewModel.acknowledgeDeletedBusinessLoginBlock()
                } label: {
                    Text("Close")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: 260)
                        .padding(.vertical, 14)
                        .background(FGColor.divider(colorScheme).opacity(0.18), in: Capsule())
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityHint("Dismisses this screen and returns to sign in")
            }

            if !fallbackMessage.isEmpty {
                Text(fallbackMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .accessibilityLabel(fallbackMessage)
            }

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanGeoScreenBackground()
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
#if canImport(MessageUI)
        .sheet(isPresented: $showMailComposer) {
            DeletedBusinessLoginMailComposer(
                attemptedLoginEmail: attemptedLoginEmail,
                businessId: attemptedBusinessId
            )
        }
#endif
    }

    private func contactSupport() {
        fallbackMessage = ""
#if DEBUG
        print("[DeletedBusinessLoginDebug] supportOpened email=\(attemptedLoginEmail) businessId=\(attemptedBusinessId?.uuidString.lowercased() ?? "nil")")
#endif
#if canImport(MessageUI)
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
            return
        }
#endif
#if canImport(UIKit)
        UIPasteboard.general.string = MapViewModel.deletedBusinessSupportRecipient
        fallbackMessage = "Support email copied: \(MapViewModel.deletedBusinessSupportRecipient)"
#else
        fallbackMessage = "Contact support at \(MapViewModel.deletedBusinessSupportRecipient)"
#endif
    }
}

#if canImport(MessageUI)
import MessageUI

private struct DeletedBusinessLoginMailComposer: UIViewControllerRepresentable {
    let attemptedLoginEmail: String
    let businessId: UUID?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([MapViewModel.deletedBusinessSupportRecipient])
        composer.setSubject(MapViewModel.deletedBusinessSupportSubject)
        composer.setMessageBody(
            MapViewModel.deletedBusinessSupportMessageBody(
                attemptedLoginEmail: attemptedLoginEmail,
                businessId: businessId
            ),
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

#if canImport(MessageUI)
import MessageUI

private struct DeletedAccountLoginMailComposer: UIViewControllerRepresentable {
    let attemptedLoginEmail: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients(["support@fangeosports.com"])
        composer.setSubject("Deleted account support request")
        let normalized = OwnerBusinessEmail.normalized(attemptedLoginEmail)
        let emailLine = normalized.isEmpty ? "<enter your account email>" : normalized
        composer.setMessageBody(
            """
            Email: \(emailLine)
            Reason: I believe my account was deleted by mistake.
            """,
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

private struct SupportNotificationPresentation: Identifiable {
    let requestID: UUID
    let initialTicketID: UUID?

    var id: UUID { requestID }
}

private struct AccountSuspensionGateView: View {
    enum SuspensionKind {
        case user
        case business
    }

    @ObservedObject var viewModel: MapViewModel
    let ban: FanGeoAccountBan
    let kind: SuspensionKind

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 32)

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(FGColor.dangerRed)

            VStack(spacing: 10) {
                Text(kind == .business ? "Business account suspended" : "Account suspended")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)

                Text(primaryMessage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)

                if let remainingMessage {
                    Text(remainingMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.center)
                }

                Text("For questions, contact support@fangeosports.com.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(FGAdaptiveSurface.cardElevated, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
            }

            Button {
                Task {
                    switch kind {
                    case .user:
                        await viewModel.refreshActiveBanGateAndRestoreSessionIfAllowed(reason: "manualSuspensionRefresh")
                    case .business:
                        await viewModel.refreshActiveBusinessBanGateAndRestoreBusinessSessionIfAllowed(reason: "manualBusinessSuspensionRefresh")
                    }
                }
            } label: {
                Text(isChecking ? "Checking..." : "Check status")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: 260)
                    .padding(.vertical, 14)
                    .background(FGColor.accentBlue, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isChecking)

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fanGeoScreenBackground()
    }

    private var primaryMessage: String {
        if ban.isPermanent {
            return kind == .business
                ? "This business account has been permanently suspended."
                : "Your account has been permanently suspended."
        }
        return kind == .business
            ? "This business account is suspended until \(formattedBanEnd)."
            : "Your account is suspended until \(formattedBanEnd)."
    }

    private var remainingMessage: String? {
        guard !ban.isPermanent else { return nil }
        guard let remainingSeconds = ban.remainingSeconds else {
            return "You can return after the suspension expires."
        }
        return "You can return in \(Self.remainingTimeText(seconds: remainingSeconds))."
    }

    private var isChecking: Bool {
        switch kind {
        case .user:
            return viewModel.isCheckingActiveBan
        case .business:
            return viewModel.isCheckingActiveBusinessBan
        }
    }

    private var formattedBanEnd: String {
        guard let bannedUntil = ban.bannedUntil else {
            return ban.bannedUntilRaw ?? "the scheduled end time"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: bannedUntil)
    }

    private static func remainingTimeText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let days = clamped / 86_400
        let hours = (clamped % 86_400) / 3_600
        let minutes = (clamped % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "less than 1 minute"
    }
}

private struct PasswordResetRecoveryOverlayWindowPresenter: UIViewRepresentable {
    @ObservedObject var viewModel: MapViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(viewModel: viewModel, sourceView: uiView)
    }

    final class Coordinator {
        private var overlayWindow: UIWindow?
        private weak var previousKeyWindow: UIWindow?
        private var hostingController: UIHostingController<PasswordResetCreatePasswordSheet>?
        private var isShowingOverlay = false

        @MainActor
        func update(viewModel: MapViewModel, sourceView: UIView) {
            let shouldShowOverlay = viewModel.isShowingPasswordResetCreateSheet
                || viewModel.isPasswordResetRecoverySessionActive
            guard shouldShowOverlay else {
                dismissOverlayIfNeeded()
                return
            }

            let host = hostingController ?? UIHostingController(
                rootView: PasswordResetCreatePasswordSheet(viewModel: viewModel)
            )
            host.rootView = PasswordResetCreatePasswordSheet(viewModel: viewModel)
            host.view.backgroundColor = .clear
            hostingController = host

            if overlayWindow == nil {
                guard let windowScene = sourceView.window?.windowScene
                    ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
                else { return }

                let window = UIWindow(windowScene: windowScene)
                window.windowLevel = .alert + 100
                window.backgroundColor = .clear
                window.rootViewController = host
                previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
                overlayWindow = window
            } else {
                overlayWindow?.rootViewController = host
            }

            overlayWindow?.makeKeyAndVisible()
            if !isShowingOverlay {
                isShowingOverlay = true
                print("[PasswordResetDebug] rootOverlayPresented=true")
                print("[PasswordResetDebug] recoveryOverlayAboveAll=true")
            }
        }

        @MainActor
        private func dismissOverlayIfNeeded() {
            guard overlayWindow != nil || isShowingOverlay else { return }
            overlayWindow?.isHidden = true
            overlayWindow?.rootViewController = nil
            overlayWindow = nil
            hostingController = nil
            previousKeyWindow?.makeKey()
            previousKeyWindow = nil
            isShowingOverlay = false
            print("[PasswordResetDebug] rootOverlayDismissed=true")
        }
    }
}

import Combine
import SwiftUI
import UIKit

/// Presents ``PublicUserProfilePreviewView`` in a dedicated high-level `UIWindow` so it appears above nested SwiftUI sheets.
@MainActor
enum PublicProfileOverlayWindowPresenter {
    private static var overlayWindow: UIWindow?
    private static weak var hostingController: UIViewController?
    private static var presentedUserId: UUID?
    private static var restoredKeyWindow: UIWindow?
    private static weak var activeSession: PublicProfileOverlaySession?
    private static var appearanceObservers: [NSObjectProtocol] = []
    private static var lastPresentationContext: String?

    static var isOverlayWindowActive: Bool {
        overlayWindow != nil && overlayWindow?.isHidden == false
    }

    static func syncPresentation(
        userId: UUID?,
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        activeSheetHint: String?
    ) {
        lastPresentationContext = activeSheetHint
        if let userId {
            if presentedUserId == userId, isOverlayWindowActive, activeSession?.isDismissing != true {
                syncOverlayInterfaceStyle(reason: "alreadyVisible")
                logPresentation(
                    activeSheet: activeSheetHint,
                    presented: true,
                    alreadyVisible: true,
                    userId: userId
                )
                SuggestedFanProfileOpenDebug.presentationStarted(alreadyPresented: true)
                return
            }
            if isOverlayWindowActive, presentedUserId != userId, let activeSession {
                swapUser(
                    to: userId,
                    session: activeSession,
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    activeSheetHint: activeSheetHint
                )
                return
            }
            present(
                userId: userId,
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                activeSheetHint: activeSheetHint
            )
        } else {
            dismiss(activeSheetHint: activeSheetHint)
        }
    }

    private static func present(
        userId: UUID,
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        activeSheetHint: String?
    ) {
        tearDown(activeSheetHint: activeSheetHint, silent: true)

        guard let scene = activeWindowScene() else {
            logPresentation(
                activeSheet: activeSheetHint,
                presented: false,
                alreadyVisible: false,
                userId: userId
            )
            return
        }

        let session = PublicProfileOverlaySession(userId: userId)
        session.onDismissCompleted = {
            viewModel.dismissPublicProfile()
            tearDown(activeSheetHint: activeSheetHint, silent: true)
        }
        activeSession = session

        let root = PublicProfileOverlayContainer(
            session: session,
            viewModel: viewModel,
            chatViewModel: chatViewModel,
            presentationContext: activeSheetHint ?? "unknown"
        )
        .environmentObject(viewModel)
        .environmentObject(chatViewModel)

        let hosting = UIHostingController(rootView: root)
        let interfaceStyle = resolvedOverrideStyle(in: scene)
        hosting.overrideUserInterfaceStyle = interfaceStyle
        hosting.view.backgroundColor = profileScreenUIColor()

        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        window.backgroundColor = profileScreenUIColor()
        // Resolve system appearance to an explicit light/dark so a brand-new overlay window
        // never boots with the wrong trait collection while SwiftUI already reads `.dark`.
        window.overrideUserInterfaceStyle = interfaceStyle
        window.rootViewController = hosting

        restoredKeyWindow = keyWindow(in: scene)
        window.isHidden = false
        window.makeKeyAndVisible()

        overlayWindow = window
        hostingController = hosting
        presentedUserId = userId
        installAppearanceObservers()

        logPresentation(
            activeSheet: activeSheetHint,
            presented: true,
            alreadyVisible: false,
            userId: userId
        )
    }

    private static func swapUser(
        to userId: UUID,
        session: PublicProfileOverlaySession,
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        activeSheetHint: String?
    ) {
        session.onDismissCompleted = {
            viewModel.dismissPublicProfile()
            tearDown(activeSheetHint: activeSheetHint, silent: true)
        }
        session.setUserId(userId)
        presentedUserId = userId
        syncOverlayInterfaceStyle(reason: "swapUser")
        logPresentation(
            activeSheet: activeSheetHint,
            presented: true,
            alreadyVisible: false,
            userId: userId
        )
    }

    private static func dismiss(activeSheetHint: String?, silent: Bool = false) {
        guard overlayWindow != nil else { return }

        if !silent, let activeSession, !activeSession.isDismissing {
            activeSession.requestDismiss()
            if !silent {
                logPresentation(
                    activeSheet: activeSheetHint,
                    presented: false,
                    alreadyVisible: false,
                    userId: presentedUserId
                )
            }
            return
        }

        tearDown(activeSheetHint: activeSheetHint, silent: silent)
    }

    private static func tearDown(activeSheetHint: String?, silent: Bool) {
        removeAppearanceObservers()
        overlayWindow?.isHidden = true
        overlayWindow = nil
        hostingController = nil
        presentedUserId = nil
        activeSession = nil

        if let restoredKeyWindow {
            restoredKeyWindow.makeKeyAndVisible()
        }
        restoredKeyWindow = nil

        if !silent {
            logPresentation(
                activeSheet: activeSheetHint,
                presented: false,
                alreadyVisible: false,
                userId: nil
            )
        }
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    private static func keyWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first(where: \.isKeyWindow)
    }

    private static var currentAppearancePreference: FanGeoAppearancePreference {
        let rawValue = UserDefaults.standard.string(forKey: FanGeoAppearancePreference.appStorageKey)
        return rawValue.flatMap(FanGeoAppearancePreference.init(rawValue:)) ?? .system
    }

    /// Prefer an explicit light/dark for forced app preferences; keep `.unspecified` for System
    /// so mid-session appearance changes continue to reach the overlay.
    private static func resolvedOverrideStyle(in scene: UIWindowScene?) -> UIUserInterfaceStyle {
        switch currentAppearancePreference {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return .unspecified
        }
    }

    private static func syncOverlayInterfaceStyle(reason: String) {
        guard let window = overlayWindow else { return }
        let style = resolvedOverrideStyle(in: window.windowScene)
        if window.overrideUserInterfaceStyle != style {
            window.overrideUserInterfaceStyle = style
        }
        if let hostingController, hostingController.overrideUserInterfaceStyle != style {
            hostingController.overrideUserInterfaceStyle = style
        }
        window.backgroundColor = profileScreenUIColor()
        hostingController?.view.backgroundColor = profileScreenUIColor()
#if DEBUG
        print("[PublicProfileAppearanceDebug] syncInterfaceStyle reason=\(reason) style=\(style.rawValue) context=\(lastPresentationContext ?? "")")
#endif
    }

    private static func installAppearanceObservers() {
        removeAppearanceObservers()

        let center = NotificationCenter.default
        appearanceObservers = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    syncOverlayInterfaceStyle(reason: "didBecomeActive")
                }
            },
            center.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    syncOverlayInterfaceStyle(reason: "appearancePreferenceChanged")
                }
            }
        ]
    }

    private static func removeAppearanceObservers() {
        let center = NotificationCenter.default
        for observer in appearanceObservers {
            center.removeObserver(observer)
        }
        appearanceObservers.removeAll()
    }

    private static func profileScreenUIColor() -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1)
                : UIColor(red: 0.96, green: 0.975, blue: 0.995, alpha: 1)
        }
    }

    private static func logPresentation(
        activeSheet: String?,
        presented: Bool,
        alreadyVisible: Bool,
        userId: UUID?
    ) {
#if DEBUG
        print("[PublicProfilePresentationDebug] presenter=custom_overlay_fullscreen")
        print("[PublicProfilePresentationDebug] swiftUIModalUsed=false")
        print("[PublicProfilePresentationDebug] overlayWindowUsed=\(isOverlayWindowActive)")
        print("[PublicProfilePresentationDebug] activeSheet=\(activeSheet ?? "")")
        print("[PublicProfilePresentationDebug] presented=\(presented) alreadyVisible=\(alreadyVisible)")
        print("[PublicProfileAppearanceDebug] sourceRoute=\(activeSheet ?? "")")
        print("[PublicProfileAppearanceDebug] profileId=\(userId?.uuidString.lowercased() ?? "nil")")
        print("[PublicProfileAppearanceDebug] presentationType=overlay_window")
        print("[PublicProfileAppearanceDebug] rootCreatedOrReused=\(alreadyVisible ? "reused" : "newly_created")")
        if let window = overlayWindow {
            print("[PublicProfileAppearanceDebug] windowStyle=\(window.traitCollection.userInterfaceStyle.rawValue)")
        }
#endif
    }
}

// MARK: - Animation session

@MainActor
final class PublicProfileOverlaySession: ObservableObject {
    @Published private(set) var userId: UUID
    @Published private(set) var contentOpacity: Double = 0
    @Published private(set) var contentOffset: CGFloat = 0
    @Published private(set) var isDismissing = false

    var onDismissCompleted: (() -> Void)?

    private var presentTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private static let offscreenOffset: CGFloat = 48
    private static let presentSpring = Animation.spring(response: 0.42, dampingFraction: 0.9, blendDuration: 0.1)
    private static let dismissSpring = Animation.spring(response: 0.34, dampingFraction: 0.94, blendDuration: 0.08)

    init(userId: UUID) {
        self.userId = userId
        contentOffset = Self.offscreenOffset
        contentOpacity = 0
    }

    func setUserId(_ newUserId: UUID) {
        guard newUserId != userId else { return }
        userId = newUserId
        isDismissing = false
        runPresentAnimation()
    }

    func runPresentAnimation() {
        presentTask?.cancel()
        dismissTask?.cancel()
        isDismissing = false
        contentOffset = Self.offscreenOffset
        contentOpacity = 0

        presentTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(Self.presentSpring) {
                contentOpacity = 1
                contentOffset = 0
            }
        }
    }

    func requestDismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        presentTask?.cancel()
        dismissTask?.cancel()

        withAnimation(Self.dismissSpring) {
            contentOpacity = 0
            contentOffset = Self.offscreenOffset
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            onDismissCompleted?()
        }
    }
}

// MARK: - Full-screen overlay UI

/// Opaque full-screen host for public fan profiles (not a partial sheet).
struct PublicProfileOverlayContainer: View {
    @ObservedObject var session: PublicProfileOverlaySession
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    var presentationContext: String = "unknown"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            FGColor.background(colorScheme)
                .ignoresSafeArea()

            PublicUserProfilePreviewView(
                userId: session.userId,
                viewModel: viewModel,
                isSelfPreview: viewModel.publicProfileIsSelfPreview && session.userId == viewModel.currentUserAuthId,
                onDismiss: { session.requestDismiss() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(session.contentOpacity)
            .offset(y: session.contentOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            session.runPresentAnimation()
#if DEBUG
            print("[PublicProfileAppearanceDebug] containerAppear context=\(presentationContext) profileId=\(session.userId.uuidString.lowercased()) colorScheme=\(colorScheme == .dark ? "dark" : "light")")
#endif
        }
        .onChange(of: colorScheme) { _, newValue in
#if DEBUG
            print("[PublicProfileAppearanceDebug] containerColorSchemeChanged context=\(presentationContext) profileId=\(session.userId.uuidString.lowercased()) colorScheme=\(newValue == .dark ? "dark" : "light")")
#endif
        }
    }
}

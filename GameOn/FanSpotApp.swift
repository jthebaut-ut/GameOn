
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

@main
struct WatchZoneApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(FanGeoAppDelegate.self) private var appDelegate
    #endif

    @AppStorage(FanGeoAppearancePreference.appStorageKey) private var appearancePreferenceRaw = FanGeoAppearancePreference.system.rawValue
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    init() {
        // Must run before ad-consent acknowledgment so upgrade migration is not polluted.
        FanGeoFirstLaunchLanguagePreferences.prepareAtProcessStart()
        GoogleMobileAdsBootstrap.startIfNeeded()
        #if DEBUG
        DebugLogGate.applyLaunchArgumentOverridesIfNeeded()
        let b = Bundle.main
        print("GAMEON_DEBUG bundlePath=\(b.bundlePath)")
        print("GAMEON_DEBUG executablePath=\(b.executablePath ?? "(nil)")")
        print("GAMEON_DEBUG bundleIdentifier=\(b.bundleIdentifier ?? "(nil)")")
        print("[FanGeoLoadingDebug] launchScreenLoaded")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            FanGeoAdConsentPrePromptHost {
                ContentView()
            }
                .preferredColorScheme(appearancePreference.colorScheme)
                .environment(\.locale, Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)))
                .onAppear {
                    #if DEBUG
                    print("[LaunchPathDebug] WatchZoneAppMounted=true")
                    print("[SettingsAppearanceDebug] appRootAppear preference=\(appearancePreference.rawValue)")
                    #endif
                }
                .onChange(of: appearancePreferenceRaw) { _, newRaw in
                    #if DEBUG
                    let preference = FanGeoAppearancePreference(rawValue: newRaw) ?? .system
                    print("[SettingsAppearanceDebug] appRootPreferenceChanged=\(preference.rawValue)")
                    #endif
                }
        }
    }

    private var appearancePreference: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }
}

#if canImport(UIKit)
private final class FanGeoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            await PushNotificationRegistrationService.shared.refreshPushTokenRegistration(reason: "appLaunch")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationRegistrationService.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationRegistrationService.shared.handleRegistrationFailure(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
#if DEBUG
        print("[RemoteNotificationDebug] received userInfo=\(userInfo)")
#endif
        completionHandler(.noData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            ProGameNotificationDeepLinkBridge.shared.handleNotificationResponse(response)
            PickupCreatorRatingNotificationDeepLinkBridge.shared.handleNotificationResponse(response)
            SupportReplyNotificationDeepLinkBridge.shared.handleNotificationResponse(response)
            FanGeoAnnouncementNotificationDeepLinkBridge.shared.handleNotificationResponse(response)
            FanGeoPlusAwardNotificationDeepLinkBridge.shared.handleNotificationResponse(response)
            BusinessProAwardNotificationDeepLinkBridge.shared.handleNotificationResponse(response)
        }
    }
}
#endif

private enum FanGeoLaunchConsentGate {
    static let fallbackSeconds: TimeInterval = 1.5
}

private struct FanGeoAdConsentPrePromptHost<Content: View>: View {
    let content: Content
    @State private var showsPreConsentPrompt = false
    @State private var isPreparingPrivacySettings = false
    @State private var revealsMainExperience = GoogleMobileAdsBootstrap.hasFinishedConsentFlow
        || GoogleMobileAdsBootstrap.canRevealMainExperienceWhileConsentFinishes

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .opacity(revealsMainExperience ? 1 : 0)
                .allowsHitTesting(revealsMainExperience)
                .accessibilityHidden(!revealsMainExperience)

            if !revealsMainExperience {
                FanGeoSplashView()
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showsPreConsentPrompt) {
            FanGeoAdConsentPrePromptView(
                isPreparingPrivacySettings: isPreparingPrivacySettings,
                onContinue: handlePreConsentContinue
            )
            .interactiveDismissDisabled()
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .task {
            await waitForAppBootstrapReady()
            handleAppBootstrapReady()
        }
        .onAppear {
            GoogleMobileAdsBootstrap.runWhenConsentFlowFinished {
                Task { @MainActor in
                    revealMainExperienceIfNeeded(reason: "consentCompleteCallback")
                }
            }
        }
    }

    private func handlePreConsentContinue() {
        guard !isPreparingPrivacySettings else { return }
        isPreparingPrivacySettings = true
        logLaunchConsentGate(state: "waiting", showing: "splash", reason: "preConsentContinue")
        Task {
            let delayNs = UInt64.random(in: 250_000_000...400_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            GoogleMobileAdsBootstrap.acknowledgePreConsentPromptAndContinue()
            await waitForConsentFlowCompletion()
            isPreparingPrivacySettings = false
            showsPreConsentPrompt = false
            revealMainExperienceIfNeeded(reason: "firstLaunchConsentComplete")
        }
    }

    private func handleAppBootstrapReady() {
        if GoogleMobileAdsBootstrap.shouldPresentPreConsentPrompt {
            logLaunchConsentGate(state: "waiting", showing: "splash", reason: "preConsentPrompt")
            showsPreConsentPrompt = true
            return
        }

        if revealMainExperienceIfNeeded(reason: "bootstrapReadyImmediate") {
            return
        }

        logLaunchConsentGate(state: "waiting", showing: "splash", reason: "consentPending")
        Task {
            await waitForConsentFlowCompletionWithFallback()
        }
    }

    @discardableResult
    private func revealMainExperienceIfNeeded(reason: String) -> Bool {
        guard !revealsMainExperience else { return true }
        guard shouldRevealMainExperienceNow else { return false }
        revealsMainExperience = true
        logLaunchConsentGate(state: "ready", showing: "app", reason: reason)
        return true
    }

    private var shouldRevealMainExperienceNow: Bool {
        GoogleMobileAdsBootstrap.hasFinishedConsentFlow
            || GoogleMobileAdsBootstrap.canRevealMainExperienceWhileConsentFinishes
    }

    private func waitForAppBootstrapReady() async {
        guard !LaunchBootstrapState.didBecomeAppReady else { return }
        while !LaunchBootstrapState.didBecomeAppReady {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
        }
    }

    private func waitForConsentFlowCompletion() async {
        if GoogleMobileAdsBootstrap.hasFinishedConsentFlow { return }
        await withCheckedContinuation { continuation in
            GoogleMobileAdsBootstrap.runWhenConsentFlowFinished {
                continuation.resume()
            }
        }
    }

    private func waitForConsentFlowCompletionWithFallback() async {
        if revealMainExperienceIfNeeded(reason: "consentAlreadyComplete") {
            return
        }

        let finishedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waitForConsentFlowCompletion()
                return true
            }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(FanGeoLaunchConsentGate.fallbackSeconds * 1_000_000_000)
                )
                return false
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }

        if revealMainExperienceIfNeeded(reason: finishedInTime ? "consentComplete" : "callbackDelayed") {
            return
        }

        if GoogleMobileAdsBootstrap.hasAcknowledgedPreConsentPrompt {
            revealsMainExperience = true
            print("[LaunchConsentGate] fallbackReveal=true reason=callbackDelayed")
            logLaunchConsentGate(state: "ready", showing: "app", reason: "callbackDelayed")
        }
    }

    private func logLaunchConsentGate(state: String, showing: String, reason: String) {
        print("[LaunchConsentGate] state=\(state) showing=\(showing) reason=\(reason)")
    }
}

private struct FanGeoAdConsentPrePromptView: View {
    let isPreparingPrivacySettings: Bool
    let onContinue: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("Help Keep FanGeo Free", languageCode: languageCode))
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(L10n.t("ad_consent_pre_prompt_body", languageCode: languageCode))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isPreparingPrivacySettings {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(L10n.t("Preparing privacy settings…", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Button(action: onContinue) {
                Text(L10n.t("Continue", languageCode: languageCode))
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(FGColor.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isPreparingPrivacySettings)
            .opacity(isPreparingPrivacySettings ? 0.55 : 1)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
    }
}

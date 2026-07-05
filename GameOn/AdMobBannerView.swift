import Foundation
import GoogleMobileAds
import UIKit
import UserMessagingPlatform
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

// Verbose ad diagnostics are limited to developer/internal builds; App Store users should not see ad debug logs.
enum AdDiagnostics {
    private static var didLogTestDeviceConfiguration = false

    static var enabled: Bool {
#if DEBUG
        return true
#else
        return sandboxReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
    }

    private static var sandboxReceiptURL: URL? {
        Bundle.main.value(forKey: "appStoreReceiptURL") as? URL
    }

    static func logStartupTestDeviceConfigurationIfNeeded() {
        guard enabled, !didLogTestDeviceConfiguration else { return }
        didLogTestDeviceConfiguration = true
        let identifiers = MobileAds.shared.requestConfiguration.testDeviceIdentifiers ?? []
        print("[AdDebug] testDeviceConfigured=\(!identifiers.isEmpty || AdMobConfiguration.usesTestAds) requestConfiguration.testDeviceIdentifiers=\(identifiers) testDeviceIdentifierCount=\(identifiers.count)")
    }
}

// MARK: - Ad unit configuration (test in DEBUG, production in RELEASE)

/// Central AdMob IDs for FanGeo.
enum AdMobConfiguration {
    // MARK: Test ad units (Google sample units — DEBUG / internal diagnostics only)
    /// Reference only. `GADApplicationIdentifier` in Info.plist always uses the FanGeo production app ID.
    static let testApplicationID = "ca-app-pub-3940256099942544~1458002511"
    static let testBannerAdUnitID = "ca-app-pub-3940256099942544/2435281174"
    /// Google-provided native test unit.
    static let testNativeAdUnitID = "ca-app-pub-3940256099942544/3986624511"

    // MARK: Production
    static let productionApplicationID = "ca-app-pub-9637364906993742~5547329973"
    static let productionBannerAdUnitID = "ca-app-pub-9637364906993742/6964124517"
    static let productionNativeAdUnitID: String? = "ca-app-pub-9637364906993742/7885775201"
    private static let developerTestDeviceIdentifiers = [
        "5221eb346221e44cb542638866e39d10"
    ]

    static var usesTestAds: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var testDeviceIdentifiers: [String] {
        AdDiagnostics.enabled ? developerTestDeviceIdentifiers : []
    }

    static func configureRequestConfiguration() {
        MobileAds.shared.requestConfiguration.testDeviceIdentifiers = testDeviceIdentifiers
    }

    /// DEBUG-only manual switch for the Google Mobile Ads native validator UI.
    ///
    /// The SDK reads `GADNativeAdValidatorEnabled` from `AdMob-Info.plist`; keep that key in sync
    /// with this flag when you intentionally want the blocking validator popup during local testing.
    static var enableNativeAdValidatorPopup: Bool {
        #if DEBUG
        false
        #else
        false
        #endif
    }

    /// Matches `GADApplicationIdentifier` in Info.plist. Test ads use test *unit* IDs, not a test app ID.
    static var applicationID: String {
        let plistID = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String
        let trimmed = plistID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return productionApplicationID
    }

    static var bannerAdUnitID: String {
        let unit = usesTestAds ? testBannerAdUnitID : productionBannerAdUnitID
        logUnitSelection(format: "banner", unitID: unit)
        return unit
    }

    static var nativeAdUnitID: String {
        let unit = usesTestAds ? testNativeAdUnitID : (productionNativeAdUnitID ?? testNativeAdUnitID)
        logUnitSelection(format: "native", unitID: unit)
        return unit
    }

    static func bannerAdUnitID(for placement: String) -> String {
        let unit = shouldUseOfficialTestUnit(format: "banner", placement: placement)
            ? testBannerAdUnitID
            : productionBannerAdUnitID
        logUnitSelection(format: "banner", unitID: unit)
        return unit
    }

    static func nativeAdUnitID(for placement: String) -> String {
        let unit = shouldUseOfficialTestUnit(format: "native", placement: placement)
            ? testNativeAdUnitID
            : (productionNativeAdUnitID ?? testNativeAdUnitID)
        logUnitSelection(format: "native", unitID: unit)
        return unit
    }

    private static func shouldUseOfficialTestUnit(format: String, placement: String) -> Bool {
        guard AdDiagnostics.enabled else { return false }
        switch (format, placement) {
        case ("banner", "discover.bottomStrip"),
             ("native", "chat.inboxFeed"):
            return true
        default:
            return usesTestAds
        }
    }

    static var nativeAdsUseTemporaryTestUnitInRelease: Bool {
        !usesTestAds && productionNativeAdUnitID == nil
    }

    private static func logUnitSelection(format: String, unitID: String) {
        AdMobDiagnostics.logUnitSelection(format: format, unitID: unitID)
    }
}

enum AdRuntimeDevice {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// DEBUG builds use Google test ad units, which are safe on physical devices.
    static var testDeviceConfigured: Bool {
        AdMobConfiguration.usesTestAds || !AdMobConfiguration.testDeviceIdentifiers.isEmpty
    }
}

private enum FanGeoAdConsentPrePromptStore {
    private static let acknowledgedKey = "FanGeoAdConsentPrePromptAcknowledged"

    static var hasAcknowledged: Bool {
        UserDefaults.standard.bool(forKey: acknowledgedKey)
    }

    static func markAcknowledged() {
        UserDefaults.standard.set(true, forKey: acknowledgedKey)
    }
}

/// Backward-compatible name used by older call sites.
enum AdMobTestConfiguration {
    static var testBannerAdUnitID: String { AdMobConfiguration.testBannerAdUnitID }
}

// MARK: - Shared root view controller for ad presentation

enum AdMobRootViewController {
    static func bestKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    static func topViewController() -> UIViewController? {
        guard let root = bestKeyWindow()?.rootViewController else { return nil }
        var top: UIViewController = root
        while let presented = top.presentedViewController {
            top = presented
        }
        if let nav = top as? UINavigationController, let visible = nav.visibleViewController {
            top = visible
        }
        if let tab = top as? UITabBarController, let selected = tab.selectedViewController {
            top = selected
        }
        return top
    }
}

/// Initializes the Google Mobile Ads SDK once at launch (non-blocking).
@MainActor
enum GoogleMobileAdsBootstrap {
    private static var didStart = false
    private static var didFinishConsentFlow = false
    private static var adsCanBeRequested = false
    private static var didStartMobileAds = false
    private static var isWaitingForPreConsentPrompt = false
    private static var pendingReadyHandlers: [() -> Void] = []
    private static var pendingConsentFlowFinishedHandlers: [() -> Void] = []

    static var canRequestAds: Bool {
        didFinishConsentFlow && adsCanBeRequested
    }

    /// UI gate: true once FanGeo pre-consent (if any), UMP, and ATT steps have completed.
    static var hasFinishedConsentFlow: Bool {
        didFinishConsentFlow
    }

    static var privacyOptionsRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    static var shouldPresentPreConsentPrompt: Bool {
        isWaitingForPreConsentPrompt && !FanGeoAdConsentPrePromptStore.hasAcknowledged
    }

    static var hasAcknowledgedPreConsentPrompt: Bool {
        FanGeoAdConsentPrePromptStore.hasAcknowledged
    }

    /// UI-only: returning users with no interactive ATT/UMP steps left can enter the app while consent refresh finishes.
    static var canRevealMainExperienceWhileConsentFinishes: Bool {
        guard hasAcknowledgedPreConsentPrompt else { return false }
        guard !isWaitingForPreConsentPrompt else { return false }
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus != .notDetermined else { return false }
        }
        switch ConsentInformation.shared.consentStatus {
        case .required, .unknown:
            return false
        case .notRequired, .obtained:
            return true
        @unknown default:
            return false
        }
    }

    static func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        FanGeoAdPolicy.logStartupDiagnostics()
        guard !FanGeoAdPolicy.shouldSkipAdNetworkBootstrap else {
            markConsentFlowFinished()
            AdDebugDiagnostics.logConsent("adsBootstrapSkipped=true reason=screenshotMode")
            return
        }
        AdMobConfiguration.configureRequestConfiguration()
        AdDiagnostics.logStartupTestDeviceConfigurationIfNeeded()
        AdMobDiagnostics.logBootstrap()
        guard FanGeoAdConsentPrePromptStore.hasAcknowledged else {
            isWaitingForPreConsentPrompt = true
            AdDebugDiagnostics.logConsent("preConsentPromptRequired=true")
            return
        }
        continueConsentFlowAfterPrePrompt()
    }

    static func acknowledgePreConsentPromptAndContinue() {
        FanGeoAdConsentPrePromptStore.markAcknowledged()
        guard isWaitingForPreConsentPrompt || !didFinishConsentFlow else { return }
        isWaitingForPreConsentPrompt = false
        AdDebugDiagnostics.logConsent("preConsentPromptAcknowledged=true")
        continueConsentFlowAfterPrePrompt()
    }

    private static func continueConsentFlowAfterPrePrompt() {
        Task {
            await resolveConsentAndStartAdsIfAllowed()
        }
    }

    static func runWhenAdsCanBeRequested(_ handler: @escaping () -> Void) {
        if canRequestAds {
            handler()
            return
        }
        pendingReadyHandlers.append(handler)
    }

    static func runWhenConsentFlowFinished(_ handler: @escaping () -> Void) {
        if didFinishConsentFlow {
            handler()
            return
        }
        pendingConsentFlowFinishedHandlers.append(handler)
    }

    static func presentPrivacyOptionsIfRequired() async {
        guard privacyOptionsRequired,
              let root = await waitForRootViewController(timeoutSeconds: 3) else { return }
        await presentPrivacyOptions(from: root)
    }

    private static func resolveConsentAndStartAdsIfAllowed() async {
        await updateUMPConsentInformation()
        await loadAndPresentUMPFormIfNeeded()
        await requestAppTrackingAuthorizationIfNeeded()

        adsCanBeRequested = ConsentInformation.shared.canRequestAds
        markConsentFlowFinished()
        applyTrackingAuthorizationToAdRequestConfiguration()
        AdDebugDiagnostics.logConsent("canRequestAds=\(adsCanBeRequested)")

        if adsCanBeRequested {
            await startMobileAdsIfNeeded()
        }

        let handlers = pendingReadyHandlers
        pendingReadyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private static func markConsentFlowFinished() {
        guard !didFinishConsentFlow else { return }
        didFinishConsentFlow = true
        let handlers = pendingConsentFlowFinishedHandlers
        pendingConsentFlowFinishedHandlers.removeAll()
        handlers.forEach { $0() }
    }

    /// Requests Apple ATT only after FanGeo pre-consent + UMP, and only when status is `.notDetermined`.
    private static func requestAppTrackingAuthorizationIfNeeded() async {
        guard #available(iOS 14, *) else { return }
        let statusBefore = ATTrackingManager.trackingAuthorizationStatus
        logATTConsentDebug("statusBefore=\(attAuthorizationStatusLabel(statusBefore))")
        guard statusBefore == .notDetermined else { return }
        logATTConsentDebug("requestPresented=true")
        let statusAfter = await ATTrackingManager.requestTrackingAuthorization()
        logATTConsentDebug("statusAfter=\(attAuthorizationStatusLabel(statusAfter))")
    }

    /// Mobile Ads respects ATT automatically; log final status for diagnostics after consent flow completes.
    private static func applyTrackingAuthorizationToAdRequestConfiguration() {
        guard #available(iOS 14, *) else { return }
        let status = ATTrackingManager.trackingAuthorizationStatus
        AdDebugDiagnostics.logConsent("attStatus=\(attAuthorizationStatusLabel(status))")
    }

    @available(iOS 14, *)
    private static func attAuthorizationStatusLabel(_ status: ATTrackingManager.AuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }

    private static func logATTConsentDebug(_ message: String) {
#if DEBUG
        print("[ATTConsentDebug] \(message)")
#endif
    }

    private static func updateUMPConsentInformation() async {
        AdDebugDiagnostics.logConsent("umpUpdateStarted=true")
        let parameters = RequestParameters()
        await withCheckedContinuation { continuation in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                if let error {
                    AdDebugDiagnostics.logConsent("umpUpdateFailed=\(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
        let required = ConsentInformation.shared.consentStatus == .required
        AdDebugDiagnostics.logConsent("consentRequired=\(required)")
    }

    private static func loadAndPresentUMPFormIfNeeded() async {
        guard let root = await waitForRootViewController(timeoutSeconds: 3) else {
            AdDebugDiagnostics.logConsent("umpFormSkipped=noRootViewController")
            return
        }
        await withCheckedContinuation { continuation in
            ConsentForm.loadAndPresentIfRequired(from: root) { error in
                if let error {
                    AdDebugDiagnostics.logConsent("umpFormFailed=\(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }

    private static func startMobileAdsIfNeeded() async {
        guard !didStartMobileAds else { return }
        didStartMobileAds = true
        _ = await MobileAds.shared.start()
        AdDebugDiagnostics.logConsent("adsStarted=true")
        AdDebugDiagnostics.logSDKStartCompleted()
    }

    private static func waitForRootViewController(timeoutSeconds: TimeInterval) async -> UIViewController? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let root = AdMobRootViewController.topViewController() {
                return root
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return AdMobRootViewController.topViewController()
    }

    private static func presentPrivacyOptions(from root: UIViewController) async {
        await withCheckedContinuation { continuation in
            ConsentForm.presentPrivacyOptionsForm(from: root) { error in
                if let error {
                    AdDebugDiagnostics.logConsent("privacyOptionsFailed=\(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }
}

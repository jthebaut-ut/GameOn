import SwiftUI

/// Why the premium stadium landing is on screen.
enum SignedOutAuthLandingSource: String, Equatable {
    case none
    /// User tapped the Profile tab while signed out.
    case profileTab
    /// An in-app auth gate (join, RSVP, favorite, Chat, etc.).
    case authGate
}

/// Explicit authentication landing. Never the signed-out app root.
enum FanGeoAuthLandingRouting {
    static var replacesRootOnSignedOutLaunch: Bool { false }
    static var isExplicitPresentationOnly: Bool { true }
    static var includesGuestAction: Bool { false }
    /// Old marketing/guest Profile (`SettingsUnifiedAccountEntryCard`) is not the signed-out Profile destination.
    static var mountsGuestProfileOnSignedOutAccountTab: Bool { false }
    static let freshLaunchTabRawValue = "discover"
    static let accountTabRawValue = "account"
    static let backgroundAssetName = "StadiumHeroBackground"
    static let brandMarkWhiteAssetName = "FanGeoBrandMarkWhite"
    static let brandMarkDarkAssetName = "FanGeoBrandMarkDark"

    /// Authenticated fan or business session always wins over the signed-out landing.
    static func canPresentAuthLanding(
        isLoggedIn: Bool,
        isVenueOwnerLoggedIn: Bool,
        resolvingEmailConfirmation: Bool = false
    ) -> Bool {
        if resolvingEmailConfirmation { return false }
        if isLoggedIn || isVenueOwnerLoggedIn { return false }
        return true
    }

    /// Signed-out Profile (and other Account-tab requests) present the stadium landing instead of the guest Profile page.
    static func shouldPresentAuthLandingForSignedOutAccountTab(
        isLoggedIn: Bool,
        isVenueOwnerLoggedIn: Bool,
        resolvingEmailConfirmation: Bool = false
    ) -> Bool {
        canPresentAuthLanding(
            isLoggedIn: isLoggedIn,
            isVenueOwnerLoggedIn: isVenueOwnerLoggedIn,
            resolvingEmailConfirmation: resolvingEmailConfirmation
        )
    }

    /// SwiftUI may write `fullScreenCover(isPresented:)` back to `true` while a nested
    /// auth sheet dismisses. Authenticated sessions must refuse that bounce.
    static func shouldHonorPresentationWrite(
        requestedPresent: Bool,
        isLoggedIn: Bool,
        isVenueOwnerLoggedIn: Bool,
        resolvingEmailConfirmation: Bool = false
    ) -> Bool {
        if requestedPresent {
            return canPresentAuthLanding(
                isLoggedIn: isLoggedIn,
                isVenueOwnerLoggedIn: isVenueOwnerLoggedIn,
                resolvingEmailConfirmation: resolvingEmailConfirmation
            )
        }
        return true
    }

    /// After a successful session, the landing must not remain presented.
    static func isLandingPresentedAfterSuccessfulAuthentication() -> Bool { false }

    /// Close X keeps the public tab that was already selected. Never leave Profile selected behind an empty cover.
    static func tabAfterDismissingSignedOutProfileAuthLanding(previousTabRaw: String) -> String {
        let raw = previousTabRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == accountTabRawValue || raw == "live" {
            return freshLaunchTabRawValue
        }
        return raw
    }

    /// Profile-tab intent continues to authenticated Profile after a successful sign-in.
    static func shouldSelectAccountAfterSuccessfulAuth(source: SignedOutAuthLandingSource) -> Bool {
        source == .profileTab
    }
}

/// Full-screen authentication entry presented only when the user chooses Sign In,
/// Create Account, or an existing auth gate sends them here.
struct SignedOutLandingView: View {
    @ObservedObject var viewModel: MapViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var showSignInChooser = false
    @State private var showUserAuthSheet = false
    @State private var showVenueAuthSheet = false
    @State private var showRegisterMode = false
    @State private var showVenueRegisterMode = false
    @State private var email = ""
    @State private var password = ""
    @State private var venuePassword = ""
    @State private var pendingAuthDestination: SignedOutLandingAuthDestination?

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    var body: some View {
        ZStack {
            landingBackground
            landingForeground
            VStack {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        viewModel.dismissPremiumAuthLanding()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.28), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("Close", languageCode: languageCode))
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .safeAreaPadding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSignInChooser, onDismiss: presentPendingAuthIfNeeded) {
            SignedOutSignInAccountTypeSheet(
                languageCode: languageCode,
                onChooseFan: {
                    pendingAuthDestination = .fanSignIn
                    showSignInChooser = false
                },
                onChooseBusiness: {
                    pendingAuthDestination = .businessSignIn
                    showSignInChooser = false
                },
                onCancel: {
                    pendingAuthDestination = nil
                    showSignInChooser = false
                }
            )
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .sheet(isPresented: $showUserAuthSheet) {
            SettingsUserAuthSheet(
                viewModel: viewModel,
                email: $email,
                password: $password,
                showRegisterMode: $showRegisterMode
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVenueAuthSheet) {
            SettingsVenueAuthSheet(
                viewModel: viewModel,
                venuePassword: $venuePassword,
                showVenueRegisterMode: $showVenueRegisterMode,
                onRequestVenueProfileDashboard: {},
                preferredEntryMode: .signIn
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .onChange(of: viewModel.presentFanUserAuthSheetFromDiscover) { _, shouldPresent in
            guard shouldPresent else { return }
            consumePendingFanUserAuthSheetFromDiscover()
        }
        .onChange(of: viewModel.isLoggedIn) { _, isLoggedIn in
            collapseNestedAuthSheetsIfAuthenticated(
                isAuthenticated: isLoggedIn || viewModel.isVenueOwnerLoggedIn
            )
        }
        .onChange(of: viewModel.isVenueOwnerLoggedIn) { _, isVenue in
            collapseNestedAuthSheetsIfAuthenticated(
                isAuthenticated: isVenue || viewModel.isLoggedIn
            )
        }
        .onChange(of: showUserAuthSheet) { _, isPresented in
            password = ""
            if isPresented { venuePassword = "" }
        }
        .onChange(of: showVenueAuthSheet) { _, isPresented in
            venuePassword = ""
            if isPresented { password = "" }
        }
        .onAppear {
#if DEBUG
            print("[SignedOutLanding] presented guestLink=false tabBar=false explicit=true")
#endif
            if viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn {
                collapseNestedAuthSheetsIfAuthenticated(isAuthenticated: true)
                viewModel.dismissSignedOutAuthUIAfterSuccessfulAuthentication()
                return
            }
            consumePendingFanUserAuthSheetFromDiscover()
        }
    }

    private var landingBackground: some View {
        GeometryReader { proxy in
            Image(FanGeoAuthLandingRouting.backgroundAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [
                            Color(red: 0.02, green: 0.05, blue: 0.14).opacity(0.62),
                            Color(red: 0.01, green: 0.03, blue: 0.10).opacity(0.18),
                            Color(red: 0.01, green: 0.02, blue: 0.08).opacity(0.78)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var landingForeground: some View {
        VStack(spacing: 0) {
            landingBrandHeader
                .padding(.top, 18)

            VStack(spacing: 2) {
                Text(L10n.t("landing_headline_find_your_game", languageCode: languageCode))
                Text(L10n.t("landing_headline_find_your_people", languageCode: languageCode))
            }
            .font(.system(size: 31, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text(L10n.t("landing_subtitle", languageCode: languageCode))
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.top, 12)

            Spacer(minLength: 24)

            VStack(spacing: 14) {
                landingSignInButton
                landingCreateAccountButton
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landingBrandHeader: some View {
        HStack(spacing: 10) {
            Image(FanGeoAuthLandingRouting.brandMarkWhiteAssetName)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            Text("FanGeo")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FanGeo")
    }

    private var landingSignInButton: some View {
        Button {
            pendingAuthDestination = nil
            showSignInChooser = true
        } label: {
            HStack(spacing: 10) {
                Image(FanGeoAuthLandingRouting.brandMarkWhiteAssetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(L10n.t("Sign In", languageCode: languageCode))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                Color(red: 0.14, green: 0.46, blue: 0.98),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("Sign In", languageCode: languageCode))
    }

    private var landingCreateAccountButton: some View {
        Button {
            pendingAuthDestination = .fanRegister
            presentPendingAuthIfNeeded()
        } label: {
            HStack(spacing: 10) {
                Image(FanGeoAuthLandingRouting.brandMarkDarkAssetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(L10n.t("Create Account", languageCode: languageCode))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                Color.white,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("Create Account", languageCode: languageCode))
    }

    private func presentPendingAuthIfNeeded() {
        guard FanGeoAuthLandingRouting.canPresentAuthLanding(
            isLoggedIn: viewModel.isLoggedIn,
            isVenueOwnerLoggedIn: viewModel.isVenueOwnerLoggedIn,
            resolvingEmailConfirmation: viewModel.resolvingEmailConfirmation
        ) else {
            pendingAuthDestination = nil
            return
        }
        guard let pendingAuthDestination else { return }
        switch pendingAuthDestination {
        case .fanSignIn:
            showRegisterMode = false
            showUserAuthSheet = true
        case .fanRegister:
            showRegisterMode = true
            showUserAuthSheet = true
        case .businessSignIn:
            showVenueRegisterMode = false
            showVenueAuthSheet = true
        }
        self.pendingAuthDestination = nil
    }

    private func consumePendingFanUserAuthSheetFromDiscover() {
        guard FanGeoAuthLandingRouting.canPresentAuthLanding(
            isLoggedIn: viewModel.isLoggedIn,
            isVenueOwnerLoggedIn: viewModel.isVenueOwnerLoggedIn,
            resolvingEmailConfirmation: viewModel.resolvingEmailConfirmation
        ) else {
            viewModel.presentFanUserAuthSheetFromDiscover = false
            viewModel.fanUserAuthSheetOpenInRegisterMode = false
            return
        }
        guard viewModel.presentFanUserAuthSheetFromDiscover else { return }
        showRegisterMode = viewModel.fanUserAuthSheetOpenInRegisterMode
        showUserAuthSheet = true
        viewModel.presentFanUserAuthSheetFromDiscover = false
        viewModel.fanUserAuthSheetOpenInRegisterMode = false
    }

    private func collapseNestedAuthSheetsIfAuthenticated(isAuthenticated: Bool) {
        guard isAuthenticated else { return }
        pendingAuthDestination = nil
        showSignInChooser = false
        showUserAuthSheet = false
        showVenueAuthSheet = false
        showRegisterMode = false
        showVenueRegisterMode = false
    }
}

private enum SignedOutLandingAuthDestination {
    case fanSignIn
    case fanRegister
    case businessSignIn
}

/// Compact account-type chooser shown after Sign In. Routes into existing auth sheets.
struct SignedOutSignInAccountTypeSheet: View {
    let languageCode: String
    let onChooseFan: () -> Void
    let onChooseBusiness: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("Sign In", languageCode: languageCode))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.t("landing_sign_in_chooser_subtitle", languageCode: languageCode))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                chooserRow(
                    title: L10n.t("landing_sign_in_fan_user", languageCode: languageCode),
                    systemImage: "person.fill",
                    tint: FGColor.accentBlue,
                    action: onChooseFan
                )
                chooserRow(
                    title: L10n.t("Business", languageCode: languageCode),
                    systemImage: "building.2.fill",
                    tint: FGColor.businessGreen,
                    action: onChooseBusiness
                )
            }

            Button(action: onCancel) {
                Text(L10n.t("Cancel", languageCode: languageCode))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Cancel", languageCode: languageCode))
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FGColor.background(colorScheme).ignoresSafeArea())
    }

    private func chooserRow(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.85), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

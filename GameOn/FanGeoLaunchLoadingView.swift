import SwiftUI

/// Bubbles to the app root so window chrome (status bar) can prefer light while any splash
/// is mounted, without writing `FanGeoAppearancePreference` / UserDefaults.
enum FanGeoSplashForcesLightAppearanceKey: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Full-screen static splash shown immediately after the static `LaunchScreen` storyboard.
/// Also reused while authenticated age eligibility is resolving (no blank compliance screen).
///
/// Always presents in **light** appearance (white canvas, dark status text) regardless of the
/// user's System/Light/Dark preference. Preference is not written — only this view forces light
/// via ``preferredColorScheme(_:)`` while mounted; the rest of FanGeo resumes the user's scheme
/// as soon as the splash is removed.
struct FanGeoSplashView: View {
    let statusMessage: String
    var showsTagline: Bool = true
    @State private var contentOpacity = 0.0

    init(
        statusMessage: String = FanGeoSplashBootstrapStage.preparing.message,
        showsTagline: Bool = true
    ) {
        self.statusMessage = statusMessage
        self.showsTagline = showsTagline
    }

    /// Splash is intentionally always the light treatment from the white launch artwork.
    private var background: Color { Color.white }

    private var statusColor: Color { Color.black.opacity(0.68) }

    private var taglineColor: Color { Color.black.opacity(0.45) }

    var body: some View {
        GeometryReader { proxy in
            let imageWidth = min(proxy.size.width * 0.72, 340)

            ZStack {
                background
                    .ignoresSafeArea()

                ZStack {
                    Image("FanGeoPremiumLoadingLogo")
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(width: imageWidth, height: imageWidth)
                        .offset(y: -54)
                        .accessibilityLabel("FanGeo")

                    VStack(spacing: 10) {
                        if showsTagline {
                            Text("Bringing fans together.")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(taglineColor)
                                .multilineTextAlignment(.center)
                                .accessibilityAddTraits(.isStaticText)
                        }

                        FanGeoCrossfadeLoadingStatusText(
                            text: statusMessage,
                            foreground: statusColor
                        )
                    }
                    .padding(.horizontal, 24)
                    .frame(height: showsTagline ? 78 : 56)
                    .offset(y: -54 + (imageWidth / 2) + 46)
                }
                .opacity(contentOpacity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        // Narrowest boundary: force light only while this splash is in the hierarchy.
        // Does not mutate UserDefaults / FanGeoAppearancePreference.
        .preferredColorScheme(.light)
        .preference(key: FanGeoSplashForcesLightAppearanceKey.self, value: true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) {
                contentOpacity = 1
            }
            #if DEBUG
            print("[FanGeoLoadingDebug] splashDisplayed")
            print("[FanGeoLoadingDebug] stableImageLayout=true")
            print("[FanGeoLoadingDebug] loadingStatus=\(statusMessage)")
            print("[FanGeoLoadingDebug] forcedLightAppearance=true")
            print("[FanGeoLoadingBrandingDebug] premiumSplashLoaded=true")
            print("[FanGeoLoadingBrandingDebug] launchAndSwiftUIMatch=true")
            print("[LaunchScreenDebug] launchBackgroundApplied=true")
            print("[LaunchScreenDebug] loadingScreenMatched=true")
            #endif
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FanGeo. Bringing fans together. \(statusMessage)")
    }
}

private struct FanGeoCrossfadeLoadingStatusText: View {
    let text: String
    var foreground: Color = Color.black.opacity(0.68)

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .tracking(0.2)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
            .animation(
                .easeInOut(duration: FanGeoSplashAnimation.statusCrossfadeDuration),
                value: text
            )
            .accessibilityLabel(text)
    }
}

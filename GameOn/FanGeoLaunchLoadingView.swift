import SwiftUI

/// Full-screen static splash shown immediately after the static `LaunchScreen` storyboard.
/// Also reused while authenticated age eligibility is resolving (no blank compliance screen).
struct FanGeoSplashView: View {
    let statusMessage: String
    var showsTagline: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentOpacity = 0.0

    init(
        statusMessage: String = FanGeoSplashBootstrapStage.preparing.message,
        showsTagline: Bool = true
    ) {
        self.statusMessage = statusMessage
        self.showsTagline = showsTagline
    }

    private var background: Color {
        colorScheme == .dark
            ? Color(red: 0.03, green: 0.05, blue: 0.08)
            : Color.white
    }

    private var statusColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.72)
            : Color.black.opacity(0.68)
    }

    private var taglineColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.45)
    }

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
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) {
                contentOpacity = 1
            }
            #if DEBUG
            print("[FanGeoLoadingDebug] splashDisplayed")
            print("[FanGeoLoadingDebug] stableImageLayout=true")
            print("[FanGeoLoadingDebug] loadingStatus=\(statusMessage)")
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

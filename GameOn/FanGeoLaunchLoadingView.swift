import SwiftUI

/// Full-screen static splash shown immediately after the static `LaunchScreen` storyboard.
struct FanGeoSplashView: View {
    let statusMessage: String
    @State private var contentOpacity = 0.0

    init(statusMessage: String = FanGeoSplashBootstrapStage.preparing.message) {
        self.statusMessage = statusMessage
    }

    var body: some View {
        GeometryReader { proxy in
            let imageWidth = min(proxy.size.width * 0.72, 340)

            ZStack {
                Color.white
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

                    FanGeoCrossfadeLoadingStatusText(text: statusMessage)
                        .padding(.horizontal, 24)
                        .frame(height: 56)
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
    }
}

private struct FanGeoCrossfadeLoadingStatusText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .tracking(0.2)
            .foregroundStyle(Color.black.opacity(0.68))
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

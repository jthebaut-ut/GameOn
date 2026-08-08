import SwiftUI
import UIKit

/// Full-screen profile-photo viewer for Fan Profile hero avatars.
/// Prefers full-resolution `avatar_url` over thumbnail; uses ``DiscoverMapImageCache``.
struct PublicProfileAvatarFullscreenViewer: View {
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let avatarDisplayRefreshToken: UUID
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var loadedImage: UIImage?
    @State private var loadFailed = false
    @State private var dragOffset: CGFloat = 0
    @State private var backdropOpacity: Double = 1
    @State private var isImageZoomed = false

    private var preferredDisplayURL: URL? {
        guard let raw = ImageDisplayURL.forDetailDisplay(
            thumbnail: avatarThumbnailURL,
            full: avatarURL,
            refreshToken: avatarDisplayRefreshToken
        ) else { return nil }
        return URL(string: raw)
    }

    private var hasRemoteCandidate: Bool {
        preferredDisplayURL != nil
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let avatarSide = max(220, min(side - 56, side * 0.82))

            ZStack {
                backdrop
                    .ignoresSafeArea()
                    .opacity(backdropOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isImageZoomed else { return }
                        dismissAnimated()
                    }

                Group {
                    if let loadedImage {
                        FanGeoZoomableImageScrollView(image: loadedImage, isZoomed: $isImageZoomed)
                            .frame(width: avatarSide, height: avatarSide)
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
                            }
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                    } else if hasRemoteCandidate && !loadFailed {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12))
                                .frame(width: avatarSide, height: avatarSide)
                            ProgressView()
                                .tint(.white)
                                .controlSize(.large)
                        }
                    } else {
                        fallbackAvatar(side: avatarSide)
                    }
                }
                .offset(y: dragOffset)
                .padding(.horizontal, 20)
                .accessibilityHidden(true)

                VStack {
                    HStack {
                        Spacer()
                        Button(action: dismissAnimated) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.95))
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("Close", languageCode: nil))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    Spacer()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .statusBarHidden(true)
        .simultaneousGesture(isImageZoomed ? nil : dismissDragGesture)
        .task(id: preferredDisplayURL?.absoluteString) {
            await loadImageIfNeeded()
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(
            String(
                format: L10n.t("public_profile_view_photo_a11y_format", languageCode: nil),
                displayName
            )
        )
    }

    private var backdrop: some View {
        ZStack {
            Color.black.opacity(0.72)
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.55)
        }
    }

    private func fallbackAvatar(side: CGFloat) -> some View {
        UserAvatarView(
            avatarThumbnailURL: nil,
            avatarURL: "",
            avatarDisplayRefreshToken: avatarDisplayRefreshToken,
            displayName: displayName,
            email: "",
            size: side,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: .white
        )
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
    }

    @MainActor
    private func loadImageIfNeeded() async {
        loadFailed = false
        loadedImage = nil
        guard let url = preferredDisplayURL else {
            loadFailed = true
            return
        }
        let requested = url
        if let cached = await DiscoverMapImageCache.shared.cachedImage(for: requested, bucket: .detail) {
            guard !Task.isCancelled else { return }
            guard preferredDisplayURL == requested else { return }
            loadedImage = cached
            return
        }
        // Prefer already-warmed list/avatar cache before network fetch.
        if let listCached = await DiscoverMapImageCache.shared.cachedImage(for: requested, bucket: .avatar) {
            guard !Task.isCancelled else { return }
            guard preferredDisplayURL == requested else { return }
            loadedImage = listCached
        }
        if let loaded = await DiscoverMapImageCache.shared.image(for: requested, bucket: .detail) {
            guard !Task.isCancelled else { return }
            guard preferredDisplayURL == requested else { return }
            loadedImage = loaded
            return
        }
        if loadedImage == nil {
            loadFailed = true
        }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                let vertical = value.translation.height
                guard vertical > 0 else {
                    dragOffset = 0
                    backdropOpacity = 1
                    return
                }
                dragOffset = vertical
                backdropOpacity = max(0.35, 1 - Double(vertical / 320))
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 180 {
                    dismissAnimated()
                } else if reduceMotion {
                    dragOffset = 0
                    backdropOpacity = 1
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                        backdropOpacity = 1
                    }
                }
            }
    }

    private func dismissAnimated() {
        if reduceMotion {
            onDismiss()
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                backdropOpacity = 0
            }
            onDismiss()
        }
    }
}

/// Makes a Fan Profile hero avatar tappable and presents ``PublicProfileAvatarFullscreenViewer``.
struct PublicProfileTappableAvatar<Avatar: View>: View {
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let avatarDisplayRefreshToken: UUID
    let zoomNamespace: Namespace.ID
    let transitionID: String
    @ViewBuilder var avatar: () -> Avatar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var showViewer = false

    var body: some View {
        Button {
            showViewer = true
        } label: {
            avatar()
                .contentShape(Circle())
                .matchedTransitionSource(id: transitionID, in: zoomNamespace)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.t("public_profile_view_photo_a11y_format", languageCode: appLanguageRaw),
                displayName
            )
        )
        .accessibilityHint(L10n.t("public_profile_view_photo_a11y_hint", languageCode: appLanguageRaw))
        .fullScreenCover(isPresented: $showViewer) {
            PublicProfileAvatarFullscreenViewer(
                displayName: displayName,
                avatarURL: avatarURL,
                avatarThumbnailURL: avatarThumbnailURL,
                avatarDisplayRefreshToken: avatarDisplayRefreshToken,
                onDismiss: { showViewer = false }
            )
            .presentationBackground(.clear)
            .modifier(
                PublicProfileAvatarZoomTransitionModifier(
                    enabled: !reduceMotion,
                    transitionID: transitionID,
                    namespace: zoomNamespace
                )
            )
        }
    }
}

private struct PublicProfileAvatarZoomTransitionModifier: ViewModifier {
    let enabled: Bool
    let transitionID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if enabled {
            content.navigationTransition(.zoom(sourceID: transitionID, in: namespace))
        } else {
            content
        }
    }
}

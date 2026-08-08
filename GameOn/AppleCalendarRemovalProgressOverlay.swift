import SwiftUI

/// Session-level Apple Calendar bulk-removal UI phase (Settings toggle off → remove events).
enum AppleCalendarRemovalPhase: Equatable {
    case idle
    case removing
    case success
}

#if DEBUG
enum AppleCalendarRemovalUIDebug {
    static func log(_ message: String) {
        print("[CalendarRemovalUIDebug] \(message)")
    }
}
#endif

/// Observes removal phase without making ``ProfileSettingsSheetHost`` an `@ObservedObject`
/// on `MapViewModel` (Host must not remount `NavigationStack` on every publish).
struct AppleCalendarRemovalSheetOverlayHost: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        Group {
            if viewModel.appleCalendarRemovalPhase != .idle {
                AppleCalendarRemovalProgressOverlay(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.appleCalendarRemovalPhase)
#if DEBUG
        .onChange(of: viewModel.appleCalendarRemovalPhase) { _, phase in
            AppleCalendarRemovalUIDebug.log("phaseChanged=\(String(describing: phase)) mount=ProfileSettingsSheetHost")
            if phase == .idle {
                AppleCalendarRemovalUIDebug.log("overlayUnmounted mount=ProfileSettingsSheetHost")
            }
        }
#endif
    }
}

/// Full-screen, non-dismissible progress while FanGeo EventKit events are removed.
struct AppleCalendarRemovalProgressOverlay: View {
    @ObservedObject var viewModel: MapViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var isSuccess: Bool {
        viewModel.appleCalendarRemovalPhase == .success
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.55 : 0.42)
                .ignoresSafeArea()
                .allowsHitTesting(true)

            VStack(spacing: 16) {
                ZStack {
                    if isSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(FGColor.accentGreen)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(FGColor.accentGreen)
                            .scaleEffect(1.25)
                            .transition(.opacity)
                    }
                }
                .frame(height: 52)
                .animation(.easeInOut(duration: 0.28), value: isSuccess)

                Text(
                    L10n.t(
                        isSuccess
                            ? "calendar_removal_completed"
                            : "calendar_removal_in_progress_title",
                        languageCode: languageCode
                    )
                )
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color.white : FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.updatesFrequently)

                if !isSuccess {
                    Text(L10n.t("calendar_removal_in_progress_subtitle", languageCode: languageCode))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(
                            (colorScheme == .dark ? Color.white : FGColor.secondaryText(colorScheme))
                                .opacity(0.88)
                        )
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.40 : 0.28),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 18, y: 8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                L10n.t(
                    isSuccess
                        ? "calendar_removal_completed"
                        : "calendar_removal_in_progress_title",
                    languageCode: languageCode
                )
            )
        }
        .interactiveDismissDisabled(true)
        .transition(.opacity)
#if DEBUG
        .onAppear {
            AppleCalendarRemovalUIDebug.log(
                "visibleSettingsOverlayMounted phase=\(String(describing: viewModel.appleCalendarRemovalPhase))"
            )
        }
        .onDisappear {
            AppleCalendarRemovalUIDebug.log("visibleSettingsOverlayDisappeared")
        }
#endif
    }
}

import Foundation
import SwiftUI
import os

/// Shared, session-level logout UI phase. Progress must not be owned by Settings/Profile `@State`.
enum SafeLogoutPhase: Equatable {
    case idle
    case loggingOut
    case failed
}

/// Shared in-memory guard so realtime/presence/chat startup paths refuse authenticated work
/// as soon as user-initiated logout begins — even before `isLoggedIn` flips.
enum FanGeoExplicitLogoutGuard {
    @MainActor
    static var isInProgress = false
}

/// DEBUG-only searchable logout tracing (`===== SAFE LOGOUT =====`).
enum SafeLogoutDebug {
    private static var pipelineStartedAt: Date?

    static func beginPipeline(source: String) {
#if DEBUG
        pipelineStartedAt = Date()
        log("pipeline begin source=\(source)")
#endif
    }

    /// Marks a discrete logout step with wall-clock elapsed ms since ``beginPipeline``.
    static func step(_ name: String, detail: String = "") {
#if DEBUG
        let ms: Int
        if let started = pipelineStartedAt {
            ms = Int(Date().timeIntervalSince(started) * 1000)
        } else {
            ms = -1
        }
        if detail.isEmpty {
            log("step=\(name) elapsedMs=\(ms)")
        } else {
            log("step=\(name) elapsedMs=\(ms) \(detail)")
        }
#endif
    }

    static func endPipeline(success: Bool) {
#if DEBUG
        step(success ? "logout_completed" : "logout_failed")
        pipelineStartedAt = nil
#endif
    }

    static func log(_ message: String) {
#if DEBUG
        let ts = ISO8601DateFormatter().string(from: Date())
        print("===== SAFE LOGOUT ===== [\(ts)] \(message)")
#endif
    }
}

/// DEBUG-only searchable tab performance tracing (`===== TAB PERFORMANCE =====`).
enum TabPerformanceDebug {
    static func log(_ message: String) {
#if DEBUG
        print("===== TAB PERFORMANCE ===== \(message)")
#endif
    }
}

/// Full-screen, non-dismissible logout progress hosted above the tab shell.
struct SafeLogoutProgressOverlay: View {
    @ObservedObject var viewModel: MapViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.55 : 0.42)
                .ignoresSafeArea()
                .allowsHitTesting(true)

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(L10n.t("settings_logging_out", languageCode: appLanguageRaw))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)

                Text(L10n.t("settings_signing_out_securely", languageCode: appLanguageRaw))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)

                if viewModel.safeLogoutPhase == .failed {
                    let message = viewModel.safeLogoutFailureMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(message.isEmpty
                         ? L10n.t("Could not log out. Please check your connection and try again.", languageCode: appLanguageRaw)
                         : message)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)

                    Button {
                        viewModel.retrySafeUserLogout()
                    } label: {
                        Text("Try Again")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.cancelSafeLogoutFailureUI()
                    } label: {
                        Text(L10n.t("Cancel", languageCode: appLanguageRaw))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.14, blue: 0.18).opacity(0.94))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.t("settings_logging_out", languageCode: appLanguageRaw))
        }
        .interactiveDismissDisabled(true)
    }
}

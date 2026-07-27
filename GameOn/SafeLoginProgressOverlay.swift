import Foundation
import SwiftUI

/// Shared, session-level login UI phase. Progress must not be owned by auth-sheet `@State`.
enum SafeLoginPhase: Equatable {
    case idle
    case authenticating
    case preparingSession
}

/// Login entry method for DEBUG tracing (no PII).
enum SafeLoginMethod: String {
    case emailPasswordFan
    case emailPasswordBusiness
    case appleFan
    case appleBusiness
}

/// DEBUG-only searchable login tracing (`===== SAFE LOGIN =====`).
enum SafeLoginDebug {
    static func log(_ message: String) {
#if DEBUG
        print("===== SAFE LOGIN ===== \(message)")
#endif
    }
}

/// Full-screen, non-dismissible login progress hosted above the tab shell.
struct SafeLoginProgressOverlay: View {
    @ObservedObject var viewModel: MapViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme

    private var primaryKey: String {
        switch viewModel.safeLoginPhase {
        case .preparingSession:
            return "login_preparing_account"
        case .authenticating, .idle:
            return "login_logging_you_in"
        }
    }

    private var secondaryKey: String {
        switch viewModel.safeLoginPhase {
        case .preparingSession:
            return "login_loading_profile_prefs"
        case .authenticating, .idle:
            return "login_securely_connecting"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.55 : 0.42)
                .ignoresSafeArea()
                .allowsHitTesting(true)

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(L10n.t(primaryKey, languageCode: appLanguageRaw))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)

                Text(L10n.t(secondaryKey, languageCode: appLanguageRaw))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.14, blue: 0.18).opacity(0.94))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.t(primaryKey, languageCode: appLanguageRaw))
            .accessibilityValue(L10n.t(secondaryKey, languageCode: appLanguageRaw))
        }
        .interactiveDismissDisabled(true)
    }
}

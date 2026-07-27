import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared realtime connection status for direct and group chat composers.
enum ChatRealtimeConnectionStatus: Equatable, Sendable {
    case connected
    case live
    case connecting
    case reconnecting
    case offline

    var localizationKey: String {
        switch self {
        case .connected, .live:
            return "chat_realtime_live"
        case .connecting:
            return "chat_realtime_connecting"
        case .reconnecting, .offline:
            return "chat_realtime_reconnecting"
        }
    }

    /// Buckets used so VoiceOver does not re-announce when flipping between `.connected` and `.live`.
    var accessibilityBucket: String {
        switch self {
        case .connected, .live:
            return "live"
        case .connecting:
            return "connecting"
        case .reconnecting, .offline:
            return "reconnecting"
        }
    }

    func tint(colorScheme: ColorScheme) -> Color {
        switch self {
        case .connected, .live, .connecting:
            return FGColor.accentGreen
        case .reconnecting:
            return FGColor.accentYellow
        case .offline:
            return FGColor.secondaryText(colorScheme)
        }
    }
}

/// Green `Live` / reconnect label shown immediately above the message composer.
struct ChatRealtimeConnectionStatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let status: ChatRealtimeConnectionStatus

    private var title: String {
        L10n.t(status.localizationKey, languageCode: appLanguageRaw)
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.tint(colorScheme: colorScheme).opacity(colorScheme == .dark ? 0.82 : 0.72))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .onChange(of: status) { oldValue, newValue in
                guard oldValue.accessibilityBucket != newValue.accessibilityBucket else { return }
                #if canImport(UIKit)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: L10n.t(newValue.localizationKey, languageCode: appLanguageRaw)
                )
                #endif
            }
    }
}

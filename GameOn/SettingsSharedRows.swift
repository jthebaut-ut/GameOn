import SwiftUI

// MARK: - Bottom spacing (floating tab bar + sheets)

/// Scroll tail insets for the Account tab and settings-presented sheets.
/// `floatingTabBarStackHeight` must stay aligned with ``MainTabView/floatingTabBarStackHeight``.
enum SettingsScrollBottomLayout {
    static let floatingTabBarStackHeight: CGFloat = 108
    static let breathingRoomBelowLastCard: CGFloat = 72
    static var accountTabScrollBottomInset: CGFloat {
        floatingTabBarStackHeight + breathingRoomBelowLastCard
    }

    /// Sheets are not under the main floating tab; use for scrollable tails above the home indicator / drag handle.
    static let sheetScrollComfortInset: CGFloat = 32
}

enum SettingsPremiumChrome {
    static let cardRadius: CGFloat = 24
    static let rowIconSize: CGFloat = 36
    static let rowMinHeight: CGFloat = 60
    static let privacyPermissionsIconSize: CGFloat = 40
    static let privacyPermissionsRowMinHeight: CGFloat = 72
    static let profileSectionListSpacing: CGFloat = 16
    static let accountDestructiveTopSpacing: CGFloat = 22
    static let scrollCardShadowRadius: CGFloat = 6
    static let scrollCardShadowYOffset: CGFloat = 3

    /// Explicit RGB only — never `Color(.system*)`. UIKit dynamic colors can keep the previous
    /// interface style inside an already-presented Settings sheet while SwiftUI `colorScheme` updates.
    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.085, green: 0.105, blue: 0.115).opacity(0.92)
            : Color(red: 0.99, green: 0.99, blue: 1.0)
    }

    static func cardHighlight(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.72)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.07)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.08)
    }

    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.92) : Color(red: 0.10, green: 0.12, blue: 0.15)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.60) : Color(red: 0.38, green: 0.42, blue: 0.50)
    }

    static func mutedText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.36) : Color(red: 0.58, green: 0.62, blue: 0.68)
    }

    static func proGold(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.94, green: 0.73, blue: 0.34)
            : Color(red: 0.72, green: 0.50, blue: 0.16)
    }

    static func proGoldDeep(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.62, green: 0.42, blue: 0.14)
            : Color(red: 0.50, green: 0.33, blue: 0.10)
    }

    static func proBadgeText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.07, blue: 0.02) : .white
    }

    static func iconSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
    }

    static func presentationBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.025, green: 0.032, blue: 0.04)
            : Color(red: 0.94, green: 0.95, blue: 0.97)
    }

    static func screenBackground(_ scheme: ColorScheme) -> some View {
        ZStack {
            presentationBackground(scheme)
            LinearGradient(
                colors: [
                    Color.white.opacity(scheme == .dark ? 0.035 : 0.56),
                    Color.clear,
                    Color.black.opacity(scheme == .dark ? 0.20 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    FGColor.accentGreen.opacity(scheme == .dark ? 0.10 : 0.08),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 320
            )
        }
    }
}

// MARK: - Profile settings isolated sections

struct ProfileSettingsSectionHeader: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme).opacity(0.72))
            .tracking(0.8)
            .textCase(nil)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

struct ProfileSettingsSectionCard<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(SettingsPremiumChrome.cardFill(colorScheme))
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                SettingsPremiumChrome.cardHighlight(colorScheme),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
        }
        .compositingGroup()
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.12 : 0.05),
            radius: SettingsPremiumChrome.scrollCardShadowRadius,
            y: SettingsPremiumChrome.scrollCardShadowYOffset
        )
    }
}

struct SettingsSheetSectionLabel: View {
    let title: String
    var subtitle: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
    }
}

// MARK: - Auth sheets + profile hero

struct SettingsSheetStatusBanner: View {
    let title: String?
    let message: String
    let tint: Color
    var systemImage: String
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    var action: (() -> Void)? = nil
    var footerMessage: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                Text(message)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let footerMessage,
                   !footerMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(footerMessage)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionSystemImage ?? "envelope.fill")
                            .font(FGTypography.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(FGSpacing.md)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1)
        }
    }
}

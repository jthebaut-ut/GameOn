import SwiftUI

/// Compact banner above the composer while a reply target is active.
struct ChatReplyComposerBanner: View {
    let senderDisplayName: String
    let previewLine: String
    let languageCode: String
    let colorScheme: ColorScheme
    var onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    String(
                        format: L10n.t("chat_reply_replying_to_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        senderDisplayName
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)

                Text(previewLine)
                    .font(.caption2)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("chat_reply_cancel_a11y", languageCode: languageCode))
        }
        .padding(.leading, FGSpacing.md)
        .padding(.trailing, FGSpacing.xs)
        .padding(.vertical, FGSpacing.xs)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.88 : 0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact quoted-reply header above a message bubble/card.
struct ChatReplyQuoteHeader: View {
    let reference: ChatReplyReference
    let languageCode: String
    let colorScheme: ColorScheme
    let isFromCurrentUser: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    if reference.availability == .available,
                       !reference.originalSenderDisplayName.isEmpty {
                        Text(reference.originalSenderDisplayName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                    Text(reference.previewLine)
                        .font(.caption2)
                        .foregroundStyle(secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44, alignment: .center)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(L10n.t("chat_reply_view_original_a11y_hint", languageCode: languageCode))
        .disabled(reference.availability != .available)
    }

    private var accent: Color {
        isFromCurrentUser ? Color.white.opacity(0.92) : FGColor.accentBlue
    }

    private var secondary: Color {
        isFromCurrentUser ? Color.white.opacity(0.78) : FGColor.secondaryText(colorScheme)
    }

    private var fill: Color {
        isFromCurrentUser
            ? Color.white.opacity(0.16)
            : FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.9)
    }

    private var accessibilityLabel: String {
        switch reference.availability {
        case .unavailable, .unsent:
            return reference.previewLine
        case .available:
            if reference.originalSenderDisplayName.isEmpty {
                return reference.previewLine
            }
            return "\(reference.originalSenderDisplayName). \(reference.previewLine)"
        }
    }
}

/// Brief highlight flash when scrolling to a replied-to message (reduced-motion safe).
struct ChatReplyHighlightBackground: ViewModifier {
    let isHighlighted: Bool
    let colorScheme: ColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(isHighlighted ? (colorScheme == .dark ? 0.28 : 0.16) : 0))
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.01) : .easeInOut(duration: 0.35),
                value: isHighlighted
            )
    }
}

extension View {
    func chatReplyHighlight(isHighlighted: Bool, colorScheme: ColorScheme) -> some View {
        modifier(ChatReplyHighlightBackground(isHighlighted: isHighlighted, colorScheme: colorScheme))
    }
}

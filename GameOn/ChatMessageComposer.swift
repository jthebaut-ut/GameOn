import SwiftUI

/// Shared chat message composer used by Private Chat and Group Chat.
/// Visual layout and controls match Private Chat (`DirectChatView`) as the source of truth.
struct ChatMessageComposer: View {
    @Binding var draft: String
    @Binding var showEmojiQuickTray: Bool
    var composerFocused: FocusState<Bool>.Binding

    let canSend: Bool
    let sendingDisabled: Bool
    let isRefreshing: Bool
    let showsRefreshButton: Bool
    let refreshEnabled: Bool
    let placeholder: String
    let maxBodyLength: Int
    let colorScheme: ColorScheme
    let emojis: [String]
    let refreshAccessibilityLabel: String
    let emojiToggleAccessibilityLabel: String
    let sendAccessibilityLabel: String
    let emojiReactionAccessibilityFormat: String

    var onSend: () -> Void
    var onQuickEmoji: (String) -> Void
    var onRefresh: (() -> Void)?
    var onTrimDraft: () -> Void

    var body: some View {
        VStack(spacing: showEmojiQuickTray ? FGSpacing.sm : 0) {
            if showEmojiQuickTray {
                quickReactionTray
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composerInputRow
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: showEmojiQuickTray)
    }

    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            Button {
                FGInteractionHaptics.selection()
                showEmojiQuickTray.toggle()
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(showEmojiQuickTray ? FGColor.accentBlue : FGColor.secondaryText(colorScheme))
                    .frame(width: 38, height: 38)
                    .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.58 : 0.94))
                    .clipShape(Circle())
            }
            .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
            .accessibilityLabel(emojiToggleAccessibilityLabel)
            .disabled(sendingDisabled)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(FGTypography.body)
                .lineLimit(1)
                .submitLabel(.send)
                .onSubmit {
                    guard canSend, !sendingDisabled else { return }
                    FGInteractionHaptics.softImpact()
                    onSend()
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.sm + 1)
                .background(
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .fill(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.64 : 0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(
                            composerFocused.wrappedValue
                                ? FGColor.accentBlue.opacity(0.42)
                                : FGColor.divider(colorScheme),
                            lineWidth: composerFocused.wrappedValue ? 1.5 : 1
                        )
                        .animation(.easeInOut(duration: 0.2), value: composerFocused.wrappedValue)
                )
                .focused(composerFocused)
                .onChange(of: draft) { _, newValue in
                    if newValue.count > maxBodyLength {
                        draft = String(newValue.prefix(maxBodyLength))
                    }
                    onTrimDraft()
                }
                .frame(minHeight: 38, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(sendingDisabled)

            if showsRefreshButton {
                refreshButton
            }

            Button {
                FGInteractionHaptics.softImpact()
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(
                                canSend && !sendingDisabled
                                    ? AnyShapeStyle(FGColor.brandGradient)
                                    : AnyShapeStyle(Color.gray.opacity(0.35))
                            )
                    )
            }
            .disabled(!canSend || sendingDisabled)
            .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.94, hapticOnPress: false))
            .contentShape(Rectangle())
            .accessibilityLabel(sendAccessibilityLabel)
        }
        .padding(.horizontal, FGSpacing.sm)
        .padding(.vertical, FGSpacing.sm)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .floatingShadow()
    }

    private var refreshButton: some View {
        Button {
            onRefresh?()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 38, height: 38)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.38), lineWidth: 0.75)
                }
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    isRefreshing
                        ? .linear(duration: 0.75).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.16),
                    value: isRefreshing
                )
                .contentShape(Circle())
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.94, hapticOnPress: false))
        .disabled(!refreshEnabled || isRefreshing)
        .opacity(isRefreshing ? 0.62 : 1.0)
        .accessibilityLabel(refreshAccessibilityLabel)
    }

    private var quickReactionTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FGSpacing.sm) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onQuickEmoji(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 23))
                            .frame(width: 40, height: 40)
                            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.56 : 0.94))
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(sendingDisabled)
                    .accessibilityLabel(String(format: emojiReactionAccessibilityFormat, emoji))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, FGSpacing.sm)
            .padding(.vertical, FGSpacing.sm)
        }
        .frame(height: 58)
        .scrollBounceBehavior(.basedOnSize)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .floatingShadow()
    }
}

enum ChatQuickReactions {
    static let emojis: [String] = [
        "👍", "❤️", "😂", "🔥", "⚽", "🏀", "🏈", "🏆", "🎉", "👀", "🙌", "😮", "🍻",
        "⚾", "🎾", "🏒", "🥊"
    ]
}

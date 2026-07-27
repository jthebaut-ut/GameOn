import PhotosUI
import SwiftUI

/// Focus targets for the compact Edit Profile sheet.
enum EditProfileFocusField: Hashable {
    case displayName
    case username
    case bio
}

// MARK: - Section chrome

struct EditProfileSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.4)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                content()
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct EditProfileRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}

// MARK: - Photo header

struct EditProfilePhotoHeader: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedAvatarItem: PhotosPickerItem?
    let isUploadingAvatar: Bool
    let isSavingIdentity: Bool
    let localAvatarPreviewImage: UIImage?
    let previewDisplayName: String
    let previewHandleLine: String
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    private static let avatarDiameter: CGFloat = 76
    private static let cameraButtonDiameter: CGFloat = 26

    var body: some View {
        VStack(spacing: 8) {
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    avatar
                    cameraBadge
                }
            }
            .disabled(isUploadingAvatar || isSavingIdentity)
            .buttonStyle(.plain)
            .accessibilityLabel("Change profile photo")

            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                Text(L10n.t("change_photo", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
            }
            .disabled(isUploadingAvatar || isSavingIdentity)
            .buttonStyle(.plain)
            .accessibilityLabel("Change profile photo")

            Text(previewDisplayName)
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            if !previewHandleLine.isEmpty {
                Text(previewHandleLine.hasPrefix("@") ? previewHandleLine : "@\(previewHandleLine)")
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var avatar: some View {
        UserAvatarView(
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
            localPreviewImage: localAvatarPreviewImage,
            displayName: previewDisplayName,
            email: viewModel.currentUserEmail,
            size: Self.avatarDiameter,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            FGColor.accentYellow.opacity(0.95),
                            FGColor.accentGreen.opacity(0.95),
                            FGColor.accentBlue.opacity(0.95),
                            FGColor.accentYellow.opacity(0.95)
                        ],
                        center: .center
                    ),
                    lineWidth: 3
                )
        }
        .padding(2)
    }

    private var cameraBadge: some View {
        Circle()
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(width: Self.cameraButtonDiameter, height: Self.cameraButtonDiameter)
            .overlay {
                ProfileHeroAvatarCameraGlyph(
                    isUploading: isUploadingAvatar,
                    iconSize: 11,
                    tint: FGColor.accentGreen
                )
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.95), lineWidth: 1.5)
            }
            .offset(x: 2, y: 2)
            .accessibilityHidden(true)
    }
}

// MARK: - Public profile rows

struct EditProfileDisplayNameRow: View {
    @Binding var displayName: String
    var focusedField: FocusState<EditProfileFocusField?>.Binding
    let languageCode: String
    var errorMessage: String = ""

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.t("display_name", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(width: 108, alignment: .leading)

                TextField(L10n.t("display_name", languageCode: languageCode), text: $displayName)
                    .font(.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                    .focused(focusedField, equals: .displayName)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(FGColor.dangerRed)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
    }
}

struct EditProfileHandleRow: View {
    @Binding var username: String
    var focusedField: FocusState<EditProfileFocusField?>.Binding
    let handleStatusMessage: String
    let handleStatusIsPositive: Bool
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.t("handle", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(width: 108, alignment: .leading)

                HStack(spacing: 6) {
                    Text("@")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background {
                            Capsule(style: .continuous)
                                .fill(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.92))
                        }
                        .accessibilityHidden(true)

                    TextField("handle", text: $username)
                        .font(.body)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused(focusedField, equals: .username)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if showsInlineAvailabilityGlyph {
                        Image(systemName: handleStatusIsPositive ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(handleStatusIsPositive ? FGColor.accentGreen : FGColor.dangerRed)
                            .accessibilityHidden(true)
                    } else if handleStatusMessage.localizedCaseInsensitiveContains("checking") {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if shouldShowStatusFootnote {
                HandleAvailabilityStatusLabel(
                    message: handleStatusMessage,
                    isPositive: handleStatusIsPositive
                )
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var showsInlineAvailabilityGlyph: Bool {
        guard !handleStatusMessage.isEmpty else { return false }
        if handleStatusMessage.localizedCaseInsensitiveContains("checking") { return false }
        return handleStatusIsPositive || handleStatusMessage.localizedCaseInsensitiveContains("taken")
            || handleStatusMessage.localizedCaseInsensitiveContains("invalid")
    }

    private var shouldShowStatusFootnote: Bool {
        guard !handleStatusMessage.isEmpty else { return false }
        // Keep checking / errors as footnotes; Available is covered by the inline check.
        if handleStatusIsPositive, handleStatusMessage.localizedCaseInsensitiveContains("available") {
            return false
        }
        return true
    }
}

struct EditProfileBioRow: View {
    @Binding var bio: String
    var focusedField: FocusState<EditProfileFocusField?>.Binding
    let characterLimit: Int
    let languageCode: String
    let onAddEmoji: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("bio", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .padding(.horizontal, 14)
                .padding(.top, 11)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $bio)
                    .font(.body)
                    .focused(focusedField, equals: .bio)
                    .frame(minHeight: 66, maxHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .autocorrectionDisabled(false)

                if bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.t("add_a_short_bio", languageCode: languageCode))
                        .font(.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Button(action: onAddEmoji) {
                    HStack(spacing: 6) {
                        Image(systemName: "face.smiling")
                            .font(.subheadline.weight(.semibold))
                        Text(L10n.t("add_emoji", languageCode: languageCode))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add emoji to bio")

                Spacer(minLength: 0)

                Text("\(bio.count)/\(characterLimit)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(
                        bio.count >= characterLimit
                            ? FGColor.dangerRed
                            : FGColor.secondaryText(colorScheme)
                    )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Location

struct EditProfileHomeCityRow: View {
    @Binding var city: String
    @Binding var region: String
    @Binding var country: String
    @Binding var displayText: String
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L10n.t("home_city", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(width: 108, alignment: .leading)
                .padding(.top, 12)

            ProfileHomeCityAutocompleteField(
                city: $city,
                region: $region,
                country: $country,
                displayText: $displayText,
                usesCompactPillStyle: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

struct EditProfileShowOnProfileRow: View {
    @Binding var isOn: Bool
    let isDisabled: Bool
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(L10n.t("show_on_profile", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
        .tint(FGColor.accentGreen)
        .disabled(isDisabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Appearance

struct EditProfileBackgroundRow: View {
    let backgroundKey: ProfileBackgroundKey
    let languageCode: String
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var option: ProfileBackgroundOption {
        ProfileBackgroundCatalog.option(for: backgroundKey)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(option.thumbnailAssetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 28)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("profile_background", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)

                    Text(option.displayName(languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose profile background")
        .accessibilityHint(L10n.t("profile_background_picker_hint", languageCode: languageCode))
        .accessibilityValue(option.displayName(languageCode: languageCode))
    }
}

// MARK: - Account

struct EditProfileAccountRow: View {
    let email: String
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    private var displayEmail: String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("email", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(displayEmail)
                    .font(.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(L10n.t("email", languageCode: languageCode)). \(displayEmail)")
    }
}

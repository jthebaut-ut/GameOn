import SwiftUI

/// Installation-scoped first-launch language selector completion (UserDefaults / AppStorage only).
enum FanGeoFirstLaunchLanguagePreferences {
    static let completedKey = "fangeo.firstLaunchLanguageSelectorCompleted"
    /// Auth user IDs that already completed the one-time post-account-creation language selector.
    static let postAccountCreationCompletedUserIdsKey =
        "fangeo.postAccountCreationLanguageSelectorCompletedUserIds"
    /// Pending auth user ID waiting for the post-account-creation language selector.
    static let pendingPostAccountCreationUserIdKey =
        "fangeo.pendingPostAccountCreationLanguageSelectorUserId"

    private static var didPrepareAtProcessStart = false

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    // MARK: - Post-account-creation (per authenticated user)

    static func hasCompletedPostAccountCreation(for userId: UUID) -> Bool {
        completedPostAccountCreationUserIds.contains(userId.uuidString.lowercased())
    }

    static func markPostAccountCreationCompleted(for userId: UUID) {
        let id = userId.uuidString.lowercased()
        var ids = completedPostAccountCreationUserIds
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: postAccountCreationCompletedUserIdsKey)
        clearPendingPostAccountCreation(ifMatches: userId)
#if DEBUG
        print("[FirstLaunchLanguage] postAccountCreationCompleted userId=\(id)")
#endif
    }

    static var pendingPostAccountCreationUserId: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: pendingPostAccountCreationUserIdKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return UUID(uuidString: raw)
    }

    /// Records a one-time post-signup language prompt for a newly created account.
    /// No-op when that account already completed the prompt (existing users stay unaffected).
    static func setPendingPostAccountCreation(userId: UUID) {
        guard !hasCompletedPostAccountCreation(for: userId) else { return }
        UserDefaults.standard.set(
            userId.uuidString.lowercased(),
            forKey: pendingPostAccountCreationUserIdKey
        )
#if DEBUG
        print("[FirstLaunchLanguage] pendingPostAccountCreation userId=\(userId.uuidString.lowercased())")
#endif
    }

    static func clearPendingPostAccountCreation(ifMatches userId: UUID? = nil) {
        guard let pending = pendingPostAccountCreationUserId else { return }
        if let userId, pending != userId { return }
        UserDefaults.standard.removeObject(forKey: pendingPostAccountCreationUserIdKey)
    }

    /// True when the signed-in user has a pending post-account-creation language prompt.
    static func shouldPresentPostAccountCreation(currentUserId: UUID?) -> Bool {
        guard let currentUserId,
              let pending = pendingPostAccountCreationUserId,
              pending == currentUserId,
              !hasCompletedPostAccountCreation(for: currentUserId)
        else { return false }
        return true
    }

    /// Prefer the current FanGeo app language; otherwise device preferred; otherwise English.
    static func resolveLanguageForPostAccountCreation(currentAppLanguage: String) -> String {
        let fromBinding = L10n.normalizedLanguageCode(currentAppLanguage)
        if isSupportedLanguageCode(fromBinding) {
            return fromBinding
        }
        let stored = UserDefaults.standard.string(forKey: L10n.appLanguageKey) ?? ""
        let fromStore = L10n.normalizedLanguageCode(stored)
        if isSupportedLanguageCode(fromStore) {
            return fromStore
        }
        return resolvePreferredSupportedLanguageCode()
    }

    private static var completedPostAccountCreationUserIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: postAccountCreationCompletedUserIdsKey) ?? [])
    }

    private static func isSupportedLanguageCode(_ code: String) -> Bool {
        L10n.supportedLanguages.contains { $0.code == code }
    }

    /// Call once at process start (before ad-consent acknowledgment) so app updates
    /// do not resurface this selector for existing installs.
    static func prepareAtProcessStart() {
        guard !didPrepareAtProcessStart else { return }
        didPrepareAtProcessStart = true
        migrateExistingInstallIfNeeded()
        applyDetectedLanguageForFirstLaunchIfNeeded()
    }

    /// Existing installs upgrading into this build must not see the one-time selector.
    private static func migrateExistingInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: completedKey) == nil else { return }

        let evidenceKeys = [
            "FanGeoAdConsentPrePromptAcknowledged",
            FanGeoStartupGuidePreferences.hideAtStartupKey,
            "fanGeoHideStartupGuide",
            "didExplicitlyLogout",
            "fanGuidelinesAccepted",
            "venueGuidelinesAccepted",
        ]
        let hasEvidence = evidenceKeys.contains { defaults.object(forKey: $0) != nil }
            || defaults.dictionaryRepresentation().keys.contains {
                $0.hasPrefix("\(FanGeoStartupGuidePreferences.hideAtStartupKey).")
                    || $0.hasPrefix("discoverActivityPanelIntroShown")
            }
        guard hasEvidence else { return }
        defaults.set(true, forKey: completedKey)
#if DEBUG
        print("[FirstLaunchLanguage] migratedExistingInstall completed=true")
#endif
    }

    /// On an incomplete first launch, seed `appLanguage` from the device preferred list.
    static func applyDetectedLanguageForFirstLaunchIfNeeded() {
        guard !hasCompleted else { return }
        let detected = resolvePreferredSupportedLanguageCode()
        UserDefaults.standard.set(detected, forKey: L10n.appLanguageKey)
#if DEBUG
        print("[FirstLaunchLanguage] seededAppLanguage=\(detected)")
#endif
    }

    /// First supported language in the device’s ordered preferred-language list; otherwise English.
    static func resolvePreferredSupportedLanguageCode(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        for preferred in preferredLanguages {
            if let code = matchSupportedCode(from: preferred) {
                return code
            }
        }
        return L10n.defaultLanguageCode
    }

    static func matchSupportedCode(from preferred: String) -> String? {
        let tag = preferred
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty else { return nil }

        let lower = tag.lowercased()

        // Traditional Chinese is not a FanGeo locale — keep scanning preferred list.
        if lower.hasPrefix("zh") {
            if lower.contains("hant")
                || lower.hasPrefix("zh-tw")
                || lower.hasPrefix("zh-hk")
                || lower.hasPrefix("zh-mo") {
                return nil
            }
            return "zh-Hans"
        }

        // Longest supported-code prefix / exact match first (e.g. zh-Hans before naive splits).
        let supportedCodes = L10n.supportedLanguages.map(\.code).sorted { $0.count > $1.count }
        for code in supportedCodes {
            let codeLower = code.lowercased()
            if lower == codeLower { return code }
            if lower.hasPrefix(codeLower + "-") { return code }
        }

        let languageCode = Locale(identifier: tag).language.languageCode?.identifier ?? ""
        guard !languageCode.isEmpty else { return nil }
        return L10n.supportedLanguages.first {
            $0.code.caseInsensitiveCompare(languageCode) == .orderedSame
        }?.code
    }

    /// Compact list: detected first, English if needed, then common locales; full list when expanded.
    static func languagesForDisplay(defaultCode: String, expanded: Bool) -> [AppLanguage] {
        if expanded {
            return orderedSupportedLanguages(defaultCode: defaultCode)
        }

        var result: [AppLanguage] = []
        var seen = Set<String>()

        func append(_ code: String) {
            let normalized = L10n.normalizedLanguageCode(code)
            guard !seen.contains(normalized),
                  let language = L10n.supportedLanguages.first(where: { $0.code == normalized })
            else { return }
            seen.insert(normalized)
            result.append(language)
        }

        append(defaultCode)
        append(L10n.defaultLanguageCode)
        for code in ["fr", "de", "es", "it", "pt"] {
            append(code)
            if result.count >= 5 { break }
        }
        if result.count < 5 {
            for language in L10n.supportedLanguages {
                append(language.code)
                if result.count >= 5 { break }
            }
        }
        return result
    }

    private static func orderedSupportedLanguages(defaultCode: String) -> [AppLanguage] {
        let normalizedDefault = L10n.normalizedLanguageCode(defaultCode)
        var result: [AppLanguage] = []
        if let detected = L10n.supportedLanguages.first(where: { $0.code == normalizedDefault }) {
            result.append(detected)
        }
        for language in L10n.supportedLanguages where language.code != normalizedDefault {
            result.append(language)
        }
        return result
    }
}

struct FirstLaunchLanguageSelectorOverlay: View {
    @Binding var appLanguageRaw: String
    let detectedLanguageCode: String
    let onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var displayedLanguages: [AppLanguage] {
        FanGeoFirstLaunchLanguagePreferences.languagesForDisplay(
            defaultCode: detectedLanguageCode,
            expanded: isExpanded
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.55 : 0.42)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            GeometryReader { geo in
                let maxCardWidth = min(400, geo.size.width - 36)
                let maxCardHeight = geo.size.height - 48

                card
                    .frame(maxWidth: maxCardWidth, maxHeight: maxCardHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 18)
                .padding(.horizontal, 20)

            ScrollView {
                VStack(spacing: 18) {
                    titleBlock
                    languageList
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(cardFill)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 28, y: 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var cardFill: Color {
        colorScheme == .dark ? FGColor.cardBackground(colorScheme) : Color.white
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.16))
                        .frame(width: 64, height: 64)
                    Image(systemName: "globe")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen.opacity(0.92))
                        .accessibilityHidden(true)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)

            Button(action: confirmAndDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.t("first_launch_language_close_a11y", languageCode: languageCode)
            )
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 10) {
            Text(L10n.t("first_launch_language_title", languageCode: languageCode))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.t("first_launch_language_subtitle", languageCode: languageCode))
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var languageList: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayedLanguages.enumerated()), id: \.element.id) { index, language in
                if index > 0 {
                    Divider()
                        .padding(.leading, 52)
                }
                languageRow(language)
            }

            if !isExpanded {
                Divider()
                    .padding(.leading, 16)
                expandRow
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color(white: 0.97))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        let isSelected = language.code == languageCode
        let isDefault = language.code == L10n.normalizedLanguageCode(detectedLanguageCode)

        return Button {
            selectLanguage(language.code)
        } label: {
            HStack(spacing: 12) {
                Text(language.flag)
                    .font(.system(size: 22))
                    .frame(width: 30)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.nativeName)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if isDefault {
                        Text(L10n.t("first_launch_language_default", languageCode: languageCode))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.accentGreen)
                    }
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme).opacity(0.45),
                            lineWidth: 2
                        )
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(FGColor.accentGreen)
                            .frame(width: 12, height: 12)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    Rectangle()
                        .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(languageAccessibilityLabel(language: language, isSelected: isSelected, isDefault: isDefault))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var expandRow: some View {
        Button {
            let updates = { isExpanded = true }
            if reduceMotion {
                updates()
            } else {
                withAnimation(.easeInOut(duration: 0.22), updates)
            }
        } label: {
            HStack(spacing: 10) {
                Text(L10n.t("first_launch_language_see_all", languageCode: languageCode))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("first_launch_language_expand_a11y", languageCode: languageCode))
        .accessibilityHint(L10n.t("first_launch_language_see_all", languageCode: languageCode))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: confirmAndDismiss) {
                Text(L10n.t("first_launch_language_continue", languageCode: languageCode))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(FGColor.accentGreen)
                    .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("first_launch_language_continue", languageCode: languageCode))

            Text(L10n.t("first_launch_language_footer", languageCode: languageCode))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selectLanguage(_ code: String) {
        let normalized = L10n.normalizedLanguageCode(code)
        guard appLanguageRaw != normalized else { return }
        appLanguageRaw = normalized
#if DEBUG
        print("[FirstLaunchLanguage] previewLanguage=\(normalized)")
#endif
    }

    private func confirmAndDismiss() {
        let normalized = L10n.normalizedLanguageCode(appLanguageRaw)
        appLanguageRaw = normalized
        FanGeoFirstLaunchLanguagePreferences.markCompleted()
#if DEBUG
        print("[FirstLaunchLanguage] completed language=\(normalized)")
#endif
        onFinished()
    }

    private func languageAccessibilityLabel(
        language: AppLanguage,
        isSelected: Bool,
        isDefault: Bool
    ) -> String {
        let key = isSelected
            ? "first_launch_language_selected_a11y"
            : "first_launch_language_unselected_a11y"
        var label = L10n.t(key, languageCode: languageCode)
            .replacingOccurrences(of: "%@", with: language.nativeName)
        if isDefault {
            label += ", " + L10n.t("first_launch_language_default", languageCode: languageCode)
        }
        return label
    }
}

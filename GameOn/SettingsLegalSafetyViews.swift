import SwiftUI

// MARK: - Legal & Safety (in-app policies)

enum FanGeoLegalLinks {
    static let supportEmail = "support@fangeosports.com"
    static let supportEmailURL = URL(string: "mailto:\(supportEmail)")!
    static let communityGuidelines = URL(string: "https://fangeosports.com/community-guidelines")!
    static let trustSafety = URL(string: "https://fangeosports.com/trust-safety")!
    static let privacyPolicy = URL(string: "https://fangeosports.com/privacy")!
    static let termsOfService = URL(string: "https://fangeosports.com/terms")!
}

enum SettingsLegalDocumentKind: String, Identifiable, Hashable {
    case privacyPolicy
    case termsOfService
    case communityGuidelines
    case safetyReporting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy:
            return L10n.t("settings_privacy_policy")
        case .termsOfService:
            return L10n.t("settings_terms_of_service")
        case .communityGuidelines:
            return L10n.t("community_guidelines")
        case .safetyReporting:
            return L10n.t("settings_trust_and_safety")
        }
    }

    var rowSubtitle: String {
        switch self {
        case .privacyPolicy:
            return L10n.t("settings_privacy_policy_subtitle")
        case .termsOfService:
            return L10n.t("settings_terms_of_service_subtitle")
        case .communityGuidelines:
            return L10n.t("settings_community_guidelines_subtitle")
        case .safetyReporting:
            return L10n.t("settings_trust_and_safety_subtitle")
        }
    }

    var systemImage: String {
        switch self {
        case .privacyPolicy: return "hand.raised.fill"
        case .termsOfService: return "doc.text.fill"
        case .communityGuidelines: return "person.3.fill"
        case .safetyReporting: return "shield.lefthalf.filled"
        }
    }

    /// Shown on every in-app legal/safety sheet header (English fallback copy).
    static let lastUpdatedDisplay = "June 18, 2026"

    func sections(languageCode: String?) -> [SettingsLegalContentSection] {
        SettingsLegalDocumentCatalog.sections(for: self, languageCode: languageCode)
    }

    func lastUpdatedLabel(languageCode: String?) -> String {
        SettingsLegalDocumentCatalog.lastUpdatedLabel(languageCode: languageCode)
    }
}

struct SettingsLegalContentSection: Hashable {
    let heading: String
    let body: String
}

struct SettingsLegalDocumentSheet: View {
    let document: SettingsLegalDocumentKind
    var embedsInNavigationStack = true
    var showsCloseButton = true
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @ViewBuilder
    var body: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let sections = document.sections(languageCode: languageCode)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.lastUpdatedLabel(languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.heading)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(section.body)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.visible)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .navigationTitle(localizedDocumentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close", languageCode: languageCode)) { dismiss() }
                }
            }
        }
    }

    private var localizedDocumentTitle: String {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        switch document {
        case .privacyPolicy:
            return L10n.t("settings_privacy_policy", languageCode: languageCode)
        case .termsOfService:
            return L10n.t("settings_terms_of_service", languageCode: languageCode)
        case .communityGuidelines:
            return L10n.t("community_guidelines", languageCode: languageCode)
        case .safetyReporting:
            return L10n.t("settings_trust_and_safety", languageCode: languageCode)
        }
    }
}

// MARK: - Auth terms acceptance (App Review / UGC compliance)

struct FanGeoAuthTermsAcceptanceView: View {
    @Binding var isAccepted: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var presentedDocument: SettingsLegalDocumentKind?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                isAccepted.toggle()
            } label: {
                Image(systemName: isAccepted ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundStyle(isAccepted ? FGColor.accentBlue : FGColor.mutedText(colorScheme))
                    .frame(width: 28, height: 28, alignment: .top)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Accept Terms of Use and Community Guidelines")
            .accessibilityAddTraits(isAccepted ? .isSelected : [])

            VStack(alignment: .leading, spacing: 8) {
                Text("By creating an account or signing in, you agree to the FanGeo Terms of Use and Community Guidelines.")
                    .font(.footnote)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    Button {
                        presentedDocument = .termsOfService
                    } label: {
                        Text("Terms of Use")
                            .font(.footnote.weight(.semibold))
                            .underline()
                    }
                    .buttonStyle(.plain)

                    Button {
                        presentedDocument = .communityGuidelines
                    } label: {
                        Text(L10n.t("community_guidelines", languageCode: appLanguageRaw))
                            .font(.footnote.weight(.semibold))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(FGColor.accentBlue)

                Text("FanGeo has zero tolerance for harassment, hate speech, threats, illegal content, abusive behavior, or other objectionable content. Accounts violating these rules may be suspended or permanently removed.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(FGSpacing.md)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.97))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $presentedDocument) { document in
            SettingsLegalDocumentSheet(document: document)
        }
    }
}

/// Compact, non-interactive status shown after the user has already accepted legal terms.
struct FanGeoAuthTermsAcceptedStatusRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .accessibilityHidden(true)

            Text(L10n.t("terms_accepted", languageCode: appLanguageRaw))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08))
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("terms_accepted_accessibility", languageCode: appLanguageRaw))
        .accessibilityAddTraits(.isStaticText)
    }
}

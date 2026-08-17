import SwiftUI

/// Sheet wrapper for the guest heart-tap save-games prompt.
struct SaveProGameSignInPromptSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        SignedOutFeatureView(
            icon: "bookmark.fill",
            title: L10n.t("going_signed_out_title", languageCode: appLanguageRaw),
            description: L10n.t("going_signed_out_body", languageCode: appLanguageRaw),
            accent: FGColor.accentBlue,
            onSignIn: {
                viewModel.continueSaveProGameSignInFromPrompt()
                dismiss()
            },
            onCreateAccount: {
                viewModel.continueSaveProGameCreateAccountFromPrompt()
                dismiss()
            }
        )
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

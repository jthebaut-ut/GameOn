import SwiftUI

// MARK: - Private chat (local device lock)

struct SettingsPrivateChatDeviceAuthCard: View {
    @AppStorage(PrivateChatSecuritySettings.requireFaceIDSettingKey) private var requireDeviceAuthForPrivateChat = false
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var requireFaceIDBinding: Binding<Bool> {
        Binding(
            get: { requireDeviceAuthForPrivateChat },
            set: { newValue in
                requireDeviceAuthForPrivateChat = newValue
                print("[PrivateChatSecurityDebug] settingChanged=\(newValue)")
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Private messages")
                .font(.headline)
                .fontWeight(.bold)

            Toggle(L10n.t("require_face_id_private_chat", languageCode: appLanguageRaw), isOn: requireFaceIDBinding)
                .font(.subheadline)

            Text(L10n.t("private_chat_face_id_description", languageCode: appLanguageRaw))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

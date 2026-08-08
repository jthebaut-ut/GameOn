import SwiftUI

struct PickupGamePollCreateSheet: View {
    let languageCode: String
    let onCancel: () -> Void
    let onCreate: (_ question: String, _ options: [String], _ allowMultiple: Bool, _ isAnonymous: Bool, _ autoCloseAtGameStart: Bool) async -> String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var allowMultiple = false
    @State private var isAnonymous = false
    @State private var autoCloseAtGameStart = true
    @State private var validationMessage: String?
    @State private var isCreating = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case question
        case option(Int)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.t("pickup_poll_question_placeholder", languageCode: languageCode),
                        text: $question,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .focused($focusedField, equals: .question)
                    .onChange(of: question) { _, newValue in
                        if newValue.count > PickupGamePollValidation.questionMaxLength {
                            question = String(newValue.prefix(PickupGamePollValidation.questionMaxLength))
                        }
                        validationMessage = nil
                    }
                    .accessibilityLabel(L10n.t("pickup_poll_question_label", languageCode: languageCode))

                    Text("\(question.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(PickupGamePollValidation.questionMaxLength)")
                        .font(.caption2)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                } header: {
                    Text(L10n.t("pickup_poll_question_label", languageCode: languageCode))
                }

                Section {
                    ForEach(options.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            TextField(
                                String(
                                    format: L10n.t("pickup_poll_option_placeholder_format", languageCode: languageCode),
                                    locale: Locale(identifier: languageCode),
                                    Int64(index + 1)
                                ),
                                text: Binding(
                                    get: { options[index] },
                                    set: { newValue in
                                        let clipped = String(newValue.prefix(PickupGamePollValidation.optionMaxLength))
                                        options[index] = clipped
                                        validationMessage = nil
                                    }
                                )
                            )
                            .focused($focusedField, equals: .option(index))
                            .accessibilityLabel(
                                String(
                                    format: L10n.t("pickup_poll_option_placeholder_format", languageCode: languageCode),
                                    locale: Locale(identifier: languageCode),
                                    Int64(index + 1)
                                )
                            )

                            if options.count > PickupGamePollValidation.optionMinCount {
                                Button(role: .destructive) {
                                    options.remove(at: index)
                                    validationMessage = nil
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red.opacity(0.85))
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.t("pickup_poll_delete_option_a11y", languageCode: languageCode))
                            }
                        }
                    }
                    .onMove { source, destination in
                        options.move(fromOffsets: source, toOffset: destination)
                    }

                    if options.count < PickupGamePollValidation.optionMaxCount {
                        Button {
                            options.append("")
                            focusedField = .option(options.count - 1)
                        } label: {
                            Label(
                                L10n.t("pickup_poll_add_option", languageCode: languageCode),
                                systemImage: "plus.circle.fill"
                            )
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel(L10n.t("pickup_poll_add_option", languageCode: languageCode))
                    }
                } header: {
                    Text(L10n.t("pickup_poll_options_label", languageCode: languageCode))
                } footer: {
                    Text(L10n.t("pickup_poll_options_reorder_hint", languageCode: languageCode))
                        .font(.caption)
                }

                Section {
                    Toggle(isOn: $allowMultiple) {
                        Text(L10n.t("pickup_poll_allow_multiple", languageCode: languageCode))
                            .font(.body)
                    }
                    .tint(FGColor.accentGreen)
                    .frame(minHeight: 44)

                    Toggle(isOn: $isAnonymous) {
                        Text(L10n.t("pickup_poll_anonymous", languageCode: languageCode))
                            .font(.body)
                    }
                    .tint(FGColor.accentGreen)
                    .frame(minHeight: 44)

                    Toggle(isOn: $autoCloseAtGameStart) {
                        Text(L10n.t("pickup_poll_auto_close", languageCode: languageCode))
                            .font(.body)
                    }
                    .tint(FGColor.accentGreen)
                    .frame(minHeight: 44)
                } header: {
                    Text(L10n.t("pickup_poll_settings_label", languageCode: languageCode))
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityLabel(validationMessage)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L10n.t("pickup_poll_create_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) {
                        onCancel()
                    }
                    .disabled(isCreating)
                    .frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text(L10n.t("pickup_poll_create_button", languageCode: languageCode))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isCreating)
                    .frame(minHeight: 44)
                    .accessibilityLabel(L10n.t("pickup_poll_create_button", languageCode: languageCode))
                }
            }
            .interactiveDismissDisabled(isCreating)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @MainActor
    private func create() async {
        if let issue = PickupGamePollValidation.validate(question: question, options: options) {
            validationMessage = PickupGamePollValidation.userMessage(for: issue, languageCode: languageCode)
            return
        }
        isCreating = true
        defer { isCreating = false }
        let q = PickupGamePollValidation.normalizeQuestion(question)
        let opts = options.map(PickupGamePollValidation.normalizeOption)
        if let error = await onCreate(q, opts, allowMultiple, isAnonymous, autoCloseAtGameStart) {
            validationMessage = error
        }
    }
}

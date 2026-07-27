import SwiftUI
import UniformTypeIdentifiers

struct PickupBulkImportPreviewView: View {
    @ObservedObject var viewModel: MapViewModel
    var showsNavigationChrome = true
    var onImported: () -> Void
    var onDoneAfterSuccess: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var isFileImporterPresented = false
    @State private var selectedFileName = ""
    @State private var previewRows: [PickupBulkImportPreparedRow] = []
    @State private var isLoadingPreview = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var templateURL: URL?
    @State private var templateErrorMessage: String?
    @State private var importResult: PickupBulkImportResult?
    @State private var selectedRowIDs: Set<UUID> = []

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var summary: PickupBulkImportSummary {
        PickupBulkImportValidator.summary(for: previewRows)
    }

    private var importableRows: [PickupBulkImportPreparedRow] {
        previewRows.filter { $0.status.isImportable }
    }

    private var selectedImportableRows: [PickupBulkImportPreparedRow] {
        importableRows.filter { selectedRowIDs.contains($0.id) }
    }

    private var hasSuccessfulImport: Bool {
        (importResult?.insertedCount ?? 0) > 0
    }

    private var isImportButtonDisabled: Bool {
        hasSuccessfulImport || selectedImportableRows.isEmpty || isLoadingPreview || isImporting
    }

    private var isStep3Enabled: Bool {
        !isImportButtonDisabled
    }

    private var isUploadEnabled: Bool {
        !isLoadingPreview && !isImporting && !hasSuccessfulImport
    }

    private var allowedFileTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText]
        if let csv = UTType(filenameExtension: "csv") {
            types.append(csv)
        }
        if let xlsx = UTType(filenameExtension: "xlsx") {
            types.append(xlsx)
        }
        return types
    }

    var body: some View {
        List {
            Section {
                csvImportWorkflowHeader
                    .listRowInsets(EdgeInsets(top: 8, leading: FGSpacing.lg, bottom: 8, trailing: FGSpacing.lg))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.dangerRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isLoadingPreview {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.t("pickup_csv_import_validating", languageCode: languageCode))
                            .font(FGTypography.body)
                    }
                    .padding(.vertical, 6)
                }
            }

            if !previewRows.isEmpty {
                Section {
                    summaryGrid
                } header: {
                    Text(L10n.t("pickup_csv_import_preview_summary", languageCode: languageCode))
                }

                Section {
                    HStack(spacing: 12) {
                        Button(L10n.t("pickup_csv_import_select_all", languageCode: languageCode)) {
                            selectAllImportableRows()
                        }
                        .disabled(importableRows.isEmpty || isImporting || hasSuccessfulImport)

                        Button(L10n.t("pickup_csv_import_deselect_all", languageCode: languageCode)) {
                            selectedRowIDs.removeAll()
                        }
                        .disabled(selectedRowIDs.isEmpty || isImporting || hasSuccessfulImport)
                    }
                    .font(FGTypography.caption.weight(.semibold))
                    .buttonStyle(.borderless)

                    Text(
                        String(
                            format: L10n.t("pickup_csv_import_selected_count_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            Int64(selectedImportableRows.count)
                        )
                    )
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }

                importableRowsSection(
                    title: L10n.t("pickup_csv_import_ready_rows", languageCode: languageCode),
                    status: .valid
                )
                importableRowsSection(
                    title: L10n.t("pickup_csv_import_warning_rows", languageCode: languageCode),
                    status: .warning
                )
                errorRowsSection
            }

            if let importResult {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            String(
                                format: L10n.t("pickup_csv_import_result_inserted_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                Int64(importResult.insertedCount)
                            ),
                            systemImage: "checkmark.circle.fill"
                        )
                            .foregroundStyle(FGColor.accentGreen)
                            .font(FGTypography.body.weight(.semibold))
                        if importResult.failedCount > 0 {
                            Text(
                                String(
                                    format: L10n.t("pickup_csv_import_result_failed_format", languageCode: languageCode),
                                    locale: Locale(identifier: languageCode),
                                    Int64(importResult.failedCount)
                                )
                            )
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                } header: {
                    Text(L10n.t("pickup_csv_import_result_header", languageCode: languageCode))
                }
            }

            if !showsNavigationChrome {
                Section {
                    completionActionButtons
                }
                .listRowInsets(EdgeInsets(top: 8, leading: FGSpacing.lg, bottom: 12, trailing: FGSpacing.lg))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle(showsNavigationChrome ? L10n.t("pickup_csv_import_title", languageCode: languageCode) : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsNavigationChrome {
                if !hasSuccessfulImport {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("pickup_csv_import_done", languageCode: languageCode)) {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if hasSuccessfulImport {
                        Button(L10n.t("pickup_csv_import_done", languageCode: languageCode)) {
                            doneTappedAfterSuccess()
                        }
                    } else {
                        Button(importButtonTitle) {
                            Task { await importPreparedRows() }
                        }
                        .disabled(isImportButtonDisabled)
                        .tint(FGColor.intentPlay)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedFileTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImporter(result)
        }
        .onAppear {
            prepareTemplateFile()
#if DEBUG
            print("[PickupBulkImport] previewScreenPresented=true")
#endif
        }
    }

    private var importButtonTitle: String {
        if isImporting {
            return L10n.t("pickup_csv_import_button_importing", languageCode: languageCode)
        }
        return L10n.t("pickup_csv_import_button", languageCode: languageCode)
    }

    private var step2Subtitle: String {
        if isLoadingPreview {
            return L10n.t("pickup_csv_import_validating", languageCode: languageCode)
        }
        if !selectedFileName.isEmpty {
            return selectedFileName
        }
        return L10n.t("pickup_csv_import_step2_subtitle", languageCode: languageCode)
    }

    private var step3Subtitle: String {
        if isImporting {
            return L10n.t("pickup_csv_import_button_importing", languageCode: languageCode)
        }
        if !previewRows.isEmpty {
            return String(
                format: L10n.t("pickup_csv_import_selected_count_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                Int64(selectedImportableRows.count)
            )
        }
        return L10n.t("pickup_csv_import_step3_subtitle", languageCode: languageCode)
    }

    private var csvImportWorkflowHeader: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("pickup_csv_import_title", languageCode: languageCode))
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.t("pickup_csv_import_subtitle", languageCode: languageCode))
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: FGSpacing.sm) {
                downloadTemplateStepRow
                uploadFileStepRow
                importGamesStepRow
            }

            if let templateErrorMessage, !templateErrorMessage.isEmpty {
                Text(templateErrorMessage)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.dangerRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            csvOfficialTemplateInfoCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var downloadTemplateStepRow: some View {
        let title = L10n.t("pickup_csv_import_step1_title", languageCode: languageCode)
        let subtitle = L10n.t("pickup_csv_import_step1_subtitle", languageCode: languageCode)
        if let templateURL {
            ShareLink(item: templateURL) {
                PickupCSVImportStepRow(
                    title: title,
                    subtitle: subtitle,
                    systemImage: "tablecells",
                    badgeTint: FGColor.accentGreen,
                    isEnabled: true,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.t("pickup_csv_import_step1_a11y_hint", languageCode: languageCode))
        } else {
            Button {
                prepareTemplateFile()
            } label: {
                PickupCSVImportStepRow(
                    title: title,
                    subtitle: subtitle,
                    systemImage: "tablecells",
                    badgeTint: FGColor.accentGreen,
                    isEnabled: true,
                    showsChevron: true
                )
            }
            .buttonStyle(FGPremiumPressButtonStyle())
            .accessibilityHint(L10n.t("pickup_csv_import_step1_a11y_hint", languageCode: languageCode))
        }
    }

    private var uploadFileStepRow: some View {
        Button {
            isFileImporterPresented = true
        } label: {
            PickupCSVImportStepRow(
                title: L10n.t("pickup_csv_import_step2_title", languageCode: languageCode),
                subtitle: step2Subtitle,
                systemImage: "arrow.up.doc.fill",
                badgeTint: FGColor.accentBlue,
                isEnabled: isUploadEnabled,
                showsChevron: true
            )
        }
        .buttonStyle(FGPremiumPressButtonStyle())
        .disabled(!isUploadEnabled)
        .accessibilityHint(L10n.t("pickup_csv_import_step2_a11y_hint", languageCode: languageCode))
    }

    @ViewBuilder
    private var importGamesStepRow: some View {
        let title = L10n.t("pickup_csv_import_step3_title", languageCode: languageCode)
        if isStep3Enabled {
            Button {
                Task { await importPreparedRows() }
            } label: {
                PickupCSVImportStepRow(
                    title: title,
                    subtitle: step3Subtitle,
                    systemImage: "checkmark.circle.fill",
                    badgeTint: FGColor.intentPlay,
                    isEnabled: true,
                    showsChevron: true
                )
            }
            .buttonStyle(FGPremiumPressButtonStyle())
            .accessibilityHint(L10n.t("pickup_csv_import_step3_a11y_hint", languageCode: languageCode))
        } else {
            PickupCSVImportStepRow(
                title: title,
                subtitle: step3Subtitle,
                systemImage: "checkmark.circle.fill",
                badgeTint: FGColor.intentPlay,
                isEnabled: false,
                showsChevron: true
            )
            .accessibilityHint(L10n.t("pickup_csv_import_step3_a11y_hint_disabled", languageCode: languageCode))
        }
    }

    private var csvOfficialTemplateInfoCard: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(L10n.t("pickup_csv_import_template_tip", languageCode: languageCode))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10),
            in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var completionActionButtons: some View {
        if hasSuccessfulImport {
            VStack(spacing: FGSpacing.sm) {
                Button {
                    doneTappedAfterSuccess()
                } label: {
                    Text(L10n.t("pickup_csv_import_done", languageCode: languageCode))
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .background(FGColor.intentPlay, in: Capsule())
                }
                .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: true))

                Button(L10n.t("pickup_csv_import_another_file", languageCode: languageCode)) {
                    resetForAnotherFile()
                }
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.intentPlay)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
            }
        } else {
            Button {
                Task { await importPreparedRows() }
            } label: {
                Text(importButtonTitle)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(isImportButtonDisabled ? FGColor.mutedText(colorScheme) : .white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                    .background(
                        (isImportButtonDisabled
                            ? FGColor.mutedText(colorScheme).opacity(colorScheme == .dark ? 0.28 : 0.18)
                            : FGColor.intentPlay),
                        in: Capsule()
                    )
            }
            .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: !isImportButtonDisabled))
            .disabled(isImportButtonDisabled)
            .accessibilityLabel(importButtonTitle)
        }
    }

    private func selectAllImportableRows() {
        guard !hasSuccessfulImport else { return }
        selectedRowIDs = Set(importableRows.map(\.id))
    }

    private var summaryGrid: some View {
        HStack(spacing: 10) {
            summaryPill(
                title: L10n.t("pickup_csv_import_summary_ready", languageCode: languageCode),
                value: summary.validCount,
                tint: FGColor.accentGreen
            )
            summaryPill(
                title: L10n.t("pickup_csv_import_summary_warning", languageCode: languageCode),
                value: summary.warningCount,
                tint: FGColor.accentYellow
            )
            summaryPill(
                title: L10n.t("pickup_csv_import_summary_error", languageCode: languageCode),
                value: summary.failedCount,
                tint: FGColor.dangerRed
            )
        }
        .padding(.vertical, 4)
    }

    private func summaryPill(title: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title3.weight(.black))
                .foregroundStyle(tint)
            Text(title)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func importableRowsSection(title: String, status: PickupBulkImportRowStatus) -> some View {
        let rows = previewRows.filter { $0.status == status }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    PickupBulkImportPreviewRowView(
                        row: row,
                        isSelected: selectedRowIDs.contains(row.id),
                        isSelectionEnabled: row.status.isImportable && !isImporting && !hasSuccessfulImport,
                        onToggleSelection: { toggleSelection(for: row) }
                    )
                }
            } header: {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var errorRowsSection: some View {
        let rows = previewRows.filter { $0.status == .failed }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    PickupBulkImportPreviewRowView(
                        row: row,
                        isSelected: false,
                        isSelectionEnabled: false,
                        onToggleSelection: {}
                    )
                }
            } header: {
                Text(L10n.t("pickup_csv_import_error_rows", languageCode: languageCode))
            } footer: {
                Text(L10n.t("pickup_csv_import_error_rows_footer", languageCode: languageCode))
            }
        }
    }

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            selectedFileName = url.lastPathComponent
            importResult = nil
            selectedRowIDs.removeAll()
            Task { await loadPreview(from: url) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func prepareTemplateFile() {
        do {
            templateURL = try PickupBulkImportParser.bundledTemplateFileURL()
            templateErrorMessage = nil
        } catch {
            templateErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadPreview(from url: URL) async {
        isLoadingPreview = true
        errorMessage = nil
        previewRows = []
        selectedRowIDs.removeAll()
        defer { isLoadingPreview = false }

        do {
            let rows = try await PickupBulkImportService.loadPreview(from: url, viewModel: viewModel)
            previewRows = rows
            selectedRowIDs = Set(rows.filter { $0.status.isImportable }.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleSelection(for row: PickupBulkImportPreparedRow) {
        guard row.status.isImportable, !isImporting, !hasSuccessfulImport else { return }
        if selectedRowIDs.contains(row.id) {
            selectedRowIDs.remove(row.id)
        } else {
            selectedRowIDs.insert(row.id)
        }
    }

    private func resetForAnotherFile() {
        selectedFileName = ""
        previewRows = []
        selectedRowIDs.removeAll()
        importResult = nil
        errorMessage = nil
        templateErrorMessage = nil
    }

    private func doneTappedAfterSuccess() {
#if DEBUG
        print("[PickupBulkImport] doneTappedAfterSuccess")
#endif
        onDoneAfterSuccess()
        dismiss()
    }

    @MainActor
    private func importPreparedRows() async {
        guard !hasSuccessfulImport else { return }
        let rowsToImport = selectedImportableRows
        guard !rowsToImport.isEmpty else { return }
#if DEBUG
        let selectedRows = rowsToImport.map { String($0.rowNumber) }.joined(separator: ",")
        print("[PickupBulkImport] selectedRowsForImport=\(selectedRows)")
#endif
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        let result = await PickupBulkImportService.importRows(rowsToImport, viewModel: viewModel)
        importResult = result
        if result.insertedCount > 0 {
            onImported()
        }
    }
}

/// Elevated step row for the Create Game CSV Import workflow.
struct PickupCSVImportStepRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let systemImage: String
    let badgeTint: Color
    var isEnabled: Bool = true
    var showsChevron: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEnabled ? badgeTint : FGColor.mutedText(colorScheme))
                .frame(width: 36, height: 36)
                .background(
                    (isEnabled ? badgeTint : FGColor.mutedText(colorScheme)).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .foregroundStyle(isEnabled ? FGColor.primaryText(colorScheme) : FGColor.mutedText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(isEnabled ? FGColor.secondaryText(colorScheme) : FGColor.mutedText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme).opacity(isEnabled ? 1 : 0.55))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 60, alignment: .center)
        .contentShape(Rectangle())
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(
                    FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.45 : 0.55),
                    lineWidth: 0.5
                )
        }
        .softCardShadow()
        .opacity(isEnabled ? 1 : 0.62)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isEnabled ? .isButton : [])
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
        .accessibilityRespondsToUserInteraction(isEnabled)
    }
}

private struct PickupBulkImportPreviewRowView: View {
    let row: PickupBulkImportPreparedRow
    let isSelected: Bool
    let isSelectionEnabled: Bool
    var onToggleSelection: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onToggleSelection()
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isSelectionEnabled ? FGColor.accentBlue : FGColor.secondaryText(colorScheme).opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!isSelectionEnabled)
            .accessibilityLabel(isSelected ? "Deselect row \(row.rowNumber)" : "Select row \(row.rowNumber)")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(sportEmoji)
                        .font(.title3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title.isEmpty ? "Untitled pickup game" : row.title)
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)

                        Text(sportLine)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    HStack(alignment: .center, spacing: 7) {
                        GameFormatBadgeView(format: row.gameType, colorScheme: colorScheme)

                        Text(row.status.displayTitle)
                            .font(FGTypography.caption.weight(.black))
                            .foregroundStyle(statusTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusTint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                    }
                }

                importPreviewMetaRow(systemImage: "calendar", text: dateTimeLine)

                if let locationLine {
                    importPreviewMetaRow(systemImage: "mappin.and.ellipse", text: locationLine)
                }

                importPreviewChipRow(primaryChips)

                if !secondaryChips.isEmpty {
                    importPreviewChipRow(secondaryChips)
                }

                if let extraMetadataLine {
                    Text(extraMetadataLine)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                ForEach(row.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.accentYellow)
                }

                ForEach(row.errors, id: \.self) { error in
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusTint: Color {
        switch row.status {
        case .valid:
            return FGColor.accentGreen
        case .warning:
            return FGColor.accentYellow
        case .failed:
            return FGColor.dangerRed
        }
    }

    private var sportLine: String {
        AppSportCatalog.displayLabel(forSportToken: row.sport)
    }

    private var sportEmoji: String {
        switch sportLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "soccer":
            return "⚽️"
        case "basketball":
            return "🏀"
        case "pickleball":
            return "🏓"
        case "badminton":
            return "🏸"
        case "tennis":
            return "🎾"
        case "baseball":
            return "⚾️"
        case "football":
            return "🏈"
        case "break dance":
            return "🕺"
        case "ballet":
            return "🩰"
        default:
            return "🏟"
        }
    }

    private var dateTimeLine: String {
        guard let start = row.gameStartAt else { return "Invalid start" }
        let startText = "\(Self.dateOnlyFormatter.string(from: start)) • \(Self.timeFormatter.string(from: start))"
        guard let end = row.endTime else {
            return startText
        }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(startText) – \(Self.timeFormatter.string(from: end))"
        }
        let endText = "\(Self.dateOnlyFormatter.string(from: end)) • \(Self.timeFormatter.string(from: end))"
        return "\(startText) – \(endText)"
    }

    private var locationLine: String? {
        let address = row.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cityState = [row.city, row.state]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let parts = [address, cityState].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    private var primaryChips: [ImportPreviewChip] {
        [
            ImportPreviewChip(text: playersText, tint: FGColor.accentBlue),
            ImportPreviewChip(text: costText, tint: row.isFree ? FGColor.accentGreen : Color.orange),
            ImportPreviewChip(text: participantPreferenceText, tint: FGColor.accentGreen)
        ]
    }

    private var secondaryChips: [ImportPreviewChip] {
        var chips = [
            ImportPreviewChip(text: skillLevelText, tint: Color.purple)
        ]
        if let age = row.ageRangeDisplayText {
            chips.append(ImportPreviewChip(text: age, tint: Color.orange))
        }
        return chips
    }

    private var playersText: String {
        let needed = row.playersNeeded.map { "\($0) needed" } ?? "Players needed missing"
        guard let maxPlayers = row.maxPlayers else { return needed }
        return "\(needed) • max \(maxPlayers)"
    }

    private var costText: String {
        if row.isFree { return "Free" }
        guard let amount = row.entryFeeAmount else { return "Paid" }
        return "Paid • \(PickupGameModels.currencyChipString(amount: amount))"
    }

    private var participantPreferenceText: String {
        PickupParticipantPreference.fromStored(row.participantPreference).displayTitle
    }

    private var skillLevelText: String {
        PickupGameSkillLevel.fromStored(row.skillLevel).displayTitle
    }

    private var extraMetadataLine: String? {
        let values = [row.leagueName, row.homeTeam, row.awayTeam, row.season, row.division]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " • ")
    }

    @ViewBuilder
    private func importPreviewMetaRow(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func importPreviewChipRow(_ chips: [ImportPreviewChip]) -> some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Text(chip.text)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(chip.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(chip.tint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(chip.tint.opacity(colorScheme == .dark ? 0.32 : 0.20), lineWidth: 1)
                    )
            }
            Spacer(minLength: 0)
        }
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct ImportPreviewChip: Identifiable {
    var id: String { text }
    let text: String
    let tint: Color
}

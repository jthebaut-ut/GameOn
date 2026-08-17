import Combine
import CoreLocation
import MapKit
import SwiftUI

// MARK: - Choose Location (Team Schedule)

struct FanTeamChooseLocationSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let teamId: UUID
    let canManageLocations: Bool
    let initialCoordinate: CLLocationCoordinate2D
    var titleKey: String = "team_location_choose_title"
    let onCancel: () -> Void
    let onSelect: (FanTeamLocationSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var locations: [FanTeamLocation] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showSearch = false
    @State private var showMapPicker = false
    @State private var showManualEntry = false
    @State private var editingLocation: FanTeamLocation?
    @State private var pendingSaveSelection: FanTeamLocationSelection?
    @State private var saveNickname = ""
    @State private var saveThenSelect = true
    @State private var showSavePrompt = false
    @State private var showClearRecentConfirm = false
    @State private var isMutating = false
    @State private var bannerError: String?

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }
    private var accent: Color { FGColor.intentTeams }
    private var split: (saved: [FanTeamLocation], recent: [FanTeamLocation]) {
        FanTeamLocationPresentation.split(locations: locations)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    if let bannerError {
                        Text(bannerError)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.accentYellow)
                    }

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, FGSpacing.xl)
                    } else if let loadError {
                        Text(loadError)
                            .font(FGTypography.body)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .padding(.vertical, FGSpacing.md)
                    } else {
                        savedSection
                        recentSection
                    }

                    searchAndAddSection
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.vertical, FGSpacing.md)
            }
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationTitle(L10n.t(titleKey, languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) {
                        onCancel()
                        dismiss()
                    }
                }
                if canManageLocations, !split.recent.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                showClearRecentConfirm = true
                            } label: {
                                Label(
                                    L10n.t("team_location_clear_recent", languageCode: languageCode),
                                    systemImage: "clock.arrow.circlepath"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(accent)
                        }
                        .accessibilityLabel(L10n.t("team_location_edit", languageCode: languageCode))
                    }
                }
            }
            .task {
                TeamLocationDebug.log("pickerOpened", detail: "teamID=\(teamId.uuidString.lowercased())")
                await reload()
            }
            .sheet(isPresented: $showSearch) {
                FanTeamLocationSearchSheet(
                    languageCode: languageCode,
                    onCancel: { showSearch = false },
                    onSelect: { selection in
                        showSearch = false
                        offerSaveThenSelect(selection)
                    }
                )
            }
            .sheet(isPresented: $showManualEntry) {
                FanTeamManualLocationEntrySheet(
                    languageCode: languageCode,
                    viewModel: viewModel,
                    onCancel: { showManualEntry = false },
                    onConfirm: { selection in
                        showManualEntry = false
                        TeamLocationDebug.log("manualLocationCreated", detail: "teamID=\(teamId.uuidString.lowercased())")
                        offerSaveThenSelect(selection)
                    }
                )
            }
            .fullScreenCover(isPresented: $showMapPicker) {
                PickupGameMapLocationPickerSheet(
                    viewModel: viewModel,
                    initialCoordinate: initialCoordinate,
                    onCancel: { showMapPicker = false },
                    onConfirm: { coord, street, cityName, stateAbbr, postalCode, country in
                        showMapPicker = false
                        let selection = FanTeamLocationSelection(
                            teamLocationId: nil,
                            nickname: nil,
                            placeName: nil,
                            address: street ?? "",
                            city: cityName ?? "",
                            state: stateAbbr ?? "",
                            zipCode: postalCode ?? "",
                            countryCode: country ?? "",
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            providerPlaceId: nil
                        )
                        TeamLocationDebug.log("manualLocationCreated", detail: "teamID=\(teamId.uuidString.lowercased()) source=map")
                        offerSaveThenSelect(selection)
                    }
                )
            }
            .sheet(item: $editingLocation) { location in
                FanTeamSavedLocationEditSheet(
                    location: location,
                    languageCode: languageCode,
                    onCancel: { editingLocation = nil },
                    onSave: { nickname, isDefault in
                        await persistEdit(location: location, nickname: nickname, isDefault: isDefault)
                    },
                    onRemove: {
                        await persistRemove(location: location)
                    }
                )
            }
            .alert(
                L10n.t("team_location_save_prompt_title", languageCode: languageCode),
                isPresented: $showSavePrompt
            ) {
                TextField(
                    L10n.t("team_location_nickname_placeholder", languageCode: languageCode),
                    text: $saveNickname
                )
                Button(L10n.t("team_location_save_action", languageCode: languageCode)) {
                    Task { await savePendingAndSelect() }
                }
                if saveThenSelect {
                    Button(L10n.t("team_location_use_without_saving", languageCode: languageCode)) {
                        if let pendingSaveSelection {
                            finishSelect(pendingSaveSelection)
                        }
                    }
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {
                    pendingSaveSelection = nil
                }
            } message: {
                Text(L10n.t("team_location_save_prompt_body", languageCode: languageCode))
            }
            .confirmationDialog(
                L10n.t("team_location_clear_recent_confirm", languageCode: languageCode),
                isPresented: $showClearRecentConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.t("team_location_clear_recent", languageCode: languageCode), role: .destructive) {
                    Task { await clearRecent() }
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            sectionHeader(
                title: L10n.t("team_location_saved_section", languageCode: languageCode),
                systemImage: "star.fill"
            )
            if split.saved.isEmpty {
                savedEmptyState
            } else {
                ForEach(split.saved) { location in
                    locationRow(location, kind: .saved)
                }
            }
        }
    }

    private var savedEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("team_location_saved_empty", languageCode: languageCode))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Text(L10n.t("team_location_saved_empty_hint", languageCode: languageCode))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if canManageLocations, !split.recent.isEmpty {
                Text(L10n.t("team_location_saved_empty_tip", languageCode: languageCode))
                    .font(FGTypography.caption)
                    .foregroundStyle(accent.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            sectionHeader(
                title: L10n.t("team_location_recent_section", languageCode: languageCode),
                systemImage: "clock.fill"
            )
            if split.recent.isEmpty {
                emptyHint(L10n.t("team_location_recent_empty", languageCode: languageCode))
            } else {
                ForEach(split.recent) { location in
                    locationRow(location, kind: .recent)
                }
            }
        }
    }

    private var searchAndAddSection: some View {
        VStack(spacing: FGSpacing.sm) {
            Button {
                showSearch = true
            } label: {
                actionRow(
                    systemImage: "magnifyingglass",
                    title: L10n.t("team_location_search", languageCode: languageCode)
                )
            }
            .buttonStyle(.plain)

            Button {
                showMapPicker = true
            } label: {
                actionRow(
                    systemImage: "mappin.and.ellipse",
                    title: L10n.t("team_location_choose_on_map", languageCode: languageCode)
                )
            }
            .buttonStyle(.plain)

            Button {
                showManualEntry = true
            } label: {
                actionRow(
                    systemImage: "pencil.line",
                    title: L10n.t("team_location_enter_manually", languageCode: languageCode)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, FGSpacing.sm)
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title)
                .font(FGTypography.metadata.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .padding(.vertical, 6)
    }

    private enum RowKind { case saved, recent }

    private func locationRow(_ location: FanTeamLocation, kind: RowKind) -> some View {
        Button {
            guard let selection = location.selection else {
                bannerError = L10n.t("team_location_incomplete", languageCode: languageCode)
                return
            }
            TeamLocationDebug.log(
                "locationSelected",
                detail: "teamID=\(teamId.uuidString.lowercased()) locationID=\(location.id.uuidString.lowercased()) kind=\(kind == .saved ? "saved" : "recent")"
            )
            finishSelect(selection)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind == .saved ? "star.fill" : "clock")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(location.title)
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if location.isDefault {
                            Text(L10n.t("team_location_default_badge", languageCode: languageCode))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
                        }
                    }
                    if let place = location.subtitlePlace {
                        Text(place)
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !location.addressLine.isEmpty {
                        Text(location.addressLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if kind == .recent {
                        Text(
                            FanTeamLocationPresentation.recentUsageCaption(
                                lastUsedAt: location.lastUsedAt,
                                usageCount: location.usageCount,
                                languageCode: languageCode
                            )
                        )
                        .font(FGTypography.caption)
                        .foregroundStyle(accent.opacity(0.9))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canManageLocations {
                    saveToggleButton(for: location, kind: kind)
                }

                if canManageLocations, kind == .saved {
                    Button {
                        editingLocation = location
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("team_location_edit", languageCode: languageCode))
                } else if !(canManageLocations && kind == .recent) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(FGSpacing.md)
            .background(
                FGAdaptiveSurface.cardElevated,
                in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(isMutating)
        .accessibilityLabel(
            FanTeamLocationPresentation.accessibilityLabel(location: location, languageCode: languageCode)
        )
        .contextMenu {
            if canManageLocations, kind == .recent, location.selection != nil {
                Button {
                    promptSaveFromRecent(location)
                } label: {
                    Label(
                        L10n.t("team_location_save_action", languageCode: languageCode),
                        systemImage: "star"
                    )
                }
            }
            if canManageLocations, kind == .saved {
                Button {
                    editingLocation = location
                } label: {
                    Label(
                        L10n.t("team_location_edit", languageCode: languageCode),
                        systemImage: "pencil"
                    )
                }
                Button(role: .destructive) {
                    Task { await persistRemove(location: location) }
                } label: {
                    Label(
                        L10n.t("team_location_unsave_action", languageCode: languageCode),
                        systemImage: "star.slash"
                    )
                }
            }
        }
    }

    private func saveToggleButton(for location: FanTeamLocation, kind: RowKind) -> some View {
        Button {
            switch kind {
            case .recent:
                promptSaveFromRecent(location)
            case .saved:
                Task { await persistRemove(location: location) }
            }
        } label: {
            Image(systemName: kind == .saved ? "star.fill" : "star")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMutating)
        .accessibilityLabel(
            L10n.t(
                kind == .saved ? "team_location_unsave_action" : "team_location_save_action",
                languageCode: languageCode
            )
        )
        .accessibilityHint(
            L10n.t(
                kind == .saved ? "team_location_unsave_a11y_hint" : "team_location_save_a11y_hint",
                languageCode: languageCode
            )
        )
    }

    private func actionRow(systemImage: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
            Text(title)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
        }
        .padding(FGSpacing.md)
        .background(
            FGAdaptiveSurface.cardElevated,
            in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func finishSelect(_ selection: FanTeamLocationSelection) {
        guard selection.hasValidCoordinate else {
            bannerError = L10n.t("team_location_incomplete", languageCode: languageCode)
            return
        }
        TeamLocationDebug.log(
            "locationSelected",
            detail: "teamID=\(teamId.uuidString.lowercased()) lat=\(selection.latitude) lon=\(selection.longitude)"
        )
        onSelect(selection)
        dismiss()
    }

    /// After Search / Map / Manual: offer an explicit Save before applying the selection.
    private func offerSaveThenSelect(_ selection: FanTeamLocationSelection) {
        guard selection.hasValidCoordinate else {
            bannerError = L10n.t("team_location_incomplete", languageCode: languageCode)
            return
        }
        guard canManageLocations else {
            finishSelect(selection)
            return
        }
        if isAlreadySaved(selection) {
            finishSelect(selection)
            return
        }
        pendingSaveSelection = selection
        saveNickname = selection.primaryDisplayLine
        saveThenSelect = true
        showSavePrompt = true
    }

    private func promptSaveFromRecent(_ location: FanTeamLocation) {
        guard let selection = location.selection else {
            bannerError = L10n.t("team_location_incomplete", languageCode: languageCode)
            return
        }
        pendingSaveSelection = selection
        saveNickname = location.title
        saveThenSelect = false
        showSavePrompt = true
    }

    private func isAlreadySaved(_ selection: FanTeamLocationSelection) -> Bool {
        FanTeamLocationPresentation.isSelectionAlreadySaved(selection, amongSaved: split.saved)
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            locations = try await FanTeamLocationService().listLocations(teamId: teamId)
        } catch {
            // Soft-fail when migration is not applied yet — picker still supports search/map.
            loadError = nil
            locations = []
            TeamLocationDebug.log(
                "savedLocationsLoaded",
                detail: "teamID=\(teamId.uuidString.lowercased()) softFail=\(error.localizedDescription)"
            )
        }
    }

    private func savePendingAndSelect() async {
        guard var selection = pendingSaveSelection else { return }
        let shouldSelectAfter = saveThenSelect
        isMutating = true
        defer { isMutating = false }
        do {
            let saved = try await FanTeamLocationService().saveLocation(
                teamId: teamId,
                selection: selection,
                nickname: saveNickname,
                setDefault: false
            )
            selection.teamLocationId = saved.id
            selection.nickname = saved.nickname
            bannerError = nil
            await reload()
            pendingSaveSelection = nil
            if shouldSelectAfter {
                finishSelect(selection)
            }
        } catch {
            // Keep the pending selection; do not claim Saved if the RPC failed.
            bannerError = error.localizedDescription
            pendingSaveSelection = nil
            if shouldSelectAfter {
                finishSelect(selection)
            }
        }
    }

    private func persistEdit(location: FanTeamLocation, nickname: String, isDefault: Bool) async {
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await FanTeamLocationService().updateLocation(
                locationId: location.id,
                nickname: nickname,
                clearNickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isDefault: isDefault
            )
            editingLocation = nil
            await reload()
        } catch {
            bannerError = error.localizedDescription
        }
    }

    private func persistRemove(location: FanTeamLocation) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await FanTeamLocationService().removeSavedLocation(locationId: location.id)
            editingLocation = nil
            await reload()
        } catch {
            bannerError = error.localizedDescription
        }
    }

    private func clearRecent() async {
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await FanTeamLocationService().clearRecentLocations(teamId: teamId)
            await reload()
        } catch {
            bannerError = error.localizedDescription
        }
    }
}

// MARK: - Search (MapKit)

private struct FanTeamLocationSearchSheet: View {
    let languageCode: String
    let onCancel: () -> Void
    let onSelect: (FanTeamLocationSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var controller = FanTeamLocationSearchController()
    @State private var query = ""
    @State private var isResolving = false
    @State private var resolveError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(FGColor.intentTeams)
                    TextField(
                        L10n.t("team_location_search", languageCode: languageCode),
                        text: $query
                    )
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .onChange(of: query) { _, value in
                        controller.refresh(query: value)
                    }
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, 12)
                .background(FGAdaptiveSurface.cardElevated)

                if let resolveError {
                    Text(resolveError)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.accentYellow)
                        .padding(FGSpacing.md)
                }

                List {
                    ForEach(controller.suggestions) { suggestion in
                        Button {
                            Task { await select(suggestion) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(FGTypography.body.weight(.semibold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(FGTypography.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(isResolving)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(L10n.t("team_location_search", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode), action: onCancel)
                }
            }
            .overlay {
                if isResolving {
                    ProgressView()
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func select(_ suggestion: FanTeamLocationSearchSuggestion) async {
        isResolving = true
        resolveError = nil
        defer { isResolving = false }
        do {
            let request = MKLocalSearch.Request(completion: suggestion.completion)
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                resolveError = L10n.t("team_location_incomplete", languageCode: languageCode)
                return
            }
            guard let selection = FanTeamMapItemLocationAdapter.selection(from: item) else {
                resolveError = L10n.t("team_location_incomplete", languageCode: languageCode)
                return
            }
            onSelect(selection)
        } catch {
            resolveError = error.localizedDescription
        }
    }
}

private struct FanTeamLocationSearchSuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion
}

@MainActor
private final class FanTeamLocationSearchController: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [FanTeamLocationSearchSuggestion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func refresh(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            suggestions = []
            return
        }
        completer.queryFragment = trimmed
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let mapped = completer.results.prefix(12).enumerated().map { index, completion in
            FanTeamLocationSearchSuggestion(
                id: "\(index)-\(completion.title)-\(completion.subtitle)",
                title: completion.title,
                subtitle: completion.subtitle,
                completion: completion
            )
        }
        Task { @MainActor in
            self.suggestions = Array(mapped)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
        }
    }
}

// MARK: - Manual entry

private struct FanTeamManualLocationEntrySheet: View {
    let languageCode: String
    @ObservedObject var viewModel: MapViewModel
    let onCancel: () -> Void
    let onConfirm: (FanTeamLocationSelection) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var placeName = ""
    @State private var address = ""
    @State private var city = ""
    @State private var state = ""
    @State private var zipCode = ""
    @State private var countryCode = FanTeamLocationPresentation.suggestedDefaultCountryCode()
    @State private var isGeocoding = false
    @State private var errorText: String?

    private var addressLabels: BusinessLocationAddressLabels {
        BusinessLocationCountryPolicy.labels(for: countryCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("team_location_place_name", languageCode: languageCode), text: $placeName)
                    TextField(L10n.t("pickup_form_street_address", languageCode: languageCode), text: $address)
                    TextField(L10n.t("pickup_form_city", languageCode: languageCode), text: $city)
                    FanGeoISOCountryFieldRow(
                        countryCode: $countryCode,
                        languageCode: languageCode,
                        onCountryChange: { newCode in
                            BusinessLocationCountryPolicy.clearDefaultRegionIfNeeded(&state, whenCountryChangesTo: newCode)
                        }
                    )
                    if BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode) == "US" {
                        BusinessLocationRegionField(
                            countryCode: countryCode,
                            labels: BusinessLocationAddressLabels(
                                locality: addressLabels.locality,
                                region: L10n.t("team_location_region", languageCode: languageCode),
                                postalCode: L10n.t("team_location_postal", languageCode: languageCode),
                                regionRequired: false,
                                localityRequired: false
                            ),
                            region: $state
                        )
                    } else {
                        TextField(L10n.t("team_location_region", languageCode: languageCode), text: $state)
                    }
                    TextField(L10n.t("team_location_postal", languageCode: languageCode), text: $zipCode)
                        .textInputAutocapitalization(.characters)
                        .keyboardType(.default)
                } footer: {
                    if let errorText {
                        Text(errorText)
                            .foregroundStyle(FGColor.accentYellow)
                    }
                }
            }
            .navigationTitle(L10n.t("team_location_enter_manually", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Confirm", languageCode: languageCode)) {
                        Task { await confirm() }
                    }
                    .disabled(isGeocoding)
                }
            }
            .overlay {
                if isGeocoding {
                    ProgressView()
                }
            }
        }
    }

    private func confirm() async {
        if let validation = FanTeamLocationPresentation.manualEntryValidationError(
            placeName: placeName,
            address: address,
            city: city,
            countryCode: countryCode,
            languageCode: languageCode
        ) {
            errorText = validation
            return
        }
        isGeocoding = true
        defer { isGeocoding = false }

        let draft = FanTeamLocationSelection(
            teamLocationId: nil,
            nickname: nil,
            placeName: placeName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyManual,
            address: address,
            city: city,
            state: state,
            zipCode: zipCode,
            countryCode: countryCode,
            latitude: 0,
            longitude: 0,
            providerPlaceId: nil
        )
        let query = draft.geocodeQuery
        guard !query.isEmpty, let coord = await viewModel.geocodeAddress(query) else {
            errorText = L10n.t("team_location_geocode_failed", languageCode: languageCode)
            return
        }
        onConfirm(
            FanTeamLocationSelection(
                teamLocationId: nil,
                nickname: nil,
                placeName: draft.placeName,
                address: address,
                city: city,
                state: state,
                zipCode: zipCode,
                countryCode: countryCode,
                latitude: coord.latitude,
                longitude: coord.longitude,
                providerPlaceId: nil
            )
        )
    }
}

private extension String {
    var nilIfEmptyManual: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Edit saved

private struct FanTeamSavedLocationEditSheet: View {
    let location: FanTeamLocation
    let languageCode: String
    let onCancel: () -> Void
    let onSave: (String, Bool) async -> Void
    let onRemove: () async -> Void

    @State private var nickname: String
    @State private var isDefault: Bool
    @State private var isWorking = false

    init(
        location: FanTeamLocation,
        languageCode: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, Bool) async -> Void,
        onRemove: @escaping () async -> Void
    ) {
        self.location = location
        self.languageCode = languageCode
        self.onCancel = onCancel
        self.onSave = onSave
        self.onRemove = onRemove
        _nickname = State(initialValue: location.nickname ?? location.placeName ?? "")
        _isDefault = State(initialValue: location.isDefault)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.t("team_location_nickname", languageCode: languageCode),
                        text: $nickname
                    )
                    Toggle(L10n.t("team_location_set_default", languageCode: languageCode), isOn: $isDefault)
                        .tint(FGColor.intentTeams)
                } footer: {
                    Text(location.addressLine)
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            isWorking = true
                            await onRemove()
                            isWorking = false
                        }
                    } label: {
                        Text(L10n.t("team_location_remove_saved", languageCode: languageCode))
                    }
                }
            }
            .navigationTitle(L10n.t("team_location_edit", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save", languageCode: languageCode)) {
                        Task {
                            isWorking = true
                            await onSave(nickname, isDefault)
                            isWorking = false
                        }
                    }
                    .disabled(isWorking)
                }
            }
        }
    }
}

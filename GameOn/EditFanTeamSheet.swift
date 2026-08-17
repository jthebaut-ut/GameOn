import CoreLocation
import MapKit
import PhotosUI
import SwiftUI
import UIKit

/// Owner/Manager Edit Team sheet: logo, name, sport, curated color palette.
struct EditFanTeamSheet: View {
    let team: FanTeamSummary
    @ObservedObject var mapViewModel: MapViewModel
    var onSaved: (FanTeamSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var name: String
    @State private var sport: String
    @State private var colorHex: String
    @State private var competitionLevel: PickupCompetitionLevel?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var localPreviewImage: UIImage?
    @State private var removeLogoRequested = false
    @State private var isSaving = false
    @State private var isLoadingPhoto = false
    @State private var errorText: String?
    @State private var discovery = FanTeamDiscoverySettings.hidden
    @State private var isLoadingDiscovery = false
    @State private var discoveryDidLoad = false
    @State private var showDiscoveryLocationPicker = false

    private let service = FanTeamsService()

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var sportOptions: [String] {
        AppSportCatalog.formPickerSportsOrdered.map {
            AppSportCatalog.displayLabel(forSportToken: $0)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving
            && !isLoadingPhoto
            && trimmedName.count >= 1
            && trimmedName.count <= 60
            && FanTeamColorPalette.isValidHex(colorHex)
    }

    private var effectiveLogoURL: String? {
        if removeLogoRequested || pendingImageData != nil { return nil }
        return team.logoURL
    }

    private var effectiveLogoThumbnailURL: String? {
        if removeLogoRequested || pendingImageData != nil { return nil }
        return team.logoThumbnailURL
    }

    private var canRemovePhoto: Bool {
        if localPreviewImage != nil { return true }
        if removeLogoRequested { return false }
        return team.logoURL != nil || team.logoThumbnailURL != nil
    }

    init(team: FanTeamSummary, mapViewModel: MapViewModel, onSaved: @escaping (FanTeamSummary) -> Void) {
        self.team = team
        self.mapViewModel = mapViewModel
        self.onSaved = onSaved
        _name = State(initialValue: team.name)
        _sport = State(initialValue: team.sport.isEmpty ? "Soccer" : team.sport)
        _colorHex = State(initialValue: FanTeamColorPalette.normalized(team.colorHex) ?? FanTeamColorPalette.defaultHex)
        _competitionLevel = State(initialValue: team.competitionLevel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    photoSection
                    EditProfileSection(title: L10n.t("fan_teams_edit_section_team", languageCode: languageCode)) {
                        nameRow
                        EditProfileRowDivider()
                        sportRow
                        EditProfileRowDivider()
                        competitionLevelRow
                    }
                    EditProfileSection(title: L10n.t("fan_teams_edit_section_appearance", languageCode: languageCode)) {
                        colorSection
                    }
                    FanTeamDiscoveryEditorSection(
                        discovery: $discovery,
                        team: team,
                        draftName: trimmedName,
                        draftSport: sport,
                        draftColorHex: colorHex,
                        logoURL: effectiveLogoURL,
                        logoThumbnailURL: effectiveLogoThumbnailURL,
                        localPreviewImage: localPreviewImage,
                        isLoading: isLoadingDiscovery,
                        languageCode: languageCode,
                        onChooseLocation: { showDiscoveryLocationPicker = true }
                    )
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(FGColor.dangerRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
            .navigationTitle(L10n.t("fan_teams_edit_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("fan_teams_edit_save", languageCode: languageCode)) {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear {
                if !sportOptions.contains(sport), let first = sportOptions.first {
                    sport = first
                }
                Task { await loadDiscoverySettings() }
            }
            .onChange(of: sport) { _, newSport in
                if SportSubtypeCatalog.hasSubtypes(forSport: newSport) {
                    discovery.sportSubtype = SportSubtypeCatalog.normalizedSubtype(
                        sport: newSport,
                        subtype: discovery.sportSubtype
                    ) ?? SportSubtypeCatalog.defaultSubtype(forSport: newSport)
                } else {
                    discovery.sportSubtype = nil
                }
            }
            .sheet(isPresented: $showDiscoveryLocationPicker) {
                FanTeamChooseLocationSheet(
                    viewModel: mapViewModel,
                    teamId: team.id,
                    canManageLocations: team.canEditIdentity,
                    initialCoordinate: discoveryMapSeedCoordinate,
                    titleKey: "team_discovery_location_title",
                    onCancel: { showDiscoveryLocationPicker = false },
                    onSelect: { selection in
                        discovery.apply(selection: selection)
                        showDiscoveryLocationPicker = false
                        errorText = nil
                    }
                )
            }
            .onChange(of: selectedPhotoItem) { _, item in
                Task { await loadPickedPhoto(item) }
            }
        }
    }

    private var photoSection: some View {
        VStack(spacing: 10) {
            FanTeamMarkView(
                sport: sport,
                logoURL: effectiveLogoURL,
                logoThumbnailURL: effectiveLogoThumbnailURL,
                colorHex: colorHex,
                size: 88,
                preferDetailURL: true,
                localPreviewImage: localPreviewImage
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("fan_teams_logo_a11y", languageCode: languageCode))

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text(L10n.t("fan_teams_change_photo", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
            }
            .disabled(isSaving || isLoadingPhoto)
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("fan_teams_change_photo_a11y", languageCode: languageCode))

            if canRemovePhoto {
                Button(role: .destructive) {
                    pendingImageData = nil
                    localPreviewImage = nil
                    selectedPhotoItem = nil
                    removeLogoRequested = true
                } label: {
                    Text(L10n.t("fan_teams_remove_photo", languageCode: languageCode))
                        .font(.caption.weight(.semibold))
                }
                .disabled(isSaving || isLoadingPhoto)
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("fan_teams_remove_photo_a11y", languageCode: languageCode))
            }

            if isLoadingPhoto {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var nameRow: some View {
        HStack {
            Text(L10n.t("fan_teams_name_field", languageCode: languageCode))
                .font(.body)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer(minLength: 12)
            TextField(L10n.t("fan_teams_name_placeholder", languageCode: languageCode), text: $name)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var sportRow: some View {
        HStack {
            Text(L10n.t("fan_teams_sport", languageCode: languageCode))
                .font(.body)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer(minLength: 12)
            Picker("", selection: $sport) {
                ForEach(sportOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .tint(FGColor.secondaryText(colorScheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        if SportSubtypeCatalog.hasSubtypes(forSport: sport) {
            EditProfileRowDivider()
            sportSubtypeRow
        }
    }

    private var competitionLevelRow: some View {
        HStack {
            Text(L10n.t("pickup_form_competition_level", languageCode: languageCode))
                .font(.body)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer(minLength: 12)
            PickupCompetitionLevelMenuPicker(
                selection: $competitionLevel,
                languageCode: languageCode,
                tint: FGColor.secondaryText(colorScheme)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("fan_teams_team_color", languageCode: languageCode))
                    .font(.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer()
                Circle()
                    .fill(Color(fanTeamHex: colorHex) ?? FGColor.accentGreen)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(FGColor.divider(colorScheme), lineWidth: 1))
                Text(FanTeamColorPalette.displayName(for: colorHex, languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6),
                spacing: 10
            ) {
                ForEach(FanTeamColorPalette.swatches, id: \.hex) { swatch in
                    Button {
                        colorHex = swatch.hex
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(fanTeamHex: swatch.hex) ?? FGColor.accentGreen)
                                .frame(width: 30, height: 30)
                            if FanTeamColorPalette.normalized(colorHex) == swatch.hex {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(L10n.t(swatch.nameKey, languageCode: languageCode))
                        .accessibilityAddTraits(
                            FanTeamColorPalette.normalized(colorHex) == swatch.hex ? .isSelected : []
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            ColorPicker(
                L10n.t("fan_teams_custom_color", languageCode: languageCode),
                selection: Binding(
                    get: { Color(fanTeamHex: colorHex) ?? FGColor.accentGreen },
                    set: { colorHex = FanTeamColorPalette.normalized($0.fanTeamHexString) ?? FanTeamColorPalette.defaultHex }
                ),
                supportsOpacity: false
            )
            .padding(.horizontal, 14)

            Text(L10n.t("fan_teams_color_personalizes_helper", languageCode: languageCode))
                .font(.footnote)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }

    private var sportSubtypeRow: some View {
        HStack {
            Text(SportSubtypeCatalog.pickerTitle(forSport: sport, languageCode: languageCode))
                .font(.body)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer(minLength: 12)
            Menu {
                ForEach(SportSubtypeCatalog.subtypes(forSport: sport)) { option in
                    Button {
                        discovery.sportSubtype = option.id
                    } label: {
                        Text(L10n.t(option.labelKey, languageCode: languageCode))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(
                        SportSubtypeCatalog.displayLabel(
                            forSubtype: discovery.sportSubtype ?? "",
                            sport: sport,
                            languageCode: languageCode
                        )
                    )
                    .font(.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SportSubtypeCatalog.pickerTitle(forSport: sport, languageCode: languageCode))
    }

    private var discoveryMapSeedCoordinate: CLLocationCoordinate2D {
        if let selection = discovery.selection, CLLocationCoordinate2DIsValid(selection.coordinate) {
            return selection.coordinate
        }
        if let center = mapViewModel.cameraPosition.region?.center,
           CLLocationCoordinate2DIsValid(center),
           !(center.latitude == 0 && center.longitude == 0) {
            return center
        }
        return CLLocationCoordinate2D(latitude: 40.7608, longitude: -111.8910)
    }

    private func loadDiscoverySettings() async {
        isLoadingDiscovery = true
        defer { isLoadingDiscovery = false }
        do {
            var loaded = try await service.getMyFanTeamDiscovery(teamId: team.id)
            if SportSubtypeCatalog.hasSubtypes(forSport: sport) {
                loaded.sportSubtype = SportSubtypeCatalog.normalizedSubtype(
                    sport: sport,
                    subtype: loaded.sportSubtype
                ) ?? SportSubtypeCatalog.defaultSubtype(forSport: sport)
            } else {
                loaded.sportSubtype = nil
            }
            discovery = loaded
            discoveryDidLoad = true
        } catch {
            discoveryDidLoad = false
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                errorText = L10n.t("fan_teams_photo_load_failed", languageCode: languageCode)
                return
            }
            pendingImageData = data
            localPreviewImage = UIImage(data: data)
            removeLogoRequested = false
            errorText = nil
        } catch {
            errorText = L10n.t("fan_teams_photo_load_failed", languageCode: languageCode)
        }
    }

    private func save() async {
        guard canSave else { return }
        if ModerationService.containsProfanity(trimmedName) {
            errorText = ModerationService.profanityRejectionUserMessage()
            return
        }
        if !FanTeamDiscoveryLocationPolicy.canSave(settings: discovery) {
            errorText = L10n.t("team_discovery_location_required", languageCode: languageCode)
            return
        }
        isSaving = true
        defer { isSaving = false }

        let previousLogo = team.logoURL
        let previousThumb = team.logoThumbnailURL
        var nextLogo = team.logoURL
        var nextThumb = team.logoThumbnailURL

        do {
            if let pendingImageData {
                let uploaded = try await service.uploadTeamLogo(teamId: team.id, imageData: pendingImageData)
                nextLogo = uploaded.fullURL
                nextThumb = uploaded.thumbnailURL
            } else if removeLogoRequested {
                nextLogo = nil
                nextThumb = nil
            }

            let normalizedColor = FanTeamColorPalette.normalized(colorHex) ?? FanTeamColorPalette.defaultHex
            try await service.updateTeamIdentity(
                teamId: team.id,
                name: trimmedName,
                sport: sport.trimmingCharacters(in: .whitespacesAndNewlines),
                colorHex: normalizedColor,
                logoURL: nextLogo,
                logoThumbnailURL: nextThumb,
                competitionLevel: competitionLevel,
                updateCompetitionLevel: true
            )
            if discoveryDidLoad {
                try await service.updateFanTeamDiscovery(discovery, teamId: team.id)
            }

            let updated = team.applyingIdentity(
                name: trimmedName,
                sport: sport.trimmingCharacters(in: .whitespacesAndNewlines),
                colorHex: normalizedColor,
                logoURL: nextLogo,
                logoThumbnailURL: nextThumb,
                competitionLevel: competitionLevel
            )

            let change = FanTeamIdentityChange(
                teamId: team.id,
                conversationId: team.groupConversationId,
                name: updated.name,
                sport: updated.sport,
                colorHex: updated.colorHex,
                competitionLevel: updated.competitionLevel,
                logoURL: updated.logoURL,
                logoThumbnailURL: updated.logoThumbnailURL,
                previousLogoURL: previousLogo,
                previousLogoThumbnailURL: previousThumb,
                artworkReplaced: pendingImageData != nil || removeLogoRequested
            )
            FanTeamIdentityChangeCenter.postIdentityChange(change)

            if let preview = localPreviewImage {
                let warmURLs = ImageDisplayURL.displayURLs(
                    thumbnail: updated.logoThumbnailURL,
                    full: updated.logoURL,
                    refreshToken: change.displayRefreshToken
                )
                if !warmURLs.isEmpty {
                    // FanTeamMarkView loads via DiscoverCachedRemoteImage (.venue bucket).
                    await DiscoverMapImageCache.shared.store(preview, for: warmURLs, bucket: .venue)
                }
            }

            await mapViewModel.deleteReplacedStorageObjectIfNeeded(
                oldPublicURL: previousLogo,
                newPublicURL: nextLogo ?? "",
                bucket: FanTeamsService.teamLogoStorageBucket
            )
            await mapViewModel.deleteReplacedStorageObjectIfNeeded(
                oldPublicURL: previousThumb,
                newPublicURL: nextThumb ?? "",
                bucket: FanTeamsService.teamLogoStorageBucket
            )
            if removeLogoRequested {
                if let previousLogo {
                    await mapViewModel.deleteStorageFile(
                        publicURL: previousLogo,
                        bucketName: FanTeamsService.teamLogoStorageBucket
                    )
                }
                if let previousThumb, previousThumb != previousLogo {
                    await mapViewModel.deleteStorageFile(
                        publicURL: previousThumb,
                        bucketName: FanTeamsService.teamLogoStorageBucket
                    )
                }
            }

            onSaved(updated)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Color palette

enum FanTeamColorPalette {
    static let defaultHex = "#22C25A"

    struct Swatch: Hashable {
        let hex: String
        let nameKey: String
    }

    static let swatches: [Swatch] = [
        Swatch(hex: "#22C25A", nameKey: "fan_teams_color_green"),
        Swatch(hex: "#2F6BFF", nameKey: "fan_teams_color_blue"),
        Swatch(hex: "#FF3B30", nameKey: "fan_teams_color_red"),
        Swatch(hex: "#FF9500", nameKey: "fan_teams_color_orange"),
        Swatch(hex: "#AF52DE", nameKey: "fan_teams_color_purple"),
        Swatch(hex: "#5856D6", nameKey: "fan_teams_color_indigo"),
        Swatch(hex: "#00C7BE", nameKey: "fan_teams_color_teal"),
        Swatch(hex: "#FF2D55", nameKey: "fan_teams_color_pink"),
        Swatch(hex: "#1C1C1E", nameKey: "fan_teams_color_black"),
        Swatch(hex: "#8E8E93", nameKey: "fan_teams_color_gray"),
        Swatch(hex: "#A2845E", nameKey: "fan_teams_color_brown"),
        Swatch(hex: "#34C759", nameKey: "fan_teams_color_mint")
    ]

    static func normalized(_ raw: String?) -> String? {
        guard var hex = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
            return nil
        }
        return "#\(hex.uppercased())"
    }

    static func isValidHex(_ raw: String?) -> Bool {
        normalized(raw) != nil
    }

    static func displayName(for hex: String, languageCode: String) -> String {
        let normalizedHex = normalized(hex) ?? defaultHex
        if let swatch = swatches.first(where: { $0.hex == normalizedHex }) {
            return L10n.t(swatch.nameKey, languageCode: languageCode)
        }
        return L10n.t("fan_teams_color_custom", languageCode: languageCode)
    }
}

private extension Color {
    var fanTeamHexString: String {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #else
        return FanTeamColorPalette.defaultHex
        #endif
    }
}

import SwiftUI

/// Owns rotating placeholder state so Discover map body is not recomputed on every tick.
struct DiscoverFloatingSearchBarRotatingPlaceholder<TrailingAccessory: View>: View {
    @ObservedObject var viewModel: MapViewModel
    var isFocused: FocusState<Bool>.Binding
    let isDiscoverTabSelected: Bool
    let languageCode: String
    let compactWidth: Bool
    let cornerRadius: CGFloat
    let onClear: () -> Void
    let onSubmit: () -> Void
    @ViewBuilder var trailingAccessory: () -> TrailingAccessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""

    @State private var appearanceSeed: UInt64 = UInt64.random(in: 1...UInt64.max)
    @State private var rotationExamples: [DiscoverSearchPlaceholderProvider.Example] = []
    @State private var rotationIndex: Int = 0
    @State private var isShowingGenericPlaceholder: Bool = true
    @State private var lastContextFingerprint: String = ""

    private var genericPlaceholderKey: String {
        compactWidth ? "discover_search_placeholder_compact" : "discover_search_placeholder_with_fans"
    }

    private var genericPlaceholder: String {
        L10n.t(genericPlaceholderKey, languageCode: languageCode)
    }

    private var trimmedQuery: String {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRotationEligible: Bool {
        isDiscoverTabSelected
            && scenePhase == .active
            && !isFocused.wrappedValue
            && trimmedQuery.isEmpty
    }

    private var displayedPlaceholder: String {
        if !isRotationEligible || isShowingGenericPlaceholder || rotationExamples.isEmpty {
            return genericPlaceholder
        }
        let example = rotationExamples[rotationIndex % rotationExamples.count]
        return DiscoverSearchPlaceholderProvider.displayText(for: example, languageCode: languageCode)
    }

    private var placeholderContext: DiscoverSearchPlaceholderProvider.Context {
        let isWatch = viewModel.discoverMapContentMode == .venues
        let isPlay = viewModel.discoverMapContentMode == .pickupGames
        let favoriteNames = FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
            .prefix(2)
            .map(\.name)
        let home = viewModel.currentUserHomeCity.trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscoverSearchPlaceholderProvider.Context(
            selectedSport: viewModel.selectedSport,
            isWatchMode: isWatch,
            isPlayGames: isPlay && viewModel.discoverPickupSubMode == .games,
            isPlayPlaces: isPlay && viewModel.discoverPickupSubMode == .places,
            favoriteTeamNames: Array(favoriteNames),
            homeCity: home.count >= 2 ? home : nil,
            languageCode: languageCode,
            appearanceSeed: appearanceSeed
        )
    }

    private var contextFingerprint: String {
        let c = placeholderContext
        return [
            c.selectedSport,
            c.isWatchMode ? "w" : "p",
            c.isPlayGames ? "g" : "",
            c.isPlayPlaces ? "pl" : "",
            c.favoriteTeamNames.joined(separator: ","),
            c.homeCity ?? "",
            c.languageCode
        ].joined(separator: "|")
    }

    private var rotationTaskID: String {
        [
            isDiscoverTabSelected ? "1" : "0",
            scenePhase == .active ? "a" : "x",
            isFocused.wrappedValue ? "f" : "u",
            trimmedQuery.isEmpty ? "e" : "q",
            String(appearanceSeed)
        ].joined(separator: ":")
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            FGSearchBar(
                placeholder: displayedPlaceholder,
                text: $viewModel.searchText,
                onClear: onClear,
                onSubmit: onSubmit,
                submitLabel: .search,
                textInputAutocapitalization: .words,
                isFocused: isFocused,
                horizontalPadding: 16,
                verticalPadding: 12,
                cornerRadius: cornerRadius,
                contentSpacing: 8,
                textFont: .system(size: 15, weight: .regular, design: .rounded),
                showsBackground: false,
                trailingAccessoryInset: 50
            )
            .animation(
                reduceMotion || isFocused.wrappedValue ? nil : .easeInOut(duration: 0.28),
                value: displayedPlaceholder
            )

            trailingAccessory()
                .padding(.trailing, 18)
        }
        .task(id: rotationTaskID) {
            await runPlaceholderRotation()
        }
        .onChange(of: contextFingerprint) { _, newValue in
            guard isRotationEligible, !isShowingGenericPlaceholder else {
                lastContextFingerprint = newValue
                return
            }
            guard newValue != lastContextFingerprint else { return }
            lastContextFingerprint = newValue
            rebuildExamplesKeepingRotation()
        }
    }

    @MainActor
    private func runPlaceholderRotation() async {
        isShowingGenericPlaceholder = true
        rotationIndex = 0
        guard isRotationEligible else { return }

        // Initial inactivity before teaching examples (approx 3.5s).
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        guard !Task.isCancelled, isRotationEligible else {
            isShowingGenericPlaceholder = true
            return
        }

        rebuildExamplesKeepingRotation()
        isShowingGenericPlaceholder = false
        lastContextFingerprint = contextFingerprint

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, isRotationEligible else {
                isShowingGenericPlaceholder = true
                return
            }
            if contextFingerprint != lastContextFingerprint {
                lastContextFingerprint = contextFingerprint
                rebuildExamplesKeepingRotation()
            }
            advanceRotationIndex()
        }
    }

    private func rebuildExamplesKeepingRotation() {
        let list = DiscoverSearchPlaceholderProvider.makeRotationList(context: placeholderContext)
        rotationExamples = list
        if list.isEmpty {
            isShowingGenericPlaceholder = true
            return
        }
        if rotationIndex >= list.count {
            rotationIndex = 0
        }
    }

    private func advanceRotationIndex() {
        guard rotationExamples.count > 1 else { return }
        let previous = rotationExamples[rotationIndex % rotationExamples.count]
        var next = (rotationIndex + 1) % rotationExamples.count
        // Soft guard: skip one step if category would repeat consecutively.
        if rotationExamples[next].category == previous.category, rotationExamples.count > 2 {
            next = (next + 1) % rotationExamples.count
        }
        rotationIndex = next
    }
}

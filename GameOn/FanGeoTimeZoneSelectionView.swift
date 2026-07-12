import SwiftUI

/// Search-first global time zone picker.
struct FanGeoTimeZoneSelectionView: View {
    @Binding var selection: FanGeoTimeZonePreference
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    var automaticPresentationToken: UUID = UUID()

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [FanGeoTimeZoneDisplayPresentation] {
        FanGeoTimeZoneCatalog.searchResults(matching: trimmedSearch)
            .map { FanGeoTimeZoneDisplayPresentation.make(for: $0.identifier, locale: .current) }
    }

    var body: some View {
        List {
            if trimmedSearch.isEmpty {
                suggestedSearchesSection
            } else if searchResults.isEmpty {
                emptyResultsSection
            } else {
                searchResultsSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search city or country"
        )
        .onChange(of: searchText) { _, newValue in
            let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            let matched = FanGeoTimeZoneSearchMetadata.matchedIdentifierCount(for: query)
            TimeZoneDebug.searchQuery(query, matchedCount: matched)
        }
        .navigationTitle("Search Time Zones")
        .navigationBarTitleDisplayMode(.inline)
        .id(automaticPresentationToken)
        .onAppear {
            TimeZoneDebug.searchOpened()
        }
    }

    private var suggestedSearchesSection: some View {
        Section {
            ForEach(FanGeoTimeZoneSuggestedSearch.shortcuts) { shortcut in
                Button {
                    searchText = shortcut.query
                } label: {
                    HStack {
                        Text(shortcut.label)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        Spacer(minLength: 0)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shortcut.label)
                .accessibilityHint("Search for \(shortcut.label)")
            }
        } header: {
            Text("Suggested Searches")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .textCase(nil)
        }
    }

    private var emptyResultsSection: some View {
        Section {
            Text("No time zones match your search.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityLabel("No time zones match your search")
        }
    }

    private var searchResultsSection: some View {
        Section {
            ForEach(searchResults, id: \.identifier) { presentation in
                FanGeoTimeZoneCompactPresentationRow(
                    presentation: presentation,
                    showsCountry: true,
                    isSelected: isFixedSelection(presentation.identifier),
                    colorScheme: colorScheme
                ) {
                    selectFixed(presentation.identifier)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: FGSpacing.md, bottom: 4, trailing: FGSpacing.md))
                .listRowBackground(Color.clear)
            }
        }
    }

    private func isFixedSelection(_ identifier: String) -> Bool {
        !selection.isAutomatic && selection.storageValue == identifier
    }

    private func selectFixed(_ identifier: String) {
        selection = .fixed(identifier)
        let zone = TimeZone(identifier: identifier) ?? TimeZone.autoupdatingCurrent
        TimeZoneDebug.selectedIdentifier(identifier)
        TimeZoneDebug.displayedOffset(utcOffsetLabel(for: zone, at: Date()))
        TimeZoneDebug.mainScreen(automaticSelected: false)
        dismiss()
    }
}

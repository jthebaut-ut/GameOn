import SwiftUI

// MARK: - General tab

struct SettingsGeneralSection: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            
            SettingsTimeZoneSummaryCard(viewModel: viewModel)
                .padding()
                .background(Color.white.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            
            SettingsCalendarDisplayCard(viewModel: viewModel)
                .padding()
                .background(Color.white.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 22))

            //if viewModel.isAdminLoggedIn {
             //   reportedCommentsAdminCard
            //}
            SettingsReportedCommentsAdminCard(viewModel: viewModel)
        }
    }
}

struct SettingsTimeZoneSummaryCard: View {
    @ObservedObject var viewModel: MapViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("time_zone", languageCode: appLanguageRaw))
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Choose how game times should appear.")
                .font(.caption)
                .foregroundStyle(.secondary)

            NavigationLink {
                FanGeoTimeZoneSettingsView(
                    selection: $viewModel.selectedTimeZone,
                    automaticPresentationToken: viewModel.automaticTimeZonePresentationToken
                )
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.selectedTimeZone.settingsRowSubtitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        let zone = viewModel.selectedTimeZone.resolvedTimeZone()
                        Text("\(viewModel.selectedTimeZone.identifier) · \(utcOffsetLabel(for: zone, at: Date()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Time zone, \(viewModel.selectedTimeZone.settingsRowSubtitle)")
            .accessibilityHint("Opens time zone selection")
        }
    }
}

struct SettingsCalendarDisplayCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calendar Display")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Choose how green calendar dots are shown.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Only show games in visible map area",
                   isOn: $viewModel.calendarUsesVisibleMapRegionOnly)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(viewModel.calendarUsesVisibleMapRegionOnly
                 ? "Matches games to the current map region. Zoom out to discover more."
                 : "Shows all available games regardless of map view.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

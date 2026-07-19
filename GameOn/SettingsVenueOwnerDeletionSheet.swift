import SwiftUI
import UIKit

struct SettingsVenueOwnerDeletionSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var confirmationText: String = ""
    @State private var preview: BusinessAccountDeletionPreview?
    @State private var isLoadingPreview: Bool = false
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String = ""
    @State private var successMessage: String = ""
    @State private var didSucceed: Bool = false

    private var targetBusinessId: UUID? {
        viewModel.currentBusinessIdForAddLocation() ?? viewModel.ownedBusinesses.first?.id
    }

    private var canDelete: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
            && preview != nil
    }

    private var groupedPreviewEvents: [(venueName: String, events: [BusinessAccountDeletionPreviewEvent])] {
        guard let preview else { return [] }
        let grouped = Dictionary(grouping: preview.gamesEventsToRemove, by: \.displayVenueName)
        return grouped
            .map { venueName, events in
                (
                    venueName: venueName,
                    events: events.sorted { lhs, rhs in
                        let lhsStart = lhs.scheduledStartAt ?? ""
                        let rhsStart = rhs.scheduledStartAt ?? ""
                        if lhsStart != rhsStart { return lhsStart < rhsStart }
                        let lhsDate = lhs.eventDate ?? ""
                        let rhsDate = rhs.eventDate ?? ""
                        if lhsDate != rhsDate { return lhsDate < rhsDate }
                        let lhsTime = lhs.eventTime ?? ""
                        let rhsTime = rhs.eventTime ?? ""
                        if lhsTime != rhsTime { return lhsTime < rhsTime }
                        return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
                    }
                )
            }
            .sorted { $0.venueName.localizedCaseInsensitiveCompare($1.venueName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Business-created venues will be permanently deleted. Community venues you claimed will stay on the map but will be removed from your business and returned to the FanGeo community marketplace.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isLoadingPreview {
                    Section("Deletion preview") {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading deletion preview...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let preview {
                    Section("Counts") {
                        countRow("Business venues to delete", preview.businessVenueCount)
                        countRow("Community venues to release", preview.communityVenueCount)
                        countRow("Games/events to remove", preview.eventCount)
                        countRow("Photos to remove", preview.photoCount)
                        countRow("Pending claims to cancel", preview.pendingClaimCount)
                    }

                    Section("Business-created venues") {
                        if preview.businessVenuesToDelete.isEmpty {
                            Text("No business-created venues will be deleted.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preview.businessVenuesToDelete) { venue in
                                previewVenueRow(
                                    name: venue.displayName,
                                    label: venue.label ?? "Will be deleted",
                                    tint: FGColor.dangerRed
                                )
                            }
                        }
                    }

                    Section("Community venues") {
                        if preview.communityVenuesToRelease.isEmpty {
                            Text("No community venues will be released.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preview.communityVenuesToRelease) { venue in
                                previewVenueRow(
                                    name: venue.displayName,
                                    label: venue.label ?? "Will be returned to FanGeo community",
                                    tint: .orange
                                )
                            }
                        }
                    }

                    Section("Games/events to remove") {
                        let groupedEvents = groupedPreviewEvents
                        if groupedEvents.isEmpty {
                            Text("No games or events will be removed.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(groupedEvents, id: \.venueName) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(group.venueName)
                                        .font(.subheadline.weight(.bold))
                                    ForEach(group.events) { event in
                                        previewEventRow(event)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Section("Pending venues/claims") {
                        if preview.pendingBusinessVenuesToDelete.isEmpty,
                           preview.pendingCommunityClaimsToCancel.isEmpty {
                            Text("No pending venues or claims will be cancelled.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            if !preview.pendingBusinessVenuesToDelete.isEmpty {
                                Text("Pending business venues to delete")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                ForEach(preview.pendingBusinessVenuesToDelete) { venue in
                                    previewVenueRow(
                                        name: venue.displayName,
                                        label: venue.label ?? "Pending business venue to delete",
                                        tint: FGColor.dangerRed.opacity(0.88)
                                    )
                                }
                            }

                            if !preview.pendingCommunityClaimsToCancel.isEmpty {
                                Text("Pending community claims to cancel")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                ForEach(preview.pendingCommunityClaimsToCancel) { venue in
                                    previewVenueRow(
                                        name: venue.displayName,
                                        label: venue.label ?? "Pending community claim to cancel",
                                        tint: .orange
                                    )
                                }
                            }
                        }
                    }
                } else {
                    Section("Deletion preview") {
                        Text("Preview unavailable. Close and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Confirm") {
                    TextField("Type DELETE to confirm", text: $confirmationText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    Text("Actual deletion only happens after tapping Delete Business Account. Loading this preview does not delete anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !successMessage.isEmpty {
                    Section {
                        Text(successMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await runDelete() }
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting { ProgressView() }
                            Text(isDeleting ? "Deleting..." : "Delete Business Account")
                            Spacer()
                        }
                    }
                    .disabled(!canDelete || isLoadingPreview || isDeleting || didSucceed)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Delete business account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSucceed ? "Done" : "Close") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .task(id: targetBusinessId) {
                await loadPreview()
            }
        }
    }

    @ViewBuilder
    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewVenueRow(name: String, label: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "building.2.crop.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func previewEventRow(_ event: BusinessAccountDeletionPreviewEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(previewEventMetadata(event))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .padding(.vertical, 2)
    }

    private func previewEventMetadata(_ event: BusinessAccountDeletionPreviewEvent) -> String {
        let league = event.league?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sport = event.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let date = event.eventDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = event.eventTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scheduled = event.scheduledStartAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = event.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dateTime = [date, time].filter { !$0.isEmpty }.joined(separator: " · ")
        var parts = [String]()
        if !sport.isEmpty { parts.append(sport) }
        if !league.isEmpty { parts.append(league) }
        if !dateTime.isEmpty {
            parts.append(dateTime)
        } else if !scheduled.isEmpty {
            parts.append(scheduled)
        }
        if !status.isEmpty { parts.append(status.capitalized) }
        return parts.isEmpty ? "Event details unavailable" : parts.joined(separator: " • ")
    }

    private func loadPreview() async {
        guard let businessId = targetBusinessId else {
            await MainActor.run {
                preview = nil
                errorMessage = "No active business account was found."
            }
            return
        }

        await MainActor.run {
            isLoadingPreview = true
            errorMessage = ""
            successMessage = ""
            preview = nil
        }
        defer {
            Task { @MainActor in isLoadingPreview = false }
        }

        do {
            let loaded = try await viewModel.businessAccountDeletionPreview(businessId: businessId)
            await MainActor.run {
                if loaded.blocked == true {
                    let reason = loaded.blockReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    switch reason {
                    case "business_disabled":
                        errorMessage = "This business account is disabled and cannot be deleted from the app. Contact FanGeo Support."
                    case "already_deleted":
                        errorMessage = "This business account has already been deleted."
                    default:
                        errorMessage = reason.isEmpty
                            ? "Business account deletion is not available right now."
                            : "Business account deletion is not available (\(reason))."
                    }
                    preview = nil
                    return
                }
                guard loaded.ok else {
                    errorMessage = "Deletion preview is unavailable for this business account."
                    preview = nil
                    return
                }
                preview = loaded
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runDelete() async {
        guard let businessId = targetBusinessId else {
            errorMessage = "No active business account was found."
            return
        }

        isDeleting = true
        defer { isDeleting = false }
        errorMessage = ""
        successMessage = ""

        do {
            _ = try await viewModel.deleteBusinessAccountCascade(businessId: businessId)
            await MainActor.run {
                successMessage = L10n.t("business_account_deleted_success", languageCode: appLanguageRaw)
                didSucceed = true
                confirmationText = ""
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

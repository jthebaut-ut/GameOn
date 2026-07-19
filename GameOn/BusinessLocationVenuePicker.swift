import SwiftUI

// MARK: - Phase B2 (managed venue location picker — Settings + VenueOwnerDashboard)

/// Shared managed-venue display status for Selected Venue chrome and Managed Venues selector.
fileprivate enum BusinessManagedVenueDisplayStatus {
    case approved
    case locked
    case pending
    case rejected

    static func resolve(
        for row: VenueProfileRow,
        effectiveMembership: BusinessVenueGamePostingStatus?
    ) -> BusinessManagedVenueDisplayStatus {
        if MapViewModel.venueDisplaysAsPlanLocked(
            row,
            effectiveMembership: effectiveMembership
        ) {
            return .locked
        }
        let raw = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty || raw == "active" { return .approved }
        if raw == "plan_locked" { return .locked }
        if raw.contains("pending") || raw.contains("review") { return .pending }
        if raw.contains("reject") || raw.contains("archive") { return .rejected }
        return .approved
    }

    /// Compact labels for the Selected Venue picker row (hero / header chrome).
    func compactPickerTitle(languageCode: String) -> String {
        switch self {
        case .approved:
            return L10n.t("venue_status_verified", languageCode: languageCode)
        case .pending:
            return L10n.t("Pending", languageCode: languageCode)
        case .locked:
            return L10n.t("venue_plan_locked", languageCode: languageCode)
        case .rejected:
            return L10n.t("Rejected", languageCode: languageCode)
        }
    }
}

/// Dropdown for **approved** managed venues (see ``MapViewModel/managedVenuesForOwner()``). Settings may also offer **Add venue**, which opens the same submit-new-location flow as before (distinct from Discover → Claim this venue on an existing listing).
struct BusinessLocationVenuePicker: View {
    enum Chrome {
        case settings
        case dashboard
        case headerCompact
    }

    private typealias ManagedVenueSelectorStatus = BusinessManagedVenueDisplayStatus

    private struct ManagedVenueSelectorRow: Identifiable {
        let id: String
        let venueID: UUID?
        let claimID: UUID?
        let title: String
        let subtitle: String
        let ownershipApprovalLine: String?
        let statusNote: String?
        let status: ManagedVenueSelectorStatus
        let venueRow: VenueProfileRow?
    }

    private struct ManagedVenueListingCounts {
        let totalVenueCount: Int
        let approvedVenueCount: Int
        let lockedVenueCount: Int
        let pendingVenueCount: Int
    }

    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    var chrome: Chrome = .settings
    /// When set (Settings), shown as the last menu action to submit a new business location for review.
    var onRequestAddNewLocation: (() -> Void)?
    /// When set, approved managed venue rows show a compact Edit affordance that opens Venue Details.
    var onEditApprovedVenue: ((UUID) -> Void)?
    var isHydrating = false
    var hydrationReason = "ready"
    var onBlockedEarlyTap: ((String, String) -> Void)?
    /// When incremented by the Business Dashboard “Manage Venues” quick action, presents the same Managed Venues sheet as the venue selector.
    var venueListPresentationToken: UInt = 0
    @State private var showVenueListSheet = false
    @State private var isRefreshingVenueSelector = false
    @State private var venueSelectorNotice: String?

    init(
        viewModel: MapViewModel,
        chrome: Chrome = .settings,
        onRequestAddNewLocation: (() -> Void)? = nil,
        onEditApprovedVenue: ((UUID) -> Void)? = nil,
        isHydrating: Bool = false,
        hydrationReason: String = "ready",
        onBlockedEarlyTap: ((String, String) -> Void)? = nil,
        venueListPresentationToken: UInt = 0
    ) {
        self.viewModel = viewModel
        self.chrome = chrome
        self.onRequestAddNewLocation = onRequestAddNewLocation
        self.onEditApprovedVenue = onEditApprovedVenue
        self.isHydrating = isHydrating
        self.hydrationReason = hydrationReason
        self.onBlockedEarlyTap = onBlockedEarlyTap
        self.venueListPresentationToken = venueListPresentationToken
    }

    private var venuePairs: [(UUID, String)] {
        var seenVenueIDs = Set<UUID>()
        return viewModel.managedVenuesForOwner().compactMap { row in
            guard let id = row.id else { return nil }
            guard managedVenueStatus(for: row) == .approved else { return nil }
            guard seenVenueIDs.insert(id).inserted else { return nil }
            let raw = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = raw.isEmpty ? "Location" : raw
            return (id, label)
        }
    }

    private var managedVenueSelectorRows: [ManagedVenueSelectorRow] {
        var seenApprovedVenueIDs = Set<UUID>()
        let approvedRows = viewModel.managedVenuesForOwner().compactMap { row -> ManagedVenueSelectorRow? in
            guard let id = row.id else { return nil }
            guard seenApprovedVenueIDs.insert(id).inserted else { return nil }
            return ManagedVenueSelectorRow(
                id: "venue-\(id.uuidString)",
                venueID: id,
                claimID: nil,
                title: venueDisplayName(for: row),
                subtitle: MapViewModel.venueDisplaysAsPlanLocked(
                    row,
                    effectiveMembership: viewModel.effectiveBusinessMembershipStatus
                )
                    ? BusinessLimitCopy.planLockedVenueSubtitle(languageCode: appLanguageRaw)
                    : (venueLocationSubtitle(for: row).isEmpty ? "Approved location for listings, games, and analytics." : venueLocationSubtitle(for: row)),
                ownershipApprovalLine: MapViewModel.venueDisplaysAsPlanLocked(
                    row,
                    effectiveMembership: viewModel.effectiveBusinessMembershipStatus
                )
                    ? nil
                    : managedVenueOwnershipApprovalLine(for: row),
                statusNote: MapViewModel.venueDisplaysAsPlanLocked(
                    row,
                    effectiveMembership: viewModel.effectiveBusinessMembershipStatus
                ) ? BusinessLimitCopy.planLockedVenueSubtitle(languageCode: appLanguageRaw) : nil,
                status: managedVenueStatus(for: row),
                venueRow: row
            )
        }
        let sortedApprovedRows = sortedManagedVenueSelectorRows(approvedRows)
        let approvedVenueIDs = Set(sortedApprovedRows.compactMap(\.venueID))
        var seenPendingVenueIDs = Set<UUID>()
        let pendingRows = viewModel.pendingVenueClaimsForSettings.compactMap { claim -> ManagedVenueSelectorRow? in
            if let venueID = claim.venue_id, approvedVenueIDs.contains(venueID) { return nil }
            if let venueID = claim.venue_id, !seenPendingVenueIDs.insert(venueID).inserted { return nil }
            return managedVenueSelectorClaimRow(claim, status: .pending)
        }
        let rejectedRows = viewModel.rejectedVenueClaimsForSettings.compactMap { claim -> ManagedVenueSelectorRow? in
            if let venueID = claim.venue_id, approvedVenueIDs.contains(venueID) { return nil }
            return managedVenueSelectorClaimRow(claim, status: .rejected)
        }
        return sortedApprovedRows + pendingRows + rejectedRows
    }

    private func sortedManagedVenueSelectorRows(_ rows: [ManagedVenueSelectorRow]) -> [ManagedVenueSelectorRow] {
        let summaries = viewModel.managedVenueUpcomingGamesByVenueId
        return rows.sorted { lhs, rhs in
            let lhsSummary = lhs.venueID.flatMap { summaries[$0] }
            let rhsSummary = rhs.venueID.flatMap { summaries[$0] }
            let lhsCount = lhsSummary?.count ?? 0
            let rhsCount = rhsSummary?.count ?? 0
            let lhsHasUpcoming = lhsCount > 0
            let rhsHasUpcoming = rhsCount > 0
            if lhsHasUpcoming != rhsHasUpcoming {
                return lhsHasUpcoming && !rhsHasUpcoming
            }
            if lhsHasUpcoming, rhsHasUpcoming {
                let lhsNext = lhsSummary?.nextStartAt ?? .distantFuture
                let rhsNext = rhsSummary?.nextStartAt ?? .distantFuture
                if lhsNext != rhsNext {
                    return lhsNext < rhsNext
                }
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var selectedVenueRow: VenueProfileRow? {
        let selectedId = viewModel.ownerVenueDatabaseId ?? venuePairs.first?.0
        guard let selectedId else { return viewModel.managedVenuesForOwner().first }
        return viewModel.managedVenuesForOwner().first(where: { $0.id == selectedId }) ?? viewModel.managedVenuesForOwner().first
    }

    private var selectedManagedVenueSelectorRow: ManagedVenueSelectorRow? {
        if let selectedId = viewModel.ownerVenueDatabaseId,
           let selected = managedVenueSelectorRows.first(where: { $0.venueID == selectedId }),
           selected.status == .approved {
            return selected
        }
        return managedVenueSelectorRows.first(where: { $0.status == .approved })
            ?? managedVenueSelectorRows.first
    }

    private var selectedVenueLabel: String {
        if isHydrating {
            return "Loading venues..."
        }
        if let selected = selectedManagedVenueSelectorRow {
            return selected.title
        }
        let id = viewModel.ownerVenueDatabaseId ?? venuePairs.first?.0
        if let id, let name = venuePairs.first(where: { $0.0 == id })?.1 {
            return name
        }
        return venuePairs.first?.1 ?? "Location"
    }

    private var inactiveVenueSelectionNotice: String {
        L10n.t("business_inactive_venue_selection_notice", languageCode: appLanguageRaw)
    }

    private var selectedVenueSubtitle: String {
        if isHydrating {
            return "Business profile is loading managed venues."
        }
        if let selected = selectedManagedVenueSelectorRow {
            return selected.statusNote ?? selected.subtitle
        }
        if let row = selectedVenueRow {
            let locationLine = venueLocationSubtitle(for: row)
            if !locationLine.isEmpty {
                return locationLine
            }
        }
        if venuePairs.count > 1 {
            return "\(venuePairs.count) approved locations available to manage."
        }
        return "Approved location for listings, games, and analytics."
    }

    private func venueDisplayName(for row: VenueProfileRow) -> String {
        let raw = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Location" : raw
    }

    private func venueLocationSubtitle(for row: VenueProfileRow) -> String {
        let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = (row.region ?? row.state)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = row.country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locationLine = [city, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        if !locationLine.isEmpty { return locationLine }
        let formatted = row.formatted_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !formatted.isEmpty { return formatted }
        return row.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func managedVenueOwnershipApprovalLine(for row: VenueProfileRow) -> String {
        let approvedDateText = managedVenueApprovedDateText(for: row)
        return ManagedVenueOwnershipDisplay.ownershipApprovalLine(
            originType: row.origin_type,
            approvedDateText: approvedDateText
        )
    }

    private func managedVenueApprovedDateText(for row: VenueProfileRow) -> String {
        let claimApprovedRaw = row.id.flatMap { venueId -> String? in
            guard let metadata = viewModel.approvedVenueClaimMetadataByVenueID[venueId] else { return nil }
            return metadata.approvedAtRaw ?? metadata.createdAtRaw
        }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !claimApprovedRaw.isEmpty,
           let date = SupabaseTimestampParsing.parseTimestamptz(claimApprovedRaw) {
            return "Approved \(Self.managedVenueApprovedDateDisplayFormatter.string(from: date))"
        }

        let venueCreatedRaw = row.created_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !venueCreatedRaw.isEmpty,
           let date = SupabaseTimestampParsing.parseTimestamptz(venueCreatedRaw) {
            return "Approved \(Self.managedVenueApprovedDateDisplayFormatter.string(from: date))"
        }

        return "Approved date unavailable"
    }

    private static let managedVenueApprovedDateDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func managedVenueStatus(for row: VenueProfileRow) -> ManagedVenueSelectorStatus {
        BusinessManagedVenueDisplayStatus.resolve(
            for: row,
            effectiveMembership: viewModel.effectiveBusinessMembershipStatus
        )
    }

    private var managedVenueListingCounts: ManagedVenueListingCounts {
        var approvedVenueIDs = Set<UUID>()
        var lockedVenueIDs = Set<UUID>()
        var pendingVenueIDs = Set<UUID>()

        for row in viewModel.managedVenuesForOwner() {
            guard let id = row.id else { continue }
            switch managedVenueStatus(for: row) {
            case .approved:
                approvedVenueIDs.insert(id)
            case .locked:
                lockedVenueIDs.insert(id)
            case .pending:
                pendingVenueIDs.insert(id)
            case .rejected:
                continue
            }
        }

        for claim in viewModel.pendingVenueClaimsForSettings {
            guard let venueID = claim.venue_id else { continue }
            guard !approvedVenueIDs.contains(venueID) else { continue }
            pendingVenueIDs.insert(venueID)
        }

        return ManagedVenueListingCounts(
            totalVenueCount: approvedVenueIDs.union(lockedVenueIDs).union(pendingVenueIDs).count,
            approvedVenueCount: approvedVenueIDs.count,
            lockedVenueCount: lockedVenueIDs.count,
            pendingVenueCount: pendingVenueIDs.count
        )
    }

    private var dashboardVenueListingCountLine: String {
        if isHydrating {
            return "Loading venues..."
        }
        let count = managedVenueListingCounts.totalVenueCount
        return "\(count) \(count == 1 ? "managed venue" : "managed venues")"
    }

    private var dashboardVenueListingStatusLine: String {
        if isHydrating {
            return "Please wait before managing venues"
        }
        let counts = managedVenueListingCounts
        if counts.lockedVenueCount > 0 {
            return "\(counts.approvedVenueCount) active • \(counts.lockedVenueCount) locked • \(counts.pendingVenueCount) pending"
        }
        return "\(counts.approvedVenueCount) active • \(counts.pendingVenueCount) pending"
    }

    private func venueClaimLocationSubtitle(for claim: VenueClaimPendingSettingsRow) -> String {
        let city = claim.venue_city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = claim.venue_state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = claim.venue_country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locationLine = [city, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        if !locationLine.isEmpty { return locationLine }
        return claim.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func pendingClaimSubmittedDateText(_ claim: VenueClaimPendingSettingsRow) -> String {
        guard let raw = claim.created_at?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Submitted date unavailable"
        }
        guard let date = SupabaseTimestampParsing.parseTimestamptz(raw) else {
            return "Submitted \(String(raw.prefix(10)))"
        }
        return "Submitted \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private func managedVenueSelectorClaimRow(
        _ claim: VenueClaimPendingSettingsRow,
        status: ManagedVenueSelectorStatus
    ) -> ManagedVenueSelectorRow {
        let name = claim.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = venueClaimLocationSubtitle(for: claim)
        let title = name.isEmpty ? "Submitted location" : name
        return ManagedVenueSelectorRow(
            id: "claim-\(claim.id.uuidString)-\(statusTitle(for: status))",
            venueID: claim.venue_id,
            claimID: claim.id,
            title: title,
            subtitle: location.isEmpty ? "Business location" : location,
            ownershipApprovalLine: status == .pending ? "Business venue • Pending review" : nil,
            statusNote: status == .pending ? pendingClaimSubmittedDateText(claim) : "Review rejected",
            status: status,
            venueRow: nil
        )
    }

    private func venueStatusTitle(for row: VenueProfileRow?) -> String? {
        let raw = row?.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty || raw == "active" { return "Approved" }
        if raw == "plan_locked" { return BusinessLimitCopy.planLockedVenueBadge(languageCode: appLanguageRaw) }
        if raw.contains("pending") || raw.contains("review") { return "Pending" }
        return raw.capitalized
    }

    private func venueStatusTint(for row: VenueProfileRow?) -> Color {
        let raw = row?.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty || raw == "active" { return FGColor.accentGreen }
        if raw == "plan_locked" { return .orange }
        if raw.contains("pending") || raw.contains("review") { return FGColor.accentYellow }
        if raw.contains("reject") || raw.contains("archive") { return FGColor.dangerRed }
        return FGColor.accentBlue
    }

    private func statusTitle(for status: ManagedVenueSelectorStatus) -> String {
        switch status {
        case .approved:
            return "Approved"
        case .locked:
            return BusinessLimitCopy.planLockedVenueBadge(languageCode: appLanguageRaw)
        case .pending:
            return "Pending"
        case .rejected:
            return "Rejected"
        }
    }

    private func statusTint(for status: ManagedVenueSelectorStatus) -> Color {
        switch status {
        case .approved:
            return FGColor.accentGreen
        case .locked:
            return .orange
        case .pending:
            return .orange
        case .rejected:
            return FGColor.dangerRed
        }
    }

    private func blockHydratingTap(action: String) -> Bool {
        guard isHydrating else { return false }
        onBlockedEarlyTap?(action, hydrationReason)
        return true
    }

    private var settingsPickerLabel: String {
        switch chrome {
        case .settings:
            return "Current managed venue"
        case .dashboard, .headerCompact:
            return "Managing location"
        }
    }

    @ViewBuilder
    private func settingsPickerRowLabel(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        showsApprovedBadge: Bool,
        chevronSystemName: String
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: FGSpacing.xs + 2) {
                    Text(title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if showsApprovedBadge {
                        managedVenueApprovedBadge()
                    }
                }

                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: chevronSystemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(width: 16, height: 16, alignment: .center)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 13)
        .frame(minHeight: 70, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func addVenueMenuButton() -> some View {
        Button {
            onRequestAddNewLocation?()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add venue")
                        .foregroundStyle(.primary)
                    Text("Submit a new location for review")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func settingsChromeMenuContent() -> some View {
        ForEach(venuePairs, id: \.0) { pair in
            Button {
                guard !blockHydratingTap(action: "viewingVenueSelector") else { return }
                Task {
                    await viewModel.selectManagedVenue(id: pair.0)
#if DEBUG
                    print("[BusinessManagedVenueTapDebug] selectedVenueUpdated venueId=\(pair.0.uuidString.lowercased())")
#endif
                }
            } label: {
                Text(pair.1)
            }
        }
        if onRequestAddNewLocation != nil {
            if !venuePairs.isEmpty {
                Divider()
            }
            addVenueMenuButton()
        }
    }

    @ViewBuilder
    private func settingsChromeMenuLabel() -> some View {
        let isEmpty = venuePairs.isEmpty
        settingsPickerRowLabel(
            title: isEmpty ? "No approved venues yet" : selectedVenueLabel,
            subtitle: isEmpty
                ? "Add a location for review, or claim an existing venue from the map (Discover → venue → Claim this venue)."
                : selectedVenueSubtitle,
            systemImage: isEmpty ? "mappin.and.ellipse" : "building.2",
            tint: isEmpty ? FGColor.mutedText(colorScheme) : FGColor.accentBlue,
            showsApprovedBadge: selectedManagedVenueSelectorRow?.status == .approved,
            chevronSystemName: "chevron.up.chevron.down"
        )
    }

    @ViewBuilder
    private func settingsChromePickerStack() -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text(settingsPickerLabel)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            if isHydrating {
                settingsPickerRowLabel(
                    title: "Loading venues...",
                    subtitle: "Business profile is loading managed venues.",
                    systemImage: "hourglass",
                    tint: FGColor.mutedText(colorScheme),
                    showsApprovedBadge: false,
                    chevronSystemName: "chevron.right"
                )
                .opacity(0.72)
                .allowsHitTesting(false)
            } else if venuePairs.isEmpty, onRequestAddNewLocation == nil {
                settingsPickerRowLabel(
                    title: "No approved venues yet",
                    subtitle: "Claim a venue from the map: Discover → venue → Claim this venue.",
                    systemImage: "mappin.and.ellipse",
                    tint: FGColor.mutedText(colorScheme),
                    showsApprovedBadge: false,
                    chevronSystemName: "chevron.right"
                )
                .opacity(0.88)
                .allowsHitTesting(false)
            } else if venuePairs.isEmpty {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    settingsPickerRowLabel(
                        title: "No approved venues yet",
                        subtitle: "Add your first venue for review, or claim an existing venue from Discover.",
                        systemImage: "mappin.and.ellipse",
                        tint: FGColor.mutedText(colorScheme),
                        showsApprovedBadge: false,
                        chevronSystemName: "chevron.right"
                    )
                    .opacity(0.88)

                    Button {
                        onRequestAddNewLocation?()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text(L10n.t("add_venue", languageCode: appLanguageRaw))
                                .font(FGTypography.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(FGColor.accentGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Menu {
                    settingsChromeMenuContent()
                } label: {
                    settingsChromeMenuLabel()
                }
            }
        }
        .onAppear { viewModel.logBusinessSwitcherDebug() }
    }

    /// Managed venues in this list are approved for owner tools; shown in Settings + dashboard pickers.
    @ViewBuilder
    private func managedVenueApprovedBadge() -> some View {
        Text("Approved")
            .font(FGTypography.metadata.weight(.semibold))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.12))
            .clipShape(Capsule(style: .continuous))
    }

    private func managedVenueStatusBadge(row: VenueProfileRow?) -> some View {
        let tint = venueStatusTint(for: row)
        return Text(venueStatusTitle(for: row) ?? "Approved")
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .clipShape(Capsule(style: .continuous))
    }

    private func managedVenueStatusBadge(status: ManagedVenueSelectorStatus) -> some View {
        let tint = statusTint(for: status)
        return Text(statusTitle(for: status))
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .clipShape(Capsule(style: .continuous))
    }

    private var viewingVenueHeaderThumbnail: some View {
        SelectedVenueThumbnailView(
            venue: selectedVenueRow,
            style: .dashboardSelector,
            showsHourglass: isHydrating
        )
        .id(selectedVenueRow?.id)
        .animation(.snappy(duration: 0.24), value: viewModel.ownerVenueDatabaseId)
    }

    private var headerCompactVenueThumbnail: some View {
        SelectedVenueThumbnailView(
            venue: selectedVenueRow,
            style: .compactHeader,
            showsHourglass: isHydrating
        )
        .id(selectedVenueRow?.id)
        .animation(.snappy(duration: 0.24), value: viewModel.ownerVenueDatabaseId)
    }

    private var dashboardChromeSelectorButton: some View {
        Button {
            guard !blockHydratingTap(action: "viewingVenueSelector") else { return }
#if DEBUG
            print("[BusinessVenueSelectorDebug] selectorTapped=true")
#endif
            showVenueListSheet = true
        } label: {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                viewingVenueHeaderThumbnail

                VStack(alignment: .leading, spacing: 6) {
                    Text("Viewing venue")
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(.uppercase)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(selectedVenueLabel)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        managedVenueStatusBadge(status: selectedManagedVenueSelectorRow?.status ?? .approved)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(dashboardVenueListingCountLine)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)

                        Text(dashboardVenueListingStatusLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isHydrating ? "hourglass" : "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(FGSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(FGAdaptiveSurface.cardElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.65), lineWidth: 1)
                    }
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .opacity(isHydrating ? 0.62 : 1)
        .onAppear {
#if DEBUG
            print("[BusinessVenueSelectorDebug] selectorVisible=true")
#endif
        }
    }

    private var headerCompactSelectorButton: some View {
        Button {
            guard !blockHydratingTap(action: "viewingVenueSelector") else { return }
#if DEBUG
            print("[BusinessVenueSelectorDebug] headerSelectorTapped=true")
#endif
            showVenueListSheet = true
        } label: {
            HStack(spacing: 8) {
                headerCompactVenueThumbnail

                Text(selectedVenueLabel)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)

                if let status = selectedManagedVenueSelectorRow?.status, !isHydrating {
                    headerCompactStatusBadge(status: status)
                        .layoutPriority(1)
                }

                Image(systemName: isHydrating ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .animation(.snappy(duration: 0.24), value: viewModel.ownerVenueDatabaseId)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.14))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.22), lineWidth: 1)
                    }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isHydrating ? 0.68 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
#if DEBUG
            print("[BusinessVenueSelectorDebug] headerSelectorVisible=true")
#endif
        }
    }

    private func headerCompactStatusBadge(status: ManagedVenueSelectorStatus) -> some View {
        let tint = statusTint(for: status)
        return Text(status.compactPickerTitle(languageCode: appLanguageRaw))
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(colorScheme == .dark ? 0.28 : 0.20))
            .clipShape(Capsule(style: .continuous))
            .accessibilityLabel(status.compactPickerTitle(languageCode: appLanguageRaw))
    }

    private var dashboardVenueListSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let venueSelectorNotice {
                        managedVenueSelectorStatusBanner(venueSelectorNotice)
                    }
                    if viewModel.managedVenuesDisplayPlanLocked() {
                        managedVenueSelectorStatusBanner(
                            BusinessLimitCopy.planLockedVenueBanner(languageCode: appLanguageRaw)
                        )
                    }

                    ForEach(managedVenueSelectorRows) { row in
                        managedVenueSheetRow(row)
                    }

                    if onRequestAddNewLocation != nil {
                        Divider()
                            .padding(.vertical, 4)
                        addNewVenueSheetButton
                    }
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.xl)
            }
            .navigationTitle("Managed venues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await refreshManagedVenueSelector()
                        }
                    } label: {
                        Label(isRefreshingVenueSelector ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshingVenueSelector)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showVenueListSheet = false
                    }
                }
            }
            .fanGeoScreenBackground()
            .onAppear {
#if DEBUG
                print("[BusinessVenueSelectorDebug] pendingVenuesVisible count=\(viewModel.pendingVenueClaimsForSettings.count)")
#endif
                Task {
                    await viewModel.refreshManagedVenueUpcomingGamesSummaries()
                }
            }
        }
    }

    @ViewBuilder
    private func managedVenueUpcomingGamesLine(_ summary: ManagedVenueUpcomingGamesSummary) -> some View {
        if summary.count > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(managedVenueUpcomingCountLabel(summary.count))
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .clipShape(Capsule(style: .continuous))

                if let nextStart = summary.nextStartAt {
                    Text(
                        String(
                            format: L10n.t("Next: %@", languageCode: appLanguageRaw),
                            managedVenueUpcomingNextDateText(nextStart)
                        )
                    )
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
        } else {
            Text(L10n.t("No upcoming games", languageCode: appLanguageRaw))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .lineLimit(1)
        }
    }

    private func managedVenueUpcomingCountLabel(_ count: Int) -> String {
        if count == 1 {
            return L10n.t("1 upcoming", languageCode: appLanguageRaw)
        }
        return String(format: L10n.t("%lld upcoming", languageCode: appLanguageRaw), Int64(count))
    }

    private func managedVenueUpcomingNextDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw))
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func managedVenueSelectorStatusBanner(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isRefreshingVenueSelector ? "arrow.clockwise" : "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isRefreshingVenueSelector ? FGColor.accentBlue : .orange)
            Text(message)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .background((isRefreshingVenueSelector ? FGColor.accentBlue : Color.orange).opacity(colorScheme == .dark ? 0.14 : 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func managedVenueSheetRow(_ row: ManagedVenueSelectorRow) -> some View {
        let isSelected = row.status == .approved && row.venueID == viewModel.ownerVenueDatabaseId
        let tint = statusTint(for: row.status)
        return HStack(spacing: FGSpacing.md) {
            SelectedVenueThumbnailView(
                venue: row.venueRow,
                style: .managedVenueList,
                fallbackTint: tint
            )
            .id(row.id)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    managedVenueStatusBadge(status: row.status)
                }

                Text(row.subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                if let ownershipApprovalLine = row.ownershipApprovalLine {
                    Text(ownershipApprovalLine)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                if row.status == .approved,
                   let venueID = row.venueID,
                   let summary = viewModel.managedVenueUpcomingGamesByVenueId[venueID] {
                    managedVenueUpcomingGamesLine(summary)
                }

                if let note = row.statusNote {
                    Text(note)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if row.status == .approved, onEditApprovedVenue != nil {
                managedVenueEditAffordance(for: row)
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
            }
        }
        .padding(FGSpacing.md)
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            handleManagedVenueRowTap(row)
        }
    }

    private func managedVenueEditAffordance(for row: ManagedVenueSelectorRow) -> some View {
        Button {
            handleManagedVenueEditTap(row)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .bold))
                Text("Edit")
                    .font(FGTypography.metadata.weight(.semibold))
            }
            .foregroundStyle(FGColor.accentBlue)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit venue \(row.title)")
    }

    private func handleManagedVenueRowTap(_ row: ManagedVenueSelectorRow) {
        guard !blockHydratingTap(action: "viewingVenueSelector") else { return }
        logBusinessManagedVenueTapDebug("tapped", row: row)
        guard let id = row.venueID else {
            if row.status == .pending {
                venueSelectorNotice = "This venue is waiting for admin approval."
#if DEBUG
                print("[BusinessVenueSelectorDebug] pendingVenueTapped id=\(row.claimID?.uuidString ?? row.venueID?.uuidString ?? "nil")")
#endif
            } else {
                venueSelectorNotice = "This venue request was rejected."
            }
            return
        }

        if row.status == .locked {
            venueSelectorNotice = inactiveVenueSelectionNotice
            logBusinessManagedVenueTapDebug("ignoredInactiveVenue", row: row, venueId: id)
            return
        }

        guard row.status == .approved else {
            venueSelectorNotice = row.status == .pending
                ? "This venue is waiting for admin approval."
                : "This venue request was rejected."
            return
        }

        showVenueListSheet = false
        Task {
            await viewModel.selectManagedVenue(id: id)
#if DEBUG
            print("[BusinessManagedVenueTapDebug] selectedVenueUpdated venueId=\(id.uuidString.lowercased())")
#endif
        }
    }

    private func handleManagedVenueEditTap(_ row: ManagedVenueSelectorRow) {
        guard row.status == .approved, let id = row.venueID else { return }
        guard !blockHydratingTap(action: "editVenueDetails") else { return }
        logBusinessManagedVenueTapDebug("editTapped", row: row, venueId: id)
        showVenueListSheet = false
        onEditApprovedVenue?(id)
    }

    private func logBusinessManagedVenueTapDebug(
        _ event: String,
        row: ManagedVenueSelectorRow,
        venueId explicitVenueId: UUID? = nil
    ) {
#if DEBUG
        let venueId = explicitVenueId ?? row.venueID
        let venueName = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = statusTitle(for: row.status)
        if event == "tapped" {
            print("[BusinessManagedVenueTapDebug] tapped venueId=\(venueId?.uuidString.lowercased() ?? "nil") venueName=\(venueName.isEmpty ? "nil" : venueName) status=\(status)")
        } else if event == "editTapped" {
            print("[BusinessManagedVenueTapDebug] editTapped venueId=\(venueId?.uuidString.lowercased() ?? "nil") venueName=\(venueName.isEmpty ? "nil" : venueName) status=\(status)")
        } else if event == "ignoredInactiveVenue" {
            print("[BusinessManagedVenueTapDebug] ignoredInactiveVenue venueId=\(venueId?.uuidString.lowercased() ?? "nil")")
        }
#endif
    }

    private func refreshManagedVenueSelector() async {
        let shouldRefresh = await MainActor.run { () -> Bool in
            guard !isRefreshingVenueSelector else { return false }
            isRefreshingVenueSelector = true
            venueSelectorNotice = "Refreshing managed venues..."
#if DEBUG
            print("[BusinessVenueSelectorDebug] refreshTapped=true")
#endif
            return true
        }
        guard shouldRefresh else { return }

        await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await viewModel.refreshPendingVenueClaimsForSettings()
        await viewModel.refreshVenueClaimStatusLineFromDatabase()
        await viewModel.refreshManagedVenueUpcomingGamesSummaries()

        await MainActor.run {
            isRefreshingVenueSelector = false
            venueSelectorNotice = "Managed venues refreshed."
#if DEBUG
            print("[BusinessVenueSelectorDebug] refreshCompleted=true")
            print("[BusinessVenueSelectorDebug] pendingVenuesVisible count=\(viewModel.pendingVenueClaimsForSettings.count)")
#endif
        }
    }

    private var addNewVenueSheetButton: some View {
        Button {
#if DEBUG
            print("[BusinessVenueSelectorDebug] addVenueTapped=true")
#endif
            showVenueListSheet = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                onRequestAddNewLocation?()
            }
        } label: {
            HStack(spacing: FGSpacing.md) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentBlue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Add New Venue")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Add Location")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)
            }
            .padding(FGSpacing.md)
            .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func logPickerDebug() {
#if DEBUG
        let n = venuePairs.count
        let sid = viewModel.ownerVenueDatabaseId?.uuidString ?? "nil"
        let sname = venuePairs.first(where: { $0.0 == viewModel.ownerVenueDatabaseId })?.1
            ?? venuePairs.first?.1
            ?? "nil"
        print("[BusinessLocationPicker] venues count=\(n)")
        print("[BusinessLocationPicker] selected id=\(sid)")
        print("[BusinessLocationPicker] selected name=\(sname)")
#endif
    }

    var body: some View {
        Group {
            if isHydrating {
                switch chrome {
                case .settings:
                    settingsChromePickerStack()
                case .dashboard:
                    dashboardChromeSelectorButton
                case .headerCompact:
                    headerCompactSelectorButton
                }
            } else if venuePairs.isEmpty && managedVenueSelectorRows.isEmpty {
                switch chrome {
                case .settings:
                    settingsChromePickerStack()
                case .dashboard, .headerCompact:
                    EmptyView()
                }
            } else {
                switch chrome {
                case .settings:
                    settingsChromePickerStack()

                case .dashboard:
                    dashboardChromeSelectorButton
                case .headerCompact:
                    headerCompactSelectorButton
                }
            }
        }
        .sheet(isPresented: $showVenueListSheet) {
            dashboardVenueListSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .onAppear { logPickerDebug() }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            logPickerDebug()
        }
        .onChange(of: isHydrating) { _, hydrating in
            if hydrating {
                showVenueListSheet = false
            }
        }
        .onChange(of: venueListPresentationToken) { _, token in
            guard token > 0 else { return }
            guard !blockHydratingTap(action: "manageVenuesQuickAction") else { return }
            showVenueListSheet = true
        }
    }
}

import Combine
import Supabase
import SwiftUI

private enum SupportCenterRoute: Hashable {
    case createRequest
    case ticketDetail(UUID)
    case reportDetail(SupportReportItemKey)
}

/// FanGeo Support Center: ticket list, create request, per-ticket status/chat.
struct FanGeoSupportHubView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    var onRequestSignIn: (() -> Void)?
    /// Kept for call-site compatibility. Ticket presentation always uses a single `NavigationPath`
    /// so Settings / notification sheets never stack competing `navigationDestination` modifiers.
    var embedsInNavigationStack = true
    var showsCloseButton = true
    var screenTitle: String = "Support Center"
    var initialTicketID: UUID? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter = FanGeoSupportCenterPresenter()
    @State private var navigationPath = NavigationPath()
    @State private var presentedTicketDetailID: UUID?
    @State private var pendingDeepLinkTicketID: UUID?
    @State private var didConsumeInitialTicketDeepLink = false
    @State private var ticketNotFoundMessage: String?

    private var hasAuthSession: Bool {
        mapViewModel.isLoggedIn || mapViewModel.isVenueOwnerLoggedIn
    }

    var body: some View {
        // Always own a single NavigationStack for ticket/report/create destinations.
        // Avoids competing item/isPresented destinations and keeps Settings + push sheets consistent.
        NavigationStack(path: $navigationPath) {
            centerListContent
                .navigationDestination(for: SupportCenterRoute.self) { route in
                    destinationView(for: route)
                }
        }
        .alert(
            "Ticket unavailable",
            isPresented: Binding(
                get: { ticketNotFoundMessage != nil },
                set: { if !$0 { ticketNotFoundMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { ticketNotFoundMessage = nil }
        } message: {
            Text(ticketNotFoundMessage ?? "This support request could not be found.")
        }
        .task(id: initialTicketID?.uuidString ?? "none") {
#if DEBUG
            print("[SupportNotificationRoute] support center opened initialTicketID=\(initialTicketID?.uuidString.lowercased() ?? "nil")")
#endif
            await presenter.loadRequests()
#if DEBUG
            print("[SupportNotificationRoute] tickets loaded count=\(presenter.requests.count)")
            print("[SupportDeepLink] tickets loaded count=\(presenter.requests.count)")
#endif
            await openInitialTicketIfNeeded()
            await consumePendingDeepLinkTicketIfNeeded()
        }
        .onChange(of: navigationPath.count) { _, count in
            if count == 0 {
                presentedTicketDetailID = nil
            }
#if DEBUG
            print("[SupportNotificationRoute] current route state pathCount=\(count) presentedTicket=\(presentedTicketDetailID?.uuidString.lowercased() ?? "nil")")
#endif
        }
    }

    @MainActor
    private func openInitialTicketIfNeeded() async {
        guard SupportReplyNotificationDeepLinkConfiguration.opensTicketDirectly,
              let initialTicketID else {
            return
        }
        guard !didConsumeInitialTicketDeepLink else {
#if DEBUG
            print("[SupportNotificationRoute] pending route already consumed conversationId=\(initialTicketID.uuidString.lowercased())")
#endif
            return
        }
        didConsumeInitialTicketDeepLink = true
#if DEBUG
        print("[SupportNotificationRoute] ticket detail requested conversationId=\(initialTicketID.uuidString.lowercased()) source=initialTicketID")
#endif
        openTicketDetailSafely(conversationId: initialTicketID, source: "initialTicketID")
#if DEBUG
        print("[SupportNotificationRoute] pending route consumed/cleared conversationId=\(initialTicketID.uuidString.lowercased())")
#endif
    }

    @MainActor
    private func consumePendingDeepLinkTicketIfNeeded() async {
        guard let pendingDeepLinkTicketID else { return }
        self.pendingDeepLinkTicketID = nil
#if DEBUG
        print("[SupportNotificationRoute] ticket detail requested conversationId=\(pendingDeepLinkTicketID.uuidString.lowercased()) source=pendingDeepLink")
#endif
        openTicketDetailSafely(conversationId: pendingDeepLinkTicketID, source: "pendingDeepLink")
#if DEBUG
        print("[SupportNotificationRoute] pending route consumed/cleared conversationId=\(pendingDeepLinkTicketID.uuidString.lowercased())")
#endif
    }

    private var centerListContent: some View {
        FanGeoSupportCenterListView(
            presenter: presenter,
            hasAuthSession: hasAuthSession,
            onRequestSignIn: onRequestSignIn,
            onCreateRequest: openCreateRequest,
            onSelectRequest: openTicketDetail,
            onSelectReport: openReportDetail
        )
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var createRequestDestination: some View {
        FanGeoSupportCreateRequestView(
            mapViewModel: mapViewModel,
            presenter: presenter,
            onRequestSignIn: onRequestSignIn,
            onSubmitted: completeSubmit,
            onSubmittedAfterEmailOnly: completeSubmitEmailOnly
        )
    }

    @ViewBuilder
    private func destinationView(for route: SupportCenterRoute) -> some View {
        switch route {
        case .createRequest:
            createRequestDestination
        case .ticketDetail(let conversationId):
            ticketDetailDestination(conversationId)
        case .reportDetail(let reportKey):
            reportDetailDestination(reportKey)
        }
    }

    private func ticketDetailDestination(_ conversationId: UUID) -> some View {
        FanGeoSupportTicketDetailView(
            conversationId: conversationId,
            presenter: presenter,
            mapViewModel: mapViewModel,
            chatViewModel: chatViewModel,
            onCreateFollowUp: openCreateRequest
        )
        .onAppear {
#if DEBUG
            print("[SupportNotificationRoute] ticket detail presented conversationId=\(conversationId.uuidString.lowercased())")
#endif
        }
    }

    private func openCreateRequest() {
#if DEBUG
        print("[SupportCenter] create new request tapped")
#endif
        replaceNavigation(with: .createRequest)
    }

    private func openTicketDetail(_ request: SupportRequestSummary) {
#if DEBUG
        print("[SupportCenter] selected ticket id=\(request.id.uuidString.lowercased())")
        print("[SupportNotificationRoute] ticket detail requested conversationId=\(request.id.uuidString.lowercased()) source=listTap")
#endif
        openTicketDetailSafely(conversationId: request.id, source: "listTap")
    }

    private func openTicketDetailFromDeepLink(_ conversationId: UUID) {
#if DEBUG
        print("[SupportCenter] deep link ticket id=\(conversationId.uuidString.lowercased())")
        print("[SupportNotificationRoute] ticket detail requested conversationId=\(conversationId.uuidString.lowercased()) source=deepLink")
#endif
        if presenter.isLoading && presenter.requests.isEmpty {
            pendingDeepLinkTicketID = conversationId
#if DEBUG
            print("[SupportNotificationRoute] ticket data not loaded yet; deferring conversationId=\(conversationId.uuidString.lowercased())")
#endif
            return
        }
        openTicketDetailSafely(conversationId: conversationId, source: "deepLink")
    }

    @MainActor
    private func openTicketDetailSafely(conversationId: UUID, source: String) {
        if presentedTicketDetailID == conversationId {
#if DEBUG
            print("[SupportNotificationRoute] duplicate presentation prevented conversationId=\(conversationId.uuidString.lowercased()) source=\(source)")
#endif
            return
        }

        if presenter.request(for: conversationId) == nil {
#if DEBUG
            print("[SupportNotificationRoute] ticket not found conversationId=\(conversationId.uuidString.lowercased()) source=\(source)")
            print("[SupportDeepLink] ticket not found; showing Support Center only conversationId=\(conversationId.uuidString.lowercased())")
#endif
            if source != "listTap" {
                ticketNotFoundMessage = "We couldn’t find that support request. It may have been closed or removed."
            }
            return
        }

#if DEBUG
        print("[SupportDeepLink] opening ticket=\(conversationId.uuidString.lowercased())")
#endif
        replaceNavigation(with: .ticketDetail(conversationId))
    }

    private func openReportDetail(_ report: SupportReportItemSummary) {
#if DEBUG
        print("[SupportCenter] selected report type=\(report.report_type) id=\(report.id.uuidString.lowercased())")
#endif
        replaceNavigation(with: .reportDetail(report.itemKey))
    }

    private func reportDetailDestination(_ reportKey: SupportReportItemKey) -> some View {
        FanGeoSupportReportDetailView(
            reportKey: reportKey,
            presenter: presenter
        )
    }

    private func completeSubmit(_ conversationId: UUID) {
#if DEBUG
        print("[SupportCenter] submit completed conversationId=\(conversationId.uuidString.lowercased())")
#endif
        replaceNavigation(with: .ticketDetail(conversationId))
    }

    private func completeSubmitEmailOnly() {
#if DEBUG
        print("[SupportCenter] submit completed emailOnly=true")
#endif
        navigationPath = NavigationPath()
        presentedTicketDetailID = nil
    }

    private func replaceNavigation(with route: SupportCenterRoute) {
        switch route {
        case .ticketDetail(let id):
            presentedTicketDetailID = id
        case .createRequest, .reportDetail:
            presentedTicketDetailID = nil
        }
        var next = NavigationPath()
        next.append(route)
        navigationPath = next
    }

    private func resetNavigationState() {
        navigationPath = NavigationPath()
        presentedTicketDetailID = nil
        pendingDeepLinkTicketID = nil
        didConsumeInitialTicketDeepLink = false
        ticketNotFoundMessage = nil
    }
}

@MainActor
final class FanGeoSupportCenterPresenter: ObservableObject {
    @Published private(set) var requests: [SupportRequestSummary] = []
    @Published private(set) var reportItems: [SupportReportItemSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var reportLoadError: String?
    @Published private(set) var isSubmitting = false
    @Published var showFailureAlert = false
    @Published var showValidationAlert = false
    @Published var failureMessage: String?
    @Published var validationMessage: String?
    @Published private(set) var didSendEmailWithoutTicket = false
    @Published private(set) var isCancelling = false
    @Published var showCancelFailureAlert = false
    @Published var cancelFailureMessage: String?
    @Published private(set) var isWithdrawingReport = false
    @Published var showWithdrawFailureAlert = false
    @Published var withdrawFailureMessage: String?

    private let service = SupportChatService()

    var openRequests: [SupportRequestSummary] {
        requests.filter(\.isOpen)
    }

    var closedRequests: [SupportRequestSummary] {
        requests.filter { !$0.isOpen }
    }

    var openRequestCount: Int { openRequests.count }

    var closedRequestCount: Int { closedRequests.count }

    var activeReportItems: [SupportReportItemSummary] {
        reportItems.filter(\.isActiveReport)
    }

    var reportHistoryItems: [SupportReportItemSummary] {
        reportItems.filter { !$0.isActiveReport }
    }

    var activeReportCount: Int { activeReportItems.count }

    var reportHistoryCount: Int { reportHistoryItems.count }

    func request(for conversationId: UUID) -> SupportRequestSummary? {
        requests.first { $0.id == conversationId }
    }

    func reportItem(for key: SupportReportItemKey) -> SupportReportItemSummary? {
        reportItems.first { $0.id == key.id && $0.report_type == key.reportType }
    }

    func loadRequests() async {
        isLoading = true
        loadError = nil
        reportLoadError = nil
        defer { isLoading = false }

        do {
            async let ticketsTask = service.fetchSupportRequests()
            async let reportsTask = service.fetchSupportReportItems()
            requests = try await ticketsTask
            do {
                reportItems = try await reportsTask
            } catch {
                reportItems = []
                reportLoadError = error.localizedDescription
#if DEBUG
                print("[SupportCenter] load report items failed error=\(error.localizedDescription)")
#endif
            }
#if DEBUG
            print("[SupportCenter] loaded tickets count=\(requests.count) reports count=\(reportItems.count)")
#endif
        } catch {
            loadError = error.localizedDescription
#if DEBUG
            print("[SupportCenter] load requests failed error=\(error.localizedDescription)")
#endif
        }
    }

    func cancelTicket(conversationId: UUID) async -> Bool {
        isCancelling = true
        defer { isCancelling = false }

        do {
            try await service.cancelTicket(conversationId: conversationId)
            await loadRequests()
#if DEBUG
            print("[SupportCenter] cancelled ticket id=\(conversationId.uuidString.lowercased())")
#endif
            return true
        } catch {
            cancelFailureMessage = error.localizedDescription
            showCancelFailureAlert = true
#if DEBUG
            print("[SupportCenter] cancel ticket failed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func withdrawReport(_ report: SupportReportItemSummary) async -> Bool {
        guard report.canWithdraw else { return false }

        isWithdrawingReport = true
        defer { isWithdrawingReport = false }

        do {
            try await service.withdrawReportItem(
                reportType: report.report_type,
                reportId: report.id
            )
            await loadRequests()
#if DEBUG
            print("[SupportCenter] withdrew report type=\(report.report_type) id=\(report.id.uuidString.lowercased())")
#endif
            return true
        } catch {
            withdrawFailureMessage = error.localizedDescription
            showWithdrawFailureAlert = true
#if DEBUG
            print("[SupportCenter] withdraw report failed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func submitNewTicket(
        category: SupportRequestCategory,
        subject: String,
        message: String
    ) async -> UUID? {
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSubject.isEmpty, !trimmedMessage.isEmpty else {
            validationMessage = "Subject and message are required."
            showValidationAlert = true
            return nil
        }
        guard trimmedSubject.count <= SupportRequestService.subjectMaxCharacters else {
            validationMessage = "Subject may be at most \(SupportRequestService.subjectMaxCharacters) characters."
            showValidationAlert = true
            return nil
        }
        guard trimmedMessage.count <= SupportRequestService.messageMaxCharacters else {
            validationMessage = "Message may be at most \(SupportRequestService.messageMaxCharacters) characters."
            showValidationAlert = true
            return nil
        }

        isSubmitting = true
        didSendEmailWithoutTicket = false
        defer { isSubmitting = false }

        do {
            try await SupportRequestService().submitSupportRequest(
                category: category,
                subject: trimmedSubject,
                message: trimmedMessage,
                client: supabase
            )

            let conversationId: UUID
            do {
                conversationId = try await service.submitTicket(
                    subject: trimmedSubject,
                    issueType: category.rawValue,
                    body: trimmedMessage
                )
            } catch {
#if DEBUG
                print("[SupportCenter] ticket create failed after email sent error=\(error.localizedDescription)")
#endif
                didSendEmailWithoutTicket = true
                await loadRequests()
                return nil
            }

            await loadRequests()
            return conversationId
        } catch let err as SupportRequestSubmitError {
            switch err {
            case .prohibitedContent, .rateLimited, .notSignedIn:
                validationMessage = err.localizedDescription
                showValidationAlert = true
            case .emailSendFailed:
                failureMessage = err.localizedDescription
                showFailureAlert = true
            }
            return nil
        } catch {
            failureMessage = error.localizedDescription
            showFailureAlert = true
            return nil
        }
    }
}

private enum SupportReportFilter: String, CaseIterable, Identifiable {
    case all
    case users
    case conversations
    case venues
    case comments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Reports"
        case .users: return "Users / Fans"
        case .conversations: return "Conversations"
        case .venues: return "Venues"
        case .comments: return "Comments"
        }
    }

    func matches(_ report: SupportReportItemSummary) -> Bool {
        switch self {
        case .all:
            return true
        case .users:
            return report.report_type == "user"
        case .conversations:
            return report.report_type == "conversation"
        case .venues:
            return report.report_type == "venue"
        case .comments:
            return report.report_type == "comment"
        }
    }
}

private struct FanGeoSupportCenterListView: View {
    @ObservedObject var presenter: FanGeoSupportCenterPresenter
    let hasAuthSession: Bool
    var onRequestSignIn: (() -> Void)?
    var onCreateRequest: () -> Void
    var onSelectRequest: (SupportRequestSummary) -> Void
    var onSelectReport: (SupportReportItemSummary) -> Void

    @State private var reportFilter: SupportReportFilter = .all

    private var filteredActiveReports: [SupportReportItemSummary] {
        presenter.activeReportItems.filter { reportFilter.matches($0) }
    }

    private var filteredReportHistory: [SupportReportItemSummary] {
        presenter.reportHistoryItems.filter { reportFilter.matches($0) }
    }

    private var hasAnyReports: Bool {
        !presenter.activeReportItems.isEmpty || !presenter.reportHistoryItems.isEmpty
    }

    var body: some View {
        Group {
            if presenter.isLoading && presenter.requests.isEmpty && presenter.reportItems.isEmpty {
                FanGeoLoadingView(message: "Loading Support Center…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAuthSession {
                signedOutContent
            } else {
                signedInContent
            }
        }
        .refreshable {
            await presenter.loadRequests()
        }
    }

    private var signedOutContent: some View {
        ContentUnavailableView {
            Label("Sign in required", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("Please sign in with your FanGeo or venue account to use the Support Center.")
        } actions: {
            Button("Sign in or create account") {
                onRequestSignIn?()
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentGreen)
        }
    }

    private var signedInContent: some View {
        List {
            Section {
                FanGeoSupportHubMajorSectionHeader(
                    emoji: "🎫",
                    title: "SUPPORT",
                    subtitle: "Need help? Contact FanGeo Support and manage your support requests."
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Button(action: onCreateRequest) {
                    Label("Create New Request", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.accentGreen)
                }
            }

            if !presenter.openRequests.isEmpty {
                Section {
                    ForEach(presenter.openRequests) { request in
                        Button {
                            onSelectRequest(request)
                        } label: {
                            FanGeoSupportRequestRowView(request: request)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Open Tickets (\(presenter.openRequestCount))")
                }
            }

            if !presenter.closedRequests.isEmpty {
                Section {
                    ForEach(presenter.closedRequests) { request in
                        Button {
                            onSelectRequest(request)
                        } label: {
                            FanGeoSupportRequestRowView(request: request)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Closed Tickets (\(presenter.closedRequestCount))")
                }
            }

            Section {
                FanGeoSupportHubMajorSectionHeader(
                    emoji: "🛡",
                    title: "REPORTS",
                    subtitle: "Track users, conversations, venues, and comments you've reported for moderation."
                )
                .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                FanGeoSupportReportFilterBar(selection: $reportFilter)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if filteredActiveReports.isEmpty {
                    if presenter.activeReportItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No active reports.")
                                .font(.subheadline.weight(.semibold))
                            Text("Everything you've reported has either been reviewed or withdrawn.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("No reports in this category.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(filteredActiveReports) { report in
                        Button {
                            onSelectReport(report)
                        } label: {
                            FanGeoSupportReportItemRowView(
                                report: report,
                                presentation: .active
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Active Reports (\(filteredActiveReports.count))")
            } footer: {
                Text("Reports currently being reviewed by FanGeo.")
            }

            Section {
                if filteredReportHistory.isEmpty {
                    Text("No previous reports.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filteredReportHistory) { report in
                        Button {
                            onSelectReport(report)
                        } label: {
                            FanGeoSupportReportItemRowView(
                                report: report,
                                presentation: .history
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Report History (\(filteredReportHistory.count))")
            } footer: {
                if hasAnyReports {
                    Text("Reports that have already been reviewed or withdrawn.")
                }
            }

            if let loadError = presenter.loadError {
                Section {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let reportLoadError = presenter.reportLoadError {
                Section {
                    Text("Couldn’t load reported items. \(reportLoadError)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct FanGeoSupportHubMajorSectionHeader: View {
    let emoji: String
    let title: String
    let subtitle: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(emoji)
                    .font(.title2)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .tracking(0.6)
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct FanGeoSupportReportFilterBar: View {
    @Binding var selection: SupportReportFilter

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter Reports")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(SupportReportFilter.allCases) { filter in
                        filterChip(for: filter)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter reports")
    }

    private func filterChip(for filter: SupportReportFilter) -> some View {
        let isSelected = selection == filter

        return Button {
            selection = filter
        } label: {
            Text(filter.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? FGColor.accentGreen : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum FanGeoSupportReportRowPresentation {
    case active
    case history
}

private struct FanGeoSupportReportLabeledValue: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
        }
    }
}

private struct FanGeoSupportReportItemRowView: View {
    let report: SupportReportItemSummary
    let presentation: FanGeoSupportReportRowPresentation

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(report.rowHeadline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                FanGeoSupportReportLabeledValue(label: "Reason", value: report.categoryTitle)

                switch presentation {
                case .active:
                    FanGeoSupportReportLabeledValue(
                        label: "Status",
                        value: report.displayStatus.title
                    )
                case .history:
                    FanGeoSupportReportLabeledValue(
                        label: "Outcome",
                        value: report.outcomeTitle
                    )
                }

                FanGeoSupportReportLabeledValue(
                    label: "Reported",
                    value: reportedDateText
                )
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var reportedDateText: String {
        switch presentation {
        case .active:
            return SupportCenterDateFormat.relativeReported(for: report.reportedAtRaw) ?? "—"
        case .history:
            return SupportCenterDateFormat.mediumDateOnly(for: report.reportedAtRaw) ?? "—"
        }
    }
}

private struct FanGeoSupportReportDetailView: View {
    let reportKey: SupportReportItemKey
    @ObservedObject var presenter: FanGeoSupportCenterPresenter

    @Environment(\.dismiss) private var dismiss
    @State private var showWithdrawConfirmation = false

    var body: some View {
        Group {
            if let report = presenter.reportItem(for: reportKey) {
                reportContent(for: report)
            } else {
                FanGeoLoadingView(message: "Loading report…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        await presenter.loadRequests()
                    }
            }
        }
        .confirmationDialog(
            "Withdraw this report? Our moderation team will no longer review it.",
            isPresented: $showWithdrawConfirmation,
            titleVisibility: .visible
        ) {
            Button("Withdraw Report", role: .destructive) {
                Task {
                    if let report = presenter.reportItem(for: reportKey),
                       await presenter.withdrawReport(report) {
                        dismiss()
                    }
                }
            }
            Button("Keep Report", role: .cancel) {}
        }
        .alert(
            "Couldn't withdraw report",
            isPresented: $presenter.showWithdrawFailureAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presenter.withdrawFailureMessage ?? "Please try again later.")
        }
    }

    private func reportContent(for report: SupportReportItemSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: report.displayStatus == .withdrawn ? "flag.slash" : "flag.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(report.displayStatus == .withdrawn ? .secondary : FGColor.accentGreen)
                    .frame(maxWidth: .infinity)

                Text(detailMessage(for: report))
                    .font(.body)
                    .multilineTextAlignment(.leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Status: \(report.displayStatus.title)")
                        .font(.subheadline.weight(.semibold))
                    Text("Reason: \(report.categoryTitle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let reported = SupportCenterDateFormat.fullDate(for: report.reportedAtRaw) {
                        Text("Reported: \(reported)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                if report.canWithdraw {
                    Button("Withdraw Report", role: .destructive) {
                        showWithdrawConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(presenter.isWithdrawingReport)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .navigationTitle(report.detailNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailMessage(for report: SupportReportItemSummary) -> String {
        switch report.displayStatus {
        case .withdrawn:
            return "You withdrew this report. It is no longer under review."
        case .closed:
            return "This report has been closed by our moderation team."
        case .underReview:
            return "Your report is under review. Our moderation team is looking into it."
        case .submitted:
            return "Your report has been submitted. Our moderation team will review it."
        }
    }
}

private struct FanGeoSupportRequestRowView: View {
    let request: SupportRequestSummary

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.displaySubject)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                Text(request.issueTypeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(request.displayStatus.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)

                    if let updated = SupportCenterDateFormat.relativeUpdated(for: request.lastUpdatedRaw) {
                        Text("Updated \(updated)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch request.displayStatus {
        case .awaitingSupport:
            return .orange
        case .chatOpen:
            return FGColor.accentGreen
        case .closed, .cancelled:
            return .secondary
        }
    }
}

private struct FanGeoSupportCreateRequestView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var presenter: FanGeoSupportCenterPresenter
    var onRequestSignIn: (() -> Void)?
    var onSubmitted: (UUID) -> Void
    var onSubmittedAfterEmailOnly: () -> Void = {}

    var body: some View {
        FanGeoSupportTicketFormView(
            mapViewModel: mapViewModel,
            onRequestSignIn: onRequestSignIn,
            isSending: presenter.isSubmitting,
            onSubmit: { category, subject, message in
                Task {
                    if let conversationId = await presenter.submitNewTicket(
                        category: category,
                        subject: subject,
                        message: message
                    ) {
                        onSubmitted(conversationId)
                    } else if presenter.didSendEmailWithoutTicket {
                        onSubmittedAfterEmailOnly()
                    }
                }
            }
        )
        .navigationTitle("Contact Support")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Couldn’t send request",
            isPresented: $presenter.showFailureAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presenter.failureMessage ?? "Please try again later.")
        }
        .alert(
            "Check your message",
            isPresented: $presenter.showValidationAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presenter.validationMessage ?? "")
        }
    }
}

private struct FanGeoSupportTicketDetailView: View {
    let conversationId: UUID
    @ObservedObject var presenter: FanGeoSupportCenterPresenter
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    var onCreateFollowUp: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCancelConfirmation = false

    var body: some View {
        Group {
            if let request = presenter.request(for: conversationId) {
                ticketContent(for: request)
            } else {
                FanGeoLoadingView(message: "Loading request…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        await presenter.loadRequests()
                    }
            }
        }
        .confirmationDialog(
            "Cancel this support request?",
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Request", role: .destructive) {
                Task {
                    if await presenter.cancelTicket(conversationId: conversationId) {
                        dismiss()
                    }
                }
            }
            Button("Keep Request", role: .cancel) {}
        } message: {
            Text("This can't be undone. You can create a new request later if you still need help.")
        }
        .alert(
            "Couldn't cancel request",
            isPresented: $presenter.showCancelFailureAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presenter.cancelFailureMessage ?? "Please try again later.")
        }
    }

    @ViewBuilder
    private func ticketContent(for request: SupportRequestSummary) -> some View {
        if request.isOpen && request.isChatAvailable {
            SupportChatView(
                mapViewModel: mapViewModel,
                chatViewModel: chatViewModel,
                conversationId: conversationId,
                showComposer: true,
                onCancelRequest: { showCancelConfirmation = true }
            )
            .onAppear {
#if DEBUG
                print("[SupportCenter] opening chat for selected ticket id=\(conversationId.uuidString.lowercased())")
#endif
            }
        } else if request.isOpen {
            FanGeoSupportTicketConfirmationView(
                subject: request.displaySubject,
                issueTypeTitle: request.issueTypeTitle,
                isCancelling: presenter.isCancelling,
                onCancelRequest: { showCancelConfirmation = true }
            )
            .navigationTitle("Request Sent")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            FanGeoSupportClosedTicketView(
                request: request,
                onCreateFollowUp: onCreateFollowUp
            )
            .navigationTitle(request.isCancelled ? "Cancelled Request" : "Closed Request")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct FanGeoSupportClosedTicketView: View {
    let request: SupportRequestSummary
    var onCreateFollowUp: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                Text(request.isCancelled
                    ? "This support request was cancelled."
                    : "This support request is closed.")
                    .font(.body)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Issue Type: \(request.issueTypeTitle)")
                        .font(.subheadline.weight(.semibold))
                    Text("Subject: \(request.displaySubject)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Status: \(request.displayStatus.rawValue)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let updated = SupportCenterDateFormat.fullDate(for: request.lastUpdatedRaw) {
                        Text("Last updated: \(updated)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                Button("Create follow-up request") {
                    onCreateFollowUp()
                }
                .buttonStyle(.borderedProminent)
                .tint(FGColor.accentGreen)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
    }
}

private enum SupportCenterDateFormat {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoWithFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    static func relativeUpdated(for raw: String?) -> String? {
        guard let date = parse(raw) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func relativeReported(for raw: String?) -> String? {
        relativeUpdated(for: raw)
    }

    static func mediumDateOnly(for raw: String?) -> String? {
        guard let date = parse(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func fullDate(for raw: String?) -> String? {
        guard let date = parse(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct FanGeoSupportTicketFormView: View {
    @ObservedObject var mapViewModel: MapViewModel
    var onRequestSignIn: (() -> Void)?
    var isSending: Bool
    var onSubmit: (SupportRequestCategory, String, String) -> Void

    @State private var category: SupportRequestCategory = .question
    @State private var subject = ""
    @State private var message = ""

    private var hasAuthSession: Bool {
        mapViewModel.isLoggedIn || mapViewModel.isVenueOwnerLoggedIn
    }

    private var canSend: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    FanGeoInlineLogoView(variant: .white, width: 104, innerPadding: 6)
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if !hasAuthSession {
                Section {
                    Text("Please sign in with your FanGeo or venue account to send a support request.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Sign in or create account") {
                        onRequestSignIn?()
                    }
                }
            } else {
                Section {
                    TextField("Subject", text: $subject)
                        .textInputAutocapitalization(.sentences)

                    Picker("Issue Type", selection: $category) {
                        ForEach(SupportRequestCategory.allCases) { issueType in
                            Text(issueType.displayTitle).tag(issueType)
                        }
                    }

                    if let line = category.exampleHelperLine, !line.isEmpty {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Message")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $message)
                            .frame(minHeight: 140)
                        Text("\(message.count) / \(SupportRequestService.messageMaxCharacters)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Screenshots are not yet supported. Please describe the issue in your message.")
                        .font(.caption)
                }

                Section {
                    Button("Send") {
                        onSubmit(category, subject, message)
                    }
                    .disabled(!canSend)
                }
            }
        }
        .overlay {
            if isSending {
                ProgressView()
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

private struct FanGeoSupportTicketConfirmationView: View {
    let subject: String
    let issueTypeTitle: String
    var isCancelling = false
    var onCancelRequest: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(maxWidth: .infinity)

                Text("Your request was sent. FanGeo Support will review it. If we need more details, a support chat will appear here.")
                    .font(.body)
                    .multilineTextAlignment(.leading)

                if !subject.isEmpty || !issueTypeTitle.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if !issueTypeTitle.isEmpty {
                            Text("Issue Type: \(issueTypeTitle)")
                                .font(.subheadline.weight(.semibold))
                        }
                        if !subject.isEmpty {
                            Text("Subject: \(subject)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }

                if let onCancelRequest {
                    Button("Cancel Request", role: .destructive) {
                        onCancelRequest()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCancelling)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }
}

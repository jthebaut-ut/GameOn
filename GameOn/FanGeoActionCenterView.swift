import SwiftUI

/// Unified FanGeo Inbox sheet — Action Needed + Notifications.
struct FanGeoActionCenterView: View {
    let actionNeededItems: [FanGeoActionItem]
    let notificationItems: [FanGeoActionItem]
    let unreadNotificationIds: Set<String>
    let languageCode: String
    let onSelect: (FanGeoActionItem) -> Void
    let onClose: () -> Void
    var onDismissActionItem: ((FanGeoActionItem) -> Void)? = nil
    var onUndoDismissActionItem: ((FanGeoActionItem) -> Void)? = nil
    var onClearNotification: ((FanGeoActionItem) -> Void)? = nil
    var onClearAllNotifications: (() -> Void)? = nil
    /// Clears currently visible Notifications + Action Needed after confirmation.
    var onClearAllInbox: (() -> Void)? = nil
    /// Sync durable server inbox when the sheet opens (cache already painted).
    var onAppearRefresh: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSection: FanGeoActionCenterListSection = .actionNeeded
    @State private var undoItem: FanGeoActionItem?
    @State private var showClearAllConfirm = false
    @State private var undoHideTask: Task<Void, Never>?

    private var displayNotificationItems: [FanGeoActionItem] {
#if DEBUG
        if FanGeoInboxPerformanceDebug.injectHundredRowFixture {
            return FanGeoInboxPerformanceFixture.makeHundredRows()
        }
#endif
        return notificationItems
    }

    private var visibleItems: [FanGeoActionItem] {
        switch selectedSection {
        case .actionNeeded: return actionNeededItems
        case .notifications: return displayNotificationItems
        }
    }

    private var groupedSections: [FanGeoInboxDateGroup] {
        FanGeoInboxOpenPerf.cardProjection()
        return FanGeoInboxOpenPerf.measureMainActor("inboxDateGrouping") {
            FanGeoInboxDateGrouping.groups(
                items: visibleItems,
                languageCode: languageCode
            )
        }
    }

    private var notificationsCount: Int {
        FanGeoInboxChrome.notificationsTabCount(unreadCount: unreadNotificationIds.count)
    }

    private var actionNeededCount: Int {
        FanGeoInboxChrome.actionNeededTabCount(items: actionNeededItems)
    }

    private var envelopeBadgeCount: Int {
        FanGeoInboxChrome.envelopeBadgeCount(
            notificationsCount: notificationsCount,
            actionNeededCount: actionNeededCount
        )
    }

    var body: some View {
        let _ = FanGeoInboxOpenPerf.rootBody()
        VStack(spacing: 0) {
            headerBlock
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 14)

            sectionPicker
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            ScrollView {
                let _ = FanGeoInboxOpenPerf.listBody()
                LazyVStack(alignment: .leading, spacing: 18) {
                    if visibleItems.isEmpty {
                        emptyState
                            .padding(.top, 8)
                    } else {
                        ForEach(groupedSections) { section in
                            Text(section.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FGColor.mutedText(colorScheme))
                                .textCase(.uppercase)
                                .tracking(0.7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                                .accessibilityAddTraits(.isHeader)

                            ForEach(section.entries) { entry in
                                FanGeoActionCenterCard(
                                    item: entry.item,
                                    languageCode: languageCode,
                                    showsUnreadDot: selectedSection == .notifications
                                        && unreadNotificationIds.contains(entry.item.id),
                                    timestampLabel: entry.timestampLabel,
                                    onSelect: { onSelect(entry.item) },
                                    onDismiss: dismissHandler(for: entry.item)
                                )
                                .equatable()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
                .transaction { transaction in
                    if FanGeoInboxChrome.notificationListDisablesAnimations {
                        transaction.animation = nil
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in FanGeoInboxOpenPerf.firstScroll() }
            )
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if let undoItem, selectedSection == .actionNeeded {
                actionCenterUndoBanner(for: undoItem)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: undoItem?.id)
        .confirmationDialog(
            L10n.t("action_center_clear_confirm_title", languageCode: languageCode),
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button(
                L10n.t("action_center_clear_all", languageCode: languageCode),
                role: .destructive
            ) {
                (onClearAllInbox ?? onClearAllNotifications)?()
                undoHideTask?.cancel()
                undoItem = nil
            }
            Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
        } message: {
            Text(L10n.t("action_center_clear_confirm_message", languageCode: languageCode))
        }
        .onAppear {
            FanGeoInboxOpenPerf.beginOpen(source: "sheet")
            FanGeoInboxOpenPerf.mark(.t1NotificationsVisible)
            if actionNeededItems.isEmpty, !notificationItems.isEmpty {
                selectedSection = .notifications
            }
            ActionCenterDismissDebug.log(
                "actionNeeded=\(actionNeededItems.reduce(0) { $0 + $1.count }) " +
                "notifications=\(notificationItems.count) unread=\(unreadNotificationIds.count)"
            )
            Task { @MainActor in
                await Task.yield()
                onAppearRefresh?()
            }
        }
        .accessibilityLabel(L10n.t("action_center_title", languageCode: languageCode))
    }

    private var sectionPicker: some View {
        HStack(spacing: 8) {
            ForEach(FanGeoInboxChrome.tabOrder, id: \.self) { section in
                inboxTabButton(section)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("action_center_title", languageCode: languageCode))
    }

    private func inboxTabButton(_ section: FanGeoActionCenterListSection) -> some View {
        let isSelected = selectedSection == section
        let count = tabCount(for: section)
        let tint = tabTint(for: section)
        let title = L10n.t(section.titleKey, languageCode: languageCode)
        return Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: FanGeoInboxChrome.tabSystemImage(for: section))
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if count > 0 {
                    Text(FanGeoActionCenterProjection.badgeLabel(count))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? tint : FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(tint.opacity(isSelected ? 0.18 : (colorScheme == .dark ? 0.22 : 0.10)))
                        )
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isSelected ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.22 : 0.12) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(
            count > 0
                ? "\(title), \(FanGeoActionCenterProjection.badgeLabel(count))"
                : title
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func tabCount(for section: FanGeoActionCenterListSection) -> Int {
        switch section {
        case .actionNeeded:
            return actionNeededCount
        case .notifications:
            return notificationsCount
        }
    }

    private func tabTint(for section: FanGeoActionCenterListSection) -> Color {
        switch section {
        case .notifications: return FGColor.accentBlue
        case .actionNeeded: return FGColor.intentTeams
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch selectedSection {
        case .actionNeeded:
            FanGeoActionCenterCaughtUpCard(languageCode: languageCode)
        case .notifications:
            FanGeoActionCenterEmptyNotificationsCard(languageCode: languageCode)
        }
    }

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            inboxEnvelopeTile
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("action_center_title", languageCode: languageCode))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(L10n.t("action_center_subtitle", languageCode: languageCode))
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                FanGeoInboxChrome.headerAccessibilityLabel(
                    inboxCount: envelopeBadgeCount,
                    languageCode: languageCode
                )
            )
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                if FanGeoInboxChrome.showsClearAllControl(
                    notificationItemCount: displayNotificationItems.count,
                    actionNeededItemCount: actionNeededItems.count,
                    canClear: onClearAllInbox != nil || onClearAllNotifications != nil
                ) {
                    Button {
                        showClearAllConfirm = true
                    } label: {
                        Text(L10n.t("action_center_clear_all", languageCode: languageCode))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        L10n.t("action_center_clear_all_a11y", languageCode: languageCode)
                    )
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(FGColor.cardBackground(colorScheme)))
                        .overlay {
                            Circle()
                                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    L10n.t("action_center_close_a11y", languageCode: languageCode)
                )
            }
        }
    }

    private var inboxEnvelopeTile: some View {
        let size = FanGeoInboxChrome.envelopeTileSize
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.42, green: 0.58, blue: 0.98),
                            Color(red: 0.58, green: 0.46, blue: 0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: FanGeoInboxChrome.envelopeSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08), radius: 8, y: 3)

            if FanGeoInboxChrome.showsEnvelopeBadge(totalCount: envelopeBadgeCount) {
                Text(FanGeoActionCenterProjection.badgeLabel(envelopeBadgeCount))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, envelopeBadgeCount > 9 ? 5 : 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.red, in: Capsule(style: .continuous))
                    .offset(x: 6, y: -6)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size, alignment: .topTrailing)
        .padding(.trailing, envelopeBadgeCount > 0 ? 6 : 0)
        .padding(.top, envelopeBadgeCount > 0 ? 4 : 0)
    }

    private func dismissHandler(for item: FanGeoActionItem) -> (() -> Void)? {
        switch selectedSection {
        case .actionNeeded:
            guard item.kind.isDismissible, onDismissActionItem != nil else { return nil }
            return { dismissActionItem(item) }
        case .notifications:
            guard onClearNotification != nil else { return nil }
            return { onClearNotification?(item) }
        }
    }

    private func dismissActionItem(_ item: FanGeoActionItem) {
        ActionCenterDismissDebug.log("dismissTapped actionKey=\(item.id)")
        onDismissActionItem?(item)
        presentUndo(for: item)
    }

    private func presentUndo(for item: FanGeoActionItem) {
        undoHideTask?.cancel()
        undoItem = item
        undoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if undoItem?.id == item.id {
                undoItem = nil
            }
        }
    }

    private func actionCenterUndoBanner(for item: FanGeoActionItem) -> some View {
        HStack(spacing: 10) {
            Text(L10n.t("action_center_removed_toast", languageCode: languageCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button {
                onUndoDismissActionItem?(item)
                undoHideTask?.cancel()
                undoItem = nil
            } label: {
                Text(L10n.t("action_center_undo", languageCode: languageCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(colorScheme == .dark ? 0.82 : 0.78), in: Capsule(style: .continuous))
    }
}

// MARK: - Caught up / empty

struct FanGeoActionCenterCaughtUpCard: View {
    let languageCode: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(FGColor.accentGreen)
                .accessibilityHidden(true)

            Text(L10n.t("action_center_caught_up_title", languageCode: languageCode))
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)

            Text(L10n.t("action_center_caught_up_body", languageCode: languageCode))
                .font(.subheadline)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FanGeoActionCenterEmptyNotificationsCard: View {
    let languageCode: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.slash")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityHidden(true)

            Text(L10n.t("action_center_notifications_empty_title", languageCode: languageCode))
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)

            Text(L10n.t("action_center_notifications_empty_body", languageCode: languageCode))
                .font(.subheadline)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }
}

// MARK: - Card

struct FanGeoActionCenterCard: View, Equatable {
    let item: FanGeoActionItem
    let languageCode: String
    var showsUnreadDot: Bool = false
    var timestampLabel: String? = nil
    let onSelect: () -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: FanGeoActionCenterCard, rhs: FanGeoActionCenterCard) -> Bool {
        lhs.item == rhs.item
            && lhs.languageCode == rhs.languageCode
            && lhs.showsUnreadDot == rhs.showsUnreadDot
            && lhs.timestampLabel == rhs.timestampLabel
    }

    private var accent: Color {
        FanGeoActionCenterTeamNotificationPresentation.cardAccent(for: item)
    }
    private var metadataRows: [FanGeoActionCenterMetadataRow] {
        FanGeoActionCenterCopy.metadataRows(for: item, languageCode: languageCode)
    }
    private var teamEventNotice: FanGeoTeamEventNotice? {
        FanGeoTeamEventNoticeBuilder.make(for: item, languageCode: languageCode)
    }

    private var isTeamNotificationCard: Bool {
        isCompactInformational
            && FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item)
    }

    private var isScheduleNotificationCard: Bool {
        isCompactInformational
            && (item.kind == .scheduleChange || item.kind == .eventCancellation)
    }

    private var relativeTime: String? {
        let passed = timestampLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !passed.isEmpty { return passed }
        let fallback = FanGeoInboxDateGrouping.cardTimestampLabel(
            for: item,
            languageCode: languageCode
        )
        return fallback.isEmpty ? nil : fallback
    }

    private var isCompactInformational: Bool {
        item.kind.listSection == .notifications
    }

    private var isProGameInboxCard: Bool {
        FanGeoProGameInboxPresentation.isProGame(item)
    }

    private var showsDismiss: Bool {
        onDismiss != nil
    }

    private var cardCornerRadius: CGFloat { FanGeoInboxChrome.cardCornerRadius }

    var body: some View {
        let _ = FanGeoInboxOpenPerf.actionCenterCardBody(
            isNotification: isCompactInformational,
            isProGame: isProGameInboxCard,
            isPractice: teamEventNotice != nil
        )
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 0) {
                    Capsule(style: .continuous)
                        .fill(accent)
                        .frame(width: 3.5)
                        .padding(.vertical, 10)

                    VStack(alignment: .leading, spacing: isCompactInformational ? 10 : 12) {
                        headerRow
                        mainRow
                        if !item.context.changeDetails.isEmpty,
                           !isTeamNotificationCard,
                           !isProGameInboxCard,
                           teamEventNotice == nil {
                            changeBlock
                        }
                        if !metadataRows.isEmpty,
                           !isTeamNotificationCard,
                           !isProGameInboxCard,
                           teamEventNotice == nil,
                           !isCompactInformational || item.context.changeDetails.isEmpty {
                            metadataBlock
                        }
                        if !isCompactInformational {
                            ctaRow
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 16)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.trailing, showsDismiss ? 8 : 14)
                        .padding(.top, showsDismiss ? 44 : 20)
                        .accessibilityHidden(true)
                }
                .background {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(FGColor.cardBackground(colorScheme))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .strokeBorder(
                            FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.7),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.04), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                FanGeoInboxChrome.cardAccessibilityLabel(
                    for: item,
                    isUnread: showsUnreadDot,
                    languageCode: languageCode
                )
            )
            .accessibilityHint(L10n.t(item.ctaKey, languageCode: languageCode))
            .accessibilityAddTraits(.isButton)

            if showsDismiss {
                Button(action: { onDismiss?() }) {
                    Image(systemName: FanGeoInboxChrome.cardDismissSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(
                    L10n.t(FanGeoInboxChrome.cardDismissAccessibilityKey, languageCode: languageCode)
                )
                .padding(.top, 2)
                .padding(.trailing, 2)
            }
        }
        .accessibilityElement(children: .contain)
        #if DEBUG
        .onAppear {
            FanGeoTeamEventInboxTrace.logRenderedCard(item, languageCode: languageCode)
        }
        #endif
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(
                FanGeoActionCenterTeamNotificationPresentation.headerBadgeText(
                    for: item,
                    languageCode: languageCode
                )
            )
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule(style: .continuous))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 6)

            if showsUnreadDot {
                Circle()
                    .fill(FGColor.accentBlue)
                    .frame(width: FanGeoInboxChrome.unreadDotSize, height: FanGeoInboxChrome.unreadDotSize)
                    .accessibilityHidden(true)
            }

            if let relativeTime, !relativeTime.isEmpty {
                Text(relativeTime)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }

            if showsDismiss {
                Color.clear
                    .frame(width: 28, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 12) {
            if !isProGameInboxCard {
                leadingGlyph
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                if isProGameInboxCard, let snapshot = item.context.proGameSnapshot {
                    FanGeoProGameInboxCard(
                        snapshot: snapshot,
                        languageCode: languageCode,
                        colorScheme: colorScheme
                    )
                    .equatable()
                } else {
                    Text(item.title(languageCode: languageCode))
                        .font(isCompactInformational ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    if let notice = teamEventNotice {
                        if !notice.allRows.isEmpty {
                            teamEventNoticeRows(notice)
                        }
                    } else if isTeamNotificationCard || isScheduleNotificationCard {
                        EmptyView()
                    } else if let summary = FanGeoActionCenterTeamNotificationPresentation.summaryLine(
                        for: item,
                        languageCode: languageCode
                    ) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isCompactInformational, !isTeamNotificationCard, let first = metadataRows.first {
                        Text(first.text)
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !isTeamNotificationCard, let subtitle = secondarySubtitleLine {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if item.kind == .pendingPickupRating {
                    ratingStarsPreview
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func teamEventNoticeRows(_ notice: FanGeoTeamEventNotice) -> some View {
        let rows = FanGeoInboxTeamEventCardLayout.rows(from: notice, languageCode: languageCode)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.showsDividerBefore {
                    Divider()
                        .padding(.vertical, 2)
                        .accessibilityHidden(true)
                }
                teamEventDisplayRow(row)
            }
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private func teamEventDisplayRow(_ row: FanGeoInboxTeamEventDisplayRow) -> some View {
        Group {
            if row.showsPlayerAvatar {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        FanGeoTeamEventNoticeBuilder.spokenFieldLabel(
                            row.labelKey,
                            languageCode: languageCode
                        )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    HStack(spacing: 8) {
                        affectedPlayerAvatar(size: FanGeoInboxChrome.playerRowAvatarSize)
                            .accessibilityHidden(true)
                        Text(row.value)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: row.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(width: 14, alignment: .center)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            FanGeoTeamEventNoticeBuilder.spokenFieldLabel(
                                row.labelKey,
                                languageCode: languageCode
                            )
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        Text(row.value)
                            .font(.caption.weight(row.isIdentity ? .semibold : .regular))
                            .foregroundStyle(
                                row.isIdentity
                                    ? FGColor.primaryText(colorScheme)
                                    : FGColor.secondaryText(colorScheme)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var secondarySubtitleLine: String? {
        let ctx = item.context
        if item.kind == .joinApproval {
            let title = ctx.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? nil : title
        }
        if let team = ctx.teamName?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty,
           let type = ctx.eventTypeLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
            let generated = "\(team) · \(type)"
            let renderedTitle = item.title(languageCode: languageCode)
            if renderedTitle.localizedCaseInsensitiveContains(generated)
                || renderedTitle.localizedCaseInsensitiveContains(team) {
                return nil
            }
            return generated
        }
        if let title = ctx.eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let renderedTitle = item.title(languageCode: languageCode)
            if renderedTitle.localizedCaseInsensitiveContains(title) {
                return nil
            }
            if FanGeoTeamEventNoticeBuilder.isRedundantGeneratedIdentity(
                title,
                teamName: ctx.teamName,
                format: GameType.parse(ctx.eventTypeLabel),
                languageCode: languageCode
            ) {
                return nil
            }
            return title
        }
        return nil
    }

    private var ratingStarsPreview: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 5, id: \.self) { _ in
                Image(systemName: "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
            }
        }
        .accessibilityHidden(true)
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(metadataRows.prefix(5).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.9))
                        .frame(width: 14, alignment: .center)
                        .padding(.top, 1)
                    Text(row.text)
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var changeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(item.context.changeDetails.prefix(3).enumerated()), id: \.offset) { _, detail in
                FanGeoActionCenterChangeRow(
                    detail: detail,
                    languageCode: languageCode,
                    accent: accent
                )
            }
            if item.context.moreChangesCount > 0 {
                Text(
                    String(
                        format: L10n.t("action_center_more_changes_format", languageCode: languageCode),
                        locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                        Int64(item.context.moreChangesCount)
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(colorScheme == .dark ? 0.14 : 0.08))
        )
    }

    private var ctaRow: some View {
        HStack {
            Text(L10n.t(item.ctaKey, languageCode: languageCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accent)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        let size = FanGeoInboxChrome.leadingArtworkSize(
            hasTeamEventNotice: teamEventNotice != nil,
            isCompactInformational: isCompactInformational
        )
        let identity = FanGeoActionCenterLeadingIdentity.source(for: item)
        switch identity {
        case .teamMark:
            if let teamId = item.context.teamId {
                ActionCenterTeamIdentityMark(
                    teamId: teamId,
                    size: size,
                    fallbackSystemImage: item.kind.systemImage,
                    accent: accent,
                    languageCode: languageCode,
                    fallbackSport: item.context.sportLabel
                )
                .equatable()
            } else {
                kindGlyph(size: size)
            }
        case .personAvatar:
            affectedPlayerAvatar(size: size)
        case .ratingGlyph:
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: size, height: size)
                .background(Circle().fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.14)))
        case .kindGlyph:
            if item.kind == .businessClaim {
                Image(systemName: "building.2.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: size, height: size)
                    .background(Circle().fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.14)))
            } else if FanGeoActionCenterTeamNotificationPresentation.usesTeamChrome(for: item),
                      let sport = item.context.sportLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sport.isEmpty {
                FanTeamMarkView(
                    sport: sport,
                    logoURL: nil,
                    logoThumbnailURL: nil,
                    colorHex: nil,
                    size: size,
                    preferDetailURL: false
                )
                .accessibilityHidden(true)
            } else {
                kindGlyph(size: size)
            }
        }
    }

    @ViewBuilder
    private func affectedPlayerAvatar(size: CGFloat) -> some View {
        let _ = FanGeoInboxOpenPerf.playerAvatarBody()
        let name = item.context.personName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = name.isEmpty ? L10n.t("Player", languageCode: languageCode) : name
        let isManaged = item.context.isManagedPlayer || item.context.managedPlayerId != nil
        let stableToken = FanGeoInboxChrome.playerAvatarRefreshToken(for: item)
        Group {
            if isManaged {
                ManagedPlayerAvatarView(
                    managedPlayerId: item.context.managedPlayerId,
                    avatarURL: item.context.personAvatarURL,
                    avatarThumbnailURL: item.context.personAvatarThumbnailURL ?? item.context.personAvatarURL,
                    displayName: displayName,
                    size: size
                )
            } else if let avatarURL = item.context.personAvatarURL?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !avatarURL.isEmpty {
                UserAvatarView(
                    avatarThumbnailURL: item.context.personAvatarThumbnailURL ?? avatarURL,
                    avatarURL: avatarURL,
                    avatarDisplayRefreshToken: stableToken,
                    displayName: displayName,
                    email: "",
                    size: size
                )
            } else if !name.isEmpty {
                UserAvatarView(
                    avatarThumbnailURL: item.context.personAvatarThumbnailURL,
                    avatarURL: item.context.personAvatarURL ?? "",
                    avatarDisplayRefreshToken: stableToken,
                    displayName: displayName,
                    email: "",
                    size: size
                )
            } else {
                kindGlyph(size: size)
            }
        }
        .overlay {
            Circle()
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
        }
    }

    private func kindGlyph(size: CGFloat) -> some View {
        Image(systemName: item.kind.systemImage)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: size, height: size)
            .background(Circle().fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.12)))
    }
}

// MARK: - Change row

struct FanGeoActionCenterChangeRow: View {
    let detail: FanGeoActionChangeDetail
    let languageCode: String
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    private var oldValue: String {
        detail.oldValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var newValue: String {
        detail.newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t(detail.labelKey, languageCode: languageCode))
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            if !oldValue.isEmpty, !newValue.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(oldValue)
                        .font(.caption)
                        .foregroundStyle(accent)
                        .strikethrough(true, color: accent.opacity(0.85))
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent.opacity(0.8))
                    Text(newValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
            } else if !newValue.isEmpty {
                Text(newValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Header bell

struct FanGeoActionCenterBellButton: View {
    let badgeCount: Int
    let languageCode: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let glyphSize: CGFloat = 40
    private let hitSize: CGFloat = 44
    private let badgeMinSize: CGFloat = 17

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(width: glyphSize, height: glyphSize)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.65), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 6, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                if badgeCount > 0 {
                    Text(FanGeoActionCenterProjection.badgeLabel(badgeCount))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, badgeCount > 9 ? 4 : 3)
                        .frame(minWidth: badgeMinSize, minHeight: badgeMinSize)
                        .background(Color.red, in: Capsule(style: .continuous))
                        .padding(.top, 1)
                        .padding(.trailing, 1)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitSize, height: hitSize)
        .accessibilityLabel(
            badgeCount > 0
                ? String(
                    format: L10n.t("action_center_a11y_pending_format", languageCode: languageCode),
                    locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                    Int64(badgeCount)
                )
                : L10n.t("action_center_title", languageCode: languageCode)
        )
        .accessibilityHint(L10n.t("action_center_a11y_hint", languageCode: languageCode))
    }
}

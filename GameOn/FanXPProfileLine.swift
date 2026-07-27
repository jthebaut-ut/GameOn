import SwiftUI

// MARK: - Shared informational catalog (not authoritative for awarding)

/// Display-only XP rule. Award amounts remain server-authoritative via
/// `public.fan_xp_amount_for_source` / `claim_fan_xp` (`20260870`).
struct FanXpRule: Identifiable, Equatable, Sendable {
    /// Canonical `xp_events.source` / `FanXPSource` string.
    let id: String
    let titleKey: String
    let frequencyKey: String
    /// Points from `fan_xp_amount_for_source` — informational mirror only.
    let points: Int
    /// Call-site / SQL evidence for audits (not shown in UI).
    let awardEvidence: String
}

/// Single catalog so own and public profile sheets cannot drift.
enum FanXpCatalog {
    /// Implemented rules only. Linked to SQL + Swift claim sites.
    static let implementedRules: [FanXpRule] = [
        FanXpRule(
            id: FanXPSource.favoriteVenue,
            titleKey: "fan_xp_rule_favorite_venue_title",
            frequencyKey: "fan_xp_freq_per_unique_venue",
            points: 2,
            awardEvidence: "SQL fan_xp_amount_for_source('favorite_venue'); MapViewModel+Favorites.awardFanXP"
        ),
        FanXpRule(
            id: FanXPSource.venueEventInterest,
            titleKey: "fan_xp_rule_venue_event_interest_title",
            frequencyKey: "fan_xp_freq_per_eligible_event",
            points: 5,
            awardEvidence: "SQL fan_xp_amount_for_source('venue_event_interest'); MapViewModel+VenueEventSocial.awardFanXP"
        ),
        FanXpRule(
            id: FanXPSource.pickupCreate,
            titleKey: "fan_xp_rule_pickup_create_title",
            frequencyKey: "fan_xp_freq_per_pickup_hosted",
            points: 20,
            awardEvidence: "SQL fan_xp_amount_for_source('pickup_create'); MapViewModel+PickupGames.awardFanXP"
        ),
        FanXpRule(
            id: FanXPSource.pickupJoinApproved,
            titleKey: "fan_xp_rule_pickup_join_title",
            frequencyKey: "fan_xp_freq_per_approved_join",
            points: 10,
            awardEvidence: "SQL fan_xp_amount_for_source('pickup_join_approved'); MapViewModel+PickupGameRequests.awardFanXP"
        ),
        FanXpRule(
            id: FanXPSource.pickupComplete,
            titleKey: "fan_xp_rule_pickup_complete_title",
            frequencyKey: "fan_xp_freq_per_completed_pickup",
            points: 15,
            awardEvidence: "SQL fan_xp_amount_for_source('pickup_complete'); MapViewModel+PickupCreatorRatings.awardFanXP"
        ),
        FanXpRule(
            id: FanXPSource.friendConnected,
            titleKey: "fan_xp_rule_friend_connected_title",
            frequencyKey: "fan_xp_freq_per_friendship",
            points: 5,
            awardEvidence: "SQL fan_xp_amount_for_source('friend_connected'); ChatViewModel.awardFriendConnectedXP"
        ),
    ]
}

// MARK: - Compact profile line

/// Compact read-only Fan XP summary under the profile handle / identity meta.
/// Layout height follows the text line; the info control keeps a ≥44pt tap target
/// via padding + negative outer padding so it does not create vertical gaps.
struct FanXpSummaryLine: View {
    let totalXP: Int
    var languageCode: String = L10n.defaultLanguageCode

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showInfo = false

    private var resolvedLanguageCode: String {
        L10n.normalizedLanguageCode(languageCode)
    }

    private var formattedXP: String {
        let amount = max(0, totalXP)
        let number = amount.formatted(.number.grouping(.automatic))
        return String(
            format: L10n.t("fan_xp_line_format", languageCode: resolvedLanguageCode),
            number
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(formattedXP)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    // Expand hit target without growing the identity stack.
                    .padding(15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-15)
            .accessibilityLabel(L10n.t("fan_xp_info_a11y", languageCode: resolvedLanguageCode))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(formattedXP). \(L10n.t("fan_xp_info_a11y", languageCode: resolvedLanguageCode))"
        )
        .sheet(isPresented: $showInfo) {
            FanXpInfoSheet(languageCode: resolvedLanguageCode)
        }
    }
}

/// Compatibility alias for existing call sites.
typealias FanXPProfileLine = FanXpSummaryLine

// MARK: - Info sheet

struct FanXpInfoSheet: View {
    var languageCode: String = L10n.defaultLanguageCode

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var rules: [FanXpRule] { FanXpCatalog.implementedRules }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.t("fan_xp_info_intro", languageCode: languageCode))
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                }

                Section {
                    ForEach(rules) { rule in
                        FanXpRuleRow(rule: rule, languageCode: languageCode)
                    }
                } header: {
                    Text(L10n.t("fan_xp_how_to_earn", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(nil)
                } footer: {
                    Text(L10n.t("fan_xp_info_footer", languageCode: languageCode))
                        .font(.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.top, 4)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.t("fan_xp_info_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("fan_xp_info_close_a11y", languageCode: languageCode)) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(rules.count <= 6 ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
    }
}

private struct FanXpRuleRow: View {
    let rule: FanXpRule
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        L10n.t(rule.titleKey, languageCode: languageCode)
    }

    private var frequency: String {
        L10n.t(rule.frequencyKey, languageCode: languageCode)
    }

    private var pointsLabel: String {
        String(
            format: L10n.t("fan_xp_points_format", languageCode: languageCode),
            rule.points
        )
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.leading)
                Text(frequency)
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(pointsLabel)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(frequency), \(pointsLabel)")
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Fan XP line") {
    FanXpSummaryLine(totalXP: 1240)
        .padding()
}

#Preview("Fan XP sheet") {
    FanXpInfoSheet()
}
#endif

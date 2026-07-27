import SwiftUI

/// Shared Venue Energy education copy and presentation (fan + business).
/// Does not expose internal weights, caps, or algorithm scores.
/// Explicitly ``nonisolated`` for pure label helpers used beside scoring (project default is MainActor).
nonisolated enum VenueEnergyEducation {
    enum Audience: Equatable, Sendable {
        case fan
        case business
    }

    struct Level: Identifiable, Equatable, Sendable {
        let id: String
        let emoji: String
        let title: String
    }

    struct Signal: Identifiable, Equatable, Sendable {
        let id: String
        let symbol: String
        let title: String
    }

    static let levels: [Level] = [
        Level(id: "starting", emoji: "✨", title: "Starting"),
        Level(id: "active", emoji: "🔥", title: "Active"),
        Level(id: "hot", emoji: "🚀", title: "Hot"),
        Level(id: "trending", emoji: "👑", title: "Trending")
    ]

    static let contributingSignals: [Signal] = [
        Signal(id: "going", symbol: "person.crop.circle.badge.checkmark", title: "Mark themselves Going"),
        Signal(id: "atmosphere", symbol: "flame.fill", title: "Confirm Great Atmosphere"),
        Signal(id: "crowded", symbol: "person.3.fill", title: "Confirm Crowded"),
        Signal(id: "tvs", symbol: "tv.fill", title: "Confirm TVs Available"),
        Signal(id: "sound", symbol: "speaker.wave.2.fill", title: "Confirm Game Sound"),
        Signal(id: "seating", symbol: "chair.lounge.fill", title: "Confirm Seating Available"),
        Signal(id: "conversation", symbol: "bubble.left.and.bubble.right.fill", title: "Participate in conversations around the venue’s games"),
        Signal(id: "live", symbol: "dot.radiowaves.left.and.right", title: "Engage while a game is live")
    ]

    static let sheetTitle = "How Venue Energy Works"

    static let intro =
        "Venue Energy shows how active a watch spot is for the selected day. It is based on activity and confirmations from the FanGeo community."

    static let levelsFooter =
        "More genuine fan activity can move a venue through these levels."

    static let contributesTitle = "What increases Venue Energy?"

    static let contributesIntro =
        "Venue Energy can increase when fans:"

    static let trustTitle = "Built by fan activity"

    static let trustBody =
        "Venue Energy reflects community activity. Business Pro status and paid promotions do not increase a venue’s Venue Energy."

    static let currencyTitle = "Activity for the selected day"

    static let currencyBody =
        "Venue Energy focuses on activity for the selected day, so it can change as fans join, vote, and participate. Live game activity can also contribute while a game is happening."

    static let businessExtraTitle = "Building Venue Energy"

    static let businessExtraBody =
        "Businesses can build Venue Energy organically by creating accurate watch events and encouraging genuine fan participation, such as Going responses, venue confirmations, and community conversation."

    static let businessIntegrity =
        "Venue Energy is designed to represent genuine fan activity. Artificial or manipulated activity may be excluded."

    static let aboutAccessibilityLabel = "About Venue Energy"
    static let aboutAccessibilityHint = "Explains how venue activity levels are determined."

    /// Human-readable Discover map tier label (never the raw algorithm score).
    static func displayLabel(forMapEnergyScore score: Int) -> String {
        let tier = VenueMapEnergyScore.tier(for: score)
        switch tier {
        case .normal:
            return ""
        case .starting, .active, .hot, .trending:
            let emoji = tier.emoji
            return emoji.isEmpty ? tier.rawValue : "\(emoji) \(tier.rawValue)"
        }
    }
}

/// Compact circular info control for Venue Energy (44pt hit target).
struct VenueEnergyInfoButton: View {
    let action: () -> Void
    var tint: Color = FGColor.accentBlue

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint.opacity(colorScheme == .dark ? 0.90 : 0.82))
                .frame(width: 44, height: 44, alignment: .center)
                .contentShape(Rectangle())
                .padding(.vertical, -12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(VenueEnergyEducation.aboutAccessibilityLabel)
        .accessibilityHint(VenueEnergyEducation.aboutAccessibilityHint)
    }
}

/// Apple-style explanation sheet for Venue Energy (fan or business audience).
struct VenueEnergyHowItWorksSheet: View {
    let audience: VenueEnergyEducation.Audience

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introBlock
                    levelsBlock
                    contributesBlock
                    trustBlock
                    currencyBlock
                    if audience == .business {
                        businessBlock
                    }
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationTitle(VenueEnergyEducation.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents(audience == .business ? [.medium, .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FGAdaptiveSurface.sheetRoot)
        .onAppear {
            FanGeoAnalyticsService.record(
                eventName: "venue_energy_info_opened",
                metadata: ["audience": audience == .business ? "business" : "fan"],
                updateLastActive: false
            )
        }
    }

    private var introBlock: some View {
        Text(VenueEnergyEducation.intro)
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var levelsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(VenueEnergyEducation.levels) { level in
                HStack(spacing: 12) {
                    Text(level.emoji)
                        .font(.system(size: 22))
                        .frame(width: 36, alignment: .center)
                        .accessibilityHidden(true)
                    Text(level.title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(level.emoji) \(level.title)")
            }

            Text(VenueEnergyEducation.levelsFooter)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.85))
        )
    }

    private var contributesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(VenueEnergyEducation.contributesTitle)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.accentBlue)
                .textCase(.uppercase)
                .tracking(0.4)
                .accessibilityAddTraits(.isHeader)

            Text(VenueEnergyEducation.contributesIntro)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(VenueEnergyEducation.contributingSignals) { signal in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: signal.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                            .frame(width: 22, alignment: .center)
                            .accessibilityHidden(true)
                        Text(signal.title)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var trustBlock: some View {
        sectionCard(
            title: VenueEnergyEducation.trustTitle,
            body: VenueEnergyEducation.trustBody
        )
    }

    private var currencyBlock: some View {
        sectionCard(
            title: VenueEnergyEducation.currencyTitle,
            body: VenueEnergyEducation.currencyBody
        )
    }

    private var businessBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCard(
                title: VenueEnergyEducation.businessExtraTitle,
                body: VenueEnergyEducation.businessExtraBody
            )
            Text(VenueEnergyEducation.businessIntegrity)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    private func sectionCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.accentBlue)
                .textCase(.uppercase)
                .tracking(0.4)
                .accessibilityAddTraits(.isHeader)

            Text(body)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.85))
        )
    }
}

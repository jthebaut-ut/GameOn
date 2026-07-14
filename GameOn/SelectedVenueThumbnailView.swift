import SwiftUI

/// Selected managed-venue thumbnail for business dashboard chrome.
/// Uses the same cover/menu photo priority as Discover cards and venue detail headers.
struct SelectedVenueThumbnailView: View {
    enum Style {
        case compactHeader
        case dashboardSelector
        case managedVenueList
    }

    let venue: VenueProfileRow?
    var style: Style = .compactHeader
    var showsHourglass: Bool = false
    var fallbackTint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var size: CGFloat {
        switch style {
        case .compactHeader: return 32
        case .dashboardSelector: return 68
        case .managedVenueList: return 60
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .compactHeader: return 11
        case .dashboardSelector: return 18
        case .managedVenueList: return 15
        }
    }

    private var photoURLString: String? {
        guard let venue else { return nil }
        return ImageDisplayURL.forBusinessVenueCard(
            coverThumbnail: venue.cover_photo_thumbnail_url,
            coverFull: venue.cover_photo_url,
            menuThumbnail: venue.menu_photo_thumbnail_url,
            menuFull: venue.menu_photo_url
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundFill)

            if showsHourglass {
                Image(systemName: "hourglass")
                    .font(.system(size: iconPointSize, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(fallbackForeground)
            } else if let urlString = photoURLString,
                      let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    buildingFallback
                }
            } else {
                buildingFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.75)
        }
    }

    private var iconPointSize: CGFloat {
        switch style {
        case .compactHeader: return 11
        case .dashboardSelector: return 22
        case .managedVenueList: return 18
        }
    }

    private var resolvedFallbackTint: Color {
        fallbackTint ?? FGColor.accentGreen
    }

    private var backgroundFill: Color {
        switch style {
        case .compactHeader:
            return Color.white.opacity(colorScheme == .dark ? 0.10 : 0.12)
        case .dashboardSelector:
            return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.12)
        case .managedVenueList:
            return resolvedFallbackTint.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }
    }

    private var fallbackForeground: Color {
        switch style {
        case .compactHeader:
            return .white.opacity(0.88)
        case .dashboardSelector:
            return FGColor.accentBlue
        case .managedVenueList:
            return resolvedFallbackTint
        }
    }

    private var borderColor: Color {
        switch style {
        case .compactHeader:
            return Color.white.opacity(colorScheme == .dark ? 0.20 : 0.26)
        case .dashboardSelector:
            return FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.28 : 0.18)
        case .managedVenueList:
            return resolvedFallbackTint.opacity(colorScheme == .dark ? 0.24 : 0.18)
        }
    }

    private var buildingFallback: some View {
        Image(systemName: style == .managedVenueList ? "building.2" : "building.2.fill")
            .font(.system(size: iconPointSize, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(fallbackForeground)
    }
}

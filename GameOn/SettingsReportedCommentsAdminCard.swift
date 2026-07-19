import SwiftUI

struct SettingsReportedCommentsAdminCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: MapViewModel

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.18, green: 0.05, blue: 0.06).opacity(0.72)
            : Color.red.opacity(0.08)
    }

    private var containerBackground: Color {
        colorScheme == .dark
            ? FGColor.cardBackground(colorScheme)
            : Color.white.opacity(0.95)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported Comments")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Button {
                Task {
                    await viewModel.loadReportedComments()
                }
            } label: {
                Label("Refresh Reports", systemImage: "arrow.clockwise")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .foregroundStyle(.white)
                    .background(FGColor.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            if viewModel.reportedCommentDisplays.isEmpty {
                Text("No reported comments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reportedCommentDisplays) { report in
                    let commentUnavailable = isCommentUnavailable(report)
                    VStack(alignment: .leading, spacing: 12) {

                        HStack(alignment: .top, spacing: 12) {

                            if !commentUnavailable,
                               let url = URL(string: report.commenterAvatarURL),
                               !report.commenterAvatarURL.isEmpty {

                                AsyncImage(url: url) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } placeholder: {
                                    Circle()
                                        .fill(Color.gray.opacity(0.20))
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())

                            } else {

                                reportAvatarFallback(unavailable: commentUnavailable, name: report.commenterName)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(commentUnavailable ? "Comment unavailable" : report.commenterName)
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(FGColor.primaryText(colorScheme))

                                if !commentUnavailable {
                                    Text("“\(report.commentText)”")
                                        .font(.subheadline)
                                        .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.88))
                                }

                                Text("\(report.venueName) • \(report.eventTitle)")
                                    .font(.caption)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                                Text("Reported: \(formattedReportDate(report.reportedAt))")
                                    .font(.caption)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                                Text("Reported by: \(report.reporterName)")
                                    .font(.caption2)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                
                                HStack(spacing: 10) {

                                    Button {
                                        Task {
                                            await viewModel.deleteReportedComment(report)
                                            await viewModel.loadReportedComments()
                                        }
                                    } label: {
                                        Label("Delete Comment", systemImage: "xmark.circle.fill")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.24 : 0.14))
                                            .foregroundStyle(FGColor.dangerRed)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        Task {
                                            await viewModel.dismissCommentReport(report)
                                        }
                                    } label: {
                                        Label("Dismiss Report", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.14))
                                            .foregroundStyle(FGColor.accentGreen)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.38 : 0.18), lineWidth: 1)
                    }
                }
            }
        }
        .padding()
        .background(containerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func reportAvatarFallback(unavailable: Bool, name: String) -> some View {
        Circle()
            .fill(unavailable ? FGColor.secondaryText(colorScheme).opacity(0.14) : Color.orange.opacity(0.15))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: unavailable ? "text.bubble.fill" : "person.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(unavailable ? FGColor.secondaryText(colorScheme) : Color.orange)
            }
            .accessibilityHidden(true)
    }

    private func isCommentUnavailable(_ report: ReportedCommentDisplay) -> Bool {
        report.commentText.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Comment not found") == .orderedSame
    }

    private func formattedReportDate(_ rawDate: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        guard let date = isoFormatter.date(from: rawDate) else {
            return rawDate
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a 'MT'"
        formatter.timeZone = TimeZone(identifier: "America/Denver")

        return formatter.string(from: date)
    }
}

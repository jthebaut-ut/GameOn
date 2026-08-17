import Foundation
import UserNotifications

/// Canonical optional rich-push artwork contract.
///
/// Server and local notifications set these keys. The Notification Service
/// Extension only downloads `artwork_url` when the host is trusted.
nonisolated enum FanGeoPushArtwork {
    static let urlKey = "artwork_url"
    static let kindKey = "artwork_kind"
    static let entityIDKey = "artwork_entity_id"

    enum Kind: String, Sendable {
        case team
        case proTeam = "pro_team"
        case user
        case group
        case player
    }

    static let maxBytes = 256 * 1024
    static let downloadTimeout: TimeInterval = 8
    static let attachmentIdentifier = "fangeo.push.artwork"

    /// Fail-closed host allowlist. HTTPS only.
    static func isTrustedArtworkURL(_ raw: String?) -> Bool {
        trustedURL(from: raw) != nil
    }

    static func trustedURL(from raw: String?) -> URL? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.count <= 1024 else { return nil }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        guard (url.scheme ?? "").lowercased() == "https" else { return nil }
        if isTheSportsDBHost(host) { return compactProviderURL(url) }
        if isSupabaseStorageURL(url, host: host) { return url }
        return nil
    }

    static func compactProviderURL(_ url: URL) -> URL {
        let path = url.path.lowercased()
        if path.hasSuffix("/tiny") || path.hasSuffix("/small") || path.hasSuffix("/medium") {
            return url
        }
        let raw = url.absoluteString
        return URL(string: raw + "/tiny") ?? url
    }

    static func isTheSportsDBHost(_ host: String) -> Bool {
        host == "www.thesportsdb.com"
            || host == "thesportsdb.com"
            || host == "r2.thesportsdb.com"
            || host.hasSuffix(".thesportsdb.com")
    }

    static func isSupabaseStorageURL(_ url: URL, host: String) -> Bool {
        let path = url.path.lowercased()
        guard path.contains("/storage/v1/object/") else { return false }
        return host.hasSuffix(".supabase.co")
            || host.hasSuffix(".supabase.in")
            || host == "supabase.co"
            || host == "supabase.in"
    }

    static func fields(
        url: String?,
        kind: Kind,
        entityID: String? = nil
    ) -> [String: String] {
        guard let trusted = trustedURL(from: url) else { return [:] }
        var fields = [
            urlKey: trusted.absoluteString,
            kindKey: kind.rawValue
        ]
        let entity = entityID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !entity.isEmpty { fields[entityIDKey] = entity }
        return fields
    }

    static func merge(_ extra: [String: String], into userInfo: inout [AnyHashable: Any]) {
        for (key, value) in extra {
            userInfo[key] = value
        }
    }

    static func artworkURL(from userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo[urlKey] as? String { return value }
        return nil
    }
}

/// Picks the send-time artwork URL. Never infers a scoring team or winner from titles.
nonisolated enum FanGeoPushArtworkSelection {
    static func teamLogo(thumbnail: String?, full: String?) -> String? {
        FanGeoPushArtwork.trustedURL(from: thumbnail)?.absoluteString
            ?? FanGeoPushArtwork.trustedURL(from: full)?.absoluteString
    }

    static func userAvatar(thumbnail: String?, full: String?) -> String? {
        FanGeoPushArtwork.trustedURL(from: thumbnail)?.absoluteString
            ?? FanGeoPushArtwork.trustedURL(from: full)?.absoluteString
    }

    /// Score update: scoring-team badge only when that side is identified.
    static func proGameScore(
        scoringTeam: String?,
        homeTeam: String,
        awayTeam: String,
        homeBadgeURL: String?,
        awayBadgeURL: String?
    ) -> String? {
        guard let scoring = normalized(scoringTeam) else { return nil }
        if scoring == normalized(homeTeam) {
            return FanGeoPushArtwork.trustedURL(from: homeBadgeURL)?.absoluteString
        }
        if scoring == normalized(awayTeam) {
            return FanGeoPushArtwork.trustedURL(from: awayBadgeURL)?.absoluteString
        }
        return nil
    }

    /// Final: winner badge. Draw → no team privileged.
    static func proGameFinal(
        homeTeam: String,
        awayTeam: String,
        homeScore: Int,
        awayScore: Int,
        homeBadgeURL: String?,
        awayBadgeURL: String?
    ) -> String? {
        if homeScore == awayScore { return nil }
        if homeScore > awayScore {
            return FanGeoPushArtwork.trustedURL(from: homeBadgeURL)?.absoluteString
        }
        return FanGeoPushArtwork.trustedURL(from: awayBadgeURL)?.absoluteString
    }

    static func chatDirect(senderAvatarURL: String?) -> String? {
        FanGeoPushArtwork.trustedURL(from: senderAvatarURL)?.absoluteString
    }

    /// Group: uploaded group image, else Team logo for Team Chat, else sender avatar.
    static func chatGroup(
        groupImageURL: String?,
        teamLogoURL: String?,
        senderAvatarURL: String?
    ) -> String? {
        if let group = FanGeoPushArtwork.trustedURL(from: groupImageURL) {
            return group.absoluteString
        }
        if let team = FanGeoPushArtwork.trustedURL(from: teamLogoURL) {
            return team.absoluteString
        }
        return FanGeoPushArtwork.trustedURL(from: senderAvatarURL)?.absoluteString
    }

    static func from(snapshot: FanGeoProGameInboxSnapshot) -> (url: String, kind: FanGeoPushArtwork.Kind)? {
        switch snapshot.kind {
        case .score, .halftime:
            if let url = proGameScore(
                scoringTeam: snapshot.identifiedScoringTeam,
                homeTeam: snapshot.homeTeam,
                awayTeam: snapshot.awayTeam,
                homeBadgeURL: snapshot.homeBadgeURL,
                awayBadgeURL: snapshot.awayBadgeURL
            ) {
                return (url, .proTeam)
            }
            return nil
        case .final:
            if let url = proGameFinal(
                homeTeam: snapshot.homeTeam,
                awayTeam: snapshot.awayTeam,
                homeScore: snapshot.homeScore,
                awayScore: snapshot.awayScore,
                homeBadgeURL: snapshot.homeBadgeURL,
                awayBadgeURL: snapshot.awayBadgeURL
            ) {
                return (url, .proTeam)
            }
            return nil
        case .kickoff:
            return nil
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return ProGameTeamScoreIdentity.cleanTeamName(trimmed)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

nonisolated protocol FanGeoPushArtworkFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct FanGeoPushArtworkURLSessionFetcher: FanGeoPushArtworkFetching {
    let session: URLSession

    init(timeout: TimeInterval = FanGeoPushArtwork.downloadTimeout) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

nonisolated enum FanGeoPushArtworkDownloader {
    static func download(
        urlString: String?,
        fetcher: FanGeoPushArtworkFetching = FanGeoPushArtworkURLSessionFetcher(),
        maxBytes: Int = FanGeoPushArtwork.maxBytes
    ) async -> URL? {
        guard let url = FanGeoPushArtwork.trustedURL(from: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = FanGeoPushArtwork.downloadTimeout
        do {
            let (data, response) = try await fetcher.data(for: request)
            guard !Task.isCancelled else { return nil }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard data.count > 32, data.count <= maxBytes else { return nil }
            guard let fileExtension = validatedImageExtension(data: data, mime: http.value(forHTTPHeaderField: "Content-Type")) else {
                return nil
            }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("fangeo-push-artwork", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static func validatedImageExtension(data: Data, mime: String?) -> String? {
        guard let sniffed = sniff(data) else { return nil }
        let mimeToken = (mime ?? "").split(separator: ";").first.map(String.init)?.lowercased() ?? ""
        if mimeToken.isEmpty { return sniffed }
        if (mimeToken.hasPrefix("image/jpeg") || mimeToken == "image/jpg") && sniffed == "jpg" { return "jpg" }
        if mimeToken.hasPrefix("image/png") && sniffed == "png" { return "png" }
        if mimeToken.hasPrefix("image/webp") && sniffed == "webp" { return "webp" }
        if mimeToken.hasPrefix("image/gif") && sniffed == "gif" { return "gif" }
        return nil
    }

    private static func sniff(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes.count >= 6, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }
        return nil
    }
}

nonisolated enum FanGeoPushArtworkAttachment {
    @discardableResult
    static func apply(
        to content: UNMutableNotificationContent,
        userInfo: [AnyHashable: Any],
        fetcher: FanGeoPushArtworkFetching = FanGeoPushArtworkURLSessionFetcher()
    ) async -> Bool {
        let raw = FanGeoPushArtwork.artworkURL(from: userInfo)
        guard let fileURL = await FanGeoPushArtworkDownloader.download(urlString: raw, fetcher: fetcher) else {
            return false
        }
        do {
            let attachment = try UNNotificationAttachment(
                identifier: FanGeoPushArtwork.attachmentIdentifier,
                url: fileURL,
                options: [UNNotificationAttachmentOptionsTypeHintKey: typeHint(for: fileURL)]
            )
            content.attachments = [attachment]
            return true
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return false
        }
    }

    private static func typeHint(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "public.png"
        case "gif": return "com.compuserve.gif"
        case "webp": return "org.webmproject.webp"
        default: return "public.jpeg"
        }
    }
}

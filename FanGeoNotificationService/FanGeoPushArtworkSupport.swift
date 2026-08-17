import Foundation
import UserNotifications

/// Extension-local copy of the trusted-host + download rules.
/// Keep aligned with `GameOn/FanGeoPushArtwork.swift`.
enum FanGeoPushArtworkSupport {
    static let urlKey = "artwork_url"
    static let maxBytes = 256 * 1024
    static let downloadTimeout: TimeInterval = 8
    static let attachmentIdentifier = "fangeo.push.artwork"

    static func trustedURL(from raw: String?) -> URL? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.count <= 1024 else { return nil }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        guard (url.scheme ?? "").lowercased() == "https" else { return nil }
        if isTheSportsDBHost(host) { return compactProviderURL(url) }
        if isSupabaseStorageURL(url, host: host) { return url }
        return nil
    }

    static func isTrustedArtworkURL(_ raw: String?) -> Bool {
        trustedURL(from: raw) != nil
    }

    private static func isTheSportsDBHost(_ host: String) -> Bool {
        host == "www.thesportsdb.com"
            || host == "thesportsdb.com"
            || host == "r2.thesportsdb.com"
            || host.hasSuffix(".thesportsdb.com")
    }

    private static func isSupabaseStorageURL(_ url: URL, host: String) -> Bool {
        let path = url.path.lowercased()
        guard path.contains("/storage/v1/object/") else { return false }
        return host.hasSuffix(".supabase.co")
            || host.hasSuffix(".supabase.in")
            || host == "supabase.co"
            || host == "supabase.in"
    }

    private static func compactProviderURL(_ url: URL) -> URL {
        let path = url.path.lowercased()
        if path.hasSuffix("/tiny") || path.hasSuffix("/small") || path.hasSuffix("/medium") {
            return url
        }
        return URL(string: url.absoluteString + "/tiny") ?? url
    }

    static func download(urlString: String?) async -> URL? {
        guard let url = trustedURL(from: urlString) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = downloadTimeout
        config.timeoutIntervalForResource = downloadTimeout
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = downloadTimeout
        do {
            let (data, response) = try await session.data(for: request)
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

    @discardableResult
    static func applyAttachment(to content: UNMutableNotificationContent, userInfo: [AnyHashable: Any]) async -> Bool {
        let raw = userInfo[urlKey] as? String
        guard let fileURL = await download(urlString: raw) else { return false }
        do {
            let attachment = try UNNotificationAttachment(
                identifier: attachmentIdentifier,
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

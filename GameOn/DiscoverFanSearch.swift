import Combine
import Foundation
import Supabase

/// Privacy-safe fan hit from ``search_discoverable_fans`` (Discover global search).
struct DiscoverFanSearchResult: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let user_id: UUID
    let display_name: String
    let handle: String?
    let avatar_url: String?
    let is_friend: Bool

    var id: UUID { user_id }

    var displayHandle: String {
        let stored = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? "" : FanGeoHandleRules.displayHandle(stored: stored)
    }
}

private struct SearchDiscoverableFansParams: Encodable {
    let p_query: String
    let p_limit: Int
}

/// Debounced Discover fan search kept off MapViewModel to avoid broad publishes.
@MainActor
final class DiscoverFanSearchController: ObservableObject {
    @Published private(set) var results: [DiscoverFanSearchResult] = []
    @Published private(set) var isLoading = false
    @Published private(set) var activeNormalizedQuery: String = ""

    private var debounceTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var resultCache: [String: [DiscoverFanSearchResult]] = [:]
    private let cacheLimit = 24
    private let debounceMilliseconds: UInt64 = 300
    private let resultLimit = 5

    func refresh(query: String, isAuthenticated: Bool, isFocused: Bool) {
        let normalized = Self.normalizeQuery(query)
        activeNormalizedQuery = normalized

        guard isFocused, isAuthenticated else {
            cancelInFlight(clearResults: true)
            return
        }

        guard normalized.count >= 2 else {
            cancelInFlight(clearResults: true)
            return
        }

        if let cached = resultCache[normalized] {
            results = cached
            isLoading = false
        }

        debounceTask?.cancel()
        generation &+= 1
        let token = generation
        let key = normalized
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceMilliseconds * 1_000_000)
            guard !Task.isCancelled, token == generation else { return }
            await self.performSearch(normalizedQuery: key, generation: token)
        }
    }

    func clear() {
        cancelInFlight(clearResults: true)
    }

    private func cancelInFlight(clearResults: Bool) {
        debounceTask?.cancel()
        debounceTask = nil
        generation &+= 1
        isLoading = false
        if clearResults {
            results = []
            activeNormalizedQuery = ""
        }
    }

    private func performSearch(normalizedQuery: String, generation token: UInt64) async {
        if let cached = resultCache[normalizedQuery] {
            guard token == generation, activeNormalizedQuery == normalizedQuery else { return }
            results = cached
            isLoading = false
            return
        }

        isLoading = true
        do {
            let rows: [DiscoverFanSearchResult] = try await supabase
                .rpc(
                    "search_discoverable_fans",
                    params: SearchDiscoverableFansParams(
                        p_query: normalizedQuery,
                        p_limit: resultLimit
                    )
                )
                .execute()
                .value

            guard token == generation, activeNormalizedQuery == normalizedQuery else { return }
            storeCache(key: normalizedQuery, rows: rows)
            results = rows
            isLoading = false
#if DEBUG
            print("[DiscoverFanSearch] query=\(normalizedQuery) count=\(rows.count)")
#endif
        } catch {
            guard token == generation, activeNormalizedQuery == normalizedQuery else { return }
            // Keep prior results for this key if any; otherwise clear.
            if resultCache[normalizedQuery] == nil {
                results = []
            }
            isLoading = false
#if DEBUG
            print("[DiscoverFanSearch] error=\(error.localizedDescription)")
#endif
        }
    }

    private func storeCache(key: String, rows: [DiscoverFanSearchResult]) {
        resultCache[key] = rows
        if resultCache.count > cacheLimit {
            let overflow = resultCache.count - cacheLimit
            for stale in resultCache.keys.prefix(overflow) {
                resultCache.removeValue(forKey: stale)
            }
        }
    }

    /// Trim, strip leading `@`, collapse whitespace — case folded for cache keys.
    nonisolated static func normalizeQuery(_ raw: String) -> String {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while q.hasPrefix("@") {
            q.removeFirst()
        }
        let collapsed = q
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.lowercased()
    }
}

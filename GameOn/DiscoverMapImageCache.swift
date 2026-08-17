import SwiftUI
import UIKit

/// Diagnostics-only tracing for ``DiscoverMapImageCache`` lookups (does not alter cache behavior).
nonisolated enum ImageCacheDebug {
    /// Per-lookup tracing; off by default so tab switches stay quiet (session summaries still log).
    static var verbosePerImageLogging = false

    private static let lock = NSLock()
    private static var memoryHits = 0
    private static var diskHits = 0
    private static var networkFetches = 0
    private static var inFlightJoins = 0
    private static var lookupCount = 0
    private static var networkFetchCountsByKey: [String: Int] = [:]

    private static func trace(_ message: @autoclosure () -> String) {
        guard verbosePerImageLogging else { return }
        DebugLogGate.hotPathPerf(message())
    }

    private struct FirstNetworkFetchTrace {
        let rawURL: String
        let normalizedURL: String
        let startedAt: Date
        var completedAt: Date?
        var memoryStoreKey: String?
    }

    private static var firstNetworkFetchByCacheKey: [String: FirstNetworkFetchTrace] = [:]

    private static func threadLabel() -> String {
        if Thread.isMainThread {
            return "main"
        }
        return String(describing: Thread.current)
    }

    static func threadLabelForDiagnostics() -> String {
        threadLabel()
    }

    static func logImageInvocationStart(actorIdentity: ObjectIdentifier, invocationId: UInt64, cacheKey: String, rawURL: String) {
        trace("[ImageCacheDebug] imageInvocationStart=true")
        trace("[ImageCacheDebug] actorIdentity=\(actorIdentity)")
        trace("[ImageCacheDebug] imageInvocationId=\(invocationId)")
        trace("[ImageCacheDebug] cacheKey=\(cacheKey)")
        trace("[ImageCacheDebug] rawURL=\(rawURL)")
        trace("[ImageCacheDebug] invocationThread=\(threadLabel())")
    }

    static func logInFlightLookupConcurrency(
        actorIdentity: ObjectIdentifier,
        invocationId: UInt64,
        cacheKey: String,
        existingTaskFound: Bool,
        activeKeys: [String],
        lookupBeforeInsertRaceSuspected: Bool
    ) {
        trace("[ImageCacheDebug] inflightLookupKey=\(cacheKey)")
        trace("[ImageCacheDebug] inflightExistingTaskFound=\(existingTaskFound)")
        trace("[ImageCacheDebug] inflightActiveKeys=\(activeKeys.joined(separator: ","))")
        trace("[ImageCacheDebug] actorIdentity=\(actorIdentity)")
        trace("[ImageCacheDebug] imageInvocationId=\(invocationId)")
        trace("[ImageCacheDebug] inflightLookupThread=\(threadLabel())")
        trace("[ImageCacheDebug] lookupBeforeInsertRaceSuspected=\(lookupBeforeInsertRaceSuspected)")
    }

    static func logInFlightInsertConcurrency(
        actorIdentity: ObjectIdentifier,
        invocationId: UInt64,
        cacheKey: String,
        activeKeys: [String],
        lookupThread: String,
        lookupInsertGapMs: Double
    ) {
        trace("[ImageCacheDebug] inflightInsertKey=\(cacheKey)")
        trace("[ImageCacheDebug] inflightActiveKeysAfterInsert=\(activeKeys.joined(separator: ","))")
        trace("[ImageCacheDebug] actorIdentity=\(actorIdentity)")
        trace("[ImageCacheDebug] imageInvocationId=\(invocationId)")
        trace("[ImageCacheDebug] inflightInsertThread=\(threadLabel())")
        trace("[ImageCacheDebug] inflightLookupThread=\(lookupThread)")
        trace("[ImageCacheDebug] lookupInsertGapMs=\(FanGeoFixedFloatFormat.d3(lookupInsertGapMs))")
    }

    /// Global probe outside actor isolation to detect overlapping lookups before any insert.
    private enum InFlightRegistrationProbe {
        private static let lock = NSLock()
        private static var openLookupInvocationByCacheKey: [String: UInt64] = [:]
        private static var insertedCacheKeys: Set<String> = []

        static func registerLookup(cacheKey: String, invocationId: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let hadOpenLookup = openLookupInvocationByCacheKey[cacheKey] != nil
            let hadInsert = insertedCacheKeys.contains(cacheKey)
            openLookupInvocationByCacheKey[cacheKey] = invocationId
            return hadOpenLookup && !hadInsert
        }

        static func registerInsert(cacheKey: String, invocationId: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            insertedCacheKeys.insert(cacheKey)
            if openLookupInvocationByCacheKey[cacheKey] == invocationId {
                openLookupInvocationByCacheKey.removeValue(forKey: cacheKey)
            }
        }

        static func reset() {
            lock.lock()
            openLookupInvocationByCacheKey = [:]
            insertedCacheKeys = []
            lock.unlock()
        }
    }

    static func diagnosticIdentity(for url: URL, bucket: DiscoverMapImageCache.Bucket) -> (normalizedURL: String, cacheKey: String) {
        let normalizedURL = ImageDisplayURL.canonicalStorageURLString(url.absoluteString)
        // Exact URL (including `?v=`) so distinct refresh tokens never share an in-flight download
        // or diagnostic network counter. Memory storage already keys by the raw `URL`.
        let cacheKey = "\(bucket)|\(url.absoluteString)"
        return (normalizedURL, cacheKey)
    }

    static func logLookup(
        bucket: DiscoverMapImageCache.Bucket,
        url: URL,
        memoryHit: Bool,
        diskHit: Bool,
        networkFetch: Bool,
        inFlightJoin: Bool,
        source: String = "DiscoverMapImageCache"
    ) {
#if DEBUG
        let identity = diagnosticIdentity(for: url, bucket: bucket)
        lock.lock()
        lookupCount += 1
        if memoryHit { memoryHits += 1 }
        if diskHit { diskHits += 1 }
        if networkFetch {
            networkFetches += 1
            let prior = networkFetchCountsByKey[identity.cacheKey, default: 0]
            networkFetchCountsByKey[identity.cacheKey] = prior + 1
        }
        let duplicateNetwork = networkFetch && networkFetchCountsByKey[identity.cacheKey, default: 0] > 1
        if inFlightJoin { inFlightJoins += 1 }
        lock.unlock()

        trace("[ImageCacheDebug] memoryHit=\(memoryHit)")
        trace("[ImageCacheDebug] diskHit=\(diskHit)")
        trace("[ImageCacheDebug] networkFetch=\(networkFetch)")
        trace("[ImageCacheDebug] inFlightJoin=\(inFlightJoin)")
        trace("[ImageCacheDebug] bucket=\(bucket)")
        trace("[ImageCacheDebug] normalizedURL=\(identity.normalizedURL)")
        trace("[ImageCacheDebug] cacheKey=\(identity.cacheKey)")
        trace("[ImageCacheDebug] source=\(source)")
        if duplicateNetwork {
            trace("[ImageCacheDebug] duplicateNetworkFetch=true cacheKey=\(identity.cacheKey)")
        }
        if memoryHit || diskHit {
            PerformanceLog.imageCacheHit(urlHash: PerformanceLog.urlHash(for: identity.cacheKey))
        } else if networkFetch {
            PerformanceLog.imageCacheMiss(urlHash: PerformanceLog.urlHash(for: identity.cacheKey))
        }
        if networkFetch, url.absoluteString != identity.normalizedURL {
            trace("[ImageCacheDebug] versionedDisplayURL=true rawURL=\(url.absoluteString)")
        }
#endif
    }

    static func logInFlightJoin(
        bucket: DiscoverMapImageCache.Bucket,
        url: URL,
        source: String = "image"
    ) {
        let identity = diagnosticIdentity(for: url, bucket: bucket)
        lock.lock()
        lookupCount += 1
        inFlightJoins += 1
        lock.unlock()

        trace("[ImageCacheDebug] memoryHit=false")
        trace("[ImageCacheDebug] diskHit=false")
        trace("[ImageCacheDebug] networkFetch=false")
        trace("[ImageCacheDebug] inFlightJoin=true")
        trace("[ImageCacheDebug] duplicateNetworkFetchPrevented=true")
        trace("[ImageCacheDebug] bucket=\(bucket)")
        trace("[ImageCacheDebug] normalizedURL=\(identity.normalizedURL)")
        trace("[ImageCacheDebug] cacheKey=\(identity.cacheKey)")
        trace("[ImageCacheDebug] source=\(source)")
    }

    static func logInFlightLookup(cacheKey: String, existingTaskFound: Bool, activeKeys: [String]) {
        trace("[ImageCacheDebug] inflightLookupKey=\(cacheKey)")
        trace("[ImageCacheDebug] inflightExistingTaskFound=\(existingTaskFound)")
        trace("[ImageCacheDebug] inflightActiveKeys=\(activeKeys.joined(separator: ","))")
    }

    static func logInFlightInsert(cacheKey: String, activeKeys: [String]) {
        trace("[ImageCacheDebug] inflightInsertKey=\(cacheKey)")
        trace("[ImageCacheDebug] inflightActiveKeysAfterInsert=\(activeKeys.joined(separator: ","))")
    }

    static func logInFlightRemove(cacheKey: String, activeKeys: [String]) {
        trace("[ImageCacheDebug] inflightRemoveKey=\(cacheKey)")
        trace("[ImageCacheDebug] inflightActiveKeysAfterRemove=\(activeKeys.joined(separator: ","))")
    }

    static func registerInFlightLookupProbe(cacheKey: String, invocationId: UInt64) -> Bool {
        InFlightRegistrationProbe.registerLookup(cacheKey: cacheKey, invocationId: invocationId)
    }

    static func registerInFlightInsertProbe(cacheKey: String, invocationId: UInt64) {
        InFlightRegistrationProbe.registerInsert(cacheKey: cacheKey, invocationId: invocationId)
    }

    static func logURLSessionStart(cacheKey: String, url: URL) {
        trace("[ImageCacheDebug] urlSessionStart=true")
        trace("[ImageCacheDebug] cacheKey=\(cacheKey)")
        trace("[ImageCacheDebug] rawURL=\(url.absoluteString)")
    }

    static func logNewNetworkFetchPath(
        cacheKey: String,
        inFlightActiveKeysBeforeInsert: [String],
        rawURL: String,
        normalizedURL: String,
        memoryLookupKey: String
    ) {
        trace("[ImageCacheDebug] newNetworkFetchPath=true")
        trace("[ImageCacheDebug] cacheKey=\(cacheKey)")
        trace("[ImageCacheDebug] inflightActiveKeysBeforeInsert=\(inFlightActiveKeysBeforeInsert.joined(separator: ","))")
        trace("[ImageCacheDebug] rawURL=\(rawURL)")
        trace("[ImageCacheDebug] normalizedURL=\(normalizedURL)")
        trace("[ImageCacheDebug] memoryLookupKey=\(memoryLookupKey)")
        recordDuplicateNetworkFetchIfNeeded(
            cacheKey: cacheKey,
            rawURL: rawURL,
            normalizedURL: normalizedURL,
            memoryLookupKey: memoryLookupKey
        )
    }

    static func recordNetworkFetchCompleted(cacheKey: String) {
        lock.lock()
        firstNetworkFetchByCacheKey[cacheKey]?.completedAt = Date()
        lock.unlock()
    }

    static func recordMemoryStore(cacheKey: String, memoryStoreKey: String) {
        lock.lock()
        firstNetworkFetchByCacheKey[cacheKey]?.memoryStoreKey = memoryStoreKey
        lock.unlock()
        trace("[ImageCacheDebug] memoryStoreKey=\(memoryStoreKey)")
        trace("[ImageCacheDebug] cacheKey=\(cacheKey)")
    }

    private static func recordDuplicateNetworkFetchIfNeeded(
        cacheKey: String,
        rawURL: String,
        normalizedURL: String,
        memoryLookupKey: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard let first = firstNetworkFetchByCacheKey[cacheKey] else {
            firstNetworkFetchByCacheKey[cacheKey] = FirstNetworkFetchTrace(
                rawURL: rawURL,
                normalizedURL: normalizedURL,
                startedAt: Date(),
                completedAt: nil,
                memoryStoreKey: nil
            )
            return
        }

        let secondStartedAt = Date()
        let firstCompletedBeforeSecond = first.completedAt.map { $0 <= secondStartedAt } ?? false
        let firstStillInFlight = first.completedAt == nil
        let versionTokenChanged = first.rawURL != rawURL && first.normalizedURL == normalizedURL

        trace("[ImageCacheDebug] duplicateFetchInvestigation=true")
        trace("[ImageCacheDebug] cacheKey=\(cacheKey)")
        trace("[ImageCacheDebug] firstRawURL=\(first.rawURL)")
        trace("[ImageCacheDebug] secondRawURL=\(rawURL)")
        trace("[ImageCacheDebug] firstNormalizedURL=\(first.normalizedURL)")
        trace("[ImageCacheDebug] secondNormalizedURL=\(normalizedURL)")
        trace("[ImageCacheDebug] firstMemoryStoreKey=\(first.memoryStoreKey ?? "nil")")
        trace("[ImageCacheDebug] secondMemoryLookupKey=\(memoryLookupKey)")
        trace("[ImageCacheDebug] firstFetchCompletedBeforeSecondStarted=\(firstCompletedBeforeSecond)")
        trace("[ImageCacheDebug] firstFetchStillInFlightAtSecondLookup=\(firstStillInFlight)")
        trace("[ImageCacheDebug] versionTokenChanged=\(versionTokenChanged)")
    }

    static func logBypass(
        loader: String,
        url: URL?,
        bucket: DiscoverMapImageCache.Bucket = .venue,
        reason: String
    ) {
        guard let url else {
            trace("[ImageCacheDebug] bypassLoader=\(loader) reason=\(reason) url=nil")
            return
        }
        let identity = diagnosticIdentity(for: url, bucket: bucket)
        trace("[ImageCacheDebug] bypassLoader=\(loader)")
        trace("[ImageCacheDebug] bypassReason=\(reason)")
        trace("[ImageCacheDebug] bucket=\(bucket)")
        trace("[ImageCacheDebug] normalizedURL=\(identity.normalizedURL)")
        trace("[ImageCacheDebug] cacheKey=\(identity.cacheKey)")
        trace("[ImageCacheDebug] memoryHit=false")
        trace("[ImageCacheDebug] diskHit=false")
        trace("[ImageCacheDebug] networkFetch=unknown")
    }

    static func printSessionSummary(reason: String) {
        lock.lock()
        let lookups = lookupCount
        let mem = memoryHits
        let disk = diskHits
        let net = networkFetches
        let joins = inFlightJoins
        let duplicates = networkFetchCountsByKey.values.reduce(0) { partial, count in
            partial + max(0, count - 1)
        }
        let duplicateKeys = networkFetchCountsByKey
            .filter { $0.value > 1 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(8)
            .map { "\($0.key):\($0.value)" }
            .joined(separator: " | ")
        lock.unlock()

        let memoryRate = lookups > 0 ? Double(mem) / Double(lookups) : 0
        let diskRate = lookups > 0 ? Double(disk) / Double(lookups) : 0
        DebugLogGate.hotPathPerf("[ImageCacheDebug] sessionSummary reason=\(reason)")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] lookupCount=\(lookups)")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] memoryHitRate=\(FanGeoFixedFloatFormat.d3(memoryRate))")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] diskHitRate=\(FanGeoFixedFloatFormat.d3(diskRate))")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] memoryHits=\(mem)")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] diskHits=\(disk)")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] networkFetchCount=\(net)")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] inFlightJoinCount=\(joins)")
        DebugLogGate.hotPathPerf("[ImageCacheDebug] duplicateNetworkFetchCount=\(duplicates)")
        if !duplicateKeys.isEmpty {
            DebugLogGate.hotPathPerf("[ImageCacheDebug] duplicateNetworkKeys=\(duplicateKeys)")
        }
        DebugLogGate.hotPathPerf("[ImageCacheDebug] diskLayerPresent=false")
    }

    static func resetSessionStats(reason: String = "reset") {
        lock.lock()
        memoryHits = 0
        diskHits = 0
        networkFetches = 0
        inFlightJoins = 0
        lookupCount = 0
        networkFetchCountsByKey = [:]
        firstNetworkFetchByCacheKey = [:]
        lock.unlock()
        trace("[ImageCacheDebug] sessionReset reason=\(reason)")
    }
}

/// Small in-memory image cache for Discover map thumbnails and “going” avatars (reduces `AsyncImage` refetch/flicker).
actor DiscoverMapImageCache {
    /// Usage buckets also define decode size. Cache keys include the bucket so a small avatar
    /// decode can never satisfy a large detail presentation of the same URL.
    nonisolated enum Bucket: Hashable {
        case venue
        case avatar
        /// Full-screen / high-resolution presentation only.
        case detail

        nonisolated var decodeTarget: ImageDecodeDownsampler.DecodeTarget {
            switch self {
            case .avatar: return .avatarSmall
            case .venue: return .listThumbnail
            case .detail: return .detail
            }
        }

        /// Pick a downsample bucket from on-screen point size. 40–128pt marks stay
        /// in the avatar decode (480px); larger venue cards keep the list thumbnail.
        nonisolated static func forPointSize(_ pointSize: CGFloat, preferDetail: Bool = false) -> Bucket {
            if preferDetail { return .detail }
            if pointSize <= 128 { return .avatar }
            return .venue
        }
    }

    static let shared = DiscoverMapImageCache()

    private var storage: [Bucket: [URL: UIImage]] = [:]
    /// Coalesces concurrent downloads for the same normalized ``ImageCacheDebug`` cacheKey.
    private var inFlightByCacheKey: [String: Task<UIImage?, Never>] = [:]
    private var imageInvocationSequence: UInt64 = 0
    private var order: [Bucket: [URL]] = [:]
    private let maxEntriesByBucket: [Bucket: Int] = [
        .venue: 96,
        .avatar: 160,
        .detail: 24
    ]

    private init() {
        // Relieve memory pressure by dropping decoded thumbnails/avatars. This is
        // appearance-neutral: on-screen images are separately retained by their
        // SwiftUI views, and any dropped entry is transparently re-fetched/re-decoded
        // to the identical image on next display. In-flight downloads are preserved
        // so awaiting callers are unaffected.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.purgeDecodedImagesForMemoryWarning() }
        }
    }

    /// Drops all cached decoded images (both buckets) on memory pressure. Does not
    /// touch `inFlightByCacheKey`, so current downloads still resolve normally.
    func purgeDecodedImagesForMemoryWarning() {
        let venueCount = storage[.venue]?.count ?? 0
        let avatarCount = storage[.avatar]?.count ?? 0
        let detailCount = storage[.detail]?.count ?? 0
        guard venueCount > 0 || avatarCount > 0 || detailCount > 0 else { return }
        storage.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        DiscoverMapImageMemoryIndex.shared.removeAll()
        ImagePerf.memoryWarningPurged(venues: venueCount, avatars: avatarCount)
    }

    func cachedImage(for url: URL, bucket: Bucket = .venue) -> UIImage? {
        // Strict per-bucket lookup: a listThumbnail decode must never satisfy `.detail`.
        if let hit = storage[bucket]?[url] {
            ImagePerf.memoryCacheHit()
            ImageCacheDebug.logLookup(
                bucket: bucket,
                url: url,
                memoryHit: true,
                diskHit: false,
                networkFetch: false,
                inFlightJoin: false,
                source: "cachedImage"
            )
            return hit
        }
        return nil
    }

    func image(for url: URL, bucket: Bucket = .venue) async -> UIImage? {
        imageInvocationSequence += 1
        let invocationId = imageInvocationSequence
        let actorIdentity = ObjectIdentifier(self)

        if let existing = cachedImage(for: url, bucket: bucket) {
            return existing
        }

        let identity = ImageCacheDebug.diagnosticIdentity(for: url, bucket: bucket)
        let cacheKey = identity.cacheKey
        let normalizedURL = identity.normalizedURL
        ImageCacheDebug.logImageInvocationStart(
            actorIdentity: actorIdentity,
            invocationId: invocationId,
            cacheKey: cacheKey,
            rawURL: url.absoluteString
        )

        let lookupStartedAt = CFAbsoluteTimeGetCurrent()
        let lookupThread = ImageCacheDebug.threadLabelForDiagnostics()
        let activeKeysBeforeLookup = Array(inFlightByCacheKey.keys)
        let existingTask = inFlightByCacheKey[cacheKey]
        let lookupBeforeInsertRaceSuspected = ImageCacheDebug.registerInFlightLookupProbe(
            cacheKey: cacheKey,
            invocationId: invocationId
        )
        ImageCacheDebug.logInFlightLookupConcurrency(
            actorIdentity: actorIdentity,
            invocationId: invocationId,
            cacheKey: cacheKey,
            existingTaskFound: existingTask != nil,
            activeKeys: activeKeysBeforeLookup,
            lookupBeforeInsertRaceSuspected: lookupBeforeInsertRaceSuspected
        )

        if let existingTask {
            ImagePerf.duplicateRequestAvoided()
            ImageCacheDebug.logInFlightJoin(bucket: bucket, url: url, source: "image")
            return await existingTask.value
        }

        ImageCacheDebug.logNewNetworkFetchPath(
            cacheKey: cacheKey,
            inFlightActiveKeysBeforeInsert: activeKeysBeforeLookup,
            rawURL: url.absoluteString,
            normalizedURL: normalizedURL,
            memoryLookupKey: url.absoluteString
        )
        ImageCacheDebug.logLookup(
            bucket: bucket,
            url: url,
            memoryHit: false,
            diskHit: false,
            networkFetch: true,
            inFlightJoin: false,
            source: "image"
        )
        let fetchStartedAt = Date()
        let decodeTarget = bucket.decodeTarget

        inFlightByCacheKey[cacheKey] = Task<UIImage?, Never> { [cacheKey, url, decodeTarget] in
            ImagePerf.downloadStarted()
            ImageCacheDebug.logURLSessionStart(cacheKey: cacheKey, url: url)
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                ImagePerf.downloadCompleted()
                return await Task.detached(priority: .userInitiated) {
                    ImageDecodeDownsampler.uiImage(from: data, target: decodeTarget)
                }.value
            } catch {
                if error is CancellationError { ImagePerf.requestCancelled() }
                return nil
            }
        }
        ImageCacheDebug.registerInFlightInsertProbe(cacheKey: cacheKey, invocationId: invocationId)
        let lookupInsertGapMs = (CFAbsoluteTimeGetCurrent() - lookupStartedAt) * 1000
        ImageCacheDebug.logInFlightInsertConcurrency(
            actorIdentity: actorIdentity,
            invocationId: invocationId,
            cacheKey: cacheKey,
            activeKeys: Array(inFlightByCacheKey.keys),
            lookupThread: lookupThread,
            lookupInsertGapMs: lookupInsertGapMs
        )

        let task = inFlightByCacheKey[cacheKey]!
        let decoded = await task.value
        inFlightByCacheKey[cacheKey] = nil
        ImageCacheDebug.logInFlightRemove(
            cacheKey: cacheKey,
            activeKeys: Array(inFlightByCacheKey.keys)
        )

        let ms = Int(Date().timeIntervalSince(fetchStartedAt) * 1000)
        DebugLogGate.hotPathPerf("[ImageCacheDebug] networkFetchFinished=true ms=\(ms) cacheKey=\(cacheKey)")
        ImageCacheDebug.recordNetworkFetchCompleted(cacheKey: cacheKey)

        guard let ui = decoded else {
            DebugLogGate.hotPathPerf("[ImageCacheDebug] networkFetchFailed=true cacheKey=\(cacheKey)")
            return nil
        }
        storeDecoded(ui, for: url, bucket: bucket)
        return ui
    }

    func prefetch(urls: [URL], bucket: Bucket = .venue) async {
        for url in urls.prefix(8) {
            _ = await image(for: url, bucket: bucket)
        }
    }

    func invalidate(urls: [URL]) {
        let exact = Set(urls)
        let canonicals = Set(
            urls.map { ImageDisplayURL.canonicalStorageURLString($0.absoluteString) }
                .filter { !$0.isEmpty }
        )
        for bucket in maxEntriesByBucket.keys {
            let storedKeys = Array((storage[bucket] ?? [:]).keys)
            let matching = storedKeys.filter { key in
                exact.contains(key)
                    || canonicals.contains(ImageDisplayURL.canonicalStorageURLString(key.absoluteString))
            }
            for key in matching {
                storage[bucket]?[key] = nil
                DiscoverMapImageMemoryIndex.shared.remove(bucket: bucket, url: key)
                let cacheKey = ImageCacheDebug.diagnosticIdentity(for: key, bucket: bucket).cacheKey
                if inFlightByCacheKey[cacheKey] != nil {
                    inFlightByCacheKey[cacheKey]?.cancel()
                    inFlightByCacheKey[cacheKey] = nil
                    ImagePerf.requestCancelled()
                }
            }
            order[bucket]?.removeAll { key in
                exact.contains(key)
                    || canonicals.contains(ImageDisplayURL.canonicalStorageURLString(key.absoluteString))
            }
        }
        for url in exact {
            URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
            let canonical = ImageDisplayURL.canonicalStorageURLString(url.absoluteString)
            if !canonical.isEmpty, let canonicalURL = URL(string: canonical), canonicalURL != url {
                URLCache.shared.removeCachedResponse(for: URLRequest(url: canonicalURL))
            }
        }
    }

    func store(_ image: UIImage, for urls: [URL], bucket: Bucket = .venue) {
        // One decoded image reused across multiple equivalent URLs (no extra decode).
        if urls.count > 1 { ImagePerf.imageReused() }
        for url in urls {
            storeDecoded(image, for: url, bucket: bucket)
        }
    }

    private func storeDecoded(_ image: UIImage, for url: URL, bucket: Bucket) {
        let cacheKey = ImageCacheDebug.diagnosticIdentity(for: url, bucket: bucket).cacheKey
        ImageCacheDebug.recordMemoryStore(cacheKey: cacheKey, memoryStoreKey: url.absoluteString)
        var bucketStorage = storage[bucket] ?? [:]
        var bucketOrder = order[bucket] ?? []
        if bucketStorage[url] == nil {
            let maxEntries = maxEntriesByBucket[bucket] ?? 96
            if bucketStorage.count >= maxEntries, let old = bucketOrder.first {
                bucketStorage.removeValue(forKey: old)
                bucketOrder.removeFirst()
                DiscoverMapImageMemoryIndex.shared.remove(bucket: bucket, url: old)
                ImagePerf.eviction()
            }
            bucketOrder.append(url)
        }
        bucketStorage[url] = image
        storage[bucket] = bucketStorage
        order[bucket] = bucketOrder
        DiscoverMapImageMemoryIndex.shared.store(bucket: bucket, url: url, image: image)
    }

    /// Same decoded image the actor holds, without an actor hop. Used by scroll-recycled cards.
    nonisolated func peekCachedImage(for url: URL, bucket: Bucket = .venue) -> UIImage? {
        DiscoverMapImageMemoryIndex.shared.peek(bucket: bucket, url: url)
    }
}

/// Lock-protected index of the same decoded images ``DiscoverMapImageCache`` stores.
/// Not a second download cache — Profile/Discover scroll can peek without awaiting the actor.
nonisolated private final class DiscoverMapImageMemoryIndex: @unchecked Sendable {
    nonisolated static let shared = DiscoverMapImageMemoryIndex()
    private let lock = NSLock()
    private var images: [String: UIImage] = [:]

    nonisolated private func key(bucket: DiscoverMapImageCache.Bucket, url: URL) -> String {
        ImageCacheDebug.diagnosticIdentity(for: url, bucket: bucket).cacheKey
    }

    nonisolated func peek(bucket: DiscoverMapImageCache.Bucket, url: URL) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key(bucket: bucket, url: url)]
    }

    nonisolated func store(bucket: DiscoverMapImageCache.Bucket, url: URL, image: UIImage) {
        lock.lock()
        images[key(bucket: bucket, url: url)] = image
        lock.unlock()
    }

    nonisolated func remove(bucket: DiscoverMapImageCache.Bucket, url: URL) {
        lock.lock()
        images.removeValue(forKey: key(bucket: bucket, url: url))
        lock.unlock()
    }

    nonisolated func removeAll() {
        lock.lock()
        images.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

/// Load phase for remote images that previously used `AsyncImage` phase switches.
/// Visuals (placeholder, failure, fade, crop) stay at each call site.
enum CachedRemoteImageLoadPhase {
    case empty
    case success(UIImage)
    case failure
}

/// Shared-cache remote loader that delivers AsyncImage-equivalent phases without
/// applying fades, frames, or placeholders of its own.
struct CachedRemoteImagePhaseView<Content: View>: View {
    let url: URL?
    var bucket: DiscoverMapImageCache.Bucket = .venue
    @ViewBuilder var content: (CachedRemoteImageLoadPhase) -> Content

    @State private var phase: CachedRemoteImageLoadPhase = .empty
    @State private var loadToken: UInt64 = 0

    var body: some View {
        content(phase)
            .task(id: url?.absoluteString ?? "") {
                let requestedURL = url
                guard let requestedURL else {
                    if case .empty = phase { return }
                    phase = .empty
                    return
                }

                if let peeked = DiscoverMapImageCache.shared.peekCachedImage(for: requestedURL, bucket: bucket) {
                    applySuccessIfNeeded(peeked)
                    return
                }

                let token = loadToken &+ 1
                loadToken = token

                if let cached = await DiscoverMapImageCache.shared.cachedImage(for: requestedURL, bucket: bucket) {
                    guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
                    applySuccessIfNeeded(cached)
                    return
                }

                if let loaded = await DiscoverMapImageCache.shared.image(for: requestedURL, bucket: bucket) {
                    guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
                    applySuccessIfNeeded(loaded)
                } else {
                    guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
                    if case .failure = phase { return }
                    phase = .failure
                }
            }
    }

    private func isCurrentLoad(token: UInt64, requestedURL: URL) -> Bool {
        if Task.isCancelled {
            ImagePerf.waiterCancelled()
            return false
        }
        if loadToken != token || url != requestedURL {
            ImagePerf.staleResultRejected()
            return false
        }
        return true
    }

    private func applySuccessIfNeeded(_ image: UIImage) {
        if case .success(let existing) = phase, existing === image {
            return
        }
        phase = .success(image)
    }
}

/// Loads a remote image with RAM cache; keeps layout stable with an intentional placeholder (non-blocking).
struct VenuePhotoDebugContext {
    let venueId: UUID
    let venueName: String
    let selectedMainPhotoURL: String?
    let selectedSecondaryPhotoURL: String?
}

struct DiscoverCachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var bucket: DiscoverMapImageCache.Bucket = .venue
    var venuePhotoDebugContext: VenuePhotoDebugContext? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var loadedImageVisible = false
    @State private var loadToken: UInt64 = 0

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .opacity(loadedImageVisible ? 1 : 0)
            } else {
                placeholder()
            }
        }
        .task(id: url?.absoluteString) {
            let requestedURL = url
            guard let requestedURL else {
                uiImage = nil
                loadedImageVisible = false
                return
            }

            if let peeked = DiscoverMapImageCache.shared.peekCachedImage(for: requestedURL, bucket: bucket) {
                if uiImage !== peeked {
                    uiImage = peeked
                }
                loadedImageVisible = true
                return
            }

            let token = loadToken &+ 1
            loadToken = token

            if let cached = await DiscoverMapImageCache.shared.cachedImage(for: requestedURL, bucket: bucket) {
                guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
                if uiImage !== cached {
                    uiImage = cached
                }
                loadedImageVisible = true
                return
            }

            if let loaded = await DiscoverMapImageCache.shared.image(for: requestedURL, bucket: bucket) {
                guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
                if uiImage !== loaded {
                    uiImage = loaded
                }
                loadedImageVisible = true
            } else {
                guard isCurrentLoad(token: token, requestedURL: requestedURL) else { return }
                uiImage = nil
                loadedImageVisible = false
#if DEBUG
                if let context = venuePhotoDebugContext {
                    print("[VenuePhotoDebug] venueId=\(context.venueId.uuidString.lowercased())")
                    print("[VenuePhotoDebug] venueName=\(context.venueName)")
                    print("[VenuePhotoDebug] selectedMainPhotoURL=\(context.selectedMainPhotoURL ?? "")")
                    print("[VenuePhotoDebug] selectedSecondaryPhotoURL=\(context.selectedSecondaryPhotoURL ?? "")")
                    print("[VenuePhotoDebug] imageLoadFailed=\(requestedURL.absoluteString)")
                }
#endif
            }
        }
    }

    private func isCurrentLoad(token: UInt64, requestedURL: URL) -> Bool {
        if Task.isCancelled {
            ImagePerf.waiterCancelled()
            return false
        }
        if loadToken != token || url != requestedURL {
            ImagePerf.staleResultRejected()
            return false
        }
        return true
    }
}

extension MapViewModel {
    /// Warms the Discover image cache for thumbnails. Menu URLs are optional (heavier / rarely shown on the map card).
    func prefetchDiscoverVenueImages(for bar: BarVenue, includeMenu: Bool = false) async {
        var urls: [URL] = []
        if let s = ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL),
           let u = URL(string: s) {
            urls.append(u)
        }
        if includeMenu,
           let s = ImageDisplayURL.forList(thumbnail: bar.menuPhotoThumbnailURL, full: bar.menuPhotoURL),
           let u = URL(string: s) {
            urls.append(u)
        }
        await DiscoverMapImageCache.shared.prefetch(urls: urls)
    }
}

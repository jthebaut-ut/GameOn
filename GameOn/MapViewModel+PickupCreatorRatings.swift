import Foundation
import Supabase

extension MapViewModel {

    func pickupCreatorTrustStats(for creatorUserId: UUID) -> PickupCreatorPublicRatingStats? {
        pickupCreatorPublicRatingStatsByUserId[creatorUserId]
    }

    /// Authoritative hosted + rating aggregates for Discover / detail (same RPC as public profile).
    func pickupOrganizerSummary(for creatorUserId: UUID) -> PickupOrganizerSummary? {
        pickupOrganizerSummaryByUserId[creatorUserId]
    }

    private static let pickupOrganizerSummaryFreshnessInterval: TimeInterval = 5 * 60
    /// Account-appear reuse window for the signed-in user's own organizer summary. Mutations
    /// (create/cancel/rate/hosted-games reload) still force a refresh outside this window.
    private static let myPickupOrganizerSummaryAppearFreshnessInterval: TimeInterval = 5 * 60

    @MainActor
    func isPickupOrganizerSummaryFresh(for creatorUserId: UUID, now: Date = Date()) -> Bool {
        guard pickupOrganizerSummaryByUserId[creatorUserId] != nil,
              let fetchedAt = pickupOrganizerSummaryFetchedAtByUserId[creatorUserId] else {
            return false
        }
        return now.timeIntervalSince(fetchedAt) < Self.pickupOrganizerSummaryFreshnessInterval
    }

    func hasSubmittedPickupCreatorRating(for pickupGameId: UUID) -> Bool {
        pickupGameIdsWithMyCreatorRating.contains(pickupGameId)
    }

    func myPickupCreatorRatingValue(for pickupGameId: UUID) -> Int? {
        pickupMyCreatorRatingValueByGameId[pickupGameId]
    }

    func myPickupCreatorRatingCreatedAt(for pickupGameId: UUID) -> Date? {
        pickupMyCreatorRatingCreatedAtByGameId[pickupGameId]
    }

    /// Deadline for automatic Going → Playing removal after a successful organizer rating.
    func pickupPlayingAutoClearDeadline(for pickupGameId: UUID) -> Date? {
        guard hasSubmittedPickupCreatorRating(for: pickupGameId),
              let ratedAt = myPickupCreatorRatingCreatedAt(for: pickupGameId) else {
            return nil
        }
        return GoingPickupPlayingCompletedVisibility.autoClearDeadline(ratedAt: ratedAt)
    }

    @MainActor
    func acknowledgePickupCreatorRatingPostSubmitPrompt(pickupGameId: UUID) {
        pickupCreatorRatingPostSubmitPromptGameIds.remove(pickupGameId)
    }

    func isPickupCreatorRatingDeferred(for pickupGameId: UUID) -> Bool {
        pickupCreatorRatingDeferredGameIds.contains(pickupGameId)
    }

    /// Clears session-scoped rating UI state (logout / account switch).
    @MainActor
    func clearPickupCreatorRatingSessionState(reason: String) {
        pickupGameIdsWithMyCreatorRating = []
        pickupMyCreatorRatingValueByGameId = [:]
        pickupMyCreatorRatingCreatedAtByGameId = [:]
        pickupCreatorRatingPostSubmitPromptGameIds = []
        pickupCreatorRatingDeferredGameIds = []
        pickupCreatorRatingSessionUserId = nil
        PickupCreatorRatingDebug.lifecycle("stale-session result ignored", details: "reason=\(reason)")
    }

    /// Ensures rating caches are keyed to the current authenticated user.
    @MainActor
    func ensurePickupCreatorRatingSessionScoped() {
        guard let uid = currentUserAuthId else {
            if pickupCreatorRatingSessionUserId != nil
                || !pickupCreatorRatingDeferredGameIds.isEmpty
                || !pickupGameIdsWithMyCreatorRating.isEmpty
                || !pickupMyCreatorRatingCreatedAtByGameId.isEmpty
                || !pickupCreatorRatingPostSubmitPromptGameIds.isEmpty {
                clearPickupCreatorRatingSessionState(reason: "signed_out")
            }
            return
        }
        if pickupCreatorRatingSessionUserId != uid {
            pickupGameIdsWithMyCreatorRating = []
            pickupMyCreatorRatingValueByGameId = [:]
            pickupMyCreatorRatingCreatedAtByGameId = [:]
            pickupCreatorRatingPostSubmitPromptGameIds = []
            pickupCreatorRatingDeferredGameIds = []
            pickupCreatorRatingSessionUserId = uid
            PickupCreatorRatingDebug.lifecycle("stale-session result ignored", details: "reason=account_switch")
        }
    }

    @MainActor
    func deferPickupCreatorRatingPrompt(pickupGameId: UUID) {
        ensurePickupCreatorRatingSessionScoped()
        pickupCreatorRatingDeferredGameIds.insert(pickupGameId)
        PickupCreatorRatingDebug.lifecycle("prompt deferred", details: "reason=not_now")
    }

    @MainActor
    func undefferPickupCreatorRatingPrompt(pickupGameId: UUID) {
        pickupCreatorRatingDeferredGameIds.remove(pickupGameId)
    }

    /// Client gate mirroring backend eligibility (approved joiner, not organizer, completed end).
    /// Does not mutate session state — safe to call from SwiftUI body.
    func pickupCreatorRatingEligibility(
        game: PickupGameRow,
        joinStatus: String?,
        now: Date = Date()
    ) -> (eligible: Bool, reason: String) {
        guard let uid = currentUserAuthId else {
            return (false, "not_authenticated")
        }
        if let scoped = pickupCreatorRatingSessionUserId, scoped != uid {
            return (false, "stale_session")
        }
        if game.creator_user_id == uid {
            return (false, "is_organizer")
        }
        let st = (joinStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch st {
        case "approved":
            break
        case "pending":
            return (false, "join_pending")
        case "rejected", "declined":
            return (false, "join_declined")
        case "cancelled", "canceled", "withdrawn":
            return (false, "join_removed_or_canceled")
        case "":
            return (false, "never_joined")
        default:
            return (false, "join_ineligible")
        }
        if !game.isPickupCreatorRatingPromptEligible(now: now) {
            if game.hasPickupGameStarted(now: now) {
                return (false, "in_progress")
            }
            return (false, "not_completed")
        }
        if hasSubmittedPickupCreatorRating(for: game.id) {
            return (false, "already_rated")
        }
        return (true, "eligible")
    }

    /// Full inline prompt (stars + submit) when eligible and not deferred this session.
    func shouldPresentPickupCreatorRatingPrompt(
        game: PickupGameRow,
        joinStatus: String?,
        now: Date = Date()
    ) -> Bool {
        let eval = pickupCreatorRatingEligibility(game: game, joinStatus: joinStatus, now: now)
        PickupCreatorRatingDebug.lifecycle(
            "completed game evaluated",
            details: "eligible=\(eval.eligible) reason=\(eval.reason)"
        )
        guard eval.eligible else { return false }
        if isPickupCreatorRatingDeferred(for: game.id) {
            PickupCreatorRatingDebug.lifecycle("prompt deferred", details: "reason=session_not_now")
            return false
        }
        PickupCreatorRatingDebug.lifecycle("unrated eligible game found")
        return true
    }

    /// Compact “Rate organizer” after Not now, or when prompt is hidden but still eligible.
    func shouldShowPickupCreatorRateOrganizerAction(
        game: PickupGameRow,
        joinStatus: String?,
        now: Date = Date()
    ) -> Bool {
        let eval = pickupCreatorRatingEligibility(game: game, joinStatus: joinStatus, now: now)
        return eval.eligible
    }

    /// Loads aggregate organizer stats and whether the current user already rated this game (Following / Discover detail).
    func refreshPickupCreatorRatingUIContext(pickupGameId: UUID, creatorUserId: UUID) async {
        await refreshPickupOrganizerSummaries(userIds: [creatorUserId])
        await refreshMyPickupCreatorRatingsForPickupGames(pickupGameIds: [pickupGameId])
    }

    /// Fetches hosted + rating aggregates for Discover map cards / detail (batched, cached, no clear-while-refresh).
    func refreshPickupOrganizerSummaries(userIds: [UUID], force: Bool = false) async {
        let unique = Array(Set(userIds))
        guard !unique.isEmpty else { return }

        let now = Date()
        let planned: [(uid: UUID, generation: UInt64)] = await MainActor.run {
            unique.compactMap { uid -> (UUID, UInt64)? in
                if !force {
                    if pickupOrganizerSummaryInFlightUserIds.contains(uid) {
                        return nil
                    }
                    if isPickupOrganizerSummaryFresh(for: uid, now: now) {
                        return nil
                    }
                }
                let next = (pickupOrganizerSummaryFetchGenerationByUserId[uid] ?? 0) &+ 1
                pickupOrganizerSummaryFetchGenerationByUserId[uid] = next
                pickupOrganizerSummaryInFlightUserIds.insert(uid)
                return (uid, next)
            }
        }
        guard !planned.isEmpty else {
            if force {
                PickupOrganizerTrustDebug.lifecycle("forced refresh coalesced", details: "count=\(unique.count)")
            } else {
                PickupOrganizerTrustDebug.lifecycle("organizer statistics served from cache", details: "count=\(unique.count)")
            }
            return
        }

        let toFetch = planned.map(\.uid)
        let generationByUserId = Dictionary(uniqueKeysWithValues: planned.map { ($0.uid, $0.generation) })
        PickupOrganizerTrustDebug.lifecycle(
            force ? "forced refresh started" : "batched organizer statistics requested",
            details: "count=\(toFetch.count)"
        )

        do {
            let rows = try await Self.fetchPickupOrganizerProfileSummariesBatch(userIds: toFetch)
            await MainActor.run {
                let sessionUid = self.currentUserAuthId
                for uid in toFetch {
                    if self.pickupOrganizerSummaryFetchGenerationByUserId[uid] == generationByUserId[uid] {
                        self.pickupOrganizerSummaryInFlightUserIds.remove(uid)
                    }
                }
                guard sessionUid == self.currentUserAuthId else {
                    PickupOrganizerTrustDebug.lifecycle("stale session result ignored", details: "reason=batch")
                    return
                }
                for (uid, summary) in rows {
                    guard self.pickupOrganizerSummaryFetchGenerationByUserId[uid] == generationByUserId[uid] else {
                        PickupOrganizerTrustDebug.lifecycle("stale summary response rejected", details: "path=batch")
                        continue
                    }
                    self.applyCachedPickupOrganizerSummary(summary, userId: uid, fetchedAt: Date())
                    PickupOrganizerTrustDebug.logResolved(summary: summary)
                }
                let missing = Set(toFetch).subtracting(rows.keys)
                for uid in missing {
                    guard self.pickupOrganizerSummaryFetchGenerationByUserId[uid] == generationByUserId[uid] else {
                        PickupOrganizerTrustDebug.lifecycle("stale summary response rejected", details: "path=batch_missing")
                        continue
                    }
                    // Preserve any prior visible value; only seed empty when nothing cached.
                    if self.pickupOrganizerSummaryByUserId[uid] == nil {
                        self.applyCachedPickupOrganizerSummary(.empty, userId: uid, fetchedAt: Date())
                        PickupOrganizerTrustDebug.lifecycle("no-rating state resolved", details: "hosted=0")
                    }
                }
            }
        } catch {
            let msg = String(describing: error).lowercased()
            let batchMissing = msg.contains("could not find the function")
                || msg.contains("pgrst202")
                || msg.contains("pickup_organizer_profile_summaries")
            if batchMissing {
                await refreshPickupOrganizerSummariesViaSingleRPC(
                    userIds: toFetch,
                    generationByUserId: generationByUserId
                )
            } else {
                await MainActor.run {
                    for uid in toFetch {
                        if self.pickupOrganizerSummaryFetchGenerationByUserId[uid] == generationByUserId[uid] {
                            self.pickupOrganizerSummaryInFlightUserIds.remove(uid)
                        }
                    }
                }
                PickupOrganizerTrustDebug.lifecycle("statistics request failed", details: "reason=batch_error")
                PickupCreatorRatingDebug.lifecycle("organizer summary refresh failed", details: "reason=batch_error")
#if DEBUG
                print("[PickupOrganizerTrust] batch failed:", error)
#endif
            }
        }
    }

    private func refreshPickupOrganizerSummariesViaSingleRPC(
        userIds: [UUID],
        generationByUserId: [UUID: UInt64] = [:]
    ) async {
        PickupOrganizerTrustDebug.lifecycle("batched organizer statistics requested", details: "path=single_rpc count=\(userIds.count)")
        var pairs: [(UUID, PickupOrganizerSummary?)] = []
        pairs.reserveCapacity(userIds.count)
        await withTaskGroup(of: (UUID, PickupOrganizerSummary?).self) { group in
            for uid in userIds {
                group.addTask {
                    do {
                        let summary = try await Self.fetchPickupOrganizerProfileSummary(userId: uid)
                        return (uid, summary)
                    } catch {
                        return (uid, nil)
                    }
                }
            }
            for await p in group {
                pairs.append(p)
            }
        }
        await MainActor.run {
            let sessionUid = self.currentUserAuthId
            for uid in userIds {
                let expected = generationByUserId[uid]
                if expected == nil || self.pickupOrganizerSummaryFetchGenerationByUserId[uid] == expected {
                    self.pickupOrganizerSummaryInFlightUserIds.remove(uid)
                }
            }
            guard sessionUid == self.currentUserAuthId else {
                PickupOrganizerTrustDebug.lifecycle("stale session result ignored", details: "reason=single_rpc")
                return
            }
            for (uid, summary) in pairs {
                if let expected = generationByUserId[uid],
                   self.pickupOrganizerSummaryFetchGenerationByUserId[uid] != expected {
                    PickupOrganizerTrustDebug.lifecycle("stale summary response rejected", details: "path=single_rpc")
                    continue
                }
                if let summary {
                    self.applyCachedPickupOrganizerSummary(summary, userId: uid, fetchedAt: Date())
                    PickupOrganizerTrustDebug.logResolved(summary: summary)
                } else {
                    PickupOrganizerTrustDebug.lifecycle("statistics request failed", details: "reason=single_rpc")
                }
            }
        }
    }

    @MainActor
    private func applyCachedPickupOrganizerSummary(_ summary: PickupOrganizerSummary, userId: UUID, fetchedAt: Date) {
        if let prior = pickupOrganizerSummaryByUserId[userId], prior == summary {
            pickupOrganizerSummaryFetchedAtByUserId[userId] = fetchedAt
            PickupOrganizerTrustDebug.lifecycle(
                "identical summary skipped",
                details: "hosted=\(summary.hostedCount) ratings=\(summary.ratingCount)"
            )
            pickupCreatorPublicRatingStatsByUserId[userId] = PickupCreatorPublicRatingStats(
                avgRating: summary.averageRating ?? 0,
                ratingCount: summary.ratingCount
            )
            return
        }
        if let prior = pickupOrganizerSummaryByUserId[userId],
           prior.ratingCount != summary.ratingCount
            || abs((prior.averageRating ?? -1) - (summary.averageRating ?? -1)) > 0.001
            || prior.hostedCount != summary.hostedCount {
            // Detect profile vs card drift only when both sides are loaded for the same user.
            if myPickupOrganizerSummaryLoadedForUserId == userId {
                let own = myPickupOrganizerSummary
                if own.ratingCount != summary.ratingCount || own.hostedCount != summary.hostedCount {
                    PickupOrganizerTrustDebug.lifecycle(
                        "public-profile and card aggregate mismatch detected",
                        details: "hostedDelta=\(own.hostedCount - summary.hostedCount) ratingDelta=\(own.ratingCount - summary.ratingCount)"
                    )
                }
            }
        }
        pickupOrganizerSummaryByUserId[userId] = summary
        pickupOrganizerSummaryFetchedAtByUserId[userId] = fetchedAt
        pickupCreatorPublicRatingStatsByUserId[userId] = PickupCreatorPublicRatingStats(
            avgRating: summary.averageRating ?? 0,
            ratingCount: summary.ratingCount
        )
        PickupOrganizerTrustDebug.lifecycle(
            "refreshed summary published",
            details: "hosted=\(summary.hostedCount) ratings=\(summary.ratingCount)"
        )
    }

    /// Invalidates freshness for one organizer and force-refetches the authoritative summary.
    /// Keeps the last visible summary until the new one arrives (avoids flashing “No ratings yet”).
    func invalidateAndRefreshPickupOrganizerSummaryAfterRating(
        creatorUserId: UUID,
        rpcAverageRating: Double? = nil,
        rpcRatingCount: Int? = nil
    ) async {
        await MainActor.run {
            let next = (pickupOrganizerSummaryFetchGenerationByUserId[creatorUserId] ?? 0) &+ 1
            pickupOrganizerSummaryFetchGenerationByUserId[creatorUserId] = next
            pickupOrganizerSummaryInFlightUserIds.remove(creatorUserId)
            pickupOrganizerSummaryFetchedAtByUserId.removeValue(forKey: creatorUserId)
            PickupOrganizerTrustDebug.lifecycle("organizer summary invalidated", details: "reason=rating_submit")
            PickupCreatorRatingDebug.lifecycle("organizer summary invalidated", details: "reason=rating_submit")

            if let rpcRatingCount {
                let prior = pickupOrganizerSummaryByUserId[creatorUserId]
                let patched = PickupOrganizerSummary(
                    hostedCount: prior?.hostedCount ?? 0,
                    averageRating: rpcAverageRating,
                    ratingCount: max(0, rpcRatingCount),
                    lastPickupGameCreatedAt: prior?.lastPickupGameCreatedAt
                )
                applyCachedPickupOrganizerSummary(patched, userId: creatorUserId, fetchedAt: .distantPast)
                PickupCreatorRatingDebug.lifecycle(
                    "organizer summary patched from submit rpc",
                    details: "ratings=\(rpcRatingCount)"
                )
            }
        }

        await refreshPickupOrganizerSummaries(userIds: [creatorUserId], force: true)
    }

    /// Fetches `pickup_creator_public_rating_stats` for the organizer; retries once if the cache is still empty (network / decode hiccup).
    func loadPickupOrganizerTrustStatsForPickupDetail(creatorUserId: UUID) async {
        await refreshPickupOrganizerSummaries(userIds: [creatorUserId])
        if pickupOrganizerSummary(for: creatorUserId) == nil {
            await refreshPickupOrganizerSummaries(userIds: [creatorUserId], force: true)
        }
        await MainActor.run {
            if self.pickupOrganizerSummary(for: creatorUserId) == nil {
                self.applyCachedPickupOrganizerSummary(.empty, userId: creatorUserId, fetchedAt: Date())
            }
#if DEBUG
            PickupOrganizerRatingDebug.log(
                creatorUserId: creatorUserId,
                stats: self.pickupCreatorTrustStats(for: creatorUserId)
            )
#endif
        }
    }

    func refreshPickupCreatorPublicRatingStats(creatorUserIds: [UUID]) async {
        let unique = Array(Set(creatorUserIds))
        guard !unique.isEmpty else { return }

        var pairs: [(UUID, PickupCreatorPublicRatingStats?)] = []
        pairs.reserveCapacity(unique.count)
        await withTaskGroup(of: (UUID, PickupCreatorPublicRatingStats?).self) { group in
            for cid in unique {
                group.addTask {
                    let stats = await Self.fetchPickupCreatorPublicRatingStats(for: cid)
                    return (cid, stats)
                }
            }
            for await p in group {
                pairs.append(p)
            }
        }

        await MainActor.run {
            for (cid, stats) in pairs {
                if let stats {
                    self.pickupCreatorPublicRatingStatsByUserId[cid] = stats
                } else {
                    self.pickupCreatorPublicRatingStatsByUserId.removeValue(forKey: cid)
                }
            }
        }
    }

    /// Clears cached aggregates for the given creators, then refetches (e.g. after submitting a rating).
    func refreshPickupCreatorPublicRatingStatsForcing(creatorUserIds: [UUID]) async {
        let unique = Array(Set(creatorUserIds))
        guard !unique.isEmpty else { return }
        for cid in unique {
            await invalidateAndRefreshPickupOrganizerSummaryAfterRating(creatorUserId: cid)
        }
    }

    func refreshMyPickupCreatorRatingsForPickupGames(pickupGameIds: [UUID]) async {
        await MainActor.run { ensurePickupCreatorRatingSessionScoped() }
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            await MainActor.run {
                pickupGameIdsWithMyCreatorRating = []
                pickupMyCreatorRatingValueByGameId = [:]
                pickupMyCreatorRatingCreatedAtByGameId = [:]
            }
            return
        }
        let unique = Array(Set(pickupGameIds))
        guard !unique.isEmpty else { return }

        struct RatingRow: Decodable {
            let pickup_game_id: UUID
            let rating: Int
            let created_at: String?
        }

        do {
            let rows: [RatingRow] = try await supabase
                .from("pickup_game_creator_ratings")
                .select("pickup_game_id,rating,created_at")
                .eq("rater_user_id", value: uid.uuidString.lowercased())
                .in("pickup_game_id", values: unique.map { $0.uuidString.lowercased() })
                .execute()
                .value
            await MainActor.run {
                self.ensurePickupCreatorRatingSessionScoped()
                guard self.currentUserAuthId == uid else {
                    PickupCreatorRatingDebug.lifecycle("stale-session result ignored", details: "reason=ratings_fetch")
                    return
                }
                for row in rows {
                    self.pickupGameIdsWithMyCreatorRating.insert(row.pickup_game_id)
                    self.pickupMyCreatorRatingValueByGameId[row.pickup_game_id] = row.rating
                    if let raw = row.created_at,
                       let created = PickupGameModels.parseSupabaseTimestamptz(raw) {
                        self.pickupMyCreatorRatingCreatedAtByGameId[row.pickup_game_id] = created
                    }
                }
            }
        } catch {
#if DEBUG
            print("[PickupCreatorRating] load existing ratings failed:", error)
#endif
        }
    }

    @discardableResult
    func submitPickupCreatorRating(
        pickupGameId: UUID,
        creatorUserId: UUID,
        rating: Int,
        feedback: String?
    ) async -> Bool {
        await MainActor.run { ensurePickupCreatorRatingSessionScoped() }
        guard let rater = currentUserAuthId else {
            PickupCreatorRatingDebug.lifecycle("rating submission failed", details: "reason=not_authenticated")
            return false
        }

        let clamped = min(5, max(1, rating))
        guard clamped == rating, rating >= 1, rating <= 5 else {
            PickupCreatorRatingDebug.lifecycle("rating submission failed", details: "reason=out_of_range")
            return false
        }

        let trimmedFeedback = feedback?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(1000)
        let feedbackOut: String? = (trimmedFeedback?.isEmpty == true) ? nil : trimmedFeedback.map(String.init)

        let alreadyRated = hasSubmittedPickupCreatorRating(for: pickupGameId)
        PickupCreatorRatingDebug.lifecycle("rating submission started", details: "stars=\(clamped)")

        struct Params: Encodable {
            let p_pickup_game_id: UUID
            let p_rating: Int
            let p_feedback: String?
        }
        struct ResultRow: Decodable {
            let outcome: String?
            let already_rated: Bool?
            let rating: Int?
            let organizer_avg_rating: PickupRPCNumericOrString?
            let organizer_rating_count: Int64?
        }

        do {
            let rows: [ResultRow] = try await supabase
                .rpc(
                    "submit_pickup_creator_rating",
                    params: Params(
                        p_pickup_game_id: pickupGameId,
                        p_rating: clamped,
                        p_feedback: feedbackOut
                    )
                )
                .execute()
                .value

            guard let row = rows.first else {
                PickupCreatorRatingDebug.lifecycle("rating submission failed", details: "reason=empty_rpc")
                return false
            }

            let outcome = (row.outcome ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let dup = row.already_rated == true || outcome == "already_rated"
            let savedStars = row.rating ?? clamped

            await MainActor.run {
                self.ensurePickupCreatorRatingSessionScoped()
                guard self.currentUserAuthId == rater else {
                    PickupCreatorRatingDebug.lifecycle("stale-session result ignored", details: "reason=submit")
                    return
                }
                self.pickupGameIdsWithMyCreatorRating.insert(pickupGameId)
                self.pickupMyCreatorRatingValueByGameId[pickupGameId] = savedStars
                if self.pickupMyCreatorRatingCreatedAtByGameId[pickupGameId] == nil {
                    self.pickupMyCreatorRatingCreatedAtByGameId[pickupGameId] = Date()
                }
                self.pickupCreatorRatingDeferredGameIds.remove(pickupGameId)
                if !alreadyRated, !dup {
                    self.pickupCreatorRatingPostSubmitPromptGameIds.insert(pickupGameId)
                }
            }

            PickupCreatorRatingDebug.lifecycle("rating submit succeeded", details: "stars=\(savedStars)")
            let rpcCount = row.organizer_rating_count.map { Int($0) }
            let rpcAvg = row.organizer_avg_rating?.doubleValue
            await invalidateAndRefreshPickupOrganizerSummaryAfterRating(
                creatorUserId: creatorUserId,
                rpcAverageRating: rpcAvg,
                rpcRatingCount: rpcCount
            )

            if creatorUserId == currentUserAuthId {
                myPickupOrganizerSummaryLoadedForUserId = nil
                await refreshMyPickupOrganizerSummary(force: true)
            }

            if dup {
                PickupCreatorRatingDebug.lifecycle("duplicate rating rejected")
            } else {
                PickupCreatorRatingDebug.lifecycle("backend accepted rating")
            }

            if !alreadyRated, !dup {
                await awardFanXP(
                    source: FanXPSource.pickupComplete,
                    sourceId: pickupGameId
                )
            }
            await cancelPickupCreatorRatingReminder(pickupGameId: pickupGameId)
            return true
        } catch {
            // Age denial first: Postgres CONTEXT can also include the function name.
            if AgeAccessBackendDenial.handle(error, requestUserId: rater) {
                PickupCreatorRatingDebug.lifecycle("rating submission failed", details: "reason=age_access_denied")
                return false
            }
            let msg = String(describing: error).lowercased()
            let rpcMissing = msg.contains("could not find the function")
                || msg.contains("pgrst202")
                || msg.contains("submit_pickup_creator_rating")
            if rpcMissing {
                return await submitPickupCreatorRatingLegacyFallback(
                    pickupGameId: pickupGameId,
                    creatorUserId: creatorUserId,
                    rating: clamped,
                    feedback: feedbackOut,
                    rater: rater,
                    alreadyRated: alreadyRated
                )
            }
            let dup = msg.contains("duplicate") || msg.contains("unique") || msg.contains("23505") || msg.contains("already_rated")
            PickupCreatorRatingDebug.lifecycle(
                dup ? "duplicate rating rejected" : "rating submission failed",
                details: "reason=rpc_error"
            )
            if dup {
                // Already on MainActor (MapViewModel); Set.insert's result is discardable.
                pickupGameIdsWithMyCreatorRating.insert(pickupGameId)
                return true
            }
            return false
        }
    }

    /// Pre-migration fallback: direct insert (no upsert) against tightened RLS when present.
    private func submitPickupCreatorRatingLegacyFallback(
        pickupGameId: UUID,
        creatorUserId: UUID,
        rating: Int,
        feedback: String?,
        rater: UUID,
        alreadyRated: Bool
    ) async -> Bool {
        PickupCreatorRatingDebug.lifecycle("rating submission started", details: "path=legacy_insert")
        let payload = PickupGameCreatorRatingUpsert(
            pickup_game_id: pickupGameId,
            creator_user_id: creatorUserId,
            rater_user_id: rater,
            rating: rating,
            feedback: feedback
        )
        do {
            try await supabase
                .from("pickup_game_creator_ratings")
                .insert(payload)
                .execute()
            await MainActor.run {
                guard self.currentUserAuthId == rater else {
                    PickupCreatorRatingDebug.lifecycle("stale-session result ignored", details: "reason=legacy_submit")
                    return
                }
                self.pickupGameIdsWithMyCreatorRating.insert(pickupGameId)
                self.pickupMyCreatorRatingValueByGameId[pickupGameId] = rating
                if self.pickupMyCreatorRatingCreatedAtByGameId[pickupGameId] == nil {
                    self.pickupMyCreatorRatingCreatedAtByGameId[pickupGameId] = Date()
                }
                self.pickupCreatorRatingDeferredGameIds.remove(pickupGameId)
                if !alreadyRated {
                    self.pickupCreatorRatingPostSubmitPromptGameIds.insert(pickupGameId)
                }
            }
            PickupCreatorRatingDebug.lifecycle("rating submit succeeded", details: "path=legacy_insert")
            await invalidateAndRefreshPickupOrganizerSummaryAfterRating(creatorUserId: creatorUserId)
            PickupCreatorRatingDebug.lifecycle("backend accepted rating")
            if !alreadyRated {
                await awardFanXP(
                    source: FanXPSource.pickupComplete,
                    sourceId: pickupGameId
                )
            }
            await cancelPickupCreatorRatingReminder(pickupGameId: pickupGameId)
            return true
        } catch {
            let msg = String(describing: error).lowercased()
            let dup = msg.contains("duplicate") || msg.contains("unique") || msg.contains("23505")
            if dup {
                // Already on MainActor (MapViewModel); Set.insert's result is discardable.
                pickupGameIdsWithMyCreatorRating.insert(pickupGameId)
                PickupCreatorRatingDebug.lifecycle("duplicate rating rejected")
                await cancelPickupCreatorRatingReminder(pickupGameId: pickupGameId)
                return true
            }
            PickupCreatorRatingDebug.lifecycle("rating submission failed", details: "reason=legacy_insert")
            return false
        }
    }

    nonisolated private static func fetchPickupCreatorPublicRatingStats(for creatorUserId: UUID) async -> PickupCreatorPublicRatingStats? {
        struct Params: Encodable {
            let p_creator_user_id: UUID
        }
        do {
            let rows: [PickupCreatorPublicRatingStatsRPCRow] = try await supabase
                .rpc("pickup_creator_public_rating_stats", params: Params(p_creator_user_id: creatorUserId))
                .execute()
                .value
            if let first = rows.first, let stats = first.toPublicStats() {
                return stats
            }
            return PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        } catch {
#if DEBUG
            print("[PickupCreatorRating] RPC stats failed creator=\(creatorUserId):", error)
#endif
            return nil
        }
    }

    /// Account-appear entry point: reuses cached aggregates within a freshness window so
    /// repeated Account visits don't re-hit the organizer-summary RPC. Explicit mutations still
    /// call ``refreshMyPickupOrganizerSummary(force:)`` directly and bypass this window.
    @MainActor
    func refreshMyPickupOrganizerSummaryOnAppearIfStale() async {
        if let uid = currentUserAuthId,
           myPickupOrganizerSummaryLoadedForUserId == uid,
           let last = lastMyPickupOrganizerSummaryRefreshAt {
            let age = Date().timeIntervalSince(last)
            if age < Self.myPickupOrganizerSummaryAppearFreshnessInterval {
                AccountActivationPerf.refreshSkippedFresh(
                    name: "myPickupOrganizerSummary",
                    ageMs: Int(age * 1000)
                )
                return
            }
        }
        AccountActivationPerf.refreshForced(name: "myPickupOrganizerSummary", reason: "appearStale")
        await refreshMyPickupOrganizerSummary(force: true)
    }

    /// Loads hosted + organizer rating aggregates for the signed-in user (one RPC).
    @MainActor
    func refreshMyPickupOrganizerSummary(force: Bool = false) async {
        guard let uid = currentUserAuthId else {
            myPickupOrganizerSummary = .empty
            myPickupOrganizerSummaryLoadedForUserId = nil
            return
        }
        if !force, myPickupOrganizerSummaryLoadedForUserId == uid {
            return
        }
        do {
            let summary = try await Self.fetchPickupOrganizerProfileSummary(userId: uid)
            applyMyPickupOrganizerSummary(summary, userId: uid)
        } catch {
#if DEBUG
            print("[PickupOrganizerSummary] rpc unavailable; falling back. error=\(error.localizedDescription)")
#endif
            await refreshPickupCreatorPublicRatingStatsForcing(creatorUserIds: [uid])
            let stats = pickupCreatorTrustStats(for: uid)
            let hostedRows = myPickupGamesForSettings + myRemovedPickupGamesForSettings
            let hosted = hostedRows.count
            let lastCreated = hostedRows
                .compactMap { row -> Date? in
                    guard let raw = row.created_at else { return nil }
                    return PickupGameModels.parseSupabaseTimestamptz(raw)
                }
                .max()
            applyMyPickupOrganizerSummary(
                PickupOrganizerSummary(
                    hostedCount: hosted,
                    stats: stats,
                    lastPickupGameCreatedAt: lastCreated
                ),
                userId: uid
            )
        }
    }

    @MainActor
    private func applyMyPickupOrganizerSummary(_ summary: PickupOrganizerSummary, userId: UUID) {
        myPickupOrganizerSummary = summary
        myPickupOrganizerSummaryLoadedForUserId = userId
        lastMyPickupOrganizerSummaryRefreshAt = Date()
        applyCachedPickupOrganizerSummary(summary, userId: userId, fetchedAt: Date())
#if DEBUG
        print("[PickupOrganizerSummary] own hosted=\(summary.hostedCount) ratings=\(summary.ratingCount) avg=\(summary.averageRating.map { String(format: "%.1f", $0) } ?? "nil") lastCreated=\(summary.lastPickupGameCreatedAt?.description ?? "nil")")
#endif
    }

    nonisolated private static func fetchPickupOrganizerProfileSummariesBatch(
        userIds: [UUID]
    ) async throws -> [UUID: PickupOrganizerSummary] {
        struct Params: Encodable {
            let p_user_ids: [UUID]
        }
        struct Row: Decodable {
            let user_id: UUID
            let pickup_games_hosted_count: Int64?
            let pickup_organizer_average_rating: PickupRPCNumericOrString?
            let pickup_organizer_rating_count: Int64?
            let last_pickup_game_created_at: String?

            func toSummary() -> PickupOrganizerSummary {
                let hosted = max(0, Int(pickup_games_hosted_count ?? 0))
                let count = max(0, Int(pickup_organizer_rating_count ?? 0))
                let avg: Double? = count > 0 ? pickup_organizer_average_rating?.doubleValue : nil
                let lastCreated: Date? = {
                    guard let raw = last_pickup_game_created_at?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty else { return nil }
                    return PickupGameModels.parseSupabaseTimestamptz(raw)
                }()
                return PickupOrganizerSummary(
                    hostedCount: hosted,
                    averageRating: avg,
                    ratingCount: count,
                    lastPickupGameCreatedAt: lastCreated
                )
            }
        }
        let rows: [Row] = try await supabase
            .rpc("pickup_organizer_profile_summaries", params: Params(p_user_ids: userIds))
            .execute()
            .value
        var out: [UUID: PickupOrganizerSummary] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[row.user_id] = row.toSummary()
        }
        return out
    }

    nonisolated private static func fetchPickupOrganizerProfileSummary(userId: UUID) async throws -> PickupOrganizerSummary {
        struct Params: Encodable {
            let p_user_id: UUID
        }
        struct Row: Decodable {
            let pickup_games_hosted_count: Int64?
            let pickup_organizer_average_rating: PickupRPCNumericOrString?
            let pickup_organizer_rating_count: Int64?
            let last_pickup_game_created_at: String?

            func toSummary() -> PickupOrganizerSummary {
                let hosted = max(0, Int(pickup_games_hosted_count ?? 0))
                let count = max(0, Int(pickup_organizer_rating_count ?? 0))
                let avg: Double? = count > 0 ? pickup_organizer_average_rating?.doubleValue : nil
                let lastCreated: Date? = {
                    guard let raw = last_pickup_game_created_at?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty else { return nil }
                    return PickupGameModels.parseSupabaseTimestamptz(raw)
                }()
                return PickupOrganizerSummary(
                    hostedCount: hosted,
                    averageRating: avg,
                    ratingCount: count,
                    lastPickupGameCreatedAt: lastCreated
                )
            }
        }
        let rows: [Row] = try await supabase
            .rpc("pickup_organizer_profile_summary", params: Params(p_user_id: userId))
            .execute()
            .value
        return rows.first?.toSummary() ?? .empty
    }
}

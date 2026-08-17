import Foundation
import Supabase

extension MapViewModel {
    static let fanSingleDeviceLogoutMessage =
        "You were signed out because your account was opened on another device."

    private static let activeSessionSelect = "active_session_id,active_session_updated_at"

    /// Fan and business single-device session enforcement (`user_profiles.active_session_id`).
    var isEligibleForFanSingleSessionEnforcement: Bool {
        (isLoggedIn || isVenueOwnerLoggedIn)
            && !isAdminLoggedIn
            && currentUserAuthId != nil
    }

    /// After successful fan or business login / sign-up: claim this device as the active session.
    func registerFanActiveSessionOnLogin() async {
        guard !shouldSuppressAuthenticatedRefreshForSafeLogout else { return }
        guard isEligibleForFanSingleSessionEnforcement else { return }
        guard let userId = currentUserAuthId else { return }

        let sessionId = UUID()
        FanSingleSessionStore.saveLocalSessionId(sessionId)
        singleSessionIgnoreRealtimeUntil = Date().addingTimeInterval(3)

#if DEBUG
        print("[SingleSessionDebug] loginSessionId=\(sessionId.uuidString.lowercased())")
        print("[SingleSessionDebug] localSessionId=\(sessionId.uuidString.lowercased())")
        print("[SingleSessionDebug] installationId=\(PushNotificationRegistrationService.installationID.uuidString.lowercased())")
#endif

        let wrote = await claimRemoteActiveSession(
            userId: userId,
            sessionId: sessionId,
            accountKind: isVenueOwnerLoggedIn ? "business" : "fan"
        )
        if wrote {
#if DEBUG
            print("[SingleSessionDebug] remoteSessionId=\(sessionId.uuidString.lowercased())")
#endif
        }

        await startFanSingleSessionRealtimeIfNeeded()
    }

    /// Foreground / restore: compare local vs remote; network failures do not sign out.
    func enforceFanSingleSessionOnForeground() async {
        await enforceFanSingleSessionFromRemoteCheck(source: "foreground")
    }

    func startFanSingleSessionRealtimeIfNeeded() async {
        // Explicit logout owns session teardown — never recreate the channel mid-pipeline.
        guard !shouldSuppressAuthenticatedRefreshForSafeLogout else {
#if DEBUG
            print("[SingleSessionDebug] startSkipped reason=logoutInProgress")
#endif
            return
        }
        guard isEligibleForFanSingleSessionEnforcement, let userId = currentUserAuthId else {
            await stopFanSingleSessionRealtime()
            return
        }

        if fanSingleSessionRealtimeTask != nil, fanSingleSessionRealtimeChannel != nil {
            return
        }

        await stopFanSingleSessionRealtime()

        fanSingleSessionRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runFanSingleSessionRealtimeLoop(userId: userId)
        }
    }

    func stopFanSingleSessionRealtime() async {
        fanSingleSessionRealtimeDebounceTask?.cancel()
        fanSingleSessionRealtimeDebounceTask = nil

        let task = fanSingleSessionRealtimeTask
        let channel = fanSingleSessionRealtimeChannel
        fanSingleSessionRealtimeTask = nil
        fanSingleSessionRealtimeChannel = nil

        // Remove channel before awaiting the listen task — otherwise `for await` on the
        // postgresChange stream never ends and logout hangs forever.
        task?.cancel()
        if let channel {
            await supabase.removeChannel(channel)
        }
        if let task {
            _ = await task.result
        }
    }

    /// Explicit-logout path: cancel and nil local single-session state synchronously.
    /// Never awaits `removeChannel` or listen-task completion — those are detached best-effort.
    @MainActor
    func abandonFanSingleSessionForLogout(knownUserId: UUID? = nil) {
        SafeLogoutDebug.step("single_session_local_abandon_begin")

        fanSingleSessionRealtimeDebounceTask?.cancel()
        fanSingleSessionRealtimeDebounceTask = nil

        let task = fanSingleSessionRealtimeTask
        let channel = fanSingleSessionRealtimeChannel
        fanSingleSessionRealtimeTask = nil
        fanSingleSessionRealtimeChannel = nil
        task?.cancel()

        let userId = knownUserId ?? currentUserAuthId
        let local = FanSingleSessionStore.localSessionId()
        FanSingleSessionStore.clearLocalSessionId()
        SafeLogoutDebug.step("single_session_local_abandon_completed")

        if let channel {
            Task {
                await supabase.removeChannel(channel)
            }
        }

        if let userId, let local {
            SafeLogoutDebug.step("single_session_remote_cleanup_dispatched")
            Task {
                if case .remote(let remote) = await self.fetchRemoteActiveSessionId(userId: userId),
                   remote == local {
                    _ = await self.patchRemoteActiveSession(userId: userId, sessionId: nil)
                }
            }
        }
    }

    /// Non-blocking cleanup used by logout-like paths. Prefer this over ``stopFanSingleSessionRealtime``
    /// whenever the caller must not wait on websocket unsubscribe acknowledgements.
    func clearFanActiveSessionOnLogout(knownUserId: UUID? = nil) async {
        // Must not call the awaited ``stopFanSingleSessionRealtime`` — that can hang forever.
        await MainActor.run {
            abandonFanSingleSessionForLogout(knownUserId: knownUserId)
        }
    }

    // MARK: - Core check

    private func enforceFanSingleSessionFromRemoteCheck(source: String) async {
        guard !shouldSuppressAuthenticatedRefreshForSafeLogout else { return }
        guard isEligibleForFanSingleSessionEnforcement else { return }
        guard !isPerformingSingleSessionLogout else { return }
        guard !UserDefaults.standard.bool(forKey: "didExplicitlyLogout") else { return }
        guard let userId = currentUserAuthId else { return }

        if let local = FanSingleSessionStore.localSessionId() {
#if DEBUG
            print("[SingleSessionDebug] localSessionId=\(local)")
#endif
            switch await fetchRemoteActiveSessionId(userId: userId) {
            case .networkFailure:
#if DEBUG
                print("[SingleSessionDebug] remoteSessionId=unavailable source=\(source)")
#endif
                return
            case .noRemote:
#if DEBUG
                print("[SingleSessionDebug] remoteSessionId=nil")
#endif
                return
            case .remote(let remote):
#if DEBUG
                print("[SingleSessionDebug] remoteSessionId=\(remote)")
#endif
                if remote != local {
                    await logoutDueToSingleSessionMismatch(
                        remoteId: remote,
                        localId: local,
                        source: source,
                        realtime: source == "realtime"
                    )
                }
            }
            return
        }

        // No local session yet (upgrade / fresh install): claim this device without signing out.
        let sessionId = UUID()
        FanSingleSessionStore.saveLocalSessionId(sessionId)
        singleSessionIgnoreRealtimeUntil = Date().addingTimeInterval(3)
        _ = await claimRemoteActiveSession(
            userId: userId,
            sessionId: sessionId,
            accountKind: isVenueOwnerLoggedIn ? "business" : "fan"
        )
#if DEBUG
        print("[SingleSessionDebug] loginSessionId=\(sessionId.uuidString.lowercased()) source=\(source)_claim")
        print("[SingleSessionDebug] localSessionId=\(sessionId.uuidString.lowercased())")
        print("[SingleSessionDebug] remoteSessionId=\(sessionId.uuidString.lowercased())")
#endif
        await startFanSingleSessionRealtimeIfNeeded()
    }

    private func logoutDueToSingleSessionMismatch(
        remoteId: String,
        localId: String,
        source: String,
        realtime: Bool
    ) async {
        guard !isPerformingSingleSessionLogout else { return }
        guard !isAuthSessionRestoringForProfilePresentation,
              authSessionState != .loadingSession,
              authSessionState != .authRefreshFailed else {
#if DEBUG
            print("[SingleSessionDebug] mismatchIgnored=true reason=authLoadingOrRefreshFailed source=\(source)")
#endif
            return
        }

        let now = Date()
        if let pending = pendingSingleSessionMismatch,
           pending.remoteId == remoteId,
           pending.localId == localId,
           now.timeIntervalSince(pending.detectedAt) >= 5 {
#if DEBUG
            print("[SingleSessionDebug] mismatchConfirmedTwice=true source=\(source)")
#endif
            pendingSingleSessionMismatch = nil
        } else {
            if pendingSingleSessionMismatch == nil ||
                pendingSingleSessionMismatch?.remoteId != remoteId ||
                pendingSingleSessionMismatch?.localId != localId {
                pendingSingleSessionMismatch = (remoteId: remoteId, localId: localId, source: source, detectedAt: now)
#if DEBUG
                print("[SingleSessionDebug] mismatchPending=true source=\(source)")
                print("[SingleSessionDebug] mismatchConfirmDelaySeconds=5")
#endif
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await self?.enforceFanSingleSessionFromRemoteCheck(source: "\(source)_confirm")
                }
            } else {
#if DEBUG
                print("[SingleSessionDebug] mismatchPending=true source=\(source) waitingForConfirm=true")
#endif
            }
            return
        }

        isPerformingSingleSessionLogout = true
        defer { isPerformingSingleSessionLogout = false }

#if DEBUG
        print("[SingleSessionDebug] mismatchLogout=true source=\(source)")
        print("[SingleSessionDebug] realtimeMismatch=\(realtime)")
        print("[SingleSessionDebug] remoteSessionId=\(remoteId)")
        print("[SingleSessionDebug] localSessionId=\(localId)")
#endif

        await stopFanSingleSessionRealtime()
        FanSingleSessionStore.clearLocalSessionId()

        await forceLogout(reason: "singleSessionMismatch", source: "MapViewModel.logoutDueToSingleSessionMismatch")
        await MainActor.run {
            authErrorMessage = L10n.t("security_session_replaced_signed_out_notice")
        }
    }

    func handleSecuritySessionReplacedDeepLink() {
        if isLoggedIn || isVenueOwnerLoggedIn {
            pendingOpenActionCenterForSecurityEvent = true
            return
        }
        if authErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authErrorMessage = L10n.t("security_session_replaced_signed_out_notice")
        }
    }

    // MARK: - Supabase

    private struct ActiveSessionRow: Decodable {
        let active_session_id: String?
    }

    private struct ActiveSessionPatch: Encodable {
        let active_session_id: String?
        let active_session_updated_at: String?
    }

    private enum RemoteActiveSessionFetchResult {
        case networkFailure
        case noRemote
        case remote(String)
    }

    private func fetchRemoteActiveSessionId(userId: UUID) async -> RemoteActiveSessionFetchResult {
        do {
            let rows: [ActiveSessionRow] = try await supabase
                .from("user_profiles")
                .select(Self.activeSessionSelect)
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            let raw = rows.first?.active_session_id?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let raw, !raw.isEmpty else { return .noRemote }
            return .remote(raw)
        } catch {
#if DEBUG
            print("[SingleSessionDebug] fetch_failed error=\(error.localizedDescription)")
#endif
            return .networkFailure
        }
    }

    @discardableResult
    private func claimRemoteActiveSession(
        userId: UUID,
        sessionId: UUID,
        accountKind: String
    ) async -> Bool {
        struct ClaimParams: Encodable {
            let p_session_id: String
            let p_installation_id: UUID
            let p_device_family: String
            let p_account_kind: String
        }
        let installationId = PushNotificationRegistrationService.installationID
        let params = ClaimParams(
            p_session_id: sessionId.uuidString.lowercased(),
            p_installation_id: installationId,
            p_device_family: FanGeoSecuritySessionReplacement.currentDeviceFamily,
            p_account_kind: accountKind
        )
        do {
            try await supabase
                .rpc("claim_active_session", params: params)
                .execute()
#if DEBUG
            print("[SecuritySessionReplaced] claim_ok installation=\(installationId.uuidString.lowercased()) kind=\(accountKind)")
#endif
            return true
        } catch {
#if DEBUG
            print("[SecuritySessionReplaced] claim_rpc_failed error=\(error.localizedDescription)")
#endif
            return await writeRemoteActiveSession(userId: userId, sessionId: sessionId)
        }
    }

    @discardableResult
    private func writeRemoteActiveSession(userId: UUID, sessionId: UUID) async -> Bool {
        await patchRemoteActiveSession(userId: userId, sessionId: sessionId.uuidString.lowercased())
    }

    @discardableResult
    private func patchRemoteActiveSession(userId: UUID, sessionId: String?) async -> Bool {
        let patch = ActiveSessionPatch(
            active_session_id: sessionId,
            active_session_updated_at: sessionId == nil ? nil : ISO8601DateFormatter().string(from: Date())
        )

        do {
            try await supabase
                .from("user_profiles")
                .update(patch)
                .eq("id", value: userId.uuidString.lowercased())
                .execute()
            return true
        } catch {
#if DEBUG
            print("[SingleSessionDebug] patch_failed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    // MARK: - Realtime

    private func runFanSingleSessionRealtimeLoop(userId: UUID) async {
        let channel = supabase.channel("fan-single-session-\(userId.uuidString.lowercased())")
        fanSingleSessionRealtimeChannel = channel

        let filter = RealtimePostgresFilter.eq("id", value: userId)
        let stream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "user_profiles",
            filter: filter
        )

        do {
            try await channel.subscribeWithError()
        } catch {
            if fanSingleSessionRealtimeChannel === channel {
                fanSingleSessionRealtimeChannel = nil
            }
            return
        }

        for await _ in stream {
            guard !Task.isCancelled else { break }

            if let ignoreUntil = singleSessionIgnoreRealtimeUntil, Date() < ignoreUntil {
                continue
            }

            fanSingleSessionRealtimeDebounceTask?.cancel()
            fanSingleSessionRealtimeDebounceTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await self.enforceFanSingleSessionFromRemoteCheck(source: "realtime")
            }
        }
    }
}

import Foundation

extension MapViewModel {
    private static let fanXPService = FanXPService()

    func refreshProfileXP() async {
        guard let uid = currentUserAuthId, isLoggedIn, !isVenueOwnerLoggedIn else {
            await MainActor.run { currentUserFanXP = .rookie }
            return
        }
        let state = await Self.fanXPService.loadUserXP(userId: uid)
        await MainActor.run { currentUserFanXP = state }
    }

    /// Claims Fan XP for a verified action. Amount and eligibility are enforced by `claim_fan_xp`.
    /// - Parameters:
    ///   - source: Canonical source string (`FanXPSource`).
    ///   - sourceId: Evidence record id (venue, event, pickup game, request, friendship, etc.).
    ///   - showToast: When true and the caller is the awarded user, show the XP overlay.
    @discardableResult
    func awardFanXP(
        source: String,
        sourceId: UUID,
        showToast: Bool = true
    ) async -> FanXPAwardResult? {
        let previousLevel = await MainActor.run {
            currentUserFanXP.level
        }

        let result = await Self.fanXPService.claimXP(
            source: source,
            sourceId: sourceId
        )

        guard let result else { return nil }

        if result.awarded == true {
            await refreshProfileXP()
            if showToast {
                let gained = result.xp_gained ?? FanXPSource.expectedAmount(for: source)
                let newLevel = await MainActor.run { currentUserFanXP.level }
                let newTitle = await MainActor.run {
                    FanReputationEngine.evaluate(
                        FanReputationSignals(fanXP: currentUserFanXP),
                        shouldLog: false
                    ).title
                }
                await MainActor.run {
                    if newLevel > previousLevel {
                        fanXPRewardOverlay.enqueueLevelUp(level: newLevel, title: newTitle)
                    } else if gained > 0 {
                        fanXPRewardOverlay.enqueueXP(amount: gained, source: source)
                    }
                }
            }
        } else if let total = result.total_xp, let level = result.level, let title = result.title {
            await MainActor.run {
                currentUserFanXP = FanXPState(totalXP: total, level: level, title: title)
            }
        }

        return result
    }

    /// Routes legacy reputation feedback through the premium overlay (not ``showSocialActionToast``).
    func showFanXPToast(_ message: String) {
        let parts = message.split(separator: "·", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if parts.count == 2, parts[0].hasPrefix("+"), parts[0].contains("XP") {
            let amountDigits = parts[0].filter(\.isNumber)
            if let amount = Int(amountDigits) {
                fanXPRewardOverlay.enqueue(
                    .xpGain(amount: amount, subtitle: parts[1])
                )
                return
            }
        }
        fanXPRewardOverlay.enqueue(
            FanXPRewardPresentation(
                id: UUID(),
                kind: .reputationSignal,
                primaryLine: message,
                secondaryLine: "FanGeo"
            )
        )
    }
}

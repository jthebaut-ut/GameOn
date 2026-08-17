import Foundation

extension MapViewModel {
    /// Loads playable Team events the viewer (or a managed player they guard) is Going to.
    /// Uses existing `list_my_fan_teams`, `list_fan_team_games`, and attendance RPCs.
    /// Does not invent invitations. Account-seat Going is already in pickup join cards.
    func refreshGoingPlayTeamParticipations(reason: String) async {
        guard isAuthenticatedForSocialFeatures, canFanUsePickupGamesUI else {
            if !goingPlayTeamParticipations.isEmpty {
                goingPlayTeamParticipations = []
            }
            return
        }
        let uid = currentUserAuthId
        do {
            let teams = try await FanTeamsService().listMyTeams()
            let managedTeams = teams.filter {
                $0.accessVia == .managedPlayer || !$0.viaManagedPlayerNames.isEmpty
            }
            guard !managedTeams.isEmpty else {
                if !goingPlayTeamParticipations.isEmpty {
                    goingPlayTeamParticipations = []
                }
                return
            }

            let service = FanTeamsService()
            let now = Date()
            var next: [GoingPlayTeamParticipation] = []
            var identityExtra: [UUID: PickupDiscoverTeamIdentity] = [:]
            let hostedIds = Set(myPickupGamesForSettings.map(\.id))
            let joinCardIds = Set(myPickupGameJoinRequestCards.map(\.pickupGameId))

            for team in managedTeams {
                let games: [FanTeamGame]
                do {
                    games = try await service.listGames(teamId: team.id)
                } catch {
#if DEBUG
                    print("[GoingPlay] listGames failed team=\(team.id.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
                    continue
                }
                let playable = games.filter { game in
                    GoingPlayProjection.isPlayableTeamEvent(game.gameType)
                        && GoingPlayProjection.isTeamGameVisibleInGoing(
                            startsAt: game.startsAt,
                            endsAt: game.endsAt,
                            now: now
                        )
                }
                let missing = playable.filter { !joinCardIds.contains($0.id) }
                guard !missing.isEmpty else { continue }

                await loadTeamScheduleAttendanceBatch(
                    teamId: team.id,
                    pickupGameIds: missing.map(\.id)
                )

                for game in missing {
                    let format = GameType(rawValue: game.gameType.rawValue) ?? .other
                    let roster = pickupGameRosterByGameId[game.id]
                    let viaNames = managedGoingPlayerNames(
                        roster: roster,
                        fallback: team.viaManagedPlayerNames
                    )
                    let selfGoing: Bool = {
                        if case .status(let status) = fanTeamSelfRSVPByGameId[game.id] {
                            return status == .going
                        }
                        return false
                    }()
                    let isCreator = uid.map { $0 == game.createdBy } ?? false
                    guard !viaNames.isEmpty || selfGoing else { continue }
                    if isCreator, hostedIds.contains(game.id), viaNames.isEmpty { continue }

                    next.append(
                        GoingPlayTeamParticipation(
                            pickupGameId: game.id,
                            teamId: team.id,
                            teamName: team.name,
                            teamSport: team.sport,
                            sportSubtype: nil,
                            colorHex: team.colorHex,
                            logoURL: team.logoURL,
                            logoThumbnailURL: team.logoThumbnailURL,
                            eventType: format,
                            customTitle: game.title,
                            opponentName: game.opponentName,
                            startsAt: game.startsAt,
                            endsAt: game.endsAt,
                            locationLine: game.locationLine,
                            createdBy: game.createdBy,
                            viaManagedPlayerNames: viaNames,
                            isCreator: isCreator
                        )
                    )
                    identityExtra[game.id] = PickupDiscoverTeamIdentity(
                        pickupGameId: game.id,
                        teamId: team.id,
                        teamName: team.name,
                        teamSport: team.sport,
                        colorHex: team.colorHex,
                        logoURL: team.logoURL,
                        logoThumbnailURL: team.logoThumbnailURL,
                        displayRefreshToken: nil
                    )
                }
            }

            goingPlayTeamParticipations = next
            mergePickupDiscoverTeamIdentities(identityExtra)
#if DEBUG
            print("[GoingPlay] refresh reason=\(reason) managedTeams=\(managedTeams.count) items=\(next.count)")
#endif
        } catch {
#if DEBUG
            print("[GoingPlay] refresh failed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func managedGoingPlayerNames(
        roster: PickupGameRosterPayload?,
        fallback: [String]
    ) -> [String] {
        guard let roster else { return fallback }
        let going = PickupTeamAttendancePresentation.rows(from: roster)
            .filter { $0.category == .going && $0.member.isManagedPlayer }
            .map { $0.member.resolvedDisplayName }
        if !going.isEmpty { return going }
        return fallback
    }

    func openGoingPlayTeamEvent(teamId: UUID, pickupGameId: UUID) {
        pendingTeamScheduleEventDeepLink = PendingTeamScheduleEventDeepLink(
            teamId: teamId,
            pickupGameId: pickupGameId
        )
    }
}

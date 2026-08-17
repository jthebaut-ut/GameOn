import CoreLocation
import Foundation

struct PickupBulkImportResult {
    let insertedRows: [PickupGameRow]
    let failedRows: [(rowNumber: Int, message: String)]

    var insertedCount: Int { insertedRows.count }
    var failedCount: Int { failedRows.count }
}

enum PickupBulkImportService {
    @MainActor
    static func loadPreview(
        from url: URL,
        viewModel: MapViewModel,
        creationContext: PickupGameCreationContext? = nil
    ) async throws -> [PickupBulkImportPreparedRow] {
        // Resolve default on MainActor — avoids evaluating MainActor-isolated
        // `PickupGameCreationContext.standard` in a nonisolated default-arg context.
        let creationContext = creationContext ?? .standard
#if DEBUG
        print(
            "[PickupBulkImport] loadPreviewStarted file=\(url.lastPathComponent) " +
            "teamSourced=\(creationContext.isTeamSourced)"
        )
#endif
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        let rawRows = try PickupBulkImportParser.parseFile(
            at: url,
            prefersTeamWorksheet: creationContext.isTeamSourced
        )
        let rows = await PickupBulkImportValidator.validate(
            rawRows: rawRows,
            viewModel: viewModel,
            creationContext: creationContext
        )
#if DEBUG
        let summary = PickupBulkImportValidator.summary(for: rows)
        print("[PickupBulkImport] previewReady total=\(summary.totalCount) importable=\(summary.importableCount)")
#endif
        return rows
    }

    @MainActor
    static func importRows(
        _ rows: [PickupBulkImportPreparedRow],
        viewModel: MapViewModel,
        creationContext: PickupGameCreationContext? = nil
    ) async -> PickupBulkImportResult {
        let creationContext = creationContext ?? .standard
        let candidates = rows.filter { $0.status.isImportable }
        let isTeamSourced = creationContext.isTeamSourced
        let team = creationContext.team
        let isVisible = PickupGameEditPrivacyPolicy.defaultIsPublicForNewGame(
            isTeamSourcedCreate: isTeamSourced
        )
#if DEBUG
        print(
            "[PickupBulkInsert] started rows=\(candidates.count) " +
            "teamSourced=\(isTeamSourced) isVisible=\(isVisible)"
        )
#endif
        var inserted: [PickupGameRow] = []
        var failed: [(rowNumber: Int, message: String)] = []

        for row in candidates {
            guard let start = row.gameStartAt,
                  let coordinate = row.coordinate,
                  let playersNeeded = row.playersNeeded else {
                failed.append((row.rowNumber, "Row was not fully validated."))
                continue
            }
            let end = row.endTime ?? PickupGameModels.defaultPickupEndTime(forStart: start)

            do {
#if DEBUG
                print("[PickupBulkInsert] row=\(row.rowNumber) title=\(row.title)")
#endif
                let insertedRow = try await viewModel.insertPickupGame(
                    title: row.title,
                    sport: row.sport,
                    description: row.description,
                    skillLevel: row.skillLevel,
                    gameStartAt: start,
                    endTime: end,
                    address: row.address.isEmpty ? nil : row.address,
                    city: row.city.isEmpty ? nil : row.city,
                    state: row.state.isEmpty ? nil : row.state,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    playersNeeded: playersNeeded,
                    playEnvironment: row.playEnvironment,
                    participantPreference: row.participantPreference,
                    ageMin: row.ageMin,
                    ageMax: row.ageMax,
                    isFree: row.isFree,
                    entryFeeAmount: row.isFree ? nil : row.entryFeeAmount,
                    maxPlayers: row.maxPlayers,
                    gameFormat: row.gameType,
                    competitionLevel: row.competitionLevel,
                    isVisible: isVisible,
                    opponentName: FanTeamScheduleMatchup.persistableOpponent(
                        format: row.gameType,
                        opponentName: row.opponentName
                    ),
                    claimsPickupCreateXP: !isTeamSourced
                )

                if isTeamSourced, let team {
                    do {
                        _ = try await FanTeamsService().linkPickupGameToFanTeam(
                            teamId: team.teamId,
                            pickupGameId: insertedRow.id
                        )
                        if row.gameType != .announcement {
                            await viewModel.awardFanXP(
                                source: FanXPSource.teamEventCreated,
                                sourceId: insertedRow.id
                            )
                        }
                    } catch {
                        // Same orphan cleanup as Manual Team create.
                        try? await viewModel.deletePickupGame(id: insertedRow.id)
#if DEBUG
                        print(
                            "[PickupBulkInsert] row=\(row.rowNumber) linkFailed " +
                            "orphanedSoftRemoved id=\(insertedRow.id.uuidString.lowercased()) " +
                            "error=\(error.localizedDescription)"
                        )
#endif
                        failed.append((row.rowNumber, error.localizedDescription))
                        continue
                    }
                }

                inserted.append(insertedRow)
#if DEBUG
                print("[PickupBulkInsert] row=\(row.rowNumber) success=true id=\(insertedRow.id.uuidString.lowercased())")
#endif
            } catch {
#if DEBUG
                print("[PickupBulkInsert] row=\(row.rowNumber) success=false error=\(error.localizedDescription)")
#endif
                failed.append((row.rowNumber, error.localizedDescription))
            }
        }

        // One Discover / settings refresh after the whole batch (not per row).
        if !inserted.isEmpty {
            await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "pickupBulkImportInserted")
            await viewModel.refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
        }

#if DEBUG
        print("[PickupBulkInsert] finished inserted=\(inserted.count) failed=\(failed.count)")
#endif
        return PickupBulkImportResult(insertedRows: inserted, failedRows: failed)
    }
}

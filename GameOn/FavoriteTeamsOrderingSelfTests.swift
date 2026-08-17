import Foundation

#if DEBUG
enum FavoriteTeamsOrderingSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FavoriteTeamsOrderingTest] PASS \(name)")
            } else {
                failures += 1
                print("[FavoriteTeamsOrderingTest] FAIL \(name)")
            }
        }

        let psg = "soccer-psg"
        let inter = "soccer-inter"
        let france = "soccer-france"
        let mbappe = "player-kylian-mbappe"
        let lakers = "nba-lakers"
        let superBowl = "tournament-super-bowl"
        let saved = [psg, inter, france, mbappe, lakers, superBowl]

        for id in saved {
            expect(FavoriteTeamCatalog.team(id: id) != nil, "catalog contains \(id)")
        }

        expect(
            FavoriteTeamsStore.uniquedIDs([psg, "  \(france)  ", psg, france, mbappe]) == [psg, france, mbappe],
            "uniqued IDs keep first-seen order"
        )
        expect(
            FavoriteTeamsStore.encodeIDs(saved) == saved.joined(separator: ","),
            "AppStorage encodes follow order, not a Set"
        )
        expect(
            FavoriteTeamsStore.decodeIDs(from: FavoriteTeamsStore.encodeIDs(saved)) == saved,
            "favorites keep exact order after initial load"
        )

        let afterArtwork = FavoriteTeamsStore.resolvedTeams(fromIDs: saved)
        expect(afterArtwork.map(\.id) == saved, "resolved teams follow saved IDs")
        expect(
            FavoriteTeamsStore.resolvedTeams(fromIDs: saved).map(\.id) == afterArtwork.map(\.id),
            "artwork hydration does not reorder"
        )

        if let mbappeTeam = FavoriteTeamCatalog.team(id: mbappe),
           let franceTeam = FavoriteTeamCatalog.team(id: france) {
            let fallback = SportsIdentityArtworkResolver.resolve(favoriteTeam: mbappeTeam)
            let franceArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: franceTeam)
            _ = fallback
            _ = franceArt
            expect(
                FavoriteTeamsStore.resolvedTeams(fromIDs: saved).map(\.id) == saved,
                "player artwork fallback → real artwork does not reorder"
            )
            expect(
                FavoriteTeamsStore.resolvedTeams(fromIDs: saved).map(\.id) == saved,
                "national-team crest hydration does not reorder"
            )
            expect(
                FavoriteTeamsStore.resolvedTeams(fromIDs: saved).map(\.id) == saved,
                "provider metadata hydration does not reorder"
            )
        }

        let byID = Dictionary(uniqueKeysWithValues: afterArtwork.map { ($0.id, $0) })
        let hydratedInSavedOrder = saved.compactMap { byID[$0] }
        expect(
            hydratedInSavedOrder.map(\.id) == saved,
            "same IDs with different hydrated metadata produce same ordering"
        )

        let appended = FavoriteTeamsStore.adding("soccer-psg-women", to: saved)
        expect(appended == saved + ["soccer-psg-women"], "add favorite appends without moving existing items")
        expect(FavoriteTeamsStore.adding(psg, to: saved) == saved, "adding an existing ID is a no-op")

        let removed = FavoriteTeamsStore.removing(inter, from: saved)
        expect(removed == [psg, france, mbappe, lakers, superBowl], "remove favorite preserves relative order")
        expect(
            FavoriteTeamsStore.toggling(mbappe, in: saved) == [psg, inter, france, lakers, superBowl],
            "unfollow via toggle drops only that identity"
        )
        expect(
            FavoriteTeamsStore.toggling("nba-bulls", in: saved) == saved + ["nba-bulls"],
            "follow via toggle appends"
        )

        let mixed = FavoriteTeamsStore.resolvedTeams(fromIDs: saved)
        expect(
            mixed.map(\.kind) == [.team, .team, .nationalTeam, .player, .team, .competition],
            "mixed team/national/player/competition identities remain interleaved"
        )
        expect(mixed.map(\.id) == saved, "mixed identities stay in saved order")

        let soccerOnly = mixed.filter { $0.sport == .soccer }
        expect(
            soccerOnly.map(\.id) == [psg, inter, france, mbappe],
            "switching sport/category filters without reshuffling the base order"
        )
        let idsAfterCategorySwitch = saved
        _ = idsAfterCategorySwitch.filter { FavoriteTeamCatalog.team(id: $0)?.kind == .player }
        expect(idsAfterCategorySwitch == saved, "switching category does not mutate base favorite order")

        let searchIDs = saved
        _ = FavoriteFollowingSearch.rankedResults(query: "Paris", prioritizingSelectedIDs: Set(searchIDs))
        expect(searchIDs == saved, "search does not mutate base favorite order")

        expect(
            FavoriteTeamsStore.mergedRemoteIDs(local: saved, remote: [superBowl, mbappe, psg, lakers, france, inter]) == saved,
            "remote hydration does not reorder when the ID set is unchanged"
        )
        expect(
            FavoriteTeamsStore.mergedRemoteIDs(local: saved, remote: saved + ["nba-bulls"]) == saved + ["nba-bulls"],
            "new remote favorites append after the saved order"
        )
        expect(
            FavoriteTeamsStore.mergedRemoteIDs(local: saved, remote: [psg, mbappe, lakers]) == [psg, mbappe, lakers],
            "removed remote IDs drop in place without reshuffling the rest"
        )

        let explicitIDs = mixed.map(\.id)
        expect(Set(explicitIDs).count == explicitIDs.count, "ForEach identity is the stable catalog ID")
        expect(explicitIDs.allSatisfy { !$0.contains("http") && !$0.contains("://") }, "ForEach identity is not an artwork URL")
        expect(explicitIDs != Array(0..<explicitIDs.count).map(String.init), "ForEach identity is not a row index")
        expect(
            FavoriteFollowingCountryBrowse.uniquedTeams(mixed).map(\.id) == saved,
            "strip uniquing preserves saved order"
        )

        let setIterationIsNotAuthoritative = FavoriteTeamsStore.uniquedIDs(saved) == saved
        expect(setIterationIsNotAuthoritative, "no Set/Dictionary iteration determines UI order")

        if failures == 0 {
            print("[FavoriteTeamsOrderingTest] ALL PASSED")
        } else {
            print("[FavoriteTeamsOrderingTest] FAILURES=\(failures)")
            assertionFailure("FavoriteTeamsOrderingSelfTests failed: \(failures)")
        }
    }
}
#endif

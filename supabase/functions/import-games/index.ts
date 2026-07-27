// Privileged sports schedule import (TheSportsDB → public.games).
// Auth: service-role bearer OR x-cron-secret (IMPORT_GAMES_CRON_SECRET / SPORTS_SYNC_CRON_SECRET).
// Manual test:
//   curl -X POST "$SUPABASE_URL/functions/v1/import-games" \
//     -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
//     -H "Content-Type: application/json"
// Deploy: supabase functions deploy import-games

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import {
  authorizeSportsWorkerRequest,
  readServiceRoleKey,
  sportsWorkerAuthLog,
} from "../_shared/sports_worker_auth.ts"

const FUNCTION_NAME = "import-games"
const API_KEY = "123"

const leagues = [
  { id: "4387", sport: "NBA", league: "NBA" },
  { id: "4391", sport: "NFL", league: "NFL" },
  { id: "4424", sport: "Baseball", league: "MLB" },
  { id: "4328", sport: "Soccer", league: "Premier League" },
]

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret, x-fangeo-cron-secret",
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

serve(async (req) => {
  const requestId = req.headers.get("x-request-id") ?? req.headers.get("sb-request-id")

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  const auth = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: [
      "IMPORT_GAMES_CRON_SECRET",
      "SPORTS_SYNC_CRON_SECRET",
    ],
  })
  if (!auth.accepted) {
    sportsWorkerAuthLog(FUNCTION_NAME, "unauthorized", {
      reason: auth.reason,
      requestId,
    })
    return json({ success: false, error: "unauthorized" }, auth.reason === "method_not_allowed" ? 405 : 401)
  }
  sportsWorkerAuthLog(FUNCTION_NAME, "authorized", {
    source: auth.source,
    requestId,
  })

  const supabaseUrl = Deno.env.get("PROJECT_URL") ?? Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = readServiceRoleKey()
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ success: false, error: "Missing Supabase service env vars" }, 500)
  }

  // Create service-role client only after authorization succeeds.
  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const allGames = []

  for (const league of leagues) {
    const url =
      `https://www.thesportsdb.com/api/v1/json/${API_KEY}/eventsnextleague.php?id=${league.id}`

    const response = await fetch(url)
    const data = await response.json()

    const events = data.events ?? []

    for (const event of events) {
      allGames.push({
        external_id: event.idEvent,
        source: "thesportsdb",
        title: event.strEvent,
        league: league.league,
        sport: league.sport,
        game_date: event.dateEvent,
        game_time: event.strTime ?? "Time TBD",
        home_team: event.strHomeTeam,
        away_team: event.strAwayTeam,
        status: "scheduled",
      })
    }
  }

  const { error } = await supabase
    .from("games")
    .upsert(allGames, { onConflict: "external_id" })

  if (error) {
    return json(error, 500)
  }

  return json({
    success: true,
    imported: allGames.length,
  })
})

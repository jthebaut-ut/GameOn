/**
 * Local unit checks for sports worker auth (no network, no secrets logged).
 *
 * Run:
 *   deno test --allow-env supabase/functions/_shared/sports_worker_auth_test.ts
 */

import {
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts"
import {
  authorizeSportsWorkerRequest,
  secretsEqual,
} from "./sports_worker_auth.ts"

const LEGACY_JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.legacy.sig"

Deno.test("secretsEqual accepts identical strings", () => {
  assertEquals(secretsEqual("abc", "abc"), true)
})

Deno.test("secretsEqual rejects mismatched values and lengths", () => {
  assertFalse(secretsEqual("abc", "abd"))
  assertFalse(secretsEqual("abc", "ab"))
  assertFalse(secretsEqual("", "a"))
})

Deno.test("authorizeSportsWorkerRequest rejects missing auth", () => {
  Deno.env.delete("SERVICE_ROLE_KEY")
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.delete("SUPABASE_SECRET_KEYS")
  Deno.env.delete("SUPABASE_SECRET_KEY")
  Deno.env.delete("SYNC_LIVE_MATCHES_CRON_SECRET")
  const req = new Request("https://example.test/sync", { method: "POST" })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["SYNC_LIVE_MATCHES_CRON_SECRET"],
  })
  assertEquals(result.accepted, false)
  if (!result.accepted) {
    assertEquals(result.reason, "misconfigured")
  }
})

Deno.test("authorizeSportsWorkerRequest accepts service role bearer", () => {
  Deno.env.delete("SERVICE_ROLE_KEY")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
  Deno.env.delete("SYNC_LIVE_MATCHES_CRON_SECRET")
  const req = new Request("https://example.test/sync", {
    method: "POST",
    headers: { Authorization: `Bearer ${LEGACY_JWT}` },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["SYNC_LIVE_MATCHES_CRON_SECRET"],
  })
  assertEquals(result.accepted, true)
  if (result.accepted) {
    assertEquals(result.source, "service_role_bearer")
  }
})

Deno.test("authorizeSportsWorkerRequest rejects anon/user-like bearer", () => {
  Deno.env.delete("SERVICE_ROLE_KEY")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
  const req = new Request("https://example.test/sync", {
    method: "POST",
    headers: { Authorization: "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.user" },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["SYNC_LIVE_MATCHES_CRON_SECRET"],
  })
  assertEquals(result.accepted, false)
  if (!result.accepted) {
    assertEquals(result.reason, "invalid_secret")
  }
})

Deno.test("authorizeSportsWorkerRequest accepts cron secret header", () => {
  Deno.env.delete("SERVICE_ROLE_KEY")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
  Deno.env.set("SYNC_LIVE_MATCHES_CRON_SECRET", "cron-test-secret")
  const req = new Request("https://example.test/sync", {
    method: "POST",
    headers: { "x-cron-secret": "cron-test-secret" },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["SYNC_LIVE_MATCHES_CRON_SECRET"],
  })
  assertEquals(result.accepted, true)
  if (result.accepted) {
    assertEquals(result.source, "cron_secret")
  }
})

Deno.test("pickup-game-change: Vault JWT bearer accepted when hosted SERVICE_ROLE_KEY is sb_secret", () => {
  // Exact live mismatch: pg_net sends Vault fangeo_service_role_key (JWT)
  // while hosted Edge SERVICE_ROLE_KEY is often sb_secret_*. The old local
  // authorizeInvocation compared only those two and logged invalid_secret.
  Deno.env.set("SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.set("fangeo_service_role_key", LEGACY_JWT)
  Deno.env.delete("SUPABASE_SECRET_KEYS")
  Deno.env.delete("SUPABASE_SECRET_KEY")
  Deno.env.delete("PICKUP_GAME_CHANGE_PUSH_CRON_SECRET")
  const req = new Request("https://example.test/notify-pickup-game-change", {
    method: "POST",
    headers: { Authorization: `Bearer ${LEGACY_JWT}` },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["PICKUP_GAME_CHANGE_PUSH_CRON_SECRET"],
  })
  assertEquals(result.accepted, true)
  if (result.accepted) {
    assertEquals(result.source, "service_role_bearer")
  }
})

Deno.test("pickup-game-change: Vault JWT rejected when Edge has only sb_secret (no mirrored JWT)", () => {
  Deno.env.set("SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.delete("SUPABASE_SECRET_KEYS")
  Deno.env.delete("SUPABASE_SECRET_KEY")
  Deno.env.delete("PICKUP_GAME_CHANGE_PUSH_CRON_SECRET")
  const req = new Request("https://example.test/notify-pickup-game-change", {
    method: "POST",
    headers: { Authorization: `Bearer ${LEGACY_JWT}` },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["PICKUP_GAME_CHANGE_PUSH_CRON_SECRET"],
  })
  assertEquals(result.accepted, false)
  if (!result.accepted) {
    assertEquals(result.reason, "invalid_secret")
  }
})

Deno.test("pickup-game-change: sb_secret apikey accepted (SQL dual-key header)", () => {
  Deno.env.set("SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.delete("SUPABASE_SECRET_KEYS")
  Deno.env.delete("SUPABASE_SECRET_KEY")
  Deno.env.delete("PICKUP_GAME_CHANGE_PUSH_CRON_SECRET")
  const req = new Request("https://example.test/notify-pickup-game-change", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${LEGACY_JWT}`,
      apikey: "sb_secret_hosted_platform",
    },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["PICKUP_GAME_CHANGE_PUSH_CRON_SECRET"],
  })
  assertEquals(result.accepted, true)
  if (result.accepted) {
    assertEquals(result.source, "secret_apikey")
  }
})

Deno.test("fan-team-invitation: Bearer-only Vault JWT rejected when Edge has only sb_secret", () => {
  // Live invitation failure class (20260942 queue): Bearer JWT only,
  // hosted SERVICE_ROLE_KEY is sb_secret_*, no mirrored fangeo JWT.
  Deno.env.set("SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.delete("SUPABASE_SECRET_KEYS")
  Deno.env.delete("SUPABASE_SECRET_KEY")
  Deno.env.delete("FAN_TEAM_INVITATION_PUSH_CRON_SECRET")
  const req = new Request("https://example.test/notify-fan-team-invitation", {
    method: "POST",
    headers: { Authorization: `Bearer ${LEGACY_JWT}` },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["FAN_TEAM_INVITATION_PUSH_CRON_SECRET"],
  })
  assertEquals(result.accepted, false)
  if (!result.accepted) {
    assertEquals(result.reason, "invalid_secret")
  }
})

Deno.test("fan-team-invitation: dual-key Bearer JWT + sb_secret apikey accepted", () => {
  Deno.env.set("SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "sb_secret_hosted_platform")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.delete("SUPABASE_SECRET_KEYS")
  Deno.env.delete("SUPABASE_SECRET_KEY")
  Deno.env.delete("FAN_TEAM_INVITATION_PUSH_CRON_SECRET")
  const req = new Request("https://example.test/notify-fan-team-invitation", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${LEGACY_JWT}`,
      apikey: "sb_secret_hosted_platform",
    },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["FAN_TEAM_INVITATION_PUSH_CRON_SECRET"],
  })
  assertEquals(result.accepted, true)
  if (result.accepted) {
    assertEquals(result.source, "secret_apikey")
  }
})

Deno.test("authorizeSportsWorkerRequest rejects wrong cron secret", () => {
  Deno.env.delete("SERVICE_ROLE_KEY")
  Deno.env.delete("fangeo_service_role_key")
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
  Deno.env.set("SYNC_LIVE_MATCHES_CRON_SECRET", "cron-test-secret")
  const req = new Request("https://example.test/sync", {
    method: "POST",
    headers: { "x-cron-secret": "wrong" },
  })
  const result = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: ["SYNC_LIVE_MATCHES_CRON_SECRET"],
  })
  assertEquals(result.accepted, false)
})

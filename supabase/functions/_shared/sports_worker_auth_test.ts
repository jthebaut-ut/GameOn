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
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key")
  Deno.env.delete("SYNC_LIVE_MATCHES_CRON_SECRET")
  const req = new Request("https://example.test/sync", {
    method: "POST",
    headers: { Authorization: "Bearer srv-role-test-key" },
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
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key")
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
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key")
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

Deno.test("authorizeSportsWorkerRequest rejects wrong cron secret", () => {
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key")
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

/**
 * Dual credential auth matrix for push workers (legacy JWT + sb_secret_*).
 *
 * Run:
 *   deno test --allow-env supabase/functions/_shared/service_role_dual_key_auth_test.ts
 */
import {
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts"
import {
  authorizeSportsWorkerRequest,
  readAdminApiKey,
  readServiceRoleKey,
  readServiceRoleKeyCandidates,
  readSupabaseSecretKeyCandidates,
} from "./sports_worker_auth.ts"
import { authorizeExactServiceRoleBearer } from "./service_role_auth.ts"

const CRON_ENV = "CHAT_MESSAGE_PUSH_CRON_SECRET"
const CRON_VALUE = "chat-push-cron-test-secret"
const SECRET_KEY = "sb_secret_test_default_0001"
const LEGACY_JWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.legacy.sig"

function withCleanAuthEnv(fn: () => void) {
  const keys = [
    "SERVICE_ROLE_KEY",
    "SUPABASE_SERVICE_ROLE_KEY",
    "fangeo_service_role_key",
    "SUPABASE_SECRET_KEYS",
    "SUPABASE_SECRET_KEY",
    "SUPABASE_PUBLISHABLE_KEYS",
    "SUPABASE_PUBLISHABLE_KEY",
    "SUPABASE_ANON_KEY",
    CRON_ENV,
    "DIRECT_MESSAGE_PUSH_CRON_SECRET",
  ]
  const prev = new Map(keys.map((k) => [k, Deno.env.get(k)]))
  for (const k of keys) Deno.env.delete(k)
  try {
    fn()
  } finally {
    for (const k of keys) {
      const v = prev.get(k)
      if (v === undefined) Deno.env.delete(k)
      else Deno.env.set(k, v)
    }
  }
}

function postBearer(token: string): Request {
  return new Request("https://example.test/notify-chat-message", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  })
}

function postApikey(key: string): Request {
  return new Request("https://example.test/notify-chat-message", {
    method: "POST",
    headers: { apikey: key },
  })
}

function postCron(secret: string): Request {
  return new Request("https://example.test/notify-chat-message", {
    method: "POST",
    headers: { "x-cron-secret": secret },
  })
}

function postBare(): Request {
  return new Request("https://example.test/notify-chat-message", { method: "POST" })
}

Deno.test("1) valid legacy service-role bearer accepted", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
    const result = authorizeSportsWorkerRequest(postBearer(LEGACY_JWT), {
      cronSecretEnvNames: [CRON_ENV],
    })
    assertEquals(result.accepted, true)
    if (result.accepted) assertEquals(result.source, "service_role_bearer")
    assertEquals(readServiceRoleKeyCandidates(), [LEGACY_JWT])
  })
})

Deno.test("2) invalid bearer rejected", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
    Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET_KEY }))
    const result = authorizeSportsWorkerRequest(postBearer("random-not-a-key"), {
      cronSecretEnvNames: [CRON_ENV],
    })
    assertEquals(result.accepted, false)
    if (!result.accepted) assertEquals(result.reason, "invalid_secret")
  })
})

Deno.test("3) valid Supabase secret apikey accepted", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET_KEY }))
    const result = authorizeSportsWorkerRequest(postApikey(SECRET_KEY), {
      cronSecretEnvNames: [CRON_ENV],
    })
    assertEquals(result.accepted, true)
    if (result.accepted) assertEquals(result.source, "secret_apikey")
    assertEquals(readSupabaseSecretKeyCandidates(), [SECRET_KEY])
    assertEquals(readAdminApiKey(), SECRET_KEY)
  })
})

Deno.test("4) invalid apikey rejected", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET_KEY }))
    const result = authorizeSportsWorkerRequest(postApikey("sb_secret_wrong"), {
      cronSecretEnvNames: [CRON_ENV],
    })
    assertEquals(result.accepted, false)
    if (!result.accepted) assertEquals(result.reason, "invalid_secret")
  })
})

Deno.test("5) publishable/anon key rejected", () => {
  withCleanAuthEnv(() => {
    const publishable = "sb_publishable_public_0001"
    Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET_KEY }))
    Deno.env.set("SUPABASE_PUBLISHABLE_KEYS", JSON.stringify({ default: publishable }))
    Deno.env.set("SUPABASE_ANON_KEY", "anon-legacy-key")
    assertEquals(
      authorizeSportsWorkerRequest(postApikey(publishable), { cronSecretEnvNames: [CRON_ENV] })
        .accepted,
      false,
    )
    assertEquals(
      authorizeSportsWorkerRequest(postBearer("anon-legacy-key"), {
        cronSecretEnvNames: [CRON_ENV],
      }).accepted,
      false,
    )
  })
})

Deno.test("6) missing credentials rejected", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
    Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET_KEY }))
    const result = authorizeSportsWorkerRequest(postBare(), {
      cronSecretEnvNames: [CRON_ENV],
    })
    assertEquals(result.accepted, false)
    if (!result.accepted) assertEquals(result.reason, "missing_secret")
  })
})

Deno.test("7) optional cron secret continues working if configured", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
    Deno.env.set(CRON_ENV, CRON_VALUE)
    const ok = authorizeSportsWorkerRequest(postCron(CRON_VALUE), {
      cronSecretEnvNames: [CRON_ENV, "DIRECT_MESSAGE_PUSH_CRON_SECRET"],
    })
    assertEquals(ok.accepted, true)
    if (ok.accepted) assertEquals(ok.source, "cron_secret")
    const bad = authorizeSportsWorkerRequest(postCron("wrong-cron"), {
      cronSecretEnvNames: [CRON_ENV],
    })
    assertEquals(bad.accepted, false)
  })
})

Deno.test("8) no regression to createClient/admin access preference", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", LEGACY_JWT)
    Deno.env.set("SERVICE_ROLE_KEY", "other-legacy")
    Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET_KEY }))
    // Prefer secret key model for admin client.
    assertEquals(readAdminApiKey(), SECRET_KEY)
    // Legacy reader still returns platform JWT for legacy-only callers.
    assertEquals(readServiceRoleKey(), LEGACY_JWT)
  })
})

Deno.test("legacy dual SERVICE_ROLE_KEY candidates still accepted", () => {
  withCleanAuthEnv(() => {
    const vaultJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.vault.sig"
    const edgeJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.edge.sig"
    Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", vaultJwt)
    Deno.env.set("SERVICE_ROLE_KEY", edgeJwt)
    assertEquals(
      authorizeSportsWorkerRequest(postBearer(vaultJwt), { cronSecretEnvNames: [CRON_ENV] })
        .accepted,
      true,
    )
    assertEquals(
      authorizeSportsWorkerRequest(postBearer(edgeJwt), { cronSecretEnvNames: [CRON_ENV] })
        .accepted,
      true,
    )
    assertEquals(authorizeExactServiceRoleBearer(postBearer(edgeJwt)).accepted, true)
  })
})

Deno.test("transitional bearer with configured sb_secret accepted", () => {
  withCleanAuthEnv(() => {
    Deno.env.set("SUPABASE_SECRET_KEYS", JSON.stringify({ default: SECRET_KEY }))
    const result = authorizeSportsWorkerRequest(postBearer(SECRET_KEY), {
      cronSecretEnvNames: [CRON_ENV],
    })
    assertEquals(result.accepted, true)
    if (result.accepted) assertEquals(result.source, "secret_apikey")
  })
})

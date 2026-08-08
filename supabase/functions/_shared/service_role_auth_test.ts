/**
 * Negative auth tests for exact service-role bearer matching.
 * Run: deno test supabase/functions/_shared/service_role_auth_test.ts
 */
import {
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts"
import {
  authorizeExactServiceRoleBearer,
  secretsEqual,
} from "./service_role_auth.ts"

function withEnv(key: string, value: string | null, fn: () => void) {
  const prev = Deno.env.get(key)
  if (value === null) Deno.env.delete(key)
  else Deno.env.set(key, value)
  try {
    fn()
  } finally {
    if (prev === undefined) Deno.env.delete(key)
    else Deno.env.set(key, prev)
  }
}

Deno.test("secretsEqual rejects different lengths", () => {
  assertEquals(secretsEqual("abc", "abcd"), false)
})

Deno.test("authorizeExactServiceRoleBearer accepts exact key match", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key-exact", () => {
    const req = new Request("https://example.test/fn", {
      method: "POST",
      headers: { Authorization: "Bearer srv-role-test-key-exact" },
    })
    const result = authorizeExactServiceRoleBearer(req)
    assertEquals(result.accepted, true)
  })
})

Deno.test("rejects forged JWT with role=service_role without key match", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key-exact", () => {
    // Header.payload.sig — payload claims role=service_role but is not the platform key.
    const forged =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
      btoa(JSON.stringify({ role: "service_role", iss: "supabase" }))
        .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") +
      ".forgedsignature"
    const req = new Request("https://example.test/fn", {
      method: "POST",
      headers: { Authorization: `Bearer ${forged}` },
    })
    const result = authorizeExactServiceRoleBearer(req)
    assertEquals(result.accepted, false)
    if (!result.accepted) assertEquals(result.reason, "invalid_secret")
  })
})

Deno.test("rejects unsigned / empty bearer", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key-exact", () => {
    const req = new Request("https://example.test/fn", { method: "POST" })
    const result = authorizeExactServiceRoleBearer(req)
    assertEquals(result.accepted, false)
  })
})

Deno.test("rejects ordinary user-shaped JWT", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key-exact", () => {
    const userJwt =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
      btoa(JSON.stringify({ role: "authenticated", sub: "11111111-1111-1111-1111-111111111111" }))
        .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") +
      ".sig"
    const req = new Request("https://example.test/fn", {
      method: "POST",
      headers: { Authorization: `Bearer ${userJwt}` },
    })
    const result = authorizeExactServiceRoleBearer(req)
    assertEquals(result.accepted, false)
  })
})

Deno.test("rejects GET by default", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", "srv-role-test-key-exact", () => {
    const req = new Request("https://example.test/fn", {
      method: "GET",
      headers: { Authorization: "Bearer srv-role-test-key-exact" },
    })
    const result = authorizeExactServiceRoleBearer(req)
    assertEquals(result.accepted, false)
    if (!result.accepted) assertEquals(result.reason, "method_not_allowed")
  })
})

Deno.test("misconfigured when service role key unset", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", null, () => {
    withEnv("SERVICE_ROLE_KEY", null, () => {
      withEnv("SUPABASE_SECRET_KEYS", null, () => {
        withEnv("SUPABASE_SECRET_KEY", null, () => {
          const req = new Request("https://example.test/fn", {
            method: "POST",
            headers: { Authorization: "Bearer anything" },
          })
          const result = authorizeExactServiceRoleBearer(req)
          assertEquals(result.accepted, false)
          if (!result.accepted) assertEquals(result.reason, "misconfigured")
        })
      })
    })
  })
})

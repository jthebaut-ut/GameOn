/**
 * Authoritative service-role / secret-key auth for privileged Edge Functions.
 *
 * Accepts:
 * - Authorization Bearer matching legacy SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY
 * - apikey matching configured SUPABASE_SECRET_KEYS (`sb_secret_...`)
 *
 * Does NOT trust:
 * - decoded JWT claims without key binding
 * - forged role=service_role payloads
 * - anon keys, publishable keys, user JWTs, emails, or body flags
 */

import {
  authorizeSportsWorkerRequest,
  secretsEqual,
  readServiceRoleKey,
  readServiceRoleKeyCandidates,
  readSupabaseSecretKeyCandidates,
  readAdminApiKey,
} from "./sports_worker_auth.ts"

export {
  secretsEqual,
  readServiceRoleKey,
  readServiceRoleKeyCandidates,
  readSupabaseSecretKeyCandidates,
  readAdminApiKey,
}

export type ServiceRoleAuthResult =
  | { accepted: true; source: "service_role_bearer" | "secret_apikey" }
  | {
    accepted: false
    reason: "missing_secret" | "invalid_secret" | "misconfigured" | "method_not_allowed"
  }

export function authorizeExactServiceRoleBearer(
  req: Request,
  options?: { allowMethods?: string[] },
): ServiceRoleAuthResult {
  const result = authorizeSportsWorkerRequest(req, {
    allowMethods: options?.allowMethods,
    cronSecretEnvNames: [],
  })
  if (result.accepted) {
    if (result.source === "cron_secret") {
      // No cron configured for this helper path.
      return { accepted: false, reason: "invalid_secret" }
    }
    return { accepted: true, source: result.source }
  }
  return {
    accepted: false,
    reason: result.reason === "method_not_allowed" || result.reason === "misconfigured"
        || result.reason === "missing_secret" || result.reason === "invalid_secret"
      ? result.reason
      : "invalid_secret",
  }
}

/** Dedicated cron secret only — no fallback env names. */
export function authorizeDedicatedCronSecret(
  req: Request,
  cronSecretEnvName: string,
): { accepted: true; source: "cron_secret" } | { accepted: false; reason: string } {
  const cronSecret = Deno.env.get(cronSecretEnvName)?.trim() ?? ""
  if (!cronSecret) {
    return { accepted: false, reason: "misconfigured" }
  }
  const requestCronSecret = req.headers.get("x-cron-secret")?.trim()
    ?? req.headers.get("x-fangeo-cron-secret")?.trim()
    ?? ""
  if (!requestCronSecret) {
    return { accepted: false, reason: "missing_secret" }
  }
  if (secretsEqual(requestCronSecret, cronSecret)) {
    return { accepted: true, source: "cron_secret" }
  }
  return { accepted: false, reason: "invalid_secret" }
}

export function authorizeServiceRoleOrDedicatedCron(
  req: Request,
  cronSecretEnvName: string,
  options?: { allowMethods?: string[] },
): { accepted: true; source: string } | { accepted: false; reason: string } {
  return authorizeSportsWorkerRequest(req, {
    allowMethods: options?.allowMethods,
    cronSecretEnvNames: [cronSecretEnvName],
  })
}

/**
 * Fail-closed auth for privileged sports Edge Functions
 * (`sync-live-matches`, `import-games`).
 *
 * Accepts only:
 *   - Authorization Bearer equal to SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY, OR
 *   - x-cron-secret / x-fangeo-cron-secret matching a configured cron env secret
 *
 * Does NOT trust anon keys, user JWTs, emails, roles, or body flags.
 */

export type SportsWorkerAuthResult =
  | { accepted: true; source: "service_role_bearer" | "cron_secret" }
  | { accepted: false; reason: "method_not_allowed" | "missing_secret" | "invalid_secret" | "misconfigured" }

/** Best-effort constant-time string compare for shared secrets. */
export function secretsEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false
  let mismatch = 0
  for (let i = 0; i < left.length; i++) {
    mismatch |= left.charCodeAt(i) ^ right.charCodeAt(i)
  }
  return mismatch === 0
}

export function readServiceRoleKey(): string {
  return (
    Deno.env.get("SERVICE_ROLE_KEY")?.trim()
    ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
    ?? ""
  )
}

/**
 * Resolves the first non-empty cron secret from the given env var names.
 * Callers pass function-specific names; never log returned values.
 */
export function readCronSecret(envNames: string[]): string {
  for (const name of envNames) {
    const value = Deno.env.get(name)?.trim() ?? ""
    if (value) return value
  }
  return ""
}

export function authorizeSportsWorkerRequest(
  req: Request,
  options: {
    /** Allow GET for rare ops; default POST-only (OPTIONS handled by caller). */
    allowMethods?: string[]
    /** Env var names checked for x-cron-secret (first match wins). */
    cronSecretEnvNames: string[]
  },
): SportsWorkerAuthResult {
  const allowed = options.allowMethods ?? ["POST"]
  if (!allowed.includes(req.method)) {
    return { accepted: false, reason: "method_not_allowed" }
  }

  const serviceRoleKey = readServiceRoleKey()
  const bearerToken = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "").trim() ?? ""
  if (bearerToken && serviceRoleKey && secretsEqual(bearerToken, serviceRoleKey)) {
    return { accepted: true, source: "service_role_bearer" }
  }

  const cronSecret = readCronSecret(options.cronSecretEnvNames)
  const requestCronSecret = req.headers.get("x-cron-secret")?.trim()
    ?? req.headers.get("x-fangeo-cron-secret")?.trim()
    ?? ""
  if (cronSecret && requestCronSecret && secretsEqual(requestCronSecret, cronSecret)) {
    return { accepted: true, source: "cron_secret" }
  }

  if (!serviceRoleKey && !cronSecret) {
    return { accepted: false, reason: "misconfigured" }
  }

  return {
    accepted: false,
    reason: bearerToken || requestCronSecret ? "invalid_secret" : "missing_secret",
  }
}

export function sportsWorkerAuthLog(
  functionName: string,
  outcome: "authorized" | "unauthorized",
  detail: { source?: string; reason?: string; requestId?: string | null },
): void {
  const requestId = detail.requestId?.trim() || "none"
  if (outcome === "authorized") {
    console.log(
      `[${functionName}] authorized source=${detail.source ?? "unknown"} requestId=${requestId}`,
    )
    return
  }
  console.warn(
    `[${functionName}] unauthorized reason=${detail.reason ?? "unknown"} requestId=${requestId}`,
  )
}

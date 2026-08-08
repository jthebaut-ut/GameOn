/**
 * Fail-closed auth for privileged sports / push Edge Functions.
 *
 * Accepts only:
 *   - Authorization: Bearer <legacy service_role JWT> matching
 *     SUPABASE_SERVICE_ROLE_KEY, SERVICE_ROLE_KEY, and/or
 *     fangeo_service_role_key
 *   - apikey: <sb_secret_...> matching a value from SUPABASE_SECRET_KEYS,
 *     SUPABASE_SECRET_KEY, or sb_secret_* values exposed under the legacy
 *     SERVICE_ROLE_* env names
 *   - x-cron-secret / x-fangeo-cron-secret matching a configured cron env secret
 *
 * Does NOT trust anon keys, publishable keys, user JWTs, emails, roles, or body flags.
 */

export type SportsWorkerAuthSource =
  | "service_role_bearer"
  | "secret_apikey"
  | "cron_secret"

export type SportsWorkerAuthResult =
  | { accepted: true; source: SportsWorkerAuthSource }
  | {
    accepted: false
    reason: "method_not_allowed" | "missing_secret" | "invalid_secret" | "misconfigured"
  }

/** Best-effort constant-time string compare for shared secrets. */
export function secretsEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false

  let mismatch = 0
  for (let i = 0; i < left.length; i++) {
    mismatch |= left.charCodeAt(i) ^ right.charCodeAt(i)
  }

  return mismatch === 0
}

function dedupeNonEmpty(values: string[]): string[] {
  const seen = new Set<string>()
  const out: string[] = []

  for (const value of values) {
    const trimmed = value.trim()
    if (!trimmed || seen.has(trimmed)) continue

    seen.add(trimmed)
    out.push(trimmed)
  }

  return out
}

function parseNamedKeyMap(envName: string): Record<string, string> {
  const raw = Deno.env.get(envName)?.trim() ?? ""
  if (!raw) return {}

  try {
    const parsed = JSON.parse(raw) as unknown

    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return {}
    }

    const out: Record<string, string> = {}

    for (const [name, value] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof value !== "string") continue

      const trimmed = value.trim()
      if (!trimmed) continue

      out[name] = trimmed
    }

    return out
  } catch {
    return {}
  }
}

/** True for legacy Supabase JWT-style keys. */
export function looksLikeLegacyJwt(value: string): boolean {
  return value.trim().startsWith("eyJ")
}

/** True for current Supabase server secret keys (`sb_secret_...`). */
export function looksLikeSupabaseSecretKey(value: string): boolean {
  return value.trim().startsWith("sb_secret_")
}

/** True for current Supabase publishable keys (`sb_publishable_...`). */
export function looksLikePublishableKey(value: string): boolean {
  return value.trim().startsWith("sb_publishable_")
}

/**
 * Deduplicated legacy service-role JWT candidates for Bearer auth.
 *
 * Important:
 * Supabase hosted Edge environments may now expose sb_secret_* values under
 * SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY. Those must NOT be treated as
 * legacy JWT bearer candidates.
 *
 * fangeo_service_role_key is the same custom name used by FanGeo Vault/pg_net.
 * If mirrored into Edge Function secrets, it allows the Edge worker to validate
 * the exact legacy JWT that Postgres sends.
 */
export function readServiceRoleKeyCandidates(): string[] {
  return dedupeNonEmpty([
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "",
    Deno.env.get("SERVICE_ROLE_KEY")?.trim() ?? "",
    Deno.env.get("fangeo_service_role_key")?.trim() ?? "",
  ]).filter(looksLikeLegacyJwt)
}

/**
 * Canonical legacy service-role JWT for fallback admin access.
 *
 * Prefer platform-provided SUPABASE_SERVICE_ROLE_KEY if it is actually JWT-shaped,
 * then SERVICE_ROLE_KEY, then the FanGeo mirrored Vault credential.
 */
export function readServiceRoleKey(): string {
  const candidates = readServiceRoleKeyCandidates()
  return candidates[0] ?? ""
}

/**
 * Current Supabase server secret-key candidates.
 *
 * Supabase may expose sb_secret_* values through:
 * - SUPABASE_SECRET_KEYS
 * - SUPABASE_SECRET_KEY
 * - SUPABASE_SERVICE_ROLE_KEY
 * - SERVICE_ROLE_KEY
 *
 * Only actual sb_secret_* values are accepted.
 */
export function readSupabaseSecretKeyCandidates(): string[] {
  const fromMap = Object.values(parseNamedKeyMap("SUPABASE_SECRET_KEYS"))

  const singular =
    Deno.env.get("SUPABASE_SECRET_KEY")?.trim() ?? ""

  const aliased = [
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "",
    Deno.env.get("SERVICE_ROLE_KEY")?.trim() ?? "",
  ]

  return dedupeNonEmpty([
    ...fromMap,
    singular,
    ...aliased,
  ]).filter(looksLikeSupabaseSecretKey)
}

/** Public/low-privilege keys that must never authorize privileged workers. */
export function readForbiddenPublicKeyCandidates(): string[] {
  const fromMap = Object.values(
    parseNamedKeyMap("SUPABASE_PUBLISHABLE_KEYS"),
  )

  const singularPublishable =
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY")?.trim() ?? ""

  const anon =
    Deno.env.get("SUPABASE_ANON_KEY")?.trim() ?? ""

  return dedupeNonEmpty([
    ...fromMap,
    singularPublishable,
    anon,
  ])
}

/**
 * Admin credential for privileged Supabase client access.
 *
 * Prefer the current sb_secret_* model.
 * Fall back to a valid legacy JWT.
 */
export function readAdminApiKey(): string {
  const secretCandidates = readSupabaseSecretKeyCandidates()

  if (secretCandidates.length > 0) {
    const secretMap = parseNamedKeyMap("SUPABASE_SECRET_KEYS")

    const preferredDefault =
      (secretMap["default"] ?? "").trim()

    if (
      preferredDefault
      && looksLikeSupabaseSecretKey(preferredDefault)
    ) {
      return preferredDefault
    }

    return secretCandidates[0]
  }

  return readServiceRoleKey()
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

/** Deduplicated non-empty cron secret candidates. */
export function readCronSecretCandidates(envNames: string[]): string[] {
  return dedupeNonEmpty(
    envNames.map(
      (name) => Deno.env.get(name)?.trim() ?? "",
    ),
  )
}

export function readRequestCredentialPresence(req: Request): {
  bearer: boolean
  apikey: boolean
  cron: boolean
} {
  const bearerToken =
    req.headers
      .get("Authorization")
      ?.replace(/^Bearer\s+/i, "")
      .trim() ?? ""

  const apikey =
    req.headers.get("apikey")?.trim() ?? ""

  const cron =
    (
      req.headers.get("x-cron-secret")?.trim()
      ?? req.headers.get("x-fangeo-cron-secret")?.trim()
      ?? ""
    ) !== ""

  return {
    bearer: bearerToken.length > 0,
    apikey: apikey.length > 0,
    cron,
  }
}

/** Safe boolean class summary — never includes secret material. */
export function describeAuthCandidateClasses(
  cronSecretEnvNames: string[] = [],
): {
  legacy: boolean
  secretKeys: boolean
  forbiddenPublic: boolean
  cronConfigured: boolean
} {
  return {
    legacy: readServiceRoleKeyCandidates().length > 0,
    secretKeys: readSupabaseSecretKeyCandidates().length > 0,
    forbiddenPublic: readForbiddenPublicKeyCandidates().length > 0,
    cronConfigured:
      readCronSecretCandidates(cronSecretEnvNames).length > 0,
  }
}

function matchesAny(
  value: string,
  candidates: string[],
): boolean {
  if (!value || candidates.length === 0) {
    return false
  }

  return candidates.some(
    (candidate) => secretsEqual(value, candidate),
  )
}

export function authorizeSportsWorkerRequest(
  req: Request,
  options: {
    /** Allow GET for rare ops; default POST-only (OPTIONS handled by caller). */
    allowMethods?: string[]

    /**
     * Env var names checked for x-cron-secret.
     * Any configured exact match accepts.
     */
    cronSecretEnvNames: string[]
  },
): SportsWorkerAuthResult {
  const allowed =
    options.allowMethods ?? ["POST"]

  if (!allowed.includes(req.method)) {
    return {
      accepted: false,
      reason: "method_not_allowed",
    }
  }

  const legacyCandidates =
    readServiceRoleKeyCandidates()

  const secretCandidates =
    readSupabaseSecretKeyCandidates()

  const forbiddenPublic =
    readForbiddenPublicKeyCandidates()

  const cronCandidates =
    readCronSecretCandidates(
      options.cronSecretEnvNames,
    )

  const bearerToken =
    req.headers
      .get("Authorization")
      ?.replace(/^Bearer\s+/i, "")
      .trim() ?? ""

  const apikey =
    req.headers.get("apikey")?.trim() ?? ""

  const requestCronSecret =
    req.headers.get("x-cron-secret")?.trim()
    ?? req.headers.get("x-fangeo-cron-secret")?.trim()
    ?? ""

  // Never authorize with anon/publishable material on either header.
  if (
    (apikey && matchesAny(apikey, forbiddenPublic))
    || (bearerToken && matchesAny(bearerToken, forbiddenPublic))
    || (apikey && looksLikePublishableKey(apikey))
    || (bearerToken && looksLikePublishableKey(bearerToken))
  ) {
    return {
      accepted: false,
      reason: "invalid_secret",
    }
  }

  // Preferred current style:
  // sb_secret_* through apikey header.
  if (
    apikey
    && looksLikeSupabaseSecretKey(apikey)
    && matchesAny(apikey, secretCandidates)
  ) {
    return {
      accepted: true,
      source: "secret_apikey",
    }
  }

  // Legacy style:
  // service_role JWT through Authorization Bearer.
  if (
    bearerToken
    && looksLikeLegacyJwt(bearerToken)
    && matchesAny(
      bearerToken,
      legacyCandidates,
    )
  ) {
    return {
      accepted: true,
      source: "service_role_bearer",
    }
  }

  // Transitional compatibility:
  // if Vault temporarily sends an sb_secret_* value using Authorization,
  // accept it ONLY if it exactly matches a configured server secret key.
  if (
    bearerToken
    && looksLikeSupabaseSecretKey(bearerToken)
    && matchesAny(
      bearerToken,
      secretCandidates,
    )
  ) {
    return {
      accepted: true,
      source: "secret_apikey",
    }
  }

  // Optional cron-secret path.
  if (
    requestCronSecret
    && cronCandidates.some(
      (candidate) =>
        secretsEqual(
          requestCronSecret,
          candidate,
        ),
    )
  ) {
    return {
      accepted: true,
      source: "cron_secret",
    }
  }

  if (
    legacyCandidates.length === 0
    && secretCandidates.length === 0
    && cronCandidates.length === 0
  ) {
    return {
      accepted: false,
      reason: "misconfigured",
    }
  }

  return {
    accepted: false,
    reason:
      bearerToken
      || apikey
      || requestCronSecret
        ? "invalid_secret"
        : "missing_secret",
  }
}

export function sportsWorkerAuthLog(
  functionName: string,
  outcome: "authorized" | "unauthorized",
  detail: {
    source?: string
    reason?: string
    requestId?: string | null
    attempted?: string
    candidates?: {
      legacy: boolean
      secretKeys: boolean
      cronConfigured: boolean
    }
  },
): void {
  const requestId =
    detail.requestId?.trim() || "none"

  if (detail.candidates) {
    console.log(
      `[${functionName}] auth candidates ` +
        `legacy=${detail.candidates.legacy} ` +
        `secretKeys=${detail.candidates.secretKeys} ` +
        `cron=${detail.candidates.cronConfigured}`,
    )
  }

  if (outcome === "authorized") {
    console.log(
      `[${functionName}] invocation ` +
        `auth=${detail.source ?? "unknown"} ` +
        `accepted=true ` +
        `attempted=${detail.attempted ?? "n/a"} ` +
        `requestId=${requestId}`,
    )
    return
  }

  console.warn(
    `[${functionName}] unauthorized ` +
      `reason=${detail.reason ?? "unknown"} ` +
      `attempted=${detail.attempted ?? "none"} ` +
      `requestId=${requestId}`,
  )
}
import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

/**
 * Finalizes a business account soft-deletion job after DB commit:
 * - deletes venue photo objects from venue-photos (best-effort)
 * - advances business_account_deletion_jobs to completed via service-role RPC
 *
 * Phase 2 intentionally does NOT delete auth.users or account_identities.
 *
 * Auth: service_role bearer only (pg_net queue / ops).
 * Accepts legacy service_role JWT (Vault) or exact match on SUPABASE_SERVICE_ROLE_KEY (sb_secret_*).
 *
 * Deploy: `supabase functions deploy finalize-business-account-deletion`
 */

interface Payload {
  job_id?: string
}

interface StorageResult {
  path: string
  ok: boolean
  error?: string
}

const LOG_PREFIX = "[BusinessAccountDeletionFinalize]"
const VENUE_PHOTOS_BUCKET = "venue-photos"

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}

function normalizePaths(paths: unknown): string[] {
  if (!Array.isArray(paths)) return []
  return paths
    .map((value) => (typeof value === "string" ? value.trim() : ""))
    .filter((value) => value.length > 0 && !value.includes("..") && !value.startsWith("/"))
}

function isBenignMissingObjectError(message: string): boolean {
  const normalized = message.toLowerCase()
  return (
    normalized.includes("not found")
    || normalized.includes("does not exist")
    || normalized.includes("no such file")
    || normalized.includes("object not found")
  )
}

async function sha256Fingerprint(value: string): Promise<string> {
  if (!value) return "empty"
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 8)
}

function bearerCredentialFormat(token: string): "empty" | "jwt" | "secret" | "unknown" {
  if (!token) return "empty"
  if (token.split(".").length === 3) return "jwt"
  if (token.startsWith("sb_secret_")) return "secret"
  return "unknown"
}

function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split(".")
  if (parts.length !== 3) return null

  try {
    const base64Url = parts[1]
    const base64 = base64Url.replace(/-/g, "+").replace(/_/g, "/")
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4)
    const json = atob(padded)
    const payload = JSON.parse(json) as Record<string, unknown>
    return payload && typeof payload === "object" ? payload : null
  } catch {
    return null
  }
}

function isLegacyServiceRoleJwt(token: string): boolean {
  const payload = decodeJwtPayload(token)
  if (!payload) return false
  return String(payload.role ?? "") === "service_role"
}

function resolveAuthorizedServiceRoleCredential(
  bearerToken: string,
  platformServiceRoleKey: string,
): string | null {
  if (!bearerToken) return null

  if (platformServiceRoleKey && bearerToken === platformServiceRoleKey) {
    return bearerToken
  }

  if (isLegacyServiceRoleJwt(bearerToken)) {
    return bearerToken
  }

  return null
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? ""
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? ""

  if (!supabaseUrl || !serviceRoleKey) {
    console.error(`${LOG_PREFIX} server_misconfigured`)
    return json({ ok: false, error: "server_misconfigured" }, 500)
  }

  let payload: Payload
  try {
    payload = await req.json() as Payload
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400)
  }

  const jobId = payload.job_id?.trim()
  if (!jobId) {
    return json({ ok: false, error: "job_id_required" }, 400)
  }

  const authorizationHeader = req.headers.get("Authorization")
  const bearerToken = authorizationHeader?.replace(/^Bearer\s+/i, "").trim() ?? ""
  const adminCredential = resolveAuthorizedServiceRoleCredential(bearerToken, serviceRoleKey)

  if (!adminCredential) {
    const bearerFingerprint = await sha256Fingerprint(bearerToken)
    const expectedFingerprint = await sha256Fingerprint(serviceRoleKey)
    console.error(
      `${LOG_PREFIX} auth_mismatch authorization_present=${Boolean(authorizationHeader)} bearer_len=${bearerToken.length} expected_len=${serviceRoleKey.length} bearer_fp=${bearerFingerprint} expected_fp=${expectedFingerprint} bearer_format=${bearerCredentialFormat(bearerToken)} platform_key_format=${bearerCredentialFormat(serviceRoleKey)}`,
    )
    return json({ ok: false, error: "unauthorized" }, 401)
  }

  const admin = createClient(supabaseUrl, adminCredential, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: job, error: jobError } = await admin
    .from("business_account_deletion_jobs")
    .select("id, subject_business_id, subject_user_id, status, stage, storage_paths, deletion_mode, completed_at")
    .eq("id", jobId)
    .maybeSingle()

  if (jobError) {
    console.error(`${LOG_PREFIX} job_load_failed`, jobError.message)
    return json({ ok: false, error: "job_load_failed", detail: jobError.message }, 500)
  }

  if (!job) {
    return json({ ok: false, error: "job_not_found" }, 404)
  }

  if (job.deletion_mode !== "soft") {
    return json({ ok: false, error: "hard_deletion_not_enabled" }, 403)
  }

  if (job.status === "completed") {
    return json({
      ok: true,
      job_id: job.id,
      business_id: job.subject_business_id,
      status: job.status,
      stage: job.stage,
      completed_at: job.completed_at,
      idempotent_replay: true,
      auth_users_deleted: false,
      account_identities_deleted: false,
    })
  }

  if (!["db_committed", "storage_pending"].includes(job.status)) {
    return json({
      ok: false,
      error: "job_not_ready_for_finalize",
      status: job.status,
      stage: job.stage,
    }, 409)
  }

  const paths = normalizePaths(job.storage_paths)
  const storageResults: StorageResult[] = []

  if (job.status === "db_committed") {
    const { error: pendingError } = await admin.rpc("advance_business_account_deletion_job", {
      p_job_id: jobId,
      p_action: "mark_storage_pending",
    })

    if (pendingError) {
      console.error(`${LOG_PREFIX} mark_storage_pending_failed`, pendingError.message)
      return json({ ok: false, error: "advance_failed", detail: pendingError.message }, 500)
    }
  }

  if (paths.length > 0) {
    for (const path of paths) {
      try {
        const { error } = await admin.storage.from(VENUE_PHOTOS_BUCKET).remove([path])
        if (error) {
          if (isBenignMissingObjectError(error.message)) {
            storageResults.push({ path, ok: true })
          } else {
            storageResults.push({ path, ok: false, error: error.message })
          }
        } else {
          storageResults.push({ path, ok: true })
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        if (isBenignMissingObjectError(message)) {
          storageResults.push({ path, ok: true })
        } else {
          storageResults.push({ path, ok: false, error: message })
        }
      }
    }
  }

  const allStorageOk = storageResults.every((result) => result.ok)
  const failedResults = storageResults.filter((result) => !result.ok)

  if (allStorageOk) {
    const { data: advanced, error: advanceError } = await admin.rpc("advance_business_account_deletion_job", {
      p_job_id: jobId,
      p_action: "mark_completed",
    })

    if (advanceError) {
      console.error(`${LOG_PREFIX} mark_completed_failed`, advanceError.message)
      return json({ ok: false, error: "advance_failed", detail: advanceError.message }, 500)
    }

    const advancedRecord = advanced as { status?: string; stage?: string } | null

    console.log(`${LOG_PREFIX} completed job=${jobId} storagePaths=${paths.length}`)

    return json({
      ok: true,
      job_id: job.id,
      business_id: job.subject_business_id,
      status: advancedRecord?.status ?? "completed",
      stage: advancedRecord?.stage ?? "completed",
      storage_results: storageResults,
      auth_users_deleted: false,
      account_identities_deleted: false,
    })
  }

  const { data: partial, error: partialError } = await admin.rpc("advance_business_account_deletion_job", {
    p_job_id: jobId,
    p_action: "mark_storage_partial",
    p_error_code: "storage_cleanup_partial",
    p_error_detail: JSON.stringify(failedResults),
  })

  if (partialError) {
    console.error(`${LOG_PREFIX} mark_storage_partial_failed`, partialError.message)
    return json({ ok: false, error: "advance_failed", detail: partialError.message }, 500)
  }

  const partialRecord = partial as { status?: string; stage?: string } | null

  console.error(`${LOG_PREFIX} storage_cleanup_partial job=${jobId} failures=${failedResults.length}`)

  return json({
    ok: false,
    error: "storage_cleanup_partial",
    job_id: job.id,
    business_id: job.subject_business_id,
    status: partialRecord?.status ?? "storage_pending",
    stage: partialRecord?.stage ?? "storage_cleanup_partial",
    storage_results: storageResults,
    auth_users_deleted: false,
    account_identities_deleted: false,
  }, 500)
})

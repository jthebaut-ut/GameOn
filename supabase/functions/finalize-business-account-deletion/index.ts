import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"

/**
 * Finalizes a business account deletion job after DB commit.
 *
 * Soft mode (deletion_mode = soft):
 * - deletes venue photo objects from venue-photos (best-effort)
 * - advances business_account_deletion_jobs to completed
 * - does NOT delete auth.users or account_identities
 *
 * Permanent mode (deletion_mode = permanent, 20260898 / 20260901 / 20260902):
 * - deletes auth.users for subject_user_id via Admin API (only after DB stages)
 * - then deletes venue photo objects
 * - finalizes linked owner account_deletion_jobs in this Edge (20260901):
 *     zero-path via sync RPC; avatar paths deleted from user-avatars using this
 *     function's trusted service-role credential (never Vault/pg_net fan queue)
 * - advances business job to completed only after child owner job is completed
 * - never restores DB tombstone/ownership detach on Auth/storage failure
 * - ready statuses are auth_delete_pending|storage_pending only (NOT soft db_committed);
 *   soft→permanent promotion (20260902) bumps off db_committed before Auth
 *
 * Auth: service_role bearer only (pg_net queue / ops).
 * Accepts legacy service_role JWT (Vault) or exact match on SUPABASE_SERVICE_ROLE_KEY (sb_secret_*).
 *
 * Deploy: `supabase functions deploy finalize-business-account-deletion`
 * (after applying migrations through 20260902).
 */

interface Payload {
  job_id?: string
  deletion_mode?: string
  permanent?: boolean
  auth_delete_pending?: boolean
  subject_user_id?: string
  user_deletion_job_id?: string
}

interface StorageResult {
  path: string
  ok: boolean
  error?: string
}

type JobRow = {
  id: string
  subject_business_id: string
  subject_user_id: string | null
  status: string
  stage: string
  storage_paths: unknown
  deletion_mode: string
  completed_at: string | null
  permanent_finalize_ready?: boolean | null
  user_deletion_job_id?: string | null
}

const LOG_PREFIX = "[BusinessAccountDeletionFinalize]"
const VENUE_PHOTOS_BUCKET = "venue-photos"
const AVATAR_BUCKET = "user-avatars"

type OwnerUserJobRow = {
  id: string
  subject_user_id: string
  status: string
  stage: string
  avatar_storage_paths: unknown
  deletion_mode: string | null
}

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

function isBenignAuthUserMissingError(message: string): boolean {
  const normalized = message.toLowerCase()
  return (
    normalized.includes("user not found")
    || normalized.includes("user_not_found")
    || normalized.includes("does not exist")
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
    const jsonText = atob(padded)
    const payload = JSON.parse(jsonText) as Record<string, unknown>
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

async function cleanupVenuePhotos(
  admin: SupabaseClient,
  paths: string[],
): Promise<StorageResult[]> {
  const storageResults: StorageResult[] = []

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

  return storageResults
}

/** Only allow deleting objects under the deletion subject's folder. */
function pathsOwnedBySubject(paths: string[], subjectUserId: string): {
  allowed: string[]
  rejected: string[]
} {
  const prefix = `${subjectUserId}/`
  const allowed: string[] = []
  const rejected: string[] = []
  for (const path of paths) {
    if (path === subjectUserId || path.startsWith(prefix)) {
      allowed.push(path)
    } else {
      rejected.push(path)
    }
  }
  return { allowed, rejected }
}

async function removeAvatarPath(
  admin: SupabaseClient,
  path: string,
): Promise<{ path: string; ok: boolean; already_missing?: boolean; error?: string }> {
  try {
    const { error } = await admin.storage.from(AVATAR_BUCKET).remove([path])
    if (!error) {
      return { path, ok: true }
    }
    if (isBenignMissingObjectError(error.message)) {
      return { path, ok: true, already_missing: true }
    }
    return { path, ok: false, error: error.message }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (isBenignMissingObjectError(message)) {
      return { path, ok: true, already_missing: true }
    }
    return { path, ok: false, error: message }
  }
}

/**
 * Finalize the linked permanent-business owner user job using this Edge's
 * trusted service-role credential. Does not call the Vault/pg_net fan queue.
 */
async function finalizeLinkedOwnerUserJob(
  admin: SupabaseClient,
  job: JobRow,
): Promise<{
  ok: boolean
  error?: string
  detail?: string
  owner_user_job_status?: string
  avatar_results?: Array<Record<string, unknown>>
  sync?: unknown
}> {
  const userJobId = job.user_deletion_job_id
  if (!userJobId) {
    return { ok: true }
  }

  const { data: childData, error: childLoadError } = await admin
    .from("account_deletion_jobs")
    .select("id, subject_user_id, status, stage, avatar_storage_paths, deletion_mode")
    .eq("id", userJobId)
    .maybeSingle()

  if (childLoadError) {
    return { ok: false, error: "owner_user_job_load_failed", detail: childLoadError.message }
  }

  if (!childData) {
    return { ok: false, error: "owner_user_job_missing", detail: `Owner user job ${userJobId} is missing` }
  }

  const child = childData as OwnerUserJobRow

  if (job.subject_user_id && child.subject_user_id !== job.subject_user_id) {
    return {
      ok: false,
      error: "owner_user_subject_mismatch",
      detail: `Business subject ${job.subject_user_id} != user job subject ${child.subject_user_id}`,
    }
  }

  if (child.status === "completed") {
    return { ok: true, owner_user_job_status: "completed" }
  }

  if (!["db_committed", "storage_pending"].includes(child.status)) {
    return {
      ok: false,
      error: "owner_user_job_not_ready",
      detail: `Owner user job status ${child.status} is not finalizable`,
      owner_user_job_status: child.status,
    }
  }

  const rawPaths = normalizePaths(child.avatar_storage_paths)

  // Zero-path: authoritative DB sync completes the child without storage work.
  if (rawPaths.length === 0) {
    const { data: sync, error: syncError } = await admin.rpc(
      "gameon_permanent_business_sync_owner_user_job",
      {
        p_user_job_id: userJobId,
        p_business_job_id: job.id,
      },
    )

    if (syncError) {
      return { ok: false, error: "owner_user_job_sync_failed", detail: syncError.message, sync }
    }

    const status = (sync as { status?: string } | null)?.status
    if (status !== "completed") {
      return {
        ok: false,
        error: "owner_user_job_not_completed",
        detail: `Zero-path sync left owner job at ${status ?? "unknown"}`,
        owner_user_job_status: status,
        sync,
      }
    }

    return { ok: true, owner_user_job_status: "completed", sync }
  }

  // Avatar-bearing: claim storage_pending via sync, then delete with Edge credentials.
  const { data: sync, error: syncError } = await admin.rpc(
    "gameon_permanent_business_sync_owner_user_job",
    {
      p_user_job_id: userJobId,
      p_business_job_id: job.id,
    },
  )

  if (syncError) {
    return { ok: false, error: "owner_user_job_sync_failed", detail: syncError.message, sync }
  }

  const { allowed: paths, rejected } = pathsOwnedBySubject(rawPaths, child.subject_user_id)
  const avatarResults: Array<Record<string, unknown>> = []

  for (const path of rejected) {
    avatarResults.push({
      path,
      ok: false,
      rejected: true,
      error: "path_not_owned_by_subject",
    })
  }

  for (const path of paths) {
    avatarResults.push(await removeAvatarPath(admin, path))
  }

  const deletable = avatarResults.filter((result) => result.rejected !== true)
  const allOk = rejected.length === 0 && deletable.every((result) => result.ok === true)
  const advanceAction = allOk ? "mark_completed" : "mark_storage_partial"

  const { data: advanced, error: advanceError } = await admin.rpc("advance_account_deletion_job", {
    p_job_id: userJobId,
    p_action: advanceAction,
    p_error_code: advanceAction === "mark_storage_partial" ? "storage_cleanup_partial" : null,
    p_error_detail: advanceAction === "mark_storage_partial"
      ? JSON.stringify(avatarResults)
      : "permanent_business_owner_edge_avatar_cleanup",
  })

  if (advanceError) {
    return {
      ok: false,
      error: "owner_user_job_advance_failed",
      detail: advanceError.message,
      avatar_results: avatarResults,
      sync,
    }
  }

  const ownerStatus = (advanced as { status?: string } | null)?.status
  if (!allOk || ownerStatus !== "completed") {
    return {
      ok: false,
      error: "owner_avatar_cleanup_partial",
      detail: "Owner avatar cleanup incomplete; business finalizer is resumable",
      owner_user_job_status: ownerStatus,
      avatar_results: avatarResults,
      sync,
    }
  }

  return {
    ok: true,
    owner_user_job_status: "completed",
    avatar_results: avatarResults,
    sync,
  }
}

async function deleteAuthUserIfNeeded(
  admin: SupabaseClient,
  userId: string | null | undefined,
): Promise<{ deleted: boolean; already_missing: boolean; error?: string }> {
  if (!userId) {
    return { deleted: false, already_missing: true, error: "missing_subject_user_id" }
  }

  const { error } = await admin.auth.admin.deleteUser(userId)
  if (!error) {
    return { deleted: true, already_missing: false }
  }

  if (isBenignAuthUserMissingError(error.message)) {
    return { deleted: true, already_missing: true }
  }

  return { deleted: false, already_missing: false, error: error.message }
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

  const { data: jobData, error: jobError } = await admin
    .from("business_account_deletion_jobs")
    .select(
      "id, subject_business_id, subject_user_id, status, stage, storage_paths, deletion_mode, completed_at, permanent_finalize_ready, user_deletion_job_id",
    )
    .eq("id", jobId)
    .maybeSingle()

  if (jobError) {
    console.error(`${LOG_PREFIX} job_load_failed`, jobError.message)
    return json({ ok: false, error: "job_load_failed", detail: jobError.message }, 500)
  }

  if (!jobData) {
    return json({ ok: false, error: "job_not_found" }, 404)
  }

  const job = jobData as JobRow
  const isPermanent = job.deletion_mode === "permanent"
  const isSoft = job.deletion_mode === "soft"

  if (!isSoft && !isPermanent) {
    return json({
      ok: false,
      error: "unsupported_deletion_mode",
      deletion_mode: job.deletion_mode,
    }, 403)
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
      deletion_mode: job.deletion_mode,
      auth_users_deleted: isPermanent,
      account_identities_deleted: isPermanent,
    })
  }

  // Permanent must NOT treat soft db_committed as ready — that status is Edge-ready
  // only for soft storage finalize. Soft→permanent promotion bumps off db_committed
  // before permanent DB stages; Auth/storage run only after auth_delete_pending
  // (permanent_finalize_ready) or storage_pending retries.
  const readyStatuses = isPermanent
    ? ["auth_delete_pending", "storage_pending"]
    : ["db_committed", "storage_pending"]

  if (!readyStatuses.includes(job.status)) {
    return json({
      ok: false,
      error: "job_not_ready_for_finalize",
      status: job.status,
      stage: job.stage,
      deletion_mode: job.deletion_mode,
    }, 409)
  }

  if (
    isPermanent &&
    job.status === "auth_delete_pending" &&
    job.permanent_finalize_ready === false
  ) {
    return json({
      ok: false,
      error: "permanent_finalize_not_ready",
      status: job.status,
      stage: job.stage,
      deletion_mode: job.deletion_mode,
    }, 409)
  }

  let authUsersDeleted = false
  let authAlreadyMissing = false

  // Permanent path: Auth delete only at auth_delete_pending (DB stages already
  // committed). storage_pending retries may re-check Auth idempotently below.
  if (isPermanent && (job.status === "auth_delete_pending" || (job.status === "storage_pending" && job.stage !== "auth_deleted"))) {
    const authResult = await deleteAuthUserIfNeeded(
      admin,
      job.subject_user_id ?? payload.subject_user_id,
    )

    if (!authResult.deleted) {
      console.error(`${LOG_PREFIX} auth_delete_failed`, authResult.error)
      // Leave status at auth_delete_pending. DB cleanup is already committed and
      // must not be undone; the Admin orchestrator can re-queue finalize.
      return json({
        ok: false,
        error: "auth_delete_failed",
        detail: authResult.error,
        job_id: job.id,
        business_id: job.subject_business_id,
        status: job.status,
        stage: job.stage,
        deletion_mode: "permanent",
        auth_users_deleted: false,
        account_identities_deleted: true,
        resumable: true,
      }, 500)
    }

    authUsersDeleted = true
    authAlreadyMissing = authResult.already_missing

    const { error: authAdvanceError } = await admin.rpc("advance_business_account_deletion_job", {
      p_job_id: jobId,
      p_action: "mark_auth_deleted",
    })

    if (authAdvanceError) {
      console.error(`${LOG_PREFIX} mark_auth_deleted_failed`, authAdvanceError.message)
      return json({
        ok: false,
        error: "advance_failed",
        detail: authAdvanceError.message,
        auth_users_deleted: true,
        resumable: true,
      }, 500)
    }
  }

  // Move to storage_pending when still at db_committed / auth_delete_pending.
  if (job.status === "db_committed" || job.status === "auth_delete_pending") {
    const { error: pendingError } = await admin.rpc("advance_business_account_deletion_job", {
      p_job_id: jobId,
      p_action: "mark_storage_pending",
    })

    if (pendingError) {
      console.error(`${LOG_PREFIX} mark_storage_pending_failed`, pendingError.message)
      return json({
        ok: false,
        error: "advance_failed",
        detail: pendingError.message,
        auth_users_deleted: authUsersDeleted,
        resumable: true,
      }, 500)
    }
  }

  const paths = normalizePaths(job.storage_paths)
  const storageResults = await cleanupVenuePhotos(admin, paths)
  const allStorageOk = storageResults.every((result) => result.ok)
  const failedResults = storageResults.filter((result) => !result.ok)

  if (allStorageOk) {
    let ownerFinalize: Awaited<ReturnType<typeof finalizeLinkedOwnerUserJob>> | null = null

    // Permanent mode: finalize linked owner user job with this Edge's credentials
    // before parent mark_completed (positive child-completed proof is also gated in SQL).
    if (isPermanent && job.user_deletion_job_id) {
      ownerFinalize = await finalizeLinkedOwnerUserJob(admin, job)

      if (!ownerFinalize.ok) {
        console.error(
          `${LOG_PREFIX} owner_user_finalize_failed`,
          ownerFinalize.error,
          ownerFinalize.detail,
        )
        return json({
          ok: false,
          error: ownerFinalize.error ?? "owner_user_finalize_failed",
          detail: ownerFinalize.detail,
          user_deletion_job_id: job.user_deletion_job_id,
          owner_user_job_status: ownerFinalize.owner_user_job_status,
          owner_avatar_results: ownerFinalize.avatar_results,
          owner_sync: ownerFinalize.sync,
          auth_users_deleted: true,
          storage_results: storageResults,
          resumable: true,
        }, 500)
      }
    }

    const { data: advanced, error: advanceError } = await admin.rpc("advance_business_account_deletion_job", {
      p_job_id: jobId,
      p_action: "mark_completed",
    })

    if (advanceError) {
      console.error(`${LOG_PREFIX} mark_completed_failed`, advanceError.message)
      return json({
        ok: false,
        error: "advance_failed",
        detail: advanceError.message,
        auth_users_deleted: isPermanent ? true : false,
        resumable: true,
      }, 500)
    }

    const advancedRecord = advanced as { status?: string; stage?: string } | null

    console.log(
      `${LOG_PREFIX} completed job=${jobId} mode=${job.deletion_mode} storagePaths=${paths.length} authDeleted=${isPermanent} ownerJob=${ownerFinalize?.owner_user_job_status ?? "n/a"}`,
    )

    return json({
      ok: true,
      job_id: job.id,
      business_id: job.subject_business_id,
      status: advancedRecord?.status ?? "completed",
      stage: advancedRecord?.stage ?? "completed",
      deletion_mode: job.deletion_mode,
      storage_results: storageResults,
      owner_user_job_status: ownerFinalize?.owner_user_job_status ?? null,
      owner_avatar_results: ownerFinalize?.avatar_results ?? null,
      auth_users_deleted: isPermanent,
      auth_user_already_missing: authAlreadyMissing,
      account_identities_deleted: isPermanent,
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
    return json({
      ok: false,
      error: "advance_failed",
      detail: partialError.message,
      auth_users_deleted: isPermanent,
      resumable: true,
    }, 500)
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
    deletion_mode: job.deletion_mode,
    storage_results: storageResults,
    auth_users_deleted: isPermanent,
    account_identities_deleted: isPermanent,
    resumable: true,
  }, 500)
})

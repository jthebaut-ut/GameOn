import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

/**
 * Finalizes a fan account soft-deletion job after DB commit:
 * - deletes avatar objects from user-avatars (best-effort)
 * - advances account_deletion_jobs to completed via whitelisted service-role RPC
 *
 * Phase 2 intentionally does NOT call auth.admin.deleteUser or release identities.
 *
 * Auth:
 * - Service role bearer (pg_net retry / ops), or
 * - User JWT where sub matches job.subject_user_id (self-service iOS finalize)
 *
 * Deploy: `supabase functions deploy finalize-account-deletion`
 */

interface Payload {
  job_id?: string
}

const LOG_PREFIX = "[AccountDeletionFinalize]"
const AVATAR_BUCKET = "user-avatars"

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
    .filter((value) => value.length > 0)
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405)
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL")?.trim()
    ?? Deno.env.get("SUPABASE_URL")?.trim()
    ?? ""
  const serviceRoleKey = Deno.env.get("SERVICE_ROLE_KEY")?.trim()
    ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
    ?? ""
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")?.trim()
    ?? Deno.env.get("ANON_KEY")?.trim()
    ?? ""

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

  const bearerToken = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "").trim() ?? ""
  const isServiceRole = bearerToken.length > 0 && bearerToken === serviceRoleKey

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: job, error: jobError } = await admin
    .from("account_deletion_jobs")
    .select("id, subject_user_id, status, stage, avatar_storage_paths, deletion_mode")
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

  if (!isServiceRole) {
    if (!anonKey || !bearerToken) {
      return json({ ok: false, error: "unauthorized" }, 401)
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${bearerToken}` } },
    })

    const { data: userData, error: userError } = await userClient.auth.getUser()
    if (userError || !userData.user) {
      return json({ ok: false, error: "unauthorized" }, 401)
    }

    if (userData.user.id !== job.subject_user_id) {
      return json({ ok: false, error: "forbidden" }, 403)
    }
  }

  if (job.status === "completed") {
    return json({
      ok: true,
      job_id: job.id,
      status: job.status,
      stage: job.stage,
      idempotent_replay: true,
      auth_users_deleted: false,
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

  const paths = normalizePaths(job.avatar_storage_paths)
  const storageResults: Array<{ path: string; ok: boolean; error?: string }> = []

  if (paths.length > 0) {
    const { error: pendingError } = await admin.rpc("advance_account_deletion_job", {
      p_job_id: jobId,
      p_action: "mark_storage_pending",
    })

    if (pendingError) {
      console.error(`${LOG_PREFIX} mark_storage_pending_failed`, pendingError.message)
      return json({ ok: false, error: "advance_failed", detail: pendingError.message }, 500)
    }

    for (const path of paths) {
      try {
        const { error } = await admin.storage.from(AVATAR_BUCKET).remove([path])
        if (error) {
          storageResults.push({ path, ok: false, error: error.message })
        } else {
          storageResults.push({ path, ok: true })
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        storageResults.push({ path, ok: false, error: message })
      }
    }
  }

  const allStorageOk = storageResults.every((result) => result.ok)
  const advanceAction = allStorageOk || paths.length === 0 ? "mark_completed" : "mark_storage_partial"

  const { data: advanced, error: advanceError } = await admin.rpc("advance_account_deletion_job", {
    p_job_id: jobId,
    p_action: advanceAction,
    p_error_code: advanceAction === "mark_storage_partial" ? "storage_cleanup_partial" : null,
    p_error_detail: advanceAction === "mark_storage_partial"
      ? JSON.stringify(storageResults.filter((result) => !result.ok))
      : null,
  })

  if (advanceError) {
    console.error(`${LOG_PREFIX} advance_failed`, advanceError.message)
    return json({ ok: false, error: "advance_failed", detail: advanceError.message }, 500)
  }

  const advancedRecord = advanced as { status?: string; stage?: string } | null
  const nextStatus = advancedRecord?.status ?? (allStorageOk || paths.length === 0 ? "completed" : "storage_pending")
  const nextStage = advancedRecord?.stage ?? (allStorageOk || paths.length === 0 ? "completed" : "storage_cleanup_partial")

  console.log(`${LOG_PREFIX} completed job=${jobId} storagePaths=${paths.length} allStorageOk=${allStorageOk}`)

  return json({
    ok: true,
    job_id: job.id,
    status: nextStatus,
    stage: nextStage,
    storage_results: storageResults,
    auth_users_deleted: false,
    account_identities_deleted: false,
    email_released: false,
  })
})

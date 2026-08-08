import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

/**
 * Admin email for moderation reports (user / conversation / message / group_conversation / group_message).
 *
 * Secrets (set via `supabase secrets set`):
 *   ADMIN_EMAIL_TO, RESEND_API_KEY, RESEND_FROM
 * Optional:
 *   ADMIN_REPORT_REVIEW_BASE_URL
 * Auto-provided on hosted projects:
 *   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
 *
 * Deploy: `supabase functions deploy notify-moderation-report`
 *
 * Auth:
 * - User JWT (iOS best-effort invoke for user/conversation/message/group types)
 * - Service-role bearer (preferred async pg_net queue for group_conversation / group_message)
 *
 * Conversation-report emails read the bounded `conversation_reports.message_snapshot`
 * from the database only when `admin_review_consent_granted === true` (never from client
 * payload, never full DM history). Group conversation emails load title/member
 * snapshots only. Group / DM message emails prefer stored `message_text_snapshot` from
 * `group_message_reports` / `message_reports` over client payload.
 */

type ReportType = "user" | "conversation" | "message" | "group_conversation" | "group_message"

/** Client may send `reporter_user_id`; it is ignored for JWT callers — reporter is JWT subject. */
interface Payload {
  report_id?: string | null
  report_type: ReportType
  /** Required for user / conversation / message JWT path. Optional when DB row is loaded. */
  reported_user_id?: string | null
  category?: string | null
  details?: string | null
  created_at?: string | null
  conversation_id?: string | null
  message_id?: string | null
  message_text_snapshot?: string | null
  review_window_start?: string | null
  review_window_end?: string | null
  /** @deprecated Ignored for evidence. Conversation body comes only from DB when consent is granted. */
  conversation_message_snapshot?: ConversationMessageSnapshot[] | null
  group_title?: string | null
  member_count?: number | null
  source?: string | null
  /** @deprecated Ignored; use JWT subject only. */
  reporter_user_id?: string | null
}

interface ConversationMessageSnapshot {
  id?: string | null
  conversation_id?: string | null
  sender_id?: string | null
  body?: string | null
  created_at?: string | null
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

const MAX_SNAPSHOT_LEN = 4000
const MAX_CONVERSATION_CONTEXT_LEN = 12000
const MAX_SNAPSHOT_MESSAGES = 80

interface ConversationReportRow {
  id: string
  reporter_user_id: string
  reported_user_id: string
  conversation_id: string
  category: string
  details: string | null
  review_window_start: string | null
  review_window_end: string | null
  message_snapshot: ConversationMessageSnapshot[] | null
  admin_review_consent_granted: boolean | null
  created_at: string | null
}

interface GroupConversationReportRow {
  id: string
  reporter_user_id: string
  group_conversation_id: string
  category: string
  details: string | null
  group_title_snapshot: string | null
  member_count_snapshot: number | null
  moderation_notified_at: string | null
  created_at: string | null
  status: string | null
}

interface GroupMessageReportRow {
  id: string
  reporter_user_id: string
  reported_user_id: string
  message_id: string
  conversation_id: string
  message_text_snapshot: string | null
  category: string | null
  details: string | null
  moderation_notified_at: string | null
  created_at: string | null
  status: string | null
}

interface ProfileNameRow {
  id: string
  display_name: string | null
  username: string | null
}

function truncateSnapshot(s: string): string {
  const t = s.trim()
  if (t.length <= MAX_SNAPSHOT_LEN) return t
  return `${t.slice(0, MAX_SNAPSHOT_LEN)}… [truncated]`
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function normalizeReportId(raw: string | null | undefined): string {
  return (raw ?? "").trim().toLowerCase()
}

function normalizeReportType(raw: string | null | undefined): ReportType | null {
  const t = (raw ?? "").trim().toLowerCase()
  if (
    t === "user"
    || t === "conversation"
    || t === "message"
    || t === "group_conversation"
    || t === "group_message"
  ) {
    return t
  }
  return null
}

function parseTimestampMs(value: string | null | undefined): number | null {
  if (!value?.trim()) return null
  const ms = Date.parse(value.trim())
  return Number.isNaN(ms) ? null : ms
}

function formatDisplayTimestamp(iso: string | null | undefined): string {
  const ms = parseTimestampMs(iso)
  if (ms == null) return "—"
  try {
    return new Date(ms).toLocaleString("en-US", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    })
  } catch {
    return iso?.trim() || "—"
  }
}

function normalizeSnapshotMessages(raw: unknown): ConversationMessageSnapshot[] {
  if (!Array.isArray(raw)) return []
  return raw.filter((item): item is ConversationMessageSnapshot => {
    return item != null && typeof item === "object"
  })
}

function filterSnapshotToReviewWindow(
  messages: ConversationMessageSnapshot[],
  windowStart: string | null | undefined,
  windowEnd: string | null | undefined,
): ConversationMessageSnapshot[] {
  const startMs = parseTimestampMs(windowStart)
  const endMs = parseTimestampMs(windowEnd)
  if (startMs == null || endMs == null) return messages
  return messages.filter((m) => {
    const createdMs = parseTimestampMs(m.created_at)
    if (createdMs == null) return false
    return createdMs >= startMs && createdMs <= endMs
  })
}

function displayLabelForSender(
  senderId: string | null | undefined,
  reporterUserId: string,
  reportedUserId: string,
  nameByUserId: Map<string, string>,
): string {
  const id = (senderId ?? "").trim()
  if (!id) return "Unknown"
  const profileName = nameByUserId.get(id)
  if (profileName) return profileName
  if (id === reporterUserId) return "Reporter"
  if (id === reportedUserId) return "Reported user"
  return `User ${id.slice(0, 8)}`
}

async function fetchDisplayNames(
  admin: ReturnType<typeof createClient>,
  userIds: string[],
): Promise<Map<string, string>> {
  const unique = [...new Set(userIds.filter((id) => id.trim().length > 0))]
  const map = new Map<string, string>()
  if (unique.length === 0) return map

  const { data, error } = await admin
    .from("user_profiles")
    .select("id,display_name,username")
    .in("id", unique)

  if (error) {
    console.error("notify-moderation-report: profile name lookup failed", error.message)
    return map
  }

  for (const row of (data ?? []) as ProfileNameRow[]) {
    const display = (row.display_name ?? "").trim()
    const username = (row.username ?? "").trim()
    const label = display || (username ? `@${username}` : "")
    if (label) map.set(row.id, label)
  }
  return map
}

function renderApprovedConversationSnapshot(
  messages: ConversationMessageSnapshot[],
  reporterUserId: string,
  reportedUserId: string,
  nameByUserId: Map<string, string>,
): string {
  if (!Array.isArray(messages) || messages.length === 0) {
    return "(No messages in the user-approved review window.)"
  }

  const sorted = [...messages].sort((a, b) => {
    const aMs = parseTimestampMs(a.created_at) ?? 0
    const bMs = parseTimestampMs(b.created_at) ?? 0
    return aMs - bMs
  })

  const limited = sorted.slice(0, MAX_SNAPSHOT_MESSAGES)
  const lines: string[] = []
  for (const m of limited) {
    const ts = formatDisplayTimestamp(m.created_at)
    const sender = displayLabelForSender(m.sender_id, reporterUserId, reportedUserId, nameByUserId)
    const body = (m.body ?? "")
      .replace(/\r\n/g, "\n")
      .replace(/\r/g, "\n")
      .trim() || "(empty message)"
    lines.push(`[${ts}]\n${sender}:\n${body}`)
  }
  if (sorted.length > MAX_SNAPSHOT_MESSAGES) {
    lines.push(`… [${sorted.length - MAX_SNAPSHOT_MESSAGES} additional message(s) omitted for length]`)
  }
  return lines.join("\n\n")
}

async function loadConversationReportSnapshot(
  admin: ReturnType<typeof createClient>,
  reportId: string,
  reporterUserId: string,
): Promise<ConversationReportRow | null> {
  const { data, error } = await admin
    .from("conversation_reports")
    .select(
      "id,reporter_user_id,reported_user_id,conversation_id,category,details,review_window_start,review_window_end,message_snapshot,admin_review_consent_granted,created_at",
    )
    .eq("id", reportId)
    .eq("reporter_user_id", reporterUserId)
    .maybeSingle()

  if (error) {
    console.error("notify-moderation-report: conversation_reports load failed", error.message)
    return null
  }
  return data as ConversationReportRow | null
}

async function loadConversationReportSnapshotWithRetry(
  admin: ReturnType<typeof createClient>,
  reportId: string,
  reporterUserId: string,
): Promise<ConversationReportRow | null> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const row = await loadConversationReportSnapshot(admin, reportId, reporterUserId)
    if (row) return row
    if (attempt === 0) await sleep(350)
  }
  return null
}

async function loadGroupConversationReport(
  admin: ReturnType<typeof createClient>,
  reportId: string,
  reporterUserId?: string | null,
): Promise<GroupConversationReportRow | null> {
  let query = admin
    .from("group_conversation_reports")
    .select(
      "id,reporter_user_id,group_conversation_id,category,details,group_title_snapshot,member_count_snapshot,moderation_notified_at,created_at,status",
    )
    .eq("id", reportId)

  if (reporterUserId) {
    query = query.eq("reporter_user_id", reporterUserId)
  }

  const { data, error } = await query.maybeSingle()

  if (error) {
    console.error("notify-moderation-report: group_conversation_reports load failed", error.message)
    return null
  }
  return data as GroupConversationReportRow | null
}

async function loadGroupMessageReport(
  admin: ReturnType<typeof createClient>,
  reportId: string,
  reporterUserId?: string | null,
): Promise<GroupMessageReportRow | null> {
  let query = admin
    .from("group_message_reports")
    .select(
      "id,reporter_user_id,reported_user_id,message_id,conversation_id,message_text_snapshot,category,details,moderation_notified_at,created_at,status",
    )
    .eq("id", reportId)

  if (reporterUserId) {
    query = query.eq("reporter_user_id", reporterUserId)
  }

  const { data, error } = await query.maybeSingle()

  if (error) {
    console.error("notify-moderation-report: group_message_reports load failed", error.message)
    return null
  }
  return data as GroupMessageReportRow | null
}

interface MessageReportRow {
  id: string
  reporter_user_id: string
  reported_user_id: string
  message_id: string
  message_text_snapshot: string | null
  category: string | null
  details: string | null
  created_at: string | null
}

/** Prefer DB snapshot for DM message reports when report_id or message_id is known. */
async function loadMessageReportSnapshot(
  admin: ReturnType<typeof createClient>,
  opts: { reportId?: string | null; messageId?: string | null; reporterUserId: string },
): Promise<MessageReportRow | null> {
  const reportId = (opts.reportId ?? "").trim()
  const messageId = (opts.messageId ?? "").trim()

  if (reportId) {
    const { data, error } = await admin
      .from("message_reports")
      .select("id,reporter_user_id,reported_user_id,message_id,message_text_snapshot,category,details,created_at")
      .eq("id", reportId)
      .eq("reporter_user_id", opts.reporterUserId)
      .maybeSingle()
    if (error) {
      console.error("notify-moderation-report: message_reports load by id failed", error.message)
      return null
    }
    if (data) return data as MessageReportRow
  }

  if (messageId) {
    const { data, error } = await admin
      .from("message_reports")
      .select("id,reporter_user_id,reported_user_id,message_id,message_text_snapshot,category,details,created_at")
      .eq("message_id", messageId)
      .eq("reporter_user_id", opts.reporterUserId)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle()
    if (error) {
      console.error("notify-moderation-report: message_reports load by message_id failed", error.message)
      return null
    }
    if (data) return data as MessageReportRow
  }

  return null
}

async function markGroupConversationReportNotified(
  admin: ReturnType<typeof createClient>,
  reportId: string,
): Promise<void> {
  const { error } = await admin
    .from("group_conversation_reports")
    .update({ moderation_notified_at: new Date().toISOString() })
    .eq("id", reportId)
    .is("moderation_notified_at", null)

  if (error) {
    console.error("notify-moderation-report: failed to stamp group_conversation moderation_notified_at", error.message)
  }
}

async function markGroupMessageReportNotified(
  admin: ReturnType<typeof createClient>,
  reportId: string,
): Promise<void> {
  const { error } = await admin
    .from("group_message_reports")
    .update({ moderation_notified_at: new Date().toISOString() })
    .eq("id", reportId)
    .is("moderation_notified_at", null)

  if (error) {
    console.error("notify-moderation-report: failed to stamp group_message moderation_notified_at", error.message)
  }
}

async function fetchReporterEmail(
  admin: ReturnType<typeof createClient>,
  reporterUserId: string,
): Promise<string> {
  try {
    const { data, error } = await admin.auth.admin.getUserById(reporterUserId)
    if (error || !data.user?.email) {
      return ""
    }
    return data.user.email.trim()
  } catch {
    return ""
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    })
  }

  const authHeader = req.headers.get("Authorization")
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? ""
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  if (!supabaseUrl || !supabaseAnonKey) {
    console.error("notify-moderation-report: missing SUPABASE_URL or SUPABASE_ANON_KEY")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const bearerToken = authHeader.replace(/^Bearer\s+/i, "").trim()
  const isServiceRole = Boolean(serviceRoleKey && bearerToken === serviceRoleKey)

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const reportType = normalizeReportType(payload.report_type)
  if (!reportType) {
    return new Response(JSON.stringify({ error: "invalid_report_type" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  if (isServiceRole && reportType !== "group_conversation" && reportType !== "group_message") {
    return new Response(JSON.stringify({ error: "service_role_type_not_allowed" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    })
  }

  let userId = ""
  let reporterEmail = ""

  if (isServiceRole) {
    if (!normalizeReportId(payload.report_id)) {
      return new Response(JSON.stringify({ error: "report_id_required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      })
    }
  } else {
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    })
    const { data: { user }, error: authErr } = await supabase.auth.getUser()
    if (authErr || !user) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      })
    }
    userId = user.id
    reporterEmail = user.email?.trim() || ""

    if (!payload.category?.trim() && reportType !== "group_conversation" && reportType !== "group_message") {
      return new Response(JSON.stringify({ error: "missing_fields" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      })
    }

    if (
      reportType !== "group_conversation"
      && reportType !== "group_message"
      && !payload.reported_user_id?.trim()
    ) {
      return new Response(JSON.stringify({ error: "missing_fields" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      })
    }

    if (reportType === "conversation") {
      const cid = payload.conversation_id?.trim()
      if (!cid) {
        return new Response(JSON.stringify({ error: "conversation_id_required" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        })
      }
      if (!normalizeReportId(payload.report_id)) {
        return new Response(JSON.stringify({ error: "report_id_required" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        })
      }
    }

    if (reportType === "group_conversation" || reportType === "group_message") {
      if (!normalizeReportId(payload.report_id)) {
        return new Response(JSON.stringify({ error: "report_id_required" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        })
      }
    }

    if (reportType === "message") {
      const mid = payload.message_id?.trim()
      if (!mid) {
        return new Response(JSON.stringify({ error: "message_id_required" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        })
      }
    }
  }

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")?.trim()
  const resendKey = Deno.env.get("RESEND_API_KEY")?.trim()
  const resendFrom = Deno.env.get("RESEND_FROM")?.trim()
  if (!adminTo || !resendKey || !resendFrom) {
    console.error("notify-moderation-report: missing ADMIN_EMAIL_TO, RESEND_API_KEY, or RESEND_FROM")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const createdAt = (payload.created_at?.trim() || new Date().toISOString())
  const reporterEmailLine = reporterEmail.length > 0 ? reporterEmail : "(not on file)"

  const detailsRaw = (payload.details ?? "").trim()
  const detailsLine = detailsRaw.length > 0 ? detailsRaw : "—"

  const reportIdNormalized = normalizeReportId(payload.report_id)
  const admin = serviceRoleKey ? createClient(supabaseUrl, serviceRoleKey) : null

  let groupTitle = (payload.group_title ?? "").trim()
  let memberCountDisplay = payload.member_count == null ? "" : String(payload.member_count)
  let groupConversationId = (payload.conversation_id ?? "").trim()
  let categoryForEmail = (payload.category ?? "").trim()
  let createdAtForEmail = createdAt
  let detailsForEmail = detailsLine
  let reportedUserIdForEmail = (payload.reported_user_id ?? "").trim()
  let messageIdForEmail = (payload.message_id ?? "").trim()
  /** Message body for email: prefer DB row; empty means omit / unavailable (never forge from client for group). */
  let messageSnapshotForEmail = ""
  let messageSnapshotFromDb = false
  let reporterUserIdForEmail = userId

  if (reportType === "group_conversation") {
    if (!admin || !reportIdNormalized) {
      return new Response(JSON.stringify({ error: "server_misconfigured" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      })
    }

    const groupReport = await loadGroupConversationReport(
      admin,
      reportIdNormalized,
      isServiceRole ? null : userId,
    )
    if (!groupReport) {
      return new Response(JSON.stringify({ error: "report_not_found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      })
    }

    if (groupReport.moderation_notified_at) {
      return new Response(JSON.stringify({ ok: true, skipped: true, reason: "already_notified" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    }

    reporterUserIdForEmail = groupReport.reporter_user_id
    if (isServiceRole || !reporterEmail) {
      reporterEmail = await fetchReporterEmail(admin, groupReport.reporter_user_id)
    }
    groupTitle = (groupReport.group_title_snapshot ?? groupTitle).trim() || "(untitled group)"
    memberCountDisplay =
      groupReport.member_count_snapshot == null ? memberCountDisplay || "—" : String(groupReport.member_count_snapshot)
    groupConversationId = groupReport.group_conversation_id || groupConversationId
    categoryForEmail = (groupReport.category || categoryForEmail).trim() || "other"
    createdAtForEmail = (groupReport.created_at || createdAtForEmail).trim()
    const dbDetails = (groupReport.details ?? "").trim()
    detailsForEmail = dbDetails.length > 0 ? dbDetails : detailsForEmail
  }

  if (reportType === "group_message") {
    if (!admin || !reportIdNormalized) {
      return new Response(JSON.stringify({ error: "server_misconfigured" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      })
    }

    const groupMessageReport = await loadGroupMessageReport(
      admin,
      reportIdNormalized,
      isServiceRole ? null : userId,
    )
    if (!groupMessageReport) {
      return new Response(JSON.stringify({ error: "report_not_found" }), {
        status: 404,
        headers: { "Content-Type": "application/json" },
      })
    }

    if (groupMessageReport.moderation_notified_at) {
      return new Response(JSON.stringify({ ok: true, skipped: true, reason: "already_notified" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    }

    reporterUserIdForEmail = groupMessageReport.reporter_user_id
    if (isServiceRole || !reporterEmail) {
      reporterEmail = await fetchReporterEmail(admin, groupMessageReport.reporter_user_id)
    }
    reportedUserIdForEmail = groupMessageReport.reported_user_id
    messageIdForEmail = groupMessageReport.message_id
    groupConversationId = groupMessageReport.conversation_id || groupConversationId
    // Never use client payload.message_text_snapshot for group messages.
    messageSnapshotForEmail = (groupMessageReport.message_text_snapshot ?? "").trim()
    messageSnapshotFromDb = true
    categoryForEmail = (groupMessageReport.category || categoryForEmail).trim() || "other"
    createdAtForEmail = (groupMessageReport.created_at || createdAtForEmail).trim()
    const dbDetails = (groupMessageReport.details ?? "").trim()
    detailsForEmail = dbDetails.length > 0 ? dbDetails : detailsForEmail

    const { data: conversation } = await admin
      .from("group_conversations")
      .select("title")
      .eq("id", groupMessageReport.conversation_id)
      .maybeSingle()
    groupTitle = ((conversation as { title?: string } | null)?.title ?? groupTitle).trim() || "Group"
  }

  if (reportType === "message" && userId) {
    if (admin) {
      const dmReport = await loadMessageReportSnapshot(admin, {
        reportId: reportIdNormalized,
        messageId: messageIdForEmail || (payload.message_id ?? "").trim(),
        reporterUserId: userId,
      })
      if (dmReport) {
        reportedUserIdForEmail = dmReport.reported_user_id || reportedUserIdForEmail
        messageIdForEmail = dmReport.message_id || messageIdForEmail
        messageSnapshotForEmail = (dmReport.message_text_snapshot ?? "").trim()
        messageSnapshotFromDb = true
        if ((dmReport.category ?? "").trim()) {
          categoryForEmail = (dmReport.category ?? "").trim()
        }
        if ((dmReport.created_at ?? "").trim()) {
          createdAtForEmail = (dmReport.created_at ?? "").trim()
        }
        const dbDetails = (dmReport.details ?? "").trim()
        if (dbDetails.length > 0) detailsForEmail = dbDetails
      } else {
        // DM message reports historically may lack report_id; fall back to payload only when DB row missing.
        messageSnapshotForEmail = (payload.message_text_snapshot ?? "").trim()
        messageSnapshotFromDb = false
        console.warn(
          `notify-moderation-report: message_reports row missing for reporter=${userId} — using payload snapshot only as last resort`,
        )
      }
    } else {
      messageSnapshotForEmail = (payload.message_text_snapshot ?? "").trim()
      messageSnapshotFromDb = false
      console.warn("notify-moderation-report: SUPABASE_SERVICE_ROLE_KEY unset — using payload message snapshot as last resort")
    }
  }

  if (!categoryForEmail && reportType !== "group_conversation" && reportType !== "group_message") {
    return new Response(JSON.stringify({ error: "missing_fields" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const reporterEmailDisplay = reporterEmail.length > 0 ? reporterEmail : reporterEmailLine

  let snapshotSection = ""
  if (reportType === "group_message") {
    if (messageSnapshotFromDb && messageSnapshotForEmail.length > 0) {
      const snap = truncateSnapshot(messageSnapshotForEmail)
      snapshotSection =
        `<p style="margin:8px 0"><strong>Message text (snapshot):</strong><br/><span style="white-space:pre-wrap">${escapeHtml(snap)}</span></p>`
    } else {
      snapshotSection =
        `<p style="margin:8px 0;font-size:13px;color:#64748b"><strong>Message text (snapshot):</strong> Evidence unavailable (no stored snapshot on the report row).</p>`
    }
  } else if (reportType === "message") {
    if (messageSnapshotForEmail.length > 0) {
      const snap = truncateSnapshot(messageSnapshotForEmail)
      snapshotSection =
        `<p style="margin:8px 0"><strong>Message text (snapshot):</strong><br/><span style="white-space:pre-wrap">${escapeHtml(snap)}</span></p>`
    } else {
      snapshotSection =
        `<p style="margin:8px 0;font-size:13px;color:#64748b"><strong>Message text (snapshot):</strong> Evidence unavailable.</p>`
    }
  }

  const convLine = groupConversationId || payload.conversation_id?.trim()
    ? `<p style="margin:8px 0"><strong>${
      reportType === "group_conversation" || reportType === "group_message"
        ? "Group conversation ID"
        : "Conversation ID"
    }:</strong> ${escapeHtml((groupConversationId || payload.conversation_id || "").trim())}</p>`
    : ""

  const reportIdLine = reportIdNormalized
    ? `<p style="margin:8px 0"><strong>Report ID:</strong> ${escapeHtml(reportIdNormalized)}</p>`
    : ""

  const msgLine = messageIdForEmail || payload.message_id?.trim()
    ? `<p style="margin:8px 0"><strong>Message ID:</strong> ${escapeHtml((messageIdForEmail || payload.message_id || "").trim())}</p>`
    : ""

  let windowStart = (payload.review_window_start ?? "").trim()
  let windowEnd = (payload.review_window_end ?? "").trim()
  let conversationContextSection = ""

  if (reportType === "conversation") {
    const reportId = reportIdNormalized
    let snapshotMessages: ConversationMessageSnapshot[] = []
    let reporterUserId = userId
    let reportedUserId = reportedUserIdForEmail
    let consentGranted = false
    let evidenceUnavailableReason = "missing_report_row"

    console.log(`[PrivateReportEmail] report_id=${reportId || "(missing)"}`)
    console.log(`[PrivateReportEmail] report_type=${reportType}`)
    // Never use payload.conversation_message_snapshot as evidence.
    console.log(`[PrivateReportEmail] payload_snapshot_ignored=true`)

    if (admin && reportId) {
      const reportRow = await loadConversationReportSnapshotWithRetry(admin, reportId, userId)
      if (reportRow) {
        windowStart = (reportRow.review_window_start ?? windowStart).trim()
        windowEnd = (reportRow.review_window_end ?? windowEnd).trim()
        reporterUserId = reportRow.reporter_user_id
        reportedUserId = reportRow.reported_user_id
        reportedUserIdForEmail = reportedUserId
        categoryForEmail = (reportRow.category || categoryForEmail).trim() || categoryForEmail
        createdAtForEmail = (reportRow.created_at || createdAtForEmail).trim()
        const dbDetails = (reportRow.details ?? "").trim()
        if (dbDetails.length > 0) detailsForEmail = dbDetails
        groupConversationId = reportRow.conversation_id || groupConversationId

        if (reportRow.admin_review_consent_granted !== true) {
          consentGranted = false
          evidenceUnavailableReason = "consent_not_granted"
          snapshotMessages = []
          console.error(
            `[PrivateReportEmail] consent_not_granted report_id=${reportId} — omitting conversation body`,
          )
        } else {
          consentGranted = true
          const rawSnapshot = normalizeSnapshotMessages(reportRow.message_snapshot)
          const dbInWindow = filterSnapshotToReviewWindow(rawSnapshot, windowStart, windowEnd)
          snapshotMessages = dbInWindow
          if (dbInWindow.length === 0) {
            evidenceUnavailableReason = "empty_db_snapshot"
            console.log(
              `[PrivateReportEmail] db_snapshot_empty report_id=${reportId} — omitting conversation body`,
            )
          }
        }
      } else {
        evidenceUnavailableReason = "missing_report_row"
        console.error(
          `notify-moderation-report: missing conversation_reports row report_id=${reportId} reporter=${userId} — omitting conversation body`,
        )
        snapshotMessages = []
      }
    } else {
      if (!serviceRoleKey) {
        console.error("notify-moderation-report: SUPABASE_SERVICE_ROLE_KEY unset — omitting conversation body")
        evidenceUnavailableReason = "service_role_missing"
      } else {
        evidenceUnavailableReason = "report_id_required"
      }
      snapshotMessages = []
    }

    console.log(`[PrivateReportEmail] snapshot_count=${snapshotMessages.length}`)
    console.log(`[PrivateReportEmail] consent_granted=${consentGranted}`)
    console.log(`[PrivateReportEmail] window_start=${windowStart || "(empty)"}`)
    console.log(`[PrivateReportEmail] window_end=${windowEnd || "(empty)"}`)

    const windowFromDisplay = formatDisplayTimestamp(windowStart)
    const windowToDisplay = formatDisplayTimestamp(windowEnd)

    if (consentGranted && snapshotMessages.length > 0) {
      const nameIds = [
        reporterUserId,
        reportedUserId,
        ...snapshotMessages.map((m) => (m.sender_id ?? "").trim()).filter(Boolean),
      ]
      const nameByUserId = admin ? await fetchDisplayNames(admin, nameIds) : new Map<string, string>()

      const rendered = renderApprovedConversationSnapshot(
        snapshotMessages,
        reporterUserId,
        reportedUserId,
        nameByUserId,
      )
      const bounded = rendered.length > MAX_CONVERSATION_CONTEXT_LEN
        ? `${rendered.slice(0, MAX_CONVERSATION_CONTEXT_LEN)}… [truncated]`
        : rendered

      conversationContextSection =
        `<p style="margin:18px 0 6px;font-size:14px"><strong>Conversation review window:</strong></p>` +
        `<p style="margin:0 0 4px;font-size:14px">From: ${escapeHtml(windowFromDisplay)}</p>` +
        `<p style="margin:0 0 10px;font-size:14px">To: ${escapeHtml(windowToDisplay)}</p>` +
        `<p style="margin:0 0 8px;font-size:13px;color:#475569">Only messages included in the user-approved review window are shown.</p>` +
        `<p style="margin:14px 0 8px;font-size:14px"><strong>Approved conversation snapshot:</strong></p>` +
        `<p style="margin:0;font-size:13px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0;font-family:ui-monospace,monospace">${
          escapeHtml(bounded)
        }</p>`

      console.log(
        `[PrivateReportEmail] email_includes_conversation_section=true snapshot_rendered=true`,
      )
    } else {
      conversationContextSection =
        `<p style="margin:18px 0 6px;font-size:14px"><strong>Conversation review window:</strong></p>` +
        `<p style="margin:0 0 4px;font-size:14px">From: ${escapeHtml(windowFromDisplay)}</p>` +
        `<p style="margin:0 0 10px;font-size:14px">To: ${escapeHtml(windowToDisplay)}</p>` +
        `<p style="margin:14px 0 8px;font-size:14px"><strong>Approved conversation snapshot:</strong></p>` +
        `<p style="margin:0;font-size:13px;color:#64748b;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">Evidence unavailable (${escapeHtml(evidenceUnavailableReason)}). Conversation body was not included.</p>`

      console.log(
        `[PrivateReportEmail] email_includes_conversation_section=true snapshot_rendered=false reason=${evidenceUnavailableReason}`,
      )
    }
  } else {
    console.log(
      `[PrivateReportEmail] email_includes_conversation_section=false reason=report_type_${reportType}`,
    )
  }

  const groupSection = reportType === "group_conversation" || reportType === "group_message"
    ? `<tr><td style="padding:6px 0;vertical-align:top"><strong>Group title</strong></td><td style="padding:6px 0">${escapeHtml(groupTitle || "—")}</td></tr>${
      reportType === "group_conversation"
        ? `<tr><td style="padding:6px 0;vertical-align:top"><strong>Member count</strong></td><td style="padding:6px 0">${escapeHtml(memberCountDisplay || "—")}</td></tr>`
        : ""
    }`
    : ""

  const reportedUserRow = reportType === "group_conversation"
    ? ""
    : `<tr><td style="padding:6px 0;vertical-align:top"><strong>Reported user ID</strong></td><td style="padding:6px 0">${escapeHtml(reportedUserIdForEmail || "—")}</td></tr>`

  const reviewWindowSection = ""

  const adminReviewBaseUrl = Deno.env.get("ADMIN_REPORT_REVIEW_BASE_URL")?.trim() ?? ""
  const reportReviewLink = adminReviewBaseUrl && reportIdNormalized
    ? reportType === "group_conversation"
      ? `${adminReviewBaseUrl.replace(/\/+$/, "")}?reportId=${encodeURIComponent(reportIdNormalized)}#group-conversation-reports`
      : reportType === "group_message"
        ? `${adminReviewBaseUrl.replace(/\/+$/, "")}?reportId=${encodeURIComponent(reportIdNormalized)}#group-message-reports`
        : `${adminReviewBaseUrl.replace(/\/+$/, "")}/${encodeURIComponent(reportIdNormalized)}`
    : ""
  const reportReviewLinkLine = reportReviewLink
    ? `<p style="margin:8px 0"><strong>Admin review:</strong> <a href="${escapeHtml(reportReviewLink)}">${escapeHtml(reportReviewLink)}</a></p>`
    : ""

  const reportTypeLabel =
    reportType === "group_conversation"
      ? "group conversation"
      : reportType === "group_message"
        ? "group message"
        : reportType

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;line-height:1.55;color:#1a1a1a;max-width:640px">
  <h1 style="font-size:20px;font-weight:650;margin:0 0 18px;color:#0f172a">FanGeo moderation report</h1>
  <p style="margin:10px 0;font-size:15px">A user submitted a report that needs manual review.</p>
  <hr style="border:none;border-top:1px solid #e2e8f0;margin:18px 0"/>
  <table style="font-size:14px;border-collapse:collapse;width:100%">
    <tr><td style="padding:6px 0;vertical-align:top;width:160px"><strong>Report type</strong></td><td style="padding:6px 0">${escapeHtml(reportTypeLabel)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Category</strong></td><td style="padding:6px 0">${escapeHtml(categoryForEmail || "—")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Created at</strong></td><td style="padding:6px 0">${escapeHtml(createdAtForEmail)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Reporter user ID</strong></td><td style="padding:6px 0">${escapeHtml(reporterUserIdForEmail || userId || "—")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Reporter email</strong></td><td style="padding:6px 0">${escapeHtml(reporterEmailDisplay)}</td></tr>
    ${reportedUserRow}
    ${groupSection}
  </table>
  ${reportIdLine}
  ${convLine}
  ${msgLine}
  ${conversationContextSection}
  <p style="margin:14px 0 8px;font-size:14px"><strong>Details</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(detailsForEmail)}</p>
  ${reviewWindowSection}
  ${reportReviewLinkLine}
  ${snapshotSection}
  <p style="margin-top:22px;font-size:12px;color:#64748b">This message was generated by the FanGeo moderation notification service.${
    reportType === "group_conversation"
      ? " Group message history is not included."
      : reportType === "group_message"
        ? " Only the stored message snapshot is included."
        : ""
  }</p>
</body>
</html>`

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: resendFrom,
      to: [adminTo],
      subject: `FanGeo moderation report — ${reportTypeLabel}`,
      html,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    console.error("notify-moderation-report: Resend error", res.status, errText)
    return new Response(
      JSON.stringify({ ok: false, error: "email_send_failed" }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    )
  }

  if (reportType === "group_conversation" && admin && reportIdNormalized) {
    await markGroupConversationReportNotified(admin, reportIdNormalized)
  }
  if (reportType === "group_message" && admin && reportIdNormalized) {
    await markGroupMessageReportNotified(admin, reportIdNormalized)
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  })
})

/**
 * Admin Support Inbox — fetch/send helpers and Supabase Realtime subscriptions.
 * Uses service_role on the server only. Does not touch direct_messages.
 */
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2"

export type SupportConversationRow = {
  id: string
  user_id: string
  status: string
  last_message_at: string | null
  last_user_message_at: string | null
  last_support_message_at: string | null
  created_at: string
  updated_at: string
  last_message_body: string | null
  last_message_sender_kind: string | null
}

export type SupportMessageRow = {
  id: string
  conversation_id: string
  sender_kind: string
  sender_auth_user_id: string | null
  body: string
  created_at: string
}

export function createAdminSupportServiceClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL")?.trim()
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
  if (!url || !key) {
    throw new Error("missing Supabase service role configuration")
  }
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

export async function adminListSupportConversations(
  client: SupabaseClient,
  adminEmail: string,
  limit = 50,
): Promise<SupportConversationRow[]> {
  const { data, error } = await client.rpc("admin_list_support_conversations", {
    p_admin_email: adminEmail,
    p_limit: limit,
  })
  if (error) throw error
  return (data ?? []) as SupportConversationRow[]
}

export async function adminFetchSupportMessages(
  client: SupabaseClient,
  conversationId: string,
  adminEmail: string,
  limit = 100,
): Promise<SupportMessageRow[]> {
  const { data, error } = await client.rpc("admin_fetch_support_messages", {
    p_conversation_id: conversationId,
    p_admin_email: adminEmail,
    p_limit: limit,
  })
  if (error) throw error
  return (data ?? []) as SupportMessageRow[]
}

export async function adminSendSupportMessage(
  client: SupabaseClient,
  conversationId: string,
  body: string,
  adminEmail: string,
): Promise<string> {
  const { data, error } = await client.rpc("admin_send_support_message", {
    p_conversation_id: conversationId,
    p_body: body,
    p_admin_email: adminEmail,
  })
  if (error) throw error
  return String(data)
}

export type SupportInboxRealtimeHandlers = {
  onInsert: (row: SupportMessageRow) => void
  onStatus?: (status: string) => void
}

/** Subscribe to all support_messages INSERTs (service role bypasses RLS). */
export function subscribeSupportInboxRealtime(
  client: SupabaseClient,
  handlers: SupportInboxRealtimeHandlers,
): { channel: ReturnType<SupabaseClient["channel"]>; unsubscribe: () => Promise<void> } {
  const channel = client
    .channel("support-inbox-admin-web")
    .on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "support_messages" },
      (payload) => {
        const record = payload.new as Record<string, unknown>
        console.log(
          `[SupportInboxRealtime] insert received id=${String(record.id ?? "")} senderKind=${String(record.sender_kind ?? "")}`,
        )
        handlers.onInsert({
          id: String(record.id ?? ""),
          conversation_id: String(record.conversation_id ?? ""),
          sender_kind: String(record.sender_kind ?? ""),
          sender_auth_user_id: record.sender_auth_user_id ? String(record.sender_auth_user_id) : null,
          body: String(record.body ?? ""),
          created_at: String(record.created_at ?? ""),
        })
      },
    )
    .subscribe((status) => {
      console.log(`[SupportInboxRealtime] channelStatus=${status}`)
      handlers.onStatus?.(status)
    })

  return {
    channel,
    unsubscribe: async () => {
      console.log("[SupportInboxRealtime] unsubscribed")
      await client.removeChannel(channel)
    },
  }
}

/** Thread-scoped INSERT listener for one support conversation. */
export function subscribeSupportThreadRealtime(
  client: SupabaseClient,
  conversationId: string,
  handlers: SupportInboxRealtimeHandlers,
): { channel: ReturnType<SupabaseClient["channel"]>; unsubscribe: () => Promise<void> } {
  const cid = conversationId.toLowerCase()
  const channel = client
    .channel(`support-thread-admin-web-${cid}`)
    .on(
      "postgres_changes",
      {
        event: "INSERT",
        schema: "public",
        table: "support_messages",
        filter: `conversation_id=eq.${cid}`,
      },
      (payload) => {
        const record = payload.new as Record<string, unknown>
        console.log(
          `[SupportInboxRealtime] thread insert received conversationId=${cid} id=${String(record.id ?? "")}`,
        )
        handlers.onInsert({
          id: String(record.id ?? ""),
          conversation_id: String(record.conversation_id ?? ""),
          sender_kind: String(record.sender_kind ?? ""),
          sender_auth_user_id: record.sender_auth_user_id ? String(record.sender_auth_user_id) : null,
          body: String(record.body ?? ""),
          created_at: String(record.created_at ?? ""),
        })
      },
    )
    .subscribe((status) => {
      console.log(`[SupportInboxRealtime] thread channelStatus=${status} conversationId=${cid}`)
      handlers.onStatus?.(status)
    })

  return {
    channel,
    unsubscribe: async () => {
      console.log(`[SupportInboxRealtime] thread unsubscribed conversationId=${cid}`)
      await client.removeChannel(channel)
    },
  }
}

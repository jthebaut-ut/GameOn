import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { handleChatMessagePushRequest } from "../_shared/chat_message_push_handler.ts"

/**
 * Unified trusted APNs worker for FanGeo social chat messages.
 *
 * Supports message_source/chat_type:
 *   - direct / venue  → public.direct_messages
 *   - group / pickup  → public.group_messages
 *
 * Invoked via pg_net from:
 *   - queue_direct_message_push_notification (compat + retargeted)
 *   - queue_chat_message_push_notification
 *
 * Auth: service-role bearer, or CHAT_MESSAGE_PUSH_CRON_SECRET /
 *       DIRECT_MESSAGE_PUSH_CRON_SECRET (x-cron-secret).
 *
 * Deploy: `supabase functions deploy notify-chat-message --no-verify-jwt`
 */

Deno.serve(async (req) => {
  return await handleChatMessagePushRequest(req)
})

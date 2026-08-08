import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { handleChatMessagePushRequest } from "../_shared/chat_message_push_handler.ts"

/**
 * Compatibility adapter for DM push.
 *
 * Historical queue targets (`/functions/v1/notify-direct-message`) continue to work.
 * Processing is delegated to the unified chat-message push handler with
 * message_source forced to `direct`.
 *
 * Prefer deploying/using `notify-chat-message` for new queues.
 * Deploy: `supabase functions deploy notify-direct-message --no-verify-jwt`
 */

Deno.serve(async (req) => {
  return await handleChatMessagePushRequest(req, { forceMessageSource: "direct" })
})

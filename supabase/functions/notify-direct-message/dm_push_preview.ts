/** Re-export shared preview helpers for DM self-tests / compatibility. */
export {
  buildDirectChatPushAlert,
  buildDirectMessagePushAlert,
  buildDirectMessagePushBody,
  buildDirectStylePushAlert,
  buildGroupChatPushAlert,
  normalizeSenderHandle,
  resolveSenderIdentity,
  sanitizeSenderDisplayName,
  sanitizeTextMessagePreview,
  structuredMessagePreview,
  type ChatPreviewMode as DmPreviewMode,
  type PushAlertContent,
  type SenderIdentity,
} from "../_shared/chat_push_preview.ts"

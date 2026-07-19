-- Static validation checklist for group chat foundation + member-left system events.
-- Run against a staging database after apply (does not modify data).

-- 1) Tables exist
SELECT to_regclass('public.group_conversations') IS NOT NULL AS group_conversations_ok,
       to_regclass('public.group_conversation_members') IS NOT NULL AS group_members_ok,
       to_regclass('public.group_messages') IS NOT NULL AS group_messages_ok,
       to_regclass('public.group_message_reports') IS NOT NULL AS group_reports_ok;

-- 2) DM tables untouched (presence only)
SELECT to_regclass('public.direct_conversations') IS NOT NULL AS dm_conversations_ok,
       to_regclass('public.direct_messages') IS NOT NULL AS dm_messages_ok;

-- 3) System payload + inbox denormalized columns
SELECT
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'group_messages' AND column_name = 'system_payload'
  ) AS system_payload_ok,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'group_conversations' AND column_name = 'last_message_type'
  ) AS last_message_type_ok,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'group_conversations' AND column_name = 'last_system_event'
  ) AS last_system_event_ok,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'group_conversations' AND column_name = 'last_system_payload'
  ) AS last_system_payload_ok;

-- 4) Duplicate-leave unique index
SELECT EXISTS (
  SELECT 1 FROM pg_indexes
  WHERE schemaname = 'public' AND indexname = 'group_messages_member_left_once_idx'
) AS member_left_unique_idx_ok;

-- 5) RLS enabled
SELECT c.relname, c.relrowsecurity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN (
    'group_conversations',
    'group_conversation_members',
    'group_messages',
    'group_message_reports'
  )
ORDER BY 1;

-- 6) RPCs exist
SELECT p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'create_group_conversation',
    'add_group_members',
    'remove_group_member',
    'leave_group_conversation',
    'mark_group_conversation_read',
    'set_group_conversation_muted',
    'report_group_message',
    'get_group_inbox_summaries',
    'send_group_message',
    'get_group_conversation_details',
    'is_active_group_member',
    'group_member_can_read_message',
    'group_add_member_eligible',
    'group_membership_display_name_snapshot'
  )
ORDER BY 1;

-- 7) leave_group_conversation body mentions member_left (smoke)
SELECT pg_get_functiondef('public.leave_group_conversation(uuid)'::regprocedure)
  ILIKE '%member_left%' AS leave_inserts_member_left_ok;

-- 8) Nonmember isolation smoke (expect 0 rows as anon/nonmember session)
-- SET ROLE authenticated; -- then as a user who is not a member:
-- SELECT count(*) FROM public.group_conversations;
-- SELECT count(*) FROM public.group_messages;

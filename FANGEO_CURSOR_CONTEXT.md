# FanGeo / GameOn — Cursor session continuation

**Created:** 2026-08-13  
**Purpose:** Durable handoff for fresh Cursor chats. Describes **current working-tree code**, not git HEAD and not the previous crashed conversation.  
**Authority:** Files on disk are the source of truth. Do not reset, stash, revert, commit, push, apply production SQL, or deploy Edge Functions unless the user explicitly asks.

---

## 1. Repository identity

| Item | Value |
|---|---|
| Workspace / repo path | `/Users/jthebaut/Desktop/GameOn_RECOVERY_FINAL/GameOn` |
| Git root | `/Users/jthebaut/Desktop/GameOn_RECOVERY_FINAL/GameOn` |
| Branch | `main` |
| HEAD | `8ac7c4880389f178ffe4cad46521ef4ce61048c3` |
| HEAD message | `FanGeo stable working version - August 9 2026` |
| Merge / rebase | None |
| Conflicts | None |
| Staged files | None |
| Tracking | Uncommitted work is substantial; HEAD is **not** the current app |

**This is the existing FanGeo iOS app + Supabase backend.** Product bundle `com.jt.fangio`. Xcode project: `GameOn.xcodeproj` (scheme `GameOn`). Sources live in `GameOn/` as a `PBXFileSystemSynchronizedRootGroup` — new Swift files under `GameOn/` are picked up without pbxproj file entries.

**Uncommitted marketing version (pbxproj only):** `MARKETING_VERSION` 1.1.1 / `CURRENT_PROJECT_VERSION` 28 (HEAD was 1.0.3 / 25).

**Supabase (local tree):** `supabase/config.toml` (`project_id = "WatchZone"`). Linked CLI metadata exists under `supabase/.temp/` (do not treat that as proof of which migrations are applied). Do not print secrets from Vault, Keychain, or env.

**Last git-tracked migration:** `20260949_0001_list_pickup_discover_team_identities.sql`  
**Latest on-disk migration:** `20260999_0001_pickup_games_sport_subtype.sql`  
**Untracked migrations 20260950–20260999:** 50 files. Production apply status is **UNKNOWN** (see §9–10).

---

## 2. Future-session rules

- Treat the current working tree as authoritative.
- Inspect existing helpers/services before adding architecture.
- Reuse canonical RPCs / Edge workers / Inbox / XP ledger. Do not create duplicate systems.
- Preserve backward compatibility.
- Production DB changes = **new forward migrations**. Never edit an already-applied migration as a production fix.
- Never automatically apply production SQL.
- Never automatically deploy Edge Functions.
- Never commit or push unless the user asks.

---

## 3. Architecture overview

FanGeo is a SwiftUI iOS app (Discover / Schedule / Going / **Teams** / Chat / Account) backed by Supabase (Postgres + RLS + RPCs + Realtime + Edge Functions + APNs workers).

Major subsystems:

| Area | Canonical locations |
|---|---|
| App shell / tabs | `MainTabView.swift`, `ContentView.swift`, `TeamsTabRootView.swift`, `ScheduleHubView.swift` |
| Teams | `FanTeamsService.swift`, `FanTeamModels.swift`, `MyTeamsChatViews.swift`, `FanTeamPermissions.swift` |
| Managed players | `FanManagedPlayer*.swift`, `MyPlayersViews.swift`, `AddManagedPlayersToTeamSheet.swift` |
| Inbox / Action Needed | `FanGeoActionCenter*.swift`, `FanGeoNotificationInbox*.swift` |
| Going-tab actions | `GoingActionCenter.swift`, `GoingActionNeededView.swift` (separate from FanGeo Inbox) |
| Fan XP | `FanXPService.swift`, `FanXPProfileLine.swift` — one ledger: `user_xp` / `xp_events` / `claim_fan_xp` |
| Pickup | `PickupGame*.swift`, `MapViewModel+Pickup*.swift` |
| Sports | `AppSportCatalog.swift`, `SportSubtypeCatalog.swift`, `SportFilterMetadata.swift` |
| Chat | `ChatViewModel.swift`, `GroupChatService.swift`, `RecoveredSocialChatViews.swift` |
| Push | `supabase/functions/notify-*`, `supabase/functions/_shared/apns_client.ts`, `sports_worker_auth.ts` |
| Localization | `GameOn/Localizable.xcstrings`, `GameOn/L10n.swift` |

Root tabs (`MainTabView.AppTab`): `discover`, `calendar` (Schedule), `following` (Going), **`teams`**, `chat`, `account`. Legacy `live` remaps to Schedule → Live. Teams is a dedicated tab wrapping `MyTeamsChatSectionView`; Team Chat messages still open the global Chat tab.

---

## 4. Teams implementation

**Status: IMPLEMENTED in client. Large SQL surface is PRESENT BUT REQUIRES SQL (production apply UNKNOWN).**

### Navigation / detail

- Dedicated Teams tab: `TeamsTabRootView` → `MyTeamsChatSectionView`.
- Team Detail tabs: Overview / Chat / Schedule / Roster (`FanTeamDetailTab`).
- Chat tab visibility follows `FanTeamSummary.canAccessTeamChat` (= account seat **or** guardian-via-managed-player). Independent of `is_player`.
- Signed-out Teams: `SignedOutFeatureView` + localization scripts.
- Deep links: invitation / team-management pending flags consumed on Teams tab (`pendingOpenMyTeamsInvitations`). Member-change / member-left / pickup-change deep-link helpers exist.

### Roles (titles)

`FanTeamMemberRole`: `owner`, `manager`, `head_coach`, `assistant_coach`, `captain`, `assistant_captain`, `member`.

- **Team title assignment is Owner-only** (`canAssignMemberRoles` / `FanTeamSummary.canAssignRoles`).
- Canonical write: `set_fan_team_membership_role(p_team_id, p_membership_id, p_role)` via `FanTeamsService.setMemberRole(teamId:membershipId:role:)`.
- Legacy `set_fan_team_member_role(p_team_id, p_user_id, p_role)` remains as an **account-seat adapter only**. Do not use it for managed seats (`user_id` is NULL).
- Owner transfer remains a separate Owner-only workflow.

**Discrepancy (do not “fix” without a task):** `FanTeamMemberRole.canManageTeam` is still `owner || manager` (legacy identity helper). Live gates on `FanTeamSummary` use permission keys (`hasPermission` / `canManage`). Prefer permission helpers.

### Permissions / Team Administrator

- Permission keys: `create_events`, `edit_events`, `publish_announcements`, `invite_members`, `manage_roster`, `manage_lineups`, `manage_managed_players`, `edit_team_information`, `moderate_team_chat`.
- Swift `FanTeamPermissions.roleDefaults`: Owner = all keys; **every other role = empty**. Management is the Team Administrator preset (all keys, never ownership).
- SQL `20260985` originally gave Manager / Head Coach / Assistant Coach role-default keys. `20260987` rewrites defaults to match Swift (Owner all, others none) and backfills Administrator ON/OFF.
- **If 20260985 is applied and 20260987 is not, production SQL disagrees with current client.**

### Schedule / events / scoring

- Team events persist as `pickup_games` + `fan_team_game_links`.
- Event types: `FanTeamEventTypeCatalog` (sport-aware labels; persisted `game_format`). Announcement is not a scored event.
- Scoring: `headToHeadScore` implemented; placement/time/points reserved (`FanTeamEventResultCapability`).
- Lineups, locations, polls, RSVP, announcements, next-event Overview cards: implemented in client; matching SQL 20260951–82 etc.

### Product invariants (Teams)

- Guardian with a managed player on the Team retains Team access even if `is_player = false`.
- Turning Myself off must **not** leave the Team (`set_my_fan_team_is_player`).
- Managed-player seat ≠ guardian/account seat. Canonical identity is `membership_id`.
- Owner-only title assignment. Manager / Team Administrator must not assign titles merely via `can_manage`.
- Chat follows **account access**, not Myself player participation.

---

## 5. Managed-player / guardian architecture

**Status: IMPLEMENTED in client. SQL 20260960–72, 79, 84, 94, 97 PRESENT BUT REQUIRES SQL (production UNKNOWN).**

- Tables / RPCs (on disk): `fan_managed_players`, `fan_managed_player_guardians`, seats on `fan_team_members` with `membership_id`, nullable `user_id`, `managed_player_id`, `is_player`.
- Managed players are Teams-only: no account, no Discover/DM/chat identity.
- Guardian access via `list_my_fan_teams` `access_via = managed_player` (`FanTeamListAccessVia`).
- Players from Your Account / Myself: `FanTeamPlayerMembershipManageSheet`, `set_my_fan_team_is_player`.
- Child-only Team access: `hasTeamAccountAccess == true`, `hasAccountSeat == false`, Chat still shown in UI.
- **SQL 20260997** provisions `group_conversation_members` for any account that can access the Team (guardian of managed seat included). Without it, UI may show Chat while `send_group_message` fails (`is_active_group_member`).
- Role on managed seat: `20260994` relaxes managed-role CHECK (any assignable title except Owner) and adds membership-id RPC.
- `20260995` allowlists `set_my_fan_team_is_player` in `assert_rpc_rate_limit` (live 22023 without this bucket). `20260994` also rewrites the same allowlist (order: 94 then 95 is intended; both try to be self-contained).

---

## 6. Notification architecture

**Status: PARTIALLY IMPLEMENTED as three overlapping stacks. Do not create a fourth.**

From code + `NOTIFICATION_ARCHITECTURE_AUDIT.txt` (2026-08-12, read-only):

| Stack | Role |
|---|---|
| A. Durable FanGeo Inbox | `fan_notification_inbox` + live Action Needed queries. Sheet: Action Needed + Notifications (`FanGeoActionCenterView`). |
| B. Server APNs workers | Family of Edge functions + SQL `pg_net` queues. Shared: `_shared/apns_client.ts`, `authorizeSportsWorkerRequest`. |
| C. iOS local notifications | `GameReminderNotificationService` (reminders / ratings / some pro-game cards). |

A and B are intentionally independent. Recurring production bug class: SQL queue sent Bearer-only while hosted Edge expected dual-key (`Authorization: Bearer` + `apikey`) → Inbox OK, APNs 401.

### Team event Inbox identity (client)

`FanGeoTeamEventNoticeBuilder` labeled rows:

- **Team:** always
- **Game:** for real schedule events (never empty, never a UUID)
- Then changed fields: Date / Time / Location / Status / Opponent
- **Announcements omit the Game row** (`omitsGameRow: true`)

SQL `20260998` snapshots `team_name` onto Inbox payloads so history survives rename/cache miss.

### Dual-key queue migrations (on disk)

- `20260988` pickup change
- `20260990` member-change (+ inbox restore)
- `20260993` Team invitation

Aug 12 audit recorded **20260993 as prepared, not applied**. That is historical notes, not live proof.

### Going vs Inbox

- FanGeo Inbox = Discover/tab-bar Action Center (invites, friend requests, Team/Pickup notifications).
- Going tab has a **separate** `GoingActionCenter` / `GoingActionNeededView` for Going-surface RSVP/schedule rows. Do not merge them into a second Inbox.

---

## 7. Fan XP architecture

**Status: ONE ledger. Pickup/venue/friend = IMPLEMENTED (existing SQL). Team awards = PRESENT BUT REQUIRES SQL `20260996`. Help UI = IMPLEMENTED.**

Canonical:

- Tables: `user_xp`, `xp_events` (unique `uq_xp_events_user_source_dedup`)
- RPCs: `fan_xp_amount_for_source`, `claim_fan_xp`, `fan_xp_validate_and_resolve`
- Client: `FanXPService` / `FanXPSource` — clients cannot choose amounts

Existing amounts (must stay unchanged):

| Source | XP |
|---|---|
| favorite_venue | 2 |
| venue_event_interest | 5 |
| pickup_create | 20 |
| pickup_join_approved | 10 |
| pickup_complete | 15 |
| friend_connected | 5 |

Team sources (`20260996` + Swift catalog):

| Source | XP | Notes |
|---|---|---|
| team_created | 20 | First **5** awarded Teams per account lifetime |
| team_join_player | 10 | Account `is_player` seat only; not managed seats |
| team_event_created | 5 | Max **8** per UTC day; not announcements |
| team_event_completed_player | 10 | Account player on completed Team event |
| team_event_completed_organizer | 15 | Organizer of completed Team event |

Awards are trigger-driven on SQL. Client still calls `awardFanXP(source: teamCreated)` after `createTeam`; `claim_fan_xp` + unique index make this **idempotent if 20260996 is applied**. If 20260996 is not applied, that claim likely no-ops / rejects unknown source.

Help screen: `FanXpCatalog` + info sheet from `FanXpSummaryLine` (profile). Sections: general / pickup / teams. Localization: `scripts/patch_fan_xp_team_localizations.py`.

**Invariant:** managed-player seats must not award guardian player XP. No second XP system. No historical backfill.

---

## 8. Sports / activity architecture

**Status: Client IMPLEMENTED. Column `pickup_games.sport_subtype` PRESENT BUT REQUIRES SQL `20260999`.**

- Top-level sports remain `AppSportCatalog` tokens. Discover chips stay on `sport`.
- Legacy **Biking** canonicalizes to **Cycling** (display + matching). Not a separate chip.
- New top-level sports: **Electric Scooter**, **Inline Skating**.
- Subtypes (`SportSubtypeCatalog`) are **not** sports:
  - Cycling: `road_cycling`, `mountain_biking`, `gravel`, `bmx`, `e_bike`, `casual_ride`, `other`
  - Electric Scooter: `group_ride`, `street_cruise`, `trail_offroad`, `other`
  - Inline Skating: `recreational`, `fitness`, `urban_street`, `speed`, `other`
- Pickup models select/decode `sport_subtype`. Existing Cycling rows with NULL subtype remain valid.
- Running / skiing / climbing subtype families are **not** implemented yet (catalog comment only).

---

## 9. Latest migration inventory (on disk)

All of these are **untracked**. Headers say PREPARE ONLY. **Do not infer production status from file existence.**

| File | Intent |
|---|---|
| 20260950 | Team role hierarchy |
| 20260951 | Event formats meeting/other |
| 20260952 | Event lineups |
| 20260953 | Preferred position |
| 20260954 | Team event change push → active members |
| 20260955 | Friend groups |
| 20260956 | Team self-RSVP pickup request guard |
| 20260957 | Member-left cleanup + push |
| 20260958 | Player-info event exclusion + member-change push |
| 20260959 | Friend-groups helper security |
| 20260960 | Managed players |
| 20260961 | Managed attendance + seats |
| 20260962 | Schedule RSVP event-scoped creator |
| 20260963 | Managed-player rate-limit buckets |
| 20260964 | Team event chat consolidation |
| 20260965 | Managed photo + multi-invite |
| 20260966 | list_my_fan_teams avatar previews |
| 20260967 | Profile My Teams visibility |
| 20260968 | My Teams visibility default everyone |
| 20260969 | Enable managed-player Team seats |
| 20260970 | Fan Teams audit hardening |
| 20260971 | Team chat polls |
| 20260972 | list_my_fan_teams managed-player access |
| 20260973 | Pickup arrival_time |
| 20260974 | Team schedule notifications RSVP reset |
| 20260975 | Team game created push |
| 20260976 | Team announcement schedule type |
| 20260977 | Action Center dismissals |
| 20260978 | Fan Team locations |
| 20260979 | Own managed-player Team membership |
| 20260980 | Locations country/postal |
| 20260981 | Announcement user state |
| 20260982 | Schedule create push all formats |
| 20260983 | `fan_notification_inbox` |
| 20260984 | Account player seat (`is_player` / `set_my_fan_team_is_player`) |
| 20260985 | Flexible permissions |
| 20260986 | Membership permissions contract fix |
| 20260987 | Team Administrator preset + empty role defaults |
| 20260988 | Pickup change push dual-key headers |
| 20260989 | Administrator chat-admin sync fix |
| 20260990 | Member-change Inbox + APNs restore + dual-key |
| 20260991 | Clear Team inbox on membership loss |
| 20260992 | Join-request decision Inbox over-capacity |
| **20260993** | **Team invitation push queue dual-key headers** |
| **20260994** | **Role mutation by membership_id; managed titles; Owner-only** |
| **20260995** | **`set_my_fan_team_is_player` rate-limit bucket** |
| **20260996** | **Fan XP Team awards / anti-farming** |
| **20260997** | **Team Chat follows account access (guardian chat membership)** |
| **20260998** | **Inbox Team name snapshot** |
| **20260999** | **`pickup_games.sport_subtype`** |

Newer than 20260996: **97, 98, 99**. Nothing after 20260999.

SQL tests exist under `supabase/tests/` (untracked) for many of the above. They were **not** executed against production in this session.

---

## 10. SQL deployment inventory

**Cannot be proven from the repository.** Linked project metadata exists; this session did not run `supabase migration list` / `db query`.

What **can** be established:

- Git HEAD last tracked migration: **20260949**.
- Working tree has **50 untracked** forward migrations (20260950–99).
- User stated some of 20260993–96 **may already have been applied manually** while others may not.
- Aug 12 local audit noted 20260993 as prepared/not applied — **stale relative to later work**; do not treat as current production truth.
- Several migrations rewrite the same functions (`assert_rpc_rate_limit`, invitation/member-change/pickup queues, `fan_xp_amount_for_source`). Apply **in filename order**. Never edit an applied file in place.

**Requiring attention (manual review against production):** entire 20260950–20260999 series, especially 20260984–99 for current Team/Inbox/XP/sport contracts.

---

## 11. Edge Function deployment inventory

**Do not deploy from the agent unless asked.**

Modified tracked:

- `supabase/functions/_shared/apns_client.ts`
- `supabase/functions/_shared/fan_team_push_mute.ts`
- `supabase/functions/_shared/sports_worker_auth_test.ts`
- `supabase/functions/notify-fan-team-invitation/index.ts` (dual-key comments; uses `authorizeSportsWorkerRequest`)
- `supabase/functions/notify-pickup-game-change/` (large local rewrite: index + alert + self-test)

Untracked (new workers):

- `supabase/functions/notify-fan-team-member-change/`
- `supabase/functions/notify-fan-team-member-left/`

Helper: `scripts/deploy_team_push_pipeline.sh` (interactive; applies SQL + deploys pickup-change + member-change). **Do not run unless the user explicitly requests it.**

Hosted vs local status: **UNKNOWN**. Dual-key SQL without matching Edge deploy (or vice versa) reproduces the 401 APNs class.

---

## 12. App / uncommitted work

Counts at reconstruction (2026-08-13):

- Modified tracked: **101**
- Untracked: **235** (105 Swift under `GameOn/`, 50 migrations, 29 SQL tests, 39 localization patch scripts, assets, Edge functions, audits)
- Staged: **0**

Notable uncommitted client areas: Teams tab, managed players, FanGeo Inbox, Going Action Needed, Fan XP Team catalog, sport subtypes, friend groups, Team locations/lineups/polls/announcements, Schedule hub, Profile My Teams, signed-out feature views, localization (`Localizable.xcstrings`).

Xcode sync root means new `GameOn/*.swift` files compile without pbxproj entries. pbxproj diff is version bump only (1.0.3→1.1.1, 25→28).

**Rebuild/reinstall: YES** for any device/simulator that is still on HEAD (Aug 9). Current Debug simulator build succeeded (see §15).

---

## 13. Localization

`L10n.supportedLanguages`: en, es, fr, pt, de, it, pl, ru, sq (Albanian), zh-Hans.

Catalog: `GameOn/Localizable.xcstrings` (sourceLanguage `en`). Recent Team / Inbox / XP / sport strings were added via `scripts/patch_*_localizations.py` (untracked) plus direct xcstrings edits (tracked file modified).

---

## 14. Important product invariants (verify in code before changing)

1. Guardian Team access is independent of `is_player`.
2. Myself off ≠ leave Team.
3. `membership_id` is the roster seat identity; managed `user_id` is NULL.
4. Owner-only Team title assignment; Team Administrator is permissions, not ownership, and cannot assign titles.
5. Team event Inbox: Team: + Game: + field rows; announcements have no Game: label.
6. One XP ledger. Team awards must not farm; managed seats must not grant guardian player XP; Pickup amounts unchanged.
7. One sport token space; subtypes are optional metadata, not Discover chips.
8. Inbox and APNs stay independent; do not duplicate either.

---

## 15. Known unresolved issues / discrepancies

1. **Production SQL/Edge apply status unknown** for 20260950–99 and related workers.
2. **20260985 vs 20260987** permission defaults: client matches 87; 85 alone would still give Manager/Coach role defaults.
3. **Guardian Chat:** UI shows Chat; send path needs **20260997** group membership.
4. **Remove Myself / is_player:** needs **20260984** body + **20260995** rate-limit allowlist (94 also allowlists related buckets).
5. **Managed Captain titles:** needs **20260994** (CHECK + membership RPC). Client already calls `set_fan_team_membership_role`.
6. **Team XP:** needs **20260996**. Help UI already lists Team rules.
7. **Sport subtype persist:** needs **20260999**. Client already encodes/selects the column.
8. **Invitation APNs:** Inbox can succeed while banners fail until **20260993** SQL + `notify-fan-team-invitation` dual-key deploy.
9. **Notification stack** is still three families (Inbox / many APNs workers / local). Consolidation is recommended in the Aug 12 audit, not started as a rewrite.
10. `FanTeamMemberRole.canManageTeam` leftover vs permission-based `FanTeamSummary.canManage`.
11. Client `awardFanXP(teamCreated)` plus SQL trigger is idempotent only after 20260996.
12. Going Action Center vs FanGeo Inbox are parallel; do not duplicate.

---

## 16. Tests and build (this session)

**Build (2026-08-13):**

```
xcodebuild -scheme GameOn -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build
```

**BUILD SUCCEEDED** (iPhone 16 simulator, iOS 26.5). `iPhone 16` was available; no project destination change.

DEBUG self-tests compile into the app (`ContentView` launch: `FanTeamsSelfTests`, `FanXPSelfTests`, `ManagedPlayerTeamAccessSelfTests`, `FanGeoActionCenterSelfTests`, `SportSubtypeCatalogSelfTests`, `FanTeamPermissionsSelfTests`, and many others). They were **not executed at runtime** in this reconstruction (no app launch). Compile success is not a substitute for DEBUG launch assertions.

SQL tests under `supabase/tests/` were not applied/run against any database.

---

## 17. DEPLOYMENT CHECKLIST (do not execute from this file)

### SQL

Production status **UNKNOWN**. Filenames requiring attention (review `supabase migration list` / object probes before any apply):

- `20260950_0001_fan_team_role_hierarchy.sql` … through …
- `20260999_0001_pickup_games_sport_subtype.sql`

Highest-priority for current contracts if not already applied:

- `20260993_0001_fan_team_invitation_push_queue_dual_key_headers.sql`
- `20260994_0001_fan_team_membership_role.sql`
- `20260995_0001_set_my_fan_team_is_player_rate_limit_bucket.sql`
- `20260996_0001_fan_xp_team_awards.sql`
- `20260997_0001_fan_team_chat_follows_account_access.sql`
- `20260998_0001_fan_notification_inbox_team_name_snapshot.sql`
- `20260999_0001_pickup_games_sport_subtype.sql`

Plus earlier untracked Team/Inbox foundations (20260960–92) if production is still on git-tracked 20260949.

### EDGE FUNCTIONS

- `notify-fan-team-invitation`
- `notify-pickup-game-change`
- `notify-fan-team-member-change` (new)
- `notify-fan-team-member-left` (new)

Shared: `_shared/apns_client.ts`, `_shared/fan_team_push_mute.ts` (deployed with the functions that import them).

### APP

**rebuild/reinstall: YES** (working tree ≠ HEAD; Debug simulator build succeeded this session).

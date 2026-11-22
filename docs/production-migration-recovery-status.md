# Production migration recovery — status and safety notes

**Status:** In progress; documentation only at this stage  
**Source branch:** `main` of `Aymanagag/robotic-assist-test`  
**Recovery branch:** `migration-recovery/production-readiness`  
**Production changes:** None.  
**TEST database changes during this recovery:** None.

## Purpose

Recover the exact database migration source used to build the TEST application, compare it with the current production schema, and prepare a production-compatible rollout plan. This branch is deliberately separate from `main`. It is not a deployment branch and must not be merged or applied until the migration set has been completed, reviewed, and rehearsed.

## Confirmed TEST migration history

The TEST project currently reports 17 migration-history entries:

1. `20261121144503_create_synthetic_robotic_assist_schema`
2. `20261121144507_distinguish_explicit_unavailability`
3. `20261121152435_configure_test_app_rls_view_and_supporting_rpcs`
4. `20261121152450_restrict_test_database_anon_privileges`
5. `20261121175125_add_change_case_assistant`
6. `20261121175333_remove_assistant_from_case`
7. `20261121181622_add_completed_case_status`
8. `20261121181643_preserve_accepted_invitation_on_completion`
9. `20261121183032_harden_test_database_permissions`
10. `20261121184317_allow_admin_booking_overlap_override`
11. `20261121200308_add_audited_case_timing_change`
12. `20261121200802_allow_admin_choice_to_preserve_case_invitation`
13. `20261121211827_add_in_app_notifications`
14. `20261121222001_create_assistant_profiles_for_invited_auth_users`
15. `20261121222534_add_profile_email_for_admin_user_management`
16. `20261121223849_fix_invited_assistant_profile_trigger_timing`
17. `20261121224529_add_secure_user_role_and_activation_management`

The history table records versions and names, not the original SQL text. A history entry alone is not proof that its executable source has been recovered.

## Source recovered from GitHub PR patches

The following SQL changes have been retrieved from validated changed-file paths in the relevant PRs:

| PR | Migration file / change | Recovery status |
|---|---|---|
| #4 | `20261121181500_add_completed_case_status.sql` | Exact PR patch recovered |
| #5 | `20261121183000_harden_test_database_permissions.sql` | Exact PR patch recovered |
| #7 | `20261121184500_allow_admin_booking_overlap_override.sql` | Exact PR patch recovered |
| #14 | `20261121211800_add_in_app_notifications.sql` | Initial exact PR patch recovered |
| #15 | Same notifications migration file | Later amendment recovered; includes indexes and trigger-function EXECUTE revocations |
| #19 | `20261121222001_create_assistant_profiles_for_invited_auth_users.sql` | Exact PR patch recovered |
| #22 | `20261121225000_add_secure_user_role_and_activation_management.sql` | Exact PR patch recovered, but filename/version discrepancy requires reconciliation |

PR #14 and PR #15 refer to the same migration filename. They must be treated as the evolution of one migration source, not two independent migrations. The later PR #15 patch adds the recipient/created and case indexes and revokes direct execution of the notification trigger functions.

## Unrecovered or unresolved migration source

The following TEST history entries do not yet have verified original SQL source in this recovery:

- `20261121144503_create_synthetic_robotic_assist_schema`
- `20261121144507_distinguish_explicit_unavailability`
- `20261121152435_configure_test_app_rls_view_and_supporting_rpcs`
- `20261121152450_restrict_test_database_anon_privileges`
- `20261121175125_add_change_case_assistant`
- `20261121175333_remove_assistant_from_case`
- `20261121181643_preserve_accepted_invitation_on_completion`
- `20261121200308_add_audited_case_timing_change`
- `20261121200802_allow_admin_choice_to_preserve_case_invitation`
- `20261121222534_add_profile_email_for_admin_user_management`
- `20261121223849_fix_invited_assistant_profile_trigger_timing`

PRs #1–3 contained only frontend changes. The first TEST schema and RLS migration entries therefore do not have corresponding migration files in those PRs. Other missing changes may have been applied directly to the TEST database or committed outside the PRs inspected so far. Do not assume their original SQL is recoverable from migration history.

These must be recovered from earlier commits/branches where possible. If original SQL cannot be found, any reconstruction must be labelled as reconstructed, generated from a documented TEST schema diff, and reviewed separately. It must not be represented as the original migration.

## Version discrepancy requiring resolution

The TEST migration history reports:

`20261121224529_add_secure_user_role_and_activation_management`

The merged PR #22 changed-file path is:

`20261121225000_add_secure_user_role_and_activation_management.sql`

These version identifiers differ. Do not rename, replay, or mark either version applied until the exact database history row, PR merge commit, and resulting live schema are reconciled. A migration-history mismatch can cause duplicate or skipped execution.

## Live schema comparison (read-only inspection)

A read-only inspection of both live databases confirms:

- Both environments have the same core public tables: assistants, audit_logs, availability, hospitals, invitations, procedures, profiles, surgeons and surgical_cases. Both also expose a `calendar_events` view.
- TEST has an additional `notifications` table and notification triggers.
- TEST `profiles` has `email` and `is_active`; production does not.
- TEST `surgical_cases` has `completed_at` and `completed_by`; production does not. TEST also accepts the `completed` status; production's status constraint does not.
- TEST has additional RPCs for assistant reassignment, assistant removal, case timing changes, case completion, admin user role changes and account activation, plus active-user checks and notification functions.
- TEST's RLS policies include active-account checks. Production's existing policies do not contain these checks and use the older policy set.
- Production has legacy functions and policies that must be reviewed and safely replaced or retained deliberately; simply applying all TEST SQL over production is not a safe migration strategy.

The `calendar_events` view is present in both environments; it is not a TEST-only table. This comparison is based on current catalog inspection and is not a full dependency-aware schema diff yet. Index definitions, grants, function bodies, trigger definitions, publication membership, Auth settings, and Edge Function secrets still require separate reconciliation.

## Production compatibility is not established

TEST and production are not schema-identical. TEST includes, among other changes, profile email and activation fields, a completed case state, notifications, assistant reassignment/removal/completion/timing RPCs, and invitation/user-management support. Production has existing users, cases, invitations, audit records, and its own legacy RPCs.

The TEST-only synthetic seed/schema migration must not be replayed against production. Production rollout must be additive and data-preserving, with explicit handling for existing rows, constraints, policies, grants, triggers, functions, and Auth users. Existing production data must not be overwritten with TEST data.

## Rehearsal and release gates

Before any production deployment:

1. Recover all original migration files or document exact reconstructed replacements.
2. Reconcile every migration version against TEST's migration-history table and Git commit history.
3. Diff production and TEST schemas, including table definitions, constraints, indexes, policies, grants, triggers, functions, publications, and Auth configuration.
4. Create a disposable Supabase development branch from TEST for rehearsal only after any applicable usage cost is disclosed and approved by the platform.
5. Test migrations against a production-shaped schema with synthetic data; validate idempotency assumptions, rollback/forward recovery, existing-row compatibility, and security behavior.
6. Complete function-by-function review of all SECURITY DEFINER functions and the Auth invitation/password setup flow.
7. Prepare a reviewed production rollout order, backup/restore plan, post-deployment verification checklist, and explicit go/no-go decision.

No production migration, function, setting, user, or data change is authorized by this document. A separate explicit approval is required before any production action.

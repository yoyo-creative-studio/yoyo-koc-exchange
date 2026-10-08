# Creator Onboarding Verification Plan

Status: Planned, not implemented

This document is the implementation handoff for adding a required creator onboarding quiz to Discord through MochiBot. It must not be presented as a live feature until the full workflow has been deployed and verified.

## Goal

Require new creators to read the core program rules and pass a short verification before receiving full creator-channel access. The feature should reduce repeated FAQ questions and accidental disclosure of internal point, engagement, reward, or campaign information.

## Recommended Experience

```text
Join Discord server
-> Accept Discord Rules Screening
-> See only Start Here, Rules, FAQ, and Verification
-> Click Start Verification
-> Read the short Creator Guide
-> Answer five multiple-choice questions
-> Pass all required questions
-> MochiBot grants Certified Creator
-> Full creator channels become visible
```

MochiBot may send a welcome DM containing the verification-channel link, but DM delivery is optional. Users who block server-member DMs must still be able to complete verification inside the server.

## Discord Configuration

### Native Rules Screening

Enable Discord Community and Rules Screening for the server-wide rules. This is the first confirmation layer, not the creator quiz.

### Channel Access

Before verification, `@everyone` should only be able to view:

- `start-here`
- `creator-rules`
- `creator-faq`
- `creator-verification`
- any required Discord safety or announcement channel

Full KOC channels should require the `Certified Creator` role.

### Bot Permissions

MochiBot requires:

- View Channels
- Send Messages
- Embed Links
- Use Application Commands
- Manage Roles

The MochiBot role must be positioned above `Certified Creator`. It must not receive Administrator unless technically unavoidable.

## Verification Interaction

1. A persistent message in `creator-verification` contains a `Start Verification` button.
2. Clicking it opens an ephemeral interaction visible only to that member.
3. The member reads a concise Creator Guide and confirms `I have read the guide`.
4. MochiBot presents five multiple-choice questions.
5. Incorrect answers show the relevant rule explanation and allow another attempt.
6. Passing grants `Certified Creator`, records the result, and displays the next steps.
7. Repeated clicks by an already verified creator return the existing verification status without duplicating roles or records.

Do not run the quiz through ordinary public channel messages. Use Discord buttons, select menus, modals, and ephemeral responses so answers do not clutter the server or reveal the answer key.

## Initial Knowledge Areas

The first rule version should test these five subjects:

1. Work links must be submitted through the Creator Portal.
2. Internal point, engagement, reward, and campaign details must not be disclosed publicly.
3. Game bugs, account problems, payments, and gameplay feedback use game support, not Creator Program feedback.
4. MochiBot notifications should not be answered by DM; support questions belong in the designated service channel.
5. Joining Discord alone does not complete official creator registration or verification.

Questions, answer options, explanations, and the passing requirement must be configurable in the admin console. Do not hard-code the only copy into the bot function.

## Data Model

Create versioned configuration and immutable attempt records. Suggested tables:

### `creator_verification_rules`

- `id`
- `version`
- `title`
- `guide_content`
- `questions_json`
- `passing_score`
- `is_active`
- `created_at`
- `updated_at`

### `creator_verification_attempts`

- `id`
- `discord_user_id`
- `rules_version`
- `score`
- `passed`
- `answers_json`
- `attempt_number`
- `created_at`

### `creator_verification_status`

- `discord_user_id` as the stable identity
- `rules_version`
- `status`: `not_started`, `in_progress`, `passed`, or `revoked`
- `passed_at`
- `role_granted_at`
- `role_grant_error`
- `manually_overridden_by`
- `updated_at`

Use Discord User ID as the key. Never bind verification by display name or username.

## MochiBot and Backend Work

Add interaction handling to the existing privileged Discord boundary, not the public GitHub Pages frontend.

Required operations:

- publish or refresh the persistent verification message
- start or resume verification
- submit an answer
- calculate the result server-side
- grant or revoke the configured Discord role
- retrieve verification status
- retry failed role grants safely
- allow an administrator to pass or revoke a member manually

Answer keys, bot tokens, service-role keys, and privileged Discord actions must remain in an Edge Function or another protected backend. The browser may receive question text and options, but it must not receive the answer key.

Every role operation and status transition must be idempotent. Retrying a successful request must not create duplicate attempts or repeatedly alter roles.

## Admin Console Module

Add a `Creator Verification` section containing:

- active rule version and publication state
- editable guide content
- editable questions, options, correct answers, and explanations
- passing requirement
- verified, unverified, failed, and role-grant-error counts
- searchable member list
- attempt count and latest attempt time
- manual pass
- revoke verification
- retry role assignment
- publish a new rules version
- optionally require existing creators to acknowledge a new version

Publishing a new version must not silently revoke existing creators. Re-verification should be an explicit admin choice with a preview of affected members.

## Join and DM Behavior

On member join, MochiBot should:

1. Record the Discord User ID and join time.
2. Check whether the member already passed the active rule version.
3. Attempt one welcome DM with a link to `creator-verification`.
4. If the DM fails, record the failure without blocking onboarding.
5. Never repeatedly DM the same member on each scan or bot restart.

The server verification channel remains the authoritative entry point.

## Failure Handling

- Closed DMs: continue through the server channel.
- Member leaves mid-quiz: preserve status; allow resume after rejoining.
- Role grant fails: keep `passed`, record the error, and expose Retry in admin.
- Username changes: continue matching by Discord User ID.
- Bot restarts: resume from database state.
- Duplicate interactions: return the existing result idempotently.
- Rule version changes during an attempt: finish against the version used when that attempt started.

## Security and Privacy

- Never store Discord bot tokens in the frontend, database rows readable by creators, Git history, or logs.
- Apply RLS so creators cannot read other members' attempts or status.
- Do not expose correct answers through public API responses.
- Log administrative overrides with actor, time, target Discord User ID, and reason.
- Store only information required for verification and operations.

## Acceptance Tests

1. A new member can see only onboarding channels before verification.
2. A user with closed DMs can complete verification in the server.
3. Wrong answers do not grant the role and show the relevant explanation.
4. A full pass grants `Certified Creator` once.
5. Repeating the final interaction does not duplicate records or role operations.
6. Username or display-name changes do not lose verification status.
7. A Discord API role error is visible in admin and can be retried.
8. Manual pass and revoke actions are audited.
9. Existing creators are not revoked when a new rules version is published unless an admin explicitly requires re-verification.
10. Answer keys and credentials are absent from browser source and network responses.

## Delivery Order

1. Configure Discord Rules Screening and onboarding-only channel permissions.
2. Add Supabase tables, RLS, indexes, and idempotent RPCs.
3. Add MochiBot interaction and role-management operations.
4. Add the persistent verification message and ephemeral quiz.
5. Add the admin configuration and monitoring module.
6. Test with a non-admin test account that has DMs disabled.
7. Pilot with a small group before enforcing access restrictions for all new members.
8. Update `flowcharts.html` only after the feature is deployed.

## Deferred Decision

This feature is intentionally deferred. Do not start implementation merely because this document exists. Begin only when Seraphina explicitly requests development of Creator Onboarding Verification.

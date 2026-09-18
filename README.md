# Yoyo Town KOC Creator System

Production system for the MLT Creator Program. It covers creator registration, submission review, monthly scoring, tier management, reward redemption, fulfillment, Discord notifications, and operational reporting.

## Production Surfaces

| Surface | URL / file | Purpose |
|---|---|---|
| Creator Portal | `index.html` | Submissions, points, tiers, redemption, order status, FAQ |
| Admin Console | `admin.html` | Registration review, KOC records, scoring, fulfillment, broadcasts, reports |
| System Flowcharts | `flowcharts.html` | End-to-end creator and admin workflow |
| Project Portfolio | `portfolio.html` | Product case study and implementation summary |
| Backend | Supabase | PostgreSQL, RLS, RPCs, scheduled jobs, Edge Functions |

Production site: <https://yoyo-creative-studio.github.io/yoyo-koc-exchange/>

## Architecture

- Static HTML/CSS/JavaScript frontends deployed with GitHub Pages.
- Supabase stores creators, submissions, point logs, redemption orders, fulfillment records, settings, and audit data.
- Edge Functions handle privileged Discord and registration operations: `discord-proxy`, `registration-review`, and `mochi-auto-welcome`.
- Tier rules shared by both frontends live in `tier-rules.js`.
- Shared admin utilities live in `admin-shared.js`.

Never add service-role keys, Discord bot tokens, or administrator credentials to committed frontend code. Supabase publishable keys may be public only when RLS and RPC authorization are correctly enforced.

## Identity Model

`discord_user_id` is the stable Discord identity. Names are searchable aliases, not primary keys.

The `kocs` identity fields are:

- `discord_user_id`: immutable Discord snowflake; unique when present.
- `discord_username`: current account username.
- `discord_display_name`: current server display name.
- `discord_aliases`: historical names used for search and fallback matching.
- `discord_name`: manually maintained legacy/display label retained for compatibility.
- `discord_identity_synced_at`: last successful identity synchronization time.

Matching priority:

1. Exact Discord User ID.
2. Exact normalized username, display name, or alias.
3. Write a match only when it is unique.
4. Never guess an ambiguous identity from similarity.

The admin search supports Discord names, aliases, Discord User ID, game UID, and 19-digit account ID. Broadcast matching, tier synchronization, and newcomer detection must prioritize Discord User ID.

Current synchronization baseline (2026-09-18): 117 active KOCs, 112 bound, 0 duplicate Discord User IDs. Unbound records are `adalia`, `ClarySage8611`, `Lilypad`, `Pretzel Pai`, and `李莎 红羽的测试号`; do not hard-bind them without a provable unique match.

## Reward Invariants

- A creator may submit one combined redemption order per redemption period; reward types belong to that order.
- Creator-facing order requests and rendering must be UID-bound and fetched with `cache: no-store`.
- Account switching and logout must clear prior creator order state before loading another account.
- Reward submission reserves/deducts the selected points immediately so the creator does not see spent points as available.
- A failed or rejected fulfillment may restore points exactly once. Publishing a valid fulfillment must reconcile any earlier refund exactly once.
- Fulfillment categories remain operationally separate: merchandise, Google Play, and in-game rewards.
- In-game fulfillment is deduplicated into three lists: continuous-creation reward only, diamonds only, or both.
- The creator portal is English-only, including order statuses, fulfillment notes, empty states, errors, and helper copy.

Fulfillment status meaning:

- `pending`: submitted and waiting for admin processing.
- `processing`: accepted and being prepared.
- `shipped` / fulfilled: issued by operations and visible in My Orders with the applicable code, tracking number, or delivery instruction.

## Merchandise Import Rules

- Treat the current logistics CSV as the authoritative shipment list for that import.
- A row explicitly marked as a current newcomer gift may create a missing zero-point welcome-gift order.
- Never recreate historical newcomer gifts that were already received.
- A current newcomer gift and monthly redemption merchandise may share one tracking number and be merged for logistics.
- Attach only orders from the source period; do not pull old historical orders into the current shipment.

## Current Production Audit

Audit completed on 2026-09-18:

- Published fulfillment records: 147 total (41 merchandise, 16 Google Play, 90 in-game).
- Positive-point published orders: 67.
- Corrected 42 fulfilled orders / 675 points that had previously been refunded.
- No published fulfillment without an order.
- No published fulfillment linked to an invalid creator.
- No fulfilled order missing its point deduction.
- No remaining uncorrected pre-fulfillment refund.
- No negative creator balance.

## Development

```bash
npm install
npm test
```

`npm test` performs inline JavaScript syntax validation for `admin.html` and `index.html`, then runs tier-rule tests.

Database changes belong in timestamped files under `supabase/migrations/`. Deploy only after reviewing the migration and verifying the target Supabase project.

## Delivery Rules

- Make focused changes from the current `main` branch.
- Do not commit `.env`, bot tokens, service-role keys, generated Supabase temp files, or unrelated local changes.
- Validate relevant behavior, commit the intended files, push to `origin/main`, and confirm the remote commit.
- After production data corrections, record counts and invariants in the handoff documentation so future work does not reintroduce the same error.

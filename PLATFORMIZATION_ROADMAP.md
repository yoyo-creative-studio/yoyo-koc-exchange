# KOC Platformization Roadmap

## Current Production Baseline

Snapshot reviewed on 2026-10-10:

- 149 active creator records.
- 268 submission records: 115 for 2026-08 and 153 for 2026-09.
- 4,075 submitted links: 1,822 for 2026-08 and 2,253 for 2026-09.
- 314 reward orders across merchandise, Google Play, and in-game rewards.
- 362 audit records.
- One legacy monthly report snapshot exists, for 2026-07.

The system runs the full business loop, but historical time spent, failure rate, and manual intervention were not captured consistently. The claimed 80% reduction in labor should remain labeled as an estimate until measured snapshots are available.

## Main-Flow Audit

### P0: Security And Ownership Boundary

- The admin page can restore its visible session from a local browser flag. It must require a valid in-session credential and server verification.
- Some privileged writes still go directly from the browser to REST tables. These must move behind authenticated Edge Functions or service-role RPCs before the system supports multiple teams.
- The Discord bot token is entered in the browser and sent to a proxy. A platform version must keep bot credentials only in server-side project secrets.

### P0: Measurability

- Audit logs describe actions but do not consistently record duration, affected record count, failure code, or retry outcome.
- Monthly snapshots are not generated consistently.
- Support feedback exists, but product issues are not classified by workflow, severity, recurrence, or resolution time.

### P1: Single-Project Coupling

- Supabase URL, Discord guild, brand copy, reward catalog, language, and timezone are global constants.
- `campaign_config` assumes one globally current period.
- Creator, submission, point, order, fulfillment, and notification records do not yet carry project ownership.

### P1: Maintainability

- `admin.html` contains UI, state, data access, validation, and business orchestration in one large file.
- Similar lifecycle logic exists in browser code, RPCs, and Edge Functions.
- Automated tests cover syntax and tier rules but not registration, submission, balance reservation, fulfillment, or cross-period isolation.

## Metrics To Capture Monthly

| Metric | Definition | Source |
|---|---|---|
| Active creators | Active creator records at period close | `kocs` snapshot |
| Participating creators | Unique creators with valid work submissions | `submissions` |
| Submission rate | Participating creators / eligible active creators | Derived snapshot |
| Submitted links | Normalized valid work links received | `submissions` |
| Review throughput | Links reviewed / review duration | Operational events |
| Settlement duration | Scoring import start to successful completion | Operational events |
| Redemption participation | Unique paid redeemers / participating creators | Orders + submissions |
| Fulfillment lead time | Order submission to published fulfillment | Orders + fulfillment |
| Workflow failure rate | Failed events / completed events by workflow | Operational events |
| Manual interventions | Admin corrections and manual point changes | Audit + operational events |
| Support issue volume | Issues by workflow and root cause | Feedback classification |
| Estimated hours saved | Previous baseline hours minus measured current hours | Monthly snapshot |

## Migration Sequence

Current status: Phase 1 is deployed. Phase 2 now includes project profiles and project-scoped reward configuration; only `mlt-global` is connected to production business data.

### Phase 1: Foundation

- Create `platform_projects` with the existing MLT Global program as the default project.
- Create project-scoped operational events and monthly metric snapshots.
- Establish the product decision log and metric definitions.
- Tighten admin session restoration.

### Phase 2: Configuration

- Move brand, locale, timezone, Discord guild, reward catalog, tier rules, and campaign behavior into project configuration.
- Add a project selector to the admin console.
- Keep the creator portal on the default project until validation is complete.

### Phase 3: Data Ownership

- Add nullable `project_id` to core business tables.
- Backfill all existing production records to `mlt-global`.
- Add dual-read checks, then make project ownership mandatory and update uniqueness constraints.

### Phase 4: Roles And Templates

- Introduce authenticated organizations, project membership, and role permissions.
- Provide reusable onboarding, scoring, redemption, fulfillment, and notification templates.
- Replace browser-held bot credentials with server-side project secrets.

### Phase 5: Portfolio Demo

- Add anonymized demo projects and seeded data.
- Show project creation, rule configuration, monthly workflow, and cross-project dashboards.
- Keep production creator data inaccessible from the public demo.

## Exit Criteria For A Reusable Platform MVP

1. A second demo project can be created without code changes.
2. Project A cannot read or modify Project B data.
3. Rewards, rules, language, timezone, and workflow switches are project-configurable.
4. Admin roles restrict review, scoring, fulfillment, and configuration actions.
5. Monthly metrics and failure rates are generated from recorded events.
6. The existing MLT Global workflow continues to pass production checks.

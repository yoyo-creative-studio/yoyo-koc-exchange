# KOC Platform Product Decisions

This log records decisions that materially affect creator balances, monthly settlement, reward fulfillment, identity, security, or future platform reuse.

## Decision Principles

1. Production facts live in the database, not in browser state or copied spreadsheets.
2. Financially meaningful actions are atomic, idempotent, and auditable.
3. Creator identity uses stable IDs; names are searchable aliases.
4. Campaign periods isolate submissions, scoring, redemption, and fulfillment.
5. Existing creator rights only move forward unless an administrator explicitly corrects an error.
6. Platformization uses an expand-migrate-contract sequence so the live MLT program is never blocked by schema conversion.

## Decision Log

| ID | Decision | Why | Consequence |
|---|---|---|---|
| PD-001 | `point_logs` is the balance source of truth. | Cached balances drift after retries and manual corrections. | Every balance is derived from immutable point changes. |
| PD-002 | Discord User ID is the stable community identity. | Usernames and display names change frequently. | Names remain aliases; automatic matching never guesses ambiguous creators. |
| PD-003 | A creator has one combined redemption request per period. | Separate orders created duplicate selections and confusing balances. | Reward types are grouped by `request_id`; pending edits replace the full selection. |
| PD-004 | Submitted rewards reserve points immediately. | Creators otherwise believe spent points remain available. | Pending and processing totals are excluded from available balance. |
| PD-005 | Reward fulfillment types remain operationally separate. | Merchandise, Google Play, and in-game rewards have different data and handoff formats. | They share an order lifecycle but keep separate fulfillment records and exports. |
| PD-006 | Campaign data is isolated by `period`. | Switching months previously exposed or mixed prior-month work. | Every monthly query and write must include an explicit period. |
| PD-007 | Tier rules are versioned by effective month. | New requirements must not rewrite historical progression. | August 2026 and earlier use legacy results; September onward uses capped content points. |
| PD-008 | Platformization starts with a project boundary, without rewriting live records. | A big-bang tenant migration creates unacceptable production risk. | `platform_projects` is introduced first; existing tables receive project ownership only after dual-read validation. |
| PD-009 | Efficiency claims require event and metric evidence. | The current 80% time-saving figure is an informed estimate, not a measured series. | Operational events and monthly metric snapshots become the evidence source. |
| PD-010 | Creator-facing surfaces remain English-only. | The active creator audience is international. | Admin tools may use Chinese; portal copy cannot. |
| PD-011 | Reward prices are validated by project configuration in the database. | Browser-displayed prices can be modified by clients. | New paid orders must be an exact multiple of an active server-side reward unit cost. |

## How To Add A Decision

Add a new row when a change affects business rules, data ownership, permissions, lifecycle states, or metric definitions. Do not use this file as a feature changelog.

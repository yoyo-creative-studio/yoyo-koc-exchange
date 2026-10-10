const fs = require('fs');
const assert = require('assert');

const adminShared = fs.readFileSync('admin-shared.js', 'utf8');
const portal = fs.readFileSync('index.html', 'utf8');
const migration = fs.readFileSync('supabase/migrations/20261010213000_core_project_ownership.sql', 'utf8');

for (const table of ['kocs', 'registration_applications', 'submissions', 'point_logs', 'redemption_orders', 'reward_fulfillments', 'redemption_order_edits']) {
  assert(migration.includes(`ALTER TABLE public.${table} ADD COLUMN IF NOT EXISTS project_id`), `${table} must receive project ownership`);
  assert(migration.includes(`ALTER TABLE public.${table} ALTER COLUMN project_id SET NOT NULL`), `${table}.project_id must be required after backfill`);
}

assert(adminShared.includes("project_id=eq."), 'admin requests must apply project filtering');
assert(portal.includes("project_id=eq."), 'creator requests must apply project filtering');
assert(portal.includes("window.ACTIVE_PROJECT_ID = data[0].project_id"), 'portal must resolve the active project before creator data loads');
assert(migration.includes("RAISE EXCEPTION 'project ownership does not match the parent record'"), 'database must reject cross-project child records');

console.log('Project isolation checks passed.');

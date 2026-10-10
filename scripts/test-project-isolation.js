const fs = require('fs');
const assert = require('assert');

const adminShared = fs.readFileSync('admin-shared.js', 'utf8');
const portal = fs.readFileSync('index.html', 'utf8');
const migration = fs.readFileSync('supabase/migrations/20261010213000_core_project_ownership.sql', 'utf8');
const identityMigration = fs.readFileSync('supabase/migrations/20261010230000_stable_creator_identity.sql', 'utf8');

for (const table of ['kocs', 'registration_applications', 'submissions', 'point_logs', 'redemption_orders', 'reward_fulfillments', 'redemption_order_edits']) {
  assert(migration.includes(`ALTER TABLE public.${table} ADD COLUMN IF NOT EXISTS project_id`), `${table} must receive project ownership`);
  assert(migration.includes(`ALTER TABLE public.${table} ALTER COLUMN project_id SET NOT NULL`), `${table}.project_id must be required after backfill`);
}

assert(adminShared.includes("project_id=eq."), 'admin requests must apply project filtering');
assert(portal.includes("project_id=eq."), 'creator requests must apply project filtering');
assert(portal.includes("window.ACTIVE_PROJECT_ID = data[0].project_id"), 'portal must resolve the active project before creator data loads');
assert(migration.includes("RAISE EXCEPTION 'project ownership does not match the parent record'"), 'database must reject cross-project child records');
assert(identityMigration.includes('idx_kocs_creator_id_unique'), 'creators must receive an immutable unique identity');
for (const table of ['submissions', 'point_logs', 'redemption_orders', 'reward_fulfillments', 'redemption_order_edits', 'creator_monthly_tier_scores', 'creator_tier_history']) {
  assert(identityMigration.includes(`ALTER TABLE public.${table} ALTER COLUMN creator_id SET NOT NULL`), `${table}.creator_id must be required after backfill`);
}
assert(identityMigration.includes("RAISE EXCEPTION 'creator identity does not match project and UID'"), 'database must reject mismatched creator references');

console.log('Project isolation checks passed.');

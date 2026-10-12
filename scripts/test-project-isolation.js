const fs = require('fs');
const assert = require('assert');

const adminShared = fs.readFileSync('admin-shared.js', 'utf8');
const portal = fs.readFileSync('index.html', 'utf8');
const migration = fs.readFileSync('supabase/migrations/20261010213000_core_project_ownership.sql', 'utf8');
const identityMigration = fs.readFileSync('supabase/migrations/20261010230000_stable_creator_identity.sql', 'utf8');
const portalRpcMigration = fs.readFileSync('supabase/migrations/20261011010000_project_creator_portal_rpcs.sql', 'utf8');
const campaignWindowMigration = fs.readFileSync('supabase/migrations/20261011011500_project_campaign_window_helper.sql', 'utf8');
const adminRpcMigration = fs.readFileSync('supabase/migrations/20261011030000_project_creator_admin_rpcs.sql', 'utf8');

for (const table of ['kocs', 'registration_applications', 'submissions', 'point_logs', 'redemption_orders', 'reward_fulfillments', 'redemption_order_edits']) {
  assert(migration.includes(`ALTER TABLE public.${table} ADD COLUMN IF NOT EXISTS project_id`), `${table} must receive project ownership`);
  assert(migration.includes(`ALTER TABLE public.${table} ALTER COLUMN project_id SET NOT NULL`), `${table}.project_id must be required after backfill`);
}

assert(adminShared.includes("project_id=eq."), 'admin requests must apply project filtering');
assert(adminShared.includes('row.project_id = projectId'), 'admin inserts must receive active project ownership');
assert(portal.includes("project_id=eq."), 'creator requests must apply project filtering');
assert(portal.includes("window.ACTIVE_PROJECT_ID = data[0].project_id"), 'portal must resolve the active project before creator data loads');
assert(migration.includes("RAISE EXCEPTION 'project ownership does not match the parent record'"), 'database must reject cross-project child records');
assert(identityMigration.includes('idx_kocs_creator_id_unique'), 'creators must receive an immutable unique identity');
for (const table of ['submissions', 'point_logs', 'redemption_orders', 'reward_fulfillments', 'redemption_order_edits', 'creator_monthly_tier_scores', 'creator_tier_history']) {
  assert(identityMigration.includes(`ALTER TABLE public.${table} ALTER COLUMN creator_id SET NOT NULL`), `${table}.creator_id must be required after backfill`);
}

const pointTierMigration = fs.readFileSync('supabase/migrations/20261012120000_project_point_tier_rpcs.sql', 'utf8');
const uidIdentityMigration = fs.readFileSync('supabase/migrations/20261012150000_remove_global_uid_identity.sql', 'utf8');
const rewardValidationMigration = fs.readFileSync('supabase/migrations/20261012180000_project_reward_validation.sql', 'utf8');
const projectCloneMigration = fs.readFileSync('supabase/migrations/20261012210000_clone_project_template.sql', 'utf8');
const publicProjectConfigMigration = fs.readFileSync('supabase/migrations/20261012223000_public_project_portal_config.sql', 'utf8');
const projectBrandingMigration = fs.readFileSync('supabase/migrations/20261012233000_project_portal_branding.sql', 'utf8');
const projectLaunchMigration = fs.readFileSync('supabase/migrations/20261013003000_project_launch_wizard.sql', 'utf8');
assert(pointTierMigration.includes('add_project_point_log_once'), 'project-scoped point adjustment RPC is required');
assert(pointTierMigration.includes('logs.project_id = v_project_id AND logs.creator_id = v_creator_id'), 'point balances must be scoped by project and creator identity');
assert(pointTierMigration.includes('preview_project_legacy_tier_upgrades'), 'project-scoped tier preview RPC is required');
assert(pointTierMigration.includes('apply_project_legacy_tier_upgrade_preview'), 'project-scoped tier apply RPC is required');
assert(pointTierMigration.includes('batches.id = p_batch_id AND batches.project_id = v_project_id'), 'tier preview application must validate project ownership');
assert(!fs.readFileSync('admin.html', 'utf8').includes("adminRpc('add_point_log_once'"), 'admin must not call the legacy point RPC');
assert(!fs.readFileSync('supabase/functions/registration-review/index.ts', 'utf8').includes('db.rpc("add_point_log_once"'), 'edge function must not call the legacy point RPC');
assert(portal.includes('ACTIVE_PROJECT_ID'), 'creator portal must resolve project ownership');
const admin = fs.readFileSync('admin.html', 'utf8');
const registrationReview = fs.readFileSync('supabase/functions/registration-review/index.ts', 'utf8');
assert(admin.includes('id="active-project-select"'), 'admin must expose an active business project selector');
assert(admin.includes('getActiveProjectKey()'), 'admin operations must use the active project key');
assert(registrationReview.includes('.eq("project_id", projectId).order("updated_at"'), 'fulfillment listing must be project scoped');
assert(uidIdentityMigration.includes('PRIMARY KEY USING INDEX idx_kocs_creator_id_unique'), 'creator_id must replace UID as the creator primary key');
assert(uidIdentityMigration.includes("attributes.attname = 'uid'"), 'legacy UID foreign keys must be removed dynamically');
assert(uidIdentityMigration.includes('PRIMARY KEY (project_id, creator_id, period)'), 'tier score identity must be project scoped');
assert(uidIdentityMigration.includes('WHERE project_id = v_project_id AND creator_id = v_creator_id'), 'UID changes must propagate by immutable creator identity');
assert(uidIdentityMigration.includes("'mlt-global', p_uid, p_account_id"), 'legacy creator RPCs must be explicit default-project wrappers');
assert(rewardValidationMigration.includes('rewards.project_id = NEW.project_id'), 'reward validation must use the order project configuration');
assert(!rewardValidationMigration.includes("projects.project_key = 'mlt-global'"), 'reward validation must not hardcode the production project');
assert(identityMigration.includes("RAISE EXCEPTION 'creator identity does not match project and UID'"), 'database must reject mismatched creator references');
assert(projectCloneMigration.includes('FUNCTION public.clone_project_template'), 'project templates require a transactional clone RPC');
for (const table of ['project_reward_options', 'campaign_config']) {
  assert(projectCloneMigration.includes(`public.${table}`), `project clone must include ${table}`);
}
for (const table of ['kocs', 'registration_applications', 'submissions', 'point_logs', 'redemption_orders', 'reward_fulfillments']) {
  assert(!projectCloneMigration.includes(`INSERT INTO public.${table}`), `project clone must not copy ${table}`);
}
assert(projectCloneMigration.includes('false, false, is_current_period, NULL, NULL'), 'cloned campaign windows must start closed without copied deadlines');
assert(admin.includes('clonePlatformProject()'), 'admin must expose project template cloning');
assert(registrationReview.includes('clone_platform_project'), 'project clone must cross the authenticated admin boundary');
assert(publicProjectConfigMigration.includes('get_public_project_portal_config'), 'portal routing requires a public project configuration RPC');
assert(!publicProjectConfigMigration.includes("'discord_guild_id'"), 'public project configuration must not expose the Discord guild setting');
assert(portal.includes("new URLSearchParams(window.location.search).get('project')"), 'portal must resolve the project key from the URL');
assert(!portal.includes("p_project_key: 'mlt-global'"), 'portal workflow RPCs must not hardcode the production project');
assert(!portal.includes("project_key: 'mlt-global'"), 'portal Edge Function calls must not hardcode the production project');
for (const field of ['brand_name', 'portal_tagline', 'studio_name', 'support_channel', 'primary_color', 'accent_color', 'background_color']) {
  assert(projectBrandingMigration.includes(`'${field}'`), `public project branding must include ${field}`);
}
assert(admin.includes('id="platform-brand-name"'), 'admin must expose project branding fields');
assert(portal.includes("rootStyle.setProperty('--pink'"), 'portal must apply the project theme');
assert(projectLaunchMigration.includes('get_project_launch_readiness'), 'project launch requires a database readiness check');
assert(projectLaunchMigration.includes('launch_platform_project'), 'project activation requires a guarded database RPC');
assert(projectLaunchMigration.includes("NEW.status := 'paused'"), 'new non-production projects must start paused');
assert(admin.includes('id="project-launch-wizard"'), 'admin must expose the project launch checklist');
for (const rpc of ['submit_project_creator_work', 'submit_project_creator_showcase', 'redeem_project_points', 'edit_project_pending_redemption']) {
  assert(portalRpcMigration.includes(`FUNCTION public.${rpc}`), `${rpc} must be project-aware`);
  assert(portal.includes(`/rpc/${rpc}`) || portal.includes(`'${rpc}'`), `portal must call ${rpc}`);
}
assert(portalRpcMigration.includes('creator_id = v_creator.creator_id'), 'portal RPCs must scope business records by immutable creator identity');
assert(campaignWindowMigration.includes('FUNCTION public.is_project_campaign_window_open'), 'project-aware portal RPCs require a project campaign-window guard');
assert(adminRpcMigration.includes('FUNCTION public.change_project_creator_uid'), 'UID changes must resolve the project creator');
assert(adminRpcMigration.includes('WHERE creator_id = v_creator.creator_id'), 'profile propagation must use immutable creator identity');

console.log('Project isolation checks passed.');

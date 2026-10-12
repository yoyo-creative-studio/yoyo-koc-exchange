import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-cron-secret",
  "Content-Type": "application/json",
};
const guildId = "1458340952358785193";
const discordApi = "https://discord.com/api/v10";
const portalUrl = "https://yoyo-creative-studio.github.io/yoyo-koc-exchange/index.html";

function identityKeys(value: unknown) {
  const raw = String(value || "").normalize("NFKC").trim().toLowerCase();
  if (!raw) return [];
  const values = [raw];
  const hint = raw.match(/\(\s*user\s*:\s*([^\)]+)\)/i);
  if (hint) values.push(hint[1]);
  raw.split("/").forEach((part) => values.push(part));
  return [...new Set(values.map((item) => item.replace(/^@/, "").replace(/\s+/g, " ").trim()).filter(Boolean))];
}

async function discordFetch(path: string, token: string, init: RequestInit = {}) {
  return fetch(discordApi + path, {
    ...init,
    headers: { Authorization: `Bot ${token}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
}

async function listMembers(token: string) {
  const response = await discordFetch(`/guilds/${guildId}/members?limit=1000`, token);
  if (!response.ok) throw new Error(`Discord members ${response.status}: ${await response.text()}`);
  return (await response.json()).filter((member: any) => !member.user?.bot);
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

const welcomeMessage = `🎉 **Welcome to the MLT Creator Program!**

Your **Newcomer Month** is the first full calendar month after your registration is approved. Earn at least **5 base points** during that month to receive **+2 bonus points**. We believe you can do it! ✨

To officially become a Certified Creator, please submit your registration information here:
${portalUrl}

After submitting your application, please wait for administrator approval. MochiBot will notify you once your application has been approved.

🎁 Once approved, you will receive a physical New Creator Welcome Gift.
💡 Visit **💡｜official-inspirations** for monthly content ideas and creator resources.

---
**Official MochiBot notification:** Please do not reply to or report this message as spam. MochiBot only sends system notifications.

If you need help, please post in **#town-service-station** and contact **YoYo assistant Mochi — look for the red butterfly profile picture.**`;

serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const body = await request.json();
    const action = String(body.action || "status");
    const { data: state, error: stateError } = await supabase.from("mochi_auto_welcome_state").select("*").eq("id", 1).single();
    if (stateError) throw stateError;

    async function requireAdmin(minimumRole: "operator" | "project_owner") {
      const ranks = { viewer: 10, operator: 20, admin: 30, project_owner: 40, platform_owner: 50 } as Record<string, number>;
      const sessionHash = await sha256(String(body.admin_session || ""));
      const { data: session } = await supabase.from("platform_admin_sessions").select("admin_id").eq("token_hash", sessionHash).gt("expires_at", new Date().toISOString()).maybeSingle();
      if (!session) throw new Error("Administrator session expired");
      const { data: admin } = await supabase.from("platform_admins").select("id,role,status").eq("id", session.admin_id).eq("status", "active").maybeSingle();
      if (!admin || (ranks[admin.role] || 0) < ranks[minimumRole]) throw new Error("Insufficient permission");
      return admin;
    }

    const { data: project, error: projectError } = await supabase.from("platform_projects")
      .select("id").eq("project_key", String(body.project_key || "mlt-global")).eq("status", "active").maybeSingle();
    if (projectError || !project) throw projectError || new Error("Project not found");
    const { data: secret } = await supabase.from("platform_project_secrets").select("discord_bot_token").eq("project_id", project.id).maybeSingle();
    const botToken = String(secret?.discord_bot_token || "").trim();

    if (action === "configure") {
      const admin = await requireAdmin("project_owner");
      if (admin.role !== "platform_owner") {
        const { data: access } = await supabase.from("platform_admin_project_access").select("project_id").eq("admin_id", admin.id).eq("project_id", project.id).maybeSingle();
        if (!access) throw new Error("No access to this project");
      }
      if (!body.enabled) {
        await supabase.from("mochi_auto_welcome_state").update({ enabled: false, updated_at: new Date().toISOString() }).eq("id", 1);
        return new Response(JSON.stringify({ ok: true, enabled: false }), { headers });
      }
      if (!botToken) throw new Error("Missing server-side Discord Bot Token");
      const members = await listMembers(botToken);
      await supabase.from("mochi_auto_welcome_state").update({
        enabled: true,
        known_member_ids: members.map((member: any) => String(member.user.id)),
        last_checked_at: new Date().toISOString(),
        last_result: { baseline: members.length, sent: 0, failed: 0 },
        updated_at: new Date().toISOString(),
      }).eq("id", 1);
      return new Response(JSON.stringify({ ok: true, enabled: true, baseline: members.length }), { headers });
    }

    if (action === "status") {
      return new Response(JSON.stringify({ ok: true, enabled: state.enabled, last_checked_at: state.last_checked_at, last_result: state.last_result }), { headers });
    }

    let adminScan = false;
    if (action === "scan_now") {
      const admin = await requireAdmin("operator");
      if (admin.role !== "platform_owner") {
        const { data: access } = await supabase.from("platform_admin_project_access").select("project_id").eq("admin_id", admin.id).eq("project_id", project.id).maybeSingle();
        if (!access) throw new Error("No access to this project");
      }
      adminScan = true;
    }
    const cronScan = action === "scan" && request.headers.get("x-cron-secret") === state.cron_secret;
    if (!adminScan && !cronScan) return new Response(JSON.stringify({ ok: false, error: "Unauthorized" }), { status: 401, headers });
    if (!state.enabled || !botToken) return new Response(JSON.stringify({ ok: true, skipped: "disabled" }), { headers });

    const members = await listMembers(botToken);
    const known = new Set((state.known_member_ids || []).map(String));
    const newMembers = members.filter((member: any) => !known.has(String(member.user.id)));
    const { data: kocs, error: kocError } = await supabase.from("kocs")
      .select("discord_name,discord_user_id,discord_username,discord_display_name,discord_aliases")
      .eq("project_id", project.id).eq("status", "active");
    if (kocError) throw kocError;
    const registered = new Set<string>();
    (kocs || []).forEach((koc: any) => {
      if (koc.discord_user_id) registered.add(`id:${koc.discord_user_id}`);
      [koc.discord_name, koc.discord_username, koc.discord_display_name]
        .concat(Array.isArray(koc.discord_aliases) ? koc.discord_aliases : [])
        .flatMap(identityKeys).forEach((key: string) => registered.add(key));
    });

    let sent = 0;
    const failures: string[] = [];
    const skippedRegistered: string[] = [];
    for (const member of newMembers) {
      const keys = [member.user?.username, member.user?.global_name, member.nick].flatMap(identityKeys);
      if (registered.has(`id:${member.user?.id}`) || keys.some((key) => registered.has(key))) {
        skippedRegistered.push(member.user?.username || member.user?.id);
        continue;
      }
      const dmResponse = await discordFetch("/users/@me/channels", botToken, { method: "POST", body: JSON.stringify({ recipient_id: member.user.id }) });
      if (!dmResponse.ok) { failures.push(`${member.user?.username}: DM ${dmResponse.status}`); continue; }
      const dm = await dmResponse.json();
      const sendResponse = await discordFetch(`/channels/${dm.id}/messages`, botToken, { method: "POST", body: JSON.stringify({ content: welcomeMessage }) });
      if (sendResponse.ok) sent++; else failures.push(`${member.user?.username}: send ${sendResponse.status}`);
      await new Promise((resolve) => setTimeout(resolve, 1200));
    }
    const result = { found: newMembers.length, sent, failed: failures.length, failures, skipped_registered: skippedRegistered };
    await supabase.from("mochi_auto_welcome_state").update({
      known_member_ids: members.map((member: any) => String(member.user.id)),
      last_checked_at: new Date().toISOString(), last_result: result, updated_at: new Date().toISOString(),
    }).eq("id", 1);
    return new Response(JSON.stringify({ ok: true, ...result }), { headers });
  } catch (error) {
    return new Response(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) }), { status: 500, headers });
  }
});

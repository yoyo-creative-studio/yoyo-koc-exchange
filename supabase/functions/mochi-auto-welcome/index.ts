import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, x-admin-password, x-cron-secret",
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

    if (action === "configure") {
      if (request.headers.get("x-admin-password") !== Deno.env.get("REGISTRATION_ADMIN_PASSWORD")) {
        return new Response(JSON.stringify({ ok: false, error: "Unauthorized" }), { status: 401, headers });
      }
      if (!body.enabled) {
        await supabase.from("mochi_auto_welcome_state").update({ enabled: false, updated_at: new Date().toISOString() }).eq("id", 1);
        return new Response(JSON.stringify({ ok: true, enabled: false }), { headers });
      }
      const token = String(body.token || state.bot_token || "").trim();
      if (!token) throw new Error("Missing Discord Bot Token");
      const members = await listMembers(token);
      await supabase.from("mochi_auto_welcome_state").update({
        enabled: true,
        bot_token: token,
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

    const adminScan = action === "scan_now" && request.headers.get("x-admin-password") === Deno.env.get("REGISTRATION_ADMIN_PASSWORD");
    const cronScan = action === "scan" && request.headers.get("x-cron-secret") === state.cron_secret;
    if (!adminScan && !cronScan) return new Response(JSON.stringify({ ok: false, error: "Unauthorized" }), { status: 401, headers });
    if (!state.enabled || !state.bot_token) return new Response(JSON.stringify({ ok: true, skipped: "disabled" }), { headers });

    const members = await listMembers(state.bot_token);
    const known = new Set((state.known_member_ids || []).map(String));
    const newMembers = members.filter((member: any) => !known.has(String(member.user.id)));
    const { data: kocs, error: kocError } = await supabase.from("kocs").select("discord_name").eq("status", "active");
    if (kocError) throw kocError;
    const registered = new Set<string>();
    (kocs || []).forEach((koc: any) => identityKeys(koc.discord_name).forEach((key) => registered.add(key)));

    let sent = 0;
    const failures: string[] = [];
    const skippedRegistered: string[] = [];
    for (const member of newMembers) {
      const keys = [member.user?.username, member.user?.global_name, member.nick].flatMap(identityKeys);
      if (keys.some((key) => registered.has(key))) {
        skippedRegistered.push(member.user?.username || member.user?.id);
        continue;
      }
      const dmResponse = await discordFetch("/users/@me/channels", state.bot_token, { method: "POST", body: JSON.stringify({ recipient_id: member.user.id }) });
      if (!dmResponse.ok) { failures.push(`${member.user?.username}: DM ${dmResponse.status}`); continue; }
      const dm = await dmResponse.json();
      const sendResponse = await discordFetch(`/channels/${dm.id}/messages`, state.bot_token, { method: "POST", body: JSON.stringify({ content: welcomeMessage }) });
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

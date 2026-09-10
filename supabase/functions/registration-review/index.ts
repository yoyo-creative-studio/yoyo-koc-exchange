import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getBusinessPeriod(date: Date) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "2-digit",
  }).formatToParts(date);
  const year = parts.find((part) => part.type === "year")?.value || "";
  const month = parts.find((part) => part.type === "month")?.value || "";
  return `${year}-${month}`;
}

function getNextPeriod(period: string) {
  const [yearText, monthText] = period.split("-");
  let year = Number(yearText);
  let month = Number(monthText) + 1;
  if (month > 12) {
    year += 1;
    month = 1;
  }
  return `${year}-${String(month).padStart(2, "0")}`;
}

function buildApprovedNotes(rawNotes: string, approvedAt: string, newbieMonth: string) {
  let notes: Record<string, unknown> = {};
  try {
    const parsed = JSON.parse(rawNotes || "{}");
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) notes = parsed;
  } catch {
    if (rawNotes.trim()) notes.legacy_notes = rawNotes.trim();
  }
  notes.registered_at = approvedAt;
  notes.approved_at = approvedAt;
  notes.newbie_month = newbieMonth;
  return JSON.stringify(notes);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const adminPassword = Deno.env.get("REGISTRATION_ADMIN_PASSWORD") || "";
    if (!supabaseUrl || !serviceRoleKey) return json({ ok: false, error: "Server configuration missing" }, 500);

    const db = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
    const { action, data = {}, admin_password = "" } = await req.json();

    if (action === "creator_reward_status") {
      const uid = String(data.uid || "").trim();
      const accountId = String(data.account_id || "").trim();
      if (!uid || !/^6\d{18}$/.test(accountId)) return json({ ok: false, error: "Valid creator credentials are required" }, 400);
      const { data: creator } = await db.from("kocs").select("uid").eq("uid", uid).eq("account_id", accountId).eq("status", "active").maybeSingle();
      if (!creator) return json({ ok: false, error: "Creator credentials do not match" }, 403);
      const { data: fulfillments, error } = await db.from("reward_fulfillments")
        .select("order_id,period,reward_type,fulfillment_status,gift_codes,carrier,tracking_number,reward_note,published_at")
        .eq("uid", uid).eq("is_published", true).order("published_at", { ascending: false });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, fulfillments: fulfillments || [] });
    }

    if (action === "creator_tier_progress") {
      const uid = String(data.uid || "").trim();
      const accountId = String(data.account_id || "").trim();
      const requestedPeriod = String(data.period || getBusinessPeriod(new Date())).trim();
      if (!uid || !/^6\d{18}$/.test(accountId) || !/^\d{4}-\d{2}$/.test(requestedPeriod)) {
        return json({ ok: false, error: "Valid creator credentials and period are required" }, 400);
      }
      const { data: creator } = await db.from("kocs").select("uid,tier").eq("uid", uid).eq("account_id", accountId).eq("status", "active").maybeSingle();
      if (!creator) return json({ ok: false, error: "Creator credentials do not match" }, 403);
      const { data: scores, error } = await db.from("creator_monthly_tier_scores")
        .select("period,historical_final_score,content_raw_points,content_capped_points")
        .eq("uid", uid).order("period", { ascending: true });
      if (error) return json({ ok: false, error: error.message }, 400);
      const isLegacy = requestedPeriod < "2026-09";
      const ruleVersion = isLegacy ? "legacy-through-2026-08" : "content-from-2026-09";
      const nextTier = creator.tier === "platinum" ? null : (creator.tier === "gold" ? "platinum" : "gold");
      const requiredMonths = nextTier === "platinum" ? 3 : 2;
      const threshold = nextTier === "platinum" ? (isLegacy ? 5 : 40) : (isLegacy ? 5 : 20);
      const inclusive = !isLegacy;
      const scoreField = isLegacy ? "historical_final_score" : "content_capped_points";
      const byPeriod = new Map((scores || []).map((row) => [String(row.period), row]));
      let cursor = requestedPeriod;
      let consecutiveMonths = 0;
      while (!isLegacy || cursor >= "2026-09") {
        const value = Number((byPeriod.get(cursor) as Record<string, unknown> | undefined)?.[scoreField]);
        if (!Number.isFinite(value) || (inclusive ? value < threshold : value <= threshold)) break;
        consecutiveMonths += 1;
        const [yearText, monthText] = cursor.split("-");
        let year = Number(yearText), month = Number(monthText) - 1;
        if (month < 1) { year -= 1; month = 12; }
        cursor = `${year}-${String(month).padStart(2, "0")}`;
      }
      const currentScore = byPeriod.get(requestedPeriod);
      return json({ ok: true, progress: {
        current_tier: creator.tier || "certified",
        next_tier: nextTier,
        rule_version: ruleVersion,
        period: requestedPeriod,
        consecutive_months: Math.min(consecutiveMonths, requiredMonths),
        required_months: requiredMonths,
        threshold,
        inclusive,
        current_content_capped_points: Number(currentScore?.content_capped_points || 0),
        months_remaining: nextTier ? Math.max(0, requiredMonths - consecutiveMonths) : 0,
        excluded_rewards: ["New Creator Bonus", "Showcase Bonus", "MochiBones", "Referral Reward", "Carry-over Balance", "Redemption refunds", "Manual balance adjustments", "Continuous Creation rewards"],
      }});
    }

    if (action === "submit") {
      const application = {
        discord_name: String(data.discord_name || "").trim(),
        account_id: String(data.account_id || "").trim(),
        uid: String(data.uid || "").trim(),
        name: String(data.name || "").trim(),
        server: String(data.server || "").trim(),
        address: String(data.address || "").trim(),
        city: String(data.city || "").trim(),
        state: String(data.state || "").trim(),
        postal_code: String(data.postal_code || "").trim(),
        country: String(data.country || "").trim(),
        phone: String(data.phone || "").trim(),
        notes: String(data.notes || ""),
      };
      if (!application.discord_name || !application.uid || !/^6\d{18}$/.test(application.account_id) || !application.name || !application.server) {
        return json({ ok: false, error: "Required registration information is incomplete" }, 400);
      }

      const { data: existingKoc } = await db.from("kocs").select("uid").or(`uid.eq.${application.uid},account_id.eq.${application.account_id}`).limit(1);
      if (existingKoc?.length) return json({ ok: false, error: "This creator is already registered. Please use Creator Login." }, 409);

      const { data: existingApplication } = await db.from("registration_applications")
        .select("id,status,review_notes")
        .or(`uid.eq.${application.uid},account_id.eq.${application.account_id}`)
        .in("status", ["pending", "approved"])
        .order("created_at", { ascending: false })
        .limit(1);
      if (existingApplication?.length) {
        return json({ ok: true, duplicate: true, application: existingApplication[0] });
      }

      const { data: inserted, error } = await db.from("registration_applications")
        .insert({ ...application, status: "pending" })
        .select("id,status,created_at")
        .single();
      if (error?.code === "23505") {
        const { data: concurrentApplication } = await db.from("registration_applications")
          .select("id,status,review_notes")
          .or(`uid.eq.${application.uid},account_id.eq.${application.account_id}`)
          .in("status", ["pending", "approved"])
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();
        if (concurrentApplication) return json({ ok: true, duplicate: true, application: concurrentApplication });
      }
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, application: inserted });
    }

    if (!adminPassword || admin_password !== adminPassword) return json({ ok: false, error: "Admin verification failed" }, 403);

    if (action === "admin_rpc") {
      const rpcName = String(data.rpc || "");
      const allowedRpcNames = new Set([
        "publish_campaign_period",
        "add_point_log_once",
        "ship_redemption_order",
        "queue_redemption_order",
        "preview_legacy_tier_upgrades",
        "apply_legacy_tier_upgrade_preview",
      ]);
      if (!allowedRpcNames.has(rpcName)) return json({ ok: false, error: "Admin operation is not allowed" }, 400);
      const { data: rpcResult, error: rpcError } = await db.rpc(rpcName, data.params || {});
      if (rpcError) return json({ ok: false, error: rpcError.message }, 400);
      return json({ ok: true, result: rpcResult });
    }

    if (action === "list_reward_fulfillments") {
      const period = String(data.period || "").trim();
      let query = db.from("reward_fulfillments").select("*").order("updated_at", { ascending: false });
      if (period) query = query.eq("period", period);
      const { data: rows, error } = await query;
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, fulfillments: rows || [] });
    }

    if (action === "delete_reward_fulfillments") {
      const ids = (Array.isArray(data.ids) ? data.ids : []).map(Number).filter(Boolean);
      if (!ids.length) return json({ ok: false, error: "No fulfillment records selected" }, 400);
      const { data: rows, error: loadError } = await db.from("reward_fulfillments")
        .select("id,is_published").in("id", ids);
      if (loadError) return json({ ok: false, error: loadError.message }, 400);
      if ((rows || []).length !== ids.length) return json({ ok: false, error: "Some fulfillment records were not found" }, 404);
      if ((rows || []).some((row) => row.is_published)) {
        return json({ ok: false, error: "Published fulfillment records cannot be deleted" }, 409);
      }
      const { error } = await db.from("reward_fulfillments").delete().in("id", ids).eq("is_published", false);
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, deleted: ids.length });
    }

    if (action === "delete_reward_orders") {
      const ids = (Array.isArray(data.ids) ? data.ids : []).map(Number).filter(Boolean);
      if (!ids.length) return json({ ok: false, error: "No reward orders selected" }, 400);
      const { data: orders, error: loadError } = await db.from("redemption_orders")
        .select("id,points_spent,status").in("id", ids);
      if (loadError) return json({ ok: false, error: loadError.message }, 400);
      if ((orders || []).length !== ids.length) return json({ ok: false, error: "Some reward orders were not found" }, 404);
      if ((orders || []).some((order) => Number(order.points_spent) !== 0 || order.status !== "shipped")) {
        return json({ ok: false, error: "Only zero-point administrator rewards can be deleted" }, 409);
      }
      const { data: fulfillmentRows, error: fulfillmentError } = await db.from("reward_fulfillments")
        .select("order_id,is_published").in("order_id", ids);
      if (fulfillmentError) return json({ ok: false, error: fulfillmentError.message }, 400);
      if ((fulfillmentRows || []).some((row) => row.is_published)) {
        return json({ ok: false, error: "Published rewards cannot be deleted" }, 409);
      }
      if ((fulfillmentRows || []).length) {
        const { error: deleteFulfillmentError } = await db.from("reward_fulfillments").delete().in("order_id", ids).eq("is_published", false);
        if (deleteFulfillmentError) return json({ ok: false, error: deleteFulfillmentError.message }, 400);
      }
      const { error } = await db.from("redemption_orders").delete().in("id", ids).eq("points_spent", 0).eq("status", "shipped");
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, deleted: ids.length });
    }

    if (action === "create_manual_reward_order") {
      const type = String(data.type || "").trim();
      const period = String(data.period || "").trim();
      const uid = String(data.uid || "").trim();
      const discordName = String(data.discord_name || "").trim();
      const rewardContent = String(data.reward_content || "").trim();
      if (!["diamonds", "gplay", "merch"].includes(type)) return json({ ok: false, error: "Unsupported reward type" }, 400);
      if (!/^\d{4}-\d{2}$/.test(period) || !uid || !discordName || !rewardContent) return json({ ok: false, error: "Required reward information is incomplete" }, 400);
      const { data: creator, error: creatorError } = await db.from("kocs").select("uid,status").eq("uid", uid).maybeSingle();
      if (creatorError) return json({ ok: false, error: creatorError.message }, 400);
      if (!creator || creator.status !== "active") return json({ ok: false, error: "Active creator not found" }, 404);
      const accountId = String(data.account_id || "").trim();
      const server = String(data.server || "").trim();
      const country = String(data.country || "").trim();
      const phone = String(data.phone || "").trim();
      const address = String(data.address || "").trim();
      if (accountId && !/^6\d{18}$/.test(accountId)) return json({ ok: false, error: "Account ID must start with 6 and contain exactly 19 digits" }, 400);
      if (type === "diamonds" && (!accountId || !server)) return json({ ok: false, error: "In-game rewards require Account ID and server" }, 400);
      if (type === "gplay" && !country) return json({ ok: false, error: "Google Play records require country" }, 400);
      if (type === "merch" && (!address || !phone)) return json({ ok: false, error: "Merchandise records require address and phone" }, 400);
      const kocUpdate: Record<string, string> = { discord_name: discordName };
      if (accountId) kocUpdate.account_id = accountId;
      if (server) kocUpdate.server = server;
      if (country) kocUpdate.country = country;
      if (phone) kocUpdate.phone = phone;
      if (address) kocUpdate.address = address;
      const { error: updateError } = await db.from("kocs").update(kocUpdate).eq("uid", uid);
      if (updateError) return json({ ok: false, error: updateError.message }, 400);
      const optionName = type === "diamonds" ? "💎 手动端内奖励" : type === "gplay" ? rewardContent : "📦 " + rewardContent;
      const { data: order, error } = await db.from("redemption_orders").insert({
        uid,
        discord_name: discordName,
        koc_name: discordName,
        option_type: type,
        option_name: optionName,
        points_spent: 0,
        reward_amount: rewardContent,
        contact_info: type === "merch" ? address : "",
        status: "shipped",
        admin_notes: String(data.notes || "").trim() || "Manual reward entry by admin",
        period,
        processed_at: new Date().toISOString(),
        processed_by: "admin",
      }).select("*").single();
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, order });
    }

    if (action === "create_manual_koc") {
      const uid = String(data.uid || "").trim();
      const discordName = String(data.discord || "").trim();
      const accountId = String(data.account || "").trim();
      const name = String(data.name || "").trim();
      const server = String(data.server || "").trim();
      if (!uid || !discordName || !/^6\d{18}$/.test(accountId) || !name || !server) return json({ ok: false, error: "Required creator information is incomplete" }, 400);
      const { data: duplicates, error: duplicateError } = await db.from("kocs").select("uid,account_id").or(`uid.eq.${uid},account_id.eq.${accountId}`).limit(1);
      if (duplicateError) return json({ ok: false, error: duplicateError.message }, 400);
      if (duplicates?.length) return json({ ok: false, error: "Game UID or Account ID already exists" }, 409);
      const tier = ["certified", "gold", "platinum"].includes(String(data.tier || "")) ? String(data.tier) : "certified";
      const { data: creator, error } = await db.from("kocs").insert({
        uid,
        discord_name: discordName,
        account_id: accountId,
        name,
        region: String(data.region || "").trim(),
        server,
        address: String(data.address || "").trim(),
        city: String(data.city || "").trim(),
        state: String(data.state || "").trim(),
        postal_code: String(data.postal || "").trim(),
        country: String(data.country || "").trim(),
        phone: String(data.phone || "").trim(),
        notes: String(data.notes || "").trim(),
        tier,
        status: "active",
        created_at: new Date().toISOString(),
      }).select("*").single();
      if (error) return json({ ok: false, error: error.message }, 400);
      let welcomeGift = null;
      if (data.welcome_gift !== false) {
        const { data: gift, error: giftError } = await db.from("redemption_orders").insert({
          uid,
          discord_name: discordName,
          koc_name: discordName,
          option_type: "merch",
          option_name: "🎁 新人入职周边",
          points_spent: 0,
          reward_amount: "随机周边 × 1",
          contact_info: String(data.address || "").trim(),
          status: "pending",
          admin_notes: "Welcome gift - manual creator entry",
          period: String(data.period || "").trim() || null,
        }).select("*").single();
        if (giftError) {
          await db.from("kocs").delete().eq("uid", uid);
          return json({ ok: false, error: `Welcome gift creation failed: ${giftError.message}` }, 400);
        }
        welcomeGift = gift;
      }
      return json({ ok: true, creator, welcome_gift: welcomeGift });
    }

    if (action === "save_reward_fulfillments") {
      const rows = Array.isArray(data.rows) ? data.rows : [];
      if (!rows.length) return json({ ok: false, error: "No fulfillment rows supplied" }, 400);
      const orderIds = rows.map((row: Record<string, unknown>) => Number(row.order_id)).filter(Boolean);
      const { data: orders, error: orderError } = await db.from("redemption_orders")
        .select("id,uid,period,option_type,option_name,reward_amount,points_spent").in("id", orderIds);
      if (orderError) return json({ ok: false, error: orderError.message }, 400);
      const orderMap = new Map((orders || []).map((order) => [Number(order.id), order]));
      const { data: publishedRows, error: publishedError } = await db.from("reward_fulfillments")
        .select("order_id").in("order_id", orderIds).eq("is_published", true);
      if (publishedError) return json({ ok: false, error: publishedError.message }, 400);
      if (publishedRows?.length) return json({ ok: false, error: "Published fulfillment records cannot be overwritten" }, 409);
      const incomingCodeOwners = new Map<string, number>();
      const incomingCodes = new Set<string>();
      for (const row of rows) {
        const orderId = Number(row.order_id);
        const codes = Array.isArray(row.gift_codes) ? row.gift_codes.map((code: unknown) => String(code || "").trim()).filter(Boolean) : [];
        for (const code of codes) {
          const normalized = code.toUpperCase();
          if (incomingCodeOwners.has(normalized)) return json({ ok: false, error: `Duplicate gift code detected: ${code}` }, 409);
          incomingCodeOwners.set(normalized, orderId);
          incomingCodes.add(normalized);
        }
      }
      if (incomingCodes.size) {
        const { data: existingCodeRows, error: existingCodeError } = await db.from("reward_fulfillments")
          .select("order_id,gift_codes").not("order_id", "in", `(${orderIds.join(",")})`);
        if (existingCodeError) return json({ ok: false, error: existingCodeError.message }, 400);
        for (const existingRow of existingCodeRows || []) {
          for (const existingCode of Array.isArray(existingRow.gift_codes) ? existingRow.gift_codes : []) {
            if (incomingCodes.has(String(existingCode || "").trim().toUpperCase())) {
              return json({ ok: false, error: `Gift code already belongs to order #${existingRow.order_id}` }, 409);
            }
          }
        }
      }
      const payload = [];
      for (const row of rows) {
        const order = orderMap.get(Number(row.order_id));
        if (!order) return json({ ok: false, error: `Order #${row.order_id} not found` }, 404);
        const codes = Array.isArray(row.gift_codes) ? row.gift_codes.map((code: unknown) => String(code || "").trim()).filter(Boolean) : [];
        if (order.option_type === "gplay") {
          const quantityText = `${order.option_name || ""} ${order.reward_amount || ""}`;
          const quantityMatch = quantityText.match(/[×xX]\s*(\d+)/);
          const expectedCodes = quantityMatch ? Number(quantityMatch[1]) : Math.max(1, Math.round((Number(order.points_spent) || 0) / 2));
          if (codes.length !== expectedCodes) return json({ ok: false, error: `Order #${order.id} requires ${expectedCodes} gift codes` }, 400);
        } else if (codes.length) {
          return json({ ok: false, error: `Order #${order.id} does not accept gift codes` }, 400);
        }
        if (order.option_type === "merch" && !String(row.tracking_number || "").trim()) {
          return json({ ok: false, error: `Order #${order.id} requires a tracking number` }, 400);
        }
        payload.push({
          order_id: order.id,
          uid: order.uid,
          period: String(order.period || row.period || ""),
          reward_type: order.option_type,
          fulfillment_status: String(row.fulfillment_status || "preparing"),
          gift_codes: codes,
          carrier: String(row.carrier || "").trim(),
          tracking_number: String(row.tracking_number || "").trim(),
          reward_note: String(row.reward_note || "").trim(),
          is_published: false,
          published_at: null,
          updated_at: new Date().toISOString(),
          updated_by: "admin",
        });
      }
      const { data: saved, error } = await db.from("reward_fulfillments").upsert(payload, { onConflict: "order_id" }).select("*");
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, fulfillments: saved || [] });
    }

    if (action === "publish_reward_fulfillments") {
      const ids = (Array.isArray(data.ids) ? data.ids : []).map(Number).filter(Boolean);
      if (!ids.length) return json({ ok: false, error: "No fulfillment records selected" }, 400);
      const { data: result, error } = await db.rpc("publish_reward_fulfillments", { p_ids: ids });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, result });
    }

    if (action === "list") {
      const { data: applications, error } = await db.from("registration_applications")
        .select("*")
        .order("created_at", { ascending: false });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, applications: applications || [] });
    }

    if (action === "approve") {
      const applicationId = Number(data.id);
      const { data: application, error: loadError } = await db.from("registration_applications")
        .select("*").eq("id", applicationId).single();
      if (loadError || !application) return json({ ok: false, error: "Application not found" }, 404);
      if (application.status !== "pending") return json({ ok: false, error: "Application has already been reviewed" }, 409);

      const approvedAt = new Date();
      const approvedAtIso = approvedAt.toISOString();
      const approvalPeriod = getBusinessPeriod(approvedAt);
      const newbieMonth = getNextPeriod(approvalPeriod);
      const approvedNotes = buildApprovedNotes(String(application.notes || ""), approvedAtIso, newbieMonth);
      const { data: currentCampaign } = await db.from("campaign_config")
        .select("period")
        .eq("is_current_period", true)
        .order("period", { ascending: false })
        .limit(1)
        .maybeSingle();
      const orderPeriod = currentCampaign?.period || approvalPeriod;

      const { error: insertError } = await db.from("kocs").insert({
        uid: application.uid,
        discord_name: application.discord_name,
        name: application.name,
        account_id: application.account_id,
        server: application.server,
        address: application.address,
        city: application.city,
        state: application.state,
        postal_code: application.postal_code,
        country: application.country,
        phone: application.phone,
        notes: approvedNotes,
        status: "active",
        created_at: approvedAtIso,
      });
      if (insertError) return json({ ok: false, error: `Unable to create creator account: ${insertError.message}` }, 400);

      const { data: giftOrder, error: giftError } = await db.from("redemption_orders").insert({
        uid: application.uid,
        discord_name: application.discord_name,
        koc_name: application.name,
        option_type: "merch",
        option_name: "🎁 New Creator Welcome Gift",
        points_spent: 0,
        reward_amount: "Random Merchandise × 1",
        contact_info: "",
        status: "pending",
        admin_notes: "Welcome gift - created automatically on registration approval",
        period: orderPeriod,
        created_at: approvedAtIso,
      }).select("id").single();
      if (giftError) {
        await db.from("kocs").delete().eq("uid", application.uid);
        return json({ ok: false, error: `Unable to create mandatory welcome gift: ${giftError.message}` }, 400);
      }

      const { error: updateError } = await db.from("registration_applications").update({
        status: "approved",
        reviewed_at: approvedAtIso,
        reviewed_by: "admin",
        review_notes: String(data.review_notes || ""),
      }).eq("id", applicationId);
      if (updateError) {
        if (giftOrder?.id) await db.from("redemption_orders").delete().eq("id", giftOrder.id);
        await db.from("kocs").delete().eq("uid", application.uid);
        return json({ ok: false, error: updateError.message }, 400);
      }
      return json({ ok: true });
    }

    if (action === "reject") {
      const applicationId = Number(data.id);
      const { error } = await db.from("registration_applications").update({
        status: "rejected",
        reviewed_at: new Date().toISOString(),
        reviewed_by: "admin",
        review_notes: String(data.review_notes || "Not approved"),
      }).eq("id", applicationId).eq("status", "pending");
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ ok: false, error: "Unknown action" }, 400);
  } catch (error) {
    return json({ ok: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});

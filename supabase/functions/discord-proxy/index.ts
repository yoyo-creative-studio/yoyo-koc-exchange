// Supabase Edge Function: Discord API 代理
// 解决浏览器端 CORS 拦截问题
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const DISCORD_API = "https://discord.com/api/v10";

serve(async (req) => {
  // CORS 头（允许浏览器访问）
  const headers = new Headers({
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
  });

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }

  try {
    const { action, data, token } = await req.json();
    if (!token) {
      return new Response(JSON.stringify({ ok: false, error: "缺少 Bot Token" }), {
        status: 400, headers,
      });
    }

    const authHeaders = {
      "Authorization": `Bot ${token}`,
      "Content-Type": "application/json",
    };

    let result;

    switch (action) {
      // 获取 Bot 实际加入的服务器
      case "list_guilds": {
        const res = await fetch(`${DISCORD_API}/users/@me/guilds`, { headers: authHeaders });
        const body = await res.text();
        if (!res.ok) {
          return new Response(JSON.stringify({ ok: false, error: `获取 Bot 服务器列表失败: ${res.status} ${body}` }), {
            status: res.status, headers,
          });
        }
        result = JSON.parse(body).map((guild: any) => ({ id: guild.id, name: guild.name }));
        break;
      }

      // 从 Bot 实际可访问的所有服务器拉取成员，避免前端写死错误 Guild ID
      case "list_all_members": {
        const guildRes = await fetch(`${DISCORD_API}/users/@me/guilds`, { headers: authHeaders });
        const guildBody = await guildRes.text();
        if (!guildRes.ok) {
          return new Response(JSON.stringify({ ok: false, error: `获取 Bot 服务器列表失败: ${guildRes.status} ${guildBody}` }), {
            status: guildRes.status, headers,
          });
        }
        const guilds = JSON.parse(guildBody);
        const memberMap = new Map<string, any>();
        const failures: string[] = [];
        for (const guild of guilds) {
          const memberRes = await fetch(`${DISCORD_API}/guilds/${guild.id}/members?limit=1000`, { headers: authHeaders });
          const memberBody = await memberRes.text();
          if (!memberRes.ok) {
            failures.push(`${guild.name} (${guild.id}): ${memberRes.status}`);
            continue;
          }
          for (const member of JSON.parse(memberBody)) {
            memberMap.set(member.user.id, {
              id: member.user.id,
              username: member.user.username,
              global_name: member.user.global_name || "",
              nick: member.nick || "",
              avatar: member.user.avatar,
              guild_id: guild.id,
              guild_name: guild.name,
            });
          }
        }
        if (memberMap.size === 0) {
          return new Response(JSON.stringify({
            ok: false,
            error: guilds.length === 0
              ? "MochiBot 尚未加入任何 Discord 服务器"
              : `MochiBot 无法读取服务器成员。请在 Discord Developer Portal 开启 Server Members Intent，并确认 Bot 仍在服务器中。${failures.length ? ` 失败: ${failures.join(", ")}` : ""}`,
          }), { status: 403, headers });
        }
        result = { members: Array.from(memberMap.values()), guilds: guilds.map((guild: any) => ({ id: guild.id, name: guild.name })), failures };
        break;
      }

      // 获取服务器所有成员
      case "list_members": {
        const { guild_id } = data;
        const res = await fetch(`${DISCORD_API}/guilds/${guild_id}/members?limit=1000`, {
          headers: authHeaders,
        });
        const body = await res.text();
        if (!res.ok) {
          return new Response(JSON.stringify({ ok: false, error: `获取成员失败: ${res.status} ${body}` }), {
            status: res.status, headers,
          });
        }
        const members = JSON.parse(body);
        result = members.map((m: any) => ({
          id: m.user.id,
          username: m.user.username,
          global_name: m.user.global_name || "",
          nick: m.nick || "",
          avatar: m.user.avatar,
          bot: Boolean(m.user.bot),
        }));
        break;
      }

      // 获取指定频道的最近消息（用于新人入群自动欢迎）
      case "list_channel_messages": {
        const { channel_id, limit = 10 } = data;
        const safeLimit = Math.min(Math.max(Number(limit) || 10, 1), 100);
        const res = await fetch(`${DISCORD_API}/channels/${channel_id}/messages?limit=${safeLimit}`, {
          headers: authHeaders,
        });
        const body = await res.text();
        if (!res.ok) {
          return new Response(JSON.stringify({ ok: false, error: `获取频道消息失败: ${res.status} ${body}` }), {
            status: res.status, headers,
          });
        }
        result = JSON.parse(body);
        break;
      }

      // 发送私信给用户
      case "check_member": {
        const { guild_id, user_id } = data;
        if (!guild_id || !user_id || !/^\d{17,20}$/.test(String(user_id))) {
          return new Response(JSON.stringify({ ok: false, error: "服务器 ID 或 Discord 用户 ID 无效" }), { status: 400, headers });
        }
        const memberRes = await fetch(`${DISCORD_API}/guilds/${guild_id}/members/${user_id}`, { headers: authHeaders });
        const memberBody = await memberRes.text();
        if (!memberRes.ok) {
          return new Response(JSON.stringify({ ok: false, member: false, error: `目标用户不在该服务器或 Bot 无权读取成员: ${memberRes.status} ${memberBody}` }), {
            status: memberRes.status, headers,
          });
        }
        const member = JSON.parse(memberBody);
        result = { ok: true, member: { id: member.user?.id || user_id, username: member.user?.username || "", nick: member.nick || "" } };
        break;
      }

      // 发送私信给用户
      case "send_dm": {
        const { user_id, message, guild_id } = data;
        if (!user_id || !/^\d{17,20}$/.test(String(user_id))) {
          return new Response(JSON.stringify({ ok: false, error: "Discord 用户 ID 无效" }), {
            status: 400, headers,
          });
        }
        if (!message || !String(message).trim()) {
          return new Response(JSON.stringify({ ok: false, error: "私信内容不能为空" }), {
            status: 400, headers,
          });
        }
        if (guild_id) {
          const memberRes = await fetch(`${DISCORD_API}/guilds/${guild_id}/members/${user_id}`, { headers: authHeaders });
          if (!memberRes.ok) {
            const memberBody = await memberRes.text();
            return new Response(JSON.stringify({ ok: false, error: `目标用户不在目标服务器，已阻止发送: ${memberRes.status} ${memberBody}` }), {
              status: memberRes.status, headers,
            });
          }
        }
        // 1. 创建 DM 频道
        const dmRes = await fetch(`${DISCORD_API}/users/@me/channels`, {
          method: "POST",
          headers: authHeaders,
          body: JSON.stringify({ recipient_id: user_id }),
        });
        const dmBody = await dmRes.text();
        if (!dmRes.ok) {
          let diagnostic = '';
          if (guild_id && dmRes.status === 403) {
            try {
              const meRes = await fetch(`${DISCORD_API}/users/@me`, { headers: authHeaders });
              const meBody = await meRes.text();
              const guildsRes = await fetch(`${DISCORD_API}/users/@me/guilds`, { headers: authHeaders });
              const guildsBody = await guildsRes.text();
              const me = meRes.ok ? JSON.parse(meBody) : null;
              const guilds = guildsRes.ok ? JSON.parse(guildsBody) : [];
              diagnostic = ` [诊断: Bot=${me?.id || "unknown"}, target_guild=${guild_id}, bot_in_target_guild=${guilds.some((guild: any) => String(guild.id) === String(guild_id))}, bot_guild_count=${guilds.length}]`;
            } catch (_) {}
          }
          return new Response(JSON.stringify({ ok: false, error: `创建DM失败: ${dmRes.status} ${dmBody}${diagnostic}` }), {
            status: dmRes.status, headers,
          });
        }
        const dm = JSON.parse(dmBody);
        // 2. 发送消息
        const msgRes = await fetch(`${DISCORD_API}/channels/${dm.id}/messages`, {
          method: "POST",
          headers: authHeaders,
          body: JSON.stringify({ content: message }),
        });
        const msgBody = await msgRes.text();
        if (!msgRes.ok) {
          let diagnostic = '';
          if (msgRes.status === 403) {
            diagnostic = ` [诊断: dm_channel=${dm.id}, target_guild=${guild_id || "not_provided"}, user_id=${user_id}]`;
          }
          return new Response(JSON.stringify({ ok: false, error: `发送消息失败: ${msgRes.status} ${msgBody}${diagnostic}` }), {
            status: msgRes.status, headers,
          });
        }
        result = { ok: true, message_id: JSON.parse(msgBody).id };
        break;
      }

      // 扫描 Bot 在指定时间后发送的系统私信，只读，不删除
      case "scan_recent_dms": {
        const since = new Date(data?.since || Date.now() - 6 * 60 * 60 * 1000);
        const targetGuildId = String(data?.guild_id || "").trim();
        if (Number.isNaN(since.getTime())) {
          return new Response(JSON.stringify({ ok: false, error: "无效的扫描起始时间" }), { status: 400, headers });
        }
        const meRes = await fetch(`${DISCORD_API}/users/@me`, { headers: authHeaders });
        const meBody = await meRes.text();
        if (!meRes.ok) {
          return new Response(JSON.stringify({ ok: false, error: `获取 Bot 信息失败: ${meRes.status} ${meBody}` }), { status: meRes.status, headers });
        }
        const botUser = JSON.parse(meBody);
        const guildRes = await fetch(`${DISCORD_API}/users/@me/guilds`, { headers: authHeaders });
        const guildBody = await guildRes.text();
        if (!guildRes.ok) {
          return new Response(JSON.stringify({ ok: false, error: `获取 Bot 服务器列表失败: ${guildRes.status} ${guildBody}` }), { status: guildRes.status, headers });
        }
        const guilds = JSON.parse(guildBody);
        const scanGuilds = targetGuildId
          ? guilds.filter((guild: any) => String(guild.id) === targetGuildId)
          : guilds;
        if (targetGuildId && scanGuilds.length === 0) {
          return new Response(JSON.stringify({ ok: false, error: "MochiBot 不在指定 Discord 服务器中" }), { status: 403, headers });
        }
        const memberMap = new Map<string, any>();
        for (const guild of scanGuilds) {
          const memberRes = await fetch(`${DISCORD_API}/guilds/${guild.id}/members?limit=1000`, { headers: authHeaders });
          if (!memberRes.ok) continue;
          for (const member of await memberRes.json()) {
            if (!member.user?.bot) memberMap.set(member.user.id, member.user);
          }
        }
        const candidates: any[] = [];
        const failures: string[] = [];
        for (const user of memberMap.values()) {
          const dmRes = await fetch(`${DISCORD_API}/users/@me/channels`, {
            method: "POST",
            headers: authHeaders,
            body: JSON.stringify({ recipient_id: user.id }),
          });
          if (!dmRes.ok) continue;
          const dm = await dmRes.json();
          const messagesRes = await fetch(`${DISCORD_API}/channels/${dm.id}/messages?limit=20`, { headers: authHeaders });
          if (!messagesRes.ok) {
            failures.push(`${user.username}: ${messagesRes.status}`);
            continue;
          }
          const messages = await messagesRes.json();
          for (const message of messages) {
            const sentAt = new Date(message.timestamp);
            const content = String(message.content || "");
            const isMochiSystemMessage = content.includes("MochiBot only sends system notifications") ||
              content.includes("yoyo-koc-exchange/index.html");
            if (message.author?.id === botUser.id && sentAt >= since && isMochiSystemMessage) {
              candidates.push({
                channel_id: dm.id,
                message_id: message.id,
                user_id: user.id,
                username: user.username,
                timestamp: message.timestamp,
                preview: content.slice(0, 120),
                fingerprint: content.trim().replace(/\s+/g, " ").toLowerCase(),
              });
            }
          }
        }
        result = { candidates, scanned_members: memberMap.size, failures };
        break;
      }

      // 删除指定的 Bot 私信；调用方必须先通过 scan_recent_dms 确认精确消息 ID
      case "delete_dm_messages": {
        const messages = Array.isArray(data?.messages) ? data.messages : [];
        const meRes = await fetch(`${DISCORD_API}/users/@me`, { headers: authHeaders });
        const meBody = await meRes.text();
        if (!meRes.ok) {
          return new Response(JSON.stringify({ ok: false, error: `获取 Bot 信息失败: ${meRes.status} ${meBody}` }), { status: meRes.status, headers });
        }
        const botUser = JSON.parse(meBody);
        const deleted: any[] = [];
        const failures: any[] = [];
        for (const message of messages) {
          const channelId = String(message?.channel_id || "");
          const messageId = String(message?.message_id || "");
          if (!/^\d+$/.test(channelId) || !/^\d+$/.test(messageId)) {
            failures.push({ channel_id: channelId, message_id: messageId, error: "无效消息 ID" });
            continue;
          }
          const messageRes = await fetch(`${DISCORD_API}/channels/${channelId}/messages/${messageId}`, {
            headers: authHeaders,
          });
          const messageBody = await messageRes.text();
          if (!messageRes.ok) {
            failures.push({ channel_id: channelId, message_id: messageId, error: `读取消息失败: ${messageRes.status} ${messageBody}` });
            continue;
          }
          const existingMessage = JSON.parse(messageBody);
          if (String(existingMessage.author?.id || "") !== String(botUser.id)) {
            failures.push({ channel_id: channelId, message_id: messageId, error: "拒绝删除：消息不是由当前 MochiBot 发送" });
            continue;
          }
          const deleteRes = await fetch(`${DISCORD_API}/channels/${channelId}/messages/${messageId}`, {
            method: "DELETE",
            headers: authHeaders,
          });
          if (deleteRes.ok || deleteRes.status === 204) deleted.push({ channel_id: channelId, message_id: messageId });
          else failures.push({ channel_id: channelId, message_id: messageId, error: `${deleteRes.status} ${await deleteRes.text()}` });
        }
        result = { deleted, failures };
        break;
      }

      default:
        return new Response(JSON.stringify({ ok: false, error: `未知操作: ${action}` }), {
          status: 400, headers,
        });
    }

    return new Response(JSON.stringify({ ok: true, data: result }), {
      status: 200, headers,
    });
  } catch (e: any) {
    return new Response(JSON.stringify({ ok: false, error: e.message }), {
      status: 500, headers,
    });
  }
});

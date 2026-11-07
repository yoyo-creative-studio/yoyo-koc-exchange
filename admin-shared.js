function fetchWithNetworkRetry(url, opts, retries) {
  var remaining = Number(retries || 0);
  return fetch(url, opts).catch(function(error) {
    if (remaining <= 0) throw error;
    return new Promise(function(resolve) { setTimeout(resolve, 450); }).then(function() {
      return fetchWithNetworkRetry(url, opts, remaining - 1);
    });
  });
}

function supabaseFetch(url, opts) {
  opts = opts || {};
  var projectId = window.ACTIVE_PROJECT_ID || '';
  var method = String(opts.method || 'GET').toUpperCase();
  if (/\/rest\/v1\/(kocs|registration_applications|submissions|point_logs|redemption_orders|reward_fulfillments|redemption_order_edits|creator_monthly_tier_scores|creator_tier_history|campaign_config)(\?|$)/.test(url) && typeof ADMIN_SESSION !== 'undefined' && ADMIN_SESSION) {
    var parsedUrl = new URL(url);
    var proxyBody = null;
    if (opts.body && method !== 'GET' && method !== 'HEAD') {
      try { proxyBody = typeof opts.body === 'string' ? JSON.parse(opts.body) : opts.body; } catch (error) { return Promise.reject(new Error('Invalid request body')); }
    }
    return fetchWithNetworkRetry(SUPABASE_URL + '/functions/v1/registration-review', {
      method: 'POST',
      headers: { 'apikey': SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'admin_data', admin_password: ADMIN_PASSWORD, admin_session: ADMIN_SESSION, data: {
        project_key: getActiveProjectKey(), method: method, path: parsedUrl.pathname + parsedUrl.search, body: proxyBody
      } })
    }, method === 'GET' || method === 'HEAD' ? 2 : 0);
  }
  if (method === 'GET' && /\/rest\/v1\/kocs(?:\?|$)/.test(url) && typeof allKocs !== 'undefined' && Array.isArray(allKocs)) {
    var rows = allKocs.slice();
    var uidMatch = url.match(/[?&]uid=eq\.([^&]+)/);
    var statusMatch = url.match(/[?&]status=eq\.([^&]+)/);
    var discordMatch = url.match(/[?&]discord_name=eq\.([^&]+)/);
    var excludeConfig = /uid=neq\.__config__/.test(url);
    if (uidMatch) rows = rows.filter(function(row) { return String(row.uid || '') === decodeURIComponent(uidMatch[1]); });
    if (statusMatch) rows = rows.filter(function(row) { return String(row.status || '') === decodeURIComponent(statusMatch[1]); });
    if (discordMatch) rows = rows.filter(function(row) { return String(row.discord_name || '') === decodeURIComponent(discordMatch[1]); });
    if (excludeConfig) rows = rows.filter(function(row) { return String(row.uid || '') !== '__config__'; });
    if (/order=discord_name\.asc/.test(url)) rows.sort(function(a, b) { return String(a.discord_name || '').localeCompare(String(b.discord_name || '')); });
    var selectMatch = url.match(/[?&]select=([^&]+)/);
    if (selectMatch && selectMatch[1] !== '*') {
      var fields = decodeURIComponent(selectMatch[1]).split(',');
      rows = rows.map(function(row) { var picked = {}; fields.forEach(function(field) { picked[field] = row[field]; }); return picked; });
    }
    return Promise.resolve(new Response(JSON.stringify(rows), { status: 200, headers: { 'Content-Type': 'application/json' } }));
  }
  var projectTableMatch = url.match(/\/rest\/v1\/(kocs|registration_applications|submissions|point_logs|redemption_orders|reward_fulfillments|redemption_order_edits|creator_monthly_tier_scores|creator_tier_history|campaign_config)(\?|$)/);
  if (method !== 'POST' && projectId && projectTableMatch && !/[?&]project_id=/.test(url)) {
    url += (url.indexOf('?') >= 0 ? '&' : '?') + 'project_id=eq.' + encodeURIComponent(projectId);
  }
  if (method === 'POST' && projectId && projectTableMatch && opts.body) {
    try {
      var parsedBody = typeof opts.body === 'string' ? JSON.parse(opts.body) : opts.body;
      var rows = Array.isArray(parsedBody) ? parsedBody : [parsedBody];
      rows.forEach(function(row) {
        if (row && typeof row === 'object' && !row.project_id) row.project_id = projectId;
      });
      opts = Object.assign({}, opts, { body: JSON.stringify(parsedBody) });
    } catch (error) {
      throw new Error('Invalid project-scoped request body');
    }
  }
  return fetchWithNetworkRetry(url, Object.assign({}, opts, {
    headers: Object.assign({ 'apikey': SUPABASE_KEY, 'Content-Type': 'application/json' }, opts.headers || {})
  }), method === 'GET' || method === 'HEAD' ? 2 : 0);
}

var REDEMPTION_STATUSES = ['pending', 'processing', 'shipped', 'cancelled'];

async function updateRedemptionOrderStatus(orderId, status) {
  if (REDEMPTION_STATUSES.indexOf(status) < 0) throw new Error('Invalid redemption status: ' + status);
  var response = await supabaseFetch(SUPABASE_URL + '/rest/v1/redemption_orders?id=eq.' + encodeURIComponent(orderId), {
    method: 'PATCH', body: JSON.stringify({ status: status })
  });
  if (!response.ok) throw new Error((await response.text()).substring(0, 120));
  return response;
}

async function appendPointLog(uid, change, reason, period, source) {
  var current = await getBalance(uid);
  var next = current + Number(change || 0);
  var response = await supabaseFetch(SUPABASE_URL + '/rest/v1/point_logs', {
    method: 'POST',
    body: JSON.stringify({ uid: uid, change: Number(change || 0), balance_after: next,
      source: source || 'manual', reason: reason, period: period || currentPeriod,
      created_by: 'admin', created_at: new Date().toISOString() })
  });
  if (!response.ok) throw new Error((await response.text()).substring(0, 120));
  return { before: current, after: next };
}

function discordIdentityKeys(value) {
  var raw = String(value || '').normalize('NFKC').trim().toLowerCase();
  if (!raw) return [];
  var values = [raw];
  var userHint = raw.match(/\(\s*user\s*:\s*([^\)]+)\)/i);
  if (userHint) values.push(userHint[1]);
  raw.split('/').forEach(function(part) { values.push(part); });
  return values.map(function(item) {
    return item.replace(/^@/, '').replace(/\s+/g, ' ').trim();
  }).filter(Boolean).filter(function(item, index, list) { return list.indexOf(item) === index; });
}

function normalizeCreatorSearchText(value) {
  return String(value || '')
    .normalize('NFKC')
    .toLowerCase()
    .replace(/^@+/, '')
    .replace(/[\p{P}\p{S}\s_]+/gu, '');
}

function creatorIdentitySearchValues(koc) {
  return [
    koc && koc.discord_name,
    koc && koc.discord_username,
    koc && koc.discord_display_name,
    koc && koc.discord_user_id,
    koc && koc.uid,
    koc && koc.account_id
  ].concat(koc && Array.isArray(koc.discord_aliases) ? koc.discord_aliases : []);
}

function creatorMatchesIdentitySearch(koc, query) {
  var rawQuery = String(query || '').normalize('NFKC').trim().toLowerCase();
  if (!rawQuery) return true;
  var normalizedQuery = normalizeCreatorSearchText(rawQuery);
  return creatorIdentitySearchValues(koc).some(function(value) {
    var rawValue = String(value || '').normalize('NFKC').toLowerCase();
    return rawValue.indexOf(rawQuery) >= 0 ||
      (normalizedQuery && normalizeCreatorSearchText(rawValue).indexOf(normalizedQuery) >= 0);
  });
}

function discordMemberIdentityKeys(member) {
  var keys = [];
  [member && member.id, member && member.username, member && member.global_name, member && member.nick].forEach(function(value) {
    discordIdentityKeys(value).forEach(function(key) { if (keys.indexOf(key) < 0) keys.push(key); });
  });
  return keys;
}

function findDiscordMemberForKoc(koc, members) {
  if (!koc) return null;
  if (koc.discord_user_id) {
    var byId = (members || []).find(function(member) { return String(member.id || '') === String(koc.discord_user_id); });
    if (byId) return byId;
  }
  var wanted = [];
  [koc.discord_name, koc.discord_username, koc.discord_display_name].concat(Array.isArray(koc.discord_aliases) ? koc.discord_aliases : []).forEach(function(value) {
    discordIdentityKeys(value).forEach(function(key) { if (wanted.indexOf(key) < 0) wanted.push(key); });
  });
  var matches = (members || []).filter(function(member) {
    return discordMemberIdentityKeys(member).some(function(key) { return wanted.indexOf(key) >= 0; });
  });
  return matches.length === 1 ? matches[0] : null;
}

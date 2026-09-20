function supabaseFetch(url, opts) {
  opts = opts || {};
  return fetch(url, Object.assign({}, opts, {
    headers: Object.assign({ 'apikey': SUPABASE_KEY, 'Content-Type': 'application/json' }, opts.headers || {})
  }));
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

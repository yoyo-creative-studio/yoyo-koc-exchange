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

function discordMemberIdentityKeys(member) {
  var keys = [];
  [member && member.id, member && member.username, member && member.global_name, member && member.nick].forEach(function(value) {
    discordIdentityKeys(value).forEach(function(key) { if (keys.indexOf(key) < 0) keys.push(key); });
  });
  return keys;
}

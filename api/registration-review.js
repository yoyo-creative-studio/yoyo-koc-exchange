const UPSTREAM_URL = 'https://rryzofimrehmkijkckrm.functions.supabase.co/registration-review';

module.exports = async function handler(request, response) {
  if (request.method === 'OPTIONS') {
    response.status(204).end();
    return;
  }

  if (request.method !== 'POST') {
    response.status(405).json({ ok: false, error: 'Method not allowed' });
    return;
  }

  const body = typeof request.body === 'string' ? request.body : JSON.stringify(request.body || {});
  const upstream = await fetch(UPSTREAM_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
  });
  const payload = await upstream.text();

  response.setHeader('Cache-Control', 'no-store, max-age=0');
  response.setHeader('Content-Type', upstream.headers.get('content-type') || 'application/json');
  response.status(upstream.status).send(payload);
};
